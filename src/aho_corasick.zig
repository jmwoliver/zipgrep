//! Aho-Corasick automaton for efficient multi-pattern string matching.
//!
//! Based on the classic algorithm: "Efficient String Matching: An Aid to
//! Bibliographic Search" by Aho and Corasick (1975).
//!
//! This implementation uses a state machine where:
//! - States are nodes in a trie built from all patterns
//! - Failure links allow backtracking without re-scanning input
//! - Output links collect all matching patterns at each state
//! - Uses dense transition tables for O(1) byte lookup
//!
//! Complexity:
//! - Construction: O(sum of pattern lengths × alphabet_size)
//! - Search: O(input_length + number_of_matches)

const std = @import("std");

/// Maximum alphabet size (full byte range)
const ALPHABET_SIZE: usize = 256;

/// Sentinel value indicating no transition (state 0 is root, so we use max u32)
const NO_TRANSITION: u32 = std.math.maxInt(u32);

/// A match found by the automaton
pub const Match = struct {
    /// Start position in the haystack
    start: usize,
    /// End position in the haystack (exclusive)
    end: usize,
    /// Index of the pattern that matched
    pattern_idx: usize,
};

/// A single state in the Aho-Corasick automaton
/// Uses dense transition tables for O(1) lookup per byte
const State = struct {
    /// Dense transition table - goto[byte] = next_state or NO_TRANSITION
    /// This uses more memory but provides O(1) transition lookup
    goto: [ALPHABET_SIZE]u32,

    /// Failure link - where to go when no direct transition
    failure: u32,

    /// Output patterns that match at this state (indices into pattern list)
    outputs: std.ArrayListUnmanaged(u32),

    /// Depth of this state (pattern prefix length)
    depth: u16,

    fn init() State {
        return .{
            .goto = [_]u32{NO_TRANSITION} ** ALPHABET_SIZE,
            .failure = 0,
            .outputs = .{},
            .depth = 0,
        };
    }

    fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.outputs.deinit(allocator);
    }

    /// Get the transition for a given byte, or null if none
    inline fn getTransition(self: *const State, byte: u8) ?u32 {
        const next = self.goto[byte];
        return if (next == NO_TRANSITION) null else next;
    }

    /// Set transition for a given byte
    inline fn setTransition(self: *State, byte: u8, state: u32) void {
        self.goto[byte] = state;
    }

    /// Add an output pattern index
    fn addOutput(self: *State, allocator: std.mem.Allocator, pattern_idx: u32) !void {
        try self.outputs.append(allocator, pattern_idx);
    }
};

