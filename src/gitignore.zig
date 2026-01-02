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
        // Strip leading ./ if present to normalize paths
        if (path.len >= 2 and path[0] == '.' and path[1] == '/') {
            return path[2..];
        }
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
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
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

const main = @import("main.zig");

/// Check if a path matches the given glob patterns from -g/--glob flags.
/// Returns true if the path should be included in the search.
///
/// Logic:
/// - If no patterns: include all files
/// - If any inclusion patterns exist (non-negated), path must match at least one
/// - If path matches any exclusion pattern (negated with !), exclude it
/// - For directory patterns ending with /, match against path with appended /
pub fn matchesGlobPatterns(path: []const u8, is_dir: bool, patterns: []const main.GlobPattern) bool {
    if (patterns.len == 0) return true;

    // Check if there are any inclusion patterns (non-negated)
    var has_file_inclusion = false;
    var has_dir_inclusion = false;
    var matches_inclusion = false;

    for (patterns) |pat| {
        if (!pat.negated) {
            // For directory-only patterns (ending with /), only match directories
            if (pat.pattern.len > 0 and pat.pattern[pat.pattern.len - 1] == '/') {
                has_dir_inclusion = true;
                if (is_dir) {
                    const pattern_without_slash = pat.pattern[0 .. pat.pattern.len - 1];
                    if (matchPath(pattern_without_slash, path)) {
                        matches_inclusion = true;
                    }
                }
            } else {
                has_file_inclusion = true;
                if (matchPath(pat.pattern, path)) {
                    matches_inclusion = true;
                }
            }
        }
    }

    // Apply inclusion logic:
    // - If we're checking a directory and there's only file inclusion patterns (like *.zig),
    //   always include directories so we can recurse into them
    // - If we're checking a file and there are file inclusion patterns, file must match
    // - If we're checking a directory and there are dir inclusion patterns, dir must match
    if (is_dir) {
        // Only filter directories if there are directory-specific inclusion patterns
        if (has_dir_inclusion and !matches_inclusion) {
            return false;
        }
        // File inclusion patterns (*.zig) don't filter directories
    } else {
        // Files must match if there are file inclusion patterns
        if (has_file_inclusion and !matches_inclusion) {
            return false;
        }
    }

    // Check exclusion patterns (negated with !)
    for (patterns) |pat| {
        if (pat.negated) {
            // For directory-only patterns (ending with /), only match directories
            if (pat.pattern.len > 0 and pat.pattern[pat.pattern.len - 1] == '/') {
                if (is_dir) {
                    const pattern_without_slash = pat.pattern[0 .. pat.pattern.len - 1];
                    if (matchPath(pattern_without_slash, path)) {
                        return false;
                    }
                }
            } else {
                if (matchPath(pat.pattern, path)) {
                    return false;
                }
            }
        }
    }

    return true;
}

/// Match a glob pattern against a path.
/// For patterns without /, match against basename only.
/// For patterns with /, match against the full path.
fn matchPath(pattern: []const u8, path: []const u8) bool {
    // Normalize path: strip leading ./ if present
    const normalized_path = if (path.len >= 2 and path[0] == '.' and path[1] == '/')
        path[2..]
    else
        path;

    // Patterns with / or ** match against the full path
    if (std.mem.indexOf(u8, pattern, "/") != null or
        std.mem.indexOf(u8, pattern, "**") != null)
    {
        return globMatch(pattern, normalized_path);
    }

    // Patterns without / match against the basename
    const basename = std.fs.path.basename(normalized_path);
    return globMatch(pattern, basename);
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

    /// Get current number of patterns (for state tracking)
    pub fn patternCount(self: *const GitignoreMatcher) usize {
        return self.patterns.items.len;
    }
};

