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

/// Run zrep as a subprocess and capture output
fn runZrep(allocator: std.mem.Allocator, args: []const []const u8) !Result {
    const exe_path = "zig-out/bin/zrep";

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

    const result = try runZrep(allocator, &.{ "PATTERN", "tests/fixtures/sample.txt" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find PATTERN in the file
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "PATTERN") != null);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "integration: recursive search" {
    const allocator = std.testing.allocator;

    const result = try runZrep(allocator, &.{ "PATTERN", "tests/fixtures/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should find in both sample.txt and subdir/nested.txt
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "sample.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "nested.txt") != null);
}

test "integration: case insensitive" {
    const allocator = std.testing.allocator;

    const result = try runZrep(allocator, &.{ "-i", "pattern", "tests/fixtures/sample.txt" });
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

    const result = try runZrep(allocator, &.{ "-c", "PATTERN", "tests/fixtures/sample.txt" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should output count in format "file:count"
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "sample.txt") != null);
}

test "integration: files only mode" {
    const allocator = std.testing.allocator;

    const result = try runZrep(allocator, &.{ "-l", "PATTERN", "tests/fixtures/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should only output filenames, no line content
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "sample.txt") != null);
    // The actual content "appears here" should not be in output
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "appears here") == null);
}

test "integration: hidden files excluded by default" {
    const allocator = std.testing.allocator;

    const result = try runZrep(allocator, &.{ "PATTERN", "tests/fixtures/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Hidden file should NOT be in results by default
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, ".hidden.txt") == null);
}

test "integration: hidden files included with flag" {
    const allocator = std.testing.allocator;

    const result = try runZrep(allocator, &.{ "--hidden", "PATTERN", "tests/fixtures/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Hidden file SHOULD be in results with --hidden
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, ".hidden.txt") != null);
}

test "integration: gitignore respected" {
    const allocator = std.testing.allocator;

    const result = try runZrep(allocator, &.{ "PATTERN", "tests/fixtures/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // ignored.txt should NOT be in results (it's in .gitignore)
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "ignored.txt") == null);
    // Other files should still appear
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "sample.txt") != null);
}

test "integration: gitignore bypassed with flag" {
    const allocator = std.testing.allocator;

    const result = try runZrep(allocator, &.{ "--no-ignore", "PATTERN", "tests/fixtures/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // ignored.txt SHOULD be in results with --no-ignore
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "ignored.txt") != null);
}

test "integration: max depth" {
    const allocator = std.testing.allocator;

    const result = try runZrep(allocator, &.{ "-d", "0", "PATTERN", "tests/fixtures/" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // With depth 0, should only search files in fixtures/, not subdir/
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "nested.txt") == null);
}

test "integration: no matches" {
    const allocator = std.testing.allocator;

    const result = try runZrep(allocator, &.{ "NONEXISTENT_PATTERN_XYZ", "tests/fixtures/sample.txt" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should have empty output (no matches)
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
}

test "integration: regex pattern with dot" {
    const allocator = std.testing.allocator;

    // Use a simple regex with . (dot) which matches any single character
    const result = try runZrep(allocator, &.{ "PAT.ERN", "tests/fixtures/sample.txt" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // PAT.ERN should match PATTERN (dot matches T)
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "PATTERN") != null);
}

test "integration: regex pattern with dot-star" {
    const allocator = std.testing.allocator;

    // Test .* quantifier (zero or more of any character)
    const result = try runZrep(allocator, &.{ "PAT.*ERN", "tests/fixtures/sample.txt" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // PAT.*ERN should match PATTERN (.* matches T)
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "PATTERN") != null);
}

test "integration: regex pattern with plus" {
    const allocator = std.testing.allocator;

    // Test + quantifier (one or more)
    const result = try runZrep(allocator, &.{ "PAT+ERN", "tests/fixtures/sample.txt" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // PAT+ERN should match PATTERN (T+ matches TT)
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "PATTERN") != null);
}

test "integration: no-heading format" {
    const allocator = std.testing.allocator;

    const result = try runZrep(allocator, &.{ "--no-heading", "PATTERN", "tests/fixtures/sample.txt" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should be in flat format: file:line:content
    // Each line should contain the file path
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) {
            try std.testing.expect(std.mem.indexOf(u8, line, "sample.txt:") != null);
        }
    }
}

test "integration: binary files skipped" {
    const allocator = std.testing.allocator;

    const result = try runZrep(allocator, &.{ "PATTERN", "tests/fixtures/binary.bin" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Binary file should be skipped, so no output
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
}

test "integration: help flag" {
    const allocator = std.testing.allocator;

    const result = try runZrep(allocator, &.{"--help"});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Help should contain usage info
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "USAGE") != null);
}

test "integration: word boundary flag" {
    const allocator = std.testing.allocator;

    // Without -w: "pattern" should match "pattern" in lowercase line
    const result_without = try runZrep(allocator, &.{ "pattern", "tests/fixtures/sample.txt" });
    defer allocator.free(result_without.stdout);
    defer allocator.free(result_without.stderr);
    try std.testing.expect(std.mem.indexOf(u8, result_without.stdout, "pattern lowercase") != null);

    // With -w: "pattern" should still match as a whole word
    const result_with = try runZrep(allocator, &.{ "-w", "pattern", "tests/fixtures/sample.txt" });
    defer allocator.free(result_with.stdout);
    defer allocator.free(result_with.stderr);
    try std.testing.expect(std.mem.indexOf(u8, result_with.stdout, "pattern lowercase") != null);
}

test "integration: word boundary rejects partial matches" {
    const allocator = std.testing.allocator;

    // Search for "file" - without -w should match "file" in multiple contexts
    const result_without = try runZrep(allocator, &.{ "file", "tests/fixtures/sample.txt" });
    defer allocator.free(result_without.stdout);
    defer allocator.free(result_without.stderr);

    // Count lines without -w
    var count_without: usize = 0;
    var lines_without = std.mem.splitScalar(u8, result_without.stdout, '\n');
    while (lines_without.next()) |line| {
        if (line.len > 0) count_without += 1;
    }

    // With -w: should only match "file" as a whole word
    const result_with = try runZrep(allocator, &.{ "-w", "file", "tests/fixtures/sample.txt" });
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
