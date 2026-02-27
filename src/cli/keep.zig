const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");
const CliContext = @import("cli_common.zig").CliContext;

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var index_str: ?[]const u8 = null;
    var strategy_str: ?[]const u8 = null;
    var no_cleanup = false;
    var preserve_context = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--strategy") or std.mem.eql(u8, args[i], "-s")) {
            i += 1;
            if (i < args.len) strategy_str = args[i];
        } else if (std.mem.eql(u8, args[i], "--no-cleanup")) {
            no_cleanup = true;
        } else if (std.mem.eql(u8, args[i], "--preserve-context")) {
            preserve_context = true;
        } else if (index_str == null and args[i].len > 0 and args[i][0] != '-') {
            index_str = args[i];
        }
    }

    if (index_str == null) {
        try stderr.print("error: exploration index required\n", .{});
        try stderr.print("usage: agx keep <index> [--strategy merge|rebase|squash|cherry-pick] [--preserve-context] [--no-cleanup]\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    const index = std.fmt.parseInt(u32, index_str.?, 10) catch {
        try stderr.print("error: invalid exploration index '{s}'\n", .{index_str.?});
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

    var ctx = CliContext.open(alloc, stderr);
    defer ctx.deinit();

    const task = ctx.store.getActiveTask() catch {
        try stderr.print("error: no active task found\n", .{});
        try stderr.flush();
        std.process.exit(1);
        unreachable;
    };
    defer task.deinit(alloc);

    const exp = ctx.store.getExplorationByIndex(task.id, index) catch {
        try stderr.print("error: exploration [{d}] not found\n", .{index});
        try stderr.flush();
        std.process.exit(1);
        unreachable;
    };
    defer exp.deinit(alloc);

    // Checkout base branch
    try stdout.print("Checking out {s}...\n", .{task.base_branch});
    ctx.git.checkout(task.base_branch) catch {
        try stderr.print("error: could not checkout base branch '{s}'\n", .{task.base_branch});
        try stderr.flush();
        std.process.exit(1);
    };

    // Merge exploration branch
    const strategy_name: []const u8 = if (strategy_str) |s| s else "merge";
    try stdout.print("Merging [{d}] via {s}...\n", .{ index, strategy_name });
    ctx.git.mergeBranch(exp.branch_name, strategy) catch {
        try stderr.print("error: merge failed — resolve conflicts manually\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    // Add commit trailers
    var sess_buf: [8]agx.Session = undefined;
    const sessions = ctx.store.getSessionsByExploration(exp.id, &sess_buf) catch &[_]agx.Session{};
    defer agx.Session.deinitSlice(alloc, sessions);

    const task_short = task.id.short(6);

    // Build trailers dynamically
    var trailer_count: usize = 2; // AGX-Task + AGX-Exploration always
    if (sessions.len > 0 and sessions[0].agent_type != null) trailer_count += 1;
    if (sessions.len > 0 and sessions[0].model_version != null) trailer_count += 1;

    const trailers = try alloc.alloc([2][]const u8, trailer_count);
    defer alloc.free(trailers);

    var ti: usize = 0;
    trailers[ti] = .{ "AGX-Task", &task_short };
    ti += 1;

    var idx_buf: [16]u8 = undefined;
    const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{index}) catch "?";
    trailers[ti] = .{ "AGX-Exploration", idx_str };
    ti += 1;

    if (sessions.len > 0) {
        if (sessions[0].agent_type) |agent| {
            trailers[ti] = .{ "AGX-Agent", agent };
            ti += 1;
        }
        if (sessions[0].model_version) |model| {
            trailers[ti] = .{ "AGX-Model", model };
            ti += 1;
        }
    }

    ctx.git.addTrailers(trailers[0..ti]) catch {
        try stderr.print("warning: could not add commit trailers\n", .{});
        try stderr.flush();
    };

    // Update DB: mark exploration as kept, resolve task
    try ctx.store.updateExplorationStatus(exp.id, .kept, null);
    try ctx.store.updateTaskStatus(task.id, .resolved, exp.id);

    // Export context if requested
    if (preserve_context) {
        if (agx.context_export.exportTaskContext(
            alloc,
            &ctx.store,
            &task,
            ".agx/context",
        )) |context_dir| {
            try stdout.print("Context exported to {s}\n", .{context_dir});
            alloc.free(context_dir);
        } else |err| {
            try stderr.print("warning: could not export context: {s}\n", .{@errorName(err)});
            try stderr.flush();
        }
    }

    // Cleanup worktrees unless --no-cleanup
    if (!no_cleanup) {
        try stdout.print("Cleaning up worktrees...\n", .{});
        var exp_buf: [32]agx.Exploration = undefined;
        const all_exps = try ctx.store.getExplorationsByTask(task.id, &exp_buf);
        defer agx.Exploration.deinitSlice(alloc, all_exps);

        for (all_exps) |e| {
            ctx.git.removeWorktree(e.worktree_path) catch {};
            // Delete non-kept branches
            if (e.index != index) {
                ctx.git.deleteBranch(e.branch_name) catch {};
                try ctx.store.updateExplorationStatus(e.id, .discarded, null);
            }
        }
    }

    try stdout.print("Exploration [{d}] merged into {s}.\n", .{ index, task.base_branch });
    try stdout.flush();
}
