const std = @import("std");
const regex = @import("regex.zig");
const simd = @import("simd.zig");
const literal = @import("literal.zig");
const aho_corasick = @import("aho_corasick.zig");
const unicode_word = @import("unicode_word.zig");
const unicode_case = @import("unicode_case.zig");

const special_fold_patterns = [_][]const u8{ "K", "ſ" };
const special_fold_plan = simd.prepareSmallLiteralPlan(&special_fold_patterns, false);

pub const MatchResult = struct {
    start: usize,
    end: usize,
};

const IndexedMatch = struct {
    result: MatchResult,
    pattern_idx: usize,
};

pub const LineCount = struct {
    count: usize,
    binary_offset: ?usize,
};

fn containsLineTerminator(pattern: []const u8) bool {
    var pos: usize = 0;
    while (pos < pattern.len) : (pos += 1) {
        if (pattern[pos] == '\n') return true;
        if (pattern[pos] != '\\') continue;
        pos += 1;
        if (pos < pattern.len and pattern[pos] == 'n') return true;
    }
    return false;
}

pub const Matcher = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    ignore_case: bool,
    word_boundary: bool,
    is_literal: bool,
    regex_engine: ?regex.Regex,
    lower_pattern: ?[]u8,

    // Multi-pattern support for pure-literal alternation (Aho-Corasick)
    ac_automaton: ?aho_corasick.AhoCorasick,
    alternation_info: ?literal.AlternationInfo,
    is_multi_literal: bool,
    lower_alternation_patterns: ?[][]u8, // Lowercased patterns for case-insensitive AC
    small_literal_plan: ?simd.SmallLiteralPlan,
    fixed_alternation_info: ?literal.FixedAlternationInfo,
    fixed_alternation_plan: ?simd.SmallLiteralPlan,
    fixed_patterns: [8][]const u8,
    fixed_teddy_plan: ?simd.SmallLiteralPlan,

    pub fn init(allocator: std.mem.Allocator, pattern: []const u8, ignore_case: bool, word_boundary: bool) !Matcher {
        if (containsLineTerminator(pattern)) return error.NewlineNotAllowed;

        // First, try to detect pure-literal alternation for AC optimization
        if (try literal.extractAlternationLiterals(allocator, pattern)) |extracted| {
            var alt_info = extracted;
            errdefer alt_info.deinit();

            // Pure-literal alternation detected - use Aho-Corasick
            // For case-insensitive, build AC from lowercased patterns
            var patterns_to_use: []const []const u8 = alt_info.literals;
            var lower_patterns: ?[][]u8 = null;
            var lower_patterns_initialized: usize = 0;

            if (ignore_case and alt_info.ascii_only) {
                lower_patterns = try allocator.alloc([]u8, alt_info.literals.len);
                errdefer {
                    if (lower_patterns) |lp| {
                        for (lp[0..lower_patterns_initialized]) |p| allocator.free(p);
                        allocator.free(lp);
                    }
                }
                for (alt_info.literals, 0..) |lit, i| {
                    lower_patterns.?[i] = try allocator.alloc(u8, lit.len);
                    lower_patterns_initialized += 1;
                    for (lit, 0..) |c, j| {
                        lower_patterns.?[i][j] = std.ascii.toLower(c);
                    }
                }
                // Use the lowercased patterns slice for AC
                // Need to cast to []const []const u8
                patterns_to_use = @as([]const []const u8, @ptrCast(lower_patterns.?));
            }

            var ac = try aho_corasick.AhoCorasick.compile(allocator, patterns_to_use);
            errdefer ac.deinit();

            // Free the lower_patterns array (but not the strings - AC doesn't own them either)
            // Actually AC doesn't copy the strings, so we need to keep them
            // Store them in a separate field

            return .{
                .allocator = allocator,
                .pattern = pattern,
                .ignore_case = ignore_case,
                .word_boundary = word_boundary,
                .is_literal = false, // Not a single literal
                .regex_engine = null, // Don't need regex for pure-literal alternation
                .lower_pattern = null,
                .ac_automaton = ac,
                .alternation_info = alt_info,
                .is_multi_literal = true,
                .lower_alternation_patterns = lower_patterns,
                .small_literal_plan = if (alt_info.literals.len <= 8)
                    simd.prepareSmallLiteralPlan(alt_info.literals, ignore_case)
                else
                    null,
                .fixed_alternation_info = null,
                .fixed_alternation_plan = null,
                .fixed_patterns = undefined,
                .fixed_teddy_plan = null,
            };
        }

        // Fall back to existing behavior for single patterns and complex regex
        const is_literal = !containsRegexMetaChars(pattern);

        var lower_pattern: ?[]u8 = null;
        if (ignore_case and is_literal) {
            lower_pattern = try allocator.alloc(u8, pattern.len);
            errdefer allocator.free(lower_pattern.?);
            for (pattern, 0..) |c, i| {
                lower_pattern.?[i] = std.ascii.toLower(c);
            }
        }

        var fixed_alternation_info = if (!is_literal)
            try literal.extractFixedAlternation(allocator, pattern)
        else
            null;
        errdefer if (fixed_alternation_info) |*info| info.deinit();

        var regex_engine: ?regex.Regex = null;
        if (!is_literal and fixed_alternation_info == null) {
            regex_engine = try regex.Regex.compileWithOptions(allocator, pattern, .{
                .ascii_case_insensitive = ignore_case,
                .word_boundary = word_boundary,
            });
            errdefer regex_engine.?.deinit();
        }

        var fixed_patterns: [8][]const u8 = undefined;
        var fixed_teddy_plan: ?simd.SmallLiteralPlan = null;
        if (fixed_alternation_info) |info| {
            for (info.branches, 0..) |branch, i| fixed_patterns[i] = branch.pattern;
            if (info.branches.len >= 4 and (!ignore_case or info.ascii_only)) {
                const candidate = simd.prepareSmallLiteralPlan(fixed_patterns[0..info.branches.len], ignore_case);
                var fingerprints_are_literal = candidate.use_teddy;
                const fingerprint_count: usize = if (ignore_case) 3 else 2;
                for (info.branches) |branch| {
                    for (candidate.teddy_offsets[0..fingerprint_count]) |offset| {
                        if (branch.pattern[offset] == '.') fingerprints_are_literal = false;
                    }
                }
                if (fingerprints_are_literal) fixed_teddy_plan = candidate;
            }
        }

        return .{
            .allocator = allocator,
            .pattern = pattern,
            .ignore_case = ignore_case,
            .word_boundary = word_boundary,
            .is_literal = is_literal,
            .regex_engine = regex_engine,
            .lower_pattern = lower_pattern,
            .ac_automaton = null,
            .alternation_info = null,
            .is_multi_literal = false,
            .lower_alternation_patterns = null,
            .small_literal_plan = null,
            .fixed_alternation_plan = if (fixed_alternation_info) |info| blk: {
                if (ignore_case and !info.ascii_only) break :blk null;
                break :blk simd.prepareSmallLiteralPlan(info.required_literals, ignore_case);
            } else null,
            .fixed_alternation_info = fixed_alternation_info,
            .fixed_patterns = fixed_patterns,
            .fixed_teddy_plan = fixed_teddy_plan,
        };
    }

    pub fn deinit(self: *Matcher) void {
        if (self.regex_engine) |*re| {
            re.deinit();
        }
        if (self.lower_pattern) |lp| {
            self.allocator.free(lp);
        }
        // Free Aho-Corasick resources
        if (self.ac_automaton) |*ac| {
            ac.deinit();
        }
        if (self.alternation_info) |*info| {
            info.deinit();
        }
        // Free lowercased alternation patterns (for case-insensitive)
        if (self.lower_alternation_patterns) |lp| {
            for (lp) |p| {
                self.allocator.free(p);
            }
            self.allocator.free(lp);
        }
        if (self.fixed_alternation_info) |*info| info.deinit();
    }

    /// Find the first match in the given haystack
    pub fn findFirst(self: *const Matcher, haystack: []const u8) ?MatchResult {
        return self.findFirstFrom(haystack, 0);
    }

    /// Return only the end offset when callers do not need the matching span.
    /// Regex DFAs can avoid the more expensive leftmost/greedy span recovery.
    pub fn findFirstEndFrom(self: *const Matcher, haystack: []const u8, start_offset: usize) ?usize {
        if (!self.word_boundary and !self.is_literal and !self.is_multi_literal and self.fixed_alternation_info == null) {
            if (self.regex_engine) |*re| return re.findEndFrom(haystack, start_offset);
        }
        return if (self.findFirstFrom(haystack, start_offset)) |match| match.end else null;
    }

    /// Find the first match starting from a given offset
    pub fn findFirstFrom(self: *const Matcher, haystack: []const u8, start_offset: usize) ?MatchResult {
        if (start_offset > haystack.len) return null;
        if (start_offset == haystack.len and haystack.len != 0) return null;

        // Use Aho-Corasick for multi-literal alternation patterns
        if (self.is_multi_literal) {
            return self.findFirstMultiLiteral(haystack, start_offset);
        }

        const result = if (self.is_literal)
            self.findLiteralInFrom(haystack, start_offset)
        else blk: {
            if (self.fixed_alternation_info != null) {
                break :blk self.findFixedAlternationFrom(haystack, start_offset);
            }
            if (self.regex_engine) |*re| {
                if (self.word_boundary) break :blk re.findWordFrom(haystack, start_offset);
                // Use findFrom to efficiently resume search from offset
                // This avoids re-running O(n²) suffix filter on each retry
                break :blk re.findFrom(haystack, start_offset);
            }
            break :blk null;
        };

        if (result) |r| {
            // If word boundary mode is enabled, validate the match
            if (self.word_boundary) {
                if (!isWordBoundaryMatch(haystack, r.start, r.end)) {
                    if (self.fixed_alternation_info != null) {
                        if (self.findBoundaryFixedAlternativeAt(haystack, r.start)) |alternative| return alternative;
                        return self.findFirstFrom(haystack, r.start + 1);
                    }
                    // Not a word boundary match, try again
                    // For patterns like .*SUFFIX where r.start is always 0,
                    // we need to skip past the END of the match to find the next
                    // suffix occurrence. Otherwise we'd get the same match forever.
                    const next_pos = if (r.end > start_offset) r.end else start_offset + 1;
                    return self.findFirstFrom(haystack, next_pos);
                }
            }

            return r;
        }

        return null;
    }

    fn findFixedAlternationFrom(self: *const Matcher, haystack: []const u8, start_offset: usize) ?MatchResult {
        const info = self.fixed_alternation_info orelse return null;
        if (self.ignore_case and !info.ascii_only) {
            return self.findFixedAlternationUnicodeFrom(haystack, start_offset);
        }
        var prefixes_only = true;
        for (info.branches) |branch| if (branch.required_offset != 0) {
            prefixes_only = false;
            break;
        };
        const unicode_fold_exception = self.ignore_case and
            patternsNeedNonAsciiFold(info.required_literals) and containsNonAscii(haystack[start_offset..]);
        if (prefixes_only and !unicode_fold_exception) {
            return self.findFixedPrefixAlternationFrom(haystack, start_offset);
        }
        var search_pos = start_offset;
        while (simd.findNonAscii(haystack[search_pos..])) |relative_high| {
            const high = search_pos + relative_high;
            var line_start = high;
            while (line_start > search_pos and haystack[line_start - 1] != '\n') line_start -= 1;

            if (self.findFixedAlternationBytesFrom(haystack[search_pos..line_start], 0)) |match| {
                return .{ .start = search_pos + match.start, .end = search_pos + match.end };
            }

            const line_end = high + (simd.findNewline(haystack[high..]) orelse (haystack.len - high));
            if (self.findFixedAlternationUnicodeFrom(haystack[line_start..line_end], 0)) |match| {
                return .{ .start = line_start + match.start, .end = line_start + match.end };
            }
            if (line_end == haystack.len) return null;
            search_pos = line_end + 1;
        }
        if (self.findFixedAlternationBytesFrom(haystack[search_pos..], 0)) |match| {
            return .{ .start = search_pos + match.start, .end = search_pos + match.end };
        }
        return null;
    }

    fn findFixedPrefixAlternationFrom(self: *const Matcher, haystack: []const u8, start_offset: usize) ?MatchResult {
        const info = self.fixed_alternation_info orelse return null;
        const plan = if (self.fixed_alternation_plan) |*prepared| prepared else return null;
        var search_pos = start_offset;
        while (search_pos < haystack.len) {
            const hit = if (self.ignore_case)
                simd.findAnySubstringFromIgnoreCasePrepared(haystack, info.required_literals, search_pos, plan)
            else
                simd.findAnySubstringFromPrepared(haystack, info.required_literals, search_pos, plan);
            const candidate = hit orelse return null;
            for (info.branches) |branch| {
                if (candidate.start + branch.required_literal.len > haystack.len or
                    !self.fixedBytesEqual(
                        haystack[candidate.start..][0..branch.required_literal.len],
                        branch.required_literal,
                    )) continue;
                const end = self.fixedUnicodeBranchEnd(haystack, candidate.start, branch.pattern) orelse continue;
                return .{ .start = candidate.start, .end = end };
            }
            search_pos = candidate.start + 1;
        }
        return null;
    }

    fn findFixedAlternationBytesFrom(self: *const Matcher, haystack: []const u8, start_offset: usize) ?MatchResult {
        const info = self.fixed_alternation_info orelse return null;
        if (self.fixed_teddy_plan) |*plan| {
            const patterns = self.fixed_patterns[0..info.branches.len];
            const match = simd.findAnyFixedTeddyFromPrepared(
                haystack,
                patterns,
                start_offset,
                plan,
                self.ignore_case,
            ) orelse return null;
            return .{ .start = match.start, .end = match.end };
        }
        const plan = if (self.fixed_alternation_plan) |*prepared| prepared else return null;
        var search_pos = start_offset;
        var best: ?MatchResult = null;
        var best_pattern_idx: usize = std.math.maxInt(usize);

        while (search_pos < haystack.len) {
            const candidate = if (self.ignore_case)
                simd.findAnySubstringFromIgnoreCasePrepared(haystack, info.required_literals, search_pos, plan)
            else
                simd.findAnySubstringFromPrepared(haystack, info.required_literals, search_pos, plan);
            const hit = candidate orelse return best;

            // Multiple branches can use the same required literal. Check all
            // branches at this literal position rather than trusting the one
            // pattern index selected by the SIMD prefilter.
            for (info.branches, 0..) |branch, pattern_idx| {
                if (hit.start < branch.required_offset) continue;
                const match_start = hit.start - branch.required_offset;
                if (match_start < start_offset or match_start + branch.pattern.len > haystack.len) continue;
                if (!self.fixedBytesEqual(
                    haystack[hit.start..][0..branch.required_literal.len],
                    branch.required_literal,
                )) continue;
                if (!self.fixedBranchMatches(haystack[match_start..][0..branch.pattern.len], branch.pattern)) continue;

                if (best == null or match_start < best.?.start or
                    (match_start == best.?.start and pattern_idx < best_pattern_idx))
                {
                    best = .{ .start = match_start, .end = match_start + branch.pattern.len };
                    best_pattern_idx = pattern_idx;
                }
            }

            // A future required-literal hit can move its branch start backward
            // by at most max_required_offset. Once that cannot beat `best`,
            // leftmost-first semantics are proven and scanning can stop.
            if (best) |match| {
                if (hit.start >= match.start + info.max_required_offset) return match;
            }
            search_pos = hit.start + 1;
        }
        return best;
    }

    fn findFixedAlternationUnicodeFrom(self: *const Matcher, haystack: []const u8, start_offset: usize) ?MatchResult {
        const info = self.fixed_alternation_info orelse return null;
        var pos = start_offset;
        while (pos < haystack.len and (haystack[pos] & 0xc0) == 0x80) pos += 1;
        while (pos < haystack.len) {
            for (info.branches) |branch| {
                const end = self.fixedUnicodeBranchEnd(haystack, pos, branch.pattern) orelse continue;
                return .{ .start = pos, .end = end };
            }
            pos += decodeAt(haystack, pos).len;
        }
        return null;
    }

    fn fixedUnicodeBranchEnd(self: *const Matcher, haystack: []const u8, start: usize, branch: []const u8) ?usize {
        var haystack_pos = start;
        var branch_pos: usize = 0;
        while (branch_pos < branch.len) {
            if (haystack_pos >= haystack.len) return null;
            const actual = decodeAt(haystack, haystack_pos);
            if (!actual.valid) return null;
            if (branch[branch_pos] == '.') {
                if (actual.codepoint == '\n') return null;
                branch_pos += 1;
            } else {
                const expected = decodeAt(branch, branch_pos);
                if (!expected.valid) return null;
                if (self.ignore_case) {
                    if (simpleFoldCodepoint(actual.codepoint) != simpleFoldCodepoint(expected.codepoint)) return null;
                } else if (actual.codepoint != expected.codepoint) return null;
                branch_pos += expected.len;
            }
            haystack_pos += actual.len;
        }
        return haystack_pos;
    }

    fn findBoundaryFixedAlternativeAt(self: *const Matcher, haystack: []const u8, start: usize) ?MatchResult {
        const info = self.fixed_alternation_info orelse return null;
        for (info.branches) |branch| {
            if ((self.ignore_case and !info.ascii_only) or containsNonAscii(haystack[start..])) {
                const unicode_end = self.fixedUnicodeBranchEnd(haystack, start, branch.pattern) orelse continue;
                if (isWordBoundaryMatch(haystack, start, unicode_end)) return .{ .start = start, .end = unicode_end };
                continue;
            }
            const end = start + branch.pattern.len;
            if (end > haystack.len) continue;
            if (!self.fixedBranchMatches(haystack[start..end], branch.pattern)) continue;
            if (isWordBoundaryMatch(haystack, start, end)) return .{ .start = start, .end = end };
        }
        return null;
    }

    fn fixedBytesEqual(self: *const Matcher, haystack: []const u8, expected: []const u8) bool {
        if (!self.ignore_case) return std.mem.eql(u8, haystack, expected);
        for (haystack, expected) |actual, wanted| {
            if (std.ascii.toLower(actual) != std.ascii.toLower(wanted)) return false;
        }
        return true;
    }

    fn fixedBranchMatches(self: *const Matcher, haystack: []const u8, branch: []const u8) bool {
        for (haystack, branch) |actual, expected| {
            if (expected == '.') {
                if (actual == '\n') return false;
            } else if (self.ignore_case) {
                if (std.ascii.toLower(actual) != std.ascii.toLower(expected)) return false;
            } else if (actual != expected) {
                return false;
            }
        }
        return true;
    }

    /// Find first match using Aho-Corasick for multi-literal alternation
    fn findFirstMultiLiteral(self: *const Matcher, haystack: []const u8, start_offset: usize) ?MatchResult {
        const ac = &(self.ac_automaton orelse return null);
        const info = self.alternation_info orelse return null;

        // For case-insensitive, we need to lowercase the haystack
        // This is done on-the-fly to avoid allocation
        if (self.ignore_case) {
            return self.findFirstMultiLiteralIgnoreCase(haystack, start_offset);
        }

        const match = if (info.literals.len <= 8) blk: {
            const plan = if (self.small_literal_plan) |*prepared| prepared else unreachable;
            const m = simd.findAnySubstringFromPrepared(haystack, info.literals, start_offset, plan) orelse return null;
            break :blk aho_corasick.Match{ .start = m.start, .end = m.end, .pattern_idx = m.pattern_idx };
        } else ac.findFirstFrom(haystack, start_offset) orelse return null;
        {
            const result = MatchResult{
                .start = match.start,
                .end = match.end,
            };

            // Word boundary check
            if (self.word_boundary) {
                if (!isWordBoundaryMatch(haystack, result.start, result.end)) {
                    if (self.findBoundaryLiteralAlternativeAt(haystack, result.start)) |alternative| return alternative;
                    // Not a word boundary match, try again from after match start
                    return self.findFirstMultiLiteral(haystack, result.start + 1);
                }
            }

            return result;
        }
    }

    /// Case-insensitive multi-literal search
    /// Uses a stack buffer to lowercase chunks of the haystack
    fn findFirstMultiLiteralIgnoreCase(self: *const Matcher, haystack: []const u8, start_offset: usize) ?MatchResult {
        _ = &(self.ac_automaton orelse return null);
        const info = self.alternation_info orelse return null;

        if (!info.ascii_only) return self.findMultiLiteralUnicodeIgnoreCase(haystack, start_offset);
        if (patternsNeedNonAsciiFold(info.literals) and containsNonAscii(haystack[start_offset..])) {
            return self.findMultiLiteralHybridIgnoreCase(haystack, start_offset);
        }
        return self.findMultiLiteralAsciiIgnoreCase(haystack, start_offset);
    }

    fn findMultiLiteralUnicodeCandidate(self: *const Matcher, haystack: []const u8, start_offset: usize) ?MatchResult {
        const info = self.alternation_info orelse return null;
        var earliest: ?MatchResult = null;
        for (info.literals) |alternative| {
            const match = findUnicodeIgnoreCase(haystack, alternative, start_offset) orelse continue;
            if (earliest == null or match.start < earliest.?.start) earliest = match;
        }
        return earliest;
    }

    fn findMultiLiteralUnicodeIgnoreCase(self: *const Matcher, haystack: []const u8, start_offset: usize) ?MatchResult {
        if (self.findMultiLiteralUnicodeCandidate(haystack, start_offset)) |result| {
            if (self.word_boundary and !isWordBoundaryMatch(haystack, result.start, result.end)) {
                if (self.findBoundaryLiteralAlternativeAt(haystack, result.start)) |alternative| return alternative;
                return self.findFirstMultiLiteralIgnoreCase(haystack, result.start + 1);
            }
            return result;
        }
        return null;
    }

    fn findMultiLiteralHybridIgnoreCase(self: *const Matcher, haystack: []const u8, start_offset: usize) ?MatchResult {
        const ascii_match = self.findMultiLiteralAsciiIgnoreCase(haystack, start_offset);
        const limit = if (ascii_match) |match| match.start else haystack.len;
        if (self.findMultiLiteralSpecialFoldCandidate(haystack, start_offset, limit)) |special| {
            const result = special.result;
            if (result.start == limit) {
                return self.findLiteralAlternativeAt(haystack, result.start, self.word_boundary) orelse ascii_match;
            }
            if (self.word_boundary and !isWordBoundaryMatch(haystack, result.start, result.end)) {
                if (self.findBoundaryLiteralAlternativeAt(haystack, result.start)) |alternative| return alternative;
                return self.findFirstMultiLiteralIgnoreCase(haystack, result.start + 1);
            }
            return result;
        }
        return ascii_match;
    }

    fn findMultiLiteralSpecialFoldCandidate(
        self: *const Matcher,
        haystack: []const u8,
        start_offset: usize,
        max_start: usize,
    ) ?IndexedMatch {
        const max_pattern_len = self.ac_automaton.?.getMaxPatternLen();
        const scan_end = @min(haystack.len, max_start +| (max_pattern_len *| 3));
        var earliest: ?IndexedMatch = null;
        var scan_pos = start_offset;
        while (simd.findAnySubstringFromPrepared(
            haystack[0..scan_end],
            &special_fold_patterns,
            scan_pos,
            &special_fold_plan,
        )) |special| {
            if (self.findMultiLiteralCandidateUsingSpecialAt(
                haystack,
                special.start,
                special.pattern_idx,
                start_offset,
                max_start,
            )) |candidate| {
                if (earliest == null or candidate.result.start < earliest.?.result.start or
                    (candidate.result.start == earliest.?.result.start and candidate.pattern_idx < earliest.?.pattern_idx))
                {
                    earliest = candidate;
                }
            }
            scan_pos = special.start + 1;
        }
        return earliest;
    }

    fn findMultiLiteralCandidateUsingSpecialAt(
        self: *const Matcher,
        haystack: []const u8,
        special_start: usize,
        special_pattern_idx: usize,
        start_offset: usize,
        max_start: usize,
    ) ?IndexedMatch {
        const info = self.alternation_info orelse return null;
        const folded_byte: u8 = if (special_pattern_idx == 0) 'k' else 's';
        var earliest: ?IndexedMatch = null;
        for (info.literals, 0..) |alternative, pattern_idx| {
            for (alternative, 0..) |byte, scalar_idx| {
                if (std.ascii.toLower(byte) != folded_byte) continue;
                const candidate_start = retreatValidScalars(
                    haystack,
                    special_start,
                    scalar_idx,
                    start_offset,
                ) orelse continue;
                if (candidate_start > max_start) continue;
                const match_len = foldedPrefixLen(haystack[candidate_start..], alternative) orelse continue;
                const candidate = IndexedMatch{
                    .result = .{ .start = candidate_start, .end = candidate_start + match_len },
                    .pattern_idx = pattern_idx,
                };
                if (earliest == null or candidate.result.start < earliest.?.result.start or
                    (candidate.result.start == earliest.?.result.start and pattern_idx < earliest.?.pattern_idx))
                {
                    earliest = candidate;
                }
            }
        }
        return earliest;
    }

    fn findMultiLiteralAsciiIgnoreCase(self: *const Matcher, haystack: []const u8, start_offset: usize) ?MatchResult {
        _ = &(self.ac_automaton orelse return null);
        const info = self.alternation_info orelse return null;

        if (info.literals.len <= 8) {
            const plan = if (self.small_literal_plan) |*prepared| prepared else unreachable;
            if (simd.findAnySubstringFromIgnoreCasePrepared(haystack, info.literals, start_offset, plan)) |match| {
                const result = MatchResult{ .start = match.start, .end = match.end };
                if (self.word_boundary and !isWordBoundaryMatch(haystack, result.start, result.end)) {
                    if (self.findBoundaryLiteralAlternativeAt(haystack, result.start)) |alternative| return alternative;
                    return self.findFirstMultiLiteralIgnoreCase(haystack, result.start + 1);
                }
                return result;
            }
            return null;
        }

        // For small haystacks, lowercase the entire thing
        // For large haystacks, search each pattern individually using SIMD
        if (haystack.len <= 4096) {
            // Use stack buffer for lowercasing
            var lower_buf: [4096]u8 = undefined;
            const len = @min(haystack.len, 4096);
            for (haystack[0..len], 0..) |c, i| {
                lower_buf[i] = std.ascii.toLower(c);
            }

            if (self.ac_automaton.?.findFirstFrom(lower_buf[0..len], start_offset)) |match| {
                const result = MatchResult{
                    .start = match.start,
                    .end = match.end,
                };

                if (self.word_boundary) {
                    if (!isWordBoundaryMatch(haystack, result.start, result.end)) {
                        if (self.findBoundaryLiteralAlternativeAt(haystack, result.start)) |alternative| return alternative;
                        return self.findFirstMultiLiteralIgnoreCase(haystack, result.start + 1);
                    }
                }

                return result;
            }
            return null;
        }

        // For large haystacks, fall back to parallel SIMD search for each pattern
        var earliest_match: ?MatchResult = null;
        var earliest_pos: usize = std.math.maxInt(usize);

        for (info.literals) |lit| {
            if (simd.findSubstringFromIgnoreCase(haystack, lit, start_offset)) |found_pos| {
                if (found_pos < earliest_pos) {
                    earliest_pos = found_pos;
                    earliest_match = MatchResult{
                        .start = found_pos,
                        .end = found_pos + lit.len,
                    };
                }
            }
        }

        if (earliest_match) |result| {
            if (self.word_boundary) {
                if (!isWordBoundaryMatch(haystack, result.start, result.end)) {
                    if (self.findBoundaryLiteralAlternativeAt(haystack, result.start)) |alternative| return alternative;
                    return self.findFirstMultiLiteralIgnoreCase(haystack, result.start + 1);
                }
            }
            return result;
        }

        return null;
    }

    fn findLiteralAlternativeAt(
        self: *const Matcher,
        haystack: []const u8,
        start: usize,
        require_boundary: bool,
    ) ?MatchResult {
        const info = self.alternation_info orelse return null;
        for (info.literals) |alternative| {
            if (self.ignore_case) {
                const match = findUnicodeIgnoreCase(haystack, alternative, start) orelse continue;
                if (match.start == start and (!require_boundary or isWordBoundaryMatch(haystack, start, match.end))) return match;
                continue;
            }
            const end = start + alternative.len;
            if (end > haystack.len) continue;
            if (!self.fixedBytesEqual(haystack[start..end], alternative)) continue;
            if (!require_boundary or isWordBoundaryMatch(haystack, start, end)) return .{ .start = start, .end = end };
        }
        return null;
    }

    fn findBoundaryLiteralAlternativeAt(self: *const Matcher, haystack: []const u8, start: usize) ?MatchResult {
        return self.findLiteralAlternativeAt(haystack, start, true);
    }

    /// Get the maximum pattern length (useful for buffer overlap handling)
    pub fn getMaxPatternLen(self: *const Matcher) usize {
        if (self.ac_automaton) |*ac| {
            return ac.getMaxPatternLen();
        }
        if (self.fixed_alternation_info) |info| return info.max_branch_len;
        return self.pattern.len;
    }

    /// Check if a match at the given position satisfies word boundary constraints
    pub fn isWordBoundaryStart(haystack: []const u8, start: usize) bool {
        // A byte-oriented fallback regex can expose offsets inside a UTF-8
        // scalar. Such offsets are never codepoint boundaries and therefore
        // cannot satisfy Unicode-aware `-w` assertions.
        if (start < haystack.len and (haystack[start] & 0xc0) == 0x80) return false;
        return if (start == 0)
            true
        else blk: {
            const previous = decodePrevious(haystack, start);
            break :blk previous.valid and !isWordCodepoint(previous.codepoint);
        };
    }

    pub fn isWordBoundaryEnd(haystack: []const u8, end: usize) bool {
        if (end < haystack.len and (haystack[end] & 0xc0) == 0x80) return false;
        return if (end >= haystack.len)
            true
        else blk: {
            const next = decodeAt(haystack, end);
            break :blk next.valid and !isWordCodepoint(next.codepoint);
        };
    }

    fn isWordBoundaryMatch(haystack: []const u8, start: usize, end: usize) bool {
        return isWordBoundaryStart(haystack, start) and isWordBoundaryEnd(haystack, end);
    }

    pub fn isWordCodepoint(cp: u21) bool {
        return unicode_word.isWord(cp);
    }

    /// Check if the haystack contains a match
    pub fn matches(self: *const Matcher, haystack: []const u8) bool {
        return self.findFirstEndFrom(haystack, 0) != null;
    }

    pub fn supportsFastLineCount(self: *const Matcher) bool {
        return self.is_literal and !self.word_boundary and self.pattern.len >= 1 and
            std.mem.indexOfScalar(u8, self.pattern, '\n') == null and
            std.mem.indexOfScalar(u8, self.pattern, 0) == null and
            (!self.ignore_case or !containsNonAscii(self.pattern));
    }

    pub fn countLiteralLines(self: *const Matcher, data: []const u8, check_nul: bool) ?LineCount {
        if (!self.supportsFastLineCount()) return null;
        if (self.ignore_case and asciiPatternNeedsNonAsciiFold(self.pattern) and containsNonAscii(data)) {
            var count: usize = 0;
            var line_start: usize = 0;
            var binary_offset: ?usize = null;
            while (line_start < data.len) {
                const line_end = line_start + (simd.findNewline(data[line_start..]) orelse (data.len - line_start));
                const line = data[line_start..line_end];
                if (self.findLiteralIgnoreCaseFrom(line, 0) != null) count += 1;
                if (check_nul and binary_offset == null) {
                    if (simd.findByteValue(line, 0)) |nul| binary_offset = line_start + nul;
                }
                if (line_end == data.len) break;
                line_start = line_end + 1;
            }
            return .{ .count = count, .binary_offset = binary_offset };
        }
        const result = simd.countLiteralLines(data, self.pattern, self.ignore_case, check_nul);
        return .{ .count = result.count, .binary_offset = result.binary_offset };
    }

    pub fn shouldFuseLiteralLineCount(self: *const Matcher, data: []const u8) bool {
        return self.supportsFastLineCount() and
            simd.shouldFuseLiteralLineCount(data, self.pattern, self.ignore_case);
    }

    pub fn supportsFastMultiLiteralLineCount(self: *const Matcher) bool {
        const info = self.alternation_info orelse return false;
        if (!self.is_multi_literal or !self.ignore_case or self.word_boundary or !info.ascii_only) return false;
        for (info.literals) |alternative| {
            if (alternative.len == 0 or std.mem.indexOfScalar(u8, alternative, '\n') != null or
                std.mem.indexOfScalar(u8, alternative, 0) != null) return false;
        }
        return true;
    }

    pub fn countMultiLiteralLines(self: *const Matcher, data: []const u8, check_nul: bool) ?LineCount {
        if (!self.supportsFastMultiLiteralLineCount()) return null;
        const info = self.alternation_info.?;
        const fold_needs = specialFoldNeeds(info.literals);
        const needs_fold_probe = fold_needs.kelvin or fold_needs.long_s;
        var has_special_fold = false;
        const Probe = struct {
            fn run(bytes: []const u8, needs: SpecialFoldNeeds, result: *bool) void {
                result.* = simd.containsSpecialFold(bytes, needs.kelvin, needs.long_s);
            }
        };
        const probe_thread: ?std.Thread = if (check_nul and needs_fold_probe and data.len >= 1024 * 1024)
            std.Thread.spawn(
                .{ .stack_size = 64 * 1024 },
                Probe.run,
                .{ data, fold_needs, &has_special_fold },
            ) catch null
        else
            null;

        if (probe_thread == null and needs_fold_probe) {
            has_special_fold = simd.containsSpecialFold(data, fold_needs.kelvin, fold_needs.long_s);
        }
        const initial_unicode_folds = if (probe_thread != null) false else has_special_fold;
        const ascii_result = self.countMultiLiteralLinesWithMode(data, check_nul, initial_unicode_folds);
        if (probe_thread) |thread| {
            thread.join();
            if (has_special_fold) return self.countMultiLiteralLinesWithMode(data, check_nul, true);
        }
        return ascii_result;
    }

    fn countMultiLiteralLinesWithMode(
        self: *const Matcher,
        data: []const u8,
        check_nul: bool,
        unicode_folds: bool,
    ) LineCount {
        var count: usize = 0;
        var search_pos: usize = 0;
        var binary_offset: ?usize = null;
        while (search_pos < data.len) {
            const match = if (!unicode_folds)
                self.findMultiLiteralAsciiIgnoreCase(data, search_pos) orelse break
            else
                self.findFirstMultiLiteral(data, search_pos) orelse break;
            count += 1;
            const line_end = match.end + (simd.findNewline(data[match.end..]) orelse (data.len - match.end));
            if (check_nul and binary_offset == null) {
                const line_start = if (std.mem.lastIndexOfScalar(u8, data[0..match.start], '\n')) |newline|
                    newline + 1
                else
                    0;
                if (simd.findByteValue(data[line_start..line_end], 0)) |nul| binary_offset = line_start + nul;
            }
            if (line_end == data.len) break;
            search_pos = line_end + 1;
        }
        return .{
            .count = count,
            .binary_offset = binary_offset,
        };
    }

    pub fn supportsFastRegexLineCount(self: *const Matcher) bool {
        if (self.is_literal or self.is_multi_literal or self.fixed_alternation_info != null) return false;
        if (self.regex_engine) |*re| {
            return if (self.word_boundary) re.supportsFastWordLineCount() else re.supportsFastLineCount();
        }
        return false;
    }

    pub fn countRegexLines(self: *const Matcher, data: []const u8, check_nul: bool) ?LineCount {
        if (!self.supportsFastRegexLineCount()) return null;
        if (self.regex_engine) |*re| {
            return if (self.word_boundary)
                re.countWordMatchingLines(data, check_nul)
            else
                re.countMatchingLines(data, check_nul);
        }
        return null;
    }

    fn findLiteralInFrom(self: *const Matcher, haystack: []const u8, start_offset: usize) ?MatchResult {
        if (self.ignore_case) {
            return self.findLiteralIgnoreCaseFrom(haystack, start_offset);
        }

        // Use SIMD-accelerated search for literal patterns
        if (simd.findSubstringFrom(haystack, self.pattern, start_offset)) |pos| {
            return MatchResult{
                .start = pos,
                .end = pos + self.pattern.len,
            };
        }
        return null;
    }

    fn findLiteralIgnoreCaseFrom(self: *const Matcher, haystack: []const u8, start_offset: usize) ?MatchResult {
        const lower_pat = self.lower_pattern orelse return null;

        if (containsNonAscii(self.pattern) or !std.unicode.utf8ValidateSlice(self.pattern) or
            (asciiPatternNeedsNonAsciiFold(self.pattern) and containsNonAscii(haystack[start_offset..])))
        {
            return findUnicodeIgnoreCase(haystack, self.pattern, start_offset);
        }

        if (simd.findSubstringFromIgnoreCase(haystack, lower_pat, start_offset)) |i| {
            return MatchResult{
                .start = i,
                .end = i + lower_pat.len,
            };
        }
        return null;
    }

    const Decoded = struct { codepoint: u21, len: usize, valid: bool };

    fn containsNonAscii(bytes: []const u8) bool {
        return simd.findNonAscii(bytes) != null;
    }

    fn asciiPatternNeedsNonAsciiFold(bytes: []const u8) bool {
        // Unicode simple folding adds non-ASCII members only to the ASCII K
        // (Kelvin sign) and S (long s) equivalence classes.
        for (bytes) |byte| switch (std.ascii.toLower(byte)) {
            'k', 's' => return true,
            else => {},
        };
        return false;
    }

    fn patternsNeedNonAsciiFold(patterns: []const []const u8) bool {
        for (patterns) |pattern| if (asciiPatternNeedsNonAsciiFold(pattern)) return true;
        return false;
    }

    const SpecialFoldNeeds = struct { kelvin: bool = false, long_s: bool = false };

    fn specialFoldNeeds(patterns: []const []const u8) SpecialFoldNeeds {
        var needs = SpecialFoldNeeds{};
        for (patterns) |pattern| {
            for (pattern) |byte| switch (std.ascii.toLower(byte)) {
                'k' => needs.kelvin = true,
                's' => needs.long_s = true,
                else => {},
            };
        }
        return needs;
    }

    fn decodeAt(bytes: []const u8, pos: usize) Decoded {
        if (pos >= bytes.len) return .{ .codepoint = 0, .len = 0, .valid = false };
        const len = std.unicode.utf8ByteSequenceLength(bytes[pos]) catch
            return .{ .codepoint = bytes[pos], .len = 1, .valid = false };
        if (pos + len > bytes.len) return .{ .codepoint = bytes[pos], .len = 1, .valid = false };
        const cp = std.unicode.utf8Decode(bytes[pos..][0..len]) catch
            return .{ .codepoint = bytes[pos], .len = 1, .valid = false };
        return .{ .codepoint = cp, .len = len, .valid = true };
    }

    fn decodePrevious(bytes: []const u8, end: usize) Decoded {
        var pos = end - 1;
        while (pos > 0 and (bytes[pos] & 0xc0) == 0x80) pos -= 1;
        const decoded = decodeAt(bytes, pos);
        if (!decoded.valid or pos + decoded.len != end) {
            return .{ .codepoint = bytes[end - 1], .len = 1, .valid = false };
        }
        return decoded;
    }

    fn retreatValidScalars(bytes: []const u8, end: usize, count: usize, floor: usize) ?usize {
        var pos = end;
        for (0..count) |_| {
            if (pos <= floor) return null;
            const decoded = decodePrevious(bytes, pos);
            if (!decoded.valid) return null;
            pos -= decoded.len;
        }
        return pos;
    }

    pub fn simpleFoldCodepoint(cp: u21) u21 {
        return unicode_case.canonical(cp);
    }

    pub fn foldedPrefixLen(haystack: []const u8, needle: []const u8) ?usize {
        var hi: usize = 0;
        var ni: usize = 0;
        while (ni < needle.len) {
            if (hi >= haystack.len) return null;
            const hc = decodeAt(haystack, hi);
            const nc = decodeAt(needle, ni);
            if (!hc.valid or !nc.valid) return null;
            if (simpleFoldCodepoint(hc.codepoint) != simpleFoldCodepoint(nc.codepoint)) return null;
            hi += hc.len;
            ni += nc.len;
        }
        return hi;
    }

    pub fn findUnicodeIgnoreCase(haystack: []const u8, needle: []const u8, start_offset: usize) ?MatchResult {
        var pos = start_offset;
        while (pos < haystack.len and (haystack[pos] & 0xc0) == 0x80) pos += 1;
        while (pos < haystack.len) {
            if (foldedPrefixLen(haystack[pos..], needle)) |len| {
                return .{ .start = pos, .end = pos + len };
            }
            pos += decodeAt(haystack, pos).len;
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

test "fixed alternation directly verifies wildcard branches" {
    const allocator = std.testing.allocator;
    var m = try Matcher.init(allocator, ".alpha|be..ta|omega.", false, false);
    defer m.deinit();

    try std.testing.expect(m.fixed_alternation_info != null);
    try std.testing.expect(m.regex_engine == null);
    try std.testing.expectEqual(MatchResult{ .start = 2, .end = 8 }, m.findFirst("xxZalpha be12ta").?);
    try std.testing.expectEqual(MatchResult{ .start = 0, .end = 6 }, m.findFirst("omega!").?);
    try std.testing.expect(!m.matches("xx\nalpha"));
}

test "fixed alternation is case insensitive" {
    const allocator = std.testing.allocator;
    var m = try Matcher.init(allocator, "Mrs. Hudson|John Watson", true, false);
    defer m.deinit();

    try std.testing.expectEqual(MatchResult{ .start = 2, .end = 13 }, m.findFirst("xxMRS! HUDSON").?);
    try std.testing.expectEqual(MatchResult{ .start = 3, .end = 14 }, m.findFirst("xx john watson").?);
}

test "fixed Unicode alternation folds literals and dot consumes a codepoint" {
    const allocator = std.testing.allocator;
    var m = try Matcher.init(allocator, "École.|Δelta.", true, false);
    defer m.deinit();

    try std.testing.expectEqual(MatchResult{ .start = 2, .end = 9 }, m.findFirst("xxéCOLE!").?);
    try std.testing.expectEqual(MatchResult{ .start = 0, .end = 9 }, m.findFirst("δELTA界").?);
    try std.testing.expect(!m.matches("école\n"));
}

test "fixed alternation Teddy verifies wildcard branches" {
    const allocator = std.testing.allocator;
    const pattern = "Sherlock Holmes|John Watson|Professor Moriarty|Mrs. Hudson";
    var m = try Matcher.init(allocator, pattern, false, false);
    defer m.deinit();

    try std.testing.expect(m.fixed_teddy_plan != null);
    try std.testing.expectEqual(MatchResult{ .start = 2, .end = 13 }, m.findFirst("xxMrs! Hudson").?);
    try std.testing.expect(!m.matches("Mrs\n Hudson"));
}

test "fixed alternation preserves leftmost branch priority" {
    const allocator = std.testing.allocator;

    var earlier = try Matcher.init(allocator, ".needle|first", false, false);
    defer earlier.deinit();
    try std.testing.expectEqual(MatchResult{ .start = 0, .end = 7 }, earlier.findFirst("xneedle first").?);

    var priority = try Matcher.init(allocator, "ab..|ab.", false, false);
    defer priority.deinit();
    try std.testing.expectEqual(MatchResult{ .start = 0, .end = 4 }, priority.findFirst("abXY").?);
}

test "word boundary alternations consider every branch at one start" {
    const allocator = std.testing.allocator;

    var literals = try Matcher.init(allocator, "a|ab", false, true);
    defer literals.deinit();
    try std.testing.expectEqual(MatchResult{ .start = 0, .end = 2 }, literals.findFirst("ab ").?);

    var fixed = try Matcher.init(allocator, "abc.|abc|def.|ghi.", false, true);
    defer fixed.deinit();
    try std.testing.expectEqual(MatchResult{ .start = 0, .end = 3 }, fixed.findFirst("abc!x").?);
}

test "case insensitive Unicode alternation" {
    const allocator = std.testing.allocator;
    var matcher = try Matcher.init(allocator, "École|Δelta", true, false);
    defer matcher.deinit();

    try std.testing.expectEqual(MatchResult{ .start = 2, .end = 8 }, matcher.findFirst("xxéCOLE yy").?);
    try std.testing.expect(matcher.matches("δELTA"));
}

test "line terminators require an unsupported multiline mode" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.NewlineNotAllowed, Matcher.init(allocator, "a\nb", false, false));
    try std.testing.expectError(error.NewlineNotAllowed, Matcher.init(allocator, "a\\nb", false, false));

    var escaped_backslash = try Matcher.init(allocator, "a\\\\nb", false, false);
    defer escaped_backslash.deinit();
    try std.testing.expect(escaped_backslash.matches("a\\nb"));
}

