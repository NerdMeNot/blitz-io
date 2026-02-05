//! Unified Waiter - Async-Aware Wait Primitive
//!
//! A unified waiter type that works in both async task context and blocking
//! thread context.
//!
//! ## Execution Contexts
//!
//! **Thread Context** (blocking pool, OS threads):
//! - `wait()` uses efficient futex blocking
//! - CPU sleeps until notified by OS
//! - Use `*Blocking()` APIs (e.g., `lockBlocking()`, `recvBlocking()`)
//!
//! **Task Context** (async tasks via `runtime.spawn()`):
//! - Use **non-blocking** APIs: `tryLock()`, `lock(waiter)`, etc.
//! - Check if operation succeeded immediately
//! - If not, store waker and **yield from your poll function**
//! - When notified, your task is re-scheduled and re-polled
//!
//! ## Correct Async Usage Pattern
//!
//! ```zig
//! // In your async task's poll function:
//! fn poll(self: *Self, waker: *Waker) PollResult {
//!     // Try fast path
//!     if (self.mutex.tryLock()) {
//!         // Got lock, do work
//!         return .ready;
//!     }
//!
//!     // Slow path: register waiter and yield
//!     if (!self.registered) {
//!         self.waiter.task_waker = waker;
//!         _ = self.mutex.lock(&self.waiter);
//!         self.registered = true;
//!     }
//!
//!     // Check if acquired while we were registering
//!     if (self.waiter.isNotified()) {
//!         // Got lock!
//!         return .ready;
//!     }
//!
//!     // Still waiting - yield to scheduler
//!     return .pending;
//! }
//! ```
//!
//! ## WARNING: `*Blocking()` APIs in Task Context
//!
//! The `*Blocking()` convenience methods (e.g., `lockBlocking()`) use spin-wait
//! with exponential backoff when called from task context. This works but is
//! **inefficient** - it wastes CPU cycles instead of yielding properly.
//!
//! For best performance in async code, use the non-blocking APIs and implement
//! proper poll/yield patterns.
//!
//! ## Thread Safety
//!
//! - `state` is atomic for cross-thread visibility
//! - `notify()` can be called from any thread
//! - `wait()` must be called from the waiting thread/task
//!
//! Reference: Inspired by Tokio's task waking and Rust's Waker pattern

const std = @import("std");
const builtin = @import("builtin");

const LinkedList = @import("../util/linked_list.zig").LinkedList;
const Pointers = @import("../util/linked_list.zig").Pointers;
const InvocationId = @import("../util/invocation_id.zig").InvocationId;

// Import the task Waker type
const executor_mod = @import("../executor.zig");
const TaskWaker = executor_mod.Waker;

// ─────────────────────────────────────────────────────────────────────────────
// Unified Waiter
// ─────────────────────────────────────────────────────────────────────────────

/// Waiter state
pub const State = enum(u32) {
    /// Waiter is waiting for notification
    waiting = 0,
    /// Waiter has been notified
    notified = 1,
    /// Waiter has been cancelled/closed
    closed = 2,
};

/// Unified waiter for all sync primitives.
/// Works in both task context (yields via waker) and blocking context (futex wait).
pub const Waiter = struct {
    /// Current state (atomic for cross-thread visibility)
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(@intFromEnum(State.waiting)),

    /// Intrusive list pointers for wait queues
    pointers: Pointers(Waiter) = .{},

    /// Debug-mode invocation tracking (detects use-after-free)
    invocation: InvocationId = .{},

    /// Task waker - set this if waiting from a task context.
    /// When set and notify() is called, the task will be re-scheduled.
    task_waker: ?*TaskWaker = null,

    const Self = @This();

    /// Spin backoff constants for task context waiting
    const MIN_SPIN_NS: u64 = 1_000; // 1µs
    const MAX_SPIN_NS: u64 = 1_000_000; // 1ms
    const BACKOFF_MULTIPLIER: u64 = 2;

    /// Create a new waiter in waiting state
    pub fn init() Self {
        return .{};
    }

    /// Wait until notified.
    ///
    /// **Thread context**: Uses efficient futex wait (CPU sleeps).
    ///
    /// **Task context**: Uses spin-wait with exponential backoff.
    /// For better efficiency, use non-blocking APIs and proper yield patterns.
    pub fn wait(self: *Self) void {
        var spin_ns: u64 = MIN_SPIN_NS;

        while (self.state.load(.acquire) == @intFromEnum(State.waiting)) {
            if (self.task_waker != null) {
                // Task context: spin-wait with exponential backoff
                // NOTE: This is inefficient. Prefer non-blocking APIs with proper yields.
                // The waker will re-schedule us when notify() is called, but we're
                // burning CPU here instead of yielding to the scheduler.
                std.Thread.sleep(spin_ns);
                spin_ns = @min(spin_ns * BACKOFF_MULTIPLIER, MAX_SPIN_NS);
            } else {
                // Thread context: efficient futex wait
                std.Thread.Futex.wait(
                    @ptrCast(&self.state),
                    @intFromEnum(State.waiting),
                );
            }
        }
    }

    /// Wait with timeout.
    /// Returns true if notified, false if timed out.
    pub fn waitTimeout(self: *Self, timeout_ns: u64) bool {
        const deadline = std.time.nanoTimestamp() + @as(i128, timeout_ns);
        var spin_ns: u64 = MIN_SPIN_NS;

        while (self.state.load(.acquire) == @intFromEnum(State.waiting)) {
            const now = std.time.nanoTimestamp();
            if (now >= deadline) {
                return false; // Timed out
            }

            const remaining: u64 = @intCast(deadline - now);

            if (self.task_waker != null) {
                // Task context: spin-wait with backoff, respecting timeout
                const sleep_ns = @min(spin_ns, remaining);
                std.Thread.sleep(sleep_ns);
                spin_ns = @min(spin_ns * BACKOFF_MULTIPLIER, MAX_SPIN_NS);
            } else {
                // Thread context: timed futex wait
                std.Thread.Futex.timedWait(
                    @ptrCast(&self.state),
                    @intFromEnum(State.waiting),
                    remaining,
                ) catch {
                    // Timeout or spurious wakeup - check state again
                };
            }
        }
        return true;
    }

    /// Notify the waiter, waking it from wait().
    ///
    /// Safe to call from any thread. If the waiter has a task_waker set,
    /// the task will be re-scheduled for execution.
    pub fn notify(self: *Self) void {
        // Set state FIRST
        self.state.store(@intFromEnum(State.notified), .release);

        // Wake task if in task context
        // This schedules the task for re-polling
        if (self.task_waker) |w| {
            w.wakeByRef();
        }

        // Also futex wake (handles thread context and races)
        std.Thread.Futex.wake(@ptrCast(&self.state), 1);
    }

    /// Close the waiter (e.g., when the primitive is being destroyed)
    pub fn close(self: *Self) void {
        self.state.store(@intFromEnum(State.closed), .release);

        if (self.task_waker) |w| {
            w.wakeByRef();
        }

        std.Thread.Futex.wake(@ptrCast(&self.state), 1);
    }

    /// Check if notified (non-blocking)
    pub fn isNotified(self: *const Self) bool {
        return self.state.load(.acquire) == @intFromEnum(State.notified);
    }

    /// Check if closed (non-blocking)
    pub fn isClosed(self: *const Self) bool {
        return self.state.load(.acquire) == @intFromEnum(State.closed);
    }

    /// Check if still waiting (non-blocking)
    pub fn isWaiting(self: *const Self) bool {
        return self.state.load(.acquire) == @intFromEnum(State.waiting);
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
        self.state.store(@intFromEnum(State.waiting), .release);
        self.task_waker = null;
        self.pointers.reset();
        self.invocation.bump();
    }
};

