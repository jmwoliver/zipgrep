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
    is_literal: bool,
    regex_engine: ?regex.Regex,
    lower_pattern: ?[]u8,

    pub fn init(allocator: std.mem.Allocator, pattern: []const u8, ignore_case: bool) !Matcher {
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
        if (self.is_literal) {
            return self.findLiteral(haystack);
        } else {
            if (self.regex_engine) |*re| {
                // Use literal prefix for SIMD pre-filtering if available
                // This quickly rejects lines that can't possibly match
                if (re.getLiteralPrefix()) |prefix| {
                    // Fast path: check if prefix exists using SIMD
                    if (simd.findSubstring(haystack, prefix) == null) {
                        return null; // No prefix = no match possible
                    }
                }
                // Full regex match
                return re.find(haystack);
            }
            return null;
        }
    }

    /// Check if the haystack contains a match
    pub fn matches(self: *const Matcher, haystack: []const u8) bool {
        return self.findFirst(haystack) != null;
    }

    fn findLiteral(self: *const Matcher, haystack: []const u8) ?MatchResult {
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

    fn containsRegexMetaChars(pattern: []const u8) bool {
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

    var m = try Matcher.init(allocator, "hello", false);
    defer m.deinit();

    try std.testing.expect(m.matches("hello world"));
    try std.testing.expect(m.matches("say hello"));
    try std.testing.expect(!m.matches("HELLO"));
    try std.testing.expect(!m.matches("helo"));
}

test "case insensitive matching" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "hello", true);
    defer m.deinit();

    try std.testing.expect(m.matches("HELLO world"));
    try std.testing.expect(m.matches("Hello"));
    try std.testing.expect(m.matches("hElLo"));
}

