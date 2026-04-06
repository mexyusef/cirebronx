const std = @import("std");
const ziggy = @import("ziggy");

const App = @import("../core/app.zig").App;
const message_mod = @import("../core/message.zig");
const commands = @import("../commands/registry.zig");
const permissions = @import("../core/permissions.zig");
const provider = @import("../provider/adapter.zig");
const session_store = @import("../storage/session.zig");
const prompt_history_store = @import("../storage/prompt_history.zig");
const tools = @import("../tools/registry.zig");
const tui_state = @import("tui_state.zig");
const tui_text = @import("tui_text.zig");
const tui_items = @import("tui_items.zig");
const tui_layout = @import("tui_layout.zig");
const tui_input = @import("tui_input.zig");

const Msg = ziggy.Event;
const Item = tui_items.Item;

const PaneFocus = enum {
    conversation,
    activity,
    input,
};

const slash_completion_items = [_]ziggy.Completion.Item{
    .{ .label = "/help", .value = "/help", .detail = "Show commands" },
    .{ .label = "/exit", .value = "/exit", .detail = "Exit interactive mode" },
    .{ .label = "/clear", .value = "/clear", .detail = "Clear current session" },
    .{ .label = "/session", .value = "/session", .detail = "Show session id" },
    .{ .label = "/config", .value = "/config", .detail = "Show config" },
    .{ .label = "/sessions", .value = "/sessions", .detail = "List recent sessions" },
    .{ .label = "/provider", .value = "/provider ", .detail = "Set provider" },
    .{ .label = "/model", .value = "/model ", .detail = "Set model" },
    .{ .label = "/skills", .value = "/skills", .detail = "List skills" },
    .{ .label = "/mcp", .value = "/mcp ", .detail = "Manage MCP servers" },
    .{ .label = "/plugins", .value = "/plugins", .detail = "List plugins" },
    .{ .label = "/doctor", .value = "/doctor", .detail = "Run environment checks" },
    .{ .label = "/diff", .value = "/diff", .detail = "Show git status and diff stat" },
    .{ .label = "/review", .value = "/review", .detail = "Review changed files" },
    .{ .label = "/compact", .value = "/compact", .detail = "Compact the current session" },
    .{ .label = "/permissions", .value = "/permissions ", .detail = "Show or set permissions" },
    .{ .label = "/plan", .value = "/plan ", .detail = "Toggle plan mode" },
    .{ .label = "/resume", .value = "/resume ", .detail = "Resume a session" },
};

const pane_focus_targets = [_]ziggy.FocusTarget{
    .{ .id = "conversation" },
    .{ .id = "input" },
};

const TuiProgram = ziggy.Program(TuiModel, Msg);
const theme = ziggy.defaultAgentTheme();

