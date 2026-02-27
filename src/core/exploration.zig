const std = @import("std");
const Allocator = std.mem.Allocator;
const Ulid = @import("ulid.zig").Ulid;

pub const ExplorationStatus = enum {
    active,
    done,
    kept,
    archived,
    discarded,

    pub fn toStr(self: ExplorationStatus) []const u8 {
        return @tagName(self);
    }

    pub fn fromStr(s: []const u8) !ExplorationStatus {
        inline for (@typeInfo(ExplorationStatus).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return error.InvalidStatus;
    }
};

pub const Exploration = struct {
    id: Ulid,
    task_id: Ulid,
    index: u32, // 1-based index within task
    worktree_path: []const u8,
    branch_name: []const u8,
    status: ExplorationStatus,
    approach: ?[]const u8, // strategic description set early
    summary: ?[]const u8, // outcome description set via `agx done`
    created_at: i64,
    updated_at: i64,

    pub fn deinit(self: *const Exploration, alloc: Allocator) void {
        alloc.free(self.worktree_path);
        alloc.free(self.branch_name);
        if (self.approach) |a| alloc.free(a);
        if (self.summary) |s| alloc.free(s);
    }

    pub fn deinitSlice(alloc: Allocator, slice: []const Exploration) void {
        for (slice) |*e| e.deinit(alloc);
    }
};
