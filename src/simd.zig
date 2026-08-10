const std = @import("std");
const builtin = @import("builtin");

// Vector width selection based on target architecture. AVX2 is preferred over
// AVX-512 here: wider vectors down-clock common server CPUs enough to reduce
// end-to-end scan throughput.
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

    // Four independent vectors expose enough instruction-level parallelism to
    // hide load/compare latency while paying one loop branch and one zero test
    // per cache line group. Materialize an exact lane mask only on a hit.
    while (pos + 4 * VECTOR_WIDTH <= haystack.len) {
        const chunk0: Vec = haystack[pos..][0..VECTOR_WIDTH].*;
        const chunk1: Vec = haystack[pos + VECTOR_WIDTH ..][0..VECTOR_WIDTH].*;
        const chunk2: Vec = haystack[pos + 2 * VECTOR_WIDTH ..][0..VECTOR_WIDTH].*;
        const chunk3: Vec = haystack[pos + 3 * VECTOR_WIDTH ..][0..VECTOR_WIDTH].*;
        const cmp0: BoolVec = chunk0 == byte_vec;
        const cmp1: BoolVec = chunk1 == byte_vec;
        const cmp2: BoolVec = chunk2 == byte_vec;
        const cmp3: BoolVec = chunk3 == byte_vec;

        if (@reduce(.Or, cmp0 | cmp1 | cmp2 | cmp3)) {
            const MaskType = std.meta.Int(.unsigned, VECTOR_WIDTH);
            const mask0: MaskType = @bitCast(cmp0);
            if (mask0 != 0) return pos + @ctz(mask0);
            const mask1: MaskType = @bitCast(cmp1);
            if (mask1 != 0) return pos + VECTOR_WIDTH + @ctz(mask1);
            const mask2: MaskType = @bitCast(cmp2);
            if (mask2 != 0) return pos + 2 * VECTOR_WIDTH + @ctz(mask2);
            const mask3: MaskType = @bitCast(cmp3);
            return pos + 3 * VECTOR_WIDTH + @ctz(mask3);
        }
        pos += 4 * VECTOR_WIDTH;
    }

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

/// Public byte finder used by streaming binary detection and line handling.
pub fn findByteValue(haystack: []const u8, byte: u8) ?usize {
    return findByte(haystack, byte);
}

/// Find the first byte with its high bit set. This is used to retain fast
/// byte-oriented matchers over ASCII regions while handing only UTF-8 lines
/// to scalar-aware verification.
pub fn findNonAscii(haystack: []const u8) ?usize {
    const high: Vec = @splat(0x80);
    var pos: usize = 0;
    while (pos + 4 * VECTOR_WIDTH <= haystack.len) : (pos += 4 * VECTOR_WIDTH) {
        const chunks = [4]Vec{
            haystack[pos..][0..VECTOR_WIDTH].*,
            haystack[pos + VECTOR_WIDTH ..][0..VECTOR_WIDTH].*,
            haystack[pos + 2 * VECTOR_WIDTH ..][0..VECTOR_WIDTH].*,
            haystack[pos + 3 * VECTOR_WIDTH ..][0..VECTOR_WIDTH].*,
        };
        const masks = [4]BoolVec{
            (chunks[0] & high) != @as(Vec, @splat(0)),
            (chunks[1] & high) != @as(Vec, @splat(0)),
            (chunks[2] & high) != @as(Vec, @splat(0)),
            (chunks[3] & high) != @as(Vec, @splat(0)),
        };
        if (@reduce(.Or, masks[0] | masks[1] | masks[2] | masks[3])) {
            const MaskType = std.meta.Int(.unsigned, VECTOR_WIDTH);
            for (masks, 0..) |lanes, block| {
                const mask: MaskType = @bitCast(lanes);
                if (mask != 0) return pos + block * VECTOR_WIDTH + @ctz(mask);
            }
        }
    }
    while (pos + VECTOR_WIDTH <= haystack.len) : (pos += VECTOR_WIDTH) {
        const chunk: Vec = haystack[pos..][0..VECTOR_WIDTH].*;
        const lanes: BoolVec = (chunk & high) != @as(Vec, @splat(0));
        if (@reduce(.Or, lanes)) {
            const mask: std.meta.Int(.unsigned, VECTOR_WIDTH) = @bitCast(lanes);
            return pos + @ctz(mask);
        }
    }
    while (pos < haystack.len) : (pos += 1) if (haystack[pos] >= 0x80) return pos;
    return null;
}

/// Detect the only two non-ASCII scalars that simple-fold to ASCII (`K` and
/// `ſ`). Searching the final UTF-8 byte uses the same sparse four-vector byte
/// finder as literal matching; the complete scalar is checked only on a hit.
pub fn containsSpecialFold(
    haystack: []const u8,
    check_kelvin: bool,
    check_long_s: bool,
) bool {
    const kelvin_end: Vec = @splat(0xaa);
    const long_s_end: Vec = @splat(0xbf);
    const no_lanes: BoolVec = @splat(false);
    var pos: usize = 0;
    while (pos + 4 * VECTOR_WIDTH <= haystack.len) : (pos += 4 * VECTOR_WIDTH) {
        var candidates: [4]BoolVec = undefined;
        inline for (0..4) |block| {
            const chunk: Vec = haystack[pos + block * VECTOR_WIDTH ..][0..VECTOR_WIDTH].*;
            const kelvin_lanes = if (check_kelvin) chunk == kelvin_end else no_lanes;
            const long_s_lanes = if (check_long_s) chunk == long_s_end else no_lanes;
            candidates[block] = kelvin_lanes | long_s_lanes;
        }
        if (!@reduce(.Or, candidates[0] | candidates[1] | candidates[2] | candidates[3])) continue;
        for (candidates, 0..) |lanes, block| {
            var mask: std.meta.Int(.unsigned, VECTOR_WIDTH) = @bitCast(lanes);
            while (mask != 0) {
                const index = pos + block * VECTOR_WIDTH + @ctz(mask);
                if ((check_kelvin and isKelvinEnd(haystack, index)) or
                    (check_long_s and isLongSEnd(haystack, index))) return true;
                mask &= mask - 1;
            }
        }
    }
    while (pos < haystack.len) : (pos += 1) {
        if ((check_kelvin and isKelvinEnd(haystack, pos)) or
            (check_long_s and isLongSEnd(haystack, pos))) return true;
    }
    return false;
}

fn isKelvinEnd(haystack: []const u8, end: usize) bool {
    return haystack[end] == 0xaa and end >= 2 and haystack[end - 2] == 0xe2 and haystack[end - 1] == 0x84;
}

fn isLongSEnd(haystack: []const u8, end: usize) bool {
    return haystack[end] == 0xbf and end >= 1 and haystack[end - 1] == 0xc5;
}

/// Byte frequency table for picking rare bytes to search for
/// Lower values = rarer bytes (based on typical text/code frequency)
const BYTE_FREQ: [256]u8 = blk: {
    var freq: [256]u8 = [_]u8{0} ** 256;
    // Common ASCII chars get high frequency
    freq[' '] = 255; // space is most common
    freq['e'] = 250;
    freq['t'] = 245;
    freq['a'] = 240;
    freq['o'] = 235;
    freq['i'] = 230;
    freq['n'] = 225;
    freq['s'] = 220;
    freq['r'] = 215;
    freq['h'] = 210;
    freq['l'] = 205;
    freq['d'] = 200;
    freq['c'] = 195;
    freq['u'] = 190;
    freq['m'] = 185;
    freq['f'] = 180;
    freq['p'] = 175;
    freq['g'] = 170;
    freq['w'] = 165;
    freq['y'] = 160;
    freq['b'] = 155;
    freq['v'] = 150;
    freq['k'] = 145;
    freq['x'] = 80;
    freq['j'] = 75;
    freq['q'] = 70;
    freq['z'] = 65;
    // Digits
    for (0..10) |d| freq['0' + d] = 100;
    // Uppercase (less common in code)
    for (0..26) |c| freq['A' + c] = 90;
    // Common punctuation in code
    freq['_'] = 140;
    freq['.'] = 150;
    freq[','] = 130;
    freq[';'] = 120;
    freq[':'] = 110;
    freq['('] = 135;
    freq[')'] = 135;
    freq['{'] = 100;
    freq['}'] = 100;
    freq['['] = 90;
    freq[']'] = 90;
    freq['"'] = 120;
    freq['\''] = 115;
    freq['='] = 125;
    freq['/'] = 110;
    freq['\\'] = 50;
    freq['\n'] = 200;
    freq['\t'] = 150;
    freq['\r'] = 100;
    // Rare chars stay at 0
    break :blk freq;
};

/// Pick the rarest byte in a pattern for searching
/// Returns (byte, offset) tuple
const RareByte = struct { byte: u8, offset: usize };

fn pickRareByte(needle: []const u8) RareByte {
    if (needle.len == 0) return .{ .byte = 0, .offset = 0 };

    var rarest_byte = needle[0];
    var rarest_offset: usize = 0;
    var rarest_freq = BYTE_FREQ[needle[0]];

    for (needle[1..], 1..) |byte, i| {
        const freq = BYTE_FREQ[byte];
        if (freq < rarest_freq) {
            rarest_freq = freq;
            rarest_byte = byte;
            rarest_offset = i;
        }
    }

    return .{ .byte = rarest_byte, .offset = rarest_offset };
}

fn ignoreCaseByteFreq(byte: u8) u8 {
    const lower = toLower(byte);
    const upper = if (lower >= 'a' and lower <= 'z') lower - 32 else lower;
    return @max(BYTE_FREQ[lower], BYTE_FREQ[upper]);
}

fn pickRareByteIgnoreCase(needle: []const u8) RareByte {
    if (needle.len == 0) return .{ .byte = 0, .offset = 0 };

    var rarest_byte = needle[0];
    var rarest_offset: usize = 0;
    var rarest_freq = ignoreCaseByteFreq(needle[0]);
    for (needle[1..], 1..) |byte, i| {
        const freq = ignoreCaseByteFreq(byte);
        if (freq < rarest_freq) {
            rarest_freq = freq;
            rarest_byte = byte;
            rarest_offset = i;
        }
    }
    return .{ .byte = rarest_byte, .offset = rarest_offset };
}

const RarePair = struct {
    first: u8,
    first_offset: usize,
    second: u8,
    second_offset: usize,
};

/// Select two low-frequency, distinct bytes when possible. Fixed first/last
/// fingerprints perform poorly on patterns whose edges are common; memchr's
/// packed-pair design instead chooses discriminating positions once and then
/// verifies the complete candidate.
fn pickRarePair(needle: []const u8) RarePair {
    return pickRarePairImpl(needle, false);
}

