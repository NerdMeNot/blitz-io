//! blitz-io Executor Module
//!
//! The executor is responsible for running async tasks to completion.
//! It manages:
//! - Worker threads for parallel task execution
//! - Task queues (local and global)
//! - Work stealing for load balancing
//! - Timer wheel for sleep/timeout operations
//! - Integration with I/O backends
//!
//! ## Quick Start
//!
//! ```zig
//! const blitz_io = @import("blitz-io");
//!
//! pub fn main() !void {
//!     var executor = try blitz_io.Executor.init(allocator, .{});
//!     defer executor.deinit();
//!
//!     try executor.start();
//!
//!     // Spawn async tasks...
//!
//!     executor.shutdown();
//! }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

// ─────────────────────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────────────────────

pub const task = @import("executor/task.zig");
pub const scheduler = @import("executor/scheduler.zig");
pub const worker = @import("executor/worker.zig");
pub const local_queue = @import("executor/local_queue.zig");
pub const global_queue = @import("executor/global_queue.zig");
pub const timer = @import("executor/timer.zig");
pub const pool = @import("executor/pool.zig");

/// Task header - the core task type visible to the scheduler
pub const Header = task.Header;

/// Waker - handle to wake a task when I/O is ready
pub const Waker = task.Waker;

/// Poll result from task execution
pub const PollResult = task.PollResult;

/// Type-erased task wrapper
pub const RawTask = task.RawTask;

/// Join handle for awaiting task results
pub const JoinHandle = task.JoinHandle;

/// Scheduler configuration
pub const SchedulerConfig = scheduler.Config;

/// The main scheduler
pub const Scheduler = scheduler.Scheduler;

/// Worker thread
pub const Worker = worker.Worker;

/// Local task queue (lock-free SPSC)
pub const LocalQueue = local_queue.LocalQueue;

/// Global task queue (MPMC)
pub const GlobalQueue = global_queue.GlobalQueue;

/// Timer wheel for efficient timeout handling
pub const TimerWheel = timer.TimerWheel;

/// Timer entry
pub const TimerEntry = timer.TimerEntry;

// I/O Backend (owned by scheduler for centralized platform detection)
// Access backend types directly via blitz-io.backend module
const backend_mod = @import("backend.zig");

/// Detect the best backend for this platform
pub const detectBestBackend = backend_mod.detectBestBackend;

/// Generate a unique task ID
pub const nextTaskId = task.nextTaskId;

/// Get the current worker ID
pub const getCurrentWorkerId = worker.getCurrentWorkerId;

/// Check if on a worker thread
pub const isWorkerThread = worker.isWorkerThread;

/// Lock-free object pool for O(1) allocation
/// Zig advantage: explicit allocator control enables specialized pooling
pub const ObjectPool = pool.ObjectPool;

// ─────────────────────────────────────────────────────────────────────────────
// Executor - High-Level Interface
// ─────────────────────────────────────────────────────────────────────────────

/// Configuration for the executor
pub const Config = struct {
    /// Number of worker threads (null = auto-detect based on CPU cores)
    num_workers: ?usize = null,

    /// Scheduling strategy
    strategy: SchedulerConfig.Strategy = .work_stealing,

    /// Enable thread affinity (pin workers to cores)
    thread_affinity: bool = false,

    /// I/O backend configuration (optional)
    io_config: ?IoConfig = null,

    pub const IoConfig = struct {
        /// Backend type (null = auto-detect)
        backend_type: ?BackendType = null,

        /// Size of the I/O ring/queue
        ring_size: u32 = 256,
    };

    pub const BackendType = enum {
        io_uring,
        kqueue,
        epoll,
        iocp,
        poll,
        auto,
    };
};

/// The main executor combining scheduler and I/O
pub const Executor = struct {
    const Self = @This();

    /// Memory allocator
    allocator: Allocator,

    /// Task scheduler
    sched: Scheduler,

    /// Timer wheel
    timers: TimerWheel,

    /// Configuration
    config: Config,

    /// Create a new executor
    pub fn init(allocator: Allocator, config: Config) !Self {
        const sched_config = SchedulerConfig{
            .num_workers = config.num_workers,
            .strategy = config.strategy,
            .thread_affinity = config.thread_affinity,
        };

        return Self{
            .allocator = allocator,
            .sched = try Scheduler.init(allocator, sched_config),
            .timers = TimerWheel.init(allocator),
            .config = config,
        };
    }

    /// Clean up executor resources
    pub fn deinit(self: *Self) void {
        self.timers.deinit();
        self.sched.deinit();
    }

    /// Start the executor
    pub fn start(self: *Self) !void {
        try self.sched.start();
    }

    /// Signal shutdown
    pub fn shutdown(self: *Self) void {
        self.sched.shutdown();
    }

    /// Spawn a task
    pub fn spawn(self: *Self, task_header: *Header) void {
        self.sched.spawn(task_header);
    }

    /// Create and spawn a task from a function
    /// Returns a join handle for awaiting the result
    pub fn spawnTask(
        self: *Self,
        comptime F: type,
        comptime Output: type,
        func: F,
    ) !JoinHandle(Output) {
        const Task = RawTask(F, Output);
        const t = try Task.init(self.allocator, func, nextTaskId());

        // Set up scheduler callback
        t.setScheduler(self, scheduleCallback);

        // Spawn it
        self.spawn(t.getHeader());

        return JoinHandle(Output).init(t.getHeader());
    }

    fn scheduleCallback(ctx: *anyopaque, header: *Header) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.sched.spawn(header);
    }

    /// Schedule a sleep timer
    pub fn sleepNs(self: *Self, duration_ns: u64, task_header: *Header) *TimerEntry {
        return timer.sleep(&self.timers, duration_ns, task_header);
    }

    /// Get the number of worker threads
    pub fn numWorkers(self: *const Self) usize {
        return self.sched.workers.len;
    }

    /// Get executor metrics
    pub fn getMetrics(self: *const Self) Metrics {
        const sched_metrics = self.sched.getMetrics();
        return Metrics{
            .scheduler = sched_metrics,
            .active_timers = self.timers.len(),
        };
    }

    pub const Metrics = struct {
        scheduler: Scheduler.Metrics,
        active_timers: usize,
    };
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "executor modules compile" {
    _ = task;
    _ = scheduler;
    _ = worker;
    _ = local_queue;
    _ = global_queue;
    _ = timer;
    _ = pool;
}
