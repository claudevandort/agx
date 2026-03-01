const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");

/// Build an enriched commit message for `agx exploration pick`.
pub fn buildExplorationPickMessage(
    alloc: Allocator,
    s: *agx.Store,
    g: agx.Goal,
    t: agx.Task,
    index: u32,
) ![]const u8 {
    var buf = std.ArrayList(u8).empty;

    // Subject line
    try buf.writer(alloc).print("agx exploration pick [{d}]: {s}\n", .{ index, g.description });

    // Goal description
    try buf.writer(alloc).print("\nGoal: {s}\n", .{g.description});

    // Approach / Summary
    if (t.approach) |approach| {
        try buf.writer(alloc).print("\nApproach: {s}\n", .{approach});
    }
    if (t.summary) |summary| {
        try buf.writer(alloc).print("Summary: {s}\n", .{summary});
    }

    // Decisions from events
    try appendDecisions(alloc, s, t, &buf);

    // Evidence
    try appendEvidence(alloc, s, t, &buf);

    // Trailers
    try buf.appendSlice(alloc, "\n");

    const goal_short = g.id.short(6);
    try buf.writer(alloc).print("AGX-Goal: {s}\n", .{&goal_short});

    var idx_buf: [16]u8 = undefined;
    const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{index}) catch "?";
    try buf.writer(alloc).print("AGX-Task: {s}\n", .{idx_str});

    // Agent/Model from first session
    var sess_buf: [8]agx.Session = undefined;
    const sessions = s.getSessionsByTask(t.id, &sess_buf) catch &[_]agx.Session{};
    if (sessions.len > 0) {
        if (sessions[0].agent_type) |agent| {
            try buf.writer(alloc).print("AGX-Agent: {s}\n", .{agent});
        }
        if (sessions[0].model_version) |model| {
            try buf.writer(alloc).print("AGX-Model: {s}\n", .{model});
        }
    }

    return buf.toOwnedSlice(alloc);
}

/// Build an enriched commit message for `agx dispatch merge`.
pub fn buildDispatchMergeMessage(
    alloc: Allocator,
    s: *agx.Store,
    d: agx.Dispatch,
    g: agx.Goal,
    t: agx.Task,
    step: usize,
    total: usize,
) ![]const u8 {
    var buf = std.ArrayList(u8).empty;

    // Subject line
    try buf.writer(alloc).print("agx dispatch merge [{d}/{d}]: {s}\n", .{ step, total, g.description });

    // Approach / Summary
    if (t.approach) |approach| {
        try buf.writer(alloc).print("\nApproach: {s}\n", .{approach});
    }
    if (t.summary) |summary| {
        try buf.writer(alloc).print("Summary: {s}\n", .{summary});
    }

    // Decisions from events
    try appendDecisions(alloc, s, t, &buf);

    // Evidence
    try appendEvidence(alloc, s, t, &buf);

    // Trailers
    try buf.appendSlice(alloc, "\n");

    const dispatch_enc = d.id.encode();
    try buf.writer(alloc).print("AGX-Dispatch: {s}\n", .{&dispatch_enc});

    const goal_enc = g.id.encode();
    try buf.writer(alloc).print("AGX-Goal: {s}\n", .{&goal_enc});

    return buf.toOwnedSlice(alloc);
}

fn appendDecisions(alloc: Allocator, s: *agx.Store, t: agx.Task, buf: *std.ArrayList(u8)) !void {
    var sess_buf: [8]agx.Session = undefined;
    const sessions = s.getSessionsByTask(t.id, &sess_buf) catch return;

    var has_header = false;
    for (sessions) |session| {
        var event_buf: [64]agx.Event = undefined;
        const events = s.getEventsBySession(session.id, "decision", &event_buf) catch continue;
        for (events) |ev| {
            if (ev.data) |data| {
                if (!has_header) {
                    try buf.appendSlice(alloc, "\nDecisions:\n");
                    has_header = true;
                }
                try buf.writer(alloc).print("- {s}\n", .{data});
            }
        }
    }
}

fn appendEvidence(alloc: Allocator, s: *agx.Store, t: agx.Task, buf: *std.ArrayList(u8)) !void {
    var ev_buf: [32]agx.Evidence = undefined;
    const evidence_list = s.getEvidenceByTask(t.id, &ev_buf) catch return;

    if (evidence_list.len == 0) return;

    try buf.appendSlice(alloc, "\nEvidence:\n");
    for (evidence_list) |ev| {
        const kind_str = ev.kind.toStr();
        const status_str = ev.status.toStr();
        if (ev.summary) |summary| {
            try buf.writer(alloc).print("- {s}: {s} — {s}\n", .{ kind_str, status_str, summary });
        } else {
            try buf.writer(alloc).print("- {s}: {s}\n", .{ kind_str, status_str });
        }
    }
}
