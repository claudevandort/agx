const std = @import("std");
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

};
