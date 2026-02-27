const c = @cImport({
    @cInclude("sqlite3.h");
});

pub fn version() [*:0]const u8 {
    return c.sqlite3_libversion();
}

/// Opaque handle to an open SQLite database.
pub const Db = struct {
    handle: *c.sqlite3,

    pub fn open(path: [*:0]const u8) !Db {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path, &db);
        if (rc != c.SQLITE_OK) {
            if (db) |d| c.sqlite3_close(d);
            return error.SqliteOpenFailed;
        }
        return .{ .handle = db.? };
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
        self.handle = undefined;
    }

    pub fn exec(self: *Db, sql: [*:0]const u8) !void {
        var err_msg: ?[*:0]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |msg| c.sqlite3_free(msg);
            return error.SqliteExecFailed;
        }
    }
};
