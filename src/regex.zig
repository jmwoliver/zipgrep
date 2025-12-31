const std = @import("std");
const matcher_mod = @import("matcher.zig");
const literal = @import("literal.zig");
const simd = @import("simd.zig");

/// Maximum number of NFA states supported (256 states = 32 bytes bitset)
/// This is enough for most practical regex patterns
const MAX_STATES: usize = 256;

/// A state in the NFA
const State = struct {
    /// Transition type
    transition: Transition,
    /// Next state(s) - NFA can have epsilon transitions to multiple states
    out1: ?usize = null,
    out2: ?usize = null,
};

const Transition = union(enum) {
    /// Matches any single character
    any: void,
    /// Matches a specific character
    char: u8,
    /// Matches a character class
    char_class: CharClass,
    /// Epsilon transition (no input consumed)
    epsilon: void,
    /// Match state (accepting)
    match: void,
};

const CharClass = struct {
    /// Bitmap for ASCII characters (256 bits = 32 bytes)
    bitmap: [32]u8,
    negated: bool,

    pub fn init(negated: bool) CharClass {
        return .{
            .bitmap = [_]u8{0} ** 32,
            .negated = negated,
        };
    }

    pub fn add(self: *CharClass, c: u8) void {
        self.bitmap[c / 8] |= @as(u8, 1) << @intCast(c % 8);
    }

    pub fn addRange(self: *CharClass, start: u8, end: u8) void {
        var c = start;
        while (c <= end) : (c += 1) {
            self.add(c);
            if (c == 255) break;
        }
    }

    pub fn contains(self: *const CharClass, c: u8) bool {
        const in_set = (self.bitmap[c / 8] & (@as(u8, 1) << @intCast(c % 8))) != 0;
        return if (self.negated) !in_set else in_set;
    }
};

/// Fixed-size bitset for tracking NFA states - no allocations during matching
const StateBitset = struct {
    bits: [MAX_STATES / 64]u64,

    pub fn init() StateBitset {
        return .{ .bits = [_]u64{0} ** (MAX_STATES / 64) };
    }

    pub fn clear(self: *StateBitset) void {
        @memset(&self.bits, 0);
    }

    pub fn set(self: *StateBitset, idx: usize) void {
        if (idx >= MAX_STATES) return;
        self.bits[idx / 64] |= @as(u64, 1) << @intCast(idx % 64);
    }

    pub fn isSet(self: *const StateBitset, idx: usize) bool {
        if (idx >= MAX_STATES) return false;
        return (self.bits[idx / 64] & (@as(u64, 1) << @intCast(idx % 64))) != 0;
    }

    pub fn isEmpty(self: *const StateBitset) bool {
        for (self.bits) |word| {
            if (word != 0) return false;
        }
        return true;
    }

    /// Iterate over set bits
    pub fn iterator(self: *const StateBitset) Iterator {
        return .{ .bitset = self, .word_idx = 0, .bit_idx = 0 };
    }

    const Iterator = struct {
        bitset: *const StateBitset,
        word_idx: usize,
        bit_idx: u6,

        pub fn next(self: *Iterator) ?usize {
            while (self.word_idx < MAX_STATES / 64) {
                var word = self.bitset.bits[self.word_idx];
                // Skip already processed bits
                word &= ~((@as(u64, 1) << self.bit_idx) - 1);

                if (word != 0) {
                    const bit_pos = @ctz(word);
                    const result = self.word_idx * 64 + bit_pos;
                    // Advance to next position
                    if (bit_pos < 63) {
                        self.bit_idx = @intCast(bit_pos + 1);
                    } else {
                        self.word_idx += 1;
                        self.bit_idx = 0;
                    }
                    return result;
                }
                self.word_idx += 1;
                self.bit_idx = 0;
            }
            return null;
        }
    };
};

