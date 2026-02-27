const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var format_str: ?[]const u8 = null;
    var diff_a: ?[]const u8 = null;
    var diff_b: ?[]const u8 = null;
    var task_filter: ?[]const u8 = null;

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
        } else if (std.mem.eql(u8, args[i], "--task") or std.mem.eql(u8, args[i], "-t")) {
            i += 1;
            if (i < args.len) task_filter = args[i];
        }
    }

    const git = agx.GitCli.init(alloc, null);
    const git_dir = git.gitDir() catch {
        try stderr.print("error: not a git repository\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };
    defer alloc.free(git_dir);

    const db_path = try std.fmt.allocPrintSentinel(alloc, "{s}/agx/db.sqlite3", .{git_dir}, 0);
    defer alloc.free(db_path);

    std.fs.cwd().access(db_path[0..db_path.len :0], .{}) catch {
        try stderr.print("error: agx not initialized. Run 'agx init' first.\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    var store = try agx.Store.init(alloc, db_path);
    defer store.deinit();

    // Find the task
    const task = blk: {
        if (task_filter) |filter| {
            break :blk findTaskByFilter(&store, filter) catch {
                try stderr.print("error: no task matching '{s}'\n", .{filter});
                try stderr.flush();
                std.process.exit(1);
                unreachable;
            };
        } else {
            break :blk store.getActiveTask() catch {
                try stderr.print("error: no active task found\n", .{});
                try stderr.print("hint: use --task <id> to specify a task\n", .{});
                try stderr.flush();
                std.process.exit(1);
                unreachable;
            };
        }
    };
    defer {
        alloc.free(task.description);
        alloc.free(task.base_commit);
        alloc.free(task.base_branch);
    }

    // Get explorations
    var exp_buf: [32]agx.Exploration = undefined;
    const explorations = try store.getExplorationsByTask(task.id, &exp_buf);
    defer for (explorations) |exp| {
        alloc.free(exp.worktree_path);
        alloc.free(exp.branch_name);
        if (exp.approach) |a| alloc.free(a);
        if (exp.summary) |s| alloc.free(s);
    };

    if (explorations.len == 0) {
        try stderr.print("error: no explorations found for this task\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    // Handle --diff mode (three-way diff between two explorations)
    if (diff_a != null and diff_b != null) {
        try runDiff(alloc, &store, &task, explorations, diff_a.?, diff_b.?, stdout, stderr);
        return;
    } else if (diff_a != null or diff_b != null) {
        try stderr.print("error: --diff requires two exploration indices (e.g., --diff 1 2)\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    // Collect metrics
    const metrics = agx.compare_metrics.collectMetrics(alloc, &store, &task, explorations) catch |err| {
        try stderr.print("error: failed to collect metrics: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
        unreachable;
    };
    defer {
        for (metrics) |*m| m.deinit(alloc);
        alloc.free(metrics);
    }

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

    try agx.compare_renderer.render(stdout, metrics, format, task.description);
    try stdout.flush();
}

fn runDiff(
    alloc: Allocator,
    store: *agx.Store,
    task: *const agx.Task,
    explorations: []const agx.Exploration,
    a_str: []const u8,
    b_str: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    const idx_a = std.fmt.parseInt(u32, a_str, 10) catch {
        try stderr.print("error: invalid exploration index '{s}'\n", .{a_str});
        try stderr.flush();
        std.process.exit(1);
    };
    const idx_b = std.fmt.parseInt(u32, b_str, 10) catch {
        try stderr.print("error: invalid exploration index '{s}'\n", .{b_str});
        try stderr.flush();
        std.process.exit(1);
    };

    _ = store;

    // Find the explorations by index
    var exp_a: ?agx.Exploration = null;
    var exp_b: ?agx.Exploration = null;
    for (explorations) |exp| {
        if (exp.index == idx_a) exp_a = exp;
        if (exp.index == idx_b) exp_b = exp;
    }

    if (exp_a == null) {
        try stderr.print("error: exploration [{d}] not found\n", .{idx_a});
        try stderr.flush();
        std.process.exit(1);
    }
    if (exp_b == null) {
        try stderr.print("error: exploration [{d}] not found\n", .{idx_b});
        try stderr.flush();
        std.process.exit(1);
    }

    try stdout.print("Three-way diff: base ({s}) vs [{d}] vs [{d}]\n\n", .{
        task.base_commit[0..@min(8, task.base_commit.len)],
        idx_a,
        idx_b,
    });

    // Use git diff between the two exploration branches
    const git = agx.GitCli.init(alloc, null);
    const diff_output = git.diffThreeWay(task.base_commit, exp_a.?.branch_name, exp_b.?.branch_name) catch {
        try stderr.print("error: could not compute diff between explorations\n", .{});
        try stderr.flush();
        std.process.exit(1);
        unreachable;
    };
    defer alloc.free(diff_output);

    if (diff_output.len == 0) {
        try stdout.print("No differences between exploration [{d}] and [{d}]\n", .{ idx_a, idx_b });
    } else {
        try stdout.print("{s}", .{diff_output});
    }
    try stdout.flush();
}

fn findTaskByFilter(store: *agx.Store, filter: []const u8) !agx.Task {
    // Search tasks by ULID prefix
    var stmt = try store.db.prepare(
        "SELECT id FROM tasks ORDER BY created_at DESC",
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
            return store.getTask(ulid);
        }
    }

    return error.NotFound;
}
