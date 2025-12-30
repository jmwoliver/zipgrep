const std = @import("std");
const builtin = @import("builtin");

// Vector width selection based on target architecture
// AVX2 = 256 bits = 32 bytes, SSE = 128 bits = 16 bytes, fallback = 16 bytes
pub const VECTOR_WIDTH: usize = if (builtin.cpu.arch == .x86_64)
    if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) 32 else 16
else if (builtin.cpu.arch == .aarch64)
    16 // NEON is 128-bit
else
    16;

pub const Vec = @Vector(VECTOR_WIDTH, u8);
pub const BoolVec = @Vector(VECTOR_WIDTH, bool);

/// Find the first occurrence of a single byte in the haystack using SIMD
pub fn findByte(haystack: []const u8, needle: u8) ?usize {
    if (haystack.len == 0) return null;

    const needle_vec: Vec = @splat(needle);
    var i: usize = 0;

    // Process VECTOR_WIDTH bytes at a time
    while (i + VECTOR_WIDTH <= haystack.len) : (i += VECTOR_WIDTH) {
        const chunk: Vec = haystack[i..][0..VECTOR_WIDTH].*;
        const matches: BoolVec = chunk == needle_vec;

        // Convert bool vector to integer for efficient bit operations
        const mask: std.meta.Int(.unsigned, VECTOR_WIDTH) = @bitCast(matches);
        if (mask != 0) {
            return i + @ctz(mask);
        }
    }

    // Scalar fallback for remaining bytes
    while (i < haystack.len) : (i += 1) {
        if (haystack[i] == needle) return i;
    }

    return null;
}

/// Find all occurrences of a single byte, returning an iterator
pub const ByteIterator = struct {
    haystack: []const u8,
    needle: u8,
    pos: usize,

    pub fn next(self: *ByteIterator) ?usize {
        if (self.pos >= self.haystack.len) return null;

        if (findByte(self.haystack[self.pos..], self.needle)) |offset| {
            const result = self.pos + offset;
            self.pos = result + 1;
            return result;
        }
        return null;
    }
};

pub fn findByteIter(haystack: []const u8, needle: u8) ByteIterator {
    return .{
        .haystack = haystack,
        .needle = needle,
        .pos = 0,
    };
}

/// Find a substring using SIMD-accelerated first byte search followed by memcmp
/// This is the "quick search" approach used by many fast string matchers
pub fn findSubstring(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    if (needle.len == 1) return findByte(haystack, needle[0]);

    const first_byte = needle[0];
    const rest = needle[1..];
    var pos: usize = 0;

    while (pos <= haystack.len - needle.len) {
        // Use SIMD to find potential match positions (first byte matches)
        if (findByte(haystack[pos..], first_byte)) |offset| {
            const candidate = pos + offset;

            // Check if we have enough room for the full needle
            if (candidate + needle.len > haystack.len) {
                return null;
            }

            // Verify the rest of the needle matches
            if (std.mem.eql(u8, haystack[candidate + 1 ..][0..rest.len], rest)) {
                return candidate;
            }

            pos = candidate + 1;
        } else {
            return null;
        }
    }

    return null;
}

/// Find all occurrences of a substring
pub const SubstringIterator = struct {
    haystack: []const u8,
    needle: []const u8,
    pos: usize,

    pub fn next(self: *SubstringIterator) ?usize {
        if (self.pos > self.haystack.len or self.pos + self.needle.len > self.haystack.len) {
            return null;
        }

        if (findSubstring(self.haystack[self.pos..], self.needle)) |offset| {
            const result = self.pos + offset;
            self.pos = result + 1;
            return result;
        }
        return null;
    }
};

pub fn findSubstringIter(haystack: []const u8, needle: []const u8) SubstringIterator {
    return .{
        .haystack = haystack,
        .needle = needle,
        .pos = 0,
    };
}

