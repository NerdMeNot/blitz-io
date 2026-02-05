//! Runtime - High-Level Async Runtime
//!
//! The Runtime is the top-level entry point for blitz-io. It manages:
//! - The scheduler with worker threads
//! - Stack pool for coroutine stacks
//! - I/O driver integration (future)
//! - Timer management (future)
//!
//! Usage:
//! ```zig
//! const rt = try Runtime.init(allocator, .{});
//! defer rt.deinit();
//!
//! // Spawn tasks
//! const handle = try rt.spawn(myAsyncFn, .{arg1, arg2});
//!
//! // Block on a task
//! const result = try rt.blockOn(myAsyncFn, .{arg1, arg2});
//!
//! // Or run until all tasks complete
//! rt.runUntilComplete();
//! ```
//!
//! Reference: tokio/tokio/src/runtime/runtime.rs

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const scheduler_mod = @import("scheduler.zig");
const Scheduler = scheduler_mod.Scheduler;
const Worker = scheduler_mod.Worker;

// Re-export I/O types for convenience
pub const Backend = scheduler_mod.Backend;
pub const BackendType = scheduler_mod.BackendType;
pub const BackendConfig = scheduler_mod.BackendConfig;
pub const Operation = scheduler_mod.Operation;
pub const Completion = scheduler_mod.Completion;

const task_mod = @import("task.zig");
const Header = task_mod.Header;
const Task = task_mod.Task;
const State = task_mod.State;

const coroutine_mod = @import("coroutine.zig");
const Coroutine = coroutine_mod.Coroutine;

const stack_pool = @import("stack_pool.zig");

// ═══════════════════════════════════════════════════════════════════════════════
// Configuration
// ═══════════════════════════════════════════════════════════════════════════════

pub const Config = struct {
    /// Number of worker threads (0 = auto based on CPU count)
    num_workers: usize = 0,

    /// Enable work stealing between workers
    enable_stealing: bool = true,

    /// Stack pool configuration
    stack_config: stack_pool.Config = .{},

    /// I/O backend type (null = auto-detect best for platform)
    backend_type: ?scheduler_mod.BackendType = null,

    /// Maximum I/O completions to process per tick
    max_io_completions: u32 = 256,

    pub fn toSchedulerConfig(self: Config) scheduler_mod.Config {
        return .{
            .num_workers = self.num_workers,
            .enable_stealing = self.enable_stealing,
            .stack_config = self.stack_config,
            .backend_type = self.backend_type,
            .max_io_completions = self.max_io_completions,
        };
    }
};

pub const default_config = Config{};

// ═══════════════════════════════════════════════════════════════════════════════
// JoinHandle - Handle to a spawned task
// ═══════════════════════════════════════════════════════════════════════════════