const TuiModel = struct {
    app: *App,
    editor: ziggy.Editor,
    sidebar_output: []const u8 = "",
    focus: PaneFocus = .input,
    conversation_scroll: usize = 0,
    conversation_body_scroll: usize = 0,
    activity_scroll: usize = 0,
    conversation_selected: usize = 0,
    activity_selected: usize = 0,
    history: tui_state.PromptHistory = .{},
    completion: ziggy.Completion.State = .{},
    input_viewport: ziggy.TextArea.Viewport = .{},
    palette_open: bool = false,
    modal: tui_state.ModalState = .{},
    actions: tui_state.ActionLog = .{},
    status_text: []const u8 = "",
    notification: ?[]u8 = null,
    notification_level: ziggy.NoticeBar.Level = .info,
    notification_until_ms: u64 = 0,
    turn_running: bool = false,
    pending_prompt: ?[]u8 = null,
    current_tool: ?[]u8 = null,
    last_error: ?[]u8 = null,
    live_assistant: ?[]u8 = null,

    fn deinit(self: *TuiModel, allocator: std.mem.Allocator) void {
        self.editor.deinit(allocator);
        self.completion.deinit(allocator);
        allocator.free(self.sidebar_output);
        allocator.free(self.status_text);
        if (self.notification) |text| allocator.free(text);
        if (self.pending_prompt) |prompt| allocator.free(prompt);
        if (self.current_tool) |tool| allocator.free(tool);
        if (self.last_error) |err_text| allocator.free(err_text);
        if (self.live_assistant) |text| allocator.free(text);
        self.history.deinit(allocator);
        self.modal.deinit(allocator);
        self.actions.deinit(allocator);
    }

    pub fn init(self: *@This(), ctx: *ziggy.Context) ziggy.Command(Msg) {
        _ = self;
        ctx.requestRedraw();
        return .{ .set_tick_interval_ms = 80 };
    }

    pub fn update(self: *@This(), event: Msg, ctx: *ziggy.Context) ziggy.Command(Msg) {
        _ = self;
        switch (event) {
            .key => |key| switch (key) {
                .ctrl_c => return .quit,
                else => {},
            },
            .resize => |_| ctx.requestRedraw(),
            else => {},
        }
        return .none;
    }

    pub fn tick(self: *@This(), ctx: *ziggy.Context) ziggy.Command(Msg) {
        if (self.notification_until_ms > 0 and ctx.now_ms >= self.notification_until_ms) {
            self.clearNotification(ctx.allocator);
        }
        if (self.turn_running or self.completion.visible or self.palette_open or self.notification != null) return .redraw;
        return .none;
    }

    pub fn replaceInput(self: *@This(), allocator: std.mem.Allocator, input: []const u8, cursor: usize) !void {
        try self.editor.setText(allocator, input, cursor);
        try self.refreshCompletion(allocator);
    }

    pub fn clearInput(self: *@This(), allocator: std.mem.Allocator) !void {
        try self.replaceInput(allocator, "", 0);
    }

    pub fn setSidebarOutput(self: *@This(), allocator: std.mem.Allocator, output: []const u8) !void {
        allocator.free(self.sidebar_output);
        self.sidebar_output = try allocator.dupe(u8, output);
    }

    fn setStatus(self: *@This(), allocator: std.mem.Allocator, output: []const u8) !void {
        allocator.free(self.status_text);
        self.status_text = try allocator.dupe(u8, output);
    }

    fn setNotification(self: *@This(), allocator: std.mem.Allocator, level: ziggy.NoticeBar.Level, output: []const u8, now_ms: u64, duration_ms: u64) !void {
        if (self.notification) |existing| allocator.free(existing);
        self.notification = try allocator.dupe(u8, output);
        self.notification_level = level;
        self.notification_until_ms = now_ms + duration_ms;
    }

    fn clearNotification(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.notification) |existing| allocator.free(existing);
        self.notification = null;
        self.notification_until_ms = 0;
    }

    pub fn logAction(self: *@This(), allocator: std.mem.Allocator, output: []const u8) !void {
        try self.actions.append(allocator, output);
        try self.setStatus(allocator, output);
    }

    fn setPendingPrompt(self: *@This(), allocator: std.mem.Allocator, prompt: []const u8) !void {
        if (self.pending_prompt) |existing| allocator.free(existing);
        self.pending_prompt = try allocator.dupe(u8, prompt);
    }

    fn clearPendingPrompt(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.pending_prompt) |existing| allocator.free(existing);
        self.pending_prompt = null;
    }

    fn setCurrentTool(self: *@This(), allocator: std.mem.Allocator, tool_name: []const u8) !void {
        if (self.current_tool) |existing| allocator.free(existing);
        self.current_tool = try allocator.dupe(u8, tool_name);
    }

    fn clearCurrentTool(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.current_tool) |existing| allocator.free(existing);
        self.current_tool = null;
    }

    fn setLastError(self: *@This(), allocator: std.mem.Allocator, err_text: []const u8) !void {
        if (self.last_error) |existing| allocator.free(existing);
        self.last_error = try allocator.dupe(u8, err_text);
    }

    fn clearLastError(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.last_error) |existing| allocator.free(existing);
        self.last_error = null;
    }

    fn appendLiveAssistant(self: *@This(), allocator: std.mem.Allocator, chunk: []const u8) !void {
        const next = if (self.live_assistant) |existing|
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ existing, chunk })
        else
            try allocator.dupe(u8, chunk);
        if (self.live_assistant) |existing| allocator.free(existing);
        self.live_assistant = next;
    }

    fn clearLiveAssistant(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.live_assistant) |existing| allocator.free(existing);
        self.live_assistant = null;
    }

    fn appendSidebarLine(self: *@This(), allocator: std.mem.Allocator, line: []const u8) !void {
        const next = if (self.sidebar_output.len == 0)
            try allocator.dupe(u8, line)
        else
            try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ self.sidebar_output, line });
        allocator.free(self.sidebar_output);
        self.sidebar_output = next;
    }

    pub fn reusableSelection(self: *@This(), allocator: std.mem.Allocator) !?[]u8 {
        return switch (self.focus) {
            .conversation => blk: {
                const items = try buildConversationItems(self, allocator);
                defer tui_items.freeItems(allocator, items);
                if (items.len == 0) break :blk null;
                break :blk if (items[self.conversation_selected].reuse) |text|
                    try allocator.dupe(u8, text)
                else
                    null;
            },
            .activity => blk: {
                const items = try buildActivityItems(self, allocator);
                defer tui_items.freeItems(allocator, items);
                if (items.len == 0) break :blk null;
                break :blk if (items[self.activity_selected].reuse) |text|
                    try allocator.dupe(u8, text)
                else
                    null;
            },
            .input => null,
        };
    }

    fn insertChar(self: *@This(), allocator: std.mem.Allocator, byte: u8) !void {
        try self.editor.insertChar(allocator, byte);
        try self.refreshCompletion(allocator);
    }

    fn insertText(self: *@This(), allocator: std.mem.Allocator, text: []const u8) !void {
        try self.editor.insertText(allocator, text);
        try self.refreshCompletion(allocator);
    }

    pub fn insertNewline(self: *@This(), allocator: std.mem.Allocator) !void {
        try self.editor.insertNewline(allocator);
        try self.refreshCompletion(allocator);
    }

    fn backspace(self: *@This(), allocator: std.mem.Allocator) !void {
        try self.editor.backspace(allocator);
        try self.refreshCompletion(allocator);
    }

    fn deleteForward(self: *@This(), allocator: std.mem.Allocator) !void {
        try self.editor.deleteForward(allocator);
        try self.refreshCompletion(allocator);
    }

    fn moveLeft(self: *@This()) void {
        self.editor.moveLeft();
    }

    fn moveRight(self: *@This()) void {
        self.editor.moveRight();
    }

    pub fn deleteToStart(self: *@This(), allocator: std.mem.Allocator) !void {
        try self.editor.deleteToStart(allocator);
        try self.refreshCompletion(allocator);
    }

    pub fn deleteToEnd(self: *@This(), allocator: std.mem.Allocator) !void {
        try self.editor.deleteToEnd(allocator);
        try self.refreshCompletion(allocator);
    }

    pub fn deletePreviousWord(self: *@This(), allocator: std.mem.Allocator) !void {
        try self.editor.deletePreviousWord(allocator);
        try self.refreshCompletion(allocator);
    }

    fn submittedInput(self: *@This(), allocator: std.mem.Allocator) ![]u8 {
        return try self.editor.trimmedCopy(allocator);
    }

    pub fn moveHome(self: *@This()) void {
        self.editor.moveHome();
    }

    pub fn moveEnd(self: *@This()) void {
        self.editor.moveEnd();
    }

    fn moveWordLeft(self: *@This()) void {
        self.editor.moveWordLeft();
    }

    fn moveWordRight(self: *@This()) void {
        self.editor.moveWordRight();
    }

    fn refreshCompletion(self: *@This(), allocator: std.mem.Allocator) !void {
        if (self.focus != .input or self.editor.value.len == 0 or self.editor.value[0] != '/') {
            self.completion.clear(allocator);
            self.palette_open = false;
            return;
        }
        try ziggy.Completion.update(allocator, &self.completion, &self.editor, &slash_completion_items);
        self.palette_open = self.completion.visible;
    }

    fn openCompletion(self: *@This(), allocator: std.mem.Allocator) !void {
        try self.refreshCompletion(allocator);
    }

    fn openCommandPalette(self: *@This(), allocator: std.mem.Allocator, now_ms: u64) !void {
        self.focus = .input;
        if (self.editor.value.len == 0 or self.editor.value[0] != '/') {
            try self.replaceInput(allocator, "/", 1);
        } else {
            try self.refreshCompletion(allocator);
        }
        self.palette_open = self.completion.visible;
        try self.setNotification(allocator, .info, "command palette", now_ms, 1800);
    }

    fn closeCommandPalette(self: *@This(), allocator: std.mem.Allocator) void {
        self.palette_open = false;
        if (self.editor.value.len == 1 and self.editor.value[0] == '/') {
            self.replaceInput(allocator, "", 0) catch {};
        } else {
            self.completion.clear(allocator);
        }
    }

    fn acceptCompletion(self: *@This(), allocator: std.mem.Allocator) !bool {
        if (!self.completion.visible) return false;
        if (!try self.completion.applyCurrent(allocator, &self.editor)) return false;
        try self.refreshCompletion(allocator);
        self.palette_open = false;
        self.input_viewport = ziggy.TextArea.followCursor(&self.editor, "> ", self.input_viewport);
        return true;
    }

    fn selectLeft(self: *@This()) void {
        self.editor.selectLeft();
    }

    fn selectRight(self: *@This()) void {
        self.editor.selectRight();
    }

    pub fn jumpToLatestError(self: *@This(), allocator: std.mem.Allocator, size: ziggy.Size) !bool {
        const items = try buildActivityItems(self, allocator);
        defer tui_items.freeItems(allocator, items);
        if (items.len == 0) return false;
        var index = items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.indexOf(u8, items[index].label, "Error") != null) {
                self.focus = .activity;
                self.activity_selected = index;
                self.syncScrollBounds(size);
                return true;
            }
        }
        return false;
    }

    pub fn jumpToLatestTool(self: *@This(), allocator: std.mem.Allocator, size: ziggy.Size) !bool {
        const items = try buildConversationItems(self, allocator);
        defer tui_items.freeItems(allocator, items);
        if (items.len == 0) return false;
        var index = items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.indexOf(u8, items[index].label, "[assistant/tools]") != null) {
                self.focus = .conversation;
                self.conversation_selected = index;
                self.conversation_body_scroll = 0;
                self.syncScrollBounds(size);
                return true;
            }
        }
        return false;
    }

    fn cycleFocus(self: *@This()) void {
        const next_index = ziggy.focusNavNext(&pane_focus_targets, paneFocusId(self.focus)) orelse return;
        self.focus = paneFocusFromTarget(next_index);
    }

    fn cycleFocusReverse(self: *@This()) void {
        const next_index = ziggy.focusNavPrevious(&pane_focus_targets, paneFocusId(self.focus)) orelse return;
        self.focus = paneFocusFromTarget(next_index);
    }

    pub fn syncScrollBounds(self: *@This(), size: ziggy.Size) void {
        const conversation_total = conversationItemCount(self, self.app.allocator) catch 0;
        const conversation_body_total = conversationBodyLineCount(self, self.app.allocator, size) catch 0;
        const activity_total = activityItemCount(self);
        if (conversation_total > 0) self.conversation_selected = @min(self.conversation_selected, conversation_total - 1) else self.conversation_selected = 0;
        if (activity_total > 0) self.activity_selected = @min(self.activity_selected, activity_total - 1) else self.activity_selected = 0;
        self.conversation_scroll = @min(self.conversation_scroll, tui_layout.maxScrollOffset(conversation_total, tui_layout.conversationVisibleHeightForSize(size)));
        self.conversation_body_scroll = @min(self.conversation_body_scroll, tui_layout.maxScrollOffset(conversation_body_total, tui_layout.conversationBodyVisibleHeight(size)));
        self.activity_scroll = @min(self.activity_scroll, tui_layout.maxScrollOffset(activity_total, tui_layout.activityVisibleHeightForSize(size)));
        self.ensureSelectionVisible(size, activity_total);
    }

    fn ensureSelectionVisible(self: *@This(), size: ziggy.Size, activity_total: usize) void {
        const act_visible = tui_layout.activityVisibleHeightForSize(size);
        if (activity_total > 0) {
            if (self.activity_selected < self.activity_scroll) self.activity_scroll = self.activity_selected;
            if (self.activity_selected >= self.activity_scroll + act_visible) {
                self.activity_scroll = self.activity_selected -| act_visible -| 1;
            }
        }
    }

    fn followConversation(self: *@This(), size: ziggy.Size, conversation_total: usize) void {
        if (conversation_total == 0) return;
        self.conversation_selected = conversation_total - 1;
        self.conversation_scroll = 0;
        const conversation_body_total = conversationBodyLineCount(self, self.app.allocator, size) catch 0;
        self.conversation_body_scroll = tui_layout.maxScrollOffset(conversation_body_total, tui_layout.conversationBodyVisibleHeight(size));
    }

    fn browseHistoryUp(self: *@This(), allocator: std.mem.Allocator) !void {
        if (self.history.items.items.len == 0) return;
        if (self.history.browse_index == null) {
            if (self.history.draft) |draft| allocator.free(draft);
            self.history.draft = try allocator.dupe(u8, self.editor.value);
            self.history.browse_index = self.history.items.items.len - 1;
        } else if (self.history.browse_index.? > 0) {
            self.history.browse_index.? -= 1;
        }
        const selected = self.history.items.items[self.history.browse_index.?];
        try self.replaceInput(allocator, selected, selected.len);
    }

    fn browseHistoryDown(self: *@This(), allocator: std.mem.Allocator) !void {
        if (self.history.browse_index == null) return;
        if (self.history.browse_index.? + 1 < self.history.items.items.len) {
            self.history.browse_index.? += 1;
            const selected = self.history.items.items[self.history.browse_index.?];
            try self.replaceInput(allocator, selected, selected.len);
            return;
        }
        const draft = self.history.draft orelse "";
        try self.replaceInput(allocator, draft, draft.len);
        self.history.resetBrowse(allocator);
    }

    pub fn searchHistoryBackward(self: *@This(), allocator: std.mem.Allocator) !bool {
        const query = std.mem.trim(u8, self.editor.value, " \r\t\n");
        if (self.history.items.items.len == 0) return false;

        var index: usize = self.history.items.items.len;
        while (index > 0) {
            index -= 1;
            const entry = self.history.items.items[index];
            if (query.len == 0 or std.mem.indexOf(u8, entry, query) != null) {
                try self.replaceInput(allocator, entry, entry.len);
                self.history.browse_index = index;
                return true;
            }
        }
        return false;
    }

    pub fn moveSelectionUp(self: *@This(), size: ziggy.Size) void {
        switch (self.focus) {
            .conversation => {
                const conversation_body_total = conversationBodyLineCount(self, self.app.allocator, size) catch 0;
                const conversation_visible = tui_layout.conversationBodyVisibleHeight(size);
                if (conversation_body_total > conversation_visible and self.conversation_body_scroll > 0) {
                    self.conversation_body_scroll -|= 1;
                } else if (self.conversation_selected > 0) {
                    self.conversation_selected -= 1;
                    self.conversation_body_scroll = 0;
                }
            },
            .activity => {
                if (self.activity_selected > 0) self.activity_selected -= 1;
            },
            .input => {},
        }
        self.syncScrollBounds(size);
    }

    pub fn moveSelectionDown(self: *@This(), size: ziggy.Size, conversation_total: usize, activity_total: usize) void {
        switch (self.focus) {
            .conversation => {
                const conversation_body_total = conversationBodyLineCount(self, self.app.allocator, size) catch 0;
                const conversation_visible = tui_layout.conversationBodyVisibleHeight(size);
                const conversation_max_scroll = tui_layout.maxScrollOffset(conversation_body_total, conversation_visible);
                if (conversation_body_total > conversation_visible and self.conversation_body_scroll < conversation_max_scroll) {
                    self.conversation_body_scroll += 1;
                } else if (conversation_total > 0 and self.conversation_selected + 1 < conversation_total) {
                    self.conversation_selected += 1;
                    self.conversation_body_scroll = 0;
                }
            },
            .activity => {
                if (activity_total > 0 and self.activity_selected + 1 < activity_total) {
                    self.activity_selected += 1;
                }
            },
            .input => {},
        }
        self.syncScrollBounds(size);
    }

    fn openSelectionModal(self: *@This(), allocator: std.mem.Allocator) !void {
        switch (self.focus) {
            .conversation => {
                const items = try buildConversationItems(self, allocator);
                defer tui_items.freeItems(allocator, items);
                if (items.len == 0) return;
                try self.modal.open(allocator, items[self.conversation_selected].label, items[self.conversation_selected].body);
            },
            .activity => {
                const items = try buildActivityItems(self, allocator);
                defer tui_items.freeItems(allocator, items);
                if (items.len == 0) return;
                try self.modal.open(allocator, items[self.activity_selected].label, items[self.activity_selected].body);
            },
            .input => {},
        }
    }

    pub fn openHelpModal(self: *@This(), allocator: std.mem.Allocator) !void {
        const body = try tui_text.buildHelpBody(allocator);
        defer allocator.free(body);
        try self.modal.open(allocator, "TUI Help", body);
    }

    pub fn openSessionModal(self: *@This(), allocator: std.mem.Allocator) !void {
        const body = try tui_text.buildSessionBody(allocator, self.app, self.turn_running, self.status_text);
        defer allocator.free(body);
        try self.modal.open(allocator, "Session", body);
    }

    pub fn openConfigModal(self: *@This(), allocator: std.mem.Allocator) !void {
        const body = try tui_text.buildConfigBody(allocator, self.app);
        defer allocator.free(body);
        try self.modal.open(allocator, "Config", body);
    }

    fn openCustomModal(self: *@This(), allocator: std.mem.Allocator, title: []const u8, body: []const u8) !void {
        try self.modal.open(allocator, title, body);
    }

    fn closeModal(self: *@This(), allocator: std.mem.Allocator) void {
        self.modal.close(allocator);
    }

    pub fn reuseSelectedIntoInput(self: *@This(), allocator: std.mem.Allocator) !void {
        switch (self.focus) {
            .conversation => {
                const items = try buildConversationItems(self, allocator);
                defer tui_items.freeItems(allocator, items);
                if (items.len == 0) return;
                const text = items[self.conversation_selected].reuse orelse items[self.conversation_selected].body;
                try self.replaceInput(allocator, text, text.len);
            },
            .activity => {
                const items = try buildActivityItems(self, allocator);
                defer tui_items.freeItems(allocator, items);
                if (items.len == 0) return;
                const text = items[self.activity_selected].reuse orelse items[self.activity_selected].body;
                try self.replaceInput(allocator, text, text.len);
            },
            .input => return,
        }
        self.focus = .input;
        self.history.resetBrowse(allocator);
    }

    fn pageMoveUp(self: *@This(), size: ziggy.Size) void {
        const conversation_step = @max(tui_layout.conversationVisibleHeightForSize(size) / 2, 1);
        const activity_step = @max(tui_layout.activityVisibleHeightForSize(size) / 2, 1);
        switch (self.focus) {
            .conversation => self.conversation_body_scroll -|= conversation_step,
            .activity => self.activity_selected -|= activity_step,
            .input => {},
        }
        self.syncScrollBounds(size);
    }

    fn pageMoveDown(self: *@This(), size: ziggy.Size, conversation_total: usize, activity_total: usize) void {
        const conversation_step = @max(tui_layout.conversationVisibleHeightForSize(size) / 2, 1);
        const activity_step = @max(tui_layout.activityVisibleHeightForSize(size) / 2, 1);
        switch (self.focus) {
            .conversation => {
                _ = conversation_total;
                self.conversation_body_scroll += conversation_step;
            },
            .activity => {
                if (activity_total > 0) {
                    self.activity_selected = @min(self.activity_selected + activity_step, activity_total - 1);
                }
            },
            .input => {},
        }
        self.syncScrollBounds(size);
    }

    pub fn viewNode(self: *@This(), ctx: *ziggy.Context) !*const ziggy.Node {
        self.syncScrollBounds(ctx.size);
        const conversation = try buildConversationPane(self, ctx.allocator, ctx.size);
        const input_rect = tui_layout.inputContentRect(ctx.size);
        self.input_viewport = ziggy.TextArea.followCursor(&self.editor, "> ", .{
            .offset_line = self.input_viewport.offset_line,
            .offset_column = self.input_viewport.offset_column,
            .width = input_rect.width,
            .height = input_rect.height,
            .scroll_margin = 1,
        });
        const input = try ziggy.TextArea.buildEditorWithViewport(
            ctx.allocator,
            &self.editor,
            self.input_viewport,
            .{
                .prompt = "> ",
                .focused = self.focus == .input,
                .placeholder = "Type a prompt or /command",
                .style = if (self.focus == .input) theme.input_active else theme.input,
                .focus = .{
                    .active = self.focus == .input,
                    .focus_id = "input",
                },
            },
        );
        const input_with_completion = if (self.completion.visible and self.focus == .input and !self.palette_open)
            blk: {
                const menu = (try ziggy.CompletionMenu.build(ctx.allocator, &self.completion, .{
                    .title = "Completions",
                    .style = theme.pane,
                    .selected_style = theme.selected,
                    .box_style = theme.pane_active,
                    .border_style = .round,
                    .focus = .{ .active = true, .focus_id = "completion" },
                })).?;
                break :blk try ziggy.VStack.build(ctx.allocator, &.{ input, menu }, 1);
            }
        else
            input;

        const status_left = try std.fmt.allocPrint(ctx.allocator, "{s}", .{
            if (self.turn_running)
                "Choreographing..."
            else if (self.last_error != null)
                self.status_text
            else
                "Ready",
        });
        const status_style = if (self.last_error != null)
            theme.status_error
        else if (self.turn_running)
            theme.status_running
        else
            theme.status_idle;
        const provider_badge = try ziggy.Badge.build(ctx.allocator, self.app.config.provider, .{
            .style = .{ .fg = .{ .ansi = 4 }, .bold = true },
        });
        const model_badge = try ziggy.Badge.build(ctx.allocator, self.app.config.model, .{
            .style = .{ .fg = .{ .ansi = 2 }, .bold = true },
        });
        const key_hints = try ziggy.KeyHints.build(ctx.allocator, &.{
            "esc to interrupt",
        }, .{
            .style = status_style,
            .separator = "  ",
            .alignment = .right,
        });
        const left_status = try ziggy.Text.buildWithOptions(ctx.allocator, status_left, .{
            .style = status_style,
            .wrap = .truncate_end,
            .alignment = .left,
        });
        const spinner_or_idle = if (self.turn_running)
            try ziggy.Spinner.build(ctx.allocator, .{
                .now_ms = ctx.now_ms,
                .interval_ms = 80,
                .style = theme.status_running,
            })
        else
            try ziggy.Text.buildWithOptions(ctx.allocator, " ", .{
                .style = status_style,
                .wrap = .none,
            });
        const status_main = try ziggy.HStack.buildWithWeights(ctx.allocator, &.{ spinner_or_idle, provider_badge, model_badge, left_status, key_hints }, 2, &.{ 1, 2, 3, 8, 4 });
        const status = if (self.notification) |text|
            blk: {
                const notice = try ziggy.NoticeBar.build(ctx.allocator, .{
                    .level = self.notification_level,
                    .label = switch (self.notification_level) {
                        .info => "INFO",
                        .success => "OK",
                        .warning => "WARN",
                        .err => "ERR",
                    },
                    .message = text,
                    .text_style = theme.pane,
                });
                break :blk try ziggy.VStack.build(ctx.allocator, &.{ notice, status_main }, 0);
            }
        else
            status_main;

        const bottom = try ziggy.Split.build(
            ctx.allocator,
            input_with_completion,
            status,
            tui_layout.bottomInputRatio(ctx.size),
            .vertical,
        );
        const base = try ziggy.Split.build(
            ctx.allocator,
            conversation,
            bottom,
            tui_layout.topAreaRatio(ctx.size),
            .vertical,
        );

        const with_palette = if (self.palette_open and self.completion.visible)
            blk: {
                const palette = (try ziggy.Palette.build(ctx.allocator, &self.completion, .{
                    .title = "Commands",
                    .hint = "Enter/Tab apply  Esc close  Ctrl+N/P move",
                    .style = theme.pane,
                    .selected_style = theme.selected,
                    .box_style = theme.pane_active,
                    .border_style = theme.modal_border_style,
                    .focus = .{ .active = true, .focus_id = "palette" },
                })).?;
                const overlay = try ziggy.Box.buildWithOptions(ctx.allocator, null, palette, .{
                    .style = theme.pane_active,
                    .border_style = theme.modal_border_style,
                    .margin_top = @intCast(@max(ctx.size.height / 6, 1)),
                    .margin_bottom = @intCast(@max(ctx.size.height / 4, 1)),
                    .margin_left = @intCast(@max(ctx.size.width / 5, 2)),
                    .margin_right = @intCast(@max(ctx.size.width / 5, 2)),
                    .padding_top = 1,
                    .padding_bottom = 1,
                    .padding_left = 1,
                    .padding_right = 1,
                });
                break :blk try ziggy.allocNode(ctx.allocator, .{
                    .overlay = .{ .base = base, .overlay = overlay },
                });
            }
        else
            base;

        if (self.modal.isOpen()) {
            return try ziggy.Chrome.buildOverlayModalThemed(ctx.allocator, with_palette, self.modal.title.?, self.modal.body.?, theme);
        }

        return with_palette;
    }
};

