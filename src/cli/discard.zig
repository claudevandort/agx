const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var index_str: ?[]const u8 = null;

    for (args) |arg| {
        if (arg.len > 0 and arg[0] != '-') {
            index_str = arg;
            break;
        }
    }

    if (index_str == null) {
        try stderr.print("error: exploration index required\n", .{});
        try stderr.print("usage: agx discard <index>\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    const index = std.fmt.parseInt(u32, index_str.?, 10) catch {
        try stderr.print("error: invalid exploration index '{s}'\n", .{index_str.?});
        try stderr.flush();
        std.process.exit(1);
    };

    const git = agx.GitCli.init(alloc, null);
    const git_dir = git.gitDir() catch {
        try stderr.print("error: not a git repository\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };
    defer alloc.free(git_dir);

    const db_path = try std.fmt.allocPrintSentinel(alloc, "{s}/agx/db.sqlite3", .{git_dir}, 0);
    defer alloc.free(db_path);

    var store = try agx.Store.init(alloc, db_path);
    defer store.deinit();

    const task = store.getActiveTask() catch {
        try stderr.print("error: no active task found\n", .{});
        try stderr.flush();
        std.process.exit(1);
        unreachable;
    };
    defer {
        alloc.free(task.description);
        alloc.free(task.base_commit);
        alloc.free(task.base_branch);
    }

    const exp = store.getExplorationByIndex(task.id, index) catch {
        try stderr.print("error: exploration [{d}] not found\n", .{index});
        try stderr.flush();
        std.process.exit(1);
        unreachable;
    };
    defer {
        alloc.free(exp.worktree_path);
        alloc.free(exp.branch_name);
        if (exp.approach) |a| alloc.free(a);
        if (exp.summary) |s| alloc.free(s);
    }

    if (exp.status == .kept) {
        try stderr.print("error: exploration [{d}] is already kept — cannot discard\n", .{index});
        try stderr.flush();
        std.process.exit(1);
    }

    // Remove worktree
    git.removeWorktree(exp.worktree_path) catch {};

    // Delete branch
    git.deleteBranch(exp.branch_name) catch {};

    // Update status
    try store.updateExplorationStatus(exp.id, .discarded, null);

    try stdout.print("Discarded exploration [{d}] — worktree and branch removed.\n", .{index});
    try stdout.flush();
}