pub const AhoCorasick = struct {
    allocator: std.mem.Allocator,
    states: std.ArrayListUnmanaged(State),
    patterns: []const []const u8,
    pattern_lengths: []u32,
    max_pattern_len: usize,

    pub fn compile(allocator: std.mem.Allocator, patterns: []const []const u8) !AhoCorasick {
        var ac = AhoCorasick{
            .allocator = allocator,
            .states = .{},
            .patterns = patterns,
            .pattern_lengths = try allocator.alloc(u32, patterns.len),
            .max_pattern_len = 0,
        };
        errdefer ac.deinit();

        // Store pattern lengths and find max
        for (patterns, 0..) |p, i| {
            ac.pattern_lengths[i] = @intCast(p.len);
            ac.max_pattern_len = @max(ac.max_pattern_len, p.len);
        }

        // Create root state
        var root = State.init();
        root.failure = 0;
        try ac.states.append(allocator, root);

        // Phase 1: Build trie (goto function)
        for (patterns, 0..) |pattern, pattern_idx| {
            try ac.addPattern(pattern, @intCast(pattern_idx));
        }

        // Phase 2: Build failure links (BFS from root)
        try ac.buildFailureLinks();

        return ac;
    }

    fn addPattern(self: *AhoCorasick, pattern: []const u8, pattern_idx: u32) !void {
        var state: u32 = 0;

        for (pattern) |c| {
            if (self.states.items[state].getTransition(c)) |next| {
                state = next;
            } else {
                // Create new state
                const new_state: u32 = @intCast(self.states.items.len);
                var new = State.init();
                new.depth = self.states.items[state].depth + 1;
                try self.states.append(self.allocator, new);
                self.states.items[state].setTransition(c, new_state);
                state = new_state;
            }
        }

        // Mark this state as accepting for this pattern
        try self.states.items[state].addOutput(self.allocator, pattern_idx);
    }

    fn buildFailureLinks(self: *AhoCorasick) !void {
        var queue = std.ArrayListUnmanaged(u32){};
        defer queue.deinit(self.allocator);

        // Initialize: all depth-1 states have failure link to root
        // Iterate over all possible bytes to find transitions from root
        for (0..ALPHABET_SIZE) |byte_idx| {
            const byte: u8 = @intCast(byte_idx);
            if (self.states.items[0].getTransition(byte)) |next_state| {
                self.states.items[next_state].failure = 0;
                try queue.append(self.allocator, next_state);
            }
        }

        // BFS to compute failure links for remaining states
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const state = queue.items[head];

            // Iterate over all possible bytes to find transitions from this state
            for (0..ALPHABET_SIZE) |byte_idx| {
                const c: u8 = @intCast(byte_idx);
                const next_state = self.states.items[state].getTransition(c) orelse continue;

                try queue.append(self.allocator, next_state);

                // Find failure state
                var failure = self.states.items[state].failure;
                while (self.states.items[failure].getTransition(c) == null and failure != 0) {
                    failure = self.states.items[failure].failure;
                }

                self.states.items[next_state].failure =
                    self.states.items[failure].getTransition(c) orelse 0;

                // Merge outputs from failure state
                const fail_state = self.states.items[next_state].failure;
                for (self.states.items[fail_state].outputs.items) |out| {
                    try self.states.items[next_state].addOutput(self.allocator, out);
                }
            }
        }
    }

    pub fn deinit(self: *AhoCorasick) void {
        for (self.states.items) |*state| {
            state.deinit(self.allocator);
        }
        self.states.deinit(self.allocator);
        self.allocator.free(self.pattern_lengths);
    }

    /// Find the first match in the haystack
    pub fn findFirst(self: *const AhoCorasick, haystack: []const u8) ?Match {
        return self.findFirstFrom(haystack, 0);
    }

    /// Find the first match starting from a given offset
    pub fn findFirstFrom(self: *const AhoCorasick, haystack: []const u8, start: usize) ?Match {
        if (start >= haystack.len) return null;

        var state: u32 = 0;

        for (haystack[start..], start..) |c, pos| {
            // Follow failure links until we find a transition or reach root
            while (self.states.items[state].getTransition(c) == null and state != 0) {
                state = self.states.items[state].failure;
            }
            state = self.states.items[state].getTransition(c) orelse 0;

            // Check for matches at this state
            const outputs = self.states.items[state].outputs.items;
            if (outputs.len > 0) {
                // Return the first matching pattern
                const pattern_idx = outputs[0];
                const pattern_len = self.pattern_lengths[pattern_idx];
                return Match{
                    .start = pos + 1 - pattern_len,
                    .end = pos + 1,
                    .pattern_idx = pattern_idx,
                };
            }
        }

        return null;
    }

    /// Get the maximum pattern length (useful for buffer overlap handling)
    pub fn getMaxPatternLen(self: *const AhoCorasick) usize {
        return self.max_pattern_len;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "AhoCorasick single pattern" {
    const allocator = std.testing.allocator;
    const patterns = &[_][]const u8{"hello"};

    var ac = try AhoCorasick.compile(allocator, patterns);
    defer ac.deinit();

    const match = ac.findFirst("say hello world");
    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(usize, 4), match.?.start);
    try std.testing.expectEqual(@as(usize, 9), match.?.end);
    try std.testing.expectEqual(@as(usize, 0), match.?.pattern_idx);
}

test "AhoCorasick multiple patterns" {
    const allocator = std.testing.allocator;
    const patterns = &[_][]const u8{ "he", "she", "his", "hers" };

    var ac = try AhoCorasick.compile(allocator, patterns);
    defer ac.deinit();

    const match = ac.findFirst("ushers");
    try std.testing.expect(match != null);
    // Should find "she" at position 1 or "he" at position 2
    // The actual result depends on trie structure
    try std.testing.expect(match.?.start <= 2);
}

