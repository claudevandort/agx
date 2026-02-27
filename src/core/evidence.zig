const std = @import("std");
const Allocator = std.mem.Allocator;
const Ulid = @import("ulid.zig").Ulid;

pub const EvidenceKind = enum {
    test_result,
    build_output,
    coverage_report,
    lint_result,
    benchmark,
    custom,

    pub fn toStr(self: EvidenceKind) []const u8 {
        return @tagName(self);
    }

    pub fn fromStr(s: []const u8) !EvidenceKind {
        inline for (@typeInfo(EvidenceKind).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return error.InvalidEvidenceKind;
    }
};

pub const EvidenceStatus = enum {
    pass,
    fail,
    @"error",
    skip,

    pub fn toStr(self: EvidenceStatus) []const u8 {
        return @tagName(self);
    }

    pub fn fromStr(s: []const u8) !EvidenceStatus {
        inline for (@typeInfo(EvidenceStatus).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return error.InvalidEvidenceStatus;
    }
};

pub const Evidence = struct {
    id: Ulid,
    exploration_id: Ulid,
    kind: EvidenceKind,
    status: EvidenceStatus,
    hash: ?[]const u8, // content hash of raw output
    summary: ?[]const u8, // e.g. "47/47 tests passed"
    raw_path: ?[]const u8, // path to full output file
    recorded_at: i64,

    pub fn deinit(self: *const Evidence, alloc: Allocator) void {
        if (self.hash) |h| alloc.free(h);
        if (self.summary) |s| alloc.free(s);
        if (self.raw_path) |p| alloc.free(p);
    }

    pub fn deinitSlice(alloc: Allocator, slice: []const Evidence) void {
        for (slice) |*e| e.deinit(alloc);
    }
};