fn pickRarePairImpl(needle: []const u8, comptime ignore_case: bool) RarePair {
    const first = if (ignore_case) pickRareByteIgnoreCase(needle) else pickRareByte(needle);
    var second_offset: ?usize = null;
    var second_freq: u8 = std.math.maxInt(u8);

    for (needle, 0..) |byte, offset| {
        if (offset == first.offset or (if (ignore_case) toLower(byte) == toLower(first.byte) else byte == first.byte)) continue;
        const freq = if (ignore_case) ignoreCaseByteFreq(byte) else BYTE_FREQ[byte];
        if (second_offset == null or freq < second_freq) {
            second_offset = offset;
            second_freq = freq;
        }
    }

    // Repeated-byte needles cannot provide a distinct predicate. Pick the
    // farthest endpoint so the pair still rejects partial runs cheaply.
    const fallback_offset: usize = if (first.offset <= (needle.len - 1) / 2) needle.len - 1 else 0;
    const second = second_offset orelse fallback_offset;
    return .{
        .first = first.byte,
        .first_offset = first.offset,
        .second = needle[second],
        .second_offset = second,
    };
}

const SampledRarePair = struct {
    pair: RarePair,
    first_count: u16,
};

const PairCache = struct {
    valid: bool = false,
    needle_ptr: usize = 0,
    needle_len: usize = 0,
    sampled: SampledRarePair = undefined,
};

threadlocal var exact_pair_cache: PairCache = .{};
threadlocal var folded_pair_cache: PairCache = .{};

/// Begin a new input source. Sampled literal fingerprints remain valid for
/// every block in a source, so the reader reuses one prepared pair instead of
/// re-sampling each refill of its rolling buffer.
pub fn resetSubstringCaches() void {
    exact_pair_cache.valid = false;
    folded_pair_cache.valid = false;
}

fn cachedPairMatchesNeedle(cache: PairCache, needle: []const u8, comptime ignore_case: bool) bool {
    if (!cache.valid) return false;
    const pair = cache.sampled.pair;
    if (pair.first_offset >= needle.len or pair.second_offset >= needle.len) return false;
    if (ignore_case) {
        return toLower(pair.first) == toLower(needle[pair.first_offset]) and
            toLower(pair.second) == toLower(needle[pair.second_offset]);
    }
    return pair.first == needle[pair.first_offset] and pair.second == needle[pair.second_offset];
}

fn pickSampledRarePair(haystack: []const u8, needle: []const u8) SampledRarePair {
    var counts = [_]u16{0} ** 256;
    for (haystack[0..@min(haystack.len, 4096)]) |byte| counts[byte] +|= 1;

    var first_offset: usize = 0;
    for (needle[1..], 1..) |byte, offset| {
        const current = needle[first_offset];
        if (counts[byte] < counts[current] or
            (counts[byte] == counts[current] and BYTE_FREQ[byte] < BYTE_FREQ[current]))
        {
            first_offset = offset;
        }
    }

    var second_offset: ?usize = null;
    for (needle, 0..) |byte, offset| {
        if (offset == first_offset or byte == needle[first_offset]) continue;
        if (second_offset == null or counts[byte] < counts[needle[second_offset.?]] or
            (counts[byte] == counts[needle[second_offset.?]] and BYTE_FREQ[byte] < BYTE_FREQ[needle[second_offset.?]]))
        {
            second_offset = offset;
        }
    }

    const fallback_offset: usize = if (first_offset <= (needle.len - 1) / 2) needle.len - 1 else 0;
    const second = second_offset orelse fallback_offset;
    return .{
        .pair = .{
            .first = needle[first_offset],
            .first_offset = first_offset,
            .second = needle[second],
            .second_offset = second,
        },
        .first_count = counts[needle[first_offset]],
    };
}

/// Static English/code frequencies are a useful fallback, but can be badly
/// wrong for a particular corpus (for example, every line may contain digits
/// while underscores are absent). Sample one cache-sized prefix and choose the
/// actual rarest folded bytes before scanning the full block.
fn pickSampledRarePairIgnoreCase(haystack: []const u8, needle: []const u8) SampledRarePair {
    var counts = [_]u16{0} ** 256;
    for (haystack[0..@min(haystack.len, 4096)]) |byte| {
        const folded = toLower(byte);
        counts[folded] +|= 1;
    }

    var first_offset: usize = 0;
    for (needle[1..], 1..) |byte, offset| {
        const folded = toLower(byte);
        const current = toLower(needle[first_offset]);
        if (counts[folded] < counts[current] or
            (counts[folded] == counts[current] and ignoreCaseByteFreq(byte) < ignoreCaseByteFreq(needle[first_offset])))
        {
            first_offset = offset;
        }
    }

    var second_offset: ?usize = null;
    for (needle, 0..) |byte, offset| {
        if (offset == first_offset or toLower(byte) == toLower(needle[first_offset])) continue;
        if (second_offset == null or counts[toLower(byte)] < counts[toLower(needle[second_offset.?])] or
            (counts[toLower(byte)] == counts[toLower(needle[second_offset.?])] and
                ignoreCaseByteFreq(byte) < ignoreCaseByteFreq(needle[second_offset.?])))
        {
            second_offset = offset;
        }
    }

    const fallback_offset: usize = if (first_offset <= (needle.len - 1) / 2) needle.len - 1 else 0;
    const second = second_offset orelse fallback_offset;
    return .{
        .pair = .{
            .first = needle[first_offset],
            .first_offset = first_offset,
            .second = needle[second],
            .second_offset = second,
        },
        .first_count = counts[toLower(needle[first_offset])],
    };
}

/// Two-byte SIMD substring search using a selected rare-byte pair.
fn findSubstringTwoByteWithPair(haystack: []const u8, needle: []const u8, pair: RarePair) ?usize {
    // Preconditions: needle.len >= 2, needle.len <= haystack.len
    const first_vec: Vec = @splat(pair.first);
    const second_vec: Vec = @splat(pair.second);
    const max_pos = haystack.len - needle.len;
    const MaskType = std.meta.Int(.unsigned, VECTOR_WIDTH);

    var pos: usize = 0;

    // Four independent pair comparisons amortize loop control and expose
    // enough load/compare parallelism for sparse no-hit scans. Exact
    // verification is still performed in position order on the rare block
    // containing a candidate.
    while (pos + 4 * VECTOR_WIDTH <= max_pos + 1) {
        const first0: Vec = haystack[pos + pair.first_offset ..][0..VECTOR_WIDTH].*;
        const second0: Vec = haystack[pos + pair.second_offset ..][0..VECTOR_WIDTH].*;
        const first1: Vec = haystack[pos + VECTOR_WIDTH + pair.first_offset ..][0..VECTOR_WIDTH].*;
        const second1: Vec = haystack[pos + VECTOR_WIDTH + pair.second_offset ..][0..VECTOR_WIDTH].*;
        const first2: Vec = haystack[pos + 2 * VECTOR_WIDTH + pair.first_offset ..][0..VECTOR_WIDTH].*;
        const second2: Vec = haystack[pos + 2 * VECTOR_WIDTH + pair.second_offset ..][0..VECTOR_WIDTH].*;
        const first3: Vec = haystack[pos + 3 * VECTOR_WIDTH + pair.first_offset ..][0..VECTOR_WIDTH].*;
        const second3: Vec = haystack[pos + 3 * VECTOR_WIDTH + pair.second_offset ..][0..VECTOR_WIDTH].*;
        const candidates0: BoolVec = (first0 == first_vec) & (second0 == second_vec);
        const candidates1: BoolVec = (first1 == first_vec) & (second1 == second_vec);
        const candidates2: BoolVec = (first2 == first_vec) & (second2 == second_vec);
        const candidates3: BoolVec = (first3 == first_vec) & (second3 == second_vec);

        if (@reduce(.Or, candidates0 | candidates1 | candidates2 | candidates3)) {
            const masks = [4]MaskType{
                @bitCast(candidates0),
                @bitCast(candidates1),
                @bitCast(candidates2),
                @bitCast(candidates3),
            };
            for (masks, 0..) |initial_mask, block| {
                var mask = initial_mask;
                while (mask != 0) {
                    const bit_pos = @ctz(mask);
                    const candidate = pos + block * VECTOR_WIDTH + bit_pos;
                    if (std.mem.eql(u8, haystack[candidate..][0..needle.len], needle)) return candidate;
                    mask &= mask - 1;
                }
            }
        }
        pos += 4 * VECTOR_WIDTH;
    }

    // SIMD loop - check first AND last byte simultaneously
    while (pos + VECTOR_WIDTH <= max_pos + 1) {
        // Load bytes at positions where first byte would be
        const first_chunk: Vec = haystack[pos + pair.first_offset ..][0..VECTOR_WIDTH].*;
        const second_chunk: Vec = haystack[pos + pair.second_offset ..][0..VECTOR_WIDTH].*;

        // Check where first byte matches
        const first_eq: BoolVec = first_chunk == first_vec;
        // Check where last byte matches
        const second_eq: BoolVec = second_chunk == second_vec;
        // AND them - only positions where BOTH match are candidates
        // Use bitwise AND on the integer representation of the bool vectors
        const first_mask: MaskType = @bitCast(first_eq);
        const second_mask: MaskType = @bitCast(second_eq);
        var mask = first_mask & second_mask;

        if (mask != 0) {
            // Found at least one position where both first and last byte match
            while (mask != 0) {
                const bit_pos = @ctz(mask);
                const candidate = pos + bit_pos;

                if (candidate <= max_pos) {
                    // The selected rare pair may be anywhere in the needle,
                    // so neither endpoint is necessarily covered by it.
                    if (std.mem.eql(u8, haystack[candidate..][0..needle.len], needle)) {
                        return candidate;
                    }
                }

                // Clear lowest set bit
                mask &= mask - 1;
            }
        }
        pos += VECTOR_WIDTH;
    }

    // Scalar fallback for tail
    while (pos <= max_pos) : (pos += 1) {
        if (haystack[pos + pair.first_offset] == pair.first and haystack[pos + pair.second_offset] == pair.second) {
            if (std.mem.eql(u8, haystack[pos..][0..needle.len], needle)) {
                return pos;
            }
        }
    }
    return null;
}

/// Search for the rarest anchor with one SIMD load stream, then check a
/// second predicate and the full needle only at candidates. This mirrors the
/// generic packed-pair prefilter in memchr and avoids doubling memory traffic
/// for selective anchors.
fn findSubstringRareAnchor(haystack: []const u8, needle: []const u8, pair: RarePair) ?usize {
    var scan_pos = pair.first_offset;
    while (scan_pos < haystack.len) {
        const found = findByte(haystack[scan_pos..], pair.first) orelse return null;
        const anchor_pos = scan_pos + found;
        if (anchor_pos >= pair.first_offset) {
            const candidate = anchor_pos - pair.first_offset;
            if (candidate + needle.len <= haystack.len and
                haystack[candidate + pair.second_offset] == pair.second and
                std.mem.eql(u8, haystack[candidate..][0..needle.len], needle))
            {
                return candidate;
            }
        }
        scan_pos = anchor_pos + 1;
    }
    return null;
}

