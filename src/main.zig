const std = @import("std");
const agx = @import("agx");

const init_cmd = @import("cli/init.zig");
const spawn_cmd = @import("cli/spawn.zig");
const status_cmd = @import("cli/status.zig");
const done_cmd = @import("cli/done.zig");
const approach_cmd = @import("cli/approach.zig");
const evidence_cmd = @import("cli/evidence.zig");
const compare_cmd = @import("cli/compare.zig");
const keep_cmd = @import("cli/keep.zig");
const archive_cmd = @import("cli/archive.zig");
const discard_cmd = @import("cli/discard.zig");
const clean_cmd = @import("cli/clean.zig");
const ingest_cmd = @import("cli/ingest.zig");

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

    if (std.mem.eql(u8, command, "init")) {
        init_cmd.run(alloc, cmd_args, stdout, stderr) catch |err| {
            try stderr.print("agx init: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, command, "spawn")) {
        spawn_cmd.run(alloc, cmd_args, stdout, stderr) catch |err| {
            try stderr.print("agx spawn: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, command, "status")) {
        status_cmd.run(alloc, cmd_args, stdout, stderr) catch |err| {
            try stderr.print("agx status: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, command, "done")) {
        done_cmd.run(alloc, cmd_args, stdout, stderr) catch |err| {
            try stderr.print("agx done: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, command, "approach")) {
        approach_cmd.run(alloc, cmd_args, stdout, stderr) catch |err| {
            try stderr.print("agx approach: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, command, "evidence")) {
        evidence_cmd.run(alloc, cmd_args, stdout, stderr) catch |err| {
            try stderr.print("agx evidence: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, command, "compare")) {
        compare_cmd.run(alloc, cmd_args, stdout, stderr) catch |err| {
            try stderr.print("agx compare: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, command, "keep")) {
        keep_cmd.run(alloc, cmd_args, stdout, stderr) catch |err| {
            try stderr.print("agx keep: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, command, "archive")) {
        archive_cmd.run(alloc, cmd_args, stdout, stderr) catch |err| {
            try stderr.print("agx archive: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, command, "discard")) {
        discard_cmd.run(alloc, cmd_args, stdout, stderr) catch |err| {
            try stderr.print("agx discard: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, command, "clean")) {
        clean_cmd.run(alloc, cmd_args, stdout, stderr) catch |err| {
            try stderr.print("agx clean: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, command, "ingest")) {
        ingest_cmd.run(alloc, cmd_args, stdout, stderr) catch |err| {
            try stderr.print("agx ingest: {s}\n", .{@errorName(err)});
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
        \\  init       Initialize agx in the current git repository
        \\  spawn      Spawn parallel explorations for a task
        \\  status     Show active tasks and explorations
        \\  done       Mark current exploration as complete
        \\  approach   Set the approach description for current exploration
        \\  evidence   Record evidence (test results, builds, etc.)
        \\  compare    Compare explorations side by side
        \\  keep       Merge an exploration into the base branch
        \\  archive    Archive an exploration (preserve context)
        \\  discard    Remove an exploration
        \\  clean      Remove all resolved task artifacts
        \\  ingest     Ingest events from JSONL files
        \\  version    Show version
        \\  help       Show this help
        \\
    , .{});
}
