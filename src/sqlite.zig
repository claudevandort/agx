const c = @cImport({
    @cInclude("sqlite3.h");
});

pub fn version() [*:0]const u8 {
    return c.sqlite3_libversion();
}

pub const SqliteError = error{
    SqliteOpenFailed,
    SqliteExecFailed,
    SqlitePrepareFailed,
    SqliteBindFailed,
    SqliteStepFailed,
};

/// Opaque handle to an open SQLite database.
pub const Db = struct {
    handle: *c.sqlite3,

    pub fn open(path: [*:0]const u8) SqliteError!Db {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path, &db);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return error.SqliteOpenFailed;
        }
        return .{ .handle = db.? };
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
        self.handle = undefined;
    }

    pub fn exec(self: *Db, sql: [*:0]const u8) SqliteError!void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg != null) c.sqlite3_free(err_msg);
            return error.SqliteExecFailed;
        }
    }

    pub fn execMulti(self: *Db, sql: []const u8) SqliteError!void {
        // sqlite3_exec requires null-terminated string but we have a slice.
        // Use the prepare/step loop to handle multiple statements.
        var remaining = sql;
        while (remaining.len > 0) {
            var stmt: ?*c.sqlite3_stmt = null;
            var tail: ?[*]const u8 = null;
            const rc = c.sqlite3_prepare_v2(
                self.handle,
                remaining.ptr,
                @intCast(remaining.len),
                &stmt,
                &tail,
            );
            if (rc != c.SQLITE_OK) return error.SqlitePrepareFailed;

            if (stmt) |s| {
                defer _ = c.sqlite3_finalize(s);
                const step_rc = c.sqlite3_step(s);
                if (step_rc != c.SQLITE_DONE and step_rc != c.SQLITE_ROW) {
                    return error.SqliteStepFailed;
                }
            }

            if (tail) |t| {
                const consumed = @intFromPtr(t) - @intFromPtr(remaining.ptr);
                remaining = remaining[consumed..];
                // Skip whitespace/semicolons between statements
                while (remaining.len > 0 and (remaining[0] == ' ' or remaining[0] == '\n' or remaining[0] == '\r' or remaining[0] == '\t' or remaining[0] == ';')) {
                    remaining = remaining[1..];
                }
            } else {
                break;
            }
        }
    }

    pub fn prepare(self: *Db, sql: [*:0]const u8) SqliteError!Stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.SqlitePrepareFailed;
        return .{ .handle = stmt.? };
    }

    pub fn lastInsertRowId(self: *Db) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    pub fn changes(self: *Db) i32 {
        return c.sqlite3_changes(self.handle);
    }
};

