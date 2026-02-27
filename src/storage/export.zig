const std = @import("std");
const Allocator = std.mem.Allocator;
const Ulid = @import("../core/ulid.zig").Ulid;
const Task = @import("../core/task.zig").Task;
const Exploration = @import("../core/exploration.zig").Exploration;
const Session = @import("../core/session.zig").Session;
const Event = @import("../core/event.zig").Event;
const Evidence = @import("../core/evidence.zig").Evidence;
const Store = @import("store.zig").Store;

/// Write a JSON-escaped version of `s` to `writer`.
/// Escapes: \, ", control chars (as \uXXXX), newlines, tabs.
fn writeJsonEscaped(writer: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.print("\\\"", .{}),
            '\\' => try writer.print("\\\\", .{}),
            '\n' => try writer.print("\\n", .{}),
            '\r' => try writer.print("\\r", .{}),
            '\t' => try writer.print("\\t", .{}),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                try writer.print("\\u{x:0>4}", .{@as(u16, c)});
            },
            else => try writer.print("{c}", .{c}),
        }
    }
}

/// Export all context for a task to .agx/context/{task_id}/.
/// Produces: summary.md, sessions.jsonl, evidence.json, decision_log.md
pub fn exportTaskContext(
    alloc: Allocator,
    store: *Store,
    task: *const Task,
    context_base: []const u8,
) ![]const u8 {
    const task_id_str = task.id.encode();
    const context_dir = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ context_base, &task_id_str });
    errdefer alloc.free(context_dir);

    std.fs.cwd().makePath(context_dir) catch {};

    // Get all explorations for this task
    var exp_buf: [32]Exploration = undefined;
    const explorations = try store.getExplorationsByTask(task.id, &exp_buf);
    defer Exploration.deinitSlice(alloc, explorations);

    try writeSummary(alloc, store, task, explorations, context_dir);
    try writeSessionsJsonl(alloc, store, explorations, context_dir);
    try writeEvidenceJson(alloc, store, explorations, context_dir);
    try writeDecisionLog(alloc, store, explorations, context_dir);

    return context_dir;
}

/// Export context for a single exploration.
pub fn exportExplorationContext(
    alloc: Allocator,
    store: *Store,
    task: *const Task,
    exp: *const Exploration,
    context_base: []const u8,
) ![]const u8 {
    const task_id_str = task.id.encode();
    const context_dir = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ context_base, &task_id_str });
    errdefer alloc.free(context_dir);

    std.fs.cwd().makePath(context_dir) catch {};

    const exps = &[_]Exploration{exp.*};
    try writeSummary(alloc, store, task, exps, context_dir);
    try writeSessionsJsonl(alloc, store, exps, context_dir);
    try writeEvidenceJson(alloc, store, exps, context_dir);
    try writeDecisionLog(alloc, store, exps, context_dir);

    return context_dir;
}

// ── summary.md ──

fn writeSummary(
    alloc: Allocator,
    store: *Store,
    task: *const Task,
    explorations: []const Exploration,
    context_dir: []const u8,
) !void {
    _ = store;
    const path = try std.fmt.allocPrint(alloc, "{s}/summary.md", .{context_dir});
    defer alloc.free(path);

    const file = std.fs.cwd().createFile(path, .{}) catch return;
    defer file.close();

    var buf: [4096]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;

    const task_short = task.id.short(6);
    try w.print("# Task {s}: {s}\n\n", .{ &task_short, task.description });
    try w.print("- Base branch: {s}\n", .{task.base_branch});
    try w.print("- Base commit: {s}\n", .{task.base_commit});
    try w.print("- Status: {s}\n", .{task.status.toStr()});
    try w.print("\n## Explorations\n\n", .{});

    for (explorations) |exp| {
        const status_icon: []const u8 = switch (exp.status) {
            .active => "●",
            .done => "✓",
            .kept => "★",
            .archived => "▪",
            .discarded => "✗",
        };
        try w.print("### [{d}] {s} {s}\n\n", .{ exp.index, status_icon, exp.status.toStr() });
        try w.print("- Branch: {s}\n", .{exp.branch_name});
        if (exp.approach) |approach| {
            try w.print("- Approach: {s}\n", .{approach});
        }
        if (exp.summary) |summary| {
            try w.print("- Summary: {s}\n", .{summary});
        }
        try w.print("\n", .{});
    }

    try w.flush();
}

// ── sessions.jsonl ──

