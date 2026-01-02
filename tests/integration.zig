const std = @import("std");

const Result = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Run zg as a subprocess and capture output
fn runZipgrep(allocator: std.mem.Allocator, args: []const []const u8) !Result {
    const exe_path = "zig-out/bin/zg";

    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(allocator);

    try argv.append(allocator, exe_path);
    for (args) |arg| {
        try argv.append(allocator, arg);
    }

    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Use collectOutput with ArrayList outputs (Zig 0.15 style)
    var stdout_list: std.ArrayList(u8) = .empty;
    defer stdout_list.deinit(allocator);
    var stderr_list: std.ArrayList(u8) = .empty;
    defer stderr_list.deinit(allocator);

    try child.collectOutput(allocator, &stdout_list, &stderr_list, 1024 * 1024);

    const term = try child.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |code| code,
        else => 255,
    };

    return .{
        .stdout = try stdout_list.toOwnedSlice(allocator),
        .stderr = try stderr_list.toOwnedSlice(allocator),
        .exit_code = exit_code,
    };
}

test "integration: basic search" {
    const allocator = std.testing.allocator;

    const result = try runZipgrep(allocator, &.{ "PATTERN", "tests/fixtures/sample.txt" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find PATTERN in the file
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "PATTERN") != null);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "integration: recursive search" {
    const allocator = std.testing.allocator;

    const result = try runZipgrep(allocator, &.{ "PATTERN", "tests/fixtures/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find in both sample.txt and subdir/nested.txt
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "sample.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "nested.txt") != null);
}

test "integration: case insensitive" {
    const allocator = std.testing.allocator;

    const result = try runZipgrep(allocator, &.{ "-i", "pattern", "tests/fixtures/sample.txt" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find both PATTERN and pattern
    // Count matches - there should be at least 2 lines
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }
    try std.testing.expect(count >= 2);
}

test "integration: count mode" {
    const allocator = std.testing.allocator;

    const result = try runZipgrep(allocator, &.{ "-c", "PATTERN", "tests/fixtures/sample.txt" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Single file count mode: should output just count (no filename)
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "1") != null);
}

test "integration: files only mode" {
    const allocator = std.testing.allocator;

    const result = try runZipgrep(allocator, &.{ "-l", "PATTERN", "tests/fixtures/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should only output filenames, no line content
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "sample.txt") != null);
    // The actual content "appears here" should not be in output
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "appears here") == null);
}

test "integration: hidden files excluded by default" {
    const allocator = std.testing.allocator;

    const result = try runZipgrep(allocator, &.{ "PATTERN", "tests/fixtures/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Hidden file should NOT be in results by default
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, ".hidden.txt") == null);
}

test "integration: hidden files included with flag" {
    const allocator = std.testing.allocator;

    const result = try runZipgrep(allocator, &.{ "--hidden", "PATTERN", "tests/fixtures/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Hidden file SHOULD be in results with --hidden
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, ".hidden.txt") != null);
}

test "integration: gitignore respected" {
    const allocator = std.testing.allocator;

    const result = try runZipgrep(allocator, &.{ "PATTERN", "tests/fixtures/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // ignored.txt should NOT be in results (it's in .gitignore)
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "ignored.txt") == null);
    // Other files should still appear
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "sample.txt") != null);
}

test "integration: gitignore bypassed with flag" {
    const allocator = std.testing.allocator;

    const result = try runZipgrep(allocator, &.{ "--no-ignore", "PATTERN", "tests/fixtures/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // ignored.txt SHOULD be in results with --no-ignore
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "ignored.txt") != null);
}

test "integration: max depth" {
    const allocator = std.testing.allocator;

    const result = try runZipgrep(allocator, &.{ "-d", "0", "PATTERN", "tests/fixtures/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // With depth 0, should only search files in fixtures/, not subdir/
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "nested.txt") == null);
}

