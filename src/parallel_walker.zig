const std = @import("std");
const main = @import("main.zig");
const matcher_mod = @import("matcher.zig");
const reader = @import("reader.zig");
const output = @import("output.zig");
const gitignore = @import("gitignore.zig");
const deque = @import("deque.zig");
const aho_corasick = @import("aho_corasick.zig");
const simd = @import("simd.zig");

/// One immutable level in a directory's inherited ignore context. Nodes are
/// shared by child jobs and may cross worker threads through work stealing.
const IgnoreNode = struct {
    const allocator = std.heap.smp_allocator;

    ref_count: std.atomic.Value(usize),
    state: gitignore.GitignoreState,
    parent: ?*IgnoreNode,

    fn create(state: gitignore.GitignoreState, parent: ?*IgnoreNode) !*IgnoreNode {
        const node = try allocator.create(IgnoreNode);
        if (parent) |p| p.retain();
        node.* = .{
            .ref_count = std.atomic.Value(usize).init(1),
            .state = state,
            .parent = parent,
        };
        return node;
    }

    fn retain(self: *IgnoreNode) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    fn release(self: *IgnoreNode) void {
        if (self.ref_count.fetchSub(1, .acq_rel) != 1) return;

        const parent = self.parent;
        self.state.deinit();
        allocator.destroy(self);
        if (parent) |p| p.release();
    }
};