/// Prepared statement wrapper.
pub const Stmt = struct {
    handle: *c.sqlite3_stmt,

    // --- Binding (1-based index) ---

    pub fn bindBlob(self: *Stmt, idx: u32, data: []const u8) SqliteError!void {
        const rc = c.sqlite3_bind_blob(self.handle, @intCast(idx), data.ptr, @intCast(data.len), c.SQLITE_TRANSIENT);
        if (rc != c.SQLITE_OK) return error.SqliteBindFailed;
    }

    pub fn bindText(self: *Stmt, idx: u32, text: []const u8) SqliteError!void {
        const rc = c.sqlite3_bind_text(self.handle, @intCast(idx), text.ptr, @intCast(text.len), c.SQLITE_TRANSIENT);
        if (rc != c.SQLITE_OK) return error.SqliteBindFailed;
    }

    pub fn bindInt64(self: *Stmt, idx: u32, val: i64) SqliteError!void {
        const rc = c.sqlite3_bind_int64(self.handle, @intCast(idx), val);
        if (rc != c.SQLITE_OK) return error.SqliteBindFailed;
    }

    pub fn bindInt(self: *Stmt, idx: u32, val: i32) SqliteError!void {
        const rc = c.sqlite3_bind_int(self.handle, @intCast(idx), val);
        if (rc != c.SQLITE_OK) return error.SqliteBindFailed;
    }

    pub fn bindNull(self: *Stmt, idx: u32) SqliteError!void {
        const rc = c.sqlite3_bind_null(self.handle, @intCast(idx));
        if (rc != c.SQLITE_OK) return error.SqliteBindFailed;
    }

    pub fn bindOptionalText(self: *Stmt, idx: u32, val: ?[]const u8) SqliteError!void {
        if (val) |v| {
            try self.bindText(idx, v);
        } else {
            try self.bindNull(idx);
        }
    }

    pub fn bindOptionalInt64(self: *Stmt, idx: u32, val: ?i64) SqliteError!void {
        if (val) |v| {
            try self.bindInt64(idx, v);
        } else {
            try self.bindNull(idx);
        }
    }

    pub fn bindOptionalBlob(self: *Stmt, idx: u32, val: ?[]const u8) SqliteError!void {
        if (val) |v| {
            try self.bindBlob(idx, v);
        } else {
            try self.bindNull(idx);
        }
    }

    // --- Stepping ---

    pub const StepResult = enum { row, done };

    pub fn step(self: *Stmt) SqliteError!StepResult {
        const rc = c.sqlite3_step(self.handle);
        if (rc == c.SQLITE_ROW) return .row;
        if (rc == c.SQLITE_DONE) return .done;
        return error.SqliteStepFailed;
    }

    // --- Column reading (0-based index) ---

    pub fn columnBlob(self: *Stmt, idx: u32) ?[]const u8 {
        const col: c_int = @intCast(idx);
        const ptr = c.sqlite3_column_blob(self.handle, col);
        if (ptr == null) return null;
        const len = c.sqlite3_column_bytes(self.handle, col);
        if (len <= 0) return null;
        const p: [*]const u8 = @ptrCast(ptr.?);
        return p[0..@intCast(len)];
    }

    pub fn columnText(self: *Stmt, idx: u32) ?[]const u8 {
        const col: c_int = @intCast(idx);
        const ptr = c.sqlite3_column_text(self.handle, col);
        if (ptr == null) return null;
        const len = c.sqlite3_column_bytes(self.handle, col);
        if (len <= 0) return &[_]u8{};
        return ptr[0..@intCast(len)];
    }

    pub fn columnInt64(self: *Stmt, idx: u32) i64 {
        return c.sqlite3_column_int64(self.handle, @intCast(idx));
    }

    pub fn columnInt(self: *Stmt, idx: u32) i32 {
        return c.sqlite3_column_int(self.handle, @intCast(idx));
    }

    pub fn columnIsNull(self: *Stmt, idx: u32) bool {
        return c.sqlite3_column_type(self.handle, @intCast(idx)) == c.SQLITE_NULL;
    }

    // --- Lifecycle ---

    pub fn reset(self: *Stmt) void {
        _ = c.sqlite3_reset(self.handle);
        _ = c.sqlite3_clear_bindings(self.handle);
    }

    pub fn finalize(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.handle);
        self.handle = undefined;
    }
};

test "open in-memory database" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE t (x INTEGER)");
    try db.exec("INSERT INTO t VALUES (42)");
}

test "prepared statement roundtrip" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE t (id BLOB, name TEXT, val INTEGER)");

    var ins = try db.prepare("INSERT INTO t VALUES (?1, ?2, ?3)");
    defer ins.finalize();
    const blob = [_]u8{ 1, 2, 3 };
    try ins.bindBlob(1, &blob);
    try ins.bindText(2, "hello");
    try ins.bindInt64(3, 99);
    const res = try ins.step();
    const std = @import("std");
    try std.testing.expectEqual(Stmt.StepResult.done, res);

    var sel = try db.prepare("SELECT id, name, val FROM t");
    defer sel.finalize();
    const row = try sel.step();
    try std.testing.expectEqual(Stmt.StepResult.row, row);
    try std.testing.expectEqualSlices(u8, &blob, sel.columnBlob(0).?);
    try std.testing.expectEqualSlices(u8, "hello", sel.columnText(1).?);
    try std.testing.expectEqual(@as(i64, 99), sel.columnInt64(2));
}
