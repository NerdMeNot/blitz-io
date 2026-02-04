//! Blitz-IO Runtime
//!
//! The core runtime that combines:
//! - Task scheduler (work-stealing executor)
//! - I/O driver (io_uring, kqueue, epoll, etc.)
//! - Blocking pool (for CPU-intensive work)
//! - Timer wheel
//!
//! Usage:
//! ```zig
//! var rt = try Runtime.init(allocator, .{});
//! defer rt.deinit();
//!
//! try rt.run(myAsyncMain);
//! ```

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const backend_mod = @import("backend.zig");
const Backend = backend_mod.Backend;
const Completion = backend_mod.Completion;

const io_driver_mod = @import("io_driver.zig");
const IoDriver = io_driver_mod.IoDriver;

const executor_mod = @import("executor.zig");
const Scheduler = executor_mod.Scheduler;
const SchedulerConfig = executor_mod.scheduler.Config;
const TimerWheel = executor_mod.TimerWheel;

const blocking_mod = @import("blocking.zig");
const BlockingPool = blocking_mod.BlockingPool;

const time_mod = @import("time.zig");
pub const Duration = time_mod.Duration;
pub const Instant = time_mod.Instant;

// ─────────────────────────────────────────────────────────────────────────────
// Configuration
// ─────────────────────────────────────────────────────────────────────────────

/// Runtime configuration.
pub const Config = struct {
    /// Number of I/O worker threads (null = CPU count).
    workers: ?usize = null,

    /// Number of blocking pool threads.
    blocking_threads: usize = 4,

    /// Maximum blocking pool threads.
    max_blocking_threads: usize = 512,

    /// I/O backend type (null = auto-detect).
    backend: ?backend_mod.BackendType = null,
};

// ─────────────────────────────────────────────────────────────────────────────
// Runtime
// ─────────────────────────────────────────────────────────────────────────────

