const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const migrations = @import("migrations.zig").migrations;
const Ulid = @import("../core/ulid.zig").Ulid;
const Task = @import("../core/task.zig").Task;
const TaskStatus = @import("../core/task.zig").TaskStatus;
const Batch = @import("../core/batch.zig").Batch;
const BatchStatus = @import("../core/batch.zig").BatchStatus;
const MergePolicy = @import("../core/batch.zig").MergePolicy;
const Exploration = @import("../core/exploration.zig").Exploration;
const ExplorationStatus = @import("../core/exploration.zig").ExplorationStatus;
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
    cached_exps_by_task: ?sqlite.Stmt = null,
    cached_sessions_by_exp: ?sqlite.Stmt = null,
    cached_events_by_session: ?sqlite.Stmt = null,
    cached_evidence_by_exp: ?sqlite.Stmt = null,

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
        if (self.cached_exps_by_task) |*s| s.finalize();
        if (self.cached_sessions_by_exp) |*s| s.finalize();
        if (self.cached_events_by_session) |*s| s.finalize();
        if (self.cached_evidence_by_exp) |*s| s.finalize();
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

    // ── Task CRUD ──

    pub fn insertTask(self: *Store, task: Task) StoreError!void {
        var stmt = try self.db.prepare(
            "INSERT INTO tasks (id, description, base_commit, base_branch, status, resolved_exploration_id, batch_id, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &task.id.bytes);
        try stmt.bindText(2, task.description);
        try stmt.bindText(3, task.base_commit);
        try stmt.bindText(4, task.base_branch);
        try stmt.bindText(5, task.status.toStr());
        try stmt.bindOptionalBlob(6, if (task.resolved_exploration_id) |r| &r.bytes else null);
        try stmt.bindOptionalBlob(7, if (task.batch_id) |b| &b.bytes else null);
        try stmt.bindInt64(8, task.created_at);
        try stmt.bindInt64(9, task.updated_at);
        _ = try stmt.step();
        self.indexEntity("task", task.id, task.id, task.description);
    }

    pub fn getTask(self: *Store, id: Ulid) StoreError!Task {
        var stmt = try self.db.prepare(
            "SELECT id, description, base_commit, base_branch, status, resolved_exploration_id, batch_id, created_at, updated_at FROM tasks WHERE id = ?1",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &id.bytes);
        const result = try stmt.step();
        if (result != .row) return error.NotFound;
        return self.readTask(&stmt);
    }

    pub fn getActiveTask(self: *Store) StoreError!Task {
        var stmt = try self.db.prepare(
            "SELECT id, description, base_commit, base_branch, status, resolved_exploration_id, batch_id, created_at, updated_at FROM tasks WHERE status = 'active' ORDER BY created_at DESC LIMIT 1",
        );
        defer stmt.finalize();
        const result = try stmt.step();
        if (result != .row) return error.NotFound;
        return self.readTask(&stmt);
    }

    pub fn updateTaskStatus(self: *Store, id: Ulid, status: TaskStatus, resolved_exploration_id: ?Ulid) StoreError!void {
        var stmt = try self.db.prepare(
            "UPDATE tasks SET status = ?1, resolved_exploration_id = ?2, updated_at = ?3 WHERE id = ?4",
        );
        defer stmt.finalize();
        try stmt.bindText(1, status.toStr());
        try stmt.bindOptionalBlob(2, if (resolved_exploration_id) |r| &r.bytes else null);
        try stmt.bindInt64(3, std.time.milliTimestamp());
        try stmt.bindBlob(4, &id.bytes);
        _ = try stmt.step();
    }

    fn readTask(self: *Store, stmt: *sqlite.Stmt) StoreError!Task {
        const resolved_blob = stmt.columnBlob(5);
        const batch_blob = stmt.columnBlob(6);
        return .{
            .id = readUlid(stmt, 0),
            .description = try self.dupeText(stmt.columnText(1)),
            .base_commit = try self.dupeText(stmt.columnText(2)),
            .base_branch = try self.dupeText(stmt.columnText(3)),
            .status = TaskStatus.fromStr(stmt.columnText(4) orelse "active") catch .active,
            .resolved_exploration_id = if (resolved_blob) |b| blk: {
                break :blk if (b.len >= 16) Ulid{ .bytes = b[0..16].* } else null;
            } else null,
            .batch_id = if (batch_blob) |b| blk: {
                break :blk if (b.len >= 16) Ulid{ .bytes = b[0..16].* } else null;
            } else null,
            .created_at = stmt.columnInt64(7),
            .updated_at = stmt.columnInt64(8),
        };
    }

    // ── Exploration CRUD ──

    pub fn insertExploration(self: *Store, exp: Exploration) StoreError!void {
        var stmt = try self.db.prepare(
            "INSERT INTO explorations (id, task_id, idx, worktree_path, branch_name, status, approach, summary, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &exp.id.bytes);
        try stmt.bindBlob(2, &exp.task_id.bytes);
        try stmt.bindInt(3, @intCast(exp.index));
        try stmt.bindText(4, exp.worktree_path);
        try stmt.bindText(5, exp.branch_name);
        try stmt.bindText(6, exp.status.toStr());
        try stmt.bindOptionalText(7, exp.approach);
        try stmt.bindOptionalText(8, exp.summary);
        try stmt.bindInt64(9, exp.created_at);
        try stmt.bindInt64(10, exp.updated_at);
        _ = try stmt.step();
    }

    pub fn getExplorationsByTask(self: *Store, task_id: Ulid, buf: []Exploration) StoreError![]Exploration {
        const stmt = try self.getCached(
            &self.cached_exps_by_task,
            "SELECT id, task_id, idx, worktree_path, branch_name, status, approach, summary, created_at, updated_at FROM explorations WHERE task_id = ?1 ORDER BY idx",
        );
        try stmt.bindBlob(1, &task_id.bytes);

        var count: usize = 0;
        while (count < buf.len) {
            const result = try stmt.step();
            if (result != .row) break;
            buf[count] = try self.readExploration(stmt);
            count += 1;
        }
        if (count == buf.len) {
            const extra = try stmt.step();
            if (extra == .row) {
                std.log.warn("getExplorationsByTask: buffer full ({d}), results truncated", .{buf.len});
            }
        }
        return buf[0..count];
    }

    pub fn getExplorationByIndex(self: *Store, task_id: Ulid, index: u32) StoreError!Exploration {
        var stmt = try self.db.prepare(
            "SELECT id, task_id, idx, worktree_path, branch_name, status, approach, summary, created_at, updated_at FROM explorations WHERE task_id = ?1 AND idx = ?2",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &task_id.bytes);
        try stmt.bindInt(2, @intCast(index));
        const result = try stmt.step();
        if (result != .row) return error.NotFound;
        return self.readExploration(&stmt);
    }

    pub fn updateExplorationStatus(self: *Store, id: Ulid, status: ExplorationStatus, summary: ?[]const u8) StoreError!void {
        var stmt = try self.db.prepare(
            "UPDATE explorations SET status = ?1, summary = COALESCE(?2, summary), updated_at = ?3 WHERE id = ?4",
        );
        defer stmt.finalize();
        try stmt.bindText(1, status.toStr());
        try stmt.bindOptionalText(2, summary);
        try stmt.bindInt64(3, std.time.milliTimestamp());
        try stmt.bindBlob(4, &id.bytes);
        _ = try stmt.step();
        // Index summary into FTS — need task_id from DB
        if (summary) |s| {
            var lookup = self.db.prepare("SELECT task_id FROM explorations WHERE id = ?1") catch return;
            defer lookup.finalize();
            lookup.bindBlob(1, &id.bytes) catch return;
            if ((lookup.step() catch return) == .row) {
                const task_id = readUlid(&lookup, 0);
                self.indexEntity("exploration", id, task_id, s);
            }
        }
    }

    pub fn updateExplorationApproach(self: *Store, id: Ulid, approach: []const u8) StoreError!void {
        var stmt = try self.db.prepare(
            "UPDATE explorations SET approach = ?1, updated_at = ?2 WHERE id = ?3",
        );
        defer stmt.finalize();
        try stmt.bindText(1, approach);
        try stmt.bindInt64(2, std.time.milliTimestamp());
        try stmt.bindBlob(3, &id.bytes);
        _ = try stmt.step();
        // Index approach into FTS — need task_id from DB
        var lookup = self.db.prepare("SELECT task_id FROM explorations WHERE id = ?1") catch return;
        defer lookup.finalize();
        lookup.bindBlob(1, &id.bytes) catch return;
        if ((lookup.step() catch return) == .row) {
            const task_id = readUlid(&lookup, 0);
            self.indexEntity("exploration", id, task_id, approach);
        }
    }

    fn readExploration(self: *Store, stmt: *sqlite.Stmt) StoreError!Exploration {
        return .{
            .id = readUlid(stmt, 0),
            .task_id = readUlid(stmt, 1),
            .index = @intCast(stmt.columnInt(2)),
            .worktree_path = try self.dupeText(stmt.columnText(3)),
            .branch_name = try self.dupeText(stmt.columnText(4)),
            .status = ExplorationStatus.fromStr(stmt.columnText(5) orelse "active") catch .active,
            .approach = try self.dupeOptionalText(stmt.columnText(6)),
            .summary = try self.dupeOptionalText(stmt.columnText(7)),
            .created_at = stmt.columnInt64(8),
            .updated_at = stmt.columnInt64(9),
        };
    }

    // ── Session CRUD ──

    pub fn insertSession(self: *Store, sess: Session) StoreError!void {
        var stmt = try self.db.prepare(
            "INSERT INTO sessions (id, exploration_id, agent_type, model_version, environment_fingerprint, initial_prompt, exit_reason, started_at, ended_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &sess.id.bytes);
        try stmt.bindBlob(2, &sess.exploration_id.bytes);
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

    pub fn getSessionsByExploration(self: *Store, exploration_id: Ulid, buf: []Session) StoreError![]Session {
        const stmt = try self.getCached(
            &self.cached_sessions_by_exp,
            "SELECT id, exploration_id, agent_type, model_version, environment_fingerprint, initial_prompt, exit_reason, started_at, ended_at FROM sessions WHERE exploration_id = ?1 ORDER BY started_at",
        );
        try stmt.bindBlob(1, &exploration_id.bytes);

        var count: usize = 0;
        while (count < buf.len) {
            const result = try stmt.step();
            if (result != .row) break;
            buf[count] = .{
                .id = readUlid(stmt, 0),
                .exploration_id = readUlid(stmt, 1),
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
                std.log.warn("getSessionsByExploration: buffer full ({d}), results truncated", .{buf.len});
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

    pub fn countErrorsByExploration(self: *Store, exploration_id: Ulid) StoreError!i64 {
        var stmt = try self.db.prepare(
            "SELECT COUNT(*) FROM events e JOIN sessions s ON e.session_id = s.id WHERE s.exploration_id = ?1 AND e.kind = 'error'",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &exploration_id.bytes);
        _ = try stmt.step();
        return stmt.columnInt64(0);
    }

    // ── Evidence CRUD ──

    pub fn insertEvidence(self: *Store, ev: Evidence) StoreError!void {
        var stmt = try self.db.prepare(
            "INSERT INTO evidence (id, exploration_id, kind, status, hash, summary, raw_path, recorded_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &ev.id.bytes);
        try stmt.bindBlob(2, &ev.exploration_id.bytes);
        try stmt.bindText(3, ev.kind.toStr());
        try stmt.bindText(4, ev.status.toStr());
        try stmt.bindOptionalText(5, ev.hash);
        try stmt.bindOptionalText(6, ev.summary);
        try stmt.bindOptionalText(7, ev.raw_path);
        try stmt.bindInt64(8, ev.recorded_at);
        _ = try stmt.step();
        // Index evidence summary into FTS
        if (ev.summary) |s| {
            var lookup = self.db.prepare("SELECT task_id FROM explorations WHERE id = ?1") catch return;
            defer lookup.finalize();
            lookup.bindBlob(1, &ev.exploration_id.bytes) catch return;
            if ((lookup.step() catch return) == .row) {
                const task_id = readUlid(&lookup, 0);
                self.indexEntity("evidence", ev.id, task_id, s);
            }
        }
    }

    pub fn getEvidenceByExploration(self: *Store, exploration_id: Ulid, buf: []Evidence) StoreError![]Evidence {
        const stmt = try self.getCached(
            &self.cached_evidence_by_exp,
            "SELECT id, exploration_id, kind, status, hash, summary, raw_path, recorded_at FROM evidence WHERE exploration_id = ?1 ORDER BY recorded_at",
        );
        try stmt.bindBlob(1, &exploration_id.bytes);

        var count: usize = 0;
        while (count < buf.len) {
            const result = try stmt.step();
            if (result != .row) break;
            buf[count] = .{
                .id = readUlid(stmt, 0),
                .exploration_id = readUlid(stmt, 1),
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
                std.log.warn("getEvidenceByExploration: buffer full ({d}), results truncated", .{buf.len});
            }
        }
        return buf[0..count];
    }

    // ── Task queries ──

    pub fn getAllTasks(self: *Store, buf: []Task) StoreError![]Task {
        var stmt = try self.db.prepare(
            "SELECT id, description, base_commit, base_branch, status, resolved_exploration_id, batch_id, created_at, updated_at FROM tasks ORDER BY created_at DESC",
        );
        defer stmt.finalize();

        var count: usize = 0;
        while (count < buf.len) {
            const result = try stmt.step();
            if (result != .row) break;
            buf[count] = try self.readTask(&stmt);
            count += 1;
        }
        if (count == buf.len) {
            const extra = try stmt.step();
            if (extra == .row) {
                std.log.warn("getAllTasks: buffer full ({d}), results truncated", .{buf.len});
            }
        }
        return buf[0..count];
    }

    pub fn getResolvedTaskIds(self: *Store, buf: []Ulid) StoreError![]Ulid {
        var stmt = try self.db.prepare(
            "SELECT id FROM tasks WHERE status = 'resolved'",
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
                std.log.warn("getResolvedTaskIds: buffer full ({d}), results truncated", .{buf.len});
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
        task_id: []const u8,
        snippet: []const u8,
        rank: f64,
    };

    /// Full-text search across the context_fts index. Returns ranked results with snippets.
    pub fn searchFts(self: *Store, query: []const u8, buf: []SearchResult) StoreError![]SearchResult {
        var stmt = try self.db.prepare(
            "SELECT entity_type, entity_id, task_id, snippet(context_fts, 4, '\xc2\xbb', '\xc2\xab', '\xe2\x80\xa6', 24), rank FROM context_fts WHERE context_fts MATCH ?1 ORDER BY rank LIMIT ?2",
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
                .task_id = try self.dupeText(stmt.columnText(2)),
                .snippet = try self.dupeText(stmt.columnText(3)),
                .rank = stmt.columnDouble(4),
            };
            count += 1;
        }
        return buf[0..count];
    }

    /// Insert a single entity into the FTS index. Silently ignores failures
    /// (e.g., FTS table doesn't exist in old DBs).
    fn indexEntity(self: *Store, entity_type: []const u8, entity_id: Ulid, task_id: Ulid, content: []const u8) void {
        if (content.len == 0) return;
        var stmt = self.db.prepare(
            "INSERT INTO context_fts (entity_type, entity_id, task_id, source, content) VALUES (?1, ?2, ?3, 'db', ?4)",
        ) catch return;
        defer stmt.finalize();
        const eid = entity_id.encode();
        const tid = task_id.encode();
        stmt.bindText(1, entity_type) catch return;
        stmt.bindText(2, &eid) catch return;
        stmt.bindText(3, &tid) catch return;
        stmt.bindText(4, content) catch return;
        _ = stmt.step() catch return;
    }

    /// Rebuild the FTS index from all DB data (tasks, explorations, evidence).
    pub fn indexForSearch(self: *Store) StoreError!void {
        try self.db.exec("BEGIN");
        errdefer self.db.exec("ROLLBACK") catch {};

        try self.db.exec("DELETE FROM context_fts WHERE source = 'db'");

        // Index tasks
        {
            var stmt = try self.db.prepare("SELECT id, description FROM tasks");
            defer stmt.finalize();
            while (true) {
                const result = try stmt.step();
                if (result != .row) break;
                const id = readUlid(&stmt, 0);
                const desc = stmt.columnText(1) orelse continue;
                self.indexEntity("task", id, id, desc);
            }
        }

        // Index explorations (approach + summary as separate rows)
        {
            var stmt = try self.db.prepare("SELECT id, task_id, approach, summary FROM explorations");
            defer stmt.finalize();
            while (true) {
                const result = try stmt.step();
                if (result != .row) break;
                const id = readUlid(&stmt, 0);
                const task_id = readUlid(&stmt, 1);
                if (stmt.columnText(2)) |approach| {
                    self.indexEntity("exploration", id, task_id, approach);
                }
                if (stmt.columnText(3)) |summary| {
                    self.indexEntity("exploration", id, task_id, summary);
                }
            }
        }

        // Index evidence
        {
            var stmt = try self.db.prepare(
                "SELECT ev.id, e.task_id, ev.summary FROM evidence ev JOIN explorations e ON ev.exploration_id = e.id",
            );
            defer stmt.finalize();
            while (true) {
                const result = try stmt.step();
                if (result != .row) break;
                const id = readUlid(&stmt, 0);
                const task_id = readUlid(&stmt, 1);
                if (stmt.columnText(2)) |summary| {
                    self.indexEntity("evidence", id, task_id, summary);
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

            const task_id_str = parsed.fm.task_id orelse entry.name;

            // Index the description
            if (parsed.fm.description) |desc| {
                var stmt = self.db.prepare(
                    "INSERT INTO context_fts (entity_type, entity_id, task_id, source, content) VALUES ('task', ?1, ?1, 'file', ?2)",
                ) catch continue;
                defer stmt.finalize();
                stmt.bindText(1, task_id_str) catch continue;
                stmt.bindText(2, desc) catch continue;
                _ = stmt.step() catch continue;
            }

            // Index the body content
            const body = content[parsed.body_start..];
            if (body.len > 0) {
                var stmt = self.db.prepare(
                    "INSERT INTO context_fts (entity_type, entity_id, task_id, source, content) VALUES ('context', ?1, ?1, 'file', ?2)",
                ) catch continue;
                defer stmt.finalize();
                stmt.bindText(1, task_id_str) catch continue;
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

    // ── Batch CRUD ──

    pub fn insertBatch(self: *Store, batch: Batch) StoreError!void {
        var stmt = try self.db.prepare(
            "INSERT INTO batches (id, description, base_commit, base_branch, status, merge_policy, merge_order, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &batch.id.bytes);
        try stmt.bindText(2, batch.description);
        try stmt.bindText(3, batch.base_commit);
        try stmt.bindText(4, batch.base_branch);
        try stmt.bindText(5, batch.status.toStr());
        try stmt.bindText(6, batch.merge_policy.toStr());
        try stmt.bindOptionalText(7, batch.merge_order);
        try stmt.bindInt64(8, batch.created_at);
        try stmt.bindInt64(9, batch.updated_at);
        _ = try stmt.step();
    }

    pub fn getBatch(self: *Store, id: Ulid) StoreError!Batch {
        var stmt = try self.db.prepare(
            "SELECT id, description, base_commit, base_branch, status, merge_policy, merge_order, created_at, updated_at FROM batches WHERE id = ?1",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &id.bytes);
        const result = try stmt.step();
        if (result != .row) return error.NotFound;
        return self.readBatch(&stmt);
    }

    pub fn getActiveBatch(self: *Store) StoreError!Batch {
        var stmt = try self.db.prepare(
            "SELECT id, description, base_commit, base_branch, status, merge_policy, merge_order, created_at, updated_at FROM batches WHERE status = 'active' OR status = 'merging' ORDER BY created_at DESC LIMIT 1",
        );
        defer stmt.finalize();
        const result = try stmt.step();
        if (result != .row) return error.NotFound;
        return self.readBatch(&stmt);
    }

    pub fn updateBatchStatus(self: *Store, id: Ulid, status: BatchStatus) StoreError!void {
        var stmt = try self.db.prepare(
            "UPDATE batches SET status = ?1, updated_at = ?2 WHERE id = ?3",
        );
        defer stmt.finalize();
        try stmt.bindText(1, status.toStr());
        try stmt.bindInt64(2, std.time.milliTimestamp());
        try stmt.bindBlob(3, &id.bytes);
        _ = try stmt.step();
    }

    pub fn updateBatchMergeOrder(self: *Store, id: Ulid, merge_order: []const u8) StoreError!void {
        var stmt = try self.db.prepare(
            "UPDATE batches SET merge_order = ?1, updated_at = ?2 WHERE id = ?3",
        );
        defer stmt.finalize();
        try stmt.bindText(1, merge_order);
        try stmt.bindInt64(2, std.time.milliTimestamp());
        try stmt.bindBlob(3, &id.bytes);
        _ = try stmt.step();
    }

    pub fn getTasksByBatch(self: *Store, batch_id: Ulid, buf: []Task) StoreError![]Task {
        var stmt = try self.db.prepare(
            "SELECT id, description, base_commit, base_branch, status, resolved_exploration_id, batch_id, created_at, updated_at FROM tasks WHERE batch_id = ?1 ORDER BY created_at",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &batch_id.bytes);

        var count: usize = 0;
        while (count < buf.len) {
            const result = try stmt.step();
            if (result != .row) break;
            buf[count] = try self.readTask(&stmt);
            count += 1;
        }
        if (count == buf.len) {
            const extra = try stmt.step();
            if (extra == .row) {
                std.log.warn("getTasksByBatch: buffer full ({d}), results truncated", .{buf.len});
            }
        }
        return buf[0..count];
    }

    fn readBatch(self: *Store, stmt: *sqlite.Stmt) StoreError!Batch {
        return .{
            .id = readUlid(stmt, 0),
            .description = try self.dupeText(stmt.columnText(1)),
            .base_commit = try self.dupeText(stmt.columnText(2)),
            .base_branch = try self.dupeText(stmt.columnText(3)),
            .status = BatchStatus.fromStr(stmt.columnText(4) orelse "active") catch .active,
            .merge_policy = MergePolicy.fromStr(stmt.columnText(5) orelse "semi") catch .semi,
            .merge_order = try self.dupeOptionalText(stmt.columnText(6)),
            .created_at = stmt.columnInt64(7),
            .updated_at = stmt.columnInt64(8),
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

test "task roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = try Store.init(arena.allocator(), ":memory:");
    defer store.deinit();

    const now = std.time.milliTimestamp();
    const id = Ulid.new();
    const task = Task{
        .id = id,
        .description = "refactor auth",
        .base_commit = "abc123",
        .base_branch = "main",
        .status = .active,
        .resolved_exploration_id = null,
        .batch_id = null,
        .created_at = now,
        .updated_at = now,
    };
    try store.insertTask(task);

    const got = try store.getTask(id);
    try std.testing.expectEqualSlices(u8, "refactor auth", got.description);
    try std.testing.expectEqual(TaskStatus.active, got.status);
}

test "exploration roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = try Store.init(arena.allocator(), ":memory:");
    defer store.deinit();

    const now = std.time.milliTimestamp();
    const task_id = Ulid.new();
    try store.insertTask(.{
        .id = task_id,
        .description = "test",
        .base_commit = "abc",
        .base_branch = "main",
        .status = .active,
        .resolved_exploration_id = null,
        .batch_id = null,
        .created_at = now,
        .updated_at = now,
    });

    const exp_id = Ulid.new();
    try store.insertExploration(.{
        .id = exp_id,
        .task_id = task_id,
        .index = 1,
        .worktree_path = "/tmp/wt1",
        .branch_name = "agx/ABC/1",
        .status = .active,
        .approach = "middleware extraction",
        .summary = null,
        .created_at = now,
        .updated_at = now,
    });

    var buf: [16]Exploration = undefined;
    const exps = try store.getExplorationsByTask(task_id, &buf);
    try std.testing.expectEqual(@as(usize, 1), exps.len);
    try std.testing.expectEqualSlices(u8, "middleware extraction", exps[0].approach.?);
}

test "FTS search" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = try Store.init(arena.allocator(), ":memory:");
    defer store.deinit();

    const now = std.time.milliTimestamp();
    const task_id = Ulid.new();
    try store.insertTask(.{
        .id = task_id,
        .description = "refactor authentication middleware",
        .base_commit = "abc",
        .base_branch = "main",
        .status = .active,
        .resolved_exploration_id = null,
        .batch_id = null,
        .created_at = now,
        .updated_at = now,
    });

    const exp_id = Ulid.new();
    try store.insertExploration(.{
        .id = exp_id,
        .task_id = task_id,
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
        .exploration_id = exp_id,
        .kind = .test_result,
        .status = .pass,
        .hash = null,
        .summary = "all authentication tests passing",
        .raw_path = null,
        .recorded_at = now,
    });

    // Rebuild full index
    try store.indexForSearch();

    // Search for "authentication" — should find task + evidence
    var buf: [10]Store.SearchResult = undefined;
    const results = try store.searchFts("authentication", &buf);
    try std.testing.expect(results.len >= 2);

    // Search for "JWT" — should find exploration approach
    const jwt_results = try store.searchFts("JWT", &buf);
    try std.testing.expect(jwt_results.len >= 1);
    try std.testing.expectEqualSlices(u8, "exploration", jwt_results[0].entity_type);

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
    const task_id = Ulid.new();
    try store.insertTask(.{
        .id = task_id,
        .description = "implement websocket support",
        .base_commit = "def456",
        .base_branch = "main",
        .status = .active,
        .resolved_exploration_id = null,
        .batch_id = null,
        .created_at = now,
        .updated_at = now,
    });

    // Task should be searchable immediately (incremental index)
    var buf: [10]Store.SearchResult = undefined;
    const results = try store.searchFts("websocket", &buf);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualSlices(u8, "task", results[0].entity_type);
}

test "evidence roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = try Store.init(arena.allocator(), ":memory:");
    defer store.deinit();

    const now = std.time.milliTimestamp();
    const task_id = Ulid.new();
    try store.insertTask(.{
        .id = task_id,
        .description = "test",
        .base_commit = "abc",
        .base_branch = "main",
        .status = .active,
        .resolved_exploration_id = null,
        .batch_id = null,
        .created_at = now,
        .updated_at = now,
    });

    const exp_id = Ulid.new();
    try store.insertExploration(.{
        .id = exp_id,
        .task_id = task_id,
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
        .exploration_id = exp_id,
        .kind = .test_result,
        .status = .pass,
        .hash = "sha256:abc",
        .summary = "47/47 tests passed",
        .raw_path = null,
        .recorded_at = now,
    });

    var buf: [16]Evidence = undefined;
    const evs = try store.getEvidenceByExploration(exp_id, &buf);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqualSlices(u8, "47/47 tests passed", evs[0].summary.?);
}

test "batch and getTasksByBatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = try Store.init(arena.allocator(), ":memory:");
    defer store.deinit();

    const now = std.time.milliTimestamp();
    const batch_id = Ulid.new();

    try store.insertBatch(.{
        .id = batch_id,
        .description = "Batch of 2 tasks",
        .base_commit = "abc123",
        .base_branch = "main",
        .status = .active,
        .merge_policy = .semi,
        .merge_order = null,
        .created_at = now,
        .updated_at = now,
    });

    // Create two tasks in the batch
    const task1_id = Ulid.new();
    try store.insertTask(.{
        .id = task1_id,
        .description = "add auth",
        .base_commit = "abc123",
        .base_branch = "main",
        .status = .active,
        .resolved_exploration_id = null,
        .batch_id = batch_id,
        .created_at = now,
        .updated_at = now,
    });

    const task2_id = Ulid.new();
    try store.insertTask(.{
        .id = task2_id,
        .description = "add logging",
        .base_commit = "abc123",
        .base_branch = "main",
        .status = .active,
        .resolved_exploration_id = null,
        .batch_id = batch_id,
        .created_at = now + 1,
        .updated_at = now + 1,
    });

    // Also create a task NOT in the batch
    try store.insertTask(.{
        .id = Ulid.new(),
        .description = "unrelated task",
        .base_commit = "abc123",
        .base_branch = "main",
        .status = .active,
        .resolved_exploration_id = null,
        .batch_id = null,
        .created_at = now,
        .updated_at = now,
    });

    // Verify batch roundtrip
    const got_batch = try store.getBatch(batch_id);
    try std.testing.expectEqualSlices(u8, "Batch of 2 tasks", got_batch.description);
    try std.testing.expectEqual(BatchStatus.active, got_batch.status);
    try std.testing.expectEqual(MergePolicy.semi, got_batch.merge_policy);

    // Verify getTasksByBatch returns only the 2 batch tasks
    var task_buf: [16]Task = undefined;
    const tasks = try store.getTasksByBatch(batch_id, &task_buf);
    try std.testing.expectEqual(@as(usize, 2), tasks.len);
    try std.testing.expectEqualSlices(u8, "add auth", tasks[0].description);
    try std.testing.expectEqualSlices(u8, "add logging", tasks[1].description);

    // Verify batch_id is set on retrieved tasks
    try std.testing.expect(tasks[0].batch_id != null);

    // Verify getActiveBatch works
    const active = try store.getActiveBatch();
    try std.testing.expectEqualSlices(u8, "Batch of 2 tasks", active.description);

    // Update status and verify
    try store.updateBatchStatus(batch_id, .completed);
    const updated = try store.getBatch(batch_id);
    try std.testing.expectEqual(BatchStatus.completed, updated.status);

    // Update merge order
    try store.updateBatchMergeOrder(batch_id, "[\"id1\",\"id2\"]");
    const with_order = try store.getBatch(batch_id);
    try std.testing.expectEqualSlices(u8, "[\"id1\",\"id2\"]", with_order.merge_order.?);
}
