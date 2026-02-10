//! Semaphore - Async Counting Semaphore
//!
//! A counting semaphore that limits concurrent access to a resource.
//! Tasks can acquire permits (decrement) and release permits (increment).
//!
//! ## Usage
//!
//! ```zig
//! var sem = Semaphore.init(3);  // Allow 3 concurrent accessors
//!
//! // Simple blocking acquire (recommended)
//! sem.acquireBlocking(1);
//! defer sem.release(1);
//! // Limited concurrency section
//!
//! // Try to acquire without waiting
//! if (sem.tryAcquire(1)) {
//!     defer sem.release(1);
//!     // Got permit
//! }
//!
//! // Advanced: manual waiter for custom wait handling
//! var waiter = Semaphore.Waiter.init(1);
//! if (!sem.acquire(&waiter)) {
//!     // ... yield task, wait for notification ...
//! }
//! defer sem.release(1);
//! ```
//!
//! ## Design
//!
//! - Waiters stored in FIFO queue for fairness
//! - Batch waking after releasing lock
//! - Supports acquiring/releasing multiple permits at once
//! - `acquireBlocking()` uses the unified Waiter for proper yielding/blocking
//!
//! Reference: tokio/src/sync/semaphore.rs

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

/// A waiter for semaphore permits.
pub const Waiter = struct {
    /// Number of permits requested
    permits: usize,

    /// Number of permits acquired so far
    acquired: usize = 0,

    /// Waker to invoke when permits are granted
    waker: ?WakerFn = null,
    waker_ctx: ?*anyopaque = null,

    /// Whether acquisition is complete (atomic for cross-thread visibility)
    complete: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Intrusive list pointers
    pointers: Pointers(Waiter) = .{},

    /// Debug-mode invocation tracking (detects use-after-free)
    invocation: InvocationId = .{},

    const Self = @This();

    pub fn init(permits: usize) Self {
        return .{
            .permits = permits,
        };
    }

    /// Set the waker for this waiter
    pub fn setWaker(self: *Self, ctx: *anyopaque, wake_fn: WakerFn) void {
        self.waker_ctx = ctx;
        self.waker = wake_fn;
    }

    /// Wake this waiter
    pub fn wake(self: *Self) void {
        if (self.waker) |wf| {
            if (self.waker_ctx) |ctx| {
                wf(ctx);
            }
        }
    }

    /// Check if acquisition is complete (uses seq_cst for cross-thread visibility)
    pub fn isComplete(self: *const Self) bool {
        return self.complete.load(.seq_cst);
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
        self.acquired = 0;
        self.complete.store(false, .seq_cst);
        self.waker = null;
        self.waker_ctx = null;
        self.pointers.reset();
        self.invocation.bump();
    }
};

/// Function pointer type for waking
pub const WakerFn = *const fn (*anyopaque) void;

/// Intrusive list of waiters
const WaiterList = LinkedList(Waiter, "pointers");

// ─────────────────────────────────────────────────────────────────────────────
// Semaphore
// ─────────────────────────────────────────────────────────────────────────────

