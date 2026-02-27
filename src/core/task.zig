const std = @import("std");
const Ulid = @import("ulid.zig").Ulid;

pub const TaskStatus = enum {
    active,
    resolved,
    abandoned,

    pub fn toStr(self: TaskStatus) []const u8 {
        return @tagName(self);
    }

    pub fn fromStr(s: []const u8) !TaskStatus {
        inline for (@typeInfo(TaskStatus).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return error.InvalidStatus;
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
