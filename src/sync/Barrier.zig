//! Barrier - Synchronization Point for Multiple Tasks
//!
//! A barrier allows N tasks to synchronize at a common point. All tasks
//! must reach the barrier before any can proceed past it.
//!
//! ## Usage
//!
//! ```zig
//! var barrier = Barrier.init(3);  // 3 tasks must reach
//!
//! // Each task calls wait()
//! var waiter = Barrier.Waiter.init();
//! if (!barrier.wait(&waiter)) {
//!     // Yield, wait for notification
//! }
//! // All tasks proceed together
//!
//! // Check if this task was the leader (last to arrive)
//! if (waiter.is_leader.load(.acquire)) {
//!     // Do one-time work
//! }
//! ```
//!
//! ## Design
//!
//! - Counter tracks arrivals
//! - Last arrival wakes all waiters
//! - Barrier can be reused after all tasks pass
//!
//! Reference: tokio/src/sync/barrier.rs

const std = @import("std");

const LinkedList = @import("../util/linked_list.zig").LinkedList;
const Pointers = @import("../util/linked_list.zig").Pointers;
const WakeList = @import("../util/wake_list.zig").WakeList;
const InvocationId = @import("../util/invocation_id.zig").InvocationId;

// Unified waiter for the simple blocking API
const unified_waiter = @import("waiter.zig");
const UnifiedWaiter = unified_waiter.Waiter;

// ─────────────────────────────────────────────────────────────────────────────
// Waiter
// ─────────────────────────────────────────────────────────────────────────────

/// Function pointer type for waking
pub const WakerFn = *const fn (*anyopaque) void;

/// Waiter for barrier synchronization
pub const Waiter = struct {
    waker: ?WakerFn = null,
    waker_ctx: ?*anyopaque = null,

    /// Whether this waiter has been released (atomic for cross-thread visibility)
    released: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Whether this waiter was the leader (last to arrive) - atomic for cross-thread visibility
    is_leader: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Intrusive list pointers
    pointers: Pointers(Waiter) = .{},

    /// Debug-mode invocation tracking (detects use-after-free)
    invocation: InvocationId = .{},

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn setWaker(self: *Self, ctx: *anyopaque, wake_fn: WakerFn) void {
        self.waker_ctx = ctx;
        self.waker = wake_fn;
    }

    pub fn wake(self: *Self) void {
        if (self.waker) |wf| {
            if (self.waker_ctx) |ctx| {
                wf(ctx);
            }
        }
    }

    pub fn isReleased(self: *const Self) bool {
        return self.released.load(.seq_cst);
    }

    /// Get invocation token (for debug tracking)
    pub fn token(self: *const Self) InvocationId.Id {
        return self.invocation.get();
    }

    /// Verify invocation token matches (debug mode)
    pub fn verifyToken(self: *const Self, tok: InvocationId.Id) void {
        self.invocation.verify(tok);
    }

    /// Reset for reuse (generates new invocation ID)
    pub fn reset(self: *Self) void {
        self.released.store(false, .seq_cst);
        self.is_leader.store(false, .seq_cst);
        self.waker = null;
        self.waker_ctx = null;
        self.pointers.reset();
        self.invocation.bump();
    }
};

const WaiterList = LinkedList(Waiter, "pointers");

// ─────────────────────────────────────────────────────────────────────────────
// Barrier
// ─────────────────────────────────────────────────────────────────────────────

