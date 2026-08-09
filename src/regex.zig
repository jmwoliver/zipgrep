const std = @import("std");
const matcher_mod = @import("matcher.zig");
const literal = @import("literal.zig");
const simd = @import("simd.zig");
const unicode_word = @import("unicode_word.zig");

/// Maximum number of NFA states supported (256 states = 32 bytes bitset)
/// This is enough for most practical regex patterns
const MAX_STATES: usize = 256;
const MAX_DFA_STATES: usize = 512;
const DFA_DEAD: u16 = std.math.maxInt(u16);
const DFA_ACCEPTING: u16 = 1 << 15;
const DFA_STATE_MASK: u16 = DFA_ACCEPTING - 1;
const DFA_ROW_MASK: u16 = DFA_ACCEPTING - 256;

fn containsNonAsciiBytes(bytes: []const u8) bool {
    for (bytes) |byte| if (byte >= 0x80) return true;
    return false;
}

const Dfa = struct {
    transitions: []u16,
    accepting: []bool,
    premultiplied: bool,

    fn deinit(self: *Dfa, allocator: std.mem.Allocator) void {
        allocator.free(self.transitions);
        allocator.free(self.accepting);
    }

    inline fn transition(self: *const Dfa, state: u16, byte: u8, comptime premultiplied: bool) u16 {
        const index = if (premultiplied)
            @as(usize, state) + byte
        else
            @as(usize, state) * 256 + byte;
        return self.transitions[index];
    }

    inline fn nextState(transition_value: u16, comptime premultiplied: bool) u16 {
        return transition_value & (if (premultiplied) DFA_ROW_MASK else DFA_STATE_MASK);
    }
};

const WordDfa = struct {
    // Two transition rows per state: without and with an injected anchored
    // start state at the current word-boundary position.
    transitions: []u16,

    fn deinit(self: *WordDfa, allocator: std.mem.Allocator) void {
        allocator.free(self.transitions);
    }

    inline fn transition(self: *const WordDfa, state: u16, byte: u8, inject_start: bool) u16 {
        return self.transitions[(@as(usize, state) * 2 + @intFromBool(inject_start)) * 256 + byte];
    }
};

const AnyRunInfo = struct {
    minimum: usize,
    maximum: ?usize,
};

const CodepointRange = struct {
    start: u21,
    end: u21,
};

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
    char: u21,
    /// Matches a character class
    char_class: CharClass,
    /// Epsilon transition (no input consumed)
    epsilon: void,
    line_start: void,
    line_end: void,
    /// Match state (accepting)
    match: void,
};

