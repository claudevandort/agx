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
        try stderr.print("usage: agx exploration evidence --kind <type> --status <pass|fail|error|skip> [--summary \"...\"] [--file path]\n", .{});
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

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const ctx = session_util.getWorktreeContext(aa, stderr) catch {
        std.process.exit(1);
        unreachable;
    };

    var store = try agx.Store.init(aa, ctx.db_path);
    defer store.deinit();

    const task_id = agx.Ulid.decode(ctx.info.task_id_str) catch {
        try stderr.print("error: invalid task ID in .agx-session\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    // If a file was provided, compute its hash and optionally copy it to evidence store
    var hash: ?[]const u8 = null;
    var raw_path: ?[]const u8 = null;

    if (file_path) |fp| {
        // Read file and compute SHA-256
        const file_content = std.fs.cwd().readFileAlloc(aa, fp, 10 * 1024 * 1024) catch |err| {
            try stderr.print("error: could not read file '{s}': {s}\n", .{ fp, @errorName(err) });
            try stderr.flush();
            std.process.exit(1);
        };

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
        hash = try std.fmt.allocPrint(aa, "sha256:{s}", .{&hex});

        // Copy file to evidence store
        const task_id_str = task_id.encode();
        const evidence_dir = try std.fmt.allocPrint(aa, "{s}/agx/evidence/{s}", .{ ctx.common_dir, &task_id_str });

        std.fs.cwd().makePath(evidence_dir) catch {};

        const dest = try std.fmt.allocPrint(aa, "{s}/{s}", .{ evidence_dir, &hex });

        std.fs.cwd().copyFile(fp, std.fs.cwd(), dest, .{}) catch |err| {
            try stderr.print("warning: could not copy evidence file: {s}\n", .{@errorName(err)});
            try stderr.flush();
        };
        raw_path = try aa.dupe(u8, dest);
    }

    const now = std.time.milliTimestamp();
    try store.insertEvidence(.{
        .id = agx.Ulid.new(),
        .exploration_id = task_id,
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
