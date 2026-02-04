//! Notify - Task Notification Primitive
//!
//! A synchronization primitive for notifying one or many waiting tasks.
//! Similar to a condition variable but designed for async task coordination.
//!
//! ## Usage
//!
//! ```zig
//! var notify = Notify.init();
//!
//! // Waiting task:
//! notify.wait(waker);  // Returns .pending, waker stored
//!
//! // Notifying task:
//! notify.notifyOne();  // Wakes one waiter
//! // or
//! notify.notifyAll();  // Wakes all waiters
//! ```
//!
//! ## Design
//!
//! - Waiters are stored in an intrusive linked list (zero allocation)
//! - Batch waking after releasing lock to avoid holding lock during wake
//! - Permit-based semantics to handle notify-before-wait race
//!
//! Reference: tokio/src/sync/notify.rs

const std = @import("std");
const builtin = @import("builtin");

const LinkedList = @import("../util/linked_list.zig").LinkedList;
const Pointers = @import("../util/linked_list.zig").Pointers;
const WakeList = @import("../util/wake_list.zig").WakeList;

// ─────────────────────────────────────────────────────────────────────────────
// Waiter
// ─────────────────────────────────────────────────────────────────────────────

/// A waiter node that embeds its own list pointers.
/// Designed to be stack-allocated by the waiting task.
pub const Waiter = struct {
    /// Waker to invoke when notified
    waker: ?WakerFn = null,
    waker_ctx: ?*anyopaque = null,

    /// Whether this waiter has been notified
    notified: bool = false,

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
        self.notified = true;
        if (self.waker) |wf| {
            if (self.waker_ctx) |ctx| {
                wf(ctx);
            }
        }
    }

    /// Check if notified
    pub fn isNotified(self: *const Self) bool {
        return self.notified;
    }

    /// Reset for reuse
    pub fn reset(self: *Self) void {
        self.notified = false;
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
// Notify State
// ─────────────────────────────────────────────────────────────────────────────

/// State bits for Notify
const State = struct {
    /// A permit is available (notify was called with no waiters)
    const PERMIT: u8 = 1 << 0;
    /// Waiters list is not empty
    const WAITING: u8 = 1 << 1;
};

// ─────────────────────────────────────────────────────────────────────────────
// Notify
// ─────────────────────────────────────────────────────────────────────────────

/// A synchronization primitive for notifying waiting tasks.
pub const Notify = struct {
    /// State flags (PERMIT, WAITING)
    state: std.atomic.Value(u8),

    /// Mutex protecting the waiters list
    mutex: std.Thread.Mutex,

    /// Waiters list
    waiters: WaiterList,

    const Self = @This();

    /// Create a new Notify.
    pub fn init() Self {
        return .{
            .state = std.atomic.Value(u8).init(0),
            .mutex = .{},
            .waiters = .{},
        };
    }

    /// Notify one waiting task.
    /// If no task is waiting, stores a permit that will be consumed by the next wait.
    pub fn notifyOne(self: *Self) void {
        // Fast path: check if anyone is waiting
        const state = self.state.load(.acquire);
        if (state & State.WAITING == 0) {
            // No waiters - try to store a permit
            _ = self.state.fetchOr(State.PERMIT, .release);
            return;
        }

        // Slow path: need to wake a waiter
        self.mutex.lock();

        // Pop one waiter
        const waiter = self.waiters.popFront();

        // Update state
        if (self.waiters.isEmpty()) {
            _ = self.state.fetchAnd(~State.WAITING, .release);
        }

        self.mutex.unlock();

        // Wake outside the lock
        if (waiter) |w| {
            w.wake();
        } else {
            // No waiter found, store a permit
            _ = self.state.fetchOr(State.PERMIT, .release);
        }
    }

    /// Notify all waiting tasks.
    /// Does NOT store a permit if no tasks are waiting.
    pub fn notifyAll(self: *Self) void {
        // Fast path: check if anyone is waiting
        const state = self.state.load(.acquire);
        if (state & State.WAITING == 0) {
            return;
        }

        // Collect waiters to wake
        var wake_list: WakeList(32) = .{};

        self.mutex.lock();

        // Drain all waiters
        while (self.waiters.popFront()) |waiter| {
            waiter.notified = true;
            if (waiter.waker) |wf| {
                if (waiter.waker_ctx) |ctx| {
                    wake_list.push(.{ .context = ctx, .wake_fn = wf });
                }
            }
        }

        // Clear WAITING flag
        _ = self.state.fetchAnd(~State.WAITING, .release);

        self.mutex.unlock();

        // Wake all outside the lock
        wake_list.wakeAll();
    }

    /// Wait for notification.
    /// Returns true if a permit was consumed (immediate return).
    /// Returns false if the waiter was added to the queue (task should yield).
    ///
    /// The waiter must be kept alive until notified or cancelled.
    pub fn wait(self: *Self, waiter: *Waiter) bool {
        // Fast path: check for permit
        var state = self.state.load(.acquire);
        if (state & State.PERMIT != 0) {
            // Try to consume permit
            const result = self.state.cmpxchgWeak(
                state,
                state & ~State.PERMIT,
                .acq_rel,
                .acquire,
            );
            if (result == null) {
                // Consumed permit
                waiter.notified = true;
                return true;
            }
            // CAS failed, fall through to slow path
        }

        // Slow path: add to waiters list
        self.mutex.lock();

        // Re-check for permit under lock
        state = self.state.load(.acquire);
        if (state & State.PERMIT != 0) {
            _ = self.state.fetchAnd(~State.PERMIT, .release);
            self.mutex.unlock();
            waiter.notified = true;
            return true;
        }

        // Add to waiters list
        waiter.notified = false;
        self.waiters.pushBack(waiter);

        // Set WAITING flag
        _ = self.state.fetchOr(State.WAITING, .release);

        self.mutex.unlock();

        return false;
    }

    /// Cancel a wait operation.
    /// Removes the waiter from the queue if it was added.
    /// Safe to call even if the waiter was already notified.
    pub fn cancelWait(self: *Self, waiter: *Waiter) void {
        // Quick check if already notified
        if (waiter.isNotified()) {
            return;
        }

        self.mutex.lock();

        // Check again under lock
        if (waiter.isNotified()) {
            self.mutex.unlock();
            return;
        }

        // Remove from list if linked
        if (WaiterList.isLinked(waiter) or self.waiters.front() == waiter) {
            self.waiters.remove(waiter);
            waiter.pointers.reset();

            // Update state if list is now empty
            if (self.waiters.isEmpty()) {
                _ = self.state.fetchAnd(~State.WAITING, .release);
            }
        }

        self.mutex.unlock();
    }

    /// Check if there are pending permits (for testing/debugging).
    pub fn hasPermit(self: *const Self) bool {
        return self.state.load(.acquire) & State.PERMIT != 0;
    }

    /// Get the number of waiters (for debugging).
    pub fn waiterCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.waiters.count();
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "Notify - notify before wait consumes permit" {
    var notify = Notify.init();

    // Notify with no waiters
    notify.notifyOne();
    try std.testing.expect(notify.hasPermit());

    // Wait should consume permit immediately
    var waiter = Waiter.init();
    const consumed = notify.wait(&waiter);

    try std.testing.expect(consumed);
    try std.testing.expect(waiter.isNotified());
    try std.testing.expect(!notify.hasPermit());
}

test "Notify - wait then notify" {
    var notify = Notify.init();
    var woken = false;

    const TestWaker = struct {
        fn wake(ctx: *anyopaque) void {
            const w: *bool = @ptrCast(@alignCast(ctx));
            w.* = true;
        }
    };

    var waiter = Waiter.init();
    waiter.setWaker(@ptrCast(&woken), TestWaker.wake);

    // Wait should return false (added to queue)
    const consumed = notify.wait(&waiter);
    try std.testing.expect(!consumed);
    try std.testing.expect(!waiter.isNotified());
    try std.testing.expectEqual(@as(usize, 1), notify.waiterCount());

    // Notify should wake the waiter
    notify.notifyOne();
    try std.testing.expect(waiter.isNotified());
    try std.testing.expect(woken);
    try std.testing.expectEqual(@as(usize, 0), notify.waiterCount());
}

test "Notify - notifyAll wakes all waiters" {
    var notify = Notify.init();
    var woken: [3]bool = .{ false, false, false };

    const TestWaker = struct {
        fn wake(ctx: *anyopaque) void {
            const w: *bool = @ptrCast(@alignCast(ctx));
            w.* = true;
        }
    };

    var waiters: [3]Waiter = undefined;
    for (&waiters, 0..) |*w, i| {
        w.* = Waiter.init();
        w.setWaker(@ptrCast(&woken[i]), TestWaker.wake);
        _ = notify.wait(w);
    }

    try std.testing.expectEqual(@as(usize, 3), notify.waiterCount());

    notify.notifyAll();

    for (woken) |w| {
        try std.testing.expect(w);
    }
    try std.testing.expectEqual(@as(usize, 0), notify.waiterCount());
}

test "Notify - cancel removes waiter" {
    var notify = Notify.init();

    var waiter1 = Waiter.init();
    var waiter2 = Waiter.init();

    _ = notify.wait(&waiter1);
    _ = notify.wait(&waiter2);

    try std.testing.expectEqual(@as(usize, 2), notify.waiterCount());

    // Cancel first waiter
    notify.cancelWait(&waiter1);
    try std.testing.expectEqual(@as(usize, 1), notify.waiterCount());

    // Notify should wake remaining waiter
    notify.notifyOne();
    try std.testing.expect(waiter2.isNotified());
    try std.testing.expect(!waiter1.isNotified());
}

test "Notify - notifyAll with no waiters is no-op" {
    var notify = Notify.init();

    // Should not store permit
    notify.notifyAll();
    try std.testing.expect(!notify.hasPermit());
}

test "Notify - notifyOne wakes exactly one waiter" {
    var notify = Notify.init();
    var woken: [3]bool = .{ false, false, false };

    const TestWaker = struct {
        fn wake(ctx: *anyopaque) void {
            const w: *bool = @ptrCast(@alignCast(ctx));
            w.* = true;
        }
    };

    // Add three waiters
    var waiters: [3]Waiter = undefined;
    for (&waiters, 0..) |*w, i| {
        w.* = Waiter.init();
        w.setWaker(@ptrCast(&woken[i]), TestWaker.wake);
        _ = notify.wait(w);
    }

    try std.testing.expectEqual(@as(usize, 3), notify.waiterCount());

    // notifyOne should wake exactly one (the first in FIFO order)
    notify.notifyOne();

    try std.testing.expect(woken[0]);
    try std.testing.expect(!woken[1]);
    try std.testing.expect(!woken[2]);
    try std.testing.expectEqual(@as(usize, 2), notify.waiterCount());

    // Clean up remaining waiters
    notify.notifyAll();
}

test "Notify - permit does not accumulate" {
    var notify = Notify.init();

    // Multiple notifyOne calls should store only one permit
    notify.notifyOne();
    notify.notifyOne();
    notify.notifyOne();

    try std.testing.expect(notify.hasPermit());

    // First wait consumes the permit
    var waiter1 = Waiter.init();
    const consumed1 = notify.wait(&waiter1);
    try std.testing.expect(consumed1);
    try std.testing.expect(waiter1.isNotified());

    // Second wait should block (no permit left)
    var waiter2 = Waiter.init();
    const consumed2 = notify.wait(&waiter2);
    try std.testing.expect(!consumed2);
    try std.testing.expect(!waiter2.isNotified());

    // Clean up
    notify.notifyOne();
}

test "Notify - rapid notify wait cycles" {
    var notify = Notify.init();

    for (0..100) |_| {
        // Notify first (stores permit)
        notify.notifyOne();
        try std.testing.expect(notify.hasPermit());

        // Wait consumes permit
        var waiter = Waiter.init();
        const consumed = notify.wait(&waiter);
        try std.testing.expect(consumed);
        try std.testing.expect(waiter.isNotified());
        try std.testing.expect(!notify.hasPermit());
    }

    // Final state should be clean
    try std.testing.expect(!notify.hasPermit());
    try std.testing.expectEqual(@as(usize, 0), notify.waiterCount());
}

test "Notify - many waiters notify one at a time" {
    var notify = Notify.init();
    const num_waiters = 100;
    var woken_count: usize = 0;

    const TestWaker = struct {
        fn wake(ctx: *anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(ctx));
            count.* += 1;
        }
    };

    // Add many waiters
    var waiters: [num_waiters]Waiter = undefined;
    for (&waiters) |*w| {
        w.* = Waiter.init();
        w.setWaker(@ptrCast(&woken_count), TestWaker.wake);
        _ = notify.wait(w);
    }

    try std.testing.expectEqual(@as(usize, num_waiters), notify.waiterCount());
    try std.testing.expectEqual(@as(usize, 0), woken_count);

    // Notify one at a time
    for (0..num_waiters) |i| {
        notify.notifyOne();
        try std.testing.expectEqual(i + 1, woken_count);
        try std.testing.expectEqual(num_waiters - i - 1, notify.waiterCount());
    }

    // All should be woken in FIFO order
    for (&waiters) |*w| {
        try std.testing.expect(w.isNotified());
    }
}

test "Notify - waiter reset and reuse" {
    var notify = Notify.init();
    var woken = false;

    const TestWaker = struct {
        fn wake(ctx: *anyopaque) void {
            const w: *bool = @ptrCast(@alignCast(ctx));
            w.* = true;
        }
    };

    // First use
    var waiter = Waiter.init();
    waiter.setWaker(@ptrCast(&woken), TestWaker.wake);
    _ = notify.wait(&waiter);

    notify.notifyOne();
    try std.testing.expect(waiter.isNotified());
    try std.testing.expect(woken);

    // Reset for reuse
    waiter.reset();
    woken = false;

    try std.testing.expect(!waiter.isNotified());
    try std.testing.expect(waiter.waker == null);

    // Second use
    waiter.setWaker(@ptrCast(&woken), TestWaker.wake);
    _ = notify.wait(&waiter);

    notify.notifyOne();
    try std.testing.expect(waiter.isNotified());
    try std.testing.expect(woken);
}
