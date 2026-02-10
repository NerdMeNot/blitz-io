//! Scheduler - Production-Grade Work-Stealing Task Scheduler
//!
//! A sophisticated multi-threaded scheduler with Tokio-grade optimizations:
//!
//! ┌─────────────────────────────────────────────────────────────────────────┐
//! │ WORKER ARCHITECTURE                                                     │
//! ├─────────────────────────────────────────────────────────────────────────┤
//! │                                                                         │
//! │  Each Worker owns:                                                      │
//! │  ┌─────────────────────────────────────────────────────────────────┐   │
//! │  │ • Local Queue (256 slots + LIFO slot)                           │   │
//! │  │ • Global Batch Buffer (32 pre-fetched tasks)                    │   │
//! │  │ • Parking State (futex-based sleep/wake)                        │   │
//! │  │ • Cooperative Budget (128 polls per tick)                       │   │
//! │  └─────────────────────────────────────────────────────────────────┘   │
//! │                                                                         │
//! └─────────────────────────────────────────────────────────────────────────┘
//!
//! ┌─────────────────────────────────────────────────────────────────────────┐
//! │ WORK FINDING PRIORITY (matches Tokio)                                   │
//! ├─────────────────────────────────────────────────────────────────────────┤
//! │                                                                         │
//! │  1. Pre-fetched Global Batch  → Already holding tasks from global      │
//! │  2. Local Queue               → Check LIFO slot, then main queue       │
//! │  3. Global Queue (periodic)   → Every N ticks, batch-pull tasks        │
//! │  4. Work Stealing             → Steal from other workers' queues       │
//! │  5. Global Queue (final)      → One more check before parking          │
//! │  6. Park                      → Sleep with timeout until woken         │
//! │                                                                         │
//! └─────────────────────────────────────────────────────────────────────────┘
//!
//! ┌─────────────────────────────────────────────────────────────────────────┐
//! │ TOKIO OPTIMIZATIONS IMPLEMENTED                                         │
//! ├─────────────────────────────────────────────────────────────────────────┤
//! │                                                                         │
//! │  1. Cooperative Budgeting (BUDGET_PER_TICK = 128)                       │
//! │     → Prevents single task from hogging worker indefinitely            │
//! │                                                                         │
//! │  2. LIFO Poll Caps (MAX_LIFO_POLLS_PER_TICK = 3)                        │
//! │     → Ensures LIFO slot doesn't starve main queue tasks                │
//! │                                                                         │
//! │  3. Batch Global Queue (up to 64 tasks per fetch)                      │
//! │     → Reduces mutex contention by amortizing lock acquisition          │
//! │                                                                         │
//! │  4. Searcher Limiting (~50% of workers)                                 │
//! │     → Prevents thundering herd when work appears                       │
//! │                                                                         │
//! │  5. Parked Worker Bitmap (64-bit, O(1) lookup via @ctz)                │
//! │     → Efficiently find and wake exactly one parked worker              │
//! │                                                                         │
//! │  6. Adaptive Global Queue Interval                                      │
//! │     → Check frequency scales with task duration (EWMA)                 │
//! │                                                                         │
//! │  7. Lost Wakeup Prevention (transitioning_to_park flag)                │
//! │     → Prevents race between LIFO push and parking                      │
//! │                                                                         │
//! └─────────────────────────────────────────────────────────────────────────┘
//!
//! Reference: tokio/src/runtime/scheduler/multi_thread/worker.rs

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const task_mod = @import("task.zig");
const Header = task_mod.Header;
const TaskQueue = task_mod.TaskQueue;
const GlobalTaskQueue = task_mod.GlobalTaskQueue;
const Lifecycle = task_mod.Lifecycle;
const State = task_mod.State;

const stack_pool = @import("stack_pool.zig");
const timer_mod = @import("timer.zig");
const TimerWheel = timer_mod.TimerWheel;
const TimerEntry = timer_mod.TimerEntry;

// I/O Backend - centralized here so scheduler owns the I/O driver
const backend_mod = @import("../backend.zig");
pub const Backend = backend_mod.Backend;
pub const BackendType = backend_mod.BackendType;
pub const BackendConfig = backend_mod.Config;
pub const Completion = backend_mod.Completion;
pub const Operation = backend_mod.Operation;

// ═══════════════════════════════════════════════════════════════════════════════
// Cooperative Scheduling Constants (from Tokio)
// ═══════════════════════════════════════════════════════════════════════════════

/// Maximum number of task polls per maintenance tick.
/// Prevents a single task from hogging the worker.
/// Tokio uses 128 as default.
pub const BUDGET_PER_TICK: u32 = 128;

/// Maximum consecutive LIFO slot polls before forcing queue check.
/// Prevents LIFO slot from starving main queue tasks.
/// Tokio uses 3-4 as default.
pub const MAX_LIFO_POLLS_PER_TICK: u8 = 3;

/// Maximum tasks to pull from global queue in one batch.
pub const MAX_GLOBAL_QUEUE_BATCH_SIZE: usize = 64;

/// Minimum batch size (to amortize lock cost).
pub const MIN_GLOBAL_QUEUE_BATCH_SIZE: usize = 4;

/// Default batch size for global queue.
pub const GLOBAL_QUEUE_BATCH_SIZE: usize = 32;

/// Maximum number of workers (for bitmap tracking).
pub const MAX_WORKERS: usize = 64;

// ═══════════════════════════════════════════════════════════════════════════════
// Adaptive Global Queue Interval (Tokio-style self-tuning)
// ═══════════════════════════════════════════════════════════════════════════════

