const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");
const CliContext = @import("cli_common.zig").CliContext;

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    _ = args;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var ctx = CliContext.open(aa, stderr);
    defer ctx.deinit();

    // Find all resolved tasks
    var id_buf: [64]agx.Ulid = undefined;
    const resolved_ids = try ctx.store.getResolvedTaskIds(&id_buf);

    var cleaned_tasks: u32 = 0;
    var cleaned_worktrees: u32 = 0;
    var cleaned_branches: u32 = 0;

    for (resolved_ids) |task_id| {

        // Get explorations for this task
        var exp_buf: [32]agx.Exploration = undefined;
        const exps = ctx.store.getExplorationsByTask(task_id, &exp_buf) catch continue;

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
        const worktree_dir = std.fmt.allocPrint(aa, "{s}/agx/worktrees/{s}", .{ ctx.git_dir, &task_short }) catch continue;
        std.fs.cwd().deleteTree(worktree_dir) catch {};

        // Remove evidence directory
        for (exps) |e| {
            const exp_id_str = e.id.encode();
            const evidence_dir = std.fmt.allocPrint(aa, "{s}/agx/evidence/{s}", .{ ctx.git_dir, &exp_id_str }) catch continue;
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
