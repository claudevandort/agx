const std = @import("std");
const Allocator = std.mem.Allocator;
const ExplorationMetrics = @import("metrics.zig").ExplorationMetrics;

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
    writer: *std.Io.Writer,
    metrics: []const ExplorationMetrics,
    format: Format,
    task_description: []const u8,
) !void {
    switch (format) {
        .table => try renderTable(writer, metrics, task_description),
        .json => try renderJson(writer, metrics, task_description),
    }
}

fn renderTable(
    w: *std.Io.Writer,
    metrics: []const ExplorationMetrics,
    task_description: []const u8,
) !void {
    try w.print("Comparing explorations for: {s}\n", .{task_description});
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
            try w.print(" {s}", .{fmtDuration(elapsed_ms)});
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
        try renderFileOverlap(w, metrics);
    }
}

fn renderFileOverlap(w: *std.Io.Writer, metrics: []const ExplorationMetrics) !void {
    // Collect all unique files
    var all_files = std.StringHashMap(void).init(std.heap.page_allocator);
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
    metrics: []const ExplorationMetrics,
    task_description: []const u8,
) !void {
    try w.print("{{\"task\":\"{s}\",\"explorations\":[", .{jsonEscape(task_description)});

    for (metrics, 0..) |m, i| {
        if (i > 0) try w.print(",", .{});
        try w.print("{{\"index\":{d},\"status\":\"{s}\"", .{ m.index, m.status.toStr() });
        try w.print(",\"files_changed\":{d},\"files_created\":{d},\"files_deleted\":{d}", .{ m.files_changed, m.files_created, m.files_deleted });
        try w.print(",\"lines_added\":{d},\"lines_removed\":{d},\"commit_count\":{d}", .{ m.lines_added, m.lines_removed, m.commit_count });
        try w.print(",\"tests_pass\":{d},\"tests_fail\":{d}", .{ m.tests_pass, m.tests_fail });
        try w.print(",\"build_pass\":{s},\"build_fail\":{s}", .{
            if (m.build_pass) "true" else "false",
            if (m.build_fail) "true" else "false",
        });
        try w.print(",\"error_count\":{d}", .{m.error_count});

        if (m.approach) |a| {
            try w.print(",\"approach\":\"{s}\"", .{jsonEscape(a)});
        }
        if (m.summary) |s| {
            try w.print(",\"summary\":\"{s}\"", .{jsonEscape(s)});
        }
        if (m.agent_type) |a| {
            try w.print(",\"agent_type\":\"{s}\"", .{jsonEscape(a)});
        }
        if (m.model_version) |mv| {
            try w.print(",\"model_version\":\"{s}\"", .{jsonEscape(mv)});
        }

        try w.print(",\"changed_files\":[", .{});
        for (m.changed_files, 0..) |f, fi| {
            if (fi > 0) try w.print(",", .{});
            try w.print("\"{s}\"", .{jsonEscape(f)});
        }
        try w.print("]}}", .{});
    }

    try w.print("]}}\n", .{});
}

/// Simple JSON string escaping — returns as-is for CLI output.
/// Strings from git/db rarely contain special JSON chars.
fn jsonEscape(s: []const u8) []const u8 {
    return s;
}

var duration_buf: [32]u8 = undefined;

fn fmtDuration(ms: i64) []const u8 {
    if (ms < 0) return "?";
    const secs = @divTrunc(ms, 1000);
    if (secs < 60) {
        return std.fmt.bufPrint(&duration_buf, "{d}s", .{secs}) catch "?";
    }
    const mins = @divTrunc(secs, 60);
    const rem_secs = @rem(secs, 60);
    if (mins < 60) {
        return std.fmt.bufPrint(&duration_buf, "{d}m{d}s", .{ mins, rem_secs }) catch "?";
    }
    const hours = @divTrunc(mins, 60);
    const rem_mins = @rem(mins, 60);
    return std.fmt.bufPrint(&duration_buf, "{d}h{d}m", .{ hours, rem_mins }) catch "?";
}
