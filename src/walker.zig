const std = @import("std");
const main = @import("main.zig");
const matcher_mod = @import("matcher.zig");
const reader = @import("reader.zig");
const output = @import("output.zig");
const gitignore = @import("gitignore.zig");
const parallel_walker = @import("parallel_walker.zig");

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

    /// Main entry point - uses parallel walker for multi-threaded traversal and search
    pub fn walk(self: *Walker) !void {
        const num_threads = self.config.getNumThreads();

        // Load ancestor .gitignore files for all search paths BEFORE starting walk
        // This walks up to find the git repository root and loads all .gitignore files
        // from the repo root down to the search path, ensuring parent patterns apply
        if (self.ignore_matcher) |im| {
            for (self.config.paths) |path| {
                const stat = std.fs.cwd().statFile(path) catch continue;
                if (stat.kind == .directory) {
                    // Find git repository root by walking up from search path
                    if (gitignore.findGitRoot(self.allocator, path)) |git_root| {
                        defer self.allocator.free(git_root);
                        // Load all .gitignore files from git root down to search path
                        gitignore.loadAncestorGitignores(im, git_root, path, self.allocator);
                    } else {
                        // No git root found, just load .gitignore from search path
                        self.loadGitignoreForDir(path) catch {};
                    }
                }
            }
        }

        // Use parallel walker for multi-threaded operation
        if (num_threads > 1) {
            var pw = try parallel_walker.ParallelWalker.init(
                self.allocator,
                self.config,
                self.pattern_matcher,
                self.ignore_matcher,
                self.out,
            );
            defer pw.deinit();

            try pw.walk();
            return;
        }

        // Fall back to sequential walker for single-threaded operation
        try self.walkSequential();
    }

    /// Sequential implementation (original behavior)
    fn walkSequential(self: *Walker) !void {
        // Collect all files first, then search sequentially
        var files = std.ArrayListUnmanaged([]const u8){};
        defer {
            for (files.items) |f| self.allocator.free(f);
            files.deinit(self.allocator);
        }

        // Track if we need to process stdin (do it AFTER files)
        var has_stdin = false;

        // Collect files from all paths
        // Note: Root .gitignore is already loaded in walk() before calling this
        for (self.config.paths) |path| {
            // Skip stdin - process after files
            if (std.mem.eql(u8, path, "-")) {
                has_stdin = true;
                continue;
            }

            const stat = std.fs.cwd().statFile(path) catch continue;
            if (stat.kind == .directory) {
                try self.collectFiles(path, 0, &files);
            } else {
                // Check gitignore for files passed directly
                if (self.ignore_matcher) |im| {
                    if (im.isIgnoredFile(path)) {
                        continue;
                    }
                }
                // Check glob patterns for files passed directly
                if (!gitignore.matchesGlobPatterns(path, false, self.config.glob_patterns)) {
                    continue;
                }
                try files.append(self.allocator, try self.allocator.dupe(u8, path));
            }
        }

        // Now search files
        for (files.items) |file_path| {
            self.searchFile(file_path) catch {};
        }

        // Process stdin AFTER files (so file output appears before blocking on stdin)
        if (has_stdin) {
            try self.searchStdin();
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

            const is_dir = entry.kind == .directory;

            // Check gitignore patterns
            if (self.ignore_matcher) |im| {
                if (im.isIgnored(full_path, is_dir)) {
                    self.allocator.free(full_path);
                    continue;
                }
            }

            // Check glob patterns from -g/--glob flags
            if (!gitignore.matchesGlobPatterns(full_path, is_dir, self.config.glob_patterns)) {
                self.allocator.free(full_path);
                continue;
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

    /// Query available bytes in stdin using FIONREAD ioctl for pre-allocation hint
    fn getStdinSizeHint(file: std.fs.File) usize {
        const builtin = @import("builtin");
        const FIONREAD: u32 = switch (builtin.os.tag) {
            .macos, .ios, .tvos, .watchos => 0x4004667f,
            .linux => 0x541B,
            .freebsd, .netbsd, .openbsd, .dragonfly => 0x4004667f,
            else => return 0, // Unsupported platform
        };

        var bytes_available: c_int = 0;
        const rc = std.posix.system.ioctl(file.handle, FIONREAD, @as(usize, @intFromPtr(&bytes_available)));
        if (rc == 0 and bytes_available > 0) {
            return @intCast(bytes_available);
        }
        return 0;
    }

    /// Search stdin for matches
    fn searchStdin(self: *Walker) !void {
        const stdin = std.fs.File.stdin();

        // Read all stdin into buffer
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(self.allocator);

        // Pre-allocate based on FIONREAD hint to reduce reallocations
        const hint = getStdinSizeHint(stdin);
        if (hint > 0) {
            content.ensureTotalCapacity(self.allocator, hint) catch {};
        }

        var read_buf: [64 * 1024]u8 = undefined;
        while (true) {
            const bytes_read = stdin.read(&read_buf) catch break;
            if (bytes_read == 0) break;
            content.appendSlice(self.allocator, read_buf[0..bytes_read]) catch break;
        }

        const data = content.items;
        if (data.len == 0) return;

        // Binary detection: check first 8KB for NUL bytes
        const check_len = @min(data.len, 8192);
        for (data[0..check_len]) |byte| {
            if (byte == 0) return; // Skip binary input
        }

        // Use FileBuffer with "<stdin>" as path
        var file_buf = output.FileBuffer.init(self.allocator, self.config, self.out.colorEnabled(), self.out.headingEnabled());
        defer file_buf.deinit();

        var line_iter = reader.LineIterator.init(data);

        while (line_iter.next()) |line| {
            if (self.pattern_matcher.findFirst(line.content)) |match_result| {
                if (self.config.count_only) {
                    file_buf.match_count += 1;
                } else {
                    try file_buf.addMatch(.{
                        .file_path = "<stdin>",
                        .line_number = line.number,
                        .line_content = line.content,
                        .match_start = match_result.start,
                        .match_end = match_result.end,
                    });

                    if (self.config.files_with_matches) break;
                }
            }
        }

        // Flush all buffered output
        if (self.config.count_only) {
            if (file_buf.match_count > 0) {
                try self.out.printFileCount("<stdin>", file_buf.match_count);
            }
        } else {
            try self.out.flushFileBuffer(&file_buf);
        }
    }

    /// Search a single file using streaming reader.
    /// Uses constant ~64KB memory regardless of file size.
    fn searchFileWithAlloc(self: *Walker, path: []const u8, alloc: std.mem.Allocator) !void {
        // Skip .gitignore files
        if (std.mem.endsWith(u8, path, ".gitignore")) return;

        // Use streaming reader - constant memory regardless of file size
        var stream = reader.StreamingLineReader.init(alloc, path) catch return;
        defer stream.deinit();

        // For single-source searches, stream output directly for fast first-result time
        // For multi-file searches, buffer to prevent interleaved output
        if (self.config.is_single_source and !self.config.count_only and !self.config.files_with_matches) {
            // Streaming path - write matches directly to stdout
            while (stream.next()) |line| {
                if (self.pattern_matcher.findFirst(line.content)) |match_result| {
                    self.out.writeMatchDirect(.{
                        .file_path = path,
                        .line_number = line.number,
                        .line_content = line.content,
                        .match_start = match_result.start,
                        .match_end = match_result.end,
                    });
                }
            }
            return;
        }

        // Buffered path - for multi-file searches or count/files-with-matches modes
        var file_buf = output.FileBuffer.init(alloc, self.config, self.out.colorEnabled(), self.out.headingEnabled());
        defer file_buf.deinit();

        while (stream.next()) |line| {
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
    const allocator = std.testing.allocator;

    // Create minimal dependencies for initialization test
    const config = main.Config{
        .pattern = "test",
        .paths = &[_][]const u8{"."},
    };

    var pattern_matcher = try matcher_mod.Matcher.init(allocator, "test", false);
    defer pattern_matcher.deinit();

    var ignore_matcher = gitignore.GitignoreMatcher.init(allocator);
    defer ignore_matcher.deinit();

    const stdout = std.fs.File.stdout();
    var out = output.Output.init(stdout, config);

    var w = try Walker.init(
        allocator,
        config,
        &pattern_matcher,
        &ignore_matcher,
        &out,
    );
    defer w.deinit();

    // Walker should be initialized with the correct config
    try std.testing.expectEqualStrings("test", w.config.pattern);
}

test "walker init without ignore matcher" {
    const allocator = std.testing.allocator;

    const config = main.Config{
        .pattern = "test",
        .paths = &[_][]const u8{"."},
        .no_ignore = true,
    };

    var pattern_matcher = try matcher_mod.Matcher.init(allocator, "test", false);
    defer pattern_matcher.deinit();

    const stdout = std.fs.File.stdout();
    var out = output.Output.init(stdout, config);

    var w = try Walker.init(
        allocator,
        config,
        &pattern_matcher,
        null, // No ignore matcher
        &out,
    );
    defer w.deinit();

    try std.testing.expect(w.ignore_matcher == null);
}

test "walker deinit does not crash" {
    const allocator = std.testing.allocator;

    const config = main.Config{
        .pattern = "test",
        .paths = &[_][]const u8{"."},
    };

    var pattern_matcher = try matcher_mod.Matcher.init(allocator, "test", false);
    defer pattern_matcher.deinit();

    const stdout = std.fs.File.stdout();
    var out = output.Output.init(stdout, config);

    var w = try Walker.init(
        allocator,
        config,
        &pattern_matcher,
        null,
        &out,
    );

    // Should not crash
    w.deinit();
}
