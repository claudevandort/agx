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

    // Check if --task <id> was given
    var task_filter: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--task") or std.mem.eql(u8, args[i], "-t")) {
            i += 1;
            if (i < args.len) task_filter = args[i];
        }
    }

    if (task_filter) |filter| {
        // Show single task detail
        try showTaskByFilter(&ctx.store, alloc, filter, stdout, stderr);
    } else {
        // Show all active tasks
        try showAllTasks(&ctx.store, alloc, stdout);
    }

    try stdout.flush();
}

fn showAllTasks(store: *agx.Store, alloc: Allocator, stdout: *std.Io.Writer) !void {
    var task_buf: [32]agx.Task = undefined;
    const tasks = try store.getAllTasks(&task_buf);

    if (tasks.len == 0) {
        try stdout.print("No tasks found. Use 'agx spawn --task \"...\"' to create one.\n", .{});
        return;
    }

    for (tasks) |task| {
        const short = task.id.short(6);
        try stdout.print("{s}  {s:<12} {s:<20} base:{s}\n", .{ &short, task.status.toStr(), task.description, task.base_branch });
        try showExplorations(store, alloc, task.id, stdout);
    }
}

fn showTaskByFilter(store: *agx.Store, alloc: Allocator, filter: []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var task_buf: [32]agx.Task = undefined;
    const tasks = try store.getAllTasks(&task_buf);

    for (tasks) |task| {
        const encoded = task.id.encode();
        if (filter.len > encoded.len) continue;
        if (std.ascii.eqlIgnoreCase(filter, encoded[0..filter.len])) {
            const short = task.id.short(6);
            try stdout.print("Task {s}: {s}\n", .{ &short, task.description });
            try stdout.print("  Status: {s}\n", .{task.status.toStr()});
            try stdout.print("  Base:   {s} ({s})\n", .{ task.base_branch, task.base_commit[0..@min(8, task.base_commit.len)] });
            try stdout.print("\n", .{});

            try showExplorations(store, alloc, task.id, stdout);
            return;
        }
    }

    try stderr.print("error: no task matching '{s}'\n", .{filter});
    try stderr.flush();
    std.process.exit(1);
}

fn showExplorations(store: *agx.Store, _: Allocator, task_id: agx.Ulid, stdout: *std.Io.Writer) !void {
    var buf: [32]agx.Exploration = undefined;
    const exps = try store.getExplorationsByTask(task_id, &buf);

    for (exps) |exp| {
        const status_icon: []const u8 = switch (exp.status) {
            .active => "●",
            .done => "✓",
            .kept => "★",
            .archived => "▪",
            .discarded => "✗",
        };

        try stdout.print("  {s} [{d}] {s:<12} {s}\n", .{
            status_icon,
            exp.index,
            exp.status.toStr(),
            exp.worktree_path,
        });

        if (exp.approach) |approach| {
            try stdout.print("           approach: {s}\n", .{approach});
        }
        if (exp.summary) |summary| {
            try stdout.print("           summary:  {s}\n", .{summary});
        }
    }
}
