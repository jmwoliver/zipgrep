const std = @import("std");

/// Information about an extracted literal from a regex pattern
pub const LiteralInfo = struct {
    /// The extracted literal string (points to pattern_storage)
    literal: []const u8,
    /// Where in the pattern the literal appears
    position: Position,
    /// Minimum characters before this literal can appear (for inner literals)
    min_offset: usize,

    pub const Position = enum {
        prefix, // At start of pattern - most efficient
        suffix, // At end of pattern - second best
        inner, // Middle of pattern - least efficient but still helps
    };
};

/// Extract the best literal from a regex pattern for SIMD pre-filtering.
/// Returns null if no useful literal can be extracted.
///
/// Priority order:
/// 1. Prefix literals (most efficient - can start search there)
/// 2. Suffix literals (second best - search backwards or verify end)
/// 3. Inner literals (still helps - quick reject lines without the literal)
pub fn extractBestLiteral(pattern: []const u8) ?LiteralInfo {
    // A literal from only one alternation branch is not required. The matcher
    // has dedicated exact handling for flat literal/fixed-width alternatives;
    // all other alternations conservatively skip this line-level prefilter.
    var escaped = false;
    var has_counted_repetition = false;
    for (pattern) |byte| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (byte == '\\') {
            escaped = true;
        } else if (byte == '|') {
            return null;
        } else if (byte == '{') {
            has_counted_repetition = true;
        }
    }

    // An exact repeated pure-literal group always starts at one occurrence of
    // that literal. This makes `(ab){2,}` as filterable as a normal prefix
    // while the regex engine still verifies the repetition count.
    if (extractCountedGroupLiteral(pattern)) |group| {
        return .{ .literal = group.literal, .position = .prefix, .min_offset = 0 };
    }

    // Try prefix first (most efficient)
    if (extractLiteralPrefix(pattern)) |prefix| {
        // For a separated `prefix.*suffix`, both literals are required. Prefer
        // an equally selective suffix: it avoids verifying every occurrence
        // of a common prefix when the suffix is absent, while retaining the
        // prefix for patterns where its score is clearly stronger.
        if (std.mem.indexOf(u8, pattern, ".*") != null) {
            if (extractLiteralSuffix(pattern)) |suffix| {
                if (scoreLiteral(suffix) >= scoreLiteral(prefix)) {
                    return LiteralInfo{
                        .literal = suffix,
                        .position = .suffix,
                        .min_offset = 0,
                    };
                }
            }
        }
        return LiteralInfo{
            .literal = prefix,
            .position = .prefix,
            .min_offset = 0,
        };
    }

    // Prefix extraction above explicitly excludes an optionally repeated last
    // byte. More general counted forms need structural literal analysis before
    // a suffix/inner substring can safely be called required.
    if (has_counted_repetition) return null;

    // Try suffix second
    if (extractLiteralSuffix(pattern)) |suffix| {
        return LiteralInfo{
            .literal = suffix,
            .position = .suffix,
            .min_offset = 0,
        };
    }

    // Try inner literals
    return extractBestInnerLiteral(pattern);
}

pub const CountedGroupLiteral = struct {
    literal: []const u8,
    minimum: usize,
    maximum: ?usize,
};

pub fn extractCountedGroupLiteral(pattern: []const u8) ?CountedGroupLiteral {
    if (pattern.len < 7 or pattern[0] != '(') return null;
    const close = std.mem.indexOfScalar(u8, pattern, ')') orelse return null;
    const group = pattern[1..close];
    if (group.len < 2 or close + 3 >= pattern.len or pattern[close + 1] != '{' or pattern[pattern.len - 1] != '}') return null;
    for (group) |byte| if (isMetachar(byte)) return null;

    var pos = close + 2;
    if (pos >= pattern.len or !std.ascii.isDigit(pattern[pos])) return null;
    var minimum: usize = 0;
    while (pos < pattern.len and std.ascii.isDigit(pattern[pos])) : (pos += 1) {
        minimum = std.math.mul(usize, minimum, 10) catch return null;
        minimum = std.math.add(usize, minimum, pattern[pos] - '0') catch return null;
    }
    if (minimum == 0 or pos >= pattern.len) return null;
    var maximum: ?usize = minimum;
    if (pattern[pos] == ',') {
        pos += 1;
        if (pos == pattern.len - 1) {
            maximum = null;
        } else {
            var parsed_maximum: usize = 0;
            while (pos < pattern.len and std.ascii.isDigit(pattern[pos])) : (pos += 1) {
                parsed_maximum = std.math.mul(usize, parsed_maximum, 10) catch return null;
                parsed_maximum = std.math.add(usize, parsed_maximum, pattern[pos] - '0') catch return null;
            }
            if (parsed_maximum < minimum) return null;
            maximum = parsed_maximum;
        }
    }
    if (pos != pattern.len - 1) return null;
    return .{ .literal = group, .minimum = minimum, .maximum = maximum };
}