fn submitCurrentInput(program: *TuiProgram, app: *App, stdin: *std.Io.Reader) !bool {
    const submitted = try program.model.submittedInput(app.allocator);
    defer app.allocator.free(submitted);
    return try executeSubmittedInput(program, app, stdin, submitted);
}

fn handleInputControlKey(program: *TuiProgram, app: *App, key: ziggy.Key) !void {
    try tui_input.handleInputControlKey(program, app, key);
}

fn handlePaneChar(program: *TuiProgram, app: *App, stdin: *std.Io.Reader, byte: u8) !bool {
    return try tui_input.handlePaneChar(program, app, stdin, byte, submitCurrentInput, conversationItemCount, activityItemCount, paneFocusString);
}

pub fn runInteractive(app: *App) !void {
    _ = std.fs.File.stdout().getOrEnableAnsiEscapeSupport();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    const stdin = &stdin_reader.interface;

    const persisted_history = try prompt_history_store.load(app.allocator, app.config.paths, app.cwd);
    defer {
        for (persisted_history) |item| app.allocator.free(item);
        app.allocator.free(persisted_history);
    }

    var model = TuiModel{
        .app = app,
        .editor = try ziggy.Editor.init(app.allocator, ""),
        .sidebar_output = try app.allocator.dupe(u8, "Type prompts here. Enter submits. Enter on panes inspects. Ctrl+D quits."),
        .status_text = try app.allocator.dupe(u8, "idle"),
    };
    try model.history.replaceAll(app.allocator, persisted_history);

    var program = try ziggy.Program(TuiModel, Msg).init(
        app.allocator,
        ziggy.Tty.withCapabilities(stdin, stdout, tui_layout.detectTerminalSize(), .{
            .bracketed_paste = true,
            .mouse = true,
            .synchronized_output = true,
            .alternate_screen = true,
        }),
        model,
        .{
            .now_ms = @intCast(@max(std.time.milliTimestamp(), 0)),
            .title = "cirebronx",
            .tab_status = .idle,
            .tick_interval_ms = 80,
        },
    );
    defer {
        program.model.deinit(app.allocator);
        program.tty.leaveRawMode();
        program.deinit();
    }

    try program.start();

    while (true) {
        const event = (try tui_input.readEventAlloc(app.allocator, stdin)) orelse break;
        defer if (event == .paste) app.allocator.free(event.paste);
        switch (event) {
            .key => |key| switch (key) {
                .ctrl_c, .ctrl_d => break,
                .ctrl_a, .ctrl_e, .ctrl_j, .ctrl_k, .ctrl_r, .ctrl_u, .ctrl_w => {
                    if (!program.model.modal.isOpen() and program.model.focus == .input) {
                        try handleInputControlKey(&program, app, key);
                    }
                },
                .ctrl_n => {
                    if (!program.model.modal.isOpen() and program.model.focus == .input and program.model.completion.visible) {
                        program.model.completion.selectNext();
                        try program.redraw();
                    }
                },
                .ctrl_p => {
                    if (!program.model.modal.isOpen() and program.model.focus == .input and program.model.completion.visible) {
                        program.model.completion.selectPrevious();
                        try program.redraw();
                    }
                },
                .ctrl_space => {
                    if (!program.model.modal.isOpen() and program.model.focus == .input) {
                        try program.model.openCompletion(app.allocator);
                        try program.redraw();
                    }
                },
                .escape => {
                    if (program.model.modal.isOpen()) {
                        program.model.closeModal(app.allocator);
                        try program.model.logAction(app.allocator, "closed detail modal");
                        try program.redraw();
                    } else if (program.model.palette_open) {
                        program.model.closeCommandPalette(app.allocator);
                        try program.redraw();
                    } else if (program.model.completion.visible) {
                        program.model.completion.clear(app.allocator);
                        try program.redraw();
                    }
                },
                .tab => {
                    if (!program.model.modal.isOpen() and program.model.focus == .input and program.model.completion.visible) {
                        _ = try program.model.acceptCompletion(app.allocator);
                        try program.redraw();
                        continue;
                    }
                    if (!program.model.modal.isOpen()) {
                        program.model.cycleFocus();
                        const action = try std.fmt.allocPrint(app.allocator, "focus -> {s}", .{
                            paneFocusString(program.model.focus),
                        });
                        defer app.allocator.free(action);
                        try program.model.logAction(app.allocator, action);
                        try program.redraw();
                    }
                },
                .back_tab => {
                    if (!program.model.modal.isOpen() and program.model.focus == .input and program.model.completion.visible) {
                        program.model.completion.selectPrevious();
                        try program.redraw();
                        continue;
                    }
                    if (!program.model.modal.isOpen()) {
                        program.model.cycleFocusReverse();
                        const action = try std.fmt.allocPrint(app.allocator, "focus -> {s}", .{
                            paneFocusString(program.model.focus),
                        });
                        defer app.allocator.free(action);
                        try program.model.logAction(app.allocator, action);
                        try program.redraw();
                    }
                },
                .char => |byte| {
                    if (program.model.modal.isOpen()) continue;

                    if (byte == ':') {
                        try program.model.openCommandPalette(app.allocator, @intCast(@max(std.time.milliTimestamp(), 0)));
                        try program.redraw();
                        continue;
                    }

                    if (program.model.focus == .input) {
                        try program.model.insertChar(app.allocator, byte);
                        try program.redraw();
                        continue;
                    }

                    if (try handlePaneChar(&program, app, stdin, byte)) break;
                },
                .backspace => {
                    if (!program.model.modal.isOpen() and program.model.focus == .input) {
                        try program.model.backspace(app.allocator);
                        try program.redraw();
                    }
                },
                .delete => {
                    if (!program.model.modal.isOpen() and program.model.focus == .input) {
                        try program.model.deleteForward(app.allocator);
                        try program.redraw();
                    }
                },
                .left => {
                    if (!program.model.modal.isOpen() and program.model.focus == .input) {
                        program.model.editor.clearSelection();
                        program.model.moveLeft();
                        try program.redraw();
                    }
                },
                .right => {
                    if (!program.model.modal.isOpen() and program.model.focus == .input) {
                        program.model.editor.clearSelection();
                        program.model.moveRight();
                        try program.redraw();
                    }
                },
                .shift_left => {
                    if (!program.model.modal.isOpen() and program.model.focus == .input) {
                        program.model.selectLeft();
                        try program.redraw();
                    }
                },
                .shift_right => {
                    if (!program.model.modal.isOpen() and program.model.focus == .input) {
                        program.model.selectRight();
                        try program.redraw();
                    }
                },
                .word_left => {
                    if (!program.model.modal.isOpen() and program.model.focus == .input) {
                        program.model.editor.clearSelection();
                        program.model.moveWordLeft();
                        try program.redraw();
                    }
                },
                .word_right => {
                    if (!program.model.modal.isOpen() and program.model.focus == .input) {
                        program.model.editor.clearSelection();
                        program.model.moveWordRight();
                        try program.redraw();
                    }
                },
                .home => {
                    if (program.model.modal.isOpen()) continue;
                    if (program.model.focus == .input) {
                        program.model.moveHome();
                    } else {
                        switch (program.model.focus) {
                            .conversation => {
                                program.model.conversation_selected = 0;
                                program.model.conversation_body_scroll = 0;
                            },
                            .activity => program.model.activity_selected = 0,
                            .input => {},
                        }
                        program.model.syncScrollBounds(program.tty.size);
                    }
                    try program.redraw();
                },
                .end => {
                    if (program.model.modal.isOpen()) continue;
                    if (program.model.focus == .input) {
                        program.model.moveEnd();
                    } else {
                        switch (program.model.focus) {
                            .conversation => {
                                const total = try conversationItemCount(&program.model, app.allocator);
                                if (total > 0) program.model.conversation_selected = total - 1;
                                program.model.conversation_body_scroll = 0;
                            },
                            .activity => {
                                const total = activityItemCount(&program.model);
                                if (total > 0) program.model.activity_selected = total - 1;
                            },
                            .input => {},
                        }
                        program.model.syncScrollBounds(program.tty.size);
                    }
                    try program.redraw();
                },
                .page_up => {
                    if (program.model.modal.isOpen()) continue;
                    if (program.model.focus != .input) {
                        program.model.pageMoveUp(program.tty.size);
                        try program.redraw();
                    }
                },
                .page_down => {
                    if (program.model.modal.isOpen()) continue;
                    if (program.model.focus != .input) {
                        const conversation_total = try conversationItemCount(&program.model, app.allocator);
                        const activity_total = activityItemCount(&program.model);
                        program.model.pageMoveDown(program.tty.size, conversation_total, activity_total);
                        try program.redraw();
                    }
                },
                .up => {
                    if (program.model.modal.isOpen()) continue;
                    if (program.model.focus == .input) {
                        if (program.model.completion.visible) {
                            program.model.completion.selectPrevious();
                        } else {
                            try program.model.browseHistoryUp(app.allocator);
                        }
                    } else {
                        program.model.moveSelectionUp(program.tty.size);
                    }
                    try program.redraw();
                },
                .down => {
                    if (program.model.modal.isOpen()) continue;
                    if (program.model.focus == .input) {
                        if (program.model.completion.visible) {
                            program.model.completion.selectNext();
                        } else {
                            try program.model.browseHistoryDown(app.allocator);
                        }
                    } else {
                        const conversation_total = try conversationItemCount(&program.model, app.allocator);
                        const activity_total = activityItemCount(&program.model);
                        program.model.moveSelectionDown(program.tty.size, conversation_total, activity_total);
                    }
                    try program.redraw();
                },
                .enter => {
                    if (program.model.modal.isOpen()) {
                        program.model.closeModal(app.allocator);
                        try program.model.logAction(app.allocator, "closed detail modal");
                        try program.redraw();
                        continue;
                    }

                    if (program.model.focus != .input) {
                        try program.model.openSelectionModal(app.allocator);
                        if (program.model.modal.isOpen()) {
                            try program.model.logAction(app.allocator, "opened detail modal");
                        }
                        try program.redraw();
                        continue;
                    }

                    if (program.model.completion.visible) {
                        _ = try program.model.acceptCompletion(app.allocator);
                        try program.redraw();
                        continue;
                    }

                    if (try submitCurrentInput(&program, app, stdin)) break;
                },
                else => {},
            },
            .mouse => |mouse| {
                if (!program.model.modal.isOpen()) {
                    try handleMouseEvent(&program, app, mouse);
                }
            },
            .paste => |text| {
                if (!program.model.modal.isOpen() and program.model.focus == .input) {
                    try program.model.insertText(app.allocator, text);
                    try program.model.logAction(app.allocator, "pasted input");
                    try program.redraw();
                }
            },
            else => {},
        }
    }

    try stdout.print("\x1b[{d};1H\x1b[K\x1b[0m\n", .{program.tty.size.height + 1});
    try stdout.flush();
}

