const std = @import("std");
const reader = @import("reader.zig");
const regex = @import("regex.zig");
const walker = @import("walker.zig");
const gitignore = @import("gitignore.zig");
const output = @import("output.zig");
const matcher = @import("matcher.zig");

pub const ColorMode = enum { auto, always, never };
pub const HeadingMode = enum { auto, always, never };

pub const Config = struct {
    pattern: []const u8,
    paths: []const []const u8,
    ignore_case: bool = false,
    line_number: bool = true,
    count_only: bool = false,
    files_with_matches: bool = false,
    no_ignore: bool = false,
    hidden: bool = false,
    word_boundary: bool = false,
    max_depth: ?usize = null,
    num_threads: ?usize = null,
    color: ColorMode = .auto,
    heading: HeadingMode = .auto,

    pub fn getNumThreads(self: Config) usize {
        return self.num_threads orelse (std.Thread.getCpuCount() catch 4);
    }
};

pub fn main() !void {
    // Use page allocator backing an arena for fast bulk allocations
    // Arena is much faster than GeneralPurposeAllocator for our use case
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = parseArgs(allocator) catch |err| {
        if (err == error.HelpRequested) {
            return;
        }
        return err;
    };

    try run(allocator, config);
}

fn parseArgs(allocator: std.mem.Allocator) !Config {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.skip();

    // Collect all args into a slice
    var args_list = std.ArrayListUnmanaged([]const u8){};
    defer args_list.deinit(allocator);

    while (args.next()) |arg| {
        try args_list.append(allocator, arg);
    }

    return parseArgsFromSlice(allocator, args_list.items);
}

/// Parse arguments from a slice of strings (testable version)
pub fn parseArgsFromSlice(allocator: std.mem.Allocator, args: []const []const u8) !Config {
    var pattern: ?[]const u8 = null;
    var paths = std.ArrayListUnmanaged([]const u8){};
    defer paths.deinit(allocator);

    var config = Config{
        .pattern = undefined,
        .paths = undefined,
    };

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                printHelp();
                return error.HelpRequested;
            } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case")) {
                config.ignore_case = true;
            } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--line-number")) {
                config.line_number = true;
            } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count")) {
                config.count_only = true;
            } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--files-with-matches")) {
                config.files_with_matches = true;
            } else if (std.mem.eql(u8, arg, "--no-ignore")) {
                config.no_ignore = true;
            } else if (std.mem.eql(u8, arg, "--hidden")) {
                config.hidden = true;
            } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--word-regexp")) {
                config.word_boundary = true;
            } else if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--threads")) {
                i += 1;
                if (i < args.len) {
                    config.num_threads = std.fmt.parseInt(usize, args[i], 10) catch {
                        return error.InvalidArgument;
                    };
                }
            } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--max-depth")) {
                i += 1;
                if (i < args.len) {
                    config.max_depth = std.fmt.parseInt(usize, args[i], 10) catch {
                        return error.InvalidArgument;
                    };
                }
            } else if (std.mem.eql(u8, arg, "--color")) {
                i += 1;
                if (i < args.len) {
                    const color_str = args[i];
                    if (std.mem.eql(u8, color_str, "always")) {
                        config.color = .always;
                    } else if (std.mem.eql(u8, color_str, "never")) {
                        config.color = .never;
                    } else if (std.mem.eql(u8, color_str, "auto")) {
                        config.color = .auto;
                    } else {
                        return error.InvalidArgument;
                    }
                }
            } else if (std.mem.eql(u8, arg, "--heading")) {
                config.heading = .always;
            } else if (std.mem.eql(u8, arg, "--no-heading")) {
                config.heading = .never;
            } else {
                return error.InvalidArgument;
            }
        } else {
            if (pattern == null) {
                pattern = arg;
            } else {
                try paths.append(allocator, arg);
            }
        }
    }

    if (pattern == null) {
        return error.InvalidArgument;
    }

    config.pattern = pattern.?;

    if (paths.items.len == 0) {
        try paths.append(allocator, ".");
    }

    config.paths = try paths.toOwnedSlice(allocator);

    return config;
}

