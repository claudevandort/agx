const std = @import("std");
const Allocator = std.mem.Allocator;

pub const FileSet = struct {
    task_index: usize,
    files: []const []const u8,
};

/// Extract file paths from git diff --numstat output.
/// Each line is: <added>\t<removed>\t<filepath>
/// Returns a slice of file path strings.
pub fn getChangedFiles(alloc: Allocator, numstat_output: []const u8) ![][]const u8 {
    var files = std.ArrayList([]const u8).empty;
    var line_start: usize = 0;

    while (line_start < numstat_output.len) {
        const line_end = std.mem.indexOfScalar(u8, numstat_output[line_start..], '\n') orelse numstat_output.len - line_start;
        const line = numstat_output[line_start .. line_start + line_end];
        line_start += line_end + 1;

        if (line.len == 0) continue;

        // Find 3rd column (after two tabs)
        var tab_count: usize = 0;
        var col_start: usize = 0;
        for (line, 0..) |ch, idx| {
            if (ch == '\t') {
                tab_count += 1;
                if (tab_count == 2) {
                    col_start = idx + 1;
                    break;
                }
            }
        }
        if (tab_count >= 2 and col_start < line.len) {
            const filepath = std.mem.trimRight(u8, line[col_start..], "\r ");
            if (filepath.len > 0) {
                try files.append(alloc, try alloc.dupe(u8, filepath));
            }
        }
    }

    return files.items;
}

/// Compute optimal merge order based on file overlap.
/// Tasks with the least overlap with other tasks are merged first.
/// Tie-break: fewer total files, then original index.
/// Returns array of task indices in merge order.
pub fn computeMergeOrder(alloc: Allocator, file_sets: []const FileSet) ![]usize {
    const n = file_sets.len;
    if (n == 0) return &[_]usize{};

    // Build a set of files per task for O(1) lookup
    const SetType = std.StringHashMap(void);
    var task_file_sets = try alloc.alloc(SetType, n);
    for (file_sets, 0..) |fs, i| {
        task_file_sets[i] = SetType.init(alloc);
        for (fs.files) |f| {
            try task_file_sets[i].put(f, {});
        }
    }

    // Compute overlap score for each task: number of files shared with any other task
    const scores = try alloc.alloc(u32, n);
    for (0..n) |i| {
        var overlap: u32 = 0;
        var it = task_file_sets[i].keyIterator();
        while (it.next()) |key| {
            for (0..n) |j| {
                if (i == j) continue;
                if (task_file_sets[j].contains(key.*)) {
                    overlap += 1;
                    break; // count each file once even if shared with multiple tasks
                }
            }
        }
        scores[i] = overlap;
    }

    // Create index array and sort by (overlap_score ASC, file_count ASC, original_index ASC)
    const order = try alloc.alloc(usize, n);
    for (0..n) |i| {
        order[i] = i;
    }

    const SortCtx = struct {
        scores: []const u32,
        file_sets: []const FileSet,

        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            if (ctx.scores[a] != ctx.scores[b]) return ctx.scores[a] < ctx.scores[b];
            const a_count = ctx.file_sets[a].files.len;
            const b_count = ctx.file_sets[b].files.len;
            if (a_count != b_count) return a_count < b_count;
            return a < b;
        }
    };

    std.mem.sortUnstable(usize, order, SortCtx{ .scores = scores, .file_sets = file_sets }, SortCtx.lessThan);

    // Map back to task_index values
    for (order) |*o| {
        o.* = file_sets[o.*].task_index;
    }

    return order;
}

// ── Tests ──

test "getChangedFiles parses numstat" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const numstat = "10\t0\tsrc/main.zig\n5\t3\tsrc/lib.zig\n0\t0\tREADME.md\n";

    const files = try getChangedFiles(aa, numstat);
    try std.testing.expectEqual(@as(usize, 3), files.len);
    try std.testing.expectEqualSlices(u8, "src/main.zig", files[0]);
    try std.testing.expectEqualSlices(u8, "src/lib.zig", files[1]);
    try std.testing.expectEqualSlices(u8, "README.md", files[2]);
}

test "getChangedFiles handles empty input" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const files = try getChangedFiles(arena.allocator(), "");
    try std.testing.expectEqual(@as(usize, 0), files.len);
}

test "computeMergeOrder disjoint sets preserve order" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const file_sets = &[_]FileSet{
        .{ .task_index = 0, .files = &.{ "a.zig", "b.zig" } },
        .{ .task_index = 1, .files = &.{ "c.zig", "d.zig" } },
        .{ .task_index = 2, .files = &.{ "e.zig", "f.zig" } },
    };

    const order = try computeMergeOrder(aa, file_sets);
    try std.testing.expectEqual(@as(usize, 3), order.len);
    // All have 0 overlap and same file count, so original order preserved
    try std.testing.expectEqual(@as(usize, 0), order[0]);
    try std.testing.expectEqual(@as(usize, 1), order[1]);
    try std.testing.expectEqual(@as(usize, 2), order[2]);
}

test "computeMergeOrder overlapping sets sorted by least overlap" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    // Task 0: shares "shared.zig" with task 1 and task 2 (overlap=1)
    // Task 1: shares "shared.zig" with task 0, "common.zig" with task 2 (overlap=2)
    // Task 2: shares "shared.zig" with task 0, "common.zig" with task 1 (overlap=2)
    const file_sets = &[_]FileSet{
        .{ .task_index = 0, .files = &.{ "a.zig", "shared.zig" } },
        .{ .task_index = 1, .files = &.{ "b.zig", "shared.zig", "common.zig" } },
        .{ .task_index = 2, .files = &.{ "c.zig", "shared.zig", "common.zig" } },
    };

    const order = try computeMergeOrder(aa, file_sets);
    try std.testing.expectEqual(@as(usize, 3), order.len);
    // Task 0 has least overlap (1), should be first
    try std.testing.expectEqual(@as(usize, 0), order[0]);
    // Tasks 1 and 2 both have overlap 2, but task 1 comes first by index
    try std.testing.expectEqual(@as(usize, 1), order[1]);
    try std.testing.expectEqual(@as(usize, 2), order[2]);
}

test "computeMergeOrder empty input" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const order = try computeMergeOrder(arena.allocator(), &[_]FileSet{});
    try std.testing.expectEqual(@as(usize, 0), order.len);
}