/// Count newlines in a buffer (useful for line number tracking)
pub fn countNewlines(haystack: []const u8) usize {
    var count: usize = 0;
    const newline: u8 = '\n';
    const newline_vec: Vec = @splat(newline);
    var i: usize = 0;

    // SIMD path
    while (i + VECTOR_WIDTH <= haystack.len) : (i += VECTOR_WIDTH) {
        const chunk: Vec = haystack[i..][0..VECTOR_WIDTH].*;
        const matches: BoolVec = chunk == newline_vec;
        const mask: std.meta.Int(.unsigned, VECTOR_WIDTH) = @bitCast(matches);
        count += @popCount(mask);
    }

    // Scalar fallback
    while (i < haystack.len) : (i += 1) {
        if (haystack[i] == newline) count += 1;
    }

    return count;
}

/// Find the next newline character
pub fn findNewline(haystack: []const u8) ?usize {
    return findByte(haystack, '\n');
}

/// Two-byte SIMD search for patterns starting with a specific pair
/// This is useful for regex literal extraction (e.g., finding "fn" quickly)
pub fn findTwoBytes(haystack: []const u8, first: u8, second: u8) ?usize {
    if (haystack.len < 2) return null;

    const first_vec: Vec = @splat(first);
    var i: usize = 0;

    while (i + VECTOR_WIDTH <= haystack.len - 1) {
        const chunk: Vec = haystack[i..][0..VECTOR_WIDTH].*;
        const matches: BoolVec = chunk == first_vec;
        const mask: std.meta.Int(.unsigned, VECTOR_WIDTH) = @bitCast(matches);

        if (mask != 0) {
            // Check each potential match for the second byte
            var m = mask;
            while (m != 0) {
                const bit_pos = @ctz(m);
                const pos = i + bit_pos;
                if (pos + 1 < haystack.len and haystack[pos + 1] == second) {
                    return pos;
                }
                // Clear the lowest set bit
                m &= m - 1;
            }
        }
        i += VECTOR_WIDTH;
    }

    // Scalar fallback
    while (i < haystack.len - 1) : (i += 1) {
        if (haystack[i] == first and haystack[i + 1] == second) {
            return i;
        }
    }

    return null;
}

// Tests
test "findByte basic" {
    const data = "hello world";
    try std.testing.expectEqual(@as(?usize, 0), findByte(data, 'h'));
    try std.testing.expectEqual(@as(?usize, 4), findByte(data, 'o'));
    try std.testing.expectEqual(@as(?usize, 6), findByte(data, 'w'));
    try std.testing.expectEqual(@as(?usize, null), findByte(data, 'x'));
}

test "findByte large buffer" {
    var data: [1024]u8 = undefined;
    @memset(&data, 'a');
    data[1000] = 'x';

    try std.testing.expectEqual(@as(?usize, 1000), findByte(&data, 'x'));
}

test "findSubstring basic" {
    const data = "hello world, hello universe";
    try std.testing.expectEqual(@as(?usize, 0), findSubstring(data, "hello"));
    try std.testing.expectEqual(@as(?usize, 6), findSubstring(data, "world"));
    try std.testing.expectEqual(@as(?usize, null), findSubstring(data, "xyz"));
}

test "findSubstring iterator" {
    const data = "hello hello hello";
    var iter = findSubstringIter(data, "hello");

    try std.testing.expectEqual(@as(?usize, 0), iter.next());
    try std.testing.expectEqual(@as(?usize, 6), iter.next());
    try std.testing.expectEqual(@as(?usize, 12), iter.next());
    try std.testing.expectEqual(@as(?usize, null), iter.next());
}

test "countNewlines" {
    const data = "line1\nline2\nline3\n";
    try std.testing.expectEqual(@as(usize, 3), countNewlines(data));
}

test "findTwoBytes" {
    const data = "fn main() { fn helper() {} }";
    try std.testing.expectEqual(@as(?usize, 0), findTwoBytes(data, 'f', 'n'));
}

