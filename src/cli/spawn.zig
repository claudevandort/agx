const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");
const Ulid = agx.Ulid;
const CliContext = @import("cli_common.zig").CliContext;

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    // Parse arguments
    var task_desc: ?[]const u8 = null;
    var count: u32 = 2;
    var base_ref: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--task") or std.mem.eql(u8, args[i], "-t")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --task requires a value\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            task_desc = args[i];
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

    if (task_desc == null) {
        try stderr.print("error: --task is required\n", .{});
        try stderr.print("usage: agx spawn --task \"description\" [--count N] [--base ref]\n", .{});
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

    // Create task
    const now = std.time.milliTimestamp();
    const task_id = Ulid.new();
    const task_short = task_id.short(6);

    try ctx.store.insertTask(.{
        .id = task_id,
        .description = task_desc.?,
        .base_commit = base_commit,
        .base_branch = base_branch,
        .status = .active,
        .resolved_exploration_id = null,
        .batch_id = null,
        .created_at = now,
        .updated_at = now,
    });

    try stdout.print("Task {s}: {s}\n", .{ &task_short, task_desc.? });
    try stdout.print("Base: {s} ({s})\n", .{ base_branch, base_commit[0..@min(8, base_commit.len)] });
    try stdout.print("\n", .{});

    // Create explorations with worktrees
    const worktree_base = try std.fmt.allocPrint(aa, "{s}/agx/worktrees/{s}", .{ ctx.git_dir, &task_short });
    std.fs.cwd().makePath(worktree_base) catch {};

    var idx: u32 = 1;
    while (idx <= count) : (idx += 1) {
        const exp_id = Ulid.new();
        const branch_name = try std.fmt.allocPrint(aa, "agx/{s}/{d}", .{ &task_short, idx });
        const worktree_path = try std.fmt.allocPrint(aa, "{s}/{d}", .{ worktree_base, idx });

        // Create worktree (also creates branch)
        ctx.git.addWorktree(worktree_path, branch_name) catch |err| {
            try stderr.print("error: could not create worktree {d}: {s}\n", .{ idx, @errorName(err) });
            try stderr.flush();
            std.process.exit(1);
        };

        try ctx.store.insertExploration(.{
            .id = exp_id,
            .task_id = task_id,
            .index = idx,
            .worktree_path = worktree_path,
            .branch_name = branch_name,
            .status = .active,
            .approach = null,
            .summary = null,
            .created_at = now,
            .updated_at = now,
        });

        // Create a session for this exploration
        const session_id = Ulid.new();
        try ctx.store.insertSession(.{
            .id = session_id,
            .exploration_id = exp_id,
            .agent_type = null,
            .model_version = null,
            .environment_fingerprint = null,
            .initial_prompt = task_desc,
            .exit_reason = null,
            .started_at = now,
            .ended_at = null,
        });

        // Write .agx-session discovery file in worktree
        const session_file_path = try std.fmt.allocPrint(aa, "{s}/.agx-session", .{worktree_path});

        const session_id_str = session_id.encode();
        const exp_id_str = exp_id.encode();
        const task_id_str = task_id.encode();

        const session_file = try std.fs.cwd().createFile(session_file_path, .{});
        defer session_file.close();

        var file_buf: [512]u8 = undefined;
        var file_writer = session_file.writer(&file_buf);
        try file_writer.interface.print("session_id={s}\nexploration_id={s}\ntask_id={s}\nindex={d}\n", .{
            &session_id_str,
            &exp_id_str,
            &task_id_str,
            idx,
        });
        try file_writer.interface.flush();

        try stdout.print("  [{d}] {s}\n", .{ idx, worktree_path });
    }

    try stdout.print("\n{d} explorations spawned. Start agents in each worktree.\n", .{count});
    try stdout.flush();
}