test "regex existence search avoids greedy span recovery" {
    const allocator = std.testing.allocator;
    var m = try Matcher.init(allocator, "alpha.*delta", false, false);
    defer m.deinit();

    const input = "alpha first delta then delta";
    try std.testing.expectEqual(@as(?usize, 17), m.findFirstEndFrom(input, 0));
    try std.testing.expectEqual(@as(usize, input.len), m.findFirst(input).?.end);
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

test "word boundary with .* prefix pattern" {
    const allocator = std.testing.allocator;

    // Pattern .*_cache with word boundary - should find first valid word boundary match
    var m = try Matcher.init(allocator, ".*_cache", false, true);
    defer m.deinit();

    // For .*SUFFIX patterns, the match STARTS at position 0 (beginning of line).
    // Word boundary check: start=0 is word boundary (beginning of string), end depends on suffix.
    // "x_cache " - match from 0 to 7, end boundary: char at 7 is ' ' (non-word) = valid!
    const input = "x_cache foo_cache bar_cache_baz";

    // Greedy `.*` extends through the last suffix whose end is a valid word
    // boundary, matching ripgrep's boundary-aware span selection.
    const result = m.findFirst(input);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?.start);
    try std.testing.expectEqual(@as(usize, 17), result.?.end);
}

test "word boundary with .* prefix finds match at end of string" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, ".*_suffix", false, true);
    defer m.deinit();

    // For greedy .*, it matches up to the LAST _suffix
    // The last _suffix ends at position 26 (end of string = word boundary)
    // Word boundary check: start=0 (OK), end=26 (end of string = OK)
    const input = "x_suffix_more text._suffix";

    const result = m.findFirst(input);
    try std.testing.expect(result != null);
    // Should match ending at the last _suffix (position 26 = end of string)
    try std.testing.expectEqual(@as(usize, 26), result.?.end);
}