/// A synchronization barrier for N tasks.
pub const Barrier = struct {
    /// Number of tasks required to reach the barrier
    num_tasks: usize,

    /// Current generation (increments each time barrier is released)
    generation: usize,

    /// Number of tasks that have arrived at current generation
    arrived: usize,

    /// Mutex protecting internal state
    mutex: std.Thread.Mutex,

    /// Waiting tasks
    waiters: WaiterList,

    const Self = @This();

    /// Create a barrier for N tasks.
    pub fn init(num_tasks: usize) Self {
        std.debug.assert(num_tasks > 0);
        return .{
            .num_tasks = num_tasks,
            .generation = 0,
            .arrived = 0,
            .mutex = .{},
            .waiters = .{},
        };
    }

    /// Wait at the barrier.
    /// Returns true if this is the leader (last to arrive) and all released immediately.
    /// Returns false if waiting for others (task should yield).
    ///
    /// After waking, check waiter.is_leader to see if this task was last.
    pub fn wait(self: *Self, waiter: *Waiter) bool {
        var wake_list: WakeList(64) = .{};
        var is_leader = false;

        self.mutex.lock();

        const my_generation = self.generation;
        self.arrived += 1;

        if (self.arrived >= self.num_tasks) {
            // We're the last one - release everyone
            is_leader = true;

            // Wake all waiters
            // CRITICAL: Copy waker info BEFORE setting released flag to avoid use-after-free
            while (self.waiters.popFront()) |w| {
                const waker_fn = w.waker;
                const waker_ctx = w.waker_ctx;
                w.released.store(true, .seq_cst);
                w.is_leader.store(false, .seq_cst);
                if (waker_fn) |wf| {
                    if (waker_ctx) |ctx| {
                        wake_list.push(.{ .context = ctx, .wake_fn = wf });
                    }
                }
            }

            // Reset for next generation
            self.arrived = 0;
            self.generation +%= 1;

            self.mutex.unlock();

            // Wake all outside lock
            wake_list.wakeAll();

            // Leader returns immediately
            waiter.released.store(true, .seq_cst);
            waiter.is_leader.store(true, .seq_cst);
            return true;
        }

        // Not the last one - wait
        waiter.released.store(false, .seq_cst);
        waiter.is_leader.store(false, .seq_cst);
        self.waiters.pushBack(waiter);

        self.mutex.unlock();

        _ = my_generation;
        return false;
    }

    /// Get the number of tasks that have arrived at the current barrier.
    pub fn arrivedCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.arrived;
    }

    /// Get the total number of tasks required.
    pub fn totalTasks(self: *const Self) usize {
        return self.num_tasks;
    }

    /// Get the current generation (number of times barrier has been released).
    pub fn currentGeneration(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.generation;
    }

    /// Get number of waiters.
    pub fn waiterCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.waiters.count();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Blocking API (using unified Waiter)
    // ═══════════════════════════════════════════════════════════════════════

    /// Blocking wait at barrier.
    /// Uses the unified Waiter for proper yielding (task context) or blocking (thread context).
    ///
    /// Returns BarrierWaitResult indicating if this task was the leader (last to arrive).
    ///
    /// Example:
    /// ```zig
    /// const result = barrier.waitBlocking();
    /// if (result.is_leader) {
    ///     // This task was last to arrive - do one-time work
    /// }
    /// // All tasks proceed together
    /// ```
    pub fn waitBlocking(self: *Self) BarrierWaitResult {
        var wake_list: WakeList(64) = .{};
        var waiter = Waiter.init();

        // Set up waker bridge to unified waiter
        var unified = UnifiedWaiter.init();
        const WakerBridge = struct {
            fn wake(ctx: *anyopaque) void {
                const uw: *UnifiedWaiter = @ptrCast(@alignCast(ctx));
                uw.notify();
            }
        };
        waiter.setWaker(@ptrCast(&unified), WakerBridge.wake);

        self.mutex.lock();

        self.arrived += 1;

        if (self.arrived >= self.num_tasks) {
            // We're the last one - release everyone

            // Wake all waiters - copy waker info BEFORE setting released flag
            while (self.waiters.popFront()) |w| {
                const waker_fn = w.waker;
                const waker_ctx = w.waker_ctx;
                w.released.store(true, .seq_cst);
                w.is_leader.store(false, .seq_cst);
                if (waker_fn) |wf| {
                    if (waker_ctx) |ctx| {
                        wake_list.push(.{ .context = ctx, .wake_fn = wf });
                    }
                }
            }

            // Reset for next generation
            self.arrived = 0;
            self.generation +%= 1;

            self.mutex.unlock();

            // Wake all outside lock
            wake_list.wakeAll();

            // Leader returns immediately
            return .{ .is_leader = true };
        }

        // Not the last one - wait
        waiter.released.store(false, .seq_cst);
        waiter.is_leader.store(false, .seq_cst);
        self.waiters.pushBack(&waiter);

        self.mutex.unlock();

        // Wait until notified - yields in task context, blocks in thread context
        unified.wait();

        return .{ .is_leader = false };
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// BarrierWaitResult - for typed returns
// ─────────────────────────────────────────────────────────────────────────────

/// Result of waiting at a barrier.
pub const BarrierWaitResult = struct {
    /// Whether this task was the leader (last to arrive)
    is_leader: bool,
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "Barrier - single task" {
    var barrier = Barrier.init(1);

    var waiter = Waiter.init();
    const immediate = barrier.wait(&waiter);

    // Single task is always leader and returns immediately
    try std.testing.expect(immediate);
    try std.testing.expect(waiter.is_leader.load(.acquire));
    try std.testing.expect(waiter.isReleased());
}

test "Barrier - multiple tasks sync" {
    var barrier = Barrier.init(3);
    var woken: [2]bool = .{ false, false };

    const TestWaker = struct {
        fn wake(ctx: *anyopaque) void {
            const w: *bool = @ptrCast(@alignCast(ctx));
            w.* = true;
        }
    };

    // First two tasks wait
    var waiters: [2]Waiter = undefined;
    for (&waiters, 0..) |*w, i| {
        w.* = Waiter.init();
        w.setWaker(@ptrCast(&woken[i]), TestWaker.wake);
        const immediate = barrier.wait(w);
        try std.testing.expect(!immediate);
    }

    try std.testing.expectEqual(@as(usize, 2), barrier.arrivedCount());
    try std.testing.expectEqual(@as(usize, 2), barrier.waiterCount());

    // Third task arrives - all released
    var leader_waiter = Waiter.init();
    const immediate = barrier.wait(&leader_waiter);

    try std.testing.expect(immediate);
    try std.testing.expect(leader_waiter.is_leader.load(.acquire));

    // All others woken
    for (woken) |w| {
        try std.testing.expect(w);
    }
    for (&waiters) |*w| {
        try std.testing.expect(w.isReleased());
        try std.testing.expect(!w.is_leader.load(.acquire));
    }

    // Barrier reset
    try std.testing.expectEqual(@as(usize, 0), barrier.arrivedCount());
    try std.testing.expectEqual(@as(usize, 1), barrier.currentGeneration());
}

test "Barrier - reusable" {
    var barrier = Barrier.init(2);

    // First round
    var w1 = Waiter.init();
    try std.testing.expect(!barrier.wait(&w1));

    var w2 = Waiter.init();
    try std.testing.expect(barrier.wait(&w2));
    try std.testing.expect(w2.is_leader.load(.acquire));

    try std.testing.expectEqual(@as(usize, 1), barrier.currentGeneration());

    // Second round
    var w3 = Waiter.init();
    try std.testing.expect(!barrier.wait(&w3));

    var w4 = Waiter.init();
    try std.testing.expect(barrier.wait(&w4));
    try std.testing.expect(w4.is_leader.load(.acquire));

    try std.testing.expectEqual(@as(usize, 2), barrier.currentGeneration());
}

test "Barrier - only one leader" {
    var barrier = Barrier.init(3);

    var waiters: [3]Waiter = undefined;
    var leaders: usize = 0;

    for (&waiters) |*w| {
        w.* = Waiter.init();
        _ = barrier.wait(w);
        if (w.is_leader.load(.acquire)) leaders += 1;
    }

    try std.testing.expectEqual(@as(usize, 1), leaders);
}

test "Barrier - large task count" {
    // Test with many tasks arriving at the barrier
    const num_tasks = 100;
    var barrier = Barrier.init(num_tasks);
    var woken_count: usize = 0;

    const TestWaker = struct {
        fn wake(ctx: *anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(ctx));
            count.* += 1;
        }
    };

    var waiters: [num_tasks]Waiter = undefined;

    // First N-1 tasks wait
    for (0..num_tasks - 1) |i| {
        waiters[i] = Waiter.init();
        waiters[i].setWaker(@ptrCast(&woken_count), TestWaker.wake);
        const immediate = barrier.wait(&waiters[i]);
        try std.testing.expect(!immediate);
        try std.testing.expectEqual(i + 1, barrier.arrivedCount());
    }

    try std.testing.expectEqual(@as(usize, num_tasks - 1), barrier.waiterCount());
    try std.testing.expectEqual(@as(usize, 0), woken_count);

    // Last task arrives - all released
    waiters[num_tasks - 1] = Waiter.init();
    const immediate = barrier.wait(&waiters[num_tasks - 1]);

    try std.testing.expect(immediate);
    try std.testing.expect(waiters[num_tasks - 1].is_leader.load(.acquire));

    // All N-1 waiters should have been woken
    try std.testing.expectEqual(@as(usize, num_tasks - 1), woken_count);

    // All waiters should be released
    for (&waiters) |*w| {
        try std.testing.expect(w.isReleased());
    }

    // Exactly one leader
    var leaders: usize = 0;
    for (&waiters) |*w| {
        if (w.is_leader.load(.acquire)) leaders += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), leaders);

    // Barrier reset for next generation
    try std.testing.expectEqual(@as(usize, 0), barrier.arrivedCount());
    try std.testing.expectEqual(@as(usize, 1), barrier.currentGeneration());
}

