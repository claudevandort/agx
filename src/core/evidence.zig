const Ulid = @import("ulid.zig").Ulid;

pub const EvidenceKind = enum {
    test_result,
    build_output,
    coverage_report,
    lint_result,
    benchmark,
    custom,

    pub fn toStr(self: EvidenceKind) []const u8 {
        return switch (self) {
            .test_result => "test_result",
            .build_output => "build_output",
            .coverage_report => "coverage_report",
            .lint_result => "lint_result",
            .benchmark => "benchmark",
            .custom => "custom",
        };
    }

    pub fn fromStr(s: []const u8) !EvidenceKind {
        const mem = @import("std").mem;
        if (mem.eql(u8, s, "test_result")) return .test_result;
        if (mem.eql(u8, s, "build_output")) return .build_output;
        if (mem.eql(u8, s, "coverage_report")) return .coverage_report;
        if (mem.eql(u8, s, "lint_result")) return .lint_result;
        if (mem.eql(u8, s, "benchmark")) return .benchmark;
        if (mem.eql(u8, s, "custom")) return .custom;
        return error.InvalidEvidenceKind;
    }
};

pub const EvidenceStatus = enum {
    pass,
    fail,
    @"error",
    skip,

    pub fn toStr(self: EvidenceStatus) []const u8 {
        return switch (self) {
            .pass => "pass",
            .fail => "fail",
            .@"error" => "error",
            .skip => "skip",
        };
    }

    pub fn fromStr(s: []const u8) !EvidenceStatus {
        const mem = @import("std").mem;
        if (mem.eql(u8, s, "pass")) return .pass;
        if (mem.eql(u8, s, "fail")) return .fail;
        if (mem.eql(u8, s, "error")) return .@"error";
        if (mem.eql(u8, s, "skip")) return .skip;
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
