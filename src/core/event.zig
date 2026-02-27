const std = @import("std");
const Allocator = std.mem.Allocator;
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
    session_id: Ulid,
    kind: EventKind,
    data: ?[]const u8, // JSON blob
    created_at: i64,

    pub fn deinit(self: *const Event, alloc: Allocator) void {
        if (self.data) |d| alloc.free(d);
    }

    pub fn deinitSlice(alloc: Allocator, slice: []const Event) void {
        for (slice) |*e| e.deinit(alloc);
    }
};