fn handleMouseEvent(program: *TuiProgram, app: *App, mouse: ziggy.Mouse) !void {
    const size = program.tty.size;
    const conversation_rect = tui_layout.conversationRect(size);
    const conversation_content_rect = tui_layout.conversationContentRect(size);
    const conversation_scrollbar_rect = tui_layout.conversationScrollbarRect(size);
    const activity_rect = tui_layout.activityRect(size);
    const activity_content_rect = tui_layout.activityContentRect(size);
    const activity_scrollbar_rect = tui_layout.activityScrollbarRect(size);
    const input_rect = tui_layout.inputRect(size);
    const input_content_rect = tui_layout.inputContentRect(size);
    const conversation_page = @max(tui_layout.conversationBodyVisibleHeight(size) / 2, 1);
    const activity_page = @max(tui_layout.activityVisibleHeightForSize(size) / 2, 1);

    if (mouse.button == .wheel_up and mouse.pressed) {
        if (conversation_rect.contains(mouse.x, mouse.y)) {
            program.model.focus = .conversation;
            program.model.conversation_body_scroll -|= 1;
            try program.redraw();
        } else if (activity_rect.contains(mouse.x, mouse.y)) {
            program.model.focus = .activity;
            program.model.activity_scroll -|= 1;
            try program.redraw();
        }
        return;
    }

    if (mouse.button == .wheel_down and mouse.pressed) {
        if (conversation_rect.contains(mouse.x, mouse.y)) {
            program.model.focus = .conversation;
            program.model.conversation_body_scroll += 1;
            program.model.syncScrollBounds(size);
            try program.redraw();
        } else if (activity_rect.contains(mouse.x, mouse.y)) {
            program.model.focus = .activity;
            program.model.activity_scroll += 1;
            program.model.syncScrollBounds(size);
            try program.redraw();
        }
        return;
    }

    if (mouse.button != .left or !mouse.pressed) return;

    if (ziggy.Scrollbar.hitTestVerticalTrack(
        conversation_scrollbar_rect,
        program.model.conversation_body_scroll,
        tui_layout.conversationBodyVisibleHeight(size),
        try conversationBodyLineCount(&program.model, app.allocator, size),
        mouse.x,
        mouse.y,
    )) |hit| {
        program.model.focus = .conversation;
        switch (hit) {
            .page_up => program.model.conversation_body_scroll -|= conversation_page,
            .page_down => program.model.conversation_body_scroll += conversation_page,
        }
        program.model.syncScrollBounds(size);
        try program.redraw();
        return;
    }

    if (ziggy.Scrollbar.hitTestVerticalTrack(
        activity_scrollbar_rect,
        program.model.activity_scroll,
        tui_layout.activityVisibleHeightForSize(size),
        activityItemCount(&program.model),
        mouse.x,
        mouse.y,
    )) |hit| {
        program.model.focus = .activity;
        switch (hit) {
            .page_up => program.model.activity_scroll -|= activity_page,
            .page_down => program.model.activity_scroll += activity_page,
        }
        program.model.syncScrollBounds(size);
        try program.redraw();
        return;
    }

    if (conversation_content_rect.contains(mouse.x, mouse.y)) {
        program.model.focus = .conversation;
        const document = try tui_items.buildConversationDocument(
            app.allocator,
            program.model.app,
            program.model.conversation_selected,
            program.model.turn_running,
            program.model.pending_prompt,
            program.model.current_tool,
            program.model.last_error,
            program.model.live_assistant,
            program.model.status_text,
            program.model.actions.items.items,
            tui_layout.conversationBodyWidth(size),
        );
        defer {
            var owned = document;
            owned.deinit(app.allocator);
        }
        const clicked_index = ziggy.Transcript.hitTestEntry(
            conversation_content_rect,
            document.entry_starts,
            program.model.conversation_body_scroll,
            mouse.x,
            mouse.y,
        ) orelse return;
        program.model.conversation_selected = clicked_index;
        program.model.syncScrollBounds(size);
        try program.redraw();
        return;
    }

    if (activity_content_rect.localPoint(mouse.x, mouse.y)) |_| {
        program.model.focus = .activity;
        const items = try buildActivityItems(&program.model, app.allocator);
        defer tui_items.freeItems(app.allocator, items);
        if (ziggy.Pane.hitTestSelectableList(activity_content_rect, items.len, program.model.activity_scroll, mouse.x, mouse.y)) |absolute| {
            program.model.activity_selected = absolute;
        }
        try program.redraw();
        return;
    }

    if (input_rect.contains(mouse.x, mouse.y)) {
        program.model.focus = .input;
        if (ziggy.TextArea.cursorFromRectPoint(input_content_rect, &program.model.editor, "> ", mouse.x, mouse.y, program.model.input_viewport)) |cursor| {
            program.model.editor.setCursor(cursor);
        } else {
            program.model.editor.moveEnd();
        }
        try program.redraw();
    }
}

