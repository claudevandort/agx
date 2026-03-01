const std = @import("std");
const Allocator = std.mem.Allocator;
const Ulid = @import("../core/ulid.zig").Ulid;
const Goal = @import("../core/goal.zig").Goal;
const Task = @import("../core/task.zig").Task;
const Session = @import("../core/session.zig").Session;
const Event = @import("../core/event.zig").Event;
const Evidence = @import("../core/evidence.zig").Evidence;
const Dispatch = @import("../core/dispatch.zig").Dispatch;
const Store = @import("store.zig").Store;
const JsonWriter = @import("../util/json_writer.zig").JsonWriter;

/// Export all context for a goal to .agx/context/{goal_id}/.
/// Produces: summary.md, sessions.jsonl, evidence.json, decision_log.md
pub fn exportGoalContext(
    alloc: Allocator,
    store: *Store,
    g: *const Goal,
    context_base: []const u8,
) ![]const u8 {
    const goal_id_str = g.id.encode();
    const context_dir = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ context_base, &goal_id_str });

    std.fs.cwd().makePath(context_dir) catch {};

    // Get all tasks for this goal
    var task_buf: [32]Task = undefined;
    const tasks = try store.getTasksByGoal(g.id, &task_buf);

    try writeSummary(alloc, g, tasks, context_dir);
    try writeSessionsJsonl(alloc, store, tasks, context_dir);
    try writeEvidenceJson(alloc, store, tasks, context_dir);
    try writeDecisionLog(alloc, store, tasks, context_dir);

    return context_dir;
}

/// Export context for a single task.
pub fn exportTaskContext(
    alloc: Allocator,
    store: *Store,
    g: *const Goal,
    t: *const Task,
    context_base: []const u8,
) ![]const u8 {
    const goal_id_str = g.id.encode();
    const context_dir = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ context_base, &goal_id_str });

    std.fs.cwd().makePath(context_dir) catch {};

    const tasks = &[_]Task{t.*};
    try writeSummary(alloc, g, tasks, context_dir);
    try writeSessionsJsonl(alloc, store, tasks, context_dir);
    try writeEvidenceJson(alloc, store, tasks, context_dir);
    try writeDecisionLog(alloc, store, tasks, context_dir);

    return context_dir;
}

// ── summary.md ──

fn writeSummary(
    alloc: Allocator,
    g: *const Goal,
    tasks: []const Task,
    context_dir: []const u8,
) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/summary.md", .{context_dir});

    const file = std.fs.cwd().createFile(path, .{}) catch return;
    defer file.close();

    var buf: [4096]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;

    // Write YAML-style frontmatter
    const goal_id_str = g.id.encode();
    const date_str = formatDate(g.created_at);
    try w.print("---\n", .{});
    try w.print("goal_id: {s}\n", .{&goal_id_str});
    try w.print("description: {s}\n", .{g.description});
    try w.print("status: {s}\n", .{g.status.toStr()});
    try w.print("base_branch: {s}\n", .{g.base_branch});
    try w.print("date: {s}\n", .{&date_str});
    try w.print("tasks: {d}\n", .{tasks.len});
    try w.print("---\n\n", .{});

    const goal_short = g.id.short(6);
    try w.print("# Goal {s}: {s}\n\n", .{ &goal_short, g.description });
    try w.print("- Base branch: {s}\n", .{g.base_branch});
    try w.print("- Base commit: {s}\n", .{g.base_commit});
    try w.print("- Status: {s}\n", .{g.status.toStr()});
    try w.print("\n## Tasks\n\n", .{});

    for (tasks) |t| {
        const status_icon: []const u8 = switch (t.status) {
            .active => "●",
            .done => "✓",
            .kept => "★",
            .archived => "▪",
            .discarded => "✗",
        };
        try w.print("### [{d}] {s} {s}\n\n", .{ t.index, status_icon, t.status.toStr() });
        try w.print("- Branch: {s}\n", .{t.branch_name});
        if (t.approach) |approach| {
            try w.print("- Approach: {s}\n", .{approach});
        }
        if (t.summary) |summary| {
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
    tasks: []const Task,
    context_dir: []const u8,
) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/sessions.jsonl", .{context_dir});

    const file = std.fs.cwd().createFile(path, .{}) catch return;
    defer file.close();

    var buf: [4096]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;

    for (tasks) |t| {
        var sess_buf: [8]Session = undefined;
        const sessions = store.getSessionsByTask(t.id, &sess_buf) catch continue;

        for (sessions) |sess| {
            const sess_id_str = sess.id.encode();
            var jw = JsonWriter.init(w);
            try jw.beginObject();
            try jw.stringField("type", "session");
            try jw.stringField("id", &sess_id_str);
            try jw.uintField("task_index", t.index);
            try jw.optionalStringField("agent_type", sess.agent_type);
            try jw.optionalStringField("model_version", sess.model_version);
            try jw.intField("started_at", sess.started_at);
            try jw.optionalIntField("ended_at", sess.ended_at);
            if (sess.exit_reason) |er| try jw.stringField("exit_reason", er.toStr());
            try jw.endObject();
            try w.print("\n", .{});

            // Write events for this session
            var ev_buf: [512]Event = undefined;
            const events = store.getEventsBySession(sess.id, null, &ev_buf) catch continue;

            for (events) |ev| {
                var ejw = JsonWriter.init(w);
                try ejw.beginObject();
                try ejw.stringField("type", "event");
                try ejw.stringField("kind", ev.kind.toStr());
                try ejw.intField("created_at", ev.created_at);
                if (ev.data) |d| try ejw.rawField("data", d);
                try ejw.endObject();
                try w.print("\n", .{});
            }

            try w.flush();
        }
    }
}

// ── evidence.json ──