/// Extract literal prefix from a regex pattern (before any metacharacters)
/// The prefix must be "required" - i.e., not followed by a quantifier that allows zero matches
/// NOTE: This only works for patterns without alternation at the top level, and without escapes
/// For patterns with escapes or alternation, we return null to fall back to suffix/inner extraction
fn extractLiteralPrefix(pattern: []const u8) ?[]const u8 {
    if (pattern.len == 0) return null;

    // Check if pattern contains alternation at top level - can't extract prefix
    // (would need to check if ALL alternatives share the prefix)
    var paren_depth: usize = 0;
    for (pattern) |c| {
        switch (c) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '|' => {
                if (paren_depth == 0) return null; // Top-level alternation
            },
            else => {},
        }
    }

    const literal_start: usize = if (pattern[0] == '^') 1 else 0;
    var end: usize = literal_start;
    var i: usize = literal_start;

    while (i < pattern.len) {
        const c = pattern[i];
        switch (c) {
            // Metacharacters that end literal prefix
            '.', '*', '+', '?', '[', ']', '(', ')', '{', '}', '|', '^', '$' => break,
            '\\' => {
                // Escaped characters are tricky - the literal includes the backslash
                // but the actual match is the escaped char. Stop here.
                break;
            },
            else => {
                // Check if this char is followed by * or ? (makes it optional)
                if (i + 1 < pattern.len and (pattern[i + 1] == '*' or
                    pattern[i + 1] == '?' or countedRepeatCanBeEmpty(pattern, i + 1)))
                {
                    // This char is optional, can't include it in required prefix
                    break;
                }
                end = i + 1;
                i += 1;
            },
        }
    }

    // Need at least 2 characters for useful prefix
    if (end - literal_start >= 2) {
        return pattern[literal_start..end];
    }
    return null;
}

fn countedRepeatCanBeEmpty(pattern: []const u8, start: usize) bool {
    if (start >= pattern.len or pattern[start] != '{') return false;
    var pos = start + 1;
    if (pos >= pattern.len or !std.ascii.isDigit(pattern[pos])) return false;
    var minimum: usize = 0;
    while (pos < pattern.len and std.ascii.isDigit(pattern[pos])) : (pos += 1) {
        minimum = std.math.mul(usize, minimum, 10) catch return false;
        minimum = std.math.add(usize, minimum, pattern[pos] - '0') catch return false;
    }
    if (pos >= pattern.len or (pattern[pos] != '}' and pattern[pos] != ',')) return false;
    return minimum == 0;
}

/// Extract literal suffix from a regex pattern (after any metacharacters)
/// NOTE: For patterns with top-level alternation, returns null
fn extractLiteralSuffix(pattern: []const u8) ?[]const u8 {
    if (pattern.len == 0) return null;

    // Check if pattern contains alternation at top level - can't extract suffix
    var paren_depth: usize = 0;
    for (pattern) |c| {
        switch (c) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '|' => {
                if (paren_depth == 0) return null; // Top-level alternation
            },
            else => {},
        }
    }

    // Scan backwards from end to find where suffix starts
    var suffix_start: usize = pattern.len;
    var i: usize = pattern.len;

    while (i > 0) {
        i -= 1;
        const c = pattern[i];

        switch (c) {
            // Metacharacters that end the suffix search
            '.', '*', '+', '?', '[', ']', '(', ')', '{', '}', '|', '^', '$' => {
                // Found metachar - suffix starts after it
                suffix_start = i + 1;
                break;
            },
            '\\' => {
                // This is an escape - the actual character is pattern[i+1]
                // Can't use escaped chars in suffix reliably (would need to decode)
                suffix_start = i + 2; // Skip the entire escape sequence
                break;
            },
            else => {
                // Regular character - continue scanning backwards
            },
        }
    }

    // If we scanned all the way back, there's no prefix metachar
    // In that case, the whole pattern is literal (should have been caught by prefix extraction)
    if (i == 0 and suffix_start == pattern.len) {
        return null;
    }

    const suffix_len = pattern.len - suffix_start;

    // Need at least 2 characters for useful suffix
    if (suffix_len >= 2) {
        return pattern[suffix_start..];
    }
    return null;
}

