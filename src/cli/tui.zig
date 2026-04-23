const std = @import("std");
const ziggy = @import("ziggy");

const App = @import("../core/app.zig").App;
const message_mod = @import("../core/message.zig");
const commands = @import("../commands/registry.zig");
const permissions = @import("../core/permissions.zig");
const provider = @import("../provider/adapter.zig");
const config_store = @import("../storage/config.zig");
const session_store = @import("../storage/session.zig");
const prompt_history_store = @import("../storage/prompt_history.zig");
const tools = @import("../tools/registry.zig");
const command_discovery = @import("../commands/discovery.zig");
const skills_discovery = @import("../skills/discovery.zig");
const tui_state = @import("tui_state.zig");
const tui_text = @import("tui_text.zig");
const tui_items = @import("tui_items.zig");
const tui_layout = @import("tui_layout.zig");
const tui_input = @import("tui_input.zig");
const turn_worker = @import("turn_worker.zig");
const input_reader = @import("input_reader.zig");

const Msg = ziggy.Event;
const Item = tui_items.Item;

const PaneFocus = enum {
    conversation,
    activity,
    repo,
    input,
};

const SlashSeed = struct {
    label: []const u8,
    value: []const u8,
    detail: []const u8,
};

const slash_completion_seeds = [_]SlashSeed{
    .{ .label = "/help", .value = "/help", .detail = "Show commands" },
    .{ .label = "/status", .value = "/status", .detail = "Show runtime status" },
    .{ .label = "/providers", .value = "/providers", .detail = "Show provider presets and current provider" },
    .{ .label = "/tools", .value = "/tools", .detail = "Show available built-in filesystem and shell tools" },
    .{ .label = "/tools show", .value = "/tools show ", .detail = "Show one built-in tool schema and details" },
    .{ .label = "/tools run", .value = "/tools run ", .detail = "Run one built-in tool directly with JSON arguments" },
    .{ .label = "/themes", .value = "/themes", .detail = "Show theme presets and current theme" },
    .{ .label = "/commands", .value = "/commands", .detail = "List external ~/.claude and ~/.codex commands" },
    .{ .label = "/exit", .value = "/exit", .detail = "Exit interactive mode" },
    .{ .label = "/clear", .value = "/clear", .detail = "Clear current session" },
    .{ .label = "/session", .value = "/session", .detail = "Show current in-memory session info" },
    .{ .label = "/config", .value = "/config", .detail = "Show config" },
    .{ .label = "/sessions", .value = "/sessions", .detail = "List saved sessions on disk" },
    .{ .label = "/provider", .value = "/provider ", .detail = "Set provider" },
    .{ .label = "/theme", .value = "/theme ", .detail = "Set theme preset" },
    .{ .label = "/model", .value = "/model ", .detail = "Set model" },
    .{ .label = "/skills", .value = "/skills", .detail = "List skills" },
    .{ .label = "/skills show", .value = "/skills show ", .detail = "Preview a rendered skill prompt" },
    .{ .label = "/mcp", .value = "/mcp ", .detail = "Manage MCP servers" },
    .{ .label = "/mcp status", .value = "/mcp status", .detail = "Check configured MCP servers and tool counts" },
    .{ .label = "/mcp show", .value = "/mcp show ", .detail = "Inspect one MCP server and its tools" },
    .{ .label = "/mcp tools", .value = "/mcp tools ", .detail = "List tools exposed by one MCP server" },
    .{ .label = "/plugins", .value = "/plugins", .detail = "List plugins" },
    .{ .label = "/doctor", .value = "/doctor", .detail = "Run environment checks" },
    .{ .label = "/diff", .value = "/diff", .detail = "Show git status and diff stat" },
    .{ .label = "/review", .value = "/review", .detail = "Review changed files" },
    .{ .label = "/subagent", .value = "/subagent ", .detail = "Subagent control surface" },
    .{ .label = "/compact", .value = "/compact", .detail = "Compact the current session" },
    .{ .label = "/permissions", .value = "/permissions ", .detail = "Show or set permissions" },
    .{ .label = "/plan", .value = "/plan ", .detail = "Toggle plan mode" },
    .{ .label = "/resume", .value = "/resume ", .detail = "Resume a saved session from disk" },
};

const TuiProgram = ziggy.Program(TuiModel, Msg);

const provider_picker_items = [_][]const u8{
    "openai",
    "openrouter",
    "anthropic",
    "gemini",
    "groq",
    "cerebras",
    "huggingface",
};

const theme_picker_items = [_][]const u8{
    "bubble",
    "midnight",
    "forest",
    "ember",
};

const PickerKind = enum {
    none,
    provider,
    model,
    theme,
};

const PaletteLayout = struct {
    margin_top: u16,
    margin_bottom: u16,
};

const HelpModalMetrics = struct {
    width: u16,
    height: u16,
    viewport_height: usize,
    document_width: usize,
};

fn appTheme(app: *const App) ziggy.AgentTheme {
    return ziggy.themeByName(app.config.theme);
}

fn computePaletteLayout(screen_height: u16, match_count: usize) PaletteLayout {
    const palette_visible_items: usize = @min(match_count, @as(usize, 10));
    const safe_height = @max(@as(usize, screen_height), 3);
    const desired_height = palette_visible_items + 12;
    const margin_top_usize = @max(safe_height / 8, 1);
    const max_palette_height = @max(safe_height - margin_top_usize - 1, 1);
    const palette_height = @min(desired_height, max_palette_height);
    return .{
        .margin_top = @intCast(margin_top_usize),
        .margin_bottom = @intCast(@max(safe_height - margin_top_usize - palette_height, 1)),
    };
}

fn computeHelpModalMetrics(size: ziggy.Size, padding: u16) HelpModalMetrics {
    const max_width = @max(size.width -| 6, @as(u16, 8));
    const max_height = @max(size.height -| 4, @as(u16, 6));
    const desired_width: u16 = @intCast((@as(u32, size.width) * 3) / 4);
    const desired_height: u16 = @intCast((@as(u32, size.height) * 3) / 4);
    const width: u16 = @min(max_width, @max(@min(max_width, @as(u16, 56)), desired_width));
    const height: u16 = @min(max_height, @max(@min(max_height, @as(u16, 14)), desired_height));
    const content_width = @max(@as(usize, width -| 2 -| (padding * 2)), 1);
    const viewport_height = @max(@as(usize, height -| 2 -| (padding * 2)), 1);
    return .{
        .width = width,
        .height = height,
        .viewport_height = viewport_height,
        .document_width = @max(content_width -| 2, 16),
    };
}