/// Thread-local gitignore state that can be cheaply cloned.
/// Used by parallel workers to have their own copy of gitignore patterns
/// that can be extended with local patterns without affecting other threads.
pub const GitignoreState = struct {
    /// Reference to the shared base patterns (immutable, not owned)
    base: ?*const GitignoreMatcher,

    /// Additional local patterns specific to this state (owned)
    local_patterns: std.ArrayListUnmanaged(Pattern),
    local_pattern_storage: std.ArrayListUnmanaged([]u8),
    local_root_storage: std.ArrayListUnmanaged([]u8),

    /// Allocator for local patterns
    allocator: std.mem.Allocator,

    /// Create a new state with optional base patterns
    pub fn init(allocator: std.mem.Allocator, base: ?*const GitignoreMatcher) GitignoreState {
        return .{
            .base = base,
            .local_patterns = .{},
            .local_pattern_storage = .{},
            .local_root_storage = .{},
            .allocator = allocator,
        };
    }

    /// Create a shallow clone of this state.
    /// The clone shares the base reference but has its own empty local patterns.
    /// This is cheap - O(1) - since local patterns start empty.
    pub fn clone(self: *const GitignoreState) GitignoreState {
        return .{
            .base = self.base,
            .local_patterns = .{},
            .local_pattern_storage = .{},
            .local_root_storage = .{},
            .allocator = self.allocator,
        };
    }

    /// Create a deep clone that copies local patterns as well.
    /// Use when you need to preserve local patterns in the clone.
    pub fn deepClone(self: *const GitignoreState) !GitignoreState {
        var new_state = GitignoreState{
            .base = self.base,
            .local_patterns = .{},
            .local_pattern_storage = .{},
            .local_root_storage = .{},
            .allocator = self.allocator,
        };

        // Copy all local patterns
        for (self.local_patterns.items) |pattern| {
            const stored_pattern = try self.allocator.dupe(u8, pattern.pattern);
            errdefer self.allocator.free(stored_pattern);

            const stored_root = try self.allocator.dupe(u8, pattern.root);
            errdefer self.allocator.free(stored_root);

            try new_state.local_pattern_storage.append(self.allocator, stored_pattern);
            try new_state.local_root_storage.append(self.allocator, stored_root);

            try new_state.local_patterns.append(self.allocator, .{
                .pattern = stored_pattern,
                .root = stored_root,
                .negated = pattern.negated,
                .directory_only = pattern.directory_only,
                .anchored = pattern.anchored,
                .contains_slash = pattern.contains_slash,
            });
        }

        return new_state;
    }

    pub fn deinit(self: *GitignoreState) void {
        for (self.local_pattern_storage.items) |stored| {
            self.allocator.free(stored);
        }
        self.local_pattern_storage.deinit(self.allocator);

        for (self.local_root_storage.items) |stored| {
            self.allocator.free(stored);
        }
        self.local_root_storage.deinit(self.allocator);

        self.local_patterns.deinit(self.allocator);
    }

    /// Add a local pattern to this state
    pub fn addPattern(self: *GitignoreState, line: []const u8, root_dir: []const u8) !void {
        var pattern_text = std.mem.trim(u8, line, " \t\r");

        // Skip empty lines and comments
        if (pattern_text.len == 0 or pattern_text[0] == '#') return;

        var negated = false;
        var directory_only = false;
        var anchored = false;

        // Check for negation
        if (pattern_text[0] == '!') {
            negated = true;
            pattern_text = pattern_text[1..];
        }

        // Check for anchoring (starts with /)
        if (pattern_text.len > 0 and pattern_text[0] == '/') {
            anchored = true;
            pattern_text = pattern_text[1..];
        }

        // Check for directory-only (ends with /)
        if (pattern_text.len > 0 and pattern_text[pattern_text.len - 1] == '/') {
            directory_only = true;
            pattern_text = pattern_text[0 .. pattern_text.len - 1];
        }

        if (pattern_text.len == 0) return;

        // Check if pattern contains a slash
        const contains_slash = patternContainsSlash(pattern_text);

        // Store pattern string
        const stored_pattern = try self.allocator.dupe(u8, pattern_text);
        errdefer self.allocator.free(stored_pattern);
        try self.local_pattern_storage.append(self.allocator, stored_pattern);

        // Store root directory
        const stored_root = try self.allocator.dupe(u8, root_dir);
        errdefer self.allocator.free(stored_root);
        try self.local_root_storage.append(self.allocator, stored_root);

        try self.local_patterns.append(self.allocator, .{
            .pattern = stored_pattern,
            .root = stored_root,
            .negated = negated,
            .directory_only = directory_only,
            .anchored = anchored,
            .contains_slash = contains_slash,
        });
    }

    /// Load patterns from a gitignore file
    pub fn loadFile(self: *GitignoreState, path: []const u8, root_dir: []const u8) !void {
        const file = std.fs.cwd().openFile(path, .{}) catch return;
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            try self.addPattern(line, root_dir);
        }
    }

    /// Check if a path should be ignored
    pub fn isIgnored(self: *const GitignoreState, path: []const u8, is_dir: bool) bool {
        var ignored = false;

        // Check base patterns first
        if (self.base) |base| {
            for (base.patterns.items) |*pattern| {
                if (pattern.matches(path, is_dir)) {
                    ignored = !pattern.negated;
                }
            }
        }

        // Then check local patterns (can override base patterns)
        for (self.local_patterns.items) |*pattern| {
            if (pattern.matches(path, is_dir)) {
                ignored = !pattern.negated;
            }
        }

        return ignored;
    }

    /// Check if a file should be ignored
    pub fn isIgnoredFile(self: *const GitignoreState, path: []const u8) bool {
        return self.isIgnored(path, false);
    }

    /// Check if a directory should be ignored
    pub fn isIgnoredDir(self: *const GitignoreState, path: []const u8) bool {
        return self.isIgnored(path, true);
    }

    /// Get total number of patterns (base + local)
    pub fn patternCount(self: *const GitignoreState) usize {
        const base_count = if (self.base) |b| b.patterns.items.len else 0;
        return base_count + self.local_patterns.items.len;
    }

    /// Get number of local patterns only
    pub fn localPatternCount(self: *const GitignoreState) usize {
        return self.local_patterns.items.len;
    }
};

/// Find the git repository root by walking up from the given path.
/// Returns the path containing .git, or null if no .git directory is found.
/// The returned path is allocated and must be freed by the caller.
pub fn findGitRoot(allocator: std.mem.Allocator, start_path: []const u8) ?[]const u8 {
    // Make path absolute if relative
    const abs_path = std.fs.cwd().realpathAlloc(allocator, start_path) catch return null;
    defer allocator.free(abs_path);

    var current: []const u8 = abs_path;
    while (true) {
        // Check for .git directory or file (submodules use .git file)
        const git_path = std.fs.path.join(allocator, &.{ current, ".git" }) catch return null;
        defer allocator.free(git_path);

        if (std.fs.cwd().statFile(git_path)) |stat| {
            // .git can be a directory (normal repo) or file (submodule/worktree)
            if (stat.kind == .directory or stat.kind == .file) {
                return allocator.dupe(u8, current) catch null;
            }
        } else |_| {}

        // Move to parent directory
        if (std.fs.path.dirname(current)) |parent| {
            // Check if we've reached the root (dirname returns "/" for "/")
            if (std.mem.eql(u8, parent, current)) break;
            current = parent;
        } else {
            break;
        }
    }
    return null;
}

