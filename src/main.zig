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

    var pattern: ?[]const u8 = null;
    var paths = std.ArrayListUnmanaged([]const u8){};
    defer paths.deinit(allocator);

    var config = Config{
        .pattern = undefined,
        .paths = undefined,
    };

    while (args.next()) |arg| {
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
            } else if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--threads")) {
                if (args.next()) |num_str| {
                    config.num_threads = std.fmt.parseInt(usize, num_str, 10) catch {
                        std.debug.print("Invalid thread count: {s}\n", .{num_str});
                        return error.InvalidArgument;
                    };
                }
            } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--max-depth")) {
                if (args.next()) |depth_str| {
                    config.max_depth = std.fmt.parseInt(usize, depth_str, 10) catch {
                        std.debug.print("Invalid max depth: {s}\n", .{depth_str});
                        return error.InvalidArgument;
                    };
                }
            } else if (std.mem.eql(u8, arg, "--color")) {
                if (args.next()) |color_str| {
                    if (std.mem.eql(u8, color_str, "always")) {
                        config.color = .always;
                    } else if (std.mem.eql(u8, color_str, "never")) {
                        config.color = .never;
                    } else if (std.mem.eql(u8, color_str, "auto")) {
                        config.color = .auto;
                    } else {
                        std.debug.print("Invalid color mode: {s} (use: auto, always, never)\n", .{color_str});
                        return error.InvalidArgument;
                    }
                }
            } else if (std.mem.eql(u8, arg, "--heading")) {
                config.heading = .always;
            } else if (std.mem.eql(u8, arg, "--no-heading")) {
                config.heading = .never;
            } else {
                std.debug.print("Unknown option: {s}\n", .{arg});
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
        std.debug.print("Error: No pattern specified\n\n", .{});
        printHelp();
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
    var pattern_matcher = try matcher.Matcher.init(allocator, config.pattern, config.ignore_case);
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

test "basic CLI parsing" {
    // Basic tests will go here
}