test "word boundary .* pattern with all non-boundary occurrences" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, ".*_cache", false, true);
    defer m.deinit();

    // All _cache occurrences have word characters adjacent
    const input = "x_cache_y a_cache_b";

    // Should NOT match since no _cache is at a word boundary
    try std.testing.expect(m.findFirst(input) == null);
}

test "word boundary .* pattern skips early non-boundary to find later valid match" {
    const allocator = std.testing.allocator;

    // This test validates the fix for the bug where .*_cache with -w failed
    // to find matches in long lines. The issue was that the greedy .* would
    // match to the LAST _cache occurrence, and if that didn't satisfy word
    // boundary, we'd skip past ALL _cache occurrences and return no match.
    //
    // The fix returns matches ending at EACH _cache occurrence in turn,
    // allowing word boundary validation to try each one.

    var m = try Matcher.init(allocator, ".*_cache", false, true);
    defer m.deinit();

    // Multiple _cache occurrences (verified with Python re.finditer):
    // - _cache at 1-7, next char: '_' (not word boundary)
    // - _cache at 10-16, next char: '_' (not word boundary)
    // - _cache at 19-25, next char: ' ' (VALID word boundary!)
    // - _cache at 27-33, next char: '_' (not word boundary)
    const input = "a_cache_ b_cache_ c_cache d_cache_x";

    const result = m.findFirst(input);
    try std.testing.expect(result != null);
    // Should find match ending at "c_cache" (position 25) - the first with valid word boundary
    try std.testing.expectEqual(@as(usize, 0), result.?.start);
    try std.testing.expectEqual(@as(usize, 25), result.?.end);
}

