const std = @import("std");
const Ulid = @import("ulid.zig").Ulid;

pub const DispatchStatus = enum {
    active,
    merging,
    conflict,
    completed,
    failed,
    abandoned,

    pub fn toStr(self: DispatchStatus) []const u8 {
        return @tagName(self);
    }

    pub fn fromStr(s: []const u8) !DispatchStatus {
        inline for (@typeInfo(DispatchStatus).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return error.InvalidStatus;
    }
};

pub const MergePolicy = enum {
    autonomous,
    semi,
    manual,

    pub fn toStr(self: MergePolicy) []const u8 {
        return @tagName(self);
    }

    pub fn fromStr(s: []const u8) !MergePolicy {
        inline for (@typeInfo(MergePolicy).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return error.InvalidPolicy;
    }
};

pub const Dispatch = struct {
    id: Ulid,
    description: []const u8,
    base_commit: []const u8,
    base_branch: []const u8,
    status: DispatchStatus,
    merge_policy: MergePolicy,
    merge_order: ?[]const u8, // JSON array of goal ULID strings, set at merge time
    merge_progress: u32, // number of goals successfully merged so far
    created_at: i64,
    updated_at: i64,
};