/// Extract the best inner literal from a regex pattern
/// Only extracts literals that are REQUIRED (not followed by * or ?)
/// NOTE: For patterns with top-level alternation, returns null (can't guarantee literal is required)
fn extractBestInnerLiteral(pattern: []const u8) ?LiteralInfo {
    if (pattern.len < 4) return null; // Need room for metachar + literal + metachar

    // Check if pattern contains alternation at top level - can't extract inner literal
    var paren_depth: usize = 0;
    for (pattern) |c| {
        switch (c) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '|' => {
                if (paren_depth == 0) return null; // Top-level alternation
            },
            else => {},
        }
    }

    var best_literal: ?[]const u8 = null;
    var best_score: u32 = 0;
    var best_min_offset: usize = 0;

    var i: usize = 0;
    var literal_start: ?usize = null;
    var min_chars_before: usize = 0;

    while (i < pattern.len) {
        const c = pattern[i];

        if (isMetachar(c)) {
            // Check if this is * or ? which makes previous element optional
            if (c == '*' or c == '?') {
                // Previous element is optional - remove last char from literal if any
                if (literal_start) |start| {
                    // End literal BEFORE the last character (which is now optional)
                    const end = if (i > 0) i - 1 else i;
                    if (end > start and end - start >= 2) {
                        const lit = pattern[start..end];
                        const score = scoreLiteral(lit);
                        if (score > best_score) {
                            best_score = score;
                            best_literal = lit;
                            best_min_offset = if (min_chars_before > (end - start)) min_chars_before - (end - start) else 0;
                        }
                    }
                    literal_start = null;
                }
                if (min_chars_before > 0) min_chars_before -= 1;
                i += 1;
                continue;
            }

            // End current literal if any (for other metachars)
            if (literal_start) |start| {
                if (i > start and i - start >= 2) {
                    const lit = pattern[start..i];
                    const score = scoreLiteral(lit);
                    if (score > best_score) {
                        best_score = score;
                        best_literal = lit;
                        best_min_offset = if (min_chars_before > (i - start)) min_chars_before - (i - start) else 0;
                    }
                }
                literal_start = null;
            }

            // Update min_chars_before based on metachar
            switch (c) {
                '.' => {
                    min_chars_before += 1; // . matches exactly 1 char
                    i += 1;
                },
                '+' => {
                    // Previous element is now 1+, keep min the same
                    i += 1;
                },
                '[' => {
                    // Character class - skip to closing bracket
                    min_chars_before += 1;
                    i += 1;
                    while (i < pattern.len and pattern[i] != ']') : (i += 1) {}
                    if (i < pattern.len) i += 1; // Skip ']'
                },
                '(' => {
                    // Group - for simplicity, just skip the paren
                    i += 1;
                },
                ')' => {
                    i += 1;
                },
                '|' => {
                    // Alternation - reset everything, can't use literals across alternations reliably
                    literal_start = null;
                    min_chars_before = 0;
                    i += 1;
                },
                '\\' => {
                    // Escape sequence - end any current literal and skip
                    // We can't include escaped chars in literals without decoding them
                    if (literal_start) |start| {
                        if (i > start and i - start >= 2) {
                            const lit = pattern[start..i];
                            const score = scoreLiteral(lit);
                            if (score > best_score) {
                                best_score = score;
                                best_literal = lit;
                                best_min_offset = if (min_chars_before > (i - start)) min_chars_before - (i - start) else 0;
                            }
                        }
                        literal_start = null;
                    }

                    if (i + 1 < pattern.len) {
                        const escaped = pattern[i + 1];
                        switch (escaped) {
                            'd', 'D', 'w', 'W', 's', 'S' => {
                                min_chars_before += 1;
                                i += 2;
                            },
                            'b', 'B' => {
                                // Zero-width assertion
                                i += 2;
                            },
                            else => {
                                // Check if followed by * or ?
                                if (i + 2 < pattern.len and (pattern[i + 2] == '*' or pattern[i + 2] == '?')) {
                                    // This escaped char is optional
                                    i += 2;
                                } else {
                                    // Required escaped char - just skip it, don't include in literal
                                    min_chars_before += 1;
                                    i += 2;
                                }
                            },
                        }
                    } else {
                        i += 1;
                    }
                },
                else => {
                    i += 1;
                },
            }
        } else {
            // Regular character - check if followed by * or ?
            if (i + 1 < pattern.len and (pattern[i + 1] == '*' or pattern[i + 1] == '?')) {
                // This char is optional, end current literal and don't include this char
                if (literal_start) |start| {
                    if (i > start and i - start >= 2) {
                        const lit = pattern[start..i];
                        const score = scoreLiteral(lit);
                        if (score > best_score) {
                            best_score = score;
                            best_literal = lit;
                            best_min_offset = if (min_chars_before > (i - start)) min_chars_before - (i - start) else 0;
                        }
                    }
                    literal_start = null;
                }
                min_chars_before += 1;
                i += 1;
            } else {
                // Required character
                if (literal_start == null) {
                    literal_start = i;
                }
                min_chars_before += 1;
                i += 1;
            }
        }
    }

    // Handle trailing literal
    if (literal_start) |start| {
        if (pattern.len > start and pattern.len - start >= 2) {
            const lit = pattern[start..];
            const score = scoreLiteral(lit);
            if (score > best_score) {
                best_score = score;
                best_literal = lit;
                best_min_offset = if (min_chars_before > (pattern.len - start)) min_chars_before - (pattern.len - start) else 0;
            }
        }
    }

    if (best_literal) |lit| {
        return LiteralInfo{
            .literal = lit,
            .position = .inner,
            .min_offset = best_min_offset,
        };
    }

    return null;
}