fn writeSessionsJsonl(
    alloc: Allocator,
    store: *Store,
    explorations: []const Exploration,
    context_dir: []const u8,
) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/sessions.jsonl", .{context_dir});
    defer alloc.free(path);

    const file = std.fs.cwd().createFile(path, .{}) catch return;
    defer file.close();

    var buf: [4096]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;

    for (explorations) |exp| {
        var sess_buf: [8]Session = undefined;
        const sessions = store.getSessionsByExploration(exp.id, &sess_buf) catch continue;
        defer Session.deinitSlice(alloc, sessions);

        for (sessions) |sess| {
            // Write session header
            const sess_id_str = sess.id.encode();
            try w.print("{{\"type\":\"session\",\"id\":\"{s}\",\"exploration_index\":{d}", .{ &sess_id_str, exp.index });
            if (sess.agent_type) |at| {
                try w.print(",\"agent_type\":\"", .{});
                try writeJsonEscaped(w, at);
                try w.print("\"", .{});
            }
            if (sess.model_version) |mv| {
                try w.print(",\"model_version\":\"", .{});
                try writeJsonEscaped(w, mv);
                try w.print("\"", .{});
            }
            try w.print(",\"started_at\":{d}", .{sess.started_at});
            if (sess.ended_at) |ea| try w.print(",\"ended_at\":{d}", .{ea});
            if (sess.exit_reason) |er| try w.print(",\"exit_reason\":\"{s}\"", .{er.toStr()});
            try w.print("}}\n", .{});

            // Write events for this session
            var ev_buf: [512]Event = undefined;
            const events = store.getEventsBySession(sess.id, null, &ev_buf) catch continue;
            defer Event.deinitSlice(alloc, events);

            for (events) |ev| {
                try w.print("{{\"type\":\"event\",\"kind\":\"{s}\",\"created_at\":{d}", .{ ev.kind.toStr(), ev.created_at });
                if (ev.data) |d| {
                    try w.print(",\"data\":{s}", .{d});
                }
                try w.print("}}\n", .{});
            }

            try w.flush();
        }
    }
}

// ── evidence.json ──

fn writeEvidenceJson(
    alloc: Allocator,
    store: *Store,
    explorations: []const Exploration,
    context_dir: []const u8,
) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/evidence.json", .{context_dir});
    defer alloc.free(path);

    const file = std.fs.cwd().createFile(path, .{}) catch return;
    defer file.close();

    var buf: [4096]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;

    try w.print("[", .{});
    var first = true;

    for (explorations) |exp| {
        var ev_buf: [64]Evidence = undefined;
        const evidence = store.getEvidenceByExploration(exp.id, &ev_buf) catch continue;
        defer Evidence.deinitSlice(alloc, evidence);

        for (evidence) |ev| {
            if (!first) try w.print(",", .{});
            first = false;
            try w.print("\n  {{\"exploration_index\":{d},\"kind\":\"{s}\",\"status\":\"{s}\"", .{
                exp.index,
                ev.kind.toStr(),
                ev.status.toStr(),
            });
            if (ev.hash) |h| {
                try w.print(",\"hash\":\"", .{});
                try writeJsonEscaped(w, h);
                try w.print("\"", .{});
            }
            if (ev.summary) |s| {
                try w.print(",\"summary\":\"", .{});
                try writeJsonEscaped(w, s);
                try w.print("\"", .{});
            }
            if (ev.raw_path) |p| {
                try w.print(",\"raw_path\":\"", .{});
                try writeJsonEscaped(w, p);
                try w.print("\"", .{});
            }
            try w.print(",\"recorded_at\":{d}}}", .{ev.recorded_at});
        }
    }

    try w.print("\n]\n", .{});
    try w.flush();
}

// ── decision_log.md ──

fn writeDecisionLog(
    alloc: Allocator,
    store: *Store,
    explorations: []const Exploration,
    context_dir: []const u8,
) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/decision_log.md", .{context_dir});
    defer alloc.free(path);

    const file = std.fs.cwd().createFile(path, .{}) catch return;
    defer file.close();

    var buf: [4096]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;

    try w.print("# Decision Log\n\n", .{});

    var has_decisions = false;

    for (explorations) |exp| {
        var sess_buf: [8]Session = undefined;
        const sessions = store.getSessionsByExploration(exp.id, &sess_buf) catch continue;
        defer Session.deinitSlice(alloc, sessions);

        for (sessions) |sess| {
            var ev_buf: [256]Event = undefined;
            const events = store.getEventsBySession(sess.id, "decision", &ev_buf) catch continue;
            defer Event.deinitSlice(alloc, events);

            if (events.len > 0 and !has_decisions) {
                has_decisions = true;
            }

            for (events) |ev| {
                try w.print("## Exploration [{d}]\n\n", .{exp.index});
                if (ev.data) |d| {
                    try w.print("- {s}\n", .{d});
                }
                try w.print("\n", .{});
            }
        }
    }

    if (!has_decisions) {
        try w.print("No decisions recorded.\n", .{});
    }

    try w.flush();
}
