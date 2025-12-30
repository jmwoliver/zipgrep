const std = @import("std");
const main = @import("main.zig");
const matcher_mod = @import("matcher.zig");
const reader = @import("reader.zig");
const output = @import("output.zig");
const gitignore = @import("gitignore.zig");

pub const Walker = struct {
    allocator: std.mem.Allocator,
    config: main.Config,
    pattern_matcher: *matcher_mod.Matcher,
    ignore_matcher: ?*gitignore.GitignoreMatcher,
    out: *output.Output,

    pub fn init(
        allocator: std.mem.Allocator,
        config: main.Config,
        pattern_matcher: *matcher_mod.Matcher,
        ignore_matcher: ?*gitignore.GitignoreMatcher,
        out: *output.Output,
    ) !Walker {
        return Walker{
            .allocator = allocator,
            .config = config,
            .pattern_matcher = pattern_matcher,
            .ignore_matcher = ignore_matcher,
            .out = out,
        };
    }

    pub fn deinit(self: *Walker) void {
        _ = self;
    }

    pub fn walk(self: *Walker) !void {
        // Collect all files first (single-threaded), then search in parallel
        var files = std.ArrayListUnmanaged([]const u8){};
        defer {
            for (files.items) |f| self.allocator.free(f);
            files.deinit(self.allocator);
        }

        // Collect files from all paths
        for (self.config.paths) |path| {
            const stat = std.fs.cwd().statFile(path) catch continue;
            if (stat.kind == .directory) {
                try self.collectFiles(path, 0, &files);
            } else {
                try files.append(self.allocator, try self.allocator.dupe(u8, path));
            }
        }

        // Now search files - use parallelism if enabled
        const num_threads = self.config.getNumThreads();
        if (num_threads <= 1 or files.items.len < 10) {
            // Single-threaded for small workloads
            for (files.items) |file_path| {
                try self.searchFile(file_path);
            }
        } else {
            // Parallel search
            try self.searchFilesParallel(files.items, num_threads);
        }
    }

    fn collectFiles(self: *Walker, path: []const u8, depth: usize, files: *std.ArrayListUnmanaged([]const u8)) !void {
        if (self.config.max_depth) |max| {
            if (depth >= max) return;
        }

        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (!self.config.hidden and entry.name.len > 0 and entry.name[0] == '.') {
                continue;
            }

            const full_path = try std.fs.path.join(self.allocator, &.{ path, entry.name });
            errdefer self.allocator.free(full_path);

            if (self.ignore_matcher) |im| {
                if (im.isIgnored(full_path)) {
                    self.allocator.free(full_path);
                    continue;
                }
            }

            switch (entry.kind) {
                .file => try files.append(self.allocator, full_path),
                .directory => {
                    defer self.allocator.free(full_path);
                    try self.collectFiles(full_path, depth + 1, files);
                },
                else => self.allocator.free(full_path),
            }
        }
    }

    fn searchFilesParallel(self: *Walker, files: []const []const u8, num_threads: usize) !void {
        const actual_threads = @min(num_threads, files.len);
        if (actual_threads == 0) return;

        const threads = try self.allocator.alloc(std.Thread, actual_threads);
        defer self.allocator.free(threads);

        // Simple work distribution - divide files among threads
        const files_per_thread = files.len / actual_threads;
        const remainder = files.len % actual_threads;

        var start: usize = 0;
        for (threads, 0..) |*thread, i| {
            const extra: usize = if (i < remainder) 1 else 0;
            const count = files_per_thread + extra;
            const end = start + count;

            const ctx = ThreadContext{
                .walker = self,
                .files = files[start..end],
            };

            thread.* = try std.Thread.spawn(.{}, searchWorker, .{ctx});
            start = end;
        }

        // Wait for all threads
        for (threads) |thread| {
            thread.join();
        }
    }

    const ThreadContext = struct {
        walker: *Walker,
        files: []const []const u8,
    };

    fn searchWorker(ctx: ThreadContext) void {
        for (ctx.files) |file_path| {
            ctx.walker.searchFile(file_path) catch {};
        }
    }

    fn searchFile(self: *Walker, path: []const u8) !void {
        var content = reader.readFile(self.allocator, path, true) catch return;
        defer content.deinit();

        const data = content.bytes();
        if (data.len == 0) return;

        var line_iter = reader.LineIterator.init(data);
        var file_match_count: usize = 0;
        var first_match = true;

        while (line_iter.next()) |line| {
            if (self.pattern_matcher.findFirst(line.content)) |match_result| {
                if (self.config.count_only) {
                    file_match_count += 1;
                } else if (self.config.files_with_matches) {
                    if (first_match) {
                        try self.out.printMatch(.{
                            .file_path = path,
                            .line_number = line.number,
                            .line_content = line.content,
                            .match_start = match_result.start,
                            .match_end = match_result.end,
                        });
                        first_match = false;
                    }
                    break;
                } else {
                    try self.out.printMatch(.{
                        .file_path = path,
                        .line_number = line.number,
                        .line_content = line.content,
                        .match_start = match_result.start,
                        .match_end = match_result.end,
                    });
                }
            }
        }

        if (self.config.count_only and file_match_count > 0) {
            try self.out.printFileCount(path, file_match_count);
        }
    }
};

test "walker initialization" {
    // Basic initialization test
}
