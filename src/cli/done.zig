const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");
const session_util = @import("session_util.zig");

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    // Parse --summary
    var summary: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--summary") or std.mem.eql(u8, args[i], "-s")) {
            i += 1;
            if (i < args.len) summary = args[i];
        }
    }

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const ctx = session_util.getWorktreeContext(aa, stderr) catch {
        std.process.exit(1);
        unreachable;
    };

    var store = try agx.Store.init(aa, ctx.db_path);
    defer store.deinit();

    const exp_id = agx.Ulid.decode(ctx.info.exploration_id_str) catch {
        try stderr.print("error: invalid exploration ID in .agx-session\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    try store.updateExplorationStatus(exp_id, .done, summary);

    const sess_id = agx.Ulid.decode(ctx.info.session_id_str) catch {
        try stderr.print("error: invalid session ID in .agx-session\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };
    try store.endSession(sess_id, .completed);

    const short = exp_id.short(6);
    try stdout.print("Exploration {s} marked as done.\n", .{&short});
    if (summary) |s| {
        try stdout.print("Summary: {s}\n", .{s});
    }
    try stdout.flush();
}
