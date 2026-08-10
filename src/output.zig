const std = @import("std");
const main = @import("main.zig");
const matcher_mod = @import("matcher.zig");
const io = std.Io.Threaded.global_single_threaded.io();

// ANSI color codes
const Color = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const blue = "\x1b[34m";
    const magenta = "\x1b[35m";
    const cyan = "\x1b[36m";

    const path = "\x1b[35m"; // magenta for file paths
    const line_num = "\x1b[32m"; // green for line numbers
    const match = "\x1b[0m\x1b[1m\x1b[31m"; // reset, then bold red for matches
    const separator = "\x1b[36m"; // cyan for separators
};

pub const Match = struct {
    file_path: []const u8,
    line_number: usize,
    line_content: []const u8,
    match_start: usize,
    match_end: usize,
};

/// Per-file output buffer - accumulates all matches for a file
/// then flushes them in one batch to reduce mutex contention
pub const FileBuffer = struct {
    buffer: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    match_count: usize,
    config: main.Config,
    use_color: bool,
    use_heading: bool,
    file_path: ?[]const u8,
    /// Skip filename prefix (for single stdin/file searches)
    skip_filename: bool,
    /// Resolved line number setting (accounts for TTY auto-detection)
    show_line_numbers: bool,

    pub fn init(allocator: std.mem.Allocator, config: main.Config, use_color: bool, use_heading: bool) FileBuffer {
        return initResolved(allocator, config, use_color, use_heading, config.showLineNumbers(use_color));
    }

    pub fn initResolved(
        allocator: std.mem.Allocator,
        config: main.Config,
        use_color: bool,
        use_heading: bool,
        show_line_numbers: bool,
    ) FileBuffer {
        return .{
            .buffer = .empty,
            .allocator = allocator,
            .match_count = 0,
            .config = config,
            .use_color = use_color,
            .use_heading = use_heading,
            .file_path = null,
            .skip_filename = config.is_single_source,
            .show_line_numbers = show_line_numbers,
        };
    }

    pub fn deinit(self: *FileBuffer) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn addMatch(self: *FileBuffer, match_data: Match) !void {
        return self.addMatchWithMatcher(match_data, null);
    }

    pub fn addMatchWithMatcher(self: *FileBuffer, match_data: Match, pattern_matcher: ?*const matcher_mod.Matcher) !void {
        var allocating: std.Io.Writer.Allocating = .fromArrayList(self.allocator, &self.buffer);
        defer self.buffer = allocating.toArrayList();
        const writer = &allocating.writer;

        if (self.use_heading) {
            // Grouped output format:
            // filepath
            // line_number:content
            // line_number:content
            //
            // filepath2
            // ...

            // Print file header on first match (skip for single stdin/file)
            if (self.match_count == 0) {
                self.file_path = match_data.file_path;
                if (!self.skip_filename or self.config.files_with_matches) {
                    if (self.use_color) {
                        try writer.print("{s}{s}{s}{s}\n", .{ Color.reset, Color.path, match_data.file_path, Color.reset });
                    } else {
                        try writer.print("{s}\n", .{match_data.file_path});
                    }
                }
            }

            self.match_count += 1;

            if (self.config.files_with_matches) {
                // Already printed header, nothing more to do
                return;
            }

            // Print line with colored match
            if (self.show_line_numbers) {
                if (self.use_color) {
                    try writer.print("{s}{s}{d}{s}:", .{
                        Color.reset,
                        Color.line_num,
                        match_data.line_number,
                        Color.reset,
                    });
                } else {
                    try writer.print("{d}:", .{match_data.line_number});
                }
            }

            // Print line content with highlighted match
            if (self.use_color and match_data.match_end <= match_data.line_content.len) {
                try writeHighlightedLine(writer, match_data, pattern_matcher);
            } else {
                try writer.print("{s}\n", .{match_data.line_content});
            }
        } else {
            // Flat output format:
            // filepath:line_number:content

            self.file_path = match_data.file_path;
            self.match_count += 1;

            if (self.config.files_with_matches) {
                // Just print the filename (always, even for single stdin)
                if (self.use_color) {
                    try writer.print("{s}{s}{s}{s}\n", .{ Color.reset, Color.path, match_data.file_path, Color.reset });
                } else {
                    try writer.print("{s}\n", .{match_data.file_path});
                }
                return;
            }

            // Print file path prefix (skip for single stdin/file)
            if (!self.skip_filename) {
                if (self.use_color) {
                    try writer.print("{s}{s}{s}{s}:", .{
                        Color.reset,
                        Color.path,
                        match_data.file_path,
                        Color.reset,
                    });
                } else {
                    try writer.print("{s}:", .{match_data.file_path});
                }
            }

            // Print line number if enabled
            if (self.show_line_numbers) {
                if (self.use_color) {
                    try writer.print("{s}{s}{d}{s}:", .{
                        Color.reset,
                        Color.line_num,
                        match_data.line_number,
                        Color.reset,
                    });
                } else {
                    try writer.print("{d}:", .{match_data.line_number});
                }
            }

            // Print line content with highlighted match
            if (self.use_color and match_data.match_end <= match_data.line_content.len) {
                try writeHighlightedLine(writer, match_data, pattern_matcher);
            } else {
                try writer.print("{s}\n", .{match_data.line_content});
            }
        }
    }

    fn writeHighlightedLine(writer: anytype, match_data: Match, pattern_matcher: ?*const matcher_mod.Matcher) !void {
        const initial = matcher_mod.MatchResult{ .start = match_data.match_start, .end = match_data.match_end };
        var current = firstNonEmptyMatch(match_data.line_content, initial, pattern_matcher) orelse {
            try writer.print("{s}\n", .{match_data.line_content});
            return;
        };
        var cursor = current.start;
        try writer.print("{s}{s}", .{ match_data.line_content[0..current.start], Color.match });
        while (current.end > current.start and current.end <= match_data.line_content.len) {
            try writer.print("{s}", .{match_data.line_content[current.start..current.end]});
            cursor = current.end;
            if (cursor >= match_data.line_content.len) {
                try writer.print("{s}", .{Color.reset});
                break;
            }
            const next = if (pattern_matcher) |m|
                nextNonEmptyMatch(m, match_data.line_content, cursor)
            else
                null;
            if (next) |following| {
                if (following.end > following.start and following.end <= match_data.line_content.len) {
                    if (following.start != cursor) {
                        try writer.print("{s}{s}{s}", .{
                            Color.reset,
                            match_data.line_content[cursor..following.start],
                            Color.match,
                        });
                    }
                    current = following;
                    continue;
                }
            }
            try writer.print("{s}", .{Color.reset});
            break;
        }
        try writer.print("{s}\n", .{match_data.line_content[cursor..]});
    }

    fn firstNonEmptyMatch(
        line: []const u8,
        initial: matcher_mod.MatchResult,
        pattern_matcher: ?*const matcher_mod.Matcher,
    ) ?matcher_mod.MatchResult {
        if (initial.end > initial.start and initial.end <= line.len) return initial;
        const matcher = pattern_matcher orelse return null;
        return nextNonEmptyMatch(matcher, line, initial.start);
    }

    fn nextNonEmptyMatch(
        pattern_matcher: *const matcher_mod.Matcher,
        line: []const u8,
        start: usize,
    ) ?matcher_mod.MatchResult {
        var position = start;
        while (position < line.len) {
            const found = pattern_matcher.findFirstFrom(line, position) orelse return null;
            if (found.end > found.start and found.end <= line.len) return found;
            if (found.start >= line.len) return null;
            // Match iterators must make progress after a zero-width match.
            // Advancing past its start also prevents a non-empty alternative
            // at that same offset from being reported out of regex priority.
            position = found.start + 1;
        }
        return null;
    }

    pub fn hasMatches(self: *const FileBuffer) bool {
        return self.match_count > 0;
    }

    pub fn getMatchCount(self: *const FileBuffer) usize {
        return self.match_count;
    }

    pub fn getBuffer(self: *const FileBuffer) []const u8 {
        return self.buffer.items;
    }
};

