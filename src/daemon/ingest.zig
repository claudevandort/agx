const std = @import("std");
const Allocator = std.mem.Allocator;
const Ulid = @import("../core/ulid.zig").Ulid;
const EventKind = @import("../core/event.zig").EventKind;
const Store = @import("../storage/store.zig").Store;

/// A single JSONL event line from an agent.
/// Format: {"kind":"tool_call","data":"{...}","timestamp":1234567890}
/// The session_id is inferred from the filename ({session_id}.jsonl).
pub const RawEvent = struct {
    kind: []const u8,
    data: ?[]const u8,
    timestamp: ?i64,
};

/// Result of an ingest operation.
pub const IngestResult = struct {
    events_ingested: u32,
    events_skipped: u32,
    errors: u32,
};

/// Parse a single JSONL line into a RawEvent.
/// Minimal JSON parsing — we only extract known keys.
pub fn parseLine(line: []const u8) !RawEvent {
    // Trim whitespace
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '{') return error.InvalidJson;

    var kind: ?[]const u8 = null;
    var data: ?[]const u8 = null;
    var timestamp: ?i64 = null;

    // Simple key extraction — find "key":"value" patterns
    kind = extractStringValue(trimmed, "\"kind\"");
    data = extractStringValue(trimmed, "\"data\"");
    timestamp = extractIntValue(trimmed, "\"timestamp\"");

    if (kind == null) return error.MissingKind;

    return .{
        .kind = kind.?,
        .data = data,
        .timestamp = timestamp,
    };
}

/// Ingest events from a JSONL content string for a given session.
pub fn ingestContent(
    alloc: Allocator,
    store: *Store,
    session_id: Ulid,
    content: []const u8,
    offset: usize,
) !IngestResult {
    _ = alloc;
    var result = IngestResult{ .events_ingested = 0, .events_skipped = 0, .errors = 0 };

    var lines = std.mem.splitScalar(u8, content[offset..], '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const raw = parseLine(line) catch {
            result.errors += 1;
            continue;
        };

        const kind = EventKind.fromStr(raw.kind) catch {
            result.errors += 1;
            continue;
        };

        const now = std.time.milliTimestamp();

        store.insertEvent(.{
            .id = Ulid.new(),
            .session_id = session_id,
            .goal_id = null,
            .kind = kind,
            .data = raw.data,
            .created_at = raw.timestamp orelse now,
        }) catch {
            result.errors += 1;
            continue;
        };

        result.events_ingested += 1;
    }

    return result;
}

/// Ingest a single JSONL file. Returns the number of bytes consumed.
pub fn ingestFile(
    alloc: Allocator,
    store: *Store,
    session_id: Ulid,
    file_path: []const u8,
    offset: usize,
) !struct { result: IngestResult, new_offset: usize } {
    const file = std.fs.cwd().openFile(file_path, .{}) catch {
        return .{
            .result = .{ .events_ingested = 0, .events_skipped = 0, .errors = 1 },
            .new_offset = offset,
        };
    };
    defer file.close();

    // Get file size to check if there's new content
    const stat = file.stat() catch {
        return .{
            .result = .{ .events_ingested = 0, .events_skipped = 0, .errors = 1 },
            .new_offset = offset,
        };
    };
    const file_size = stat.size;

    if (file_size <= offset) {
        return .{
            .result = .{ .events_ingested = 0, .events_skipped = 0, .errors = 0 },
            .new_offset = offset,
        };
    }

    // Seek to offset and read only new content
    file.seekTo(offset) catch {
        return .{
            .result = .{ .events_ingested = 0, .events_skipped = 0, .errors = 1 },
            .new_offset = offset,
        };
    };

    const new_len = file_size - offset;
    const max_read: usize = 50 * 1024 * 1024;
    const to_read = @min(new_len, max_read);
    const content = alloc.alloc(u8, to_read) catch {
        return .{
            .result = .{ .events_ingested = 0, .events_skipped = 0, .errors = 1 },
            .new_offset = offset,
        };
    };
    defer alloc.free(content);

    const bytes_read = file.readAll(content) catch {
        return .{
            .result = .{ .events_ingested = 0, .events_skipped = 0, .errors = 1 },
            .new_offset = offset,
        };
    };

    // Pass 0 as offset since content already starts at the right position
    const result = try ingestContent(alloc, store, session_id, content[0..bytes_read], 0);
    return .{ .result = result, .new_offset = offset + bytes_read };
}

// ── Minimal JSON value extraction ──

