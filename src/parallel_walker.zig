const std = @import("std");
const main = @import("main.zig");
const matcher_mod = @import("matcher.zig");
const reader = @import("reader.zig");
const output = @import("output.zig");
const gitignore = @import("gitignore.zig");
const deque = @import("deque.zig");

/// A unit of work for the parallel walker
/// Uses page_allocator which is thread-safe for concurrent allocation/deallocation
pub const WorkItem = struct {
    /// Path to the directory to process
    path: []const u8,

    /// Depth in the directory tree
    depth: usize,

    /// Thread-safe allocator for WorkItems - page_allocator is safe for concurrent use
    const allocator = std.heap.page_allocator;

    pub fn init(dir_path: []const u8, depth: usize) !*WorkItem {
        const owned_path = try allocator.dupe(u8, dir_path);
        errdefer allocator.free(owned_path);

        const item = try allocator.create(WorkItem);
        item.* = .{
            .path = owned_path,
            .depth = depth,
        };
        return item;
    }

    pub fn deinit(self: *WorkItem) void {
        allocator.free(self.path);
        allocator.destroy(self);
    }
};

/// Minimal context passed to each worker thread - the arena is created on the thread's stack
const WorkerContext = struct {
    walker: *ParallelWalker,
    worker_id: usize,
};

