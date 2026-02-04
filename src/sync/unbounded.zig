//! Unbounded Channel - MPSC with No Send Blocking
//!
//! An unbounded multi-producer single-consumer channel. Senders never block;
//! values are queued until the receiver consumes them.
//!
//! ## Usage
//!
//! ```zig
//! var channel = UnboundedChannel(u32).init(allocator);
//! defer channel.deinit();
//!
//! // Senders (never block)
//! try channel.send(1);
//! try channel.send(2);
//!
//! // Receiver
//! if (channel.tryRecv()) |value| {
//!     // Process value
//! }
//! ```
//!
//! ## Design
//!
//! - Linked list of values (allocates on send)
//! - Senders never wait
//! - Receiver waits when empty
//! - Thread-safe via mutex
//!
//! Reference: tokio/src/sync/mpsc/unbounded.rs

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const LinkedList = @import("../util/linked_list.zig").LinkedList;
const Pointers = @import("../util/linked_list.zig").Pointers;
const WakeList = @import("../util/wake_list.zig").WakeList;

// ─────────────────────────────────────────────────────────────────────────────
// Waiter
// ─────────────────────────────────────────────────────────────────────────────

/// Function pointer type for waking
pub const WakerFn = *const fn (*anyopaque) void;

/// Waiter for receive operation
pub const RecvWaiter = struct {
    waker: ?WakerFn = null,
    waker_ctx: ?*anyopaque = null,
    complete: bool = false,
    closed: bool = false,
    pointers: Pointers(RecvWaiter) = .{},

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
        return self.complete or self.closed;
    }

    pub fn reset(self: *Self) void {
        self.complete = false;
        self.closed = false;
        self.waker = null;
        self.waker_ctx = null;
        self.pointers.reset();
    }
};

const RecvWaiterList = LinkedList(RecvWaiter, "pointers");

// ─────────────────────────────────────────────────────────────────────────────
// UnboundedChannel
// ─────────────────────────────────────────────────────────────────────────────

/// An unbounded MPSC channel.
pub fn UnboundedChannel(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Node in the message queue
        const Node = struct {
            value: T,
            next: ?*Node,
        };

        /// Allocator for nodes
        allocator: Allocator,

        /// Head of message queue (oldest)
        head: ?*Node,

        /// Tail of message queue (newest)
        tail: ?*Node,

        /// Number of messages in queue
        count: usize,

        /// Whether the channel is closed
        closed: bool,

        /// Mutex protecting internal state
        mutex: std.Thread.Mutex,

        /// Waiting receivers
        recv_waiters: RecvWaiterList,

        /// Send result
        pub const SendResult = enum {
            ok,
            closed,
        };

        /// Receive result
        pub const RecvResult = union(enum) {
            value: T,
            empty,
            closed,
        };

        /// Create a new unbounded channel.
        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .head = null,
                .tail = null,
                .count = 0,
                .closed = false,
                .mutex = .{},
                .recv_waiters = .{},
            };
        }

        /// Destroy the channel, freeing any queued messages.
        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Free all queued nodes
            var node = self.head;
            while (node) |n| {
                const next = n.next;
                self.allocator.destroy(n);
                node = next;
            }
            self.head = null;
            self.tail = null;
            self.count = 0;
        }

        // ═══════════════════════════════════════════════════════════════════
        // Send (Never Blocks)
        // ═══════════════════════════════════════════════════════════════════

        /// Send a value. Never blocks. Returns error on allocation failure.
        pub fn send(self: *Self, value: T) !SendResult {
            // Allocate node outside lock
            const node = try self.allocator.create(Node);
            node.* = .{ .value = value, .next = null };

            var waiter_to_wake: ?*RecvWaiter = null;

            self.mutex.lock();

            if (self.closed) {
                self.mutex.unlock();
                self.allocator.destroy(node);
                return .closed;
            }

            // Append to queue
            if (self.tail) |tail| {
                tail.next = node;
            } else {
                self.head = node;
            }
            self.tail = node;
            self.count += 1;

            // Wake one receiver if any
            waiter_to_wake = self.recv_waiters.popFront();
            if (waiter_to_wake) |w| {
                w.complete = true;
            }

            self.mutex.unlock();

            // Wake outside lock
            if (waiter_to_wake) |w| {
                w.wake();
            }

            return .ok;
        }

        // ═══════════════════════════════════════════════════════════════════
        // Receive
        // ═══════════════════════════════════════════════════════════════════

        /// Try to receive without waiting.
        pub fn tryRecv(self: *Self) RecvResult {
            self.mutex.lock();

            if (self.head) |node| {
                // Remove from queue
                self.head = node.next;
                if (self.head == null) {
                    self.tail = null;
                }
                self.count -= 1;

                const value = node.value;
                self.mutex.unlock();

                self.allocator.destroy(node);
                return .{ .value = value };
            }

            if (self.closed) {
                self.mutex.unlock();
                return .closed;
            }

            self.mutex.unlock();
            return .empty;
        }

        /// Receive, potentially waiting if empty.
        /// Returns value if received immediately.
        /// Returns null if waiting (task should yield).
        pub fn recv(self: *Self, waiter: *RecvWaiter) ?T {
            self.mutex.lock();

            if (self.head) |node| {
                // Remove from queue
                self.head = node.next;
                if (self.head == null) {
                    self.tail = null;
                }
                self.count -= 1;

                const value = node.value;
                self.mutex.unlock();

                self.allocator.destroy(node);
                waiter.complete = true;
                return value;
            }

            if (self.closed) {
                self.mutex.unlock();
                waiter.closed = true;
                return null;
            }

            // Wait for sender
            waiter.complete = false;
            waiter.closed = false;
            self.recv_waiters.pushBack(waiter);

            self.mutex.unlock();
            return null;
        }

        /// Cancel a pending receive.
        pub fn cancelRecv(self: *Self, waiter: *RecvWaiter) void {
            if (waiter.isComplete()) return;

            self.mutex.lock();

            if (waiter.isComplete()) {
                self.mutex.unlock();
                return;
            }

            if (RecvWaiterList.isLinked(waiter) or self.recv_waiters.front() == waiter) {
                self.recv_waiters.remove(waiter);
                waiter.pointers.reset();
            }

            self.mutex.unlock();
        }

        // ═══════════════════════════════════════════════════════════════════
        // Channel Control
        // ═══════════════════════════════════════════════════════════════════

        /// Close the channel.
        pub fn close(self: *Self) void {
            var wake_list: WakeList(32) = .{};

            self.mutex.lock();

            if (self.closed) {
                self.mutex.unlock();
                return;
            }

            self.closed = true;

            // Wake all recv waiters
            while (self.recv_waiters.popFront()) |w| {
                w.closed = true;
                if (w.waker) |wf| {
                    if (w.waker_ctx) |ctx| {
                        wake_list.push(.{ .context = ctx, .wake_fn = wf });
                    }
                }
            }

            self.mutex.unlock();

            wake_list.wakeAll();
        }

        /// Check if closed.
        pub fn isClosed(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.closed;
        }

        /// Get queue length.
        pub fn len(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.count;
        }

        /// Check if empty.
        pub fn isEmpty(self: *Self) bool {
            return self.len() == 0;
        }
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "UnboundedChannel - send and recv" {
    var ch = UnboundedChannel(u32).init(std.testing.allocator);
    defer ch.deinit();

    _ = try ch.send(1);
    _ = try ch.send(2);
    _ = try ch.send(3);

    try std.testing.expectEqual(@as(usize, 3), ch.len());

    try std.testing.expectEqual(UnboundedChannel(u32).RecvResult{ .value = 1 }, ch.tryRecv());
    try std.testing.expectEqual(UnboundedChannel(u32).RecvResult{ .value = 2 }, ch.tryRecv());
    try std.testing.expectEqual(UnboundedChannel(u32).RecvResult{ .value = 3 }, ch.tryRecv());
    try std.testing.expect(ch.tryRecv() == .empty);
}

