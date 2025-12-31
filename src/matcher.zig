const std = @import("std");
const simd = @import("simd.zig");
const regex = @import("regex.zig");

pub const MatchResult = struct {
    start: usize,
    end: usize,
};

pub const Matcher = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    ignore_case: bool,
    word_boundary: bool,
    is_literal: bool,
    regex_engine: ?regex.Regex,
    lower_pattern: ?[]u8,

    pub fn init(allocator: std.mem.Allocator, pattern: []const u8, ignore_case: bool, word_boundary: bool) !Matcher {
        const is_literal = !containsRegexMetaChars(pattern);

        var lower_pattern: ?[]u8 = null;
        if (ignore_case and is_literal) {
            lower_pattern = try allocator.alloc(u8, pattern.len);
            for (pattern, 0..) |c, i| {
                lower_pattern.?[i] = std.ascii.toLower(c);
            }
        }

        var regex_engine: ?regex.Regex = null;
        if (!is_literal) {
            regex_engine = try regex.Regex.compile(allocator, pattern);
        }

        return .{
            .allocator = allocator,
            .pattern = pattern,
            .ignore_case = ignore_case,
            .word_boundary = word_boundary,
            .is_literal = is_literal,
            .regex_engine = regex_engine,
            .lower_pattern = lower_pattern,
        };
    }

    pub fn deinit(self: *Matcher) void {
        if (self.regex_engine) |*re| {
            re.deinit();
        }
        if (self.lower_pattern) |lp| {
            self.allocator.free(lp);
        }
    }

    /// Find the first match in the given haystack
    pub fn findFirst(self: *const Matcher, haystack: []const u8) ?MatchResult {
        return self.findFirstFrom(haystack, 0);
    }

    /// Find the first match starting from a given offset
    fn findFirstFrom(self: *const Matcher, haystack: []const u8, start_offset: usize) ?MatchResult {
        if (start_offset >= haystack.len) return null;

        const search_slice = haystack[start_offset..];

        const result = if (self.is_literal)
            self.findLiteralIn(search_slice)
        else blk: {
            if (self.regex_engine) |*re| {
                // Use literal prefix for SIMD pre-filtering if available
                // This quickly rejects lines that can't possibly match
                if (re.getLiteralPrefix()) |prefix| {
                    // Fast path: check if prefix exists using SIMD
                    if (simd.findSubstring(search_slice, prefix) == null) {
                        break :blk null; // No prefix = no match possible
                    }
                }
                // Full regex match
                break :blk re.find(search_slice);
            }
            break :blk null;
        };

        if (result) |r| {
            // Adjust positions back to original haystack coordinates
            const adjusted = MatchResult{
                .start = r.start + start_offset,
                .end = r.end + start_offset,
            };

            // If word boundary mode is enabled, validate the match
            if (self.word_boundary) {
                if (!isWordBoundaryMatch(haystack, adjusted.start, adjusted.end)) {
                    // Not a word boundary match, try again from next position
                    return self.findFirstFrom(haystack, adjusted.start + 1);
                }
            }

            return adjusted;
        }

        return null;
    }

    /// Check if a match at the given position satisfies word boundary constraints
    fn isWordBoundaryMatch(haystack: []const u8, start: usize, end: usize) bool {
        // Check character before match (must be non-word char or start of string)
        const before_ok = (start == 0) or !isWordChar(haystack[start - 1]);
        // Check character after match (must be non-word char or end of string)
        const after_ok = (end >= haystack.len) or !isWordChar(haystack[end]);
        return before_ok and after_ok;
    }

    /// Check if a character is a "word" character (alphanumeric or underscore)
    fn isWordChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    /// Check if the haystack contains a match
    pub fn matches(self: *const Matcher, haystack: []const u8) bool {
        return self.findFirst(haystack) != null;
    }

    fn findLiteralIn(self: *const Matcher, haystack: []const u8) ?MatchResult {
        if (self.ignore_case) {
            return self.findLiteralIgnoreCase(haystack);
        }

        // Use SIMD-accelerated search for literal patterns
        if (simd.findSubstring(haystack, self.pattern)) |pos| {
            return MatchResult{
                .start = pos,
                .end = pos + self.pattern.len,
            };
        }
        return null;
    }

    fn findLiteralIgnoreCase(self: *const Matcher, haystack: []const u8) ?MatchResult {
        const lower_pat = self.lower_pattern orelse return null;

        // Simple case-insensitive search (could be optimized with SIMD later)
        if (haystack.len < lower_pat.len) return null;

        var i: usize = 0;
        outer: while (i <= haystack.len - lower_pat.len) : (i += 1) {
            for (lower_pat, 0..) |pc, j| {
                const hc = std.ascii.toLower(haystack[i + j]);
                if (hc != pc) continue :outer;
            }
            return MatchResult{
                .start = i,
                .end = i + lower_pat.len,
            };
        }
        return null;
    }

    pub fn containsRegexMetaChars(pattern: []const u8) bool {
        for (pattern) |c| {
            switch (c) {
                '.', '*', '+', '?', '[', ']', '(', ')', '{', '}', '|', '^', '$', '\\' => return true,
                else => {},
            }
        }
        return false;
    }
};

