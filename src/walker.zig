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

    /// Main entry point - sequential directory collection, parallel file search
    ///                    TODO need to make directory collection parallel
    pub fn walk(self: *Walker) !void {
        // Collect all files first, then search in parallel
        var files = std.ArrayListUnmanaged([]const u8){};
        defer {
            for (files.items) |f| self.allocator.free(f);
            files.deinit(self.allocator);
        }

        // Collect files from all paths
        for (self.config.paths) |path| {
            const stat = std.fs.cwd().statFile(path) catch continue;
            if (stat.kind == .directory) {
                // Load .gitignore from the root search directory
                try self.loadGitignoreForDir(path);
                try self.collectFiles(path, 0, &files);
            } else {
                // Check gitignore for files passed directly
                if (self.ignore_matcher) |im| {
                    if (im.isIgnoredFile(path)) {
                        continue;
                    }
                }
                try files.append(self.allocator, try self.allocator.dupe(u8, path));
            }
        }

        // Now search files
        for (files.items) |file_path| {
            self.searchFile(file_path) catch {};
        }
    }

    /// Load .gitignore file for a directory if it exists
    fn loadGitignoreForDir(self: *Walker, dir_path: []const u8) !void {
        if (self.ignore_matcher == null) return;

        const gitignore_path = try std.fs.path.join(self.allocator, &.{ dir_path, ".gitignore" });
        defer self.allocator.free(gitignore_path);

        // Try to load the .gitignore file (ignore errors if it doesn't exist)
        self.ignore_matcher.?.loadFile(gitignore_path, dir_path) catch {};
    }

    fn collectFiles(self: *Walker, path: []const u8, depth: usize, files: *std.ArrayListUnmanaged([]const u8)) !void {
        if (self.config.max_depth) |max| {
            if (depth >= max) return;
        }

        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return;
        defer dir.close();

        // Load .gitignore from this directory (scoped to this dir and below)
        if (depth > 0) { // Root already loaded in walk()
            try self.loadGitignoreForDir(path);
        }

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            // Skip hidden files/dirs unless --hidden is set
            // Exception: .gitignore files are always searched
            if (!self.config.hidden and entry.name.len > 0 and entry.name[0] == '.') {
                if (entry.kind != .file or !std.mem.eql(u8, entry.name, ".gitignore")) {
                    continue;
                }
            }

            // Quick check for VCS directories that should always be skipped
            if (entry.kind == .directory and gitignore.GitignoreMatcher.isCommonIgnoredDir(entry.name)) {
                continue;
            }

            const full_path = try std.fs.path.join(self.allocator, &.{ path, entry.name });
            errdefer self.allocator.free(full_path);

            // Check gitignore patterns
            if (self.ignore_matcher) |im| {
                const is_dir = entry.kind == .directory;
                if (im.isIgnored(full_path, is_dir)) {
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




    fn searchFile(self: *Walker, path: []const u8) !void {
        return self.searchFileWithAlloc(path, self.allocator);
    }

    fn searchFileWithAlloc(self: *Walker, path: []const u8, alloc: std.mem.Allocator) !void {
        var content = reader.readFile(alloc, path, true) catch return;
        defer content.deinit();

        const data = content.bytes();
        if (data.len == 0) return;

        // Binary file detection: check first 8KB for NUL bytes
        const check_len = @min(data.len, 8192);
        for (data[0..check_len]) |byte| {
            if (byte == 0) return; // Skip binary files
        }

        // Use per-file buffer to batch output - reduces mutex contention
        var file_buf = output.FileBuffer.init(alloc, self.config, self.out.colorEnabled(), self.out.headingEnabled());
        defer file_buf.deinit();

        var line_iter = reader.LineIterator.init(data);

        while (line_iter.next()) |line| {
            if (self.pattern_matcher.findFirst(line.content)) |match_result| {
                if (self.config.count_only) {
                    file_buf.match_count += 1;
                } else {
                    try file_buf.addMatch(.{
                        .file_path = path,
                        .line_number = line.number,
                        .line_content = line.content,
                        .match_start = match_result.start,
                        .match_end = match_result.end,
                    });

                    if (self.config.files_with_matches) break;
                }
            }
        }

        // Flush all buffered output in one mutex lock
        if (self.config.count_only) {
            if (file_buf.match_count > 0) {
                try self.out.printFileCount(path, file_buf.match_count);
            }
        } else {
            try self.out.flushFileBuffer(&file_buf);
        }
    }
};

test "walker initialization" {
    // Basic initialization test
}