/// Check if a character is a regex metacharacter
fn isMetachar(c: u8) bool {
    return switch (c) {
        '.', '*', '+', '?', '[', ']', '(', ')', '{', '}', '|', '^', '$', '\\' => true,
        else => false,
    };
}

/// Score a literal for filtering effectiveness
/// Higher score = better for filtering (more selective)
fn scoreLiteral(lit: []const u8) u32 {
    var score: u32 = 0;

    // Longer literals are better (more selective)
    score += @intCast(lit.len * 10);

    // Score based on character rarity
    for (lit) |c| {
        switch (c) {
            // Very rare characters - high bonus
            '_', 'Q', 'X', 'Z', 'q', 'x', 'z' => score += 5,
            // Uppercase letters - moderately uncommon
            'A'...'O', 'R'...'W', 'Y' => score += 3,
            // P is somewhat common
            'P' => score += 2,
            // Numbers - somewhat uncommon in prose
            '0'...'9' => score += 2,
            // Very common letters - no bonus
            'e', 't', 'a', 'o', 'i', 'n', 's', 'r', 'h', 'l', ' ' => {},
            // Less common lowercase letters
            'd', 'c', 'u', 'm', 'f', 'p', 'g', 'w', 'y', 'b' => score += 1,
            'v', 'k' => score += 2,
            else => score += 1,
        }
    }

    return score;
}

// Tests

test "extract prefix from hello.*" {
    const info = extractBestLiteral("hello.*");
    try std.testing.expect(info != null);
    try std.testing.expectEqualStrings("hello", info.?.literal);
    try std.testing.expectEqual(LiteralInfo.Position.prefix, info.?.position);
}

test "extract suffix from .*_PLATFORM" {
    const info = extractBestLiteral(".*_PLATFORM");
    try std.testing.expect(info != null);
    try std.testing.expectEqualStrings("_PLATFORM", info.?.literal);
    try std.testing.expectEqual(LiteralInfo.Position.suffix, info.?.position);
}

