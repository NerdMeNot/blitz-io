//! Worker Thread Management
//!
//! ┌─────────────────────────────────────────────────────────────────────────┐
//! │ WORKER ARCHITECTURE                                                     │
//! ├─────────────────────────────────────────────────────────────────────────┤
//! │                                                                         │
//! │  Each Worker owns:                                                      │
//! │  ┌─────────────────────────────────────────────────────────────────┐   │
//! │  │ • Local Queue (256 slots + LIFO slot)                          │   │
//! │  │ • Global Batch Buffer (32 pre-fetched tasks)                   │   │
//! │  │ • Parking State (futex-based sleep/wake)                       │   │
//! │  │ • Metrics (tasks polled, stolen, park count)                   │   │
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
//! │  3. Batch Global Queue (GLOBAL_QUEUE_BATCH_SIZE = 32)                   │
//! │     → Reduces mutex contention by amortizing lock acquisition          │
//! │                                                                         │
//! │  4. Searcher Limiting (~50% of workers)                                 │
//! │     → Prevents thundering herd when work appears                       │
//! │                                                                         │
//! │  5. Parked Worker Bitmap (64-bit, O(1) lookup via @ctz)                │
//! │     → Efficiently find and wake exactly one parked worker              │
//! │                                                                         │
//! │  6. Adaptive Global Queue Interval                                      │
//! │     → Check frequency scales with worker count                         │
//! │                                                                         │
//! └─────────────────────────────────────────────────────────────────────────┘
//!
//! Reference: tokio/src/runtime/scheduler/multi_thread/worker.rs

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const Header = @import("task.zig").Header;
const LocalQueue = @import("local_queue.zig").LocalQueue;
const GlobalQueue = @import("global_queue.zig").GlobalQueue;
const ShardedGlobalQueue = @import("global_queue.zig").ShardedGlobalQueue;

// ─────────────────────────────────────────────────────────────────────────────
// Cooperative Scheduling Constants (from Tokio)
// ─────────────────────────────────────────────────────────────────────────────

/// Maximum number of task polls per maintenance tick
/// Prevents a single task from hogging the worker
/// Tokio uses 128 as default
pub const BUDGET_PER_TICK: u32 = 128;

/// Maximum consecutive LIFO slot polls before forcing queue check
/// Prevents LIFO slot from starving main queue tasks
/// Tokio uses 3-4 as default
pub const MAX_LIFO_POLLS_PER_TICK: u8 = 3;

/// Maximum tasks to pull from global queue in one batch
/// Actual batch size is adaptive based on queue depth
pub const MAX_GLOBAL_QUEUE_BATCH_SIZE: usize = 64;

/// Minimum batch size (to amortize lock cost)
pub const MIN_GLOBAL_QUEUE_BATCH_SIZE: usize = 4;

// Legacy alias for compatibility
pub const GLOBAL_QUEUE_BATCH_SIZE: usize = 32;

/// Maximum number of workers (for bitmap tracking)
pub const MAX_WORKERS: usize = 64;

// ─────────────────────────────────────────────────────────────────────────────
// Adaptive Global Queue Interval (inspired by Tokio's self-tuning)
// ─────────────────────────────────────────────────────────────────────────────

/// Target latency for checking global queue (1ms)
/// We want to check global queue at least this often to prevent starvation
const TARGET_GLOBAL_QUEUE_LATENCY_NS: u64 = 1_000_000;

/// EWMA smoothing factor (0.1 = 10% weight to new sample)
/// Lower values = more stable, higher values = more responsive
const EWMA_ALPHA: f64 = 0.1;

/// Minimum global queue check interval (prevent constant checking)
const MIN_GLOBAL_QUEUE_INTERVAL: u32 = 8;

/// Maximum global queue check interval (prevent starvation)
const MAX_GLOBAL_QUEUE_INTERVAL: u32 = 255;

/// Default initial estimate for task poll time (50µs)
const DEFAULT_AVG_TASK_NS: u64 = 50_000;