test "literal matching" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "hello", false, false);
    defer m.deinit();

    try std.testing.expect(m.matches("hello world"));
    try std.testing.expect(m.matches("say hello"));
    try std.testing.expect(!m.matches("HELLO"));
    try std.testing.expect(!m.matches("helo"));
}

test "case insensitive matching" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "hello", true, false);
    defer m.deinit();

    try std.testing.expect(m.matches("HELLO world"));
    try std.testing.expect(m.matches("Hello"));
    try std.testing.expect(m.matches("hElLo"));
}

test "matcher regex pattern" {
    const allocator = std.testing.allocator;

    // Pattern with metacharacters should use regex
    var m = try Matcher.init(allocator, "hel+o", false, false);
    defer m.deinit();

    try std.testing.expect(!m.is_literal);
    try std.testing.expect(m.regex_engine != null);
    try std.testing.expect(m.matches("hello"));
    try std.testing.expect(m.matches("helllo"));
    try std.testing.expect(!m.matches("heo"));
}

test "matcher findFirst returns position" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "world", false, false);
    defer m.deinit();

    const result = m.findFirst("hello world");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 6), result.?.start);
    try std.testing.expectEqual(@as(usize, 11), result.?.end);
}

test "matcher no match returns null" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "xyz", false, false);
    defer m.deinit();

    try std.testing.expect(m.findFirst("hello") == null);
    try std.testing.expect(!m.matches("hello"));
}

test "matcher empty haystack" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "test", false, false);
    defer m.deinit();

    try std.testing.expect(m.findFirst("") == null);
    try std.testing.expect(!m.matches(""));
}

test "matcher pattern at start" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "hello", false, false);
    defer m.deinit();

    const result = m.findFirst("hello world");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?.start);
}

test "matcher pattern at end" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "world", false, false);
    defer m.deinit();

    const result = m.findFirst("hello world");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 6), result.?.start);
    try std.testing.expectEqual(@as(usize, 11), result.?.end);
}

test "matcher multiple matches returns first" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "ab", false, false);
    defer m.deinit();

    const result = m.findFirst("ab ab ab");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?.start);
}

