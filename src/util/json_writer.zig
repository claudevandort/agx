const std = @import("std");

/// Streaming JSON writer that tracks comma state.
/// Wraps a std.Io.Writer and provides structured JSON output methods.
pub const JsonWriter = struct {
    writer: *std.Io.Writer,
    needs_comma: bool,

    pub fn init(writer: *std.Io.Writer) JsonWriter {
        return .{ .writer = writer, .needs_comma = false };
    }

    pub fn beginObject(self: *JsonWriter) !void {
        try self.writer.print("{{", .{});
        self.needs_comma = false;
    }

    pub fn endObject(self: *JsonWriter) !void {
        try self.writer.print("}}", .{});
        self.needs_comma = true;
    }

    pub fn beginArray(self: *JsonWriter) !void {
        try self.writer.print("[", .{});
        self.needs_comma = false;
    }

    pub fn endArray(self: *JsonWriter) !void {
        try self.writer.print("]", .{});
        self.needs_comma = true;
    }

    fn writeComma(self: *JsonWriter) !void {
        if (self.needs_comma) try self.writer.print(",", .{});
    }

    pub fn stringField(self: *JsonWriter, name: []const u8, value: []const u8) !void {
        try self.writeComma();
        try self.writer.print("\"{s}\":\"", .{name});
        try writeJsonEscaped(self.writer, value);
        try self.writer.print("\"", .{});
        self.needs_comma = true;
    }

    pub fn intField(self: *JsonWriter, name: []const u8, value: i64) !void {
        try self.writeComma();
        try self.writer.print("\"{s}\":{d}", .{ name, value });
        self.needs_comma = true;
    }

    pub fn uintField(self: *JsonWriter, name: []const u8, value: u32) !void {
        try self.writeComma();
        try self.writer.print("\"{s}\":{d}", .{ name, value });
        self.needs_comma = true;
    }

    pub fn boolField(self: *JsonWriter, name: []const u8, value: bool) !void {
        try self.writeComma();
        try self.writer.print("\"{s}\":{s}", .{ name, if (value) "true" else "false" });
        self.needs_comma = true;
    }

    pub fn optionalStringField(self: *JsonWriter, name: []const u8, value: ?[]const u8) !void {
        if (value) |v| try self.stringField(name, v);
    }

    pub fn optionalIntField(self: *JsonWriter, name: []const u8, value: ?i64) !void {
        if (value) |v| try self.intField(name, v);
    }

    /// Write a field whose value is pre-encoded raw JSON (no quoting).
    pub fn rawField(self: *JsonWriter, name: []const u8, raw_json: []const u8) !void {
        try self.writeComma();
        try self.writer.print("\"{s}\":{s}", .{ name, raw_json });
        self.needs_comma = true;
    }

    /// Write a bare string value (for arrays of strings).
    pub fn stringValue(self: *JsonWriter, value: []const u8) !void {
        try self.writeComma();
        try self.writer.print("\"", .{});
        try writeJsonEscaped(self.writer, value);
        try self.writer.print("\"", .{});
        self.needs_comma = true;
    }

    /// Write a named array field and open it.
    pub fn arrayField(self: *JsonWriter, name: []const u8) !void {
        try self.writeComma();
        try self.writer.print("\"{s}\":[", .{name});
        self.needs_comma = false;
    }

    /// Begin a nested object as the next value (for arrays of objects).
    pub fn beginObjectValue(self: *JsonWriter) !void {
        try self.writeComma();
        try self.writer.print("{{", .{});
        self.needs_comma = false;
    }
};

/// Write a JSON-escaped version of `s` to `writer`.
/// Escapes: \, ", control chars (as \uXXXX), newlines, tabs.
pub fn writeJsonEscaped(writer: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.print("\\\"", .{}),
            '\\' => try writer.print("\\\\", .{}),
            '\n' => try writer.print("\\n", .{}),
            '\r' => try writer.print("\\r", .{}),
            '\t' => try writer.print("\\t", .{}),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                try writer.print("\\u{x:0>4}", .{@as(u16, ch)});
            },
            else => try writer.print("{c}", .{ch}),
        }
    }
}

test "JsonWriter basic object" {
    var out_buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out_buf);
    var gw = fbs.writer();
    var adapt_buf: [256]u8 = undefined;
    var adapter = gw.adaptToNewApi(&adapt_buf);
    const w = &adapter.new_interface;

    var jw = JsonWriter.init(w);
    try jw.beginObject();
    try jw.stringField("name", "test");
    try jw.intField("value", 42);
    try jw.boolField("ok", true);
    try jw.endObject();
    try w.flush();

    const written = fbs.getWritten();
    try std.testing.expectEqualSlices(u8, "{\"name\":\"test\",\"value\":42,\"ok\":true}", written);
}

test "JsonWriter nested array" {
    var out_buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out_buf);
    var gw = fbs.writer();
    var adapt_buf: [256]u8 = undefined;
    var adapter = gw.adaptToNewApi(&adapt_buf);
    const w = &adapter.new_interface;

    var jw = JsonWriter.init(w);
    try jw.beginObject();
    try jw.arrayField("items");
    try jw.stringValue("a");
    try jw.stringValue("b");
    try jw.endArray();
    try jw.endObject();
    try w.flush();

    const written = fbs.getWritten();
    try std.testing.expectEqualSlices(u8, "{\"items\":[\"a\",\"b\"]}", written);
}

test "writeJsonEscaped special chars" {
    var out_buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out_buf);
    var gw = fbs.writer();
    var adapt_buf: [128]u8 = undefined;
    var adapter = gw.adaptToNewApi(&adapt_buf);
    const w = &adapter.new_interface;

    try writeJsonEscaped(w, "hello\n\"world\"\t\\end");
    try w.flush();

    const written = fbs.getWritten();
    try std.testing.expectEqualSlices(u8, "hello\\n\\\"world\\\"\\t\\\\end", written);
}