pub const Regex = struct {
    allocator: std.mem.Allocator,
    states: std.ArrayListUnmanaged(State),
    start: usize,
    match_state: usize, // Cache the match state index for fast checking
    literal_info: ?literal.LiteralInfo, // Extracted literal for SIMD pre-filtering
    pattern_storage: ?[]u8, // Storage for the pattern (for literal extraction)
    starts_with_dot_star: bool, // True if pattern starts with .* (optimization for suffix filter)

    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) CompileError!Regex {
        var compiler = Compiler.init(allocator);
        errdefer compiler.states.deinit(allocator);

        var re = try compiler.compile(pattern);

        // Detect if pattern starts with .* (greedy match-all)
        // This enables optimization in findWithSuffixFilter
        re.starts_with_dot_star = pattern.len >= 2 and pattern[0] == '.' and pattern[1] == '*';

        // Extract best literal for SIMD pre-filtering (prefix, suffix, or inner)
        const extracted_info = literal.extractBestLiteral(pattern);

        // Store the pattern if we have a literal
        if (extracted_info) |info| {
            re.pattern_storage = try allocator.dupe(u8, pattern);
            // Update literal to point to our owned copy
            const lit_start = @intFromPtr(info.literal.ptr) - @intFromPtr(pattern.ptr);
            re.literal_info = .{
                .literal = re.pattern_storage.?[lit_start..][0..info.literal.len],
                .position = info.position,
                .min_offset = info.min_offset,
            };
        }

        return re;
    }

    /// Get the literal info for SIMD pre-filtering
    /// Returns the literal slice if available (for backward compatibility)
    pub fn getLiteralPrefix(self: *const Regex) ?[]const u8 {
        if (self.literal_info) |info| {
            if (info.position == .prefix) {
                return info.literal;
            }
        }
        return null;
    }

    /// Get full literal info including position
    pub fn getLiteralInfo(self: *const Regex) ?literal.LiteralInfo {
        return self.literal_info;
    }

    pub fn deinit(self: *Regex) void {
        self.states.deinit(self.allocator);
        if (self.pattern_storage) |ps| {
            self.allocator.free(ps);
        }
    }

    /// Find the first match in the input using position-aware literal filtering
    pub fn find(self: *const Regex, input: []const u8) ?matcher_mod.MatchResult {
        return self.findFrom(input, 0);
    }

    /// Find the first match starting from a given offset
    /// This allows efficient resume of search after word boundary check fails
    pub fn findFrom(self: *const Regex, input: []const u8, start_offset: usize) ?matcher_mod.MatchResult {
        if (start_offset >= input.len) return null;

        if (self.literal_info) |info| {
            return switch (info.position) {
                .prefix => self.findWithPrefixFilterFrom(input, info.literal, start_offset),
                .suffix => self.findWithSuffixFilterFrom(input, info.literal, start_offset),
                .inner => self.findWithInnerFilterFrom(input, info, start_offset),
            };
        }
        return self.findBruteForceFrom(input, start_offset);
    }

    /// Find using prefix literal as filter, starting from a given offset
    fn findWithPrefixFilterFrom(self: *const Regex, input: []const u8, prefix: []const u8, start_offset: usize) ?matcher_mod.MatchResult {
        var search_pos: usize = start_offset;
        while (simd.findSubstringFrom(input, prefix, search_pos)) |lit_pos| {
            // Found prefix at lit_pos, try matching from there
            if (self.matchAt(input, lit_pos)) |end| {
                return matcher_mod.MatchResult{
                    .start = lit_pos,
                    .end = end,
                };
            }
            search_pos = lit_pos + 1;
        }
        return null;
    }

    /// Find using suffix literal as filter, starting from a given offset
    /// For patterns starting with .*, start_offset means "find suffix AFTER this position"
    fn findWithSuffixFilterFrom(self: *const Regex, input: []const u8, suffix: []const u8, start_offset: usize) ?matcher_mod.MatchResult {
        // For .* patterns, start_offset indicates we should skip suffixes before this position
        // because they've already been tried and failed (e.g., word boundary check)
        var search_pos: usize = start_offset;

        while (simd.findSubstringFrom(input, suffix, search_pos)) |lit_pos| {
            if (self.starts_with_dot_star) {
                // OPTIMIZATION: For patterns like .*SUFFIX, .* is greedy and will consume
                // everything from the start up to the suffix. So we only try matchAt(0).
                // This reduces O(n²) to O(n).
                //
                // However, we must ensure the match covers the suffix at lit_pos specifically.
                // If start_offset > 0, it means a previous match ending earlier failed
                // (e.g., word boundary check), so we need a suffix occurrence AFTER start_offset.
                // The search_pos already ensures lit_pos >= start_offset.
                if (self.matchAt(input, 0)) |end| {
                    // Match must extend to cover this specific suffix occurrence
                    if (end >= lit_pos + suffix.len) {
                        // IMPORTANT: For word boundary checks to work correctly, we return
                        // a match ending at THIS specific suffix occurrence, not the greedy
                        // longest match. This allows the word boundary check to validate
                        // the boundary at this suffix, and if it fails, we can try the next
                        // suffix occurrence.
                        return matcher_mod.MatchResult{
                            .start = 0,
                            .end = lit_pos + suffix.len,
                        };
                    }
                }
                // If matchAt(0) doesn't reach this suffix, no point trying - .* is greedy
                // and will always match the same way from position 0. Move to next suffix.
            } else {
                // For other patterns, try all positions from 0 to lit_pos
                // (or from start_offset if resuming)
                var start: usize = 0;
                while (start <= lit_pos) : (start += 1) {
                    if (self.matchAt(input, start)) |end| {
                        if (end >= lit_pos + suffix.len) {
                            return matcher_mod.MatchResult{
                                .start = start,
                                .end = end,
                            };
                        }
                    }
                }
            }
            search_pos = lit_pos + 1;
        }
        return null;
    }

    /// Find using inner literal as filter, starting from a given offset
    fn findWithInnerFilterFrom(self: *const Regex, input: []const u8, info: literal.LiteralInfo, start_offset: usize) ?matcher_mod.MatchResult {
        var search_pos: usize = start_offset;
        while (simd.findSubstringFrom(input, info.literal, search_pos)) |lit_pos| {
            // Found inner literal at lit_pos
            // Start searching from max(start_offset, lit_pos - min_offset)
            const min_start = if (lit_pos >= info.min_offset) lit_pos - info.min_offset else 0;
            const start_bound = @max(start_offset, min_start);
            var start: usize = start_bound;
            while (start <= lit_pos) : (start += 1) {
                if (self.matchAt(input, start)) |end| {
                    // Match must include the literal
                    if (end > lit_pos) {
                        return matcher_mod.MatchResult{
                            .start = start,
                            .end = end,
                        };
                    }
                }
            }
            search_pos = lit_pos + 1;
        }
        return null;
    }

    /// Brute force find starting from a given offset (fallback when no literal filter)
    fn findBruteForceFrom(self: *const Regex, input: []const u8, start_offset: usize) ?matcher_mod.MatchResult {
        var pos: usize = start_offset;
        while (pos <= input.len) : (pos += 1) {
            if (self.matchAt(input, pos)) |end| {
                return matcher_mod.MatchResult{
                    .start = pos,
                    .end = end,
                };
            }
        }
        return null;
    }

    /// Check if there's a match at the given position - uses bitsets, no allocations
    fn matchAt(self: *const Regex, input: []const u8, start: usize) ?usize {
        var current_states = StateBitset.init();
        var next_states = StateBitset.init();

        // Add start state and follow epsilon transitions
        self.addStateWithEpsilon(&current_states, self.start);

        var longest_match: ?usize = null;

        // Check if start state is already a match
        if (current_states.isSet(self.match_state)) {
            longest_match = start;
        }

        var pos = start;
        while (pos < input.len) : (pos += 1) {
            const c = input[pos];

            // Process all current states
            var iter = current_states.iterator();
            while (iter.next()) |state_idx| {
                const state = self.states.items[state_idx];
                if (self.matchTransition(state.transition, c)) {
                    if (state.out1) |next_state| {
                        self.addStateWithEpsilon(&next_states, next_state);
                    }
                }
            }

            // Swap current and next
            current_states = next_states;
            next_states.clear();

            // Check for match
            if (current_states.isSet(self.match_state)) {
                longest_match = pos + 1;
            }

            // If no states left, break early
            if (current_states.isEmpty()) break;
        }

        return longest_match;
    }

    fn matchTransition(self: *const Regex, transition: Transition, c: u8) bool {
        _ = self;
        return switch (transition) {
            .any => c != '\n', // . doesn't match newline
            .char => |ch| ch == c,
            .char_class => |*cc| cc.contains(c),
            .epsilon, .match => false,
        };
    }

    /// Add a state and follow all epsilon transitions
    fn addStateWithEpsilon(self: *const Regex, states: *StateBitset, state_idx: usize) void {
        if (state_idx >= MAX_STATES or states.isSet(state_idx)) return;

        const state = self.states.items[state_idx];
        states.set(state_idx);

        // Follow epsilon transitions recursively
        if (state.transition == .epsilon) {
            if (state.out1) |next| {
                self.addStateWithEpsilon(states, next);
            }
            if (state.out2) |next| {
                self.addStateWithEpsilon(states, next);
            }
        }
    }
};

