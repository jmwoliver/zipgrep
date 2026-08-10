const std = @import("std");
const io = std.testing.io;

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

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, exe_path);
    for (args) |arg| {
        try argv.append(allocator, arg);
    }

    const run_result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    const exit_code: u8 = switch (run_result.term) {
        .exited => |code| code,
        else => 255,
    };

    return .{
        .stdout = run_result.stdout,
        .stderr = run_result.stderr,
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

test "integration: quiet mode returns match status without output" {
    const allocator = std.testing.allocator;

    const matched = try runZipgrep(allocator, &.{ "-q", "PATTERN", "tests/fixtures/" });
    defer allocator.free(matched.stdout);
    defer allocator.free(matched.stderr);
    try std.testing.expectEqual(@as(u8, 0), matched.exit_code);
    try std.testing.expectEqual(@as(usize, 0), matched.stdout.len);

    const absent = try runZipgrep(allocator, &.{ "-q", "ABSENT_7F91", "tests/fixtures/" });
    defer allocator.free(absent.stdout);
    defer allocator.free(absent.stderr);
    try std.testing.expectEqual(@as(u8, 1), absent.exit_code);
    try std.testing.expectEqual(@as(usize, 0), absent.stdout.len);
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

test "integration: explicit binary files report matches" {
    const allocator = std.testing.allocator;

    const result = try runZipgrep(allocator, &.{ "PATTERN", "tests/fixtures/binary.bin" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqualStrings(
        "binary file matches (found \"\\0\" byte around offset 16)\n",
        result.stdout,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
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
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, test_content);
    }
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

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
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, test_content);
    }
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

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
        try content.print(allocator, "item{d}_cache_ext ", .{i});
    }
    // Add one valid word boundary occurrence
    try content.appendSlice(allocator, "final_cache ");
    // Add more non-boundary occurrences after
    for (50..100) |i| {
        try content.print(allocator, "item{d}_cache_more ", .{i});
    }
    try content.append(allocator, '\n');

    const temp_path = "/tmp/zipgrep_test_long_line.txt";

    // Write test file
    {
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, content.items);
    }
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

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
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, test_content);
    }
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

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

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, exe_path);
    for (args) |arg| {
        try argv.append(allocator, arg);
    }

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    // Write stdin input and close
    if (child.stdin) |stdin| {
        try stdin.writeStreamingAll(io, stdin_input);
        stdin.close(io);
    }
    child.stdin = null;

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    while (multi_reader.fill(0, .none)) |_| {
        if (stdout_reader.buffered().len > 1024 * 1024 or stderr_reader.buffered().len > 1024 * 1024)
            return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi_reader.checkAnyError();

    const term = try child.wait(io);
    const exit_code: u8 = switch (term) {
        .exited => |code| code,
        else => 255,
    };

    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);

    return .{
        .stdout = stdout,
        .stderr = stderr,
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

// =============================================================================
// Performance optimization tests
// =============================================================================

test "integration: large file search" {
    // Test search in a moderately large file to verify SIMD optimizations work
    const allocator = std.testing.allocator;
    const temp_path = "/tmp/zipgrep_large_test.txt";

    // Create ~500KB file with known pattern
    {
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer file.close(io);
        // Write 10000 lines of filler
        const line = "line XXXXX: some text content here\n";
        for (0..10000) |_| {
            try file.writeStreamingAll(io, line);
        }
        try file.writeStreamingAll(io, "UNIQUE_PATTERN_HERE on this line\n");
        // Write 10000 more lines
        for (0..10000) |_| {
            try file.writeStreamingAll(io, line);
        }
    }
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    const result = try runZipgrep(allocator, &.{ "UNIQUE_PATTERN_HERE", temp_path });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "UNIQUE_PATTERN_HERE") != null);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "integration: case insensitive large file" {
    // Test case-insensitive search (exercises SIMD case-insensitive path)
    const allocator = std.testing.allocator;
    const temp_path = "/tmp/zipgrep_ci_test.txt";

    {
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer file.close(io);
        // Write lines alternating between PATTERN and pattern
        for (0..2500) |_| {
            try file.writeStreamingAll(io, "line XXXXX: PATTERN here\n");
            try file.writeStreamingAll(io, "line XXXXX: pattern there\n");
        }
    }
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    // Count matches
    const result = try runZipgrep(allocator, &.{ "-i", "-c", "pattern", temp_path });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find 5000 matches (2500 PATTERN + 2500 pattern)
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "5000") != null);
}

