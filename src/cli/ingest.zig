const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var watch = false;
    var poll_ms: u64 = 1000;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--watch") or std.mem.eql(u8, args[i], "-w")) {
            watch = true;
        } else if (std.mem.eql(u8, args[i], "--poll")) {
            i += 1;
            if (i < args.len) {
                poll_ms = std.fmt.parseInt(u64, args[i], 10) catch {
                    try stderr.print("error: --poll must be a number (milliseconds)\n", .{});
                    try stderr.flush();
                    std.process.exit(1);
                };
            }
        }
    }

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const git = agx.GitCli.init(aa, null);
    const git_dir = git.gitDir() catch {
        try stderr.print("error: not a git repository\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    const db_path = try std.fmt.allocPrintSentinel(aa, "{s}/agx/db.sqlite3", .{git_dir}, 0);

    std.fs.cwd().access(db_path[0..db_path.len :0], .{}) catch {
        try stderr.print("error: agx not initialized. Run 'agx init' first.\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    var store = try agx.Store.init(aa, db_path);
    defer store.deinit();

    const events_dir = try std.fmt.allocPrint(aa, "{s}/agx/events", .{git_dir});

    // Ensure events directory exists
    std.fs.cwd().makePath(events_dir) catch {};

    if (watch) {
        try stdout.print("Watching {s} for events (poll: {d}ms)...\n", .{ events_dir, poll_ms });
        try stdout.flush();
        try agx.file_watcher.watchLoop(aa, &store, events_dir, poll_ms, stdout, 0);
    } else {
        const result = try agx.file_watcher.scanAndIngest(aa, &store, events_dir);

        if (result.events_ingested == 0 and result.errors == 0) {
            try stdout.print("No new events to ingest.\n", .{});
        } else {
            try stdout.print("Ingested {d} event(s)", .{result.events_ingested});
            if (result.errors > 0) {
                try stdout.print(" ({d} errors)", .{result.errors});
            }
            try stdout.print("\n", .{});
        }
        try stdout.flush();
    }
}
