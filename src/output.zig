const std = @import("std");
const main = @import("main.zig");

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
    const match = "\x1b[1m\x1b[31m"; // bold red for matches
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

    pub fn init(allocator: std.mem.Allocator, config: main.Config, use_color: bool, use_heading: bool) FileBuffer {
        return .{
            .buffer = .{},
            .allocator = allocator,
            .match_count = 0,
            .config = config,
            .use_color = use_color,
            .use_heading = use_heading,
            .file_path = null,
        };
    }

    pub fn deinit(self: *FileBuffer) void {
        self.buffer.deinit(self.allocator);
    }


    pub fn addMatch(self: *FileBuffer, match_data: Match) !void {
        const writer = self.buffer.writer(self.allocator);

        if (self.use_heading) {
            // Grouped output format:
            // filepath
            // line_number:content
            // line_number:content
            //
            // filepath2
            // ...

            // Print file header on first match
            if (self.match_count == 0) {
                self.file_path = match_data.file_path;
                if (self.use_color) {
                    try writer.print("{s}{s}{s}\n", .{ Color.path, match_data.file_path, Color.reset });
                } else {
                    try writer.print("{s}\n", .{match_data.file_path});
                }
            }

            self.match_count += 1;

            if (self.config.files_with_matches) {
                // Already printed header, nothing more to do
                return;
            }

            // Print line with colored match
            if (self.config.line_number) {
                if (self.use_color) {
                    try writer.print("{s}{d}{s}{s}:{s}", .{
                        Color.line_num,
                        match_data.line_number,
                        Color.reset,
                        Color.separator,
                        Color.reset,
                    });
                } else {
                    try writer.print("{d}:", .{match_data.line_number});
                }
            }

            // Print line content with highlighted match
            if (self.use_color and match_data.match_end > match_data.match_start and match_data.match_end <= match_data.line_content.len) {
                // Before match
                try writer.print("{s}", .{match_data.line_content[0..match_data.match_start]});
                // The match (highlighted)
                try writer.print("{s}{s}{s}", .{
                    Color.match,
                    match_data.line_content[match_data.match_start..match_data.match_end],
                    Color.reset,
                });
                // After match
                try writer.print("{s}\n", .{match_data.line_content[match_data.match_end..]});
            } else {
                try writer.print("{s}\n", .{match_data.line_content});
            }
        } else {
            // Flat output format:
            // filepath:line_number:content

            self.file_path = match_data.file_path;
            self.match_count += 1;

            if (self.config.files_with_matches) {
                // Just print the filename
                if (self.use_color) {
                    try writer.print("{s}{s}{s}\n", .{ Color.path, match_data.file_path, Color.reset });
                } else {
                    try writer.print("{s}\n", .{match_data.file_path});
                }
                return;
            }

            // Print file path prefix
            if (self.use_color) {
                try writer.print("{s}{s}{s}{s}:{s}", .{
                    Color.path,
                    match_data.file_path,
                    Color.reset,
                    Color.separator,
                    Color.reset,
                });
            } else {
                try writer.print("{s}:", .{match_data.file_path});
            }

            // Print line number if enabled
            if (self.config.line_number) {
                if (self.use_color) {
                    try writer.print("{s}{d}{s}{s}:{s}", .{
                        Color.line_num,
                        match_data.line_number,
                        Color.reset,
                        Color.separator,
                        Color.reset,
                    });
                } else {
                    try writer.print("{d}:", .{match_data.line_number});
                }
            }

            // Print line content with highlighted match
            if (self.use_color and match_data.match_end > match_data.match_start and match_data.match_end <= match_data.line_content.len) {
                // Before match
                try writer.print("{s}", .{match_data.line_content[0..match_data.match_start]});
                // The match (highlighted)
                try writer.print("{s}{s}{s}", .{
                    Color.match,
                    match_data.line_content[match_data.match_start..match_data.match_end],
                    Color.reset,
                });
                // After match
                try writer.print("{s}\n", .{match_data.line_content[match_data.match_end..]});
            } else {
                try writer.print("{s}\n", .{match_data.line_content});
            }
        }
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
    file: std.fs.File,
    config: main.Config,
    total_count: std.atomic.Value(usize),
    mutex: std.Thread.Mutex,
    use_color: bool,
    use_heading: bool,
    needs_separator: bool,

    pub fn init(file: std.fs.File, config: main.Config) Output {
        const is_tty = file.isTty();

        // Determine color mode based on config and TTY status
        const use_color = switch (config.color) {
            .always => true,
            .never => false,
            .auto => is_tty,
        };

        // Determine heading mode based on config and TTY status
        // Like ripgrep: use headings when outputting to TTY, flat format when piped
        const use_heading = switch (config.heading) {
            .always => true,
            .never => false,
            .auto => is_tty,
        };

        return .{
            .file = file,
            .config = config,
            .total_count = std.atomic.Value(usize).init(0),
            .mutex = .{},
            .use_color = use_color,
            .use_heading = use_heading,
            .needs_separator = false,
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

    /// Flush a file buffer's contents to output - single lock for entire file
    pub fn flushFileBuffer(self: *Output, file_buf: *FileBuffer) !void {
        if (!file_buf.hasMatches()) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        // Add separator between files (only in heading mode)
        if (self.use_heading and self.needs_separator) {
            _ = self.file.write("\n") catch {};
        }
        if (self.use_heading) {
            self.needs_separator = true;
        }

        // Write entire buffer in one go
        _ = self.file.write(file_buf.getBuffer()) catch {};

        // Update count
        if (self.config.count_only) {
            _ = self.total_count.fetchAdd(file_buf.getMatchCount(), .monotonic);
        }
    }


    pub fn printFileCount(self: *Output, file_path: []const u8, count: usize) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var buf: [4096]u8 = undefined;
        var writer = self.file.writer(&buf);

        if (self.use_color) {
            try writer.interface.print("{s}{s}{s}{s}:{s}{s}{d}{s}\n", .{
                Color.path,
                file_path,
                Color.reset,
                Color.separator,
                Color.reset,
                Color.line_num,
                count,
                Color.reset,
            });
        } else {
            try writer.interface.print("{s}:{d}\n", .{ file_path, count });
        }
        try writer.interface.flush();
        _ = self.total_count.fetchAdd(count, .monotonic);
    }

    pub fn printTotalCount(self: *Output) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var buf: [256]u8 = undefined;
        var writer = self.file.writer(&buf);
        const count = self.total_count.load(.monotonic);
        try writer.interface.print("{d}\n", .{count});
        try writer.interface.flush();
    }
};
