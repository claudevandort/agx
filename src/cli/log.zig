const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");
const CliContext = @import("cli_common.zig").CliContext;
const JsonWriter = agx.json_writer.JsonWriter;

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
        try stderr.print("error: task index required\n", .{});
        try stderr.print("usage: agx exploration log <index> [--kind <type>] [--limit N] [--json]\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    const index = std.fmt.parseInt(u32, index_str.?, 10) catch {
        try stderr.print("error: invalid task index '{s}'\n", .{index_str.?});
        try stderr.flush();
        std.process.exit(1);
    };

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var ctx = CliContext.open(aa, stderr);
    defer ctx.deinit();

    // Find the active goal
    const g = ctx.store.getActiveGoal() catch {
        try stderr.print("error: no active goal found\n", .{});
        try stderr.flush();
        std.process.exit(1);
        unreachable;
    };

    // Find task by index
    const t = ctx.store.getTaskByIndex(g.id, index) catch {
        try stderr.print("error: task [{d}] not found\n", .{index});
        try stderr.flush();
        std.process.exit(1);
        unreachable;
    };

    // Get sessions for this task
    var sess_buf: [8]agx.Session = undefined;
    const sessions = try ctx.store.getSessionsByTask(t.id, &sess_buf);

    if (sessions.len == 0) {
        try stdout.print("No sessions found for task [{d}]\n", .{index});
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
        const events = try ctx.store.getEventsBySession(sess.id, kind_filter, ev_buf[0..buf_limit]);

        for (events) |ev| {
            if (format_json) {
                if (!first_json) try stdout.print(",", .{});
                first_json = false;
                var jw = JsonWriter.init(stdout);
                try jw.beginObject();
                try jw.stringField("kind", ev.kind.toStr());
                try jw.intField("created_at", ev.created_at);
                if (ev.data) |d| {
                    // data is expected to be a raw JSON value, but validate
                    // it starts with { or [ or " — otherwise escape as string
                    if (d.len > 0 and (d[0] == '{' or d[0] == '[' or d[0] == '"')) {
                        try jw.rawField("data", d);
                    } else {
                        try jw.stringField("data", d);
                    }
                }
                try jw.endObject();
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
        try stdout.print("No events recorded for task [{d}]", .{index});
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
        const truncated = data[0..max_len];
        // Truncate at newline
        const preview = if (std.mem.indexOfScalar(u8, truncated, '\n')) |nl| truncated[0..nl] else truncated;
        try w.print("  {s}", .{preview});
        if (data.len > 80) try w.print("...", .{});
    }
    try w.print("\n", .{});
}