/// A unit of work for the parallel walker. Files are first-class jobs so a
/// single wide directory can use every search worker.
pub const WorkItem = struct {
    const Kind = enum { directory, file };

    path: []const u8,
    depth: usize,
    kind: Kind,
    binary_scan_all: bool,
    ignore_node: ?*IgnoreNode,

    // The SMP allocator avoids one mmap/munmap pair per discovered file while
    // remaining safe for producer/consumer allocation on different threads.
    const allocator = std.heap.smp_allocator;

    pub fn init(dir_path: []const u8, depth: usize) !*WorkItem {
        return initDirectory(dir_path, depth, null);
    }

    fn initDirectory(dir_path: []const u8, depth: usize, ignore_node: ?*IgnoreNode) !*WorkItem {
        return initKind(dir_path, depth, .directory, true, ignore_node);
    }

    pub fn initFile(file_path: []const u8, binary_scan_all: bool) !*WorkItem {
        return initKind(file_path, 0, .file, binary_scan_all, null);
    }

    fn initOwnedFile(file_path: []u8, binary_scan_all: bool) !*WorkItem {
        return initOwnedKind(file_path, 0, .file, binary_scan_all, null);
    }

    fn initOwnedDirectory(dir_path: []u8, depth: usize, ignore_node: ?*IgnoreNode) !*WorkItem {
        return initOwnedKind(dir_path, depth, .directory, true, ignore_node);
    }

    fn initKind(path: []const u8, depth: usize, kind: Kind, binary_scan_all: bool, ignore_node: ?*IgnoreNode) !*WorkItem {
        const owned_path = try allocator.dupe(u8, path);
        return initOwnedKind(owned_path, depth, kind, binary_scan_all, ignore_node);
    }

    fn initOwnedKind(owned_path: []u8, depth: usize, kind: Kind, binary_scan_all: bool, ignore_node: ?*IgnoreNode) !*WorkItem {
        errdefer allocator.free(owned_path);
        const item = try allocator.create(WorkItem);
        item.* = .{
            .path = owned_path,
            .depth = depth,
            .kind = kind,
            .binary_scan_all = binary_scan_all,
            .ignore_node = ignore_node,
        };
        if (ignore_node) |node| node.retain();
        return item;
    }

    pub fn deinit(self: *WorkItem) void {
        if (self.ignore_node) |node| node.release();
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
    cancelled: std.atomic.Value(bool),

    /// Count of active workers (for termination detection)
    active_workers: std.atomic.Value(usize),

    /// Count of workers that have finished initialization
    initialized_workers: std.atomic.Value(usize),

    /// Worker-side I/O/allocation errors are recorded and reported after join.
    had_error: std.atomic.Value(bool),
    broken_pipe: std.atomic.Value(bool),
    error_mutex: std.Thread.Mutex,

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
        errdefer {
            for (deques) |d| {
                if (d) |dq| dq.deinit();
            }
        }

        const threads = try allocator.alloc(std.Thread, num_threads);
        errdefer allocator.free(threads);

        // Initialize deques
        for (0..num_threads) |i| {
            // Queue backing arrays grow independently on worker threads. The
            // caller allocator is normally a non-thread-safe arena, so queue
            // internals must use a shared concurrent allocator.
            deques[i] = try deque.Deque(*WorkItem).init(std.heap.smp_allocator);
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
            .cancelled = std.atomic.Value(bool).init(false),
            .active_workers = std.atomic.Value(usize).init(num_threads),
            .initialized_workers = std.atomic.Value(usize).init(0),
            .had_error = std.atomic.Value(bool).init(false),
            .broken_pipe = std.atomic.Value(bool).init(false),
            .error_mutex = .{},
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
        var work_count: usize = 0;
        for (self.config.paths, 0..) |_, input_index| {
            if (self.done.load(.acquire)) break;
            // The owner end of the deque is LIFO. Reverse initial insertion
            // for the one-worker path so explicit sources are searched in
            // command-line order without changing the deque's semantics.
            const path_index = if (self.num_threads == 1)
                self.config.paths.len - input_index - 1
            else
                input_index;
            const path = self.config.paths[path_index];
            // Skip stdin - process after files
            if (std.mem.eql(u8, path, "-")) {
                has_stdin = true;
                continue;
            }

            const stat = std.fs.cwd().statFile(path) catch |err| {
                self.recordError(path, err);
                continue;
            };
            if (stat.kind == .directory) {
                const work_item = try WorkItem.init(path, 0);
                const target_deque = work_count % self.num_threads;

                var worker_handle = self.deques[target_deque].?.worker();
                worker_handle.push(work_item) catch |err| {
                    work_item.deinit();
                    return err;
                };
                work_count += 1;
            } else {
                if (gitignore.matchesGlobPatterns(path, false, self.config.glob_patterns)) {
                    // Keep the common one-file path on the caller thread to
                    // preserve sub-millisecond startup. Multiple explicit
                    // files are stealable just like recursively found files.
                    if (self.config.is_single_source) {
                        try self.searchFile(path, std.heap.smp_allocator, false);
                    } else {
                        const work_item = try WorkItem.initFile(path, false);
                        const target_deque = work_count % self.num_threads;
                        var worker_handle = self.deques[target_deque].?.worker();
                        worker_handle.push(work_item) catch |err| {
                            work_item.deinit();
                            return err;
                        };
                        work_count += 1;
                    }
                }
            }
        }

        // If no directories to process, skip to stdin
        if (work_count == 0) {
            // Process stdin last (after files) so output appears before blocking
            if (has_stdin) {
                try self.searchStdin();
            }
            if (self.had_error.load(.acquire)) return error.SearchFailed;
            return;
        }

        if (self.num_threads == 1) {
            // Avoid thread creation on explicit -j1 and sequential traversal.
            self.workerThreadFn(0);
        } else {
            // Spawn worker threads - pass walker and worker_id directly
            var spawned: usize = 0;
            for (0..self.num_threads) |i| {
                self.threads[i] = std.Thread.spawn(.{}, workerThreadFn, .{ self, i }) catch |err| {
                    self.done.store(true, .release);
                    self.initialized_workers.store(self.num_threads, .release);
                    for (self.threads[0..spawned]) |thread| thread.join();
                    return err;
                };
                spawned += 1;
            }

            // Wait for all workers to complete
            for (self.threads) |thread| {
                thread.join();
            }
        }

        // Process stdin AFTER files (so file output appears before blocking on stdin)
        if (has_stdin and !self.cancelled.load(.acquire) and !self.broken_pipe.load(.acquire)) {
            try self.searchStdin();
        }
        if (self.broken_pipe.load(.acquire)) return error.BrokenPipe;
        if (self.had_error.load(.acquire)) return error.SearchFailed;
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
        if (self.done.load(.acquire)) return;

        var consecutive_empty: u32 = 0;

        while (true) {
            if (self.done.load(.acquire)) break;
            // Try to get work - first from own deque, then steal
            const work_item = worker_handle.pop() orelse self.trySteal(worker_id);

            if (work_item) |item| {
                // Got work - process it
                consecutive_empty = 0;
                switch (item.kind) {
                    .directory => self.processDirectory(item, &worker_handle, thread_arena.allocator()),
                    .file => {
                        defer item.deinit();
                        const buffer_allocator = if (item.binary_scan_all) thread_arena.allocator() else std.heap.smp_allocator;
                        self.searchFile(item.path, buffer_allocator, item.binary_scan_all) catch |err| {
                            self.recordError(item.path, err);
                        };
                    },
                }

                // Reset arena to reclaim memory after each directory
                // This is safe because all allocations from processDirectory are
                // temporary (paths, gitignore state) and not referenced after return.
                // WorkItem uses page_allocator separately and is unaffected.
                // Using .retain_capacity keeps backing pages to avoid syscall overhead.
                _ = thread_arena.reset(.{ .retain_with_limit = 256 * 1024 });

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

    /// Process a single directory
    fn processDirectory(self: *ParallelWalker, work: *WorkItem, worker_handle: *deque.Worker(*WorkItem), alloc: std.mem.Allocator) void {
        defer work.deinit();

        // Check max depth
        if (self.config.max_depth) |max| {
            if (work.depth >= max) return;
        }

        // Open directory
        var dir = std.fs.cwd().openDir(work.path, .{ .iterate = true }) catch |err| {
            self.recordError(work.path, err);
            return;
        };
        defer dir.close();

        // The root's .gitignore and its ancestors are already in the immutable
        // base matcher. Every child loads only its own local file and shares its
        // parent's persistent state with any child jobs it creates.
        var effective_ignore = work.ignore_node;
        var local_node: ?*IgnoreNode = null;
        defer if (local_node) |node| node.release();

        if (self.base_ignore_matcher != null and work.depth > 0) {
            var local_state = gitignore.GitignoreState.init(
                std.heap.smp_allocator,
                if (work.ignore_node == null) self.base_ignore_matcher else null,
            );
            local_state.parent = if (work.ignore_node) |node| &node.state else null;
            var state_moved = false;
            defer if (!state_moved) local_state.deinit();

            const gitignore_path = std.fs.path.join(alloc, &.{ work.path, ".gitignore" }) catch null;
            if (gitignore_path) |path| {
                local_state.loadFile(path, work.path) catch |err| {
                    self.recordError(path, err);
                };
            }

            if (local_state.localPatternCount() > 0) {
                local_node = IgnoreNode.create(local_state, work.ignore_node) catch |err| {
                    self.recordError(work.path, err);
                    return;
                };
                state_moved = true;
                effective_ignore = local_node;
            }
        }

        // Iterate directory entries
        var iter = dir.iterate();
        while (true) {
            if (self.done.load(.acquire)) break;
            const entry = (iter.next() catch |err| {
                self.recordError(work.path, err);
                break;
            }) orelse break;
            // Skip hidden files/dirs unless --hidden is set
            if (!self.config.hidden and entry.name.len > 0 and entry.name[0] == '.') {
                continue;
            }

            // Skip common VCS directories
            if (entry.kind == .directory and gitignore.GitignoreMatcher.isCommonIgnoredDir(entry.name)) {
                continue;
            }

            const full_path = std.fs.path.join(WorkItem.allocator, &.{ work.path, entry.name }) catch |err| {
                self.recordError(work.path, err);
                continue;
            };
            const is_dir = entry.kind == .directory;

            // Check gitignore
            if (effective_ignore) |node| {
                if (node.state.isIgnored(full_path, is_dir)) {
                    WorkItem.allocator.free(full_path);
                    continue;
                }
            } else if (self.base_ignore_matcher) |base| {
                if (base.isIgnored(full_path, is_dir)) {
                    WorkItem.allocator.free(full_path);
                    continue;
                }
            }

            // Check glob patterns from -g/--glob flags
            if (!gitignore.matchesGlobPatterns(full_path, is_dir, self.config.glob_patterns)) {
                WorkItem.allocator.free(full_path);
                continue;
            }

            switch (entry.kind) {
                .file => {
                    // Queue files individually so flat directories scale.
                    const new_work = WorkItem.initOwnedFile(full_path, true) catch |err| {
                        self.recordError(work.path, err);
                        continue;
                    };
                    worker_handle.push(new_work) catch |err| {
                        self.recordError(new_work.path, err);
                        new_work.deinit();
                    };
                },
                .directory => {
                    // Push subdirectory to local deque
                    const new_work = WorkItem.initOwnedDirectory(full_path, work.depth + 1, effective_ignore) catch |err| {
                        self.recordError(work.path, err);
                        continue;
                    };

                    worker_handle.push(new_work) catch |err| {
                        self.recordError(new_work.path, err);
                        new_work.deinit();
                    };
                },
                else => {
                    WorkItem.allocator.free(full_path);
                },
            }
        }
    }

    fn recordError(self: *ParallelWalker, path: []const u8, err: anyerror) void {
        if (err == error.BrokenPipe) {
            self.broken_pipe.store(true, .release);
            self.done.store(true, .release);
            return;
        }
        self.had_error.store(true, .release);
        self.error_mutex.lock();
        defer self.error_mutex.unlock();
        std.debug.print("zg: {s}: {s}\n", .{ path, @errorName(err) });
    }

    /// Search stdin for matches
    fn searchStdin(self: *ParallelWalker) !void {
        const buffer_size: usize = if (self.config.files_with_matches) 64 * 1024 else 256 * 1024;
        var stream = try reader.StreamingLineReader.initFileWithBuffer(std.heap.smp_allocator, std.fs.File.stdin(), false, buffer_size);
        defer stream.deinit();
        try self.searchStream(&stream, "<stdin>");
    }

    /// Search a single file for matches using streaming reader.
    /// Uses memory proportional to the longest line, not the file size.
    fn searchFile(self: *ParallelWalker, path: []const u8, buffer_allocator: std.mem.Allocator, binary_scan_all: bool) !void {
        const buffer_size: usize = if (self.config.files_with_matches) 64 * 1024 else 256 * 1024;
        var stream = try reader.StreamingLineReader.initWithOptions(buffer_allocator, path, binary_scan_all, buffer_size);
        defer stream.deinit();

        try self.searchStream(&stream, path);
    }

    /// Unified matching/output path for recursive files, explicit files and
    /// stdin. Keeping one implementation prevents mode-specific correctness
    /// and performance drift.
    fn searchStream(self: *ParallelWalker, stream: *reader.StreamingLineReader, path: []const u8) !void {
        simd.resetSubstringCaches();
        if (self.config.quiet) {
            const QuietCallback = struct {
                walker: *ParallelWalker,

                pub fn call(ctx: *@This(), _: reader.StreamingLineReader.Line, _: usize, _: usize) !bool {
                    ctx.walker.out.markMatched();
                    ctx.walker.cancelled.store(true, .release);
                    ctx.walker.done.store(true, .release);
                    return false;
                }
            };
            var callback = QuietCallback{ .walker = self };
            _ = try stream.searchMatcher(
                self.pattern_matcher,
                &callback,
                false,
                false,
                false,
            );
            return;
        }

        if (self.config.count_only) {
            if (try stream.searchCountMatcher(self.pattern_matcher)) |count| {
                if (count > 0 and !(stream.isBinary() and stream.quitsOnBinary())) {
                    try self.out.printFileCount(path, count);
                }
                return;
            }
        }

        // For single-source searches, stream output directly for fast first-result time
        // For multi-file searches, buffer to prevent interleaved output
        if (self.config.is_single_source and !self.config.count_only and !self.config.files_with_matches) {
            const StreamCallback = struct {
                out: *output.Output,
                path: []const u8,
                pattern_matcher: *const matcher_mod.Matcher,

                pub fn call(ctx: *@This(), line: reader.StreamingLineReader.Line, match_start: usize, match_end: usize) !bool {
                    try ctx.out.writeMatchDirect(.{
                        .file_path = ctx.path,
                        .line_number = line.number,
                        .line_content = line.content,
                        .match_start = match_start,
                        .match_end = match_end,
                    }, ctx.pattern_matcher);
                    ctx.out.finishDirectMatch();
                    return true;
                }
            };

            var callback = StreamCallback{ .out = self.out, .path = path, .pattern_matcher = self.pattern_matcher };
            const found = try stream.searchMatcher(
                self.pattern_matcher,
                &callback,
                self.out.lineNumbersEnabled(),
                self.out.colorEnabled(),
                true,
            );
            try self.out.flushDirect();
            if (found) {
                if (stream.binaryByteOffset()) |offset| {
                    try self.out.printBinaryMessage(path, offset, stream.quitsOnBinary());
                }
            }
            return;
        }

        // Buffered path - for multi-file searches or count/files-with-matches modes
        // Output can grow larger than the input when every line matches and a
        // path prefix is added. Keep it out of the reset-only worker arena:
        // ArrayList growth there retains every superseded allocation until the
        // file finishes, causing large allocation and RSS spikes on dense data.
        var file_buf = output.FileBuffer.initResolved(
            std.heap.smp_allocator,
            self.config,
            self.out.colorEnabled(),
            self.out.headingEnabled(),
            self.out.lineNumbersEnabled(),
        );
        defer file_buf.deinit();

        const Callback = struct {
            file_buf: *output.FileBuffer,
            path: []const u8,
            files_with_matches: bool,
            count_only: bool,
            pattern_matcher: *const matcher_mod.Matcher,

            pub fn call(ctx: *@This(), line: reader.StreamingLineReader.Line, match_start: usize, match_end: usize) !bool {
                if (ctx.count_only) {
                    ctx.file_buf.match_count += 1;
                    return true;
                }

                try ctx.file_buf.addMatchWithMatcher(.{
                    .file_path = ctx.path,
                    .line_number = line.number,
                    .line_content = line.content,
                    .match_start = match_start,
                    .match_end = match_end,
                }, ctx.pattern_matcher);
                return !ctx.files_with_matches;
            }
        };

        var callback = Callback{
            .file_buf = &file_buf,
            .path = path,
            .files_with_matches = self.config.files_with_matches,
            .count_only = self.config.count_only,
            .pattern_matcher = self.pattern_matcher,
        };
        const found = try stream.searchMatcher(
            self.pattern_matcher,
            &callback,
            !self.config.count_only and self.out.lineNumbersEnabled(),
            self.out.colorEnabled() and !self.config.count_only and !self.config.files_with_matches,
            !self.config.count_only and !self.config.files_with_matches,
        );

        // Flush all buffered output in one mutex lock
        if (self.config.count_only) {
            if (file_buf.match_count > 0 and !(stream.isBinary() and stream.quitsOnBinary())) {
                try self.out.printFileCount(path, file_buf.match_count);
            }
        } else {
            try self.out.flushFileBuffer(&file_buf);
            if (found and !self.config.files_with_matches) {
                if (stream.binaryByteOffset()) |offset| {
                    try self.out.printBinaryMessage(path, offset, stream.quitsOnBinary());
                }
            }
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