/// Parallel directory walker using work-stealing for load balancing
pub const ParallelWalker = struct {
    allocator: std.mem.Allocator,
    config: main.Config,
    pattern_matcher: *matcher_mod.Matcher,
    base_ignore_matcher: ?*const gitignore.GitignoreMatcher,
    out: *output.Output,

    /// Number of worker threads
    num_threads: usize,

    /// Per-thread work-stealing deques
    deques: []?*deque.Deque(*WorkItem),

    /// Worker threads
    threads: []std.Thread,

    /// Termination signal
    done: std.atomic.Value(bool),

    /// Count of active workers (for termination detection)
    active_workers: std.atomic.Value(usize),

    /// Count of workers that have finished initialization
    initialized_workers: std.atomic.Value(usize),

    pub fn init(
        allocator: std.mem.Allocator,
        config: main.Config,
        pattern_matcher: *matcher_mod.Matcher,
        ignore_matcher: ?*const gitignore.GitignoreMatcher,
        out: *output.Output,
    ) !*ParallelWalker {
        const num_threads = config.getNumThreads();

        const walker = try allocator.create(ParallelWalker);
        errdefer allocator.destroy(walker);

        // Allocate arrays
        const deques = try allocator.alloc(?*deque.Deque(*WorkItem), num_threads);
        errdefer allocator.free(deques);
        @memset(deques, null);

        const threads = try allocator.alloc(std.Thread, num_threads);
        errdefer allocator.free(threads);

        // Initialize deques
        for (0..num_threads) |i| {
            deques[i] = try deque.Deque(*WorkItem).init(allocator);
        }
        errdefer {
            for (deques) |d| {
                if (d) |dq| dq.deinit();
            }
        }

        walker.* = .{
            .allocator = allocator,
            .config = config,
            .pattern_matcher = pattern_matcher,
            .base_ignore_matcher = ignore_matcher,
            .out = out,
            .num_threads = num_threads,
            .deques = deques,
            .threads = threads,
            .done = std.atomic.Value(bool).init(false),
            .active_workers = std.atomic.Value(usize).init(num_threads),
            .initialized_workers = std.atomic.Value(usize).init(0),
        };

        return walker;
    }

    pub fn deinit(self: *ParallelWalker) void {
        // Free any remaining work items in deques
        for (self.deques) |maybe_dq| {
            if (maybe_dq) |dq| {
                var worker_handle = dq.worker();
                while (worker_handle.pop()) |item| {
                    item.deinit();
                }
                dq.deinit();
            }
        }

        self.allocator.free(self.deques);
        self.allocator.free(self.threads);
        self.allocator.destroy(self);
    }

    /// Main entry point - walks all paths in parallel
    pub fn walk(self: *ParallelWalker) !void {
        // Track if we need to process stdin (do it AFTER files)
        var has_stdin = false;

        // Distribute initial paths to worker deques (round-robin)
        var path_idx: usize = 0;
        for (self.config.paths) |path| {
            // Skip stdin - process after files
            if (std.mem.eql(u8, path, "-")) {
                has_stdin = true;
                continue;
            }

            const stat = std.fs.cwd().statFile(path) catch continue;
            if (stat.kind == .directory) {
                const work_item = try WorkItem.init(path, 0);
                const target_deque = path_idx % self.num_threads;

                var worker_handle = self.deques[target_deque].?.worker();
                try worker_handle.push(work_item);
                path_idx += 1;
            } else {
                // Process individual files directly (check glob patterns first)
                if (gitignore.matchesGlobPatterns(path, false, self.config.glob_patterns)) {
                    self.searchFile(path, self.allocator) catch {};
                }
            }
        }

        // If no directories to process, skip to stdin
        if (path_idx == 0) {
            // Process stdin last (after files) so output appears before blocking
            if (has_stdin) {
                self.searchStdin() catch {};
            }
            return;
        }

        // Spawn worker threads - pass walker and worker_id directly
        for (0..self.num_threads) |i| {
            self.threads[i] = try std.Thread.spawn(.{}, workerThreadFn, .{ self, i });
        }

        // Wait for all workers to complete
        for (self.threads) |thread| {
            thread.join();
        }

        // Process stdin AFTER files (so file output appears before blocking on stdin)
        if (has_stdin) {
            self.searchStdin() catch {};
        }
    }

    /// Worker thread function - creates its own arena allocator on the stack
    /// Based on the Rust ignore crate pattern for efficient work-stealing
    fn workerThreadFn(self: *ParallelWalker, worker_id: usize) void {
        var worker_handle = self.deques[worker_id].?.worker();

        // Create thread-local arena allocator on this thread's stack
        // This ensures proper alignment and thread-local memory management
        var thread_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer thread_arena.deinit();

        // Signal that this worker is initialized
        _ = self.initialized_workers.fetchAdd(1, .release);

        // Wait for all workers to initialize (prevents early termination)
        while (self.initialized_workers.load(.acquire) < self.num_threads) {
            std.atomic.spinLoopHint();
        }

        var consecutive_empty: u32 = 0;

        while (true) {
            // Try to get work - first from own deque, then steal
            const work_item = worker_handle.pop() orelse self.trySteal(worker_id);

            if (work_item) |item| {
                // Got work - process it
                consecutive_empty = 0;
                self.processDirectory(item, &worker_handle, thread_arena.allocator());

                // Reset arena to reclaim memory after each directory
                // This is safe because all allocations from processDirectory are
                // temporary (paths, gitignore state) and not referenced after return.
                // WorkItem uses page_allocator separately and is unaffected.
                // Using .retain_capacity keeps backing pages to avoid syscall overhead.
                _ = thread_arena.reset(.retain_capacity);

                continue;
            }

            // No work found - check if we should terminate or sleep
            // This is the critical section where we need to be careful about atomics

            // Check if already done
            if (self.done.load(.acquire)) {
                break;
            }

            // Adaptive spinning - spin more on first few empty cycles
            const spin_iterations: usize = if (consecutive_empty < 4) 128 else 32;
            var found_work = false;
            for (0..spin_iterations) |_| {
                std.atomic.spinLoopHint();
                // Quick check if work appeared in our deque
                if (!worker_handle.deque.isEmpty()) {
                    found_work = true;
                    break;
                }
            }
            if (found_work) continue;

            // Also check other deques before sleeping (quick scan)
            for (self.deques) |maybe_dq| {
                if (maybe_dq) |dq| {
                    if (!dq.isEmpty()) {
                        found_work = true;
                        break;
                    }
                }
            }
            if (found_work) continue;

            // No work after spinning - deactivate this worker
            const prev_active = self.active_workers.fetchSub(1, .acq_rel);

            if (prev_active == 1) {
                // We were the last active worker - check if truly done
                var any_work = false;
                for (self.deques) |maybe_dq| {
                    if (maybe_dq) |dq| {
                        if (!dq.isEmpty()) {
                            any_work = true;
                            break;
                        }
                    }
                }

                if (!any_work) {
                    // Truly done - signal termination
                    self.done.store(true, .release);
                    break;
                }

                // Work exists - reactivate and continue
                _ = self.active_workers.fetchAdd(1, .acq_rel);
                consecutive_empty = 0;
                continue;
            }

            // Stay deactivated and sleep until work appears or we're done
            // This loop avoids atomic operations while idle
            while (true) {
                consecutive_empty = @min(consecutive_empty + 1, 20);
                const sleep_ns: u64 = switch (consecutive_empty) {
                    0...2 => 10_000, // 10µs - very responsive
                    3...5 => 100_000, // 100µs
                    6...10 => 500_000, // 500µs
                    else => 2_000_000, // 2ms - save CPU when truly idle
                };
                std.Thread.sleep(sleep_ns);

                // Check if done
                if (self.done.load(.acquire)) {
                    break;
                }

                // Check if work appeared in any deque
                var has_work = false;
                for (self.deques) |maybe_dq| {
                    if (maybe_dq) |dq| {
                        if (!dq.isEmpty()) {
                            has_work = true;
                            break;
                        }
                    }
                }

                if (has_work) {
                    // Work available - reactivate and exit sleep loop
                    _ = self.active_workers.fetchAdd(1, .acq_rel);
                    consecutive_empty = 0;
                    break;
                }
                // No work - stay deactivated and sleep again
            }
        }
    }

    /// Try to steal work from another worker's deque
    fn trySteal(self: *ParallelWalker, worker_id: usize) ?*WorkItem {
        // Try stealing from other workers in round-robin order
        for (1..self.num_threads) |offset| {
            const target = (worker_id + offset) % self.num_threads;
            var stealer = self.deques[target].?.stealer();

            // Try a few times in case of contention
            for (0..3) |_| {
                switch (stealer.steal()) {
                    .success => |item| return item,
                    .empty => break,
                    .retry => continue,
                }
            }
        }
        return null;
    }

    /// Load .gitignore files from all parent directories of the given path
    /// This walks from the search root down to the current directory, loading
    /// any .gitignore files found along the way. This ensures nested gitignore
    /// patterns are properly inherited even when work items are processed out of order.
    fn loadParentGitignores(self: *ParallelWalker, ignore_state: *gitignore.GitignoreState, dir_path: []const u8, alloc: std.mem.Allocator) void {
        // Get the search root - we need to find which config path this directory is under
        var search_root: []const u8 = ".";
        for (self.config.paths) |path| {
            if (std.mem.startsWith(u8, dir_path, path)) {
                search_root = path;
                break;
            }
        }

        // Normalize search root
        var normalized_root = search_root;
        if (std.mem.eql(u8, normalized_root, ".") and dir_path.len >= 2 and dir_path[0] == '.' and dir_path[1] == '/') {
            normalized_root = "./";
        }

        // Build list of directories from root to current (in order)
        var dirs_to_check = std.ArrayListUnmanaged([]const u8){};
        defer {
            for (dirs_to_check.items) |d| {
                alloc.free(d);
            }
            dirs_to_check.deinit(alloc);
        }

        // Start with the full path and walk up to find all parent directories
        var current = dir_path;
        while (current.len > 0) {
            // Don't go above search root
            if (current.len < search_root.len) break;
            if (std.mem.eql(u8, search_root, ".") and !std.mem.startsWith(u8, current, "./") and current.len > 0) {
                // For "." root, stop at the first component
                const dup = alloc.dupe(u8, current) catch break;
                dirs_to_check.append(alloc, dup) catch {
                    alloc.free(dup);
                    break;
                };
                break;
            }

            const dup = alloc.dupe(u8, current) catch break;
            dirs_to_check.append(alloc, dup) catch {
                alloc.free(dup);
                break;
            };

            // Move to parent directory
            if (std.mem.lastIndexOf(u8, current, "/")) |idx| {
                if (idx == 0) break;
                current = current[0..idx];
            } else {
                break;
            }
        }

        // Reverse to process from root to current directory
        std.mem.reverse([]const u8, dirs_to_check.items);

        // Load .gitignore from each directory in order
        for (dirs_to_check.items) |dir| {
            const gitignore_path = std.fs.path.join(alloc, &.{ dir, ".gitignore" }) catch continue;
            defer alloc.free(gitignore_path);
            ignore_state.loadFile(gitignore_path, dir) catch {};
        }
    }

    /// Process a single directory
    fn processDirectory(self: *ParallelWalker, work: *WorkItem, worker_handle: *deque.Worker(*WorkItem), alloc: std.mem.Allocator) void {
        defer work.deinit();

        // Check max depth
        if (self.config.max_depth) |max| {
            if (work.depth >= max) return;
        }

        // Open directory
        var dir = std.fs.cwd().openDir(work.path, .{ .iterate = true }) catch return;
        defer dir.close();

        // Create thread-local gitignore state (only if not --no-ignore)
        var ignore_state = gitignore.GitignoreState.init(alloc, self.base_ignore_matcher);
        defer ignore_state.deinit();

        // Load .gitignore files from all parent directories up to and including current
        // This ensures nested .gitignore patterns are properly inherited
        if (self.base_ignore_matcher != null) {
            self.loadParentGitignores(&ignore_state, work.path, alloc);
        }

        // Iterate directory entries
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            // Skip hidden files/dirs unless --hidden is set
            if (!self.config.hidden and entry.name.len > 0 and entry.name[0] == '.') {
                if (entry.kind != .file or !std.mem.eql(u8, entry.name, ".gitignore")) {
                    continue;
                }
            }

            // Skip common VCS directories
            if (entry.kind == .directory and gitignore.GitignoreMatcher.isCommonIgnoredDir(entry.name)) {
                continue;
            }

            const full_path = std.fs.path.join(alloc, &.{ work.path, entry.name }) catch continue;
            const is_dir = entry.kind == .directory;

            // Check gitignore
            if (self.base_ignore_matcher != null or ignore_state.localPatternCount() > 0) {
                if (ignore_state.isIgnored(full_path, is_dir)) {
                    alloc.free(full_path);
                    continue;
                }
            }

            // Check glob patterns from -g/--glob flags
            if (!gitignore.matchesGlobPatterns(full_path, is_dir, self.config.glob_patterns)) {
                alloc.free(full_path);
                continue;
            }

            switch (entry.kind) {
                .file => {
                    // Search file immediately
                    self.searchFile(full_path, alloc) catch {};
                    alloc.free(full_path);
                },
                .directory => {
                    // Push subdirectory to local deque
                    const new_work = WorkItem.init(full_path, work.depth + 1) catch {
                        alloc.free(full_path);
                        continue;
                    };
                    alloc.free(full_path);

                    worker_handle.push(new_work) catch {
                        new_work.deinit();
                    };
                },
                else => {
                    alloc.free(full_path);
                },
            }
        }
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
    fn searchStdin(self: *ParallelWalker) !void {
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

    /// Search a single file for matches
    fn searchFile(self: *ParallelWalker, path: []const u8, alloc: std.mem.Allocator) !void {
        // Skip .gitignore files
        if (std.mem.endsWith(u8, path, ".gitignore")) return;

        var content = reader.readFile(alloc, path, true) catch return;
        defer content.deinit();

        const data = content.bytes();
        if (data.len == 0) return;

        // Binary file detection: check first 8KB for NUL bytes
        const check_len = @min(data.len, 8192);
        for (data[0..check_len]) |byte| {
            if (byte == 0) return;
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

// ============================================================================
// Tests
// ============================================================================

test "WorkItem: init and deinit" {
    const allocator = std.testing.allocator;

    _ = allocator; // WorkItem uses its own thread-safe allocator
    const item = try WorkItem.init("/test/path", 5);
    defer item.deinit();

    try std.testing.expectEqualStrings("/test/path", item.path);
    try std.testing.expectEqual(@as(usize, 5), item.depth);
}

test "Thread-local arena allocator alignment" {
    // This test verifies that creating an arena allocator on a thread's stack
    // and using it for allocations works correctly - this was the root cause
    // of the alignment panic bug.
    const num_threads: usize = 4;
    const allocations_per_thread: usize = 100;

    var threads: [num_threads]std.Thread = undefined;
    var results: [num_threads]bool = [_]bool{false} ** num_threads;

    // Spawn threads that each create their own arena and do allocations
    for (0..num_threads) |i| {
        threads[i] = std.Thread.spawn(.{}, struct {
            fn threadFn(thread_results: *[num_threads]bool, thread_id: usize) void {
                // Create arena on this thread's stack - this must be properly aligned
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();

                const alloc = arena.allocator();

                // Do various allocations to test alignment
                var success = true;
                for (0..allocations_per_thread) |j| {
                    // Allocate slices of varying sizes
                    const size = (j + 1) * 8;
                    const slice = alloc.alloc(u8, size) catch {
                        success = false;
                        break;
                    };

                    // Verify the allocation is usable
                    @memset(slice, @truncate(j));
                    for (slice) |byte| {
                        if (byte != @as(u8, @truncate(j))) {
                            success = false;
                            break;
                        }
                    }
                    alloc.free(slice);

                    // Also test creating structs (like WorkItem)
                    const TestStruct = struct {
                        data: [64]u8,
                        ptr: ?*anyopaque,
                        value: usize,
                    };

                    const item = alloc.create(TestStruct) catch {
                        success = false;
                        break;
                    };
                    item.* = .{
                        .data = [_]u8{0} ** 64,
                        .ptr = null,
                        .value = j,
                    };
                    alloc.destroy(item);
                }

                thread_results[thread_id] = success;
            }
        }.threadFn, .{ &results, i }) catch {
            results[i] = false;
            continue;
        };
    }

    // Join all threads
    for (&threads) |*t| {
        t.join();
    }

    // Verify all threads succeeded
    for (results, 0..) |result, i| {
        if (!result) {
            std.debug.print("Thread {d} failed\n", .{i});
        }
        try std.testing.expect(result);
    }
}

test "ParallelWalker: init and deinit" {
    const allocator = std.testing.allocator;

    const config = main.Config{
        .pattern = "test",
        .paths = &[_][]const u8{"."},
        .num_threads = 4,
    };

    var pattern_matcher = try matcher_mod.Matcher.init(allocator, "test", false, false);
    defer pattern_matcher.deinit();

    const stdout = std.fs.File.stdout();
    var out = output.Output.init(stdout, config);

    var walker = try ParallelWalker.init(allocator, config, &pattern_matcher, null, &out);
    defer walker.deinit();

    try std.testing.expectEqual(@as(usize, 4), walker.num_threads);
    try std.testing.expect(!walker.done.load(.acquire));
}

test "ParallelWalker: with gitignore matcher" {
    const allocator = std.testing.allocator;

    const config = main.Config{
        .pattern = "test",
        .paths = &[_][]const u8{"."},
    };

    var pattern_matcher = try matcher_mod.Matcher.init(allocator, "test", false, false);
    defer pattern_matcher.deinit();

    var ignore_matcher = gitignore.GitignoreMatcher.init(allocator);
    defer ignore_matcher.deinit();
    try ignore_matcher.addPattern("*.log", ".");

    const stdout = std.fs.File.stdout();
    var out = output.Output.init(stdout, config);

    var walker = try ParallelWalker.init(allocator, config, &pattern_matcher, &ignore_matcher, &out);
    defer walker.deinit();

    try std.testing.expect(walker.base_ignore_matcher != null);
}

test "Parallel WorkItem allocation stress test" {
    // This test simulates the actual parallel walker pattern:
    // - Multiple threads creating WorkItems concurrently
    // - WorkItems use page_allocator (thread-safe) internally
    // - Heavy concurrent allocation/deallocation
    //
    // This specifically tests the fix for the alignment panic bug.

    const num_threads: usize = 8;
    const items_per_thread: usize = 500;

    var threads: [num_threads]std.Thread = undefined;
    var errors: [num_threads]bool = [_]bool{false} ** num_threads;

    // Spawn threads that simulate parallel walker behavior
    for (0..num_threads) |i| {
        threads[i] = std.Thread.spawn(.{}, struct {
            fn threadFn(error_flags: *[num_threads]bool, thread_id: usize) void {
                // Create thread-local arena (like the fixed parallel walker does)
                var thread_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer thread_arena.deinit();

                const arena_alloc = thread_arena.allocator();

                // Simulate work item creation and processing
                for (0..items_per_thread) |j| {
                    // Create path using thread-local arena
                    const path = std.fmt.allocPrint(arena_alloc, "/test/path/{d}/{d}", .{ thread_id, j }) catch {
                        error_flags[thread_id] = true;
                        return;
                    };

                    // WorkItem uses its own thread-safe page_allocator internally
                    const item = WorkItem.init(path, j) catch {
                        error_flags[thread_id] = true;
                        return;
                    };

                    // Simulate some work
                    if (!std.mem.eql(u8, item.path[0..5], "/test")) {
                        error_flags[thread_id] = true;
                        item.deinit();
                        return;
                    }

                    if (item.depth != j) {
                        error_flags[thread_id] = true;
                        item.deinit();
                        return;
                    }

                    item.deinit();
                }
            }
        }.threadFn, .{ &errors, i }) catch {
            errors[i] = true;
            continue;
        };
    }

    // Join all threads
    for (&threads) |*t| {
        t.join();
    }

    // Verify no threads had errors
    for (errors, 0..) |had_error, i| {
        if (had_error) {
            std.debug.print("Thread {d} had an error\n", .{i});
        }
        try std.testing.expect(!had_error);
    }
}
