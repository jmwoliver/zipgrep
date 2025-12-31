const std = @import("std");

/// A pattern from a gitignore file with its scope
const Pattern = struct {
    pattern: []const u8,
    root: []const u8, // The directory where this .gitignore was found
    negated: bool,
    directory_only: bool,
    anchored: bool, // Pattern is relative to gitignore location
    contains_slash: bool, // Pattern contains a slash (besides leading/trailing)

    /// Match a path against this pattern
    /// The path should be relative to the search root (not absolute)
    fn matches(self: *const Pattern, path: []const u8, is_dir: bool) bool {
        // If pattern is directory-only, only match directories
        if (self.directory_only and !is_dir) {
            return false;
        }

        // Get path relative to pattern's root
        const rel_path = getRelativePath(path, self.root) orelse return false;
        if (rel_path.len == 0) return false;

        // If pattern is anchored or contains a slash, match against the full relative path
        // Otherwise, match against basename only
        if (self.anchored or self.contains_slash) {
            return globMatch(self.pattern, rel_path);
        } else {
            // Match against any path component
            const basename = std.fs.path.basename(rel_path);
            return globMatch(self.pattern, basename);
        }
    }
};

/// Get path relative to root (returns null if path is not under root)
fn getRelativePath(path: []const u8, root: []const u8) ?[]const u8 {
    // Handle empty root (current directory)
    if (root.len == 0 or std.mem.eql(u8, root, ".")) {
        return path;
    }

    // Normalize root by removing trailing slash for comparison
    var normalized_root = root;
    if (normalized_root.len > 0 and normalized_root[normalized_root.len - 1] == '/') {
        normalized_root = normalized_root[0 .. normalized_root.len - 1];
    }

    // Check if path starts with root
    if (path.len < normalized_root.len) return null;

    if (!std.mem.startsWith(u8, path, normalized_root)) {
        return null;
    }

    // Path must either equal root or have a separator after root
    if (path.len == normalized_root.len) {
        return "";
    }

    if (path[normalized_root.len] == '/') {
        return path[normalized_root.len + 1 ..];
    }

    return null;
}

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

/// Check if pattern contains a slash (besides leading/trailing)
fn patternContainsSlash(pattern: []const u8) bool {
    for (pattern, 0..) |c, i| {
        if (c == '/' and i > 0 and i < pattern.len - 1) {
            return true;
        }
    }
    return false;
}

