const std = @import("std");

/// Parsed YAML-style frontmatter from a context markdown file.
pub const Frontmatter = struct {
    task_id: ?[]const u8 = null,
    description: ?[]const u8 = null,
    status: ?[]const u8 = null,
    base_branch: ?[]const u8 = null,
    date: ?[]const u8 = null,
    explorations: ?[]const u8 = null,
};

pub const ParseResult = struct {
    fm: Frontmatter,
    body_start: usize,
};

/// Parse YAML-style frontmatter delimited by "---" lines.
/// Returns the frontmatter struct and the byte offset where the body content starts.
pub fn parseFrontmatter(content: []const u8) ParseResult {
    // Must start with "---\n" or "---\r\n"
    if (!std.mem.startsWith(u8, content, "---\n") and !std.mem.startsWith(u8, content, "---\r\n")) {
        return .{ .fm = .{}, .body_start = 0 };
    }

    // Skip the opening "---\n"
    const start: usize = if (content.len > 4 and content[3] == '\n') 4 else 5;

    // Find the closing "---"
    var end: usize = start;
    var fm = Frontmatter{};

    while (end < content.len) {
        const line_end = std.mem.indexOfScalar(u8, content[end..], '\n') orelse content.len - end;
        const line = std.mem.trimRight(u8, content[end .. end + line_end], &[_]u8{ '\r', ' ' });

        if (std.mem.eql(u8, line, "---")) {
            const body_start = end + line_end + 1;
            return .{ .fm = fm, .body_start = @min(body_start, content.len) };
        }

        // Parse "key: value"
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            const key = std.mem.trim(u8, line[0..colon], &[_]u8{ ' ', '\t' });
            const val = std.mem.trim(u8, line[colon + 1 ..], &[_]u8{ ' ', '\t' });
            if (val.len > 0) {
                if (std.mem.eql(u8, key, "task_id")) {
                    fm.task_id = val;
                } else if (std.mem.eql(u8, key, "description")) {
                    fm.description = val;
                } else if (std.mem.eql(u8, key, "status")) {
                    fm.status = val;
                } else if (std.mem.eql(u8, key, "base_branch")) {
                    fm.base_branch = val;
                } else if (std.mem.eql(u8, key, "date")) {
                    fm.date = val;
                } else if (std.mem.eql(u8, key, "explorations")) {
                    fm.explorations = val;
                }
            }
        }

        end += line_end + 1;
    }

    // No closing "---" found — treat entire content as body
    return .{ .fm = .{}, .body_start = 0 };
}

/// Case-insensitive substring match.
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Check if `id` starts with `prefix` (case-insensitive).
pub fn prefixMatch(id: []const u8, prefix: []const u8) bool {
    if (prefix.len > id.len) return false;
    return std.ascii.eqlIgnoreCase(id[0..prefix.len], prefix);
}

// ── Tests ──

test "parseFrontmatter basic" {
    const content =
        \\---
        \\task_id: 01JK7MTEST123456789ABCDE
        \\description: Test task
        \\status: resolved
        \\base_branch: main
        \\date: 2025-01-15
        \\explorations: 3
        \\---
        \\# Body content here
        \\
    ;

    const result = parseFrontmatter(content);
    try std.testing.expectEqualSlices(u8, "01JK7MTEST123456789ABCDE", result.fm.task_id.?);
    try std.testing.expectEqualSlices(u8, "Test task", result.fm.description.?);
    try std.testing.expectEqualSlices(u8, "resolved", result.fm.status.?);
    try std.testing.expectEqualSlices(u8, "main", result.fm.base_branch.?);
    try std.testing.expectEqualSlices(u8, "2025-01-15", result.fm.date.?);
    try std.testing.expectEqualSlices(u8, "3", result.fm.explorations.?);
    try std.testing.expect(std.mem.startsWith(u8, content[result.body_start..], "# Body content here"));
}

test "parseFrontmatter missing closing delimiter" {
    const content =
        \\---
        \\task_id: ABC
        \\no closing delimiter
        \\
    ;
    const result = parseFrontmatter(content);
    try std.testing.expect(result.fm.task_id == null);
    try std.testing.expect(result.body_start == 0);
}

test "parseFrontmatter no frontmatter" {
    const content = "# Just a normal markdown file\n";
    const result = parseFrontmatter(content);
    try std.testing.expect(result.fm.task_id == null);
    try std.testing.expect(result.body_start == 0);
}

test "containsIgnoreCase" {
    try std.testing.expect(containsIgnoreCase("Hello World", "hello"));
    try std.testing.expect(containsIgnoreCase("Hello World", "WORLD"));
    try std.testing.expect(containsIgnoreCase("Hello World", "lo Wo"));
    try std.testing.expect(!containsIgnoreCase("Hello", "xyz"));
    try std.testing.expect(containsIgnoreCase("anything", ""));
}

test "prefixMatch" {
    try std.testing.expect(prefixMatch("01JK7MTEST", "01JK7M"));
    try std.testing.expect(prefixMatch("01JK7MTEST", "01jk7m"));
    try std.testing.expect(!prefixMatch("01JK7M", "01JK7MTEST"));
}
