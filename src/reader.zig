const std = @import("std");
const simd = @import("simd.zig");
const aho_corasick = @import("aho_corasick.zig");

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
/// Matches ripgrep's approach: 64KB buffer with dynamic growth for long lines.
///
/// Key benefits over mmap:
/// - Constant memory usage regardless of file size
/// - No page fault overhead (data in userspace buffer)
/// - Better cache locality (64KB fits in L2)
/// - Efficient OS read-ahead for sequential access
pub const StreamingLineReader = struct {
    file: std.fs.File,
    buffer: []u8,
    allocator: std.mem.Allocator,

    // Buffer state
    data_start: usize, // Start of unprocessed data in buffer
    data_end: usize, // End of valid data in buffer
    line_number: usize, // Current line number (1-indexed)
    eof_reached: bool, // True when file is exhausted

    // Binary detection
    binary_checked: bool, // True after first buffer checked for binary
    is_binary: bool, // True if binary file detected

    const DEFAULT_BUFFER_SIZE: usize = 1024 * 1024; // 1MB for better I/O efficiency
    const MAX_BUFFER_SIZE: usize = 1024 * 1024; // 1MB max for long lines

    pub const Line = struct {
        content: []const u8,
        number: usize,
    };

    /// Initialize a streaming reader for the given file path.
    pub fn init(allocator: std.mem.Allocator, path: []const u8) !StreamingLineReader {
        const file = try std.fs.cwd().openFile(path, .{});
        errdefer file.close();

        // Hint to kernel that we'll read sequentially - improves prefetching
        // This matches mmap's MADV_SEQUENTIAL behavior
        if (@hasDecl(std.posix, "fadvise")) {
            std.posix.fadvise(file.handle, 0, 0, std.posix.POSIX_FADV.SEQUENTIAL) catch {};
        }

        const buffer = try allocator.alloc(u8, DEFAULT_BUFFER_SIZE);
        errdefer allocator.free(buffer);

        return .{
            .file = file,
            .buffer = buffer,
            .allocator = allocator,
            .data_start = 0,
            .data_end = 0,
            .line_number = 0,
            .eof_reached = false,
            .binary_checked = false,
            .is_binary = false,
        };
    }

    pub fn deinit(self: *StreamingLineReader) void {
        self.allocator.free(self.buffer);
        self.file.close();
    }

    /// Check if this is a binary file (call after at least one next() call)
    pub fn isBinary(self: *const StreamingLineReader) bool {
        return self.is_binary;
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

    /// Refill buffer, preserving partial line at start.
    /// Returns false if no progress can be made or binary detected.
    fn refillBuffer(self: *StreamingLineReader) bool {
        const available_len = self.data_end - self.data_start;

        // Roll: move unprocessed data to start of buffer
        if (self.data_start > 0 and available_len > 0) {
            std.mem.copyForwards(u8, self.buffer[0..available_len], self.buffer[self.data_start..self.data_end]);
        }
        self.data_start = 0;
        self.data_end = available_len;

        // Check if buffer is full (line longer than buffer)
        if (self.data_end >= self.buffer.len) {
            // Try to grow buffer for long line
            if (self.buffer.len >= MAX_BUFFER_SIZE) {
                // Hit max size - treat buffer contents as "line" and continue
                // This handles pathological cases with extremely long lines
                return false;
            }

            // Double buffer size using realloc
            const new_size = @min(self.buffer.len * 2, MAX_BUFFER_SIZE);
            const new_buffer = self.allocator.realloc(self.buffer, new_size) catch {
                return false; // Can't grow buffer
            };
            self.buffer = new_buffer;
        }

        // Read more data into buffer
        const bytes_read = self.file.read(self.buffer[self.data_end..]) catch {
            return false; // Read error
        };

        if (bytes_read == 0) {
            self.eof_reached = true;
            return true; // Progress: now we know we're at EOF
        }

        self.data_end += bytes_read;

        // Binary detection on first read (check first 8KB for NUL bytes)
        if (!self.binary_checked) {
            self.binary_checked = true;
            const check_len = @min(self.data_end, 8192);
            for (self.buffer[0..check_len]) |byte| {
                if (byte == 0) {
                    self.is_binary = true;
                    return false;
                }
            }
        }

        return true;
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

    const file = try tmp_dir.dir.createFile("test.txt", .{});
    try file.writeAll("line1\nline2\nline3");
    file.close();

    // Get the full path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("test.txt", &path_buf);

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

    const file = try tmp_dir.dir.createFile("empty.txt", .{});
    file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("empty.txt", &path_buf);

    var reader = try StreamingLineReader.init(allocator, path);
    defer reader.deinit();

    try std.testing.expect(reader.next() == null);
}

test "StreamingLineReader trailing newline" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("trailing.txt", .{});
    try file.writeAll("line1\nline2\n");
    file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("trailing.txt", &path_buf);

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

    const file = try tmp_dir.dir.createFile("binary.txt", .{});
    try file.writeAll("text\x00binary");
    file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("binary.txt", &path_buf);

    var reader = try StreamingLineReader.init(allocator, path);
    defer reader.deinit();

    // Should return null after detecting binary
    try std.testing.expect(reader.next() == null);
    try std.testing.expect(reader.isBinary());
}

test "StreamingLineReader consecutive newlines" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("consecutive.txt", .{});
    try file.writeAll("line1\n\nline3");
    file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("consecutive.txt", &path_buf);

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