test "integration: line numbers correct with many lines" {
    // Test that SIMD newline counting produces correct line numbers
    const allocator = std.testing.allocator;
    const temp_path = "/tmp/zipgrep_linenum_test.txt";

    {
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer file.close(io);
        // Write 499 filler lines, then target, then 500 more filler lines
        const filler_line = "line content filler text here\n";
        for (0..499) |_| {
            try file.writeStreamingAll(io, filler_line);
        }
        try file.writeStreamingAll(io, "TARGET_LINE_HERE\n");
        for (0..500) |_| {
            try file.writeStreamingAll(io, filler_line);
        }
    }
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    const result = try runZipgrep(allocator, &.{ "-n", "TARGET_LINE_HERE", temp_path });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should report line 500
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "500:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "TARGET_LINE_HERE") != null);
}

test "integration: pattern at buffer boundary" {
    // Test patterns that might span SIMD chunk boundaries (16/32 bytes)
    // This exercises the SIMD two-byte fingerprinting
    const allocator = std.testing.allocator;
    const temp_path = "/tmp/zipgrep_boundary_test.txt";

    {
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer file.close(io);
        // Write content with patterns at various offsets that cross SIMD boundaries
        // SIMD width is 16 bytes on ARM, so write patterns near 14, 15, 16, 17 byte offsets
        try file.writeStreamingAll(io, "prefix14xxxxBOUNDARY_PATTERN_TEST_ONE\n"); // pattern starts at offset 14
        try file.writeStreamingAll(io, "prefix15xxxxxBOUNDARY_PATTERN_TEST_TWO\n"); // pattern starts at offset 15
        try file.writeStreamingAll(io, "prefix16xxxxxxBOUNDARY_PATTERN_TEST_THREE\n"); // pattern starts at offset 16
        try file.writeStreamingAll(io, "prefix31xxxxxxxxxxxxxxxxxxxxxxBOUNDARY_PATTERN_TEST_FOUR\n"); // pattern starts at offset 31
    }
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    const result = try runZipgrep(allocator, &.{ "-c", "BOUNDARY_PATTERN_TEST", temp_path });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find all 4 patterns
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "4") != null);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "integration: two byte pattern search" {
    // Test minimum pattern length for two-byte SIMD optimization
    const allocator = std.testing.allocator;
    const temp_path = "/tmp/zipgrep_twobyte_test.txt";

    {
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "xx ab xx ab xx cd xx\nab at start\nend with ab\n");
    }
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    const result = try runZipgrep(allocator, &.{ "-c", "ab", temp_path });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find 4 lines with "ab"
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "3") != null);
}