const ExecuteResult = struct {
    output: []u8,
    exit_requested: bool,
};

const ProviderObserverContext = struct {
    program: *TuiProgram,
    app: *App,
};

const ApprovalContext = struct {
    program: *TuiProgram,
    app: *App,
    stdin: *std.Io.Reader,
};

fn executeSubmittedInput(program: *TuiProgram, app: *App, stdin: *std.Io.Reader, line: []const u8) !bool {
    if (line.len == 0) {
        try program.model.setSidebarOutput(app.allocator, "Empty input ignored.");
        try program.model.logAction(app.allocator, "empty input ignored");
        try program.model.clearInput(app.allocator);
        try program.redraw();
        return false;
    }

    const started = try std.fmt.allocPrint(app.allocator, "run: {s}", .{
        ziggy.FormatText.previewText(line, 56),
    });
    defer app.allocator.free(started);
    try program.model.logAction(app.allocator, started);
    program.model.turn_running = true;
    try program.model.setPendingPrompt(app.allocator, line);
    program.model.clearCurrentTool(app.allocator);
    program.model.clearLastError(app.allocator);
    program.model.clearLiveAssistant(app.allocator);
    try program.model.setStatus(app.allocator, "running turn");
    try program.redraw();
    try program.model.history.push(app.allocator, line);
    try prompt_history_store.save(app.allocator, app.config.paths, app.cwd, program.model.history.items.items);

    const result = try executeLineInTui(program, app, stdin, line);
    defer app.allocator.free(result.output);

    program.model.turn_running = false;
    program.model.clearPendingPrompt(app.allocator);
    program.model.clearCurrentTool(app.allocator);
    program.model.clearLiveAssistant(app.allocator);

    const finished = try std.fmt.allocPrint(app.allocator, "done: {s}", .{
        ziggy.FormatText.previewText(result.output, 56),
    });
    defer app.allocator.free(finished);
    try program.model.logAction(app.allocator, finished);
    program.model.activity_selected = activityItemCount(&program.model) -| 1;
    const conversation_total = try conversationItemCount(&program.model, app.allocator);
    program.model.followConversation(program.tty.size, conversation_total);
    program.model.syncScrollBounds(program.tty.size);
    try program.model.clearInput(app.allocator);
    try program.redraw();
    return result.exit_requested;
}

fn executeLineInTui(program: *TuiProgram, app: *App, stdin: *std.Io.Reader, line: []const u8) !ExecuteResult {
    var output: std.Io.Writer.Allocating = .init(app.allocator);
    errdefer output.deinit();

    const handled = commands.handle(app, line, .{
        .stdout = &output.writer,
        .stdin = stdin,
        .interactive = true,
    }) catch |err| switch (err) {
        commands.CommandError.ExitRequested => {
            const text = try app.allocator.dupe(u8, "Exit requested.");
            output.deinit();
            return .{ .output = text, .exit_requested = true };
        },
        else => return err,
    };

    if (!handled) {
        try runPromptLineTui(program, app, line, stdin);
        const result = try app.allocator.dupe(u8, std.mem.trimRight(u8, program.model.sidebar_output, "\r\n"));
        output.deinit();
        return .{ .output = result, .exit_requested = false };
    }

    const trimmed = std.mem.trimRight(u8, output.written(), "\r\n");
    const result = if (trimmed.len == 0)
        try app.allocator.dupe(u8, "OK")
    else
        try app.allocator.dupe(u8, trimmed);
    try program.model.setSidebarOutput(app.allocator, result);
    output.deinit();
    return .{ .output = result, .exit_requested = false };
}

fn runPromptLineTui(program: *TuiProgram, app: *App, prompt: []const u8, stdin: *std.Io.Reader) !void {
    try app.appendMessage(.{
        .role = .user,
        .content = prompt,
    });

    var io_capture: std.Io.Writer.Allocating = .init(app.allocator);
    defer io_capture.deinit();

    var approval_context = ApprovalContext{
        .program = program,
        .app = app,
        .stdin = stdin,
    };
    const ctx = tools.ExecutionContext{
        .app = app,
        .io = permissions.PromptIo{
            .stdout = &io_capture.writer,
            .stdin = stdin,
            .interactive = true,
            .approval = .{
                .context = &approval_context,
                .callback = tuiApprovalPrompt,
            },
        },
    };
    const visible_tools = tools.toolsForExposure(app);
    var observer_context = ProviderObserverContext{
        .program = program,
        .app = app,
    };
    const observer = provider.TurnObserver{
        .context = &observer_context,
        .on_status = onProviderStatus,
        .on_text_chunk = onProviderTextChunk,
        .on_tool_calls = onProviderToolCalls,
    };

    var step: usize = 0;
    while (step < 8) : (step += 1) {
        try program.model.setStatus(app.allocator, if (step == 0) "requesting model" else "continuing tool loop");
        try program.redraw();

        var turn = provider.sendTurnObserved(app, visible_tools, observer) catch |err| {
            const text = try std.fmt.allocPrint(app.allocator, "error: {s}", .{@errorName(err)});
            defer app.allocator.free(text);
            try program.model.setLastError(app.allocator, text);
            try program.model.appendSidebarLine(app.allocator, text);
            try program.model.logAction(app.allocator, text);
            return;
        };
        defer turn.deinit(app.allocator);

        switch (turn) {
            .assistant_text => |text| {
                program.model.clearCurrentTool(app.allocator);
                try program.model.appendSidebarLine(app.allocator, text);
                try program.model.setStatus(app.allocator, "assistant replied");
                try app.appendAssistantText(text);
                try program.redraw();
                break;
            },
            .tool_calls => |calls| {
                try app.appendAssistantToolCalls(calls);
                for (calls) |call| {
                    try program.model.setCurrentTool(app.allocator, call.name);
                    const tool_line = try std.fmt.allocPrint(app.allocator, "[tool] {s}", .{call.name});
                    defer app.allocator.free(tool_line);
                    try program.model.appendSidebarLine(app.allocator, tool_line);
                    const tool_action = try std.fmt.allocPrint(app.allocator, "tool: {s}", .{call.name});
                    defer app.allocator.free(tool_action);
                    try program.model.logAction(app.allocator, tool_action);
                    const tool_status = try std.fmt.allocPrint(app.allocator, "tool running: {s}", .{call.name});
                    defer app.allocator.free(tool_status);
                    try program.model.setStatus(app.allocator, tool_status);
                    try program.redraw();

                    const result = tools.executeTool(app.allocator, ctx, call) catch |err| blk: {
                        const err_text = try std.fmt.allocPrint(app.allocator, "tool error: {s}", .{@errorName(err)});
                        try program.model.setLastError(app.allocator, err_text);
                        try program.model.appendSidebarLine(app.allocator, err_text);
                        break :blk err_text;
                    };
                    defer app.allocator.free(result);
                    try app.appendToolResult(call.id, call.name, result);
                    const result_line = try std.fmt.allocPrint(app.allocator, "tool result: {s}", .{ziggy.FormatText.previewText(result, 56)});
                    defer app.allocator.free(result_line);
                    try program.model.appendSidebarLine(app.allocator, result_line);
                    try program.redraw();
                }
                program.model.clearCurrentTool(app.allocator);
            },
        }
    }

    if (step >= 8) {
        try program.model.setLastError(app.allocator, "error: MaxStepsReached");
        try program.model.appendSidebarLine(app.allocator, "error: MaxStepsReached");
    }

    try session_store.saveSession(
        app.allocator,
        app.config.paths,
        app.session_id,
        app.cwd,
        app.config.model,
        app.session.items,
    );
}