test "word boundary with CJK ideographs" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "cache", false, true);
    defer m.deinit();

    // CJK ideographs are word characters - should NOT match when surrounded by Chinese
    try std.testing.expect(!m.matches("硬件cache更小")); // Chinese: "hardware cache smaller"
    try std.testing.expect(!m.matches("硬件cache")); // cache at end after Chinese
    try std.testing.expect(!m.matches("cache更小")); // cache at start before Chinese

    // Japanese hiragana - should NOT match
    try std.testing.expect(!m.matches("あcacheい"));

    // But should match when there's whitespace
    try std.testing.expect(m.matches("硬件 cache 更小"));
    try std.testing.expect(m.matches("硬件 cache"));
    try std.testing.expect(m.matches("cache 更小"));
}

test "word boundary with CJK punctuation" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "cache", false, true);
    defer m.deinit();

    // Unicode punctuation creates word boundaries just like ASCII punctuation.
    try std.testing.expect(m.matches("test、cache")); // ideographic comma U+3001
    try std.testing.expect(m.matches("test。cache")); // ideographic full stop U+3002
    try std.testing.expect(m.matches("test「cache")); // left corner bracket U+300C
    try std.testing.expect(m.matches("test，cache")); // fullwidth comma U+FF0C
    try std.testing.expect(m.matches("test：cache")); // fullwidth colon U+FF1A

    // ASCII punctuation still works correctly
    try std.testing.expect(m.matches("test,cache")); // ASCII comma - DOES match
    try std.testing.expect(m.matches("test.cache")); // ASCII period - DOES match
}