fn printHelp() void {
    const help =
        \\zrep - A fast grep implementation in Zig
        \\
        \\USAGE:
        \\    zrep [OPTIONS] PATTERN [PATH ...]
        \\
        \\ARGS:
        \\    PATTERN    The pattern to search for (literal or regex)
        \\    PATH       Files or directories to search (default: current directory)
        \\
        \\OPTIONS:
        \\    -h, --help              Show this help message
        \\    -i, --ignore-case       Case insensitive search
        \\    -n, --line-number       Show line numbers (default: on)
        \\    -c, --count             Only show count of matching lines
        \\    -l, --files-with-matches Only show filenames with matches
        \\    -w, --word-regexp       Only match whole words
        \\    --no-ignore             Don't respect .gitignore files
        \\    --hidden                Search hidden files and directories
        \\    -j, --threads NUM       Number of threads to use
        \\    -d, --max-depth NUM     Maximum directory depth to search
        \\    --color MODE            Color mode: auto, always, never (default: auto)
        \\    --heading               Group matches by file with headers (default for TTY)
        \\    --no-heading            Print file:line:content format (default for pipes)
        \\
        \\EXAMPLES:
        \\    zrep "TODO" src/
        \\    zrep -i "error" *.log
        \\    zrep "fn\s+\w+" --no-ignore .
        \\
    ;
    std.debug.print("{s}", .{help});
}

fn run(allocator: std.mem.Allocator, config: Config) !void {
    // With arena allocator, no need to free individual allocations
    // The arena handles bulk deallocation at the end
    
    const stdout = std.fs.File.stdout();

    // Create the pattern matcher
    var pattern_matcher = try matcher.Matcher.init(allocator, config.pattern, config.ignore_case, config.word_boundary);
    defer pattern_matcher.deinit();

    // Create gitignore matcher if needed
    var ignore_matcher: ?gitignore.GitignoreMatcher = null;
    if (!config.no_ignore) {
        ignore_matcher = gitignore.GitignoreMatcher.init(allocator);
    }
    defer if (ignore_matcher) |*im| im.deinit();

    // Create output handler
    var out = output.Output.init(stdout, config);

    // Create and run the parallel walker
    var w = try walker.Walker.init(
        allocator,
        config,
        &pattern_matcher,
        if (ignore_matcher) |*im| im else null,
        &out,
    );
    defer w.deinit();

    try w.walk();

    // Print final stats if counting
    if (config.count_only) {
        try out.printTotalCount();
    }
}

test "parseArgs pattern only" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{"searchterm"};

    const config = try parseArgsFromSlice(allocator, &args);
    defer allocator.free(config.paths);

    try std.testing.expectEqualStrings("searchterm", config.pattern);
    try std.testing.expectEqual(@as(usize, 1), config.paths.len);
    try std.testing.expectEqualStrings(".", config.paths[0]); // Default path
}

test "parseArgs pattern and path" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "pattern", "src/" };

    const config = try parseArgsFromSlice(allocator, &args);
    defer allocator.free(config.paths);

    try std.testing.expectEqualStrings("pattern", config.pattern);
    try std.testing.expectEqual(@as(usize, 1), config.paths.len);
    try std.testing.expectEqualStrings("src/", config.paths[0]);
}

test "parseArgs multiple paths" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "pattern", "src/", "lib/", "tests/" };

    const config = try parseArgsFromSlice(allocator, &args);
    defer allocator.free(config.paths);

    try std.testing.expectEqual(@as(usize, 3), config.paths.len);
    try std.testing.expectEqualStrings("src/", config.paths[0]);
    try std.testing.expectEqualStrings("lib/", config.paths[1]);
    try std.testing.expectEqualStrings("tests/", config.paths[2]);
}

test "parseArgs -i flag" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "-i", "pattern" };

    const config = try parseArgsFromSlice(allocator, &args);
    defer allocator.free(config.paths);

    try std.testing.expect(config.ignore_case);
}

test "parseArgs --ignore-case flag" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--ignore-case", "pattern" };

    const config = try parseArgsFromSlice(allocator, &args);
    defer allocator.free(config.paths);

    try std.testing.expect(config.ignore_case);
}

test "parseArgs -c flag" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "-c", "pattern" };

    const config = try parseArgsFromSlice(allocator, &args);
    defer allocator.free(config.paths);

    try std.testing.expect(config.count_only);
}

test "parseArgs -l flag" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "-l", "pattern" };

    const config = try parseArgsFromSlice(allocator, &args);
    defer allocator.free(config.paths);

    try std.testing.expect(config.files_with_matches);
}

test "parseArgs --no-ignore flag" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--no-ignore", "pattern" };

    const config = try parseArgsFromSlice(allocator, &args);
    defer allocator.free(config.paths);

    try std.testing.expect(config.no_ignore);
}

