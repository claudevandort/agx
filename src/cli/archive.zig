const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");

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

    const git = agx.GitCli.init(alloc, null);
    const git_dir = git.gitDir() catch {
        try stderr.print("error: not a git repository\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };
    defer alloc.free(git_dir);

    const db_path = try std.fmt.allocPrintSentinel(alloc, "{s}/agx/db.sqlite3", .{git_dir}, 0);
    defer alloc.free(db_path);

    var store = try agx.Store.init(alloc, db_path);
    defer store.deinit();

    const task = store.getActiveTask() catch {
        try stderr.print("error: no active task found\n", .{});
        try stderr.flush();
        std.process.exit(1);
        unreachable;
    };
    defer {
        alloc.free(task.description);
        alloc.free(task.base_commit);
        alloc.free(task.base_branch);
    }

    if (archive_all) {
        var exp_buf: [32]agx.Exploration = undefined;
        const exps = try store.getExplorationsByTask(task.id, &exp_buf);
        defer for (exps) |e| {
            alloc.free(e.worktree_path);
            alloc.free(e.branch_name);
            if (e.approach) |a| alloc.free(a);
            if (e.summary) |s| alloc.free(s);
        };

        var archived: u32 = 0;
        for (exps) |e| {
            if (e.status == .kept or e.status == .archived or e.status == .discarded) continue;
            archiveOne(alloc, &store, &git, &task, &e, stdout, stderr) catch continue;
            archived += 1;
        }
        try stdout.print("{d} exploration(s) archived.\n", .{archived});
    } else {
        const index = std.fmt.parseInt(u32, index_str.?, 10) catch {
            try stderr.print("error: invalid exploration index '{s}'\n", .{index_str.?});
            try stderr.flush();
            std.process.exit(1);
        };

        const exp = store.getExplorationByIndex(task.id, index) catch {
            try stderr.print("error: exploration [{d}] not found\n", .{index});
            try stderr.flush();
            std.process.exit(1);
            unreachable;
        };
        defer {
            alloc.free(exp.worktree_path);
            alloc.free(exp.branch_name);
            if (exp.approach) |a| alloc.free(a);
            if (exp.summary) |s| alloc.free(s);
        }

        if (exp.status == .kept) {
            try stderr.print("error: exploration [{d}] is already kept\n", .{index});
            try stderr.flush();
            std.process.exit(1);
        }

        try archiveOne(alloc, &store, &git, &task, &exp, stdout, stderr);
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

    // Export context to .agx/context/{task_id}/
    const task_id_str = task.id.encode();
    const context_dir = try std.fmt.allocPrint(alloc, ".agx/context/{s}", .{&task_id_str});
    defer alloc.free(context_dir);
    std.fs.cwd().makePath(context_dir) catch {};

    // Write summary for this exploration
    const summary_path = try std.fmt.allocPrint(alloc, "{s}/exploration_{d}.md", .{ context_dir, exp.index });
    defer alloc.free(summary_path);

    const summary_file = std.fs.cwd().createFile(summary_path, .{}) catch |err| {
        try stdout.print("warning: could not write context for [{d}]: {s}\n", .{ exp.index, @errorName(err) });
        return;
    };
    defer summary_file.close();

    var file_buf: [2048]u8 = undefined;
    var fw = summary_file.writer(&file_buf);
    const w = &fw.interface;

    try w.print("# Exploration [{d}]\n\n", .{exp.index});
    try w.print("- Status: {s}\n", .{exp.status.toStr()});
    try w.print("- Branch: {s}\n", .{exp.branch_name});
    if (exp.approach) |approach| {
        try w.print("- Approach: {s}\n", .{approach});
    }
    if (exp.summary) |summary| {
        try w.print("- Summary: {s}\n", .{summary});
    }

    // Write evidence summary
    var ev_buf: [64]agx.Evidence = undefined;
    const evidence = store.getEvidenceByExploration(exp.id, &ev_buf) catch &[_]agx.Evidence{};
    defer for (evidence) |ev| {
        if (ev.hash) |h| alloc.free(h);
        if (ev.summary) |s| alloc.free(s);
        if (ev.raw_path) |p| alloc.free(p);
    };

    if (evidence.len > 0) {
        try w.print("\n## Evidence\n\n", .{});
        for (evidence) |ev| {
            try w.print("- [{s}] {s}", .{ ev.status.toStr(), ev.kind.toStr() });
            if (ev.summary) |s| {
                try w.print(": {s}", .{s});
            }
            try w.print("\n", .{});
        }
    }

    try w.flush();

    // Remove worktree but keep branch (as orphan ref for future reference)
    git.removeWorktree(exp.worktree_path) catch {};

    // Update status
    try store.updateExplorationStatus(exp.id, .archived, null);

    try stdout.print("Archived [{d}] — context saved to {s}\n", .{ exp.index, summary_path });
}