fn writeEvidenceJson(
    alloc: Allocator,
    store: *Store,
    tasks: []const Task,
    context_dir: []const u8,
) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/evidence.json", .{context_dir});

    const file = std.fs.cwd().createFile(path, .{}) catch return;
    defer file.close();

    var buf: [4096]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;
    var jw = JsonWriter.init(w);

    try jw.beginArray();

    for (tasks) |t| {
        var ev_buf: [64]Evidence = undefined;
        const evidence = store.getEvidenceByTask(t.id, &ev_buf) catch continue;

        for (evidence) |ev| {
            try jw.beginObjectValue();
            try jw.uintField("task_index", t.index);
            try jw.stringField("kind", ev.kind.toStr());
            try jw.stringField("status", ev.status.toStr());
            try jw.optionalStringField("hash", ev.hash);
            try jw.optionalStringField("summary", ev.summary);
            try jw.optionalStringField("raw_path", ev.raw_path);
            try jw.intField("recorded_at", ev.recorded_at);
            try jw.endObject();
        }
    }

    try jw.endArray();
    try w.print("\n", .{});
    try w.flush();
}

// ── decision_log.md ──

fn writeDecisionLog(
    alloc: Allocator,
    store: *Store,
    tasks: []const Task,
    context_dir: []const u8,
) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/decision_log.md", .{context_dir});

    const file = std.fs.cwd().createFile(path, .{}) catch return;
    defer file.close();

    var buf: [4096]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;

    try w.print("# Decision Log\n\n", .{});

    var has_decisions = false;

    for (tasks) |t| {
        var sess_buf: [8]Session = undefined;
        const sessions = store.getSessionsByTask(t.id, &sess_buf) catch continue;

        var header_written = false;
        for (sessions) |sess| {
            var ev_buf: [256]Event = undefined;
            const events = store.getEventsBySession(sess.id, "decision", &ev_buf) catch continue;

            for (events) |ev| {
                if (!header_written) {
                    try w.print("## Task [{d}]\n\n", .{t.index});
                    header_written = true;
                    has_decisions = true;
                }
                if (ev.data) |d| {
                    try w.print("- {s}\n", .{d});
                }
            }
        }
        if (header_written) {
            try w.print("\n", .{});
        }
    }

    if (!has_decisions) {
        try w.print("No decisions recorded.\n", .{});
    }

    try w.flush();
}

/// Export all context for a dispatch: per-goal context + dispatch summary.
/// Returns the dispatch context directory path.
pub fn exportDispatchContext(
    alloc: Allocator,
    store: *Store,
    d: *const Dispatch,
    context_base: []const u8,
) ![]const u8 {
    const dispatch_id_str = d.id.encode();
    const dispatch_dir = try std.fmt.allocPrint(alloc, "{s}/dispatch-{s}", .{ context_base, &dispatch_id_str });

    std.fs.cwd().makePath(dispatch_dir) catch {};

    // Export each goal in the dispatch
    var goal_buf: [64]Goal = undefined;
    const goals = try store.getGoalsByDispatch(d.id, &goal_buf);

    for (goals) |g| {
        _ = try exportGoalContext(alloc, store, &g, context_base);
    }

    // Write dispatch-level summary
    try writeDispatchSummary(alloc, d, goals, dispatch_dir);

    return dispatch_dir;
}

fn writeDispatchSummary(
    alloc: Allocator,
    d: *const Dispatch,
    goals: []const Goal,
    dispatch_dir: []const u8,
) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/summary.md", .{dispatch_dir});

    const file = std.fs.cwd().createFile(path, .{}) catch return;
    defer file.close();

    var buf: [4096]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;

    // YAML frontmatter
    const dispatch_id_str = d.id.encode();
    const date_str = formatDate(d.created_at);
    try w.print("---\n", .{});
    try w.print("dispatch_id: {s}\n", .{&dispatch_id_str});
    try w.print("description: {s}\n", .{d.description});
    try w.print("status: {s}\n", .{d.status.toStr()});
    try w.print("merge_policy: {s}\n", .{d.merge_policy.toStr()});
    try w.print("base_branch: {s}\n", .{d.base_branch});
    try w.print("date: {s}\n", .{&date_str});
    try w.print("goals: {d}\n", .{goals.len});
    try w.print("---\n\n", .{});

    // Markdown body
    const dispatch_short = d.id.short(6);
    try w.print("# Dispatch {s}: {s}\n\n", .{ &dispatch_short, d.description });
    try w.print("- Base branch: {s}\n", .{d.base_branch});
    try w.print("- Base commit: {s}\n", .{d.base_commit});
    try w.print("- Status: {s}\n", .{d.status.toStr()});
    try w.print("- Merge policy: {s}\n", .{d.merge_policy.toStr()});

    // Goal list
    try w.print("\n## Goals\n\n", .{});
    for (goals, 1..) |g, idx| {
        const status_icon: []const u8 = switch (g.status) {
            .active => "●",
            .resolved => "✓",
            .abandoned => "✗",
        };
        const goal_id_str = g.id.encode();
        try w.print("{d}. {s} `{s}` — {s}\n", .{ idx, status_icon, &goal_id_str, g.description });
    }

    // Merge order section
    if (d.merge_order) |order| {
        try w.print("\n## Merge Order\n\n", .{});
        try w.print("```\n{s}\n```\n", .{order});
    }

    try w.flush();
}

/// Format millisecond-epoch timestamp as YYYY-MM-DD.
fn formatDate(ms_epoch: i64) [10]u8 {
    const secs: u64 = @intCast(@divTrunc(ms_epoch, 1000));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    var buf: [10]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        yd.year,
        @as(u32, @intFromEnum(md.month)),
        @as(u32, md.day_index) + 1,
    }) catch unreachable;
    return buf;
}
