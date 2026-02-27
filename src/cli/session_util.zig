const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");

pub const SessionInfo = struct {
    exploration_id_str: []u8,
    session_id_str: []u8,
    task_id_str: []u8,
    index: u32,
};

pub const WorktreeContext = struct {
    info: SessionInfo,
    db_path: [:0]u8,
    common_dir: []u8,
};

/// Detect the current worktree context: read .agx-session, find the store.
/// Prints errors to stderr and returns error on failure.
pub fn getWorktreeContext(alloc: Allocator, stderr: *std.Io.Writer) !WorktreeContext {
    const info = findSessionFile(alloc) catch {
        try stderr.print("error: not inside an agx exploration worktree\n", .{});
        try stderr.print("hint: run this command from within a spawned worktree\n", .{});
        try stderr.flush();
        return error.NotInWorktree;
    };

    const git = agx.GitCli.init(alloc, null);

    const common_dir = git.gitCommonDir() catch {
        try stderr.print("error: could not determine git common dir\n", .{});
        try stderr.flush();
        return error.GitError;
    };

    const db_path = try std.fmt.allocPrintSentinel(alloc, "{s}/agx/db.sqlite3", .{common_dir}, 0);

    return .{
        .info = info,
        .db_path = db_path,
        .common_dir = common_dir,
    };
}

pub fn findSessionFile(alloc: Allocator) !SessionInfo {
    const content = std.fs.cwd().readFileAlloc(alloc, ".agx-session", 4096) catch {
        return error.NotInWorktree;
    };
    defer alloc.free(content);

    return parseSessionFile(alloc, content);
}

fn parseSessionFile(alloc: Allocator, content: []const u8) !SessionInfo {
    var exploration_id: ?[]const u8 = null;
    var session_id: ?[]const u8 = null;
    var task_id: ?[]const u8 = null;
    var index: u32 = 0;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "exploration_id=")) {
            exploration_id = line["exploration_id=".len..];
        } else if (std.mem.startsWith(u8, line, "session_id=")) {
            session_id = line["session_id=".len..];
        } else if (std.mem.startsWith(u8, line, "task_id=")) {
            task_id = line["task_id=".len..];
        } else if (std.mem.startsWith(u8, line, "index=")) {
            index = std.fmt.parseInt(u32, line["index=".len..], 10) catch 0;
        }
    }

    if (exploration_id == null or session_id == null or task_id == null) {
        return error.InvalidSessionFile;
    }

    return .{
        .exploration_id_str = try alloc.dupe(u8, exploration_id.?),
        .session_id_str = try alloc.dupe(u8, session_id.?),
        .task_id_str = try alloc.dupe(u8, task_id.?),
        .index = index,
    };
}
