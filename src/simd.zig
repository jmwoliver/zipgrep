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

/// Find a single byte using SIMD
fn findByte(haystack: []const u8, byte: u8) ?usize {
    if (haystack.len == 0) return null;

    const byte_vec: Vec = @splat(byte);
    var pos: usize = 0;

    // SIMD loop - process VECTOR_WIDTH bytes at a time
    while (pos + VECTOR_WIDTH <= haystack.len) {
        const chunk: Vec = haystack[pos..][0..VECTOR_WIDTH].*;
        const cmp: BoolVec = chunk == byte_vec;

        if (@reduce(.Or, cmp)) {
            const MaskType = std.meta.Int(.unsigned, VECTOR_WIDTH);
            const mask: MaskType = @bitCast(cmp);
            return pos + @ctz(mask);
        }
        pos += VECTOR_WIDTH;
    }

    // Scalar fallback for remaining bytes
    while (pos < haystack.len) : (pos += 1) {
        if (haystack[pos] == byte) return pos;
    }
    return null;
}

/// Find a substring using SIMD-accelerated first byte search followed by memcmp
/// This is the "quick search" approach used by many fast string matchers
pub fn findSubstring(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    // Single byte optimization: use SIMD byte search
    if (needle.len == 1) {
        return findByte(haystack, needle[0]);
    }

    const first_byte = needle[0];
    const first_vec: Vec = @splat(first_byte);
    const max_pos = haystack.len - needle.len;
    var pos: usize = 0;

    // SIMD loop - process VECTOR_WIDTH bytes at a time looking for first byte
    while (pos + VECTOR_WIDTH <= max_pos + 1) {
        const chunk: Vec = haystack[pos..][0..VECTOR_WIDTH].*;
        const cmp: BoolVec = chunk == first_vec;

        if (@reduce(.Or, cmp)) {
            // Found at least one first-byte match in this chunk
            const MaskType = std.meta.Int(.unsigned, VECTOR_WIDTH);
            var mask: MaskType = @bitCast(cmp);

            // Process all matches in this chunk
            while (mask != 0) {
                const offset = @ctz(mask);
                const candidate = pos + offset;

                // Check if we have room for full needle
                if (candidate <= max_pos) {
                    // Verify full needle match
                    if (std.mem.eql(u8, haystack[candidate..][0..needle.len], needle)) {
                        return candidate;
                    }
                }

                // Clear lowest set bit and check next match
                mask &= mask - 1;
            }
        }
        pos += VECTOR_WIDTH;
    }

    // Scalar fallback for remaining positions
    while (pos <= max_pos) : (pos += 1) {
        if (haystack[pos] == first_byte) {
            if (std.mem.eql(u8, haystack[pos..][0..needle.len], needle)) {
                return pos;
            }
        }
    }

    return null;
}



/// Find a substring starting from a given offset
/// Returns the position relative to the start of haystack (not the offset)
pub fn findSubstringFrom(haystack: []const u8, needle: []const u8, start: usize) ?usize {
    if (start >= haystack.len) return null;
    if (needle.len == 0) return start;
    if (start + needle.len > haystack.len) return null;

    // Search in the slice starting from offset
    if (findSubstring(haystack[start..], needle)) |pos| {
        return start + pos;
    }
    return null;
}

/// Find the next newline character using SIMD
pub fn findNewline(haystack: []const u8) ?usize {
    if (haystack.len == 0) return null;

    const newline_vec: Vec = @splat('\n');
    var pos: usize = 0;

    // SIMD loop - process VECTOR_WIDTH bytes at a time
    while (pos + VECTOR_WIDTH <= haystack.len) {
        const chunk: Vec = haystack[pos..][0..VECTOR_WIDTH].*;
        const cmp: BoolVec = chunk == newline_vec;

        if (@reduce(.Or, cmp)) {
            // Found at least one newline in this chunk
            const MaskType = std.meta.Int(.unsigned, VECTOR_WIDTH);
            const mask: MaskType = @bitCast(cmp);
            return pos + @ctz(mask);
        }
        pos += VECTOR_WIDTH;
    }

    // Scalar fallback for remaining bytes
    while (pos < haystack.len) : (pos += 1) {
        if (haystack[pos] == '\n') return pos;
    }
    return null;
}


// Tests

test "findSubstring basic" {
    const data = "hello world, hello universe";
    try std.testing.expectEqual(@as(?usize, 0), findSubstring(data, "hello"));
    try std.testing.expectEqual(@as(?usize, 6), findSubstring(data, "world"));
    try std.testing.expectEqual(@as(?usize, null), findSubstring(data, "xyz"));
}

