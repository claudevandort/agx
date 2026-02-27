const Ulid = @import("ulid.zig").Ulid;

pub const ExplorationStatus = enum {
    active,
    done,
    kept,
    archived,
    discarded,

    pub fn toStr(self: ExplorationStatus) []const u8 {
        return switch (self) {
            .active => "active",
            .done => "done",
            .kept => "kept",
            .archived => "archived",
            .discarded => "discarded",
        };
    }

    pub fn fromStr(s: []const u8) !ExplorationStatus {
        const mem = @import("std").mem;
        if (mem.eql(u8, s, "active")) return .active;
        if (mem.eql(u8, s, "done")) return .done;
        if (mem.eql(u8, s, "kept")) return .kept;
        if (mem.eql(u8, s, "archived")) return .archived;
        if (mem.eql(u8, s, "discarded")) return .discarded;
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
};
