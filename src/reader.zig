const std = @import("std");
const builtin = @import("builtin");
const matcher_mod = @import("matcher.zig");
const simd = @import("simd.zig");
const aho_corasick = @import("aho_corasick.zig");
const io = std.Io.Threaded.global_single_threaded.io();

/// Line iterator for processing file content line by line
pub const LineIterator = struct {
    data: []const u8,
    pos: usize,
    line_number: usize,

    pub fn init(data: []const u8) LineIterator {
        return .{
            .data = data,
            .pos = 0,
            .line_number = 0,
        };
    }

    pub const Line = struct {
        content: []const u8,
        number: usize,
    };

    pub fn next(self: *LineIterator) ?Line {
        if (self.pos >= self.data.len) return null;

        const start = self.pos;
        self.line_number += 1;

        // Use SIMD to find the next newline
        if (simd.findNewline(self.data[self.pos..])) |offset| {
            self.pos = self.pos + offset + 1;
            return Line{
                .content = self.data[start .. self.pos - 1], // Exclude newline
                .number = self.line_number,
            };
        } else {
            // Last line without trailing newline
            self.pos = self.data.len;
            return Line{
                .content = self.data[start..],
                .number = self.line_number,
            };
        }
    }
};

// Tests
test "LineIterator basic" {
    const data = "line1\nline2\nline3";
    var iter = LineIterator.init(data);

    const l1 = iter.next().?;
    try std.testing.expectEqualStrings("line1", l1.content);
    try std.testing.expectEqual(@as(usize, 1), l1.number);

    const l2 = iter.next().?;
    try std.testing.expectEqualStrings("line2", l2.content);
    try std.testing.expectEqual(@as(usize, 2), l2.number);

    const l3 = iter.next().?;
    try std.testing.expectEqualStrings("line3", l3.content);
    try std.testing.expectEqual(@as(usize, 3), l3.number);

    try std.testing.expect(iter.next() == null);
}

test "readFile buffered" {
    // This test would need a real file - skipping for now
}

test "LineIterator empty input" {
    var iter = LineIterator.init("");
    try std.testing.expect(iter.next() == null);
}

test "LineIterator single line no newline" {
    const data = "single line without newline";
    var iter = LineIterator.init(data);

    const line = iter.next().?;
    try std.testing.expectEqualStrings("single line without newline", line.content);
    try std.testing.expectEqual(@as(usize, 1), line.number);

    try std.testing.expect(iter.next() == null);
}

test "LineIterator trailing newline" {
    const data = "line1\nline2\n";
    var iter = LineIterator.init(data);

    const l1 = iter.next().?;
    try std.testing.expectEqualStrings("line1", l1.content);

    const l2 = iter.next().?;
    try std.testing.expectEqualStrings("line2", l2.content);

    // No third line - trailing newline doesn't create empty line
    try std.testing.expect(iter.next() == null);
}

test "LineIterator consecutive newlines" {
    const data = "line1\n\nline3";
    var iter = LineIterator.init(data);

    const l1 = iter.next().?;
    try std.testing.expectEqualStrings("line1", l1.content);
    try std.testing.expectEqual(@as(usize, 1), l1.number);

    const l2 = iter.next().?;
    try std.testing.expectEqualStrings("", l2.content); // Empty line
    try std.testing.expectEqual(@as(usize, 2), l2.number);

    const l3 = iter.next().?;
    try std.testing.expectEqualStrings("line3", l3.content);
    try std.testing.expectEqual(@as(usize, 3), l3.number);

    try std.testing.expect(iter.next() == null);
}

test "LineIterator line numbers correct" {
    const data = "a\nb\nc\nd\ne";
    var iter = LineIterator.init(data);

    for (1..6) |expected_num| {
        const line = iter.next().?;
        try std.testing.expectEqual(expected_num, line.number);
    }

    try std.testing.expect(iter.next() == null);
}

test "LineIterator single newline" {
    const data = "\n";
    var iter = LineIterator.init(data);

    const line = iter.next().?;
    try std.testing.expectEqualStrings("", line.content);
    try std.testing.expectEqual(@as(usize, 1), line.number);

    try std.testing.expect(iter.next() == null);
}

test "LineIterator windows line endings" {
    // Note: Current implementation only handles \n, not \r\n
    // This test documents the behavior
    const data = "line1\r\nline2";
    var iter = LineIterator.init(data);

    const l1 = iter.next().?;
    // \r will be included in the line content
    try std.testing.expectEqualStrings("line1\r", l1.content);

    const l2 = iter.next().?;
    try std.testing.expectEqualStrings("line2", l2.content);
}

// =============================================================================
// StreamingLineReader - Memory-efficient streaming file reader
// =============================================================================

