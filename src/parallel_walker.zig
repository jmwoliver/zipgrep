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

    pub fn init(path: []const u8, depth: usize) !*WorkItem {
        const owned_path = try allocator.dupe(u8, path);
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
        // Distribute initial paths to worker deques (round-robin)
        var path_idx: usize = 0;
        for (self.config.paths) |path| {
            const stat = std.fs.cwd().statFile(path) catch continue;
            if (stat.kind == .directory) {
                const work_item = try WorkItem.init(path, 0);
                const target_deque = path_idx % self.num_threads;

                var worker_handle = self.deques[target_deque].?.worker();
                try worker_handle.push(work_item);
                path_idx += 1;
            } else {
                // Process individual files directly
                self.searchFile(path, self.allocator) catch {};
            }
        }

        // If no directories to process, we're done
        if (path_idx == 0) {
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
    }

    /// Worker thread function - creates its own arena allocator on the stack
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
            std.Thread.yield() catch {};
        }

        while (!self.done.load(.acquire)) {
            // 1. Try to get work from own deque (LIFO - depth first)
            if (worker_handle.pop()) |work_item| {
                self.processDirectory(work_item, &worker_handle, thread_arena.allocator());
                continue;
            }

            // 2. Try stealing from other workers
            if (self.trySteal(worker_id)) |stolen_item| {
                self.processDirectory(stolen_item, &worker_handle, thread_arena.allocator());
                continue;
            }

            // 3. No work found - check for termination
            if (self.checkTermination(worker_id)) {
                break;
            }

            // Brief yield before retrying
            std.Thread.yield() catch {};
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

    /// Check if all work is done and signal termination if so
    fn checkTermination(self: *ParallelWalker, worker_id: usize) bool {
        _ = worker_id;

        // Decrement active count
        const prev = self.active_workers.fetchSub(1, .acq_rel);

        if (prev == 1) {
            // We were the last active worker - verify all deques are truly empty
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
                return true;
            }

            // Found work - re-increment and continue
            _ = self.active_workers.fetchAdd(1, .acq_rel);
            return false;
        }

        // Other workers still active - wait briefly and re-check
        std.Thread.yield() catch {}; // Brief yield instead of sleep

        // Re-check if work appeared
        for (self.deques) |maybe_dq| {
            if (maybe_dq) |dq| {
                if (!dq.isEmpty()) {
                    // Work appeared - re-increment and continue
                    _ = self.active_workers.fetchAdd(1, .acq_rel);
                    return false;
                }
            }
        }

        // Check if another worker signaled done
        if (self.done.load(.acquire)) {
            return true;
        }

        // Re-increment and keep trying
        _ = self.active_workers.fetchAdd(1, .acq_rel);
        return false;
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

        // Load .gitignore from this directory (only if gitignore is enabled)
        if (self.base_ignore_matcher != null) {
            const gitignore_path = std.fs.path.join(alloc, &.{ work.path, ".gitignore" }) catch return;
            defer alloc.free(gitignore_path);
            ignore_state.loadFile(gitignore_path, work.path) catch {};
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

            // Check gitignore
            if (self.base_ignore_matcher != null or ignore_state.localPatternCount() > 0) {
                const is_dir = entry.kind == .directory;
                if (ignore_state.isIgnored(full_path, is_dir)) {
                    alloc.free(full_path);
                    continue;
                }
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

    /// Search a single file for matches
    fn searchFile(self: *ParallelWalker, path: []const u8, alloc: std.mem.Allocator) !void {
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
