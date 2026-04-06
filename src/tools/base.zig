const permissions = @import("../core/permissions.zig");

pub const ToolKind = enum {
    read_file,
    list_files,
    grep,
    list_skills,
    git_status,
    git_worktree_list,
    git_worktree_add,
    shell_command,
    write_file,
    edit_file,
    create_task_note,
};

pub const ToolSpec = struct {
    kind: ToolKind,
    name: []const u8,
    description: []const u8,
    schema_json: []const u8,
    permission: permissions.PermissionClass,
};
