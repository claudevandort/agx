const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");
const Ulid = agx.Ulid;
const CliContext = @import("cli_common.zig").CliContext;

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    // Parse arguments
    var goal_desc: ?[]const u8 = null;
    var count: u32 = 2;
    var base_ref: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--goal") or std.mem.eql(u8, args[i], "-g")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --goal requires a value\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            goal_desc = args[i];
        } else if (std.mem.eql(u8, args[i], "--count") or std.mem.eql(u8, args[i], "-n")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --count requires a value\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            count = std.fmt.parseInt(u32, args[i], 10) catch {
                try stderr.print("error: --count must be a number\n", .{});
                try stderr.flush();
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, args[i], "--base")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --base requires a value\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            base_ref = args[i];
        }
    }

    if (goal_desc == null) {
        try stderr.print("error: --goal is required\n", .{});
        try stderr.print("usage: agx exploration create --goal \"description\" [--count N] [--base ref]\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var ctx = CliContext.open(aa, stderr);
    defer ctx.deinit();

    // Resolve base commit
    const base_commit = if (base_ref) |ref|
        try ctx.git.resolveRef(ref)
    else
        try ctx.git.headCommit();

    const base_branch = ctx.git.currentBranch() catch try aa.dupe(u8, "HEAD");

    // Create goal
    const now = std.time.milliTimestamp();
    const goal_id = Ulid.new();
    const goal_short = goal_id.short(6);

    try ctx.store.insertGoal(.{
        .id = goal_id,
        .description = goal_desc.?,
        .base_commit = base_commit,
        .base_branch = base_branch,
        .status = .active,
        .resolved_task_id = null,
        .dispatch_id = null,
        .created_at = now,
        .updated_at = now,
    });

    try stdout.print("Goal {s}: {s}\n", .{ &goal_short, goal_desc.? });
    try stdout.print("Base: {s} ({s})\n", .{ base_branch, base_commit[0..@min(8, base_commit.len)] });
    try stdout.print("\n", .{});

    // Create tasks with worktrees
    const worktree_base = try std.fmt.allocPrint(aa, "{s}/agx/worktrees/{s}", .{ ctx.git_dir, &goal_short });
    std.fs.cwd().makePath(worktree_base) catch {};

    var idx: u32 = 1;
    while (idx <= count) : (idx += 1) {
        const task_id = Ulid.new();
        const branch_name = try std.fmt.allocPrint(aa, "agx/{s}/{d}", .{ &goal_short, idx });
        const worktree_path = try std.fmt.allocPrint(aa, "{s}/{d}", .{ worktree_base, idx });

        // Create worktree (also creates branch)
        ctx.git.addWorktree(worktree_path, branch_name) catch |err| {
            try stderr.print("error: could not create worktree {d}: {s}\n", .{ idx, @errorName(err) });
            try stderr.flush();
            std.process.exit(1);
        };

        try ctx.store.insertTask(.{
            .id = task_id,
            .goal_id = goal_id,
            .index = idx,
            .worktree_path = worktree_path,
            .branch_name = branch_name,
            .status = .active,
            .approach = null,
            .summary = null,
            .created_at = now,
            .updated_at = now,
        });

        // Create a session for this task
        const session_id = Ulid.new();
        try ctx.store.insertSession(.{
            .id = session_id,
            .task_id = task_id,
            .agent_type = null,
            .model_version = null,
            .environment_fingerprint = null,
            .initial_prompt = goal_desc,
            .exit_reason = null,
            .started_at = now,
            .ended_at = null,
        });

        // Write .agx-session discovery file in worktree
        const session_file_path = try std.fmt.allocPrint(aa, "{s}/.agx-session", .{worktree_path});

        const session_id_str = session_id.encode();
        const task_id_str = task_id.encode();
        const goal_id_str = goal_id.encode();

        const session_file = try std.fs.cwd().createFile(session_file_path, .{});
        defer session_file.close();

        var file_buf: [512]u8 = undefined;
        var file_writer = session_file.writer(&file_buf);
        try file_writer.interface.print("session_id={s}\ntask_id={s}\ngoal_id={s}\nindex={d}\n", .{
            &session_id_str,
            &task_id_str,
            &goal_id_str,
            idx,
        });
        try file_writer.interface.flush();

        try stdout.print("  [{d}] {s}\n", .{ idx, worktree_path });
    }

    try stdout.print("\n{d} tasks spawned. Start agents in each worktree.\n", .{count});
    try stdout.flush();
}