/// Streaming line reader for memory-efficient file searching.
/// Uses a rolling buffer to handle lines spanning buffer boundaries.
/// Uses a 256 KiB base buffer with dynamic growth for long lines.
///
/// Key benefits over mmap:
/// - Constant memory usage regardless of file size
/// - No page fault overhead (data in userspace buffer)
/// - Bounded per-worker memory and predictable cache locality
/// - Efficient OS read-ahead for sequential access
pub const StreamingLineReader = struct {
    file: std.Io.File,
    owns_file: bool,
    buffer: []u8,
    mapped_data: ?[]align(std.heap.page_size_min) u8,
    mapped_advised_until: usize,
    allocator: std.mem.Allocator,

    // Buffer state
    data_start: usize, // Start of unprocessed data in buffer
    data_end: usize, // End of valid data in buffer
    line_number: usize, // Current line number (1-indexed)
    eof_reached: bool, // True when file is exhausted

    // Binary detection
    is_binary: bool, // True if binary file detected
    binary_scan_all: bool,
    binary_initial_checked: bool,
    binary_byte_offset: ?usize,
    buffer_byte_offset: usize,

    // Large enough to amortize matcher setup and read syscalls while keeping
    // eight recursive workers below ripgrep's typical per-process RSS.
    const DEFAULT_BUFFER_SIZE: usize = 256 * 1024;
    // Explicit regular files can avoid the page-cache-to-userspace copy by
    // searching a mapping. Process and release it in bounded windows so RSS
    // does not grow with multi-gigabyte inputs as an unreclaimed mmap does.
    const MMAP_MIN_SIZE: usize = 1024 * 1024;
    const MMAP_WINDOW_SIZE: usize = 8 * 1024 * 1024;

    pub const Line = struct {
        content: []const u8,
        number: usize,
    };

    /// Initialize a streaming reader for the given file path.
    pub fn init(allocator: std.mem.Allocator, path: []const u8) !StreamingLineReader {
        return initWithBinaryScan(allocator, path, true);
    }

    /// Recursive and streamed inputs probe every buffer. For an explicitly
    /// named regular file, probing the initial 64 KiB mirrors ripgrep's mmap
    /// strategy; later NULs are checked if their line becomes a match.
    pub fn initWithBinaryScan(allocator: std.mem.Allocator, path: []const u8, binary_scan_all: bool) !StreamingLineReader {
        return initWithOptions(allocator, path, binary_scan_all, DEFAULT_BUFFER_SIZE);
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, path: []const u8, binary_scan_all: bool, buffer_size: usize) !StreamingLineReader {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);

        if (!binary_scan_all and comptime builtin.os.tag != .windows) {
            const stat = try file.stat(io);
            if (stat.kind == .file and stat.size >= MMAP_MIN_SIZE and stat.size <= std.math.maxInt(usize)) {
                const mapped = try std.posix.mmap(
                    null,
                    @intCast(stat.size),
                    .{ .READ = true },
                    .{ .TYPE = .PRIVATE },
                    file.handle,
                    0,
                );

                // Keep an initially detected explicit binary input on the
                // writable streaming path so its binary offset is retained.
                if (simd.findByteValue(mapped[0..@min(mapped.len, 64 * 1024)], 0) == null) {
                    std.posix.madvise(mapped.ptr, mapped.len, std.posix.MADV.SEQUENTIAL) catch {};
                    return .{
                        .file = file,
                        .owns_file = true,
                        .buffer = mapped,
                        .mapped_data = mapped,
                        .mapped_advised_until = 0,
                        .allocator = allocator,
                        .data_start = 0,
                        .data_end = mapped.len,
                        .line_number = 0,
                        .eof_reached = true,
                        .is_binary = false,
                        .binary_scan_all = false,
                        .binary_initial_checked = true,
                        .binary_byte_offset = null,
                        .buffer_byte_offset = 0,
                    };
                }
                std.posix.munmap(mapped);
            }
        }

        var result = try initFileWithBuffer(allocator, file, true, buffer_size);
        result.binary_scan_all = binary_scan_all;
        return result;
    }

    /// Initialize a streaming reader around an existing file handle. When
    /// `owns_file` is false, deinit leaves the handle open (used for stdin).
    pub fn initFile(allocator: std.mem.Allocator, file: std.Io.File, owns_file: bool) !StreamingLineReader {
        return initFileWithBuffer(allocator, file, owns_file, DEFAULT_BUFFER_SIZE);
    }

    pub fn initFileWithBuffer(allocator: std.mem.Allocator, file: std.Io.File, owns_file: bool, buffer_size: usize) !StreamingLineReader {

        // Hint to kernel that we'll read sequentially - improves prefetching
        // This matches mmap's MADV_SEQUENTIAL behavior
        if (@hasDecl(std.posix, "fadvise")) {
            std.posix.fadvise(file.handle, 0, 0, std.posix.POSIX_FADV.SEQUENTIAL) catch {};
        }

        const buffer = try allocator.alloc(u8, buffer_size);
        errdefer allocator.free(buffer);

        return .{
            .file = file,
            .owns_file = owns_file,
            .buffer = buffer,
            .mapped_data = null,
            .mapped_advised_until = 0,
            .allocator = allocator,
            .data_start = 0,
            .data_end = 0,
            .line_number = 0,
            .eof_reached = false,
            .is_binary = false,
            .binary_scan_all = !owns_file,
            .binary_initial_checked = false,
            .binary_byte_offset = null,
            .buffer_byte_offset = 0,
        };
    }

    pub fn deinit(self: *StreamingLineReader) void {
        if (self.mapped_data) |mapped| {
            std.posix.munmap(mapped);
        } else {
            self.allocator.free(self.buffer);
        }
        if (self.owns_file) self.file.close(io);
    }

    /// Check if this is a binary file (call after at least one next() call)
    pub fn isBinary(self: *const StreamingLineReader) bool {
        return self.is_binary;
    }

    pub fn binaryByteOffset(self: *const StreamingLineReader) ?usize {
        return self.binary_byte_offset;
    }

    pub fn quitsOnBinary(self: *const StreamingLineReader) bool {
        return self.binary_scan_all;
    }

    /// Get next complete line, refilling buffer as needed.
    /// Returns null when EOF reached or binary file detected.
    pub fn next(self: *StreamingLineReader) ?Line {
        // Binary file - stop processing
        if (self.is_binary) return null;

        while (true) {
            // Try to find newline in current buffer data
            const available = self.buffer[self.data_start..self.data_end];

            if (simd.findNewline(available)) |newline_offset| {
                // Found complete line
                self.line_number += 1;
                const line_content = available[0..newline_offset];
                self.data_start += newline_offset + 1;

                return Line{
                    .content = line_content,
                    .number = self.line_number,
                };
            }

            // No newline found - check if we're at EOF
            if (self.eof_reached) {
                // Last line without trailing newline
                if (available.len > 0) {
                    self.line_number += 1;
                    self.data_start = self.data_end; // Mark as consumed
                    return Line{
                        .content = available,
                        .number = self.line_number,
                    };
                }
                return null; // Truly done
            }

            // Need to read more data
            if (!self.refillBuffer()) {
                // Read error, binary detected, or line too long
                return null;
            }
        }
    }

    /// Refill buffer, preserving partial line at start. This fallible version
    /// is used by the production search path so read and allocation failures
    /// are never confused with EOF.
    fn refillBufferFallible(self: *StreamingLineReader) !bool {
        std.debug.assert(self.mapped_data == null);
        const available_len = self.data_end - self.data_start;
        self.buffer_byte_offset += self.data_start;

        // Roll: move unprocessed data to start of buffer
        if (self.data_start > 0 and available_len > 0) {
            std.mem.copyForwards(u8, self.buffer[0..available_len], self.buffer[self.data_start..self.data_end]);
        }
        self.data_start = 0;
        self.data_end = available_len;

        // A complete matching line must remain available for normal grep
        // output. Grow without an arbitrary line-length limit. Modes that can
        // stop at the first match still terminate before reading more data.
        if (self.data_end >= self.buffer.len) {
            const new_size = std.math.mul(usize, self.buffer.len, 2) catch return error.OutOfMemory;
            self.buffer = try self.allocator.realloc(self.buffer, new_size);
        }

        // Read more data into buffer
        const read_start = self.data_end;
        const bytes_read = self.file.readStreaming(io, &.{self.buffer[self.data_end..]}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };

        if (bytes_read == 0) {
            self.eof_reached = true;
            return true; // Progress: now we know we're at EOF
        }

        self.data_end += bytes_read;

        // Streamed and recursively discovered inputs probe every read. An
        // explicit regular file only probes the same initial 64 KiB used by a
        // typical line buffer, avoiding a second full memory pass on mmap-like
        // workloads. Matching lines are checked separately below.
        const new_data = self.buffer[read_start..self.data_end];
        const probe = if (self.binary_scan_all)
            new_data
        else if (!self.binary_initial_checked)
            new_data[0..@min(new_data.len, 64 * 1024)]
        else
            new_data[0..0];
        self.binary_initial_checked = true;
        if (simd.findByteValue(probe, 0)) |nul_offset| {
            self.is_binary = true;
            self.binary_byte_offset = self.buffer_byte_offset + read_start + nul_offset;

            if (self.binary_scan_all) {
                // Implicit files use NUL as an EOF marker and discard the read
                // that exposed it. Matches flushed from earlier reads remain
                // valid and receive a warning; this read was never searched.
                self.eof_reached = true;
                return false;
            }

            // Explicit regular files are never filtered. Search the original
            // bytes and let the output layer suppress binary match content.
            // This also matches ripgrep's mmap behavior for expressions that
            // can match a NUL byte (for example `foo.*bar`).
        }

        return true;
    }

    /// Compatibility wrapper for the older optional-return line iterator.
    /// New search code uses refillBufferFallible directly.
    fn refillBuffer(self: *StreamingLineReader) bool {
        return self.refillBufferFallible() catch false;
    }

    /// Search complete lines in bulk with the supplied matcher. Files and
    /// stdin share this implementation, so matching begins as soon as bytes
    /// arrive and memory is bounded by the longest line rather than input size.
    ///
    /// The callback returns false to stop the current source immediately (for
    /// example, `-l`) and may propagate output/allocation errors.
    pub fn searchMatcher(
        self: *StreamingLineReader,
        pattern_matcher: anytype,
        callback: anytype,
        track_line_numbers: bool,
        need_match_span: bool,
        suppress_explicit_binary: bool,
    ) !bool {
        if (self.is_binary and self.binary_scan_all) return false;

        var found_any = false;

        while (true) {
            if (self.data_start == self.data_end) {
                if (self.eof_reached) break;
                if (!try self.refillBufferFallible()) break;
                continue;
            }

            const available = self.buffer[self.data_start..self.data_end];

            // Only expose complete lines to matching and output. Preserve an
            // incomplete trailing line for the next refill; at EOF it is a
            // complete unterminated final line.
            const process_len = if (self.mapped_data != null and available.len > MMAP_WINDOW_SIZE)
                if (std.mem.lastIndexOfScalar(u8, available[0..MMAP_WINDOW_SIZE], '\n')) |newline|
                    newline + 1
                else
                    MMAP_WINDOW_SIZE + (if (simd.findNewline(available[MMAP_WINDOW_SIZE..])) |newline|
                        newline + 1
                    else
                        available.len - MMAP_WINDOW_SIZE)
            else if (self.eof_reached)
                available.len
            else if (std.mem.lastIndexOfScalar(u8, available, '\n')) |newline|
                newline + 1
            else {
                if (!try self.refillBufferFallible()) break;
                continue;
            };

            if (process_len == 0) {
                if (self.eof_reached) break;
                if (!try self.refillBufferFallible()) break;
                continue;
            }

            const data = available[0..process_len];
            var search_pos: usize = 0;
            var counted_pos: usize = 0;
            var current_line = self.line_number + 1;

            while (search_pos <= data.len) {
                const match_result: matcher_mod.MatchResult = if (need_match_span)
                    pattern_matcher.findFirstFrom(data, search_pos) orelse break
                else blk: {
                    const match_end = pattern_matcher.findFirstEndFrom(data, search_pos) orelse break;
                    break :blk .{ .start = match_end, .end = match_end };
                };

                // A trailing newline terminates the previous line; it does not
                // create an additional empty line at EOF. An empty regex such
                // as ^$ may otherwise report a phantom final match at data.len.
                if (match_result.start == data.len and data.len > 0 and data[data.len - 1] == '\n') break;

                // The matcher is configured for line-oriented searching, but
                // derive exact line bounds only after it reports a candidate.
                const line_start = if (std.mem.lastIndexOfScalar(u8, data[0..match_result.start], '\n')) |newline|
                    newline + 1
                else
                    0;
                const line_end = if (match_result.end < data.len)
                    match_result.end + (simd.findNewline(data[match_result.end..]) orelse (data.len - match_result.end))
                else
                    data.len;

                // mmap-style explicit-file probing checks later binary data
                // only when it occurs on a line that would otherwise match.
                if (!self.binary_scan_all) {
                    if (simd.findByteValue(data[line_start..line_end], 0)) |nul_offset| {
                        self.is_binary = true;
                        if (self.binary_byte_offset == null) {
                            self.binary_byte_offset = self.buffer_byte_offset + self.data_start + line_start + nul_offset;
                        }
                    }
                }

                // Standard grep output for an explicitly supplied binary file
                // is a summary, not the matching bytes themselves. Count and
                // files-with-matches modes still invoke their callbacks.
                if (self.is_binary and !self.binary_scan_all and suppress_explicit_binary) {
                    found_any = true;
                    return true;
                }

                if (track_line_numbers) {
                    current_line += simd.countNewlines(data[counted_pos..line_start]);
                }
                found_any = true;

                const keep_going = try callback.call(Line{
                    .content = data[line_start..line_end],
                    .number = current_line,
                }, match_result.start - line_start, match_result.end - line_start);
                if (!keep_going) return found_any;

                // One result per matching line, as required by normal, count
                // and files-with-matches grep modes.
                if (line_end < data.len and data[line_end] == '\n') {
                    search_pos = line_end + 1;
                    counted_pos = search_pos;
                    if (track_line_numbers) current_line += 1;
                } else {
                    search_pos = data.len;
                    counted_pos = data.len;
                    break;
                }
            }

            if (track_line_numbers) {
                self.line_number += simd.countNewlines(data);
                if (self.eof_reached and data.len > 0 and data[data.len - 1] != '\n') {
                    self.line_number += 1;
                }
            }

            self.data_start += process_len;
            self.releaseProcessedMappedPages();
            if (self.eof_reached and self.data_start == self.data_end) break;
        }

        return found_any;
    }

    /// Specialized count path for plain byte literals. It fuses literal,
    /// newline and matching-line NUL discovery instead of re-entering the
    /// generic match/callback path once per matching line. A null result means
    /// this matcher shape is unsupported and the caller should use
    /// `searchMatcher`.
    pub fn searchCountMatcher(self: *StreamingLineReader, pattern_matcher: *const matcher_mod.Matcher) !?usize {
        const use_literal = pattern_matcher.supportsFastLineCount();
        const use_multi_literal = pattern_matcher.supportsFastMultiLiteralLineCount();
        const use_regex = pattern_matcher.supportsFastRegexLineCount();
        if (!use_literal and !use_multi_literal and !use_regex) return null;
        if (self.is_binary and self.binary_scan_all) return 0;

        var count: usize = 0;
        var strategy_selected = false;
        while (true) {
            if (self.data_start == self.data_end) {
                if (self.eof_reached) break;
                if (!try self.refillBufferFallible()) break;
                continue;
            }

            const available = self.buffer[self.data_start..self.data_end];
            const process_len = if (self.mapped_data != null and available.len > MMAP_WINDOW_SIZE)
                if (std.mem.lastIndexOfScalar(u8, available[0..MMAP_WINDOW_SIZE], '\n')) |newline|
                    newline + 1
                else
                    MMAP_WINDOW_SIZE + (if (simd.findNewline(available[MMAP_WINDOW_SIZE..])) |newline|
                        newline + 1
                    else
                        available.len - MMAP_WINDOW_SIZE)
            else if (self.eof_reached)
                available.len
            else if (std.mem.lastIndexOfScalar(u8, available, '\n')) |newline|
                newline + 1
            else {
                if (!try self.refillBufferFallible()) break;
                continue;
            };

            if (process_len == 0) {
                if (self.eof_reached) break;
                if (!try self.refillBufferFallible()) break;
                continue;
            }

            if (!strategy_selected) {
                if (use_literal and !pattern_matcher.shouldFuseLiteralLineCount(available[0..process_len])) return null;
                strategy_selected = true;
            }
            const result = if (use_literal)
                pattern_matcher.countLiteralLines(available[0..process_len], !self.binary_scan_all) orelse unreachable
            else if (use_multi_literal)
                pattern_matcher.countMultiLiteralLines(available[0..process_len], !self.binary_scan_all) orelse unreachable
            else
                pattern_matcher.countRegexLines(available[0..process_len], !self.binary_scan_all) orelse unreachable;
            count += result.count;
            if (result.binary_offset) |offset| {
                self.is_binary = true;
                if (self.binary_byte_offset == null) {
                    self.binary_byte_offset = self.buffer_byte_offset + self.data_start + offset;
                }
            }

            self.data_start += process_len;
            self.releaseProcessedMappedPages();
            if (self.eof_reached and self.data_start == self.data_end) break;
        }
        return count;
    }

    fn releaseProcessedMappedPages(self: *StreamingLineReader) void {
        const mapped = self.mapped_data orelse return;
        const page_size = std.heap.pageSize();
        const drop_until = std.mem.alignBackward(usize, self.data_start, page_size);
        if (drop_until <= self.mapped_advised_until) return;
        const ptr: [*]align(std.heap.page_size_min) u8 = @alignCast(mapped.ptr + self.mapped_advised_until);
        std.posix.madvise(
            ptr,
            drop_until - self.mapped_advised_until,
            std.posix.MADV.DONTNEED,
        ) catch {};
        self.mapped_advised_until = drop_until;
    }

    /// Search the buffer for a literal pattern and return matching lines.
    /// This is much faster than line-by-line searching because it only
    /// processes lines that actually contain matches.
    ///
    /// callback is called with each matching line (Line, match_start, match_end).
    /// Returns true if any matches were found.
    pub fn searchLiteral(self: *StreamingLineReader, pattern: []const u8, callback: anytype) bool {
        if (self.is_binary or pattern.len == 0) return false;

        var found_any = false;

        // Process buffers until EOF
        while (true) {
            // Ensure we have data in buffer
            if (self.data_end == self.data_start) {
                if (self.eof_reached) break;
                if (!self.refillBuffer()) break;
                continue;
            }

            const buffer_data = self.buffer[self.data_start..self.data_end];

            // Track position in buffer for incremental line counting
            var last_counted_pos: usize = 0;
            var current_line = self.line_number + 1; // 1-indexed

            // Search entire buffer for pattern
            var search_pos: usize = 0;
            while (search_pos < buffer_data.len) {
                // Find pattern in remaining buffer
                const match_pos = simd.findSubstringFrom(buffer_data, pattern, search_pos) orelse break;

                found_any = true;

                // Find line start (search backwards for newline)
                var line_start: usize = match_pos;
                while (line_start > 0 and buffer_data[line_start - 1] != '\n') {
                    line_start -= 1;
                }

                // Find line end (search forwards for newline)
                var line_end: usize = match_pos + pattern.len;
                while (line_end < buffer_data.len and buffer_data[line_end] != '\n') {
                    line_end += 1;
                }

                // Count newlines incrementally from last_counted_pos to line_start
                // This avoids O(n²) behavior when there are many matches
                // Use SIMD for faster counting
                current_line += simd.countNewlines(buffer_data[last_counted_pos..line_start]);
                last_counted_pos = line_start;

                const line_content = buffer_data[line_start..line_end];
                const match_in_line_start = match_pos - line_start;
                const match_in_line_end = match_in_line_start + pattern.len;

                // Call callback with match info
                callback.call(Line{
                    .content = line_content,
                    .number = current_line,
                }, match_in_line_start, match_in_line_end);

                // Move past this line to avoid duplicate matches on same line
                search_pos = line_end + 1;
            }

            // Keep pattern.len - 1 bytes at end in case pattern spans buffer boundary
            // This ensures we don't miss matches that straddle two reads
            const keep_bytes = @min(pattern.len - 1, buffer_data.len);
            const consumed_len = buffer_data.len - keep_bytes;

            // Count remaining newlines from last_counted_pos to end of consumed portion
            // Use SIMD for faster counting
            current_line += simd.countNewlines(buffer_data[last_counted_pos..consumed_len]);
            self.line_number = current_line - 1; // Convert back to 0-indexed for storage

            // Move to keep only the lookback bytes
            self.data_start = self.data_end - keep_bytes;

            if (self.eof_reached) break;
            if (!self.refillBuffer()) break;
        }

        return found_any;
    }

    /// Search the buffer for a literal pattern case-insensitively.
    /// Same as searchLiteral but uses case-insensitive matching.
    pub fn searchLiteralIgnoreCase(self: *StreamingLineReader, pattern: []const u8, callback: anytype) bool {
        if (self.is_binary or pattern.len == 0) return false;

        var found_any = false;

        // Process buffers until EOF
        while (true) {
            // Ensure we have data in buffer
            if (self.data_end == self.data_start) {
                if (self.eof_reached) break;
                if (!self.refillBuffer()) break;
                continue;
            }

            const buffer_data = self.buffer[self.data_start..self.data_end];

            // Track position in buffer for incremental line counting
            var last_counted_pos: usize = 0;
            var current_line = self.line_number + 1; // 1-indexed

            // Search entire buffer for pattern (case-insensitive)
            var search_pos: usize = 0;
            while (search_pos < buffer_data.len) {
                // Find pattern in remaining buffer (case-insensitive)
                const match_pos = simd.findSubstringFromIgnoreCase(buffer_data, pattern, search_pos) orelse break;

                found_any = true;

                // Find line start (search backwards for newline)
                var line_start: usize = match_pos;
                while (line_start > 0 and buffer_data[line_start - 1] != '\n') {
                    line_start -= 1;
                }

                // Find line end (search forwards for newline)
                var line_end: usize = match_pos + pattern.len;
                while (line_end < buffer_data.len and buffer_data[line_end] != '\n') {
                    line_end += 1;
                }

                // Count newlines incrementally from last_counted_pos to line_start
                // Use SIMD for faster counting
                current_line += simd.countNewlines(buffer_data[last_counted_pos..line_start]);
                last_counted_pos = line_start;

                const line_content = buffer_data[line_start..line_end];
                const match_in_line_start = match_pos - line_start;
                const match_in_line_end = match_in_line_start + pattern.len;

                // Call callback with match info
                callback.call(Line{
                    .content = line_content,
                    .number = current_line,
                }, match_in_line_start, match_in_line_end);

                // Move past this line to avoid duplicate matches on same line
                search_pos = line_end + 1;
            }

            // Keep pattern.len - 1 bytes at end in case pattern spans buffer boundary
            const keep_bytes = @min(pattern.len - 1, buffer_data.len);
            const consumed_len = buffer_data.len - keep_bytes;

            // Count remaining newlines from last_counted_pos to end of consumed portion
            // Use SIMD for faster counting
            current_line += simd.countNewlines(buffer_data[last_counted_pos..consumed_len]);
            self.line_number = current_line - 1;

            // Move to keep only the lookback bytes
            self.data_start = self.data_end - keep_bytes;

            if (self.eof_reached) break;
            if (!self.refillBuffer()) break;
        }

        return found_any;
    }

    /// Search for multiple literal patterns using Aho-Corasick automaton with a callback.
    /// This is much faster than line-by-line searching for alternation patterns like "foo|bar|baz".
    /// If ignore_case is true, performs case-insensitive matching by lowercasing the buffer.
    ///
    /// callback is called with each matching line (Line, match_start, match_end).
    /// Returns true if any matches were found.
    pub fn searchMultiLiteralWithCallback(
        self: *StreamingLineReader,
        ac: *const aho_corasick.AhoCorasick,
        max_pattern_len: usize,
        callback: anytype,
        lower_buf: ?[]u8,
        ignore_case: bool,
    ) bool {
        if (self.is_binary) return false;

        var found_any = false;

        // Process buffers until EOF
        while (true) {
            // Ensure we have data in buffer
            if (self.data_end == self.data_start) {
                if (self.eof_reached) break;
                if (!self.refillBuffer()) break;
                continue;
            }

            const buffer_data = self.buffer[self.data_start..self.data_end];

            // For case-insensitive search, lowercase the buffer first
            var search_data: []const u8 = buffer_data;
            if (ignore_case) {
                if (lower_buf) |lb| {
                    const copy_len = @min(buffer_data.len, lb.len);
                    for (buffer_data[0..copy_len], 0..) |c, i| {
                        lb[i] = std.ascii.toLower(c);
                    }
                    search_data = lb[0..copy_len];
                }
            }

            // Track position in buffer for incremental line counting
            var last_counted_pos: usize = 0;
            var current_line = self.line_number + 1; // 1-indexed

            // Search entire buffer using Aho-Corasick
            var search_pos: usize = 0;
            while (search_pos < search_data.len) {
                // Find pattern in remaining buffer using AC
                const match_result = ac.findFirstFrom(search_data, search_pos) orelse break;
                const match_pos = match_result.start;
                const match_len = match_result.end - match_result.start;

                found_any = true;

                // Find line start (search backwards for newline) - use original buffer
                var line_start: usize = match_pos;
                while (line_start > 0 and buffer_data[line_start - 1] != '\n') {
                    line_start -= 1;
                }

                // Find line end (search forwards for newline) - use original buffer
                var line_end: usize = match_pos + match_len;
                while (line_end < buffer_data.len and buffer_data[line_end] != '\n') {
                    line_end += 1;
                }

                // Count newlines incrementally from last_counted_pos to line_start
                current_line += simd.countNewlines(buffer_data[last_counted_pos..line_start]);
                last_counted_pos = line_start;

                // Use original buffer_data for the line content (preserves original case)
                const line_content = buffer_data[line_start..line_end];
                const match_in_line_start = match_pos - line_start;
                const match_in_line_end = match_in_line_start + match_len;

                // Call callback with match info
                callback.call(Line{
                    .content = line_content,
                    .number = current_line,
                }, match_in_line_start, match_in_line_end);

                // Move past this line to avoid duplicate matches on same line
                search_pos = line_end + 1;
            }

            // Keep max_pattern_len - 1 bytes at end in case pattern spans buffer boundary
            const keep_bytes = @min(if (max_pattern_len > 0) max_pattern_len - 1 else 0, buffer_data.len);
            const consumed_len = buffer_data.len - keep_bytes;

            // Count remaining newlines from last_counted_pos to end of consumed portion
            current_line += simd.countNewlines(buffer_data[last_counted_pos..consumed_len]);
            self.line_number = current_line - 1;

            // Move to keep only the lookback bytes
            self.data_start = self.data_end - keep_bytes;

            if (self.eof_reached) break;
            if (!self.refillBuffer()) break;
        }

        return found_any;
    }
};