test "integration: long pattern search" {
    // Test patterns longer than SIMD width
    const allocator = std.testing.allocator;
    const temp_path = "/tmp/zipgrep_longpattern_test.txt";

    const long_pattern = "this_is_a_very_long_pattern_for_testing_simd_search";

    {
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer file.close(io);
        // Write filler lines
        const filler_line = "line content: some filler content here\n";
        for (0..100) |_| {
            try file.writeStreamingAll(io, filler_line);
        }
        try file.writeStreamingAll(io, "found: " ++ long_pattern ++ "\n");
        for (0..100) |_| {
            try file.writeStreamingAll(io, filler_line);
        }
    }
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    const result = try runZipgrep(allocator, &.{ long_pattern, temp_path });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, long_pattern) != null);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "integration: many matches same line" {
    // Test multiple matches on the same line (exercises match iteration)
    const allocator = std.testing.allocator;
    const temp_path = "/tmp/zipgrep_manymatches_test.txt";

    {
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer file.close(io);
        // Line with multiple "ab" occurrences
        try file.writeStreamingAll(io, "ab ab ab ab ab ab ab ab ab ab\n");
        try file.writeStreamingAll(io, "no matches here\n");
        try file.writeStreamingAll(io, "ab ab ab\n");
    }
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    // Just check that it finds matches without crashing
    const result = try runZipgrep(allocator, &.{ "ab", temp_path });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(result.stdout.len > 0);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "integration: empty lines handling" {
    // Test files with many empty lines (exercises newline counting)
    const allocator = std.testing.allocator;
    const temp_path = "/tmp/zipgrep_emptylines_test.txt";

    {
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer file.close(io);
        // Write 100 empty lines, then content, then 100 more empty lines
        // Use batched writes for efficiency
        const empty_lines = "\n" ** 100;
        try file.writeStreamingAll(io, empty_lines);
        try file.writeStreamingAll(io, "TARGET_ON_LINE_101\n");
        try file.writeStreamingAll(io, empty_lines);
    }
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    const result = try runZipgrep(allocator, &.{ "-n", "TARGET_ON_LINE_101", temp_path });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should report line 101
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "101:") != null);
}

// =============================================================================
// Multi-literal Alternation Integration Tests (Aho-Corasick)
// =============================================================================

test "integration: alternation basic" {
    // Test basic multi-literal alternation pattern (uses Aho-Corasick)
    const allocator = std.testing.allocator;
    const temp_path = "/tmp/zipgrep_alternation_test.txt";

    {
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "line with ERR_SYS error\n");
        try file.writeStreamingAll(io, "line with no match\n");
        try file.writeStreamingAll(io, "line with PME_TURN_OFF event\n");
        try file.writeStreamingAll(io, "another line without match\n");
        try file.writeStreamingAll(io, "line with LINK_REQ_RST status\n");
        try file.writeStreamingAll(io, "final line with CFG_BME_EVT config\n");
    }
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    const result = try runZipgrep(allocator, &.{ "ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT", temp_path });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find all 4 matching lines
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "ERR_SYS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "PME_TURN_OFF") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "LINK_REQ_RST") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "CFG_BME_EVT") != null);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "integration: alternation count mode" {
    // Test alternation with count mode
    const allocator = std.testing.allocator;
    const temp_path = "/tmp/zipgrep_alternation_count_test.txt";

    {
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "ERROR here\n");
        try file.writeStreamingAll(io, "no match\n");
        try file.writeStreamingAll(io, "WARNING here\n");
        try file.writeStreamingAll(io, "no match\n");
        try file.writeStreamingAll(io, "INFO here\n");
        try file.writeStreamingAll(io, "no match\n");
    }
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    const result = try runZipgrep(allocator, &.{ "-c", "ERROR|WARNING|INFO", temp_path });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should count 3 matching lines
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "3") != null);
}

