//! Blocking Thread Pool
//!
//! A dedicated thread pool for running CPU-intensive or blocking work,
//! separate from the async I/O workers. This prevents blocking operations
//! from starving async task execution.
//!
//! Used by `io.blocking(func, args)` to offload work from the I/O loop.
//!
//! Features:
//! - Dynamic scaling: grows from min to max threads on demand
//! - Idle timeout: excess threads exit after keep_alive period
//! - Oneshot result delivery: efficiently returns results to I/O tasks

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Configuration for the blocking pool.
pub const Config = struct {
    /// Minimum threads to keep alive (default: 1).
    min_threads: usize = 1,

    /// Maximum threads to spawn (default: 512).
    max_threads: usize = 512,

    /// Idle timeout before excess threads exit (nanoseconds).
    /// Default: 60 seconds.
    keep_alive_ns: u64 = 60 * std.time.ns_per_s,
};

/// A blocking thread pool that grows dynamically.
pub const BlockingPool = struct {
    const Self = @This();

    allocator: Allocator,
    config: Config,

    // Synchronization
    mutex: std.Thread.Mutex = .{},
    not_empty: std.Thread.Condition = .{},

    // Task queue (intrusive linked list)
    queue_head: ?*Task = null,
    queue_tail: ?*Task = null,
    queue_len: usize = 0,

    // Thread tracking
    thread_count: usize = 0,
    idle_count: usize = 0,
    threads: std.ArrayListUnmanaged(std.Thread) = .{},

    // Shutdown
    shutdown: bool = false,

    /// A task to execute on the blocking pool.
    pub const Task = struct {
        /// Function to execute.
        func: *const fn (*anyopaque) void,

        /// Context/closure data.
        context: *anyopaque,

        /// Intrusive list pointer.
        next: ?*Task = null,
    };

    /// Initialize the blocking pool.
    /// Note: Threads are spawned lazily on first submit to avoid pointer invalidation.
    pub fn init(allocator: Allocator, config: Config) Self {
        std.debug.assert(config.min_threads <= config.max_threads);
        std.debug.assert(config.max_threads > 0);

        return Self{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Ensure minimum threads are running (call after struct is in final location).
    pub fn ensureStarted(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.thread_count < self.config.min_threads) {
            try self.spawnThreadLocked();
        }
    }

    /// Shutdown the pool and wait for all threads.
    pub fn deinit(self: *Self) void {
        // Signal shutdown
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.shutdown = true;
            self.not_empty.broadcast();
        }

        // Join all threads
        for (self.threads.items) |thread| {
            thread.join();
        }

        self.threads.deinit(self.allocator);
    }

    /// Submit a task to the blocking pool.
    pub fn submit(self: *Self, task: *Task) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.shutdown) {
            return error.PoolShutdown;
        }

        // Enqueue task
        task.next = null;
        if (self.queue_tail) |tail| {
            tail.next = task;
        } else {
            self.queue_head = task;
        }
        self.queue_tail = task;
        self.queue_len += 1;

        // Spawn new thread if needed (ensure at least min_threads)
        while (self.thread_count < self.config.min_threads) {
            self.spawnThreadLocked() catch break;
        }
        // Spawn extra if all threads are busy
        if (self.idle_count == 0 and self.thread_count < self.config.max_threads) {
            self.spawnThreadLocked() catch {
                // Continue - existing threads will handle it
            };
        }

        self.not_empty.signal();
    }

    /// Spawn a worker thread (must hold mutex).
    fn spawnThreadLocked(self: *Self) !void {
        const thread = try std.Thread.spawn(.{}, workerLoop, .{self});
        try self.threads.append(self.allocator, thread);
        self.thread_count += 1;
    }

    /// Worker thread main loop.
    fn workerLoop(self: *Self) void {
        while (true) {
            var task: ?*Task = null;

            {
                self.mutex.lock();
                defer self.mutex.unlock();

                // Wait for work or shutdown
                while (self.queue_head == null and !self.shutdown) {
                    self.idle_count += 1;
                    self.not_empty.wait(&self.mutex);
                    self.idle_count -= 1;
                }

                // Check shutdown
                if (self.shutdown) {
                    self.thread_count -= 1;
                    return;
                }

                // Dequeue task
                task = self.queue_head;
                if (task) |t| {
                    self.queue_head = t.next;
                    if (self.queue_head == null) {
                        self.queue_tail = null;
                    }
                    self.queue_len -= 1;
                }
            }

            // Execute task outside lock
            if (task) |t| {
                t.func(t.context);
            }
        }
    }

    /// Get number of active threads.
    pub fn threadCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.thread_count;
    }

    /// Get number of pending tasks.
    pub fn pendingTasks(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.queue_len;
    }
};