const CharClass = struct {
    /// Bitmap for ASCII characters (256 bits = 32 bytes)
    bitmap: [32]u8,
    negated: bool,
    non_ascii: NonAsciiClass,
    range_start: u16,
    range_count: u16,

    const NonAsciiClass = enum {
        none,
        word,
        non_word,
        all,
    };

    pub fn init(negated: bool) CharClass {
        return .{
            .bitmap = [_]u8{0} ** 32,
            .negated = negated,
            .non_ascii = .none,
            .range_start = 0,
            .range_count = 0,
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

    fn containsRaw(self: *const CharClass, c: u8) bool {
        return (self.bitmap[c / 8] & (@as(u8, 1) << @intCast(c % 8))) != 0;
    }

    pub fn contains(self: *const CharClass, c: u8, ignore_case: bool) bool {
        if (!ignore_case) {
            const in_set = self.containsRaw(c);
            return if (self.negated) !in_set else in_set;
        }

        const folded_in_set = self.containsRaw(c) or
            self.containsRaw(std.ascii.toLower(c)) or
            self.containsRaw(std.ascii.toUpper(c));
        return if (self.negated) !folded_in_set else folded_in_set;
    }

    fn containsCodepoint(self: *const CharClass, cp: u21, ignore_case: bool, ranges: []const CodepointRange) bool {
        var in_set = if (cp <= std.math.maxInt(u8)) self.containsRaw(@intCast(cp)) else false;
        if (ignore_case) {
            const folded = matcher_mod.Matcher.simpleFoldCodepoint(cp);
            if (folded <= std.math.maxInt(u8)) {
                const byte: u8 = @intCast(folded);
                in_set = in_set or self.containsRaw(byte) or
                    self.containsRaw(std.ascii.toLower(byte)) or
                    self.containsRaw(std.ascii.toUpper(byte));
            }
        }
        if (cp >= 0x80) {
            in_set = in_set or switch (self.non_ascii) {
                .none => false,
                .word => unicode_word.isWord(cp),
                .non_word => !unicode_word.isWord(cp),
                .all => true,
            };
        }
        for (ranges[self.range_start..][0..self.range_count]) |range| {
            const direct_match = cp >= range.start and cp <= range.end;
            const folded_match = if (ignore_case) blk: {
                const folded = matcher_mod.Matcher.simpleFoldCodepoint(cp);
                const folded_start = matcher_mod.Matcher.simpleFoldCodepoint(range.start);
                const folded_end = matcher_mod.Matcher.simpleFoldCodepoint(range.end);
                break :blk folded >= @min(folded_start, folded_end) and folded <= @max(folded_start, folded_end);
            } else false;
            if (direct_match or folded_match) {
                in_set = true;
                break;
            }
        }
        return if (self.negated) !in_set else in_set;
    }

    fn addClass(self: *CharClass, other: CharClass) void {
        for (0..256) |value| {
            if (other.contains(@intCast(value), false)) self.add(@intCast(value));
        }
        self.non_ascii = unionNonAscii(self.non_ascii, effectiveNonAscii(other));
    }

    fn effectiveNonAscii(self: CharClass) NonAsciiClass {
        if (!self.negated) return self.non_ascii;
        return switch (self.non_ascii) {
            .none => .all,
            .word => .non_word,
            .non_word => .word,
            .all => .none,
        };
    }

    fn unionNonAscii(a: NonAsciiClass, b: NonAsciiClass) NonAsciiClass {
        if (a == .all or b == .all) return .all;
        if (a == .none) return b;
        if (b == .none or a == b) return a;
        return .all;
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

const PikeThread = struct {
    state: u16,
    start: usize,
};

const PikeThreadList = struct {
    threads: [MAX_STATES]PikeThread = undefined,
    len: usize = 0,
    seen: StateBitset = StateBitset.init(),

    fn clear(self: *PikeThreadList) void {
        self.len = 0;
        self.seen.clear();
    }
};

pub const Regex = struct {
    allocator: std.mem.Allocator,
    states: std.ArrayListUnmanaged(State),
    class_ranges: std.ArrayListUnmanaged(CodepointRange),
    start: usize,
    match_state: usize, // Cache the match state index for fast checking
    literal_info: ?literal.LiteralInfo, // Extracted literal for SIMD pre-filtering
    pattern_storage: ?[]u8, // Storage for the pattern (for literal extraction)
    counted_literal_info: ?literal.CountedGroupLiteral,
    required_alternation_info: ?literal.AlternationInfo,
    required_alternation_plan: ?simd.SmallLiteralPlan,
    starts_with_dot_star: bool, // True if pattern starts with .* (optimization for suffix filter)
    empty_line_only: bool,
    any_run_info: ?AnyRunInfo,
    unicode_class_state: ?usize,
    scalar_sensitive: bool,
    always_scalar: bool,
    has_assertions: bool,
    ignore_case: bool,
    unanchored_dfa: ?Dfa,
    word_dfa: ?WordDfa,

    pub const Options = struct {
        ascii_case_insensitive: bool = false,
        word_boundary: bool = false,
    };

    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) CompileError!Regex {
        return compileWithOptions(allocator, pattern, .{});
    }

    pub fn compileWithOptions(allocator: std.mem.Allocator, pattern: []const u8, options: Options) CompileError!Regex {
        var compiler = Compiler.init(allocator);
        errdefer {
            compiler.states.deinit(allocator);
            compiler.class_ranges.deinit(allocator);
        }

        var re = try compiler.compile(pattern);
        re.ignore_case = options.ascii_case_insensitive;
        re.empty_line_only = std.mem.eql(u8, pattern, "^$");
        re.any_run_info = parseAnyRun(pattern);
        errdefer {
            if (re.unanchored_dfa) |*dfa| dfa.deinit(allocator);
            if (re.word_dfa) |*dfa| dfa.deinit(allocator);
        }

        // Assertions depend on the byte before/after the current position, so
        // retain the assertion-aware NFA for those expressions.  DFA size is
        // deliberately bounded: large subset constructions simply use NFA.
        var has_assertions = false;
        var scalar_sensitive = false;
        for (re.states.items) |state| switch (state.transition) {
            .line_start, .line_end => has_assertions = true,
            .any, .char_class => scalar_sensitive = true,
            .char => |codepoint| if (codepoint >= 0x80) {
                scalar_sensitive = true;
            },
            else => {},
        };
        re.scalar_sensitive = scalar_sensitive;
        re.always_scalar = options.ascii_case_insensitive and containsNonAsciiBytes(pattern);
        re.has_assertions = has_assertions;
        if (re.states.items.len == 4 and pattern.len >= 4 and pattern[0] == '[' and
            pattern[pattern.len - 2] == ']' and pattern[pattern.len - 1] == '+')
        {
            const start_state = re.states.items[re.start];
            if (start_state.transition == .char_class) {
                const cc = start_state.transition.char_class;
                var matches_ascii = false;
                for (0..128) |byte| if (byte != '\n' and
                    cc.containsCodepoint(@intCast(byte), options.ascii_case_insensitive, re.class_ranges.items))
                {
                    matches_ascii = true;
                    break;
                };
                if (!matches_ascii) re.unicode_class_state = re.start;
            }
        }
        if (!has_assertions) {
            re.unanchored_dfa = re.buildDfa(true) catch |err| switch (err) {
                error.StateLimit => null,
                error.OutOfMemory => return error.OutOfMemory,
            };
        }

        // Detect if pattern starts with .* (greedy match-all)
        // This enables optimization in findWithSuffixFilter
        re.starts_with_dot_star = pattern.len >= 2 and pattern[0] == '.' and pattern[1] == '*';

        // Extract a required prefix, suffix or inner literal. Character classes
        // around it are safe. Assertion/escape expressions currently require
        // the assertion-aware NFA verifier, so do not route those through the
        // byte-exact candidate verifier.
        const prefilter_safe = std.mem.indexOfScalar(u8, pattern, '\\') == null;
        const extracted_info = if (options.ascii_case_insensitive or !prefilter_safe) null else literal.extractBestLiteral(pattern);

        // Store the pattern if we have a literal
        if (extracted_info) |info| {
            const counted = literal.extractCountedGroupLiteral(pattern);
            const repeated_len = if (counted) |group|
                std.math.mul(usize, group.literal.len, group.minimum) catch 0
            else
                0;
            const stored_repeated_len = if (repeated_len <= 4096) repeated_len else 0;
            re.pattern_storage = try allocator.alloc(u8, pattern.len + stored_repeated_len);
            @memcpy(re.pattern_storage.?[0..pattern.len], pattern);
            // Update literal to point to our owned copy
            const lit_start = @intFromPtr(info.literal.ptr) - @intFromPtr(pattern.ptr);
            re.literal_info = .{
                .literal = re.pattern_storage.?[lit_start..][0..info.literal.len],
                .position = info.position,
                .min_offset = info.min_offset,
            };
            if (counted) |group| {
                const counted_start = @intFromPtr(group.literal.ptr) - @intFromPtr(pattern.ptr);
                re.counted_literal_info = .{
                    .literal = re.pattern_storage.?[counted_start..][0..group.literal.len],
                    .minimum = group.minimum,
                    .maximum = group.maximum,
                };
                if (stored_repeated_len > 0) {
                    const repeated = re.pattern_storage.?[pattern.len..];
                    for (0..group.minimum) |repetition| {
                        @memcpy(repeated[repetition * group.literal.len ..][0..group.literal.len], group.literal);
                    }
                    re.literal_info.?.literal = repeated;
                }
            }
        }

        if (re.literal_info == null) {
            if (try literal.extractRepeatedAlternationLiterals(allocator, pattern)) |extracted| {
                var info = extracted;
                if (info.literals.len <= 8) {
                    // ASCII case folding has a SIMD candidate plan. Unicode
                    // alternatives use the codepoint-aware candidate path in
                    // findWithRequiredAlternation instead.
                    if (!options.ascii_case_insensitive or info.ascii_only) {
                        re.required_alternation_plan = simd.prepareSmallLiteralPlan(info.literals, options.ascii_case_insensitive);
                    }
                    re.required_alternation_info = info;
                } else {
                    info.deinit();
                }
            }
        }

        // Count mode only needs to know whether each line contains a valid
        // boundary-delimited match. Build a DFA whose transition can inject
        // the anchored start subset only at eligible codepoint boundaries.
        // Sparse expressions retain their cheaper literal candidate plans.
        if (options.word_boundary and !has_assertions and re.literal_info == null and
            re.required_alternation_info == null and !re.isSingleAny())
        {
            re.word_dfa = re.buildWordDfa() catch |err| switch (err) {
                error.StateLimit => null,
                error.OutOfMemory => return error.OutOfMemory,
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
        if (self.unanchored_dfa) |*dfa| dfa.deinit(self.allocator);
        if (self.word_dfa) |*dfa| dfa.deinit(self.allocator);
        self.states.deinit(self.allocator);
        self.class_ranges.deinit(self.allocator);
        if (self.required_alternation_info) |*info| info.deinit();
        if (self.pattern_storage) |ps| {
            self.allocator.free(ps);
        }
    }

    /// Find the first match in the input using position-aware literal filtering
    pub fn find(self: *const Regex, input: []const u8) ?matcher_mod.MatchResult {
        return self.findFrom(input, 0);
    }

    /// Find the first match whose complete span is surrounded by non-word
    /// codepoints (or input edges). Boundary checks participate in NFA span
    /// selection instead of rejecting one greedy span after the fact: a
    /// shorter or overlapping path at the same position may still be valid.
    pub fn findWordFrom(self: *const Regex, input: []const u8, start_offset: usize) ?matcher_mod.MatchResult {
        if (start_offset > input.len) return null;

        if (self.isSingleAny()) {
            var pos = start_offset;
            while (pos < input.len) {
                while (pos < input.len and (input[pos] & 0xc0) == 0x80) pos += 1;
                if (pos >= input.len) return null;
                const decoded = decodeScalar(input, pos);
                const end = pos + decoded.len;
                if (decoded.valid and input[pos] != '\n' and
                    matcher_mod.Matcher.isWordBoundaryStart(input, pos) and
                    matcher_mod.Matcher.isWordBoundaryEnd(input, end))
                {
                    return .{ .start = pos, .end = end };
                }
                pos = end;
            }
            return null;
        }

        if (self.required_alternation_info != null) {
            var search_pos = start_offset;
            while (self.findRequiredAlternationCandidate(input, search_pos)) |candidate| {
                const line_end = candidate + (simd.findNewline(input[candidate..]) orelse (input.len - candidate));
                if (self.findLinearImpl(input[0..line_end], candidate, true)) |match| {
                    if (match.start == candidate) return match;
                }
                search_pos = candidate + 1;
            }
            return null;
        }

        if (self.literal_info) |info| {
            var search_pos = start_offset;
            while (simd.findSubstringFrom(input, info.literal, search_pos)) |candidate| {
                const candidate_start = if (info.position == .prefix) candidate else blk: {
                    var line_start = candidate;
                    while (line_start > start_offset and input[line_start - 1] != '\n') line_start -= 1;
                    break :blk line_start;
                };
                const line_end = candidate + (simd.findNewline(input[candidate..]) orelse (input.len - candidate));
                if (self.findLinearImpl(input[0..line_end], candidate_start, true)) |match| {
                    if (info.position != .prefix or match.start == candidate) return match;
                }
                search_pos = candidate + 1;
            }
            return null;
        }

        return self.findLinearImpl(input, start_offset, true);
    }

    /// Return the end of any match without recovering its full span. Modes
    /// such as count, files-with-matches and uncolored output only need to know
    /// which line matched. The unanchored DFA can answer that in one pass and
    /// stop at its first accepting state.
    pub fn findEndFrom(self: *const Regex, input: []const u8, start_offset: usize) ?usize {
        if (start_offset >= input.len) return null;
        if (self.any_run_info) |info| return if (self.findAnyRunFrom(input, start_offset, info)) |match| match.end else null;
        if (self.isSingleAny()) return if (self.findSingleAnyFrom(input, start_offset)) |match| match.end else null;
        if (self.unicode_class_state != null) {
            return if (self.findUnicodeClassFrom(input, start_offset)) |match| match.end else null;
        }
        if (self.literal_info) |info| return self.findEndWithLiteral(input, info, start_offset);
        if (self.required_alternation_info != null) {
            return if (self.findWithRequiredAlternation(input, start_offset)) |match| match.end else null;
        }
        if (self.needsScalarNfa(input[start_offset..])) {
            return if (self.findLinearFrom(input, start_offset)) |match| match.end else null;
        }
        if (self.unanchored_dfa != null) return self.unanchoredDfaHit(input, start_offset);
        return if (self.findFrom(input, start_offset)) |match| match.end else null;
    }

    fn findEndWithLiteral(self: *const Regex, input: []const u8, info: literal.LiteralInfo, start_offset: usize) ?usize {
        const required = info.literal;
        var search_pos = start_offset;
        while (simd.findSubstringFrom(input, required, search_pos)) |lit_pos| {
            if (info.position == .prefix) {
                if (self.counted_literal_info) |counted| {
                    if (self.countedLiteralEnd(input, lit_pos, counted, false)) |end| return end;
                    search_pos = lit_pos + 1;
                    continue;
                }
                const line_end = lit_pos + (simd.findNewline(input[lit_pos..]) orelse (input.len - lit_pos));
                if (self.matchEndAt(input[0..line_end], lit_pos)) |end| return end;
                search_pos = lit_pos + 1;
                continue;
            }

            var line_start = lit_pos;
            while (line_start > start_offset and input[line_start - 1] != '\n') line_start -= 1;
            const line_end = lit_pos + (simd.findNewline(input[lit_pos..]) orelse (input.len - lit_pos));

            if (self.needsScalarNfa(input[line_start..line_end])) {
                if (self.findLinearFrom(input[0..line_end], line_start)) |match| return match.end;
            } else {
                if (self.unanchoredDfaHit(input[0..line_end], line_start)) |end| return end;
                if (self.unanchored_dfa == null) {
                    if (self.findLinearFrom(input[0..line_end], line_start)) |match| return match.end;
                }
            }
            search_pos = lit_pos + 1;
        }
        return null;
    }

    pub fn supportsFastLineCount(self: *const Regex) bool {
        if (self.empty_line_only or self.any_run_info != null or self.unicode_class_state != null) return true;
        if (self.unanchored_dfa == null) return false;
        if (self.literal_info != null or self.required_alternation_info != null) return false;
        for (self.states.items) |state| switch (state.transition) {
            .char => |byte| if (byte == '\n') return false,
            .line_start, .line_end => return false,
            else => {},
        };
        return true;
    }

    pub fn supportsFastWordLineCount(self: *const Regex) bool {
        return self.isSingleAny() or self.word_dfa != null;
    }

    pub fn countWordMatchingLines(self: *const Regex, input: []const u8, check_nul: bool) ?matcher_mod.LineCount {
        if (!self.supportsFastWordLineCount()) return null;
        if (self.always_scalar) return self.countScalarLines(input, check_nul, true);
        if (self.isSingleAny()) return self.countSingleAnyWordLines(input, check_nul);

        const dfa = &self.word_dfa.?;
        var count: usize = 0;
        var state: u16 = 0;
        var line_start: usize = 0;
        var pos: usize = 0;
        var previous_word = false;
        var current_word = false;
        var scalar_end: usize = 0;
        var binary_offset: ?usize = null;

        while (pos < input.len) {
            if (input[pos] == '\n') {
                pos += 1;
                line_start = pos;
                state = 0;
                previous_word = false;
                scalar_end = pos;
                continue;
            }

            // Byte DFAs retain their hot ASCII transition tables. A line
            // containing UTF-8 needs the scalar NFA because classes and dot
            // consume one codepoint rather than one byte. Re-evaluate just
            // that uncommon line and resume the DFA at the next line.
            if (self.scalar_sensitive and input[pos] >= 0x80) {
                const line_end = pos + (simd.findNewline(input[pos..]) orelse (input.len - pos));
                if (check_nul) {
                    if (simd.findByteValue(input[line_start..line_end], 0)) |nul| {
                        if (binary_offset == null) binary_offset = line_start + nul;
                    }
                }
                if (self.findWordFrom(input[line_start..line_end], 0) != null) count += 1;
                if (line_end == input.len) break;
                pos = line_end + 1;
                line_start = pos;
                state = 0;
                previous_word = false;
                scalar_end = pos;
                continue;
            }

            const scalar_start = pos >= scalar_end;
            if (scalar_start) {
                if (input[pos] < 0x80) {
                    scalar_end = pos + 1;
                    current_word = isAsciiWord(input[pos]);
                } else {
                    const decoded = decodeScalar(input, pos);
                    scalar_end = pos + decoded.len;
                    // Malformed UTF-8 cannot form a Unicode word boundary.
                    // Treat it as blocking both a preceding end assertion and
                    // a following start assertion, matching findWordFrom.
                    current_word = !decoded.valid or matcher_mod.Matcher.isWordCodepoint(decoded.codepoint);
                }
            }
            const inject_start = scalar_start and (pos == line_start or !previous_word);
            const transition = dfa.transition(state, input[pos], inject_start);
            state = transition & DFA_STATE_MASK;
            pos += 1;

            const at_scalar_end = pos >= scalar_end;
            if (at_scalar_end) previous_word = current_word;
            if (transition & DFA_ACCEPTING == 0 or !at_scalar_end) continue;

            const valid_end = pos >= input.len or input[pos] == '\n' or if (input[pos] < 0x80)
                !isAsciiWord(input[pos])
            else blk: {
                const next = decodeScalar(input, pos);
                break :blk next.valid and !matcher_mod.Matcher.isWordCodepoint(next.codepoint);
            };
            if (!valid_end) continue;

            const line_end = pos + (simd.findNewline(input[pos..]) orelse (input.len - pos));
            if (check_nul) {
                if (simd.findByteValue(input[line_start..line_end], 0)) |nul| {
                    if (binary_offset == null) binary_offset = line_start + nul;
                }
            }
            count += 1;
            if (line_end == input.len) break;
            pos = line_end + 1;
            line_start = pos;
            state = 0;
            previous_word = false;
            scalar_end = pos;
        }
        return .{ .count = count, .binary_offset = binary_offset };
    }

    fn countSingleAnyWordLines(self: *const Regex, input: []const u8, check_nul: bool) matcher_mod.LineCount {
        _ = self;
        var count: usize = 0;
        var line_start: usize = 0;
        var pos: usize = 0;
        var previous_word = false;
        var binary_offset: ?usize = null;

        while (pos < input.len) {
            if (pos > 0 and pos + simd.VECTOR_WIDTH + 1 <= input.len) {
                const scan = simd.scanAsciiWordDotCandidate(input, pos);
                if (scan.candidate) |candidate| {
                    if (std.mem.lastIndexOfScalar(u8, input[line_start..candidate], '\n')) |newline| {
                        line_start += newline + 1;
                    }
                    const end = candidate + 1;
                    const line_end = end + (simd.findNewline(input[end..]) orelse (input.len - end));
                    if (check_nul) {
                        if (simd.findByteValue(input[line_start..line_end], 0)) |nul| {
                            if (binary_offset == null) binary_offset = line_start + nul;
                        }
                    }
                    count += 1;
                    if (line_end == input.len) break;
                    pos = line_end + 1;
                    line_start = pos;
                    previous_word = false;
                    continue;
                }
                if (scan.scanned > 0) {
                    const scanned_end = pos + scan.scanned;
                    if (std.mem.lastIndexOfScalar(u8, input[line_start..scanned_end], '\n')) |newline| {
                        line_start += newline + 1;
                    }
                    previous_word = isAsciiWord(input[scanned_end - 1]);
                    pos = scanned_end;
                    continue;
                }
            }

            if (input[pos] == '\n') {
                pos += 1;
                line_start = pos;
                previous_word = false;
                continue;
            }
            const decoded = if (input[pos] < 0x80)
                DecodedScalar{ .codepoint = input[pos], .len = 1, .valid = true }
            else
                decodeScalar(input, pos);
            if (!decoded.valid) {
                // An invalid scalar blocks a boundary on either side.
                previous_word = true;
                pos += decoded.len;
                continue;
            }
            const end = pos + decoded.len;
            const next_is_word = if (end >= input.len or input[end] == '\n')
                false
            else if (input[end] < 0x80)
                isAsciiWord(input[end])
            else blk: {
                const next = decodeScalar(input, end);
                break :blk !next.valid or matcher_mod.Matcher.isWordCodepoint(next.codepoint);
            };
            if ((pos == line_start or !previous_word) and !next_is_word) {
                const line_end = end + (simd.findNewline(input[end..]) orelse (input.len - end));
                if (check_nul) {
                    if (simd.findByteValue(input[line_start..line_end], 0)) |nul| {
                        if (binary_offset == null) binary_offset = line_start + nul;
                    }
                }
                count += 1;
                if (line_end == input.len) break;
                pos = line_end + 1;
                line_start = pos;
                previous_word = false;
                continue;
            }
            previous_word = if (decoded.codepoint < 0x80)
                isAsciiWord(@intCast(decoded.codepoint))
            else
                matcher_mod.Matcher.isWordCodepoint(decoded.codepoint);
            pos = end;
        }
        return .{ .count = count, .binary_offset = binary_offset };
    }

    /// Count accepted lines directly in the unanchored DFA. This retains the
    /// DFA row and current line start locally and jumps to the next newline
    /// after acceptance, avoiding one generic matcher/callback round trip and
    /// a reverse line-boundary scan for every dense match.
    pub fn countMatchingLines(self: *const Regex, input: []const u8, check_nul: bool) ?matcher_mod.LineCount {
        if (!self.supportsFastLineCount()) return null;
        if (self.always_scalar) return self.countScalarLines(input, check_nul, false);
        if (self.empty_line_only) return .{ .count = simd.countEmptyLines(input), .binary_offset = null };
        if (self.any_run_info) |info| return self.countAnyRunLines(input, info.minimum, check_nul);
        if (self.unicode_class_state != null) return self.countUnicodeClassLines(input, check_nul);
        const dfa = &self.unanchored_dfa.?;
        if (dfa.accepting[0]) {
            const count = simd.countNewlines(input) + @intFromBool(input.len > 0 and input[input.len - 1] != '\n');
            const binary_offset = if (check_nul) simd.findByteValue(input, 0) else null;
            return .{ .count = count, .binary_offset = binary_offset };
        }
        return if (dfa.premultiplied)
            self.countMatchingLinesDfa(input, check_nul, true)
        else
            self.countMatchingLinesDfa(input, check_nul, false);
    }

    fn countMatchingLinesDfa(
        self: *const Regex,
        input: []const u8,
        check_nul: bool,
        comptime premultiplied: bool,
    ) matcher_mod.LineCount {
        const dfa = &self.unanchored_dfa.?;
        var count: usize = 0;
        var state: u16 = 0;
        var line_start: usize = 0;
        var pos: usize = 0;
        var binary_offset: ?usize = null;

        while (pos < input.len) {
            const byte = input[pos];
            if (byte == '\n') {
                pos += 1;
                line_start = pos;
                state = 0;
                continue;
            }

            if (self.scalar_sensitive and byte >= 0x80) {
                const line_end = pos + (simd.findNewline(input[pos..]) orelse (input.len - pos));
                if (check_nul) {
                    if (simd.findByteValue(input[line_start..line_end], 0)) |nul| {
                        if (binary_offset == null) binary_offset = line_start + nul;
                    }
                }
                if (self.findEndFrom(input[line_start..line_end], 0) != null) count += 1;
                if (line_end == input.len) break;
                pos = line_end + 1;
                line_start = pos;
                state = 0;
                continue;
            }

            const transition = dfa.transition(state, byte, premultiplied);
            if (transition == DFA_DEAD) return .{ .count = count, .binary_offset = binary_offset };
            state = Dfa.nextState(transition, premultiplied);
            pos += 1;
            if (transition & DFA_ACCEPTING == 0) continue;

            const line_end = pos + (simd.findNewline(input[pos..]) orelse (input.len - pos));
            if (check_nul) {
                if (simd.findByteValue(input[line_start..line_end], 0)) |nul| {
                    if (binary_offset == null) binary_offset = line_start + nul;
                }
            }
            count += 1;
            if (line_end == input.len) break;
            pos = line_end + 1;
            line_start = pos;
            state = 0;
        }
        return .{ .count = count, .binary_offset = binary_offset };
    }

    /// Find the first match starting from a given offset
    /// This allows efficient resume of search after word boundary check fails
    pub fn findFrom(self: *const Regex, input: []const u8, start_offset: usize) ?matcher_mod.MatchResult {
        if (start_offset >= input.len) return null;

        if (self.any_run_info) |info| return self.findAnyRunFrom(input, start_offset, info);
        if (self.isSingleAny()) return self.findSingleAnyFrom(input, start_offset);
        if (self.unicode_class_state != null) return self.findUnicodeClassFrom(input, start_offset);

        if (self.literal_info) |info| {
            return switch (info.position) {
                .prefix => self.findWithPrefixFilterFrom(input, info.literal, start_offset),
                .suffix => self.findWithSuffixFilterFrom(input, info.literal, start_offset),
                .inner => self.findWithInnerFilterFrom(input, info, start_offset),
            };
        }
        if (self.required_alternation_info != null) return self.findWithRequiredAlternation(input, start_offset);
        if (self.needsScalarNfa(input[start_offset..])) return self.findLinearFrom(input, start_offset);
        if (self.unanchoredDfaHit(input, start_offset)) |hit_end| {
            var start = start_offset;
            while (start <= hit_end) : (start += 1) {
                if (self.matchAt(input, start)) |end|
                    return .{ .start = start, .end = end };
            }
            unreachable;
        }
        if (self.unanchored_dfa != null) return null;
        return self.findLinearFrom(input, start_offset);
    }

    fn isSingleAny(self: *const Regex) bool {
        if (self.states.items.len != 2) return false;
        const start_state = self.states.items[self.start];
        return start_state.transition == .any and start_state.out1 == self.match_state;
    }

    fn findSingleAnyFrom(self: *const Regex, input: []const u8, start_offset: usize) ?matcher_mod.MatchResult {
        _ = self;
        var pos = start_offset;
        while (pos < input.len and (input[pos] & 0xc0) == 0x80) pos += 1;
        while (pos < input.len) {
            const decoded = decodeScalar(input, pos);
            const end = pos + decoded.len;
            if (decoded.valid and input[pos] != '\n') return .{ .start = pos, .end = end };
            pos = end;
        }
        return null;
    }

    fn findAnyRunFrom(self: *const Regex, input: []const u8, start_offset: usize, info: AnyRunInfo) ?matcher_mod.MatchResult {
        _ = self;
        var pos = start_offset;
        var run_start = pos;
        var scalar_count: usize = 0;
        while (pos <= input.len) {
            if (pos == input.len or input[pos] == '\n') {
                if (scalar_count >= info.minimum) return .{ .start = run_start, .end = pos };
                if (pos == input.len) break;
                pos += 1;
                run_start = pos;
                scalar_count = 0;
                continue;
            }
            const decoded = decodeScalar(input, pos);
            if (!decoded.valid) {
                if (scalar_count >= info.minimum) return .{ .start = run_start, .end = pos };
                pos += decoded.len;
                run_start = pos;
                scalar_count = 0;
                continue;
            }
            pos += decoded.len;
            scalar_count += 1;
            if (info.maximum) |maximum| {
                if (scalar_count == maximum) return .{ .start = run_start, .end = pos };
            }
        }
        return null;
    }

    fn countAnyRunLines(self: *const Regex, input: []const u8, minimum: usize, check_nul: bool) matcher_mod.LineCount {
        _ = self;
        var count: usize = 0;
        var pos: usize = 0;
        var line_start: usize = 0;
        var scalar_count: usize = 0;
        var binary_offset: ?usize = null;
        while (pos < input.len) {
            if (input[pos] == '\n') {
                pos += 1;
                line_start = pos;
                scalar_count = 0;
                continue;
            }
            const decoded = decodeScalar(input, pos);
            pos += decoded.len;
            if (!decoded.valid) {
                scalar_count = 0;
                continue;
            }
            scalar_count += 1;
            if (scalar_count < minimum) continue;

            const line_end = pos + (simd.findNewline(input[pos..]) orelse (input.len - pos));
            if (check_nul) {
                if (simd.findByteValue(input[line_start..line_end], 0)) |nul| {
                    if (binary_offset == null) binary_offset = line_start + nul;
                }
            }
            count += 1;
            if (line_end == input.len) break;
            pos = line_end + 1;
            line_start = pos;
            scalar_count = 0;
        }
        return .{ .count = count, .binary_offset = binary_offset };
    }

    fn findUnicodeClassFrom(self: *const Regex, input: []const u8, start_offset: usize) ?matcher_mod.MatchResult {
        const state_index = self.unicode_class_state orelse return null;
        const cc = &self.states.items[state_index].transition.char_class;
        var pos = start_offset;
        while (simd.findNonAscii(input[pos..])) |relative| {
            const start = pos + relative;
            const decoded = decodeScalar(input, start);
            if (!decoded.valid or !cc.containsCodepoint(decoded.codepoint, self.ignore_case, self.class_ranges.items)) {
                pos = start + decoded.len;
                continue;
            }

            var end = start + decoded.len;
            while (end < input.len) {
                const next = decodeScalar(input, end);
                if (!next.valid or !cc.containsCodepoint(next.codepoint, self.ignore_case, self.class_ranges.items)) break;
                end += next.len;
            }
            return .{ .start = start, .end = end };
        }
        return null;
    }

    fn countUnicodeClassLines(self: *const Regex, input: []const u8, check_nul: bool) matcher_mod.LineCount {
        var count: usize = 0;
        var line_start: usize = 0;
        var pos: usize = 0;
        var binary_offset: ?usize = null;
        while (self.findUnicodeClassFrom(input, pos)) |match| {
            if (std.mem.lastIndexOfScalar(u8, input[line_start..match.start], '\n')) |newline| {
                line_start += newline + 1;
            }
            const line_end = match.end + (simd.findNewline(input[match.end..]) orelse (input.len - match.end));
            if (check_nul and binary_offset == null) {
                if (simd.findByteValue(input[line_start..line_end], 0)) |nul| binary_offset = line_start + nul;
            }
            count += 1;
            if (line_end == input.len) break;
            pos = line_end + 1;
            line_start = pos;
        }
        return .{ .count = count, .binary_offset = binary_offset };
    }

    fn countScalarLines(
        self: *const Regex,
        input: []const u8,
        check_nul: bool,
        comptime word_boundary: bool,
    ) matcher_mod.LineCount {
        var count: usize = 0;
        var line_start: usize = 0;
        var binary_offset: ?usize = null;
        while (line_start < input.len) {
            const line_end = line_start + (simd.findNewline(input[line_start..]) orelse (input.len - line_start));
            const line = input[line_start..line_end];
            const matches = if (word_boundary)
                self.findWordFrom(line, 0) != null
            else
                self.findEndFrom(line, 0) != null;
            if (matches) {
                count += 1;
                if (check_nul and binary_offset == null) {
                    if (simd.findByteValue(line, 0)) |nul| binary_offset = line_start + nul;
                }
            }
            if (line_end == input.len) break;
            line_start = line_end + 1;
        }
        return .{ .count = count, .binary_offset = binary_offset };
    }

    const DecodedScalar = struct { codepoint: u21, len: usize, valid: bool };

    fn decodeScalar(input: []const u8, start: usize) DecodedScalar {
        const len = std.unicode.utf8ByteSequenceLength(input[start]) catch
            return .{ .codepoint = input[start], .len = 1, .valid = false };
        if (start + len > input.len) return .{ .codepoint = input[start], .len = 1, .valid = false };
        const codepoint = std.unicode.utf8Decode(input[start..][0..len]) catch
            return .{ .codepoint = input[start], .len = 1, .valid = false };
        return .{ .codepoint = codepoint, .len = len, .valid = true };
    }

    fn needsScalarNfa(self: *const Regex, input: []const u8) bool {
        if (self.always_scalar) return true;
        if (!self.scalar_sensitive) return false;
        for (input) |byte| if (byte >= 0x80) return true;
        return false;
    }

    inline fn isAsciiWord(byte: u8) bool {
        return std.ascii.isAlphanumeric(byte) or byte == '_';
    }

    fn parseAnyRun(pattern: []const u8) ?AnyRunInfo {
        if (pattern.len < 4 or pattern[0] != '.' or pattern[1] != '{' or pattern[pattern.len - 1] != '}') return null;
        var pos: usize = 2;
        if (!std.ascii.isDigit(pattern[pos])) return null;
        var minimum: usize = 0;
        while (pos < pattern.len - 1 and std.ascii.isDigit(pattern[pos])) : (pos += 1) {
            minimum = std.math.mul(usize, minimum, 10) catch return null;
            minimum = std.math.add(usize, minimum, pattern[pos] - '0') catch return null;
        }
        if (minimum == 0) return null;
        if (pos == pattern.len - 1) return .{ .minimum = minimum, .maximum = minimum };
        if (pattern[pos] != ',') return null;
        pos += 1;
        if (pos == pattern.len - 1) return .{ .minimum = minimum, .maximum = null };
        var maximum: usize = 0;
        while (pos < pattern.len - 1 and std.ascii.isDigit(pattern[pos])) : (pos += 1) {
            maximum = std.math.mul(usize, maximum, 10) catch return null;
            maximum = std.math.add(usize, maximum, pattern[pos] - '0') catch return null;
        }
        return if (pos == pattern.len - 1 and maximum >= minimum)
            .{ .minimum = minimum, .maximum = maximum }
        else
            null;
    }

    fn unanchoredDfaHit(self: *const Regex, input: []const u8, start: usize) ?usize {
        const dfa = &(self.unanchored_dfa orelse return null);
        return if (dfa.premultiplied)
            unanchoredDfaHitImpl(dfa, input, start, true)
        else
            unanchoredDfaHitImpl(dfa, input, start, false);
    }

    fn unanchoredDfaHitImpl(dfa: *const Dfa, input: []const u8, start: usize, comptime premultiplied: bool) ?usize {
        if (dfa.accepting[0]) return start;
        var state: u16 = 0;
        for (input[start..], start..) |c, pos| {
            const transition = dfa.transition(state, c, premultiplied);
            if (transition == DFA_DEAD) return null;
            if (transition & DFA_ACCEPTING != 0) return pos + 1;
            state = Dfa.nextState(transition, premultiplied);
        }
        return null;
    }

    fn findWithRequiredAlternation(self: *const Regex, input: []const u8, start_offset: usize) ?matcher_mod.MatchResult {
        const info = self.required_alternation_info orelse return null;
        var search_pos = start_offset;
        while (search_pos < input.len) {
            const match_start = self.findRequiredAlternationCandidate(input, search_pos) orelse return null;

            // The extracted shape is exactly `(literal|literal|...)+`, so
            // direct verification is both cheaper and more faithful than the
            // generic longest-match NFA. Try branches in source order at each
            // repetition, matching ripgrep's leftmost-first alternation.
            var end = match_start;
            while (self.repeatedAlternativeEnd(input, info, end)) |next_end| {
                end = next_end;
            }
            if (end > match_start) return .{ .start = match_start, .end = end };
            search_pos = match_start + 1;
        }
        return null;
    }

    fn findRequiredAlternationCandidate(self: *const Regex, input: []const u8, start: usize) ?usize {
        const info = self.required_alternation_info orelse return null;
        if (self.ignore_case and (!info.ascii_only or
            (self.alternativesNeedNonAsciiFold(info.literals) and self.containsNonAscii(input[start..]))))
        {
            return self.findUnicodeAlternationCandidate(input, info.literals, start);
        }
        const plan = if (self.required_alternation_plan) |*prepared| prepared else return null;
        const candidate = if (self.ignore_case)
            simd.findAnySubstringFromIgnoreCasePrepared(input, info.literals, start, plan)
        else
            simd.findAnySubstringFromPrepared(input, info.literals, start, plan);
        return if (candidate) |hit| hit.start else null;
    }

    fn findUnicodeAlternationCandidate(self: *const Regex, input: []const u8, alternatives: []const []const u8, start: usize) ?usize {
        _ = self;
        var earliest: ?usize = null;
        for (alternatives) |alternative| {
            const match = matcher_mod.Matcher.findUnicodeIgnoreCase(input, alternative, start) orelse continue;
            if (earliest == null or match.start < earliest.?) earliest = match.start;
        }
        return earliest;
    }

    fn repeatedAlternativeEnd(self: *const Regex, input: []const u8, info: literal.AlternationInfo, start: usize) ?usize {
        for (info.literals) |alternative| {
            if (self.ignore_case and (!info.ascii_only or
                (start < input.len and input[start] >= 0x80 and self.patternNeedsNonAsciiFold(alternative))))
            {
                const len = matcher_mod.Matcher.foldedPrefixLen(input[start..], alternative) orelse continue;
                return start + len;
            }
            if (start + alternative.len > input.len) continue;
            const candidate = input[start..][0..alternative.len];
            if (self.ignore_case) {
                var equal = true;
                for (candidate, alternative) |actual, expected| {
                    if (std.ascii.toLower(actual) != std.ascii.toLower(expected)) {
                        equal = false;
                        break;
                    }
                }
                if (!equal) continue;
            } else if (!std.mem.eql(u8, candidate, alternative)) {
                continue;
            }
            return start + alternative.len;
        }
        return null;
    }

    fn patternNeedsNonAsciiFold(self: *const Regex, pattern: []const u8) bool {
        _ = self;
        for (pattern) |byte| switch (std.ascii.toLower(byte)) {
            'k', 's' => return true,
            else => {},
        };
        return false;
    }

    fn alternativesNeedNonAsciiFold(self: *const Regex, alternatives: []const []const u8) bool {
        for (alternatives) |alternative| if (self.patternNeedsNonAsciiFold(alternative)) return true;
        return false;
    }

    fn containsNonAscii(self: *const Regex, input: []const u8) bool {
        _ = self;
        for (input) |byte| if (byte >= 0x80) return true;
        return false;
    }

    /// One unanchored ordered-Pike pass. Thread order preserves source branch
    /// priority and greedy quantifiers without retrying every input position.
    fn findLinearFrom(self: *const Regex, input: []const u8, start_offset: usize) ?matcher_mod.MatchResult {
        return self.findLinearImpl(input, start_offset, false);
    }

    fn findLinearImpl(self: *const Regex, input: []const u8, start_offset: usize, comptime word_boundary: bool) ?matcher_mod.MatchResult {
        return self.findPikeImpl(input, start_offset, true, word_boundary);
    }

    fn findPikeImpl(
        self: *const Regex,
        input: []const u8,
        start_offset: usize,
        comptime unanchored: bool,
        comptime word_boundary: bool,
    ) ?matcher_mod.MatchResult {
        var list_a = PikeThreadList{};
        var list_b = PikeThreadList{};
        var current = &list_a;
        var next = &list_b;
        var candidate: ?matcher_mod.MatchResult = null;
        var pos = start_offset;
        while (pos <= input.len) {
            const scalar_start = pos == input.len or (input[pos] & 0xc0) != 0x80;
            const inject_start = scalar_start and candidate == null and
                (unanchored or pos == start_offset) and
                (!word_boundary or matcher_mod.Matcher.isWordBoundaryStart(input, pos));
            if (inject_start) {
                self.addPikeThread(current, self.start, pos, input, pos);
            }

            var process_len = current.len;
            for (current.threads[0..current.len], 0..) |thread, i| {
                if (thread.state != self.match_state or
                    (word_boundary and !matcher_mod.Matcher.isWordBoundaryEnd(input, pos))) continue;
                candidate = .{ .start = thread.start, .end = pos };
                process_len = i;
                break;
            }

            if (pos == input.len) return candidate;
            const decoded = decodeScalar(input, pos);
            const next_pos = pos + decoded.len;
            next.clear();
            for (current.threads[0..process_len]) |thread| {
                const state = self.states.items[thread.state];
                if (!self.matchScalarTransition(state.transition, decoded)) continue;
                if (state.out1) |out| {
                    self.addPikeThread(next, out, thread.start, input, next_pos);
                }
            }

            if (next.len == 0) {
                if (candidate != null or !unanchored) return candidate;
                current.clear();
            } else {
                std.mem.swap(*PikeThreadList, &current, &next);
            }
            pos = next_pos;
        }
        return candidate;
    }

    fn addPikeThread(
        self: *const Regex,
        list: *PikeThreadList,
        idx: usize,
        start: usize,
        input: []const u8,
        pos: usize,
    ) void {
        if (list.seen.isSet(idx)) return;
        list.seen.set(idx);
        const state = self.states.items[idx];
        const follows = switch (state.transition) {
            .epsilon => true,
            .line_start => pos == 0 or input[pos - 1] == '\n',
            .line_end => pos == input.len or input[pos] == '\n',
            else => false,
        };
        if (follows) {
            if (state.out1) |out| self.addPikeThread(list, out, start, input, pos);
            if (state.out2) |out| self.addPikeThread(list, out, start, input, pos);
            return;
        }
        if (state.transition == .line_start or state.transition == .line_end) return;
        list.threads[list.len] = .{ .state = @intCast(idx), .start = start };
        list.len += 1;
    }

    /// Find using prefix literal as filter, starting from a given offset
    fn findWithPrefixFilterFrom(self: *const Regex, input: []const u8, prefix: []const u8, start_offset: usize) ?matcher_mod.MatchResult {
        var search_pos: usize = start_offset;
        while (simd.findSubstringFrom(input, prefix, search_pos)) |lit_pos| {
            // Found prefix at lit_pos, try matching from there
            if (self.matchCandidateAt(input, lit_pos)) |match| return match;
            search_pos = lit_pos + 1;
        }
        return null;
    }

    fn matchCandidateAt(self: *const Regex, input: []const u8, start: usize) ?matcher_mod.MatchResult {
        if (self.counted_literal_info) |counted| {
            const end = self.countedLiteralEnd(input, start, counted, true) orelse return null;
            return .{ .start = start, .end = end };
        }
        // Recover source-order and greedy span semantics with the ordered NFA.
        // Bound recovery to this candidate's line so a rejected anchor never
        // rescans the remainder of a multi-megabyte mmap window.
        const line_end = start + (simd.findNewline(input[start..]) orelse (input.len - start));
        return self.findPikeImpl(input[0..line_end], start, false, false);
    }

    fn countedLiteralEnd(
        self: *const Regex,
        input: []const u8,
        start: usize,
        info: literal.CountedGroupLiteral,
        greedy: bool,
    ) ?usize {
        _ = self;
        var end = start;
        var repetitions: usize = 0;
        while (repetitions < info.minimum) : (repetitions += 1) {
            if (info.literal.len > input.len - end or
                !std.mem.eql(u8, input[end..][0..info.literal.len], info.literal)) return null;
            end += info.literal.len;
        }
        if (!greedy) return end;
        while (info.maximum == null or repetitions < info.maximum.?) : (repetitions += 1) {
            if (info.literal.len > input.len - end or
                !std.mem.eql(u8, input[end..][0..info.literal.len], info.literal)) break;
            end += info.literal.len;
        }
        return end;
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
                var line_start = lit_pos;
                while (line_start > 0 and input[line_start - 1] != '\n') line_start -= 1;
                if (self.matchCandidateAt(input, line_start)) |match| {
                    // Match must extend to cover this specific suffix occurrence
                    if (match.end >= lit_pos + suffix.len) {
                        // IMPORTANT: For word boundary checks to work correctly, we return
                        // a match ending at THIS specific suffix occurrence, not the greedy
                        // longest match. This allows the word boundary check to validate
                        // the boundary at this suffix, and if it fails, we can try the next
                        // suffix occurrence.
                        return matcher_mod.MatchResult{
                            .start = match.start,
                            .end = lit_pos + suffix.len,
                        };
                    }
                }
                // If matchAt(0) doesn't reach this suffix, no point trying - .* is greedy
                // and will always match the same way from position 0. Move to next suffix.
            } else {
                // For other patterns, try all positions from 0 to lit_pos
                // (or from start_offset if resuming)
                var start: usize = start_offset;
                while (start <= lit_pos) : (start += 1) {
                    if (self.matchCandidateAt(input, start)) |match| {
                        if (match.end >= lit_pos + suffix.len) {
                            return matcher_mod.MatchResult{
                                .start = match.start,
                                .end = match.end,
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
            // A minimum offset is not an upper bound: variable-width tokens
            // before the literal can place the match start anywhere earlier
            // on this line. One tagged-NFA pass recovers the leftmost span
            // without retrying every possible start (which would be O(n²)).
            var line_start = lit_pos;
            while (line_start > start_offset and input[line_start - 1] != '\n') line_start -= 1;
            const line_end = lit_pos + (simd.findNewline(input[lit_pos..]) orelse (input.len - lit_pos));
            if (self.findLinearFrom(input[0..line_end], line_start)) |match| return match;
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
        const match = self.findPikeImpl(input, start, false, false) orelse return null;
        return match.end;
    }

    /// Return the first accepting end for an anchored candidate. End-only
    /// callers do not need source-priority span recovery, so ASCII candidates
    /// can use compact Thompson bitsets instead of the ordered Pike VM.
    fn matchEndAt(self: *const Regex, input: []const u8, start: usize) ?usize {
        if (self.has_assertions or self.needsScalarNfa(input[start..])) return self.matchAt(input, start);

        var current = StateBitset.init();
        var next = StateBitset.init();
        self.addStateWithEpsilon(&current, self.start);
        if (current.isSet(self.match_state)) return start;

        for (input[start..], start..) |byte, pos| {
            var states = current.iterator();
            while (states.next()) |state_idx| {
                const state = self.states.items[state_idx];
                if (self.matchTransition(state.transition, byte)) {
                    if (state.out1) |out| self.addStateWithEpsilon(&next, out);
                }
            }
            current = next;
            next.clear();
            if (current.isSet(self.match_state)) return pos + 1;
            if (current.isEmpty()) return null;
        }
        return null;
    }

    fn matchTransition(self: *const Regex, transition: Transition, c: u8) bool {
        return switch (transition) {
            .any => c != '\n', // . doesn't match newline
            .char => |ch| if (ch > std.math.maxInt(u8))
                false
            else if (self.ignore_case)
                std.ascii.toLower(@intCast(ch)) == std.ascii.toLower(c)
            else
                @as(u8, @intCast(ch)) == c,
            .char_class => |*cc| c != '\n' and cc.contains(c, self.ignore_case),
            .epsilon, .line_start, .line_end, .match => false,
        };
    }

    fn matchScalarTransition(self: *const Regex, transition: Transition, decoded: DecodedScalar) bool {
        if (!decoded.valid) return false;
        return switch (transition) {
            .any => decoded.codepoint != '\n',
            .char => |ch| if (self.ignore_case)
                matcher_mod.Matcher.simpleFoldCodepoint(ch) == matcher_mod.Matcher.simpleFoldCodepoint(decoded.codepoint)
            else
                ch == decoded.codepoint,
            .char_class => |*cc| decoded.codepoint != '\n' and
                cc.containsCodepoint(decoded.codepoint, self.ignore_case, self.class_ranges.items),
            .epsilon, .line_start, .line_end, .match => false,
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

    fn buildDfa(self: *const Regex, unanchored: bool) error{ OutOfMemory, StateLimit }!Dfa {
        const allocator = self.allocator;
        var subsets = std.ArrayListUnmanaged(StateBitset){};
        defer subsets.deinit(allocator);
        var transitions = std.ArrayListUnmanaged(u16){};
        errdefer transitions.deinit(allocator);
        var accepting = std.ArrayListUnmanaged(bool){};
        errdefer accepting.deinit(allocator);

        var initial = StateBitset.init();
        self.addStateWithEpsilon(&initial, self.start);
        try subsets.append(allocator, initial);
        try accepting.append(allocator, initial.isSet(self.match_state));
        var index: usize = 0;
        while (index < subsets.items.len) : (index += 1) {
            const subset = subsets.items[index];
            for (0..256) |byte| {
                var next = StateBitset.init();
                var iter = subset.iterator();
                while (iter.next()) |state_idx| {
                    const state = self.states.items[state_idx];
                    if (self.matchTransition(state.transition, @intCast(byte)))
                        if (state.out1) |out| self.addStateWithEpsilon(&next, out);
                }
                if (unanchored) {
                    for (initial.bits, 0..) |word, w| next.bits[w] |= word;
                }
                var found: ?usize = null;
                for (subsets.items, 0..) |known, known_idx| {
                    if (std.mem.eql(u64, &known.bits, &next.bits)) {
                        found = known_idx;
                        break;
                    }
                }
                if (found == null and !next.isEmpty()) {
                    if (subsets.items.len >= MAX_DFA_STATES) return error.StateLimit;
                    found = subsets.items.len;
                    try subsets.append(allocator, next);
                    try accepting.append(allocator, next.isSet(self.match_state));
                }
                try transitions.append(allocator, if (found) |f|
                    @as(u16, @intCast(f)) | (if (accepting.items[f]) DFA_ACCEPTING else 0)
                else
                    DFA_DEAD);
            }
        }
        const premultiplied = accepting.items.len <= 128;
        if (premultiplied) {
            for (transitions.items) |*transition| {
                if (transition.* == DFA_DEAD) continue;
                const accepting_bit = transition.* & DFA_ACCEPTING;
                const state = transition.* & DFA_STATE_MASK;
                transition.* = (state << 8) | accepting_bit;
            }
        }
        const transition_slice = try transitions.toOwnedSlice(allocator);
        errdefer allocator.free(transition_slice);
        const accepting_slice = try accepting.toOwnedSlice(allocator);
        return .{
            .transitions = transition_slice,
            .accepting = accepting_slice,
            .premultiplied = premultiplied,
        };
    }

    fn buildWordDfa(self: *const Regex) error{ OutOfMemory, StateLimit }!WordDfa {
        const allocator = self.allocator;
        var subsets = std.ArrayListUnmanaged(StateBitset){};
        defer subsets.deinit(allocator);
        var transitions = std.ArrayListUnmanaged(u16){};
        errdefer transitions.deinit(allocator);

        var initial = StateBitset.init();
        self.addStateWithEpsilon(&initial, self.start);
        if (initial.isSet(self.match_state)) return error.StateLimit;

        // State zero is the empty active set. Unlike the regular unanchored
        // DFA, starts are injected conditionally by a separate transition row.
        try subsets.append(allocator, StateBitset.init());
        var index: usize = 0;
        while (index < subsets.items.len) : (index += 1) {
            for (0..2) |inject| {
                var current = subsets.items[index];
                if (inject != 0) {
                    for (initial.bits, 0..) |word, w| current.bits[w] |= word;
                }
                for (0..256) |byte| {
                    var next = StateBitset.init();
                    var iter = current.iterator();
                    while (iter.next()) |state_idx| {
                        const nfa_state = self.states.items[state_idx];
                        if (self.matchTransition(nfa_state.transition, @intCast(byte)))
                            if (nfa_state.out1) |out| self.addStateWithEpsilon(&next, out);
                    }

                    var found: ?usize = null;
                    for (subsets.items, 0..) |known, known_idx| {
                        if (std.mem.eql(u64, &known.bits, &next.bits)) {
                            found = known_idx;
                            break;
                        }
                    }
                    if (found == null) {
                        if (subsets.items.len >= MAX_DFA_STATES) return error.StateLimit;
                        found = subsets.items.len;
                        try subsets.append(allocator, next);
                    }
                    const found_index = found.?;
                    try transitions.append(allocator, @as(u16, @intCast(found_index)) |
                        (if (next.isSet(self.match_state)) DFA_ACCEPTING else 0));
                }
            }
        }
        return .{ .transitions = try transitions.toOwnedSlice(allocator) };
    }
};

pub const CompileError = error{
    OutOfMemory,
    UnexpectedEnd,
    UnmatchedParen,
    UnmatchedBracket,
    TrailingBackslash,
    InvalidEscape,
    InvalidRange,
    InvalidUtf8,
    UnexpectedToken,
    TooManyStates,
};

const Compiler = struct {
    allocator: std.mem.Allocator,
    states: std.ArrayListUnmanaged(State),
    class_ranges: std.ArrayListUnmanaged(CodepointRange),
    pos: usize,
    pattern: []const u8,

    const PatternScalar = struct { codepoint: u21, len: usize };

    fn init(allocator: std.mem.Allocator) Compiler {
        return .{
            .allocator = allocator,
            .states = .{},
            .class_ranges = .{},
            .pos = 0,
            .pattern = undefined,
        };
    }

    fn compile(self: *Compiler, pattern: []const u8) CompileError!Regex {
        self.pattern = pattern;
        self.pos = 0;

        var frag = try self.parseExpr();
        errdefer frag.out.deinit(self.allocator);
        if (self.pos != pattern.len) {
            return error.UnmatchedParen;
        }

        // Add match state
        const match_state = try self.addState(.{ .transition = .match });

        // Connect fragment to match state
        self.patch(frag.out, match_state);
        frag.out.deinit(self.allocator);

        return Regex{
            .allocator = self.allocator,
            .states = self.states,
            .class_ranges = self.class_ranges,
            .start = frag.start,
            .match_state = match_state,
            .literal_info = null,
            .pattern_storage = null,
            .counted_literal_info = null,
            .required_alternation_info = null,
            .required_alternation_plan = null,
            .starts_with_dot_star = false, // Will be set by Regex.compile()
            .empty_line_only = false,
            .any_run_info = null,
            .unicode_class_state = null,
            .scalar_sensitive = false,
            .always_scalar = false,
            .has_assertions = false,
            .ignore_case = false,
            .unanchored_dfa = null,
            .word_dfa = null,
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
                } else if (next_char == '{') {
                    atom = try self.applyCountedQuantifier(atom);
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
                self.pos += 1;
                const state = try self.addState(.{ .transition = if (c == '^') .line_start else .line_end });
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
                if (escapeClass(escaped)) |cc| return self.createSingleState(.{ .char_class = cc });
                return self.createSingleState(.{ .char = try self.escapeChar(escaped) });
            },
            '*', '+', '?', '{', '}', ')', '|' => return error.UnexpectedToken,
            else => {
                const decoded = try self.decodePatternScalar();
                self.pos += decoded.len;
                return self.createSingleState(.{ .char = decoded.codepoint });
            },
        }
    }

    fn parseCharClass(self: *Compiler) CompileError!Fragment {
        self.pos += 1; // Skip '['

        var cc = CharClass.init(false);
        if (self.class_ranges.items.len > std.math.maxInt(u16)) return error.TooManyStates;
        cc.range_start = @intCast(self.class_ranges.items.len);

        if (self.pos < self.pattern.len and self.pattern[self.pos] == '^') {
            cc.negated = true;
            self.pos += 1;
        }

        while (self.pos < self.pattern.len and self.pattern[self.pos] != ']') {
            var codepoint: u21 = undefined;
            if (self.pattern[self.pos] == '\\') {
                self.pos += 1;
                if (self.pos >= self.pattern.len) return error.TrailingBackslash;
                const e = self.pattern[self.pos];
                self.pos += 1;
                if (escapeClass(e)) |ec| {
                    cc.addClass(ec);
                    continue;
                }
                codepoint = try self.escapeChar(e);
            } else {
                const decoded = try self.decodePatternScalar();
                codepoint = decoded.codepoint;
                self.pos += decoded.len;
            }

            // Check for range
            if (self.pos + 1 < self.pattern.len and
                self.pattern[self.pos] == '-' and
                self.pattern[self.pos + 1] != ']')
            {
                self.pos += 1; // Skip '-'
                var end: u21 = undefined;
                if (self.pattern[self.pos] == '\\') {
                    self.pos += 1;
                    if (self.pos >= self.pattern.len) return error.TrailingBackslash;
                    const escaped = self.pattern[self.pos];
                    self.pos += 1;
                    if (escapeClass(escaped) != null) return error.InvalidRange;
                    end = try self.escapeChar(escaped);
                } else {
                    const decoded = try self.decodePatternScalar();
                    end = decoded.codepoint;
                    self.pos += decoded.len;
                }
                if (codepoint > end) return error.InvalidRange;
                try self.addCodepointRange(&cc, codepoint, end);
            } else {
                try self.addCodepointRange(&cc, codepoint, codepoint);
            }
        }

        if (self.pos >= self.pattern.len) {
            return error.UnmatchedBracket;
        }
        self.pos += 1; // Skip ']'

        const range_count = self.class_ranges.items.len - cc.range_start;
        if (range_count > std.math.maxInt(u16)) return error.TooManyStates;
        cc.range_count = @intCast(range_count);

        return self.createSingleState(.{ .char_class = cc });
    }

    fn decodePatternScalar(self: *Compiler) CompileError!PatternScalar {
        const len = std.unicode.utf8ByteSequenceLength(self.pattern[self.pos]) catch return error.InvalidUtf8;
        if (self.pos + len > self.pattern.len) return error.InvalidUtf8;
        const codepoint = std.unicode.utf8Decode(self.pattern[self.pos..][0..len]) catch return error.InvalidUtf8;
        return .{ .codepoint = codepoint, .len = len };
    }

    fn addCodepointRange(self: *Compiler, cc: *CharClass, start: u21, end: u21) CompileError!void {
        var byte_value = start;
        const byte_end = @min(end, std.math.maxInt(u8));
        while (byte_value <= byte_end) : (byte_value += 1) {
            cc.add(@intCast(byte_value));
            if (byte_value == std.math.maxInt(u8)) break;
        }
        if (end <= std.math.maxInt(u8)) return;
        if (self.class_ranges.items.len >= std.math.maxInt(u16)) return error.TooManyStates;
        try self.class_ranges.append(self.allocator, .{
            .start = @max(start, @as(u21, std.math.maxInt(u8)) + 1),
            .end = end,
        });
    }

    fn createSingleState(self: *Compiler, transition: Transition) CompileError!Fragment {
        const state = try self.addState(.{ .transition = transition });
        var out = std.ArrayListUnmanaged(usize){};
        try out.append(self.allocator, state);
        return Fragment{ .start = state, .out = out };
    }

    fn applyQuantifier(self: *Compiler, frag_in: Fragment, quantifier: u8) CompileError!Fragment {
        var frag = frag_in;
        errdefer frag.out.deinit(self.allocator);
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
                frag.out = .{};

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
                errdefer out.deinit(self.allocator);
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
                frag.out = .{};

                // Create skip state for the "done matching" path
                const skip = try self.addState(.{ .transition = .epsilon });
                self.states.items[split].out2 = skip;

                var out = std.ArrayListUnmanaged(usize){};
                errdefer out.deinit(self.allocator);
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
                errdefer new_out.deinit(self.allocator);
                for (frag.out.items) |out_state| {
                    try new_out.append(self.allocator, out_state);
                }
                try new_out.append(self.allocator, skip);
                frag.out.deinit(self.allocator);
                frag.out = .{};

                return Fragment{ .start = split, .out = new_out };
            },
            else => unreachable,
        }
    }

    fn applyCountedQuantifier(self: *Compiler, atom_in: Fragment) CompileError!Fragment {
        var atom = atom_in;
        var atom_owned = true;
        errdefer if (atom_owned) atom.out.deinit(self.allocator);
        std.debug.assert(self.pattern[self.pos] == '{');
        self.pos += 1;
        const min = try self.parseRepeatNumber();

        var max: ?usize = min;
        if (self.pos < self.pattern.len and self.pattern[self.pos] == ',') {
            self.pos += 1;
            max = if (self.pos < self.pattern.len and self.pattern[self.pos] == '}')
                null
            else
                try self.parseRepeatNumber();
        }
        if (self.pos >= self.pattern.len or self.pattern[self.pos] != '}') return error.UnexpectedToken;
        self.pos += 1;
        if (max) |bounded| {
            if (bounded < min) return error.UnexpectedToken;
            if (bounded > MAX_STATES) return error.TooManyStates;
        } else if (min > MAX_STATES) {
            return error.TooManyStates;
        }

        const copies_needed = if (max) |bounded|
            bounded
        else if (min == 0)
            1
        else
            min + 1;
        if (copies_needed == 0) {
            atom.out.deinit(self.allocator);
            atom_owned = false;
            const empty = try self.addState(.{ .transition = .epsilon });
            var out = std.ArrayListUnmanaged(usize){};
            errdefer out.deinit(self.allocator);
            try out.append(self.allocator, empty);
            return .{ .start = empty, .out = out };
        }

        var copies = std.ArrayListUnmanaged(Fragment){};
        defer copies.deinit(self.allocator);
        errdefer for (copies.items) |*copy| copy.out.deinit(self.allocator);
        try copies.append(self.allocator, atom);
        atom_owned = false;
        for (1..copies_needed) |_| {
            var cloned = try self.cloneFragment(atom);
            copies.append(self.allocator, cloned) catch |err| {
                cloned.out.deinit(self.allocator);
                return err;
            };
        }

        for (copies.items, 0..) |*copy, index| {
            const optional = if (max != null)
                index >= min
            else
                (min == 0 or index == min);
            if (optional) {
                const input = copy.*;
                copy.out = .{};
                copy.* = try self.applyQuantifier(input, if (max == null) '*' else '?');
            }
        }

        var result = copies.items[0];
        copies.items[0].out = .{};
        for (copies.items[1..]) |*copy| {
            self.patch(result.out, copy.start);
            result.out.deinit(self.allocator);
            result.out = copy.out;
            copy.out = .{};
        }
        return result;
    }

    fn parseRepeatNumber(self: *Compiler) CompileError!usize {
        const start = self.pos;
        var value: usize = 0;
        while (self.pos < self.pattern.len and std.ascii.isDigit(self.pattern[self.pos])) : (self.pos += 1) {
            value = std.math.mul(usize, value, 10) catch return error.TooManyStates;
            value = std.math.add(usize, value, self.pattern[self.pos] - '0') catch return error.TooManyStates;
        }
        if (self.pos == start) return error.UnexpectedToken;
        return value;
    }

    fn cloneFragment(self: *Compiler, source: Fragment) CompileError!Fragment {
        var state_map = [_]usize{std.math.maxInt(usize)} ** MAX_STATES;
        const start = try self.cloneState(source.start, &state_map);
        var out = std.ArrayListUnmanaged(usize){};
        errdefer out.deinit(self.allocator);
        for (source.out.items) |old_state| {
            const mapped = state_map[old_state];
            if (mapped == std.math.maxInt(usize)) return error.UnexpectedToken;
            try out.append(self.allocator, mapped);
        }
        return .{ .start = start, .out = out };
    }

    fn cloneState(self: *Compiler, old_idx: usize, state_map: *[MAX_STATES]usize) CompileError!usize {
        if (state_map[old_idx] != std.math.maxInt(usize)) return state_map[old_idx];
        const old = self.states.items[old_idx];
        const new_idx = try self.addState(.{ .transition = old.transition });
        state_map[old_idx] = new_idx;
        // Recursive cloning may reallocate `states`; finish it before taking
        // the destination slot again rather than assigning through a stale
        // ArrayList element pointer.
        if (old.out1) |next| {
            const cloned = try self.cloneState(next, state_map);
            self.states.items[new_idx].out1 = cloned;
        }
        if (old.out2) |next| {
            const cloned = try self.cloneState(next, state_map);
            self.states.items[new_idx].out2 = cloned;
        }
        return new_idx;
    }

    fn addState(self: *Compiler, state: State) CompileError!usize {
        const idx = self.states.items.len;
        if (idx >= MAX_STATES) return error.TooManyStates;
        try self.states.append(self.allocator, state);
        return idx;
    }

    fn patch(self: *Compiler, out_list: std.ArrayListUnmanaged(usize), target: usize) void {
        for (out_list.items) |state_idx| {
            self.states.items[state_idx].out1 = target;
        }
    }

    fn escapeChar(self: *Compiler, c: u8) CompileError!u8 {
        _ = self;
        return switch (c) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '\\', '.', '[', ']', '(', ')', '{', '}', '*', '+', '?', '|', '^', '$', '-' => c,
            else => error.InvalidEscape,
        };
    }
};

fn escapeClass(c: u8) ?CharClass {
    var cc = CharClass.init(c == 'S' or c == 'D' or c == 'W');
    switch (std.ascii.toLower(c)) {
        's' => {
            cc.add(' ');
            cc.add('\t');
            cc.add('\r');
            cc.add('\n');
            cc.add(0x0b);
            cc.add(0x0c);
        },
        'd' => cc.addRange('0', '9'),
        'w' => {
            cc.addRange('a', 'z');
            cc.addRange('A', 'Z');
            cc.addRange('0', '9');
            cc.add('_');
            cc.non_ascii = .word;
        },
        else => return null,
    }
    return cc;
}

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

test "line anchors and line-oriented classes" {
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "^foo$");
    defer re.deinit();
    const result = re.find("no\nfoo\nbar").?;
    try std.testing.expectEqual(@as(usize, 3), result.start);
    try std.testing.expectEqual(@as(usize, 6), result.end);

    var class = try Regex.compile(allocator, "[^x]+");
    defer class.deinit();
    try std.testing.expectEqual(@as(usize, 1), class.find("a\nb").?.end);
}

test "standard classes, syntax errors, and ASCII case folding" {
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "\\d+\\s\\w+\\D");
    defer re.deinit();
    try std.testing.expect(re.find("12 abc!") != null);
    try std.testing.expectError(error.InvalidEscape, Regex.compile(allocator, "\\q"));
    try std.testing.expectError(error.InvalidRange, Regex.compile(allocator, "[z-a]"));
    try std.testing.expectError(error.UnexpectedToken, Regex.compile(allocator, "*a"));

    var folded = try Regex.compileWithOptions(allocator, "alpha", .{ .ascii_case_insensitive = true });
    defer folded.deinit();
    try std.testing.expect(folded.find("ALPHA") != null);

    var oversized = [_]u8{'a'} ** MAX_STATES;
    try std.testing.expectError(error.TooManyStates, Regex.compile(allocator, &oversized));
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

test "case insensitive negated character class" {
    const allocator = std.testing.allocator;

    var re = try Regex.compileWithOptions(allocator, "[^a-z]+", .{ .ascii_case_insensitive = true });
    defer re.deinit();

    try std.testing.expect(re.find("abcXYZ") == null);
    try std.testing.expect(re.find("abc 123") != null);
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

test "regex counted repetitions" {
    const allocator = std.testing.allocator;

    var exact = try Regex.compile(allocator, "a{2}");
    defer exact.deinit();
    try std.testing.expect(exact.find("a") == null);
    try std.testing.expectEqual(@as(usize, 2), exact.find("aaa").?.end);

    var bounded = try Regex.compile(allocator, "ba{1,3}c");
    defer bounded.deinit();
    try std.testing.expect(bounded.find("bac") != null);
    try std.testing.expect(bounded.find("baaac") != null);
    try std.testing.expect(bounded.find("bc") == null);
    try std.testing.expect(bounded.find("baaaac") == null);

    var unbounded = try Regex.compile(allocator, "(ab){2,}c");
    defer unbounded.deinit();
    try std.testing.expectEqual(@as(?usize, 5), unbounded.matchAt("ababc", 0));
    try std.testing.expect(unbounded.find("ababc") != null);
    try std.testing.expect(unbounded.find("abababc") != null);
    try std.testing.expect(unbounded.find("abc") == null);

    var optional = try Regex.compile(allocator, "^x{0,2}y$");
    defer optional.deinit();
    try std.testing.expect(optional.find("y") != null);
    try std.testing.expect(optional.find("xxy") != null);
    try std.testing.expect(optional.find("xxxy") == null);

    var alternation = try Regex.compile(allocator, "^(a|bc){2,}$");
    defer alternation.deinit();
    try std.testing.expect(alternation.find("aa") != null);
    try std.testing.expect(alternation.find("abc") != null);
    try std.testing.expect(alternation.find("bca") != null);
    try std.testing.expect(alternation.find("bcbc") != null);
    try std.testing.expect(alternation.find("ab") == null);
}

test "repeated literal alternation uses required-set prefilter" {
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "(Sherlock|John)+");
    defer re.deinit();

    try std.testing.expect(re.required_alternation_info != null);
    try std.testing.expectEqual(
        matcher_mod.MatchResult{ .start = 2, .end = 14 },
        re.find("xxSherlockJohn yy").?,
    );
    try std.testing.expect(re.find("elementary") == null);
}

test "repeated literal alternation preserves source branch priority" {
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "(ab|aba)+");
    defer re.deinit();

    try std.testing.expectEqual(
        matcher_mod.MatchResult{ .start = 0, .end = 2 },
        re.find("aba").?,
    );
    try std.testing.expectEqual(
        matcher_mod.MatchResult{ .start = 0, .end = 4 },
        re.find("abab").?,
    );
}

test "repeated Unicode alternation uses codepoint case folding" {
    const allocator = std.testing.allocator;
    var re = try Regex.compileWithOptions(allocator, "(École|Δelta)+", .{ .ascii_case_insensitive = true });
    defer re.deinit();

    try std.testing.expectEqual(
        matcher_mod.MatchResult{ .start = 2, .end = 14 },
        re.find("xxéCOLEδELTA!").?,
    );
}

test "assertion-bearing inner literal filters recover spans" {
    const allocator = std.testing.allocator;

    var line_end = try Regex.compile(allocator, ".*foo$");
    defer line_end.deinit();
    try std.testing.expectEqual(
        matcher_mod.MatchResult{ .start = 4, .end = 9 },
        line_end.find("bar\nxxfoo\n").?,
    );

    var both = try Regex.compile(allocator, "^.*foo$");
    defer both.deinit();
    try std.testing.expectEqual(
        matcher_mod.MatchResult{ .start = 4, .end = 9 },
        both.find("bar\nxxfoo\n").?,
    );
}

test "single dot consumes one Unicode scalar" {
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, ".");
    defer re.deinit();

    try std.testing.expectEqual(
        matcher_mod.MatchResult{ .start = 0, .end = 3 },
        re.find("界").?,
    );
    try std.testing.expectEqual(
        matcher_mod.MatchResult{ .start = 11, .end = 14 },
        re.findWordFrom("日本 foo 本", 0).?,
    );
}

test "word-boundary count DFA matches boundary-aware search" {
    const allocator = std.testing.allocator;
    const input = "abc\na!b\n!\n---\nÉcole\nUºurel\n";

    var dot = try Regex.compileWithOptions(allocator, ".", .{ .word_boundary = true });
    defer dot.deinit();
    try std.testing.expectEqual(
        matcher_mod.LineCount{ .count = 3, .binary_offset = null },
        dot.countWordMatchingLines(input, true).?,
    );

    var negated = try Regex.compileWithOptions(allocator, "[^abc]+", .{ .word_boundary = true });
    defer negated.deinit();
    try std.testing.expect(negated.word_dfa != null);
    try std.testing.expectEqual(
        matcher_mod.LineCount{ .count = 3, .binary_offset = null },
        negated.countWordMatchingLines(input, true).?,
    );
}

test "word-boundary count rejects malformed adjacent UTF-8" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{
        "a\x80\n",
        "\x80a\n",
        "!\x80\n",
        "\x80!\n",
        "a\xe2\n",
        "\xe2a\n",
    };

    var dot = try Regex.compileWithOptions(allocator, ".", .{ .word_boundary = true });
    defer dot.deinit();
    var word = try Regex.compileWithOptions(allocator, "\\w", .{ .word_boundary = true });
    defer word.deinit();

    for (inputs) |input| {
        try std.testing.expectEqual(@as(usize, 0), dot.countWordMatchingLines(input, false).?.count);
        try std.testing.expectEqual(@as(usize, 0), word.countWordMatchingLines(input, false).?.count);
    }
}

test "counted dot run uses Unicode scalar minimum" {
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, ".{3,8}");
    defer re.deinit();

    const input = "界界\n界界界\nascii\n";
    try std.testing.expectEqual(
        matcher_mod.LineCount{ .count = 2, .binary_offset = null },
        re.countMatchingLines(input, true).?,
    );
    try std.testing.expectEqual(
        matcher_mod.MatchResult{ .start = 7, .end = 16 },
        re.find(input).?,
    );
}

test "empty-line count specialization" {
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "^$");
    defer re.deinit();
    try std.testing.expectEqual(
        matcher_mod.LineCount{ .count = 3, .binary_offset = null },
        re.countMatchingLines("\ntext\n\n\nlast\n", true).?,
    );
}

test "broad counted regex supports direct line counting" {
    const allocator = std.testing.allocator;
    var re = try Regex.compile(allocator, "\\w{5}\\s+\\w{5}\\s+\\w{5}");
    defer re.deinit();

    try std.testing.expect(re.supportsFastLineCount());
    try std.testing.expectEqual(
        matcher_mod.LineCount{ .count = 2, .binary_offset = null },
        re.countMatchingLines("alpha delta gamma\nshort\nthree words there\n", false).?,
    );

    const binary = "alpha delta gamma\nalpha delta gamma\x00\nalpha delta gamma\n";
    try std.testing.expectEqual(
        matcher_mod.LineCount{ .count = 3, .binary_offset = 35 },
        re.countMatchingLines(binary, true).?,
    );
}

test "regex rejects invalid counted repetitions" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedToken, Regex.compile(allocator, "a{,2}"));
    try std.testing.expectError(error.UnexpectedToken, Regex.compile(allocator, "a{3,2}"));
    try std.testing.expectError(error.UnexpectedToken, Regex.compile(allocator, "a{2"));
    try std.testing.expectError(error.TooManyStates, Regex.compile(allocator, "a{254,}"));
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