/// Load .gitignore files from a git repository root down to (and including) a search path.
/// This ensures parent gitignore patterns are loaded before child patterns.
/// `git_root` is the path containing .git
/// `search_path` is the user-provided search path (may be a subdirectory of git_root)
pub fn loadAncestorGitignores(
    ignore_matcher: *GitignoreMatcher,
    git_root: []const u8,
    search_path: []const u8,
    allocator: std.mem.Allocator,
) void {
    // Make both paths absolute for comparison
    const abs_git_root = std.fs.cwd().realpathAlloc(allocator, git_root) catch return;
    defer allocator.free(abs_git_root);

    const abs_search_path = std.fs.cwd().realpathAlloc(allocator, search_path) catch return;
    defer allocator.free(abs_search_path);

    // Get absolute cwd for converting back to relative paths
    const abs_cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch return;
    defer allocator.free(abs_cwd);

    // search_path should be under or equal to git_root
    if (!std.mem.startsWith(u8, abs_search_path, abs_git_root)) {
        return;
    }

    // Build list of directories from git root to search path
    var dirs = std.ArrayListUnmanaged([]const u8){};
    defer {
        for (dirs.items) |d| allocator.free(d);
        dirs.deinit(allocator);
    }

    // Start from search path and walk up to git root, collecting directories
    var current: []const u8 = abs_search_path;
    while (true) {
        const dup = allocator.dupe(u8, current) catch break;
        dirs.append(allocator, dup) catch {
            allocator.free(dup);
            break;
        };

        // Stop if we've reached or passed the git root
        if (std.mem.eql(u8, current, abs_git_root)) break;

        // Move to parent
        if (std.fs.path.dirname(current)) |parent| {
            if (std.mem.eql(u8, parent, current)) break; // At filesystem root
            current = parent;
        } else {
            break;
        }
    }

    // Reverse to process from git root to search path (parent patterns first)
    std.mem.reverse([]const u8, dirs.items);

    // Load .gitignore from each directory in order
    // Use relative paths for pattern roots so they match how the walker checks paths
    for (dirs.items) |abs_dir| {
        const gitignore_path = std.fs.path.join(allocator, &.{ abs_dir, ".gitignore" }) catch continue;
        defer allocator.free(gitignore_path);

        // Convert absolute directory path to relative path from cwd
        // This ensures patterns match the relative paths used by the walker
        const rel_dir = if (std.mem.startsWith(u8, abs_dir, abs_cwd) and abs_dir.len > abs_cwd.len and abs_dir[abs_cwd.len] == '/')
            abs_dir[abs_cwd.len + 1 ..]
        else if (std.mem.eql(u8, abs_dir, abs_cwd))
            "."
        else
            abs_dir; // Keep absolute if not under cwd

        ignore_matcher.loadFile(gitignore_path, rel_dir) catch {};
    }
}

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

test "glob with ./ prefix in path" {
    // This tests the issue where paths like ./src/file.go don't match src/**/*.go
    // Because the ./ prefix prevents matching
    try std.testing.expect(globMatch("src/**/*.go", "src/listen.go"));
    try std.testing.expect(globMatch("src/**/*.go", "src/store/scheduler.go"));

    // The globMatch function itself doesn't normalize paths - that's done in matchPath
    // Direct globMatch with ./ prefix won't match (expected behavior)
    try std.testing.expect(!globMatch("src/**/*.go", "./src/listen.go"));
}