test "AhoCorasick no match" {
    const allocator = std.testing.allocator;
    const patterns = &[_][]const u8{ "xyz", "abc" };

    var ac = try AhoCorasick.compile(allocator, patterns);
    defer ac.deinit();

    const match = ac.findFirst("hello world");
    try std.testing.expect(match == null);
}

test "AhoCorasick benchmark patterns" {
    const allocator = std.testing.allocator;
    const patterns = &[_][]const u8{ "ERR_SYS", "PME_TURN_OFF", "LINK_REQ_RST", "CFG_BME_EVT" };

    var ac = try AhoCorasick.compile(allocator, patterns);
    defer ac.deinit();

    const match1 = ac.findFirst("test ERR_SYS here");
    try std.testing.expect(match1 != null);
    try std.testing.expectEqual(@as(usize, 0), match1.?.pattern_idx);
    try std.testing.expectEqual(@as(usize, 5), match1.?.start);
    try std.testing.expectEqual(@as(usize, 12), match1.?.end);

    const match2 = ac.findFirst("test CFG_BME_EVT here");
    try std.testing.expect(match2 != null);
    try std.testing.expectEqual(@as(usize, 3), match2.?.pattern_idx);

    const match3 = ac.findFirst("no matches here");
    try std.testing.expect(match3 == null);
}

test "AhoCorasick findFirstFrom" {
    const allocator = std.testing.allocator;
    const patterns = &[_][]const u8{"foo"};

    var ac = try AhoCorasick.compile(allocator, patterns);
    defer ac.deinit();

    const haystack = "foo bar foo baz foo";

    // First match
    const match1 = ac.findFirstFrom(haystack, 0);
    try std.testing.expect(match1 != null);
    try std.testing.expectEqual(@as(usize, 0), match1.?.start);

    // Skip first, find second
    const match2 = ac.findFirstFrom(haystack, 3);
    try std.testing.expect(match2 != null);
    try std.testing.expectEqual(@as(usize, 8), match2.?.start);

    // Skip first two, find third
    const match3 = ac.findFirstFrom(haystack, 11);
    try std.testing.expect(match3 != null);
    try std.testing.expectEqual(@as(usize, 16), match3.?.start);

    // Past last match
    const match4 = ac.findFirstFrom(haystack, 19);
    try std.testing.expect(match4 == null);
}

test "AhoCorasick overlapping matches" {
    const allocator = std.testing.allocator;
    // "ana" appears twice in "banana" with overlap
    const patterns = &[_][]const u8{"ana"};

    var ac = try AhoCorasick.compile(allocator, patterns);
    defer ac.deinit();

    const match1 = ac.findFirst("banana");
    try std.testing.expect(match1 != null);
    try std.testing.expectEqual(@as(usize, 1), match1.?.start); // First "ana"

    // Find second overlapping match
    const match2 = ac.findFirstFrom("banana", 2);
    try std.testing.expect(match2 != null);
    try std.testing.expectEqual(@as(usize, 3), match2.?.start); // Second "ana"
}

test "AhoCorasick empty patterns list" {
    const allocator = std.testing.allocator;
    const patterns = &[_][]const u8{};

    var ac = try AhoCorasick.compile(allocator, patterns);
    defer ac.deinit();

    const match = ac.findFirst("hello");
    try std.testing.expect(match == null);
}

test "AhoCorasick max pattern length" {
    const allocator = std.testing.allocator;
    const patterns = &[_][]const u8{ "a", "abc", "abcdefghij" };

    var ac = try AhoCorasick.compile(allocator, patterns);
    defer ac.deinit();

    try std.testing.expectEqual(@as(usize, 10), ac.getMaxPatternLen());
}

// =============================================================================
// Additional Edge Case Tests
// =============================================================================

test "AhoCorasick single character patterns" {
    const allocator = std.testing.allocator;
    const patterns = &[_][]const u8{ "a", "b", "c" };

    var ac = try AhoCorasick.compile(allocator, patterns);
    defer ac.deinit();

    const match1 = ac.findFirst("xyz a xyz");
    try std.testing.expect(match1 != null);
    try std.testing.expectEqual(@as(usize, 4), match1.?.start);
    try std.testing.expectEqual(@as(usize, 5), match1.?.end);

    const match2 = ac.findFirst("b");
    try std.testing.expect(match2 != null);
    try std.testing.expectEqual(@as(usize, 0), match2.?.start);

    const match3 = ac.findFirst("xyz");
    try std.testing.expect(match3 == null);
}