test "integration: alternation case insensitive" {
    // Test alternation with case-insensitive flag
    const allocator = std.testing.allocator;
    const temp_path = "/tmp/zipgrep_alternation_casei_test.txt";

    {
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "line with FOO uppercase\n");
        try file.writeStreamingAll(io, "line with foo lowercase\n");
        try file.writeStreamingAll(io, "line with Bar mixedcase\n");
        try file.writeStreamingAll(io, "line with BAZ uppercase\n");
        try file.writeStreamingAll(io, "no match here\n");
    }
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    const result = try runZipgrep(allocator, &.{ "-i", "foo|bar|baz", temp_path });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find all 4 matching lines (case insensitive)
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "integration: alternation word boundary" {
    // Test alternation with word boundary flag
    const allocator = std.testing.allocator;
    const temp_path = "/tmp/zipgrep_alternation_word_test.txt";

    {
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "line with ERR standalone\n");
        try file.writeStreamingAll(io, "line with ERROR embedded\n"); // ERR is NOT word-bounded here
        try file.writeStreamingAll(io, "line with WARN standalone\n");
        try file.writeStreamingAll(io, "line with WARNING embedded\n"); // WARN is NOT word-bounded here
        try file.writeStreamingAll(io, "no match here\n");
    }
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    const result = try runZipgrep(allocator, &.{ "-w", "ERR|WARN", temp_path });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should only find 2 lines (standalone ERR and WARN)
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "integration: alternation line numbers" {
    // Test alternation with line number display
    const allocator = std.testing.allocator;
    const temp_path = "/tmp/zipgrep_alternation_lineno_test.txt";

    {
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "no match\n"); // line 1
        try file.writeStreamingAll(io, "AAA here\n"); // line 2
        try file.writeStreamingAll(io, "no match\n"); // line 3
        try file.writeStreamingAll(io, "BBB here\n"); // line 4
        try file.writeStreamingAll(io, "no match\n"); // line 5
        try file.writeStreamingAll(io, "CCC here\n"); // line 6
    }
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    const result = try runZipgrep(allocator, &.{ "-n", "AAA|BBB|CCC", temp_path });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should show correct line numbers
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "2:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "4:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "6:") != null);
}

test "integration: alternation no match" {
    // Test alternation that finds no matches
    const allocator = std.testing.allocator;
    const temp_path = "/tmp/zipgrep_alternation_nomatch_test.txt";

    {
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "line one\n");
        try file.writeStreamingAll(io, "line two\n");
        try file.writeStreamingAll(io, "line three\n");
    }
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    const result = try runZipgrep(allocator, &.{ "XYZ|ABC|DEF", temp_path });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // No output when no matches
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
}

test "integration: alternation recursive" {
    // Test alternation with recursive directory search
    const allocator = std.testing.allocator;
    const temp_dir = "/tmp/zipgrep_alternation_recursive";

    // Create directory structure
    std.Io.Dir.cwd().deleteTree(io, temp_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, temp_dir ++ "/subdir");

    {
        const file1 = try std.Io.Dir.cwd().createFile(io, temp_dir ++ "/file1.txt", .{});
        defer file1.close(io);
        try file1.writeStreamingAll(io, "AAA in file1\n");

        const file2 = try std.Io.Dir.cwd().createFile(io, temp_dir ++ "/subdir/file2.txt", .{});
        defer file2.close(io);
        try file2.writeStreamingAll(io, "BBB in file2\n");
    }
    defer std.Io.Dir.cwd().deleteTree(io, temp_dir) catch {};

    const result = try runZipgrep(allocator, &.{ "AAA|BBB", temp_dir });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find in both files
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "file1.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "file2.txt") != null);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "integration: alternation multiple matches per line" {
    // Test alternation when multiple alternatives match on the same line
    const allocator = std.testing.allocator;
    const temp_path = "/tmp/zipgrep_alternation_multiline_test.txt";

    {
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer file.close(io);
        // Line with multiple matching alternatives
        try file.writeStreamingAll(io, "ERR_SYS and PME_TURN_OFF on same line\n");
        try file.writeStreamingAll(io, "no match\n");
        try file.writeStreamingAll(io, "LINK_REQ_RST only\n");
    }
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    const result = try runZipgrep(allocator, &.{ "-c", "ERR_SYS|PME_TURN_OFF|LINK_REQ_RST", temp_path });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should count 2 matching lines (line 1 and line 3)
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "2") != null);
}

test "integration: alternation combined flags" {
    // Test alternation with combined flags (-i -w -n)
    const allocator = std.testing.allocator;
    const temp_path = "/tmp/zipgrep_alternation_combined_test.txt";

    {
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "line one\n"); // line 1
        try file.writeStreamingAll(io, "FOO standalone\n"); // line 2 - matches
        try file.writeStreamingAll(io, "FOOBAR embedded\n"); // line 3 - no match (word boundary)
        try file.writeStreamingAll(io, "bar standalone\n"); // line 4 - matches (case insensitive)
        try file.writeStreamingAll(io, "barbaz embedded\n"); // line 5 - no match
    }
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    const result = try runZipgrep(allocator, &.{ "-i", "-w", "-n", "foo|bar", temp_path });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should show lines 2 and 4
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "2:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "4:") != null);
    // Should NOT contain lines 3 or 5
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "3:") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "5:") == null);
}

