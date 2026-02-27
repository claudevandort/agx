const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");
const session_util = @import("session_util.zig");

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (args.len == 0) {
        try stderr.print("error: approach description required\n", .{});
        try stderr.print("usage: agx approach \"description of approach\"\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    // The approach is the first positional argument
    const approach = args[0];

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

    try store.updateExplorationApproach(exp_id, approach);

    try stdout.print("Approach set: {s}\n", .{approach});
    try stdout.flush();
}