test "AhoCorasick patterns with common prefix" {
    const allocator = std.testing.allocator;
    // All patterns share common prefix "config_"
    const patterns = &[_][]const u8{ "config_a", "config_ab", "config_abc" };

    var ac = try AhoCorasick.compile(allocator, patterns);
    defer ac.deinit();

    // Should find shortest match first (config_a) since it completes first
    const match1 = ac.findFirst("test config_abc test");
    try std.testing.expect(match1 != null);
    try std.testing.expectEqual(@as(usize, 5), match1.?.start);
    // Pattern "config_a" matches at position 5, ends at 13
    try std.testing.expectEqual(@as(usize, 13), match1.?.end);
}

test "AhoCorasick patterns with common suffix" {
    const allocator = std.testing.allocator;
    const patterns = &[_][]const u8{ "a_end", "ab_end", "abc_end" };

    var ac = try AhoCorasick.compile(allocator, patterns);
    defer ac.deinit();

    const match = ac.findFirst("test abc_end test");
    try std.testing.expect(match != null);
    // Should find the pattern that matches at this position
    try std.testing.expectEqual(@as(usize, 5), match.?.start);
}

test "AhoCorasick failure link correctness - classic example" {
    const allocator = std.testing.allocator;
    // Classic AC test case: "he", "she", "his", "hers"
    // When searching "ushers", failure links should find "she" inside "ushers"
    const patterns = &[_][]const u8{ "he", "she", "his", "hers" };

    var ac = try AhoCorasick.compile(allocator, patterns);
    defer ac.deinit();

    // "ushers" contains "she" at position 1, "he" at position 2, "hers" at position 2
    const match = ac.findFirst("ushers");
    try std.testing.expect(match != null);

    // Find all matches by iterating
    var matches_found: usize = 0;
    var pos: usize = 0;
    while (ac.findFirstFrom("ushers", pos)) |m| {
        matches_found += 1;
        pos = m.start + 1;
        if (pos >= 6) break;
    }
    // Should find multiple overlapping patterns
    try std.testing.expect(matches_found >= 2);
}

test "AhoCorasick adjacent matches" {
    const allocator = std.testing.allocator;
    const patterns = &[_][]const u8{"ab"};

    var ac = try AhoCorasick.compile(allocator, patterns);
    defer ac.deinit();

    // "abab" has "ab" at positions 0 and 2
    const match1 = ac.findFirst("abab");
    try std.testing.expect(match1 != null);
    try std.testing.expectEqual(@as(usize, 0), match1.?.start);

    const match2 = ac.findFirstFrom("abab", 1);
    try std.testing.expect(match2 != null);
    try std.testing.expectEqual(@as(usize, 2), match2.?.start);
}

test "AhoCorasick match at end of haystack" {
    const allocator = std.testing.allocator;
    const patterns = &[_][]const u8{"end"};

    var ac = try AhoCorasick.compile(allocator, patterns);
    defer ac.deinit();

    const match = ac.findFirst("this is the end");
    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(usize, 12), match.?.start);
    try std.testing.expectEqual(@as(usize, 15), match.?.end);
}

test "AhoCorasick match at start of haystack" {
    const allocator = std.testing.allocator;
    const patterns = &[_][]const u8{"start"};

    var ac = try AhoCorasick.compile(allocator, patterns);
    defer ac.deinit();

    const match = ac.findFirst("start of something");
    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(usize, 0), match.?.start);
    try std.testing.expectEqual(@as(usize, 5), match.?.end);
}

test "AhoCorasick haystack equals pattern" {
    const allocator = std.testing.allocator;
    const patterns = &[_][]const u8{"exact"};

    var ac = try AhoCorasick.compile(allocator, patterns);
    defer ac.deinit();

    const match = ac.findFirst("exact");
    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(usize, 0), match.?.start);
    try std.testing.expectEqual(@as(usize, 5), match.?.end);
}