/// Find a substring using SIMD-accelerated two-byte fingerprinting
/// For patterns >= 2 bytes, searches for first AND last byte simultaneously
/// This dramatically reduces false positives compared to single-byte search
pub fn findSubstring(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    // Single byte: use direct byte search
    if (needle.len == 1) {
        return findByte(haystack, needle[0]);
    }

    const sampled = pickSampledRarePair(haystack, needle);
    if (sampled.first_count <= 2) {
        return findSubstringRareAnchor(haystack, needle, sampled.pair);
    }

    // Common anchors benefit from checking both predicates in parallel.
    return findSubstringTwoByteWithPair(haystack, needle, sampled.pair);
}

fn findSubstringStatic(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    if (needle.len == 1) return findByte(haystack, needle[0]);

    const pair = pickRarePair(needle);
    if (BYTE_FREQ[pair.first] <= 100) return findSubstringRareAnchor(haystack, needle, pair);
    return findSubstringTwoByteWithPair(haystack, needle, pair);
}

/// Find a substring starting from a given offset
/// Returns the position relative to the start of haystack (not the offset)
pub fn findSubstringFrom(haystack: []const u8, needle: []const u8, start: usize) ?usize {
    if (start >= haystack.len) return null;
    if (needle.len == 0) return start;
    if (start + needle.len > haystack.len) return null;
    if (needle.len == 1) {
        const relative = findByte(haystack[start..], needle[0]) orelse return null;
        return start + relative;
    }

    const needle_ptr = @intFromPtr(needle.ptr);
    if (!cachedPairMatchesNeedle(exact_pair_cache, needle, false) or exact_pair_cache.needle_ptr != needle_ptr or
        exact_pair_cache.needle_len != needle.len)
    {
        exact_pair_cache = .{
            .valid = true,
            .needle_ptr = needle_ptr,
            .needle_len = needle.len,
            .sampled = pickSampledRarePair(haystack, needle),
        };
    }
    const sampled = exact_pair_cache.sampled;
    const relative = if (sampled.first_count <= 2)
        findSubstringRareAnchor(haystack[start..], needle, sampled.pair)
    else
        findSubstringTwoByteWithPair(haystack[start..], needle, sampled.pair);
    if (relative) |pos| {
        return start + pos;
    }
    return null;
}

/// Case-insensitive byte comparison helper
inline fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

inline fn caseByteMask(chunk: Vec, byte: u8) std.meta.Int(.unsigned, VECTOR_WIDTH) {
    const lower = toLower(byte);
    const matches: BoolVec = if (lower >= 'a' and lower <= 'z')
        (chunk | @as(Vec, @splat(0x20))) == @as(Vec, @splat(lower))
    else
        chunk == @as(Vec, @splat(lower));
    return @bitCast(matches);
}

/// Case-insensitive memory comparison
fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (toLower(ac) != toLower(bc)) return false;
    }
    return true;
}

/// Two-byte case-insensitive SIMD substring search
/// Checks both cases of first and last byte simultaneously
fn findSubstringTwoByteIgnoreCase(haystack: []const u8, needle: []const u8, pair: RarePair) ?usize {
    // Preconditions: needle.len >= 2, needle.len <= haystack.len
    const first_lower = toLower(pair.first);
    const second_lower = toLower(pair.second);
    const max_pos = haystack.len - needle.len;

    var pos: usize = 0;

    // SIMD loop - check first AND last byte (both cases) simultaneously
    while (pos + VECTOR_WIDTH <= max_pos + 1) {
        const first_chunk: Vec = haystack[pos + pair.first_offset ..][0..VECTOR_WIDTH].*;
        const second_chunk: Vec = haystack[pos + pair.second_offset ..][0..VECTOR_WIDTH].*;

        // OR-ing ASCII's case bit folds A-Z to a-z in one vector operation,
        // halving the comparisons needed by lower|upper matching.
        var mask = caseByteMask(first_chunk, first_lower) & caseByteMask(second_chunk, second_lower);

        if (mask != 0) {
            while (mask != 0) {
                const bit_pos = @ctz(mask);
                const candidate = pos + bit_pos;

                if (candidate <= max_pos) {
                    if (eqlIgnoreCase(haystack[candidate..][0..needle.len], needle)) {
                        return candidate;
                    }
                }

                mask &= mask - 1;
            }
        }
        pos += VECTOR_WIDTH;
    }

    // Scalar fallback
    while (pos <= max_pos) : (pos += 1) {
        const first_c = toLower(haystack[pos + pair.first_offset]);
        const second_c = toLower(haystack[pos + pair.second_offset]);
        if (first_c == first_lower and second_c == second_lower) {
            if (eqlIgnoreCase(haystack[pos..][0..needle.len], needle)) {
                return pos;
            }
        }
    }
    return null;
}

fn findSubstringRareAnchorIgnoreCase(haystack: []const u8, needle: []const u8, pair: RarePair) ?usize {
    const first_lower = toLower(pair.first);
    const first_upper = if (first_lower >= 'a' and first_lower <= 'z') first_lower - 32 else first_lower;
    var scan_pos = pair.first_offset;
    while (scan_pos < haystack.len) {
        const found = findByteIgnoreCase(haystack[scan_pos..], first_lower, first_upper) orelse return null;
        const anchor_pos = scan_pos + found;
        if (anchor_pos >= pair.first_offset) {
            const candidate = anchor_pos - pair.first_offset;
            if (candidate + needle.len <= haystack.len and
                toLower(haystack[candidate + pair.second_offset]) == toLower(pair.second) and
                eqlIgnoreCase(haystack[candidate..][0..needle.len], needle))
            {
                return candidate;
            }
        }
        scan_pos = anchor_pos + 1;
    }
    return null;
}

/// Find a substring case-insensitively using SIMD-accelerated two-byte fingerprinting
/// Searches for both uppercase and lowercase versions of first AND last byte simultaneously
pub fn findSubstringIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    // Single byte optimization
    if (needle.len == 1) {
        const lower = toLower(needle[0]);
        const upper = if (lower >= 'a' and lower <= 'z') lower - 32 else lower;
        return findByteIgnoreCase(haystack, lower, upper);
    }

    const sampled = pickSampledRarePairIgnoreCase(haystack, needle);
    if (sampled.first_count <= 2) {
        return findSubstringRareAnchorIgnoreCase(haystack, needle, sampled.pair);
    }

    return findSubstringTwoByteIgnoreCase(haystack, needle, sampled.pair);
}

fn findSubstringIgnoreCaseStatic(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    if (needle.len == 1) {
        const lower = toLower(needle[0]);
        const upper = if (lower >= 'a' and lower <= 'z') lower - 32 else lower;
        return findByteIgnoreCase(haystack, lower, upper);
    }
    return findSubstringTwoByteIgnoreCase(haystack, needle, pickRarePairImpl(needle, true));
}

/// Find a byte case-insensitively using SIMD
fn findByteIgnoreCase(haystack: []const u8, lower: u8, upper: u8) ?usize {
    if (haystack.len == 0) return null;

    _ = upper;
    var pos: usize = 0;

    while (pos + VECTOR_WIDTH <= haystack.len) {
        const chunk: Vec = haystack[pos..][0..VECTOR_WIDTH].*;
        const mask = caseByteMask(chunk, lower);

        if (mask != 0) {
            return pos + @ctz(mask);
        }
        pos += VECTOR_WIDTH;
    }

    // Scalar fallback
    while (pos < haystack.len) : (pos += 1) {
        const c = toLower(haystack[pos]);
        if (c == lower) return pos;
    }
    return null;
}

/// Find a substring case-insensitively starting from a given offset
pub fn findSubstringFromIgnoreCase(haystack: []const u8, needle: []const u8, start: usize) ?usize {
    if (start >= haystack.len) return null;
    if (needle.len == 0) return start;
    if (start + needle.len > haystack.len) return null;
    if (needle.len == 1) {
        const lower = toLower(needle[0]);
        const upper = if (lower >= 'a' and lower <= 'z') lower - 32 else lower;
        const relative = findByteIgnoreCase(haystack[start..], lower, upper) orelse return null;
        return start + relative;
    }

    const needle_ptr = @intFromPtr(needle.ptr);
    if (!cachedPairMatchesNeedle(folded_pair_cache, needle, true) or folded_pair_cache.needle_ptr != needle_ptr or
        folded_pair_cache.needle_len != needle.len)
    {
        folded_pair_cache = .{
            .valid = true,
            .needle_ptr = needle_ptr,
            .needle_len = needle.len,
            .sampled = pickSampledRarePairIgnoreCase(haystack, needle),
        };
    }
    const sampled = folded_pair_cache.sampled;
    const relative = if (sampled.first_count <= 2)
        findSubstringRareAnchorIgnoreCase(haystack[start..], needle, sampled.pair)
    else
        findSubstringTwoByteIgnoreCase(haystack[start..], needle, sampled.pair);
    if (relative) |pos| {
        return start + pos;
    }
    return null;
}

pub const LiteralLineCount = struct {
    count: usize,
    binary_offset: ?usize,
};

pub fn shouldFuseLiteralLineCount(data: []const u8, needle: []const u8, ignore_case: bool) bool {
    if (data.len < VECTOR_WIDTH or needle.len == 0) return false;
    const sample = data[0..@min(data.len, 4096)];
    if (needle.len == 1) {
        var count: usize = 0;
        for (sample) |byte| {
            const equal = if (ignore_case)
                toLower(byte) == toLower(needle[0])
            else
                byte == needle[0];
            if (equal) {
                count += 1;
                if (count > 8) return true;
            }
        }
        return false;
    }
    var matches: usize = 0;
    var pos: usize = 0;
    while (pos + needle.len <= sample.len) {
        const relative = if (ignore_case)
            findSubstringIgnoreCaseStatic(sample[pos..], needle)
        else
            findSubstringStatic(sample[pos..], needle);
        const match_pos = relative orelse return false;
        matches += 1;
        if (matches > 8) return true;
        pos += match_pos + 1;
    }
    // A selective literal lets the ordinary substring path skip almost the
    // entire corpus. Fusing newline comparisons is valuable only when actual
    // matches make per-line restarts more expensive than a contiguous pass.
    return false;
}

/// Count lines containing a literal while scanning each input vector once.
/// Candidate discovery, newline localization and explicit-file NUL checking
/// share the same resident bytes. This avoids restarting substring/newline
/// searches and rescanning line bounds for every dense match.
pub fn countLiteralLines(data: []const u8, needle: []const u8, ignore_case: bool, check_nul: bool) LiteralLineCount {
    if (needle.len == 1) {
        return if (ignore_case)
            countSingleByteLinesImpl(data, needle[0], true, check_nul)
        else
            countSingleByteLinesImpl(data, needle[0], false, check_nul);
    }
    return if (ignore_case)
        countLiteralLinesImpl(data, needle, true, check_nul)
    else
        countLiteralLinesImpl(data, needle, false, check_nul);
}