// StreamingLineReader Tests

test "StreamingLineReader basic" {
    const allocator = std.testing.allocator;

    // Create a temporary file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "test.txt", .{});
    try file.writeStreamingAll(io, "line1\nline2\nline3");
    file.close(io);

    // Get the full path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(io, "test.txt", &path_buf);
    const path = path_buf[0..path_len];

    var reader = try StreamingLineReader.init(allocator, path);
    defer reader.deinit();

    const l1 = reader.next().?;
    try std.testing.expectEqualStrings("line1", l1.content);
    try std.testing.expectEqual(@as(usize, 1), l1.number);

    const l2 = reader.next().?;
    try std.testing.expectEqualStrings("line2", l2.content);
    try std.testing.expectEqual(@as(usize, 2), l2.number);

    const l3 = reader.next().?;
    try std.testing.expectEqualStrings("line3", l3.content);
    try std.testing.expectEqual(@as(usize, 3), l3.number);

    try std.testing.expect(reader.next() == null);
}

test "StreamingLineReader empty file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "empty.txt", .{});
    file.close(io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(io, "empty.txt", &path_buf);
    const path = path_buf[0..path_len];

    var reader = try StreamingLineReader.init(allocator, path);
    defer reader.deinit();

    try std.testing.expect(reader.next() == null);
}

