const std = @import("std");
const Allocator = std.mem.Allocator;
const Ulid = @import("../core/ulid.zig").Ulid;
const Task = @import("../core/task.zig").Task;
const Exploration = @import("../core/exploration.zig").Exploration;
const Session = @import("../core/session.zig").Session;
const Event = @import("../core/event.zig").Event;
const Evidence = @import("../core/evidence.zig").Evidence;
const Batch = @import("../core/batch.zig").Batch;
const Store = @import("store.zig").Store;
const JsonWriter = @import("../util/json_writer.zig").JsonWriter;

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

    std.fs.cwd().makePath(context_dir) catch {};

    // Get all explorations for this task
    var exp_buf: [32]Exploration = undefined;
    const explorations = try store.getExplorationsByTask(task.id, &exp_buf);

    try writeSummary(alloc, task, explorations, context_dir);
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

    std.fs.cwd().makePath(context_dir) catch {};

    const exps = &[_]Exploration{exp.*};
    try writeSummary(alloc, task, exps, context_dir);
    try writeSessionsJsonl(alloc, store, exps, context_dir);
    try writeEvidenceJson(alloc, store, exps, context_dir);
    try writeDecisionLog(alloc, store, exps, context_dir);

    return context_dir;
}

// ── summary.md ──

fn writeSummary(
    alloc: Allocator,
    task: *const Task,
    explorations: []const Exploration,
    context_dir: []const u8,
) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/summary.md", .{context_dir});

    const file = std.fs.cwd().createFile(path, .{}) catch return;
    defer file.close();

    var buf: [4096]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;

    // Write YAML-style frontmatter
    const task_id_str = task.id.encode();
    const date_str = formatDate(task.created_at);
    try w.print("---\n", .{});
    try w.print("task_id: {s}\n", .{&task_id_str});
    try w.print("description: {s}\n", .{task.description});
    try w.print("status: {s}\n", .{task.status.toStr()});
    try w.print("base_branch: {s}\n", .{task.base_branch});
    try w.print("date: {s}\n", .{&date_str});
    try w.print("explorations: {d}\n", .{explorations.len});
    try w.print("---\n\n", .{});

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

    const file = std.fs.cwd().createFile(path, .{}) catch return;
    defer file.close();

    var buf: [4096]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;

    for (explorations) |exp| {
        var sess_buf: [8]Session = undefined;
        const sessions = store.getSessionsByExploration(exp.id, &sess_buf) catch continue;

        for (sessions) |sess| {
            const sess_id_str = sess.id.encode();
            var jw = JsonWriter.init(w);
            try jw.beginObject();
            try jw.stringField("type", "session");
            try jw.stringField("id", &sess_id_str);
            try jw.uintField("exploration_index", exp.index);
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
    explorations: []const Exploration,
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

    for (explorations) |exp| {
        var ev_buf: [64]Evidence = undefined;
        const evidence = store.getEvidenceByExploration(exp.id, &ev_buf) catch continue;

        for (evidence) |ev| {
            try jw.beginObjectValue();
            try jw.uintField("exploration_index", exp.index);
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
    explorations: []const Exploration,
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

    for (explorations) |exp| {
        var sess_buf: [8]Session = undefined;
        const sessions = store.getSessionsByExploration(exp.id, &sess_buf) catch continue;

        var header_written = false;
        for (sessions) |sess| {
            var ev_buf: [256]Event = undefined;
            const events = store.getEventsBySession(sess.id, "decision", &ev_buf) catch continue;

            for (events) |ev| {
                if (!header_written) {
                    try w.print("## Exploration [{d}]\n\n", .{exp.index});
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

/// Export all context for a batch: per-task context + batch summary.
/// Returns the batch context directory path.
pub fn exportBatchContext(
    alloc: Allocator,
    store: *Store,
    batch_obj: *const Batch,
    context_base: []const u8,
) ![]const u8 {
    const batch_id_str = batch_obj.id.encode();
    const batch_dir = try std.fmt.allocPrint(alloc, "{s}/batch-{s}", .{ context_base, &batch_id_str });

    std.fs.cwd().makePath(batch_dir) catch {};

    // Export each task in the batch
    var task_buf: [64]Task = undefined;
    const tasks = try store.getTasksByBatch(batch_obj.id, &task_buf);

    for (tasks) |t| {
        _ = try exportTaskContext(alloc, store, &t, context_base);
    }

    // Write batch-level summary
    try writeBatchSummary(alloc, batch_obj, tasks, batch_dir);

    return batch_dir;
}

fn writeBatchSummary(
    alloc: Allocator,
    batch_obj: *const Batch,
    tasks: []const Task,
    batch_dir: []const u8,
) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/summary.md", .{batch_dir});

    const file = std.fs.cwd().createFile(path, .{}) catch return;
    defer file.close();

    var buf: [4096]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;

    // YAML frontmatter
    const batch_id_str = batch_obj.id.encode();
    const date_str = formatDate(batch_obj.created_at);
    try w.print("---\n", .{});
    try w.print("batch_id: {s}\n", .{&batch_id_str});
    try w.print("description: {s}\n", .{batch_obj.description});
    try w.print("status: {s}\n", .{batch_obj.status.toStr()});
    try w.print("merge_policy: {s}\n", .{batch_obj.merge_policy.toStr()});
    try w.print("base_branch: {s}\n", .{batch_obj.base_branch});
    try w.print("date: {s}\n", .{&date_str});
    try w.print("tasks: {d}\n", .{tasks.len});
    try w.print("---\n\n", .{});

    // Markdown body
    const batch_short = batch_obj.id.short(6);
    try w.print("# Batch {s}: {s}\n\n", .{ &batch_short, batch_obj.description });
    try w.print("- Base branch: {s}\n", .{batch_obj.base_branch});
    try w.print("- Base commit: {s}\n", .{batch_obj.base_commit});
    try w.print("- Status: {s}\n", .{batch_obj.status.toStr()});
    try w.print("- Merge policy: {s}\n", .{batch_obj.merge_policy.toStr()});

    // Task list
    try w.print("\n## Tasks\n\n", .{});
    for (tasks, 1..) |t, idx| {
        const status_icon: []const u8 = switch (t.status) {
            .active => "●",
            .resolved => "✓",
            .abandoned => "✗",
        };
        const task_id_str = t.id.encode();
        try w.print("{d}. {s} `{s}` — {s}\n", .{ idx, status_icon, &task_id_str, t.description });
    }

    // Merge order section
    if (batch_obj.merge_order) |order| {
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
