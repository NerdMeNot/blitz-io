//! Oneshot - Single-Value Channel
//!
//! A channel for sending a single value from one task to another.
//! The sender can send exactly one value, and the receiver receives it.
//!
//! ## Usage
//!
//! ```zig
//! // Create channel pair
//! var pair = Oneshot(u32).init();
//! var tx = pair.sender;
//! var rx = pair.receiver;
//!
//! // Sender side:
//! tx.send(42);  // Sends value
//!
//! // Receiver side:
//! var waiter = Oneshot(u32).RecvWaiter.init();
//! if (rx.tryRecv()) |value| {
//!     // Got value immediately
//! } else if (!rx.recv(&waiter)) {
//!     // Yield task, wait for notification
//! }
//! const value = waiter.value.?;  // After woken
//! ```
//!
//! ## Design
//!
//! - Zero-allocation: sender/receiver are value types
//! - State machine tracks: empty, value_sent, receiver_waiting, closed
//! - Thread-safe through atomic state transitions
//!
//! Reference: tokio/src/sync/oneshot.rs

const std = @import("std");
const builtin = @import("builtin");

// ─────────────────────────────────────────────────────────────────────────────
// State
// ─────────────────────────────────────────────────────────────────────────────

/// Channel state
const State = enum(u8) {
    /// Channel is empty, no value sent
    empty,
    /// Value has been sent, waiting for receiver
    value_sent,
    /// Receiver is waiting for value
    receiver_waiting,
    /// Channel is closed (sender dropped without sending)
    closed,
};

// ─────────────────────────────────────────────────────────────────────────────
// Oneshot
// ─────────────────────────────────────────────────────────────────────────────