pub const Output = struct {
    const DIRECT_BUFFER_SIZE = 64 * 1024;

    file: std.Io.File,
    config: main.Config,
    total_count: std.atomic.Value(usize),
    matched: std.atomic.Value(bool),
    mutex: std.Io.Mutex,
    use_color: bool,
    use_heading: bool,
    show_line_numbers: bool,
    needs_separator: bool,
    direct_buffer: [DIRECT_BUFFER_SIZE]u8,
    direct_len: usize,
    direct_first_written: bool,

    pub fn init(file: std.Io.File, config: main.Config) Output {
        const is_tty = file.isTty(io) catch false;

        // Determine color mode based on config and TTY status
        const use_color = switch (config.color) {
            .always => true,
            .never => false,
            .auto => is_tty,
        };

        // Determine heading mode based on config and TTY status
        // Use headings when outputting to TTY, flat format when piped
        const use_heading = switch (config.heading) {
            .always => true,
            .never => false,
            .auto => is_tty,
        };

        return .{
            .file = file,
            .config = config,
            .total_count = std.atomic.Value(usize).init(0),
            .matched = std.atomic.Value(bool).init(false),
            .mutex = .init,
            .use_color = use_color,
            .use_heading = use_heading,
            .show_line_numbers = config.showLineNumbers(is_tty),
            .needs_separator = false,
            .direct_buffer = undefined,
            .direct_len = 0,
            .direct_first_written = false,
        };
    }

    /// Check if color is enabled (for creating FileBuffers)
    pub fn colorEnabled(self: *const Output) bool {
        return self.use_color;
    }

    /// Check if heading mode is enabled (for creating FileBuffers)
    pub fn headingEnabled(self: *const Output) bool {
        return self.use_heading;
    }

    pub fn lineNumbersEnabled(self: *const Output) bool {
        return self.show_line_numbers;
    }

    pub fn markMatched(self: *Output) void {
        self.matched.store(true, .monotonic);
    }

    /// Write a match directly to output (for single-file streaming)
    /// No buffering - writes immediately to stdout for fast first-result time
    /// Only use for single-source searches where no mutex is needed
    pub fn writeMatchDirect(self: *Output, match_data: Match, pattern_matcher: ?*const matcher_mod.Matcher) !void {
        const show_line_numbers = self.show_line_numbers;
        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);

        if (self.use_heading) {
            // Heading format: just line_number:content (no filename for single source)
            if (show_line_numbers) {
                if (self.use_color) {
                    try writer.print("{s}{s}{d}{s}:", .{
                        Color.reset,
                        Color.line_num,
                        match_data.line_number,
                        Color.reset,
                    });
                } else {
                    try writer.print("{d}:", .{match_data.line_number});
                }
            }
        } else {
            // Flat format: line_number:content (no filename for single source)
            if (show_line_numbers) {
                if (self.use_color) {
                    try writer.print("{s}{s}{d}{s}:", .{
                        Color.reset,
                        Color.line_num,
                        match_data.line_number,
                        Color.reset,
                    });
                } else {
                    try writer.print("{d}:", .{match_data.line_number});
                }
            }
        }

        const prefix = writer.buffered();
        try self.writeDirectPart(prefix);

        // Print line content with highlighted match
        if (self.use_color and match_data.match_end <= match_data.line_content.len) {
            const initial = matcher_mod.MatchResult{ .start = match_data.match_start, .end = match_data.match_end };
            var current = FileBuffer.firstNonEmptyMatch(match_data.line_content, initial, pattern_matcher) orelse {
                try self.writeDirectPart(match_data.line_content);
                try self.writeDirectPart("\n");
                self.matched.store(true, .monotonic);
                return;
            };
            var cursor = current.start;
            try self.writeDirectPart(match_data.line_content[0..current.start]);
            try self.writeDirectPart(Color.match);
            while (current.end > current.start and current.end <= match_data.line_content.len) {
                try self.writeDirectPart(match_data.line_content[current.start..current.end]);
                cursor = current.end;
                if (cursor >= match_data.line_content.len) {
                    try self.writeDirectPart(Color.reset);
                    break;
                }
                const next = if (pattern_matcher) |m|
                    FileBuffer.nextNonEmptyMatch(m, match_data.line_content, cursor)
                else
                    null;
                if (next) |following| {
                    if (following.end > following.start and following.end <= match_data.line_content.len) {
                        if (following.start != cursor) {
                            try self.writeDirectPart(Color.reset);
                            try self.writeDirectPart(match_data.line_content[cursor..following.start]);
                            try self.writeDirectPart(Color.match);
                        }
                        current = following;
                        continue;
                    }
                }
                try self.writeDirectPart(Color.reset);
                break;
            }
            try self.writeDirectPart(match_data.line_content[cursor..]);
        } else {
            try self.writeDirectPart(match_data.line_content);
        }
        try self.writeDirectPart("\n");

        self.matched.store(true, .monotonic);
    }

    /// Keep first-result latency low by writing the first match immediately;
    /// block-buffer subsequent lines to avoid one syscall per dense match.
    fn writeDirectPart(self: *Output, bytes: []const u8) !void {
        if (bytes.len == 0) return;

        if (!self.direct_first_written) {
            try self.file.writeStreamingAll(io, bytes);
            return;
        }

        if (bytes.len > self.direct_buffer.len) {
            try self.flushDirect();
            try self.file.writeStreamingAll(io, bytes);
            return;
        }

        if (self.direct_len + bytes.len > self.direct_buffer.len) {
            try self.flushDirect();
        }
        @memcpy(self.direct_buffer[self.direct_len..][0..bytes.len], bytes);
        self.direct_len += bytes.len;
    }

    pub fn finishDirectMatch(self: *Output) void {
        self.direct_first_written = true;
    }

    pub fn flushDirect(self: *Output) !void {
        if (self.direct_len == 0) return;
        try self.file.writeStreamingAll(io, self.direct_buffer[0..self.direct_len]);
        self.direct_len = 0;
    }

    /// Flush a file buffer's contents to output - single lock for entire file
    pub fn flushFileBuffer(self: *Output, file_buf: *FileBuffer) !void {
        if (!file_buf.hasMatches()) return;

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        // Add separator between files (only in heading mode)
        const grouped = self.use_heading and !self.config.files_with_matches;
        if (grouped and self.needs_separator) {
            try self.file.writeStreamingAll(io, "\n");
        }
        if (grouped) {
            self.needs_separator = true;
        }

        // Write entire buffer in one go
        try self.file.writeStreamingAll(io, file_buf.getBuffer());
        self.matched.store(true, .monotonic);

        // Update count
        if (self.config.count_only) {
            _ = self.total_count.fetchAdd(file_buf.getMatchCount(), .monotonic);
        }
    }

    pub fn printFileCount(self: *Output, file_path: []const u8, count: usize) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var buf: [4096]u8 = undefined;
        var writer = self.file.writerStreaming(io, &buf);

        if (self.config.is_single_source) {
            // ripgrep does not color counts, even when color is forced.
            try writer.interface.print("{d}\n", .{count});
        } else if (self.use_color) {
            try writer.interface.print("{s}{s}{s}{s}:{d}\n", .{
                Color.reset,
                Color.path,
                file_path,
                Color.reset,
                count,
            });
        } else {
            try writer.interface.print("{s}:{d}\n", .{ file_path, count });
        }
        try writer.interface.flush();
        _ = self.total_count.fetchAdd(count, .monotonic);
        if (count > 0) self.matched.store(true, .monotonic);
    }

    pub fn printBinaryMessage(self: *Output, file_path: []const u8, byte_offset: usize, quit: bool) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var buf: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        if (quit) {
            if (!self.config.is_single_source) try writer.print("{s}: ", .{file_path});
            try writer.print("WARNING: stopped searching binary file after match (found \"\\0\" byte around offset {d})\n", .{byte_offset});
        } else {
            if (!self.config.is_single_source) try writer.print("{s}: ", .{file_path});
            try writer.print("binary file matches (found \"\\0\" byte around offset {d})\n", .{byte_offset});
        }
        try self.file.writeStreamingAll(io, writer.buffered());
        self.matched.store(true, .monotonic);
    }

    pub fn printTotalCount(self: *Output) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var buf: [256]u8 = undefined;
        var writer = self.file.writerStreaming(io, &buf);
        const count = self.total_count.load(.monotonic);
        try writer.interface.print("{d}\n", .{count});
        try writer.interface.flush();
    }

    pub fn hasMatches(self: *const Output) bool {
        return self.matched.load(.monotonic);
    }
};

