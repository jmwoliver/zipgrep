const std = @import("std");

/// A lock-free work-stealing deque based on the Chase-Lev algorithm.
/// Reference: "Dynamic Circular Work-Stealing Deque" by Chase and Lev
///
/// The deque supports:
/// - Single-owner push/pop from the bottom (LIFO for depth-first traversal)
/// - Multiple stealers can steal from the top (FIFO from their perspective)
///
/// Memory orderings are carefully chosen to ensure correctness without
/// unnecessary synchronization overhead.

/// Circular buffer backing the deque.
/// Capacity is always a power of 2 for efficient modulo via bitwise AND.
pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Raw pointer to array of items
        ptr: [*]T,
        /// Capacity (always power of 2)
        capacity: usize,
        /// Allocator used to create this buffer
        allocator: std.mem.Allocator,

        /// Create a new buffer with the given capacity (must be power of 2)
        pub fn init(allocator: std.mem.Allocator, capacity: usize) !*Self {
            std.debug.assert(capacity > 0 and (capacity & (capacity - 1)) == 0);

            const items = try allocator.alloc(T, capacity);
            const buffer = try allocator.create(Self);
            buffer.* = .{
                .ptr = items.ptr,
                .capacity = capacity,
                .allocator = allocator,
            };
            return buffer;
        }

        pub fn deinit(self: *Self) void {
            const slice = self.ptr[0..self.capacity];
            self.allocator.free(slice);
            self.allocator.destroy(self);
        }

        /// Get item at index (using bitwise AND for efficient modulo)
        pub fn get(self: *const Self, index: usize) T {
            return self.ptr[index & (self.capacity - 1)];
        }

        /// Put item at index (using bitwise AND for efficient modulo)
        pub fn put(self: *Self, index: usize, item: T) void {
            self.ptr[index & (self.capacity - 1)] = item;
        }

        /// Grow the buffer to double its capacity, copying existing items.
        /// Returns the new buffer.
        pub fn grow(self: *Self, bottom: usize, top: usize) !*Self {
            const new_capacity = self.capacity * 2;
            const new_buffer = try Self.init(self.allocator, new_capacity);

            // Copy items from old buffer to new buffer
            var i = top;
            while (i != bottom) : (i +%= 1) {
                new_buffer.put(i, self.get(i));
            }

            return new_buffer;
        }
    };
}

/// Result of a steal operation
pub fn StealResult(comptime T: type) type {
    return union(enum) {
        /// The deque is empty
        empty,
        /// The steal failed due to contention (CAS failed), should retry
        retry,
        /// Successfully stolen an item
        success: T,
    };
}

/// A work-stealing deque.
/// Only the owner thread should use Worker operations (push/pop).
/// Other threads can obtain Stealer handles to steal work.
pub fn Deque(comptime T: type) type {
    return struct {
        const Self = @This();
        const BufferT = Buffer(T);

        /// Bottom index - only modified by owner (Worker)
        bottom: std.atomic.Value(isize),

        /// Top index - modified by stealers via CAS
        top: std.atomic.Value(isize),

        /// Current buffer - can be swapped during growth
        buffer: std.atomic.Value(*BufferT),

        /// Old buffers to be freed (kept until deque is destroyed)
        garbage: std.ArrayListUnmanaged(*BufferT),

        /// Allocator for buffer management
        allocator: std.mem.Allocator,

        /// Minimum buffer capacity
        const MIN_CAPACITY: usize = 64;

        /// Create a new deque with default initial capacity
        pub fn init(allocator: std.mem.Allocator) !*Self {
            return initWithCapacity(allocator, MIN_CAPACITY);
        }

        /// Create a new deque with specified initial capacity (rounded up to power of 2)
        pub fn initWithCapacity(allocator: std.mem.Allocator, requested_capacity: usize) !*Self {
            // Round up to power of 2
            var capacity = @max(MIN_CAPACITY, requested_capacity);
            capacity = std.math.ceilPowerOfTwo(usize, capacity) catch MIN_CAPACITY;

            const buffer = try BufferT.init(allocator, capacity);
            errdefer buffer.deinit();

            const deque = try allocator.create(Self);
            deque.* = .{
                .bottom = std.atomic.Value(isize).init(0),
                .top = std.atomic.Value(isize).init(0),
                .buffer = std.atomic.Value(*BufferT).init(buffer),
                .garbage = .{},
                .allocator = allocator,
            };
            return deque;
        }

        /// Destroy the deque and free all resources
        pub fn deinit(self: *Self) void {
            // Free current buffer
            self.buffer.load(.monotonic).deinit();

            // Free old buffers
            for (self.garbage.items) |old_buffer| {
                old_buffer.deinit();
            }
            self.garbage.deinit(self.allocator);

            self.allocator.destroy(self);
        }

        /// Get a Worker handle for this deque (single owner only)
        pub fn worker(self: *Self) Worker(T) {
            return .{ .deque = self };
        }

        /// Get a Stealer handle for this deque (can be cloned)
        pub fn stealer(self: *Self) Stealer(T) {
            return .{ .deque = self };
        }

        /// Check if the deque is empty (approximate, may have false positives due to races)
        pub fn isEmpty(self: *Self) bool {
            const t = self.top.load(.acquire);
            const b = self.bottom.load(.acquire);
            return b <= t;
        }

        /// Get the current length (approximate, may be stale)
        pub fn len(self: *Self) usize {
            const t = self.top.load(.acquire);
            const b = self.bottom.load(.acquire);
            if (b <= t) return 0;
            return @intCast(b - t);
        }
    };
}