test "Unicode literal simple case folding" {
    const allocator = std.testing.allocator;
    var m = try Matcher.init(allocator, "école", true, false);
    defer m.deinit();

    const result = m.findFirst("Une ÉCOLE").?;
    try std.testing.expectEqual(@as(usize, 4), result.start);
    try std.testing.expectEqual(@as(usize, 10), result.end);
}

test "word boundary with mixed ASCII and UTF-8" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "foo", false, true);
    defer m.deinit();

    // UTF-8 continuation bytes should be treated as word chars
    // This prevents false matches when ASCII appears inside multibyte sequences
    try std.testing.expect(!m.matches("日foo本")); // Japanese: should NOT match
    try std.testing.expect(m.matches("日 foo 本")); // With spaces: should match
}

// =============================================================================
// Multi-literal Alternation Tests (Aho-Corasick)
// =============================================================================

test "multi-literal alternation basic" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "foo|bar|baz", false, false);
    defer m.deinit();

    try std.testing.expect(m.is_multi_literal);
    try std.testing.expect(m.ac_automaton != null);
    try std.testing.expect(m.matches("foo"));
    try std.testing.expect(m.matches("bar"));
    try std.testing.expect(m.matches("baz"));
    try std.testing.expect(m.matches("hello foo world"));
    try std.testing.expect(m.matches("hello bar world"));
    try std.testing.expect(!m.matches("hello world"));
}

