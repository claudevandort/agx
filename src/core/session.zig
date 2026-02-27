const Ulid = @import("ulid.zig").Ulid;

pub const ExitReason = enum {
    completed,
    interrupted,
    @"error",
    timeout,

    pub fn toStr(self: ExitReason) []const u8 {
        return switch (self) {
            .completed => "completed",
            .interrupted => "interrupted",
            .@"error" => "error",
            .timeout => "timeout",
        };
    }

    pub fn fromStr(s: []const u8) !ExitReason {
        const mem = @import("std").mem;
        if (mem.eql(u8, s, "completed")) return .completed;
        if (mem.eql(u8, s, "interrupted")) return .interrupted;
        if (mem.eql(u8, s, "error")) return .@"error";
        if (mem.eql(u8, s, "timeout")) return .timeout;
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
};
