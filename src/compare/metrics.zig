const std = @import("std");
const Allocator = std.mem.Allocator;
const Task = @import("../core/task.zig").Task;
const Exploration = @import("../core/exploration.zig").Exploration;
const ExplorationStatus = @import("../core/exploration.zig").ExplorationStatus;
const Evidence = @import("../core/evidence.zig").Evidence;
const Session = @import("../core/session.zig").Session;
const Store = @import("../storage/store.zig").Store;
const GitCli = @import("../git/cli.zig").GitCli;

/// Per-exploration metrics relative to the task's base_commit.
pub const ExplorationMetrics = struct {
    index: u32,
    status: ExplorationStatus,
    approach: ?[]const u8,
    summary: ?[]const u8,

    // Git diff stats
    files_changed: u32,
    files_created: u32,
    files_deleted: u32,
    lines_added: u32,
    lines_removed: u32,
    commit_count: u32,

    // File list (for overlap matrix)
    changed_files: []const []const u8,

    // Evidence summary
    tests_pass: u32,
    tests_fail: u32,
    build_pass: bool,
    build_fail: bool,

    // Session info
    agent_type: ?[]const u8,
    model_version: ?[]const u8,

    // Timing
    started_at: i64,
    ended_at: ?i64,

    // Errors
    error_count: u32,

    pub fn toStr(self: *const ExplorationMetrics) []const u8 {
        return self.status.toStr();
    }
};

/// Collect metrics for all explorations of a task.
pub fn collectMetrics(
    alloc: Allocator,
    store: *Store,
    task: *const Task,
    explorations: []const Exploration,
) ![]ExplorationMetrics {
    const metrics = try alloc.alloc(ExplorationMetrics, explorations.len);
    errdefer alloc.free(metrics);

    for (explorations, 0..) |exp, i| {
        metrics[i] = try collectOne(alloc, store, task, &exp);
    }

    return metrics;
}

fn collectOne(
    alloc: Allocator,
    store: *Store,
    task: *const Task,
    exp: *const Exploration,
) !ExplorationMetrics {
    const git = GitCli.init(alloc, exp.worktree_path);

    // Git diff stats relative to base commit
    var files_changed: u32 = 0;
    var lines_added: u32 = 0;
    var lines_removed: u32 = 0;
    var changed_files_list: std.ArrayList([]const u8) = .empty;

    if (git.diffNumstat(task.base_commit, "HEAD")) |numstat| {
        defer alloc.free(numstat);
        var lines = std.mem.splitScalar(u8, numstat, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var parts = std.mem.splitScalar(u8, line, '\t');
            const added_str = parts.next() orelse continue;
            const removed_str = parts.next() orelse continue;
            const file_name = parts.next() orelse continue;

            // Binary files show "-" for add/remove
            if (!std.mem.eql(u8, added_str, "-")) {
                lines_added += std.fmt.parseInt(u32, added_str, 10) catch 0;
            }
            if (!std.mem.eql(u8, removed_str, "-")) {
                lines_removed += std.fmt.parseInt(u32, removed_str, 10) catch 0;
            }
            files_changed += 1;
            try changed_files_list.append(alloc, try alloc.dupe(u8, file_name));
        }
    } else |_| {}

    // Files created (Added)
    var files_created: u32 = 0;
    if (git.diffFilter(task.base_commit, "HEAD", "A")) |added| {
        defer alloc.free(added);
        var lines = std.mem.splitScalar(u8, added, '\n');
        while (lines.next()) |line| {
            if (line.len > 0) files_created += 1;
        }
    } else |_| {}

    // Files deleted
    var files_deleted: u32 = 0;
    if (git.diffFilter(task.base_commit, "HEAD", "D")) |deleted| {
        defer alloc.free(deleted);
        var lines = std.mem.splitScalar(u8, deleted, '\n');
        while (lines.next()) |line| {
            if (line.len > 0) files_deleted += 1;
        }
    } else |_| {}

    // Commit count
    const commit_count = git.commitCount(task.base_commit, "HEAD") catch 0;

    // Evidence
    var ev_buf: [64]Evidence = undefined;
    const evidence = try store.getEvidenceByExploration(exp.id, &ev_buf);

    var tests_pass: u32 = 0;
    var tests_fail: u32 = 0;
    var build_pass = false;
    var build_fail = false;
    for (evidence) |ev| {
        switch (ev.kind) {
            .test_result => switch (ev.status) {
                .pass => tests_pass += 1,
                .fail, .@"error" => tests_fail += 1,
                .skip => {},
            },
            .build_output => switch (ev.status) {
                .pass => build_pass = true,
                .fail, .@"error" => build_fail = true,
                .skip => {},
            },
            else => {},
        }
    }

    // Session info (use first session)
    var sess_buf: [8]Session = undefined;
    const sessions = try store.getSessionsByExploration(exp.id, &sess_buf);

    var agent_type: ?[]const u8 = null;
    var model_version: ?[]const u8 = null;
    var started_at: i64 = exp.created_at;
    var ended_at: ?i64 = null;

    if (sessions.len > 0) {
        const first = sessions[0];
        agent_type = if (first.agent_type) |a| try alloc.dupe(u8, a) else null;
        model_version = if (first.model_version) |m| try alloc.dupe(u8, m) else null;
        started_at = first.started_at;
        // Use last session's end time
        const last = sessions[sessions.len - 1];
        ended_at = last.ended_at;
    }

    // Error count
    const error_count_raw = store.countErrorsByExploration(exp.id) catch 0;
    const error_count: u32 = if (error_count_raw < 0) 0 else @intCast(@min(error_count_raw, std.math.maxInt(u32)));

    return .{
        .index = exp.index,
        .status = exp.status,
        .approach = if (exp.approach) |a| try alloc.dupe(u8, a) else null,
        .summary = if (exp.summary) |s| try alloc.dupe(u8, s) else null,
        .files_changed = files_changed,
        .files_created = files_created,
        .files_deleted = files_deleted,
        .lines_added = lines_added,
        .lines_removed = lines_removed,
        .commit_count = commit_count,
        .changed_files = try changed_files_list.toOwnedSlice(alloc),
        .tests_pass = tests_pass,
        .tests_fail = tests_fail,
        .build_pass = build_pass,
        .build_fail = build_fail,
        .agent_type = agent_type,
        .model_version = model_version,
        .started_at = started_at,
        .ended_at = ended_at,
        .error_count = error_count,
    };
}
