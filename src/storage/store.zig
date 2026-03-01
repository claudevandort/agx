const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const migrations = @import("migrations.zig").migrations;
const Ulid = @import("../core/ulid.zig").Ulid;
const Goal = @import("../core/goal.zig").Goal;
const GoalStatus = @import("../core/goal.zig").GoalStatus;
const Dispatch = @import("../core/dispatch.zig").Dispatch;
const DispatchStatus = @import("../core/dispatch.zig").DispatchStatus;
const MergePolicy = @import("../core/dispatch.zig").MergePolicy;
const Task = @import("../core/task.zig").Task;
const TaskStatus = @import("../core/task.zig").TaskStatus;
const Session = @import("../core/session.zig").Session;
const ExitReason = @import("../core/session.zig").ExitReason;
const Event = @import("../core/event.zig").Event;
const EventKind = @import("../core/event.zig").EventKind;
const Evidence = @import("../core/evidence.zig").Evidence;
const EvidenceKind = @import("../core/evidence.zig").EvidenceKind;
const EvidenceStatus = @import("../core/evidence.zig").EvidenceStatus;
const Snapshot = @import("../core/snapshot.zig").Snapshot;

pub const StoreError = sqlite.SqliteError || Allocator.Error || error{
    MigrationFailed,
    NotFound,
};