test "extract prefix from CONFIG_.*" {
    const info = extractBestLiteral("CONFIG_.*");
    try std.testing.expect(info != null);
    try std.testing.expectEqualStrings("CONFIG_", info.?.literal);
    try std.testing.expectEqual(LiteralInfo.Position.prefix, info.?.position);
}

test "extract prefix after line anchor" {
    const info = extractBestLiteral("^Sherlock").?;
    try std.testing.expectEqualStrings("Sherlock", info.literal);
    try std.testing.expectEqual(LiteralInfo.Position.prefix, info.position);
}

test "counted optional byte is excluded from required prefix" {
    const info = extractBestLiteral("prefix{0,2}SUFFIX").?;
    try std.testing.expectEqualStrings("prefi", info.literal);
    try std.testing.expectEqual(LiteralInfo.Position.prefix, info.position);
}

test "extract selective suffix from separated literals" {
    const info = extractBestLiteral("alpha.*omega").?;
    try std.testing.expectEqualStrings("omega", info.literal);
    try std.testing.expectEqual(LiteralInfo.Position.suffix, info.position);
}

test "extract prefix from counted literal group" {
    const info = extractBestLiteral("(ab){2,}").?;
    try std.testing.expectEqualStrings("ab", info.literal);
    try std.testing.expectEqual(LiteralInfo.Position.prefix, info.position);
    try std.testing.expect(extractBestLiteral("(a.){2,}") == null);
    try std.testing.expect(extractBestLiteral("(ab){0,3}") == null);
}

test "extract inner from [a-z]+_FOO_[a-z]+" {
    const info = extractBestLiteral("[a-z]+_FOO_[a-z]+");
    try std.testing.expect(info != null);
    try std.testing.expectEqualStrings("_FOO_", info.?.literal);
    try std.testing.expectEqual(LiteralInfo.Position.inner, info.?.position);
}

test "no literal extraction for [a-z]+" {
    const info = extractBestLiteral("[a-z]+");
    try std.testing.expect(info == null);
}

test "no literal extraction for .*" {
    const info = extractBestLiteral(".*");
    try std.testing.expect(info == null);
}

test "no literal extraction for .+" {
    const info = extractBestLiteral(".+");
    try std.testing.expect(info == null);
}

test "extract prefix with escaped metachar" {
    const info = extractBestLiteral("foo\\.bar.*");
    try std.testing.expect(info != null);
    // Should extract "foo" as prefix (escape stops prefix extraction)
    // This is conservative - we don't include escaped chars to avoid complexity
    try std.testing.expectEqualStrings("foo", info.?.literal);
    try std.testing.expectEqual(LiteralInfo.Position.prefix, info.?.position);
}

test "short pattern returns null" {
    const info = extractBestLiteral("a");
    try std.testing.expect(info == null);
}

test "empty pattern returns null" {
    const info = extractBestLiteral("");
    try std.testing.expect(info == null);
}

test "pure literal returns prefix" {
    const info = extractBestLiteral("hello");
    try std.testing.expect(info != null);
    try std.testing.expectEqualStrings("hello", info.?.literal);
    try std.testing.expectEqual(LiteralInfo.Position.prefix, info.?.position);
}

test "suffix with quantifier prefix" {
    const info = extractBestLiteral(".+CONFIG");
    try std.testing.expect(info != null);
    try std.testing.expectEqualStrings("CONFIG", info.?.literal);
    try std.testing.expectEqual(LiteralInfo.Position.suffix, info.?.position);
}

// =============================================================================
// Alternation Literal Extraction for Aho-Corasick
// =============================================================================

/// Result of alternation analysis - contains all extracted literals
pub const AlternationInfo = struct {
    /// The extracted literal alternatives (each is a pure literal string)
    /// Memory is owned by this struct
    literals: []const []const u8,
    /// True if all alternatives contain only ASCII characters
    ascii_only: bool,
    /// Allocator used for memory management
    allocator: std.mem.Allocator,

    pub fn deinit(self: *AlternationInfo) void {
        for (self.literals) |lit| {
            self.allocator.free(lit);
        }
        self.allocator.free(self.literals);
    }
};

