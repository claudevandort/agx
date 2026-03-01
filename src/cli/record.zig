const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");
const session_util = @import("session_util.zig");

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    // Parse: agx record <subcommand> [options]
    // Subcommands: event
    if (args.len == 0) {
        try printUsage(stderr);
        std.process.exit(1);
    }

    if (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) {
        try printUsage(stdout);
        return;
    }

    const subcmd = args[0];
    const sub_args = args[1..];

    if (std.mem.eql(u8, subcmd, "event")) {
        try recordEvent(alloc, sub_args, stdout, stderr);
    } else {
        try stderr.print("error: unknown record subcommand '{s}'\n", .{subcmd});
        try printUsage(stderr);
        std.process.exit(1);
    }
}

fn recordEvent(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var kind_str: ?[]const u8 = null;
    var data: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--kind") or std.mem.eql(u8, args[i], "-k")) {
            i += 1;
            if (i < args.len) kind_str = args[i];
        } else if (std.mem.eql(u8, args[i], "--data") or std.mem.eql(u8, args[i], "-d")) {
            i += 1;
            if (i < args.len) data = args[i];
        }
    }

    if (kind_str == null) {
        try stderr.print("error: --kind is required\n", .{});
        try stderr.print("usage: agx record event --kind <type> [--data '<json>']\n", .{});
        try stderr.print("kinds: message, tool_call, tool_result, decision, file_change, git_commit, error, custom\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    const kind = agx.event.EventKind.fromStr(kind_str.?) catch {
        try stderr.print("error: unknown event kind '{s}'\n", .{kind_str.?});
        try stderr.print("valid: message, tool_call, tool_result, decision, file_change, git_commit, error, custom\n", .{});
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

    const sess_id = agx.Ulid.decode(ctx.info.session_id_str) catch {
        try stderr.print("error: invalid session ID in .agx-session\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    const now = std.time.milliTimestamp();
    try store.insertEvent(.{
        .id = agx.Ulid.new(),
        .session_id = sess_id,
        .kind = kind,
        .data = data,
        .created_at = now,
    });

    try stdout.print("Recorded {s} event\n", .{kind_str.?});
    try stdout.flush();
}

fn printUsage(w: *std.Io.Writer) !void {
    try w.print("usage: agx record event --kind <type> [--data '<json>']\n", .{});
    try w.print("kinds: message, tool_call, tool_result, decision, file_change, git_commit, error, custom\n", .{});
    try w.flush();
}