pub const Store = struct {
    db: sqlite.Db,
    alloc: Allocator,

    // Cached prepared statements for hot-path queries
    cached_insert_event: ?sqlite.Stmt = null,
    cached_tasks_by_goal: ?sqlite.Stmt = null,
    cached_sessions_by_task: ?sqlite.Stmt = null,
    cached_events_by_session: ?sqlite.Stmt = null,
    cached_evidence_by_task: ?sqlite.Stmt = null,

    pub fn init(alloc: Allocator, path: [*:0]const u8) StoreError!Store {
        var db = try sqlite.Db.open(path);

        // Enable WAL mode and foreign keys
        try db.exec("PRAGMA journal_mode=WAL");
        try db.exec("PRAGMA foreign_keys=ON");
        try db.exec("PRAGMA busy_timeout=5000");

        var store = Store{ .db = db, .alloc = alloc };
        try store.migrate();
        return store;
    }

    pub fn deinit(self: *Store) void {
        if (self.cached_insert_event) |*s| s.finalize();
        if (self.cached_tasks_by_goal) |*s| s.finalize();
        if (self.cached_sessions_by_task) |*s| s.finalize();
        if (self.cached_events_by_session) |*s| s.finalize();
        if (self.cached_evidence_by_task) |*s| s.finalize();
        self.db.close();
    }

    fn getCached(self: *Store, field: *?sqlite.Stmt, sql: [*:0]const u8) StoreError!*sqlite.Stmt {
        if (field.*) |*s| {
            s.reset();
            return s;
        }
        field.* = try self.db.prepare(sql);
        return &field.*.?;
    }

    fn migrate(self: *Store) StoreError!void {
        self.db.exec(
            "CREATE TABLE IF NOT EXISTS agx_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL)",
        ) catch return error.MigrationFailed;

        var stmt = try self.db.prepare("SELECT COALESCE(MAX(version), -1) FROM agx_migrations");
        defer stmt.finalize();
        const row = try stmt.step();
        const current_version: i64 = if (row == .row) stmt.columnInt64(0) else -1;

        for (migrations, 0..) |sql, i| {
            const ver: i64 = @intCast(i);
            if (ver <= current_version) continue;

            self.db.exec("BEGIN") catch return error.MigrationFailed;
            errdefer self.db.exec("ROLLBACK") catch {};

            self.db.execMulti(sql) catch return error.MigrationFailed;

            var rec = self.db.prepare("INSERT INTO agx_migrations (version, applied_at) VALUES (?1, ?2)") catch return error.MigrationFailed;
            defer rec.finalize();
            rec.bindInt64(1, ver) catch return error.MigrationFailed;
            rec.bindInt64(2, std.time.milliTimestamp()) catch return error.MigrationFailed;
            _ = rec.step() catch return error.MigrationFailed;

            self.db.exec("COMMIT") catch return error.MigrationFailed;
        }
    }

    // ── Helpers for copying SQLite text into owned memory ──

    fn dupeText(self: *Store, val: ?[]const u8) Allocator.Error![]const u8 {
        return self.alloc.dupe(u8, val orelse "");
    }

    fn dupeOptionalText(self: *Store, val: ?[]const u8) Allocator.Error!?[]const u8 {
        if (val) |v| return try self.alloc.dupe(u8, v);
        return null;
    }

    fn readUlid(stmt: *sqlite.Stmt, col: u32) Ulid {
        const blob = stmt.columnBlob(col) orelse return Ulid{ .bytes = [_]u8{0} ** 16 };
        if (blob.len < 16) return Ulid{ .bytes = [_]u8{0} ** 16 };
        return Ulid{ .bytes = blob[0..16].* };
    }

    // ── Goal CRUD ──

    pub fn insertGoal(self: *Store, goal: Goal) StoreError!void {
        var stmt = try self.db.prepare(
            "INSERT INTO goals (id, description, base_commit, base_branch, status, resolved_task_id, dispatch_id, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &goal.id.bytes);
        try stmt.bindText(2, goal.description);
        try stmt.bindText(3, goal.base_commit);
        try stmt.bindText(4, goal.base_branch);
        try stmt.bindText(5, goal.status.toStr());
        try stmt.bindOptionalBlob(6, if (goal.resolved_task_id) |r| &r.bytes else null);
        try stmt.bindOptionalBlob(7, if (goal.dispatch_id) |b| &b.bytes else null);
        try stmt.bindInt64(8, goal.created_at);
        try stmt.bindInt64(9, goal.updated_at);
        _ = try stmt.step();
        self.indexEntity("goal", goal.id, goal.id, goal.description);
    }

    pub fn getGoal(self: *Store, id: Ulid) StoreError!Goal {
        var stmt = try self.db.prepare(
            "SELECT id, description, base_commit, base_branch, status, resolved_task_id, dispatch_id, created_at, updated_at FROM goals WHERE id = ?1",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &id.bytes);
        const result = try stmt.step();
        if (result != .row) return error.NotFound;
        return self.readGoal(&stmt);
    }

    pub fn getActiveGoal(self: *Store) StoreError!Goal {
        var stmt = try self.db.prepare(
            "SELECT id, description, base_commit, base_branch, status, resolved_task_id, dispatch_id, created_at, updated_at FROM goals WHERE status = 'active' ORDER BY created_at DESC LIMIT 1",
        );
        defer stmt.finalize();
        const result = try stmt.step();
        if (result != .row) return error.NotFound;
        return self.readGoal(&stmt);
    }

    pub fn updateGoalStatus(self: *Store, id: Ulid, status: GoalStatus, resolved_task_id: ?Ulid) StoreError!void {
        var stmt = try self.db.prepare(
            "UPDATE goals SET status = ?1, resolved_task_id = ?2, updated_at = ?3 WHERE id = ?4",
        );
        defer stmt.finalize();
        try stmt.bindText(1, status.toStr());
        try stmt.bindOptionalBlob(2, if (resolved_task_id) |r| &r.bytes else null);
        try stmt.bindInt64(3, std.time.milliTimestamp());
        try stmt.bindBlob(4, &id.bytes);
        _ = try stmt.step();
    }

    fn readGoal(self: *Store, stmt: *sqlite.Stmt) StoreError!Goal {
        const resolved_blob = stmt.columnBlob(5);
        const dispatch_blob = stmt.columnBlob(6);
        return .{
            .id = readUlid(stmt, 0),
            .description = try self.dupeText(stmt.columnText(1)),
            .base_commit = try self.dupeText(stmt.columnText(2)),
            .base_branch = try self.dupeText(stmt.columnText(3)),
            .status = GoalStatus.fromStr(stmt.columnText(4) orelse "active") catch .active,
            .resolved_task_id = if (resolved_blob) |b| blk: {
                break :blk if (b.len >= 16) Ulid{ .bytes = b[0..16].* } else null;
            } else null,
            .dispatch_id = if (dispatch_blob) |b| blk: {
                break :blk if (b.len >= 16) Ulid{ .bytes = b[0..16].* } else null;
            } else null,
            .created_at = stmt.columnInt64(7),
            .updated_at = stmt.columnInt64(8),
        };
    }

    // ── Task CRUD ──

    pub fn insertTask(self: *Store, task: Task) StoreError!void {
        var stmt = try self.db.prepare(
            "INSERT INTO tasks (id, goal_id, idx, worktree_path, branch_name, status, approach, summary, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &task.id.bytes);
        try stmt.bindBlob(2, &task.goal_id.bytes);
        try stmt.bindInt(3, @intCast(task.index));
        try stmt.bindText(4, task.worktree_path);
        try stmt.bindText(5, task.branch_name);
        try stmt.bindText(6, task.status.toStr());
        try stmt.bindOptionalText(7, task.approach);
        try stmt.bindOptionalText(8, task.summary);
        try stmt.bindInt64(9, task.created_at);
        try stmt.bindInt64(10, task.updated_at);
        _ = try stmt.step();
    }

    pub fn getTasksByGoal(self: *Store, goal_id: Ulid, buf: []Task) StoreError![]Task {
        const stmt = try self.getCached(
            &self.cached_tasks_by_goal,
            "SELECT id, goal_id, idx, worktree_path, branch_name, status, approach, summary, created_at, updated_at FROM tasks WHERE goal_id = ?1 ORDER BY idx",
        );
        try stmt.bindBlob(1, &goal_id.bytes);

        var count: usize = 0;
        while (count < buf.len) {
            const result = try stmt.step();
            if (result != .row) break;
            buf[count] = try self.readTask(stmt);
            count += 1;
        }
        if (count == buf.len) {
            const extra = try stmt.step();
            if (extra == .row) {
                std.log.warn("getTasksByGoal: buffer full ({d}), results truncated", .{buf.len});
            }
        }
        return buf[0..count];
    }

    pub fn getTaskByIndex(self: *Store, goal_id: Ulid, index: u32) StoreError!Task {
        var stmt = try self.db.prepare(
            "SELECT id, goal_id, idx, worktree_path, branch_name, status, approach, summary, created_at, updated_at FROM tasks WHERE goal_id = ?1 AND idx = ?2",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &goal_id.bytes);
        try stmt.bindInt(2, @intCast(index));
        const result = try stmt.step();
        if (result != .row) return error.NotFound;
        return self.readTask(&stmt);
    }

    pub fn updateTaskStatus(self: *Store, id: Ulid, status: TaskStatus, summary: ?[]const u8) StoreError!void {
        var stmt = try self.db.prepare(
            "UPDATE tasks SET status = ?1, summary = COALESCE(?2, summary), updated_at = ?3 WHERE id = ?4",
        );
        defer stmt.finalize();
        try stmt.bindText(1, status.toStr());
        try stmt.bindOptionalText(2, summary);
        try stmt.bindInt64(3, std.time.milliTimestamp());
        try stmt.bindBlob(4, &id.bytes);
        _ = try stmt.step();
        // Index summary into FTS — need goal_id from DB
        if (summary) |s| {
            var lookup = self.db.prepare("SELECT goal_id FROM tasks WHERE id = ?1") catch return;
            defer lookup.finalize();
            lookup.bindBlob(1, &id.bytes) catch return;
            if ((lookup.step() catch return) == .row) {
                const goal_id = readUlid(&lookup, 0);
                self.indexEntity("task", id, goal_id, s);
            }
        }
    }

    pub fn updateTaskApproach(self: *Store, id: Ulid, approach: []const u8) StoreError!void {
        var stmt = try self.db.prepare(
            "UPDATE tasks SET approach = ?1, updated_at = ?2 WHERE id = ?3",
        );
        defer stmt.finalize();
        try stmt.bindText(1, approach);
        try stmt.bindInt64(2, std.time.milliTimestamp());
        try stmt.bindBlob(3, &id.bytes);
        _ = try stmt.step();
        // Index approach into FTS — need goal_id from DB
        var lookup = self.db.prepare("SELECT goal_id FROM tasks WHERE id = ?1") catch return;
        defer lookup.finalize();
        lookup.bindBlob(1, &id.bytes) catch return;
        if ((lookup.step() catch return) == .row) {
            const goal_id = readUlid(&lookup, 0);
            self.indexEntity("task", id, goal_id, approach);
        }
    }

    fn readTask(self: *Store, stmt: *sqlite.Stmt) StoreError!Task {
        return .{
            .id = readUlid(stmt, 0),
            .goal_id = readUlid(stmt, 1),
            .index = @intCast(stmt.columnInt(2)),
            .worktree_path = try self.dupeText(stmt.columnText(3)),
            .branch_name = try self.dupeText(stmt.columnText(4)),
            .status = TaskStatus.fromStr(stmt.columnText(5) orelse "active") catch .active,
            .approach = try self.dupeOptionalText(stmt.columnText(6)),
            .summary = try self.dupeOptionalText(stmt.columnText(7)),
            .created_at = stmt.columnInt64(8),
            .updated_at = stmt.columnInt64(9),
        };
    }

    // ── Session CRUD ──

    pub fn insertSession(self: *Store, sess: Session) StoreError!void {
        var stmt = try self.db.prepare(
            "INSERT INTO sessions (id, task_id, agent_type, model_version, environment_fingerprint, initial_prompt, exit_reason, started_at, ended_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &sess.id.bytes);
        try stmt.bindBlob(2, &sess.task_id.bytes);
        try stmt.bindOptionalText(3, sess.agent_type);
        try stmt.bindOptionalText(4, sess.model_version);
        try stmt.bindOptionalText(5, sess.environment_fingerprint);
        try stmt.bindOptionalText(6, sess.initial_prompt);
        try stmt.bindOptionalText(7, if (sess.exit_reason) |r| r.toStr() else null);
        try stmt.bindInt64(8, sess.started_at);
        try stmt.bindOptionalInt64(9, sess.ended_at);
        _ = try stmt.step();
    }

    pub fn endSession(self: *Store, id: Ulid, exit_reason: ExitReason) StoreError!void {
        var stmt = try self.db.prepare(
            "UPDATE sessions SET exit_reason = ?1, ended_at = ?2 WHERE id = ?3",
        );
        defer stmt.finalize();
        try stmt.bindText(1, exit_reason.toStr());
        try stmt.bindInt64(2, std.time.milliTimestamp());
        try stmt.bindBlob(3, &id.bytes);
        _ = try stmt.step();
    }

    pub fn getSessionsByTask(self: *Store, task_id: Ulid, buf: []Session) StoreError![]Session {
        const stmt = try self.getCached(
            &self.cached_sessions_by_task,
            "SELECT id, task_id, agent_type, model_version, environment_fingerprint, initial_prompt, exit_reason, started_at, ended_at FROM sessions WHERE task_id = ?1 ORDER BY started_at",
        );
        try stmt.bindBlob(1, &task_id.bytes);

        var count: usize = 0;
        while (count < buf.len) {
            const result = try stmt.step();
            if (result != .row) break;
            buf[count] = .{
                .id = readUlid(stmt, 0),
                .task_id = readUlid(stmt, 1),
                .agent_type = try self.dupeOptionalText(stmt.columnText(2)),
                .model_version = try self.dupeOptionalText(stmt.columnText(3)),
                .environment_fingerprint = try self.dupeOptionalText(stmt.columnText(4)),
                .initial_prompt = try self.dupeOptionalText(stmt.columnText(5)),
                .exit_reason = if (stmt.columnText(6)) |r| (ExitReason.fromStr(r) catch null) else null,
                .started_at = stmt.columnInt64(7),
                .ended_at = blk: {
                    const val = stmt.columnInt64(8);
                    break :blk if (val == 0) null else val;
                },
            };
            count += 1;
        }
        if (count == buf.len) {
            const extra = try stmt.step();
            if (extra == .row) {
                std.log.warn("getSessionsByTask: buffer full ({d}), results truncated", .{buf.len});
            }
        }
        return buf[0..count];
    }

    // ── Event CRUD ──

    pub fn insertEvent(self: *Store, event: Event) StoreError!void {
        const stmt = try self.getCached(
            &self.cached_insert_event,
            "INSERT INTO events (id, session_id, kind, data, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
        );
        try stmt.bindBlob(1, &event.id.bytes);
        try stmt.bindBlob(2, &event.session_id.bytes);
        try stmt.bindText(3, event.kind.toStr());
        try stmt.bindOptionalText(4, event.data);
        try stmt.bindInt64(5, event.created_at);
        _ = try stmt.step();
    }

    pub fn countEventsBySession(self: *Store, session_id: Ulid) StoreError!i64 {
        var stmt = try self.db.prepare("SELECT COUNT(*) FROM events WHERE session_id = ?1");
        defer stmt.finalize();
        try stmt.bindBlob(1, &session_id.bytes);
        _ = try stmt.step();
        return stmt.columnInt64(0);
    }

    pub fn getEventsBySession(self: *Store, session_id: Ulid, kind_filter: ?[]const u8, buf: []Event) StoreError![]Event {
        // Filtered queries use uncached prepare/finalize; unfiltered uses cached stmt
        var uncached_stmt: ?sqlite.Stmt = null;
        defer if (uncached_stmt) |*s| s.finalize();

        const stmt: *sqlite.Stmt = if (kind_filter) |_| blk: {
            uncached_stmt = try self.db.prepare(
                "SELECT id, session_id, kind, data, created_at FROM events WHERE session_id = ?1 AND kind = ?2 ORDER BY created_at LIMIT ?3",
            );
            break :blk &uncached_stmt.?;
        } else try self.getCached(
            &self.cached_events_by_session,
            "SELECT id, session_id, kind, data, created_at FROM events WHERE session_id = ?1 ORDER BY created_at LIMIT ?2",
        );

        try stmt.bindBlob(1, &session_id.bytes);
        if (kind_filter) |kf| {
            try stmt.bindText(2, kf);
            try stmt.bindInt(3, @intCast(buf.len));
        } else {
            try stmt.bindInt(2, @intCast(buf.len));
        }

        var count: usize = 0;
        while (count < buf.len) {
            const result = try stmt.step();
            if (result != .row) break;
            buf[count] = .{
                .id = readUlid(stmt, 0),
                .session_id = readUlid(stmt, 1),
                .kind = EventKind.fromStr(stmt.columnText(2) orelse "custom") catch .custom,
                .data = try self.dupeOptionalText(stmt.columnText(3)),
                .created_at = stmt.columnInt64(4),
            };
            count += 1;
        }

        return buf[0..count];
    }

    pub fn countErrorsByTask(self: *Store, task_id: Ulid) StoreError!i64 {
        var stmt = try self.db.prepare(
            "SELECT COUNT(*) FROM events e JOIN sessions s ON e.session_id = s.id WHERE s.task_id = ?1 AND e.kind = 'error'",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &task_id.bytes);
        _ = try stmt.step();
        return stmt.columnInt64(0);
    }

    // ── Evidence CRUD ──

    pub fn insertEvidence(self: *Store, ev: Evidence) StoreError!void {
        var stmt = try self.db.prepare(
            "INSERT INTO evidence (id, task_id, kind, status, hash, summary, raw_path, recorded_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &ev.id.bytes);
        try stmt.bindBlob(2, &ev.task_id.bytes);
        try stmt.bindText(3, ev.kind.toStr());
        try stmt.bindText(4, ev.status.toStr());
        try stmt.bindOptionalText(5, ev.hash);
        try stmt.bindOptionalText(6, ev.summary);
        try stmt.bindOptionalText(7, ev.raw_path);
        try stmt.bindInt64(8, ev.recorded_at);
        _ = try stmt.step();
        // Index evidence summary into FTS
        if (ev.summary) |s| {
            var lookup = self.db.prepare("SELECT goal_id FROM tasks WHERE id = ?1") catch return;
            defer lookup.finalize();
            lookup.bindBlob(1, &ev.task_id.bytes) catch return;
            if ((lookup.step() catch return) == .row) {
                const goal_id = readUlid(&lookup, 0);
                self.indexEntity("evidence", ev.id, goal_id, s);
            }
        }
    }

    pub fn getEvidenceByTask(self: *Store, task_id: Ulid, buf: []Evidence) StoreError![]Evidence {
        const stmt = try self.getCached(
            &self.cached_evidence_by_task,
            "SELECT id, task_id, kind, status, hash, summary, raw_path, recorded_at FROM evidence WHERE task_id = ?1 ORDER BY recorded_at",
        );
        try stmt.bindBlob(1, &task_id.bytes);

        var count: usize = 0;
        while (count < buf.len) {
            const result = try stmt.step();
            if (result != .row) break;
            buf[count] = .{
                .id = readUlid(stmt, 0),
                .task_id = readUlid(stmt, 1),
                .kind = EvidenceKind.fromStr(stmt.columnText(2) orelse "custom") catch .custom,
                .status = EvidenceStatus.fromStr(stmt.columnText(3) orelse "error") catch .@"error",
                .hash = try self.dupeOptionalText(stmt.columnText(4)),
                .summary = try self.dupeOptionalText(stmt.columnText(5)),
                .raw_path = try self.dupeOptionalText(stmt.columnText(6)),
                .recorded_at = stmt.columnInt64(7),
            };
            count += 1;
        }
        if (count == buf.len) {
            const extra = try stmt.step();
            if (extra == .row) {
                std.log.warn("getEvidenceByTask: buffer full ({d}), results truncated", .{buf.len});
            }
        }
        return buf[0..count];
    }

    // ── Goal queries ──

    pub fn getAllGoals(self: *Store, buf: []Goal) StoreError![]Goal {
        var stmt = try self.db.prepare(
            "SELECT id, description, base_commit, base_branch, status, resolved_task_id, dispatch_id, created_at, updated_at FROM goals ORDER BY created_at DESC",
        );
        defer stmt.finalize();

        var count: usize = 0;
        while (count < buf.len) {
            const result = try stmt.step();
            if (result != .row) break;
            buf[count] = try self.readGoal(&stmt);
            count += 1;
        }
        if (count == buf.len) {
            const extra = try stmt.step();
            if (extra == .row) {
                std.log.warn("getAllGoals: buffer full ({d}), results truncated", .{buf.len});
            }
        }
        return buf[0..count];
    }

    pub fn getResolvedGoalIds(self: *Store, buf: []Ulid) StoreError![]Ulid {
        var stmt = try self.db.prepare(
            "SELECT id FROM goals WHERE status = 'resolved'",
        );
        defer stmt.finalize();

        var count: usize = 0;
        while (count < buf.len) {
            const result = try stmt.step();
            if (result != .row) break;
            buf[count] = readUlid(&stmt, 0);
            count += 1;
        }
        if (count == buf.len) {
            const extra = try stmt.step();
            if (extra == .row) {
                std.log.warn("getResolvedGoalIds: buffer full ({d}), results truncated", .{buf.len});
            }
        }
        return buf[0..count];
    }

    // ── Ingest offset tracking ──

    pub fn getIngestOffset(self: *Store, file_name: []const u8) StoreError!usize {
        var stmt = try self.db.prepare("SELECT byte_offset FROM ingest_offsets WHERE file_name = ?1");
        defer stmt.finalize();
        try stmt.bindText(1, file_name);
        const result = try stmt.step();
        if (result != .row) return 0;
        return @intCast(stmt.columnInt64(0));
    }

    pub fn setIngestOffset(self: *Store, file_name: []const u8, offset: usize) StoreError!void {
        var stmt = try self.db.prepare(
            "INSERT OR REPLACE INTO ingest_offsets (file_name, byte_offset, updated_at) VALUES (?1, ?2, ?3)",
        );
        defer stmt.finalize();
        try stmt.bindText(1, file_name);
        try stmt.bindInt64(2, @intCast(offset));
        try stmt.bindInt64(3, std.time.milliTimestamp());
        _ = try stmt.step();
    }

    // ── FTS5 full-text search ──

    pub const SearchResult = struct {
        entity_type: []const u8,
        entity_id: []const u8,
        goal_id: []const u8,
        snippet: []const u8,
        rank: f64,
    };

    /// Full-text search across the context_fts index. Returns ranked results with snippets.
    pub fn searchFts(self: *Store, query: []const u8, buf: []SearchResult) StoreError![]SearchResult {
        var stmt = try self.db.prepare(
            "SELECT entity_type, entity_id, goal_id, snippet(context_fts, 4, '\xc2\xbb', '\xc2\xab', '\xe2\x80\xa6', 24), rank FROM context_fts WHERE context_fts MATCH ?1 ORDER BY rank LIMIT ?2",
        );
        defer stmt.finalize();
        try stmt.bindText(1, query);
        try stmt.bindInt(2, @intCast(buf.len));

        var count: usize = 0;
        while (count < buf.len) {
            const result = try stmt.step();
            if (result != .row) break;
            buf[count] = .{
                .entity_type = try self.dupeText(stmt.columnText(0)),
                .entity_id = try self.dupeText(stmt.columnText(1)),
                .goal_id = try self.dupeText(stmt.columnText(2)),
                .snippet = try self.dupeText(stmt.columnText(3)),
                .rank = stmt.columnDouble(4),
            };
            count += 1;
        }
        return buf[0..count];
    }

    /// Insert a single entity into the FTS index. Silently ignores failures
    /// (e.g., FTS table doesn't exist in old DBs).
    fn indexEntity(self: *Store, entity_type: []const u8, entity_id: Ulid, goal_id: Ulid, content: []const u8) void {
        if (content.len == 0) return;
        var stmt = self.db.prepare(
            "INSERT INTO context_fts (entity_type, entity_id, goal_id, source, content) VALUES (?1, ?2, ?3, 'db', ?4)",
        ) catch return;
        defer stmt.finalize();
        const eid = entity_id.encode();
        const gid = goal_id.encode();
        stmt.bindText(1, entity_type) catch return;
        stmt.bindText(2, &eid) catch return;
        stmt.bindText(3, &gid) catch return;
        stmt.bindText(4, content) catch return;
        _ = stmt.step() catch return;
    }

    /// Rebuild the FTS index from all DB data (goals, tasks, evidence).
    pub fn indexForSearch(self: *Store) StoreError!void {
        try self.db.exec("BEGIN");
        errdefer self.db.exec("ROLLBACK") catch {};

        try self.db.exec("DELETE FROM context_fts WHERE source = 'db'");

        // Index goals
        {
            var stmt = try self.db.prepare("SELECT id, description FROM goals");
            defer stmt.finalize();
            while (true) {
                const result = try stmt.step();
                if (result != .row) break;
                const id = readUlid(&stmt, 0);
                const desc = stmt.columnText(1) orelse continue;
                self.indexEntity("goal", id, id, desc);
            }
        }

        // Index tasks (approach + summary as separate rows)
        {
            var stmt = try self.db.prepare("SELECT id, goal_id, approach, summary FROM tasks");
            defer stmt.finalize();
            while (true) {
                const result = try stmt.step();
                if (result != .row) break;
                const id = readUlid(&stmt, 0);
                const goal_id = readUlid(&stmt, 1);
                if (stmt.columnText(2)) |approach| {
                    self.indexEntity("task", id, goal_id, approach);
                }
                if (stmt.columnText(3)) |summary| {
                    self.indexEntity("task", id, goal_id, summary);
                }
            }
        }

        // Index evidence
        {
            var stmt = try self.db.prepare(
                "SELECT ev.id, t.goal_id, ev.summary FROM evidence ev JOIN tasks t ON ev.task_id = t.id",
            );
            defer stmt.finalize();
            while (true) {
                const result = try stmt.step();
                if (result != .row) break;
                const id = readUlid(&stmt, 0);
                const goal_id = readUlid(&stmt, 1);
                if (stmt.columnText(2)) |summary| {
                    self.indexEntity("evidence", id, goal_id, summary);
                }
            }
        }

        try self.db.exec("COMMIT");
    }

    /// Index shared .agx/context/ files into the FTS index with source='file'.
    pub fn indexContextFiles(self: *Store, context_dir: []const u8) StoreError!void {
        try self.db.exec("DELETE FROM context_fts WHERE source = 'file'");

        const fm_mod = @import("../util/frontmatter.zig");

        var dir = std.fs.cwd().openDir(context_dir, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch return) |entry| {
            if (entry.kind != .directory) continue;

            const summary_path = std.fmt.allocPrint(self.alloc, "{s}/{s}/summary.md", .{ context_dir, entry.name }) catch continue;
            const content = std.fs.cwd().readFileAlloc(self.alloc, summary_path, 1024 * 1024) catch continue;
            const parsed = fm_mod.parseFrontmatter(content);

            const goal_id_str = parsed.fm.goal_id orelse entry.name;

            // Index the description
            if (parsed.fm.description) |desc| {
                var stmt = self.db.prepare(
                    "INSERT INTO context_fts (entity_type, entity_id, goal_id, source, content) VALUES ('goal', ?1, ?1, 'file', ?2)",
                ) catch continue;
                defer stmt.finalize();
                stmt.bindText(1, goal_id_str) catch continue;
                stmt.bindText(2, desc) catch continue;
                _ = stmt.step() catch continue;
            }

            // Index the body content
            const body = content[parsed.body_start..];
            if (body.len > 0) {
                var stmt = self.db.prepare(
                    "INSERT INTO context_fts (entity_type, entity_id, goal_id, source, content) VALUES ('context', ?1, ?1, 'file', ?2)",
                ) catch continue;
                defer stmt.finalize();
                stmt.bindText(1, goal_id_str) catch continue;
                stmt.bindText(2, body) catch continue;
                _ = stmt.step() catch continue;
            }
        }
    }

    /// Count the total number of rows in the FTS index.
    pub fn countFtsEntries(self: *Store) StoreError!i64 {
        var stmt = try self.db.prepare("SELECT COUNT(*) FROM context_fts");
        defer stmt.finalize();
        _ = try stmt.step();
        return stmt.columnInt64(0);
    }

    // ── Dispatch CRUD ──

    pub fn insertDispatch(self: *Store, d: Dispatch) StoreError!void {
        var stmt = try self.db.prepare(
            "INSERT INTO dispatches (id, description, base_commit, base_branch, status, merge_policy, merge_order, merge_progress, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &d.id.bytes);
        try stmt.bindText(2, d.description);
        try stmt.bindText(3, d.base_commit);
        try stmt.bindText(4, d.base_branch);
        try stmt.bindText(5, d.status.toStr());
        try stmt.bindText(6, d.merge_policy.toStr());
        try stmt.bindOptionalText(7, d.merge_order);
        try stmt.bindInt64(8, @intCast(d.merge_progress));
        try stmt.bindInt64(9, d.created_at);
        try stmt.bindInt64(10, d.updated_at);
        _ = try stmt.step();
    }

    pub fn getDispatch(self: *Store, id: Ulid) StoreError!Dispatch {
        var stmt = try self.db.prepare(
            "SELECT id, description, base_commit, base_branch, status, merge_policy, merge_order, merge_progress, created_at, updated_at FROM dispatches WHERE id = ?1",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &id.bytes);
        const result = try stmt.step();
        if (result != .row) return error.NotFound;
        return self.readDispatch(&stmt);
    }

    pub fn getActiveDispatch(self: *Store) StoreError!Dispatch {
        var stmt = try self.db.prepare(
            "SELECT id, description, base_commit, base_branch, status, merge_policy, merge_order, merge_progress, created_at, updated_at FROM dispatches WHERE status IN ('active', 'merging', 'conflict') ORDER BY created_at DESC LIMIT 1",
        );
        defer stmt.finalize();
        const result = try stmt.step();
        if (result != .row) return error.NotFound;
        return self.readDispatch(&stmt);
    }

    pub fn updateDispatchStatus(self: *Store, id: Ulid, status: DispatchStatus) StoreError!void {
        var stmt = try self.db.prepare(
            "UPDATE dispatches SET status = ?1, updated_at = ?2 WHERE id = ?3",
        );
        defer stmt.finalize();
        try stmt.bindText(1, status.toStr());
        try stmt.bindInt64(2, std.time.milliTimestamp());
        try stmt.bindBlob(3, &id.bytes);
        _ = try stmt.step();
    }

    pub fn updateDispatchMergeProgress(self: *Store, id: Ulid, progress: u32) StoreError!void {
        var stmt = try self.db.prepare(
            "UPDATE dispatches SET merge_progress = ?1, updated_at = ?2 WHERE id = ?3",
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, @intCast(progress));
        try stmt.bindInt64(2, std.time.milliTimestamp());
        try stmt.bindBlob(3, &id.bytes);
        _ = try stmt.step();
    }

    pub fn updateDispatchMergeOrder(self: *Store, id: Ulid, merge_order: []const u8) StoreError!void {
        var stmt = try self.db.prepare(
            "UPDATE dispatches SET merge_order = ?1, updated_at = ?2 WHERE id = ?3",
        );
        defer stmt.finalize();
        try stmt.bindText(1, merge_order);
        try stmt.bindInt64(2, std.time.milliTimestamp());
        try stmt.bindBlob(3, &id.bytes);
        _ = try stmt.step();
    }

    pub fn getAllDispatches(self: *Store, buf: []Dispatch) StoreError![]Dispatch {
        var stmt = try self.db.prepare(
            "SELECT id, description, base_commit, base_branch, status, merge_policy, merge_order, merge_progress, created_at, updated_at FROM dispatches ORDER BY created_at DESC",
        );
        defer stmt.finalize();

        var count: usize = 0;
        while (count < buf.len) {
            const result = try stmt.step();
            if (result != .row) break;
            buf[count] = try self.readDispatch(&stmt);
            count += 1;
        }
        if (count == buf.len) {
            const extra = try stmt.step();
            if (extra == .row) {
                std.log.warn("getAllDispatches: buffer full ({d}), results truncated", .{buf.len});
            }
        }
        return buf[0..count];
    }

    /// Delete a dispatch and all its child records.
    /// Caller must pass pre-fetched task and session IDs to avoid
    /// read locks from cached statements.
    /// Delete order respects FK constraints:
    ///   events/snapshots -> sessions -> evidence -> tasks -> goals -> dispatches
    pub fn deleteDispatch(self: *Store, dispatch_id: Ulid, task_ids: []const Ulid, session_ids: []const Ulid) StoreError!void {
        // Reset cached statements to release any read locks
        if (self.cached_tasks_by_goal) |*s| s.reset();
        if (self.cached_sessions_by_task) |*s| s.reset();
        if (self.cached_events_by_session) |*s| s.reset();
        if (self.cached_evidence_by_task) |*s| s.reset();

        // 1. Delete events and snapshots (reference sessions)
        for (session_ids) |sid| {
            self.deleteByBlob("DELETE FROM events WHERE session_id = ?1", &sid.bytes) catch {};
            self.deleteByBlob("DELETE FROM snapshots WHERE session_id = ?1", &sid.bytes) catch {};
        }
        // 2. Delete sessions (reference tasks)
        for (task_ids) |tid| {
            self.deleteByBlob("DELETE FROM sessions WHERE task_id = ?1", &tid.bytes) catch {};
        }
        // 3. Delete evidence (reference tasks)
        for (task_ids) |tid| {
            self.deleteByBlob("DELETE FROM evidence WHERE task_id = ?1", &tid.bytes) catch {};
        }
        // 4. Delete tasks (reference goals)
        for (task_ids) |tid| {
            self.deleteByBlob("DELETE FROM tasks WHERE id = ?1", &tid.bytes) catch {};
        }
        // 5. Delete goals (reference dispatches)
        self.deleteByBlob("DELETE FROM goals WHERE dispatch_id = ?1", &dispatch_id.bytes) catch {};
        // 6. Delete the dispatch
        self.deleteByBlob("DELETE FROM dispatches WHERE id = ?1", &dispatch_id.bytes) catch {};
    }

    fn deleteByBlob(self: *Store, sql: [:0]const u8, blob: []const u8) StoreError!void {
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindBlob(1, blob);
        _ = try stmt.step();
    }

    pub fn getGoalsByDispatch(self: *Store, dispatch_id: Ulid, buf: []Goal) StoreError![]Goal {
        var stmt = try self.db.prepare(
            "SELECT id, description, base_commit, base_branch, status, resolved_task_id, dispatch_id, created_at, updated_at FROM goals WHERE dispatch_id = ?1 ORDER BY created_at",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &dispatch_id.bytes);

        var count: usize = 0;
        while (count < buf.len) {
            const result = try stmt.step();
            if (result != .row) break;
            buf[count] = try self.readGoal(&stmt);
            count += 1;
        }
        if (count == buf.len) {
            const extra = try stmt.step();
            if (extra == .row) {
                std.log.warn("getGoalsByDispatch: buffer full ({d}), results truncated", .{buf.len});
            }
        }
        return buf[0..count];
    }

    fn readDispatch(self: *Store, stmt: *sqlite.Stmt) StoreError!Dispatch {
        return .{
            .id = readUlid(stmt, 0),
            .description = try self.dupeText(stmt.columnText(1)),
            .base_commit = try self.dupeText(stmt.columnText(2)),
            .base_branch = try self.dupeText(stmt.columnText(3)),
            .status = DispatchStatus.fromStr(stmt.columnText(4) orelse "active") catch .active,
            .merge_policy = MergePolicy.fromStr(stmt.columnText(5) orelse "semi") catch .semi,
            .merge_order = try self.dupeOptionalText(stmt.columnText(6)),
            .merge_progress = @intCast(stmt.columnInt64(7)),
            .created_at = stmt.columnInt64(8),
            .updated_at = stmt.columnInt64(9),
        };
    }

    // ── Snapshot CRUD ──

    pub fn insertSnapshot(self: *Store, snap: Snapshot) StoreError!void {
        var stmt = try self.db.prepare(
            "INSERT INTO snapshots (id, session_id, commit_sha, summary, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &snap.id.bytes);
        try stmt.bindBlob(2, &snap.session_id.bytes);
        try stmt.bindText(3, snap.commit_sha);
        try stmt.bindOptionalText(4, snap.summary);
        try stmt.bindInt64(5, snap.created_at);
        _ = try stmt.step();
    }
};

// ── Tests ──

test "store init and migrate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = try Store.init(arena.allocator(), ":memory:");
    defer store.deinit();
}

test "goal roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = try Store.init(arena.allocator(), ":memory:");
    defer store.deinit();

    const now = std.time.milliTimestamp();
    const id = Ulid.new();
    const g = Goal{
        .id = id,
        .description = "refactor auth",
        .base_commit = "abc123",
        .base_branch = "main",
        .status = .active,
        .resolved_task_id = null,
        .dispatch_id = null,
        .created_at = now,
        .updated_at = now,
    };
    try store.insertGoal(g);

    const got = try store.getGoal(id);
    try std.testing.expectEqualSlices(u8, "refactor auth", got.description);
    try std.testing.expectEqual(GoalStatus.active, got.status);
}

test "task roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = try Store.init(arena.allocator(), ":memory:");
    defer store.deinit();

    const now = std.time.milliTimestamp();
    const goal_id = Ulid.new();
    try store.insertGoal(.{
        .id = goal_id,
        .description = "test",
        .base_commit = "abc",
        .base_branch = "main",
        .status = .active,
        .resolved_task_id = null,
        .dispatch_id = null,
        .created_at = now,
        .updated_at = now,
    });

    const task_id = Ulid.new();
    try store.insertTask(.{
        .id = task_id,
        .goal_id = goal_id,
        .index = 1,
        .worktree_path = "/tmp/wt1",
        .branch_name = "agx/ABC/1",
        .status = .active,
        .approach = "middleware extraction",
        .summary = null,
        .created_at = now,
        .updated_at = now,
    });

    var buf: [16]Task = undefined;
    const tasks = try store.getTasksByGoal(goal_id, &buf);
    try std.testing.expectEqual(@as(usize, 1), tasks.len);
    try std.testing.expectEqualSlices(u8, "middleware extraction", tasks[0].approach.?);
}

test "FTS search" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = try Store.init(arena.allocator(), ":memory:");
    defer store.deinit();

    const now = std.time.milliTimestamp();
    const goal_id = Ulid.new();
    try store.insertGoal(.{
        .id = goal_id,
        .description = "refactor authentication middleware",
        .base_commit = "abc",
        .base_branch = "main",
        .status = .active,
        .resolved_task_id = null,
        .dispatch_id = null,
        .created_at = now,
        .updated_at = now,
    });

    const task_id = Ulid.new();
    try store.insertTask(.{
        .id = task_id,
        .goal_id = goal_id,
        .index = 1,
        .worktree_path = "/tmp/wt1",
        .branch_name = "agx/ABC/1",
        .status = .active,
        .approach = "extract JWT validation into separate module",
        .summary = null,
        .created_at = now,
        .updated_at = now,
    });

    try store.insertEvidence(.{
        .id = Ulid.new(),
        .task_id = task_id,
        .kind = .test_result,
        .status = .pass,
        .hash = null,
        .summary = "all authentication tests passing",
        .raw_path = null,
        .recorded_at = now,
    });

    // Rebuild full index
    try store.indexForSearch();

    // Search for "authentication" — should find goal + evidence
    var buf: [10]Store.SearchResult = undefined;
    const results = try store.searchFts("authentication", &buf);
    try std.testing.expect(results.len >= 2);

    // Search for "JWT" — should find task approach
    const jwt_results = try store.searchFts("JWT", &buf);
    try std.testing.expect(jwt_results.len >= 1);
    try std.testing.expectEqualSlices(u8, "task", jwt_results[0].entity_type);

    // Search for something not indexed
    const no_results = try store.searchFts("nonexistent", &buf);
    try std.testing.expectEqual(@as(usize, 0), no_results.len);
}

test "incremental FTS indexing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = try Store.init(arena.allocator(), ":memory:");
    defer store.deinit();

    const now = std.time.milliTimestamp();
    const goal_id = Ulid.new();
    try store.insertGoal(.{
        .id = goal_id,
        .description = "implement websocket support",
        .base_commit = "def456",
        .base_branch = "main",
        .status = .active,
        .resolved_task_id = null,
        .dispatch_id = null,
        .created_at = now,
        .updated_at = now,
    });

    // Goal should be searchable immediately (incremental index)
    var buf: [10]Store.SearchResult = undefined;
    const results = try store.searchFts("websocket", &buf);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualSlices(u8, "goal", results[0].entity_type);
}

test "evidence roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = try Store.init(arena.allocator(), ":memory:");
    defer store.deinit();

    const now = std.time.milliTimestamp();
    const goal_id = Ulid.new();
    try store.insertGoal(.{
        .id = goal_id,
        .description = "test",
        .base_commit = "abc",
        .base_branch = "main",
        .status = .active,
        .resolved_task_id = null,
        .dispatch_id = null,
        .created_at = now,
        .updated_at = now,
    });

    const task_id = Ulid.new();
    try store.insertTask(.{
        .id = task_id,
        .goal_id = goal_id,
        .index = 1,
        .worktree_path = "/tmp/wt1",
        .branch_name = "agx/ABC/1",
        .status = .active,
        .approach = null,
        .summary = null,
        .created_at = now,
        .updated_at = now,
    });

    try store.insertEvidence(.{
        .id = Ulid.new(),
        .task_id = task_id,
        .kind = .test_result,
        .status = .pass,
        .hash = "sha256:abc",
        .summary = "47/47 tests passed",
        .raw_path = null,
        .recorded_at = now,
    });

    var buf: [16]Evidence = undefined;
    const evs = try store.getEvidenceByTask(task_id, &buf);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqualSlices(u8, "47/47 tests passed", evs[0].summary.?);
}