test "regex separated literal extraction" {
    const allocator = std.testing.allocator;

    // Pattern with literal prefix followed by regex
    var re = try Regex.compile(allocator, "hello.*world");
    defer re.deinit();

    const info = re.getLiteralInfo();
    try std.testing.expect(info != null);
    try std.testing.expectEqualStrings("world", info.?.literal);
    try std.testing.expectEqual(literal.LiteralInfo.Position.suffix, info.?.position);
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

    try std.testing.expect(cc.contains('a', false));
    try std.testing.expect(cc.contains('b', false));
    try std.testing.expect(cc.contains('z', false));
    try std.testing.expect(!cc.contains('c', false));
    try std.testing.expect(!cc.contains('x', false));
}

test "CharClass addRange" {
    var cc = CharClass.init(false);
    cc.addRange('a', 'f');

    try std.testing.expect(cc.contains('a', false));
    try std.testing.expect(cc.contains('c', false));
    try std.testing.expect(cc.contains('f', false));
    try std.testing.expect(!cc.contains('g', false));
    try std.testing.expect(!cc.contains('z', false));
}

test "CharClass negated" {
    var cc = CharClass.init(true); // negated
    cc.add('a');
    cc.add('b');

    // Negated class: contains returns true for chars NOT in the set
    try std.testing.expect(!cc.contains('a', false));
    try std.testing.expect(!cc.contains('b', false));
    try std.testing.expect(cc.contains('c', false));
    try std.testing.expect(cc.contains('z', false));
    try std.testing.expect(!cc.contains('A', true));
}