/// A counting semaphore.
pub const Semaphore = struct {
    /// Maximum permits
    max_permits: usize,

    /// Currently available permits
    permits: std.atomic.Value(usize),

    /// Mutex protecting the waiters list
    mutex: std.Thread.Mutex,

    /// Waiters list (FIFO for fairness)
    waiters: WaiterList,

    const Self = @This();

    /// Create a semaphore with the given number of permits.
    pub fn init(permits: usize) Self {
        return .{
            .max_permits = permits,
            .permits = std.atomic.Value(usize).init(permits),
            .mutex = .{},
            .waiters = .{},
        };
    }

    /// Try to acquire permits without waiting.
    /// Returns true if permits were acquired, false if not enough available.
    pub fn tryAcquire(self: *Self, num: usize) bool {
        var current = self.permits.load(.seq_cst);
        while (true) {
            if (current < num) {
                return false;
            }

            const result = self.permits.cmpxchgWeak(
                current,
                current - num,
                .seq_cst,
                .seq_cst,
            );

            if (result) |new_val| {
                current = new_val;
                continue;
            }

            return true;
        }
    }

    /// Acquire permits, potentially waiting.
    /// Returns true if permits were acquired immediately.
    /// Returns false if the waiter was added to the queue (task should yield).
    ///
    /// The waiter must be kept alive until complete or cancelled.
    pub fn acquire(self: *Self, waiter: *Waiter) bool {
        // Fast path: try to acquire without lock
        if (self.tryAcquire(waiter.permits)) {
            waiter.acquired = waiter.permits;
            waiter.complete.store(true, .seq_cst);
            return true;
        }

        // Slow path: add to waiters list
        self.mutex.lock();

        // Re-check permits under lock
        const current = self.permits.load(.seq_cst);
        if (current >= waiter.permits) {
            _ = self.permits.fetchSub(waiter.permits, .seq_cst);
            self.mutex.unlock();
            waiter.acquired = waiter.permits;
            waiter.complete.store(true, .seq_cst);
            return true;
        }

        // Not enough permits - take what we can and wait
        waiter.acquired = current;
        if (current > 0) {
            _ = self.permits.fetchSub(current, .seq_cst);
        }
        waiter.complete.store(false, .seq_cst);

        // Add to waiters list
        self.waiters.pushBack(waiter);

        self.mutex.unlock();

        return false;
    }

    /// Release permits.
    pub fn release(self: *Self, num: usize) void {
        // Add permits
        _ = self.permits.fetchAdd(num, .seq_cst);

        // Wake waiters that can now proceed
        var wake_list: WakeList(32) = .{};

        self.mutex.lock();

        // Try to satisfy waiters in FIFO order
        // NOTE: We must read the current permit count fresh each iteration because:
        // 1. Other threads may be calling release() concurrently
        // 2. tryAcquire() can race with us (it doesn't hold the mutex)
        // We use cmpxchg to safely claim permits without risking underflow.
        outer: while (self.waiters.front()) |waiter| {
            const needed = waiter.permits - waiter.acquired;

            // Try to claim permits atomically
            while (true) {
                const current = self.permits.load(.seq_cst);

                if (current >= needed) {
                    // Try to claim exactly what this waiter needs
                    if (self.permits.cmpxchgWeak(current, current - needed, .seq_cst, .seq_cst)) |_| {
                        // CAS failed, permits changed - retry
                        continue;
                    }
                    // Success - waiter fully satisfied
                    waiter.acquired = waiter.permits;

                    // CRITICAL: Copy waker info BEFORE setting complete flag to avoid use-after-free
                    const waker_fn = waiter.waker;
                    const waker_ctx = waiter.waker_ctx;
                    waiter.complete.store(true, .seq_cst);

                    _ = self.waiters.popFront();

                    if (waker_fn) |wf| {
                        if (waker_ctx) |ctx| {
                            wake_list.push(.{ .context = ctx, .wake_fn = wf });
                        }
                    }
                    // Continue to next waiter
                    break;
                } else if (current > 0) {
                    // Partial fulfillment - take all available
                    if (self.permits.cmpxchgWeak(current, 0, .seq_cst, .seq_cst)) |_| {
                        // CAS failed, permits changed - retry
                        continue;
                    }
                    waiter.acquired += current;
                    // Can't fully satisfy, stop processing waiters
                    break :outer;
                } else {
                    // No permits available
                    break :outer;
                }
            }
        }

        self.mutex.unlock();

        // Wake outside lock
        wake_list.wakeAll();
    }

    /// Cancel an acquisition.
    /// Returns any partially acquired permits back to the semaphore.
    pub fn cancelAcquire(self: *Self, waiter: *Waiter) void {
        // Quick check if already complete
        if (waiter.isComplete()) {
            return;
        }

        self.mutex.lock();

        // Check again under lock
        if (waiter.isComplete()) {
            self.mutex.unlock();
            return;
        }

        // Remove from list if linked
        if (WaiterList.isLinked(waiter) or self.waiters.front() == waiter) {
            self.waiters.remove(waiter);
            waiter.pointers.reset();
        }

        // Return any partially acquired permits
        const to_return = waiter.acquired;
        waiter.acquired = 0;

        self.mutex.unlock();

        // Return permits (may wake other waiters)
        if (to_return > 0) {
            self.release(to_return);
        }
    }

    /// Blocking permit acquisition.
    /// Uses the unified Waiter for proper yielding (task context) or blocking (thread context).
    /// This is the simplest API for acquiring permits - NO SPIN WAITING.
    ///
    /// Example:
    /// ```zig
    /// sem.acquireBlocking(1);
    /// defer sem.release(1);
    /// // Limited concurrency section
    /// ```
    pub fn acquireBlocking(self: *Self, num: usize) void {
        // Fast path: try to acquire without waiting
        if (self.tryAcquire(num)) {
            return;
        }

        // Slow path: use unified waiter
        var waiter = Waiter.init(num);

        // Set up waker bridge to unified waiter
        var unified = UnifiedWaiter.init();
        const WakerBridge = struct {
            fn wake(ctx: *anyopaque) void {
                const uw: *UnifiedWaiter = @ptrCast(@alignCast(ctx));
                uw.notify();
            }
        };
        waiter.setWaker(@ptrCast(&unified), WakerBridge.wake);

        // Use the internal acquire path
        if (self.acquire(&waiter)) {
            return; // Got permits immediately on retry
        }

        // Wait until notified - this yields in task context, blocks in thread context
        unified.wait();
    }

    /// Get available permits (for debugging).
    pub fn availablePermits(self: *const Self) usize {
        return self.permits.load(.seq_cst);
    }

    /// Get number of waiters (for debugging).
    pub fn waiterCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.waiters.count();
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// SemaphorePermit - RAII guard
// ─────────────────────────────────────────────────────────────────────────────

/// RAII guard that releases permits when dropped.
pub const SemaphorePermit = struct {
    semaphore: *Semaphore,
    permits: usize,

    const Self = @This();

    pub fn init(semaphore: *Semaphore, permits: usize) Self {
        return .{
            .semaphore = semaphore,
            .permits = permits,
        };
    }

    /// Release permits and invalidate this guard.
    pub fn release(self: *Self) void {
        if (self.permits > 0) {
            self.semaphore.release(self.permits);
            self.permits = 0;
        }
    }

    /// Forget this permit (don't release on drop).
    pub fn forget(self: *Self) void {
        self.permits = 0;
    }

    /// Deinit (releases permits).
    pub fn deinit(self: *Self) void {
        self.release();
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "Semaphore - tryAcquire success" {
    var sem = Semaphore.init(3);

    try std.testing.expect(sem.tryAcquire(1));
    try std.testing.expectEqual(@as(usize, 2), sem.availablePermits());

    try std.testing.expect(sem.tryAcquire(2));
    try std.testing.expectEqual(@as(usize, 0), sem.availablePermits());
}

test "Semaphore - tryAcquire failure" {
    var sem = Semaphore.init(2);

    try std.testing.expect(!sem.tryAcquire(3));
    try std.testing.expectEqual(@as(usize, 2), sem.availablePermits());

    try std.testing.expect(sem.tryAcquire(2));
    try std.testing.expect(!sem.tryAcquire(1));
}

test "Semaphore - acquire and release" {
    var sem = Semaphore.init(1);
    var woken = false;

    const TestWaker = struct {
        fn wake(ctx: *anyopaque) void {
            const w: *bool = @ptrCast(@alignCast(ctx));
            w.* = true;
        }
    };

    // First acquire succeeds immediately
    var waiter1 = Waiter.init(1);
    try std.testing.expect(sem.acquire(&waiter1));
    try std.testing.expect(waiter1.isComplete());

    // Second acquire should wait
    var waiter2 = Waiter.init(1);
    waiter2.setWaker(@ptrCast(&woken), TestWaker.wake);
    try std.testing.expect(!sem.acquire(&waiter2));
    try std.testing.expect(!waiter2.isComplete());
    try std.testing.expectEqual(@as(usize, 1), sem.waiterCount());

    // Release wakes waiter2
    sem.release(1);
    try std.testing.expect(waiter2.isComplete());
    try std.testing.expect(woken);
}

test "Semaphore - FIFO ordering" {
    var sem = Semaphore.init(0);

    // Add waiters in order
    var waiters: [3]Waiter = undefined;
    for (&waiters) |*w| {
        w.* = Waiter.init(1);
        _ = sem.acquire(w);
    }

    try std.testing.expectEqual(@as(usize, 3), sem.waiterCount());

    // Release one at a time - should wake in FIFO order
    sem.release(1);
    try std.testing.expect(waiters[0].isComplete());
    try std.testing.expect(!waiters[1].isComplete());
    try std.testing.expect(!waiters[2].isComplete());

    sem.release(1);
    try std.testing.expect(waiters[1].isComplete());
    try std.testing.expect(!waiters[2].isComplete());

    sem.release(1);
    try std.testing.expect(waiters[2].isComplete());
}

test "Semaphore - cancel returns permits" {
    var sem = Semaphore.init(2);

    // Acquire all permits
    try std.testing.expect(sem.tryAcquire(2));
    try std.testing.expectEqual(@as(usize, 0), sem.availablePermits());

    // Start waiting for more
    var waiter = Waiter.init(2);
    try std.testing.expect(!sem.acquire(&waiter));

    // Cancel - should return any partial acquisition
    sem.cancelAcquire(&waiter);
    try std.testing.expectEqual(@as(usize, 0), sem.waiterCount());
}

test "Semaphore - permit RAII" {
    var sem = Semaphore.init(2);

    {
        try std.testing.expect(sem.tryAcquire(1));
        var permit = SemaphorePermit.init(&sem, 1);
        try std.testing.expectEqual(@as(usize, 1), sem.availablePermits());

        permit.deinit();
    }

    try std.testing.expectEqual(@as(usize, 2), sem.availablePermits());
}

test "Semaphore - binary semaphore (mutex equivalent)" {
    var sem = Semaphore.init(1);

    // First acquire succeeds
    try std.testing.expect(sem.tryAcquire(1));
    try std.testing.expectEqual(@as(usize, 0), sem.availablePermits());

    // Second acquire fails (semaphore is "locked")
    try std.testing.expect(!sem.tryAcquire(1));

    // Release
    sem.release(1);
    try std.testing.expectEqual(@as(usize, 1), sem.availablePermits());

    // Can acquire again
    try std.testing.expect(sem.tryAcquire(1));
}

test "Semaphore - large permit count" {
    var sem = Semaphore.init(1000);

    // Acquire in chunks
    try std.testing.expect(sem.tryAcquire(100));
    try std.testing.expectEqual(@as(usize, 900), sem.availablePermits());

    try std.testing.expect(sem.tryAcquire(400));
    try std.testing.expectEqual(@as(usize, 500), sem.availablePermits());

    try std.testing.expect(sem.tryAcquire(500));
    try std.testing.expectEqual(@as(usize, 0), sem.availablePermits());

    // Can't acquire more
    try std.testing.expect(!sem.tryAcquire(1));

    // Release all
    sem.release(1000);
    try std.testing.expectEqual(@as(usize, 1000), sem.availablePermits());
}

test "Semaphore - multiple acquire release cycles" {
    var sem = Semaphore.init(5);

    // Multiple cycles
    for (0..10) |_| {
        // Acquire all
        try std.testing.expect(sem.tryAcquire(5));
        try std.testing.expectEqual(@as(usize, 0), sem.availablePermits());

        // Release all
        sem.release(5);
        try std.testing.expectEqual(@as(usize, 5), sem.availablePermits());
    }

    // Partial acquire/release cycles
    for (0..10) |_| {
        try std.testing.expect(sem.tryAcquire(3));
        try std.testing.expect(sem.tryAcquire(2));
        try std.testing.expectEqual(@as(usize, 0), sem.availablePermits());

        sem.release(2);
        sem.release(3);
        try std.testing.expectEqual(@as(usize, 5), sem.availablePermits());
    }
}

test "Semaphore - release increases permits" {
    var sem = Semaphore.init(2);

    // Release can increase beyond initial count
    sem.release(3);
    try std.testing.expectEqual(@as(usize, 5), sem.availablePermits());

    // Acquire all the permits
    try std.testing.expect(sem.tryAcquire(5));
    try std.testing.expectEqual(@as(usize, 0), sem.availablePermits());
}

test "Semaphore - acquireBlocking simple" {
    var sem = Semaphore.init(2);

    // First acquire should succeed immediately
    sem.acquireBlocking(1);
    try std.testing.expectEqual(@as(usize, 1), sem.availablePermits());

    sem.release(1);
    try std.testing.expectEqual(@as(usize, 2), sem.availablePermits());
}

test "Semaphore - acquireBlocking with contention" {
    var sem = Semaphore.init(1);
    var counter: u32 = 0;
    var done = std.atomic.Value(bool).init(false);

    // Acquire the only permit
    sem.acquireBlocking(1);

    // Start a thread that will try to acquire
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *Semaphore, c: *u32, d: *std.atomic.Value(bool)) void {
            s.acquireBlocking(1); // Should block until main thread releases
            c.* += 1;
            s.release(1);
            d.store(true, .release);
        }
    }.run, .{ &sem, &counter, &done });

    // Give the thread time to start and block
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Counter should still be 0 (thread is blocked)
    try std.testing.expectEqual(@as(u32, 0), counter);

    // Release - this should wake the other thread
    sem.release(1);

    // Wait for the thread to finish
    thread.join();

    // Now counter should be 1
    try std.testing.expectEqual(@as(u32, 1), counter);
    try std.testing.expect(done.load(.acquire));
}