test "multi-literal alternation benchmark pattern" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT", false, false);
    defer m.deinit();

    try std.testing.expect(m.is_multi_literal);
    try std.testing.expect(m.matches("test ERR_SYS here"));
    try std.testing.expect(m.matches("test PME_TURN_OFF here"));
    try std.testing.expect(m.matches("test LINK_REQ_RST here"));
    try std.testing.expect(m.matches("test CFG_BME_EVT here"));
    try std.testing.expect(!m.matches("test NO_MATCH here"));
}

test "multi-literal alternation findFirst position" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "foo|bar", false, false);
    defer m.deinit();

    const result1 = m.findFirst("hello foo world");
    try std.testing.expect(result1 != null);
    try std.testing.expectEqual(@as(usize, 6), result1.?.start);
    try std.testing.expectEqual(@as(usize, 9), result1.?.end);

    const result2 = m.findFirst("hello bar world");
    try std.testing.expect(result2 != null);
    try std.testing.expectEqual(@as(usize, 6), result2.?.start);
    try std.testing.expectEqual(@as(usize, 9), result2.?.end);
}

test "multi-literal alternation finds earliest match" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "bar|foo", false, false);
    defer m.deinit();

    // "foo" appears first in the string, should be found first regardless of pattern order
    const result = m.findFirst("hello foo bar");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 6), result.?.start);
}