test "AhoCorasick haystack shorter than all patterns" {
    const allocator = std.testing.allocator;
    const patterns = &[_][]const u8{ "longer", "patterns", "here" };

    var ac = try AhoCorasick.compile(allocator, patterns);
    defer ac.deinit();

    const match = ac.findFirst("ab");
    try std.testing.expect(match == null);
}

test "AhoCorasick empty haystack" {
    const allocator = std.testing.allocator;
    const patterns = &[_][]const u8{"pattern"};

    var ac = try AhoCorasick.compile(allocator, patterns);
    defer ac.deinit();

    const match = ac.findFirst("");
    try std.testing.expect(match == null);
}

test "AhoCorasick special characters in patterns" {
    const allocator = std.testing.allocator;
    // Patterns with underscores, numbers, mixed case
    const patterns = &[_][]const u8{ "ERR_123", "warn_456", "INFO_789" };

    var ac = try AhoCorasick.compile(allocator, patterns);
    defer ac.deinit();

    const match1 = ac.findFirst("test ERR_123 here");
    try std.testing.expect(match1 != null);
    try std.testing.expectEqual(@as(usize, 5), match1.?.start);

    const match2 = ac.findFirst("test warn_456 here");
    try std.testing.expect(match2 != null);
    try std.testing.expectEqual(@as(usize, 5), match2.?.start);
}

test "AhoCorasick multiple matches same pattern" {
    const allocator = std.testing.allocator;
    const patterns = &[_][]const u8{"test"};

    var ac = try AhoCorasick.compile(allocator, patterns);
    defer ac.deinit();

    const haystack = "test one test two test three";
    var count: usize = 0;
    var pos: usize = 0;

    while (ac.findFirstFrom(haystack, pos)) |m| {
        count += 1;
        pos = m.end;
    }

    try std.testing.expectEqual(@as(usize, 3), count);
}

test "AhoCorasick long pattern" {
    const allocator = std.testing.allocator;
    const long_pattern = "this_is_a_very_long_pattern_that_should_still_work";
    const patterns = &[_][]const u8{long_pattern};

    var ac = try AhoCorasick.compile(allocator, patterns);
    defer ac.deinit();

    const haystack = "prefix " ++ long_pattern ++ " suffix";
    const match = ac.findFirst(haystack);
    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(usize, 7), match.?.start);
    try std.testing.expectEqual(@as(usize, 7 + long_pattern.len), match.?.end);
}

test "AhoCorasick many patterns" {
    const allocator = std.testing.allocator;
    // Test with more patterns to stress the trie
    const patterns = &[_][]const u8{
        "alpha", "beta",  "gamma", "delta",
        "epsilon", "zeta", "eta",   "theta",
        "iota", "kappa", "lambda", "mu",
    };

    var ac = try AhoCorasick.compile(allocator, patterns);
    defer ac.deinit();

    try std.testing.expect(ac.findFirst("test alpha here") != null);
    try std.testing.expect(ac.findFirst("test lambda here") != null);
    try std.testing.expect(ac.findFirst("test mu here") != null);
    try std.testing.expect(ac.findFirst("test omega here") == null);
}

test "AhoCorasick pattern is prefix of another" {
    const allocator = std.testing.allocator;
    const patterns = &[_][]const u8{ "ab", "abc", "abcd" };

    var ac = try AhoCorasick.compile(allocator, patterns);
    defer ac.deinit();

    // When searching "abcd", we should find "ab" first (it completes first)
    const match = ac.findFirst("xabcd");
    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(usize, 1), match.?.start);
    // "ab" is the first to match
    try std.testing.expectEqual(@as(usize, 3), match.?.end);
}

test "AhoCorasick no false positives on partial matches" {
    const allocator = std.testing.allocator;
    const patterns = &[_][]const u8{"abcd"};

    var ac = try AhoCorasick.compile(allocator, patterns);
    defer ac.deinit();

    // "abc" is a prefix of "abcd" but shouldn't match
    try std.testing.expect(ac.findFirst("abc") == null);
    try std.testing.expect(ac.findFirst("ab") == null);
    try std.testing.expect(ac.findFirst("a") == null);

    // But "abcd" should match
    try std.testing.expect(ac.findFirst("abcd") != null);
}