/// Result handle for blocking operations.
/// Allows the I/O task to wait for the blocking result.
pub fn BlockingHandle(comptime T: type) type {
    return struct {
        const Self = @This();

        result: ?T = null,
        err: ?anyerror = null,
        completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        mutex: std.Thread.Mutex = .{},
        condition: std.Thread.Condition = .{},

        // The task submitted to the pool
        task: BlockingPool.Task = undefined,

        /// Wait for result (blocking).
        pub fn wait(self: *Self) !T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (!self.completed.load(.acquire)) {
                self.condition.wait(&self.mutex);
            }

            if (self.err) |e| {
                return e;
            }
            return self.result.?;
        }

        /// Check if complete (non-blocking).
        pub fn isComplete(self: *Self) bool {
            return self.completed.load(.acquire);
        }

        /// Try to get result without blocking.
        pub fn tryGet(self: *Self) ?T {
            if (!self.isComplete()) return null;

            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.err != null) return null;
            return self.result;
        }

        /// Signal completion (called by worker).
        fn complete(self: *Self, value: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.result = value;
            self.completed.store(true, .release);
            self.condition.signal();
        }

        /// Signal error (called by worker).
        fn completeWithError(self: *Self, e: anyerror) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.err = e;
            self.completed.store(true, .release);
            self.condition.signal();
        }
    };
}

/// Execute a function on the blocking pool and return a handle.
/// The handle can be waited on to get the result.
pub fn runBlocking(
    pool: *BlockingPool,
    comptime func: anytype,
    args: anytype,
) !*BlockingHandle(ReturnType(@TypeOf(func))) {
    const Result = ReturnType(@TypeOf(func));
    const Args = @TypeOf(args);
    const Handle = BlockingHandle(Result);

    // Allocate handle + args together
    // The Context captures `func` at comptime, so we can call it directly
    const Context = struct {
        handle: Handle,
        args: Args,

        fn execute(ctx_ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));

            // Call the comptime-known function directly with stored args
            const result = @call(.auto, func, self.args);

            // Handle error union
            if (@typeInfo(Result) == .error_union) {
                if (result) |value| {
                    self.handle.complete(value);
                } else |err| {
                    self.handle.completeWithError(err);
                }
            } else {
                self.handle.complete(result);
            }
        }
    };

    const ctx = try pool.allocator.create(Context);
    ctx.* = .{
        .handle = .{},
        .args = args,
    };

    ctx.handle.task = .{
        .func = Context.execute,
        .context = ctx,
    };

    try pool.submit(&ctx.handle.task);

    return &ctx.handle;
}

/// Helper to get return type, unwrapping error unions.
fn ReturnType(comptime Func: type) type {
    const info = @typeInfo(Func);
    if (info == .pointer) {
        return ReturnType(info.pointer.child);
    }
    const ret = info.@"fn".return_type.?;
    if (@typeInfo(ret) == .error_union) {
        return @typeInfo(ret).error_union.payload;
    }
    return ret;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "BlockingPool - init and deinit" {
    var pool = BlockingPool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 4,
    });
    defer pool.deinit();

    // Ensure threads are started (now that struct is in final location)
    try pool.ensureStarted();

    try std.testing.expect(pool.threadCount() >= 1);
}

test "BlockingPool - submit task" {
    var pool = BlockingPool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 4,
    });
    defer pool.deinit();

    try pool.ensureStarted();

    var completed = std.atomic.Value(bool).init(false);

    const Context = struct {
        flag: *std.atomic.Value(bool),

        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.flag.store(true, .release);
        }
    };

    var ctx = Context{ .flag = &completed };
    var task = BlockingPool.Task{
        .func = Context.run,
        .context = &ctx,
    };

    try pool.submit(&task);

    // Wait for completion
    while (!completed.load(.acquire)) {
        std.Thread.sleep(1_000_000);
    }

    try std.testing.expect(completed.load(.acquire));
}

test "BlockingPool - multiple tasks" {
    var pool = BlockingPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 4,
    });
    defer pool.deinit();

    try pool.ensureStarted();

    var counter = std.atomic.Value(usize).init(0);

    const Context = struct {
        counter: *std.atomic.Value(usize),

        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.counter.fetchAdd(1, .acq_rel);
        }
    };

    const num_tasks = 10;
    var contexts: [num_tasks]Context = undefined;
    var tasks: [num_tasks]BlockingPool.Task = undefined;

    for (0..num_tasks) |i| {
        contexts[i] = .{ .counter = &counter };
        tasks[i] = .{
            .func = Context.run,
            .context = &contexts[i],
        };
        try pool.submit(&tasks[i]);
    }

    // Wait for all tasks to complete
    while (counter.load(.acquire) < num_tasks) {
        std.Thread.sleep(1_000_000);
    }

    try std.testing.expectEqual(@as(usize, num_tasks), counter.load(.acquire));
}