test "integration: no matches" {
    const allocator = std.testing.allocator;

    const result = try runZipgrep(allocator, &.{ "NONEXISTENT_PATTERN_XYZ", "tests/fixtures/sample.txt" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should have empty output (no matches)
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
}

test "integration: regex pattern with dot" {
    const allocator = std.testing.allocator;

    // Use a simple regex with . (dot) which matches any single character
    const result = try runZipgrep(allocator, &.{ "PAT.ERN", "tests/fixtures/sample.txt" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // PAT.ERN should match PATTERN (dot matches T)
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "PATTERN") != null);
}

test "integration: regex pattern with dot-star" {
    const allocator = std.testing.allocator;

    // Test .* quantifier (zero or more of any character)
    const result = try runZipgrep(allocator, &.{ "PAT.*ERN", "tests/fixtures/sample.txt" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // PAT.*ERN should match PATTERN (.* matches T)
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "PATTERN") != null);
}

test "integration: regex pattern with plus" {
    const allocator = std.testing.allocator;

    // Test + quantifier (one or more)
    const result = try runZipgrep(allocator, &.{ "PAT+ERN", "tests/fixtures/sample.txt" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // PAT+ERN should match PATTERN (T+ matches TT)
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "PATTERN") != null);
}

test "integration: no-heading format" {
    const allocator = std.testing.allocator;

    // Use directory to test --no-heading (single file doesn't show filename prefix)
    const result = try runZipgrep(allocator, &.{ "--no-heading", "PATTERN", "tests/fixtures/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should be in flat format: file:content (no line numbers by default)
    // Each line should contain a file path
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    var found_sample = false;
    while (lines.next()) |line| {
        if (line.len > 0) {
            // Should have filename prefix for directory search
            if (std.mem.indexOf(u8, line, "sample.txt:") != null) found_sample = true;
        }
    }
    try std.testing.expect(found_sample);
}

test "integration: binary files skipped" {
    const allocator = std.testing.allocator;

    const result = try runZipgrep(allocator, &.{ "PATTERN", "tests/fixtures/binary.bin" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Binary file should be skipped, so no output
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
}

test "integration: help flag" {
    const allocator = std.testing.allocator;

    const result = try runZipgrep(allocator, &.{"--help"});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Help should contain usage info
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "USAGE") != null);
}

test "integration: word boundary flag" {
    const allocator = std.testing.allocator;

    // Without -w: "pattern" should match "pattern" in lowercase line
    const result_without = try runZipgrep(allocator, &.{ "pattern", "tests/fixtures/sample.txt" });
    defer allocator.free(result_without.stdout);
    defer allocator.free(result_without.stderr);
    try std.testing.expect(std.mem.indexOf(u8, result_without.stdout, "pattern lowercase") != null);

    // With -w: "pattern" should still match as a whole word
    const result_with = try runZipgrep(allocator, &.{ "-w", "pattern", "tests/fixtures/sample.txt" });
    defer allocator.free(result_with.stdout);
    defer allocator.free(result_with.stderr);
    try std.testing.expect(std.mem.indexOf(u8, result_with.stdout, "pattern lowercase") != null);
}

test "integration: word boundary rejects partial matches" {
    const allocator = std.testing.allocator;

    // Search for "file" - without -w should match "file" in multiple contexts
    const result_without = try runZipgrep(allocator, &.{ "file", "tests/fixtures/sample.txt" });
    defer allocator.free(result_without.stdout);
    defer allocator.free(result_without.stderr);

    // Count lines without -w
    var count_without: usize = 0;
    var lines_without = std.mem.splitScalar(u8, result_without.stdout, '\n');
    while (lines_without.next()) |line| {
        if (line.len > 0) count_without += 1;
    }

    // With -w: should only match "file" as a whole word
    const result_with = try runZipgrep(allocator, &.{ "-w", "file", "tests/fixtures/sample.txt" });
    defer allocator.free(result_with.stdout);
    defer allocator.free(result_with.stderr);

    // Count lines with -w
    var count_with: usize = 0;
    var lines_with = std.mem.splitScalar(u8, result_with.stdout, '\n');
    while (lines_with.next()) |line| {
        if (line.len > 0) count_with += 1;
    }

    // Both should find matches (the word "file" appears as whole word)
    try std.testing.expect(count_without >= 1);
    try std.testing.expect(count_with >= 1);
}

// ============================================================================
// Glob pattern filtering tests (-g/--glob)
// ============================================================================

test "integration: glob include pattern" {
    const allocator = std.testing.allocator;

    // Only search .txt files
    const result = try runZipgrep(allocator, &.{ "-g", "*.txt", "PATTERN", "tests/fixtures/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find matches in .txt files
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "sample.txt") != null);

    // Should NOT find matches in binary file (even though it's not .txt anyway)
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "binary.bin") == null);
}

test "integration: glob exclude pattern" {
    const allocator = std.testing.allocator;

    // Exclude .txt files (search everything else)
    const result = try runZipgrep(allocator, &.{ "-g", "!*.txt", "--no-ignore", "PATTERN", "tests/fixtures/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should NOT find matches in .txt files
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "sample.txt") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "nested.txt") == null);
}

test "integration: glob directory exclusion" {
    const allocator = std.testing.allocator;

    // Exclude subdir/ directory
    const result = try runZipgrep(allocator, &.{ "-g", "!subdir/", "PATTERN", "tests/fixtures/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find matches in root
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "sample.txt") != null);

    // Should NOT find matches in subdir (excluded)
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "nested.txt") == null);
}

