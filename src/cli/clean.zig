const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");
const CliContext = @import("cli_common.zig").CliContext;

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    _ = args;

    var ctx = CliContext.open(alloc, stderr);
    defer ctx.deinit();

    // Find all resolved tasks
    var stmt = try ctx.store.db.prepare(
        "SELECT id FROM tasks WHERE status = 'resolved'",
    );
    defer stmt.finalize();

    var cleaned_tasks: u32 = 0;
    var cleaned_worktrees: u32 = 0;
    var cleaned_branches: u32 = 0;

    while (true) {
        const result = try stmt.step();
        if (result != .row) break;

        const id_blob = stmt.columnBlob(0) orelse continue;
        if (id_blob.len < 16) continue;
        const task_id = agx.Ulid{ .bytes = id_blob[0..16].* };

        // Get explorations for this task
        var exp_buf: [32]agx.Exploration = undefined;
        const exps = ctx.store.getExplorationsByTask(task_id, &exp_buf) catch continue;
        defer agx.Exploration.deinitSlice(alloc, exps);

        for (exps) |e| {
            // Remove worktree if it still exists
            ctx.git.removeWorktree(e.worktree_path) catch {};
            cleaned_worktrees += 1;

            // Delete branch (except kept ones — they've been merged)
            if (e.status != .kept) {
                ctx.git.deleteBranch(e.branch_name) catch {};
                cleaned_branches += 1;
            }
        }

        // Remove the worktree directory structure
        const task_short = task_id.short(6);
        const worktree_dir = std.fmt.allocPrint(alloc, "{s}/agx/worktrees/{s}", .{ ctx.git_dir, &task_short }) catch continue;
        defer alloc.free(worktree_dir);
        std.fs.cwd().deleteTree(worktree_dir) catch {};

        // Remove evidence directory
        for (exps) |e| {
            const exp_id_str = e.id.encode();
            const evidence_dir = std.fmt.allocPrint(alloc, "{s}/agx/evidence/{s}", .{ ctx.git_dir, &exp_id_str }) catch continue;
            defer alloc.free(evidence_dir);
            std.fs.cwd().deleteTree(evidence_dir) catch {};
        }

        cleaned_tasks += 1;
    }

    if (cleaned_tasks == 0) {
        try stdout.print("Nothing to clean — no resolved tasks.\n", .{});
    } else {
        try stdout.print("Cleaned {d} resolved task(s): {d} worktrees, {d} branches removed.\n", .{
            cleaned_tasks,
            cleaned_worktrees,
            cleaned_branches,
        });
    }
    try stdout.flush();
}