fn onProviderStatus(raw: ?*anyopaque, text: []const u8) !void {
    const context: *ProviderObserverContext = @ptrCast(@alignCast(raw.?));
    try context.program.model.setStatus(context.app.allocator, text);
    try context.program.redraw();
}

fn onProviderTextChunk(raw: ?*anyopaque, text: []const u8) !void {
    const context: *ProviderObserverContext = @ptrCast(@alignCast(raw.?));
    try context.program.model.appendLiveAssistant(context.app.allocator, text);
    try context.program.model.setStatus(context.app.allocator, "streaming assistant");
    try context.program.redraw();
}

fn onProviderToolCalls(raw: ?*anyopaque, calls: []const message_mod.ToolCall) !void {
    const context: *ProviderObserverContext = @ptrCast(@alignCast(raw.?));
    if (calls.len > 0) {
        try context.program.model.setCurrentTool(context.app.allocator, calls[0].name);
    }
    try context.program.model.setStatus(context.app.allocator, "received tool calls");
    try context.program.redraw();
}

fn tuiApprovalPrompt(raw: ?*anyopaque, permission_set: *permissions.PermissionSet, class: permissions.PermissionClass, summary: []const u8) !bool {
    const context: *ApprovalContext = @ptrCast(@alignCast(raw.?));
    const body = try ziggy.FormatText.buildSectionsBody(context.app.allocator, &.{
        .{ .title = "permission class", .body = @tagName(class) },
        .{ .title = "current mode", .body = switch (class) {
            .read => permissions.modeString(permission_set.read),
            .write => permissions.modeString(permission_set.write),
            .shell => permissions.modeString(permission_set.shell),
        } },
        .{ .title = "request summary", .body = summary },
        .{ .title = "workspace", .body = context.app.cwd },
        .{ .title = "actions", .body = "y allow once\na allow always\nn deny once\nd deny always\nEsc cancel" },
    });
    defer context.app.allocator.free(body);
    try context.program.model.openCustomModal(context.app.allocator, "Approval", body);
    try context.program.model.logAction(context.app.allocator, "opened permission approval");
    try context.program.redraw();

    while (true) {
        const event = (try tui_input.readEventAlloc(context.app.allocator, context.stdin)) orelse return false;
        defer if (event == .paste) context.app.allocator.free(event.paste);
        switch (event) {
            .key => |key| switch (key) {
                .escape, .ctrl_c, .ctrl_d => {
                    context.program.model.closeModal(context.app.allocator);
                    try context.program.model.logAction(context.app.allocator, "permission denied");
                    try context.program.redraw();
                    return false;
                },
                .char => |byte| switch (byte) {
                    'y', 'Y' => {
                        context.program.model.closeModal(context.app.allocator);
                        try context.program.model.logAction(context.app.allocator, "permission allowed once");
                        try context.program.redraw();
                        return true;
                    },
                    'a', 'A' => {
                        permission_set.setForClass(class, .allow);
                        context.program.model.closeModal(context.app.allocator);
                        try context.program.model.logAction(context.app.allocator, "permission allowed always");
                        try context.program.redraw();
                        return true;
                    },
                    'n', 'N' => {
                        context.program.model.closeModal(context.app.allocator);
                        try context.program.model.logAction(context.app.allocator, "permission denied");
                        try context.program.redraw();
                        return false;
                    },
                    'd', 'D' => {
                        permission_set.setForClass(class, .deny);
                        context.program.model.closeModal(context.app.allocator);
                        try context.program.model.logAction(context.app.allocator, "permission denied always");
                        try context.program.redraw();
                        return false;
                    },
                    else => {},
                },
                else => {},
            },
            .paste => {},
            else => {},
        }
    }
}

fn buildConversationPane(model: *const TuiModel, allocator: std.mem.Allocator, size: ziggy.Size) !*const ziggy.Node {
    const items = try buildConversationItems(model, allocator);
    defer tui_items.freeItems(allocator, items);
    const title = try allocator.dupe(u8, "Conversation");
    const document = try tui_items.buildConversationDocument(
        allocator,
        model.app,
        if (items.len == 0) 0 else @min(model.conversation_selected, items.len - 1),
        model.turn_running,
        model.pending_prompt,
        model.current_tool,
        model.last_error,
        model.live_assistant,
        model.status_text,
        model.actions.items.items,
        tui_layout.conversationBodyWidth(size),
    );
    defer {
        var owned = document;
        owned.deinit(allocator);
    }

    const follow_end = model.focus != .conversation;
    const resolved_scroll = if (follow_end)
        ziggy.RichDocument.followOffset(document.lines.len, tui_layout.conversationBodyVisibleHeight(size))
    else
        model.conversation_body_scroll;
    const doc = try ziggy.StaticLog.build(allocator, document.lines, .{
        .offset = resolved_scroll,
        .viewport_height = tui_layout.conversationBodyVisibleHeight(size),
        .follow_end = follow_end,
        .style = theme.pane,
    });
    const panel = try ziggy.Box.buildWithOptions(allocator, title, doc, .{
        .style = if (model.focus == .conversation) theme.pane_active else theme.pane,
        .border_style = theme.border_style,
        .title_align = .center,
    });
    const scrollbar = if (document.lines.len > tui_layout.conversationBodyVisibleHeight(size))
        try ziggy.Scrollbar.build(allocator, .{
            .offset = resolved_scroll,
            .viewport = tui_layout.conversationBodyVisibleHeight(size),
            .total = document.lines.len,
            .style = theme.pane,
            .thumb_style = theme.selected,
        })
    else
        try ziggy.Text.buildWithOptions(allocator, "", .{
            .style = theme.pane,
            .wrap = .none,
        });
    return try ziggy.HStack.buildWithWeights(allocator, &.{ panel, scrollbar }, 0, &.{ 100, 1 });
}

fn buildSidebarPane(model: *const TuiModel, allocator: std.mem.Allocator, size: ziggy.Size) !*const ziggy.Node {
    const items = try buildActivityItems(model, allocator);
    defer tui_items.freeItems(allocator, items);
    const labels = try tui_items.extractLabels(allocator, items);
    const title = try std.fmt.allocPrint(allocator, "Activity [{s}] {d}/{d}", .{
        if (model.turn_running)
            "live"
        else if (model.focus == .activity)
            "active"
        else
            "view",
        @min(items.len, model.activity_selected + 1),
        items.len,
    });
    const panel = try ziggy.Pane.buildSelectableList(allocator, title, labels, .{
        .selected = model.activity_selected,
        .offset = model.activity_scroll,
        .focused = model.focus == .activity,
        .style = theme.pane,
        .selected_style = theme.selected_alt,
        .box_style = theme.pane_active,
        .border_style = theme.border_style,
        .title_align = .center,
        .focus = .{
            .active = model.focus == .activity,
            .focus_id = "activity",
        },
    });
    const scrollbar = if (labels.len > tui_layout.activityVisibleHeightForSize(size))
        try ziggy.Scrollbar.build(allocator, .{
            .offset = model.activity_scroll,
            .viewport = tui_layout.activityVisibleHeightForSize(size),
            .total = labels.len,
            .style = theme.pane,
            .thumb_style = theme.selected_alt,
        })
    else
        try ziggy.Text.buildWithOptions(allocator, "", .{
            .style = theme.pane,
            .wrap = .none,
        });
    const activity_main = try ziggy.HStack.buildWithWeights(allocator, &.{ panel, scrollbar }, 1, &.{ 100, 1 });
    if (model.turn_running or model.current_tool != null or model.last_error != null) {
        const tool_status = try ziggy.TaskStatusRow.build(allocator, .{
            .title = if (model.current_tool) |tool| tool else "assistant",
            .mode = if (model.last_error) |err|
                .{ .idle = err }
            else if (model.turn_running and model.current_tool != null)
                .{ .running = model.status_text }
            else
                .{ .idle = model.status_text },
            .now_ms = @intCast(@max(std.time.milliTimestamp(), 0)),
            .title_style = theme.selected_alt,
            .meta_style = theme.pane,
        });
        return try ziggy.VStack.build(allocator, &.{ tool_status, activity_main }, 1);
    }
    return activity_main;
}

fn paneFocusString(focus: PaneFocus) []const u8 {
    return switch (focus) {
        .conversation => "conversation",
        .activity => "activity",
        .input => "input",
    };
}

fn paneFocusId(focus: PaneFocus) ?[]const u8 {
    return paneFocusString(focus);
}

fn paneFocusFromTarget(index: usize) PaneFocus {
    return switch (index) {
        0 => .conversation,
        else => .input,
    };
}

fn conversationItemCount(model: *const TuiModel, allocator: std.mem.Allocator) !usize {
    const items = try buildConversationItems(model, allocator);
    defer tui_items.freeItems(allocator, items);
    return items.len;
}