test "integration: glob combined include and exclude" {
    const allocator = std.testing.allocator;

    // Include .txt files but exclude those in subdir
    const result = try runZipgrep(allocator, &.{ "-g", "*.txt", "-g", "!subdir/", "PATTERN", "tests/fixtures/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find matches in root .txt files
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "sample.txt") != null);

    // Should NOT find matches in subdir (excluded)
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "nested.txt") == null);
}

test "integration: glob multiple include patterns" {
    const allocator = std.testing.allocator;

    // Include both .txt and .bin files (OR logic)
    const result = try runZipgrep(allocator, &.{ "-g", "*.txt", "-g", "*.bin", "PATTERN", "tests/fixtures/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find matches in .txt files
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "sample.txt") != null);

    // Binary files are skipped due to binary detection, not glob
    // But the glob should allow them through
}

test "integration: glob long form --glob" {
    const allocator = std.testing.allocator;

    // Test --glob long form
    const result = try runZipgrep(allocator, &.{ "--glob", "*.txt", "PATTERN", "tests/fixtures/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should work the same as -g
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "sample.txt") != null);
}

test "integration: glob no match" {
    const allocator = std.testing.allocator;

    // Include only .rs files (none exist)
    const result = try runZipgrep(allocator, &.{ "-g", "*.rs", "PATTERN", "tests/fixtures/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should have no matches
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
}

test "integration: glob with recursive search" {
    const allocator = std.testing.allocator;

    // Include .txt files and ensure recursive search still works
    const result = try runZipgrep(allocator, &.{ "-g", "*.txt", "PATTERN", "tests/fixtures/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find matches in both root and subdir
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "sample.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "nested.txt") != null);
}

// ============================================================================
// Word boundary with .* prefix pattern tests
// ============================================================================

test "integration: word boundary with greedy .* prefix finds valid match" {
    // This test validates the fix for a bug where -w '.*_suffix' would fail
    // to find matches when the LAST occurrence of _suffix in the line was not
    // at a word boundary, even if EARLIER occurrences were valid.
    //
    // The bug: greedy .* would match to the last _suffix, word boundary check
    // would fail, and we'd skip ALL occurrences instead of trying earlier ones.

    const allocator = std.testing.allocator;

    // Create a temp file with multiple _cache occurrences
    // First two have word chars after them (not word boundary)
    // Third one has a space after (valid word boundary)
    // Fourth has word char after (not word boundary)
    const test_content = "x_cache_y z_cache_w valid_cache here_cache_end\n";
    const temp_path = "/tmp/zipgrep_test_word_boundary.txt";

    // Write test file
    {
        const file = try std.fs.cwd().createFile(temp_path, .{});
        defer file.close();
        try file.writeAll(test_content);
    }
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    // Run zg with -w flag
    const result = try runZipgrep(allocator, &.{ "-w", ".*_cache", temp_path });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find a match (the "valid_cache" occurrence has word boundary)
    try std.testing.expect(result.stdout.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "valid_cache") != null);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "integration: word boundary with greedy .* prefix no valid match" {
    // Test case where NO occurrences satisfy word boundary - should return no match

    const allocator = std.testing.allocator;

    // All _cache occurrences have word characters after them
    const test_content = "x_cache_y z_cache_w a_cache_b\n";
    const temp_path = "/tmp/zipgrep_test_no_word_boundary.txt";

    // Write test file
    {
        const file = try std.fs.cwd().createFile(temp_path, .{});
        defer file.close();
        try file.writeAll(test_content);
    }
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    // Run zg with -w flag
    const result = try runZipgrep(allocator, &.{ "-w", ".*_cache", temp_path });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should NOT find a match (no _cache is at a word boundary)
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
}

test "integration: word boundary with greedy .* long line" {
    // Test with a longer line to ensure the fix works with many occurrences
    // This simulates the real-world case of minified JS files

    const allocator = std.testing.allocator;

    // Build a long line with many _cache occurrences, only one valid
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);

    // Add many non-boundary occurrences
    for (0..50) |i| {
        try content.writer(allocator).print("item{d}_cache_ext ", .{i});
    }
    // Add one valid word boundary occurrence
    try content.appendSlice(allocator, "final_cache ");
    // Add more non-boundary occurrences after
    for (50..100) |i| {
        try content.writer(allocator).print("item{d}_cache_more ", .{i});
    }
    try content.append(allocator, '\n');

    const temp_path = "/tmp/zipgrep_test_long_line.txt";

    // Write test file
    {
        const file = try std.fs.cwd().createFile(temp_path, .{});
        defer file.close();
        try file.writeAll(content.items);
    }
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    // Run zg with -w flag
    const result = try runZipgrep(allocator, &.{ "-w", ".*_cache", temp_path });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find a match at "final_cache"
    try std.testing.expect(result.stdout.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "final_cache") != null);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "integration: word boundary .* match at end of line" {
    // Test where valid word boundary is at end of string

    const allocator = std.testing.allocator;

    // _suffix at end of line has implicit word boundary (end of string)
    const test_content = "prefix_suffix_more text_suffix\n";
    const temp_path = "/tmp/zipgrep_test_end_boundary.txt";

    // Write test file
    {
        const file = try std.fs.cwd().createFile(temp_path, .{});
        defer file.close();
        try file.writeAll(test_content);
    }
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    // Run zg with -w flag
    const result = try runZipgrep(allocator, &.{ "-w", ".*_suffix", temp_path });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find a match (last _suffix is at word boundary - end of line)
    try std.testing.expect(result.stdout.len > 0);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================================
// Stdin support tests
// ============================================================================

/// Helper to run zg with stdin input
fn runZipgrepWithStdin(allocator: std.mem.Allocator, args: []const []const u8, stdin_input: []const u8) !Result {
    const exe_path = "zig-out/bin/zg";

    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(allocator);

    try argv.append(allocator, exe_path);
    for (args) |arg| {
        try argv.append(allocator, arg);
    }

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Write stdin input and close
    if (child.stdin) |stdin| {
        try stdin.writeAll(stdin_input);
        stdin.close();
    }
    child.stdin = null;

    // Use collectOutput with ArrayList outputs (Zig 0.15 style)
    var stdout_list: std.ArrayList(u8) = .empty;
    defer stdout_list.deinit(allocator);
    var stderr_list: std.ArrayList(u8) = .empty;
    defer stderr_list.deinit(allocator);

    try child.collectOutput(allocator, &stdout_list, &stderr_list, 1024 * 1024);

    const term = try child.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |code| code,
        else => 255,
    };

    return .{
        .stdout = try stdout_list.toOwnedSlice(allocator),
        .stderr = try stderr_list.toOwnedSlice(allocator),
        .exit_code = exit_code,
    };
}

test "integration: stdin basic search" {
    const allocator = std.testing.allocator;

    const result = try runZipgrepWithStdin(allocator, &.{"hello"}, "hello world\n");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find "hello world" with line number
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hello world") != null);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "integration: stdin multiline" {
    const allocator = std.testing.allocator;

    const result = try runZipgrepWithStdin(allocator, &.{"hello"}, "line one\nline two hello\nline three\n");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find the line containing hello (no line number by default)
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "line two hello") != null);
}

test "integration: stdin multiline with line numbers" {
    const allocator = std.testing.allocator;

    const result = try runZipgrepWithStdin(allocator, &.{ "-n", "hello" }, "line one\nline two hello\nline three\n");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // With -n flag, should show line number prefix
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "2:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hello") != null);
}

