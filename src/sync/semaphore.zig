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
//! // Acquire a permit
//! var waiter = Semaphore.Waiter.init(1);
//! if (!sem.tryAcquire(1)) {
//!     _ = sem.acquire(&waiter);
//!     // ... yield task, wait for notification ...
//! }
//!
//! // Critical section with limited concurrency
//!
//! // Release permit
//! sem.release(1);
//! ```
//!
//! ## Design
//!
//! - Waiters stored in FIFO queue for fairness
//! - Batch waking after releasing lock
//! - Supports acquiring/releasing multiple permits at once
//!
//! Reference: tokio/src/sync/semaphore.rs

const std = @import("std");
const builtin = @import("builtin");

const LinkedList = @import("../util/linked_list.zig").LinkedList;
const Pointers = @import("../util/linked_list.zig").Pointers;
const WakeList = @import("../util/wake_list.zig").WakeList;

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

    /// Whether acquisition is complete
    complete: bool = false,

    /// Intrusive list pointers
    pointers: Pointers(Waiter) = .{},

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

    /// Check if acquisition is complete
    pub fn isComplete(self: *const Self) bool {
        return self.complete;
    }

    /// Reset for reuse
    pub fn reset(self: *Self) void {
        self.acquired = 0;
        self.complete = false;
        self.waker = null;
        self.waker_ctx = null;
        self.pointers.reset();
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
        var current = self.permits.load(.acquire);
        while (true) {
            if (current < num) {
                return false;
            }

            const result = self.permits.cmpxchgWeak(
                current,
                current - num,
                .acq_rel,
                .acquire,
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
            waiter.complete = true;
            return true;
        }

        // Slow path: add to waiters list
        self.mutex.lock();

        // Re-check permits under lock
        const current = self.permits.load(.acquire);
        if (current >= waiter.permits) {
            _ = self.permits.fetchSub(waiter.permits, .release);
            self.mutex.unlock();
            waiter.acquired = waiter.permits;
            waiter.complete = true;
            return true;
        }

        // Not enough permits - take what we can and wait
        waiter.acquired = current;
        if (current > 0) {
            _ = self.permits.fetchSub(current, .release);
        }
        waiter.complete = false;

        // Add to waiters list
        self.waiters.pushBack(waiter);

        self.mutex.unlock();

        return false;
    }

    /// Release permits.
    pub fn release(self: *Self, num: usize) void {
        // Add permits
        var available = self.permits.fetchAdd(num, .release) + num;

        // Wake waiters that can now proceed
        var wake_list: WakeList(32) = .{};

        self.mutex.lock();

        // Try to satisfy waiters in FIFO order
        while (self.waiters.front()) |waiter| {
            const needed = waiter.permits - waiter.acquired;

            if (available >= needed) {
                // Can satisfy this waiter
                available -= needed;
                _ = self.permits.fetchSub(needed, .release);
                waiter.acquired = waiter.permits;
                waiter.complete = true;

                _ = self.waiters.popFront();

                if (waiter.waker) |wf| {
                    if (waiter.waker_ctx) |ctx| {
                        wake_list.push(.{ .context = ctx, .wake_fn = wf });
                    }
                }
            } else if (available > 0) {
                // Partial fulfillment
                waiter.acquired += available;
                _ = self.permits.fetchSub(available, .release);
                available = 0;
                break;
            } else {
                break;
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

    /// Get available permits (for debugging).
    pub fn availablePermits(self: *const Self) usize {
        return self.permits.load(.acquire);
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