pub const CompileError = error{
    OutOfMemory,
    UnexpectedEnd,
    UnmatchedParen,
    UnmatchedBracket,
    TrailingBackslash,
};

const Compiler = struct {
    allocator: std.mem.Allocator,
    states: std.ArrayListUnmanaged(State),
    pos: usize,
    pattern: []const u8,

    fn init(allocator: std.mem.Allocator) Compiler {
        return .{
            .allocator = allocator,
            .states = .{},
            .pos = 0,
            .pattern = undefined,
        };
    }

    fn compile(self: *Compiler, pattern: []const u8) CompileError!Regex {
        self.pattern = pattern;
        self.pos = 0;

        var frag = try self.parseExpr();

        // Add match state
        const match_state = try self.addState(.{ .transition = .match });

        // Connect fragment to match state
        self.patch(frag.out, match_state);
        frag.out.deinit(self.allocator);

        return Regex{
            .allocator = self.allocator,
            .states = self.states,
            .start = frag.start,
            .match_state = match_state,
            .literal_info = null,
            .pattern_storage = null,
            .starts_with_dot_star = false, // Will be set by Regex.compile()
        };
    }

    const Fragment = struct {
        start: usize,
        out: std.ArrayListUnmanaged(usize),
    };

    fn parseExpr(self: *Compiler) CompileError!Fragment {
        var frag = try self.parseTerm();

        while (self.pos < self.pattern.len and self.pattern[self.pos] == '|') {
            self.pos += 1;
            var frag2 = try self.parseTerm();

            // Create split state
            const split = try self.addState(.{
                .transition = .epsilon,
                .out1 = frag.start,
                .out2 = frag2.start,
            });

            // Merge outputs
            for (frag2.out.items) |out| {
                try frag.out.append(self.allocator, out);
            }
            frag2.out.deinit(self.allocator);

            frag.start = split;
        }

        return frag;
    }

    fn parseTerm(self: *Compiler) CompileError!Fragment {
        var frag: ?Fragment = null;
        errdefer if (frag) |*f| f.out.deinit(self.allocator);

        while (self.pos < self.pattern.len) {
            const c = self.pattern[self.pos];
            if (c == '|' or c == ')') break;

            var atom = try self.parseAtom();

            // Handle quantifiers
            if (self.pos < self.pattern.len) {
                const next_char = self.pattern[self.pos];
                if (next_char == '*' or next_char == '+' or next_char == '?') {
                    self.pos += 1;
                    atom = try self.applyQuantifier(atom, next_char);
                }
            }

            if (frag) |*f| {
                // Concatenate
                self.patch(f.out, atom.start);
                f.out.deinit(self.allocator);
                f.out = atom.out;
            } else {
                frag = atom;
            }
        }

        if (frag) |f| {
            return f;
        }

        // Empty pattern - return epsilon transition to self
        const empty = try self.addState(.{ .transition = .epsilon });
        var out = std.ArrayListUnmanaged(usize){};
        try out.append(self.allocator, empty);
        return Fragment{ .start = empty, .out = out };
    }

    fn parseAtom(self: *Compiler) CompileError!Fragment {
        if (self.pos >= self.pattern.len) {
            return error.UnexpectedEnd;
        }

        const c = self.pattern[self.pos];

        switch (c) {
            '.' => {
                self.pos += 1;
                return self.createSingleState(.any);
            },
            '[' => {
                return self.parseCharClass();
            },
            '(' => {
                self.pos += 1;
                var frag_result = try self.parseExpr();
                errdefer frag_result.out.deinit(self.allocator);
                if (self.pos >= self.pattern.len or self.pattern[self.pos] != ')') {
                    return error.UnmatchedParen;
                }
                self.pos += 1;
                return frag_result;
            },
            '^', '$' => {
                // Anchor - for now, just treat as epsilon (simplified)
                self.pos += 1;
                const state = try self.addState(.{ .transition = .epsilon });
                var out = std.ArrayListUnmanaged(usize){};
                try out.append(self.allocator, state);
                return Fragment{ .start = state, .out = out };
            },
            '\\' => {
                self.pos += 1;
                if (self.pos >= self.pattern.len) {
                    return error.TrailingBackslash;
                }
                const escaped = self.pattern[self.pos];
                self.pos += 1;
                return self.createSingleState(.{ .char = self.escapeChar(escaped) });
            },
            else => {
                self.pos += 1;
                return self.createSingleState(.{ .char = c });
            },
        }
    }

    fn parseCharClass(self: *Compiler) CompileError!Fragment {
        self.pos += 1; // Skip '['

        var cc = CharClass.init(false);

        if (self.pos < self.pattern.len and self.pattern[self.pos] == '^') {
            cc.negated = true;
            self.pos += 1;
        }

        while (self.pos < self.pattern.len and self.pattern[self.pos] != ']') {
            const char = self.pattern[self.pos];
            self.pos += 1;

            // Check for range
            if (self.pos + 1 < self.pattern.len and
                self.pattern[self.pos] == '-' and
                self.pattern[self.pos + 1] != ']')
            {
                self.pos += 1; // Skip '-'
                const end = self.pattern[self.pos];
                self.pos += 1;
                cc.addRange(char, end);
            } else {
                cc.add(char);
            }
        }

        if (self.pos >= self.pattern.len) {
            return error.UnmatchedBracket;
        }
        self.pos += 1; // Skip ']'

        return self.createSingleState(.{ .char_class = cc });
    }

    fn createSingleState(self: *Compiler, transition: Transition) CompileError!Fragment {
        const state = try self.addState(.{ .transition = transition });
        var out = std.ArrayListUnmanaged(usize){};
        try out.append(self.allocator, state);
        return Fragment{ .start = state, .out = out };
    }

    fn applyQuantifier(self: *Compiler, frag_in: Fragment, quantifier: u8) CompileError!Fragment {
        var frag = frag_in;
        switch (quantifier) {
            '*' => {
                // Zero-or-more: split state with two paths
                // out1 = go to fragment (match more), out2 = skip (set by patch later)
                const split = try self.addState(.{
                    .transition = .epsilon,
                    .out1 = frag.start, // Path 1: enter the fragment to match
                    // out2 will be set by patch() to point to continuation
                });
                // Loop back: fragment's end points back to split
                self.patch(frag.out, split);
                frag.out.deinit(self.allocator);

                // The "out" of this fragment is split's out2 (the skip path)
                // We need patch() to set out2 instead of out1 for split
                // But patch() always sets out1, so we need a different approach:
                // Use the fact that split is in the out list, and we need to
                // set its out2 when concatenating with the next fragment.
                //
                // Actually, the standard Thompson construction puts split in out
                // so that when patched, out1 gets set to next state. But we already
                // set out1 to frag.start for looping.
                //
                // Solution: Create a second epsilon state for the "skip" path
                const skip = try self.addState(.{ .transition = .epsilon });

                // Update split to have both paths
                self.states.items[split].out2 = skip;

                var out = std.ArrayListUnmanaged(usize){};
                try out.append(self.allocator, skip);

                return Fragment{ .start = split, .out = out };
            },
            '+' => {
                // One-or-more: must match fragment at least once, then optionally more
                // frag.start -> frag -> split -> (loop back to frag.start OR skip to next)
                const split = try self.addState(.{
                    .transition = .epsilon,
                    .out1 = frag.start, // Path 1: loop back for more matches
                });
                self.patch(frag.out, split);
                frag.out.deinit(self.allocator);

                // Create skip state for the "done matching" path
                const skip = try self.addState(.{ .transition = .epsilon });
                self.states.items[split].out2 = skip;

                var out = std.ArrayListUnmanaged(usize){};
                try out.append(self.allocator, skip);

                return Fragment{ .start = frag.start, .out = out };
            },
            '?' => {
                // Zero-or-one: split state with two paths
                // out1 = go to fragment (match), out2 = skip to next
                const skip = try self.addState(.{ .transition = .epsilon });

                const split = try self.addState(.{
                    .transition = .epsilon,
                    .out1 = frag.start, // Path 1: enter fragment
                    .out2 = skip, // Path 2: skip fragment
                });

                // Both fragment's end AND skip need to go to next
                var new_out = std.ArrayListUnmanaged(usize){};
                for (frag.out.items) |out_state| {
                    try new_out.append(self.allocator, out_state);
                }
                try new_out.append(self.allocator, skip);
                frag.out.deinit(self.allocator);

                return Fragment{ .start = split, .out = new_out };
            },
            else => unreachable,
        }
    }

    fn addState(self: *Compiler, state: State) CompileError!usize {
        const idx = self.states.items.len;
        try self.states.append(self.allocator, state);
        return idx;
    }

    fn patch(self: *Compiler, out_list: std.ArrayListUnmanaged(usize), target: usize) void {
        for (out_list.items) |state_idx| {
            self.states.items[state_idx].out1 = target;
        }
    }

    fn escapeChar(self: *Compiler, c: u8) u8 {
        _ = self;
        return switch (c) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            's' => ' ', // Simplified - should be character class
            else => c,
        };
    }
};

