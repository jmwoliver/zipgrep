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

/// Find a substring using SIMD-accelerated first byte search followed by memcmp
/// This is the "quick search" approach used by many fast string matchers
pub fn findSubstring(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    if (needle.len == 1) {
        var i: usize = 0;
        while (i < haystack.len) : (i += 1) {
            if (haystack[i] == needle[0]) return i;
        }
        return null;
    }

    const first_byte = needle[0];
    const rest = needle[1..];
    var pos: usize = 0;

    while (pos <= haystack.len - needle.len) {
        // Find potential match positions (first byte matches)
        var found = false;
        var offset: usize = 0;
        var i: usize = 0;
        while (i < haystack[pos..].len) : (i += 1) {
            if (haystack[pos + i] == first_byte) {
                offset = i;
                found = true;
                break;
            }
        }

        if (found) {
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



/// Find the next newline character
pub fn findNewline(haystack: []const u8) ?usize {
    var i: usize = 0;
    while (i < haystack.len) : (i += 1) {
        if (haystack[i] == '\n') return i;
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