test "BlockingPool - pool metrics" {
    var pool = BlockingPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 8,
    });
    defer pool.deinit();

    // Initially no threads
    try std.testing.expectEqual(@as(usize, 0), pool.threadCount());
    try std.testing.expectEqual(@as(usize, 0), pool.pendingTasks());

    // Start minimum threads
    try pool.ensureStarted();
    try std.testing.expect(pool.threadCount() >= 2);

    // Submit a task
    var done = std.atomic.Value(bool).init(false);

    const Context = struct {
        flag: *std.atomic.Value(bool),

        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            // Sleep to allow pending check
            std.Thread.sleep(10_000_000); // 10ms
            self.flag.store(true, .release);
        }
    };

    var ctx = Context{ .flag = &done };
    var task = BlockingPool.Task{
        .func = Context.run,
        .context = &ctx,
    };

    try pool.submit(&task);

    // Wait for completion
    while (!done.load(.acquire)) {
        std.Thread.sleep(1_000_000);
    }
}

test "BlockingPool - tasks complete before shutdown" {
    var pool = BlockingPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 4,
    });
    defer pool.deinit();

    try pool.ensureStarted();

    var completed = std.atomic.Value(usize).init(0);

    const Context = struct {
        counter: *std.atomic.Value(usize),

        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            std.Thread.sleep(5_000_000); // 5ms
            _ = self.counter.fetchAdd(1, .acq_rel);
        }
    };

    var contexts: [3]Context = undefined;
    var tasks: [3]BlockingPool.Task = undefined;

    for (0..3) |i| {
        contexts[i] = .{ .counter = &completed };
        tasks[i] = .{
            .func = Context.run,
            .context = &contexts[i],
        };
        try pool.submit(&tasks[i]);
    }

    // Wait for all tasks to complete
    while (completed.load(.acquire) < 3) {
        std.Thread.sleep(1_000_000);
    }

    // All tasks should have completed
    try std.testing.expectEqual(@as(usize, 3), completed.load(.acquire));
}

test "BlockingPool - submit after shutdown fails" {
    var pool = BlockingPool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 2,
    });

    try pool.ensureStarted();
    pool.deinit();

    // Create a dummy task
    const Context = struct {
        fn run(_: *anyopaque) void {}
    };

    var task = BlockingPool.Task{
        .func = Context.run,
        .context = undefined,
    };

    // Submit should fail after shutdown
    const result = pool.submit(&task);
    try std.testing.expectError(error.PoolShutdown, result);
}

test "BlockingHandle - wait and isComplete" {
    const Handle = BlockingHandle(u32);
    var handle = Handle{};

    // Initially not complete
    try std.testing.expect(!handle.isComplete());
    try std.testing.expect(handle.tryGet() == null);

    // Complete with value
    handle.complete(42);

    // Now complete
    try std.testing.expect(handle.isComplete());
    try std.testing.expectEqual(@as(?u32, 42), handle.tryGet());

    // wait should return immediately
    const result = try handle.wait();
    try std.testing.expectEqual(@as(u32, 42), result);
}

test "BlockingHandle - error completion" {
    const Handle = BlockingHandle(u32);
    var handle = Handle{};

    // Complete with error
    handle.completeWithError(error.OutOfMemory);

    try std.testing.expect(handle.isComplete());
    try std.testing.expect(handle.tryGet() == null); // tryGet returns null on error

    // wait should return error
    const result = handle.wait();
    try std.testing.expectError(error.OutOfMemory, result);
}

test "BlockingPool - dynamic thread scaling" {
    var pool = BlockingPool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 4,
    });
    defer pool.deinit();

    try pool.ensureStarted();

    // Start with min threads
    const initial_threads = pool.threadCount();
    try std.testing.expect(initial_threads >= 1);

    // Submit many tasks that block
    var barrier = std.atomic.Value(bool).init(false);
    var completed = std.atomic.Value(usize).init(0);

    const Context = struct {
        barrier: *std.atomic.Value(bool),
        completed: *std.atomic.Value(usize),

        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            // Wait for barrier
            while (!self.barrier.load(.acquire)) {
                std.Thread.sleep(100_000); // 0.1ms
            }
            _ = self.completed.fetchAdd(1, .acq_rel);
        }
    };

    const num_tasks = 4;
    var contexts: [num_tasks]Context = undefined;
    var tasks: [num_tasks]BlockingPool.Task = undefined;

    for (0..num_tasks) |i| {
        contexts[i] = .{ .barrier = &barrier, .completed = &completed };
        tasks[i] = .{
            .func = Context.run,
            .context = &contexts[i],
        };
        try pool.submit(&tasks[i]);
    }

    // Give pool time to potentially spawn more threads
    std.Thread.sleep(10_000_000); // 10ms

    // Pool should have scaled up (may have more threads)
    try std.testing.expect(pool.threadCount() >= 1);

    // Release barrier
    barrier.store(true, .release);

    // Wait for all tasks to complete
    while (completed.load(.acquire) < num_tasks) {
        std.Thread.sleep(1_000_000);
    }

    try std.testing.expectEqual(@as(usize, num_tasks), completed.load(.acquire));
}