fn countSingleByteLinesImpl(
    data: []const u8,
    needle: u8,
    comptime ignore_case: bool,
    check_nul: bool,
) LiteralLineCount {
    const MaskType = std.meta.Int(.unsigned, VECTOR_WIDTH);
    const all_bits: MaskType = std.math.maxInt(MaskType);
    const newline_vec: Vec = @splat('\n');
    const zero_vec: Vec = @splat(0);
    const needle_vec: Vec = @splat(needle);
    var count: usize = 0;
    var line_has_match = false;
    var line_has_nul = false;
    var line_nul_offset: usize = 0;
    var binary_offset: ?usize = null;
    var pos: usize = 0;

    while (pos + VECTOR_WIDTH <= data.len) : (pos += VECTOR_WIDTH) {
        const chunk: Vec = data[pos..][0..VECTOR_WIDTH].*;
        const matches: MaskType = if (ignore_case)
            caseByteMask(chunk, needle)
        else
            @bitCast(chunk == needle_vec);
        var newlines: MaskType = @bitCast(chunk == newline_vec);
        var nuls: MaskType = if (check_nul) @bitCast(chunk == zero_vec) else 0;
        var consumed: MaskType = 0;
        while (newlines != 0) {
            const lane = @ctz(newlines);
            const through_newline: MaskType = if (lane == VECTOR_WIDTH - 1)
                all_bits
            else
                (@as(MaskType, 1) << @intCast(lane + 1)) - 1;
            const line_mask = through_newline & ~consumed;
            line_has_match = line_has_match or (matches & line_mask) != 0;
            if (check_nul and !line_has_nul) {
                const line_nuls = nuls & line_mask;
                if (line_nuls != 0) {
                    line_has_nul = true;
                    line_nul_offset = pos + @ctz(line_nuls);
                }
            }
            if (line_has_match) {
                if (line_has_nul and binary_offset == null) binary_offset = line_nul_offset;
                count += 1;
            }
            line_has_match = false;
            line_has_nul = false;
            consumed = through_newline;
            newlines &= newlines - 1;
        }

        line_has_match = line_has_match or (matches & ~consumed) != 0;
        if (check_nul and !line_has_nul) {
            nuls &= ~consumed;
            if (nuls != 0) {
                line_has_nul = true;
                line_nul_offset = pos + @ctz(nuls);
            }
        }
    }

    while (pos < data.len) : (pos += 1) {
        const byte = data[pos];
        if (check_nul and byte == 0 and !line_has_nul) {
            line_has_nul = true;
            line_nul_offset = pos;
        }
        line_has_match = line_has_match or (if (ignore_case)
            toLower(byte) == toLower(needle)
        else
            byte == needle);
        if (byte == '\n') {
            if (line_has_match) {
                if (line_has_nul and binary_offset == null) binary_offset = line_nul_offset;
                count += 1;
            }
            line_has_match = false;
            line_has_nul = false;
        }
    }

    if (line_has_match) {
        if (line_has_nul and binary_offset == null) binary_offset = line_nul_offset;
        count += 1;
    }
    return .{ .count = count, .binary_offset = binary_offset };
}

fn countLiteralLinesImpl(
    data: []const u8,
    needle: []const u8,
    comptime ignore_case: bool,
    check_nul: bool,
) LiteralLineCount {
    std.debug.assert(needle.len >= 2);
    std.debug.assert(std.mem.indexOfScalar(u8, needle, '\n') == null);
    std.debug.assert(std.mem.indexOfScalar(u8, needle, 0) == null);

    const sampled = if (ignore_case)
        pickSampledRarePairIgnoreCase(data, needle)
    else
        pickSampledRarePair(data, needle);
    const pair = sampled.pair;
    const MaskType = std.meta.Int(.unsigned, VECTOR_WIDTH);
    const all_bits: MaskType = std.math.maxInt(MaskType);
    const newline_vec: Vec = @splat('\n');
    const zero_vec: Vec = @splat(0);
    var count: usize = 0;
    var line_has_match = false;
    var line_has_nul = false;
    var line_nul_offset: usize = 0;
    var binary_offset: ?usize = null;
    var pos: usize = 0;

    // Every candidate lane must have enough lookahead for the complete
    // literal. The remaining bytes are handled by the short scalar tail.
    while (pos + VECTOR_WIDTH + needle.len - 1 <= data.len) : (pos += VECTOR_WIDTH) {
        const chunk: Vec = data[pos..][0..VECTOR_WIDTH].*;
        const first_chunk: Vec = data[pos + pair.first_offset ..][0..VECTOR_WIDTH].*;
        const second_chunk: Vec = data[pos + pair.second_offset ..][0..VECTOR_WIDTH].*;
        var candidates: MaskType = if (ignore_case)
            caseByteMask(first_chunk, pair.first) & caseByteMask(second_chunk, pair.second)
        else
            @as(MaskType, @bitCast(first_chunk == @as(Vec, @splat(pair.first)))) &
                @as(MaskType, @bitCast(second_chunk == @as(Vec, @splat(pair.second))));
        var matches: MaskType = 0;
        while (candidates != 0) {
            const lane = @ctz(candidates);
            const candidate = pos + lane;
            const equal = if (ignore_case)
                eqlIgnoreCase(data[candidate..][0..needle.len], needle)
            else
                std.mem.eql(u8, data[candidate..][0..needle.len], needle);
            if (equal) matches |= @as(MaskType, 1) << @intCast(lane);
            candidates &= candidates - 1;
        }

        var newlines: MaskType = @bitCast(chunk == newline_vec);
        var nuls: MaskType = if (check_nul) @bitCast(chunk == zero_vec) else 0;
        var consumed: MaskType = 0;
        while (newlines != 0) {
            const lane = @ctz(newlines);
            const through_newline: MaskType = if (lane == VECTOR_WIDTH - 1)
                all_bits
            else
                (@as(MaskType, 1) << @intCast(lane + 1)) - 1;
            const line_mask = through_newline & ~consumed;
            line_has_match = line_has_match or (matches & line_mask) != 0;
            if (check_nul and !line_has_nul) {
                const line_nuls = nuls & line_mask;
                if (line_nuls != 0) {
                    line_has_nul = true;
                    line_nul_offset = pos + @ctz(line_nuls);
                }
            }
            if (line_has_match) {
                if (line_has_nul and binary_offset == null) binary_offset = line_nul_offset;
                count += 1;
            }
            line_has_match = false;
            line_has_nul = false;
            consumed = through_newline;
            newlines &= newlines - 1;
        }

        line_has_match = line_has_match or (matches & ~consumed) != 0;
        if (check_nul and !line_has_nul) {
            nuls &= ~consumed;
            if (nuls != 0) {
                line_has_nul = true;
                line_nul_offset = pos + @ctz(nuls);
            }
        }
    }

    // A vector candidate can start before `pos` and end in this tail, but it
    // was already verified by the preceding vector. Only new start positions
    // remain here.
    while (pos < data.len) : (pos += 1) {
        const byte = data[pos];
        if (check_nul and byte == 0 and !line_has_nul) {
            line_has_nul = true;
            line_nul_offset = pos;
        }
        if (!line_has_match and pos + needle.len <= data.len) {
            line_has_match = if (ignore_case)
                eqlIgnoreCase(data[pos..][0..needle.len], needle)
            else
                std.mem.eql(u8, data[pos..][0..needle.len], needle);
        }
        if (byte == '\n') {
            if (line_has_match) {
                if (line_has_nul and binary_offset == null) binary_offset = line_nul_offset;
                count += 1;
            }
            line_has_match = false;
            line_has_nul = false;
        }
    }

    if (line_has_match) {
        if (line_has_nul and binary_offset == null) binary_offset = line_nul_offset;
        count += 1;
    }
    return .{ .count = count, .binary_offset = binary_offset };
}

pub const MultiMatch = struct {
    start: usize,
    end: usize,
    pattern_idx: usize,
};

pub const SmallLiteralPlan = struct {
    anchors: [8]u8,
    offsets: [8]usize,
    verify_bytes: [8]u8,
    verify_offsets: [8]usize,
    common_anchor: ?u8,
    common_prefix_len: usize,
    max_offset: usize,
    shared_pair_offsets: [2]usize,
    has_shared_pair: bool,
    teddy_offsets: [3]usize,
    teddy_low: [3]Vec,
    teddy_high: [3]Vec,
    use_teddy: bool,
    group_anchors: [8]u8,
    group_count: usize,
};

fn indexOfScalarIgnoreCase(haystack: []const u8, byte: u8) ?usize {
    const folded = toLower(byte);
    for (haystack, 0..) |candidate, i| {
        if (toLower(candidate) == folded) return i;
    }
    return null;
}