test "StreamingLineReader trailing newline" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "trailing.txt", .{});
    try file.writeStreamingAll(io, "line1\nline2\n");
    file.close(io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(io, "trailing.txt", &path_buf);
    const path = path_buf[0..path_len];

    var reader = try StreamingLineReader.init(allocator, path);
    defer reader.deinit();

    const l1 = reader.next().?;
    try std.testing.expectEqualStrings("line1", l1.content);

    const l2 = reader.next().?;
    try std.testing.expectEqualStrings("line2", l2.content);

    // No third line - trailing newline doesn't create empty line
    try std.testing.expect(reader.next() == null);
}

test "StreamingLineReader binary detection" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "binary.txt", .{});
    try file.writeStreamingAll(io, "text\x00binary");
    file.close(io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(io, "binary.txt", &path_buf);
    const path = path_buf[0..path_len];

    var reader = try StreamingLineReader.init(allocator, path);
    defer reader.deinit();

    // Should return null after detecting binary
    try std.testing.expect(reader.next() == null);
    try std.testing.expect(reader.isBinary());
}

test "StreamingLineReader preserves matches from reads before binary data" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "late-binary.txt", .{});
    try file.writeStreamingAll(io, "NEEDLE first\npadding line\npadding line\n\x00tail\n");
    file.close(io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(io, "late-binary.txt", &path_buf);
    const path = path_buf[0..path_len];

    var stream = try StreamingLineReader.initWithOptions(allocator, path, true, 16);
    defer stream.deinit();
    var matcher = try matcher_mod.Matcher.init(allocator, "NEEDLE", false, false);
    defer matcher.deinit();

    const Callback = struct {
        matches: usize = 0,

        pub fn call(self: *@This(), _: StreamingLineReader.Line, _: usize, _: usize) !bool {
            self.matches += 1;
            return true;
        }
    };
    var callback = Callback{};
    const found = try stream.searchMatcher(&matcher, &callback, false, false, false);

    try std.testing.expect(found);
    try std.testing.expectEqual(@as(usize, 1), callback.matches);
    try std.testing.expect(stream.isBinary());
    try std.testing.expectEqual(@as(?usize, 39), stream.binaryByteOffset());
}