test "parseArgs --hidden flag" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--hidden", "pattern" };

    const config = try parseArgsFromSlice(allocator, &args);
    defer allocator.free(config.paths);

    try std.testing.expect(config.hidden);
}

test "parseArgs -w flag" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "-w", "pattern" };

    const config = try parseArgsFromSlice(allocator, &args);
    defer allocator.free(config.paths);

    try std.testing.expect(config.word_boundary);
}

test "parseArgs --word-regexp flag" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--word-regexp", "pattern" };

    const config = try parseArgsFromSlice(allocator, &args);
    defer allocator.free(config.paths);

    try std.testing.expect(config.word_boundary);
}

test "parseArgs -j threads" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "-j", "8", "pattern" };

    const config = try parseArgsFromSlice(allocator, &args);
    defer allocator.free(config.paths);

    try std.testing.expectEqual(@as(?usize, 8), config.num_threads);
}

test "parseArgs --threads" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--threads", "4", "pattern" };

    const config = try parseArgsFromSlice(allocator, &args);
    defer allocator.free(config.paths);

    try std.testing.expectEqual(@as(?usize, 4), config.num_threads);
}

test "parseArgs -d depth" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "-d", "3", "pattern" };

    const config = try parseArgsFromSlice(allocator, &args);
    defer allocator.free(config.paths);

    try std.testing.expectEqual(@as(?usize, 3), config.max_depth);
}

test "parseArgs --color always" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--color", "always", "pattern" };

    const config = try parseArgsFromSlice(allocator, &args);
    defer allocator.free(config.paths);

    try std.testing.expectEqual(ColorMode.always, config.color);
}

test "parseArgs --color never" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--color", "never", "pattern" };

    const config = try parseArgsFromSlice(allocator, &args);
    defer allocator.free(config.paths);

    try std.testing.expectEqual(ColorMode.never, config.color);
}

test "parseArgs --heading flag" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--heading", "pattern" };

    const config = try parseArgsFromSlice(allocator, &args);
    defer allocator.free(config.paths);

    try std.testing.expectEqual(HeadingMode.always, config.heading);
}

test "parseArgs --no-heading flag" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--no-heading", "pattern" };

    const config = try parseArgsFromSlice(allocator, &args);
    defer allocator.free(config.paths);

    try std.testing.expectEqual(HeadingMode.never, config.heading);
}

test "parseArgs invalid option" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--invalid", "pattern" };

    const result = parseArgsFromSlice(allocator, &args);
    try std.testing.expectError(error.InvalidArgument, result);
}

test "parseArgs no pattern" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{};

    const result = parseArgsFromSlice(allocator, &args);
    try std.testing.expectError(error.InvalidArgument, result);
}

test "parseArgs invalid thread count" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "-j", "not_a_number", "pattern" };

    const result = parseArgsFromSlice(allocator, &args);
    try std.testing.expectError(error.InvalidArgument, result);
}

test "parseArgs invalid color mode" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--color", "invalid", "pattern" };

    const result = parseArgsFromSlice(allocator, &args);
    try std.testing.expectError(error.InvalidArgument, result);
}

test "Config getNumThreads with value" {
    const config = Config{
        .pattern = "test",
        .paths = &[_][]const u8{"."},
        .num_threads = 16,
    };

    try std.testing.expectEqual(@as(usize, 16), config.getNumThreads());
}

test "Config getNumThreads default" {
    const config = Config{
        .pattern = "test",
        .paths = &[_][]const u8{"."},
        .num_threads = null,
    };

    // Should return CPU count or 4
    const threads = config.getNumThreads();
    try std.testing.expect(threads >= 1);
}

test "parseArgs combined flags" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "-i", "-c", "--hidden", "pattern", "src/" };

    const config = try parseArgsFromSlice(allocator, &args);
    defer allocator.free(config.paths);

    try std.testing.expect(config.ignore_case);
    try std.testing.expect(config.count_only);
    try std.testing.expect(config.hidden);
    try std.testing.expectEqualStrings("pattern", config.pattern);
    try std.testing.expectEqualStrings("src/", config.paths[0]);
}

test "parseArgs flags after pattern" {
    const allocator = std.testing.allocator;
    // Note: Current implementation treats flags anywhere as flags
    const args = [_][]const u8{ "pattern", "-i" };

    const config = try parseArgsFromSlice(allocator, &args);
    defer allocator.free(config.paths);

    try std.testing.expect(config.ignore_case);
    try std.testing.expectEqualStrings("pattern", config.pattern);
}