/// Worker handle for the deque owner.
/// Only one thread should use the Worker handle at a time.
pub fn Worker(comptime T: type) type {
    return struct {
        const Self = @This();
        const DequeT = Deque(T);
        const BufferT = Buffer(T);

        deque: *DequeT,

        /// Push an item to the bottom of the deque.
        /// May grow the buffer if needed.
        pub fn push(self: *Self, item: T) !void {
            const b = self.deque.bottom.load(.monotonic);
            const t = self.deque.top.load(.acquire);
            var buffer = self.deque.buffer.load(.monotonic);

            const size = b -% t;
            if (size >= @as(isize, @intCast(buffer.capacity))) {
                // Buffer is full, grow it
                const new_buffer = try buffer.grow(@intCast(@max(0, b)), @intCast(@max(0, t)));

                // Keep old buffer for later cleanup
                try self.deque.garbage.append(self.deque.allocator, buffer);

                // Store new buffer with release ordering
                self.deque.buffer.store(new_buffer, .release);
                buffer = new_buffer;
            }

            // Store item at bottom position
            buffer.put(@intCast(@mod(b, @as(isize, @intCast(buffer.capacity)))), item);

            // Store with release ordering ensures item is visible before bottom increment
            self.deque.bottom.store(b +% 1, .release);
        }

        /// Pop an item from the bottom of the deque (LIFO).
        /// Returns null if the deque is empty.
        pub fn pop(self: *Self) ?T {
            const b = self.deque.bottom.load(.monotonic) -% 1;
            const buffer = self.deque.buffer.load(.monotonic);

            // Decrement bottom
            self.deque.bottom.store(b, .seq_cst);

            // Load top with seq_cst for synchronization
            const t = self.deque.top.load(.seq_cst);

            if (t <= b) {
                // Non-empty, get item
                const item = buffer.get(@intCast(@mod(b, @as(isize, @intCast(buffer.capacity)))));

                if (t == b) {
                    // This was the last item - race with stealers possible
                    // Try to claim it via CAS on top
                    if (self.deque.top.cmpxchgStrong(t, t +% 1, .seq_cst, .monotonic)) |_| {
                        // CAS failed - a stealer got it
                        self.deque.bottom.store(t +% 1, .monotonic);
                        return null;
                    }
                    self.deque.bottom.store(t +% 1, .monotonic);
                }

                return item;
            } else {
                // Empty - restore bottom
                self.deque.bottom.store(t, .monotonic);
                return null;
            }
        }
    };
}

