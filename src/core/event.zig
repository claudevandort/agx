const std = @import("std");
const Ulid = @import("ulid.zig").Ulid;

pub const EventKind = enum {
    message,
    tool_call,
    tool_result,
    decision,
    file_change,
    git_commit,
    @"error",
    custom,

    pub fn toStr(self: EventKind) []const u8 {
        return @tagName(self);
    }

    pub fn fromStr(s: []const u8) !EventKind {
        inline for (@typeInfo(EventKind).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return error.InvalidEventKind;
    }
};

pub const Event = struct {
    id: Ulid,
    session_id: ?Ulid,
    goal_id: ?Ulid,
    kind: EventKind,
    data: ?[]const u8, // JSON blob
    created_at: i64,
};
