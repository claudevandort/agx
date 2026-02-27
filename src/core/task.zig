const Ulid = @import("ulid.zig").Ulid;

pub const TaskStatus = enum {
    active,
    resolved,
    abandoned,

    pub fn toStr(self: TaskStatus) []const u8 {
        return switch (self) {
            .active => "active",
            .resolved => "resolved",
            .abandoned => "abandoned",
        };
    }

    pub fn fromStr(s: []const u8) !TaskStatus {
        if (eql(s, "active")) return .active;
        if (eql(s, "resolved")) return .resolved;
        if (eql(s, "abandoned")) return .abandoned;
        return error.InvalidStatus;
    }

    fn eql(a: []const u8, b: []const u8) bool {
        return @import("std").mem.eql(u8, a, b);
    }
};

pub const Task = struct {
    id: Ulid,
    description: []const u8,
    base_commit: []const u8, // SHA hex
    base_branch: []const u8,
    status: TaskStatus,
    resolved_exploration_id: ?Ulid, // which exploration was kept
    created_at: i64, // ms since epoch
    updated_at: i64,
};