// Tests
test "regex literal" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "hello");
    defer re.deinit();

    const result = re.find("say hello world");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 4), result.?.start);
    try std.testing.expectEqual(@as(usize, 9), result.?.end);
}

test "regex dot" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "h.llo");
    defer re.deinit();

    try std.testing.expect(re.find("hello") != null);
    try std.testing.expect(re.find("hallo") != null);
    try std.testing.expect(re.find("hllo") == null);
}

test "regex star" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "ab*c");
    defer re.deinit();

    try std.testing.expect(re.find("ac") != null);
    try std.testing.expect(re.find("abc") != null);
    try std.testing.expect(re.find("abbc") != null);
    try std.testing.expect(re.find("abbbc") != null);
}

test "regex plus" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "ab+c");
    defer re.deinit();

    try std.testing.expect(re.find("ac") == null);
    try std.testing.expect(re.find("abc") != null);
    try std.testing.expect(re.find("abbc") != null);
}

test "regex alternation" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "cat|dog");
    defer re.deinit();

    try std.testing.expect(re.find("cat") != null);
    try std.testing.expect(re.find("dog") != null);
    try std.testing.expect(re.find("bird") == null);
}

test "regex character class" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "[abc]");
    defer re.deinit();

    try std.testing.expect(re.find("a") != null);
    try std.testing.expect(re.find("b") != null);
    try std.testing.expect(re.find("c") != null);
    try std.testing.expect(re.find("d") == null);
}