/// A oneshot channel for sending a single value.
pub fn Oneshot(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Shared state between sender and receiver
        pub const Shared = struct {
            /// Channel state
            state: std.atomic.Value(u8),

            /// The value (valid when state == .value_sent)
            value: ?T,

            /// Waiting receiver (valid when state == .receiver_waiting)
            /// We store the waiter pointer so sender can set waiter.value directly
            waiter: ?*RecvWaiter,

            /// Mutex for state transitions
            mutex: std.Thread.Mutex,

            pub fn init() Shared {
                return .{
                    .state = std.atomic.Value(u8).init(@intFromEnum(State.empty)),
                    .value = null,
                    .waiter = null,
                    .mutex = .{},
                };
            }
        };

        /// Waiter for receive operation
        pub const RecvWaiter = struct {
            /// Received value (set when notified)
            value: ?T = null,

            /// Error if channel closed
            closed: bool = false,

            /// Waker to invoke when value arrives
            waker: ?WakerFn = null,
            waker_ctx: ?*anyopaque = null,

            pub fn init() RecvWaiter {
                return .{};
            }

            pub fn setWaker(self: *RecvWaiter, ctx: *anyopaque, wake_fn: WakerFn) void {
                self.waker_ctx = ctx;
                self.waker = wake_fn;
            }

            pub fn isComplete(self: *const RecvWaiter) bool {
                return self.value != null or self.closed;
            }

            pub fn reset(self: *RecvWaiter) void {
                self.value = null;
                self.closed = false;
                self.waker = null;
                self.waker_ctx = null;
            }
        };

        /// Function pointer type for waking
        pub const WakerFn = *const fn (*anyopaque) void;

        /// Sender half of the channel
        pub const Sender = struct {
            shared: *Shared,
            sent: bool = false,

            /// Send a value through the channel.
            /// Returns true if value was delivered (or will be), false if receiver is gone.
            pub fn send(self: *Sender, value: T) bool {
                if (self.sent) return false;
                self.sent = true;

                self.shared.mutex.lock();

                const state: State = @enumFromInt(self.shared.state.load(.acquire));

                switch (state) {
                    .empty => {
                        // No receiver waiting, store value
                        self.shared.value = value;
                        self.shared.state.store(@intFromEnum(State.value_sent), .release);
                        self.shared.mutex.unlock();
                        return true;
                    },
                    .receiver_waiting => {
                        // Receiver is waiting, deliver directly to waiter
                        // Copy waiter pointer and waker info BEFORE setting value
                        // (to avoid use-after-free if waiter checks value and destroys itself)
                        const waiter = self.shared.waiter.?;
                        const waker = waiter.waker;
                        const ctx = waiter.waker_ctx;

                        // Store value in both places
                        self.shared.value = value;
                        waiter.value = value;

                        // Clear waiter pointer and update state
                        self.shared.waiter = null;
                        self.shared.state.store(@intFromEnum(State.value_sent), .release);

                        self.shared.mutex.unlock();

                        // Wake receiver outside lock using copied waker
                        if (waker) |wf| {
                            if (ctx) |c| {
                                wf(c);
                            }
                        }
                        return true;
                    },
                    .closed, .value_sent => {
                        // Already closed or sent (shouldn't happen)
                        self.shared.mutex.unlock();
                        return false;
                    },
                }
            }

            /// Check if receiver is still alive.
            pub fn isReceiverAlive(self: *const Sender) bool {
                const state: State = @enumFromInt(self.shared.state.load(.acquire));
                return state != .closed;
            }

            /// Close without sending (signals error to receiver).
            pub fn close(self: *Sender) void {
                if (self.sent) return;
                self.sent = true;

                self.shared.mutex.lock();

                const state: State = @enumFromInt(self.shared.state.load(.acquire));

                if (state == .receiver_waiting) {
                    // Copy waiter pointer and waker info BEFORE setting closed flag
                    const waiter = self.shared.waiter.?;
                    const waker = waiter.waker;
                    const ctx = waiter.waker_ctx;

                    // Set closed flag on waiter
                    waiter.closed = true;

                    // Clear waiter pointer and update state
                    self.shared.waiter = null;
                    self.shared.state.store(@intFromEnum(State.closed), .release);

                    self.shared.mutex.unlock();

                    // Wake receiver outside lock using copied waker
                    if (waker) |wf| {
                        if (ctx) |c| {
                            wf(c);
                        }
                    }
                } else {
                    self.shared.state.store(@intFromEnum(State.closed), .release);
                    self.shared.mutex.unlock();
                }
            }
        };

        /// Receiver half of the channel
        pub const Receiver = struct {
            shared: *Shared,
            received: bool = false,

            /// Try to receive without waiting.
            /// Returns the value if available, null otherwise.
            pub fn tryRecv(self: *Receiver) ?T {
                if (self.received) return null;

                const state: State = @enumFromInt(self.shared.state.load(.acquire));

                if (state == .value_sent) {
                    self.received = true;
                    return self.shared.value;
                }

                return null;
            }

            /// Try to receive, returning error info.
            pub const TryRecvResult = union(enum) {
                value: T,
                empty: void,
                closed: void,
            };

            pub fn tryRecvResult(self: *Receiver) TryRecvResult {
                if (self.received) return .{ .closed = {} };

                const state: State = @enumFromInt(self.shared.state.load(.acquire));

                switch (state) {
                    .value_sent => {
                        self.received = true;
                        return .{ .value = self.shared.value.? };
                    },
                    .closed => {
                        self.received = true;
                        return .{ .closed = {} };
                    },
                    else => return .{ .empty = {} },
                }
            }

            /// Receive, potentially waiting.
            /// Returns true if value was received immediately.
            /// Returns false if receiver is now waiting (task should yield).
            ///
            /// After waking, check waiter.value or waiter.closed.
            pub fn recv(self: *Receiver, waiter: *RecvWaiter) bool {
                if (self.received) {
                    waiter.closed = true;
                    return true;
                }

                self.shared.mutex.lock();

                const state: State = @enumFromInt(self.shared.state.load(.acquire));

                switch (state) {
                    .value_sent => {
                        self.received = true;
                        waiter.value = self.shared.value;
                        self.shared.mutex.unlock();
                        return true;
                    },
                    .closed => {
                        self.received = true;
                        waiter.closed = true;
                        self.shared.mutex.unlock();
                        return true;
                    },
                    .empty => {
                        // Register waiter (store pointer so sender can set waiter.value)
                        self.shared.waiter = waiter;
                        self.shared.state.store(@intFromEnum(State.receiver_waiting), .release);
                        self.shared.mutex.unlock();
                        return false;
                    },
                    .receiver_waiting => {
                        // Already waiting (shouldn't happen)
                        self.shared.mutex.unlock();
                        return false;
                    },
                }
            }

            /// Cancel a pending receive.
            pub fn cancelRecv(self: *Receiver) void {
                self.shared.mutex.lock();

                const state: State = @enumFromInt(self.shared.state.load(.acquire));

                if (state == .receiver_waiting) {
                    self.shared.waiter = null;
                    self.shared.state.store(@intFromEnum(State.empty), .release);
                }

                self.shared.mutex.unlock();
            }

            /// Close the receiver (signals to sender).
            pub fn close(self: *Receiver) void {
                if (self.received) return;
                self.received = true;

                self.shared.mutex.lock();
                self.shared.state.store(@intFromEnum(State.closed), .release);
                self.shared.mutex.unlock();
            }
        };

        /// Create a new oneshot channel.
        /// Returns the shared state and sender/receiver pair.
        pub fn init() struct { shared: Shared, sender: Sender, receiver: Receiver } {
            var result: struct { shared: Shared, sender: Sender, receiver: Receiver } = undefined;
            result.shared = Shared.init();
            result.sender = .{ .shared = &result.shared };
            result.receiver = .{ .shared = &result.shared };
            return result;
        }

        /// Create sender and receiver from existing shared state.
        /// Use this when shared state is allocated separately.
        pub fn fromShared(shared: *Shared) struct { sender: Sender, receiver: Receiver } {
            return .{
                .sender = .{ .shared = shared },
                .receiver = .{ .shared = shared },
            };
        }
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "Oneshot - send then receive" {
    const Ch = Oneshot(u32);
    var shared = Ch.Shared.init();
    var pair = Ch.fromShared(&shared);

    // Send value
    try std.testing.expect(pair.sender.send(42));

    // Receive should get it immediately
    const value = pair.receiver.tryRecv();
    try std.testing.expectEqual(@as(?u32, 42), value);
}

test "Oneshot - receive then send" {
    const Ch = Oneshot(u32);
    var shared = Ch.Shared.init();
    var pair = Ch.fromShared(&shared);
    var woken = false;

    const TestWaker = struct {
        fn wake(ctx: *anyopaque) void {
            const w: *bool = @ptrCast(@alignCast(ctx));
            w.* = true;
        }
    };

    // Try receive - should be empty
    try std.testing.expect(pair.receiver.tryRecv() == null);

    // Start waiting
    var waiter = Ch.RecvWaiter.init();
    waiter.setWaker(@ptrCast(&woken), TestWaker.wake);
    try std.testing.expect(!pair.receiver.recv(&waiter));
    try std.testing.expect(!waiter.isComplete());

    // Send value
    try std.testing.expect(pair.sender.send(42));
    try std.testing.expect(woken);

    // Waiter should now have value (need to check shared state)
    try std.testing.expectEqual(@as(?u32, 42), shared.value);
}

test "Oneshot - sender close wakes receiver" {
    const Ch = Oneshot(u32);
    var shared = Ch.Shared.init();
    var pair = Ch.fromShared(&shared);
    var woken = false;

    const TestWaker = struct {
        fn wake(ctx: *anyopaque) void {
            const w: *bool = @ptrCast(@alignCast(ctx));
            w.* = true;
        }
    };

    // Start waiting
    var waiter = Ch.RecvWaiter.init();
    waiter.setWaker(@ptrCast(&woken), TestWaker.wake);
    _ = pair.receiver.recv(&waiter);

    // Close sender
    pair.sender.close();
    try std.testing.expect(woken);

    // State should be closed
    const state: State = @enumFromInt(shared.state.load(.acquire));
    try std.testing.expectEqual(State.closed, state);
}

test "Oneshot - double send fails" {
    const Ch = Oneshot(u32);
    var shared = Ch.Shared.init();
    var pair = Ch.fromShared(&shared);

    try std.testing.expect(pair.sender.send(1));
    try std.testing.expect(!pair.sender.send(2)); // Should fail
}

test "Oneshot - tryRecvResult" {
    const Ch = Oneshot(u32);

    // Test empty
    {
        var shared = Ch.Shared.init();
        var pair = Ch.fromShared(&shared);
        const result = pair.receiver.tryRecvResult();
        try std.testing.expect(result == .empty);
    }

    // Test value
    {
        var shared = Ch.Shared.init();
        var pair = Ch.fromShared(&shared);
        _ = pair.sender.send(42);
        const result = pair.receiver.tryRecvResult();
        try std.testing.expectEqual(Ch.Receiver.TryRecvResult{ .value = 42 }, result);
    }

    // Test closed
    {
        var shared = Ch.Shared.init();
        var pair = Ch.fromShared(&shared);
        pair.sender.close();
        const result = pair.receiver.tryRecvResult();
        try std.testing.expect(result == .closed);
    }
}