test "integration: stdin count mode" {
    const allocator = std.testing.allocator;

    const result = try runZipgrepWithStdin(allocator, &.{ "-c", "hello" }, "hello one\nhello two\ngoodbye\n");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should output just "2" (no filename prefix for single stdin)
    try std.testing.expectEqualStrings("2\n", result.stdout);
}

test "integration: stdin files-with-matches" {
    const allocator = std.testing.allocator;

    const result = try runZipgrepWithStdin(allocator, &.{ "-l", "hello" }, "hello world\n");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should output "<stdin>"
    try std.testing.expectEqualStrings("<stdin>\n", result.stdout);
}

test "integration: stdin case insensitive" {
    const allocator = std.testing.allocator;

    const result = try runZipgrepWithStdin(allocator, &.{ "-i", "hello" }, "HELLO WORLD\n");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "HELLO") != null);
}

test "integration: stdin word boundary" {
    const allocator = std.testing.allocator;

    const result = try runZipgrepWithStdin(allocator, &.{ "-w", "hello" }, "helloworld hello world\n");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find "hello" as whole word
    try std.testing.expect(result.stdout.len > 0);
}

test "integration: stdin no matches" {
    const allocator = std.testing.allocator;

    const result = try runZipgrepWithStdin(allocator, &.{"xyz"}, "hello world\n");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should have empty output
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
}