test "UnboundedChannel - never blocks sender" {
    var ch = UnboundedChannel(u32).init(std.testing.allocator);
    defer ch.deinit();

    // Can send many without blocking
    for (0..1000) |i| {
        const result = try ch.send(@intCast(i));
        try std.testing.expectEqual(UnboundedChannel(u32).SendResult.ok, result);
    }

    try std.testing.expectEqual(@as(usize, 1000), ch.len());
}

test "UnboundedChannel - recv waits for send" {
    var ch = UnboundedChannel(u32).init(std.testing.allocator);
    defer ch.deinit();
    var woken = false;

    const TestWaker = struct {
        fn wake(ctx: *anyopaque) void {
            const w: *bool = @ptrCast(@alignCast(ctx));
            w.* = true;
        }
    };

    // Recv on empty channel
    var waiter = RecvWaiter.init();
    waiter.setWaker(@ptrCast(&woken), TestWaker.wake);
    const value = ch.recv(&waiter);

    try std.testing.expect(value == null);
    try std.testing.expect(!waiter.isComplete());

    // Send wakes receiver
    _ = try ch.send(42);
    try std.testing.expect(woken);
    try std.testing.expect(waiter.complete);
}

test "UnboundedChannel - close wakes waiters" {
    var ch = UnboundedChannel(u32).init(std.testing.allocator);
    defer ch.deinit();
    var woken = false;

    const TestWaker = struct {
        fn wake(ctx: *anyopaque) void {
            const w: *bool = @ptrCast(@alignCast(ctx));
            w.* = true;
        }
    };

    var waiter = RecvWaiter.init();
    waiter.setWaker(@ptrCast(&woken), TestWaker.wake);
    _ = ch.recv(&waiter);

    ch.close();

    try std.testing.expect(woken);
    try std.testing.expect(waiter.closed);
}

test "UnboundedChannel - closed rejects send" {
    var ch = UnboundedChannel(u32).init(std.testing.allocator);
    defer ch.deinit();

    ch.close();

    const result = try ch.send(1);
    try std.testing.expectEqual(UnboundedChannel(u32).SendResult.closed, result);
}

test "UnboundedChannel - FIFO ordering" {
    var ch = UnboundedChannel(u32).init(std.testing.allocator);
    defer ch.deinit();

    _ = try ch.send(1);
    _ = try ch.send(2);
    _ = try ch.send(3);

    try std.testing.expectEqual(UnboundedChannel(u32).RecvResult{ .value = 1 }, ch.tryRecv());
    try std.testing.expectEqual(UnboundedChannel(u32).RecvResult{ .value = 2 }, ch.tryRecv());
    try std.testing.expectEqual(UnboundedChannel(u32).RecvResult{ .value = 3 }, ch.tryRecv());
}
