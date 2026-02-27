const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    const ver = sqlite.version();
    try stdout.print("agx v0.1.0 (sqlite {s})\n", .{ver});
    try stdout.flush();
}