test "regex dot does not match newline" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "a.b");
    defer re.deinit();

    try std.testing.expect(re.find("axb") != null);
    try std.testing.expect(re.find("a\nb") == null);
}

test "regex Unicode Perl word classes consume complete scalars" {
    const allocator = std.testing.allocator;
    const input = "—fooαβbar—";

    var word = try Regex.compile(allocator, "foo\\w+bar");
    defer word.deinit();
    const word_match = word.find(input).?;
    try std.testing.expectEqual(@as(usize, "—".len), word_match.start);
    try std.testing.expectEqual(@as(usize, input.len - "—".len), word_match.end);

    var non_word = try Regex.compile(allocator, "\\W+");
    defer non_word.deinit();
    const non_word_match = non_word.find(input).?;
    try std.testing.expectEqual(@as(usize, 0), non_word_match.start);
    try std.testing.expectEqual(@as(usize, "—".len), non_word_match.end);

    var bracketed = try Regex.compile(allocator, "[\\w.-]+");
    defer bracketed.deinit();
    const bracketed_match = bracketed.find(input).?;
    try std.testing.expectEqual(word_match, bracketed_match);
}

test "regex counted Unicode word class counts codepoints not bytes" {
    const allocator = std.testing.allocator;

    var re = try Regex.compileWithOptions(allocator, "\\w{2}", .{ .word_boundary = true });
    defer re.deinit();

    try std.testing.expect(re.findWordFrom("α", 0) == null);
    try std.testing.expect(re.findWordFrom("αβ", 0) != null);

    const counted = re.countWordMatchingLines("α\n中\nab\naα\n", false).?;
    try std.testing.expectEqual(@as(usize, 2), counted.count);
}