// Tests

test "FileBuffer init" {
    const allocator = std.testing.allocator;
    const config = main.Config{
        .pattern = "test",
        .paths = &[_][]const u8{"."},
    };

    var buf = FileBuffer.init(allocator, config, false, false);
    defer buf.deinit();

    try std.testing.expectEqual(@as(usize, 0), buf.match_count);
    try std.testing.expect(!buf.hasMatches());
    try std.testing.expect(buf.file_path == null);
}

test "FileBuffer addMatch flat no color" {
    const allocator = std.testing.allocator;
    const config = main.Config{
        .pattern = "test",
        .paths = &[_][]const u8{"."},
        .line_number = true, // explicit true
    };

    var buf = FileBuffer.init(allocator, config, false, false); // no color, no heading
    defer buf.deinit();

    try buf.addMatch(.{
        .file_path = "test.txt",
        .line_number = 42,
        .line_content = "hello world test",
        .match_start = 12,
        .match_end = 16,
    });

    try std.testing.expectEqual(@as(usize, 1), buf.match_count);
    try std.testing.expect(buf.hasMatches());

    // Check output format is flat: file:line:content
    const output = buf.getBuffer();
    try std.testing.expect(std.mem.indexOf(u8, output, "test.txt:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "42:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hello world test") != null);
}

test "FileBuffer addMatch heading no color" {
    const allocator = std.testing.allocator;
    const config = main.Config{
        .pattern = "test",
        .paths = &[_][]const u8{"."},
        .line_number = true, // explicit true
    };

    var buf = FileBuffer.init(allocator, config, false, true); // no color, heading mode
    defer buf.deinit();

    try buf.addMatch(.{
        .file_path = "test.txt",
        .line_number = 10,
        .line_content = "match here",
        .match_start = 0,
        .match_end = 5,
    });

    const output = buf.getBuffer();
    // In heading mode, first line should be just the filename
    try std.testing.expect(std.mem.startsWith(u8, output, "test.txt\n"));
}

test "FileBuffer files_with_matches" {
    const allocator = std.testing.allocator;
    const config = main.Config{
        .pattern = "test",
        .paths = &[_][]const u8{"."},
        .files_with_matches = true,
    };

    var buf = FileBuffer.init(allocator, config, false, false);
    defer buf.deinit();

    try buf.addMatch(.{
        .file_path = "myfile.txt",
        .line_number = 1,
        .line_content = "content",
        .match_start = 0,
        .match_end = 7,
    });

    const output = buf.getBuffer();
    // Should only contain filename
    try std.testing.expectEqualStrings("myfile.txt\n", output);
}

test "FileBuffer match_count increments" {
    const allocator = std.testing.allocator;
    const config = main.Config{
        .pattern = "test",
        .paths = &[_][]const u8{"."},
    };

    var buf = FileBuffer.init(allocator, config, false, false);
    defer buf.deinit();

    try std.testing.expectEqual(@as(usize, 0), buf.getMatchCount());

    try buf.addMatch(.{
        .file_path = "file.txt",
        .line_number = 1,
        .line_content = "a",
        .match_start = 0,
        .match_end = 1,
    });
    try std.testing.expectEqual(@as(usize, 1), buf.getMatchCount());

    try buf.addMatch(.{
        .file_path = "file.txt",
        .line_number = 2,
        .line_content = "b",
        .match_start = 0,
        .match_end = 1,
    });
    try std.testing.expectEqual(@as(usize, 2), buf.getMatchCount());
}

test "FileBuffer addMatch with color" {
    const allocator = std.testing.allocator;
    const config = main.Config{
        .pattern = "test",
        .paths = &[_][]const u8{"."},
        .line_number = true, // explicit true
    };

    var buf = FileBuffer.init(allocator, config, true, false); // color enabled
    defer buf.deinit();

    try buf.addMatch(.{
        .file_path = "test.txt",
        .line_number = 1,
        .line_content = "hello test world",
        .match_start = 6,
        .match_end = 10,
    });

    const output = buf.getBuffer();
    // Should contain ANSI escape codes
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[") != null);
}

test "FileBuffer getBuffer empty" {
    const allocator = std.testing.allocator;
    const config = main.Config{
        .pattern = "test",
        .paths = &[_][]const u8{"."},
    };

    var buf = FileBuffer.init(allocator, config, false, false);
    defer buf.deinit();

    try std.testing.expectEqual(@as(usize, 0), buf.getBuffer().len);
}

test "FileBuffer no line number" {
    const allocator = std.testing.allocator;
    const config = main.Config{
        .pattern = "test",
        .paths = &[_][]const u8{"."},
        .line_number = false, // explicit false
    };

    var buf = FileBuffer.init(allocator, config, false, false);
    defer buf.deinit();

    try buf.addMatch(.{
        .file_path = "file.txt",
        .line_number = 99,
        .line_content = "content",
        .match_start = 0,
        .match_end = 7,
    });

    const output = buf.getBuffer();
    // Should not contain line number (99)
    try std.testing.expect(std.mem.indexOf(u8, output, "99:") == null);
}

test "heading files-with-matches always emits one path" {
    const allocator = std.testing.allocator;
    const config = main.Config{
        .pattern = "test",
        .paths = &[_][]const u8{"only.txt"},
        .files_with_matches = true,
        .is_single_source = true,
    };

    var buf = FileBuffer.initResolved(allocator, config, false, true, false);
    defer buf.deinit();
    try buf.addMatch(.{
        .file_path = "only.txt",
        .line_number = 1,
        .line_content = "test",
        .match_start = 0,
        .match_end = 4,
    });
    try std.testing.expectEqualStrings("only.txt\n", buf.getBuffer());
}

test "color highlighting advances past prioritized empty matches" {
    const allocator = std.testing.allocator;
    var pattern_matcher = try matcher_mod.Matcher.init(allocator, "^|foo", false, false);
    defer pattern_matcher.deinit();

    const config = main.Config{
        .pattern = "^|foo",
        .paths = &[_][]const u8{"only.txt"},
        .is_single_source = true,
    };
    var buf = FileBuffer.initResolved(allocator, config, true, false, false);
    defer buf.deinit();

    const first = pattern_matcher.findFirst("xfoo").?;
    try std.testing.expectEqual(first.start, first.end);
    try buf.addMatchWithMatcher(.{
        .file_path = "only.txt",
        .line_number = 1,
        .line_content = "xfoo",
        .match_start = first.start,
        .match_end = first.end,
    }, &pattern_matcher);

    const prioritized_empty = pattern_matcher.findFirst("foo").?;
    try buf.addMatchWithMatcher(.{
        .file_path = "only.txt",
        .line_number = 2,
        .line_content = "foo",
        .match_start = prioritized_empty.start,
        .match_end = prioritized_empty.end,
    }, &pattern_matcher);

    try std.testing.expectEqualStrings(
        "x" ++ Color.match ++ "foo" ++ Color.reset ++ "\nfoo\n",
        buf.getBuffer(),
    );
}
