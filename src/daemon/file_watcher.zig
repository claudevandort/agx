const std = @import("std");
const Allocator = std.mem.Allocator;
const Ulid = @import("../core/ulid.zig").Ulid;
const Store = @import("../storage/store.zig").Store;
const ingest = @import("ingest.zig");

/// Scan the events directory and ingest any new JSONL content.
/// Offsets are persisted in the store's ingest_offsets table.
pub fn scanAndIngest(
    alloc: Allocator,
    store: *Store,
    events_dir: []const u8,
) !ingest.IngestResult {
    var total = ingest.IngestResult{ .events_ingested = 0, .events_skipped = 0, .errors = 0 };

    var dir = std.fs.cwd().openDir(events_dir, .{ .iterate = true }) catch {
        return total;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;

        // Files must be named {session_id}.jsonl (26-char ULID + .jsonl)
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        if (entry.name.len < 32) continue; // 26 + ".jsonl"

        const session_id_str = entry.name[0 .. entry.name.len - 6]; // strip .jsonl
        const session_id = Ulid.decode(session_id_str) catch continue;

        // Build full path
        const file_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ events_dir, entry.name });
        defer alloc.free(file_path);

        // Get persisted offset for this file
        const current_offset = store.getIngestOffset(entry.name) catch 0;

        const result = try ingest.ingestFile(alloc, store, session_id, file_path, current_offset);

        // Persist new offset — warn on failure since duplicate events may result
        if (result.new_offset > current_offset) {
            store.setIngestOffset(entry.name, result.new_offset) catch {
                std.log.warn("failed to persist ingest offset for {s}; duplicates may occur on next scan", .{entry.name});
            };
        }

        total.events_ingested += result.result.events_ingested;
        total.events_skipped += result.result.events_skipped;
        total.errors += result.result.errors;
    }

    return total;
}

/// Run in watch mode — poll the events directory at an interval.
pub fn watchLoop(
    alloc: Allocator,
    store: *Store,
    events_dir: []const u8,
    poll_ms: u64,
    writer: *std.Io.Writer,
    max_iterations: u32,
) !void {
    var iterations: u32 = 0;
    while (max_iterations == 0 or iterations < max_iterations) : (iterations += 1) {
        const result = try scanAndIngest(alloc, store, events_dir);

        if (result.events_ingested > 0) {
            try writer.print("Ingested {d} event(s)", .{result.events_ingested});
            if (result.errors > 0) {
                try writer.print(" ({d} errors)", .{result.errors});
            }
            try writer.print("\n", .{});
            try writer.flush();
        }

        std.Thread.sleep(poll_ms * std.time.ns_per_ms);
    }
}