/// Precompute the discriminating anchors for a small literal set. Matchers
/// reuse this plan for every line instead of rescanning all patterns for each
/// call, which is particularly important for recursive source-tree searches.
pub fn prepareSmallLiteralPlan(patterns: []const []const u8, ignore_case: bool) SmallLiteralPlan {
    std.debug.assert(patterns.len > 0 and patterns.len <= 8);

    var plan: SmallLiteralPlan = .{
        .anchors = undefined,
        .offsets = undefined,
        .verify_bytes = undefined,
        .verify_offsets = undefined,
        .common_anchor = null,
        .common_prefix_len = patterns[0].len,
        .max_offset = 0,
        .shared_pair_offsets = .{ 0, 0 },
        .has_shared_pair = false,
        .teddy_offsets = .{ 0, 0, 0 },
        .teddy_low = undefined,
        .teddy_high = undefined,
        .use_teddy = false,
        .group_anchors = undefined,
        .group_count = 0,
    };

    var common_score: u8 = std.math.maxInt(u8);
    for (patterns[0]) |candidate| {
        var present_in_all = true;
        for (patterns[1..]) |pattern| {
            const found = if (ignore_case)
                indexOfScalarIgnoreCase(pattern, candidate)
            else
                std.mem.indexOfScalar(u8, pattern, candidate);
            if (found == null) {
                present_in_all = false;
                break;
            }
        }
        const score = if (ignore_case) ignoreCaseByteFreq(candidate) else BYTE_FREQ[candidate];
        if (present_in_all and score < common_score) {
            plan.common_anchor = candidate;
            common_score = score;
        }
    }
    if (common_score > 150) plan.common_anchor = null;

    for (patterns, 0..) |pattern, i| {
        std.debug.assert(pattern.len > 0);
        const anchor: RareByte = if (plan.common_anchor) |byte|
            .{
                .byte = byte,
                .offset = if (ignore_case)
                    indexOfScalarIgnoreCase(pattern, byte).?
                else
                    std.mem.indexOfScalar(u8, pattern, byte).?,
            }
        else if (ignore_case)
            pickRareByteIgnoreCase(pattern)
        else
            pickRareByte(pattern);
        plan.anchors[i] = anchor.byte;
        plan.offsets[i] = anchor.offset;
        plan.max_offset = @max(plan.max_offset, anchor.offset);

        // A shared anchor can be common in structured text (notably `_` in
        // identifiers). Select an independent rare predicate so candidates do
        // not require a full comparison against every alternative.
        var verify_offset: usize = if (pattern.len == 1 or anchor.offset != 0) 0 else 1;
        var verify_score = if (ignore_case)
            ignoreCaseByteFreq(pattern[verify_offset])
        else
            BYTE_FREQ[pattern[verify_offset]];
        for (pattern, 0..) |byte, offset| {
            if (offset == anchor.offset) continue;
            const score = if (ignore_case) ignoreCaseByteFreq(byte) else BYTE_FREQ[byte];
            if (score < verify_score) {
                verify_score = score;
                verify_offset = offset;
            }
        }
        plan.verify_bytes[i] = pattern[verify_offset];
        plan.verify_offsets[i] = verify_offset;
    }

    if (ignore_case) {
        for (patterns[1..]) |pattern| {
            plan.common_prefix_len = @min(plan.common_prefix_len, pattern.len);
            var i: usize = 0;
            while (i < plan.common_prefix_len and toLower(patterns[0][i]) == toLower(pattern[i])) : (i += 1) {}
            plan.common_prefix_len = i;
        }
    } else {
        plan.common_prefix_len = 0;
    }

    var min_pattern_len = patterns[0].len;
    for (patterns[1..]) |pattern| min_pattern_len = @min(min_pattern_len, pattern.len);
    if (min_pattern_len >= 2) {
        plan.has_shared_pair = true;
        var best_score: u64 = std.math.maxInt(u64);
        for (0..min_pattern_len) |first_offset| {
            for (first_offset + 1..min_pattern_len) |second_offset| {
                var score: u64 = 0;
                for (patterns) |pattern| {
                    const first_freq = if (ignore_case)
                        ignoreCaseByteFreq(pattern[first_offset])
                    else
                        BYTE_FREQ[pattern[first_offset]];
                    const second_freq = if (ignore_case)
                        ignoreCaseByteFreq(pattern[second_offset])
                    else
                        BYTE_FREQ[pattern[second_offset]];
                    score += @as(u64, first_freq) * second_freq;
                }
                if (score < best_score) {
                    best_score = score;
                    plan.shared_pair_offsets = .{ first_offset, second_offset };
                }
            }
        }

        // Four or more alternatives amortize nibble-table lookup better than
        // two equality comparisons per pattern. Each u8 lane carries one bit
        // per pattern, which is the slim Teddy representation.
        if (patterns.len >= 4 and builtin.cpu.arch == .x86_64 and
            min_pattern_len >= 3 and std.Target.x86.featureSetHas(builtin.cpu.features, .ssse3))
        {
            plan.use_teddy = true;
            plan.teddy_offsets[0..2].* = plan.shared_pair_offsets;
            var best_third_score: u64 = std.math.maxInt(u64);
            for (0..min_pattern_len) |offset| {
                if (offset == plan.shared_pair_offsets[0] or offset == plan.shared_pair_offsets[1]) continue;
                var score: u64 = 0;
                for (patterns) |pattern| {
                    const first_freq = if (ignore_case) ignoreCaseByteFreq(pattern[plan.shared_pair_offsets[0]]) else BYTE_FREQ[pattern[plan.shared_pair_offsets[0]]];
                    const second_freq = if (ignore_case) ignoreCaseByteFreq(pattern[plan.shared_pair_offsets[1]]) else BYTE_FREQ[pattern[plan.shared_pair_offsets[1]]];
                    const third_freq = if (ignore_case) ignoreCaseByteFreq(pattern[offset]) else BYTE_FREQ[pattern[offset]];
                    score += @as(u64, first_freq) * second_freq * third_freq;
                }
                if (score < best_third_score) {
                    best_third_score = score;
                    plan.teddy_offsets[2] = offset;
                }
            }

            var low = [_][VECTOR_WIDTH]u8{[_]u8{0} ** VECTOR_WIDTH} ** 3;
            var high = [_][VECTOR_WIDTH]u8{[_]u8{0} ** VECTOR_WIDTH} ** 3;
            for (patterns, 0..) |pattern, pattern_idx| {
                const pattern_bit: u8 = @as(u8, 1) << @intCast(pattern_idx);
                for (plan.teddy_offsets, 0..) |offset, fingerprint_idx| {
                    const byte = pattern[offset];
                    addTeddyByte(&low[fingerprint_idx], &high[fingerprint_idx], byte, pattern_bit);
                    if (ignore_case) {
                        addTeddyByte(&low[fingerprint_idx], &high[fingerprint_idx], std.ascii.toLower(byte), pattern_bit);
                        addTeddyByte(&low[fingerprint_idx], &high[fingerprint_idx], std.ascii.toUpper(byte), pattern_bit);
                    }
                }
            }
            inline for (0..3) |i| {
                plan.teddy_low[i] = low[i];
                plan.teddy_high[i] = high[i];
            }
        }
    }

    for (patterns, 0..) |_, i| {
        const normalized = if (ignore_case) toLower(plan.anchors[i]) else plan.anchors[i];
        var group: ?usize = null;
        for (plan.group_anchors[0..plan.group_count], 0..) |existing, g| {
            if (existing == normalized) {
                group = g;
                break;
            }
        }
        if (group == null) {
            plan.group_anchors[plan.group_count] = normalized;
            plan.group_count += 1;
        }
    }

    return plan;
}

fn addTeddyByte(low: *[VECTOR_WIDTH]u8, high: *[VECTOR_WIDTH]u8, byte: u8, pattern_bit: u8) void {
    var lane: usize = byte & 0x0f;
    while (lane < VECTOR_WIDTH) : (lane += 16) low[lane] |= pattern_bit;
    lane = byte >> 4;
    while (lane < VECTOR_WIDTH) : (lane += 16) high[lane] |= pattern_bit;
}

fn shuffleTeddy(table: Vec, indices: Vec) Vec {
    if (comptime builtin.cpu.arch != .x86_64 or
        !std.Target.x86.featureSetHas(builtin.cpu.features, .ssse3))
    {
        unreachable;
    }
    if (comptime VECTOR_WIDTH == 32) {
        return asm volatile ("vpshufb %[indices], %[table], %[result]"
            : [result] "=x" (-> Vec),
            : [table] "x" (table),
              [indices] "x" (indices),
        );
    }
    return asm volatile ("pshufb %[indices], %[result]"
        : [result] "=x" (-> Vec),
        : [table] "0" (table),
          [indices] "x" (indices),
    );
}

inline fn highNibbles(bytes: Vec, low_nibble: Vec) Vec {
    const WordVec = @Vector(VECTOR_WIDTH / 2, u16);
    const words: WordVec = @bitCast(bytes);
    const shifted: WordVec = words >> @as(WordVec, @splat(4));
    return @as(Vec, @bitCast(shifted)) & low_nibble;
}

fn teddyPatternEqual(
    haystack: []const u8,
    pattern: []const u8,
    comptime ignore_case: bool,
    comptime dot_is_wildcard: bool,
) bool {
    if (!dot_is_wildcard) {
        return if (ignore_case) eqlIgnoreCase(haystack, pattern) else std.mem.eql(u8, haystack, pattern);
    }
    for (haystack, pattern) |actual, expected| {
        if (expected == '.') {
            if (actual == '\n') return false;
        } else if (ignore_case) {
            if (std.ascii.toLower(actual) != std.ascii.toLower(expected)) return false;
        } else if (actual != expected) {
            return false;
        }
    }
    return true;
}

fn findAnyTeddy(
    haystack: []const u8,
    patterns: []const []const u8,
    start: usize,
    plan: *const SmallLiteralPlan,
    comptime ignore_case: bool,
    comptime dot_is_wildcard: bool,
) ?MultiMatch {
    const MaskType = std.meta.Int(.unsigned, VECTOR_WIDTH);
    const low_nibble: Vec = @splat(0x0f);
    const zero: Vec = @splat(0);
    const first_offset = plan.teddy_offsets[0];
    const second_offset = plan.teddy_offsets[1];
    const third_offset = plan.teddy_offsets[2];
    const max_offset = if (ignore_case)
        @max(first_offset, @max(second_offset, third_offset))
    else
        @max(first_offset, second_offset);
    var pos = start;

    while (pos + VECTOR_WIDTH + max_offset <= haystack.len) : (pos += VECTOR_WIDTH) {
        const first: Vec = haystack[pos + first_offset ..][0..VECTOR_WIDTH].*;
        const second: Vec = haystack[pos + second_offset ..][0..VECTOR_WIDTH].*;
        const first_members = shuffleTeddy(plan.teddy_low[0], first & low_nibble) &
            shuffleTeddy(plan.teddy_high[0], highNibbles(first, low_nibble));
        const second_members = shuffleTeddy(plan.teddy_low[1], second & low_nibble) &
            shuffleTeddy(plan.teddy_high[1], highNibbles(second, low_nibble));
        const candidates = if (ignore_case) blk: {
            const third: Vec = haystack[pos + third_offset ..][0..VECTOR_WIDTH].*;
            const third_members = shuffleTeddy(plan.teddy_low[2], third & low_nibble) &
                shuffleTeddy(plan.teddy_high[2], highNibbles(third, low_nibble));
            break :blk first_members & second_members & third_members;
        } else first_members & second_members;
        var lanes: MaskType = @bitCast(candidates != zero);
        const candidate_bytes: [VECTOR_WIDTH]u8 = @bitCast(candidates);

        while (lanes != 0) {
            const lane = @ctz(lanes);
            const match_start = pos + lane;
            var pattern_bits = candidate_bytes[lane];
            while (pattern_bits != 0) {
                const pattern_idx = @ctz(pattern_bits);
                const pattern = patterns[pattern_idx];
                if (match_start + pattern.len <= haystack.len) {
                    if (teddyPatternEqual(
                        haystack[match_start..][0..pattern.len],
                        pattern,
                        ignore_case,
                        dot_is_wildcard,
                    )) return .{
                        .start = match_start,
                        .end = match_start + pattern.len,
                        .pattern_idx = pattern_idx,
                    };
                }
                pattern_bits &= pattern_bits - 1;
            }
            lanes &= lanes - 1;
        }
    }

    // Scalar tail also handles short haystacks and preserves pattern priority.
    while (pos < haystack.len) : (pos += 1) {
        for (patterns, 0..) |pattern, pattern_idx| {
            if (pos + pattern.len > haystack.len) continue;
            if (teddyPatternEqual(
                haystack[pos..][0..pattern.len],
                pattern,
                ignore_case,
                dot_is_wildcard,
            )) return .{ .start = pos, .end = pos + pattern.len, .pattern_idx = pattern_idx };
        }
    }
    return null;
}

pub fn findAnyFixedTeddyFromPrepared(
    haystack: []const u8,
    patterns: []const []const u8,
    start: usize,
    plan: *const SmallLiteralPlan,
    ignore_case: bool,
) ?MultiMatch {
    std.debug.assert(plan.use_teddy);
    return if (ignore_case)
        findAnyTeddy(haystack, patterns, start, plan, true, true)
    else
        findAnyTeddy(haystack, patterns, start, plan, false, true);
}

