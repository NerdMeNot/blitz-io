//! Mutex - Async Mutual Exclusion
//!
//! An async-aware mutex that allows tasks to wait for exclusive access.
//! Unlike std.Thread.Mutex, this mutex yields to the scheduler when contended
//! rather than blocking the thread.
//!
//! ## Usage
//!
//! ```zig
//! var mutex = Mutex.init();
//!
//! // Try to lock without waiting
//! if (mutex.tryLock()) {
//!     defer mutex.unlock();
//!     // Critical section
//! }
//!
//! // Async lock (with waiter)
//! var waiter = Mutex.Waiter.init();
//! if (!mutex.lock(&waiter)) {
//!     // Yield task, wait for notification
//! }
//! defer mutex.unlock();
//! // Critical section
//! ```
//!
//! ## Design
//!
//! - Built on top of a binary semaphore (1 permit)
//! - FIFO ordering for fairness
//! - Batch waking after releasing lock
//!
//! Reference: tokio/src/sync/mutex.rs

const std = @import("std");
const builtin = @import("builtin");

const LinkedList = @import("../util/linked_list.zig").LinkedList;
const Pointers = @import("../util/linked_list.zig").Pointers;
const WakeList = @import("../util/wake_list.zig").WakeList;

// ─────────────────────────────────────────────────────────────────────────────
// Waiter
// ─────────────────────────────────────────────────────────────────────────────