const TuiModel = struct {
    app: *App,
    editor: ziggy.Editor,
    sidebar_output: []const u8 = "",
    focus: PaneFocus = .input,
    conversation_scroll: usize = 0,
    conversation_body_scroll: usize = 0,
    activity_scroll: usize = 0,
    inspector_scroll: usize = 0,
    repo_scroll: usize = 0,
    show_right_sidebar: bool = true,
    conversation_selected: usize = 0,
    activity_selected: usize = 0,
    repo_state: ziggy.FileTreeBrowser.State = .{},
    repo_expanded_paths: std.ArrayList([]u8) = .empty,
    history: tui_state.PromptHistory = .{},
    completion: ziggy.Completion.State = .{},
    slash_items: std.ArrayList(ziggy.Completion.Item) = .empty,
    input_viewport: ziggy.TextArea.Viewport = .{},
    palette_open: bool = false,
    picker_kind: PickerKind = .none,
    picker_state: ziggy.PickerDialog.State = .{},
    modal: tui_state.ModalState = .{},
    actions: tui_state.ActionLog = .{},
    status_text: []const u8 = "",
    notification: ?[]u8 = null,
    notification_level: ziggy.NoticeBar.Level = .info,
    notification_until_ms: u64 = 0,
    turn_running: bool = false,
    turn_queue: turn_worker.TurnQueue = .{},
    pending_prompt: ?[]u8 = null,
    current_tool: ?[]u8 = null,
    last_error: ?[]u8 = null,
    live_assistant: ?[]u8 = null,

    fn deinit(self: *TuiModel, allocator: std.mem.Allocator) void {
        self.editor.deinit(allocator);
        self.completion.deinit(allocator);
        self.deinitSlashItems(allocator);
        for (self.repo_expanded_paths.items) |path| allocator.free(path);
        self.repo_expanded_paths.deinit(allocator);
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
        self.turn_queue.deinit();
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
        if (applyTurnWorkerEvents(self, ctx.persistent_allocator, ctx.now_ms) catch false) {
            ctx.requestRedraw();
        }
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
        if (looksLikePseudoToolPreview(next)) {
            if (self.live_assistant) |existing| allocator.free(existing);
            allocator.free(next);
            self.live_assistant = null;
            return;
        }
        if (self.live_assistant) |existing| allocator.free(existing);
        self.live_assistant = next;
    }

    fn clearLiveAssistant(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.live_assistant) |existing| allocator.free(existing);
        self.live_assistant = null;
    }

    fn looksLikePseudoToolPreview(text: []const u8) bool {
        return std.mem.indexOf(u8, text, "CALL>{") != null or
            std.mem.startsWith(u8, text, "CALL>") or
            std.mem.indexOf(u8, text, "ALL>{\"name\":") != null;
    }

    fn pickerItems(self: *const @This()) []const []const u8 {
        return switch (self.picker_kind) {
            .provider => &provider_picker_items,
            .theme => &theme_picker_items,
            .model => modelPickerItems(self.app.config.provider),
            .none => &.{},
        };
    }

    fn pickerTitle(self: *const @This()) []const u8 {
        return switch (self.picker_kind) {
            .provider => "Select Provider",
            .model => "Select Model",
            .theme => "Select Theme",
            .none => "",
        };
    }

    fn pickerDescription(self: *const @This()) []const u8 {
        return switch (self.picker_kind) {
            .provider => "Enter applies the provider preset and persists config.",
            .model => "Select a model tuned for the current provider preset.",
            .theme => "Choose the visual preset for cirebronx panels and selectors.",
            .none => "",
        };
    }

    fn openPicker(self: *@This(), kind: PickerKind) void {
        self.picker_kind = kind;
        self.picker_state = .{};
        self.picker_state.selection.viewport = 8;
        const items = self.pickerItems();
        if (items.len == 0) return;
        const selected_name = switch (kind) {
            .provider => self.app.config.provider,
            .model => self.app.config.model,
            .theme => self.app.config.theme,
            .none => "",
        };
        for (items, 0..) |item, index| {
            if (std.mem.eql(u8, item, selected_name)) {
                self.picker_state.selection.cursor = index;
                self.picker_state.selection.selected = index;
                self.picker_state.selection.offset = if (index > 3) index - 3 else 0;
                break;
            }
        }
    }

    fn closePicker(self: *@This()) void {
        self.picker_kind = .none;
        self.picker_state = .{};
    }

    fn appendSidebarLine(self: *@This(), allocator: std.mem.Allocator, line: []const u8) !void {
        const next = if (self.sidebar_output.len == 0)
            try allocator.dupe(u8, line)
        else
            try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ self.sidebar_output, line });
        allocator.free(self.sidebar_output);
        self.sidebar_output = next;
    }

    fn buildRepoEntries(self: *const @This(), allocator: std.mem.Allocator) !tui_items.RepoEntries {
        return tui_items.buildRepoEntries(allocator, self.app.cwd, self.repo_expanded_paths.items, 128);
    }

    fn repoPathIsExpanded(self: *const @This(), relative_path: []const u8) bool {
        for (self.repo_expanded_paths.items) |path| {
            if (std.mem.eql(u8, path, relative_path)) return true;
        }
        return false;
    }

    fn expandRepoPath(self: *@This(), allocator: std.mem.Allocator, relative_path: []const u8) !void {
        if (self.repoPathIsExpanded(relative_path)) return;
        try self.repo_expanded_paths.append(allocator, try allocator.dupe(u8, relative_path));
    }

    fn collapseRepoPath(self: *@This(), allocator: std.mem.Allocator, relative_path: []const u8) void {
        var index: usize = 0;
        while (index < self.repo_expanded_paths.items.len) {
            const path = self.repo_expanded_paths.items[index];
            const exact = std.mem.eql(u8, path, relative_path);
            const descendant = path.len > relative_path.len and
                std.mem.startsWith(u8, path, relative_path) and
                path[relative_path.len] == '/';
            if (exact or descendant) {
                allocator.free(path);
                _ = self.repo_expanded_paths.orderedRemove(index);
                continue;
            }
            index += 1;
        }
    }

    fn toggleRepoDirectory(self: *@This(), allocator: std.mem.Allocator, relative_path: []const u8) !void {
        if (self.repoPathIsExpanded(relative_path)) {
            self.collapseRepoPath(allocator, relative_path);
        } else {
            try self.expandRepoPath(allocator, relative_path);
        }
    }

    fn parentRepoPath(relative_path: []const u8) ?[]const u8 {
        const slash = std.mem.lastIndexOfScalar(u8, relative_path, '/') orelse return null;
        return relative_path[0..slash];
    }

    fn expandSelectedRepo(self: *@This(), allocator: std.mem.Allocator) !bool {
        var entries_data = try self.buildRepoEntries(allocator);
        defer entries_data.deinit(allocator);
        if (entries_data.entries.len == 0) return false;
        const selected = entries_data.entries[@min(self.repo_state.tree_state.selection.cursor, entries_data.entries.len - 1)];
        if (!selected.is_dir) return false;
        const normalized = std.mem.trimRight(u8, selected.path, "/");
        if (!selected.expanded) {
            try self.expandRepoPath(allocator, normalized);
            return true;
        }
        return false;
    }

    fn collapseSelectedRepo(self: *@This(), allocator: std.mem.Allocator) !bool {
        var entries_data = try self.buildRepoEntries(allocator);
        defer entries_data.deinit(allocator);
        if (entries_data.entries.len == 0) return false;
        const selected = entries_data.entries[@min(self.repo_state.tree_state.selection.cursor, entries_data.entries.len - 1)];
        if (selected.is_dir and selected.expanded) {
            self.collapseRepoPath(allocator, std.mem.trimRight(u8, selected.path, "/"));
            return true;
        }
        if (selected.depth > 0) {
            const parent = parentRepoPath(std.mem.trimRight(u8, selected.path, "/")) orelse return false;
            var parent_entries = try self.buildRepoEntries(allocator);
            defer parent_entries.deinit(allocator);
            for (parent_entries.entries, 0..) |entry, index| {
                if (std.mem.eql(u8, std.mem.trimRight(u8, entry.path, "/"), parent)) {
                    self.repo_state.tree_state.selection.cursor = index;
                    return true;
                }
            }
        }
        return false;
    }

    fn activateSelectedRepo(self: *@This(), allocator: std.mem.Allocator) !bool {
        var entries_data = try self.buildRepoEntries(allocator);
        defer entries_data.deinit(allocator);
        if (entries_data.entries.len == 0) return false;
        const selected = entries_data.entries[@min(self.repo_state.tree_state.selection.cursor, entries_data.entries.len - 1)];
        if (!selected.is_dir) return false;
        try self.toggleRepoDirectory(allocator, std.mem.trimRight(u8, selected.path, "/"));
        return true;
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
            .repo => blk: {
                const entries_data = try self.buildRepoEntries(allocator);
                defer {
                    var owned = entries_data;
                    owned.deinit(allocator);
                }
                if (entries_data.entries.len == 0) break :blk null;
                const selected = entries_data.entries[@min(self.repo_state.tree_state.selection.cursor, entries_data.entries.len - 1)];
                break :blk try allocator.dupe(u8, selected.path);
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
        try self.rebuildSlashItems(allocator);
        try ziggy.Completion.update(allocator, &self.completion, &self.editor, self.slash_items.items);
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
        self.completion.clear(allocator);
        if (self.editor.value.len == 1 and self.editor.value[0] == '/') {
            self.replaceInput(allocator, "", 0) catch {};
        }
    }

    fn dismissTransientUi(self: *@This(), allocator: std.mem.Allocator) bool {
        const had_any = self.modal.isOpen() or self.picker_kind != .none or self.palette_open or self.completion.visible;
        if (!had_any) return false;
        self.modal.close(allocator);
        self.closePicker();
        self.closeCommandPalette(allocator);
        return true;
    }

    fn acceptCompletion(self: *@This(), allocator: std.mem.Allocator) !bool {
        if (!self.completion.visible) return false;
        if (!try self.completion.applyCurrent(allocator, &self.editor)) return false;
        try self.refreshCompletion(allocator);
        self.palette_open = false;
        self.input_viewport = ziggy.TextArea.followCursor(&self.editor, "> ", self.input_viewport);
        return true;
    }

    fn deinitSlashItems(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.slash_items.items) |item| {
            allocator.free(@constCast(item.label));
            allocator.free(@constCast(item.value));
            if (item.detail) |detail| allocator.free(@constCast(detail));
        }
        self.slash_items.deinit(allocator);
        self.slash_items = .empty;
    }

    fn appendSlashItem(self: *@This(), allocator: std.mem.Allocator, label: []const u8, value: []const u8, detail: []const u8) !void {
        try self.slash_items.append(allocator, .{
            .label = try allocator.dupe(u8, label),
            .value = try allocator.dupe(u8, value),
            .detail = try allocator.dupe(u8, detail),
        });
    }

    fn containsSlashLabel(self: *const @This(), label: []const u8) bool {
        for (self.slash_items.items) |item| {
            if (std.mem.eql(u8, item.label, label)) return true;
        }
        return false;
    }

    fn rebuildSlashItems(self: *@This(), allocator: std.mem.Allocator) !void {
        self.deinitSlashItems(allocator);

        for (slash_completion_seeds) |seed| {
            try self.appendSlashItem(allocator, seed.label, seed.value, seed.detail);
        }

        const found_commands = try command_discovery.discover(allocator);
        defer {
            for (found_commands) |*command| command.deinit(allocator);
            allocator.free(found_commands);
        }
        for (found_commands) |command| {
            const label = try std.fmt.allocPrint(allocator, "/{s}", .{command.name});
            defer allocator.free(label);
            if (self.containsSlashLabel(label)) continue;
            const value = try std.fmt.allocPrint(allocator, "/{s} ", .{command.name});
            defer allocator.free(value);
            const detail = try std.fmt.allocPrint(allocator, "[{s}] {s}", .{ command.source, command.summary });
            defer allocator.free(detail);
            try self.appendSlashItem(allocator, label, value, detail);
        }

        const found_skills = try skills_discovery.discover(allocator);
        defer {
            for (found_skills) |*skill| skill.deinit(allocator);
            allocator.free(found_skills);
        }
        for (found_skills) |skill| {
            const label = try std.fmt.allocPrint(allocator, "/{s}", .{skill.name});
            defer allocator.free(label);
            if (self.containsSlashLabel(label)) continue;
            const value = try std.fmt.allocPrint(allocator, "/{s} ", .{skill.name});
            defer allocator.free(value);
            const detail = try std.fmt.allocPrint(allocator, "[{s}] {s}", .{ skill.source, skill.summary });
            defer allocator.free(detail);
            try self.appendSlashItem(allocator, label, value, detail);
        }

        std.mem.sort(ziggy.Completion.Item, self.slash_items.items, {}, struct {
            fn lessThan(_: void, a: ziggy.Completion.Item, b: ziggy.Completion.Item) bool {
                return std.ascii.lessThanIgnoreCase(a.label, b.label);
            }
        }.lessThan);
    }

    fn selectedCompletionExecutesImmediately(self: *const @This()) bool {
        const current = self.completion.current() orelse return false;
        return !std.mem.endsWith(u8, current.item.value, " ");
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
        const entries = self.focusEntries();
        const next_id = ziggy.FocusGroup.next(&entries, paneFocusId(self.focus)) orelse return;
        self.focus = paneFocusFromId(next_id);
    }

    fn cycleFocusReverse(self: *@This()) void {
        const entries = self.focusEntries();
        const next_id = ziggy.FocusGroup.previous(&entries, paneFocusId(self.focus)) orelse return;
        self.focus = paneFocusFromId(next_id);
    }

    fn focusEntries(self: *const @This()) [4]ziggy.FocusGroup.Entry {
        return .{
            .{ .id = "conversation" },
            .{ .id = "activity", .enabled = self.show_right_sidebar },
            .{ .id = "repo", .enabled = self.show_right_sidebar },
            .{ .id = "input" },
        };
    }

    fn normalizeFocus(self: *@This()) void {
        const entries = self.focusEntries();
        const normalized = ziggy.FocusGroup.normalize(&entries, paneFocusId(self.focus)) orelse return;
        self.focus = paneFocusFromId(normalized);
    }

    fn toggleRightSidebar(self: *@This()) void {
        self.show_right_sidebar = !self.show_right_sidebar;
        self.normalizeFocus();
    }

    pub fn syncScrollBounds(self: *@This(), size: ziggy.Size) void {
        self.normalizeFocus();
        const conversation_total = conversationItemCount(self, self.app.allocator) catch 0;
        const conversation_body_total = conversationBodyLineCount(self, self.app.allocator, size) catch 0;
        const activity_total = activityItemCount(self);
        if (conversation_total > 0) self.conversation_selected = @min(self.conversation_selected, conversation_total - 1) else self.conversation_selected = 0;
        if (activity_total > 0) self.activity_selected = @min(self.activity_selected, activity_total - 1) else self.activity_selected = 0;
        const repo_total = repoItemCount(self, self.app.allocator) catch 0;
        if (repo_total > 0)
            self.repo_state.tree_state.selection.cursor = @min(self.repo_state.tree_state.selection.cursor, repo_total - 1)
        else
            self.repo_state.tree_state.selection.cursor = 0;
        self.repo_scroll = @min(self.repo_scroll, tui_layout.maxScrollOffset(repo_total, @as(usize, tui_layout.repoContentRect(size).height)));
        self.conversation_scroll = @min(self.conversation_scroll, tui_layout.maxScrollOffset(conversation_total, tui_layout.conversationVisibleHeightForSize(size)));
        self.conversation_body_scroll = @min(self.conversation_body_scroll, tui_layout.maxScrollOffset(conversation_body_total, tui_layout.conversationBodyVisibleHeight(size)));
        self.activity_scroll = @min(self.activity_scroll, tui_layout.maxScrollOffset(activity_total, tui_layout.activityVisibleHeightForSize(size)));
        const inspector_total = inspectorLineCount(self, self.app.allocator) catch 0;
        self.inspector_scroll = @min(self.inspector_scroll, tui_layout.maxScrollOffset(inspector_total, @as(usize, tui_layout.inspectorContentRect(size).height)));
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
        const repo_visible = @as(usize, tui_layout.repoContentRect(size).height);
        const repo_selected = self.repo_state.tree_state.selection.cursor;
        if (repo_selected < self.repo_scroll) self.repo_scroll = repo_selected;
        if (repo_visible > 0 and repo_selected >= self.repo_scroll + repo_visible) {
            self.repo_scroll = repo_selected -| repo_visible -| 1;
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
            .repo => {
                if (self.repo_state.tree_state.selection.cursor > 0) self.repo_state.tree_state.selection.cursor -= 1;
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
            .repo => {
                const repo_total = repoItemCount(self, self.app.allocator) catch 0;
                if (repo_total > 0 and self.repo_state.tree_state.selection.cursor + 1 < repo_total) {
                    self.repo_state.tree_state.selection.cursor += 1;
                }
            },
            .input => {},
        }
        self.syncScrollBounds(size);
    }

    fn openSelectionModal(self: *@This(), allocator: std.mem.Allocator) !void {
        self.closeCommandPalette(allocator);
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
            .repo => {
                const entries_data = try self.buildRepoEntries(allocator);
                defer {
                    var owned = entries_data;
                    owned.deinit(allocator);
                }
                if (entries_data.entries.len == 0) return;
                const selected = entries_data.entries[@min(self.repo_state.tree_state.selection.cursor, entries_data.entries.len - 1)];
                try self.modal.open(allocator, "Repo Entry", selected.path);
            },
            .input => {},
        }
    }

    pub fn openHelpModal(self: *@This(), allocator: std.mem.Allocator) !void {
        self.closeCommandPalette(allocator);
        const body = try tui_text.buildHelpBody(allocator);
        defer allocator.free(body);
        try self.modal.openWithKind(allocator, "TUI Help", body, .help);
    }

    pub fn openSessionModal(self: *@This(), allocator: std.mem.Allocator) !void {
        self.closeCommandPalette(allocator);
        const body = try tui_text.buildSessionBody(allocator, self.app, self.turn_running, self.status_text);
        defer allocator.free(body);
        try self.modal.open(allocator, "Session", body);
    }

    pub fn openConfigModal(self: *@This(), allocator: std.mem.Allocator) !void {
        self.closeCommandPalette(allocator);
        const body = try tui_text.buildConfigBody(allocator, self.app);
        defer allocator.free(body);
        try self.modal.open(allocator, "Config", body);
    }

    fn openCustomModal(self: *@This(), allocator: std.mem.Allocator, title: []const u8, body: []const u8) !void {
        self.closeCommandPalette(allocator);
        try self.modal.open(allocator, title, body);
    }

    fn closeModal(self: *@This(), allocator: std.mem.Allocator) void {
        _ = self.dismissTransientUi(allocator);
    }

    fn applyPickerSelection(self: *@This(), allocator: std.mem.Allocator) ![]const u8 {
        const kind = self.picker_kind;
        const items = self.pickerItems();
        if (items.len == 0) return "picker closed";
        const selected_index = @min(self.picker_state.selection.cursor, items.len - 1);
        const selected = items[selected_index];
        switch (kind) {
            .provider => try config_store.setProviderPreset(allocator, &self.app.config, config_store.parseProviderPreset(selected).?),
            .model => {
                allocator.free(self.app.config.model);
                self.app.config.model = try allocator.dupe(u8, selected);
            },
            .theme => {
                allocator.free(self.app.config.theme);
                self.app.config.theme = try allocator.dupe(u8, selected);
            },
            .none => {},
        }
        try config_store.save(allocator, &self.app.config);
        self.closePicker();
        return switch (kind) {
            .provider => "provider updated",
            .model => "model updated",
            .theme => "theme updated",
            .none => "picker closed",
        };
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
            .repo => {
                const reusable = try self.reusableSelection(allocator) orelse return;
                defer allocator.free(reusable);
                try self.replaceInput(allocator, reusable, reusable.len);
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
            .repo => self.repo_state.tree_state.selection.cursor -|= activity_step,
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
            .repo => {
                const repo_total = repoItemCount(self, self.app.allocator) catch 0;
                if (repo_total > 0) {
                    self.repo_state.tree_state.selection.cursor = @min(self.repo_state.tree_state.selection.cursor + activity_step, repo_total - 1);
                }
            },
            .input => {},
        }
        self.syncScrollBounds(size);
    }

    pub fn viewNode(self: *@This(), ctx: *ziggy.Context) !*const ziggy.Node {
        self.syncScrollBounds(ctx.size);
        const theme = appTheme(self.app);
        const conversation = try buildConversationPane(self, ctx.allocator, ctx.size);
        const main = if (self.show_right_sidebar)
            blk: {
                const right_column = try buildRightColumn(self, ctx.allocator, ctx.size);
                break :blk try ziggy.HStack.buildWithWeights(ctx.allocator, &.{ conversation, right_column }, 1, &.{ tui_layout.leftPaneRatio(ctx.size), 100 - tui_layout.leftPaneRatio(ctx.size) });
            }
        else
            conversation;
        const input_rect = tui_layout.inputContentRect(ctx.size);
        self.input_viewport = ziggy.TextArea.followCursor(&self.editor, "> ", .{
            .offset_line = self.input_viewport.offset_line,
            .offset_column = self.input_viewport.offset_column,
            .width = input_rect.width,
            .height = 1,
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
            "ctrl+x quit",
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
            main,
            bottom,
            tui_layout.topAreaRatio(ctx.size),
            .vertical,
        );

        const with_palette = if (self.palette_open and self.completion.visible)
            blk: {
                const palette_layout = computePaletteLayout(ctx.size.height, self.completion.matches.len);
                const palette = (try ziggy.Palette.build(ctx.allocator, &self.completion, .{
                    .title = "Commands",
                    .hint = "Enter runs complete commands  Tab inserts  Esc closes  Ctrl+N/P moves",
                    .style = theme.pane,
                    .selected_style = .{
                        .fg = .{ .rgb = .{ .r = 8, .g = 12, .b = 20 } },
                        .bg = .{ .rgb = .{ .r = 250, .g = 204, .b = 21 } },
                        .bold = true,
                    },
                    .box_style = theme.pane_active,
                    .border_style = theme.modal_border_style,
                    .detail_style = theme.pane,
                    .detail_box_style = theme.pane,
                    .max_visible_items = 7,
                    .focus = .{ .active = true, .focus_id = "palette" },
                })).?;
                const overlay = try ziggy.Box.buildWithOptions(ctx.allocator, null, palette, .{
                    .style = theme.pane_active,
                    .border_style = theme.modal_border_style,
                    .margin_top = palette_layout.margin_top,
                    .margin_bottom = palette_layout.margin_bottom,
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

        const with_picker = if (self.picker_kind != .none)
            blk: {
                const items = self.pickerItems();
                const picker = try ziggy.PickerDialog.build(ctx.allocator, self.pickerTitle(), items, .{
                    .description = self.pickerDescription(),
                    .selected = self.picker_state.selection.cursor,
                    .offset = self.picker_state.selection.offset,
                    .style = theme.pane,
                    .selected_style = theme.selected,
                    .box_style = theme.pane_active,
                    .description_style = theme.status_idle,
                    .border_style = theme.modal_border_style,
                    .focus = .{ .active = true, .focus_id = "picker" },
                });
                const modal = try ziggy.Modal.buildNodeWithOptions(ctx.allocator, self.pickerTitle(), picker, .{
                    .style = theme.pane_active,
                    .border_style = theme.modal_border_style,
                });
                break :blk try ziggy.allocNode(ctx.allocator, .{
                    .overlay = .{ .base = with_palette, .overlay = modal },
                });
            }
        else
            with_palette;

        if (self.modal.isOpen()) {
            const modal_padding: u16 = 1;
            const modal_metrics = computeHelpModalMetrics(ctx.size, modal_padding);
            const markdown_theme: ziggy.FormatRichMarkdown.Theme = .{
                .base = theme.pane,
                .heading = theme.selected_alt,
                .bullet = theme.selected_alt,
                .quote = theme.status_idle,
                .code = theme.input,
                .strong = .{ .bold = true },
                .emphasis = .{ .underline = true },
                .link = .{
                    .fg = theme.selected_alt.fg,
                    .underline = true,
                },
                .muted = theme.status_idle,
                .accent = theme.selected_alt,
                .code_lineno = theme.status_idle,
            };
            const lines = try ziggy.FormatRichMarkdown.renderLines(
                ctx.allocator,
                self.modal.body.?,
                modal_metrics.document_width,
                markdown_theme,
            );
            self.modal.scroll = ziggy.RichDocument.clampOffset(lines.len, modal_metrics.viewport_height, self.modal.scroll);
            const help_document = try ziggy.RichDocument.build(ctx.allocator, lines, self.modal.scroll, theme.pane);
            const scrollbar = try ziggy.Scrollbar.build(ctx.allocator, .{
                .offset = self.modal.scroll,
                .viewport = modal_metrics.viewport_height,
                .total = lines.len,
                .style = theme.pane,
                .thumb_style = theme.selected_alt,
            });
            const help_content = try ziggy.HStack.buildWithWeights(ctx.allocator, &.{ help_document, scrollbar }, 1, &.{ 100, 1 });
            const modal = try ziggy.Modal.buildNodeWithOptions(ctx.allocator, self.modal.title.?, help_content, .{
                .style = theme.pane_active,
                .border_style = theme.modal_border_style,
                .padding = modal_padding,
            });
            return try ziggy.allocNode(ctx.allocator, .{
                .overlay = .{ .base = with_picker, .overlay = modal },
            });
        }

        return with_picker;
    }
};

fn buildRightColumn(model: *const TuiModel, allocator: std.mem.Allocator, size: ziggy.Size) !*const ziggy.Node {
    const activity = try buildSidebarPane(model, allocator, size);
    const inspector = try buildInspectorPane(model, allocator, size);
    const repo = try buildRepoPane(model, allocator, size);
    const right_bottom = try ziggy.VStack.buildWithWeights(allocator, &.{ inspector, repo }, 1, &.{ 3, 2 });
    return try ziggy.VStack.buildWithWeights(allocator, &.{ activity, right_bottom }, 1, &.{ 3, 2 });
}

fn submitCurrentInput(program: *TuiProgram, app: *App, stdin: *std.Io.Reader) !bool {
    const submitted = try program.model.submittedInput(app.allocator);
    defer app.allocator.free(submitted);
    return try executeSubmittedInput(program, app, stdin, submitted);
}

fn handlePickerKey(program: *TuiProgram, app: *App, key: ziggy.Key) !bool {
    if (program.model.picker_kind == .none) return false;

    const items = program.model.pickerItems();
    if (items.len == 0) {
        program.model.closePicker();
        try program.redraw();
        return true;
    }

    const mapped_key = switch (key) {
        .char => |byte| switch (byte) {
            'j' => ziggy.Key{ .down = {} },
            'k' => ziggy.Key{ .up = {} },
            else => return false,
        },
        .tab => ziggy.Key{ .enter = {} },
        else => key,
    };

    const response = ziggy.PickerDialog.handleEvent(&program.model.picker_state, items, mapped_key);
    if (!response.handled) return false;

    switch (response.action) {
        .submitted => {
            const result = try program.model.applyPickerSelection(app.allocator);
            try program.model.setStatus(app.allocator, result);
            try program.model.logAction(app.allocator, result);
            try program.model.setNotification(
                app.allocator,
                .info,
                result,
                @intCast(@max(std.time.milliTimestamp(), 0)),
                1800,
            );
            program.model.syncScrollBounds(program.tty.size);
        },
        .cancelled => {
            program.model.closePicker();
            try program.model.logAction(app.allocator, "picker closed");
        },
        else => {},
    }

    if (response.redraw) try program.redraw();
    return true;
}

fn handleInputControlKey(program: *TuiProgram, app: *App, key: ziggy.Key) !void {
    try tui_input.handleInputControlKey(program, app, key);
}

fn handlePaneChar(program: *TuiProgram, app: *App, stdin: *std.Io.Reader, byte: u8) !bool {
    return try tui_input.handlePaneChar(program, app, stdin, byte, submitCurrentInput, conversationItemCount, activityItemCount, repoItemCount, paneFocusString);
}

pub fn runInteractive(app: *App) !void {
    _ = ziggy.prepareConsole();
    const render_profile = ziggy.getRenderProfile();

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
        .sidebar_output = try tui_text.buildStartupSidebar(app.allocator, render_profile),
        .status_text = try std.fmt.allocPrint(app.allocator, "idle | render={s} icon={s}", .{
            @tagName(render_profile.render_mode),
            @tagName(render_profile.icon_mode),
        }),
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
    var queued_input = input_reader.InputQueue{};
    defer queued_input.deinit();
    try input_reader.spawn(&queued_input, stdin);
    var last_tick_ms: u64 = @intCast(@max(std.time.milliTimestamp(), 0));

    interactive_loop: while (true) {
        const now_ms: u64 = @intCast(@max(std.time.milliTimestamp(), 0));
        const delta_ms = now_ms - last_tick_ms;
        last_tick_ms = now_ms;
        if (!try program.processTick(delta_ms)) break;

        const events = try queued_input.poll();
        defer {
            for (events) |*event| input_reader.deinitEvent(std.heap.page_allocator, event);
            std.heap.page_allocator.free(events);
        }
        for (events) |event| switch (event) {
            .key => |key| {
                if (!program.model.modal.isOpen() and try handlePickerKey(&program, app, key)) continue;
                switch (key) {
                .ctrl_c, .ctrl_d, .ctrl_x => break :interactive_loop,
                .ctrl_a, .ctrl_e, .ctrl_j, .ctrl_k, .ctrl_r, .ctrl_u, .ctrl_w => {
                    if (!program.model.modal.isOpen() and program.model.focus == .input) {
                        try handleInputControlKey(&program, app, key);
                    }
                },
                .ctrl_h => {
                    if (program.model.modal.isOpen()) {
                        program.model.closeModal(app.allocator);
                        try program.model.logAction(app.allocator, "closed help modal");
                    } else {
                        try program.model.openHelpModal(app.allocator);
                        try program.model.logAction(app.allocator, "opened help modal");
                    }
                    try program.redraw();
                },
                .ctrl_y => {
                    if (program.model.focus != .input or program.model.modal.isOpen()) {
                        try copyFocusedSelection(&program, app);
                        try program.redraw();
                    }
                },
                .ctrl_b => {
                    if (!program.model.modal.isOpen()) {
                        program.model.toggleRightSidebar();
                        program.model.syncScrollBounds(program.tty.size);
                        try program.model.logAction(app.allocator, if (program.model.show_right_sidebar)
                            "right sidebar shown"
                        else
                            "right sidebar hidden");
                        try program.redraw();
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
                    if (program.model.dismissTransientUi(app.allocator)) {
                        try program.model.logAction(app.allocator, "closed transient ui");
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

                    if (program.model.focus != .input) {
                        switch (byte) {
                            'v' => {
                                program.model.openPicker(.provider);
                                try program.model.logAction(app.allocator, "opened provider picker");
                                try program.redraw();
                                continue;
                            },
                            'm' => {
                                program.model.openPicker(.model);
                                try program.model.logAction(app.allocator, "opened model picker");
                                try program.redraw();
                                continue;
                            },
                            't' => {
                                program.model.openPicker(.theme);
                                try program.model.logAction(app.allocator, "opened theme picker");
                                try program.redraw();
                                continue;
                            },
                            else => {},
                        }
                    }

                    if (program.model.focus == .input) {
                        try program.model.insertChar(app.allocator, byte);
                        try program.redraw();
                        continue;
                    }

                    if (try handlePaneChar(&program, app, stdin, byte)) break :interactive_loop;
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
                    } else if (!program.model.modal.isOpen() and program.model.focus == .repo) {
                        if (try program.model.collapseSelectedRepo(app.allocator)) try program.redraw();
                    }
                },
                .right => {
                    if (!program.model.modal.isOpen() and program.model.focus == .input) {
                        program.model.editor.clearSelection();
                        program.model.moveRight();
                        try program.redraw();
                    } else if (!program.model.modal.isOpen() and program.model.focus == .repo) {
                        if (try program.model.expandSelectedRepo(app.allocator)) try program.redraw();
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
                    if (program.model.modal.isOpen()) {
                        program.model.modal.scroll = 0;
                        try program.redraw();
                        continue;
                    }
                    if (program.model.focus == .input) {
                        program.model.moveHome();
                    } else {
                        switch (program.model.focus) {
                            .conversation => {
                                program.model.conversation_selected = 0;
                                program.model.conversation_body_scroll = 0;
                            },
                            .activity => program.model.activity_selected = 0,
                            .repo => program.model.repo_state.tree_state.selection.cursor = 0,
                            .input => {},
                        }
                        program.model.syncScrollBounds(program.tty.size);
                    }
                    try program.redraw();
                },
                .end => {
                    if (program.model.modal.isOpen()) {
                        program.model.modal.scroll = 1_000_000;
                        try program.redraw();
                        continue;
                    }
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
                            .repo => {
                                const total = try repoItemCount(&program.model, app.allocator);
                                if (total > 0) program.model.repo_state.tree_state.selection.cursor = total - 1;
                            },
                            .input => {},
                        }
                        program.model.syncScrollBounds(program.tty.size);
                    }
                    try program.redraw();
                },
                .page_up => {
                    if (program.model.modal.isOpen()) {
                        program.model.modal.scroll -|= 8;
                        try program.redraw();
                        continue;
                    }
                    if (program.model.focus != .input) {
                        program.model.pageMoveUp(program.tty.size);
                        try program.redraw();
                    }
                },
                .page_down => {
                    if (program.model.modal.isOpen()) {
                        program.model.modal.scroll += 8;
                        try program.redraw();
                        continue;
                    }
                    if (program.model.focus != .input) {
                        const conversation_total = try conversationItemCount(&program.model, app.allocator);
                        const activity_total = activityItemCount(&program.model);
                        program.model.pageMoveDown(program.tty.size, conversation_total, activity_total);
                        try program.redraw();
                    }
                },
                .up => {
                    if (program.model.modal.isOpen()) {
                        program.model.modal.scroll -|= 1;
                        try program.redraw();
                        continue;
                    }
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
                    if (program.model.modal.isOpen()) {
                        program.model.modal.scroll += 1;
                        try program.redraw();
                        continue;
                    }
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

                    if (program.model.picker_kind != .none) {
                        _ = try handlePickerKey(&program, app, .enter);
                        continue;
                    }

                    if (program.model.focus != .input) {
                        if (program.model.focus == .repo and try program.model.activateSelectedRepo(app.allocator)) {
                            try program.model.logAction(app.allocator, "toggled repo directory");
                            try program.redraw();
                            continue;
                        }
                        try program.model.openSelectionModal(app.allocator);
                        if (program.model.modal.isOpen()) {
                            try program.model.logAction(app.allocator, "opened detail modal");
                        }
                        try program.redraw();
                        continue;
                    }

                    if (program.model.completion.visible) {
                        const execute_now = program.model.palette_open and program.model.selectedCompletionExecutesImmediately();
                        _ = try program.model.acceptCompletion(app.allocator);
                        if (execute_now) {
                            if (try submitCurrentInput(&program, app, stdin)) break :interactive_loop;
                        }
                        try program.redraw();
                        continue;
                    }

                    if (try submitCurrentInput(&program, app, stdin)) break :interactive_loop;
                },
                else => {},
                }
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
        };

        std.Thread.sleep(16 * std.time.ns_per_ms);
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
    const inspector_rect = tui_layout.inspectorRect(size);
    const inspector_content_rect = tui_layout.inspectorContentRect(size);
    const inspector_scrollbar_rect = tui_layout.inspectorScrollbarRect(size);
    const repo_rect = tui_layout.repoRect(size);
    const repo_content_rect = tui_layout.repoContentRect(size);
    const repo_scrollbar_rect = tui_layout.repoScrollbarRect(size);
    const input_rect = tui_layout.inputRect(size);
    const input_content_rect = tui_layout.inputContentRect(size);
    const conversation_page = @max(tui_layout.conversationBodyVisibleHeight(size) / 2, 1);
    const activity_page = @max(tui_layout.activityVisibleHeightForSize(size) / 2, 1);

    if (mouse.button == .wheel_up and mouse.pressed) {
        if (conversation_rect.contains(mouse.x, mouse.y)) {
            program.model.focus = .conversation;
            program.model.conversation_body_scroll -|= 1;
            try program.redraw();
        } else if (program.model.show_right_sidebar and activity_rect.contains(mouse.x, mouse.y)) {
            program.model.focus = .activity;
            program.model.activity_scroll -|= 1;
            try program.redraw();
        } else if (program.model.show_right_sidebar and inspector_rect.contains(mouse.x, mouse.y)) {
            program.model.inspector_scroll -|= 1;
            try program.redraw();
        } else if (program.model.show_right_sidebar and repo_rect.contains(mouse.x, mouse.y)) {
            program.model.focus = .repo;
            program.model.repo_scroll -|= 1;
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
        } else if (program.model.show_right_sidebar and activity_rect.contains(mouse.x, mouse.y)) {
            program.model.focus = .activity;
            program.model.activity_scroll += 1;
            program.model.syncScrollBounds(size);
            try program.redraw();
        } else if (program.model.show_right_sidebar and inspector_rect.contains(mouse.x, mouse.y)) {
            program.model.inspector_scroll += 1;
            program.model.syncScrollBounds(size);
            try program.redraw();
        } else if (program.model.show_right_sidebar and repo_rect.contains(mouse.x, mouse.y)) {
            program.model.focus = .repo;
            program.model.repo_scroll += 1;
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

    if (program.model.show_right_sidebar) {
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
    }

    if (program.model.show_right_sidebar) {
        if (ziggy.Scrollbar.hitTestVerticalTrack(
            inspector_scrollbar_rect,
            program.model.inspector_scroll,
            @as(usize, inspector_content_rect.height),
            try inspectorLineCount(&program.model, app.allocator),
            mouse.x,
            mouse.y,
        )) |hit| {
            switch (hit) {
                .page_up => program.model.inspector_scroll -|= activity_page,
                .page_down => program.model.inspector_scroll += activity_page,
            }
            program.model.syncScrollBounds(size);
            try program.redraw();
            return;
        }
    }

    if (program.model.show_right_sidebar) {
        if (ziggy.Scrollbar.hitTestVerticalTrack(
            repo_scrollbar_rect,
            program.model.repo_scroll,
            @as(usize, repo_content_rect.height),
            try repoItemCount(&program.model, app.allocator),
            mouse.x,
            mouse.y,
        )) |hit| {
            program.model.focus = .repo;
            switch (hit) {
                .page_up => program.model.repo_scroll -|= activity_page,
                .page_down => program.model.repo_scroll += activity_page,
            }
            program.model.syncScrollBounds(size);
            try program.redraw();
            return;
        }
    }

    if (conversation_content_rect.contains(mouse.x, mouse.y)) {
        program.model.focus = .conversation;
        const document = try tui_items.buildConversationDocument(
            app.allocator,
            appTheme(program.model.app),
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

    if (program.model.show_right_sidebar) {
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
    }

    if (program.model.show_right_sidebar and inspector_content_rect.contains(mouse.x, mouse.y)) {
        try program.redraw();
        return;
    }

    if (program.model.show_right_sidebar and repo_content_rect.contains(mouse.x, mouse.y)) {
        program.model.focus = .repo;
        var entries_data = try program.model.buildRepoEntries(app.allocator);
        defer entries_data.deinit(app.allocator);
        if (ziggy.Pane.hitTestSelectableList(repo_content_rect, entries_data.entries.len, program.model.repo_scroll, mouse.x, mouse.y)) |absolute| {
            const previous = program.model.repo_state.tree_state.selection.cursor;
            program.model.repo_state.tree_state.selection.cursor = absolute;
            const selected = entries_data.entries[absolute];
            if (selected.is_dir and absolute == previous) {
                try program.model.toggleRepoDirectory(app.allocator, std.mem.trimRight(u8, selected.path, "/"));
            }
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
    background_started: bool = false,
};

fn startBackgroundTurn(program: *TuiProgram, app: *App, prompt: []const u8) !void {
    try app.appendMessage(.{
        .role = .user,
        .content = prompt,
    });
    program.model.turn_running = true;
    try program.model.setPendingPrompt(app.allocator, prompt);
    program.model.clearCurrentTool(app.allocator);
    program.model.clearLastError(app.allocator);
    program.model.clearLiveAssistant(app.allocator);
    try program.model.setStatus(app.allocator, "queued background turn");
    try turn_worker.spawn(&program.model.turn_queue, app);
}

fn finishBackgroundTurn(model: *TuiModel, app: *App) !void {
    model.turn_running = false;
    model.clearPendingPrompt(app.allocator);
    model.clearCurrentTool(app.allocator);
    model.clearLiveAssistant(app.allocator);
    try session_store.saveSession(
        app.allocator,
        app.config.paths,
        app.session_id,
        app.cwd,
        app.config.model,
        app.session.items,
    );
}

fn applyTurnWorkerEvents(model: *TuiModel, allocator: std.mem.Allocator, now_ms: u64) !bool {
    const events = try model.turn_queue.poll();
    defer {
        for (events) |*event| event.deinit(std.heap.page_allocator);
        std.heap.page_allocator.free(events);
    }

    var changed = false;
    for (events) |event| {
        changed = true;
        switch (event) {
            .status => |text| {
                try model.setStatus(allocator, text);
            },
            .text_chunk => |text| {
                try model.appendLiveAssistant(allocator, text);
                try model.setStatus(allocator, "streaming assistant");
            },
            .tool_calls => |calls| {
                try applyToolCallEvent(model, allocator, calls);
            },
            .tool_result => |result| {
                try applyToolResultEvent(model, allocator, result);
            },
            .assistant_text => |text| {
                try applyAssistantTextEvent(model, allocator, text);
            },
            .turn_error => |text| {
                try applyTurnErrorEvent(model, allocator, now_ms, text);
            },
            .done => {
                try finishBackgroundTurn(model, model.app);
            },
        }
    }
    return changed;
}

fn applyToolCallEvent(model: *TuiModel, allocator: std.mem.Allocator, calls: []const message_mod.ToolCall) !void {
    model.clearLiveAssistant(allocator);
    try model.app.appendAssistantToolCalls(calls);
    if (calls.len == 0) return;

    try model.setCurrentTool(allocator, calls[0].name);
    const tool_line = try std.fmt.allocPrint(allocator, "[tool] {s}", .{calls[0].name});
    defer allocator.free(tool_line);
    try model.appendSidebarLine(allocator, tool_line);
    const tool_action = try std.fmt.allocPrint(allocator, "tool: {s}", .{calls[0].name});
    defer allocator.free(tool_action);
    try model.logAction(allocator, tool_action);
}

fn applyToolResultEvent(model: *TuiModel, allocator: std.mem.Allocator, result: turn_worker.ToolResult) !void {
    try model.app.appendToolResult(result.tool_call_id, result.tool_name, result.content);
    const result_line = try std.fmt.allocPrint(allocator, "tool result: {s}", .{ziggy.FormatText.previewText(result.content, 56)});
    defer allocator.free(result_line);
    try model.appendSidebarLine(allocator, result_line);
}

fn applyAssistantTextEvent(model: *TuiModel, allocator: std.mem.Allocator, text: []const u8) !void {
    model.clearCurrentTool(allocator);
    model.clearLiveAssistant(allocator);
    try model.app.appendAssistantText(text);
    try model.appendSidebarLine(allocator, text);
    try model.setStatus(allocator, "assistant replied");
    const finished = try std.fmt.allocPrint(allocator, "done: {s}", .{
        ziggy.FormatText.previewText(text, 56),
    });
    defer allocator.free(finished);
    try model.logAction(allocator, finished);
    model.activity_selected = activityItemCount(model) -| 1;
}

fn applyTurnErrorEvent(model: *TuiModel, allocator: std.mem.Allocator, now_ms: u64, text: []const u8) !void {
    try model.setLastError(allocator, text);
    try model.appendSidebarLine(allocator, text);
    try model.logAction(allocator, text);
    try model.setNotification(
        allocator,
        .err,
        text,
        now_ms,
        2400,
    );
}

fn copyToClipboard(allocator: std.mem.Allocator, text: []const u8) !void {
    var child = std.process.Child.init(&.{ "cmd", "/c", "clip" }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    if (child.stdin) |stdin_pipe| {
        defer stdin_pipe.close();
        _ = try stdin_pipe.writeAll(text);
    }
    _ = try child.wait();
}

fn copyFocusedSelection(program: *TuiProgram, app: *App) !void {
    const text = if (program.model.modal.isOpen())
        try app.allocator.dupe(u8, program.model.modal.body orelse "")
    else
        try buildInspectorBodyText(&program.model, app.allocator);
    defer app.allocator.free(text);

    try copyToClipboard(app.allocator, text);
    try program.model.setNotification(
        app.allocator,
        .success,
        "copied selection to clipboard",
        @intCast(@max(std.time.milliTimestamp(), 0)),
        1800,
    );
    try program.model.logAction(app.allocator, "copied selection");
}

fn executeSubmittedInput(program: *TuiProgram, app: *App, stdin: *std.Io.Reader, line: []const u8) !bool {
    if (line.len == 0) {
        try program.model.setSidebarOutput(app.allocator, "Empty input ignored.");
        try program.model.logAction(app.allocator, "empty input ignored");
        try program.model.clearInput(app.allocator);
        try program.redraw();
        return false;
    }

    if (program.model.turn_running) {
        try program.model.setNotification(
            app.allocator,
            .warning,
            "turn already running; wait for it to finish before submitting another prompt",
            @intCast(@max(std.time.milliTimestamp(), 0)),
            2200,
        );
        try program.redraw();
        return false;
    }

    const started = try std.fmt.allocPrint(app.allocator, "run: {s}", .{
        ziggy.FormatText.previewText(line, 56),
    });
    defer app.allocator.free(started);
    try program.model.logAction(app.allocator, started);
    try program.model.history.push(app.allocator, line);
    try prompt_history_store.save(app.allocator, app.config.paths, app.cwd, program.model.history.items.items);

    const result = try executeLineInTui(program, app, stdin, line);
    defer app.allocator.free(result.output);

    if (result.background_started) {
        try program.model.clearInput(app.allocator);
        try program.redraw();
        return result.exit_requested;
    }

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
        if (try commands.tryBareSkillInvocation(app, line, .{
            .stdout = &output.writer,
            .stdin = stdin,
            .interactive = true,
        })) {
            if (app.takePendingInjectedPrompt()) |rendered| {
                defer app.allocator.free(rendered);
                try startBackgroundTurn(program, app, rendered);
                const result = try app.allocator.dupe(u8, "running in background");
                output.deinit();
                return .{ .output = result, .exit_requested = false, .background_started = true };
            }
            const result = try app.allocator.dupe(u8, "OK");
            output.deinit();
            return .{ .output = result, .exit_requested = false };
        }
        try startBackgroundTurn(program, app, line);
        const result = try app.allocator.dupe(u8, "running in background");
        output.deinit();
        return .{ .output = result, .exit_requested = false, .background_started = true };
    }

    if (app.takePendingInjectedPrompt()) |rendered| {
        defer app.allocator.free(rendered);
        try startBackgroundTurn(program, app, rendered);
        const result = try app.allocator.dupe(u8, "running in background");
        output.deinit();
        return .{ .output = result, .exit_requested = false, .background_started = true };
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

fn buildConversationPane(model: *const TuiModel, allocator: std.mem.Allocator, size: ziggy.Size) !*const ziggy.Node {
    const theme = appTheme(model.app);
    const items = try buildConversationItems(model, allocator);
    defer tui_items.freeItems(allocator, items);
    const transcript = try tui_items.buildConversationTranscript(
        allocator,
        theme,
        model.app,
        if (items.len == 0) 0 else @min(model.conversation_selected, items.len - 1),
        model.turn_running,
        model.pending_prompt,
        model.current_tool,
        model.last_error,
        model.live_assistant,
        model.status_text,
        model.actions.items.items,
    );
    defer {
        var owned = transcript;
        owned.deinit(allocator);
    }
    const follow_end = model.focus != .conversation;
    const built = try ziggy.AgentTranscript.build(allocator, transcript.messages, .{
        .title = "Conversation",
        .width = tui_layout.conversationBodyWidth(size),
        .offset = model.conversation_body_scroll,
        .viewport_height = tui_layout.conversationBodyVisibleHeight(size),
        .follow_end = follow_end,
        .theme = .{
            .style = if (model.focus == .conversation) theme.pane_active else theme.pane,
            .selected_title_style = theme.selected,
        },
    });
    const panel = built.node;
    const document = try tui_items.buildConversationDocument(
        allocator,
        theme,
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
    const resolved_scroll = if (follow_end)
        ziggy.RichDocument.followOffset(document.lines.len, tui_layout.conversationBodyVisibleHeight(size))
    else
        model.conversation_body_scroll;
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
    const theme = appTheme(model.app);
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
    return activity_main;
}

fn buildInspectorPane(model: *const TuiModel, allocator: std.mem.Allocator, size: ziggy.Size) !*const ziggy.Node {
    const theme = appTheme(model.app);
    if (model.focus == .repo) {
        return try buildRepoInspectorPane(model, allocator, size);
    }

    const source_items = switch (model.focus) {
        .activity => try buildActivityItems(model, allocator),
        else => try buildConversationItems(model, allocator),
    };
    defer tui_items.freeItems(allocator, source_items);

    if (source_items.len == 0) {
        return try buildScrollableInspectorText(allocator, theme, size, "Inspector", "No selection.", model.inspector_scroll);
    }

    const selected_index = switch (model.focus) {
        .activity => @min(model.activity_selected, source_items.len - 1),
        else => @min(model.conversation_selected, source_items.len - 1),
    };
    const selected = source_items[selected_index];
    const owned_title = try allocator.dupe(u8, selected.label);
    return try buildScrollableInspectorText(allocator, theme, size, owned_title, selected.body, model.inspector_scroll);
}

fn buildRepoPane(model: *const TuiModel, allocator: std.mem.Allocator, size: ziggy.Size) !*const ziggy.Node {
    const theme = appTheme(model.app);
    var entries_data = try model.buildRepoEntries(allocator);
    defer entries_data.deinit(allocator);
    const labels = try allocator.alloc([]const u8, entries_data.entries.len);
    defer allocator.free(labels);
    for (entries_data.entries, 0..) |entry, index| {
        const indent = try repoIndent(allocator, entry.depth);
        defer allocator.free(indent);
        labels[index] = try std.fmt.allocPrint(allocator, "{s}{s} {s}", .{
            indent,
            if (entry.is_dir) (if (entry.expanded) "-" else "+") else "*",
            entry.label,
        });
    }
    defer for (labels) |label| allocator.free(label);

    const title = try std.fmt.allocPrint(allocator, "Repo {d}/{d}", .{
        if (entries_data.entries.len == 0) 0 else @min(entries_data.entries.len, model.repo_state.tree_state.selection.cursor + 1),
        entries_data.entries.len,
    });
    const panel = try ziggy.Pane.buildSelectableList(allocator, title, labels, .{
        .selected = model.repo_state.tree_state.selection.cursor,
        .offset = model.repo_scroll,
        .focused = model.focus == .repo,
        .style = theme.pane,
        .selected_style = theme.selected_alt,
        .box_style = theme.pane_active,
        .border_style = theme.border_style,
        .title_align = .center,
        .focus = .{
            .active = model.focus == .repo,
            .focus_id = "repo",
        },
    });
    const repo_viewport = @as(usize, tui_layout.repoContentRect(size).height);
    const scrollbar = if (entries_data.entries.len > repo_viewport)
        try ziggy.Scrollbar.build(allocator, .{
            .offset = model.repo_scroll,
            .viewport = repo_viewport,
            .total = entries_data.entries.len,
            .style = theme.pane,
            .thumb_style = theme.selected_alt,
        })
    else
        try ziggy.Text.buildWithOptions(allocator, "", .{ .style = theme.pane, .wrap = .none });
    return try ziggy.HStack.buildWithWeights(allocator, &.{ panel, scrollbar }, 1, &.{ 100, 1 });
}

fn buildRepoInspectorPane(model: *const TuiModel, allocator: std.mem.Allocator, size: ziggy.Size) !*const ziggy.Node {
    const theme = appTheme(model.app);
    var entries_data = try model.buildRepoEntries(allocator);
    defer entries_data.deinit(allocator);

    if (entries_data.entries.len == 0) {
        return try buildScrollableInspectorText(allocator, theme, size, "Inspector", "Workspace is empty.", model.inspector_scroll);
    }

    const selected = entries_data.entries[@min(model.repo_state.tree_state.selection.cursor, entries_data.entries.len - 1)];
    const normalized = std.mem.trimRight(u8, selected.path, "/");
    const absolute_path = try std.fs.path.join(allocator, &.{ model.app.cwd, normalized });
    defer allocator.free(absolute_path);

    const body = if (selected.is_dir)
        try std.fmt.allocPrint(allocator,
            \\Directory
            \\
            \\path: {s}
            \\state: {s}
            \\
            \\controls:
            \\  right / enter : expand
            \\  left          : collapse / parent
            \\  click         : select
            \\  click again   : toggle folder
        , .{
            normalized,
            if (selected.expanded) "expanded" else "collapsed",
        })
    else
        try buildRepoFilePreview(allocator, absolute_path, normalized);
    defer allocator.free(body);

    return try buildScrollableInspectorText(allocator, theme, size, try allocator.dupe(u8, selected.label), body, model.inspector_scroll);
}

fn looksLikeDiff(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "@@ ") != null or
        std.mem.startsWith(u8, text, "diff --git") or
        std.mem.indexOf(u8, text, "\n+") != null or
        std.mem.indexOf(u8, text, "\n-") != null;
}

fn repoItemCount(model: *const TuiModel, allocator: std.mem.Allocator) !usize {
    var entries_data = try model.buildRepoEntries(allocator);
    defer entries_data.deinit(allocator);
    return entries_data.entries.len;
}

fn inspectorLineCount(model: *const TuiModel, allocator: std.mem.Allocator) !usize {
    const body = try buildInspectorBodyText(model, allocator);
    defer allocator.free(body);
    return tui_layout.countLines(body);
}

fn buildRepoFilePreview(allocator: std.mem.Allocator, absolute_path: []const u8, relative_path: []const u8) ![]u8 {
    const max_bytes = 8192;
    const file = std.fs.openFileAbsolute(absolute_path, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "path: {s}\n\nfailed to open file: {s}", .{ relative_path, @errorName(err) });
    };
    defer file.close();

    const bytes = file.readToEndAlloc(allocator, max_bytes) catch |err| {
        return std.fmt.allocPrint(allocator, "path: {s}\n\nfailed to read file: {s}", .{ relative_path, @errorName(err) });
    };
    defer allocator.free(bytes);

    if (!std.unicode.utf8ValidateSlice(bytes)) {
        return std.fmt.allocPrint(allocator, "path: {s}\n\nbinary or non-UTF-8 content preview is not shown.", .{relative_path});
    }

    return std.fmt.allocPrint(allocator, "path: {s}\n\n{s}", .{ relative_path, bytes });
}

fn buildInspectorBodyText(model: *const TuiModel, allocator: std.mem.Allocator) ![]u8 {
    if (model.focus == .repo) {
        var entries_data = try model.buildRepoEntries(allocator);
        defer entries_data.deinit(allocator);
        if (entries_data.entries.len == 0) return allocator.dupe(u8, "Workspace is empty.");

        const selected = entries_data.entries[@min(model.repo_state.tree_state.selection.cursor, entries_data.entries.len - 1)];
        const normalized = std.mem.trimRight(u8, selected.path, "/");
        const absolute_path = try std.fs.path.join(allocator, &.{ model.app.cwd, normalized });
        defer allocator.free(absolute_path);

        if (selected.is_dir) {
            return std.fmt.allocPrint(allocator,
                \\Directory
                \\
                \\path: {s}
                \\state: {s}
                \\
                \\controls:
                \\  right / enter : expand
                \\  left          : collapse / parent
                \\  click         : select
                \\  click again   : toggle folder
            , .{
                normalized,
                if (selected.expanded) "expanded" else "collapsed",
            });
        }
        return buildRepoFilePreview(allocator, absolute_path, normalized);
    }

    const source_items = switch (model.focus) {
        .activity => try buildActivityItems(model, allocator),
        else => try buildConversationItems(model, allocator),
    };
    defer tui_items.freeItems(allocator, source_items);
    if (source_items.len == 0) return allocator.dupe(u8, "No selection.");

    const selected_index = switch (model.focus) {
        .activity => @min(model.activity_selected, source_items.len - 1),
        else => @min(model.conversation_selected, source_items.len - 1),
    };
    return allocator.dupe(u8, source_items[selected_index].body);
}

fn buildScrollableInspectorText(
    allocator: std.mem.Allocator,
    theme: ziggy.AgentTheme,
    size: ziggy.Size,
    title: []const u8,
    body: []const u8,
    offset: usize,
) !*const ziggy.Node {
    const built = try ziggy.StaticLog.buildFromText(allocator, body, .{
        .offset = offset,
        .viewport_height = @as(usize, tui_layout.inspectorContentRect(size).height),
        .follow_end = false,
        .style = theme.pane,
    });
    const panel = try ziggy.Box.buildWithOptions(allocator, title, built.node, .{
        .style = theme.pane,
        .border_style = theme.border_style,
        .title_align = .center,
    });
    return try wrapPaneWithScrollbar(
        allocator,
        theme,
        panel,
        offset,
        @as(usize, tui_layout.inspectorContentRect(size).height),
        built.lines.len,
        theme.selected_alt,
    );
}

fn wrapPaneWithScrollbar(
    allocator: std.mem.Allocator,
    theme: ziggy.AgentTheme,
    panel: *const ziggy.Node,
    offset: usize,
    viewport: usize,
    total: usize,
    thumb_style: ziggy.Style,
) !*const ziggy.Node {
    const scrollbar = if (total > viewport)
        try ziggy.Scrollbar.build(allocator, .{
            .offset = offset,
            .viewport = viewport,
            .total = total,
            .style = theme.pane,
            .thumb_style = thumb_style,
        })
    else
        try ziggy.Text.buildWithOptions(allocator, "", .{ .style = theme.pane, .wrap = .none });
    return try ziggy.HStack.buildWithWeights(allocator, &.{ panel, scrollbar }, 1, &.{ 100, 1 });
}

fn repoIndent(allocator: std.mem.Allocator, depth: usize) ![]u8 {
    const out = try allocator.alloc(u8, depth * 2);
    @memset(out, ' ');
    return out;
}

fn modelPickerItems(provider_name: []const u8) []const []const u8 {
    if (std.mem.eql(u8, provider_name, "openrouter")) {
        return &.{
            "openrouter/free",
            "openai/gpt-4o-mini",
            "openai/gpt-4.1-mini",
            "anthropic/claude-3.7-sonnet",
            "google/gemini-2.5-flash",
            "meta-llama/llama-4-maverick",
        };
    }
    if (std.mem.eql(u8, provider_name, "anthropic")) {
        return &.{
            "claude-sonnet-4-20250514",
            "claude-3-7-sonnet-20250219",
            "claude-3-5-haiku-20241022",
        };
    }
    if (std.mem.eql(u8, provider_name, "gemini")) {
        return &.{
            "gemini-2.5-flash",
            "gemini-2.5-pro",
            "gemini-2.0-flash",
        };
    }
    if (std.mem.eql(u8, provider_name, "groq")) {
        return &.{
            "llama-3.3-70b-versatile",
            "llama-3.1-8b-instant",
            "mixtral-8x7b-32768",
        };
    }
    if (std.mem.eql(u8, provider_name, "cerebras")) {
        return &.{
            "gpt-oss-120b",
            "llama3.1-70b",
            "qwen-3-32b",
        };
    }
    if (std.mem.eql(u8, provider_name, "huggingface")) {
        return &.{
            "openai/gpt-oss-120b:cerebras",
            "meta-llama/Llama-3.3-70B-Instruct:fireworks-ai",
            "Qwen/Qwen3-32B:novita",
        };
    }
    return &.{
        "gpt-4o-mini",
        "gpt-4.1-mini",
        "gpt-4.1",
        "o4-mini",
    };
}

fn paneFocusString(focus: PaneFocus) []const u8 {
    return switch (focus) {
        .conversation => "conversation",
        .activity => "activity",
        .repo => "repo",
        .input => "input",
    };
}

fn paneFocusId(focus: PaneFocus) ?[]const u8 {
    return paneFocusString(focus);
}

fn paneFocusFromId(id: []const u8) PaneFocus {
    if (std.mem.eql(u8, id, "conversation")) return .conversation;
    if (std.mem.eql(u8, id, "activity")) return .activity;
    if (std.mem.eql(u8, id, "repo")) return .repo;
    return .input;
}

test "sidebar toggle normalizes focus when right pane is hidden" {
    var model = TuiModel{
        .app = undefined,
        .editor = undefined,
        .focus = .activity,
        .sidebar_output = "",
        .status_text = "",
    };

    model.toggleRightSidebar();
    try std.testing.expect(!model.show_right_sidebar);
    try std.testing.expectEqual(PaneFocus.conversation, model.focus);
}

test "sidebar toggle keeps input focus when right pane is hidden" {
    var model = TuiModel{
        .app = undefined,
        .editor = undefined,
        .focus = .input,
        .sidebar_output = "",
        .status_text = "",
    };

    model.toggleRightSidebar();
    try std.testing.expect(!model.show_right_sidebar);
    try std.testing.expectEqual(PaneFocus.input, model.focus);
}

fn conversationItemCount(model: *const TuiModel, allocator: std.mem.Allocator) !usize {
    const items = try buildConversationItems(model, allocator);
    defer tui_items.freeItems(allocator, items);
    return items.len;
}

fn conversationBodyLineCount(model: *const TuiModel, allocator: std.mem.Allocator, size: ziggy.Size) !usize {
    const document = try tui_items.buildConversationDocument(
        allocator,
        appTheme(model.app),
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
        appTheme(model.app),
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
    try std.testing.expect(std.mem.indexOf(u8, items[1].body, "start=2 role=assistant calls=1 results=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, items[1].body, "result 1: list_files (call_1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, items[1].body, "list_files") != null);
    try std.testing.expect(std.mem.indexOf(u8, items[1].body, "follow-up: done") != null);
    try std.testing.expect(std.mem.indexOf(u8, items[1].body, "{\"path\":\".\"}") == null);
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
    try std.testing.expectEqualStrings("/mcp status", items[4].reuse.?);
    try std.testing.expectEqualStrings("/skills show pdf", items[5].reuse.?);
    try std.testing.expectEqualStrings("/", items[6].reuse.?);
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

    try std.testing.expect(std.mem.indexOf(u8, body, "## Cirebronx Help") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "`Ctrl+H`") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "`Ctrl+B`") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "`Ctrl+Y`") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "`Ctrl+X`") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "`PgUp` / `PgDn`") != null);
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

test "closeCommandPalette clears completion and slash draft in one step" {
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

    try model.insertText(std.testing.allocator, "/");
    try std.testing.expect(model.completion.visible);
    try std.testing.expect(model.palette_open);

    model.closeCommandPalette(std.testing.allocator);

    try std.testing.expect(!model.palette_open);
    try std.testing.expect(!model.completion.visible);
    try std.testing.expectEqualStrings("", model.editor.value);
}

test "closeModal clears hidden command palette state too" {
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

    try model.insertText(std.testing.allocator, "/");
    try std.testing.expect(model.completion.visible);
    try std.testing.expect(model.palette_open);

    try model.openHelpModal(std.testing.allocator);
    try std.testing.expect(model.modal.isOpen());

    model.closeModal(std.testing.allocator);

    try std.testing.expect(!model.modal.isOpen());
    try std.testing.expect(!model.palette_open);
    try std.testing.expect(!model.completion.visible);
    try std.testing.expectEqualStrings("", model.editor.value);
}

test "dismissTransientUi clears modal picker and command palette together" {
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

    try model.insertText(std.testing.allocator, "/");
    try std.testing.expect(model.completion.visible);
    try std.testing.expect(model.palette_open);

    model.openPicker(.provider);
    try model.openHelpModal(std.testing.allocator);
    try std.testing.expect(model.modal.isOpen());
    try std.testing.expect(model.picker_kind != .none);

    try std.testing.expect(model.dismissTransientUi(std.testing.allocator));
    try std.testing.expect(!model.modal.isOpen());
    try std.testing.expect(model.picker_kind == .none);
    try std.testing.expect(!model.palette_open);
    try std.testing.expect(!model.completion.visible);
    try std.testing.expectEqualStrings("", model.editor.value);
}

test "readEvent parses arrow page keys and editor control sequences" {
    var reader = std.Io.Reader.fixed("\x1b[D\x1b[Z\x1b[5~\x1b[3~\x1bb\x1b[1;5C\x01\x05\x0a\x0b\x12\x15\x17\x04");

    const left = (try tui_input.readEventAlloc(std.testing.allocator, &reader, null)).?;
    try std.testing.expect(left == .key);
    try std.testing.expect(left.key == .left);

    const back_tab = (try tui_input.readEventAlloc(std.testing.allocator, &reader, null)).?;
    try std.testing.expect(back_tab == .key);
    try std.testing.expect(back_tab.key == .back_tab);

    const page_up = (try tui_input.readEventAlloc(std.testing.allocator, &reader, null)).?;
    try std.testing.expect(page_up == .key);
    try std.testing.expect(page_up.key == .page_up);

    const delete = (try tui_input.readEventAlloc(std.testing.allocator, &reader, null)).?;
    try std.testing.expect(delete == .key);
    try std.testing.expect(delete.key == .delete);

    const word_left = (try tui_input.readEventAlloc(std.testing.allocator, &reader, null)).?;
    try std.testing.expect(word_left == .key);
    try std.testing.expect(word_left.key == .word_left);

    const word_right = (try tui_input.readEventAlloc(std.testing.allocator, &reader, null)).?;
    try std.testing.expect(word_right == .key);
    try std.testing.expect(word_right.key == .word_right);

    const ctrl_a = (try tui_input.readEventAlloc(std.testing.allocator, &reader, null)).?;
    try std.testing.expect(ctrl_a == .key);
    try std.testing.expect(ctrl_a.key == .ctrl_a);

    const ctrl_e = (try tui_input.readEventAlloc(std.testing.allocator, &reader, null)).?;
    try std.testing.expect(ctrl_e == .key);
    try std.testing.expect(ctrl_e.key == .ctrl_e);

    const ctrl_j = (try tui_input.readEventAlloc(std.testing.allocator, &reader, null)).?;
    try std.testing.expect(ctrl_j == .key);
    try std.testing.expect(ctrl_j.key == .ctrl_j);

    const ctrl_k = (try tui_input.readEventAlloc(std.testing.allocator, &reader, null)).?;
    try std.testing.expect(ctrl_k == .key);
    try std.testing.expect(ctrl_k.key == .ctrl_k);

    const ctrl_r = (try tui_input.readEventAlloc(std.testing.allocator, &reader, null)).?;
    try std.testing.expect(ctrl_r == .key);
    try std.testing.expect(ctrl_r.key == .ctrl_r);

    const ctrl_u = (try tui_input.readEventAlloc(std.testing.allocator, &reader, null)).?;
    try std.testing.expect(ctrl_u == .key);
    try std.testing.expect(ctrl_u.key == .ctrl_u);

    const ctrl_w = (try tui_input.readEventAlloc(std.testing.allocator, &reader, null)).?;
    try std.testing.expect(ctrl_w == .key);
    try std.testing.expect(ctrl_w.key == .ctrl_w);

    const ctrl_d = (try tui_input.readEventAlloc(std.testing.allocator, &reader, null)).?;
    try std.testing.expect(ctrl_d == .key);
    try std.testing.expect(ctrl_d.key == .ctrl_d);
}

test "readEventAlloc parses bracketed paste" {
    var reader = std.Io.Reader.fixed("\x1b[200~hello\nworld\x1b[201~");
    const event = (try tui_input.readEventAlloc(std.testing.allocator, &reader, null)).?;
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

test "computePaletteLayout stays valid for tiny terminal heights" {
    const h3 = computePaletteLayout(3, 20);
    try std.testing.expect(h3.margin_top >= 1);
    try std.testing.expect(h3.margin_bottom >= 1);

    const h4 = computePaletteLayout(4, 20);
    try std.testing.expect(h4.margin_top >= 1);
    try std.testing.expect(h4.margin_bottom >= 1);

    const h8 = computePaletteLayout(8, 50);
    try std.testing.expect(h8.margin_top >= 1);
    try std.testing.expect(h8.margin_bottom >= 1);
}