test "Barrier - multiple generations leader consistency" {
    // Verify exactly one leader per generation across multiple rounds
    var barrier = Barrier.init(5);
    const num_generations = 10;

    for (0..num_generations) |gen| {
        var waiters: [5]Waiter = undefined;
        var leaders: usize = 0;

        for (&waiters) |*w| {
            w.* = Waiter.init();
            _ = barrier.wait(w);
        }

        // Count leaders in this generation
        for (&waiters) |*w| {
            if (w.is_leader.load(.acquire)) leaders += 1;
        }

        try std.testing.expectEqual(@as(usize, 1), leaders);
        try std.testing.expectEqual(gen + 1, barrier.currentGeneration());
    }
}

test "Barrier - arrived count tracking" {
    var barrier = Barrier.init(5);

    // Verify arrived count increments correctly
    try std.testing.expectEqual(@as(usize, 0), barrier.arrivedCount());

    var w1 = Waiter.init();
    _ = barrier.wait(&w1);
    try std.testing.expectEqual(@as(usize, 1), barrier.arrivedCount());

    var w2 = Waiter.init();
    _ = barrier.wait(&w2);
    try std.testing.expectEqual(@as(usize, 2), barrier.arrivedCount());

    var w3 = Waiter.init();
    _ = barrier.wait(&w3);
    try std.testing.expectEqual(@as(usize, 3), barrier.arrivedCount());

    var w4 = Waiter.init();
    _ = barrier.wait(&w4);
    try std.testing.expectEqual(@as(usize, 4), barrier.arrivedCount());

    // Last task triggers reset
    var w5 = Waiter.init();
    const immediate = barrier.wait(&w5);
    try std.testing.expect(immediate);
    try std.testing.expectEqual(@as(usize, 0), barrier.arrivedCount());
}

