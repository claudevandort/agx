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
        return switch (self) {
            .message => "message",
            .tool_call => "tool_call",
            .tool_result => "tool_result",
            .decision => "decision",
            .file_change => "file_change",
            .git_commit => "git_commit",
            .@"error" => "error",
            .custom => "custom",
        };
    }

    pub fn fromStr(s: []const u8) !EventKind {
        const mem = @import("std").mem;
        if (mem.eql(u8, s, "message")) return .message;
        if (mem.eql(u8, s, "tool_call")) return .tool_call;
        if (mem.eql(u8, s, "tool_result")) return .tool_result;
        if (mem.eql(u8, s, "decision")) return .decision;
        if (mem.eql(u8, s, "file_change")) return .file_change;
        if (mem.eql(u8, s, "git_commit")) return .git_commit;
        if (mem.eql(u8, s, "error")) return .@"error";
        if (mem.eql(u8, s, "custom")) return .custom;
        return error.InvalidEventKind;
    }
};

pub const Event = struct {
    id: Ulid,
    session_id: Ulid,
    kind: EventKind,
    data: ?[]const u8, // JSON blob
    created_at: i64,
};
