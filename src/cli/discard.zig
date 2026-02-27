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
        try stderr.print("error: exploration index required\n", .{});
        try stderr.print("usage: agx discard <index>\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    const index = std.fmt.parseInt(u32, index_str.?, 10) catch {
        try stderr.print("error: invalid exploration index '{s}'\n", .{index_str.?});
        try stderr.flush();
        std.process.exit(1);
    };

    var ctx = CliContext.open(alloc, stderr);
    defer ctx.deinit();

    const task = ctx.store.getActiveTask() catch {
        try stderr.print("error: no active task found\n", .{});
        try stderr.flush();
        std.process.exit(1);
        unreachable;
    };
    defer task.deinit(alloc);

    const exp = ctx.store.getExplorationByIndex(task.id, index) catch {
        try stderr.print("error: exploration [{d}] not found\n", .{index});
        try stderr.flush();
        std.process.exit(1);
        unreachable;
    };
    defer exp.deinit(alloc);

    if (exp.status == .kept) {
        try stderr.print("error: exploration [{d}] is already kept — cannot discard\n", .{index});
        try stderr.flush();
        std.process.exit(1);
    }

    // Remove worktree
    ctx.git.removeWorktree(exp.worktree_path) catch {};

    // Delete branch
    ctx.git.deleteBranch(exp.branch_name) catch {};

    // Update status
    try ctx.store.updateExplorationStatus(exp.id, .discarded, null);

    try stdout.print("Discarded exploration [{d}] — worktree and branch removed.\n", .{index});
    try stdout.flush();
}