/// Analyze a pattern to detect pure-literal alternation.
/// Returns AlternationInfo if pattern is exactly "A|B|C|..." where all A,B,C are pure literals.
/// Returns null if:
/// - Pattern contains nested groups with alternation: (a|b)|c
/// - Any alternative contains regex metacharacters: a.*|b
/// - Pattern is empty or has no alternation
/// - Any alternative is empty
///
/// This is conservative: it only extracts alternatives that are guaranteed to be
/// pure literals with no special regex meaning.
///
/// Caller must call deinit() on the returned AlternationInfo to free memory.
pub fn extractAlternationLiterals(allocator: std.mem.Allocator, pattern: []const u8) !?AlternationInfo {
    if (pattern.len == 0) return null;

    var literals = std.ArrayListUnmanaged([]const u8){};
    defer {
        for (literals.items) |lit| allocator.free(lit);
        literals.deinit(allocator);
    }

    var ascii_only = true;
    var start: usize = 0;
    var escaped = false;
    for (pattern, 0..) |byte, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (byte == '\\') {
            escaped = true;
            continue;
        }
        if (byte != '|') continue;

        const alternative = pattern[start..i];
        if (alternative.len == 0) return null;
        const decoded = try decodePureLiteral(allocator, alternative) orelse return null;
        literals.append(allocator, decoded) catch |err| {
            allocator.free(decoded);
            return err;
        };
        for (decoded) |decoded_byte| {
            if (decoded_byte >= 0x80) ascii_only = false;
        }
        start = i + 1;
    }
    if (start == 0) return null;

    const final_alternative = pattern[start..];
    if (final_alternative.len == 0) return null;
    const decoded = try decodePureLiteral(allocator, final_alternative) orelse return null;
    literals.append(allocator, decoded) catch |err| {
        allocator.free(decoded);
        return err;
    };
    for (decoded) |decoded_byte| {
        if (decoded_byte >= 0x80) ascii_only = false;
    }

    return AlternationInfo{
        .literals = try literals.toOwnedSlice(allocator),
        .ascii_only = ascii_only,
        .allocator = allocator,
    };
}

/// Extract `(literal|literal|...)+`. Every match contains at least one full
/// alternative, so the set is a sound prefilter; the regex engine still
/// verifies the candidate to recover repetition and branch semantics.
pub fn extractRepeatedAlternationLiterals(allocator: std.mem.Allocator, pattern: []const u8) !?AlternationInfo {
    if (pattern.len < 5 or pattern[0] != '(' or pattern[pattern.len - 2] != ')' or pattern[pattern.len - 1] != '+') {
        return null;
    }
    return extractAlternationLiterals(allocator, pattern[1 .. pattern.len - 2]);
}

fn decodePureLiteral(allocator: std.mem.Allocator, pattern: []const u8) !?[]u8 {
    var decoded = std.ArrayListUnmanaged(u8){};
    defer decoded.deinit(allocator);

    var pos: usize = 0;
    while (pos < pattern.len) : (pos += 1) {
        const byte = pattern[pos];
        if (byte != '\\') {
            if (isMetachar(byte)) return null;
            try decoded.append(allocator, byte);
            continue;
        }

        pos += 1;
        if (pos >= pattern.len) return null;
        const literal_byte: u8 = switch (pattern[pos]) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '\\', '.', '[', ']', '(', ')', '{', '}', '*', '+', '?', '|', '^', '$', '-' => pattern[pos],
            else => return null,
        };
        try decoded.append(allocator, literal_byte);
    }
    return try decoded.toOwnedSlice(allocator);
}

pub const FixedAlternationBranch = struct {
    pattern: []const u8,
    required_literal: []const u8,
    required_offset: usize,
};

/// A flat alternation of fixed-width branches. Branch and literal bytes borrow
/// from the pattern supplied to `extractFixedAlternation`; only the two slices
/// of metadata are owned here.
pub const FixedAlternationInfo = struct {
    branches: []const FixedAlternationBranch,
    required_literals: []const []const u8,
    max_required_offset: usize,
    max_branch_len: usize,
    ascii_only: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FixedAlternationInfo) void {
        self.allocator.free(self.branches);
        self.allocator.free(self.required_literals);
    }
};

