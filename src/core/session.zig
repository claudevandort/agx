const std = @import("std");
const Allocator = std.mem.Allocator;
const Ulid = @import("ulid.zig").Ulid;

pub const ExitReason = enum {
    completed,
    interrupted,
    @"error",
    timeout,

    pub fn toStr(self: ExitReason) []const u8 {
        return @tagName(self);
    }

    pub fn fromStr(s: []const u8) !ExitReason {
        inline for (@typeInfo(ExitReason).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return error.InvalidExitReason;
    }
};

pub const Session = struct {
    id: Ulid,
    exploration_id: Ulid,
    agent_type: ?[]const u8, // e.g. "claude-code", "aider"
    model_version: ?[]const u8, // e.g. "claude-sonnet-4-20250514"
    environment_fingerprint: ?[]const u8, // toolchain/runtime digest
    initial_prompt: ?[]const u8, // goal given to agent
    exit_reason: ?ExitReason,
    started_at: i64,
    ended_at: ?i64,

    pub fn deinit(self: *const Session, alloc: Allocator) void {
        if (self.agent_type) |a| alloc.free(a);
        if (self.model_version) |m| alloc.free(m);
        if (self.environment_fingerprint) |e| alloc.free(e);
        if (self.initial_prompt) |p| alloc.free(p);
    }

    pub fn deinitSlice(alloc: Allocator, slice: []const Session) void {
        for (slice) |*s| s.deinit(alloc);
    }
};
