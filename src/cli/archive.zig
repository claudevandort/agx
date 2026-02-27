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
        try stderr.print("error: exploration index required (or --all)\n", .{});
        try stderr.print("usage: agx archive <index> | agx archive --all\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    var ctx = CliContext.open(alloc, stderr);
    defer ctx.deinit();

    const task = ctx.store.getActiveTask() catch {
        try stderr.print("error: no active task found\n", .{});
        try stderr.flush();
        std.process.exit(1);
        unreachable;
    };
    defer task.deinit(alloc);

    if (archive_all) {
        var exp_buf: [32]agx.Exploration = undefined;
        const exps = try ctx.store.getExplorationsByTask(task.id, &exp_buf);
        defer agx.Exploration.deinitSlice(alloc, exps);

        var archived: u32 = 0;
        for (exps) |e| {
            if (e.status == .kept or e.status == .archived or e.status == .discarded) continue;
            archiveOne(alloc, &ctx.store, &ctx.git, &task, &e, stdout, stderr) catch continue;
            archived += 1;
        }
        try stdout.print("{d} exploration(s) archived.\n", .{archived});
    } else {
        const index = std.fmt.parseInt(u32, index_str.?, 10) catch {
            try stderr.print("error: invalid exploration index '{s}'\n", .{index_str.?});
            try stderr.flush();
            std.process.exit(1);
        };

        const exp = ctx.store.getExplorationByIndex(task.id, index) catch {
            try stderr.print("error: exploration [{d}] not found\n", .{index});
            try stderr.flush();
            std.process.exit(1);
            unreachable;
        };
        defer exp.deinit(alloc);

        if (exp.status == .kept) {
            try stderr.print("error: exploration [{d}] is already kept\n", .{index});
            try stderr.flush();
            std.process.exit(1);
        }

        try archiveOne(alloc, &ctx.store, &ctx.git, &task, &exp, stdout, stderr);
    }

    try stdout.flush();
}

fn archiveOne(
    alloc: Allocator,
    store: *agx.Store,
    git: *const agx.GitCli,
    task: *const agx.Task,
    exp: *const agx.Exploration,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    _ = stderr;

    // Export context using the export module
    const context_dir = agx.context_export.exportExplorationContext(
        alloc,
        store,
        task,
        exp,
        ".agx/context",
    ) catch |err| {
        try stdout.print("warning: could not export context for [{d}]: {s}\n", .{ exp.index, @errorName(err) });
        return;
    };
    defer alloc.free(context_dir);

    // Remove worktree but keep branch (as orphan ref for future reference)
    git.removeWorktree(exp.worktree_path) catch {};

    // Update status
    try store.updateExplorationStatus(exp.id, .archived, null);

    try stdout.print("Archived [{d}] — context saved to {s}\n", .{ exp.index, context_dir });
}
