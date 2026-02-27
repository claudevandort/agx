const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");
const session_util = @import("session_util.zig");

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var kind_str: ?[]const u8 = null;
    var status_str: ?[]const u8 = null;
    var summary: ?[]const u8 = null;
    var file_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--kind") or std.mem.eql(u8, args[i], "-k")) {
            i += 1;
            if (i < args.len) kind_str = args[i];
        } else if (std.mem.eql(u8, args[i], "--status")) {
            i += 1;
            if (i < args.len) status_str = args[i];
        } else if (std.mem.eql(u8, args[i], "--summary") or std.mem.eql(u8, args[i], "-s")) {
            i += 1;
            if (i < args.len) summary = args[i];
        } else if (std.mem.eql(u8, args[i], "--file") or std.mem.eql(u8, args[i], "-f")) {
            i += 1;
            if (i < args.len) file_path = args[i];
        }
    }

    if (kind_str == null) {
        try stderr.print("error: --kind is required\n", .{});
        try stderr.print("usage: agx evidence --kind <type> --status <pass|fail|error|skip> [--summary \"...\"] [--file path]\n", .{});
        try stderr.print("kinds: test_result, build_output, coverage_report, lint_result, benchmark, custom\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    if (status_str == null) {
        try stderr.print("error: --status is required (pass, fail, error, skip)\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    const kind = agx.evidence.EvidenceKind.fromStr(kind_str.?) catch {
        try stderr.print("error: unknown evidence kind '{s}'\n", .{kind_str.?});
        try stderr.print("valid: test_result, build_output, coverage_report, lint_result, benchmark, custom\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    const status = agx.evidence.EvidenceStatus.fromStr(status_str.?) catch {
        try stderr.print("error: unknown evidence status '{s}'\n", .{status_str.?});
        try stderr.print("valid: pass, fail, error, skip\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    const ctx = session_util.getWorktreeContext(alloc, stderr) catch {
        std.process.exit(1);
        unreachable;
    };
    defer ctx.deinit(alloc);

    var store = try agx.Store.init(alloc, ctx.db_path);
    defer store.deinit();

    const exp_id = agx.Ulid.decode(ctx.info.exploration_id_str) catch {
        try stderr.print("error: invalid exploration ID in .agx-session\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    // If a file was provided, compute its hash and optionally copy it to evidence store
    var hash: ?[]const u8 = null;
    var raw_path: ?[]const u8 = null;
    defer if (hash) |h| alloc.free(h);
    defer if (raw_path) |p| alloc.free(p);

    if (file_path) |fp| {
        // Read file and compute SHA-256
        const file_content = std.fs.cwd().readFileAlloc(alloc, fp, 10 * 1024 * 1024) catch |err| {
            try stderr.print("error: could not read file '{s}': {s}\n", .{ fp, @errorName(err) });
            try stderr.flush();
            std.process.exit(1);
        };
        defer alloc.free(file_content);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(file_content, &digest, .{});

        // Hex encode the hash
        var hex: [64]u8 = undefined;
        for (digest, 0..) |byte, idx| {
            const high: u4 = @truncate(byte >> 4);
            const low: u4 = @truncate(byte);
            hex[idx * 2] = "0123456789abcdef"[high];
            hex[idx * 2 + 1] = "0123456789abcdef"[low];
        }
        hash = try std.fmt.allocPrint(alloc, "sha256:{s}", .{&hex});

        // Copy file to evidence store
        const exp_id_str = exp_id.encode();
        const evidence_dir = try std.fmt.allocPrint(alloc, "{s}/agx/evidence/{s}", .{ ctx.common_dir, &exp_id_str });
        defer alloc.free(evidence_dir);

        std.fs.cwd().makePath(evidence_dir) catch {};

        const dest = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ evidence_dir, &hex });
        defer alloc.free(dest);

        std.fs.cwd().copyFile(fp, std.fs.cwd(), dest, .{}) catch |err| {
            try stderr.print("warning: could not copy evidence file: {s}\n", .{@errorName(err)});
            try stderr.flush();
        };
        raw_path = try alloc.dupe(u8, dest);
    }

    const now = std.time.milliTimestamp();
    try store.insertEvidence(.{
        .id = agx.Ulid.new(),
        .exploration_id = exp_id,
        .kind = kind,
        .status = status,
        .hash = hash,
        .summary = summary,
        .raw_path = raw_path,
        .recorded_at = now,
    });

    const status_icon: []const u8 = switch (status) {
        .pass => "PASS",
        .fail => "FAIL",
        .@"error" => "ERR ",
        .skip => "SKIP",
    };

    try stdout.print("[{s}] {s}", .{ status_icon, kind_str.? });
    if (summary) |s| {
        try stdout.print(": {s}", .{s});
    }
    try stdout.print("\n", .{});
    try stdout.flush();
}