test "multi-literal alternation with word boundary" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "foo|bar", false, true);
    defer m.deinit();

    try std.testing.expect(m.matches("foo bar"));
    try std.testing.expect(m.matches("hello foo"));
    try std.testing.expect(!m.matches("foobar")); // "foo" not at word boundary
    try std.testing.expect(!m.matches("barfoo")); // "bar" not at word boundary
}

test "multi-literal max pattern length" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "a|abc|abcdefghij", false, false);
    defer m.deinit();

    try std.testing.expectEqual(@as(usize, 10), m.getMaxPatternLen());
}

test "multi-literal case insensitive small haystack" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "FOO|BAR", true, false);
    defer m.deinit();

    try std.testing.expect(m.matches("hello foo world"));
    try std.testing.expect(m.matches("hello FOO world"));
    try std.testing.expect(m.matches("hello FoO world"));
    try std.testing.expect(m.matches("hello bar world"));
    try std.testing.expect(m.matches("hello BAR world"));
}

// =============================================================================
// Additional Multi-literal Tests
// =============================================================================

test "multi-literal alternation position tracking" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "ERR|WARN|INFO", false, false);
    defer m.deinit();

    // Test findFirst returns correct positions
    const result1 = m.findFirst("some ERR message");
    try std.testing.expect(result1 != null);
    try std.testing.expectEqual(@as(usize, 5), result1.?.start);
    try std.testing.expectEqual(@as(usize, 8), result1.?.end);

    const result2 = m.findFirst("some WARN message");
    try std.testing.expect(result2 != null);
    try std.testing.expectEqual(@as(usize, 5), result2.?.start);
    try std.testing.expectEqual(@as(usize, 9), result2.?.end);

    const result3 = m.findFirst("some INFO message");
    try std.testing.expect(result3 != null);
    try std.testing.expectEqual(@as(usize, 5), result3.?.start);
    try std.testing.expectEqual(@as(usize, 9), result3.?.end);
}

