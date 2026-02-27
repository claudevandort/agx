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
    const content = std.fs.cwd().readFileAlloc(alloc, file_path, 50 * 1024 * 1024) catch {
        return .{
            .result = .{ .events_ingested = 0, .events_skipped = 0, .errors = 1 },
            .new_offset = offset,
        };
    };
    defer alloc.free(content);

    if (content.len <= offset) {
        return .{
            .result = .{ .events_ingested = 0, .events_skipped = 0, .errors = 0 },
            .new_offset = offset,
        };
    }

    const result = try ingestContent(alloc, store, session_id, content, offset);
    return .{ .result = result, .new_offset = content.len };
}

// ── Minimal JSON value extraction ──

fn extractStringValue(json: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = std.mem.indexOf(u8, json, key) orelse return null;
    const after_key = json[key_pos + key.len ..];

    // Skip ':'  and whitespace
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ':' or after_key[i] == ' ')) : (i += 1) {}
    if (i >= after_key.len or after_key[i] != '"') return null;
    i += 1; // skip opening quote

    // Find closing quote (handle escaped quotes)
    const start = i;
    while (i < after_key.len) : (i += 1) {
        if (after_key[i] == '\\') {
            i += 1; // skip escaped char
            continue;
        }
        if (after_key[i] == '"') {
            return after_key[start..i];
        }
    }
    return null;
}

fn extractIntValue(json: []const u8, key: []const u8) ?i64 {
    const key_pos = std.mem.indexOf(u8, json, key) orelse return null;
    const after_key = json[key_pos + key.len ..];

    // Skip ':' and whitespace
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ':' or after_key[i] == ' ')) : (i += 1) {}
    if (i >= after_key.len) return null;

    // Parse integer
    const start = i;
    if (after_key[i] == '-') i += 1;
    while (i < after_key.len and after_key[i] >= '0' and after_key[i] <= '9') : (i += 1) {}
    if (i == start) return null;

    return std.fmt.parseInt(i64, after_key[start..i], 10) catch null;
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