test "bitset operations" {
    var bs = StateBitset.init();
    try std.testing.expect(bs.isEmpty());

    bs.set(0);
    bs.set(5);
    bs.set(63);
    bs.set(64);
    bs.set(100);

    try std.testing.expect(!bs.isEmpty());
    try std.testing.expect(bs.isSet(0));
    try std.testing.expect(bs.isSet(5));
    try std.testing.expect(bs.isSet(63));
    try std.testing.expect(bs.isSet(64));
    try std.testing.expect(bs.isSet(100));
    try std.testing.expect(!bs.isSet(1));
    try std.testing.expect(!bs.isSet(65));

    // Test iterator
    var iter = bs.iterator();
    try std.testing.expectEqual(@as(?usize, 0), iter.next());
    try std.testing.expectEqual(@as(?usize, 5), iter.next());
    try std.testing.expectEqual(@as(?usize, 63), iter.next());
    try std.testing.expectEqual(@as(?usize, 64), iter.next());
    try std.testing.expectEqual(@as(?usize, 100), iter.next());
    try std.testing.expectEqual(@as(?usize, null), iter.next());
}

test "bitset clear" {
    var bs = StateBitset.init();
    bs.set(0);
    bs.set(100);
    bs.set(255);
    try std.testing.expect(!bs.isEmpty());

    bs.clear();
    try std.testing.expect(bs.isEmpty());
    try std.testing.expect(!bs.isSet(0));
    try std.testing.expect(!bs.isSet(100));
    try std.testing.expect(!bs.isSet(255));
}

