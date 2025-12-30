const std = @import("std");
const simd = @import("simd.zig");

/// Threshold for switching between mmap and buffered reading
/// Files smaller than this use mmap, larger files use buffered reading for directories
const MMAP_THRESHOLD: usize = 128 * 1024 * 1024; // 128 MB

/// Buffer size for buffered reading
const BUFFER_SIZE: usize = 64 * 1024; // 64 KB

pub const FileContent = union(enum) {
    /// Memory-mapped file content (zero-copy)
    mmap: MappedContent,
    /// Buffered file content (owned memory)
    buffered: BufferedContent,

    pub fn bytes(self: FileContent) []const u8 {
        return switch (self) {
            .mmap => |m| m.data,
            .buffered => |b| b.data,
        };
    }

    pub fn deinit(self: *FileContent) void {
        switch (self.*) {
            .mmap => |*m| m.deinit(),
            .buffered => |*b| b.deinit(),
        }
    }
};

pub const MappedContent = struct {
    data: []align(std.heap.page_size_min) const u8,

    pub fn deinit(self: *MappedContent) void {
        std.posix.munmap(self.data);
    }
};

pub const BufferedContent = struct {
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *BufferedContent) void {
        if (self.data.len > 0) {
            self.allocator.free(self.data);
        }
    }
};

/// Read a file using the optimal strategy based on size and context
pub fn readFile(allocator: std.mem.Allocator, path: []const u8, use_mmap: bool) !FileContent {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const size = stat.size;

    // Skip empty files
    if (size == 0) {
        return FileContent{ .buffered = .{
            .data = &[_]u8{},
            .allocator = allocator,
        } };
    }

    // Use mmap for larger files when requested
    if (use_mmap and size <= MMAP_THRESHOLD and size > 0) {
        if (mmapFile(file, size)) |content| {
            return content;
        }
        // Fall through to buffered if mmap fails
    }

    // Buffered reading
    return readBuffered(allocator, file, size);
}

fn mmapFile(file: std.fs.File, size: u64) ?FileContent {
    const ptr = std.posix.mmap(
        null,
        @intCast(size),
        std.posix.PROT.READ,
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    ) catch return null;

    // Hint to kernel that we'll read sequentially - improves prefetching
    std.posix.madvise(ptr.ptr, @intCast(size), std.posix.MADV.SEQUENTIAL) catch {};

    return FileContent{ .mmap = .{
        .data = ptr[0..@intCast(size)],
    } };
}

fn readBuffered(allocator: std.mem.Allocator, file: std.fs.File, size: u64) !FileContent {
    const data = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(data);

    const bytes_read = try file.readAll(data);
    if (bytes_read != size) {
        allocator.free(data);
        return error.UnexpectedEof;
    }

    return FileContent{ .buffered = .{
        .data = data,
        .allocator = allocator,
    } };
}

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

    /// Reset the iterator to a specific position
    pub fn reset(self: *LineIterator, pos: usize, line_number: usize) void {
        self.pos = pos;
        self.line_number = line_number;
    }
};

/// Streaming reader for very large files (doesn't load entire file into memory)
pub const StreamingReader = struct {
    file: std.fs.File,
    buffer: [BUFFER_SIZE]u8,
    buffer_len: usize,
    buffer_start: usize,
    file_offset: usize,
    line_number: usize,
    eof: bool,

    pub fn open(path: []const u8) !StreamingReader {
        const file = try std.fs.cwd().openFile(path, .{});

        var reader_instance = StreamingReader{
            .file = file,
            .buffer = undefined,
            .buffer_len = 0,
            .buffer_start = 0,
            .file_offset = 0,
            .line_number = 0,
            .eof = false,
        };

        try reader_instance.fillBuffer();
        return reader_instance;
    }

    pub fn deinit(self: *StreamingReader) void {
        self.file.close();
    }

    fn fillBuffer(self: *StreamingReader) !void {
        const bytes_read = try self.file.read(&self.buffer);
        self.buffer_len = bytes_read;
        self.buffer_start = 0;
        self.eof = bytes_read == 0;
    }

    pub fn nextLine(self: *StreamingReader, allocator: std.mem.Allocator) !?LineIterator.Line {
        if (self.eof and self.buffer_start >= self.buffer_len) return null;

        self.line_number += 1;
        var line = std.ArrayListUnmanaged(u8){};
        defer line.deinit(allocator);

        while (true) {
            if (self.buffer_start >= self.buffer_len) {
                try self.fillBuffer();
                if (self.eof) {
                    if (line.items.len > 0) {
                        return LineIterator.Line{
                            .content = try line.toOwnedSlice(allocator),
                            .number = self.line_number,
                        };
                    }
                    return null;
                }
            }

            const remaining = self.buffer[self.buffer_start..self.buffer_len];
            if (simd.findNewline(remaining)) |offset| {
                try line.appendSlice(allocator, remaining[0..offset]);
                self.buffer_start += offset + 1;
                return LineIterator.Line{
                    .content = try line.toOwnedSlice(allocator),
                    .number = self.line_number,
                };
            } else {
                try line.appendSlice(allocator, remaining);
                self.buffer_start = self.buffer_len;
            }
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
