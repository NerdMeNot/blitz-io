//! Broadcast Channel - Multi-Producer Multi-Consumer
//!
//! A broadcast channel where each sent value is received by ALL receivers.
//! Uses a ring buffer with reference counting per slot.
//!
//! ## Usage
//!
//! ```zig
//! var channel = try BroadcastChannel(u32).init(allocator, 16);
//! defer channel.deinit();
//!
//! // Create receivers
//! var rx1 = channel.subscribe();
//! var rx2 = channel.subscribe();
//!
//! // Send broadcasts to all
//! _ = channel.send(42);
//!
//! // Each receiver gets the value
//! _ = rx1.tryRecv();  // 42
//! _ = rx2.tryRecv();  // 42
//! ```
//!
//! ## Design
//!
//! - Ring buffer with capacity
//! - Each receiver tracks its position
//! - Lagging receivers may miss messages (configurable behavior)
//! - Senders never block
//!
//! Reference: tokio/src/sync/broadcast.rs

const std = @import("std");
const Allocator = std.mem.Allocator;

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

/// Waiter for receive operation
pub const RecvWaiter = struct {
    waker: ?WakerFn = null,
    waker_ctx: ?*anyopaque = null,
    /// Whether receive completed (atomic for cross-thread visibility)
    complete: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Whether channel was closed (atomic for cross-thread visibility)
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    pointers: Pointers(RecvWaiter) = .{},
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
        return self.complete.load(.seq_cst) or self.closed.load(.seq_cst);
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
        self.closed.store(false, .seq_cst);
        self.waker = null;
        self.waker_ctx = null;
        self.pointers.reset();
        self.invocation.bump();
    }
};

const RecvWaiterList = LinkedList(RecvWaiter, "pointers");

// ─────────────────────────────────────────────────────────────────────────────
// BroadcastChannel
// ─────────────────────────────────────────────────────────────────────────────

