const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");
const CliContext = @import("cli_common.zig").CliContext;
const GitCli = agx.git.GitCli;

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    _ = args;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var ctx = CliContext.open(aa, stderr);
    defer ctx.deinit();

    var cleaned_goals: u32 = 0;
    var cleaned_worktrees: u32 = 0;
    var cleaned_branches: u32 = 0;

    // Find all resolved goals (non-dispatch tasks)
    var id_buf: [64]agx.Ulid = undefined;
    const resolved_ids = try ctx.store.getResolvedGoalIds(&id_buf);

    for (resolved_ids) |goal_id| {
        var task_buf: [32]agx.Task = undefined;
        const tasks = ctx.store.getTasksByGoal(goal_id, &task_buf) catch continue;

        for (tasks) |t| {
            cleaned_worktrees += cleanWorktree(&ctx.git, t.worktree_path);
            if (t.status != .kept) {
                cleaned_branches += cleanBranch(&ctx.git, t.branch_name);
            }
            cleanEvidence(aa, ctx.git_dir, t.id);
        }

        // Remove the worktree directory structure
        const goal_short = goal_id.short(6);
        const worktree_dir = std.fmt.allocPrint(aa, "{s}/agx/worktrees/{s}", .{ ctx.git_dir, &goal_short }) catch continue;
        std.fs.cwd().deleteTree(worktree_dir) catch {};

        cleaned_goals += 1;
    }

    // Clean up terminal-state dispatches (completed, failed, abandoned)
    var dispatch_buf: [32]agx.Dispatch = undefined;
    const all_dispatches = ctx.store.getAllDispatches(&dispatch_buf) catch &[_]agx.Dispatch{};
    var cleaned_dispatches: u32 = 0;

    for (all_dispatches) |d| {
        switch (d.status) {
            .completed, .failed, .abandoned => {},
            .active, .merging, .conflict => continue,
        }

        const dispatch_short = d.id.short(6);

        // Collect goal and task IDs, clean worktrees/branches
        var goal_buf: [64]agx.Goal = undefined;
        const goals = ctx.store.getGoalsByDispatch(d.id, &goal_buf) catch continue;

        var task_ids = std.ArrayList(agx.Ulid).empty;
        var session_ids = std.ArrayList(agx.Ulid).empty;

        for (goals) |g| {
            var task_buf: [8]agx.Task = undefined;
            const tasks = ctx.store.getTasksByGoal(g.id, &task_buf) catch continue;

            for (tasks) |t| {
                task_ids.append(aa, t.id) catch continue;
                cleaned_worktrees += cleanWorktree(&ctx.git, t.worktree_path);
                if (t.status != .kept) {
                    cleaned_branches += cleanBranch(&ctx.git, t.branch_name);
                }
                cleanEvidence(aa, ctx.git_dir, t.id);

                // Collect session IDs for FK-safe deletion
                var sess_buf: [16]agx.Session = undefined;
                const sessions = ctx.store.getSessionsByTask(t.id, &sess_buf) catch continue;
                for (sessions) |s| {
                    session_ids.append(aa, s.id) catch continue;
                }
            }
        }

        // Remove the dispatch worktree directory structure
        const dispatch_dir = std.fmt.allocPrint(aa, "{s}/agx/worktrees/dispatch-{s}", .{ ctx.git_dir, &dispatch_short }) catch continue;
        std.fs.cwd().deleteTree(dispatch_dir) catch {};

        // Remove the dispatch and all child records from the database
        ctx.store.deleteDispatch(d.id, task_ids.items, session_ids.items) catch {};

        cleaned_dispatches += 1;
    }

    if (cleaned_goals == 0 and cleaned_dispatches == 0) {
        try stdout.print("Nothing to clean.\n", .{});
    } else {
        if (cleaned_goals > 0) {
            try stdout.print("Cleaned {d} resolved goal(s).\n", .{cleaned_goals});
        }
        if (cleaned_dispatches > 0) {
            try stdout.print("Cleaned {d} dispatch(es).\n", .{cleaned_dispatches});
        }
        try stdout.print("Removed {d} worktrees, {d} branches.\n", .{ cleaned_worktrees, cleaned_branches });
    }
    try stdout.flush();
}

/// Remove a worktree only if it exists on disk. Returns 1 if removed, 0 if skipped.
fn cleanWorktree(git: *const GitCli, path: []const u8) u32 {
    // Check if the worktree directory exists before calling git
    std.fs.cwd().access(path, .{}) catch return 0;
    git.removeWorktree(path) catch return 0;
    return 1;
}

/// Delete a branch only if it exists. Returns 1 if deleted, 0 if skipped.
fn cleanBranch(git: *const GitCli, name: []const u8) u32 {
    if (!git.branchExists(name)) return 0;
    git.deleteBranch(name) catch return 0;
    return 1;
}

/// Remove evidence directory for a task.
fn cleanEvidence(aa: Allocator, git_dir: []const u8, task_id: agx.Ulid) void {
    const task_id_str = task_id.encode();
    const evidence_dir = std.fmt.allocPrint(aa, "{s}/agx/evidence/{s}", .{ git_dir, &task_id_str }) catch return;
    std.fs.cwd().deleteTree(evidence_dir) catch {};
}