test "Barrier - waiter reset and reuse" {
    var barrier = Barrier.init(2);

    // First usage
    var waiter = Waiter.init();
    try std.testing.expect(!barrier.wait(&waiter));

    var leader = Waiter.init();
    try std.testing.expect(barrier.wait(&leader));

    try std.testing.expect(waiter.isReleased());
    try std.testing.expect(!waiter.is_leader.load(.acquire));

    // Reset waiter for reuse
    waiter.reset();
    try std.testing.expect(!waiter.isReleased());
    try std.testing.expect(!waiter.is_leader.load(.acquire));
    try std.testing.expect(waiter.waker == null);

    // Second usage with same waiter
    try std.testing.expect(!barrier.wait(&waiter));

    var leader2 = Waiter.init();
    try std.testing.expect(barrier.wait(&leader2));

    try std.testing.expect(waiter.isReleased());
    try std.testing.expect(!waiter.is_leader.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), barrier.currentGeneration());
}

test "Barrier - waitBlocking simple" {
    var barrier = Barrier.init(1);

    // Single task is always leader
    const result = barrier.waitBlocking();
    try std.testing.expect(result.is_leader);
}

test "Barrier - waitBlocking with contention" {
    var barrier = Barrier.init(3);
    var leader_count = std.atomic.Value(u32).init(0);
    var arrived_count = std.atomic.Value(u32).init(0);

    // Start two threads that will wait at the barrier
    const thread1 = try std.Thread.spawn(.{}, struct {
        fn run(b: *Barrier, lc: *std.atomic.Value(u32), ac: *std.atomic.Value(u32)) void {
            _ = ac.fetchAdd(1, .seq_cst);
            const result = b.waitBlocking();
            if (result.is_leader) {
                _ = lc.fetchAdd(1, .seq_cst);
            }
        }
    }.run, .{ &barrier, &leader_count, &arrived_count });

    const thread2 = try std.Thread.spawn(.{}, struct {
        fn run(b: *Barrier, lc: *std.atomic.Value(u32), ac: *std.atomic.Value(u32)) void {
            _ = ac.fetchAdd(1, .seq_cst);
            const result = b.waitBlocking();
            if (result.is_leader) {
                _ = lc.fetchAdd(1, .seq_cst);
            }
        }
    }.run, .{ &barrier, &leader_count, &arrived_count });

    // Wait until both threads have arrived
    while (arrived_count.load(.acquire) < 2) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    // Give threads time to actually call waitBlocking
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Main thread is the third arrival - should release everyone
    const result = barrier.waitBlocking();
    if (result.is_leader) {
        _ = leader_count.fetchAdd(1, .seq_cst);
    }

    // Wait for threads to finish
    thread1.join();
    thread2.join();

    // Exactly one leader
    try std.testing.expectEqual(@as(u32, 1), leader_count.load(.acquire));
}