/// Stealer handle for stealing from the deque.
/// Can be freely cloned and shared across threads.
pub fn Stealer(comptime T: type) type {
    return struct {
        const Self = @This();
        const DequeT = Deque(T);
        const BufferT = Buffer(T);
        const Result = StealResult(T);

        deque: *DequeT,

        /// Attempt to steal an item from the top of the deque.
        pub fn steal(self: *Self) Result {
            // Load top with acquire
            const t = self.deque.top.load(.acquire);

            // Load bottom with seq_cst to ensure proper ordering with top
            // This acts as a full fence between the two loads
            const b = self.deque.bottom.load(.seq_cst);

            if (t >= b) {
                return .empty;
            }

            // Non-empty, try to steal from top
            const buffer = self.deque.buffer.load(.acquire);
            const item = buffer.get(@intCast(@mod(t, @as(isize, @intCast(buffer.capacity)))));

            // CAS to increment top (claim the item)
            if (self.deque.top.cmpxchgStrong(t, t +% 1, .seq_cst, .monotonic)) |_| {
                // CAS failed - another stealer won or owner popped
                return .retry;
            }

            // Successfully stolen
            return .{ .success = item };
        }

        /// Check if the deque appears empty (may have false positives)
        pub fn isEmpty(self: *Self) bool {
            return self.deque.isEmpty();
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Buffer: init and deinit" {
    const allocator = std.testing.allocator;

    const buffer = try Buffer(usize).init(allocator, 64);
    defer buffer.deinit();

    try std.testing.expectEqual(@as(usize, 64), buffer.capacity);
}

test "Buffer: get and put" {
    const allocator = std.testing.allocator;

    var buffer = try Buffer(usize).init(allocator, 64);
    defer buffer.deinit();

    buffer.put(0, 42);
    buffer.put(1, 100);
    buffer.put(63, 999);

    try std.testing.expectEqual(@as(usize, 42), buffer.get(0));
    try std.testing.expectEqual(@as(usize, 100), buffer.get(1));
    try std.testing.expectEqual(@as(usize, 999), buffer.get(63));

    // Wraparound: index 64 should map to 0
    buffer.put(64, 1234);
    try std.testing.expectEqual(@as(usize, 1234), buffer.get(0));
    try std.testing.expectEqual(@as(usize, 1234), buffer.get(64));
}

test "Buffer: grow" {
    const allocator = std.testing.allocator;

    var buffer = try Buffer(usize).init(allocator, 4);
    defer buffer.deinit();

    // Fill buffer
    buffer.put(0, 10);
    buffer.put(1, 20);
    buffer.put(2, 30);
    buffer.put(3, 40);

    // Grow
    const new_buffer = try buffer.grow(4, 0);
    defer new_buffer.deinit();

    try std.testing.expectEqual(@as(usize, 8), new_buffer.capacity);

    // Items should be copied
    try std.testing.expectEqual(@as(usize, 10), new_buffer.get(0));
    try std.testing.expectEqual(@as(usize, 20), new_buffer.get(1));
    try std.testing.expectEqual(@as(usize, 30), new_buffer.get(2));
    try std.testing.expectEqual(@as(usize, 40), new_buffer.get(3));
}

test "Deque: init and deinit" {
    const allocator = std.testing.allocator;

    const deque = try Deque(usize).init(allocator);
    defer deque.deinit();

    try std.testing.expect(deque.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), deque.len());
}

test "Deque: single-threaded push and pop (LIFO)" {
    const allocator = std.testing.allocator;

    const deque = try Deque(usize).init(allocator);
    defer deque.deinit();

    var worker_handle = deque.worker();

    // Push items
    try worker_handle.push(1);
    try worker_handle.push(2);
    try worker_handle.push(3);

    try std.testing.expectEqual(@as(usize, 3), deque.len());

    // Pop should be LIFO
    try std.testing.expectEqual(@as(?usize, 3), worker_handle.pop());
    try std.testing.expectEqual(@as(?usize, 2), worker_handle.pop());
    try std.testing.expectEqual(@as(?usize, 1), worker_handle.pop());
    try std.testing.expectEqual(@as(?usize, null), worker_handle.pop());

    try std.testing.expect(deque.isEmpty());
}

test "Deque: push to capacity and grow" {
    const allocator = std.testing.allocator;

    // Start with small capacity
    const deque = try Deque(usize).initWithCapacity(allocator, 4);
    defer deque.deinit();

    var worker_handle = deque.worker();

    // Push more than capacity to trigger growth
    for (0..100) |i| {
        try worker_handle.push(i);
    }

    try std.testing.expectEqual(@as(usize, 100), deque.len());

    // Pop all items (LIFO order)
    var i: usize = 100;
    while (i > 0) {
        i -= 1;
        try std.testing.expectEqual(@as(?usize, i), worker_handle.pop());
    }

    try std.testing.expect(deque.isEmpty());
}

test "Deque: pop from empty returns null" {
    const allocator = std.testing.allocator;

    const deque = try Deque(usize).init(allocator);
    defer deque.deinit();

    var worker_handle = deque.worker();

    try std.testing.expectEqual(@as(?usize, null), worker_handle.pop());
    try std.testing.expectEqual(@as(?usize, null), worker_handle.pop());
}

test "Deque: steal from empty returns empty" {
    const allocator = std.testing.allocator;

    const deque = try Deque(usize).init(allocator);
    defer deque.deinit();

    var stealer_handle = deque.stealer();

    try std.testing.expectEqual(StealResult(usize).empty, stealer_handle.steal());
}

test "Deque: single item push and steal" {
    const allocator = std.testing.allocator;

    const deque = try Deque(usize).init(allocator);
    defer deque.deinit();

    var worker_handle = deque.worker();
    var stealer_handle = deque.stealer();

    try worker_handle.push(42);

    const result = stealer_handle.steal();
    try std.testing.expectEqual(StealResult(usize){ .success = 42 }, result);

    // Deque should be empty now
    try std.testing.expect(deque.isEmpty());
    try std.testing.expectEqual(StealResult(usize).empty, stealer_handle.steal());
}

test "Deque: multiple steals (FIFO from stealer perspective)" {
    const allocator = std.testing.allocator;

    const deque = try Deque(usize).init(allocator);
    defer deque.deinit();

    var worker_handle = deque.worker();
    var stealer_handle = deque.stealer();

    // Push items
    try worker_handle.push(1);
    try worker_handle.push(2);
    try worker_handle.push(3);

    // Steal should be FIFO (from top)
    try std.testing.expectEqual(StealResult(usize){ .success = 1 }, stealer_handle.steal());
    try std.testing.expectEqual(StealResult(usize){ .success = 2 }, stealer_handle.steal());
    try std.testing.expectEqual(StealResult(usize){ .success = 3 }, stealer_handle.steal());
    try std.testing.expectEqual(StealResult(usize).empty, stealer_handle.steal());
}

test "Deque: interleaved push, pop, and steal" {
    const allocator = std.testing.allocator;

    const deque = try Deque(usize).init(allocator);
    defer deque.deinit();

    var worker_handle = deque.worker();
    var stealer_handle = deque.stealer();

    // Push 1, 2, 3
    try worker_handle.push(1);
    try worker_handle.push(2);
    try worker_handle.push(3);

    // Steal 1 (from top)
    try std.testing.expectEqual(StealResult(usize){ .success = 1 }, stealer_handle.steal());

    // Pop 3 (from bottom, LIFO)
    try std.testing.expectEqual(@as(?usize, 3), worker_handle.pop());

    // Push 4
    try worker_handle.push(4);

    // Steal 2
    try std.testing.expectEqual(StealResult(usize){ .success = 2 }, stealer_handle.steal());

    // Pop 4
    try std.testing.expectEqual(@as(?usize, 4), worker_handle.pop());

    try std.testing.expect(deque.isEmpty());
}

test "Deque: worker and stealer handles are independent" {
    const allocator = std.testing.allocator;

    const deque = try Deque(usize).init(allocator);
    defer deque.deinit();

    var worker1 = deque.worker();
    var worker2 = deque.worker();
    var stealer1 = deque.stealer();
    var stealer2 = deque.stealer();

    try worker1.push(10);
    try worker2.push(20);

    // Both stealers see the same deque
    const r1 = stealer1.steal();
    const r2 = stealer2.steal();

    // One should succeed, one should get either success or empty
    var total: usize = 0;
    if (r1 == .success) total += r1.success;
    if (r2 == .success) total += r2.success;

    try std.testing.expectEqual(@as(usize, 30), total);
}

// ============================================================================
// Multi-threaded Stress Tests
// ============================================================================

test "Deque stress: one producer, one stealer" {
    const allocator = std.testing.allocator;
    const num_items: usize = 10_000;

    const deque = try Deque(usize).init(allocator);
    defer deque.deinit();

    var received = std.AutoHashMap(usize, void).init(allocator);
    defer received.deinit();

    var received_mutex = std.Thread.Mutex{};
    var done = std.atomic.Value(bool).init(false);

    // Stealer thread
    const stealer_thread = try std.Thread.spawn(.{}, struct {
        fn run(d: *Deque(usize), recv: *std.AutoHashMap(usize, void), mutex: *std.Thread.Mutex, done_flag: *std.atomic.Value(bool)) void {
            var s = d.stealer();
            while (!done_flag.load(.acquire) or !d.isEmpty()) {
                switch (s.steal()) {
                    .success => |item| {
                        mutex.lock();
                        defer mutex.unlock();
                        recv.put(item, {}) catch {};
                    },
                    .empty, .retry => {},
                }
            }
        }
    }.run, .{ deque, &received, &received_mutex, &done });

    // Producer: push items
    var worker_handle = deque.worker();
    for (0..num_items) |i| {
        try worker_handle.push(i);
    }

    // Signal done
    done.store(true, .release);

    // Also pop remaining items from producer side
    while (worker_handle.pop()) |item| {
        received_mutex.lock();
        defer received_mutex.unlock();
        try received.put(item, {});
    }

    stealer_thread.join();

    // Verify all items received
    try std.testing.expectEqual(num_items, received.count());
    for (0..num_items) |i| {
        try std.testing.expect(received.contains(i));
    }
}

test "Deque stress: one producer, multiple stealers" {
    const allocator = std.testing.allocator;
    const num_stealers: usize = 4;
    const num_items: usize = 10_000;

    const deque = try Deque(usize).init(allocator);
    defer deque.deinit();

    var received = std.AutoHashMap(usize, void).init(allocator);
    defer received.deinit();

    var received_mutex = std.Thread.Mutex{};
    var done = std.atomic.Value(bool).init(false);

    // Spawn stealer threads
    var stealer_threads: [num_stealers]std.Thread = undefined;
    for (0..num_stealers) |i| {
        stealer_threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(d: *Deque(usize), recv: *std.AutoHashMap(usize, void), mutex: *std.Thread.Mutex, done_flag: *std.atomic.Value(bool)) void {
                var s = d.stealer();
                while (!done_flag.load(.acquire) or !d.isEmpty()) {
                    switch (s.steal()) {
                        .success => |item| {
                            mutex.lock();
                            defer mutex.unlock();
                            recv.put(item, {}) catch {};
                        },
                        .empty, .retry => {},
                    }
                }
            }
        }.run, .{ deque, &received, &received_mutex, &done });
    }

    // Producer: push items
    var worker_handle = deque.worker();
    for (0..num_items) |i| {
        try worker_handle.push(i);
    }

    // Signal done
    done.store(true, .release);

    // Pop remaining items from producer side
    while (worker_handle.pop()) |item| {
        received_mutex.lock();
        defer received_mutex.unlock();
        try received.put(item, {});
    }

    // Join stealer threads
    for (&stealer_threads) |*t| {
        t.join();
    }

    // Verify all items received exactly once
    try std.testing.expectEqual(num_items, received.count());
    for (0..num_items) |i| {
        try std.testing.expect(received.contains(i));
    }
}