test "multi-literal alternation finds earliest match regardless of pattern order" {
    const allocator = std.testing.allocator;

    // Pattern order shouldn't affect which match is found first
    var m = try Matcher.init(allocator, "WARN|ERR|INFO", false, false);
    defer m.deinit();

    // ERR appears first in the string
    const result = m.findFirst("test ERR then WARN then INFO");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 5), result.?.start);
    try std.testing.expectEqual(@as(usize, 8), result.?.end);
}

test "multi-literal with word boundary skips embedded matches" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "ERR|WARN", false, true);
    defer m.deinit();

    // "ERROR" contains "ERR" but not at word boundary
    try std.testing.expect(!m.matches("ERROR"));
    try std.testing.expect(!m.matches("WARNING"));

    // But standalone should match
    try std.testing.expect(m.matches("ERR"));
    try std.testing.expect(m.matches("WARN"));
    try std.testing.expect(m.matches("test ERR here"));
    try std.testing.expect(m.matches("test WARN here"));
}

test "multi-literal case insensitive with word boundary" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "foo|bar", true, true);
    defer m.deinit();

    // Should match case-insensitive at word boundaries
    try std.testing.expect(m.matches("FOO bar"));
    try std.testing.expect(m.matches("foo BAR"));
    try std.testing.expect(m.matches("test FOO test"));
    try std.testing.expect(m.matches("test Bar test"));

    // Should NOT match when not at word boundary
    try std.testing.expect(!m.matches("FOOBAR"));
    try std.testing.expect(!m.matches("testFOOtest"));
}

test "multi-literal no match returns null" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "xyz|abc|def", false, false);
    defer m.deinit();

    try std.testing.expect(m.findFirst("hello world") == null);
    try std.testing.expect(!m.matches("hello world"));
}

test "multi-literal empty haystack" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "foo|bar", false, false);
    defer m.deinit();

    try std.testing.expect(m.findFirst("") == null);
    try std.testing.expect(!m.matches(""));
}

test "multi-literal single character alternatives" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "a|b|c", false, false);
    defer m.deinit();

    try std.testing.expect(m.matches("a"));
    try std.testing.expect(m.matches("b"));
    try std.testing.expect(m.matches("c"));
    try std.testing.expect(m.matches("xyz a xyz"));
    try std.testing.expect(!m.matches("xyz"));
}

test "multi-literal mixed length patterns" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "a|abc|abcdef", false, false);
    defer m.deinit();

    // Should find match even with mixed lengths
    try std.testing.expect(m.matches("abcdef"));
    try std.testing.expect(m.matches("abc"));
    try std.testing.expect(m.matches("a"));
}

test "multi-literal special characters preserved" {
    const allocator = std.testing.allocator;

    // Underscores and numbers are literal, not regex
    var m = try Matcher.init(allocator, "ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT", false, false);
    defer m.deinit();

    try std.testing.expect(m.is_multi_literal);
    try std.testing.expect(m.matches("test ERR_SYS here"));
    try std.testing.expect(m.matches("test PME_TURN_OFF here"));
    try std.testing.expect(m.matches("test LINK_REQ_RST here"));
    try std.testing.expect(m.matches("test CFG_BME_EVT here"));
    try std.testing.expect(!m.matches("test ERR_OTHER here"));
}

test "multi-literal vs regex fallback" {
    const allocator = std.testing.allocator;

    // Pure literals should use AC
    {
        var m = try Matcher.init(allocator, "foo|bar", false, false);
        defer m.deinit();
        try std.testing.expect(m.is_multi_literal);
        try std.testing.expect(m.ac_automaton != null);
        try std.testing.expect(m.regex_engine == null);
    }

    // Pattern with regex metachar should NOT use AC
    {
        var m = try Matcher.init(allocator, "foo.*|bar", false, false);
        defer m.deinit();
        try std.testing.expect(!m.is_multi_literal);
        try std.testing.expect(m.ac_automaton == null);
        try std.testing.expect(m.regex_engine != null);
    }
}

test "multi-literal case insensitive position" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "FOO|BAR", true, false);
    defer m.deinit();

    // Check positions are correct for case-insensitive matches
    const result = m.findFirst("test foo here");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 5), result.?.start);
    try std.testing.expectEqual(@as(usize, 8), result.?.end);
}

test "multi-literal overlapping patterns in haystack" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "ab|bc", false, false);
    defer m.deinit();

    // "abc" contains both "ab" and "bc" overlapping
    const result1 = m.findFirst("xabcx");
    try std.testing.expect(result1 != null);
    try std.testing.expectEqual(@as(usize, 1), result1.?.start);
}

test "multi-literal consecutive matches" {
    const allocator = std.testing.allocator;

    var m = try Matcher.init(allocator, "aa|bb", false, false);
    defer m.deinit();

    // Test that we can find multiple consecutive matches
    try std.testing.expect(m.matches("aabb"));
    try std.testing.expect(m.matches("bbaa"));

    const result = m.findFirst("aabb");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?.start);
}

test "fixed alternation dots consume Unicode scalars" {
    const allocator = std.testing.allocator;

    var matcher = try Matcher.init(allocator, "foo..|bar..", false, false);
    defer matcher.deinit();
    try std.testing.expect(matcher.fixed_alternation_info != null);
    try std.testing.expect(matcher.findFirst("foo界") == null);
    try std.testing.expectEqual(MatchResult{ .start = 0, .end = 7 }, matcher.findFirst("foo界x").?);
    try std.testing.expect(matcher.findFirst("foo\xffx") == null);
}

test "whole-word matches reject adjacent malformed UTF-8" {
    const allocator = std.testing.allocator;

    var matcher = try Matcher.init(allocator, "k|foo", true, true);
    defer matcher.deinit();
    try std.testing.expect(!matcher.matches("\xffK"));
    try std.testing.expect(!matcher.matches("K\xfe"));
    try std.testing.expect(!matcher.matches(".\x80foo"));
    try std.testing.expect(!matcher.matches("foo\xc0\xaf"));
    try std.testing.expect(matcher.matches(".K!"));
    try std.testing.expect(matcher.matches(" foo "));
}

test "case-insensitive alternations search Unicode folds only where needed" {
    const allocator = std.testing.allocator;

    var matcher = try Matcher.init(allocator, "k|foo", true, false);
    defer matcher.deinit();
    try std.testing.expectEqual(MatchResult{ .start = 4, .end = 7 }, matcher.findFirst("abc K then foo").?);
    try std.testing.expectEqual(MatchResult{ .start = 7, .end = 10 }, matcher.findFirst("αβγ foo K").?);
    try std.testing.expectEqual(MatchResult{ .start = 0, .end = 3 }, matcher.findFirst("foo αβγ K").?);
}

test "case-insensitive alternation line count falls back for Unicode folds" {
    const allocator = std.testing.allocator;

    var matcher = try Matcher.init(allocator, "k|foo", true, false);
    defer matcher.deinit();
    const result = matcher.countMultiLiteralLines("none\x00\nK\nfoo\x00\nno\n", true).?;
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqual(@as(?usize, 13), result.binary_offset);
}
