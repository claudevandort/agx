const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const migrations = @import("migrations.zig").migrations;
const Ulid = @import("../core/ulid.zig").Ulid;
const Task = @import("../core/task.zig").Task;
const TaskStatus = @import("../core/task.zig").TaskStatus;
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
        self.db.close();
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

            self.db.execMulti(sql) catch return error.MigrationFailed;

            var rec = self.db.prepare("INSERT INTO agx_migrations (version, applied_at) VALUES (?1, ?2)") catch return error.MigrationFailed;
            defer rec.finalize();
            rec.bindInt64(1, ver) catch return error.MigrationFailed;
            rec.bindInt64(2, std.time.milliTimestamp()) catch return error.MigrationFailed;
            _ = rec.step() catch return error.MigrationFailed;
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
            "INSERT INTO tasks (id, description, base_commit, base_branch, status, resolved_exploration_id, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &task.id.bytes);
        try stmt.bindText(2, task.description);
        try stmt.bindText(3, task.base_commit);
        try stmt.bindText(4, task.base_branch);
        try stmt.bindText(5, task.status.toStr());
        try stmt.bindOptionalBlob(6, if (task.resolved_exploration_id) |r| &r.bytes else null);
        try stmt.bindInt64(7, task.created_at);
        try stmt.bindInt64(8, task.updated_at);
        _ = try stmt.step();
    }

    pub fn getTask(self: *Store, id: Ulid) StoreError!Task {
        var stmt = try self.db.prepare(
            "SELECT id, description, base_commit, base_branch, status, resolved_exploration_id, created_at, updated_at FROM tasks WHERE id = ?1",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &id.bytes);
        const result = try stmt.step();
        if (result != .row) return error.NotFound;
        return self.readTask(&stmt);
    }

    pub fn getActiveTask(self: *Store) StoreError!Task {
        var stmt = try self.db.prepare(
            "SELECT id, description, base_commit, base_branch, status, resolved_exploration_id, created_at, updated_at FROM tasks WHERE status = 'active' ORDER BY created_at DESC LIMIT 1",
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
        return .{
            .id = readUlid(stmt, 0),
            .description = try self.dupeText(stmt.columnText(1)),
            .base_commit = try self.dupeText(stmt.columnText(2)),
            .base_branch = try self.dupeText(stmt.columnText(3)),
            .status = TaskStatus.fromStr(stmt.columnText(4) orelse "active") catch .active,
            .resolved_exploration_id = if (resolved_blob) |b| blk: {
                break :blk if (b.len >= 16) Ulid{ .bytes = b[0..16].* } else null;
            } else null,
            .created_at = stmt.columnInt64(6),
            .updated_at = stmt.columnInt64(7),
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
        var stmt = try self.db.prepare(
            "SELECT id, task_id, idx, worktree_path, branch_name, status, approach, summary, created_at, updated_at FROM explorations WHERE task_id = ?1 ORDER BY idx",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &task_id.bytes);

        var count: usize = 0;
        while (count < buf.len) {
            const result = try stmt.step();
            if (result != .row) break;
            buf[count] = try self.readExploration(&stmt);
            count += 1;
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
        var stmt = try self.db.prepare(
            "SELECT id, exploration_id, agent_type, model_version, environment_fingerprint, initial_prompt, exit_reason, started_at, ended_at FROM sessions WHERE exploration_id = ?1 ORDER BY started_at",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &exploration_id.bytes);

        var count: usize = 0;
        while (count < buf.len) {
            const result = try stmt.step();
            if (result != .row) break;
            buf[count] = .{
                .id = readUlid(&stmt, 0),
                .exploration_id = readUlid(&stmt, 1),
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
        return buf[0..count];
    }

    // ── Event CRUD ──

    pub fn insertEvent(self: *Store, event: Event) StoreError!void {
        var stmt = try self.db.prepare(
            "INSERT INTO events (id, session_id, kind, data, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
        );
        defer stmt.finalize();
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
    }

    pub fn getEvidenceByExploration(self: *Store, exploration_id: Ulid, buf: []Evidence) StoreError![]Evidence {
        var stmt = try self.db.prepare(
            "SELECT id, exploration_id, kind, status, hash, summary, raw_path, recorded_at FROM evidence WHERE exploration_id = ?1 ORDER BY recorded_at",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &exploration_id.bytes);

        var count: usize = 0;
        while (count < buf.len) {
            const result = try stmt.step();
            if (result != .row) break;
            buf[count] = .{
                .id = readUlid(&stmt, 0),
                .exploration_id = readUlid(&stmt, 1),
                .kind = EvidenceKind.fromStr(stmt.columnText(2) orelse "custom") catch .custom,
                .status = EvidenceStatus.fromStr(stmt.columnText(3) orelse "error") catch .@"error",
                .hash = try self.dupeOptionalText(stmt.columnText(4)),
                .summary = try self.dupeOptionalText(stmt.columnText(5)),
                .raw_path = try self.dupeOptionalText(stmt.columnText(6)),
                .recorded_at = stmt.columnInt64(7),
            };
            count += 1;
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
    var store = try Store.init(std.testing.allocator, ":memory:");
    defer store.deinit();
}

test "task roundtrip" {
    var store = try Store.init(std.testing.allocator, ":memory:");
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
        .created_at = now,
        .updated_at = now,
    };
    try store.insertTask(task);

    const got = try store.getTask(id);
    defer {
        std.testing.allocator.free(got.description);
        std.testing.allocator.free(got.base_commit);
        std.testing.allocator.free(got.base_branch);
    }
    try std.testing.expectEqualSlices(u8, "refactor auth", got.description);
    try std.testing.expectEqual(TaskStatus.active, got.status);
}

test "exploration roundtrip" {
    var store = try Store.init(std.testing.allocator, ":memory:");
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
    defer for (exps) |exp| {
        std.testing.allocator.free(exp.worktree_path);
        std.testing.allocator.free(exp.branch_name);
        if (exp.approach) |a| std.testing.allocator.free(a);
        if (exp.summary) |s| std.testing.allocator.free(s);
    };
    try std.testing.expectEqual(@as(usize, 1), exps.len);
    try std.testing.expectEqualSlices(u8, "middleware extraction", exps[0].approach.?);
}

test "evidence roundtrip" {
    var store = try Store.init(std.testing.allocator, ":memory:");
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
    defer for (evs) |ev| {
        if (ev.hash) |h| std.testing.allocator.free(h);
        if (ev.summary) |s| std.testing.allocator.free(s);
        if (ev.raw_path) |p| std.testing.allocator.free(p);
    };
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqualSlices(u8, "47/47 tests passed", evs[0].summary.?);
}