test "findSubstring empty needle" {
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("hello", ""));
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("", ""));
}

test "findSubstring needle longer than haystack" {
    try std.testing.expectEqual(@as(?usize, null), findSubstring("hi", "hello"));
    try std.testing.expectEqual(@as(?usize, null), findSubstring("", "x"));
}

test "findSubstring single char" {
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("abc", "a"));
    try std.testing.expectEqual(@as(?usize, 1), findSubstring("abc", "b"));
    try std.testing.expectEqual(@as(?usize, 2), findSubstring("abc", "c"));
    try std.testing.expectEqual(@as(?usize, null), findSubstring("abc", "d"));
}

test "findSubstring at start" {
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("hello world", "hello"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("test", "test"));
}

test "findSubstring at end" {
    try std.testing.expectEqual(@as(?usize, 6), findSubstring("hello world", "world"));
    try std.testing.expectEqual(@as(?usize, 3), findSubstring("abcdef", "def"));
}

test "findSubstring no match" {
    try std.testing.expectEqual(@as(?usize, null), findSubstring("hello", "xyz"));
    try std.testing.expectEqual(@as(?usize, null), findSubstring("aaa", "aaaa"));
}

test "findSubstring partial match not found" {
    // Partial prefix that doesn't complete
    try std.testing.expectEqual(@as(?usize, null), findSubstring("hel", "hello"));
    try std.testing.expectEqual(@as(?usize, null), findSubstring("abc", "abd"));
}

test "findSubstring overlapping occurrences" {
    // Should return first match
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("aaaa", "aa"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("abab", "ab"));
}

test "findSubstring exact match" {
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("hello", "hello"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("x", "x"));
}

test "findNewline basic" {
    try std.testing.expectEqual(@as(?usize, 5), findNewline("hello\nworld"));
    try std.testing.expectEqual(@as(?usize, 0), findNewline("\ntest"));
}

test "findNewline not found" {
    try std.testing.expectEqual(@as(?usize, null), findNewline("hello world"));
    try std.testing.expectEqual(@as(?usize, null), findNewline("no newlines here"));
}

test "findNewline at start" {
    try std.testing.expectEqual(@as(?usize, 0), findNewline("\n"));
    try std.testing.expectEqual(@as(?usize, 0), findNewline("\nhello"));
}

test "findNewline empty input" {
    try std.testing.expectEqual(@as(?usize, null), findNewline(""));
}

test "findNewline multiple newlines" {
    // Should return first newline
    try std.testing.expectEqual(@as(?usize, 1), findNewline("a\nb\nc"));
    try std.testing.expectEqual(@as(?usize, 0), findNewline("\n\n\n"));
}

test "findSubstringFrom basic" {
    const data = "hello world, hello universe";
    // Find first "hello" starting from 0
    try std.testing.expectEqual(@as(?usize, 0), findSubstringFrom(data, "hello", 0));
    // Find second "hello" starting from 1
    try std.testing.expectEqual(@as(?usize, 13), findSubstringFrom(data, "hello", 1));
    // Find "world" starting from 0
    try std.testing.expectEqual(@as(?usize, 6), findSubstringFrom(data, "world", 0));
    // Find "world" starting after "world"
    try std.testing.expectEqual(@as(?usize, null), findSubstringFrom(data, "world", 7));
}

test "findSubstringFrom at offset" {
    const data = "abcabc";
    try std.testing.expectEqual(@as(?usize, 0), findSubstringFrom(data, "abc", 0));
    try std.testing.expectEqual(@as(?usize, 3), findSubstringFrom(data, "abc", 1));
    try std.testing.expectEqual(@as(?usize, 3), findSubstringFrom(data, "abc", 3));
    try std.testing.expectEqual(@as(?usize, null), findSubstringFrom(data, "abc", 4));
}

test "findSubstringFrom edge cases" {
    try std.testing.expectEqual(@as(?usize, null), findSubstringFrom("hello", "hello", 1));
    try std.testing.expectEqual(@as(?usize, null), findSubstringFrom("hello", "world", 0));
    try std.testing.expectEqual(@as(?usize, 0), findSubstringFrom("hello", "", 0));
    try std.testing.expectEqual(@as(?usize, 3), findSubstringFrom("hello", "", 3));
    try std.testing.expectEqual(@as(?usize, null), findSubstringFrom("hello", "", 10));
}