/// Target latency for checking global queue (1ms).
/// We want to check global queue at least this often to prevent starvation.
const TARGET_GLOBAL_QUEUE_LATENCY_NS: u64 = 1_000_000;

/// EWMA smoothing factor (0.1 = 10% weight to new sample).
/// Lower values = more stable, higher values = more responsive.
const EWMA_ALPHA: f64 = 0.1;

/// Minimum global queue check interval (prevent constant checking).
const MIN_GLOBAL_QUEUE_INTERVAL: u32 = 8;

/// Maximum global queue check interval (prevent starvation).
const MAX_GLOBAL_QUEUE_INTERVAL: u32 = 255;

/// Default initial estimate for task poll time (50µs).
const DEFAULT_AVG_TASK_NS: u64 = 50_000;

/// Park timeout in nanoseconds (10ms).
const PARK_TIMEOUT_NS: u64 = 10 * std.time.ns_per_ms;

// ═══════════════════════════════════════════════════════════════════════════════
// Configuration
// ═══════════════════════════════════════════════════════════════════════════════

pub const Config = struct {
    /// Number of worker threads (0 = auto-detect based on CPU count)
    num_workers: usize = 0,

    /// Maximum tasks in global queue before backpressure
    global_queue_capacity: usize = 65536,

    /// Enable work stealing
    enable_stealing: bool = true,

    /// Stack pool configuration
    stack_config: stack_pool.Config = .{},

    /// I/O backend type (null = auto-detect best for platform)
    backend_type: ?BackendType = null,

    /// Maximum I/O completions to process per tick
    max_io_completions: u32 = 256,

    pub fn getNumWorkers(self: Config) usize {
        if (self.num_workers == 0) {
            return @max(1, std.Thread.getCpuCount() catch 1);
        }
        return self.num_workers;
    }

    /// Convert to I/O backend configuration
    pub fn toBackendConfig(self: Config) BackendConfig {
        return BackendConfig{
            .backend_type = self.backend_type orelse .auto,
            .max_completions = self.max_io_completions,
        };
    }
};

pub const default_config = Config{};

// ═══════════════════════════════════════════════════════════════════════════════
// Idle State - Sophisticated idle coordination (from Tokio's idle.rs)
// ═══════════════════════════════════════════════════════════════════════════════

