const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");
const CliContext = @import("cli_common.zig").CliContext;

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var ctx = CliContext.open(aa, stderr);
    defer ctx.deinit();

    // Check if --goal <id> was given
    var goal_filter: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--goal") or std.mem.eql(u8, args[i], "-g")) {
            i += 1;
            if (i < args.len) goal_filter = args[i];
        }
    }

    if (goal_filter) |filter| {
        // Show single goal detail
        try showGoalByFilter(&ctx.store, alloc, filter, stdout, stderr);
    } else {
        // Show all active goals
        try showAllGoals(&ctx.store, alloc, stdout);
    }

    try stdout.flush();
}

fn showAllGoals(store: *agx.Store, _: Allocator, stdout: *std.Io.Writer) !void {
    var goal_buf: [32]agx.Goal = undefined;
    const goals = try store.getAllGoals(&goal_buf);

    if (goals.len == 0) {
        try stdout.print("No goals found. Use 'agx exploration create --goal \"...\"' to create one.\n", .{});
        return;
    }

    for (goals) |g| {
        const short = g.id.short(6);
        try stdout.print("{s}  {s:<12} {s:<20} base:{s}\n", .{ &short, g.status.toStr(), g.description, g.base_branch });
        try showTasks(store, g.id, stdout);
    }
}

fn showGoalByFilter(store: *agx.Store, _: Allocator, filter: []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var goal_buf: [32]agx.Goal = undefined;
    const goals = try store.getAllGoals(&goal_buf);

    for (goals) |g| {
        const encoded = g.id.encode();
        if (filter.len > encoded.len) continue;
        if (std.ascii.eqlIgnoreCase(filter, encoded[0..filter.len])) {
            const short = g.id.short(6);
            try stdout.print("Goal {s}: {s}\n", .{ &short, g.description });
            try stdout.print("  Status: {s}\n", .{g.status.toStr()});
            try stdout.print("  Base:   {s} ({s})\n", .{ g.base_branch, g.base_commit[0..@min(8, g.base_commit.len)] });
            try stdout.print("\n", .{});

            try showTasks(store, g.id, stdout);
            return;
        }
    }

    try stderr.print("error: no goal matching '{s}'\n", .{filter});
    try stderr.flush();
    std.process.exit(1);
}

fn showTasks(store: *agx.Store, goal_id: agx.Ulid, stdout: *std.Io.Writer) !void {
    var buf: [32]agx.Task = undefined;
    const tasks = try store.getTasksByGoal(goal_id, &buf);

    for (tasks) |t| {
        const status_icon: []const u8 = switch (t.status) {
            .active => "●",
            .done => "✓",
            .kept => "★",
            .archived => "▪",
            .discarded => "✗",
        };

        try stdout.print("  {s} [{d}] {s:<12} {s}\n", .{
            status_icon,
            t.index,
            t.status.toStr(),
            t.worktree_path,
        });

        if (t.approach) |approach| {
            try stdout.print("           approach: {s}\n", .{approach});
        }
        if (t.summary) |summary| {
            try stdout.print("           summary:  {s}\n", .{summary});
        }
    }
}