fn findAnySharedPair(haystack: []const u8, patterns: []const []const u8, start: usize, plan: *const SmallLiteralPlan, comptime ignore_case: bool) ?MultiMatch {
    const MaskType = std.meta.Int(.unsigned, VECTOR_WIDTH);
    var pos = start;
    const first_offset = plan.shared_pair_offsets[0];
    const second_offset = plan.shared_pair_offsets[1];
    const max_offset = @max(first_offset, second_offset);

    // Two case-insensitive literals are common in generated regex prefilters.
    // Fold each input vector once, then compare both packed pairs over four
    // independent blocks. This avoids recomputing the case fold per pattern
    // and gives the CPU enough independent loads/comparisons to hide latency.
    if (ignore_case and patterns.len == 2) {
        const p00 = toLower(patterns[0][first_offset]);
        const p01 = toLower(patterns[0][second_offset]);
        const p10 = toLower(patterns[1][first_offset]);
        const p11 = toLower(patterns[1][second_offset]);
        const all_letters = p00 >= 'a' and p00 <= 'z' and p01 >= 'a' and p01 <= 'z' and
            p10 >= 'a' and p10 <= 'z' and p11 >= 'a' and p11 <= 'z';
        if (all_letters) {
            const case_bit: Vec = @splat(0x20);
            const p00_vec: Vec = @splat(p00);
            const p01_vec: Vec = @splat(p01);
            const p10_vec: Vec = @splat(p10);
            const p11_vec: Vec = @splat(p11);

            while (pos + 4 * VECTOR_WIDTH + max_offset <= haystack.len) : (pos += 4 * VECTOR_WIDTH) {
                var masks: [4]MaskType = undefined;
                inline for (0..4) |block| {
                    const block_pos = pos + block * VECTOR_WIDTH;
                    const first: Vec = haystack[block_pos + first_offset ..][0..VECTOR_WIDTH].* | case_bit;
                    const second: Vec = haystack[block_pos + second_offset ..][0..VECTOR_WIDTH].* | case_bit;
                    const candidates = ((first == p00_vec) & (second == p01_vec)) |
                        ((first == p10_vec) & (second == p11_vec));
                    masks[block] = @bitCast(candidates);
                }

                for (masks, 0..) |initial_mask, block| {
                    var mask = initial_mask;
                    while (mask != 0) {
                        const lane = @ctz(mask);
                        const match_start = pos + block * VECTOR_WIDTH + lane;
                        for (patterns, 0..) |pattern, i| {
                            if (match_start + pattern.len <= haystack.len and
                                eqlIgnoreCase(haystack[match_start..][0..pattern.len], pattern))
                            {
                                return .{ .start = match_start, .end = match_start + pattern.len, .pattern_idx = i };
                            }
                        }
                        mask &= mask - 1;
                    }
                }
            }
        }
    }

    // Candidate lanes represent match starts, so masks from patterns with
    // different literals can be combined while preserving leftmost semantics.
    // Both offsets are shared, reducing shifted input loads from two per
    // pattern to two per vector (the same shape used by Teddy prefilters).
    while (pos + VECTOR_WIDTH + max_offset <= haystack.len) : (pos += VECTOR_WIDTH) {
        var candidates: MaskType = 0;
        const first_chunk: Vec = haystack[pos + first_offset ..][0..VECTOR_WIDTH].*;
        const second_chunk: Vec = haystack[pos + second_offset ..][0..VECTOR_WIDTH].*;
        for (patterns) |pattern| {
            const first_mask: MaskType = if (ignore_case)
                caseByteMask(first_chunk, pattern[first_offset])
            else
                @bitCast(first_chunk == @as(Vec, @splat(pattern[first_offset])));
            const second_mask: MaskType = if (ignore_case)
                caseByteMask(second_chunk, pattern[second_offset])
            else
                @bitCast(second_chunk == @as(Vec, @splat(pattern[second_offset])));
            candidates |= first_mask & second_mask;
        }

        while (candidates != 0) {
            const lane = @ctz(candidates);
            const match_start = pos + lane;
            for (patterns, 0..) |pattern, i| {
                if (match_start + pattern.len > haystack.len) continue;
                const equal = if (ignore_case)
                    toLower(haystack[match_start + first_offset]) == toLower(pattern[first_offset]) and
                        toLower(haystack[match_start + second_offset]) == toLower(pattern[second_offset]) and
                        eqlIgnoreCase(haystack[match_start..][0..pattern.len], pattern)
                else
                    haystack[match_start + first_offset] == pattern[first_offset] and
                        haystack[match_start + second_offset] == pattern[second_offset] and
                        std.mem.eql(u8, haystack[match_start..][0..pattern.len], pattern);
                if (equal) {
                    return .{ .start = match_start, .end = match_start + pattern.len, .pattern_idx = i };
                }
            }
            candidates &= candidates - 1;
        }
    }

    while (pos < haystack.len) : (pos += 1) {
        for (patterns, 0..) |pattern, i| {
            if (pos + pattern.len > haystack.len) continue;
            const equal = if (ignore_case)
                toLower(haystack[pos + first_offset]) == toLower(pattern[first_offset]) and
                    toLower(haystack[pos + second_offset]) == toLower(pattern[second_offset]) and
                    eqlIgnoreCase(haystack[pos..][0..pattern.len], pattern)
            else
                haystack[pos + first_offset] == pattern[first_offset] and
                    haystack[pos + second_offset] == pattern[second_offset] and
                    std.mem.eql(u8, haystack[pos..][0..pattern.len], pattern);
            if (equal) {
                return .{ .start = pos, .end = pos + pattern.len, .pattern_idx = i };
            }
        }
    }
    return null;
}

/// SIMD packed-pair search for a small literal set. Unlike dense
/// Aho-Corasick, this performs independent comparisons that the CPU can issue
/// in parallel and touches no state-transition table for each input byte.
pub fn findAnySubstringFrom(haystack: []const u8, patterns: []const []const u8, start: usize) ?MultiMatch {
    return findAnySubstringImpl(haystack, patterns, start, false, null);
}

pub fn findAnySubstringFromIgnoreCase(haystack: []const u8, patterns: []const []const u8, start: usize) ?MultiMatch {
    return findAnySubstringImpl(haystack, patterns, start, true, null);
}

pub fn findAnySubstringFromPrepared(haystack: []const u8, patterns: []const []const u8, start: usize, plan: *const SmallLiteralPlan) ?MultiMatch {
    return findAnySubstringImpl(haystack, patterns, start, false, plan);
}

pub fn findAnySubstringFromIgnoreCasePrepared(haystack: []const u8, patterns: []const []const u8, start: usize, plan: *const SmallLiteralPlan) ?MultiMatch {
    return findAnySubstringImpl(haystack, patterns, start, true, plan);
}

fn findAnySubstringImpl(haystack: []const u8, patterns: []const []const u8, start: usize, comptime ignore_case: bool, prepared: ?*const SmallLiteralPlan) ?MultiMatch {
    const MAX_PATTERNS = 8;
    if (patterns.len == 0 or patterns.len > MAX_PATTERNS or start >= haystack.len) return null;

    for (patterns, 0..) |pattern, i| {
        if (pattern.len == 0) return .{ .start = start, .end = start, .pattern_idx = i };
    }

    var computed_plan: SmallLiteralPlan = undefined;
    const plan = prepared orelse blk: {
        computed_plan = prepareSmallLiteralPlan(patterns, ignore_case);
        break :blk &computed_plan;
    };

    if (ignore_case) {
        if (plan.common_prefix_len >= 3) {
            const prefix = patterns[0][0..plan.common_prefix_len];
            var scan_pos = start;
            while (findSubstringFromIgnoreCase(haystack, prefix, scan_pos)) |match_start| {
                for (patterns, 0..) |pattern, i| {
                    if (match_start + pattern.len <= haystack.len and
                        eqlIgnoreCase(haystack[match_start..][0..pattern.len], pattern))
                    {
                        return .{ .start = match_start, .end = match_start + pattern.len, .pattern_idx = i };
                    }
                }
                scan_pos = match_start + 1;
            }
            return null;
        }
    }

    // Use two positions shared by every pattern so candidate bits represent
    // match starts directly. This is more selective than the one-byte grouped
    // filter below and, unlike independent rare-byte searches, loads each
    // shifted input vector only once. It is the portable SIMD form of Teddy's
    // multi-literal packed fingerprint.
    if (plan.use_teddy) {
        return findAnyTeddy(haystack, patterns, start, plan, ignore_case, false);
    }
    if (plan.has_shared_pair and (ignore_case or plan.common_anchor == null)) {
        return findAnySharedPair(haystack, patterns, start, plan, ignore_case);
    }

    // When every pattern has the same selective byte, use the tight byte
    // finder directly instead of re-entering the generalized grouped-anchor
    // loop for every vector. This is the common shape of symbolic alternatives
    // (NOT_ONE|NOT_TWO, ERR_*|WARN_*) and has the same scan cost as one literal.
    if (plan.common_anchor) |anchor| {
        const lower = toLower(anchor);
        const upper = if (lower >= 'a' and lower <= 'z') lower - 32 else lower;
        var scan_pos = start;
        var best: ?MultiMatch = null;
        while (scan_pos < haystack.len) {
            const relative = if (ignore_case and lower >= 'a' and lower <= 'z')
                findByteIgnoreCase(haystack[scan_pos..], lower, upper)
            else
                findByte(haystack[scan_pos..], anchor);
            const anchor_pos = scan_pos + (relative orelse return best);
            for (patterns, 0..) |pattern, i| {
                if (anchor_pos < plan.offsets[i]) continue;
                const match_start = anchor_pos - plan.offsets[i];
                if (match_start < start or match_start + pattern.len > haystack.len) continue;
                const verify_equal = if (ignore_case)
                    toLower(haystack[match_start + plan.verify_offsets[i]]) == toLower(plan.verify_bytes[i])
                else
                    haystack[match_start + plan.verify_offsets[i]] == plan.verify_bytes[i];
                if (!verify_equal) continue;
                const equal = if (ignore_case)
                    eqlIgnoreCase(haystack[match_start..][0..pattern.len], pattern)
                else
                    std.mem.eql(u8, haystack[match_start..][0..pattern.len], pattern);
                if (equal and (best == null or match_start < best.?.start or
                    (match_start == best.?.start and i < best.?.pattern_idx)))
                {
                    best = .{ .start = match_start, .end = match_start + pattern.len, .pattern_idx = i };
                }
            }
            if (best) |match| {
                if (anchor_pos >= match.start + plan.max_offset) return match;
            }
            scan_pos = anchor_pos + 1;
        }
        return best;
    }

    const MaskType = std.meta.Int(.unsigned, VECTOR_WIDTH);
    var pos = start;
    var best: ?MultiMatch = null;
    while (pos + VECTOR_WIDTH <= haystack.len) : (pos += VECTOR_WIDTH) {
        const chunk: Vec = haystack[pos..][0..VECTOR_WIDTH].*;
        var any_mask: MaskType = switch (plan.group_count) {
            1 => anchorGroupMask(1, chunk, plan.group_anchors, ignore_case),
            2 => anchorGroupMask(2, chunk, plan.group_anchors, ignore_case),
            3 => anchorGroupMask(3, chunk, plan.group_anchors, ignore_case),
            4 => anchorGroupMask(4, chunk, plan.group_anchors, ignore_case),
            5 => anchorGroupMask(5, chunk, plan.group_anchors, ignore_case),
            6 => anchorGroupMask(6, chunk, plan.group_anchors, ignore_case),
            7 => anchorGroupMask(7, chunk, plan.group_anchors, ignore_case),
            8 => anchorGroupMask(8, chunk, plan.group_anchors, ignore_case),
            else => unreachable,
        };

        while (any_mask != 0) {
            const lane = @ctz(any_mask);
            const candidate = pos + lane;
            for (patterns, 0..) |pattern, i| {
                const anchor_matches = if (ignore_case)
                    toLower(haystack[candidate]) == toLower(plan.anchors[i])
                else
                    haystack[candidate] == plan.anchors[i];
                if (!anchor_matches or candidate < plan.offsets[i]) continue;
                const match_start = candidate - plan.offsets[i];
                if (match_start < start or match_start + pattern.len > haystack.len) continue;
                const equal = if (ignore_case)
                    eqlIgnoreCase(haystack[match_start..][0..pattern.len], pattern)
                else
                    std.mem.eql(u8, haystack[match_start..][0..pattern.len], pattern);
                if (equal and (best == null or match_start < best.?.start or
                    (match_start == best.?.start and i < best.?.pattern_idx)))
                {
                    best = .{ .start = match_start, .end = match_start + pattern.len, .pattern_idx = i };
                }
            }
            any_mask &= any_mask - 1;
        }

        // Different patterns use anchors at different offsets. Continue only
        // far enough to prove that no later anchor can belong to an earlier
        // match start.
        if (best) |match| {
            if (pos + VECTOR_WIDTH > match.start + plan.max_offset) return match;
        }
    }

    // Verify the tail and short haystacks in strict position/pattern order,
    // then combine it with any candidate found in the final vector block.
    while (pos < haystack.len) : (pos += 1) {
        for (patterns, 0..) |pattern, i| {
            const anchor_matches = if (ignore_case)
                toLower(haystack[pos]) == toLower(plan.anchors[i])
            else
                haystack[pos] == plan.anchors[i];
            if (!anchor_matches or pos < plan.offsets[i]) continue;
            const match_start = pos - plan.offsets[i];
            if (match_start < start or match_start + pattern.len > haystack.len) continue;
            const equal = if (ignore_case)
                toLower(haystack[pos]) == toLower(plan.anchors[i]) and eqlIgnoreCase(haystack[match_start..][0..pattern.len], pattern)
            else
                std.mem.eql(u8, haystack[match_start..][0..pattern.len], pattern);
            if (equal and (best == null or match_start < best.?.start or
                (match_start == best.?.start and i < best.?.pattern_idx)))
            {
                best = .{ .start = match_start, .end = match_start + pattern.len, .pattern_idx = i };
            }
        }
    }
    return best;
}

