const Ulid = @import("ulid.zig").Ulid;

pub const Snapshot = struct {
    id: Ulid,
    session_id: Ulid,
    commit_sha: []const u8,
    summary: ?[]const u8,
    created_at: i64,
};