/// A broadcast channel.
pub fn BroadcastChannel(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Slot in the ring buffer
        const Slot = struct {
            value: T,
            /// Sequence number when this was written
            seq: u64,
        };

        /// Ring buffer
        buffer: []Slot,

        /// Allocator
        allocator: Allocator,

        /// Capacity
        capacity: usize,

        /// Current write position (next sequence to write)
        write_seq: u64,

        /// Number of active receivers
        receiver_count: usize,

        /// Whether the channel is closed
        closed: bool,

        /// Mutex protecting internal state
        mutex: std.Thread.Mutex,

        /// Waiting receivers
        recv_waiters: RecvWaiterList,

        /// Receiver handle
        pub const Receiver = struct {
            channel: *Self,
            /// Next sequence this receiver expects
            read_seq: u64,

            /// Receive result
            pub const RecvResult = union(enum) {
                value: T,
                empty,
                lagged: u64, // Number of missed messages
                closed,
            };

            /// Try to receive without waiting.
            pub fn tryRecv(self: *Receiver) RecvResult {
                self.channel.mutex.lock();
                defer self.channel.mutex.unlock();

                // Check if we're lagging
                const oldest_seq = if (self.channel.write_seq > self.channel.capacity)
                    self.channel.write_seq - self.channel.capacity
                else
                    0;

                if (self.read_seq < oldest_seq) {
                    // We missed some messages
                    const missed = oldest_seq - self.read_seq;
                    self.read_seq = oldest_seq;
                    return .{ .lagged = missed };
                }

                // Check if anything to read
                if (self.read_seq >= self.channel.write_seq) {
                    if (self.channel.closed) {
                        return .closed;
                    }
                    return .empty;
                }

                // Read from buffer
                const idx = self.read_seq % self.channel.capacity;
                const slot = &self.channel.buffer[idx];

                // Verify sequence matches (slot hasn't been overwritten)
                if (slot.seq != self.read_seq) {
                    // Slot was overwritten - we lagged
                    const missed = self.channel.write_seq - self.read_seq;
                    self.read_seq = self.channel.write_seq;
                    return .{ .lagged = missed };
                }

                const value = slot.value;
                self.read_seq += 1;
                return .{ .value = value };
            }

            /// Receive, potentially waiting if empty.
            /// Returns value if received immediately, null if waiting.
            pub fn recv(self: *Receiver, waiter: *RecvWaiter) ?RecvResult {
                self.channel.mutex.lock();

                // Check if we're lagging
                const oldest_seq = if (self.channel.write_seq > self.channel.capacity)
                    self.channel.write_seq - self.channel.capacity
                else
                    0;

                if (self.read_seq < oldest_seq) {
                    const missed = oldest_seq - self.read_seq;
                    self.read_seq = oldest_seq;
                    self.channel.mutex.unlock();
                    waiter.complete.store(true, .seq_cst);
                    return .{ .lagged = missed };
                }

                // Check if anything to read
                if (self.read_seq >= self.channel.write_seq) {
                    if (self.channel.closed) {
                        self.channel.mutex.unlock();
                        waiter.closed.store(true, .seq_cst);
                        return .closed;
                    }

                    // Wait for sender
                    waiter.complete.store(false, .seq_cst);
                    waiter.closed.store(false, .seq_cst);
                    self.channel.recv_waiters.pushBack(waiter);
                    self.channel.mutex.unlock();
                    return null;
                }

                // Read from buffer
                const idx = self.read_seq % self.channel.capacity;
                const slot = &self.channel.buffer[idx];

                if (slot.seq != self.read_seq) {
                    const missed = self.channel.write_seq - self.read_seq;
                    self.read_seq = self.channel.write_seq;
                    self.channel.mutex.unlock();
                    waiter.complete.store(true, .seq_cst);
                    return .{ .lagged = missed };
                }

                const value = slot.value;
                self.read_seq += 1;
                self.channel.mutex.unlock();
                waiter.complete.store(true, .seq_cst);
                return .{ .value = value };
            }

            /// Cancel pending receive.
            pub fn cancelRecv(self: *Receiver, waiter: *RecvWaiter) void {
                if (waiter.isComplete()) return;

                self.channel.mutex.lock();

                if (waiter.isComplete()) {
                    self.channel.mutex.unlock();
                    return;
                }

                if (RecvWaiterList.isLinked(waiter) or self.channel.recv_waiters.front() == waiter) {
                    self.channel.recv_waiters.remove(waiter);
                    waiter.pointers.reset();
                }

                self.channel.mutex.unlock();
            }

            /// Check if this receiver is lagging.
            pub fn isLagging(self: *const Receiver) bool {
                const oldest_seq = if (self.channel.write_seq > self.channel.capacity)
                    self.channel.write_seq - self.channel.capacity
                else
                    0;
                return self.read_seq < oldest_seq;
            }

            // ═══════════════════════════════════════════════════════════════
            // Blocking API (using unified Waiter)
            // ═══════════════════════════════════════════════════════════════

            /// Blocking receive - blocks until a value is available or channel is closed.
            /// Uses the unified Waiter for proper yielding (task context) or blocking (thread context).
            ///
            /// Returns .value, .lagged, or .closed.
            pub fn recvBlocking(self: *Receiver) RecvResult {
                while (true) {
                    // Fast path
                    const fast_result = self.tryRecv();
                    switch (fast_result) {
                        .value => |v| return .{ .value = v },
                        .lagged => |n| return .{ .lagged = n },
                        .closed => return .closed,
                        .empty => {},
                    }

                    // Slow path: use unified waiter
                    var waiter = RecvWaiter.init();

                    var unified = UnifiedWaiter.init();
                    const WakerBridge = struct {
                        fn wake(ctx: *anyopaque) void {
                            const uw: *UnifiedWaiter = @ptrCast(@alignCast(ctx));
                            uw.notify();
                        }
                    };
                    waiter.setWaker(@ptrCast(&unified), WakerBridge.wake);

                    self.channel.mutex.lock();

                    // Re-check under lock
                    const oldest_seq = if (self.channel.write_seq > self.channel.capacity)
                        self.channel.write_seq - self.channel.capacity
                    else
                        0;

                    if (self.read_seq < oldest_seq) {
                        const missed = oldest_seq - self.read_seq;
                        self.read_seq = oldest_seq;
                        self.channel.mutex.unlock();
                        return .{ .lagged = missed };
                    }

                    if (self.read_seq >= self.channel.write_seq) {
                        if (self.channel.closed) {
                            self.channel.mutex.unlock();
                            return .closed;
                        }

                        // Wait for sender
                        waiter.complete.store(false, .seq_cst);
                        waiter.closed.store(false, .seq_cst);
                        self.channel.recv_waiters.pushBack(&waiter);
                        self.channel.mutex.unlock();

                        // Wait until notified
                        unified.wait();

                        // Check if closed
                        if (waiter.closed.load(.seq_cst)) {
                            return .closed;
                        }

                        // Loop back to try again
                        continue;
                    }

                    // Read from buffer
                    const idx = self.read_seq % self.channel.capacity;
                    const slot = &self.channel.buffer[idx];

                    if (slot.seq != self.read_seq) {
                        const missed = self.channel.write_seq - self.read_seq;
                        self.read_seq = self.channel.write_seq;
                        self.channel.mutex.unlock();
                        return .{ .lagged = missed };
                    }

                    const value = slot.value;
                    self.read_seq += 1;
                    self.channel.mutex.unlock();
                    return .{ .value = value };
                }
            }
        };

        /// Send result
        pub const SendResult = union(enum) {
            /// Number of receivers that will receive this message
            ok: usize,
            /// Channel is closed
            closed,
        };

        /// Create a new broadcast channel.
        pub fn init(allocator: Allocator, capacity: usize) !Self {
            const buffer = try allocator.alloc(Slot, capacity);
            for (buffer) |*slot| {
                slot.seq = 0;
            }

            return .{
                .buffer = buffer,
                .allocator = allocator,
                .capacity = capacity,
                .write_seq = 0,
                .receiver_count = 0,
                .closed = false,
                .mutex = .{},
                .recv_waiters = .{},
            };
        }

        /// Destroy the channel.
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }

        /// Create a new receiver subscribed to this channel.
        pub fn subscribe(self: *Self) Receiver {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.receiver_count += 1;
            return .{
                .channel = self,
                .read_seq = self.write_seq, // Start from current position
            };
        }

        /// Send a value to all receivers.
        pub fn send(self: *Self, value: T) SendResult {
            var wake_list: WakeList(64) = .{};

            self.mutex.lock();

            if (self.closed) {
                self.mutex.unlock();
                return .closed;
            }

            // Write to buffer
            const idx = self.write_seq % self.capacity;
            self.buffer[idx] = .{
                .value = value,
                .seq = self.write_seq,
            };
            self.write_seq += 1;

            const receivers = self.receiver_count;

            // Wake all waiting receivers
            // CRITICAL: Copy waker info BEFORE setting complete flag to avoid use-after-free
            while (self.recv_waiters.popFront()) |w| {
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

            return .{ .ok = receivers };
        }

        /// Close the channel.
        pub fn close(self: *Self) void {
            var wake_list: WakeList(64) = .{};

            self.mutex.lock();

            if (self.closed) {
                self.mutex.unlock();
                return;
            }

            self.closed = true;

            // CRITICAL: Copy waker info BEFORE setting closed flag to avoid use-after-free
            while (self.recv_waiters.popFront()) |w| {
                const waker_fn = w.waker;
                const waker_ctx = w.waker_ctx;
                w.closed.store(true, .seq_cst);
                if (waker_fn) |wf| {
                    if (waker_ctx) |ctx| {
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

        /// Get receiver count.
        pub fn receiverCount(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.receiver_count;
        }
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "BroadcastChannel - single receiver" {
    var ch = try BroadcastChannel(u32).init(std.testing.allocator, 4);
    defer ch.deinit();

    var rx = ch.subscribe();

    _ = ch.send(1);
    _ = ch.send(2);

    try std.testing.expectEqual(BroadcastChannel(u32).Receiver.RecvResult{ .value = 1 }, rx.tryRecv());
    try std.testing.expectEqual(BroadcastChannel(u32).Receiver.RecvResult{ .value = 2 }, rx.tryRecv());
    try std.testing.expect(rx.tryRecv() == .empty);
}

test "BroadcastChannel - multiple receivers" {
    var ch = try BroadcastChannel(u32).init(std.testing.allocator, 4);
    defer ch.deinit();

    var rx1 = ch.subscribe();
    var rx2 = ch.subscribe();

    _ = ch.send(42);

    // Both receivers get the same value
    try std.testing.expectEqual(BroadcastChannel(u32).Receiver.RecvResult{ .value = 42 }, rx1.tryRecv());
    try std.testing.expectEqual(BroadcastChannel(u32).Receiver.RecvResult{ .value = 42 }, rx2.tryRecv());
}

test "BroadcastChannel - lagging receiver" {
    var ch = try BroadcastChannel(u32).init(std.testing.allocator, 2);
    defer ch.deinit();

    var rx = ch.subscribe();

    // Fill and overflow buffer
    _ = ch.send(1);
    _ = ch.send(2);
    _ = ch.send(3); // Overwrites slot 0
    _ = ch.send(4); // Overwrites slot 1

    // Receiver should detect lag
    const result = rx.tryRecv();
    switch (result) {
        .lagged => |missed| try std.testing.expect(missed >= 2),
        else => try std.testing.expect(false),
    }
}

test "BroadcastChannel - new subscriber starts at current" {
    var ch = try BroadcastChannel(u32).init(std.testing.allocator, 4);
    defer ch.deinit();

    _ = ch.send(1);
    _ = ch.send(2);

    // New subscriber doesn't see old messages
    var rx = ch.subscribe();
    try std.testing.expect(rx.tryRecv() == .empty);

    // But sees new ones
    _ = ch.send(3);
    try std.testing.expectEqual(BroadcastChannel(u32).Receiver.RecvResult{ .value = 3 }, rx.tryRecv());
}

test "BroadcastChannel - close wakes waiters" {
    var ch = try BroadcastChannel(u32).init(std.testing.allocator, 4);
    defer ch.deinit();
    var woken = false;

    const TestWaker = struct {
        fn wake(ctx: *anyopaque) void {
            const w: *bool = @ptrCast(@alignCast(ctx));
            w.* = true;
        }
    };

    var rx = ch.subscribe();
    var waiter = RecvWaiter.init();
    waiter.setWaker(@ptrCast(&woken), TestWaker.wake);

    _ = rx.recv(&waiter);

    ch.close();

    try std.testing.expect(woken);
    try std.testing.expect(waiter.closed.load(.acquire));
}

test "BroadcastChannel - send returns receiver count" {
    var ch = try BroadcastChannel(u32).init(std.testing.allocator, 4);
    defer ch.deinit();

    _ = ch.subscribe();
    _ = ch.subscribe();

    const result = ch.send(42);
    switch (result) {
        .ok => |count| try std.testing.expectEqual(@as(usize, 2), count),
        .closed => try std.testing.expect(false),
    }
}