/// Find a top-level key in a flat JSON object and return the position after the colon.
/// Skips over string values to avoid matching keys inside values.
fn findTopLevelKey(json: []const u8, key: []const u8) ?usize {
    var i: usize = 0;
    while (i < json.len) {
        // Skip whitespace
        if (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r' or json[i] == ',' or json[i] == '{') {
            i += 1;
            continue;
        }
        // At a string — check if it matches the key
        if (json[i] == '"') {
            const match = i + key.len <= json.len and std.mem.eql(u8, json[i .. i + key.len], key);
            // Skip past this string
            i += 1;
            while (i < json.len) : (i += 1) {
                if (json[i] == '\\') {
                    i += 1;
                    continue;
                }
                if (json[i] == '"') {
                    i += 1;
                    break;
                }
            }
            if (match) {
                // Skip colon and whitespace
                while (i < json.len and (json[i] == ':' or json[i] == ' ')) : (i += 1) {}
                return i;
            }
            // Not our key — skip the value
            if (i < json.len and json[i] == ':') {
                i += 1;
                while (i < json.len and json[i] == ' ') : (i += 1) {}
                i = skipJsonValue(json, i);
            }
            continue;
        }
        // Skip any other character (closing brace, etc.)
        i += 1;
    }
    return null;
}

/// Skip over a JSON value (string, number, object, array, bool, null).
fn skipJsonValue(json: []const u8, start: usize) usize {
    if (start >= json.len) return start;
    var i = start;
    switch (json[i]) {
        '"' => {
            i += 1;
            while (i < json.len) : (i += 1) {
                if (json[i] == '\\') {
                    i += 1;
                    continue;
                }
                if (json[i] == '"') return i + 1;
            }
            return i;
        },
        '{', '[' => {
            const close: u8 = if (json[i] == '{') '}' else ']';
            var depth: u32 = 1;
            i += 1;
            while (i < json.len and depth > 0) : (i += 1) {
                if (json[i] == '"') {
                    i += 1;
                    while (i < json.len) : (i += 1) {
                        if (json[i] == '\\') {
                            i += 1;
                            continue;
                        }
                        if (json[i] == '"') break;
                    }
                } else if (json[i] == json[start]) {
                    depth += 1;
                } else if (json[i] == close) {
                    depth -= 1;
                }
            }
            return i;
        },
        else => {
            // number, true, false, null
            while (i < json.len and json[i] != ',' and json[i] != '}' and json[i] != ']') : (i += 1) {}
            return i;
        },
    }
}

fn extractStringValue(json: []const u8, key: []const u8) ?[]const u8 {
    const pos = findTopLevelKey(json, key) orelse return null;
    if (pos >= json.len or json[pos] != '"') return null;

    var i = pos + 1;
    const start = i;
    while (i < json.len) : (i += 1) {
        if (json[i] == '\\') {
            i += 1;
            continue;
        }
        if (json[i] == '"') {
            return json[start..i];
        }
    }
    return null;
}

fn extractIntValue(json: []const u8, key: []const u8) ?i64 {
    const pos = findTopLevelKey(json, key) orelse return null;
    if (pos >= json.len) return null;

    var i = pos;
    const start = i;
    if (i < json.len and json[i] == '-') i += 1;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1) {}
    if (i == start) return null;

    return std.fmt.parseInt(i64, json[start..i], 10) catch null;
}

// ── Tests ──

test "parseLine basic" {
    const line =
        \\{"kind":"tool_call","data":"{\"tool\":\"read\"}","timestamp":1700000000}
    ;
    const raw = try parseLine(line);
    try std.testing.expectEqualSlices(u8, "tool_call", raw.kind);
    try std.testing.expect(raw.data != null);
    try std.testing.expectEqual(@as(i64, 1700000000), raw.timestamp.?);
}

test "parseLine minimal" {
    const line =
        \\{"kind":"message"}
    ;
    const raw = try parseLine(line);
    try std.testing.expectEqualSlices(u8, "message", raw.kind);
    try std.testing.expect(raw.data == null);
    try std.testing.expect(raw.timestamp == null);
}

test "parseLine missing kind" {
    const line =
        \\{"data":"hello"}
    ;
    try std.testing.expectError(error.MissingKind, parseLine(line));
}

test "parseLine empty" {
    try std.testing.expectError(error.InvalidJson, parseLine(""));
    try std.testing.expectError(error.InvalidJson, parseLine("not json"));
}

test "parseLine key inside value does not confuse parser" {
    // "data" value contains the string "kind" — should not match as the kind key
    const line =
        \\{"data":"kind","kind":"decision"}
    ;
    const raw = try parseLine(line);
    try std.testing.expectEqualSlices(u8, "decision", raw.kind);
    try std.testing.expectEqualSlices(u8, "kind", raw.data.?);
}