test "containsRegexMetaChars" {
    // All metacharacters should be detected
    try std.testing.expect(Matcher.containsRegexMetaChars("."));
    try std.testing.expect(Matcher.containsRegexMetaChars("*"));
    try std.testing.expect(Matcher.containsRegexMetaChars("+"));
    try std.testing.expect(Matcher.containsRegexMetaChars("?"));
    try std.testing.expect(Matcher.containsRegexMetaChars("["));
    try std.testing.expect(Matcher.containsRegexMetaChars("]"));
    try std.testing.expect(Matcher.containsRegexMetaChars("("));
    try std.testing.expect(Matcher.containsRegexMetaChars(")"));
    try std.testing.expect(Matcher.containsRegexMetaChars("{"));
    try std.testing.expect(Matcher.containsRegexMetaChars("}"));
    try std.testing.expect(Matcher.containsRegexMetaChars("|"));
    try std.testing.expect(Matcher.containsRegexMetaChars("^"));
    try std.testing.expect(Matcher.containsRegexMetaChars("$"));
    try std.testing.expect(Matcher.containsRegexMetaChars("\\"));

    // Plain text should not be detected
    try std.testing.expect(!Matcher.containsRegexMetaChars("hello"));
    try std.testing.expect(!Matcher.containsRegexMetaChars("test123"));
    try std.testing.expect(!Matcher.containsRegexMetaChars(""));
}

test "matcher literal is detected" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "hello", false, false);
    defer m.deinit();

    try std.testing.expect(m.is_literal);
    try std.testing.expect(m.regex_engine == null);
}

test "matcher case insensitive creates lower pattern" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "HeLLo", true, false);
    defer m.deinit();

    try std.testing.expect(m.lower_pattern != null);
    try std.testing.expectEqualStrings("hello", m.lower_pattern.?);
}

test "matcher case insensitive position" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "WORLD", true, false);
    defer m.deinit();

    const result = m.findFirst("hello world");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 6), result.?.start);
    try std.testing.expectEqual(@as(usize, 11), result.?.end);
}

test "word boundary literal match" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "foo", false, true); // word_boundary=true
    defer m.deinit();

    // Should match "foo" as a whole word
    try std.testing.expect(m.matches("foo"));
    try std.testing.expect(m.matches("foo bar"));
    try std.testing.expect(m.matches("bar foo"));
    try std.testing.expect(m.matches("bar foo baz"));

    // Should NOT match "foo" as part of another word
    try std.testing.expect(!m.matches("foobar"));
    try std.testing.expect(!m.matches("barfoo"));
    try std.testing.expect(!m.matches("barfoobar"));
}

test "word boundary skips non-boundary matches" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "foo", false, true);
    defer m.deinit();

    // "xfoo foo" - should skip match at pos 1, find match at pos 5
    const result = m.findFirst("xfoo foo");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 5), result.?.start);
    try std.testing.expectEqual(@as(usize, 8), result.?.end);
}

test "word boundary with underscore" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "foo", false, true);
    defer m.deinit();

    // Underscore is a word character, so foo_bar should NOT match "foo"
    try std.testing.expect(!m.matches("foo_bar"));
    try std.testing.expect(!m.matches("bar_foo"));

    // But "foo_" alone should not match either (underscore is word char)
    try std.testing.expect(!m.matches("foo_"));
    try std.testing.expect(!m.matches("_foo"));
}

test "word boundary at string boundaries" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "foo", false, true);
    defer m.deinit();

    // Match at start of string
    const result1 = m.findFirst("foo bar");
    try std.testing.expect(result1 != null);
    try std.testing.expectEqual(@as(usize, 0), result1.?.start);

    // Match at end of string
    const result2 = m.findFirst("bar foo");
    try std.testing.expect(result2 != null);
    try std.testing.expectEqual(@as(usize, 4), result2.?.start);
}

test "word boundary with punctuation" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "foo", false, true);
    defer m.deinit();

    // Punctuation is not a word character, so these should match
    try std.testing.expect(m.matches("foo.bar"));
    try std.testing.expect(m.matches("foo,bar"));
    try std.testing.expect(m.matches("(foo)"));
    try std.testing.expect(m.matches("foo!"));
}

test "word boundary disabled" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "foo", false, false); // word_boundary=false
    defer m.deinit();

    // Without word boundary, should match anywhere
    try std.testing.expect(m.matches("foobar"));
    try std.testing.expect(m.matches("barfoo"));
    try std.testing.expect(m.matches("barfoobar"));
}