fn anchorGroupMask(comptime count: usize, chunk: Vec, anchors: [8]u8, comptime ignore_case: bool) std.meta.Int(.unsigned, VECTOR_WIDTH) {
    const MaskType = std.meta.Int(.unsigned, VECTOR_WIDTH);
    var mask: MaskType = 0;
    inline for (0..count) |i| {
        if (ignore_case) {
            mask |= caseByteMask(chunk, anchors[i]);
        } else {
            mask |= @bitCast(chunk == @as(Vec, @splat(anchors[i])));
        }
    }
    return mask;
}

/// Count newlines in a buffer using SIMD
/// Much faster than a scalar loop for counting characters
pub fn countNewlines(data: []const u8) usize {
    if (data.len == 0) return 0;

    const newline_vec: Vec = @splat('\n');
    var count: usize = 0;
    var pos: usize = 0;

    // SIMD loop - count newlines in VECTOR_WIDTH bytes at a time
    while (pos + VECTOR_WIDTH <= data.len) {
        const chunk: Vec = data[pos..][0..VECTOR_WIDTH].*;
        const matches: BoolVec = chunk == newline_vec;

        // Convert bool vector to integer mask and popcount
        const MaskType = std.meta.Int(.unsigned, VECTOR_WIDTH);
        const mask: MaskType = @bitCast(matches);
        count += @popCount(mask);

        pos += VECTOR_WIDTH;
    }

    // Scalar tail
    for (data[pos..]) |c| {
        if (c == '\n') count += 1;
    }

    return count;
}

/// Count empty logical lines: a newline at byte zero or immediately following
/// another newline. A trailing newline terminates the preceding line and does
/// not create an extra phantom line.
pub fn countEmptyLines(data: []const u8) usize {
    if (data.len == 0) return 0;
    const newline: Vec = @splat('\n');
    var count: usize = if (data[0] == '\n') 1 else 0;
    var pos: usize = 1;
    while (pos + VECTOR_WIDTH <= data.len) : (pos += VECTOR_WIDTH) {
        const previous: Vec = data[pos - 1 ..][0..VECTOR_WIDTH].*;
        const current: Vec = data[pos..][0..VECTOR_WIDTH].*;
        const pairs: BoolVec = (previous == newline) & (current == newline);
        const mask: std.meta.Int(.unsigned, VECTOR_WIDTH) = @bitCast(pairs);
        count += @popCount(mask);
    }
    while (pos < data.len) : (pos += 1) {
        if (data[pos - 1] == '\n' and data[pos] == '\n') count += 1;
    }
    return count;
}

/// Find the next newline character using SIMD
pub fn findNewline(haystack: []const u8) ?usize {
    return findByte(haystack, '\n');
}

pub const AsciiWordDotScan = struct {
    candidate: ?usize,
    scanned: usize,
};

inline fn asciiWordLanes(chunk: Vec) BoolVec {
    return ((chunk >= @as(Vec, @splat('0'))) & (chunk <= @as(Vec, @splat('9')))) |
        ((chunk >= @as(Vec, @splat('A'))) & (chunk <= @as(Vec, @splat('Z')))) |
        ((chunk >= @as(Vec, @splat('a'))) & (chunk <= @as(Vec, @splat('z')))) |
        (chunk == @as(Vec, @splat('_')));
}

