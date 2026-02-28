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

    var cleaned_tasks: u32 = 0;
    var cleaned_worktrees: u32 = 0;
    var cleaned_branches: u32 = 0;

    // Find all resolved tasks (non-batch explorations)
    var id_buf: [64]agx.Ulid = undefined;
    const resolved_ids = try ctx.store.getResolvedTaskIds(&id_buf);

    for (resolved_ids) |task_id| {
        var exp_buf: [32]agx.Exploration = undefined;
        const exps = ctx.store.getExplorationsByTask(task_id, &exp_buf) catch continue;

        for (exps) |e| {
            cleaned_worktrees += cleanWorktree(&ctx.git, e.worktree_path);
            if (e.status != .kept) {
                cleaned_branches += cleanBranch(&ctx.git, e.branch_name);
            }
            cleanEvidence(aa, ctx.git_dir, e.id);
        }

        // Remove the worktree directory structure
        const task_short = task_id.short(6);
        const worktree_dir = std.fmt.allocPrint(aa, "{s}/agx/worktrees/{s}", .{ ctx.git_dir, &task_short }) catch continue;
        std.fs.cwd().deleteTree(worktree_dir) catch {};

        cleaned_tasks += 1;
    }

    // Clean up terminal-state batches (completed, failed, abandoned)
    var batch_buf: [32]agx.Batch = undefined;
    const all_batches = ctx.store.getAllBatches(&batch_buf) catch &[_]agx.Batch{};
    var cleaned_batches: u32 = 0;

    for (all_batches) |batch| {
        switch (batch.status) {
            .completed, .failed, .abandoned => {},
            .active, .merging => continue,
        }

        const batch_short = batch.id.short(6);

        // Collect task and exploration IDs, clean worktrees/branches
        var task_buf: [64]agx.Task = undefined;
        const tasks = ctx.store.getTasksByBatch(batch.id, &task_buf) catch continue;

        var exp_ids = std.ArrayList(agx.Ulid).empty;
        var session_ids = std.ArrayList(agx.Ulid).empty;

        for (tasks) |t| {
            var exp_buf: [8]agx.Exploration = undefined;
            const exps = ctx.store.getExplorationsByTask(t.id, &exp_buf) catch continue;

            for (exps) |e| {
                exp_ids.append(aa, e.id) catch continue;
                cleaned_worktrees += cleanWorktree(&ctx.git, e.worktree_path);
                if (e.status != .kept) {
                    cleaned_branches += cleanBranch(&ctx.git, e.branch_name);
                }
                cleanEvidence(aa, ctx.git_dir, e.id);

                // Collect session IDs for FK-safe deletion
                var sess_buf: [16]agx.Session = undefined;
                const sessions = ctx.store.getSessionsByExploration(e.id, &sess_buf) catch continue;
                for (sessions) |s| {
                    session_ids.append(aa, s.id) catch continue;
                }
            }
        }

        // Remove the batch worktree directory structure
        const batch_dir = std.fmt.allocPrint(aa, "{s}/agx/worktrees/batch-{s}", .{ ctx.git_dir, &batch_short }) catch continue;
        std.fs.cwd().deleteTree(batch_dir) catch {};

        // Remove the batch and all child records from the database
        ctx.store.deleteBatch(batch.id, exp_ids.items, session_ids.items) catch {};

        cleaned_batches += 1;
    }

    if (cleaned_tasks == 0 and cleaned_batches == 0) {
        try stdout.print("Nothing to clean.\n", .{});
    } else {
        if (cleaned_tasks > 0) {
            try stdout.print("Cleaned {d} resolved task(s).\n", .{cleaned_tasks});
        }
        if (cleaned_batches > 0) {
            try stdout.print("Cleaned {d} batch(es).\n", .{cleaned_batches});
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
    // Check if the branch exists by trying to resolve it
    git.branchExists(name) catch return 0;
    git.deleteBranch(name) catch return 0;
    return 1;
}

/// Remove evidence directory for an exploration.
fn cleanEvidence(aa: Allocator, git_dir: []const u8, exp_id: agx.Ulid) void {
    const exp_id_str = exp_id.encode();
    const evidence_dir = std.fmt.allocPrint(aa, "{s}/agx/evidence/{s}", .{ git_dir, &exp_id_str }) catch return;
    std.fs.cwd().deleteTree(evidence_dir) catch {};
}