test "dispatch and getGoalsByDispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = try Store.init(arena.allocator(), ":memory:");
    defer store.deinit();

    const now = std.time.milliTimestamp();
    const dispatch_id = Ulid.new();

    try store.insertDispatch(.{
        .id = dispatch_id,
        .description = "Dispatch of 2 goals",
        .base_commit = "abc123",
        .base_branch = "main",
        .status = .active,
        .merge_policy = .semi,
        .merge_order = null,
        .merge_progress = 0,
        .created_at = now,
        .updated_at = now,
    });

    // Create two goals in the dispatch
    const goal1_id = Ulid.new();
    try store.insertGoal(.{
        .id = goal1_id,
        .description = "add auth",
        .base_commit = "abc123",
        .base_branch = "main",
        .status = .active,
        .resolved_task_id = null,
        .dispatch_id = dispatch_id,
        .created_at = now,
        .updated_at = now,
    });

    const goal2_id = Ulid.new();
    try store.insertGoal(.{
        .id = goal2_id,
        .description = "add logging",
        .base_commit = "abc123",
        .base_branch = "main",
        .status = .active,
        .resolved_task_id = null,
        .dispatch_id = dispatch_id,
        .created_at = now + 1,
        .updated_at = now + 1,
    });

    // Also create a goal NOT in the dispatch
    try store.insertGoal(.{
        .id = Ulid.new(),
        .description = "unrelated goal",
        .base_commit = "abc123",
        .base_branch = "main",
        .status = .active,
        .resolved_task_id = null,
        .dispatch_id = null,
        .created_at = now,
        .updated_at = now,
    });

    // Verify dispatch roundtrip
    const got_dispatch = try store.getDispatch(dispatch_id);
    try std.testing.expectEqualSlices(u8, "Dispatch of 2 goals", got_dispatch.description);
    try std.testing.expectEqual(DispatchStatus.active, got_dispatch.status);
    try std.testing.expectEqual(MergePolicy.semi, got_dispatch.merge_policy);

    // Verify getGoalsByDispatch returns only the 2 dispatch goals
    var goal_buf: [16]Goal = undefined;
    const goals = try store.getGoalsByDispatch(dispatch_id, &goal_buf);
    try std.testing.expectEqual(@as(usize, 2), goals.len);
    try std.testing.expectEqualSlices(u8, "add auth", goals[0].description);
    try std.testing.expectEqualSlices(u8, "add logging", goals[1].description);

    // Verify dispatch_id is set on retrieved goals
    try std.testing.expect(goals[0].dispatch_id != null);

    // Verify getActiveDispatch works
    const active = try store.getActiveDispatch();
    try std.testing.expectEqualSlices(u8, "Dispatch of 2 goals", active.description);

    // Update status and verify
    try store.updateDispatchStatus(dispatch_id, .completed);
    const updated = try store.getDispatch(dispatch_id);
    try std.testing.expectEqual(DispatchStatus.completed, updated.status);

    // Update merge order
    try store.updateDispatchMergeOrder(dispatch_id, "[\"id1\",\"id2\"]");
    const with_order = try store.getDispatch(dispatch_id);
    try std.testing.expectEqualSlices(u8, "[\"id1\",\"id2\"]", with_order.merge_order.?);
}
