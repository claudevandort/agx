const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");
const CliContext = @import("cli_common.zig").CliContext;

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var index_str: ?[]const u8 = null;

    for (args) |arg| {
        if (arg.len > 0 and arg[0] != '-') {
            index_str = arg;
            break;
        }
    }

    if (index_str == null) {
        try stderr.print("error: task index required\n", .{});
        try stderr.print("usage: agx exploration discard <index>\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    const index = std.fmt.parseInt(u32, index_str.?, 10) catch {
        try stderr.print("error: invalid task index '{s}'\n", .{index_str.?});
        try stderr.flush();
        std.process.exit(1);
    };

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var ctx = CliContext.open(aa, stderr);
    defer ctx.deinit();

    const g = ctx.store.getActiveGoal() catch {
        try stderr.print("error: no active goal found\n", .{});
        try stderr.flush();
        std.process.exit(1);
        unreachable;
    };

    const t = ctx.store.getTaskByIndex(g.id, index) catch {
        try stderr.print("error: task [{d}] not found\n", .{index});
        try stderr.flush();
        std.process.exit(1);
        unreachable;
    };

    if (t.status == .kept) {
        try stderr.print("error: task [{d}] is already kept — cannot discard\n", .{index});
        try stderr.flush();
        std.process.exit(1);
    }

    // Remove worktree
    ctx.git.removeWorktree(t.worktree_path) catch {};

    // Delete branch
    ctx.git.deleteBranch(t.branch_name) catch {};

    // Update status
    try ctx.store.updateTaskStatus(t.id, .discarded, null);

    try stdout.print("Discarded task [{d}] — worktree and branch removed.\n", .{index});
    try stdout.flush();
}