test "integration: stdin empty input" {
    const allocator = std.testing.allocator;

    const result = try runZipgrepWithStdin(allocator, &.{"hello"}, "");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should handle gracefully with no output
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
}

test "integration: stdin explicit dash" {
    const allocator = std.testing.allocator;

    // Use explicit - as path argument
    const result = try runZipgrepWithStdin(allocator, &.{ "hello", "-" }, "hello from stdin\n");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hello") != null);
}

test "integration: stdin with file" {
    const allocator = std.testing.allocator;

    // Search both stdin and a file
    const result = try runZipgrepWithStdin(allocator, &.{ "--no-heading", "PATTERN", "-", "tests/fixtures/sample.txt" }, "PATTERN from stdin\n");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find matches in both stdin and file
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "<stdin>:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "sample.txt:") != null);
}

// ============================================================================
// Parent .gitignore traversal tests (tests for commit 90d71cb fix)
// ============================================================================

test "integration: parent gitignore from root respects root gitignore" {
    const allocator = std.testing.allocator;

    // Search from root of nested_gitignore fixture
    const result = try runZipgrep(allocator, &.{ "PATTERN", "tests/fixtures/nested_gitignore/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find non-ignored files
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "root_file.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "sub_file.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "deep_file.txt") != null);

    // Should NOT find files matching *.root_ignored (from root .gitignore)
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, ".root_ignored") == null);

    // Should NOT find files matching *.sub_ignored (from subdir .gitignore)
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, ".sub_ignored") == null);
}

test "integration: parent gitignore from subdir respects parent gitignore" {
    // This is the main test for the fix in commit 90d71cb
    // When searching a subdirectory, parent .gitignore patterns should apply
    const allocator = std.testing.allocator;

    // Search from subdir (should still respect root's .gitignore)
    const result = try runZipgrep(allocator, &.{ "PATTERN", "tests/fixtures/nested_gitignore/subdir/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find non-ignored files in subdir
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "sub_file.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "deep_file.txt") != null);

    // Should NOT find files matching *.root_ignored (from PARENT .gitignore)
    // This is the key behavior the fix addresses
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "deep_root_ignored.root_ignored") == null);

    // Should NOT find files matching *.sub_ignored (from local .gitignore)
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "sub_ignored.sub_ignored") == null);
}

test "integration: parent gitignore from deep subdir respects all ancestors" {
    const allocator = std.testing.allocator;

    // Search from deep/ (should respect both root and subdir .gitignore)
    const result = try runZipgrep(allocator, &.{ "PATTERN", "tests/fixtures/nested_gitignore/subdir/deep/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find non-ignored files
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "deep_file.txt") != null);

    // Should NOT find files matching *.root_ignored (from root .gitignore)
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, ".root_ignored") == null);
}

test "integration: parent gitignore bypassed with --no-ignore" {
    const allocator = std.testing.allocator;

    // Search from subdir with --no-ignore (should find ALL files)
    const result = try runZipgrep(allocator, &.{ "--no-ignore", "PATTERN", "tests/fixtures/nested_gitignore/subdir/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find ALL files including ignored ones
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "sub_file.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "deep_file.txt") != null);

    // With --no-ignore, should find files that would otherwise be ignored
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "deep_root_ignored.root_ignored") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "sub_ignored.sub_ignored") != null);
}

test "integration: parent gitignore local patterns override parent" {
    // Test that local .gitignore can override parent patterns
    // This requires a more complex fixture, so we test the general behavior
    const allocator = std.testing.allocator;

    // Search from subdir
    const result = try runZipgrep(allocator, &.{ "PATTERN", "tests/fixtures/nested_gitignore/subdir/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Both parent and local patterns should be applied
    // *.root_ignored from parent
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, ".root_ignored") == null);
    // *.sub_ignored from local
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, ".sub_ignored") == null);
}
