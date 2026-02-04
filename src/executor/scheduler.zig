//! Task Scheduler
//!
//! The scheduler coordinates:
//! - Worker thread management
//! - Task spawning and scheduling
//! - Work distribution (local vs global queue)
//! - I/O integration for async operations
//!
//! Scheduling Strategies:
//! - WorkStealing: Tasks can be stolen between workers
//! - ThreadPerCore: Tasks stay on their spawning worker (better cache locality)
//! - SingleThreaded: All tasks run on one thread (for debugging or simple use)
//!
//! Reference: tokio/src/runtime/scheduler/multi_thread/mod.rs

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const task_mod = @import("task.zig");
const Header = task_mod.Header;
const Waker = task_mod.Waker;
const Worker = @import("worker.zig").Worker;
const SharedState = @import("worker.zig").SharedState;
const IdleState = @import("worker.zig").IdleState;
const LocalQueue = @import("local_queue.zig").LocalQueue;
const GlobalQueue = @import("global_queue.zig").GlobalQueue;
const ShardedGlobalQueue = @import("global_queue.zig").ShardedGlobalQueue;
const worker_mod = @import("worker.zig");

// I/O Backend - centralized here so executor owns the I/O driver
const backend_mod = @import("../backend.zig");
const Backend = backend_mod.Backend;
const BackendType = backend_mod.BackendType;
const BackendConfig = backend_mod.Config;

/// Scheduler configuration
pub const Config = struct {
    /// Number of worker threads (null = auto-detect)
    num_workers: ?usize = null,

    /// Scheduling strategy
    strategy: Strategy = .work_stealing,

    /// Enable thread affinity
    thread_affinity: bool = false,

    /// Stack size for worker threads (bytes)
    stack_size: ?usize = null,

    /// Name prefix for worker threads
    thread_name_prefix: []const u8 = "blitz-worker",

    /// High water mark for backpressure (tasks per worker)
    /// When queue depth exceeds this, spawnWithBackpressure returns .backpressure
    backpressure_threshold: usize = 1024,

    /// I/O backend type (null = auto-detect best for platform)
    backend: ?BackendType = null,

    /// Maximum I/O completions to process per tick
    max_io_completions: u32 = 256,

    pub const Strategy = enum {
        work_stealing,
        thread_per_core,
        single_threaded,
    };
};

/// Result of spawn operation with backpressure awareness
pub const SpawnResult = enum {
    /// Task was successfully scheduled
    ok,
    /// Queue depth is high, caller should slow down
    backpressure,
    /// Task was rejected (cancelled or already scheduled)
    rejected,
};

