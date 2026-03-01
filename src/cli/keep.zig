const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");
const CliContext = @import("cli_common.zig").CliContext;
const commit_message = @import("commit_message.zig");

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var index_str: ?[]const u8 = null;
    var strategy_str: ?[]const u8 = null;
    var no_cleanup = false;
    var no_context = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--strategy") or std.mem.eql(u8, args[i], "-s")) {
            i += 1;
            if (i < args.len) strategy_str = args[i];
        } else if (std.mem.eql(u8, args[i], "--no-cleanup")) {
            no_cleanup = true;
        } else if (std.mem.eql(u8, args[i], "--no-context")) {
            no_context = true;
        } else if (index_str == null and args[i].len > 0 and args[i][0] != '-') {
            index_str = args[i];
        }
    }

    if (index_str == null) {
        try stderr.print("error: task index required\n", .{});
        try stderr.print("usage: agx exploration pick <index> [--strategy merge|rebase|squash|cherry-pick] [--no-context] [--no-cleanup]\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    const index = std.fmt.parseInt(u32, index_str.?, 10) catch {
        try stderr.print("error: invalid task index '{s}'\n", .{index_str.?});
        try stderr.flush();
        std.process.exit(1);
    };

    const strategy: agx.GitCli.MergeStrategy = if (strategy_str) |s| blk: {
        if (std.mem.eql(u8, s, "merge")) break :blk .merge;
        if (std.mem.eql(u8, s, "rebase")) break :blk .rebase;
        if (std.mem.eql(u8, s, "squash")) break :blk .squash;
        if (std.mem.eql(u8, s, "cherry-pick") or std.mem.eql(u8, s, "cherry_pick")) break :blk .cherry_pick;
        try stderr.print("error: unknown strategy '{s}' (valid: merge, rebase, squash, cherry-pick)\n", .{s});
        try stderr.flush();
        std.process.exit(1);
    } else .merge;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var ctx = CliContext.open(aa, stderr);
    defer ctx.deinit();

    const g = ctx.store.getActiveGoal() catch {
        try stderr.print("error: no active goal found\n", .{});
        try stderr.flush();
        std.process.exit(1);
        unreachable;
    };

    const t = ctx.store.getTaskByIndex(g.id, index) catch {
        try stderr.print("error: task [{d}] not found\n", .{index});
        try stderr.flush();
        std.process.exit(1);
        unreachable;
    };

    // Checkout base branch
    try stdout.print("Checking out {s}...\n", .{g.base_branch});
    ctx.git.checkout(g.base_branch) catch {
        try stderr.print("error: could not checkout base branch '{s}'\n", .{g.base_branch});
        try stderr.flush();
        std.process.exit(1);
    };

    // Merge task branch
    const strategy_name: []const u8 = if (strategy_str) |s| s else "merge";
    try stdout.print("Merging [{d}] via {s}...\n", .{ index, strategy_name });
    ctx.git.mergeBranch(t.branch_name, strategy) catch {
        try stderr.print("error: merge failed — resolve conflicts manually\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    // Amend merge commit with enriched message
    if (commit_message.buildExplorationPickMessage(aa, &ctx.store, g, t, index)) |msg| {
        ctx.git.commitAmend(msg) catch {
            try stderr.print("warning: could not amend commit with enriched message\n", .{});
            try stderr.flush();
        };
    } else |_| {}

    // Update DB: mark task as kept, resolve goal
    try ctx.store.updateTaskStatus(t.id, .kept, null);
    try ctx.store.updateGoalStatus(g.id, .resolved, t.id);

    // Export context (default on, skip with --no-context)
    // Use a copy with updated status so the export reflects the resolved state
    if (!no_context) {
        var resolved_goal = g;
        resolved_goal.status = .resolved;
        if (agx.context_export.exportGoalContext(
            aa,
            &ctx.store,
            &resolved_goal,
            ".agx/context",
        )) |context_dir| {
            try stdout.print("Context exported to {s}\n", .{context_dir});
        } else |err| {
            try stderr.print("warning: could not export context: {s}\n", .{@errorName(err)});
            try stderr.flush();
        }
    }

    // Cleanup worktrees unless --no-cleanup
    if (!no_cleanup) {
        try stdout.print("Cleaning up worktrees...\n", .{});
        var task_buf: [32]agx.Task = undefined;
        const all_tasks = try ctx.store.getTasksByGoal(g.id, &task_buf);

        for (all_tasks) |e| {
            ctx.git.removeWorktree(e.worktree_path) catch {};
            // Delete non-kept branches
            if (e.index != index) {
                ctx.git.deleteBranch(e.branch_name) catch {};
                try ctx.store.updateTaskStatus(e.id, .discarded, null);
            }
        }
    }

    try stdout.print("Task [{d}] merged into {s}.\n", .{ index, g.base_branch });
    try stdout.flush();
}
