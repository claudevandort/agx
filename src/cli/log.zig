const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var index_str: ?[]const u8 = null;
    var kind_filter: ?[]const u8 = null;
    var limit: u32 = 100;
    var format_json = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--kind") or std.mem.eql(u8, args[i], "-k")) {
            i += 1;
            if (i < args.len) kind_filter = args[i];
        } else if (std.mem.eql(u8, args[i], "--limit") or std.mem.eql(u8, args[i], "-n")) {
            i += 1;
            if (i < args.len) {
                limit = std.fmt.parseInt(u32, args[i], 10) catch 100;
            }
        } else if (std.mem.eql(u8, args[i], "--json")) {
            format_json = true;
        } else if (index_str == null and args[i].len > 0 and args[i][0] != '-') {
            index_str = args[i];
        }
    }

    if (index_str == null) {
        try stderr.print("error: exploration index required\n", .{});
        try stderr.print("usage: agx log <index> [--kind <type>] [--limit N] [--json]\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    const index = std.fmt.parseInt(u32, index_str.?, 10) catch {
        try stderr.print("error: invalid exploration index '{s}'\n", .{index_str.?});
        try stderr.flush();
        std.process.exit(1);
    };

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

    // Find the active task
    const task = store.getActiveTask() catch {
        // Try to find any task with this exploration index
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

    // Find exploration by index
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

    // Get sessions for this exploration
    var sess_buf: [8]agx.Session = undefined;
    const sessions = try store.getSessionsByExploration(exp.id, &sess_buf);
    defer for (sessions) |sess| {
        if (sess.agent_type) |a| alloc.free(a);
        if (sess.model_version) |m| alloc.free(m);
        if (sess.environment_fingerprint) |e| alloc.free(e);
        if (sess.initial_prompt) |p| alloc.free(p);
    };

    if (sessions.len == 0) {
        try stdout.print("No sessions found for exploration [{d}]\n", .{index});
        try stdout.flush();
        return;
    }

    // Validate kind filter if provided
    if (kind_filter) |kf| {
        _ = agx.event.EventKind.fromStr(kf) catch {
            try stderr.print("error: unknown event kind '{s}'\n", .{kf});
            try stderr.print("valid: message, tool_call, tool_result, decision, file_change, git_commit, error, custom\n", .{});
            try stderr.flush();
            std.process.exit(1);
        };
    }

    if (format_json) {
        try stdout.print("[", .{});
    }

    var total_events: u32 = 0;
    var first_json = true;

    var ev_buf: [1024]agx.Event = undefined;
    const buf_limit = @min(limit, ev_buf.len);

    for (sessions) |sess| {
        const events = try store.getEventsBySession(sess.id, kind_filter, ev_buf[0..buf_limit]);
        defer for (events) |ev| {
            if (ev.data) |d| alloc.free(d);
        };

        for (events) |ev| {
            if (format_json) {
                if (!first_json) try stdout.print(",", .{});
                first_json = false;
                try stdout.print("{{\"kind\":\"{s}\",\"created_at\":{d}", .{ ev.kind.toStr(), ev.created_at });
                if (ev.data) |d| {
                    try stdout.print(",\"data\":{s}", .{d});
                }
                try stdout.print("}}", .{});
            } else {
                // Human-readable format
                try printEvent(stdout, &ev);
            }
            total_events += 1;
        }
    }

    if (format_json) {
        try stdout.print("]\n", .{});
    } else if (total_events == 0) {
        try stdout.print("No events recorded for exploration [{d}]", .{index});
        if (kind_filter) |kf| {
            try stdout.print(" (filter: {s})", .{kf});
        }
        try stdout.print("\n", .{});
    } else {
        try stdout.print("\n{d} event(s) shown", .{total_events});
        if (kind_filter) |kf| {
            try stdout.print(" (filter: {s})", .{kf});
        }
        try stdout.print("\n", .{});
    }
    try stdout.flush();
}

fn printEvent(w: *std.Io.Writer, ev: *const agx.Event) !void {
    // Format: [timestamp] KIND  data_preview
    const kind_str = ev.kind.toStr();

    // Format timestamp as relative or absolute
    const ts = ev.created_at;
    const secs = @divTrunc(ts, 1000);
    const hours = @rem(@divTrunc(secs, 3600), 24);
    const mins = @rem(@divTrunc(secs, 60), 60);
    const sec = @rem(secs, 60);

    try w.print("[{d:0>2}:{d:0>2}:{d:0>2}] {s:<12}", .{ hours, mins, sec, kind_str });

    if (ev.data) |data| {
        // Show first 80 chars of data, single line
        const max_len = @min(data.len, 80);
        var preview = data[0..max_len];
        // Truncate at newline
        if (std.mem.indexOfScalar(u8, preview, '\n')) |nl| {
            preview = preview[0..nl];
        }
        try w.print("  {s}", .{preview});
        if (data.len > 80) try w.print("...", .{});
    }
    try w.print("\n", .{});
}