fn conversationBodyLineCount(model: *const TuiModel, allocator: std.mem.Allocator, size: ziggy.Size) !usize {
    const document = try tui_items.buildConversationDocument(
        allocator,
        model.app,
        model.conversation_selected,
        model.turn_running,
        model.pending_prompt,
        model.current_tool,
        model.last_error,
        model.live_assistant,
        model.status_text,
        model.actions.items.items,
        tui_layout.conversationBodyWidth(size),
    );
    defer {
        var owned = document;
        owned.deinit(allocator);
    }
    return document.lines.len;
}

fn conversationSelectedLine(model: *const TuiModel, allocator: std.mem.Allocator, size: ziggy.Size) !usize {
    const document = try tui_items.buildConversationDocument(
        allocator,
        model.app,
        model.conversation_selected,
        model.turn_running,
        model.pending_prompt,
        model.current_tool,
        model.last_error,
        model.live_assistant,
        model.status_text,
        model.actions.items.items,
        tui_layout.conversationBodyWidth(size),
    );
    defer {
        var owned = document;
        owned.deinit(allocator);
    }
    return document.selected_line;
}

fn buildConversationItems(model: *const TuiModel, allocator: std.mem.Allocator) ![]Item {
    return try tui_items.buildConversationItems(
        allocator,
        model.app,
        model.turn_running,
        model.pending_prompt,
        model.current_tool,
        model.last_error,
        model.live_assistant,
        model.status_text,
        model.actions.items.items,
    );
}

fn buildActivityItems(model: *const TuiModel, allocator: std.mem.Allocator) ![]Item {
    return try tui_items.buildActivityItems(
        allocator,
        model.app,
        model.sidebar_output,
        model.turn_running,
        model.pending_prompt,
        model.current_tool,
        model.last_error,
        model.live_assistant,
        model.status_text,
        model.actions.items.items,
        model.history.items.items,
    );
}

fn activityItemCount(model: *const TuiModel) usize {
    var output_count = tui_layout.countLines(model.sidebar_output);
    if (output_count > 20) output_count = 20;
    var total: usize = 6 + model.actions.items.items.len + @min(model.history.items.items.len, 4) + output_count;
    if (model.turn_running and model.pending_prompt != null) total += 1;
    if (model.current_tool != null) total += 1;
    if (model.last_error != null) total += 1;
    if (model.live_assistant != null and model.live_assistant.?.len > 0) total += 1;
    return total;
}

