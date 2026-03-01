const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");
const CliContext = @import("cli_common.zig").CliContext;

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var index_str: ?[]const u8 = null;
    var archive_all = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--all")) {
            archive_all = true;
        } else if (index_str == null and args[i].len > 0 and args[i][0] != '-') {
            index_str = args[i];
        }
    }

    if (index_str == null and !archive_all) {
        try stderr.print("error: task index required (or --all)\n", .{});
        try stderr.print("usage: agx exploration archive <index> | agx exploration archive --all\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

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

    if (archive_all) {
        var task_buf: [32]agx.Task = undefined;
        const tasks = try ctx.store.getTasksByGoal(g.id, &task_buf);

        var archived: u32 = 0;
        for (tasks) |t| {
            if (t.status == .kept or t.status == .archived or t.status == .discarded) continue;
            archiveOne(aa, &ctx.store, &ctx.git, &g, &t, stdout, stderr) catch continue;
            archived += 1;
        }
        try stdout.print("{d} task(s) archived.\n", .{archived});
    } else {
        const index = std.fmt.parseInt(u32, index_str.?, 10) catch {
            try stderr.print("error: invalid task index '{s}'\n", .{index_str.?});
            try stderr.flush();
            std.process.exit(1);
        };

        const t = ctx.store.getTaskByIndex(g.id, index) catch {
            try stderr.print("error: task [{d}] not found\n", .{index});
            try stderr.flush();
            std.process.exit(1);
            unreachable;
        };

        if (t.status == .kept) {
            try stderr.print("error: task [{d}] is already kept\n", .{index});
            try stderr.flush();
            std.process.exit(1);
        }

        try archiveOne(aa, &ctx.store, &ctx.git, &g, &t, stdout, stderr);
    }

    try stdout.flush();
}

fn archiveOne(
    alloc: Allocator,
    store: *agx.Store,
    git: *const agx.GitCli,
    g: *const agx.Goal,
    t: *const agx.Task,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    _ = stderr;

    // Export context using the export module
    const context_dir = agx.context_export.exportTaskContext(
        alloc,
        store,
        g,
        t,
        ".agx/context",
    ) catch |err| {
        try stdout.print("warning: could not export context for [{d}]: {s}\n", .{ t.index, @errorName(err) });
        return;
    };

    // Remove worktree but keep branch (as orphan ref for future reference)
    git.removeWorktree(t.worktree_path) catch {};

    // Update status
    try store.updateTaskStatus(t.id, .archived, null);

    try stdout.print("Archived [{d}] — context saved to {s}\n", .{ t.index, context_dir });
}
