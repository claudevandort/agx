const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    // Parse --summary
    var summary: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--summary") or std.mem.eql(u8, args[i], "-s")) {
            i += 1;
            if (i < args.len) summary = args[i];
        }
    }

    // Detect which exploration we're in by looking for .agx-session in cwd or parents
    const session_info = findSessionFile(alloc) catch {
        try stderr.print("error: not inside an agx exploration worktree\n", .{});
        try stderr.print("hint: run this command from within a spawned worktree\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };
    defer alloc.free(session_info.exploration_id_str);
    defer alloc.free(session_info.session_id_str);
    defer alloc.free(session_info.task_id_str);

    // Open the store from the main repo
    const git = agx.GitCli.init(alloc, null);
    const git_dir = git.gitDir() catch {
        try stderr.print("error: not a git repository\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };
    defer alloc.free(git_dir);

    // The git dir from a worktree points back to the main repo's .git
    // We need to find the main .git/agx/db.sqlite3
    const common_dir = git.gitCommonDir() catch {
        try stderr.print("error: could not determine git common dir\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };
    defer alloc.free(common_dir);

    const db_path = try std.fmt.allocPrintSentinel(alloc, "{s}/agx/db.sqlite3", .{common_dir}, 0);
    defer alloc.free(db_path);

    var store = try agx.Store.init(alloc, db_path);
    defer store.deinit();

    // Find the exploration
    const exp_id = agx.Ulid.decode(session_info.exploration_id_str) catch {
        try stderr.print("error: invalid exploration ID in .agx-session\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    // Update exploration status to done
    try store.updateExplorationStatus(exp_id, .done, summary);

    // End the session
    const sess_id = agx.Ulid.decode(session_info.session_id_str) catch {
        try stderr.print("error: invalid session ID in .agx-session\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };
    try store.endSession(sess_id, .completed);

    const short = exp_id.short(6);
    try stdout.print("Exploration {s} marked as done.\n", .{&short});
    if (summary) |s| {
        try stdout.print("Summary: {s}\n", .{s});
    }
    try stdout.flush();
}

const SessionInfo = struct {
    exploration_id_str: []u8,
    session_id_str: []u8,
    task_id_str: []u8,
    index: u32,
};

fn findSessionFile(alloc: Allocator) !SessionInfo {
    // Try to read .agx-session from current directory
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