test "buildConversationItems groups by message" {
    var app = try App.init(std.testing.allocator);
    defer app.deinit();

    try app.appendMessage(.{ .role = .user, .content = "hello" });
    try app.appendAssistantText("world");

    var model = TuiModel{
        .app = &app,
        .editor = try ziggy.Editor.init(std.testing.allocator, ""),
        .sidebar_output = try std.testing.allocator.dupe(u8, ""),
        .status_text = try std.testing.allocator.dupe(u8, "idle"),
    };
    defer model.deinit(std.testing.allocator);

    const items = try buildConversationItems(&model, std.testing.allocator);
    defer tui_items.freeItems(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expect(std.mem.indexOf(u8, items[0].label, "[user]") != null);
    try std.testing.expect(std.mem.indexOf(u8, items[1].body, "world") != null);
}

test "buildConversationItems groups assistant tool call and tool results" {
    var app = try App.init(std.testing.allocator);
    defer app.deinit();

    try app.appendMessage(.{ .role = .user, .content = "list files" });
    const calls = [_]message_mod.ToolCall{
        .{
            .id = try std.testing.allocator.dupe(u8, "call_1"),
            .name = try std.testing.allocator.dupe(u8, "list_files"),
            .arguments = try std.testing.allocator.dupe(u8, "{\"path\":\".\"}"),
        },
    };
    defer {
        for (calls) |call| {
            std.testing.allocator.free(call.id);
            std.testing.allocator.free(call.name);
            std.testing.allocator.free(call.arguments);
        }
    }
    try app.appendAssistantToolCalls(&calls);
    try app.appendToolResult("call_1", "list_files", "a.txt\nb.txt");
    try app.appendAssistantText("done");

    var model = TuiModel{
        .app = &app,
        .editor = try ziggy.Editor.init(std.testing.allocator, ""),
        .sidebar_output = try std.testing.allocator.dupe(u8, ""),
        .status_text = try std.testing.allocator.dupe(u8, "idle"),
    };
    defer model.deinit(std.testing.allocator);

    const items = try buildConversationItems(&model, std.testing.allocator);
    defer tui_items.freeItems(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expect(std.mem.indexOf(u8, items[1].label, "[assistant/tools]") != null);
    try std.testing.expect(std.mem.indexOf(u8, items[1].body, "### Tool results") != null);
    try std.testing.expect(std.mem.indexOf(u8, items[1].body, "list_files") != null);
    try std.testing.expect(std.mem.indexOf(u8, items[1].body, "### Assistant follow-up") != null);
    try std.testing.expectEqualStrings("done", items[1].reuse.?);
}

test "buildConversationItems appends pending turn entry" {
    var app = try App.init(std.testing.allocator);
    defer app.deinit();

    try app.appendMessage(.{ .role = .user, .content = "hello" });

    var model = TuiModel{
        .app = &app,
        .editor = try ziggy.Editor.init(std.testing.allocator, ""),
        .sidebar_output = try std.testing.allocator.dupe(u8, ""),
        .status_text = try std.testing.allocator.dupe(u8, "running turn"),
        .turn_running = true,
        .pending_prompt = try std.testing.allocator.dupe(u8, "check repo"),
    };
    defer model.deinit(std.testing.allocator);

    const items = try buildConversationItems(&model, std.testing.allocator);
    defer tui_items.freeItems(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expect(std.mem.indexOf(u8, items[1].label, "[pending]") != null);
    try std.testing.expect(std.mem.indexOf(u8, items[1].body, "check repo") != null);
}

test "buildConversationItems appends live assistant preview entry" {
    var app = try App.init(std.testing.allocator);
    defer app.deinit();

    try app.appendMessage(.{ .role = .user, .content = "hello" });

    var model = TuiModel{
        .app = &app,
        .editor = try ziggy.Editor.init(std.testing.allocator, ""),
        .sidebar_output = try std.testing.allocator.dupe(u8, ""),
        .status_text = try std.testing.allocator.dupe(u8, "streaming assistant"),
        .turn_running = true,
        .pending_prompt = try std.testing.allocator.dupe(u8, "check repo"),
        .live_assistant = try std.testing.allocator.dupe(u8, "draft answer"),
    };
    defer model.deinit(std.testing.allocator);

    const items = try buildConversationItems(&model, std.testing.allocator);
    defer tui_items.freeItems(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expect(std.mem.indexOf(u8, items[2].label, "[assistant/live]") != null);
    try std.testing.expect(std.mem.indexOf(u8, items[2].body, "draft answer") != null);
}

test "buildActivityItems exposes shortcut reuse text" {
    var app = try App.init(std.testing.allocator);
    defer app.deinit();

    var model = TuiModel{
        .app = &app,
        .editor = try ziggy.Editor.init(std.testing.allocator, ""),
        .sidebar_output = try std.testing.allocator.dupe(u8, ""),
        .status_text = try std.testing.allocator.dupe(u8, "idle"),
    };
    defer model.deinit(std.testing.allocator);

    const items = try buildActivityItems(&model, std.testing.allocator);
    defer tui_items.freeItems(std.testing.allocator, items);

    try std.testing.expectEqualStrings("/help", items[0].reuse.?);
    try std.testing.expectEqualStrings("/config", items[1].reuse.?);
    try std.testing.expectEqualStrings("/sessions", items[2].reuse.?);
    try std.testing.expectEqualStrings("/resume", items[3].reuse.?);
    try std.testing.expectEqualStrings("/", items[4].reuse.?);
}

test "action reuse only exposes run entries" {
    const action = try tui_items.actionReuseText(std.testing.allocator, "run: /help");
    defer if (action) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("/help", action.?);

    const not_action = try tui_items.actionReuseText(std.testing.allocator, "done: OK");
    try std.testing.expect(not_action == null);
}

test "output reuse only exposes slash lines" {
    const slash = try tui_items.outputReuseText(std.testing.allocator, "/help");
    defer if (slash) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("/help", slash.?);

    const tool = try tui_items.outputReuseText(std.testing.allocator, "[tool] read_file");
    try std.testing.expect(tool == null);
}

test "buildActivityItems adds live entry and categorized output" {
    var app = try App.init(std.testing.allocator);
    defer app.deinit();

    var model = TuiModel{
        .app = &app,
        .editor = try ziggy.Editor.init(std.testing.allocator, ""),
        .sidebar_output = try std.testing.allocator.dupe(u8, "[tool] read_file\nerror: MissingApiKey\n/help"),
        .status_text = try std.testing.allocator.dupe(u8, "running turn"),
        .turn_running = true,
        .pending_prompt = try std.testing.allocator.dupe(u8, "check files"),
        .live_assistant = try std.testing.allocator.dupe(u8, "partial reply"),
    };
    defer model.deinit(std.testing.allocator);
    try model.actions.append(std.testing.allocator, "run: /help");

    const items = try buildActivityItems(&model, std.testing.allocator);
    defer tui_items.freeItems(std.testing.allocator, items);

    var saw_live = false;
    var saw_live_output = false;
    var saw_run = false;
    var saw_error = false;
    var saw_help_reuse = false;
    for (items) |item| {
        saw_live = saw_live or std.mem.indexOf(u8, item.label, "Live:") != null;
        saw_live_output = saw_live_output or std.mem.indexOf(u8, item.label, "Live Output:") != null;
        saw_run = saw_run or std.mem.indexOf(u8, item.label, "Run:") != null;
        saw_error = saw_error or std.mem.indexOf(u8, item.label, "Error") != null;
        saw_help_reuse = saw_help_reuse or (item.reuse != null and std.mem.eql(u8, item.reuse.?, "/help"));
    }
    try std.testing.expect(saw_live);
    try std.testing.expect(saw_live_output);
    try std.testing.expect(saw_run);
    try std.testing.expect(saw_error);
    try std.testing.expect(saw_help_reuse);
}

test "activityItemCount matches shortcut and live rows" {
    var app = try App.init(std.testing.allocator);
    defer app.deinit();

    var model = TuiModel{
        .app = &app,
        .editor = try ziggy.Editor.init(std.testing.allocator, ""),
        .sidebar_output = try std.testing.allocator.dupe(u8, "one\ntwo"),
        .status_text = try std.testing.allocator.dupe(u8, "running turn"),
        .turn_running = true,
        .pending_prompt = try std.testing.allocator.dupe(u8, "check files"),
        .current_tool = try std.testing.allocator.dupe(u8, "read_file"),
        .last_error = try std.testing.allocator.dupe(u8, "error: denied"),
        .live_assistant = try std.testing.allocator.dupe(u8, "partial reply"),
    };
    defer model.deinit(std.testing.allocator);
    try model.actions.append(std.testing.allocator, "run: /help");
    try model.history.push(std.testing.allocator, "alpha");

    try std.testing.expectEqual(@as(usize, 14), activityItemCount(&model));
}

test "help body mentions key operator shortcuts" {
    const body = try tui_text.buildHelpBody(std.testing.allocator);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "Tab") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Shift+Tab") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Ctrl+D") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Ctrl+J") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Ctrl+R") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Ctrl+W") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "T / E") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "s          open session modal") != null);
}

test "slash completion opens and applies into input" {
    var app = try App.init(std.testing.allocator);
    defer app.deinit();

    var model = TuiModel{
        .app = &app,
        .editor = try ziggy.Editor.init(std.testing.allocator, ""),
        .sidebar_output = try std.testing.allocator.dupe(u8, ""),
        .status_text = try std.testing.allocator.dupe(u8, "idle"),
        .focus = .input,
    };
    defer model.deinit(std.testing.allocator);

    try model.insertText(std.testing.allocator, "/he");
    try std.testing.expect(model.completion.visible);

    const accepted = try model.acceptCompletion(std.testing.allocator);
    try std.testing.expect(accepted);
    try std.testing.expectEqualStrings("/help", model.editor.value);
}

test "readEvent parses arrow page keys and editor control sequences" {
    var reader = std.Io.Reader.fixed("\x1b[D\x1b[Z\x1b[5~\x1bb\x1b[1;5C\x01\x05\x0a\x0b\x12\x15\x17\x04");

    const left = (try tui_input.readEventAlloc(std.testing.allocator, &reader)).?;
    try std.testing.expect(left == .key);
    try std.testing.expect(left.key == .left);

    const back_tab = (try tui_input.readEventAlloc(std.testing.allocator, &reader)).?;
    try std.testing.expect(back_tab == .key);
    try std.testing.expect(back_tab.key == .back_tab);

    const page_up = (try tui_input.readEventAlloc(std.testing.allocator, &reader)).?;
    try std.testing.expect(page_up == .key);
    try std.testing.expect(page_up.key == .page_up);

    const word_left = (try tui_input.readEventAlloc(std.testing.allocator, &reader)).?;
    try std.testing.expect(word_left == .key);
    try std.testing.expect(word_left.key == .word_left);

    const word_right = (try tui_input.readEventAlloc(std.testing.allocator, &reader)).?;
    try std.testing.expect(word_right == .key);
    try std.testing.expect(word_right.key == .word_right);

    const ctrl_a = (try tui_input.readEventAlloc(std.testing.allocator, &reader)).?;
    try std.testing.expect(ctrl_a == .key);
    try std.testing.expect(ctrl_a.key == .ctrl_a);

    const ctrl_e = (try tui_input.readEventAlloc(std.testing.allocator, &reader)).?;
    try std.testing.expect(ctrl_e == .key);
    try std.testing.expect(ctrl_e.key == .ctrl_e);

    const ctrl_j = (try tui_input.readEventAlloc(std.testing.allocator, &reader)).?;
    try std.testing.expect(ctrl_j == .key);
    try std.testing.expect(ctrl_j.key == .ctrl_j);

    const ctrl_k = (try tui_input.readEventAlloc(std.testing.allocator, &reader)).?;
    try std.testing.expect(ctrl_k == .key);
    try std.testing.expect(ctrl_k.key == .ctrl_k);

    const ctrl_r = (try tui_input.readEventAlloc(std.testing.allocator, &reader)).?;
    try std.testing.expect(ctrl_r == .key);
    try std.testing.expect(ctrl_r.key == .ctrl_r);

    const ctrl_u = (try tui_input.readEventAlloc(std.testing.allocator, &reader)).?;
    try std.testing.expect(ctrl_u == .key);
    try std.testing.expect(ctrl_u.key == .ctrl_u);

    const ctrl_w = (try tui_input.readEventAlloc(std.testing.allocator, &reader)).?;
    try std.testing.expect(ctrl_w == .key);
    try std.testing.expect(ctrl_w.key == .ctrl_w);

    const ctrl_d = (try tui_input.readEventAlloc(std.testing.allocator, &reader)).?;
    try std.testing.expect(ctrl_d == .key);
    try std.testing.expect(ctrl_d.key == .ctrl_d);
}

test "readEventAlloc parses bracketed paste" {
    var reader = std.Io.Reader.fixed("\x1b[200~hello\nworld\x1b[201~");
    const event = (try tui_input.readEventAlloc(std.testing.allocator, &reader)).?;
    defer if (event == .paste) std.testing.allocator.free(event.paste);
    try std.testing.expect(event == .paste);
    try std.testing.expectEqualStrings("hello\nworld", event.paste);
}

test "input editor supports newline and trim operations" {
    var model = TuiModel{
        .app = undefined,
        .editor = try ziggy.Editor.initWithCursor(std.testing.allocator, "abc", 1),
        .sidebar_output = try std.testing.allocator.dupe(u8, ""),
        .status_text = try std.testing.allocator.dupe(u8, ""),
    };
    defer model.deinit(std.testing.allocator);

    try model.insertNewline(std.testing.allocator);
    try std.testing.expectEqualStrings("a\nbc", model.editor.value);
    try std.testing.expectEqual(@as(usize, 2), model.editor.cursor);

    try model.deleteToEnd(std.testing.allocator);
    try std.testing.expectEqualStrings("a\n", model.editor.value);

    model.moveEnd();
    try model.deleteToStart(std.testing.allocator);
    try std.testing.expectEqualStrings("", model.editor.value);
    try std.testing.expectEqual(@as(usize, 0), model.editor.cursor);
}

test "input editor deletes previous word and searches history" {
    var model = TuiModel{
        .app = undefined,
        .editor = try ziggy.Editor.initWithCursor(std.testing.allocator, "alpha beta", "alpha beta".len),
        .sidebar_output = try std.testing.allocator.dupe(u8, ""),
        .status_text = try std.testing.allocator.dupe(u8, ""),
    };
    defer model.deinit(std.testing.allocator);

    try model.deletePreviousWord(std.testing.allocator);
    try std.testing.expectEqualStrings("alpha ", model.editor.value);

    try model.history.push(std.testing.allocator, "grep TODO");
    try model.history.push(std.testing.allocator, "read src/main.zig");
    try model.replaceInput(std.testing.allocator, "main", 4);
    try std.testing.expect(try model.searchHistoryBackward(std.testing.allocator));
    try std.testing.expectEqualStrings("read src/main.zig", model.editor.value);
}

test "input editor inserts pasted text and moves by word" {
    var model = TuiModel{
        .app = undefined,
        .editor = try ziggy.Editor.initWithCursor(std.testing.allocator, "alpha gamma", 6),
        .sidebar_output = try std.testing.allocator.dupe(u8, ""),
        .status_text = try std.testing.allocator.dupe(u8, ""),
    };
    defer model.deinit(std.testing.allocator);

    try model.insertText(std.testing.allocator, "beta ");
    try std.testing.expectEqualStrings("alpha beta gamma", model.editor.value);

    model.moveWordLeft();
    try std.testing.expectEqual(@as(usize, 6), model.editor.cursor);

    model.moveWordRight();
    try std.testing.expectEqual(@as(usize, 11), model.editor.cursor);
}

test "jump helpers find latest tool and error entries" {
    var app = try App.init(std.testing.allocator);
    defer app.deinit();

    try app.appendMessage(.{ .role = .user, .content = "list files" });
    const calls = [_]message_mod.ToolCall{
        .{
            .id = try std.testing.allocator.dupe(u8, "call_1"),
            .name = try std.testing.allocator.dupe(u8, "list_files"),
            .arguments = try std.testing.allocator.dupe(u8, "{\"path\":\".\"}"),
        },
    };
    defer {
        for (calls) |call| {
            std.testing.allocator.free(call.id);
            std.testing.allocator.free(call.name);
            std.testing.allocator.free(call.arguments);
        }
    }
    try app.appendAssistantToolCalls(&calls);
    try app.appendToolResult("call_1", "list_files", "a.txt");

    var model = TuiModel{
        .app = &app,
        .editor = try ziggy.Editor.init(std.testing.allocator, ""),
        .sidebar_output = try std.testing.allocator.dupe(u8, "error: MissingApiKey"),
        .status_text = try std.testing.allocator.dupe(u8, "idle"),
    };
    defer model.deinit(std.testing.allocator);

    try std.testing.expect(try model.jumpToLatestTool(std.testing.allocator, .{ .width = 100, .height = 30 }));
    try std.testing.expectEqual(PaneFocus.conversation, model.focus);

    try std.testing.expect(try model.jumpToLatestError(std.testing.allocator, .{ .width = 100, .height = 30 }));
    try std.testing.expectEqual(PaneFocus.activity, model.focus);
}

test "prompt history browse restores draft" {
    var model = TuiModel{
        .app = undefined,
        .editor = try ziggy.Editor.init(std.testing.allocator, "draft"),
        .sidebar_output = try std.testing.allocator.dupe(u8, ""),
    };
    defer model.deinit(std.testing.allocator);

    try model.history.push(std.testing.allocator, "one");
    try model.history.push(std.testing.allocator, "two");

    try model.browseHistoryUp(std.testing.allocator);
    try std.testing.expect(std.mem.eql(u8, model.editor.value, "two"));

    try model.browseHistoryUp(std.testing.allocator);
    try std.testing.expect(std.mem.eql(u8, model.editor.value, "one"));

    try model.browseHistoryDown(std.testing.allocator);
    try std.testing.expect(std.mem.eql(u8, model.editor.value, "two"));

    try model.browseHistoryDown(std.testing.allocator);
    try std.testing.expect(std.mem.eql(u8, model.editor.value, "draft"));
}
