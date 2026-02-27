const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");
const CliContext = @import("cli_common.zig").CliContext;

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var ctx = CliContext.open(alloc, stderr);
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
    // Get all active tasks - query directly
    var stmt = try store.db.prepare(
        "SELECT id, description, base_branch, status, created_at FROM tasks ORDER BY created_at DESC",
    );
    defer stmt.finalize();

    var found = false;
    while (true) {
        const result = try stmt.step();
        if (result != .row) break;
        found = true;

        const id_blob = stmt.columnBlob(0);
        const desc = stmt.columnText(1) orelse "(no description)";
        const branch = stmt.columnText(2) orelse "?";
        const status = stmt.columnText(3) orelse "?";

        var short: [6]u8 = undefined;
        if (id_blob) |blob| {
            if (blob.len >= 16) {
                const ulid = agx.Ulid{ .bytes = blob[0..16].* };
                short = ulid.short(6);
            } else {
                short = "??????".*;
            }
        } else {
            short = "??????".*;
        }

        try stdout.print("{s}  {s:<12} {s:<20} base:{s}\n", .{ &short, status, desc, branch });

        // Show explorations for this task
        if (id_blob) |blob| {
            if (blob.len >= 16) {
                const task_id = agx.Ulid{ .bytes = blob[0..16].* };
                try showExplorations(store, alloc, task_id, stdout);
            }
        }
    }

    if (!found) {
        try stdout.print("No tasks found. Use 'agx spawn --task \"...\"' to create one.\n", .{});
    }
}

fn showTaskByFilter(store: *agx.Store, alloc: Allocator, filter: []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    // Try to find task by short ID prefix
    var stmt = try store.db.prepare(
        "SELECT id, description, base_commit, base_branch, status, created_at FROM tasks ORDER BY created_at DESC",
    );
    defer stmt.finalize();

    while (true) {
        const result = try stmt.step();
        if (result != .row) break;

        const id_blob = stmt.columnBlob(0) orelse continue;
        if (id_blob.len < 16) continue;

        const ulid = agx.Ulid{ .bytes = id_blob[0..16].* };
        const encoded = ulid.encode();

        // Check if filter matches prefix of encoded ULID (case-insensitive)
        if (filter.len > encoded.len) continue;
        if (std.ascii.eqlIgnoreCase(filter, encoded[0..filter.len])) {
            const desc = stmt.columnText(1) orelse "(no description)";
            const base_commit = stmt.columnText(2) orelse "?";
            const base_branch = stmt.columnText(3) orelse "?";
            const status = stmt.columnText(4) orelse "?";

            const short = ulid.short(6);
            try stdout.print("Task {s}: {s}\n", .{ &short, desc });
            try stdout.print("  Status: {s}\n", .{status});
            try stdout.print("  Base:   {s} ({s})\n", .{ base_branch, base_commit[0..@min(8, base_commit.len)] });
            try stdout.print("\n", .{});

            try showExplorations(store, alloc, ulid, stdout);
            return;
        }
    }

    try stderr.print("error: no task matching '{s}'\n", .{filter});
    try stderr.flush();
    std.process.exit(1);
}

fn showExplorations(store: *agx.Store, alloc: Allocator, task_id: agx.Ulid, stdout: *std.Io.Writer) !void {
    var buf: [32]agx.Exploration = undefined;
    const exps = try store.getExplorationsByTask(task_id, &buf);
    defer agx.Exploration.deinitSlice(alloc, exps);

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
