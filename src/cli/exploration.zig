const std = @import("std");

const spawn_cmd = @import("spawn.zig");
const status_cmd = @import("status.zig");
const compare_cmd = @import("compare.zig");
const keep_cmd = @import("keep.zig");
const done_cmd = @import("done.zig");
const approach_cmd = @import("approach.zig");
const evidence_cmd = @import("evidence.zig");
const archive_cmd = @import("archive.zig");
const discard_cmd = @import("discard.zig");
const clean_cmd = @import("clean.zig");
const log_cmd = @import("log.zig");

const CommandFn = *const fn (std.mem.Allocator, []const []const u8, *std.Io.Writer, *std.Io.Writer) anyerror!void;

const subcommands = std.StaticStringMap(CommandFn).initComptime(.{
    .{ "create", spawn_cmd.run },
    .{ "status", status_cmd.run },
    .{ "compare", compare_cmd.run },
    .{ "pick", keep_cmd.run },
    .{ "done", done_cmd.run },
    .{ "approach", approach_cmd.run },
    .{ "evidence", evidence_cmd.run },
    .{ "archive", archive_cmd.run },
    .{ "discard", discard_cmd.run },
    .{ "clean", clean_cmd.run },
    .{ "log", log_cmd.run },
});

pub fn run(alloc: std.mem.Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (args.len == 0) {
        try printUsage(stderr);
        try stderr.flush();
        std.process.exit(1);
    }

    if (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) {
        try printUsage(stdout);
        try stdout.flush();
        return;
    }

    const subcmd = args[0];
    const sub_args = args[1..];

    if (subcommands.get(subcmd)) |run_fn| {
        try run_fn(alloc, sub_args, stdout, stderr);
    } else {
        try stderr.print("agx exploration: unknown subcommand '{s}'\n", .{subcmd});
        try printUsage(stderr);
        try stderr.flush();
        std.process.exit(1);
    }
}

fn printUsage(w: *std.Io.Writer) !void {
    try w.print(
        \\Usage: agx exploration <subcommand> [options]
        \\
        \\Subcommands:
        \\  create     Spawn parallel tasks for a goal
        \\  status     Show active goals and tasks
        \\  compare    Compare tasks side by side
        \\  pick       Merge a task into the base branch
        \\  done       Mark current task as complete
        \\  approach   Set the approach description for current task
        \\  evidence   Record evidence (test results, builds, etc.)
        \\  archive    Archive a task (preserve context)
        \\  discard    Remove a task
        \\  clean      Remove all resolved goal artifacts
        \\  log        View events for a task
        \\
    , .{});
}