test "sparse count fallback still searches explicit binary data" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "sparse-binary.txt", .{});
    try file.writeStreamingAll(io, "hit\x00padding\n");
    file.close(io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(io, "sparse-binary.txt", &path_buf);
    const path = path_buf[0..path_len];
    var stream = try StreamingLineReader.initWithOptions(allocator, path, false, 4096);
    defer stream.deinit();
    var matcher = try matcher_mod.Matcher.init(allocator, "hit", false, false);
    defer matcher.deinit();

    try std.testing.expect((try stream.searchCountMatcher(&matcher)) == null);
    const Callback = struct {
        count: usize = 0,

        pub fn call(ctx: *@This(), _: StreamingLineReader.Line, _: usize, _: usize) !bool {
            ctx.count += 1;
            return true;
        }
    };
    var callback = Callback{};
    try std.testing.expect(try stream.searchMatcher(&matcher, &callback, false, false, false));
    try std.testing.expectEqual(@as(usize, 1), callback.count);
    try std.testing.expect(stream.isBinary());
}

test "explicit binary regex count searches original NUL byte" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "binary-regex.txt", .{});
    try file.writeStreamingAll(io, "foo\x00bar\nfoo bar\n");
    file.close(io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(io, "binary-regex.txt", &path_buf);
    const path = path_buf[0..path_len];
    var stream = try StreamingLineReader.initWithOptions(allocator, path, false, 4096);
    defer stream.deinit();
    var matcher = try matcher_mod.Matcher.init(allocator, "foo.*bar", false, false);
    defer matcher.deinit();

    const Callback = struct {
        count: usize = 0,

        pub fn call(ctx: *@This(), _: StreamingLineReader.Line, _: usize, _: usize) !bool {
            ctx.count += 1;
            return true;
        }
    };
    var callback = Callback{};
    try std.testing.expect(try stream.searchMatcher(&matcher, &callback, false, false, false));
    try std.testing.expectEqual(@as(usize, 2), callback.count);
    try std.testing.expectEqual(@as(?usize, 3), stream.binaryByteOffset());
}

