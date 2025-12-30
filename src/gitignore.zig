const std = @import("std");

/// A pattern from a gitignore file
const Pattern = struct {
    pattern: []const u8,
    negated: bool,
    directory_only: bool,
    anchored: bool, // Pattern is relative to gitignore location

    /// Match a path against this pattern
    fn matches(self: *const Pattern, path: []const u8) bool {
        const target = if (self.directory_only)
            std.fs.path.dirname(path) orelse path
        else
            path;

        return globMatch(self.pattern, target);
    }
};

/// Simple glob pattern matcher
fn globMatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star_p: ?usize = null;
    var star_t: usize = 0;

    while (t < text.len) {
        if (p < pattern.len) {
            switch (pattern[p]) {
                '*' => {
                    // Handle ** (match any path segments)
                    if (p + 1 < pattern.len and pattern[p + 1] == '*') {
                        p += 2;
                        // Skip any following /
                        if (p < pattern.len and pattern[p] == '/') {
                            p += 1;
                        }
                        // Match everything until we find a match for the rest
                        while (t < text.len) {
                            if (globMatch(pattern[p..], text[t..])) {
                                return true;
                            }
                            t += 1;
                        }
                        return globMatch(pattern[p..], text[t..]);
                    }

                    // Single * - match anything except /
                    star_p = p;
                    star_t = t;
                    p += 1;
                    continue;
                },
                '?' => {
                    // Match any single character except /
                    if (text[t] != '/') {
                        p += 1;
                        t += 1;
                        continue;
                    }
                },
                '[' => {
                    // Character class
                    if (matchCharClass(pattern, &p, text[t])) {
                        t += 1;
                        continue;
                    }
                },
                '\\' => {
                    // Escaped character
                    p += 1;
                    if (p < pattern.len and pattern[p] == text[t]) {
                        p += 1;
                        t += 1;
                        continue;
                    }
                },
                else => |c| {
                    if (c == text[t]) {
                        p += 1;
                        t += 1;
                        continue;
                    }
                },
            }
        }

        // No match, try backtracking to last *
        if (star_p) |sp| {
            p = sp + 1;
            star_t += 1;
            t = star_t;

            // * doesn't match /
            if (star_t > 0 and text[star_t - 1] == '/') {
                return false;
            }
            continue;
        }

        return false;
    }

    // Consume trailing *
    while (p < pattern.len and pattern[p] == '*') {
        p += 1;
    }

    return p == pattern.len;
}

fn matchCharClass(pattern: []const u8, p: *usize, c: u8) bool {
    p.* += 1; // Skip '['

    var negated = false;
    if (p.* < pattern.len and pattern[p.*] == '!') {
        negated = true;
        p.* += 1;
    }

    var matched = false;
    var first = true;

    while (p.* < pattern.len and (pattern[p.*] != ']' or first)) {
        first = false;
        const start = pattern[p.*];
        p.* += 1;

        // Check for range
        if (p.* + 1 < pattern.len and pattern[p.*] == '-' and pattern[p.* + 1] != ']') {
            p.* += 1;
            const end = pattern[p.*];
            p.* += 1;

            if (c >= start and c <= end) {
                matched = true;
            }
        } else {
            if (c == start) {
                matched = true;
            }
        }
    }

    if (p.* < pattern.len) {
        p.* += 1; // Skip ']'
    }

    return if (negated) !matched else matched;
}

