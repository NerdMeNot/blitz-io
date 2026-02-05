//! OnceCell - Lazy One-Time Initialization
//!
//! A cell that can be initialized exactly once. Multiple tasks can race to
//! initialize, but only one succeeds. All waiters get the same value.
//!
//! ## Usage
//!
//! ```zig
//! var cell = OnceCell(ExpensiveResource).init();
//!
//! // Multiple tasks can call getOrInit concurrently
//! const resource = cell.getOrInit(initExpensiveResource);
//! // First caller initializes, others wait and get same value
//! ```
//!
//! ## Design
//!
//! - State machine: EMPTY -> INITIALIZING -> INITIALIZED
//! - First caller to transition to INITIALIZING does the init
//! - Other callers wait until INITIALIZED
//! - Value is stored inline (no allocation)
//!
//! Reference: tokio/src/sync/once_cell.rs

const std = @import("std");

const LinkedList = @import("../util/linked_list.zig").LinkedList;
const Pointers = @import("../util/linked_list.zig").Pointers;
const WakeList = @import("../util/wake_list.zig").WakeList;
const InvocationId = @import("../util/invocation_id.zig").InvocationId;

// Unified waiter for the simple blocking API
const unified_waiter = @import("waiter.zig");
const UnifiedWaiter = unified_waiter.Waiter;

// ─────────────────────────────────────────────────────────────────────────────
// State
// ─────────────────────────────────────────────────────────────────────────────

const State = enum(u8) {
    empty,
    initializing,
    initialized,
};

// ─────────────────────────────────────────────────────────────────────────────
// Waiter
// ─────────────────────────────────────────────────────────────────────────────

/// Function pointer type for waking
pub const WakerFn = *const fn (*anyopaque) void;

/// Waiter for initialization completion
pub const InitWaiter = struct {
    waker: ?WakerFn = null,
    waker_ctx: ?*anyopaque = null,
    /// Whether initialization completed (atomic for cross-thread visibility)
    complete: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    pointers: Pointers(InitWaiter) = .{},
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
        self.complete.store(false, .seq_cst);
        self.waker = null;
        self.waker_ctx = null;
        self.pointers.reset();
        self.invocation.bump();
    }
};

const InitWaiterList = LinkedList(InitWaiter, "pointers");

// ─────────────────────────────────────────────────────────────────────────────
// OnceCell
// ─────────────────────────────────────────────────────────────────────────────

