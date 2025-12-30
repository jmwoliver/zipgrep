const std = @import("std");
const matcher_mod = @import("matcher.zig");

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
    literal_prefix: ?[]const u8, // Extracted literal prefix for SIMD pre-filtering
    pattern_storage: ?[]u8, // Storage for the pattern (for prefix extraction)

    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) CompileError!Regex {
        var compiler = Compiler.init(allocator);
        var re = try compiler.compile(pattern);

        // Extract literal prefix for SIMD pre-filtering
        re.literal_prefix = extractLiteralPrefix(pattern);

        // Store the pattern if we have a prefix
        if (re.literal_prefix != null) {
            re.pattern_storage = try allocator.dupe(u8, pattern);
            // Update prefix to point to our owned copy
            re.literal_prefix = re.pattern_storage.?[0..re.literal_prefix.?.len];
        }

        return re;
    }

    /// Extract the literal prefix from a regex pattern (before any metacharacters)
    /// Returns null if no useful literal prefix exists
    fn extractLiteralPrefix(pattern: []const u8) ?[]const u8 {
        if (pattern.len == 0) return null;

        var end: usize = 0;
        var i: usize = 0;

        while (i < pattern.len) : (i += 1) {
            const c = pattern[i];
            switch (c) {
                // Metacharacters that end literal prefix
                '.', '*', '+', '?', '[', ']', '(', ')', '{', '}', '|', '^', '$' => break,
                '\\' => {
                    // Escaped character - could be literal or special
                    if (i + 1 < pattern.len) {
                        const escaped = pattern[i + 1];
                        switch (escaped) {
                            // These are special regex escapes, not literal
                            'd', 'D', 'w', 'W', 's', 'S', 'b', 'B' => break,
                            // These are literal characters
                            'n', 'r', 't' => {
                                // Can't use these in SIMD prefix search easily
                                break;
                            },
                            else => {
                                // Escaped metacharacter or regular char - skip both
                                i += 1;
                                end = i + 1;
                            },
                        }
                    } else {
                        break;
                    }
                },
                else => {
                    end = i + 1;
                },
            }
        }

        // Need at least 2 characters for useful prefix
        if (end >= 2) {
            return pattern[0..end];
        }
        return null;
    }

    /// Get the literal prefix for SIMD pre-filtering
    pub fn getLiteralPrefix(self: *const Regex) ?[]const u8 {
        return self.literal_prefix;
    }

    pub fn deinit(self: *Regex) void {
        self.states.deinit(self.allocator);
        if (self.pattern_storage) |ps| {
            self.allocator.free(ps);
        }
    }

    /// Find the first match in the input
    pub fn find(self: *const Regex, input: []const u8) ?matcher_mod.MatchResult {
        // Try matching at each position
        var pos: usize = 0;
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
            .literal_prefix = null,
            .pattern_storage = null,
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
                const frag_result = try self.parseExpr();
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
                // Create split state for zero-or-more
                const split = try self.addState(.{
                    .transition = .epsilon,
                    .out1 = frag.start,
                });
                self.patch(frag.out, split);
                frag.out.deinit(self.allocator);

                var out = std.ArrayListUnmanaged(usize){};
                try out.append(self.allocator, split);

                return Fragment{ .start = split, .out = out };
            },
            '+' => {
                // One-or-more: frag -> split -> frag | out
                const split = try self.addState(.{
                    .transition = .epsilon,
                    .out1 = frag.start,
                });
                self.patch(frag.out, split);
                frag.out.deinit(self.allocator);

                var out = std.ArrayListUnmanaged(usize){};
                try out.append(self.allocator, split);

                return Fragment{ .start = frag.start, .out = out };
            },
            '?' => {
                // Zero-or-one: split -> frag | out
                const split = try self.addState(.{
                    .transition = .epsilon,
                    .out1 = frag.start,
                });

                var new_out = std.ArrayListUnmanaged(usize){};
                for (frag.out.items) |out_state| {
                    try new_out.append(self.allocator, out_state);
                }
                try new_out.append(self.allocator, split);
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