/// Worker state
pub const Worker = struct {
    const Self = @This();

    /// Worker ID (0-indexed)
    id: usize,

    /// Local task queue
    local_queue: LocalQueue,

    /// Thread handle (null until started)
    thread: ?std.Thread,

    /// Parking state
    park_state: ParkState,

    /// Metrics
    tasks_polled: std.atomic.Value(u64),
    tasks_stolen: std.atomic.Value(u64),
    times_parked: std.atomic.Value(u64),

    /// Shutdown flag
    shutdown: *std.atomic.Value(bool),

    /// Pointer to shared state (set after init)
    shared: ?*SharedState,

    /// Tick counter for adaptive global queue checking
    tick: u32,

    /// Cooperative budget: remaining polls this tick
    /// Reset to BUDGET_PER_TICK after maintenance/parking
    budget: u32,

    /// LIFO polls this tick - limited to prevent starvation
    lifo_polls_this_tick: u8,

    /// CRITICAL: Flag indicating worker is transitioning to parked state
    /// Set BEFORE flushing LIFO, cleared AFTER waking.
    /// Schedulers MUST check this before pushing to LIFO to avoid lost wakeups.
    /// Uses seq_cst ordering to ensure visibility across all threads.
    transitioning_to_park: std.atomic.Value(bool),

    // === Adaptive Global Queue Interval (Tokio-style self-tuning) ===

    /// EWMA of task poll time in nanoseconds
    /// Used to calculate how often to check global queue
    avg_task_ns: u64,

    /// Calculated global queue check interval (adaptive)
    /// Updated after each batch based on avg_task_ns
    global_queue_interval: u32,

    /// Timestamp of batch start for measuring poll times
    batch_start_ns: i128,

    /// Buffer for batch global queue pulls
    global_batch_buffer: [GLOBAL_QUEUE_BATCH_SIZE]?*Header,

    /// Current position in batch buffer
    global_batch_pos: usize,

    /// Number of tasks in batch buffer
    global_batch_len: usize,

    /// Parking mechanism
    pub const ParkState = struct {
        /// Is worker currently parked?
        parked: std.atomic.Value(bool),

        /// Futex word for parking
        futex: std.atomic.Value(u32),

        const UNPARKED: u32 = 0;
        const PARKED: u32 = 1;
        const NOTIFIED: u32 = 2;

        pub fn init() ParkState {
            return .{
                .parked = std.atomic.Value(bool).init(false),
                .futex = std.atomic.Value(u32).init(UNPARKED),
            };
        }

        /// Park the worker until notified or timeout
        pub fn park(self: *ParkState, timeout_ns: ?u64) void {
            self.parked.store(true, .release);

            // Try to transition to PARKED
            const expected: u32 = UNPARKED;
            const result = self.futex.cmpxchgStrong(
                expected,
                PARKED,
                .acq_rel,
                .acquire,
            );

            if (result == null) {
                // Successfully set to PARKED, now wait
                if (timeout_ns) |ns| {
                    // Use timedWait for timeout
                    std.Thread.Futex.timedWait(&self.futex, PARKED, ns) catch {};
                } else {
                    // Wait indefinitely
                    std.Thread.Futex.wait(&self.futex, PARKED);
                }
            }

            // Reset state
            self.futex.store(UNPARKED, .release);
            self.parked.store(false, .release);
        }

        /// Unpark the worker
        pub fn unpark(self: *ParkState) void {
            // Set to NOTIFIED (wakes if parked, prevents parking if about to)
            const prev = self.futex.swap(NOTIFIED, .acq_rel);

            if (prev == PARKED) {
                // Worker was parked, wake it
                std.Thread.Futex.wake(&self.futex, 1);
            }
        }

        /// Check if parked
        pub fn isParked(self: *const ParkState) bool {
            return self.parked.load(.acquire);
        }
    };

    /// Create a new worker
    pub fn init(id: usize, shutdown: *std.atomic.Value(bool)) Self {
        var worker = Self{
            .id = id,
            .local_queue = LocalQueue.init(),
            .thread = null,
            .park_state = ParkState.init(),
            .tasks_polled = std.atomic.Value(u64).init(0),
            .tasks_stolen = std.atomic.Value(u64).init(0),
            .times_parked = std.atomic.Value(u64).init(0),
            .shutdown = shutdown,
            .shared = null,
            .tick = 0,
            .budget = BUDGET_PER_TICK,
            .lifo_polls_this_tick = 0,
            .transitioning_to_park = std.atomic.Value(bool).init(false),
            // Adaptive global queue interval
            .avg_task_ns = DEFAULT_AVG_TASK_NS,
            .global_queue_interval = 61, // Tokio's default
            .batch_start_ns = 0,
            .global_batch_buffer = undefined,
            .global_batch_pos = 0,
            .global_batch_len = 0,
        };

        // Initialize batch buffer to null
        for (&worker.global_batch_buffer) |*slot| {
            slot.* = null;
        }

        return worker;
    }

    /// Set shared state (called by scheduler)
    pub fn setShared(self: *Self, shared: *SharedState) void {
        self.shared = shared;
    }

    /// Start the worker thread
    pub fn start(self: *Self) !void {
        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    /// Wait for the worker thread to finish
    pub fn join(self: *Self) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// Wake the worker if parked
    pub fn wake(self: *Self) void {
        self.park_state.unpark();
    }

    /// Check if the worker is parked
    pub fn isParked(self: *const Self) bool {
        return self.park_state.isParked();
    }

    /// Push a task to this worker's local queue
    /// Returns false if full
    pub fn push(self: *Self, task: *Header) bool {
        return self.local_queue.push(task);
    }

    /// Push to LIFO slot (preferred for locality)
    /// IMPORTANT: Check canPushToLifo() first to avoid lost wakeup race!
    pub fn pushLifo(self: *Self, task: *Header) ?*Header {
        return self.local_queue.pushLifo(task);
    }

    /// Check if it's safe to push to this worker's LIFO slot
    /// Returns false if worker is transitioning to parked state (use global queue instead)
    pub fn canPushToLifo(self: *const Self) bool {
        return !self.transitioning_to_park.load(.seq_cst);
    }

    /// Safe push to LIFO - checks transition flag first, returns false if should use global
    /// This is the preferred method for schedulers to use
    pub fn tryPushLifo(self: *Self, task: *Header) bool {
        // Check if worker is transitioning to park - if so, don't use LIFO
        if (self.transitioning_to_park.load(.seq_cst)) {
            return false; // Caller should use global queue
        }

        // Push to LIFO
        const overflow = self.local_queue.pushLifo(task);
        if (overflow) |overflow_task| {
            // LIFO overflowed, push overflow to main buffer
            if (!self.local_queue.push(overflow_task)) {
                // Main buffer also full - this shouldn't happen normally
                // but if it does, the caller will get the task back
                return false;
            }
        }
        return true;
    }

    /// Main worker loop
    fn workerMain(self: *Self) void {
        // Set thread-local worker ID
        current_worker_id = self.id;

        while (!self.shutdown.load(.acquire)) {
            self.tick +%= 1;

            // Record batch start time for adaptive interval calculation
            self.batch_start_ns = std.time.nanoTimestamp();

            // Run tasks until budget exhausted or no work available
            var tasks_run: u32 = 0;
            while (self.budget > 0) {
                // Try to get work
                if (self.findWork()) |task| {
                    self.runTask(task);
                    self.budget -|= 1;
                    tasks_run += 1;
                    continue;
                }
                break;
            }

            // Update adaptive interval based on how long this batch took
            self.updateAdaptiveInterval(tasks_run);

            // Maintenance cycle: reset budget and counters
            self.maintenanceCycle();

            if (tasks_run == 0) {
                // No work found - park with timeout
                // Timeout prevents missing wake-ups and allows periodic I/O polling
                _ = self.times_parked.fetchAdd(1, .monotonic);

                // CRITICAL FIX FOR LOST WAKEUP RACE:
                // Set transitioning flag BEFORE flush with seq_cst ordering.
                // This tells schedulers "don't push to my LIFO, use global queue".
                // Without this, a task could be pushed to LIFO between flush and park.
                self.transitioning_to_park.store(true, .seq_cst);

                // Flush LIFO stack to main buffer so tasks are stealable
                _ = self.local_queue.flushLifoToBuffer();

                // Double-check: if new work arrived during flush, don't park
                if (!self.local_queue.isEmpty()) {
                    self.transitioning_to_park.store(false, .seq_cst);
                    self.budget = BUDGET_PER_TICK;
                    continue;
                }

                // Transition to parked state in idle tracking
                if (self.shared) |shared| {
                    shared.idle_state.workerParking(self.id);
                }

                self.park_state.park(10 * std.time.ns_per_ms); // 10ms timeout

                // Transition back to running - clear the flag AFTER waking
                self.transitioning_to_park.store(false, .seq_cst);

                if (self.shared) |shared| {
                    shared.idle_state.workerUnparking(self.id);
                }

                // Reset budget after waking
                self.budget = BUDGET_PER_TICK;
            }
        }
    }

    /// Periodic maintenance: reset counters, check timers, flush metrics
    fn maintenanceCycle(self: *Self) void {
        // Reset cooperative budgeting state
        self.budget = BUDGET_PER_TICK;
        self.lifo_polls_this_tick = 0;

        // Clear any remaining items in global batch buffer
        // (shouldn't happen normally, but defensive)
        self.global_batch_pos = 0;
        self.global_batch_len = 0;
    }

    /// Update adaptive global queue interval based on measured task poll times.
    /// Uses EWMA (Exponentially Weighted Moving Average) for stability.
    ///
    /// The goal: Check global queue approximately every TARGET_GLOBAL_QUEUE_LATENCY_NS.
    /// - Short tasks → check more often (more tasks fit in the target latency)
    /// - Long tasks → check less often (fewer tasks fit)
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
        self.avg_task_ns = @max(1, new_avg); // Prevent division by zero

        // Calculate new interval: how many tasks fit in TARGET_GLOBAL_QUEUE_LATENCY_NS?
        const tasks_per_target = TARGET_GLOBAL_QUEUE_LATENCY_NS / self.avg_task_ns;
        const clamped = @min(MAX_GLOBAL_QUEUE_INTERVAL, @max(MIN_GLOBAL_QUEUE_INTERVAL, tasks_per_target));
        self.global_queue_interval = @intCast(clamped);
    }

    /// Get current adaptive global queue interval
    fn getGlobalQueueInterval(self: *const Self) u32 {
        return self.global_queue_interval;
    }

    /// Calculate global queue check interval based on worker count
    /// Higher worker counts = less frequent checks to reduce contention
    fn globalQueueInterval(num_workers: usize) u32 {
        // Tokio uses 61 as base (prime for better distribution)
        // Scale with worker count
        return @intCast(@min(61, 31 + num_workers));
    }

    /// Find work from any source
    fn findWork(self: *Self) ?*Header {
        const shared = self.shared orelse return null;

        // 1. Check buffered global queue batch first
        if (self.pollGlobalBatch()) |task| {
            return task;
        }

        // 2. Check local queue with LIFO limiting
        if (self.pollLocalQueue()) |task| {
            return task;
        }

        // 3. Check global queue periodically using ADAPTIVE interval
        // The interval self-tunes based on measured task poll times:
        // - Short tasks → check more often (every 8-20 ticks)
        // - Long tasks → check less often (up to every 255 ticks)
        // This prevents starvation while minimizing lock contention.
        if (self.tick % self.global_queue_interval == 0) {
            if (self.fetchGlobalBatch(shared)) |task| {
                return task;
            }
        }

        // 4. Try stealing from other workers (with searcher limiting)
        if (self.tryStealWithLimit(shared)) |task| {
            _ = self.tasks_stolen.fetchAdd(1, .monotonic);
            return task;
        }

        // 5. Final check of global queue before parking
        if (self.fetchGlobalBatch(shared)) |task| {
            return task;
        }

        return null;
    }

    /// Poll local queue with LIFO limiting
    /// After MAX_LIFO_POLLS_PER_TICK, skip LIFO slot to prevent starvation
    fn pollLocalQueue(self: *Self) ?*Header {
        // Check if we should limit LIFO polls
        if (self.lifo_polls_this_tick < MAX_LIFO_POLLS_PER_TICK) {
            // Normal path: check LIFO slot first
            if (self.local_queue.pop()) |task| {
                // Track if this came from LIFO slot (heuristic: was empty before)
                self.lifo_polls_this_tick +|= 1;
                return task;
            }
        } else {
            // LIFO limited: bypass LIFO slot, go direct to buffer
            if (self.local_queue.popFromBuffer()) |task| {
                return task;
            }
        }
        return null;
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

    /// Calculate optimal batch size based on queue depth and worker count
    /// IMPROVEMENT OVER TOKIO: Adaptive batch sizing for better load distribution
    fn optimalBatchSize(global_len: usize, num_workers: usize) usize {
        // Aim for fair distribution with min/max bounds
        const fair_share = global_len / @max(1, num_workers);
        return @min(MAX_GLOBAL_QUEUE_BATCH_SIZE, @max(MIN_GLOBAL_QUEUE_BATCH_SIZE, fair_share));
    }

    /// Fetch a batch of tasks from global queue (reduces lock contention)
    fn fetchGlobalBatch(self: *Self, shared: *SharedState) ?*Header {
        // IMPROVEMENT: Adaptive batch size based on queue depth
        const global_len = shared.global_queue.len();
        const batch_size = optimalBatchSize(global_len, shared.workers.len);
        const popped = shared.global_queue.popBatch(&self.global_batch_buffer, batch_size);

        if (popped == 0) {
            return null;
        }

        // Return first task, rest go to buffer
        const first = self.global_batch_buffer[0];
        self.global_batch_buffer[0] = null;

        if (popped > 1) {
            self.global_batch_pos = 1;
            self.global_batch_len = popped;
        } else {
            self.global_batch_pos = 0;
            self.global_batch_len = 0;
        }

        return first;
    }

    /// Try to steal work with searcher limiting
    /// Only allows ~50% of workers to be searching at once
    fn tryStealWithLimit(self: *Self, shared: *SharedState) ?*Header {
        const num_workers = shared.workers.len;
        if (num_workers <= 1) return null;

        // Check if we can become a searcher
        const max_searchers = @max(1, num_workers / 2);
        const current_searchers = shared.idle_state.num_searching.load(.acquire);

        if (current_searchers >= max_searchers) {
            // Too many searchers already - back off
            return null;
        }

        // Try to become a searcher
        const prev = shared.idle_state.num_searching.fetchAdd(1, .acq_rel);
        if (prev >= max_searchers) {
            // Lost race - undo and back off
            _ = shared.idle_state.num_searching.fetchSub(1, .release);
            return null;
        }

        // We're now a searcher - try to steal
        defer {
            _ = shared.idle_state.num_searching.fetchSub(1, .release);
        }

        return self.trySteal(shared);
    }

    /// Try to steal work from another worker
    fn trySteal(self: *Self, shared: *SharedState) ?*Header {
        const num_workers = shared.workers.len;

        // Start from a different victim each time to avoid contention
        // Use tick as randomization source
        var victim_start = (self.id + @as(usize, @intCast(self.tick))) % num_workers;

        for (0..num_workers - 1) |_| {
            const victim_id = victim_start;
            victim_start = (victim_start + 1) % num_workers;

            if (victim_id == self.id) continue;

            // Try to steal one task
            if (shared.workers[victim_id].local_queue.steal()) |task| {
                return task;
            }
        }

        return null;
    }

    /// Execute a task
    fn runTask(self: *Self, task: *Header) void {
        _ = self.tasks_polled.fetchAdd(1, .monotonic);

        // Poll the task
        const complete = task.poll();

        if (!complete) {
            // Task yielded - it will be re-scheduled by its waker
            // when the I/O it's waiting on completes
        }
        // If complete, the task's drop function will handle cleanup
    }

    /// Get metrics for this worker
    pub fn getMetrics(self: *const Self) Metrics {
        return .{
            .tasks_polled = self.tasks_polled.load(.monotonic),
            .tasks_stolen = self.tasks_stolen.load(.monotonic),
            .times_parked = self.times_parked.load(.monotonic),
            .queue_depth = self.local_queue.len(),
        };
    }

    pub const Metrics = struct {
        tasks_polled: u64,
        tasks_stolen: u64,
        times_parked: u64,
        queue_depth: usize,
    };
};

/// Idle coordination state (from Tokio's idle.rs)
/// Tracks searching workers to prevent thundering herd
pub const IdleState = struct {
    /// Number of workers currently searching for work
    num_searching: std.atomic.Value(u32),

    /// Number of workers currently parked (sleeping)
    num_parked: std.atomic.Value(u32),

    /// Bitmap of parked workers (for selective waking)
    /// Each bit represents one worker: 1 = parked, 0 = running
    parked_bitmap: std.atomic.Value(u64),

    /// Total number of workers
    num_workers: u32,

    pub fn init(num_workers: u32) IdleState {
        return .{
            .num_searching = std.atomic.Value(u32).init(0),
            .num_parked = std.atomic.Value(u32).init(0),
            .parked_bitmap = std.atomic.Value(u64).init(0),
            .num_workers = num_workers,
        };
    }

    /// Check if we should wake a worker (fast path)
    pub fn shouldWakeWorker(self: *const IdleState) bool {
        // If no searchers, we should wake someone
        return self.num_searching.load(.acquire) == 0;
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

    /// Find a parked worker to wake (returns worker ID or null)
    pub fn findParkedWorker(self: *const IdleState) ?usize {
        const bitmap = self.parked_bitmap.load(.acquire);
        if (bitmap == 0) return null;

        // Find lowest set bit (first parked worker)
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

    /// Check if all workers are idle (parked or searching)
    pub fn allIdle(self: *const IdleState) bool {
        const parked = self.num_parked.load(.acquire);
        const searching = self.num_searching.load(.acquire);
        return parked + searching >= self.num_workers;
    }
};

/// Shared state between workers
pub const SharedState = struct {
    workers: []Worker,
    global_queue: ShardedGlobalQueue,
    idle_state: IdleState,
};

/// Thread-local worker ID (UNSET_WORKER_ID means not a worker thread)
const UNSET_WORKER_ID: usize = std.math.maxInt(usize);
threadlocal var current_worker_id: usize = UNSET_WORKER_ID;

/// Get the current worker ID
/// Returns UNSET_WORKER_ID if not on a worker thread
pub fn getCurrentWorkerId() usize {
    return current_worker_id;
}

/// Check if current thread is a worker thread
pub fn isWorkerThread() bool {
    return current_worker_id != UNSET_WORKER_ID;
}

/// Placeholder - actual count from scheduler
pub var global_worker_count: usize = 0;

fn getWorkerCount() usize {
    return global_worker_count;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "Worker - init" {
    var shutdown = std.atomic.Value(bool).init(false);
    var worker = Worker.init(0, &shutdown);

    try std.testing.expectEqual(@as(usize, 0), worker.id);
    try std.testing.expect(worker.thread == null);
    try std.testing.expect(worker.local_queue.isEmpty());
    try std.testing.expectEqual(@as(u32, 0), worker.tick);
}

test "Worker - push to local queue" {
    var shutdown = std.atomic.Value(bool).init(false);
    var worker = Worker.init(0, &shutdown);

    var header = Header.init(&dummy_vtable, 1);

    try std.testing.expect(worker.push(&header));
    try std.testing.expectEqual(@as(usize, 1), worker.local_queue.len());
}

test "Worker - push to LIFO slot" {
    var shutdown = std.atomic.Value(bool).init(false);
    var worker = Worker.init(0, &shutdown);

    var header = Header.init(&dummy_vtable, 1);

    // LIFO push should not overflow
    try std.testing.expect(worker.pushLifo(&header) == null);
    try std.testing.expect(!worker.local_queue.isLifoEmpty());
}

test "Worker.ParkState - unpark without park" {
    var state = Worker.ParkState.init();

    // Should not hang
    state.unpark();
    try std.testing.expect(!state.isParked());
}

test "Worker.ParkState - park with immediate unpark" {
    var state = Worker.ParkState.init();

    // Pre-notify
    state.unpark();

    // Park should return immediately
    state.park(null);
    try std.testing.expect(!state.isParked());
}

test "Worker - metrics" {
    var shutdown = std.atomic.Value(bool).init(false);
    var worker = Worker.init(1, &shutdown);

    const metrics = worker.getMetrics();
    try std.testing.expectEqual(@as(u64, 0), metrics.tasks_polled);
    try std.testing.expectEqual(@as(u64, 0), metrics.tasks_stolen);
    try std.testing.expectEqual(@as(usize, 0), metrics.queue_depth);
}

test "globalQueueInterval - scales with workers" {
    try std.testing.expectEqual(@as(u32, 32), Worker.globalQueueInterval(1));
    try std.testing.expectEqual(@as(u32, 35), Worker.globalQueueInterval(4));
    try std.testing.expectEqual(@as(u32, 39), Worker.globalQueueInterval(8));
    try std.testing.expectEqual(@as(u32, 61), Worker.globalQueueInterval(100));
}

test "IdleState - init" {
    const idle = IdleState.init(4);
    try std.testing.expectEqual(@as(u32, 0), idle.num_searching.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), idle.num_parked.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), idle.parked_bitmap.load(.acquire));
    try std.testing.expectEqual(@as(u32, 4), idle.num_workers);
}

test "IdleState - shouldWakeWorker" {
    var idle = IdleState.init(4);

    // No searchers - should wake
    try std.testing.expect(idle.shouldWakeWorker());

    // Add a searcher
    _ = idle.num_searching.fetchAdd(1, .release);
    try std.testing.expect(!idle.shouldWakeWorker());
}

test "IdleState - parking and unparking" {
    var idle = IdleState.init(4);

    // Initially no workers parked
    try std.testing.expect(idle.findParkedWorker() == null);
    try std.testing.expectEqual(@as(u32, 0), idle.getParkedCount());

    // Park worker 2
    idle.workerParking(2);
    try std.testing.expectEqual(@as(u32, 1), idle.getParkedCount());
    try std.testing.expect(idle.isWorkerParked(2));
    try std.testing.expect(!idle.isWorkerParked(0));
    try std.testing.expect(!idle.isWorkerParked(1));
    try std.testing.expect(!idle.isWorkerParked(3));

    // findParkedWorker should return 2
    try std.testing.expectEqual(@as(usize, 2), idle.findParkedWorker().?);

    // Park worker 0 (lower ID)
    idle.workerParking(0);
    try std.testing.expectEqual(@as(u32, 2), idle.getParkedCount());
    // Should now find worker 0 (lowest set bit)
    try std.testing.expectEqual(@as(usize, 0), idle.findParkedWorker().?);

    // Unpark worker 0
    idle.workerUnparking(0);
    try std.testing.expectEqual(@as(u32, 1), idle.getParkedCount());
    try std.testing.expectEqual(@as(usize, 2), idle.findParkedWorker().?);

    // Unpark worker 2
    idle.workerUnparking(2);
    try std.testing.expectEqual(@as(u32, 0), idle.getParkedCount());
    try std.testing.expect(idle.findParkedWorker() == null);
}

test "IdleState - allIdle" {
    var idle = IdleState.init(4);

    // Initially not all idle (none parked, none searching = 0 < 4)
    try std.testing.expect(!idle.allIdle());

    // Park 2 workers -> 2 < 4, not all idle
    idle.workerParking(0);
    idle.workerParking(1);
    try std.testing.expect(!idle.allIdle());

    // Park 2 more -> 4 >= 4, all idle
    idle.workerParking(2);
    idle.workerParking(3);
    try std.testing.expect(idle.allIdle());

    // Unpark one, add searcher -> 3 parked + 1 searching = 4, still all idle
    idle.workerUnparking(3);
    _ = idle.num_searching.fetchAdd(1, .release);
    try std.testing.expect(idle.allIdle());
}

test "Worker - cooperative budget initialization" {
    var shutdown = std.atomic.Value(bool).init(false);
    const worker = Worker.init(0, &shutdown);

    // Verify initial cooperative budgeting state
    try std.testing.expectEqual(BUDGET_PER_TICK, worker.budget);
    try std.testing.expectEqual(@as(u8, 0), worker.lifo_polls_this_tick);
    try std.testing.expectEqual(@as(usize, 0), worker.global_batch_pos);
    try std.testing.expectEqual(@as(usize, 0), worker.global_batch_len);
}

const dummy_vtable = Header.VTable{
    .poll = struct {
        fn f(_: *Header) bool {
            return true;
        }
    }.f,
    .drop = struct {
        fn f(_: *Header) void {}
    }.f,
    .get_output = struct {
        fn f(_: *Header) ?*anyopaque {
            return null;
        }
    }.f,
    .schedule = struct {
        fn f(_: *Header) void {}
    }.f,
};