/// Handle to a spawned task, allows waiting for completion
pub fn JoinHandle(comptime T: type) type {
    return struct {
        const Self = @This();

        header: *Header,
        runtime: *Runtime,
        /// Pointer to the result storage (inside the Task struct)
        result_ptr: *?T,

        /// Wait for the task to complete and get the result
        pub fn join(self: *Self) !T {
            // Busy wait for now - will be replaced with proper parking
            while (!self.header.isComplete()) {
                std.Thread.yield() catch {};
            }

            // Get the result before cleanup (only for non-void)
            const result = if (T == void) {} else self.result_ptr.*;

            // Clean up our reference
            if (self.header.unref()) {
                self.header.drop();
            }

            // Return the result
            if (T == void) {
                return;
            } else {
                // If task completed but no result, it was likely cancelled
                if (result) |r| {
                    return r;
                } else {
                    return error.TaskCancelled;
                }
            }
        }

        /// Check if the task is complete
        pub fn isDone(self: *const Self) bool {
            return self.header.isComplete();
        }

        /// Request cancellation of the task
        pub fn cancel(self: *Self) void {
            _ = self.header.cancel();
        }

        /// Detach the handle (task continues running, result is discarded)
        pub fn detach(self: *Self) void {
            if (self.header.unref()) {
                self.header.drop();
            }
            self.* = undefined;
        }
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
// Runtime
// ═══════════════════════════════════════════════════════════════════════════════

/// The main async runtime
pub const Runtime = struct {
    const Self = @This();

    /// Configuration
    config: Config,

    /// The scheduler
    scheduler: *Scheduler,

    /// Whether the runtime has been started
    started: bool = false,

    /// Allocator for runtime resources
    allocator: Allocator,

    /// Initialize a new runtime
    pub fn init(allocator: Allocator, config: Config) !*Self {
        // Initialize global stack pool if not already done
        if (stack_pool.getGlobal() == null) {
            stack_pool.initGlobal(config.stack_config);
        }

        const scheduler = try Scheduler.init(allocator, config.toSchedulerConfig());
        errdefer scheduler.deinit();

        const self = try allocator.create(Self);
        self.* = .{
            .config = config,
            .scheduler = scheduler,
            .allocator = allocator,
        };

        return self;
    }

    /// Initialize with default configuration
    pub fn initDefault(allocator: Allocator) !*Self {
        return init(allocator, default_config);
    }

    /// Deinitialize the runtime
    pub fn deinit(self: *Self) void {
        if (self.started) {
            self.scheduler.shutdownAndWait();
        }
        self.scheduler.deinit();
        self.allocator.destroy(self);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Lifecycle
    // ─────────────────────────────────────────────────────────────────────────

    /// Start the runtime (spawns worker threads)
    pub fn start(self: *Self) !void {
        if (self.started) return;
        try self.scheduler.start();
        self.started = true;
    }

    /// Shutdown the runtime and wait for all tasks to complete
    pub fn shutdown(self: *Self) void {
        if (!self.started) return;
        self.scheduler.shutdownAndWait();
        self.started = false;
    }

    /// Check if runtime is running
    pub fn isRunning(self: *const Self) bool {
        return self.started and self.scheduler.isRunning();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Task Spawning
    // ─────────────────────────────────────────────────────────────────────────

    /// Spawn a task onto the runtime
    pub fn spawn(
        self: *Self,
        comptime func: anytype,
        args: anytype,
    ) !JoinHandle(@typeInfo(@TypeOf(func)).@"fn".return_type.?) {
        const F = @TypeOf(func);
        const Args = @TypeOf(args);
        const TaskType = Task(F, Args);
        const Result = @typeInfo(F).@"fn".return_type.?;

        // Ensure runtime is started
        if (!self.started) {
            try self.start();
        }

        // Create the task
        const task = try TaskType.create(self.allocator, func, args);

        // Set up scheduler callback
        task.setScheduler(self.scheduler, scheduleCallback);

        // Get pointer to result storage before spawning
        const result_ptr: *?Result = &task.result;

        // Spawn onto scheduler
        self.scheduler.spawn(&task.header);

        return .{
            .header = &task.header,
            .runtime = self,
            .result_ptr = result_ptr,
        };
    }

    /// Spawn a task and detach it (fire-and-forget)
    pub fn spawnDetached(
        self: *Self,
        comptime func: anytype,
        args: anytype,
    ) !void {
        var handle = try self.spawn(func, args);
        handle.detach();
    }

    /// Block the current thread until the given function completes
    pub fn blockOn(
        self: *Self,
        comptime func: anytype,
        args: anytype,
    ) !@typeInfo(@TypeOf(func)).@"fn".return_type.? {
        var handle = try self.spawn(func, args);
        return handle.join();
    }

    // Scheduler callback for re-scheduling tasks
    fn scheduleCallback(sched_ptr: *anyopaque, header: *Header) void {
        const sched: *Scheduler = @ptrCast(@alignCast(sched_ptr));
        sched.spawn(header);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // I/O Operations
    // ─────────────────────────────────────────────────────────────────────────

    /// Submit an I/O operation to the backend
    pub fn submitIo(self: *Self, op: Operation) !@import("../backend.zig").SubmissionId {
        return self.scheduler.submitIo(op);
    }

    /// Submit multiple I/O operations
    pub fn submitIoBatch(self: *Self, ops: []const Operation) !void {
        return self.scheduler.submitIoBatch(ops);
    }

    /// Get the active I/O backend type
    pub fn getBackendType(self: *const Self) BackendType {
        return self.scheduler.getBackendType();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Statistics
    // ─────────────────────────────────────────────────────────────────────────

    pub const Stats = struct {
        total_spawned: u64,
        num_workers: usize,
        io_completions: u64,
        timers_processed: u64,
        is_running: bool,
    };

    pub fn getStats(self: *const Self) Stats {
        return .{
            .total_spawned = self.scheduler.total_spawned.load(.acquire),
            .num_workers = self.scheduler.workers.len,
            .io_completions = self.scheduler.io_completions_processed.load(.acquire),
            .timers_processed = self.scheduler.timers_processed.load(.acquire),
            .is_running = self.isRunning(),
        };
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Convenience Functions
// ═══════════════════════════════════════════════════════════════════════════════

/// Thread-local runtime pointer
threadlocal var current_runtime: ?*Runtime = null;

/// Get the current runtime (if in a task context)
pub fn current() ?*Runtime {
    return current_runtime;
}

/// Set the current runtime (internal use)
pub fn setCurrent(rt: ?*Runtime) void {
    current_runtime = rt;
}

/// Yield control back to the scheduler.
/// Must be called from within a task.
pub fn yield() void {
    if (coroutine_mod.current()) |c| {
        c.yield();
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

test "Runtime - create and destroy" {
    const allocator = std.testing.allocator;

    const rt = try Runtime.init(allocator, .{ .num_workers = 1 });
    defer rt.deinit();

    try std.testing.expect(!rt.started);
}

test "Runtime - start and shutdown" {
    const allocator = std.testing.allocator;

    const rt = try Runtime.init(allocator, .{ .num_workers = 2 });
    defer rt.deinit();

    try rt.start();
    // Wait for workers to be ready (proper synchronization, no arbitrary sleep)
    rt.scheduler.waitForWorkersReady();

    try std.testing.expect(rt.isRunning());

    rt.shutdown();
    try std.testing.expect(!rt.isRunning());
}

test "Runtime - spawn simple task" {
    const allocator = std.testing.allocator;

    const rt = try Runtime.init(allocator, .{ .num_workers = 1 });
    defer rt.deinit();

    const TestFn = struct {
        fn run(_: *Coroutine) void {
            // Do nothing
        }
    };

    var handle = try rt.spawn(TestFn.run, .{});

    // Wait for completion (consumes the handle)
    try handle.join();

    // Note: After join(), the handle is consumed and cannot be used
}

test "Runtime - spawn multiple tasks" {
    const allocator = std.testing.allocator;

    const rt = try Runtime.init(allocator, .{ .num_workers = 2 });
    defer rt.deinit();

    const TestFn = struct {
        fn run(_: *Coroutine) void {}
    };

    var handles: [10]JoinHandle(void) = undefined;
    for (&handles) |*h| {
        h.* = try rt.spawn(TestFn.run, .{});
    }

    for (&handles) |*h| {
        try h.join();
    }

    const stats = rt.getStats();
    try std.testing.expectEqual(@as(u64, 10), stats.total_spawned);
}

test "Runtime - task with yielding" {
    const allocator = std.testing.allocator;

    const rt = try Runtime.init(allocator, .{ .num_workers = 1 });
    defer rt.deinit();

    var counter: std.atomic.Value(i32) = std.atomic.Value(i32).init(0);

    const TestFn = struct {
        fn run(coro: *Coroutine, cnt: *std.atomic.Value(i32)) void {
            // Increment counter
            _ = cnt.fetchAdd(1, .seq_cst);

            // Yield back to scheduler
            coro.yield();

            // Increment again after resume
            _ = cnt.fetchAdd(1, .seq_cst);

            // Yield again
            coro.yield();

            // Final increment
            _ = cnt.fetchAdd(1, .seq_cst);
        }
    };

    var handle = try rt.spawn(TestFn.run, .{&counter});
    try handle.join();

    // After completion, counter should be 3
    try std.testing.expectEqual(@as(i32, 3), counter.load(.seq_cst));
}