/// Matcher for gitignore patterns
pub const GitignoreMatcher = struct {
    allocator: std.mem.Allocator,
    patterns: std.ArrayListUnmanaged(Pattern),
    pattern_storage: std.ArrayListUnmanaged([]u8),

    pub fn init(allocator: std.mem.Allocator) GitignoreMatcher {
        return .{
            .allocator = allocator,
            .patterns = .{},
            .pattern_storage = .{},
        };
    }

    pub fn deinit(self: *GitignoreMatcher) void {
        for (self.pattern_storage.items) |stored| {
            self.allocator.free(stored);
        }
        self.pattern_storage.deinit(self.allocator);
        self.patterns.deinit(self.allocator);
    }

    /// Load patterns from a gitignore file
    pub fn loadFile(self: *GitignoreMatcher, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            try self.addPattern(line);
        }
    }

    /// Add a single pattern
    pub fn addPattern(self: *GitignoreMatcher, line: []const u8) !void {
        var pattern = std.mem.trim(u8, line, " \t\r");

        // Skip empty lines and comments
        if (pattern.len == 0 or pattern[0] == '#') return;

        var negated = false;
        var directory_only = false;
        var anchored = false;

        // Check for negation
        if (pattern[0] == '!') {
            negated = true;
            pattern = pattern[1..];
        }

        // Check for anchoring (starts with /)
        if (pattern.len > 0 and pattern[0] == '/') {
            anchored = true;
            pattern = pattern[1..];
        }

        // Check for directory-only (ends with /)
        if (pattern.len > 0 and pattern[pattern.len - 1] == '/') {
            directory_only = true;
            pattern = pattern[0 .. pattern.len - 1];
        }

        if (pattern.len == 0) return;

        // Store pattern string
        const stored = try self.allocator.dupe(u8, pattern);
        try self.pattern_storage.append(self.allocator, stored);

        try self.patterns.append(self.allocator, .{
            .pattern = stored,
            .negated = negated,
            .directory_only = directory_only,
            .anchored = anchored,
        });
    }

    /// Check if a path should be ignored
    pub fn isIgnored(self: *const GitignoreMatcher, path: []const u8) bool {
        var ignored = false;

        // Get the basename for non-anchored patterns
        const basename = std.fs.path.basename(path);

        for (self.patterns.items) |*pattern| {
            const target = if (pattern.anchored) path else basename;

            if (pattern.matches(target)) {
                ignored = !pattern.negated;
            }
        }

        return ignored;
    }

    /// Check common ignored directories directly (optimization)
    pub fn isCommonIgnoredDir(name: []const u8) bool {
        const ignored_dirs = [_][]const u8{
            ".git",
            "node_modules",
            ".svn",
            ".hg",
            "__pycache__",
            ".tox",
            ".eggs",
            "*.egg-info",
            "venv",
            ".venv",
            "target", // Rust
            "build",
            "dist",
            ".next",
            ".nuxt",
            "vendor", // Go, PHP
        };

        for (ignored_dirs) |dir| {
            if (std.mem.eql(u8, name, dir)) return true;
        }

        return false;
    }
};

// Tests
test "glob basic" {
    try std.testing.expect(globMatch("*.txt", "file.txt"));
    try std.testing.expect(!globMatch("*.txt", "file.rs"));
    try std.testing.expect(globMatch("test*", "testing"));
    try std.testing.expect(globMatch("*test*", "my_testing_file"));
}

test "glob double star" {
    try std.testing.expect(globMatch("**/*.txt", "dir/file.txt"));
    try std.testing.expect(globMatch("**/*.txt", "a/b/c/file.txt"));
    try std.testing.expect(globMatch("src/**/*.zig", "src/lib/file.zig"));
}

test "glob character class" {
    try std.testing.expect(globMatch("[abc]", "a"));
    try std.testing.expect(globMatch("[abc]", "b"));
    try std.testing.expect(!globMatch("[abc]", "d"));
    try std.testing.expect(globMatch("[a-z]", "m"));
    try std.testing.expect(!globMatch("[a-z]", "5"));
}

test "gitignore matcher" {
    const allocator = std.testing.allocator;

    var matcher = GitignoreMatcher.init(allocator);
    defer matcher.deinit();

    try matcher.addPattern("*.log");
    try matcher.addPattern("node_modules/");
    try matcher.addPattern("!important.log");

    try std.testing.expect(matcher.isIgnored("debug.log"));
    try std.testing.expect(matcher.isIgnored("node_modules"));
    try std.testing.expect(!matcher.isIgnored("important.log"));
    try std.testing.expect(!matcher.isIgnored("main.zig"));
}
