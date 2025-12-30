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

    // ripgrep-style colors
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

pub const Output = struct {
    file: std.fs.File,
    config: main.Config,
    total_count: std.atomic.Value(usize),
    mutex: std.Thread.Mutex,
    last_file: ?[]const u8,
    use_color: bool,

    pub fn init(file: std.fs.File, config: main.Config) Output {
        // Determine color mode based on config and TTY status
        const use_color = switch (config.color) {
            .always => true,
            .never => false,
            .auto => file.isTty(),
        };

        return .{
            .file = file,
            .config = config,
            .total_count = std.atomic.Value(usize).init(0),
            .mutex = .{},
            .last_file = null,
            .use_color = use_color,
        };
    }

    pub fn printMatch(self: *Output, match: Match) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.config.count_only) {
            _ = self.total_count.fetchAdd(1, .monotonic);
            return;
        }

        var buf: [8192]u8 = undefined;
        var writer = self.file.writer(&buf);

        if (self.config.files_with_matches) {
            if (self.use_color) {
                try writer.interface.print("{s}{s}{s}\n", .{ Color.path, match.file_path, Color.reset });
            } else {
                try writer.interface.print("{s}\n", .{match.file_path});
            }
            try writer.interface.flush();
            return;
        }

        // Print file header if this is a new file (ripgrep style grouping)
        const print_header = if (self.last_file) |last| !std.mem.eql(u8, last, match.file_path) else true;

        if (print_header) {
            if (self.last_file != null) {
                // Add blank line between files
                try writer.interface.print("\n", .{});
            }
            if (self.use_color) {
                try writer.interface.print("{s}{s}{s}\n", .{ Color.path, match.file_path, Color.reset });
            } else {
                try writer.interface.print("{s}\n", .{match.file_path});
            }
            self.last_file = match.file_path;
        }

        // Print line with colored match
        if (self.config.line_number) {
            if (self.use_color) {
                try writer.interface.print("{s}{d}{s}{s}:{s}", .{
                    Color.line_num,
                    match.line_number,
                    Color.reset,
                    Color.separator,
                    Color.reset,
                });
            } else {
                try writer.interface.print("{d}:", .{match.line_number});
            }
        }

        // Print line content with highlighted match
        if (self.use_color and match.match_end > match.match_start and match.match_end <= match.line_content.len) {
            // Before match
            try writer.interface.print("{s}", .{match.line_content[0..match.match_start]});
            // The match (highlighted)
            try writer.interface.print("{s}{s}{s}", .{
                Color.match,
                match.line_content[match.match_start..match.match_end],
                Color.reset,
            });
            // After match
            try writer.interface.print("{s}\n", .{match.line_content[match.match_end..]});
        } else {
            try writer.interface.print("{s}\n", .{match.line_content});
        }

        try writer.interface.flush();
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