test "bitset boundary" {
    var bs = StateBitset.init();

    // Test at MAX_STATES - 1 (last valid index)
    bs.set(MAX_STATES - 1);
    try std.testing.expect(bs.isSet(MAX_STATES - 1));

    // Test at MAX_STATES (should be ignored/return false)
    bs.set(MAX_STATES);
    try std.testing.expect(!bs.isSet(MAX_STATES));
}

test "regex question mark" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "ab?c");
    defer re.deinit();

    try std.testing.expect(re.find("ac") != null);
    try std.testing.expect(re.find("abc") != null);
    try std.testing.expect(re.find("abbc") == null);
}

test "regex nested groups" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "(ab)+");
    defer re.deinit();

    try std.testing.expect(re.find("ab") != null);
    try std.testing.expect(re.find("abab") != null);
    try std.testing.expect(re.find("ababab") != null);
    try std.testing.expect(re.find("a") == null);
}

test "regex escaped metacharacters" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "a\\.b");
    defer re.deinit();

    try std.testing.expect(re.find("a.b") != null);
    try std.testing.expect(re.find("axb") == null);
}

test "regex escape sequences" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "a\\nb");
    defer re.deinit();

    try std.testing.expect(re.find("a\nb") != null);
    try std.testing.expect(re.find("anb") == null);
}

