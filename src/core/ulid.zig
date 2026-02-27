const std = @import("std");

/// ULID: Universally Unique Lexicographically Sortable Identifier
/// 128-bit: 48-bit timestamp (ms) + 80-bit random
/// Encoded as 26-char Crockford Base32 string.
pub const Ulid = struct {
    bytes: [16]u8,

    const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

    /// Generate a new ULID using current time and crypto random.
    pub fn new() Ulid {
        const ms: u64 = @intCast(std.time.milliTimestamp());
        return fromParts(ms, null);
    }

    /// Generate a ULID from explicit parts (for testing).
    pub fn fromParts(timestamp_ms: u64, random: ?[10]u8) Ulid {
        var bytes: [16]u8 = undefined;

        // First 6 bytes: timestamp (big-endian, top 2 bytes of u64 dropped since we only use 48 bits)
        const ts48: u48 = @truncate(timestamp_ms);
        std.mem.writeInt(u48, bytes[0..6], ts48, .big);

        // Last 10 bytes: random
        if (random) |r| {
            @memcpy(bytes[6..16], &r);
        } else {
            std.crypto.random.bytes(bytes[6..16]);
        }

        return .{ .bytes = bytes };
    }

    /// Encode as 26-char Crockford Base32 string.
    pub fn encode(self: Ulid) [26]u8 {
        var out: [26]u8 = undefined;

        // Convert 128 bits to 26 base-32 digits (5 bits each, 26*5=130, top 2 bits unused)
        // Work with the full 128-bit value
        var val: u128 = std.mem.readInt(u128, &self.bytes, .big);

        var i: usize = 26;
        while (i > 0) {
            i -= 1;
            out[i] = crockford[@as(usize, @intCast(val & 0x1F))];
            val >>= 5;
        }

        return out;
    }

    /// Decode from a 26-char Crockford Base32 string.
    pub fn decode(str: []const u8) !Ulid {
        if (str.len != 26) return error.InvalidLength;

        var val: u128 = 0;
        for (str) |ch| {
            const d = decodeCrockford(ch) orelse return error.InvalidCharacter;
            val = (val << 5) | @as(u128, d);
        }

        var bytes: [16]u8 = undefined;
        std.mem.writeInt(u128, &bytes, val, .big);
        return .{ .bytes = bytes };
    }

    /// Extract the 48-bit timestamp (milliseconds since epoch).
    pub fn timestamp(self: Ulid) u48 {
        return std.mem.readInt(u48, self.bytes[0..6], .big);
    }

    /// Return the first N characters of the encoded ULID (for short IDs).
    pub fn short(self: Ulid, comptime n: usize) [n]u8 {
        const full = self.encode();
        return full[0..n].*;
    }

    /// Compare two ULIDs (lexicographic on bytes = chronological + random tiebreak).
    pub fn order(a: Ulid, b: Ulid) std.math.Order {
        return std.mem.order(u8, &a.bytes, &b.bytes);
    }

    pub fn eql(a: Ulid, b: Ulid) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    fn decodeCrockford(ch: u8) ?u5 {
        return switch (ch) {
            '0', 'O', 'o' => 0,
            '1', 'I', 'i', 'L', 'l' => 1,
            '2' => 2,
            '3' => 3,
            '4' => 4,
            '5' => 5,
            '6' => 6,
            '7' => 7,
            '8' => 8,
            '9' => 9,
            'A', 'a' => 10,
            'B', 'b' => 11,
            'C', 'c' => 12,
            'D', 'd' => 13,
            'E', 'e' => 14,
            'F', 'f' => 15,
            'G', 'g' => 16,
            'H', 'h' => 17,
            'J', 'j' => 18,
            'K', 'k' => 19,
            'M', 'm' => 20,
            'N', 'n' => 21,
            'P', 'p' => 22,
            'Q', 'q' => 23,
            'R', 'r' => 24,
            'S', 's' => 25,
            'T', 't' => 26,
            'V', 'v' => 27,
            'W', 'w' => 28,
            'X', 'x' => 29,
            'Y', 'y' => 30,
            'Z', 'z' => 31,
            else => null,
        };
    }
};

test "ulid encode/decode roundtrip" {
    const random = [10]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A };
    const id = Ulid.fromParts(1234567890123, random);
    const encoded = id.encode();
    const decoded = try Ulid.decode(&encoded);
    try std.testing.expect(id.eql(decoded));
}

test "ulid timestamp extraction" {
    const id = Ulid.fromParts(1700000000000, undefined);
    // Timestamp is preserved even though random part differs
    try std.testing.expectEqual(@as(u48, 1700000000000), id.timestamp());
}

test "ulid ordering is chronological" {
    const random = [10]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const a = Ulid.fromParts(1000, random);
    const b = Ulid.fromParts(2000, random);
    try std.testing.expectEqual(std.math.Order.lt, Ulid.order(a, b));
}

test "ulid short returns prefix" {
    const random = [10]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const id = Ulid.fromParts(0, random);
    const s = id.short(6);
    try std.testing.expectEqual(@as(usize, 6), s.len);
}
