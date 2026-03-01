const std = @import("std");
const Ulid = @import("ulid.zig").Ulid;

pub const TaskStatus = enum {
    active,
    done,
    kept,
    archived,
    discarded,

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
    goal_id: Ulid,
    index: u32, // 1-based index within goal
    worktree_path: []const u8,
    branch_name: []const u8,
    status: TaskStatus,
    approach: ?[]const u8, // strategic description set early
    summary: ?[]const u8, // outcome description set via `agx exploration done`
    created_at: i64,
    updated_at: i64,
};