/// Extract every branch of a flat alternation whose only non-literal token is
/// `.` (exactly one non-newline byte). A selective literal is retained for
/// finding candidates, while the complete fixed-width branch is retained so a
/// match can be verified directly without entering the general NFA/DFA engine.
/// Quantifiers, classes, escapes and groups deliberately fall back to regex.
pub fn extractFixedAlternation(allocator: std.mem.Allocator, pattern: []const u8) !?FixedAlternationInfo {
    if (std.mem.indexOfScalar(u8, pattern, '|') == null) return null;

    var branches = std.ArrayListUnmanaged(FixedAlternationBranch){};
    defer branches.deinit(allocator);
    var literals = std.ArrayListUnmanaged([]const u8){};
    defer literals.deinit(allocator);
    var max_required_offset: usize = 0;
    var max_branch_len: usize = 0;
    var ascii_only = true;

    var alternatives = std.mem.splitScalar(u8, pattern, '|');
    while (alternatives.next()) |alternative| {
        if (alternative.len == 0) return null;

        var best: []const u8 = "";
        var best_offset: usize = 0;
        var run_start: usize = 0;
        for (alternative, 0..) |byte, i| {
            if (byte == '.') {
                if (i - run_start > best.len) {
                    best = alternative[run_start..i];
                    best_offset = run_start;
                }
                run_start = i + 1;
            } else if (isMetachar(byte)) {
                return null;
            }
        }
        const prefix_end = std.mem.indexOfScalar(u8, alternative, '.') orelse alternative.len;
        if (prefix_end >= 3) {
            best = alternative[0..prefix_end];
            best_offset = 0;
        } else if (alternative.len - run_start > best.len) {
            best = alternative[run_start..];
            best_offset = run_start;
        }
        if (best.len < 2) return null;

        try branches.append(allocator, .{
            .pattern = alternative,
            .required_literal = best,
            .required_offset = best_offset,
        });
        try literals.append(allocator, best);
        for (alternative) |byte| {
            if (byte >= 0x80) ascii_only = false;
        }
        if (branches.items.len > 8) return null;
        max_required_offset = @max(max_required_offset, best_offset);
        max_branch_len = @max(max_branch_len, alternative.len);
    }

    if (branches.items.len < 2) return null;
    const owned_branches = try branches.toOwnedSlice(allocator);
    errdefer allocator.free(owned_branches);
    const owned_literals = try literals.toOwnedSlice(allocator);
    return .{
        .branches = owned_branches,
        .required_literals = owned_literals,
        .max_required_offset = max_required_offset,
        .max_branch_len = max_branch_len,
        .ascii_only = ascii_only,
        .allocator = allocator,
    };
}

// =============================================================================
// Alternation Tests
// =============================================================================

test "extractAlternationLiterals pure literals" {
    const allocator = std.testing.allocator;
    var info = (try extractAlternationLiterals(allocator, "foo|bar|baz")).?;
    defer info.deinit();

    try std.testing.expectEqual(@as(usize, 3), info.literals.len);
    try std.testing.expectEqualStrings("foo", info.literals[0]);
    try std.testing.expectEqualStrings("bar", info.literals[1]);
    try std.testing.expectEqualStrings("baz", info.literals[2]);
    try std.testing.expect(info.ascii_only);
}

test "extract fixed alternation required literals" {
    const allocator = std.testing.allocator;
    var info = (try extractFixedAlternation(allocator, "Sherlock Holmes|John Watson|Professor Moriarty|Mrs. Hudson")).?;
    defer info.deinit();

    try std.testing.expectEqual(@as(usize, 4), info.branches.len);
    try std.testing.expectEqualStrings("Sherlock Holmes", info.required_literals[0]);
    try std.testing.expectEqualStrings("John Watson", info.required_literals[1]);
    try std.testing.expectEqualStrings("Professor Moriarty", info.required_literals[2]);
    try std.testing.expectEqualStrings("Mrs", info.required_literals[3]);
    try std.testing.expectEqual(@as(usize, 0), info.branches[3].required_offset);
    try std.testing.expectEqualStrings("Mrs. Hudson", info.branches[3].pattern);
}

