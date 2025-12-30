const std = @import("std");

/// A simple thread pool for parallel task execution with proper work tracking
pub fn ThreadPool(comptime Context: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        threads: []std.Thread,
        queue: WorkQueue,
        context: *Context,
        running: std.atomic.Value(bool),
        pending_work: std.atomic.Value(isize), // Tracks pending + in-progress work

        pub const TaskData = union(enum) {
            file: []const u8,
            directory: struct {
                path: []const u8,
                depth: usize,
            },
        };

        const Task = struct {
            data: TaskData,
            next: ?*Task = null,
        };

        const WorkQueue = struct {
            head: ?*Task,
            tail: ?*Task,
            mutex: std.Thread.Mutex,
            cond: std.Thread.Condition,
            allocator: std.mem.Allocator,

            fn init(allocator: std.mem.Allocator) WorkQueue {
                return .{
                    .head = null,
                    .tail = null,
                    .mutex = .{},
                    .cond = .{},
                    .allocator = allocator,
                };
            }

            fn push(self: *WorkQueue, task_data: TaskData) !void {
                const task = try self.allocator.create(Task);
                task.* = .{ .data = task_data };

                self.mutex.lock();
                defer self.mutex.unlock();

                if (self.tail) |tail| {
                    tail.next = task;
                    self.tail = task;
                } else {
                    self.head = task;
                    self.tail = task;
                }

                self.cond.signal();
            }

            fn pop(self: *WorkQueue, running: *std.atomic.Value(bool)) ?TaskData {
                self.mutex.lock();
                defer self.mutex.unlock();

                while (self.head == null and running.load(.acquire)) {
                    self.cond.timedWait(&self.mutex, 50 * std.time.ns_per_ms) catch {};
                }

                if (self.head) |head| {
                    const data = head.data;
                    self.head = head.next;
                    if (self.head == null) {
                        self.tail = null;
                    }
                    self.allocator.destroy(head);
                    return data;
                }

                return null;
            }

            fn broadcast(self: *WorkQueue) void {
                self.cond.broadcast();
            }
        };

        pub fn init(
            allocator: std.mem.Allocator,
            num_threads: usize,
            context: *Context,
        ) !Self {
            const actual_threads = @max(1, num_threads);
            const threads = try allocator.alloc(std.Thread, actual_threads);
            errdefer allocator.free(threads);

            var pool = Self{
                .allocator = allocator,
                .threads = threads,
                .queue = WorkQueue.init(allocator),
                .context = context,
                .running = std.atomic.Value(bool).init(true),
                .pending_work = std.atomic.Value(isize).init(0),
            };

            // Spawn worker threads
            for (threads) |*thread| {
                thread.* = try std.Thread.spawn(.{}, workerThread, .{&pool});
            }

            return pool;
        }

        pub fn deinit(self: *Self) void {
            self.shutdown();
            self.allocator.free(self.threads);
        }

        /// Submit work and increment pending counter
        pub fn submit(self: *Self, task_data: TaskData) !void {
            _ = self.pending_work.fetchAdd(1, .acq_rel);
            try self.queue.push(task_data);
        }

        pub fn shutdown(self: *Self) void {
            self.running.store(false, .release);
            self.queue.broadcast();

            for (self.threads) |thread| {
                thread.join();
            }
        }

        /// Wait for all pending work to complete
        pub fn wait(self: *Self) void {
            while (self.pending_work.load(.acquire) > 0) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
        }

        fn workerThread(pool: *Self) void {
            while (pool.running.load(.acquire) or pool.pending_work.load(.acquire) > 0) {
                if (pool.queue.pop(&pool.running)) |task| {
                    // Process the task using the context
                    pool.context.processTask(task, pool) catch {};

                    // Decrement pending work counter
                    _ = pool.pending_work.fetchSub(1, .acq_rel);
                } else if (pool.pending_work.load(.acquire) == 0) {
                    break;
                }
            }
        }
    };
}

// Tests
test "thread pool basic" {
    const TestContext = struct {
        counter: std.atomic.Value(usize),

        const Pool = ThreadPool(@This());

        fn processTask(self: *@This(), task: Pool.TaskData, pool: *Pool) !void {
            _ = pool;
            _ = task;
            _ = self.counter.fetchAdd(1, .monotonic);
        }
    };

    var ctx = TestContext{
        .counter = std.atomic.Value(usize).init(0),
    };

    var pool = try ThreadPool(TestContext).init(std.testing.allocator, 4, &ctx);
    defer pool.deinit();

    // Submit some tasks
    for (0..100) |_| {
        try pool.submit(.{ .file = "test.txt" });
    }

    pool.wait();

    try std.testing.expectEqual(@as(usize, 100), ctx.counter.load(.monotonic));
}