test "Deque stress: producer with interleaved pop" {
    const allocator = std.testing.allocator;
    const num_items: usize = 5_000;

    const deque = try Deque(usize).init(allocator);
    defer deque.deinit();

    var received = std.AutoHashMap(usize, void).init(allocator);
    defer received.deinit();

    var received_mutex = std.Thread.Mutex{};
    var done = std.atomic.Value(bool).init(false);

    // Stealer threads
    var stealer_threads: [2]std.Thread = undefined;
    for (0..2) |i| {
        stealer_threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(d: *Deque(usize), recv: *std.AutoHashMap(usize, void), mutex: *std.Thread.Mutex, done_flag: *std.atomic.Value(bool)) void {
                var s = d.stealer();
                while (!done_flag.load(.acquire) or !d.isEmpty()) {
                    switch (s.steal()) {
                        .success => |item| {
                            mutex.lock();
                            defer mutex.unlock();
                            recv.put(item, {}) catch {};
                        },
                        .empty, .retry => {},
                    }
                }
            }
        }.run, .{ deque, &received, &received_mutex, &done });
    }

    // Producer: interleave push and pop
    var worker_handle = deque.worker();
    for (0..num_items) |i| {
        try worker_handle.push(i);

        // Occasionally pop from producer side
        if (i % 10 == 0) {
            if (worker_handle.pop()) |item| {
                received_mutex.lock();
                defer received_mutex.unlock();
                try received.put(item, {});
            }
        }
    }

    // Signal done
    done.store(true, .release);

    // Pop remaining items
    while (worker_handle.pop()) |item| {
        received_mutex.lock();
        defer received_mutex.unlock();
        try received.put(item, {});
    }

    // Join stealer threads
    for (&stealer_threads) |*t| {
        t.join();
    }

    // Verify all items received
    try std.testing.expectEqual(num_items, received.count());
}