/// The async I/O runtime.
pub const Runtime = struct {
    const Self = @This();

    allocator: Allocator,
    scheduler: Scheduler,
    io_driver: IoDriver,
    timers: TimerWheel,
    blocking_pool: BlockingPool,
    completions: []Completion,

    shutdown: std.atomic.Value(bool),

    /// Initialize the runtime.
    pub fn init(allocator: Allocator, config: Config) !Self {
        // Initialize scheduler (which now owns the I/O backend)
        const sched_config = SchedulerConfig{
            .num_workers = config.workers,
            .strategy = .work_stealing,
            .backend = config.backend, // Pass through to scheduler
            .max_io_completions = 256,
        };
        var scheduler = try Scheduler.init(allocator, sched_config);
        errdefer scheduler.deinit();

        // Initialize blocking pool (threads spawned lazily)
        const blocking_pool = BlockingPool.init(allocator, .{
            .min_threads = config.blocking_threads,
            .max_threads = config.max_blocking_threads,
        });

        // Allocate completion buffer
        const completions = try allocator.alloc(Completion, 256);
        errdefer allocator.free(completions);

        // Create a temporary self to get scheduler's backend pointer
        var self = Self{
            .allocator = allocator,
            .scheduler = scheduler,
            .io_driver = undefined, // Will be set below
            .timers = TimerWheel.init(allocator),
            .blocking_pool = blocking_pool,
            .completions = completions,
            .shutdown = std.atomic.Value(bool).init(false),
        };

        // Initialize IoDriver with pointer to scheduler's backend
        self.io_driver = try IoDriver.init(allocator, self.scheduler.getBackend(), 256);

        return self;
    }

    /// Clean up all resources.
    pub fn deinit(self: *Self) void {
        self.shutdown.store(true, .release);

        self.io_driver.deinit();
        self.blocking_pool.deinit();
        self.timers.deinit();
        // Scheduler deinit also cleans up its owned backend
        self.scheduler.deinit();
        self.allocator.free(self.completions);
    }

    /// Run an async function to completion.
    pub fn run(self: *Self, comptime func: anytype, args: anytype) !ReturnType(@TypeOf(func), @TypeOf(args)) {
        // Set thread-local runtime
        const prev_runtime = current_runtime;
        current_runtime = self;
        defer current_runtime = prev_runtime;

        // Start scheduler workers
        try self.scheduler.start();

        // Start blocking pool (now that self is in final location)
        try self.blocking_pool.ensureStarted();

        // Run the main function
        // For now, just call it directly (synchronous)
        // TODO: Proper async task creation and event loop
        const result = @call(.auto, func, args);

        // Note: Don't shutdown here - let deinit() handle it properly
        // This avoids leaving threads in limbo

        return result;
    }

    /// Single iteration of the event loop.
    pub fn tick(self: *Self) !usize {
        // Update time and process expired timers
        self.timers.updateTime();
        _ = executor_mod.timer.pollAndProcess(&self.timers);

        // Poll I/O (non-blocking) - backend is owned by scheduler
        const count = try self.scheduler.getBackend().wait(self.completions, 0);

        // Process completions
        for (self.completions[0..count]) |comp| {
            self.processCompletion(comp);
        }

        return count;
    }

    /// Process an I/O completion.
    fn processCompletion(self: *Self, comp: Completion) void {
        _ = self;
        _ = comp;
        // TODO: Wake the task that was waiting on this I/O
    }

    /// Get the blocking pool for `io.blocking()` calls.
    pub fn getBlockingPool(self: *Self) *BlockingPool {
        return &self.blocking_pool;
    }

    /// Get the I/O backend (owned by scheduler).
    pub fn getBackend(self: *Self) *Backend {
        return self.scheduler.getBackend();
    }

    /// Get the scheduler.
    pub fn getScheduler(self: *Self) *Scheduler {
        return &self.scheduler;
    }

    /// Get the I/O driver.
    pub fn getIoDriver(self: *Self) *IoDriver {
        return &self.io_driver;
    }

    /// Run a function on the blocking pool.
    /// Use this for CPU-intensive work or blocking I/O that would
    /// otherwise stall the async event loop.
    ///
    /// Example:
    /// ```zig
    /// const result = try runtime.spawnBlocking(expensiveComputation, .{data});
    /// ```
    pub fn spawnBlocking(
        self: *Self,
        comptime func: anytype,
        args: anytype,
    ) !BlockingResult(@TypeOf(func)) {
        const handle = try blocking_mod.runBlocking(&self.blocking_pool, func, args);
        return handle.wait();
    }

    fn BlockingResult(comptime Func: type) type {
        const info = @typeInfo(Func);
        const ret = if (info == .pointer)
            @typeInfo(info.pointer.child).@"fn".return_type.?
        else
            info.@"fn".return_type.?;

        if (@typeInfo(ret) == .error_union) {
            return @typeInfo(ret).error_union.payload;
        }
        return ret;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Thread-Local Runtime Access
// ─────────────────────────────────────────────────────────────────────────────

/// Thread-local runtime reference.
threadlocal var current_runtime: ?*Runtime = null;

/// Get the current runtime (if running inside one).
pub fn getRuntime() ?*Runtime {
    return current_runtime;
}

/// Get the current runtime or panic.
pub fn runtime() *Runtime {
    return current_runtime orelse @panic("Not running inside a blitz-io runtime");
}

// ─────────────────────────────────────────────────────────────────────────────
// Public API Functions (usable inside runtime.run())
// ─────────────────────────────────────────────────────────────────────────────

/// Sleep for a duration.
pub fn sleep(duration: Duration) void {
    // For now, just use OS sleep
    // TODO: Integrate with timer wheel for async sleep
    std.Thread.sleep(duration.asNanos());
}

/// Run a function on the blocking pool.
/// Use this for CPU-intensive or blocking work.
pub fn blocking(comptime func: anytype, args: anytype) !ReturnType(@TypeOf(func), @TypeOf(args)) {
    const rt = runtime();
    const pool = rt.getBlockingPool();

    const handle = try blocking_mod.runBlocking(pool, func, args);
    return handle.wait();
}

/// Spawn a concurrent task (fire and forget).
pub fn spawn(comptime func: anytype, args: anytype) void {
    _ = func;
    _ = args;
    // TODO: Create task and submit to scheduler
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

fn ReturnType(comptime Func: type, comptime Args: type) type {
    _ = Args;
    const info = @typeInfo(Func);
    if (info == .pointer) {
        return @typeInfo(info.pointer.child).@"fn".return_type.?;
    }
    return info.@"fn".return_type.?;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "Runtime - init and deinit" {
    var rt = try Runtime.init(std.testing.allocator, .{
        .workers = 1,
        .blocking_threads = 1,
    });
    defer rt.deinit();

    // Blocking pool threads start lazily (on run() or ensureStarted())
    try std.testing.expectEqual(@as(usize, 0), rt.getBlockingPool().threadCount());
}

test "Runtime - run simple function" {
    var rt = try Runtime.init(std.testing.allocator, .{
        .workers = 1,
        .blocking_threads = 1,
    });
    defer rt.deinit();

    const result = try rt.run(struct {
        fn main() i32 {
            return 42;
        }
    }.main, .{});

    try std.testing.expectEqual(@as(i32, 42), result);
}

test "Runtime - init with custom config" {
    var rt = try Runtime.init(std.testing.allocator, .{
        .workers = 2,
        .blocking_threads = 2,
        .max_blocking_threads = 10,
    });
    defer rt.deinit();

    // Scheduler should have 2 workers
    const metrics = rt.scheduler.getMetrics();
    try std.testing.expectEqual(@as(usize, 2), metrics.num_workers);
}

test "Runtime - getBlockingPool returns pool" {
    var rt = try Runtime.init(std.testing.allocator, .{
        .workers = 1,
        .blocking_threads = 1,
    });
    defer rt.deinit();

    const pool = rt.getBlockingPool();
    try std.testing.expect(@intFromPtr(pool) != 0);
}

test "Runtime - getBackend returns backend" {
    var rt = try Runtime.init(std.testing.allocator, .{
        .workers = 1,
    });
    defer rt.deinit();

    const backend = rt.getBackend();
    try std.testing.expect(@intFromPtr(backend) != 0);
}

test "Runtime - getScheduler returns scheduler" {
    var rt = try Runtime.init(std.testing.allocator, .{
        .workers = 1,
    });
    defer rt.deinit();

    const scheduler = rt.getScheduler();
    try std.testing.expect(@intFromPtr(scheduler) != 0);
}

test "Runtime - getIoDriver returns driver" {
    var rt = try Runtime.init(std.testing.allocator, .{
        .workers = 1,
    });
    defer rt.deinit();

    const driver = rt.getIoDriver();
    try std.testing.expect(@intFromPtr(driver) != 0);
}

test "Runtime - run with arguments" {
    var rt = try Runtime.init(std.testing.allocator, .{
        .workers = 1,
    });
    defer rt.deinit();

    const result = try rt.run(struct {
        fn compute(a: i32, b: i32) i32 {
            return a + b;
        }
    }.compute, .{ 10, 32 });

    try std.testing.expectEqual(@as(i32, 42), result);
}

test "Runtime - tick with no pending I/O" {
    var rt = try Runtime.init(std.testing.allocator, .{
        .workers = 1,
    });
    defer rt.deinit();

    // tick should return 0 when no I/O is pending
    const count = try rt.tick();
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "Runtime - getRuntime outside runtime returns null" {
    try std.testing.expectEqual(@as(?*Runtime, null), getRuntime());
}

test "Runtime - getRuntime inside runtime returns self" {
    var rt = try Runtime.init(std.testing.allocator, .{
        .workers = 1,
    });
    defer rt.deinit();

    var captured_runtime: ?*Runtime = null;

    _ = try rt.run(struct {
        fn checkRuntime(out: *?*Runtime) void {
            out.* = getRuntime();
        }
    }.checkRuntime, .{&captured_runtime});

    try std.testing.expect(captured_runtime != null);
    try std.testing.expectEqual(&rt, captured_runtime.?);
}

test "Runtime - sleep function" {
    // Just test that it doesn't crash
    const start = std.time.nanoTimestamp();
    sleep(Duration.fromMillis(1));
    const elapsed = std.time.nanoTimestamp() - start;

    // Should have slept at least 1ms (1_000_000 ns)
    try std.testing.expect(elapsed >= 500_000); // Allow some tolerance
}

test "Runtime - Config defaults" {
    const config = Config{};

    try std.testing.expectEqual(@as(?usize, null), config.workers);
    try std.testing.expectEqual(@as(usize, 4), config.blocking_threads);
    try std.testing.expectEqual(@as(usize, 512), config.max_blocking_threads);
    try std.testing.expectEqual(@as(?backend_mod.BackendType, null), config.backend);
}

test "Runtime - shutdown flag" {
    var rt = try Runtime.init(std.testing.allocator, .{
        .workers = 1,
    });
    defer rt.deinit();

    try std.testing.expect(!rt.shutdown.load(.acquire));

    // Trigger shutdown via deinit will set the flag
    // (We can't test this directly without calling deinit)
}

test "Runtime - multiple sequential run calls" {
    var rt = try Runtime.init(std.testing.allocator, .{
        .workers = 1,
        .blocking_threads = 1,
    });
    defer rt.deinit();

    // First run
    const result1 = try rt.run(struct {
        fn compute() i32 {
            return 10;
        }
    }.compute, .{});

    // Second run (same runtime)
    const result2 = try rt.run(struct {
        fn compute() i32 {
            return 20;
        }
    }.compute, .{});

    // Third run
    const result3 = try rt.run(struct {
        fn compute() i32 {
            return 30;
        }
    }.compute, .{});

    try std.testing.expectEqual(@as(i32, 10), result1);
    try std.testing.expectEqual(@as(i32, 20), result2);
    try std.testing.expectEqual(@as(i32, 30), result3);
}

test "Runtime - multi-runtime separate instances" {
    // Create two separate runtime instances
    var rt1 = try Runtime.init(std.testing.allocator, .{
        .workers = 1,
        .blocking_threads = 1,
    });
    defer rt1.deinit();

    var rt2 = try Runtime.init(std.testing.allocator, .{
        .workers = 1,
        .blocking_threads = 1,
    });
    defer rt2.deinit();

    // Run on both (sequentially)
    const result1 = try rt1.run(struct {
        fn compute() i32 {
            return 100;
        }
    }.compute, .{});

    const result2 = try rt2.run(struct {
        fn compute() i32 {
            return 200;
        }
    }.compute, .{});

    try std.testing.expectEqual(@as(i32, 100), result1);
    try std.testing.expectEqual(@as(i32, 200), result2);
}

test "Runtime - blocking pool is accessible" {
    var rt = try Runtime.init(std.testing.allocator, .{
        .workers = 1,
        .blocking_threads = 2,
    });
    defer rt.deinit();

    // Verify blocking pool is properly initialized
    const pool = rt.getBlockingPool();
    try std.testing.expect(@intFromPtr(pool) != 0);

    // Initially no threads are spawned (lazy)
    try std.testing.expectEqual(@as(usize, 0), pool.threadCount());
}

test "Runtime - getRuntime thread-local restored after run" {
    try std.testing.expectEqual(@as(?*Runtime, null), getRuntime());

    var rt = try Runtime.init(std.testing.allocator, .{
        .workers = 1,
    });
    defer rt.deinit();

    // Before run, should be null
    try std.testing.expectEqual(@as(?*Runtime, null), getRuntime());

    _ = try rt.run(struct {
        fn check() bool {
            // Inside run, should have runtime
            return getRuntime() != null;
        }
    }.check, .{});

    // After run, should be null again (restored)
    try std.testing.expectEqual(@as(?*Runtime, null), getRuntime());
}

test "Runtime - nested getRuntime calls" {
    var rt = try Runtime.init(std.testing.allocator, .{
        .workers = 1,
    });
    defer rt.deinit();

    var inner_check: bool = false;
    var outer_check: bool = false;

    _ = try rt.run(struct {
        fn outer(inner_ptr: *bool, outer_ptr: *bool) void {
            outer_ptr.* = getRuntime() != null;
            inner(inner_ptr);
        }
        fn inner(inner_ptr: *bool) void {
            inner_ptr.* = getRuntime() != null;
        }
    }.outer, .{ &inner_check, &outer_check });

    try std.testing.expect(outer_check);
    try std.testing.expect(inner_check);
}

test "Runtime - Duration conversions" {
    // Test Duration type used by runtime sleep
    const d1 = Duration.fromMillis(1000);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), d1.asNanos());

    const d2 = Duration.fromSecs(2);
    try std.testing.expectEqual(@as(u64, 2_000_000_000), d2.asNanos());

    const d3 = Duration.fromNanos(500_000_000);
    try std.testing.expectEqual(@as(u64, 500_000_000), d3.asNanos());
}