/// A cell for lazy one-time initialization.
pub fn OnceCell(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Current state
        state: std.atomic.Value(u8),

        /// The value (valid when state == .initialized)
        value: T,

        /// Mutex for waiters list
        mutex: std.Thread.Mutex,

        /// Waiters for initialization
        waiters: InitWaiterList,

        /// Create an empty OnceCell.
        pub fn init() Self {
            return .{
                .state = std.atomic.Value(u8).init(@intFromEnum(State.empty)),
                .value = undefined,
                .mutex = .{},
                .waiters = .{},
            };
        }

        /// Create an already-initialized OnceCell.
        pub fn initWith(value: T) Self {
            return .{
                .state = std.atomic.Value(u8).init(@intFromEnum(State.initialized)),
                .value = value,
                .mutex = .{},
                .waiters = .{},
            };
        }

        /// No cleanup needed.
        pub fn deinit(self: *Self) void {
            _ = self;
        }

        /// Check if initialized.
        pub fn isInitialized(self: *const Self) bool {
            return @as(State, @enumFromInt(self.state.load(.seq_cst))) == .initialized;
        }

        /// Get the value if initialized.
        pub fn get(self: *Self) ?*T {
            if (self.isInitialized()) {
                return &self.value;
            }
            return null;
        }

        /// Get the value (const version).
        pub fn getConst(self: *const Self) ?*const T {
            if (self.isInitialized()) {
                return &self.value;
            }
            return null;
        }

        /// Try to set the value. Returns false if already initialized.
        pub fn set(self: *Self, value: T) bool {
            // Try to transition EMPTY -> INITIALIZING
            const result = self.state.cmpxchgStrong(
                @intFromEnum(State.empty),
                @intFromEnum(State.initializing),
                .seq_cst,
                .seq_cst,
            );

            if (result != null) {
                // Already initializing or initialized
                return false;
            }

            // We won the race - store value
            self.value = value;

            // Transition to INITIALIZED and wake waiters
            self.completeInit();

            return true;
        }

        /// Get the value, initializing with the provided function if needed.
        /// The init function is only called by the first caller.
        pub fn getOrInit(self: *Self, comptime init_fn: fn () T) *T {
            // Fast path: already initialized
            if (self.isInitialized()) {
                return &self.value;
            }

            // Try to become the initializer
            const result = self.state.cmpxchgStrong(
                @intFromEnum(State.empty),
                @intFromEnum(State.initializing),
                .seq_cst,
                .seq_cst,
            );

            if (result == null) {
                // We won - initialize
                self.value = init_fn();
                self.completeInit();
                return &self.value;
            }

            // Someone else is initializing - wait
            self.waitForInit();
            return &self.value;
        }

        /// Get the value, initializing with the provided function if needed.
        /// This version takes a context argument.
        pub fn getOrInitCtx(
            self: *Self,
            comptime Ctx: type,
            ctx: Ctx,
            comptime init_fn: fn (Ctx) T,
        ) *T {
            // Fast path: already initialized
            if (self.isInitialized()) {
                return &self.value;
            }

            // Try to become the initializer
            const result = self.state.cmpxchgStrong(
                @intFromEnum(State.empty),
                @intFromEnum(State.initializing),
                .seq_cst,
                .seq_cst,
            );

            if (result == null) {
                // We won - initialize
                self.value = init_fn(ctx);
                self.completeInit();
                return &self.value;
            }

            // Someone else is initializing - wait
            self.waitForInit();
            return &self.value;
        }

        /// Async version: get or init, potentially waiting.
        /// Returns the value if already initialized or if we initialize it.
        /// Returns null if we need to wait (waiter added to queue).
        pub fn getOrInitAsync(
            self: *Self,
            comptime init_fn: fn () T,
            waiter: *InitWaiter,
        ) ?*T {
            // Fast path: already initialized
            if (self.isInitialized()) {
                waiter.complete.store(true, .seq_cst);
                return &self.value;
            }

            // Try to become the initializer
            const result = self.state.cmpxchgStrong(
                @intFromEnum(State.empty),
                @intFromEnum(State.initializing),
                .seq_cst,
                .seq_cst,
            );

            if (result == null) {
                // We won - initialize
                self.value = init_fn();
                self.completeInit();
                waiter.complete.store(true, .seq_cst);
                return &self.value;
            }

            // Check if already initialized (race between cmpxchg and now)
            if (self.isInitialized()) {
                waiter.complete.store(true, .seq_cst);
                return &self.value;
            }

            // Someone else is initializing - register waiter
            self.mutex.lock();

            // Re-check under lock
            if (self.isInitialized()) {
                self.mutex.unlock();
                waiter.complete.store(true, .seq_cst);
                return &self.value;
            }

            waiter.complete.store(false, .seq_cst);
            self.waiters.pushBack(waiter);
            self.mutex.unlock();

            return null;
        }

        /// Cancel a pending wait.
        pub fn cancelWait(self: *Self, waiter: *InitWaiter) void {
            if (waiter.isComplete()) return;

            self.mutex.lock();

            if (waiter.isComplete()) {
                self.mutex.unlock();
                return;
            }

            if (InitWaiterList.isLinked(waiter) or self.waiters.front() == waiter) {
                self.waiters.remove(waiter);
                waiter.pointers.reset();
            }

            self.mutex.unlock();
        }

        /// Complete initialization and wake waiters.
        fn completeInit(self: *Self) void {
            var wake_list: WakeList(32) = .{};

            self.mutex.lock();

            // Set to initialized
            self.state.store(@intFromEnum(State.initialized), .seq_cst);

            // Wake all waiters
            // CRITICAL: Copy waker info BEFORE setting complete flag to avoid use-after-free
            while (self.waiters.popFront()) |w| {
                const waker_fn = w.waker;
                const waker_ctx = w.waker_ctx;
                w.complete.store(true, .seq_cst);
                if (waker_fn) |wf| {
                    if (waker_ctx) |ctx| {
                        wake_list.push(.{ .context = ctx, .wake_fn = wf });
                    }
                }
            }

            self.mutex.unlock();

            wake_list.wakeAll();
        }

        /// Wait for initialization to complete (blocking).
        /// Uses the unified Waiter for proper yielding (task context) or blocking (thread context).
        fn waitForInit(self: *Self) void {
            // Fast path: already initialized
            if (self.isInitialized()) {
                return;
            }

            // Set up waiter with unified waiter bridge
            var waiter = InitWaiter.init();
            var unified = UnifiedWaiter.init();
            const WakerBridge = struct {
                fn wake(ctx: *anyopaque) void {
                    const uw: *UnifiedWaiter = @ptrCast(@alignCast(ctx));
                    uw.notify();
                }
            };
            waiter.setWaker(@ptrCast(&unified), WakerBridge.wake);

            self.mutex.lock();

            // Re-check under lock
            if (self.isInitialized()) {
                self.mutex.unlock();
                return;
            }

            // Add to waiters list
            waiter.complete.store(false, .seq_cst);
            self.waiters.pushBack(&waiter);

            self.mutex.unlock();

            // Wait until notified - yields in task context, blocks in thread context
            unified.wait();
        }
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "OnceCell - init empty" {
    var cell = OnceCell(u32).init();
    defer cell.deinit();

    try std.testing.expect(!cell.isInitialized());
    try std.testing.expect(cell.get() == null);
}

test "OnceCell - initWith" {
    var cell = OnceCell(u32).initWith(42);
    defer cell.deinit();

    try std.testing.expect(cell.isInitialized());
    try std.testing.expectEqual(@as(u32, 42), cell.get().?.*);
}

test "OnceCell - set once" {
    var cell = OnceCell(u32).init();
    defer cell.deinit();

    try std.testing.expect(cell.set(42));
    try std.testing.expect(cell.isInitialized());
    try std.testing.expectEqual(@as(u32, 42), cell.get().?.*);

    // Second set fails
    try std.testing.expect(!cell.set(100));
    try std.testing.expectEqual(@as(u32, 42), cell.get().?.*);
}

test "OnceCell - getOrInit" {
    var cell = OnceCell(u32).init();
    defer cell.deinit();

    const initFn = struct {
        fn f() u32 {
            return 42;
        }
    }.f;

    // First call initializes
    const val1 = cell.getOrInit(initFn);
    try std.testing.expectEqual(@as(u32, 42), val1.*);

    // Second call gets same value (doesn't reinitialize)
    const val2 = cell.getOrInit(initFn);
    try std.testing.expectEqual(@as(u32, 42), val2.*);
    try std.testing.expect(val1 == val2); // Same pointer
}

test "OnceCell - async wait" {
    var cell = OnceCell(u32).init();
    defer cell.deinit();
    var woken = false;

    const TestWaker = struct {
        fn wake(ctx: *anyopaque) void {
            const w: *bool = @ptrCast(@alignCast(ctx));
            w.* = true;
        }
    };

    // Simulate another task initializing
    _ = cell.state.cmpxchgStrong(
        @intFromEnum(State.empty),
        @intFromEnum(State.initializing),
        .acq_rel,
        .acquire,
    );

    // This task tries to get
    var waiter = InitWaiter.init();
    waiter.setWaker(@ptrCast(&woken), TestWaker.wake);

    const initFn = struct {
        fn f() u32 {
            return 99;
        }
    }.f;

    const result = cell.getOrInitAsync(initFn, &waiter);
    try std.testing.expect(result == null); // Should wait

    // Complete initialization
    cell.value = 42;
    cell.completeInit();

    try std.testing.expect(woken);
    try std.testing.expect(waiter.complete.load(.acquire));
    try std.testing.expectEqual(@as(u32, 42), cell.get().?.*);
}

test "OnceCell - getOrInitCtx" {
    var cell = OnceCell(u32).init();
    defer cell.deinit();

    const initFn = struct {
        fn f(multiplier: u32) u32 {
            return 10 * multiplier;
        }
    }.f;

    const val = cell.getOrInitCtx(u32, 5, initFn);
    try std.testing.expectEqual(@as(u32, 50), val.*);
}