test "fixed alternation rejects optional branches" {
    const allocator = std.testing.allocator;
    try std.testing.expect((try extractFixedAlternation(allocator, "foo.*|bar")) == null);
    try std.testing.expect((try extractFixedAlternation(allocator, "foo|ba[rz]")) == null);
}

test "extractAlternationLiterals benchmark pattern" {
    const allocator = std.testing.allocator;
    var info = (try extractAlternationLiterals(allocator, "ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT")).?;
    defer info.deinit();

    try std.testing.expectEqual(@as(usize, 4), info.literals.len);
    try std.testing.expectEqualStrings("ERR_SYS", info.literals[0]);
    try std.testing.expectEqualStrings("PME_TURN_OFF", info.literals[1]);
    try std.testing.expectEqualStrings("LINK_REQ_RST", info.literals[2]);
    try std.testing.expectEqualStrings("CFG_BME_EVT", info.literals[3]);
}

test "extractAlternationLiterals decodes escaped literals" {
    const allocator = std.testing.allocator;
    var info = (try extractAlternationLiterals(allocator, "foo\\.bar|left\\|right|line\\tend")).?;
    defer info.deinit();

    try std.testing.expectEqual(@as(usize, 3), info.literals.len);
    try std.testing.expectEqualStrings("foo.bar", info.literals[0]);
    try std.testing.expectEqualStrings("left|right", info.literals[1]);
    try std.testing.expectEqualStrings("line\tend", info.literals[2]);
}

test "extractAlternationLiterals rejects escaped classes" {
    const allocator = std.testing.allocator;
    try std.testing.expect((try extractAlternationLiterals(allocator, "foo\\d|bar")) == null);
    try std.testing.expect((try extractAlternationLiterals(allocator, "foo\\|bar")) == null);
}

test "extract repeated literal alternation" {
    const allocator = std.testing.allocator;
    var info = (try extractRepeatedAlternationLiterals(allocator, "(Sherlock|John)+")).?;
    defer info.deinit();
    try std.testing.expectEqualStrings("Sherlock", info.literals[0]);
    try std.testing.expectEqualStrings("John", info.literals[1]);
    try std.testing.expect((try extractRepeatedAlternationLiterals(allocator, "(Sherlock|J.hn)+")) == null);
}

test "extractAlternationLiterals with regex returns null" {
    const allocator = std.testing.allocator;
    const info = try extractAlternationLiterals(allocator, "foo.*|bar");
    try std.testing.expect(info == null);
}

test "extractAlternationLiterals with character class returns null" {
    const allocator = std.testing.allocator;
    const info = try extractAlternationLiterals(allocator, "[a-z]+|bar");
    try std.testing.expect(info == null);
}

test "extractAlternationLiterals single pattern returns null" {
    const allocator = std.testing.allocator;
    const info = try extractAlternationLiterals(allocator, "foo");
    try std.testing.expect(info == null);
}

test "extractAlternationLiterals empty alternative returns null" {
    const allocator = std.testing.allocator;
    const info = try extractAlternationLiterals(allocator, "foo||bar");
    try std.testing.expect(info == null);
}

test "extractAlternationLiterals nested group returns null" {
    const allocator = std.testing.allocator;
    // Nested alternation in group - still pure literals at top level
    const info = try extractAlternationLiterals(allocator, "(foo|bar)|baz");
    // This should return null because the parentheses are regex metacharacters
    try std.testing.expect(info == null);
}

test "extractAlternationLiterals two patterns" {
    const allocator = std.testing.allocator;
    var info = (try extractAlternationLiterals(allocator, "foo|bar")).?;
    defer info.deinit();

    try std.testing.expectEqual(@as(usize, 2), info.literals.len);
    try std.testing.expectEqualStrings("foo", info.literals[0]);
    try std.testing.expectEqualStrings("bar", info.literals[1]);
}

test "extractAlternationLiterals non-ascii" {
    const allocator = std.testing.allocator;
    var info = (try extractAlternationLiterals(allocator, "foo|日本語")).?;
    defer info.deinit();

    try std.testing.expectEqual(@as(usize, 2), info.literals.len);
    try std.testing.expect(!info.ascii_only);
}