/// Scan ASCII bytes for a position matched by `-w .`: neither neighboring
/// byte may be a word byte, while the candidate itself may be word or
/// punctuation. Newlines act as boundaries but cannot be candidates. Stop
/// before a vector containing non-ASCII so the caller can apply Unicode scalar
/// semantics. `start` must leave one byte of look-behind available.
pub fn scanAsciiWordDotCandidate(data: []const u8, start: usize) AsciiWordDotScan {
    std.debug.assert(start > 0 and start <= data.len);
    const high_bit: Vec = @splat(0x80);
    const newline: Vec = @splat('\n');
    var pos = start;
    while (pos + VECTOR_WIDTH + 1 <= data.len) : (pos += VECTOR_WIDTH) {
        const previous: Vec = data[pos - 1 ..][0..VECTOR_WIDTH].*;
        const current: Vec = data[pos..][0..VECTOR_WIDTH].*;
        const next: Vec = data[pos + 1 ..][0..VECTOR_WIDTH].*;
        if (@reduce(.Or, ((previous | current | next) & high_bit) != @as(Vec, @splat(0)))) {
            break;
        }
        const candidates: BoolVec = !asciiWordLanes(previous) &
            !asciiWordLanes(next) & (current != newline);
        if (@reduce(.Or, candidates)) {
            const mask: std.meta.Int(.unsigned, VECTOR_WIDTH) = @bitCast(candidates);
            return .{ .candidate = pos + @ctz(mask), .scanned = pos - start };
        }
    }
    return .{ .candidate = null, .scanned = pos - start };
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

test "findSubstringFrom single byte preserves absolute offsets" {
    try std.testing.expectEqual(@as(?usize, 1), findSubstringFrom("banana", "a", 0));
    try std.testing.expectEqual(@as(?usize, 3), findSubstringFrom("banana", "a", 2));
    try std.testing.expectEqual(@as(?usize, 5), findSubstringFrom("banana", "a", 4));
    try std.testing.expectEqual(@as(?usize, null), findSubstringFrom("banana", "a", 6));
    try std.testing.expectEqual(@as(?usize, 3), findSubstringFromIgnoreCase("bAnAna", "a", 2));
}

test "countLiteralLines fuses matching line and binary detection" {
    const vector_prefix = "0123456789012345678901234567890";
    const data = vector_prefix ++ "\nalpha alpha\nno match\nALPHA\ntail alpha";

    try std.testing.expectEqual(
        LiteralLineCount{ .count = 2, .binary_offset = null },
        countLiteralLines(data, "alpha", false, true),
    );
    try std.testing.expectEqual(
        LiteralLineCount{ .count = 3, .binary_offset = null },
        countLiteralLines(data, "alpha", true, true),
    );

    const binary = "alpha\nsafe\npre\x00alpha\nafter alpha\n";
    try std.testing.expectEqual(
        LiteralLineCount{ .count = 3, .binary_offset = 14 },
        countLiteralLines(binary, "alpha", false, true),
    );

    try std.testing.expectEqual(
        LiteralLineCount{ .count = 3, .binary_offset = 3 },
        countLiteralLines("a\na\x00\na\n", "a", false, true),
    );
}

test "ASCII word-dot candidate scan respects neighboring word bytes" {
    const padding = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const data = padding ++ " a!b --- x " ++ padding;
    const start = padding.len;
    const result = scanAsciiWordDotCandidate(data, start);
    try std.testing.expectEqual(@as(?usize, start + 1), result.candidate);

    const words = padding ++ " abc def ghi jkl mno pqr stu " ++ padding;
    const none = scanAsciiWordDotCandidate(words, start);
    try std.testing.expect(none.candidate == null);
}

// =============================================================================
// Two-Byte SIMD Fingerprinting Tests (Phase 1 optimization)
// =============================================================================

test "findSubstringTwoByte two char patterns" {
    // Exact 2-char patterns (no middle verification needed)
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("ab", "ab"));
    try std.testing.expectEqual(@as(?usize, 1), findSubstring("xab", "ab"));
    try std.testing.expectEqual(@as(?usize, null), findSubstring("axb", "ab"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("abcd", "ab"));
}

test "findSubstringTwoByte same first and last byte" {
    // Edge case: pattern starts and ends with same byte
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("aba", "aba"));
    try std.testing.expectEqual(@as(?usize, 1), findSubstring("xabax", "aba"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("aaa", "aa"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstring("aaaa", "aaa"));
}

test "findSubstringTwoByte long patterns" {
    // Patterns longer than SIMD width (16 bytes on ARM)
    const long_pattern = "this is a very long pattern here";
    const haystack = "prefix " ++ long_pattern ++ " suffix";
    try std.testing.expectEqual(@as(?usize, 7), findSubstring(haystack, long_pattern));
}

test "findSubstringTwoByte at SIMD boundaries" {
    // Pattern crosses SIMD chunk boundaries (16/32 bytes)
    var haystack: [48]u8 = undefined;
    @memset(&haystack, 'x');
    // Place "needle" at position 14 (crosses 16-byte boundary)
    @memcpy(haystack[14..20], "needle");
    try std.testing.expectEqual(@as(?usize, 14), findSubstring(&haystack, "needle"));

    // Place at position 15
    @memset(&haystack, 'x');
    @memcpy(haystack[15..21], "needle");
    try std.testing.expectEqual(@as(?usize, 15), findSubstring(&haystack, "needle"));

    // Place at position 31 (another boundary)
    @memset(&haystack, 'x');
    @memcpy(haystack[31..37], "needle");
    try std.testing.expectEqual(@as(?usize, 31), findSubstring(&haystack, "needle"));
}

test "findSubstringTwoByte many false positives" {
    // Test with many first+last byte matches but few full matches
    // Pattern "aba" has 'a' at both ends
    const haystack = "aa aa aa aba aa aa";
    try std.testing.expectEqual(@as(?usize, 9), findSubstring(haystack, "aba"));

    // More complex: "xyzx" where 'x' appears often
    const haystack2 = "xxxx xyzx xxxx";
    try std.testing.expectEqual(@as(?usize, 5), findSubstring(haystack2, "xyzx"));
}

test "findSubstringTwoByte scalar fallback" {
    // Test patterns that exercise the scalar tail path
    // Haystack just long enough to use SIMD once, then scalar
    var haystack: [20]u8 = undefined;
    @memset(&haystack, 'x');
    // Put pattern in scalar tail region (after first 16 bytes)
    @memcpy(haystack[17..19], "ab");
    try std.testing.expectEqual(@as(?usize, 17), findSubstring(&haystack, "ab"));
}

// =============================================================================
// Case-Insensitive Two-Byte Search Tests
// =============================================================================

test "findSubstringIgnoreCase basic" {
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("HELLO", "hello"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("hello", "HELLO"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("HeLLo", "hello"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("hElLo", "HELLO"));
}

test "findSubstringIgnoreCase mixed case pattern" {
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("hello", "HeLLo"));
    try std.testing.expectEqual(@as(?usize, 6), findSubstringIgnoreCase("hello WORLD", "world"));
    try std.testing.expectEqual(@as(?usize, 6), findSubstringIgnoreCase("hello world", "WORLD"));
}

test "findSubstringIgnoreCase non-alpha chars" {
    // Non-alphabetic characters should match exactly
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("123", "123"));
    try std.testing.expectEqual(@as(?usize, null), findSubstringIgnoreCase("123", "124"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("a1b", "A1B"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("A1B", "a1b"));
}

test "rare pair verifies the complete needle" {
    try std.testing.expectEqual(@as(?usize, null), findSubstringIgnoreCase("snd_pcm_resume", "PM_RESUME"));
    try std.testing.expectEqual(@as(?usize, 4), findSubstringIgnoreCase("snd_PM_RESUME", "pm_resume"));
}

test "findSubstringIgnoreCase single char" {
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("A", "a"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("a", "A"));
    try std.testing.expectEqual(@as(?usize, 2), findSubstringIgnoreCase("xxA", "a"));
}

test "findSubstringIgnoreCase two char patterns" {
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("AB", "ab"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("ab", "AB"));
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase("Ab", "aB"));
}

test "findSubstringFromIgnoreCase basic" {
    const data = "Hello World, HELLO Universe";
    try std.testing.expectEqual(@as(?usize, 0), findSubstringFromIgnoreCase(data, "hello", 0));
    try std.testing.expectEqual(@as(?usize, 13), findSubstringFromIgnoreCase(data, "hello", 1));
    try std.testing.expectEqual(@as(?usize, null), findSubstringFromIgnoreCase(data, "hello", 20));
}

test "small literal Teddy filter handles vector boundaries" {
    const patterns = [_][]const u8{ "Sherlock Holmes", "John Watson", "Professor Moriarty", "Mrs Hudson" };
    for ([_]usize{ 0, 15, 16, 31, 32, 63 }) |offset| {
        var haystack: [96]u8 = [_]u8{'x'} ** 96;
        @memcpy(haystack[offset..][0..patterns[2].len], patterns[2]);
        const match = findAnySubstringFrom(&haystack, &patterns, 0).?;
        try std.testing.expectEqual(offset, match.start);
        try std.testing.expectEqual(@as(usize, 2), match.pattern_idx);
    }
}

test "small literal Teddy filter preserves priority and case folding" {
    const patterns = [_][]const u8{ "alphabet soup", "alphabet", "beta value", "gamma ray" };
    const exact = findAnySubstringFrom("xxalphabet soup", &patterns, 0).?;
    try std.testing.expectEqual(@as(usize, 2), exact.start);
    try std.testing.expectEqual(@as(usize, 0), exact.pattern_idx);

    const folded = findAnySubstringFromIgnoreCase("xxGAMMA RAY", &patterns, 0).?;
    try std.testing.expectEqual(@as(usize, 2), folded.start);
    try std.testing.expectEqual(@as(usize, 3), folded.pattern_idx);
    try std.testing.expect(findAnySubstringFrom("alphxbet soup", &patterns, 0) == null);
}

test "findSubstringIgnoreCase long pattern" {
    const haystack = "THIS IS A VERY LONG STRING WITH PATTERN";
    try std.testing.expectEqual(@as(?usize, 0), findSubstringIgnoreCase(haystack, "this is a very long"));
    // "PATTERN" starts at index 32 in the haystack
    try std.testing.expectEqual(@as(?usize, 32), findSubstringIgnoreCase(haystack, "pattern"));
}

// =============================================================================
// SIMD Newline Counting Tests (Phase 4 optimization)
// =============================================================================

test "countNewlines empty" {
    try std.testing.expectEqual(@as(usize, 0), countNewlines(""));
}

test "countNewlines no newlines" {
    try std.testing.expectEqual(@as(usize, 0), countNewlines("hello world"));
    try std.testing.expectEqual(@as(usize, 0), countNewlines("x"));
    try std.testing.expectEqual(@as(usize, 0), countNewlines("abc def ghi jkl"));
}

test "countNewlines single newline" {
    try std.testing.expectEqual(@as(usize, 1), countNewlines("\n"));
    try std.testing.expectEqual(@as(usize, 1), countNewlines("hello\n"));
    try std.testing.expectEqual(@as(usize, 1), countNewlines("hello\nworld"));
    try std.testing.expectEqual(@as(usize, 1), countNewlines("\nworld"));
}

test "countNewlines multiple newlines" {
    try std.testing.expectEqual(@as(usize, 3), countNewlines("a\nb\nc\n"));
    try std.testing.expectEqual(@as(usize, 5), countNewlines("\n\n\n\n\n"));
    try std.testing.expectEqual(@as(usize, 2), countNewlines("line1\nline2\n"));
}

test "countNewlines large buffer SIMD path" {
    // Test with buffer larger than SIMD width to exercise SIMD path
    var buf: [256]u8 = undefined;
    @memset(&buf, 'x');
    // Add 10 newlines at various positions
    buf[15] = '\n';
    buf[32] = '\n';
    buf[47] = '\n';
    buf[64] = '\n';
    buf[79] = '\n';
    buf[100] = '\n';
    buf[120] = '\n';
    buf[150] = '\n';
    buf[200] = '\n';
    buf[255] = '\n';
    try std.testing.expectEqual(@as(usize, 10), countNewlines(&buf));
}

test "countNewlines all newlines" {
    var buf: [64]u8 = undefined;
    @memset(&buf, '\n');
    try std.testing.expectEqual(@as(usize, 64), countNewlines(&buf));

    var small_buf: [16]u8 = undefined;
    @memset(&small_buf, '\n');
    try std.testing.expectEqual(@as(usize, 16), countNewlines(&small_buf));
}

test "countNewlines scalar tail" {
    // Test the scalar tail path (buffer not divisible by SIMD width)
    try std.testing.expectEqual(@as(usize, 2), countNewlines("a\nb\n")); // 4 bytes (< 16)
    try std.testing.expectEqual(@as(usize, 2), countNewlines("123456789012345\n1\n")); // 18 bytes

    // 17 bytes - one SIMD chunk + 1 scalar byte
    var buf17: [17]u8 = undefined;
    @memset(&buf17, 'x');
    buf17[0] = '\n';
    buf17[16] = '\n';
    try std.testing.expectEqual(@as(usize, 2), countNewlines(&buf17));
}

test "countNewlines at SIMD boundaries" {
    // Test newlines exactly at SIMD boundaries (16, 32, 48...)
    var buf: [64]u8 = undefined;
    @memset(&buf, 'x');
    buf[15] = '\n'; // Last byte of first chunk
    buf[16] = '\n'; // First byte of second chunk
    buf[31] = '\n'; // Last byte of second chunk
    buf[32] = '\n'; // First byte of third chunk
    try std.testing.expectEqual(@as(usize, 4), countNewlines(&buf));
}

test "countEmptyLines handles edges and vector blocks" {
    try std.testing.expectEqual(@as(usize, 0), countEmptyLines(""));
    try std.testing.expectEqual(@as(usize, 1), countEmptyLines("\n"));
    try std.testing.expectEqual(@as(usize, 2), countEmptyLines("\n\n"));
    try std.testing.expectEqual(@as(usize, 2), countEmptyLines("text\n\n\nlast\n"));

    var data: [96]u8 = [_]u8{'x'} ** 96;
    data[0] = '\n';
    data[31] = '\n';
    data[32] = '\n';
    data[63] = '\n';
    data[64] = '\n';
    try std.testing.expectEqual(@as(usize, 3), countEmptyLines(&data));
}

test "special ASCII fold detection handles vector boundaries and class selection" {
    var data: [4 * VECTOR_WIDTH + 8]u8 = [_]u8{'x'} ** (4 * VECTOR_WIDTH + 8);
    @memcpy(data[VECTOR_WIDTH - 1 ..][0.."K".len], "K");
    @memcpy(data[3 * VECTOR_WIDTH - 1 ..][0.."ſ".len], "ſ");

    try std.testing.expect(containsSpecialFold(&data, true, false));
    try std.testing.expect(containsSpecialFold(&data, false, true));
    try std.testing.expect(containsSpecialFold(&data, true, true));
    try std.testing.expect(!containsSpecialFold("plain UTF-8 αβγ", true, true));
    try std.testing.expect(!containsSpecialFold("\x84\xaa and \xc5x\xbf", true, true));
}