test "regex ordered Pike VM preserves alternation priority and greediness" {
    const allocator = std.testing.allocator;

    var first_short = try Regex.compile(allocator, "a|a.*");
    defer first_short.deinit();
    try std.testing.expectEqual(matcher_mod.MatchResult{ .start = 0, .end = 1 }, first_short.find("abc").?);

    var first_greedy = try Regex.compile(allocator, "a.*|a");
    defer first_greedy.deinit();
    try std.testing.expectEqual(matcher_mod.MatchResult{ .start = 0, .end = 3 }, first_greedy.find("abc").?);

    var boundary = try Regex.compile(allocator, "a|.+");
    defer boundary.deinit();
    try std.testing.expectEqual(matcher_mod.MatchResult{ .start = 0, .end = 1 }, boundary.findWordFrom("a!", 0).?);
}

test "regex scalar literal filters cannot accept partial Unicode characters" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "..cd");
    defer re.deinit();
    try std.testing.expect(re.find("écd") == null);
    try std.testing.expect(re.findEndFrom("écd", 0) == null);
    try std.testing.expect(re.find("zzécd") != null);
    try std.testing.expect(re.findEndFrom("zzécd", 0) != null);
}

test "regex dot and classes reject malformed UTF-8" {
    const allocator = std.testing.allocator;
    const invalid = "\xff\xe2";

    var dot = try Regex.compile(allocator, ".");
    defer dot.deinit();
    try std.testing.expect(dot.find(invalid) == null);

    var class = try Regex.compile(allocator, "[^a]");
    defer class.deinit();
    try std.testing.expect(class.find(invalid) == null);

    var run = try Regex.compile(allocator, ".{2}");
    defer run.deinit();
    try std.testing.expect(run.find(invalid) == null);
}

test "regex bracket classes support Unicode literals and ranges" {
    const allocator = std.testing.allocator;

    var literal_class = try Regex.compile(allocator, "[é中]+");
    defer literal_class.deinit();
    try std.testing.expectEqual(matcher_mod.MatchResult{ .start = 1, .end = 6 }, literal_class.find("xé中y").?);

    var range_class = try Regex.compile(allocator, "[α-ω]+");
    defer range_class.deinit();
    try std.testing.expectEqual(matcher_mod.MatchResult{ .start = 2, .end = 6 }, range_class.find("ΩαβΨ").?);

    var negated = try Regex.compile(allocator, "[^é]+");
    defer negated.deinit();
    try std.testing.expectEqual(matcher_mod.MatchResult{ .start = 2, .end = 3 }, negated.find("éx").?);
}