test "regex negated character class" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "[^abc]");
    defer re.deinit();

    try std.testing.expect(re.find("d") != null);
    try std.testing.expect(re.find("x") != null);
    try std.testing.expect(re.find("1") != null);
    // Note: Single char strings "a", "b", "c" should not match
    // But if there's other text around them they might
    try std.testing.expect(re.find("xyz") != null);
}

test "regex character range" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "[a-z]+");
    defer re.deinit();

    try std.testing.expect(re.find("hello") != null);
    try std.testing.expect(re.find("xyz") != null);

    var re2 = try Regex.compile(allocator, "[0-9]+");
    defer re2.deinit();

    try std.testing.expect(re2.find("123") != null);
    try std.testing.expect(re2.find("test") == null);
}

test "regex combined quantifiers" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "a+b*c?");
    defer re.deinit();

    try std.testing.expect(re.find("a") != null);
    try std.testing.expect(re.find("ac") != null);
    try std.testing.expect(re.find("ab") != null);
    try std.testing.expect(re.find("abc") != null);
    try std.testing.expect(re.find("aabbbc") != null);
    try std.testing.expect(re.find("aaaa") != null);
}

test "regex empty pattern" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "");
    defer re.deinit();

    // Empty pattern should match at start of any string
    const result = re.find("hello");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?.start);
}

test "regex no match" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "xyz");
    defer re.deinit();

    try std.testing.expect(re.find("hello") == null);
    try std.testing.expect(re.find("abc") == null);
    try std.testing.expect(re.find("") == null);
}