/// Matcher for gitignore patterns with proper scoping
pub const GitignoreMatcher = struct {
    allocator: std.mem.Allocator,
    patterns: std.ArrayListUnmanaged(Pattern),
    pattern_storage: std.ArrayListUnmanaged([]u8),
    root_storage: std.ArrayListUnmanaged([]u8),

    pub fn init(allocator: std.mem.Allocator) GitignoreMatcher {
        return .{
            .allocator = allocator,
            .patterns = .{},
            .pattern_storage = .{},
            .root_storage = .{},
        };
    }

    pub fn deinit(self: *GitignoreMatcher) void {
        for (self.pattern_storage.items) |stored| {
            self.allocator.free(stored);
        }
        self.pattern_storage.deinit(self.allocator);

        for (self.root_storage.items) |stored| {
            self.allocator.free(stored);
        }
        self.root_storage.deinit(self.allocator);

        self.patterns.deinit(self.allocator);
    }

    /// Load patterns from a gitignore file
    /// root_dir is the directory containing the .gitignore file
    pub fn loadFile(self: *GitignoreMatcher, path: []const u8, root_dir: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            try self.addPattern(line, root_dir);
        }
    }

    /// Add a single pattern with its root directory
    pub fn addPattern(self: *GitignoreMatcher, line: []const u8, root_dir: []const u8) !void {
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

        // Check if pattern contains a slash (makes it anchored-like)
        const contains_slash = patternContainsSlash(pattern);

        // Store pattern string
        const stored_pattern = try self.allocator.dupe(u8, pattern);
        try self.pattern_storage.append(self.allocator, stored_pattern);

        // Store root directory
        const stored_root = try self.allocator.dupe(u8, root_dir);
        try self.root_storage.append(self.allocator, stored_root);

        try self.patterns.append(self.allocator, .{
            .pattern = stored_pattern,
            .root = stored_root,
            .negated = negated,
            .directory_only = directory_only,
            .anchored = anchored,
            .contains_slash = contains_slash,
        });
    }

    /// Check if a path should be ignored
    /// path should be relative to the search root
    /// is_dir indicates if the path is a directory
    pub fn isIgnored(self: *const GitignoreMatcher, path: []const u8, is_dir: bool) bool {
        var ignored = false;

        for (self.patterns.items) |*pattern| {
            if (pattern.matches(path, is_dir)) {
                ignored = !pattern.negated;
            }
        }

        return ignored;
    }

    /// Simplified check for paths (assumes file, not directory)
    pub fn isIgnoredFile(self: *const GitignoreMatcher, path: []const u8) bool {
        return self.isIgnored(path, false);
    }

    /// Check for directory
    pub fn isIgnoredDir(self: *const GitignoreMatcher, path: []const u8) bool {
        return self.isIgnored(path, true);
    }

    /// Check common ignored directories directly (optimization)
    /// These are directories that should ALWAYS be skipped regardless of .gitignore
    pub fn isCommonIgnoredDir(name: []const u8) bool {
        const ignored_dirs = [_][]const u8{
            ".git",
            ".svn",
            ".hg",
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

test "gitignore matcher basic" {
    const allocator = std.testing.allocator;

    var matcher = GitignoreMatcher.init(allocator);
    defer matcher.deinit();

    try matcher.addPattern("*.log", ".");
    try matcher.addPattern("node_modules/", ".");
    try matcher.addPattern("!important.log", ".");

    try std.testing.expect(matcher.isIgnoredFile("debug.log"));
    try std.testing.expect(matcher.isIgnoredDir("node_modules"));
    try std.testing.expect(!matcher.isIgnoredFile("important.log"));
    try std.testing.expect(!matcher.isIgnoredFile("main.zig"));
}

test "gitignore scoped patterns" {
    const allocator = std.testing.allocator;

    var matcher = GitignoreMatcher.init(allocator);
    defer matcher.deinit();

    // Pattern from root .gitignore
    try matcher.addPattern("*.log", ".");

    // Pattern from subdir .gitignore
    try matcher.addPattern("*.tmp", "subdir");

    // Root pattern should match everywhere
    try std.testing.expect(matcher.isIgnoredFile("debug.log"));
    try std.testing.expect(matcher.isIgnoredFile("subdir/debug.log"));

    // Subdir pattern should only match in subdir
    try std.testing.expect(!matcher.isIgnoredFile("file.tmp"));
    try std.testing.expect(matcher.isIgnoredFile("subdir/file.tmp"));
}

test "gitignore anchored patterns" {
    const allocator = std.testing.allocator;

    var matcher = GitignoreMatcher.init(allocator);
    defer matcher.deinit();

    // Anchored pattern (with leading /)
    try matcher.addPattern("/build", ".");

    // Should match at root only
    try std.testing.expect(matcher.isIgnoredDir("build"));
    try std.testing.expect(!matcher.isIgnoredDir("src/build"));
}

test "getRelativePath" {
    try std.testing.expectEqualStrings("file.txt", getRelativePath("dir/file.txt", "dir").?);
    try std.testing.expectEqualStrings("sub/file.txt", getRelativePath("dir/sub/file.txt", "dir").?);
    try std.testing.expect(getRelativePath("other/file.txt", "dir") == null);
    try std.testing.expectEqualStrings("file.txt", getRelativePath("file.txt", ".").?);
}

test "getRelativePath edge cases" {
    // Empty root treated as current directory
    try std.testing.expectEqualStrings("file.txt", getRelativePath("file.txt", "").?);

    // Path equals root returns empty string
    try std.testing.expectEqualStrings("", getRelativePath("dir", "dir").?);

    // Path shorter than root
    try std.testing.expect(getRelativePath("d", "dir") == null);

    // Path is prefix but no separator
    try std.testing.expect(getRelativePath("directory/file.txt", "dir") == null);

    // Root with trailing slash should work
    try std.testing.expectEqualStrings("file.txt", getRelativePath("tests/fixtures/file.txt", "tests/fixtures/").?);
    try std.testing.expectEqualStrings("ignored.txt", getRelativePath("tests/fixtures/ignored.txt", "tests/fixtures/").?);
}

test "glob question mark" {
    try std.testing.expect(globMatch("?", "a"));
    try std.testing.expect(globMatch("?", "x"));
    try std.testing.expect(!globMatch("?", ""));
    try std.testing.expect(!globMatch("?", "ab"));
    try std.testing.expect(globMatch("a?c", "abc"));
    try std.testing.expect(!globMatch("a?c", "ac"));
}

test "glob escaped characters" {
    try std.testing.expect(globMatch("\\*", "*"));
    try std.testing.expect(!globMatch("\\*", "a"));
    try std.testing.expect(globMatch("a\\*b", "a*b"));
}

test "glob empty pattern" {
    try std.testing.expect(globMatch("", ""));
    try std.testing.expect(!globMatch("", "a"));
}

test "glob negated character class" {
    try std.testing.expect(globMatch("[!abc]", "d"));
    try std.testing.expect(globMatch("[!abc]", "x"));
    try std.testing.expect(!globMatch("[!abc]", "a"));
    try std.testing.expect(!globMatch("[!abc]", "b"));
}

test "glob single star does not cross slash" {
    try std.testing.expect(globMatch("*.txt", "file.txt"));
    try std.testing.expect(!globMatch("*.txt", "dir/file.txt"));
    try std.testing.expect(globMatch("src/*.zig", "src/main.zig"));
    try std.testing.expect(!globMatch("src/*.zig", "src/sub/main.zig"));
}

test "gitignore directory only pattern" {
    const allocator = std.testing.allocator;

    var matcher = GitignoreMatcher.init(allocator);
    defer matcher.deinit();

    try matcher.addPattern("build/", "."); // Directory only pattern

    // Should match directories
    try std.testing.expect(matcher.isIgnoredDir("build"));

    // Should NOT match files
    try std.testing.expect(!matcher.isIgnoredFile("build"));
}

test "gitignore double star middle" {
    try std.testing.expect(globMatch("a/**/b", "a/b"));
    try std.testing.expect(globMatch("a/**/b", "a/x/b"));
    try std.testing.expect(globMatch("a/**/b", "a/x/y/z/b"));
    try std.testing.expect(!globMatch("a/**/b", "a/x/c"));
}

test "gitignore comment lines" {
    const allocator = std.testing.allocator;

    var matcher = GitignoreMatcher.init(allocator);
    defer matcher.deinit();

    try matcher.addPattern("# this is a comment", ".");
    try matcher.addPattern("*.log", ".");

    // Comment should be ignored, *.log should work
    try std.testing.expect(matcher.isIgnoredFile("debug.log"));
    try std.testing.expectEqual(@as(usize, 1), matcher.patterns.items.len);
}

test "gitignore whitespace trimming" {
    const allocator = std.testing.allocator;

    var matcher = GitignoreMatcher.init(allocator);
    defer matcher.deinit();

    try matcher.addPattern("  *.log  ", "."); // Leading/trailing whitespace

    try std.testing.expect(matcher.isIgnoredFile("debug.log"));
}

test "gitignore empty lines" {
    const allocator = std.testing.allocator;

    var matcher = GitignoreMatcher.init(allocator);
    defer matcher.deinit();

    try matcher.addPattern("", ".");
    try matcher.addPattern("   ", ".");
    try matcher.addPattern("*.log", ".");

    // Empty lines should be skipped
    try std.testing.expectEqual(@as(usize, 1), matcher.patterns.items.len);
}

test "isCommonIgnoredDir" {
    try std.testing.expect(GitignoreMatcher.isCommonIgnoredDir(".git"));
    try std.testing.expect(GitignoreMatcher.isCommonIgnoredDir(".svn"));
    try std.testing.expect(GitignoreMatcher.isCommonIgnoredDir(".hg"));
    try std.testing.expect(!GitignoreMatcher.isCommonIgnoredDir("node_modules"));
    try std.testing.expect(!GitignoreMatcher.isCommonIgnoredDir("src"));
    try std.testing.expect(!GitignoreMatcher.isCommonIgnoredDir(".gitignore"));
}

test "gitignore pattern with slash" {
    const allocator = std.testing.allocator;

    var matcher = GitignoreMatcher.init(allocator);
    defer matcher.deinit();

    // Pattern with slash should only match relative to root
    try matcher.addPattern("src/*.txt", ".");

    try std.testing.expect(matcher.isIgnoredFile("src/file.txt"));
    try std.testing.expect(!matcher.isIgnoredFile("other/file.txt"));
}

test "gitignore negation override" {
    const allocator = std.testing.allocator;

    var matcher = GitignoreMatcher.init(allocator);
    defer matcher.deinit();

    try matcher.addPattern("*.log", ".");
    try matcher.addPattern("!important.log", ".");

    try std.testing.expect(matcher.isIgnoredFile("debug.log"));
    try std.testing.expect(matcher.isIgnoredFile("error.log"));
    try std.testing.expect(!matcher.isIgnoredFile("important.log"));
}

test "patternContainsSlash" {
    try std.testing.expect(!patternContainsSlash("*.txt"));
    try std.testing.expect(patternContainsSlash("src/*.txt"));
    try std.testing.expect(patternContainsSlash("a/b/c"));
    // Leading/trailing slashes don't count
    try std.testing.expect(!patternContainsSlash("/build"));
    try std.testing.expect(!patternContainsSlash("build/"));
}