test "mapped fast count continues after a late binary match" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const line = "alpha pad\n";
    const line_count = 110_000;
    const binary_line = 7_000;
    const content = try allocator.alloc(u8, line.len * line_count);
    defer allocator.free(content);
    for (0..line_count) |i| @memcpy(content[i * line.len ..][0..line.len], line);
    content[binary_line * line.len + 5] = 0;

    const file = try tmp_dir.dir.createFile(io, "late-binary.txt", .{});
    try file.writeStreamingAll(io, content);
    file.close(io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(io, "late-binary.txt", &path_buf);
    const path = path_buf[0..path_len];
    var stream = try StreamingLineReader.initWithOptions(allocator, path, false, 64 * 1024);
    defer stream.deinit();
    try std.testing.expect(stream.mapped_data != null);

    var matcher = try matcher_mod.Matcher.init(allocator, "alpha", false, false);
    defer matcher.deinit();
    try std.testing.expectEqual(line_count, (try stream.searchCountMatcher(&matcher)).?);
    try std.testing.expectEqual(@as(?usize, binary_line * line.len + 5), stream.binaryByteOffset());
}

test "mapped reader searches and releases line-aligned windows" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "mapped.txt", .{});
    try file.writeStreamingAll(io, "NEEDLE before\n");
    var padding: [4096]u8 = [_]u8{'x'} ** 4096;
    padding[padding.len - 1] = '\n';
    for (0..2050) |_| try file.writeStreamingAll(io, &padding);
    try file.writeStreamingAll(io, "NEEDLE after\n");
    file.close(io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(io, "mapped.txt", &path_buf);
    const path = path_buf[0..path_len];
    var stream = try StreamingLineReader.initWithOptions(allocator, path, false, 64 * 1024);
    defer stream.deinit();
    try std.testing.expect(stream.mapped_data != null);

    var matcher = try matcher_mod.Matcher.init(allocator, "NEEDLE", false, false);
    defer matcher.deinit();
    const Callback = struct {
        matches: usize = 0,
        last_line: usize = 0,

        pub fn call(self: *@This(), line: StreamingLineReader.Line, _: usize, _: usize) !bool {
            self.matches += 1;
            self.last_line = line.number;
            return true;
        }
    };
    var callback = Callback{};
    try std.testing.expect(try stream.searchMatcher(&matcher, &callback, true, false, false));
    try std.testing.expectEqual(@as(usize, 2), callback.matches);
    try std.testing.expectEqual(@as(usize, 2052), callback.last_line);
    try std.testing.expect(stream.mapped_advised_until >= StreamingLineReader.MMAP_WINDOW_SIZE);
}

test "StreamingLineReader consecutive newlines" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(io, "consecutive.txt", .{});
    try file.writeStreamingAll(io, "line1\n\nline3");
    file.close(io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp_dir.dir.realPathFile(io, "consecutive.txt", &path_buf);
    const path = path_buf[0..path_len];

    var reader = try StreamingLineReader.init(allocator, path);
    defer reader.deinit();

    const l1 = reader.next().?;
    try std.testing.expectEqualStrings("line1", l1.content);

    const l2 = reader.next().?;
    try std.testing.expectEqualStrings("", l2.content); // Empty line

    const l3 = reader.next().?;
    try std.testing.expectEqualStrings("line3", l3.content);

    try std.testing.expect(reader.next() == null);
}
