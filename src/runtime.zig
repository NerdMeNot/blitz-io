//! Blitz-IO Runtime
//!
//! The core runtime that combines:
//! - Coroutine-based task scheduler (work-stealing with Tokio optimizations)
//! - I/O driver (io_uring, kqueue, epoll, IOCP)
//! - Blocking pool (for CPU-intensive work)
//! - Hierarchical timer wheel
//!
//! This runtime is built on the coroutine foundation which provides:
//! - Platform-specific context switching (x86_64, aarch64)
//! - Stack pooling with guard pages
//! - Shield-based cancellation for graceful shutdown
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

// Coroutine system - the new foundation
const coro = struct {
    pub const Scheduler = @import("coroutine/scheduler.zig").Scheduler;
    pub const SchedulerConfig = @import("coroutine/scheduler.zig").Config;
    pub const Backend = @import("coroutine/scheduler.zig").Backend;
    pub const BackendType = @import("coroutine/scheduler.zig").BackendType;
    pub const Header = @import("coroutine/task.zig").Header;
    pub const Task = @import("coroutine/task.zig").Task;
    pub const Coroutine = @import("coroutine/coroutine.zig").Coroutine;
    pub const CoroutineRuntime = @import("coroutine/runtime.zig").Runtime;
    pub const stack_pool = @import("coroutine/stack_pool.zig");
};

const blocking_mod = @import("blocking.zig");
const BlockingPool = blocking_mod.BlockingPool;

const time_mod = @import("time.zig");
pub const Duration = time_mod.Duration;
pub const Instant = time_mod.Instant;

