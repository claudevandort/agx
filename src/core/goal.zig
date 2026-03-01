const std = @import("std");
const Ulid = @import("ulid.zig").Ulid;

pub const GoalStatus = enum {
    active,
    resolved,
    abandoned,

    pub fn toStr(self: GoalStatus) []const u8 {
        return @tagName(self);
    }

    pub fn fromStr(s: []const u8) !GoalStatus {
        inline for (@typeInfo(GoalStatus).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return error.InvalidStatus;
    }
};

pub const Goal = struct {
    id: Ulid,
    description: []const u8,
    base_commit: []const u8, // SHA hex
    base_branch: []const u8,
    status: GoalStatus,
    resolved_task_id: ?Ulid, // which task was picked
    dispatch_id: ?Ulid, // if part of a dispatch
    created_at: i64, // ms since epoch
    updated_at: i64,
};
