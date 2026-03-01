const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");
const CliContext = @import("cli_common.zig").CliContext;

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var format_str: ?[]const u8 = null;
    var diff_a: ?[]const u8 = null;
    var diff_b: ?[]const u8 = null;
    var goal_filter: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--format") or std.mem.eql(u8, args[i], "-f")) {
            i += 1;
            if (i < args.len) format_str = args[i];
        } else if (std.mem.eql(u8, args[i], "--diff") or std.mem.eql(u8, args[i], "-d")) {
            i += 1;
            if (i < args.len) diff_a = args[i];
            i += 1;
            if (i < args.len) diff_b = args[i];
        } else if (std.mem.eql(u8, args[i], "--goal") or std.mem.eql(u8, args[i], "-g")) {
            i += 1;
            if (i < args.len) goal_filter = args[i];
        }
    }

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var ctx = CliContext.open(aa, stderr);
    defer ctx.deinit();

    // Find the goal
    const g = blk: {
        if (goal_filter) |filter| {
            break :blk findGoalByFilter(&ctx.store, filter) catch {
                try stderr.print("error: no goal matching '{s}'\n", .{filter});
                try stderr.flush();
                std.process.exit(1);
                unreachable;
            };
        } else {
            break :blk ctx.store.getActiveGoal() catch {
                try stderr.print("error: no active goal found\n", .{});
                try stderr.print("hint: use --goal <id> to specify a goal\n", .{});
                try stderr.flush();
                std.process.exit(1);
                unreachable;
            };
        }
    };

    // Get tasks
    var task_buf: [32]agx.Task = undefined;
    const tasks = try ctx.store.getTasksByGoal(g.id, &task_buf);

    if (tasks.len == 0) {
        try stderr.print("error: no tasks found for this goal\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    // Handle --diff mode (three-way diff between two tasks)
    if (diff_a != null and diff_b != null) {
        try runDiff(alloc, &ctx.store, &g, tasks, diff_a.?, diff_b.?, stdout, stderr);
        return;
    } else if (diff_a != null or diff_b != null) {
        try stderr.print("error: --diff requires two task indices (e.g., --diff 1 2)\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    // Collect metrics
    const metrics = agx.compare_metrics.collectMetrics(aa, &ctx.store, &g, tasks) catch |err| {
        try stderr.print("error: failed to collect metrics: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
        unreachable;
    };

    // Render
    const format = if (format_str) |fs|
        agx.compare_renderer.Format.fromStr(fs) catch {
            try stderr.print("error: unknown format '{s}' (valid: table, json)\n", .{fs});
            try stderr.flush();
            std.process.exit(1);
            unreachable;
        }
    else
        .table;

    try agx.compare_renderer.render(aa, stdout, metrics, format, g.description);
    try stdout.flush();
}

fn runDiff(
    alloc: Allocator,
    store: *agx.Store,
    g: *const agx.Goal,
    tasks: []const agx.Task,
    a_str: []const u8,
    b_str: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    const idx_a = std.fmt.parseInt(u32, a_str, 10) catch {
        try stderr.print("error: invalid task index '{s}'\n", .{a_str});
        try stderr.flush();
        std.process.exit(1);
    };
    const idx_b = std.fmt.parseInt(u32, b_str, 10) catch {
        try stderr.print("error: invalid task index '{s}'\n", .{b_str});
        try stderr.flush();
        std.process.exit(1);
    };

    _ = store;

    // Find the tasks by index
    var task_a: ?agx.Task = null;
    var task_b: ?agx.Task = null;
    for (tasks) |t| {
        if (t.index == idx_a) task_a = t;
        if (t.index == idx_b) task_b = t;
    }

    if (task_a == null) {
        try stderr.print("error: task [{d}] not found\n", .{idx_a});
        try stderr.flush();
        std.process.exit(1);
    }
    if (task_b == null) {
        try stderr.print("error: task [{d}] not found\n", .{idx_b});
        try stderr.flush();
        std.process.exit(1);
    }

    try stdout.print("Three-way diff: base ({s}) vs [{d}] vs [{d}]\n\n", .{
        g.base_commit[0..@min(8, g.base_commit.len)],
        idx_a,
        idx_b,
    });

    // Use git diff between the two task branches
    const git = agx.GitCli.init(alloc, null);
    const diff_output = git.diffThreeWay(g.base_commit, task_a.?.branch_name, task_b.?.branch_name) catch {
        try stderr.print("error: could not compute diff between tasks\n", .{});
        try stderr.flush();
        std.process.exit(1);
        unreachable;
    };

    if (diff_output.len == 0) {
        try stdout.print("No differences between task [{d}] and [{d}]\n", .{ idx_a, idx_b });
    } else {
        try stdout.print("{s}", .{diff_output});
    }
    try stdout.flush();
}

fn findGoalByFilter(store: *agx.Store, filter: []const u8) !agx.Goal {
    // Search goals by ULID prefix
    var stmt = try store.db.prepare(
        "SELECT id FROM goals ORDER BY created_at DESC",
    );
    defer stmt.finalize();

    while (true) {
        const result = try stmt.step();
        if (result != .row) break;

        const id_blob = stmt.columnBlob(0) orelse continue;
        if (id_blob.len < 16) continue;

        const ulid = agx.Ulid{ .bytes = id_blob[0..16].* };
        const encoded = ulid.encode();

        if (filter.len <= encoded.len and std.ascii.eqlIgnoreCase(filter, encoded[0..filter.len])) {
            return store.getGoal(ulid);
        }
    }

    return error.NotFound;
}