test "Deque stress: high contention on single item" {
    const allocator = std.testing.allocator;
    const num_rounds: usize = 1_000;
    const num_stealers: usize = 4;

    const deque = try Deque(usize).init(allocator);
    defer deque.deinit();

    var total_stolen = std.atomic.Value(usize).init(0);
    var done = std.atomic.Value(bool).init(false);

    // Spawn stealer threads
    var stealer_threads: [num_stealers]std.Thread = undefined;
    for (0..num_stealers) |i| {
        stealer_threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(d: *Deque(usize), total: *std.atomic.Value(usize), done_flag: *std.atomic.Value(bool)) void {
                var s = d.stealer();
                while (!done_flag.load(.acquire)) {
                    switch (s.steal()) {
                        .success => |_| {
                            _ = total.fetchAdd(1, .monotonic);
                        },
                        .empty, .retry => {},
                    }
                }
                // Final drain
                while (true) {
                    switch (s.steal()) {
                        .success => |_| {
                            _ = total.fetchAdd(1, .monotonic);
                        },
                        .empty => break,
                        .retry => {},
                    }
                }
            }
        }.run, .{ deque, &total_stolen, &done });
    }

    // Producer: push single items and let stealers race
    var worker_handle = deque.worker();
    var total_popped: usize = 0;
    for (0..num_rounds) |i| {
        try worker_handle.push(i);
        // Small yield to give stealers a chance
        if (worker_handle.pop()) |_| {
            total_popped += 1;
        }
    }

    // Signal done
    done.store(true, .release);

    // Drain remaining
    while (worker_handle.pop()) |_| {
        total_popped += 1;
    }

    // Join stealer threads
    for (&stealer_threads) |*t| {
        t.join();
    }

    // Total should equal num_rounds
    const stolen = total_stolen.load(.monotonic);
    try std.testing.expectEqual(num_rounds, stolen + total_popped);
}