/// The main scheduler
pub const Scheduler = struct {
    const Self = @This();

    /// Allocator for scheduler resources
    allocator: Allocator,

    /// Worker threads
    workers: []Worker,

    /// Shared state
    shared: SharedState,

    /// Configuration
    config: Config,

    /// I/O backend (owned by scheduler for centralized management)
    backend: Backend,

    /// Shutdown signal
    shutdown_flag: std.atomic.Value(bool),

    /// Running flag
    running: std.atomic.Value(bool),

    /// Next worker for round-robin spawning
    next_worker: std.atomic.Value(usize),

    /// Total tasks spawned (for metrics)
    tasks_spawned: std.atomic.Value(u64),

    /// Create a new scheduler
    pub fn init(allocator: Allocator, config: Config) !Self {
        const num_workers = config.num_workers orelse detectCpuCount();
        const actual_workers = if (config.strategy == .single_threaded) 1 else num_workers;

        // Initialize I/O backend (centralized here for automatic platform selection)
        const backend_config = BackendConfig{
            .backend_type = config.backend orelse .auto,
            .max_completions = config.max_io_completions,
        };
        var backend = try Backend.init(allocator, backend_config);
        errdefer backend.deinit();

        const workers = try allocator.alloc(Worker, actual_workers);
        errdefer allocator.free(workers);

        var shutdown_val = std.atomic.Value(bool).init(false);

        for (workers, 0..) |*w, i| {
            w.* = Worker.init(i, &shutdown_val);
        }

        return Self{
            .allocator = allocator,
            .workers = workers,
            .shared = SharedState{
                .workers = workers,
                .global_queue = ShardedGlobalQueue.init(),
                .idle_state = IdleState.init(@intCast(actual_workers)),
            },
            .config = config,
            .backend = backend,
            .shutdown_flag = shutdown_val,
            .running = std.atomic.Value(bool).init(false),
            .next_worker = std.atomic.Value(usize).init(0),
            .tasks_spawned = std.atomic.Value(u64).init(0),
        };
        // Note: Workers are connected to shared state in start() after struct is in final location
    }

    /// Clean up scheduler resources
    ///
    /// Graceful shutdown sequence:
    /// 1. Set shutdown flag (workers will exit their loops)
    /// 2. Close global queue (new pushes are rejected)
    /// 3. Wake all workers (so they see the shutdown flag)
    /// 4. Join worker threads (wait for them to finish)
    /// 5. Drain any remaining tasks (cancel and unref)
    pub fn deinit(self: *Self) void {
        // Signal shutdown
        self.shutdown_flag.store(true, .release);

        // Close global queue to reject new tasks during shutdown
        self.shared.global_queue.close();

        // Wake all workers so they see shutdown flag
        for (self.workers) |*w| {
            w.wake();
        }

        // Wait for all workers to finish
        for (self.workers) |*w| {
            w.join();
        }

        // Drain remaining tasks to prevent memory leaks
        self.drainRemainingTasks();

        // Clean up I/O backend
        self.backend.deinit();

        self.allocator.free(self.workers);
    }

    /// Drain all queues and drop remaining tasks to prevent memory leaks
    fn drainRemainingTasks(self: *Self) void {
        // Drain global queue
        while (self.shared.global_queue.pop()) |task| {
            // Mark as cancelled and drop
            _ = task.cancel();
            task.unref();
        }

        // Drain all local queues and worker batch buffers
        for (self.workers) |*w| {
            // Drain worker's pre-fetched global batch buffer
            // These are tasks pulled from global queue but not yet processed
            while (w.global_batch_pos < w.global_batch_len) {
                if (w.global_batch_buffer[w.global_batch_pos]) |task| {
                    _ = task.cancel();
                    task.unref();
                }
                w.global_batch_pos += 1;
            }
            w.global_batch_len = 0;

            // Drain LIFO slot and main queue
            while (w.local_queue.pop()) |task| {
                _ = task.cancel();
                task.unref();
            }
        }
    }

    /// Get the I/O backend (for submitting operations or polling)
    pub fn getBackend(self: *Self) *Backend {
        return &self.backend;
    }

    /// Get the detected backend type (for logging/debugging)
    pub fn getBackendType(self: *Self) BackendType {
        return std.meta.activeTag(self.backend);
    }

    /// Start the scheduler
    pub fn start(self: *Self) !void {
        if (self.running.swap(true, .acq_rel)) {
            return; // Already running
        }

        // Connect workers to shared state (must be done after struct is in final location)
        for (self.workers) |*w| {
            w.setShared(&self.shared);
            w.shutdown = &self.shutdown_flag;
        }

        // Start worker threads
        for (self.workers) |*w| {
            try w.start();
        }

        worker_mod.global_worker_count = self.workers.len;
    }

    /// Signal shutdown
    pub fn shutdown(self: *Self) void {
        self.shutdown_flag.store(true, .release);

        // Wake all workers
        for (self.workers) |*w| {
            w.wake();
        }
    }

    /// Spawn a task
    pub fn spawn(self: *Self, task: *Header) void {
        _ = self.spawnWithBackpressure(task);
    }

    /// Spawn a task with backpressure awareness
    /// IMPROVEMENT OVER TOKIO: Returns backpressure signal when queues are full
    pub fn spawnWithBackpressure(self: *Self, task: *Header) SpawnResult {
        _ = self.tasks_spawned.fetchAdd(1, .monotonic);

        // Try to schedule the task
        if (!task.transitionToScheduled()) {
            return .rejected; // Task was cancelled or already scheduled
        }

        // Check backpressure
        const total_depth = self.totalQueueDepth();
        const threshold = self.config.backpressure_threshold * self.workers.len;

        self.scheduleTask(task);

        if (total_depth > threshold) {
            return .backpressure;
        }
        return .ok;
    }

    /// Get total queue depth across all queues
    pub fn totalQueueDepth(self: *const Self) usize {
        var total: usize = self.shared.global_queue.len();
        for (self.workers) |*w| {
            total += w.local_queue.len();
        }
        return total;
    }

    /// Schedule a task (internal)
    fn scheduleTask(self: *Self, task: *Header) void {
        switch (self.config.strategy) {
            .work_stealing => {
                // Try local queue first if on a worker thread
                if (self.tryLocalQueue(task)) {
                    return;
                }
                // Fall back to global queue
                // Note: If queue is closed (shutdown), push returns false
                // and task is not enqueued - this is intentional
                _ = self.shared.global_queue.push(task);
                self.notifyWorker();
            },
            .thread_per_core => {
                // Always use local queue of assigned worker
                const worker_id = worker_mod.getCurrentWorkerId();
                if (worker_id < self.workers.len) {
                    if (!self.workers[worker_id].push(task)) {
                        // Local queue full, use global
                        _ = self.shared.global_queue.push(task);
                    }
                } else {
                    // Not on a valid worker thread, use global queue
                    _ = self.shared.global_queue.push(task);
                }
                self.notifyWorker();
            },
            .single_threaded => {
                // Single worker
                if (!self.workers[0].push(task)) {
                    _ = self.shared.global_queue.push(task);
                }
                self.workers[0].wake();
            },
        }
    }

    /// Try to push to current worker's local queue
    fn tryLocalQueue(self: *Self, task: *Header) bool {
        if (!worker_mod.isWorkerThread()) {
            return false;
        }

        const worker_id = worker_mod.getCurrentWorkerId();
        if (worker_id >= self.workers.len) {
            return false;
        }

        return self.workers[worker_id].push(task);
    }

    /// Wake a worker to process tasks
    /// Uses bitmap-based smart waking for efficiency
    fn notifyWorker(self: *Self) void {
        // Fast path: check if any workers are parked using bitmap
        if (self.shared.idle_state.findParkedWorker()) |worker_id| {
            if (worker_id < self.workers.len) {
                self.workers[worker_id].wake();
                return;
            }
        }

        // No parked workers found in bitmap, check if we should wake anyone
        // If there are searchers actively looking for work, no need to wake
        if (!self.shared.idle_state.shouldWakeWorker()) {
            return;
        }

        // Fall back to round-robin to distribute wake-ups
        const idx = self.next_worker.fetchAdd(1, .monotonic) % self.workers.len;
        self.workers[idx].wake();
    }

    /// Notify all workers (for batch spawning or shutdown)
    fn notifyAllWorkers(self: *Self) void {
        for (self.workers) |*w| {
            w.wake();
        }
    }

    /// Block until all spawned tasks complete
    /// Note: This is a simple implementation - doesn't track task completion
    pub fn blockOnAll(self: *Self) void {
        // Wait until all queues are empty
        while (true) {
            var has_work = false;

            if (!self.shared.global_queue.isEmpty()) {
                has_work = true;
            }

            for (self.workers) |*w| {
                if (!w.local_queue.isEmpty()) {
                    has_work = true;
                    break;
                }
            }

            if (!has_work) break;

            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }

    /// Get scheduler metrics
    pub fn getMetrics(self: *const Self) Metrics {
        var total_polled: u64 = 0;
        var total_stolen: u64 = 0;
        var total_parked: u64 = 0;
        var total_queue_depth: usize = 0;

        for (self.workers) |*w| {
            const m = w.getMetrics();
            total_polled += m.tasks_polled;
            total_stolen += m.tasks_stolen;
            total_parked += m.times_parked;
            total_queue_depth += m.queue_depth;
        }

        return .{
            .num_workers = self.workers.len,
            .tasks_spawned = self.tasks_spawned.load(.monotonic),
            .tasks_polled = total_polled,
            .tasks_stolen = total_stolen,
            .times_parked = total_parked,
            .global_queue_depth = self.shared.global_queue.len(),
            .local_queue_depth = total_queue_depth,
        };
    }

    pub const Metrics = struct {
        num_workers: usize,
        tasks_spawned: u64,
        tasks_polled: u64,
        tasks_stolen: u64,
        times_parked: u64,
        global_queue_depth: usize,
        local_queue_depth: usize,
    };

    /// Schedule callback for tasks to use
    pub fn scheduleCallback(_: *anyopaque, header: *Header) void {
        // Note: In a real implementation, we'd capture the scheduler pointer
        // For now, tasks must be spawned through spawn()
        _ = header;
    }
};

/// Detect the number of CPU cores
fn detectCpuCount() usize {
    return std.Thread.getCpuCount() catch 1;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "Scheduler - detect cpu count" {
    const count = detectCpuCount();
    try std.testing.expect(count >= 1);
}

// Test task for scheduler tests
// Uses external atomics so we can check completion after task is freed
const TestTask = struct {
    header: Header,
    // Pointer to external counter (outlives task)
    completed_counter: *std.atomic.Value(u32),
    allocator: Allocator,

    const vtable = Header.VTable{
        .poll = poll,
        .drop = drop,
        .get_output = getOutput,
        .schedule = schedule,
    };

    fn create(allocator: Allocator, completed_counter: *std.atomic.Value(u32)) !*TestTask {
        const task = try allocator.create(TestTask);
        task.* = .{
            .header = Header.init(&vtable, task_mod.nextTaskId()),
            .completed_counter = completed_counter,
            .allocator = allocator,
        };
        return task;
    }

    fn poll(header: *Header) bool {
        const self: *TestTask = @fieldParentPtr("header", header);
        _ = self.completed_counter.fetchAdd(1, .acq_rel);
        return true; // Task completes immediately
    }

    fn drop(header: *Header) void {
        const self: *TestTask = @fieldParentPtr("header", header);
        self.allocator.destroy(self);
    }

    fn getOutput(_: *Header) ?*anyopaque {
        return null;
    }

    fn schedule(header: *Header) void {
        _ = header;
    }
};

test "Scheduler - init and deinit" {
    const allocator = std.testing.allocator;

    var scheduler = try Scheduler.init(allocator, .{
        .num_workers = 2,
        .strategy = .work_stealing,
    });
    defer scheduler.deinit();

    try std.testing.expectEqual(@as(usize, 2), scheduler.workers.len);
    try std.testing.expect(!scheduler.running.load(.acquire));
}

test "Scheduler - init with single threaded strategy" {
    const allocator = std.testing.allocator;

    var scheduler = try Scheduler.init(allocator, .{
        .strategy = .single_threaded,
    });
    defer scheduler.deinit();

    // Single threaded forces 1 worker
    try std.testing.expectEqual(@as(usize, 1), scheduler.workers.len);
}

test "Scheduler - start and shutdown" {
    const allocator = std.testing.allocator;

    var scheduler = try Scheduler.init(allocator, .{
        .num_workers = 2,
    });
    defer scheduler.deinit();

    try scheduler.start();
    try std.testing.expect(scheduler.running.load(.acquire));

    scheduler.shutdown();
    try std.testing.expect(scheduler.shutdown_flag.load(.acquire));
}

test "Scheduler - spawn enqueues task" {
    const allocator = std.testing.allocator;

    var scheduler = try Scheduler.init(allocator, .{
        .num_workers = 2,
    });
    defer scheduler.deinit();

    // Don't start workers - just test that spawn enqueues properly
    var completed = std.atomic.Value(u32).init(0);
    const task = try TestTask.create(allocator, &completed);

    // Check initial depth
    const initial_depth = scheduler.totalQueueDepth();

    scheduler.spawn(&task.header);

    // Task should be in a queue
    try std.testing.expect(scheduler.totalQueueDepth() > initial_depth);

    // deinit will drain and clean up
}

test "Scheduler - spawn multiple tasks enqueues all" {
    const allocator = std.testing.allocator;

    var scheduler = try Scheduler.init(allocator, .{
        .num_workers = 2,
    });
    defer scheduler.deinit();

    // Don't start workers - just test that multiple spawns enqueue properly
    const num_tasks = 10;
    var completed = std.atomic.Value(u32).init(0);

    for (0..num_tasks) |_| {
        const task = try TestTask.create(allocator, &completed);
        scheduler.spawn(&task.header);
    }

    // All tasks should be in queues
    try std.testing.expect(scheduler.totalQueueDepth() >= num_tasks);

    // deinit will drain and clean up
}

test "Scheduler - spawnWithBackpressure returns ok" {
    const allocator = std.testing.allocator;

    var scheduler = try Scheduler.init(allocator, .{
        .num_workers = 2,
        .backpressure_threshold = 1000,
    });
    defer scheduler.deinit();

    var completed = std.atomic.Value(u32).init(0);
    const task = try TestTask.create(allocator, &completed);
    const result = scheduler.spawnWithBackpressure(&task.header);

    try std.testing.expectEqual(SpawnResult.ok, result);

    // deinit will drain the task
}

test "Scheduler - totalQueueDepth" {
    const allocator = std.testing.allocator;

    var scheduler = try Scheduler.init(allocator, .{
        .num_workers = 2,
    });
    defer scheduler.deinit();

    // Initially empty
    try std.testing.expectEqual(@as(usize, 0), scheduler.totalQueueDepth());

    var completed = std.atomic.Value(u32).init(0);

    // Spawn some tasks (without starting workers, they stay in queue)
    const task1 = try TestTask.create(allocator, &completed);
    const task2 = try TestTask.create(allocator, &completed);

    scheduler.spawn(&task1.header);
    scheduler.spawn(&task2.header);

    // Should have 2 tasks in queues
    try std.testing.expect(scheduler.totalQueueDepth() >= 2);
}

test "Scheduler - getMetrics" {
    const allocator = std.testing.allocator;

    var scheduler = try Scheduler.init(allocator, .{
        .num_workers = 2,
    });
    defer scheduler.deinit();

    const metrics = scheduler.getMetrics();

    try std.testing.expectEqual(@as(usize, 2), metrics.num_workers);
    try std.testing.expectEqual(@as(u64, 0), metrics.tasks_spawned);
}

test "Scheduler - metrics update after spawn" {
    const allocator = std.testing.allocator;

    var scheduler = try Scheduler.init(allocator, .{
        .num_workers = 1,
    });
    defer scheduler.deinit();

    var completed = std.atomic.Value(u32).init(0);
    const task = try TestTask.create(allocator, &completed);
    scheduler.spawn(&task.header);

    const metrics = scheduler.getMetrics();
    try std.testing.expectEqual(@as(u64, 1), metrics.tasks_spawned);
}

test "Scheduler - thread_per_core strategy enqueues" {
    const allocator = std.testing.allocator;

    var scheduler = try Scheduler.init(allocator, .{
        .num_workers = 2,
        .strategy = .thread_per_core,
    });
    defer scheduler.deinit();

    // Test that thread_per_core uses global queue when not on worker thread
    var completed = std.atomic.Value(u32).init(0);
    const task = try TestTask.create(allocator, &completed);
    scheduler.spawn(&task.header);

    // Task should be enqueued (goes to global queue since we're not on a worker)
    try std.testing.expect(scheduler.totalQueueDepth() >= 1);
}

test "Scheduler - shutdown with pending tasks" {
    const allocator = std.testing.allocator;

    var scheduler = try Scheduler.init(allocator, .{
        .num_workers = 1,
    });

    var completed = std.atomic.Value(u32).init(0);

    // Spawn tasks without starting workers
    for (0..5) |_| {
        const task = try TestTask.create(allocator, &completed);
        scheduler.spawn(&task.header);
    }

    // deinit should drain and clean up pending tasks
    scheduler.deinit();
}

test "Scheduler - getBackend returns valid backend" {
    const allocator = std.testing.allocator;

    var scheduler = try Scheduler.init(allocator, .{
        .num_workers = 1,
    });
    defer scheduler.deinit();

    const backend = scheduler.getBackend();
    try std.testing.expect(@intFromPtr(backend) != 0);
}

test "Scheduler - double start is safe" {
    const allocator = std.testing.allocator;

    var scheduler = try Scheduler.init(allocator, .{
        .num_workers = 1,
    });
    defer scheduler.deinit();

    try scheduler.start();
    try scheduler.start(); // Should not error or double-start

    try std.testing.expect(scheduler.running.load(.acquire));
    scheduler.shutdown();
}

test "Scheduler - blockOnAll with empty queues" {
    const allocator = std.testing.allocator;

    var scheduler = try Scheduler.init(allocator, .{
        .num_workers = 1,
    });
    defer scheduler.deinit();

    // Should return immediately when no tasks
    scheduler.blockOnAll();
}