// Re-export backend types for backward compatibility
const backend_mod = @import("backend.zig");

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
/// Now powered by the coroutine-based scheduler with Tokio-grade optimizations.
pub const Runtime = struct {
    const Self = @This();

    allocator: Allocator,
    coro_runtime: *coro.CoroutineRuntime,
    blocking_pool: BlockingPool,
    shutdown: std.atomic.Value(bool),

    /// Initialize the runtime.
    pub fn init(allocator: Allocator, config: Config) !Self {
        // Initialize global stack pool if not already done
        if (coro.stack_pool.getGlobal() == null) {
            coro.stack_pool.initGlobalDefault();
        }

        // Initialize coroutine runtime
        const coro_config = @import("coroutine/runtime.zig").Config{
            .num_workers = config.workers orelse 0,
            .enable_stealing = true,
            .backend_type = config.backend,
        };
        const coro_runtime = try coro.CoroutineRuntime.init(allocator, coro_config);
        errdefer coro_runtime.deinit();

        // Initialize blocking pool (threads spawned lazily)
        const blocking_pool = BlockingPool.init(allocator, .{
            .min_threads = config.blocking_threads,
            .max_threads = config.max_blocking_threads,
        });

        return Self{
            .allocator = allocator,
            .coro_runtime = coro_runtime,
            .blocking_pool = blocking_pool,
            .shutdown = std.atomic.Value(bool).init(false),
        };
    }

    /// Clean up all resources.
    pub fn deinit(self: *Self) void {
        self.shutdown.store(true, .release);
        self.blocking_pool.deinit();
        self.coro_runtime.deinit();
    }

    /// Run an async function to completion.
    /// This is the main entry point for running async code.
    ///
    /// The function receives a Coroutine handle for yielding and async operations.
    pub fn run(self: *Self, comptime func: anytype, args: anytype) !ReturnType(@TypeOf(func), @TypeOf(args)) {
        const Result = ReturnType(@TypeOf(func), @TypeOf(args));

        // Set thread-local runtime
        const prev_runtime = current_runtime;
        current_runtime = self;
        defer current_runtime = prev_runtime;

        // Start blocking pool
        try self.blocking_pool.ensureStarted();

        // If the function doesn't take a Coroutine, wrap it
        const FuncType = @TypeOf(func);
        const func_info = @typeInfo(FuncType).@"fn";

        if (func_info.params.len > 0) {
            const first_param = func_info.params[0];
            if (first_param.type) |T| {
                if (T == *coro.Coroutine) {
                    // Function takes Coroutine - use directly
                    var handle = try self.coro_runtime.spawn(func, args);
                    return handle.join();
                }
            }
        }

        // Function doesn't take Coroutine - wrap it
        const Wrapper = struct {
            fn wrapped(_: *coro.Coroutine) Result {
                return @call(.auto, func, args);
            }
        };

        var handle = try self.coro_runtime.spawn(Wrapper.wrapped, .{});
        return handle.join();
    }

    /// Single iteration of the event loop (poll I/O and timers).
    pub fn tick(self: *Self) !usize {
        // The coroutine scheduler handles I/O polling internally
        // This is mainly for compatibility - returns 0 as polling is automatic
        _ = self;
        return 0;
    }

    /// Get the blocking pool for `io.blocking()` calls.
    pub fn getBlockingPool(self: *Self) *BlockingPool {
        return &self.blocking_pool;
    }

    /// Get the underlying scheduler.
    pub fn getScheduler(self: *Self) *coro.Scheduler {
        return self.coro_runtime.scheduler;
    }

    /// Run a function on the blocking pool.
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

/// Set the current runtime for this thread.
pub fn setCurrentRuntime(rt_ptr: *anyopaque) void {
    current_runtime = @ptrCast(@alignCast(rt_ptr));
}

// ─────────────────────────────────────────────────────────────────────────────
// Public API Functions (usable inside runtime.run())
// ─────────────────────────────────────────────────────────────────────────────

/// Sleep for a duration.
pub fn sleep(duration: Duration) void {
    // TODO: Integrate with coroutine timer wheel for proper async sleep
    // For now, use OS sleep
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

/// Spawn a concurrent task.
/// Returns a JoinHandle that can be used to await the task's result.
pub fn spawn(comptime func: anytype, args: anytype) !JoinHandle(ReturnType(@TypeOf(func), @TypeOf(args))) {
    const rt = runtime();
    const Result = ReturnType(@TypeOf(func), @TypeOf(args));

    // Wrap non-coroutine functions
    const FuncType = @TypeOf(func);
    const func_info = @typeInfo(FuncType).@"fn";

    if (func_info.params.len > 0) {
        const first_param = func_info.params[0];
        if (first_param.type) |T| {
            if (T == *coro.Coroutine) {
                const handle = try rt.coro_runtime.spawn(func, args);
                return JoinHandle(Result){ .inner = handle };
            }
        }
    }

    // Wrap function that doesn't take Coroutine
    const Wrapper = struct {
        fn wrapped(_: *coro.Coroutine) Result {
            return @call(.auto, func, args);
        }
    };

    const handle = try rt.coro_runtime.spawn(Wrapper.wrapped, .{});
    return JoinHandle(Result){ .inner = handle };
}

/// JoinHandle - handle to await a spawned task's result.
pub fn JoinHandle(comptime Output: type) type {
    return struct {
        const Self = @This();

        inner: @import("coroutine/runtime.zig").JoinHandle(Output),

        /// Check if the task is complete
        pub fn isFinished(self: *const Self) bool {
            return self.inner.isDone();
        }

        /// Cancel the task
        pub fn cancel(self: *Self) void {
            self.inner.cancel();
        }

        /// Wait for completion and get result
        pub fn join(self: *Self) !Output {
            return self.inner.join();
        }

        /// Get the output if complete (non-blocking)
        pub fn tryJoin(self: *Self) ?Output {
            if (!self.isFinished()) {
                return null;
            }
            return self.join() catch null;
        }

        /// Drop the join handle
        pub fn deinit(self: *Self) void {
            self.inner.detach();
        }
    };
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

    // Blocking pool threads start lazily
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

test "Runtime - getBlockingPool returns pool" {
    var rt = try Runtime.init(std.testing.allocator, .{
        .workers = 1,
        .blocking_threads = 1,
    });
    defer rt.deinit();

    const pool = rt.getBlockingPool();
    try std.testing.expect(@intFromPtr(pool) != 0);
}

test "Runtime - getScheduler returns scheduler" {
    var rt = try Runtime.init(std.testing.allocator, .{
        .workers = 1,
    });
    defer rt.deinit();

    const scheduler = rt.getScheduler();
    try std.testing.expect(@intFromPtr(scheduler) != 0);
}

test "Runtime - getRuntime outside runtime returns null" {
    try std.testing.expectEqual(@as(?*Runtime, null), getRuntime());
}

test "Runtime - sleep function" {
    const start = std.time.nanoTimestamp();
    sleep(Duration.fromMillis(1));
    const elapsed = std.time.nanoTimestamp() - start;

    // Should have slept at least 1ms
    try std.testing.expect(elapsed >= 500_000);
}

test "Runtime - Config defaults" {
    const config = Config{};

    try std.testing.expectEqual(@as(?usize, null), config.workers);
    try std.testing.expectEqual(@as(usize, 4), config.blocking_threads);
    try std.testing.expectEqual(@as(usize, 512), config.max_blocking_threads);
    try std.testing.expectEqual(@as(?backend_mod.BackendType, null), config.backend);
}

test "Runtime - Duration conversions" {
    const d1 = Duration.fromMillis(1000);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), d1.asNanos());

    const d2 = Duration.fromSecs(2);
    try std.testing.expectEqual(@as(u64, 2_000_000_000), d2.asNanos());
}