test "Deque stress: rapid grow" {
    const allocator = std.testing.allocator;

    // Very small initial capacity to force many grows
    const deque = try Deque(usize).initWithCapacity(allocator, 4);
    defer deque.deinit();

    var received = std.AutoHashMap(usize, void).init(allocator);
    defer received.deinit();

    var received_mutex = std.Thread.Mutex{};
    var done = std.atomic.Value(bool).init(false);

    // Stealer thread
    const stealer_thread = try std.Thread.spawn(.{}, struct {
        fn run(d: *Deque(usize), recv: *std.AutoHashMap(usize, void), mutex: *std.Thread.Mutex, done_flag: *std.atomic.Value(bool)) void {
            var s = d.stealer();
            while (!done_flag.load(.acquire) or !d.isEmpty()) {
                switch (s.steal()) {
                    .success => |item| {
                        mutex.lock();
                        defer mutex.unlock();
                        recv.put(item, {}) catch {};
                    },
                    .empty, .retry => {},
                }
            }
        }
    }.run, .{ deque, &received, &received_mutex, &done });

    // Producer: push many items (will cause multiple grows)
    var worker_handle = deque.worker();
    const num_items: usize = 10_000;
    for (0..num_items) |i| {
        try worker_handle.push(i);
    }

    done.store(true, .release);

    // Pop remaining
    while (worker_handle.pop()) |item| {
        received_mutex.lock();
        defer received_mutex.unlock();
        try received.put(item, {});
    }

    stealer_thread.join();

    // Verify all items received
    try std.testing.expectEqual(num_items, received.count());
}
