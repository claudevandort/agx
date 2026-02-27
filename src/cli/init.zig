const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    _ = stderr;

    var shared = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--shared")) {
            shared = true;
        }
    }

    // Verify we're in a git repo
    const git = agx.GitCli.init(alloc, null);
    const git_dir = git.gitDir() catch {
        try stdout.print("error: not a git repository\n", .{});
        try stdout.flush();
        std.process.exit(1);
    };
    defer alloc.free(git_dir);

    // Create .git/agx/ directory structure
    const agx_dir = try std.fmt.allocPrint(alloc, "{s}/agx", .{git_dir});
    defer alloc.free(agx_dir);

    const dirs = [_][]const u8{
        "agx",
        "agx/cache",
        "agx/worktrees",
        "agx/evidence",
    };

    for (dirs) |sub| {
        const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ git_dir, sub });
        defer alloc.free(full);
        std.fs.cwd().makePath(full) catch |err| {
            try stdout.print("error: could not create {s}: {s}\n", .{ full, @errorName(err) });
            try stdout.flush();
            std.process.exit(1);
        };
    }

    // Initialize the SQLite database
    const db_path = try std.fmt.allocPrintSentinel(alloc, "{s}/agx/db.sqlite3", .{git_dir}, 0);
    defer alloc.free(db_path);

    var store = try agx.Store.init(alloc, db_path);
    store.deinit();

    try stdout.print("Initialized agx in {s}/agx/\n", .{git_dir});

    // Create .agx/ for team sharing if --shared
    if (shared) {
        const shared_dirs = [_][]const u8{
            ".agx",
            ".agx/context",
        };
        for (shared_dirs) |dir| {
            std.fs.cwd().makePath(dir) catch |err| {
                try stdout.print("error: could not create {s}: {s}\n", .{ dir, @errorName(err) });
                try stdout.flush();
                std.process.exit(1);
            };
        }

        // Create shared config.toml if it doesn't exist
        const config_file = std.fs.cwd().createFile(".agx/config.toml", .{ .exclusive = true }) catch |err| {
            if (err == error.PathAlreadyExists) {
                try stdout.print("Created .agx/ for team sharing\n", .{});
                try stdout.flush();
                return;
            }
            return err;
        };
        defer config_file.close();

        var config_buf: [256]u8 = undefined;
        var config_writer = config_file.writer(&config_buf);
        try config_writer.interface.print("# agx shared configuration\n", .{});
        try config_writer.interface.flush();

        try stdout.print("Created .agx/ for team sharing\n", .{});
    }

    try stdout.flush();
}
