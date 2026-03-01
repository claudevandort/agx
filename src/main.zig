const std = @import("std");

const init_cmd = @import("cli/init.zig");
const ingest_cmd = @import("cli/ingest.zig");
const record_cmd = @import("cli/record.zig");
const context_cmd = @import("cli/context.zig");
const exploration_cmd = @import("cli/exploration.zig");
const dispatch_cmd = @import("cli/dispatch.zig");

const CommandFn = *const fn (std.mem.Allocator, []const []const u8, *std.Io.Writer, *std.Io.Writer) anyerror!void;

const commands = std.StaticStringMap(CommandFn).initComptime(.{
    .{ "init", init_cmd.run },
    .{ "exploration", exploration_cmd.run },
    .{ "dispatch", dispatch_cmd.run },
    .{ "ingest", ingest_cmd.run },
    .{ "record", record_cmd.run },
    .{ "context", context_cmd.run },
});

// NOTE: CLI commands call std.process.exit(1) on user-facing errors, which skips
// defer cleanup (store.deinit, GPA leak detection). This is an accepted trade-off
// for CLI ergonomics — the OS reclaims resources on exit. For long-running modes
// (e.g., ingest --watch), errors are handled without process.exit.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        try printUsage(stdout);
        try stdout.flush();
        return;
    }

    const command = args[1];
    const cmd_args = args[2..];

    if (commands.get(command)) |run_fn| {
        run_fn(alloc, cmd_args, stdout, stderr) catch |err| {
            try stderr.print("agx {s}: {s}\n", .{ command, @errorName(err) });
            try stderr.flush();
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, command, "version")) {
        try stdout.print("agx v0.1.0\n", .{});
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage(stdout);
    } else {
        try stderr.print("agx: unknown command '{s}'\n", .{command});
        try stderr.flush();
        std.process.exit(1);
    }

    try stdout.flush();
}

fn printUsage(writer: *std.Io.Writer) !void {
    try writer.print(
        \\agx — Agent-Aware Version Control
        \\
        \\Usage: agx <command> [options]
        \\
        \\Commands:
        \\  init          Initialize agx in the current git repository
        \\  exploration   Manage parallel task explorations for a goal
        \\  dispatch      Multi-goal dispatch execution with conflict-aware merging
        \\  record        Record an event (CLI-based agent integration)
        \\  ingest        Ingest events from JSONL files
        \\  context       Query archived exploration context
        \\  version       Show version
        \\  help          Show this help
        \\
        \\Run 'agx <command> --help' for details on a specific command.
        \\
    , .{});
}