test "regex match position" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "world");
    defer re.deinit();

    const result = re.find("hello world");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 6), result.?.start);
    try std.testing.expectEqual(@as(usize, 11), result.?.end);
}

test "regex match at start" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "hello");
    defer re.deinit();

    const result = re.find("hello world");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?.start);
    try std.testing.expectEqual(@as(usize, 5), result.?.end);
}

test "regex literal prefix extraction" {
    const allocator = std.testing.allocator;

    // Pattern with literal prefix followed by regex
    var re = try Regex.compile(allocator, "hello.*world");
    defer re.deinit();

    const info = re.getLiteralInfo();
    try std.testing.expect(info != null);
    try std.testing.expectEqualStrings("hello", info.?.literal);
    try std.testing.expectEqual(literal.LiteralInfo.Position.prefix, info.?.position);
}

test "regex literal suffix extraction" {
    const allocator = std.testing.allocator;

    // Pattern starting with metacharacter - should extract suffix
    var re = try Regex.compile(allocator, ".*_PLATFORM");
    defer re.deinit();

    const info = re.getLiteralInfo();
    try std.testing.expect(info != null);
    try std.testing.expectEqualStrings("_PLATFORM", info.?.literal);
    try std.testing.expectEqual(literal.LiteralInfo.Position.suffix, info.?.position);
}

test "regex suffix pattern matching" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, ".*_PLATFORM");
    defer re.deinit();

    // Should find matches
    const result1 = re.find("CONFIG_PLATFORM");
    try std.testing.expect(result1 != null);
    try std.testing.expectEqual(@as(usize, 0), result1.?.start);

    const result2 = re.find("MY_PLATFORM");
    try std.testing.expect(result2 != null);

    // Should not match without suffix
    try std.testing.expect(re.find("PLATFORM_CONFIG") == null);
    try std.testing.expect(re.find("no match here") == null);
}

test "regex no literal extraction for pure regex" {
    const allocator = std.testing.allocator;

    // Pattern with no extractable literal
    var re = try Regex.compile(allocator, "[a-z]+");
    defer re.deinit();

    const info = re.getLiteralInfo();
    try std.testing.expect(info == null);
}

test "regex compile error unmatched paren" {
    const allocator = std.testing.allocator;

    const result = Regex.compile(allocator, "(abc");
    try std.testing.expectError(error.UnmatchedParen, result);
}

test "regex compile error unmatched bracket" {
    const allocator = std.testing.allocator;

    const result = Regex.compile(allocator, "[abc");
    try std.testing.expectError(error.UnmatchedBracket, result);
}

test "regex compile error trailing backslash" {
    const allocator = std.testing.allocator;

    const result = Regex.compile(allocator, "abc\\");
    try std.testing.expectError(error.TrailingBackslash, result);
}

test "CharClass add and contains" {
    var cc = CharClass.init(false);
    cc.add('a');
    cc.add('b');
    cc.add('z');

    try std.testing.expect(cc.contains('a'));
    try std.testing.expect(cc.contains('b'));
    try std.testing.expect(cc.contains('z'));
    try std.testing.expect(!cc.contains('c'));
    try std.testing.expect(!cc.contains('x'));
}

test "CharClass addRange" {
    var cc = CharClass.init(false);
    cc.addRange('a', 'f');

    try std.testing.expect(cc.contains('a'));
    try std.testing.expect(cc.contains('c'));
    try std.testing.expect(cc.contains('f'));
    try std.testing.expect(!cc.contains('g'));
    try std.testing.expect(!cc.contains('z'));
}

test "CharClass negated" {
    var cc = CharClass.init(true); // negated
    cc.add('a');
    cc.add('b');

    // Negated class: contains returns true for chars NOT in the set
    try std.testing.expect(!cc.contains('a'));
    try std.testing.expect(!cc.contains('b'));
    try std.testing.expect(cc.contains('c'));
    try std.testing.expect(cc.contains('z'));
}

test "regex dot does not match newline" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "a.b");
    defer re.deinit();

    try std.testing.expect(re.find("axb") != null);
    try std.testing.expect(re.find("a\nb") == null);
}