test "matchPath normalizes ./ prefix" {
    // matchPath should strip ./ prefix before matching
    try std.testing.expect(matchPath("src/**/*.go", "./src/listen.go"));
    try std.testing.expect(matchPath("src/**/*.go", "./src/store/scheduler.go"));
    try std.testing.expect(matchPath("src/**/*.go", "src/listen.go"));
    try std.testing.expect(matchPath("src/*.go", "./src/listen.go"));
    try std.testing.expect(!matchPath("src/**/*.go", "./vendor/foo.go"));
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

test "gitignore anchored patterns with ./ prefix" {
    const allocator = std.testing.allocator;

    var matcher = GitignoreMatcher.init(allocator);
    defer matcher.deinit();

    // Anchored pattern (with leading /)
    try matcher.addPattern("/pkg", ".");

    // Paths with ./ prefix should match anchored patterns at root
    try std.testing.expect(matcher.isIgnoredDir("./pkg"));
    try std.testing.expect(matcher.isIgnoredDir("pkg"));

    // Should not match when nested under another directory
    try std.testing.expect(!matcher.isIgnoredDir("./src/pkg"));
    try std.testing.expect(!matcher.isIgnoredFile("./src/pkg/file.txt"));

    // Note: Pattern /pkg (without trailing slash) matches both files and directories named "pkg"
    // The pattern would need trailing slash like /pkg/ to only match directories
    try std.testing.expect(matcher.isIgnoredFile("./pkg")); // Non-directory-only pattern matches files too
}

test "gitignore multiple anchored patterns with ./ prefix" {
    const allocator = std.testing.allocator;

    var matcher = GitignoreMatcher.init(allocator);
    defer matcher.deinit();

    // Multiple anchored patterns from a typical .gitignore
    try matcher.addPattern("/pkg", ".");
    try matcher.addPattern("/data-postgresql/", ".");
    try matcher.addPattern("/packaging/build-*", ".");

    // Test /pkg pattern
    try std.testing.expect(matcher.isIgnoredDir("./pkg"));
    try std.testing.expect(matcher.isIgnoredDir("pkg"));

    // Test /data-postgresql/ pattern (directory-only)
    try std.testing.expect(matcher.isIgnoredDir("./data-postgresql"));
    try std.testing.expect(matcher.isIgnoredDir("data-postgresql"));
    try std.testing.expect(!matcher.isIgnoredFile("data-postgresql")); // Not a file match

    // Test /packaging/build-* pattern (wildcard) - these MUST pass
    try std.testing.expect(matcher.isIgnoredDir("./packaging/build-deb"));
    try std.testing.expect(matcher.isIgnoredDir("packaging/build-deb"));
    try std.testing.expect(matcher.isIgnoredDir("./packaging/build-rpm"));
    try std.testing.expect(!matcher.isIgnoredDir("./packaging/src")); // Doesn't match pattern
}

test "gitignore pattern with slash in middle" {
    const allocator = std.testing.allocator;

    var matcher = GitignoreMatcher.init(allocator);
    defer matcher.deinit();

    // Pattern with slash in the middle (like /packaging/build-*)
    try matcher.addPattern("/packaging/build-*", ".");

    // Debug: verify pattern is stored correctly
    try std.testing.expectEqual(@as(usize, 1), matcher.patternCount());

    // Should match directories with the pattern
    try std.testing.expect(matcher.isIgnoredDir("packaging/build-deb"));
    try std.testing.expect(matcher.isIgnoredDir("./packaging/build-deb"));
    try std.testing.expect(matcher.isIgnoredDir("packaging/build-rpm"));
    try std.testing.expect(matcher.isIgnoredFile("packaging/build-foo")); // File also matches (no trailing /)
    try std.testing.expect(!matcher.isIgnoredDir("packaging/src")); // Doesn't match
    try std.testing.expect(!matcher.isIgnoredDir("other/packaging/build-deb")); // Wrong root
}

test "gitignore pattern with absolute paths" {
    const allocator = std.testing.allocator;

    var matcher = GitignoreMatcher.init(allocator);
    defer matcher.deinit();

    // Pattern loaded with absolute root (simulating loading .gitignore with full path)
    try matcher.addPattern("/packaging/build-*", "/tmp/gitignore_test2");

    // Debug: verify pattern is stored correctly
    try std.testing.expectEqual(@as(usize, 1), matcher.patternCount());

    // Should match absolute paths
    try std.testing.expect(matcher.isIgnoredDir("/tmp/gitignore_test2/packaging/build-deb"));
    try std.testing.expect(matcher.isIgnoredDir("/tmp/gitignore_test2/packaging/build-rpm"));
    try std.testing.expect(!matcher.isIgnoredDir("/tmp/gitignore_test2/packaging/src"));
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

test "getRelativePath strips ./ prefix" {
    // Paths with ./ prefix should be normalized when root is . or empty
    try std.testing.expectEqualStrings("pkg", getRelativePath("./pkg", ".").?);
    try std.testing.expectEqualStrings("pkg/mod/file.txt", getRelativePath("./pkg/mod/file.txt", ".").?);
    try std.testing.expectEqualStrings("file.txt", getRelativePath("./file.txt", ".").?);
    try std.testing.expectEqualStrings("pkg", getRelativePath("./pkg", "").?);
    try std.testing.expectEqualStrings("a/b/c", getRelativePath("./a/b/c", ".").?);
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

    // Test patterns like /packaging/build-* which should match packaging/build-deb
    try std.testing.expect(globMatch("packaging/build-*", "packaging/build-deb"));
    try std.testing.expect(globMatch("packaging/build-*", "packaging/build-rpm"));
    try std.testing.expect(!globMatch("packaging/build-*", "packaging/src"));
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

// GitignoreState tests

test "GitignoreState: init with no base" {
    const allocator = std.testing.allocator;

    var state = GitignoreState.init(allocator, null);
    defer state.deinit();

    try std.testing.expect(state.base == null);
    try std.testing.expectEqual(@as(usize, 0), state.patternCount());
    try std.testing.expectEqual(@as(usize, 0), state.localPatternCount());
}

test "GitignoreState: init with base" {
    const allocator = std.testing.allocator;

    var matcher = GitignoreMatcher.init(allocator);
    defer matcher.deinit();

    try matcher.addPattern("*.log", ".");

    var state = GitignoreState.init(allocator, &matcher);
    defer state.deinit();

    try std.testing.expect(state.base != null);
    try std.testing.expectEqual(@as(usize, 1), state.patternCount());
    try std.testing.expectEqual(@as(usize, 0), state.localPatternCount());

    // Should respect base patterns
    try std.testing.expect(state.isIgnoredFile("debug.log"));
    try std.testing.expect(!state.isIgnoredFile("main.zig"));
}

test "GitignoreState: add local patterns" {
    const allocator = std.testing.allocator;

    var matcher = GitignoreMatcher.init(allocator);
    defer matcher.deinit();

    try matcher.addPattern("*.log", ".");

    var state = GitignoreState.init(allocator, &matcher);
    defer state.deinit();

    // Add local pattern
    try state.addPattern("*.tmp", "subdir");

    try std.testing.expectEqual(@as(usize, 2), state.patternCount());
    try std.testing.expectEqual(@as(usize, 1), state.localPatternCount());

    // Base pattern still works
    try std.testing.expect(state.isIgnoredFile("debug.log"));

    // Local pattern works in scope
    try std.testing.expect(state.isIgnoredFile("subdir/file.tmp"));
    try std.testing.expect(!state.isIgnoredFile("file.tmp")); // Outside scope
}

test "GitignoreState: clone is shallow" {
    const allocator = std.testing.allocator;

    var matcher = GitignoreMatcher.init(allocator);
    defer matcher.deinit();

    try matcher.addPattern("*.log", ".");

    var state = GitignoreState.init(allocator, &matcher);
    defer state.deinit();

    try state.addPattern("*.tmp", ".");

    // Clone
    var cloned = state.clone();
    defer cloned.deinit();

    // Clone has same base but no local patterns
    try std.testing.expect(cloned.base == state.base);
    try std.testing.expectEqual(@as(usize, 1), cloned.patternCount()); // Only base
    try std.testing.expectEqual(@as(usize, 0), cloned.localPatternCount());

    // Original still has local patterns
    try std.testing.expectEqual(@as(usize, 2), state.patternCount());
    try std.testing.expectEqual(@as(usize, 1), state.localPatternCount());
}

test "GitignoreState: deepClone copies local patterns" {
    const allocator = std.testing.allocator;

    var matcher = GitignoreMatcher.init(allocator);
    defer matcher.deinit();

    try matcher.addPattern("*.log", ".");

    var state = GitignoreState.init(allocator, &matcher);
    defer state.deinit();

    try state.addPattern("*.tmp", ".");
    try state.addPattern("build/", ".");

    // Deep clone
    var cloned = try state.deepClone();
    defer cloned.deinit();

    // Clone has same base AND copies of local patterns
    try std.testing.expect(cloned.base == state.base);
    try std.testing.expectEqual(@as(usize, 3), cloned.patternCount());
    try std.testing.expectEqual(@as(usize, 2), cloned.localPatternCount());

    // Patterns work in clone
    try std.testing.expect(cloned.isIgnoredFile("debug.log"));
    try std.testing.expect(cloned.isIgnoredFile("file.tmp"));
    try std.testing.expect(cloned.isIgnoredDir("build"));
}

test "GitignoreState: local patterns override base" {
    const allocator = std.testing.allocator;

    var matcher = GitignoreMatcher.init(allocator);
    defer matcher.deinit();

    try matcher.addPattern("*.log", "."); // Ignore all .log

    var state = GitignoreState.init(allocator, &matcher);
    defer state.deinit();

    // Add negation locally
    try state.addPattern("!important.log", ".");

    try std.testing.expect(state.isIgnoredFile("debug.log"));
    try std.testing.expect(!state.isIgnoredFile("important.log")); // Negated locally
}

test "GitignoreState: no base patterns" {
    const allocator = std.testing.allocator;

    var state = GitignoreState.init(allocator, null);
    defer state.deinit();

    try state.addPattern("*.log", ".");
    try state.addPattern("build/", ".");

    try std.testing.expectEqual(@as(usize, 2), state.patternCount());
    try std.testing.expect(state.isIgnoredFile("test.log"));
    try std.testing.expect(state.isIgnoredDir("build"));
    try std.testing.expect(!state.isIgnoredFile("main.zig"));
}

// Tests for matchesGlobPatterns (CLI -g flag matching)

test "matchesGlobPatterns: empty patterns includes all" {
    const patterns = [_]main.GlobPattern{};
    try std.testing.expect(matchesGlobPatterns("file.txt", false, &patterns));
    try std.testing.expect(matchesGlobPatterns("dir", true, &patterns));
}

test "matchesGlobPatterns: file inclusion pattern" {
    const patterns = [_]main.GlobPattern{
        .{ .pattern = "*.zig", .negated = false },
    };
    try std.testing.expect(matchesGlobPatterns("main.zig", false, &patterns));
    try std.testing.expect(matchesGlobPatterns("src/main.zig", false, &patterns));
    try std.testing.expect(!matchesGlobPatterns("main.rs", false, &patterns));
    // Directories should pass through (not filtered by file patterns)
    try std.testing.expect(matchesGlobPatterns("src", true, &patterns));
}

test "matchesGlobPatterns: directory exclusion pattern" {
    const patterns = [_]main.GlobPattern{
        .{ .pattern = "tests/", .negated = true },
    };
    // File should be included (not a directory)
    try std.testing.expect(matchesGlobPatterns("file.txt", false, &patterns));
    try std.testing.expect(matchesGlobPatterns("build.zig", false, &patterns));
    // Directory "tests" should be excluded
    try std.testing.expect(!matchesGlobPatterns("tests", true, &patterns));
    try std.testing.expect(!matchesGlobPatterns("./tests", true, &patterns));
    // Other directories should be included
    try std.testing.expect(matchesGlobPatterns("src", true, &patterns));
}

test "matchesGlobPatterns: file exclusion pattern" {
    const patterns = [_]main.GlobPattern{
        .{ .pattern = "*.log", .negated = true },
    };
    // .log files should be excluded
    try std.testing.expect(!matchesGlobPatterns("debug.log", false, &patterns));
    try std.testing.expect(!matchesGlobPatterns("./error.log", false, &patterns));
    // Other files should be included
    try std.testing.expect(matchesGlobPatterns("main.zig", false, &patterns));
}

test "matchesGlobPatterns: combined include and exclude" {
    const patterns = [_]main.GlobPattern{
        .{ .pattern = "*.zig", .negated = false },
        .{ .pattern = "main.zig", .negated = true },
    };
    // Include *.zig but exclude main.zig
    try std.testing.expect(matchesGlobPatterns("walker.zig", false, &patterns));
    try std.testing.expect(!matchesGlobPatterns("main.zig", false, &patterns));
    try std.testing.expect(!matchesGlobPatterns("file.rs", false, &patterns));
}

test "matchesGlobPatterns: directory include pattern" {
    const patterns = [_]main.GlobPattern{
        .{ .pattern = "src/", .negated = false },
    };
    // Only directories matching src/ should be included
    try std.testing.expect(matchesGlobPatterns("src", true, &patterns));
    try std.testing.expect(!matchesGlobPatterns("tests", true, &patterns));
    // Files don't have directory inclusion patterns, so they pass
    try std.testing.expect(matchesGlobPatterns("file.txt", false, &patterns));
}

// ============================================================================
// findGitRoot tests
// ============================================================================

test "findGitRoot: finds git root from repo root" {
    const allocator = std.testing.allocator;

    // Use the actual repo we're in
    if (findGitRoot(allocator, ".")) |git_root| {
        defer allocator.free(git_root);
        // Should find a git root (we're in a git repo)
        // Verify it contains .git
        const git_path = std.fs.path.join(allocator, &.{ git_root, ".git" }) catch unreachable;
        defer allocator.free(git_path);
        const stat = std.fs.cwd().statFile(git_path) catch unreachable;
        try std.testing.expect(stat.kind == .directory or stat.kind == .file);
    } else {
        // If we're not in a git repo (e.g., running tests in isolation), skip
        return;
    }
}

test "findGitRoot: finds git root from subdirectory" {
    const allocator = std.testing.allocator;

    // Use src/ subdirectory of the actual repo
    if (findGitRoot(allocator, "src")) |git_root| {
        defer allocator.free(git_root);
        // Should find the same git root as from "."
        if (findGitRoot(allocator, ".")) |root_git_root| {
            defer allocator.free(root_git_root);
            try std.testing.expectEqualStrings(root_git_root, git_root);
        }
    } else {
        return; // Not in a git repo
    }
}

test "findGitRoot: finds git root from deeply nested path" {
    const allocator = std.testing.allocator;

    // Use tests/fixtures/subdir which is deeply nested
    if (findGitRoot(allocator, "tests/fixtures/subdir")) |git_root| {
        defer allocator.free(git_root);
        // Should find the same git root as from "."
        if (findGitRoot(allocator, ".")) |root_git_root| {
            defer allocator.free(root_git_root);
            try std.testing.expectEqualStrings(root_git_root, git_root);
        }
    } else {
        return; // Not in a git repo
    }
}

test "findGitRoot: returns null outside git repo" {
    const allocator = std.testing.allocator;

    // /tmp is unlikely to be inside a git repo
    const result = findGitRoot(allocator, "/tmp");
    if (result) |git_root| {
        // If /tmp happens to be in a git repo, free and skip
        allocator.free(git_root);
        return;
    }
    try std.testing.expect(result == null);
}

test "findGitRoot: returns null for nonexistent path" {
    const allocator = std.testing.allocator;

    const result = findGitRoot(allocator, "/nonexistent/path/that/does/not/exist");
    try std.testing.expect(result == null);
}

// ============================================================================
// loadAncestorGitignores tests
// ============================================================================

test "loadAncestorGitignores: loads gitignore at git root" {
    const allocator = std.testing.allocator;

    // Create a temporary directory structure with .git and .gitignore
    const tmp_dir_raw = "/tmp/gitignore_ancestor_test1";

    // Clean up any previous test run
    std.fs.cwd().deleteTree(tmp_dir_raw) catch {};

    // Create directory structure
    std.fs.cwd().makePath(tmp_dir_raw) catch return;
    defer std.fs.cwd().deleteTree(tmp_dir_raw) catch {};

    // Get the real path (resolves symlinks like /tmp -> /private/tmp on macOS)
    const tmp_dir = std.fs.cwd().realpathAlloc(allocator, tmp_dir_raw) catch return;
    defer allocator.free(tmp_dir);

    // Create .git directory (to mark as git root)
    const git_dir = std.fs.path.join(allocator, &.{ tmp_dir, ".git" }) catch return;
    defer allocator.free(git_dir);
    std.fs.cwd().makeDir(git_dir) catch return;

    // Create .gitignore
    const gitignore_path = std.fs.path.join(allocator, &.{ tmp_dir, ".gitignore" }) catch return;
    defer allocator.free(gitignore_path);
    {
        const file = std.fs.cwd().createFile(gitignore_path, .{}) catch return;
        defer file.close();
        file.writeAll("*.log\n") catch return;
    }

    // Test loading
    var matcher = GitignoreMatcher.init(allocator);
    defer matcher.deinit();

    loadAncestorGitignores(&matcher, tmp_dir, tmp_dir, allocator);

    // Should have loaded the pattern - paths must be under the root
    const debug_path = std.fs.path.join(allocator, &.{ tmp_dir, "debug.log" }) catch return;
    defer allocator.free(debug_path);
    const main_path = std.fs.path.join(allocator, &.{ tmp_dir, "main.zig" }) catch return;
    defer allocator.free(main_path);

    try std.testing.expect(matcher.isIgnoredFile(debug_path));
    try std.testing.expect(!matcher.isIgnoredFile(main_path));
}

test "loadAncestorGitignores: loads gitignores from multiple ancestors" {
    const allocator = std.testing.allocator;

    const tmp_dir_raw = "/tmp/gitignore_ancestor_test2";

    // Clean up any previous test run
    std.fs.cwd().deleteTree(tmp_dir_raw) catch {};

    // Create directory structure: tmp_dir/subdir/deep
    std.fs.cwd().makePath(tmp_dir_raw ++ "/subdir/deep") catch return;
    defer std.fs.cwd().deleteTree(tmp_dir_raw) catch {};

    // Get the real path (resolves symlinks like /tmp -> /private/tmp on macOS)
    const tmp_dir = std.fs.cwd().realpathAlloc(allocator, tmp_dir_raw) catch return;
    defer allocator.free(tmp_dir);

    const subdir = std.fs.path.join(allocator, &.{ tmp_dir, "subdir" }) catch return;
    defer allocator.free(subdir);
    const deep = std.fs.path.join(allocator, &.{ subdir, "deep" }) catch return;
    defer allocator.free(deep);

    // Create .git directory at root
    const git_dir = std.fs.path.join(allocator, &.{ tmp_dir, ".git" }) catch return;
    defer allocator.free(git_dir);
    std.fs.cwd().makeDir(git_dir) catch return;

    // Create .gitignore at root
    const root_gitignore = std.fs.path.join(allocator, &.{ tmp_dir, ".gitignore" }) catch return;
    defer allocator.free(root_gitignore);
    {
        const file = std.fs.cwd().createFile(root_gitignore, .{}) catch return;
        defer file.close();
        file.writeAll("*.root_ignored\n") catch return;
    }

    // Create .gitignore in subdir
    const subdir_gitignore = std.fs.path.join(allocator, &.{ subdir, ".gitignore" }) catch return;
    defer allocator.free(subdir_gitignore);
    {
        const file = std.fs.cwd().createFile(subdir_gitignore, .{}) catch return;
        defer file.close();
        file.writeAll("*.sub_ignored\n") catch return;
    }

    // Test loading from deep directory
    var matcher = GitignoreMatcher.init(allocator);
    defer matcher.deinit();

    loadAncestorGitignores(&matcher, tmp_dir, deep, allocator);

    // Should have loaded patterns from both root and subdir - paths must be under respective roots
    const root_file_path = std.fs.path.join(allocator, &.{ tmp_dir, "file.root_ignored" }) catch return;
    defer allocator.free(root_file_path);
    const subdir_file_path = std.fs.path.join(allocator, &.{ subdir, "file.sub_ignored" }) catch return;
    defer allocator.free(subdir_file_path);

    try std.testing.expect(matcher.isIgnoredFile(root_file_path));
    try std.testing.expect(matcher.isIgnoredFile(subdir_file_path));
}

test "loadAncestorGitignores: parent patterns loaded before child" {
    const allocator = std.testing.allocator;

    const tmp_dir_raw = "/tmp/gitignore_ancestor_test3";

    // Clean up any previous test run
    std.fs.cwd().deleteTree(tmp_dir_raw) catch {};

    // Create directory structure
    std.fs.cwd().makePath(tmp_dir_raw ++ "/subdir") catch return;
    defer std.fs.cwd().deleteTree(tmp_dir_raw) catch {};

    // Get the real path (resolves symlinks like /tmp -> /private/tmp on macOS)
    const tmp_dir = std.fs.cwd().realpathAlloc(allocator, tmp_dir_raw) catch return;
    defer allocator.free(tmp_dir);

    const subdir = std.fs.path.join(allocator, &.{ tmp_dir, "subdir" }) catch return;
    defer allocator.free(subdir);

    // Create .git directory at root
    const git_dir = std.fs.path.join(allocator, &.{ tmp_dir, ".git" }) catch return;
    defer allocator.free(git_dir);
    std.fs.cwd().makeDir(git_dir) catch return;

    // Create .gitignore at root that ignores *.log
    const root_gitignore = std.fs.path.join(allocator, &.{ tmp_dir, ".gitignore" }) catch return;
    defer allocator.free(root_gitignore);
    {
        const file = std.fs.cwd().createFile(root_gitignore, .{}) catch return;
        defer file.close();
        file.writeAll("*.log\n") catch return;
    }

    // Create .gitignore in subdir that negates important.log
    const subdir_gitignore = std.fs.path.join(allocator, &.{ subdir, ".gitignore" }) catch return;
    defer allocator.free(subdir_gitignore);
    {
        const file = std.fs.cwd().createFile(subdir_gitignore, .{}) catch return;
        defer file.close();
        file.writeAll("!important.log\n") catch return;
    }

    // Test loading
    var matcher = GitignoreMatcher.init(allocator);
    defer matcher.deinit();

    loadAncestorGitignores(&matcher, tmp_dir, subdir, allocator);

    // Parent pattern *.log should be loaded first, then child negation
    // Paths must be under the respective roots
    const debug_path = std.fs.path.join(allocator, &.{ tmp_dir, "debug.log" }) catch return;
    defer allocator.free(debug_path);
    const important_path = std.fs.path.join(allocator, &.{ subdir, "important.log" }) catch return;
    defer allocator.free(important_path);

    // debug.log in root should be ignored by root's *.log pattern
    try std.testing.expect(matcher.isIgnoredFile(debug_path));
    // important.log in subdir should NOT be ignored (negated by child)
    try std.testing.expect(!matcher.isIgnoredFile(important_path));
}

test "loadAncestorGitignores: handles missing gitignore gracefully" {
    const allocator = std.testing.allocator;

    const tmp_dir = "/tmp/gitignore_ancestor_test4";

    // Clean up any previous test run
    std.fs.cwd().deleteTree(tmp_dir) catch {};

    // Create directory structure without any .gitignore files
    const subdir = std.fs.path.join(allocator, &.{ tmp_dir, "subdir" }) catch return;
    defer allocator.free(subdir);

    std.fs.cwd().makePath(subdir) catch return;
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    // Create .git directory at root (but no .gitignore)
    const git_dir = std.fs.path.join(allocator, &.{ tmp_dir, ".git" }) catch return;
    defer allocator.free(git_dir);
    std.fs.cwd().makeDir(git_dir) catch return;

    // Test loading - should not crash
    var matcher = GitignoreMatcher.init(allocator);
    defer matcher.deinit();

    loadAncestorGitignores(&matcher, tmp_dir, subdir, allocator);

    // Should have no patterns
    try std.testing.expectEqual(@as(usize, 0), matcher.patternCount());
}

test "loadAncestorGitignores: search path equals git root" {
    const allocator = std.testing.allocator;

    const tmp_dir_raw = "/tmp/gitignore_ancestor_test5";

    // Clean up any previous test run
    std.fs.cwd().deleteTree(tmp_dir_raw) catch {};

    std.fs.cwd().makePath(tmp_dir_raw) catch return;
    defer std.fs.cwd().deleteTree(tmp_dir_raw) catch {};

    // Get the real path (resolves symlinks like /tmp -> /private/tmp on macOS)
    const tmp_dir = std.fs.cwd().realpathAlloc(allocator, tmp_dir_raw) catch return;
    defer allocator.free(tmp_dir);

    // Create .git directory
    const git_dir = std.fs.path.join(allocator, &.{ tmp_dir, ".git" }) catch return;
    defer allocator.free(git_dir);
    std.fs.cwd().makeDir(git_dir) catch return;

    // Create .gitignore
    const gitignore_path = std.fs.path.join(allocator, &.{ tmp_dir, ".gitignore" }) catch return;
    defer allocator.free(gitignore_path);
    {
        const file = std.fs.cwd().createFile(gitignore_path, .{}) catch return;
        defer file.close();
        file.writeAll("*.tmp\n") catch return;
    }

    // Test loading when search path equals git root
    var matcher = GitignoreMatcher.init(allocator);
    defer matcher.deinit();

    loadAncestorGitignores(&matcher, tmp_dir, tmp_dir, allocator);

    // Should have loaded the pattern - paths must be under the root
    const tmp_file_path = std.fs.path.join(allocator, &.{ tmp_dir, "file.tmp" }) catch return;
    defer allocator.free(tmp_file_path);

    try std.testing.expect(matcher.isIgnoredFile(tmp_file_path));
}

test "loadAncestorGitignores: search path not under git root" {
    const allocator = std.testing.allocator;

    const git_root = "/tmp/gitignore_ancestor_test6_root";
    const search_path = "/tmp/gitignore_ancestor_test6_other";

    // Clean up any previous test run
    std.fs.cwd().deleteTree(git_root) catch {};
    std.fs.cwd().deleteTree(search_path) catch {};

    std.fs.cwd().makePath(git_root) catch return;
    std.fs.cwd().makePath(search_path) catch return;
    defer std.fs.cwd().deleteTree(git_root) catch {};
    defer std.fs.cwd().deleteTree(search_path) catch {};

    // Create .git directory in git_root
    const git_dir = std.fs.path.join(allocator, &.{ git_root, ".git" }) catch return;
    defer allocator.free(git_dir);
    std.fs.cwd().makeDir(git_dir) catch return;

    // Create .gitignore in git_root
    const gitignore_path = std.fs.path.join(allocator, &.{ git_root, ".gitignore" }) catch return;
    defer allocator.free(gitignore_path);
    {
        const file = std.fs.cwd().createFile(gitignore_path, .{}) catch return;
        defer file.close();
        file.writeAll("*.secret\n") catch return;
    }

    // Test loading with search path not under git root - should be a no-op
    var matcher = GitignoreMatcher.init(allocator);
    defer matcher.deinit();

    loadAncestorGitignores(&matcher, git_root, search_path, allocator);

    // Should not have loaded any patterns (search path not under git root)
    try std.testing.expectEqual(@as(usize, 0), matcher.patternCount());
}
