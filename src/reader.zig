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

test "FileContent bytes mmap" {
    // Test that bytes() returns correct data for mmap variant
    // Note: We can't easily test mmap without a real file, so this is a partial test
    const test_data = "test content";
    const content = FileContent{ .buffered = .{
        .data = @constCast(test_data),
        .allocator = std.testing.allocator,
    } };

    try std.testing.expectEqualStrings("test content", content.bytes());
}

test "BufferedContent deinit" {
    const allocator = std.testing.allocator;

    // Allocate some data
    const data = try allocator.alloc(u8, 10);
    @memset(data, 'x');

    var content = BufferedContent{
        .data = data,
        .allocator = allocator,
    };

    // deinit should free without error
    content.deinit();
}

test "BufferedContent deinit empty" {
    // Empty data should not cause issues on deinit
    var content = BufferedContent{
        .data = &[_]u8{},
        .allocator = std.testing.allocator,
    };

    content.deinit(); // Should not crash
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