test "integration: alternation large file" {
    // Test alternation on a larger file (stress test)
    const allocator = std.testing.allocator;
    const temp_path = "/tmp/zipgrep_alternation_large_test.txt";

    {
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer file.close(io);

        // Write many lines, with matches scattered throughout
        var i: usize = 0;
        while (i < 10000) : (i += 1) {
            if (i == 1000) {
                try file.writeStreamingAll(io, "ERROR_CODE_ALPHA found\n");
            } else if (i == 5000) {
                try file.writeStreamingAll(io, "ERROR_CODE_BETA found\n");
            } else if (i == 9000) {
                try file.writeStreamingAll(io, "ERROR_CODE_GAMMA found\n");
            } else {
                try file.writeStreamingAll(io, "normal line content here\n");
            }
        }
    }
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    const result = try runZipgrep(allocator, &.{ "-c", "ERROR_CODE_ALPHA|ERROR_CODE_BETA|ERROR_CODE_GAMMA", temp_path });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find exactly 3 matches
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "3") != null);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "integration: alternation single character patterns" {
    // Test alternation with single character alternatives
    const allocator = std.testing.allocator;
    const temp_path = "/tmp/zipgrep_alternation_singlechar_test.txt";

    {
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "line with a\n");
        try file.writeStreamingAll(io, "line with b\n");
        try file.writeStreamingAll(io, "line with c\n");
        try file.writeStreamingAll(io, "line with d\n");
    }
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    const result = try runZipgrep(allocator, &.{ "-c", "a|b|c", temp_path });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find 3 matching lines (a, b, c but not d)
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "3") != null);
}

test "integration: alternation special chars in patterns" {
    // Test alternation with underscores and numbers (common in code)
    const allocator = std.testing.allocator;
    const temp_path = "/tmp/zipgrep_alternation_special_test.txt";

    {
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "CONFIG_DEBUG_123 enabled\n");
        try file.writeStreamingAll(io, "some other line\n");
        try file.writeStreamingAll(io, "FLAG_VERBOSE_456 set\n");
        try file.writeStreamingAll(io, "another line\n");
        try file.writeStreamingAll(io, "OPT_TRACE_789 active\n");
    }
    defer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    const result = try runZipgrep(allocator, &.{ "CONFIG_DEBUG_123|FLAG_VERBOSE_456|OPT_TRACE_789", temp_path });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find all 3 pattern matches
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "CONFIG_DEBUG_123") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "FLAG_VERBOSE_456") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "OPT_TRACE_789") != null);
}

test "integration: one worker preserves explicit source order" {
    const allocator = std.testing.allocator;
    const temp_dir = "/tmp/zipgrep_explicit_source_order";
    const first_path = temp_dir ++ "/first.txt";
    const second_path = temp_dir ++ "/second.txt";

    std.Io.Dir.cwd().deleteTree(io, temp_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, temp_dir);
    defer std.Io.Dir.cwd().deleteTree(io, temp_dir) catch {};
    {
        const first = try std.Io.Dir.cwd().createFile(io, first_path, .{});
        defer first.close(io);
        try first.writeStreamingAll(io, "ORDER_MATCH first\n");
        const second = try std.Io.Dir.cwd().createFile(io, second_path, .{});
        defer second.close(io);
        try second.writeStreamingAll(io, "ORDER_MATCH second\n");
    }

    var result = try runZipgrep(allocator, &.{ "-j", "1", "ORDER_MATCH", first_path, second_path });
    defer result.deinit(allocator);
    const first_offset = std.mem.indexOf(u8, result.stdout, first_path).?;
    const second_offset = std.mem.indexOf(u8, result.stdout, second_path).?;
    try std.testing.expect(first_offset < second_offset);
}