/// Type alias for waiter list
pub const WaiterList = LinkedList(Waiter, "pointers");

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "Waiter - init and state" {
    var waiter = Waiter.init();

    try std.testing.expect(!waiter.isNotified());
    try std.testing.expect(!waiter.isClosed());
    try std.testing.expect(waiter.isWaiting());
    try std.testing.expectEqual(@intFromEnum(State.waiting), waiter.state.load(.acquire));
}

test "Waiter - notify wakes waiter" {
    var waiter = Waiter.init();

    // Notify without waiting (should not block)
    waiter.notify();

    try std.testing.expect(waiter.isNotified());
    try std.testing.expect(!waiter.isWaiting());
}

test "Waiter - close sets closed state" {
    var waiter = Waiter.init();

    waiter.close();

    try std.testing.expect(waiter.isClosed());
    try std.testing.expect(!waiter.isNotified());
    try std.testing.expect(!waiter.isWaiting());
}

test "Waiter - reset clears state" {
    var waiter = Waiter.init();

    waiter.notify();
    try std.testing.expect(waiter.isNotified());

    waiter.reset();
    try std.testing.expect(!waiter.isNotified());
    try std.testing.expect(!waiter.isClosed());
    try std.testing.expect(waiter.isWaiting());
}

test "Waiter - notify before wait" {
    var waiter = Waiter.init();

    // Notify first
    waiter.notify();

    // Wait should return immediately
    waiter.wait();

    try std.testing.expect(waiter.isNotified());
}

test "Waiter - waitTimeout returns false on timeout" {
    var waiter = Waiter.init();

    // Very short timeout - should time out
    const result = waiter.waitTimeout(1000); // 1µs

    try std.testing.expect(!result);
}

test "Waiter - waitTimeout returns true when notified" {
    var waiter = Waiter.init();

    // Notify first
    waiter.notify();

    // Should return true immediately
    const result = waiter.waitTimeout(1_000_000_000); // 1s timeout

    try std.testing.expect(result);
}

test "WaiterList - basic operations" {
    var list: WaiterList = .{};

    var w1 = Waiter.init();
    var w2 = Waiter.init();
    var w3 = Waiter.init();

    list.pushBack(&w1);
    list.pushBack(&w2);
    list.pushBack(&w3);

    try std.testing.expectEqual(@as(usize, 3), list.count());

    try std.testing.expectEqual(&w1, list.popFront().?);
    try std.testing.expectEqual(&w2, list.popFront().?);
    try std.testing.expectEqual(&w3, list.popFront().?);
    try std.testing.expect(list.isEmpty());
}

test "Waiter - invocation tracking" {
    if (builtin.mode != .Debug) return;

    var waiter = Waiter.init();
    waiter.invocation.bump(); // Initialize the ID

    const tok1 = waiter.token();

    waiter.reset();
    const tok2 = waiter.token();

    // Tokens should be different after reset
    try std.testing.expect(tok1 != tok2);
}

test "Waiter - exponential backoff bounds" {
    // Verify the constants are reasonable
    try std.testing.expect(Waiter.MIN_SPIN_NS < Waiter.MAX_SPIN_NS);
    try std.testing.expectEqual(@as(u64, 1_000), Waiter.MIN_SPIN_NS);
    try std.testing.expectEqual(@as(u64, 1_000_000), Waiter.MAX_SPIN_NS);
}