/// Tracks searching/parked workers to prevent thundering herd
pub const IdleState = struct {
    /// Number of workers currently searching for work
    num_searching: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Number of workers currently parked (sleeping)
    num_parked: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Bitmap of parked workers (for selective waking).
    /// Each bit represents one worker: 1 = parked, 0 = running.
    parked_bitmap: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Total number of workers
    num_workers: u32,

    pub fn init(num_workers: u32) IdleState {
        return .{ .num_workers = num_workers };
    }

    /// Check if we should wake a worker (fast path)
    pub fn shouldWakeWorker(self: *const IdleState) bool {
        // If no searchers and someone is parked, we should wake
        return self.num_searching.load(.acquire) == 0 and
            self.num_parked.load(.acquire) > 0;
    }

    /// Called when a worker is about to park
    pub fn workerParking(self: *IdleState, worker_id: usize) void {
        if (worker_id >= MAX_WORKERS) return;

        const mask: u64 = @as(u64, 1) << @intCast(worker_id);
        _ = self.parked_bitmap.fetchOr(mask, .release);
        _ = self.num_parked.fetchAdd(1, .release);
    }

    /// Called when a worker is unparking
    pub fn workerUnparking(self: *IdleState, worker_id: usize) void {
        if (worker_id >= MAX_WORKERS) return;

        const mask: u64 = @as(u64, 1) << @intCast(worker_id);
        _ = self.parked_bitmap.fetchAnd(~mask, .release);
        _ = self.num_parked.fetchSub(1, .release);
    }

    /// Find a parked worker to wake (returns worker ID or null).
    /// Uses @ctz for O(1) lookup of lowest set bit.
    pub fn findParkedWorker(self: *const IdleState) ?usize {
        const bitmap = self.parked_bitmap.load(.acquire);
        if (bitmap == 0) return null;
        return @ctz(bitmap);
    }

    /// Check if a specific worker is parked
    pub fn isWorkerParked(self: *const IdleState, worker_id: usize) bool {
        if (worker_id >= MAX_WORKERS) return false;
        const mask: u64 = @as(u64, 1) << @intCast(worker_id);
        return (self.parked_bitmap.load(.acquire) & mask) != 0;
    }

    /// Get number of parked workers
    pub fn getParkedCount(self: *const IdleState) u32 {
        return self.num_parked.load(.acquire);
    }

    /// Try to become a searcher. Returns true if allowed.
    pub fn tryBecomeSearcher(self: *IdleState, max_searchers: u32) bool {
        const current = self.num_searching.load(.acquire);
        if (current >= max_searchers) return false;

        const prev = self.num_searching.fetchAdd(1, .acq_rel);
        if (prev >= max_searchers) {
            // Lost race - undo
            _ = self.num_searching.fetchSub(1, .release);
            return false;
        }
        return true;
    }

    /// Stop being a searcher
    pub fn stopSearching(self: *IdleState) void {
        _ = self.num_searching.fetchSub(1, .release);
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Park State - Futex-based parking mechanism
// ═══════════════════════════════════════════════════════════════════════════════

pub const ParkState = struct {
    /// Futex word for parking
    futex: std.atomic.Value(u32) = std.atomic.Value(u32).init(UNPARKED),

    const UNPARKED: u32 = 0;
    const PARKED: u32 = 1;
    const NOTIFIED: u32 = 2;

    /// Park the worker until notified or timeout
    pub fn park(self: *ParkState, timeout_ns: ?u64) void {
        // Try to transition to PARKED
        const result = self.futex.cmpxchgStrong(
            UNPARKED,
            PARKED,
            .acq_rel,
            .acquire,
        );

        if (result == null) {
            // Successfully set to PARKED, now wait
            if (timeout_ns) |ns| {
                std.Thread.Futex.timedWait(&self.futex, PARKED, ns) catch {};
            } else {
                std.Thread.Futex.wait(&self.futex, PARKED);
            }
        }

        // Reset state
        self.futex.store(UNPARKED, .release);
    }

    /// Unpark the worker
    pub fn unpark(self: *ParkState) void {
        const prev = self.futex.swap(NOTIFIED, .acq_rel);
        if (prev == PARKED) {
            std.Thread.Futex.wake(&self.futex, 1);
        }
    }

    /// Check if in parked state
    pub fn isParked(self: *const ParkState) bool {
        return self.futex.load(.acquire) == PARKED;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Worker - Sophisticated worker thread with all Tokio optimizations
// ═══════════════════════════════════════════════════════════════════════════════

pub const Worker = struct {
    const Self = @This();

    /// Worker index
    index: usize,

    /// LIFO slot - single task for immediate execution (cache-hot)
    lifo_slot: std.atomic.Value(?*Header) = std.atomic.Value(?*Header).init(null),

    /// Local run queue (FIFO for fairness within worker)
    local_queue: TaskQueue = .{},

    /// Reference to scheduler
    scheduler: *Scheduler,

    /// Worker thread handle
    thread: ?std.Thread = null,

    /// Running flag
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Parking state
    park_state: ParkState = .{},

    // ─────────────────────────────────────────────────────────────────────────
    // Cooperative Scheduling State
    // ─────────────────────────────────────────────────────────────────────────

    /// Tick counter for periodic operations
    tick: u32 = 0,

    /// Cooperative budget: remaining polls this tick
    budget: u32 = BUDGET_PER_TICK,

    /// LIFO polls this tick - limited to prevent starvation
    lifo_polls_this_tick: u8 = 0,

    /// CRITICAL: Flag indicating worker is transitioning to parked state.
    /// Set BEFORE flushing LIFO, cleared AFTER waking.
    /// Prevents lost wakeup race condition.
    transitioning_to_park: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // ─────────────────────────────────────────────────────────────────────────
    // Adaptive Global Queue Interval
    // ─────────────────────────────────────────────────────────────────────────

    /// EWMA of task poll time in nanoseconds
    avg_task_ns: u64 = DEFAULT_AVG_TASK_NS,

    /// Calculated global queue check interval (adaptive)
    global_queue_interval: u32 = 61,

    /// Timestamp of batch start for measuring poll times
    batch_start_ns: i128 = 0,

    // ─────────────────────────────────────────────────────────────────────────
    // Global Queue Batch Buffer
    // ─────────────────────────────────────────────────────────────────────────

    /// Buffer for batch global queue pulls
    global_batch_buffer: [GLOBAL_QUEUE_BATCH_SIZE]?*Header = [_]?*Header{null} ** GLOBAL_QUEUE_BATCH_SIZE,

    /// Current position in batch buffer
    global_batch_pos: usize = 0,

    /// Number of tasks in batch buffer
    global_batch_len: usize = 0,

    // ─────────────────────────────────────────────────────────────────────────
    // Statistics
    // ─────────────────────────────────────────────────────────────────────────

    stats: Stats = .{},

    pub const Stats = struct {
        tasks_polled: u64 = 0,
        tasks_stolen: u64 = 0,
        times_parked: u64 = 0,
        lifo_hits: u64 = 0,
        global_batch_fetches: u64 = 0,
    };

    /// Initialize a worker
    pub fn init(index: usize, scheduler: *Scheduler) Self {
        return .{
            .index = index,
            .scheduler = scheduler,
        };
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Task Scheduling (with lost wakeup prevention)
    // ─────────────────────────────────────────────────────────────────────────

    /// Schedule a task on this worker's LIFO slot (preferred for locality).
    /// Returns false if worker is transitioning to park - use global queue instead.
    pub fn tryScheduleLocal(self: *Self, task: *Header) bool {
        // CRITICAL: Check transitioning flag to prevent lost wakeup
        if (self.transitioning_to_park.load(.seq_cst)) {
            return false; // Caller should use global queue
        }

        // Try LIFO slot first
        if (self.lifo_slot.cmpxchgStrong(null, task, .release, .monotonic) == null) {
            self.stats.lifo_hits += 1;
            return true;
        }

        // LIFO full - push to local queue
        self.local_queue.push(task);
        return true;
    }

    /// Force push to local queue (bypasses LIFO)
    pub fn pushToQueue(self: *Self, task: *Header) void {
        self.local_queue.push(task);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Work Finding (Tokio priority order)
    // ─────────────────────────────────────────────────────────────────────────

    /// Find work from any source (Tokio priority order)
    fn findWork(self: *Self) ?*Header {
        // 1. Check buffered global queue batch first
        if (self.pollGlobalBatch()) |task| {
            return task;
        }

        // 2. Check local queue with LIFO limiting
        if (self.pollLocalQueue()) |task| {
            return task;
        }

        // 3. Check global queue periodically (adaptive interval)
        if (self.tick % self.global_queue_interval == 0) {
            if (self.fetchGlobalBatch()) |task| {
                return task;
            }
        }

        // 4. Try stealing from other workers (with searcher limiting)
        if (self.scheduler.config.enable_stealing) {
            if (self.tryStealWithLimit()) |task| {
                self.stats.tasks_stolen += 1;
                return task;
            }
        }

        // 5. Final check of global queue before parking
        return self.fetchGlobalBatch();
    }

    /// Poll local queue with LIFO limiting
    fn pollLocalQueue(self: *Self) ?*Header {
        // Check if we should limit LIFO polls
        if (self.lifo_polls_this_tick < MAX_LIFO_POLLS_PER_TICK) {
            // Try LIFO slot first
            if (self.lifo_slot.swap(null, .acquire)) |task| {
                self.lifo_polls_this_tick +|= 1;
                return task;
            }
        }

        // Check main queue
        return self.local_queue.pop();
    }

    /// Poll from pre-fetched global batch buffer
    fn pollGlobalBatch(self: *Self) ?*Header {
        if (self.global_batch_pos < self.global_batch_len) {
            const task = self.global_batch_buffer[self.global_batch_pos];
            self.global_batch_buffer[self.global_batch_pos] = null;
            self.global_batch_pos += 1;
            return task;
        }
        return null;
    }

    /// Fetch a batch of tasks from global queue (reduces lock contention)
    fn fetchGlobalBatch(self: *Self) ?*Header {
        const global_len = self.scheduler.global_queue.length();
        if (global_len == 0) return null;

        // Adaptive batch size based on queue depth and worker count
        const num_workers = self.scheduler.workers.len;
        const fair_share = global_len / @max(1, num_workers);
        const batch_size = @min(MAX_GLOBAL_QUEUE_BATCH_SIZE, @max(MIN_GLOBAL_QUEUE_BATCH_SIZE, fair_share));

        // Fetch batch
        var fetched: usize = 0;
        while (fetched < batch_size) {
            if (self.scheduler.global_queue.pop()) |task| {
                self.global_batch_buffer[fetched] = task;
                fetched += 1;
            } else {
                break;
            }
        }

        if (fetched == 0) return null;

        self.stats.global_batch_fetches += 1;

        // Return first task, rest go to buffer
        const first = self.global_batch_buffer[0];
        self.global_batch_buffer[0] = null;

        if (fetched > 1) {
            self.global_batch_pos = 1;
            self.global_batch_len = fetched;
        } else {
            self.global_batch_pos = 0;
            self.global_batch_len = 0;
        }

        return first;
    }

    /// Try to steal work with searcher limiting (~50% of workers)
    fn tryStealWithLimit(self: *Self) ?*Header {
        const num_workers = self.scheduler.workers.len;
        if (num_workers <= 1) return null;

        const max_searchers: u32 = @intCast(@max(1, num_workers / 2));

        if (!self.scheduler.idle_state.tryBecomeSearcher(max_searchers)) {
            return null; // Too many searchers already
        }
        defer self.scheduler.idle_state.stopSearching();

        return self.trySteal();
    }

    /// Try to steal work from another worker
    fn trySteal(self: *Self) ?*Header {
        const num_workers = self.scheduler.workers.len;

        // Start from a different victim each time (use tick as randomization)
        var victim_start = (self.index + @as(usize, @intCast(self.tick))) % num_workers;

        for (0..num_workers - 1) |_| {
            const victim_id = victim_start;
            victim_start = (victim_start + 1) % num_workers;

            if (victim_id == self.index) continue;

            const victim = &self.scheduler.workers[victim_id];

            // Try to steal from LIFO slot
            if (victim.lifo_slot.swap(null, .acquire)) |task| {
                return task;
            }

            // Try to steal from local queue
            if (victim.local_queue.pop()) |task| {
                return task;
            }
        }

        return null;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Adaptive Interval Tuning
    // ─────────────────────────────────────────────────────────────────────────

    /// Update adaptive global queue interval based on measured task poll times.
    fn updateAdaptiveInterval(self: *Self, tasks_run: u32) void {
        if (tasks_run == 0) return;

        const end_ns = std.time.nanoTimestamp();
        const batch_ns: u64 = @intCast(@max(0, end_ns - self.batch_start_ns));
        const current_avg = batch_ns / tasks_run;

        // EWMA: new_avg = (current * alpha) + (old * (1 - alpha))
        const new_avg: u64 = @intFromFloat(
            (@as(f64, @floatFromInt(current_avg)) * EWMA_ALPHA) +
                (@as(f64, @floatFromInt(self.avg_task_ns)) * (1.0 - EWMA_ALPHA)),
        );
        self.avg_task_ns = @max(1, new_avg);

        // Calculate new interval: how many tasks fit in TARGET_GLOBAL_QUEUE_LATENCY_NS?
        const tasks_per_target = TARGET_GLOBAL_QUEUE_LATENCY_NS / self.avg_task_ns;
        const clamped = @min(MAX_GLOBAL_QUEUE_INTERVAL, @max(MIN_GLOBAL_QUEUE_INTERVAL, tasks_per_target));
        self.global_queue_interval = @intCast(clamped);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Worker Loop
    // ─────────────────────────────────────────────────────────────────────────

    /// Main worker loop
    fn run(self: *Self) void {
        self.running.store(true, .release);

        // Set thread-local context
        setCurrentContext(self.scheduler, self.index);
        defer clearCurrentContext();

        // Signal ready
        _ = self.scheduler.ready_count.fetchAdd(1, .release);

        while (!self.scheduler.shutdown.load(.acquire)) {
            self.tick +%= 1;
            self.batch_start_ns = std.time.nanoTimestamp();

            // Poll timers at the start of each tick (worker 0 is primary timer driver)
            // Only one worker needs to poll timers to avoid excessive contention
            if (self.index == 0) {
                _ = self.scheduler.pollTimers();
            }

            // Poll I/O completions (all workers can try, uses tryLock)
            // This ensures responsive I/O processing across workers
            _ = self.scheduler.pollIo();

            // Run tasks until budget exhausted or no work
            var tasks_run: u32 = 0;
            while (self.budget > 0) {
                if (self.findWork()) |task| {
                    self.executeTask(task);
                    self.budget -|= 1;
                    tasks_run += 1;
                } else {
                    break;
                }
            }

            // Update adaptive interval
            self.updateAdaptiveInterval(tasks_run);

            // Maintenance: reset budget and counters
            self.budget = BUDGET_PER_TICK;
            self.lifo_polls_this_tick = 0;
            self.global_batch_pos = 0;
            self.global_batch_len = 0;

            if (tasks_run == 0) {
                self.parkWorker();
            }
        }

        self.running.store(false, .release);
        self.drainOnShutdown();
    }

    /// Execute a single task
    fn executeTask(self: *Self, task: *Header) void {
        // Transition to running
        if (!task.transitionToRunning()) {
            return; // Cancelled or wrong state
        }

        // Poll the task
        const result = task.poll();
        self.stats.tasks_polled += 1;

        switch (result) {
            .complete => {
                task.transitionToComplete();
                if (task.unref()) {
                    task.drop();
                }
            },
            .pending => {
                // Task yielded - transition back to idle
                const prev = task.transitionToIdle();

                // Clear notified flag if set
                if (prev.notified) {
                    _ = task.clearNotified();
                }

                // Always reschedule yielded tasks (cooperative scheduling)
                if (task.transitionToScheduled()) {
                    // Try local LIFO first, fall back to global
                    if (!self.tryScheduleLocal(task)) {
                        self.scheduler.global_queue.push(task);
                    }
                }
            },
        }
    }

    /// Park the worker with lost wakeup prevention
    fn parkWorker(self: *Self) void {
        self.stats.times_parked += 1;

        // CRITICAL: Set transitioning flag BEFORE flush (seq_cst ordering)
        // This tells schedulers "don't push to my LIFO, use global queue"
        self.transitioning_to_park.store(true, .seq_cst);

        // Flush LIFO slot to queue so tasks are stealable
        if (self.lifo_slot.swap(null, .acquire)) |task| {
            self.local_queue.push(task);
        }

        // Double-check: if new work arrived during flush, don't park
        if (!self.local_queue.isEmpty() or !self.scheduler.global_queue.isEmpty()) {
            self.transitioning_to_park.store(false, .seq_cst);
            self.budget = BUDGET_PER_TICK;
            return;
        }

        // Track in idle state
        self.scheduler.idle_state.workerParking(self.index);

        // Calculate park timeout: use timer expiration or default
        // Worker 0 must wake to process timers, others can sleep longer
        const park_timeout: u64 = if (self.index == 0)
            self.scheduler.nextTimerExpiration() orelse PARK_TIMEOUT_NS
        else
            PARK_TIMEOUT_NS;

        // Park with timeout
        self.park_state.park(park_timeout);

        // Clear transitioning flag AFTER waking
        self.transitioning_to_park.store(false, .seq_cst);

        // Track unparking
        self.scheduler.idle_state.workerUnparking(self.index);

        // Reset budget after waking
        self.budget = BUDGET_PER_TICK;
    }

    /// Drain tasks on shutdown
    fn drainOnShutdown(self: *Self) void {
        // Cancel and drop LIFO slot
        if (self.lifo_slot.swap(null, .acquire)) |task| {
            _ = task.cancel();
            if (task.unref()) {
                task.drop();
            }
        }

        // Cancel and drop local queue
        while (self.local_queue.pop()) |task| {
            _ = task.cancel();
            if (task.unref()) {
                task.drop();
            }
        }

        // Cancel and drop batch buffer
        while (self.global_batch_pos < self.global_batch_len) {
            if (self.global_batch_buffer[self.global_batch_pos]) |task| {
                _ = task.cancel();
                if (task.unref()) {
                    task.drop();
                }
            }
            self.global_batch_pos += 1;
        }
    }

    /// Wake this worker
    pub fn wake(self: *Self) void {
        self.park_state.unpark();
    }

    /// Check if worker is parked
    pub fn isParked(self: *const Self) bool {
        return self.park_state.isParked();
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Scheduler - Production-grade work-stealing scheduler
// ═══════════════════════════════════════════════════════════════════════════════

pub const Scheduler = struct {
    const Self = @This();

    /// Configuration
    config: Config,

    /// Workers array
    workers: []Worker,

    /// Global injection queue
    global_queue: GlobalTaskQueue = .{},

    /// Shutdown flag
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Idle coordination state
    idle_state: IdleState,

    /// Number of workers that have started and are ready
    ready_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Stack pool for coroutines
    stacks: stack_pool.StackPool,

    /// Timer wheel for sleep/timeout operations
    timer_wheel: TimerWheel,

    /// Mutex protecting timer wheel (multiple workers may poll)
    timer_mutex: std.Thread.Mutex = .{},

    /// I/O backend (owned by scheduler for centralized management)
    backend: Backend,

    /// Completion buffer for I/O polling
    completions: []Completion,

    /// Mutex protecting I/O backend (single poller at a time)
    io_mutex: std.Thread.Mutex = .{},

    /// Allocator
    allocator: Allocator,

    /// Statistics
    total_spawned: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    timers_processed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    io_completions_processed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Initialize the scheduler
    pub fn init(allocator: Allocator, config: Config) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const num_workers = config.getNumWorkers();

        // Initialize I/O backend (centralized here for automatic platform selection)
        var backend = try Backend.init(allocator, config.toBackendConfig());
        errdefer backend.deinit();

        // Allocate completions buffer
        const completions = try allocator.alloc(Completion, config.max_io_completions);
        errdefer allocator.free(completions);

        self.* = .{
            .config = config,
            .workers = try allocator.alloc(Worker, num_workers),
            .idle_state = IdleState.init(@intCast(num_workers)),
            .stacks = stack_pool.StackPool.init(config.stack_config),
            .timer_wheel = TimerWheel.init(allocator),
            .backend = backend,
            .completions = completions,
            .allocator = allocator,
        };

        // Initialize workers
        for (self.workers, 0..) |*worker, i| {
            worker.* = Worker.init(i, self);
        }

        return self;
    }

    /// Deinitialize the scheduler
    pub fn deinit(self: *Self) void {
        self.timer_wheel.deinit();
        self.backend.deinit();
        self.allocator.free(self.completions);
        self.allocator.free(self.workers);
        self.stacks.deinit();
        self.allocator.destroy(self);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Lifecycle
    // ─────────────────────────────────────────────────────────────────────────

    /// Start all worker threads
    pub fn start(self: *Self) !void {
        self.ready_count.store(0, .release);

        for (self.workers) |*worker| {
            worker.thread = try std.Thread.spawn(.{}, Worker.run, .{worker});
        }
    }

    /// Wait until all workers have started
    pub fn waitForWorkersReady(self: *Self) void {
        const target: u32 = @intCast(self.workers.len);
        while (self.ready_count.load(.acquire) < target) {
            std.Thread.yield() catch {};
        }
    }

    /// Start workers and wait until all are ready
    pub fn startAndWait(self: *Self) !void {
        try self.start();
        self.waitForWorkersReady();
    }

    /// Signal shutdown and wait for all workers
    pub fn shutdownAndWait(self: *Self) void {
        self.shutdown.store(true, .release);

        // Wake all workers
        for (self.workers) |*worker| {
            worker.wake();
        }

        // Join all threads
        for (self.workers) |*worker| {
            if (worker.thread) |thread| {
                thread.join();
                worker.thread = null;
            }
        }
    }

    /// Check if scheduler is running
    pub fn isRunning(self: *Self) bool {
        return !self.shutdown.load(.acquire);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Task Spawning (with intelligent wake)
    // ─────────────────────────────────────────────────────────────────────────

    /// Spawn a task onto the scheduler
    pub fn spawn(self: *Self, task: *Header) void {
        if (!task.transitionToScheduled()) {
            return;
        }

        task.ref();
        _ = self.total_spawned.fetchAdd(1, .monotonic);

        // Push to global queue
        self.global_queue.push(task);

        // Wake a worker if needed (using bitmap for O(1) lookup)
        self.wakeWorkerIfNeeded();
    }

    /// Spawn from a specific worker context (use local queue)
    pub fn spawnFromWorker(self: *Self, worker_idx: usize, task: *Header) void {
        if (!task.transitionToScheduled()) {
            return;
        }

        task.ref();
        _ = self.total_spawned.fetchAdd(1, .monotonic);

        if (worker_idx < self.workers.len) {
            const worker = &self.workers[worker_idx];
            if (!worker.tryScheduleLocal(task)) {
                // Worker transitioning to park, use global
                self.global_queue.push(task);
                self.wakeWorkerIfNeeded();
            }
        } else {
            self.global_queue.push(task);
            self.wakeWorkerIfNeeded();
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Wake Management (with bitmap optimization)
    // ─────────────────────────────────────────────────────────────────────────

    /// Wake a worker if needed (O(1) using bitmap)
    fn wakeWorkerIfNeeded(self: *Self) void {
        if (!self.idle_state.shouldWakeWorker()) {
            return; // Someone is already searching
        }

        // Find a parked worker using bitmap (O(1))
        if (self.idle_state.findParkedWorker()) |worker_id| {
            if (worker_id < self.workers.len) {
                self.workers[worker_id].wake();
            }
        }
    }

    /// Wake all workers (for shutdown)
    fn wakeAll(self: *Self) void {
        for (self.workers) |*worker| {
            worker.wake();
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Statistics
    // ─────────────────────────────────────────────────────────────────────────

    pub const Stats = struct {
        total_spawned: u64,
        total_polled: u64,
        total_stolen: u64,
        total_parked: u64,
        num_workers: usize,
    };

    pub fn getStats(self: *const Self) Stats {
        var total_polled: u64 = 0;
        var total_stolen: u64 = 0;
        var total_parked: u64 = 0;

        for (self.workers) |*worker| {
            total_polled += worker.stats.tasks_polled;
            total_stolen += worker.stats.tasks_stolen;
            total_parked += worker.stats.times_parked;
        }

        return .{
            .total_spawned = self.total_spawned.load(.acquire),
            .total_polled = total_polled,
            .total_stolen = total_stolen,
            .total_parked = total_parked,
            .num_workers = self.workers.len,
        };
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Timer Operations
    // ─────────────────────────────────────────────────────────────────────────

    /// Poll and process expired timers (thread-safe)
    /// Returns number of timers processed
    pub fn pollTimers(self: *Self) usize {
        self.timer_mutex.lock();
        defer self.timer_mutex.unlock();

        const expired = self.timer_wheel.poll();
        const count = timer_mod.processExpired(&self.timer_wheel, expired);

        if (count > 0) {
            _ = self.timers_processed.fetchAdd(count, .monotonic);
        }

        return count;
    }

    /// Get time until next timer expires (for park timeout)
    pub fn nextTimerExpiration(self: *Self) ?u64 {
        self.timer_mutex.lock();
        defer self.timer_mutex.unlock();
        return self.timer_wheel.nextExpiration();
    }

    /// Schedule a sleep for a task (returns timer entry for cancellation)
    /// The task will be woken when the timer expires
    pub fn scheduleSleep(self: *Self, duration_ns: u64, task: *Header) !*TimerEntry {
        self.timer_mutex.lock();
        defer self.timer_mutex.unlock();
        return timer_mod.sleep(&self.timer_wheel, duration_ns, task);
    }

    /// Schedule a deadline for a task
    pub fn scheduleDeadline(self: *Self, deadline_ns: u64, task: *Header) !*TimerEntry {
        self.timer_mutex.lock();
        defer self.timer_mutex.unlock();
        return timer_mod.deadline(&self.timer_wheel, deadline_ns, task);
    }

    /// Schedule a timer with a custom waker callback
    pub fn scheduleTimerWithWaker(
        self: *Self,
        duration_ns: u64,
        ctx: *anyopaque,
        waker: timer_mod.WakerFn,
    ) !*TimerEntry {
        self.timer_mutex.lock();
        defer self.timer_mutex.unlock();
        return timer_mod.sleepWithWaker(&self.timer_wheel, duration_ns, ctx, waker);
    }

    /// Cancel a timer
    pub fn cancelTimer(self: *Self, entry: *TimerEntry) void {
        self.timer_mutex.lock();
        defer self.timer_mutex.unlock();
        self.timer_wheel.remove(entry);
    }

    /// Get current monotonic time from timer wheel
    pub fn now(self: *Self) u64 {
        self.timer_mutex.lock();
        defer self.timer_mutex.unlock();
        return self.timer_wheel.now();
    }

    /// Get number of active timers
    pub fn activeTimers(self: *Self) usize {
        self.timer_mutex.lock();
        defer self.timer_mutex.unlock();
        return self.timer_wheel.len();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // I/O Operations
    // ─────────────────────────────────────────────────────────────────────────

    /// Poll I/O completions (thread-safe, non-blocking)
    /// Returns number of completions processed
    pub fn pollIo(self: *Self) usize {
        // Try to acquire the I/O mutex (non-blocking)
        if (!self.io_mutex.tryLock()) {
            return 0; // Another worker is polling
        }
        defer self.io_mutex.unlock();

        // Poll for completions (non-blocking, timeout = 0)
        const count = self.backend.wait(self.completions, 0) catch return 0;

        // Process completions
        for (self.completions[0..count]) |completion| {
            self.processCompletion(completion);
        }

        if (count > 0) {
            _ = self.io_completions_processed.fetchAdd(count, .monotonic);
        }

        return count;
    }

    /// Poll I/O completions with timeout (for parking)
    /// Only call this when worker is parking (will block)
    pub fn pollIoBlocking(self: *Self, timeout_ns: u64) usize {
        self.io_mutex.lock();
        defer self.io_mutex.unlock();

        const timeout_ms: u32 = @intCast(@min(timeout_ns / std.time.ns_per_ms, std.math.maxInt(u32)));
        const count = self.backend.wait(self.completions, timeout_ms) catch return 0;

        // Process completions
        for (self.completions[0..count]) |completion| {
            self.processCompletion(completion);
        }

        if (count > 0) {
            _ = self.io_completions_processed.fetchAdd(count, .monotonic);
        }

        return count;
    }

    /// Process a single I/O completion (wake associated task)
    fn processCompletion(self: *Self, completion: Completion) void {
        // User data contains the task header pointer
        if (completion.user_data != 0) {
            const task: *Header = @ptrFromInt(completion.user_data);

            // Store the I/O result in the task for later retrieval
            // (This assumes tasks have a way to receive I/O results)

            // Wake the task by scheduling it
            if (task.transitionToScheduled()) {
                task.ref();
                self.global_queue.push(task);
                self.wakeWorkerIfNeeded();
            }
        }
    }

    /// Submit an I/O operation (returns submission ID for tracking)
    pub fn submitIo(self: *Self, op: Operation) !backend_mod.SubmissionId {
        self.io_mutex.lock();
        defer self.io_mutex.unlock();
        return self.backend.submit(op);
    }

    /// Submit multiple I/O operations
    pub fn submitIoBatch(self: *Self, ops: []const Operation) !void {
        self.io_mutex.lock();
        defer self.io_mutex.unlock();
        for (ops) |op| {
            _ = try self.backend.submit(op);
        }
    }

    /// Get active I/O backend type (for diagnostics)
    pub fn getBackendType(self: *const Self) BackendType {
        return @as(BackendType, self.backend);
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Thread-local Context
// ═══════════════════════════════════════════════════════════════════════════════

threadlocal var current_worker_idx: ?usize = null;
threadlocal var current_scheduler: ?*Scheduler = null;

pub fn getCurrentWorkerIndex() ?usize {
    return current_worker_idx;
}

pub fn getCurrentScheduler() ?*Scheduler {
    return current_scheduler;
}

pub fn setCurrentContext(scheduler: *Scheduler, worker_idx: usize) void {
    current_scheduler = scheduler;
    current_worker_idx = worker_idx;
}

pub fn clearCurrentContext() void {
    current_scheduler = null;
    current_worker_idx = null;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

test "Scheduler - create and destroy" {
    const allocator = std.testing.allocator;

    stack_pool.initGlobalDefault();
    defer stack_pool.deinitGlobal();

    const sched = try Scheduler.init(allocator, .{ .num_workers = 2 });
    defer sched.deinit();

    try std.testing.expectEqual(@as(usize, 2), sched.workers.len);
}

test "Scheduler - spawn task" {
    const allocator = std.testing.allocator;

    stack_pool.initGlobalDefault();
    defer stack_pool.deinitGlobal();

    const sched = try Scheduler.init(allocator, .{ .num_workers = 1 });
    defer sched.deinit();

    const vtable = Header.VTable{
        .poll = struct {
            fn f(_: *Header) Header.PollResult {
                return .complete;
            }
        }.f,
        .drop = struct {
            fn f(_: *Header) void {}
        }.f,
        .schedule = struct {
            fn f(_: *Header) void {}
        }.f,
    };

    var header = Header.init(&vtable);
    sched.spawn(&header);

    try std.testing.expectEqual(@as(u64, 1), sched.total_spawned.load(.acquire));
}

test "Worker - LIFO slot with transition check" {
    const allocator = std.testing.allocator;

    stack_pool.initGlobalDefault();
    defer stack_pool.deinitGlobal();

    const sched = try Scheduler.init(allocator, .{ .num_workers = 1 });
    defer sched.deinit();

    var worker = &sched.workers[0];

    const vtable = Header.VTable{
        .poll = struct {
            fn f(_: *Header) Header.PollResult {
                return .complete;
            }
        }.f,
        .drop = struct {
            fn f(_: *Header) void {}
        }.f,
        .schedule = struct {
            fn f(_: *Header) void {}
        }.f,
    };

    var h1 = Header.init(&vtable);

    // Should succeed when not transitioning
    try std.testing.expect(worker.tryScheduleLocal(&h1));
    try std.testing.expectEqual(&h1, worker.lifo_slot.load(.acquire));

    // Set transitioning flag
    worker.transitioning_to_park.store(true, .seq_cst);

    var h2 = Header.init(&vtable);

    // Should fail when transitioning
    try std.testing.expect(!worker.tryScheduleLocal(&h2));

    worker.transitioning_to_park.store(false, .seq_cst);
}

test "Scheduler - start and shutdown" {
    const allocator = std.testing.allocator;

    stack_pool.initGlobalDefault();
    defer stack_pool.deinitGlobal();

    const sched = try Scheduler.init(allocator, .{ .num_workers = 2 });
    defer sched.deinit();

    try sched.startAndWait();

    for (sched.workers) |*worker| {
        try std.testing.expect(worker.running.load(.acquire));
    }

    sched.shutdownAndWait();

    for (sched.workers) |*worker| {
        try std.testing.expect(!worker.running.load(.acquire));
    }
}

test "IdleState - bitmap operations" {
    var idle = IdleState.init(4);

    // Initially no workers parked
    try std.testing.expect(idle.findParkedWorker() == null);
    try std.testing.expectEqual(@as(u32, 0), idle.getParkedCount());

    // Park worker 2
    idle.workerParking(2);
    try std.testing.expectEqual(@as(u32, 1), idle.getParkedCount());
    try std.testing.expect(idle.isWorkerParked(2));
    try std.testing.expectEqual(@as(usize, 2), idle.findParkedWorker().?);

    // Park worker 0 (lower ID - should be found first due to @ctz)
    idle.workerParking(0);
    try std.testing.expectEqual(@as(u32, 2), idle.getParkedCount());
    try std.testing.expectEqual(@as(usize, 0), idle.findParkedWorker().?);

    // Unpark worker 0
    idle.workerUnparking(0);
    try std.testing.expectEqual(@as(usize, 2), idle.findParkedWorker().?);
}

test "IdleState - searcher limiting" {
    var idle = IdleState.init(4);

    // Max 2 searchers (50% of 4)
    try std.testing.expect(idle.tryBecomeSearcher(2));
    try std.testing.expect(idle.tryBecomeSearcher(2));
    try std.testing.expect(!idle.tryBecomeSearcher(2)); // Should fail

    idle.stopSearching();
    try std.testing.expect(idle.tryBecomeSearcher(2)); // Should work now
}

test "Config - auto workers" {
    const config = Config{};
    const num = config.getNumWorkers();
    try std.testing.expect(num >= 1);
}

test "Cooperative budget constants" {
    try std.testing.expectEqual(@as(u32, 128), BUDGET_PER_TICK);
    try std.testing.expectEqual(@as(u8, 3), MAX_LIFO_POLLS_PER_TICK);
    try std.testing.expectEqual(@as(usize, 64), MAX_GLOBAL_QUEUE_BATCH_SIZE);
}