/// A waiter for mutex lock acquisition.
pub const Waiter = struct {
    /// Waker to invoke when lock is granted
    waker: ?WakerFn = null,
    waker_ctx: ?*anyopaque = null,

    /// Whether lock has been acquired
    acquired: bool = false,

    /// Intrusive list pointers
    pointers: Pointers(Waiter) = .{},

    const Self = @This();

    pub fn init() Self {
        return .{};
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

    /// Check if lock was acquired
    pub fn isAcquired(self: *const Self) bool {
        return self.acquired;
    }

    /// Reset for reuse
    pub fn reset(self: *Self) void {
        self.acquired = false;
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
// Mutex
// ─────────────────────────────────────────────────────────────────────────────

/// An async-aware mutex.
pub const Mutex = struct {
    /// Whether the mutex is currently locked
    locked: std.atomic.Value(bool),

    /// Mutex protecting the waiters list
    wait_lock: std.Thread.Mutex,

    /// Waiters list (FIFO for fairness)
    waiters: WaiterList,

    const Self = @This();

    /// Create a new unlocked mutex.
    pub fn init() Self {
        return .{
            .locked = std.atomic.Value(bool).init(false),
            .wait_lock = .{},
            .waiters = .{},
        };
    }

    /// Try to acquire the lock without waiting.
    /// Returns true if lock was acquired, false otherwise.
    pub fn tryLock(self: *Self) bool {
        return self.locked.cmpxchgStrong(false, true, .acquire, .monotonic) == null;
    }

    /// Acquire the lock, potentially waiting.
    /// Returns true if lock was acquired immediately.
    /// Returns false if the waiter was added to the queue (task should yield).
    ///
    /// The waiter must be kept alive until acquired or cancelled.
    pub fn lock(self: *Self, waiter: *Waiter) bool {
        // Fast path: try to acquire without lock
        if (self.tryLock()) {
            waiter.acquired = true;
            return true;
        }

        // Slow path: add to waiters list
        self.wait_lock.lock();

        // Re-check under lock
        if (self.locked.cmpxchgStrong(false, true, .acquire, .monotonic) == null) {
            self.wait_lock.unlock();
            waiter.acquired = true;
            return true;
        }

        // Add to waiters list
        waiter.acquired = false;
        self.waiters.pushBack(waiter);

        self.wait_lock.unlock();

        return false;
    }

    /// Release the lock.
    /// If there are waiters, grants the lock to the first one.
    pub fn unlock(self: *Self) void {
        self.wait_lock.lock();

        // Check for waiters
        if (self.waiters.popFront()) |waiter| {
            // Grant lock to waiter (don't change locked state)
            waiter.acquired = true;
            self.wait_lock.unlock();
            waiter.wake();
        } else {
            // No waiters - unlock
            self.locked.store(false, .release);
            self.wait_lock.unlock();
        }
    }

    /// Cancel a lock acquisition.
    pub fn cancelLock(self: *Self, waiter: *Waiter) void {
        // Quick check if already acquired
        if (waiter.isAcquired()) {
            return;
        }

        self.wait_lock.lock();

        // Check again under lock
        if (waiter.isAcquired()) {
            self.wait_lock.unlock();
            return;
        }

        // Remove from list if linked
        if (WaiterList.isLinked(waiter) or self.waiters.front() == waiter) {
            self.waiters.remove(waiter);
            waiter.pointers.reset();
        }

        self.wait_lock.unlock();
    }

    /// Check if locked (for debugging).
    pub fn isLocked(self: *const Self) bool {
        return self.locked.load(.acquire);
    }

    /// Get number of waiters (for debugging).
    pub fn waiterCount(self: *Self) usize {
        self.wait_lock.lock();
        defer self.wait_lock.unlock();
        return self.waiters.count();
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// MutexGuard - RAII guard
// ─────────────────────────────────────────────────────────────────────────────

/// RAII guard that releases the mutex when dropped.
pub const MutexGuard = struct {
    mutex: *Mutex,
    active: bool,

    const Self = @This();

    pub fn init(mutex: *Mutex) Self {
        return .{
            .mutex = mutex,
            .active = true,
        };
    }

    /// Explicitly unlock.
    pub fn unlock(self: *Self) void {
        if (self.active) {
            self.mutex.unlock();
            self.active = false;
        }
    }

    /// Deinit (unlocks if still held).
    pub fn deinit(self: *Self) void {
        self.unlock();
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "Mutex - tryLock success" {
    var mutex = Mutex.init();

    try std.testing.expect(mutex.tryLock());
    try std.testing.expect(mutex.isLocked());

    mutex.unlock();
    try std.testing.expect(!mutex.isLocked());
}

test "Mutex - tryLock fails when locked" {
    var mutex = Mutex.init();

    try std.testing.expect(mutex.tryLock());
    try std.testing.expect(!mutex.tryLock());

    mutex.unlock();
    try std.testing.expect(mutex.tryLock());
}

test "Mutex - lock and unlock" {
    var mutex = Mutex.init();
    var woken = false;

    const TestWaker = struct {
        fn wake(ctx: *anyopaque) void {
            const w: *bool = @ptrCast(@alignCast(ctx));
            w.* = true;
        }
    };

    // First lock succeeds immediately
    var waiter1 = Waiter.init();
    try std.testing.expect(mutex.lock(&waiter1));
    try std.testing.expect(waiter1.isAcquired());

    // Second lock should wait
    var waiter2 = Waiter.init();
    waiter2.setWaker(@ptrCast(&woken), TestWaker.wake);
    try std.testing.expect(!mutex.lock(&waiter2));
    try std.testing.expect(!waiter2.isAcquired());
    try std.testing.expectEqual(@as(usize, 1), mutex.waiterCount());

    // Unlock grants to waiter2
    mutex.unlock();
    try std.testing.expect(waiter2.isAcquired());
    try std.testing.expect(woken);
    try std.testing.expect(mutex.isLocked()); // Still locked by waiter2

    // Clean unlock
    mutex.unlock();
    try std.testing.expect(!mutex.isLocked());
}

test "Mutex - FIFO ordering" {
    var mutex = Mutex.init();

    // Lock the mutex
    try std.testing.expect(mutex.tryLock());

    // Add waiters in order
    var waiters: [3]Waiter = undefined;
    for (&waiters) |*w| {
        w.* = Waiter.init();
        _ = mutex.lock(w);
    }

    try std.testing.expectEqual(@as(usize, 3), mutex.waiterCount());

    // Unlock should wake in FIFO order
    mutex.unlock();
    try std.testing.expect(waiters[0].isAcquired());
    try std.testing.expect(!waiters[1].isAcquired());
    try std.testing.expect(!waiters[2].isAcquired());

    mutex.unlock();
    try std.testing.expect(waiters[1].isAcquired());

    mutex.unlock();
    try std.testing.expect(waiters[2].isAcquired());

    mutex.unlock();
    try std.testing.expect(!mutex.isLocked());
}

test "Mutex - cancel removes waiter" {
    var mutex = Mutex.init();

    // Lock the mutex
    try std.testing.expect(mutex.tryLock());

    // Add waiter
    var waiter = Waiter.init();
    _ = mutex.lock(&waiter);
    try std.testing.expectEqual(@as(usize, 1), mutex.waiterCount());

    // Cancel
    mutex.cancelLock(&waiter);
    try std.testing.expectEqual(@as(usize, 0), mutex.waiterCount());

    // Unlock should succeed with no waiters
    mutex.unlock();
    try std.testing.expect(!mutex.isLocked());
}

test "Mutex - guard RAII" {
    var mutex = Mutex.init();

    {
        try std.testing.expect(mutex.tryLock());
        var guard = MutexGuard.init(&mutex);
        try std.testing.expect(mutex.isLocked());

        guard.deinit();
    }

    try std.testing.expect(!mutex.isLocked());
}
