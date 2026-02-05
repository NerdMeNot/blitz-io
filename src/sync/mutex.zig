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
//! // Simple blocking lock (uses unified Waiter, works in both task and thread context)
//! mutex.lockBlocking();
//! defer mutex.unlock();
//! // Critical section
//!
//! // Try to lock without waiting
//! if (mutex.tryLock()) {
//!     defer mutex.unlock();
//!     // Critical section
//! }
//!
//! // Async lock (with waiter) - for custom wait handling
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
//! - `lockBlocking()` uses the unified Waiter for proper yielding/blocking
//!
//! Reference: tokio/src/sync/mutex.rs

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

/// A waiter for mutex lock acquisition.
pub const Waiter = struct {
    /// Waker to invoke when lock is granted
    waker: ?WakerFn = null,
    waker_ctx: ?*anyopaque = null,

    /// Whether lock has been acquired (atomic for cross-thread visibility)
    acquired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Intrusive list pointers
    pointers: Pointers(Waiter) = .{},

    /// Debug-mode invocation tracking (detects use-after-free)
    invocation: InvocationId = .{},

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

    /// Check if lock was acquired (uses seq_cst for cross-thread visibility)
    pub fn isAcquired(self: *const Self) bool {
        return self.acquired.load(.seq_cst);
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
        self.acquired.store(false, .seq_cst);
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
        return self.locked.cmpxchgStrong(false, true, .seq_cst, .seq_cst) == null;
    }

    /// Acquire the lock, potentially waiting.
    /// Returns true if lock was acquired immediately.
    /// Returns false if the waiter was added to the queue (task should yield).
    ///
    /// The waiter must be kept alive until acquired or cancelled.
    pub fn lock(self: *Self, waiter: *Waiter) bool {
        // Fast path: try to acquire without lock
        if (self.tryLock()) {
            waiter.acquired.store(true, .seq_cst);
            return true;
        }

        // Slow path: add to waiters list
        self.wait_lock.lock();

        // Re-check under lock
        if (self.locked.cmpxchgStrong(false, true, .seq_cst, .seq_cst) == null) {
            self.wait_lock.unlock();
            waiter.acquired.store(true, .seq_cst);
            return true;
        }

        // Add to waiters list
        waiter.acquired.store(false, .seq_cst);
        self.waiters.pushBack(waiter);

        self.wait_lock.unlock();

        return false;
    }

    /// Release the lock.
    /// If there are waiters, grants the lock to the first one.
    pub fn unlock(self: *Self) void {
        // Copy waker info before setting acquired, because once acquired is set,
        // the waiting thread may destroy the waiter (use-after-free race).
        var waker_fn: ?WakerFn = null;
        var waker_ctx: ?*anyopaque = null;

        self.wait_lock.lock();

        // Check for waiters
        if (self.waiters.popFront()) |waiter| {
            // Copy waker BEFORE setting acquired
            waker_fn = waiter.waker;
            waker_ctx = waiter.waker_ctx;

            // Grant lock to waiter (don't change locked state)
            // WARNING: After this line, waiter may be freed by the waiting thread!
            waiter.acquired.store(true, .seq_cst);
        } else {
            // No waiters - unlock
            self.locked.store(false, .seq_cst);
        }

        self.wait_lock.unlock();

        // Wake outside lock using copied function pointers (safe even if waiter is freed)
        if (waker_fn) |wf| {
            if (waker_ctx) |ctx| {
                wf(ctx);
            }
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

    /// Blocking lock acquisition.
    /// Uses the unified Waiter for proper yielding (task context) or blocking (thread context).
    /// This is the simplest API for acquiring the lock - NO SPIN WAITING.
    ///
    /// Example:
    /// ```zig
    /// mutex.lockBlocking();
    /// defer mutex.unlock();
    /// // Critical section
    /// ```
    pub fn lockBlocking(self: *Self) void {
        // Fast path: try to acquire without waiting
        if (self.tryLock()) {
            return;
        }

        // Slow path: use unified waiter
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

        self.wait_lock.lock();

        // Re-check under lock
        if (self.locked.cmpxchgStrong(false, true, .seq_cst, .seq_cst) == null) {
            self.wait_lock.unlock();
            return;
        }

        // Add to waiters list
        waiter.acquired.store(false, .seq_cst);
        self.waiters.pushBack(&waiter);

        self.wait_lock.unlock();

        // Wait until notified - this yields in task context, blocks in thread context
        unified.wait();
    }

    /// Check if locked (for debugging).
    pub fn isLocked(self: *const Self) bool {
        return self.locked.load(.seq_cst);
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

test "Mutex - lockBlocking simple" {
    var mutex = Mutex.init();

    // First lock should succeed immediately
    mutex.lockBlocking();
    try std.testing.expect(mutex.isLocked());

    mutex.unlock();
    try std.testing.expect(!mutex.isLocked());

    // Second lock should also work
    mutex.lockBlocking();
    try std.testing.expect(mutex.isLocked());

    mutex.unlock();
    try std.testing.expect(!mutex.isLocked());
}

test "Mutex - lockBlocking with contention" {
    var mutex = Mutex.init();
    var counter: u32 = 0;
    var done = std.atomic.Value(bool).init(false);

    // Lock the mutex
    mutex.lockBlocking();

    // Start a thread that will try to lock
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(m: *Mutex, c: *u32, d: *std.atomic.Value(bool)) void {
            m.lockBlocking(); // Should block until main thread unlocks
            c.* += 1;
            m.unlock();
            d.store(true, .release);
        }
    }.run, .{ &mutex, &counter, &done });

    // Give the thread time to start and block
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Counter should still be 0 (thread is blocked)
    try std.testing.expectEqual(@as(u32, 0), counter);

    // Unlock - this should wake the other thread
    mutex.unlock();

    // Wait for the thread to finish
    thread.join();

    // Now counter should be 1
    try std.testing.expectEqual(@as(u32, 1), counter);
    try std.testing.expect(done.load(.acquire));
}
