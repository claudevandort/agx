const std = @import("std");
const Allocator = std.mem.Allocator;
const TaskMetrics = @import("metrics.zig").TaskMetrics;
const JsonWriter = @import("../util/json_writer.zig").JsonWriter;

pub const Format = enum {
    table,
    json,

    pub fn fromStr(s: []const u8) !Format {
        if (std.mem.eql(u8, s, "table")) return .table;
        if (std.mem.eql(u8, s, "json")) return .json;
        return error.InvalidFormat;
    }
};

pub fn render(
    alloc: Allocator,
    writer: *std.Io.Writer,
    metrics: []const TaskMetrics,
    format: Format,
    goal_description: []const u8,
) !void {
    switch (format) {
        .table => try renderTable(alloc, writer, metrics, goal_description),
        .json => try renderJson(writer, metrics, goal_description),
    }
}

fn renderTable(
    alloc: Allocator,
    w: *std.Io.Writer,
    metrics: []const TaskMetrics,
    goal_description: []const u8,
) !void {
    try w.print("Comparing tasks for: {s}\n", .{goal_description});
    try w.print("\n", .{});

    // Header
    try w.print("  #  Status    Files  +Lines  -Lines  Commits  Tests     Build  Errors\n", .{});
    try w.print("  ─  ──────    ─────  ──────  ──────  ───────  ─────     ─────  ──────\n", .{});

    for (metrics) |m| {
        // Status
        const status_str: []const u8 = switch (m.status) {
            .active => "active ",
            .done => "done   ",
            .kept => "kept   ",
            .archived => "archive",
            .discarded => "discard",
        };

        // Tests summary
        var test_buf: [16]u8 = undefined;
        const tests_str = blk: {
            if (m.tests_pass > 0 or m.tests_fail > 0) {
                break :blk std.fmt.bufPrint(&test_buf, "{d}P/{d}F", .{ m.tests_pass, m.tests_fail }) catch "?";
            } else {
                break :blk "  -  ";
            }
        };

        // Build summary
        const build_str: []const u8 = if (m.build_pass and !m.build_fail)
            " pass"
        else if (m.build_fail)
            " FAIL"
        else
            "  -  ";

        try w.print("  {d}  {s}   {d:>4}  {d:>5}+  {d:>5}-  {d:>6}   {s:<8}  {s}  {d:>5}\n", .{
            m.index,
            status_str,
            m.files_changed,
            m.lines_added,
            m.lines_removed,
            m.commit_count,
            tests_str,
            build_str,
            m.error_count,
        });
    }

    // Approach / summary section
    try w.print("\n", .{});
    for (metrics) |m| {
        try w.print("  [{d}]", .{m.index});
        if (m.agent_type) |agent| {
            try w.print(" ({s}", .{agent});
            if (m.model_version) |model| {
                try w.print("/{s}", .{model});
            }
            try w.print(")", .{});
        }
        if (m.ended_at) |end| {
            const elapsed_ms = end - m.started_at;
            var dur_buf: [32]u8 = undefined;
            try w.print(" {s}", .{fmtDuration(&dur_buf, elapsed_ms)});
        }
        try w.print("\n", .{});
        if (m.approach) |approach| {
            try w.print("      approach: {s}\n", .{approach});
        }
        if (m.summary) |summary| {
            try w.print("      summary:  {s}\n", .{summary});
        }
    }

    // File overlap matrix
    if (metrics.len > 1) {
        try renderFileOverlap(alloc, w, metrics);
    }
}

fn renderFileOverlap(alloc: Allocator, w: *std.Io.Writer, metrics: []const TaskMetrics) !void {
    // Collect all unique files
    var all_files = std.StringHashMap(void).init(alloc);
    defer all_files.deinit();

    for (metrics) |m| {
        for (m.changed_files) |f| {
            try all_files.put(f, {});
        }
    }

    if (all_files.count() == 0) return;

    try w.print("\n  File overlap:\n", .{});

    // For each file, show which explorations touched it
    var it = all_files.keyIterator();
    while (it.next()) |key| {
        const file = key.*;
        try w.print("    {s}  ", .{file});
        for (metrics) |m| {
            var found = false;
            for (m.changed_files) |f| {
                if (std.mem.eql(u8, f, file)) {
                    found = true;
                    break;
                }
            }
            if (found) {
                try w.print("[{d}]", .{m.index});
            } else {
                try w.print("   ", .{});
            }
        }
        try w.print("\n", .{});
    }
}

fn renderJson(
    w: *std.Io.Writer,
    metrics: []const TaskMetrics,
    goal_description: []const u8,
) !void {
    var jw = JsonWriter.init(w);
    try jw.beginObject();
    try jw.stringField("goal", goal_description);
    try jw.arrayField("tasks");

    for (metrics) |m| {
        try jw.beginObjectValue();
        try jw.uintField("index", m.index);
        try jw.stringField("status", m.status.toStr());
        try jw.uintField("files_changed", m.files_changed);
        try jw.uintField("files_created", m.files_created);
        try jw.uintField("files_deleted", m.files_deleted);
        try jw.uintField("lines_added", m.lines_added);
        try jw.uintField("lines_removed", m.lines_removed);
        try jw.uintField("commit_count", m.commit_count);
        try jw.uintField("tests_pass", m.tests_pass);
        try jw.uintField("tests_fail", m.tests_fail);
        try jw.boolField("build_pass", m.build_pass);
        try jw.boolField("build_fail", m.build_fail);
        try jw.uintField("error_count", m.error_count);
        try jw.optionalStringField("approach", m.approach);
        try jw.optionalStringField("summary", m.summary);
        try jw.optionalStringField("agent_type", m.agent_type);
        try jw.optionalStringField("model_version", m.model_version);
        try jw.arrayField("changed_files");
        for (m.changed_files) |f| {
            try jw.stringValue(f);
        }
        try jw.endArray();
        try jw.endObject();
    }

    try jw.endArray();
    try jw.endObject();
    try w.print("\n", .{});
}

fn fmtDuration(buf: *[32]u8, ms: i64) []const u8 {
    if (ms < 0) return "?";
    const secs = @divTrunc(ms, 1000);
    if (secs < 60) {
        return std.fmt.bufPrint(buf, "{d}s", .{secs}) catch "?";
    }
    const mins = @divTrunc(secs, 60);
    const rem_secs = @rem(secs, 60);
    if (mins < 60) {
        return std.fmt.bufPrint(buf, "{d}m{d}s", .{ mins, rem_secs }) catch "?";
    }
    const hours = @divTrunc(mins, 60);
    const rem_mins = @rem(mins, 60);
    return std.fmt.bufPrint(buf, "{d}h{d}m", .{ hours, rem_mins }) catch "?";
}
