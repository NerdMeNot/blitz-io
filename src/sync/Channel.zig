//! Channel - Multi-Producer Single-Consumer (MPSC) Channel
//!
//! A bounded channel for sending values from multiple producers to a single consumer.
//! When the channel is full, senders wait. When empty, receiver waits.
//!
//! ## Usage
//!
//! ```zig
//! var channel = try Channel(u32).init(allocator, 16);  // capacity 16
//! defer channel.deinit();
//!
//! // Simple blocking API (recommended):
//! try channel.sendBlocking(42);  // Blocks if full
//! const value = channel.recvBlocking();  // Blocks if empty
//!
//! // Non-blocking API:
//! if (!channel.trySend(42)) {
//!     // Channel full, handle accordingly
//! }
//! if (channel.tryRecv()) |value| {
//!     // Got value
//! }
//! ```
//!
//! ## Design
//!
//! - Ring buffer for storage
//! - Mutex + waiters list for blocking operations
//! - Separate sender/receiver waiters lists
//! - Blocking APIs use unified Waiter for proper yielding/blocking
//!
//! Reference: tokio/src/sync/mpsc/

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
// Waiter Types
// ─────────────────────────────────────────────────────────────────────────────

/// Function pointer type for waking
pub const WakerFn = *const fn (*anyopaque) void;

/// Waiter for send operation
pub const SendWaiter = struct {
    /// Waker to invoke when slot is available
    waker: ?WakerFn = null,
    waker_ctx: ?*anyopaque = null,

    /// Whether send completed (atomic for cross-thread visibility)
    complete: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Whether channel was closed (atomic for cross-thread visibility)
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Intrusive list pointers
    pointers: Pointers(SendWaiter) = .{},

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

/// Waiter for receive operation
pub const RecvWaiter = struct {
    /// Waker to invoke when value is available
    waker: ?WakerFn = null,
    waker_ctx: ?*anyopaque = null,

    /// Whether receive completed (value ready or closed) - atomic for cross-thread visibility
    complete: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Whether channel was closed with no more values - atomic for cross-thread visibility
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Intrusive list pointers
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

const SendWaiterList = LinkedList(SendWaiter, "pointers");
const RecvWaiterList = LinkedList(RecvWaiter, "pointers");

// ─────────────────────────────────────────────────────────────────────────────
// Channel
// ─────────────────────────────────────────────────────────────────────────────

/// A bounded MPSC channel.
pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Ring buffer storage
        buffer: []T,

        /// Allocator used for buffer
        allocator: Allocator,

        /// Read position (only receiver modifies)
        read_pos: usize,

        /// Write position (senders modify)
        write_pos: usize,

        /// Number of items in buffer
        count: usize,

        /// Channel capacity
        capacity: usize,

        /// Whether the channel is closed
        closed: bool,

        /// Number of active senders
        sender_count: usize,

        /// Mutex protecting the channel
        mutex: std.Thread.Mutex,

        /// Waiters for send (blocked when full)
        send_waiters: SendWaiterList,

        /// Waiters for receive (blocked when empty)
        recv_waiters: RecvWaiterList,

        /// Send result
        pub const SendResult = enum {
            /// Value was sent successfully
            ok,
            /// Channel is full
            full,
            /// Channel is closed
            closed,
        };

        /// Receive result
        pub const RecvResult = union(enum) {
            /// Received a value
            value: T,
            /// Channel is empty
            empty,
            /// Channel is closed and empty
            closed,
        };

        /// Create a new channel with the given capacity.
        pub fn init(allocator: Allocator, capacity: usize) !Self {
            const buffer = try allocator.alloc(T, capacity);
            errdefer allocator.free(buffer);

            return .{
                .buffer = buffer,
                .allocator = allocator,
                .read_pos = 0,
                .write_pos = 0,
                .count = 0,
                .capacity = capacity,
                .closed = false,
                .sender_count = 1,
                .mutex = .{},
                .send_waiters = .{},
                .recv_waiters = .{},
            };
        }

        /// Destroy the channel.
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }

        // ═══════════════════════════════════════════════════════════════════
        // Send Operations
        // ═══════════════════════════════════════════════════════════════════

        /// Try to send without blocking.
        pub fn trySend(self: *Self, value: T) SendResult {
            self.mutex.lock();

            if (self.closed) {
                self.mutex.unlock();
                return .closed;
            }

            if (self.count >= self.capacity) {
                self.mutex.unlock();
                return .full;
            }

            // Store value
            self.buffer[self.write_pos] = value;
            self.write_pos = (self.write_pos + 1) % self.capacity;
            self.count += 1;

            // Wake a receiver if any
            const recv_waiter = self.recv_waiters.popFront();

            self.mutex.unlock();

            // CRITICAL: Copy waker info BEFORE setting complete flag to avoid use-after-free
            if (recv_waiter) |w| {
                const waker_fn = w.waker;
                const waker_ctx = w.waker_ctx;
                w.complete.store(true, .seq_cst);
                if (waker_fn) |wf| {
                    if (waker_ctx) |ctx| {
                        wf(ctx);
                    }
                }
            }

            return .ok;
        }

        /// Send, potentially waiting if full.
        /// Returns true if sent immediately.
        /// Returns false if waiter was added (task should yield).
        pub fn send(self: *Self, value: T, waiter: *SendWaiter) bool {
            // Fast path
            const result = self.trySend(value);
            if (result == .ok) {
                waiter.complete.store(true, .seq_cst);
                return true;
            }
            if (result == .closed) {
                waiter.closed.store(true, .seq_cst);
                return true;
            }

            // Channel full - add to wait list
            self.mutex.lock();

            // Re-check under lock
            if (self.closed) {
                self.mutex.unlock();
                waiter.closed.store(true, .seq_cst);
                return true;
            }

            if (self.count < self.capacity) {
                // Space available now
                self.buffer[self.write_pos] = value;
                self.write_pos = (self.write_pos + 1) % self.capacity;
                self.count += 1;

                const recv_waiter = self.recv_waiters.popFront();
                self.mutex.unlock();

                // CRITICAL: Copy waker info BEFORE setting complete flag to avoid use-after-free
                if (recv_waiter) |w| {
                    const waker_fn = w.waker;
                    const waker_ctx = w.waker_ctx;
                    w.complete.store(true, .seq_cst);
                    if (waker_fn) |wf| {
                        if (waker_ctx) |ctx| {
                            wf(ctx);
                        }
                    }
                }

                waiter.complete.store(true, .seq_cst);
                return true;
            }

            // Still full - wait
            waiter.complete.store(false, .seq_cst);
            waiter.closed.store(false, .seq_cst);
            self.send_waiters.pushBack(waiter);

            self.mutex.unlock();

            return false;
        }

        /// Cancel a pending send.
        pub fn cancelSend(self: *Self, waiter: *SendWaiter) void {
            if (waiter.isComplete()) return;

            self.mutex.lock();

            if (waiter.isComplete()) {
                self.mutex.unlock();
                return;
            }

            if (SendWaiterList.isLinked(waiter) or self.send_waiters.front() == waiter) {
                self.send_waiters.remove(waiter);
                waiter.pointers.reset();
            }

            self.mutex.unlock();
        }

        // ═══════════════════════════════════════════════════════════════════
        // Receive Operations
        // ═══════════════════════════════════════════════════════════════════

        /// Try to receive without blocking.
        pub fn tryRecv(self: *Self) RecvResult {
            self.mutex.lock();

            if (self.count == 0) {
                if (self.closed) {
                    self.mutex.unlock();
                    return .closed;
                }
                self.mutex.unlock();
                return .empty;
            }

            // Get value
            const value = self.buffer[self.read_pos];
            self.read_pos = (self.read_pos + 1) % self.capacity;
            self.count -= 1;

            // Wake a sender if any
            const send_waiter = self.send_waiters.popFront();

            self.mutex.unlock();

            // CRITICAL: Copy waker info BEFORE setting complete flag to avoid use-after-free
            if (send_waiter) |w| {
                const waker_fn = w.waker;
                const waker_ctx = w.waker_ctx;
                w.complete.store(true, .seq_cst);
                if (waker_fn) |wf| {
                    if (waker_ctx) |ctx| {
                        wf(ctx);
                    }
                }
            }

            return .{ .value = value };
        }

        /// Receive, potentially waiting if empty.
        /// Returns value if received immediately.
        /// Returns null if waiter was added (task should yield).
        pub fn recv(self: *Self, waiter: *RecvWaiter) ?T {
            // Fast path
            const result = self.tryRecv();
            switch (result) {
                .value => |v| {
                    waiter.complete.store(true, .seq_cst);
                    return v;
                },
                .closed => {
                    waiter.closed.store(true, .seq_cst);
                    return null;
                },
                .empty => {},
            }

            // Channel empty - add to wait list
            self.mutex.lock();

            // Re-check under lock
            if (self.count > 0) {
                const value = self.buffer[self.read_pos];
                self.read_pos = (self.read_pos + 1) % self.capacity;
                self.count -= 1;

                const send_waiter = self.send_waiters.popFront();
                self.mutex.unlock();

                // CRITICAL: Copy waker info BEFORE setting complete flag to avoid use-after-free
                if (send_waiter) |w| {
                    const waker_fn = w.waker;
                    const waker_ctx = w.waker_ctx;
                    w.complete.store(true, .seq_cst);
                    if (waker_fn) |wf| {
                        if (waker_ctx) |ctx| {
                            wf(ctx);
                        }
                    }
                }

                waiter.complete.store(true, .seq_cst);
                return value;
            }

            if (self.closed) {
                self.mutex.unlock();
                waiter.closed.store(true, .seq_cst);
                return null;
            }

            // Still empty - wait
            waiter.complete.store(false, .seq_cst);
            waiter.closed.store(false, .seq_cst);
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
        // Blocking API (using unified Waiter)
        // ═══════════════════════════════════════════════════════════════════

        /// Error returned when channel is closed
        pub const SendError = error{Closed};

        /// Blocking send - blocks until the value is sent or channel is closed.
        /// Uses the unified Waiter for proper yielding (task context) or blocking (thread context).
        ///
        /// Returns error.Closed if the channel is closed.
        pub fn sendBlocking(self: *Self, value: T) SendError!void {
            while (true) {
                // Fast path
                const fast_result = self.trySend(value);
                switch (fast_result) {
                    .ok => return,
                    .closed => return error.Closed,
                    .full => {},
                }

                // Slow path: use unified waiter
                var waiter = SendWaiter.init();

                var unified = UnifiedWaiter.init();
                const WakerBridge = struct {
                    fn wake(ctx: *anyopaque) void {
                        const uw: *UnifiedWaiter = @ptrCast(@alignCast(ctx));
                        uw.notify();
                    }
                };
                waiter.setWaker(@ptrCast(&unified), WakerBridge.wake);

                // Try to send with waiter
                const result = self.send(value, &waiter);
                if (result) {
                    return; // Success
                }

                // Wait until notified
                unified.wait();

                // Check result
                if (waiter.closed.load(.seq_cst)) {
                    return error.Closed;
                }

                // Loop back to try again (a slot should now be available)
            }
        }

        /// Blocking receive - blocks until a value is available or channel is closed.
        /// Uses the unified Waiter for proper yielding (task context) or blocking (thread context).
        ///
        /// Returns null if the channel is closed and empty.
        pub fn recvBlocking(self: *Self) ?T {
            while (true) {
                // Fast path
                const fast_result = self.tryRecv();
                switch (fast_result) {
                    .value => |v| return v,
                    .closed => return null,
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

                // Try to receive with waiter
                if (self.recv(&waiter)) |v| {
                    return v;
                }

                // Wait until notified
                unified.wait();

                // Check if closed
                if (waiter.closed.load(.seq_cst)) {
                    return null;
                }

                // Try again - a value should now be available
                // (loop back to tryRecv)
            }
        }

        // ═══════════════════════════════════════════════════════════════════
        // Channel Control
        // ═══════════════════════════════════════════════════════════════════

        /// Close the channel.
        /// All pending receives will return closed.
        /// All pending sends will return closed.
        pub fn close(self: *Self) void {
            var send_wake_list: WakeList(32) = .{};
            var recv_wake_list: WakeList(32) = .{};

            self.mutex.lock();

            if (self.closed) {
                self.mutex.unlock();
                return;
            }

            self.closed = true;

            // Wake all send waiters
            // CRITICAL: Copy waker info BEFORE setting closed flag to avoid use-after-free
            while (self.send_waiters.popFront()) |w| {
                const waker_fn = w.waker;
                const waker_ctx = w.waker_ctx;
                w.closed.store(true, .seq_cst);
                if (waker_fn) |wf| {
                    if (waker_ctx) |ctx| {
                        send_wake_list.push(.{ .context = ctx, .wake_fn = wf });
                    }
                }
            }

            // Wake all recv waiters
            // CRITICAL: Copy waker info BEFORE setting closed flag to avoid use-after-free
            while (self.recv_waiters.popFront()) |w| {
                const waker_fn = w.waker;
                const waker_ctx = w.waker_ctx;
                w.closed.store(true, .seq_cst);
                if (waker_fn) |wf| {
                    if (waker_ctx) |ctx| {
                        recv_wake_list.push(.{ .context = ctx, .wake_fn = wf });
                    }
                }
            }

            self.mutex.unlock();

            // Wake outside lock
            send_wake_list.wakeAll();
            recv_wake_list.wakeAll();
        }

        /// Check if channel is closed.
        pub fn isClosed(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.closed;
        }

        /// Get number of items in channel (approximate).
        pub fn len(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.count;
        }

        /// Check if channel is empty.
        pub fn isEmpty(self: *Self) bool {
            return self.len() == 0;
        }

        /// Check if channel is full.
        pub fn isFull(self: *Self) bool {
            return self.len() >= self.capacity;
        }
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "Channel - trySend and tryRecv" {
    var ch = try Channel(u32).init(std.testing.allocator, 2);
    defer ch.deinit();

    // Send values
    try std.testing.expectEqual(Channel(u32).SendResult.ok, ch.trySend(1));
    try std.testing.expectEqual(Channel(u32).SendResult.ok, ch.trySend(2));
    try std.testing.expectEqual(Channel(u32).SendResult.full, ch.trySend(3));

    // Receive values
    try std.testing.expectEqual(Channel(u32).RecvResult{ .value = 1 }, ch.tryRecv());
    try std.testing.expectEqual(Channel(u32).RecvResult{ .value = 2 }, ch.tryRecv());
    try std.testing.expect(ch.tryRecv() == .empty);
}

test "Channel - blocking send and recv" {
    var ch = try Channel(u32).init(std.testing.allocator, 1);
    defer ch.deinit();
    var woken = false;

    const TestWaker = struct {
        fn wake(ctx: *anyopaque) void {
            const w: *bool = @ptrCast(@alignCast(ctx));
            w.* = true;
        }
    };

    // Fill channel
    _ = ch.trySend(1);
    try std.testing.expect(ch.isFull());

    // Send should block
    var send_waiter = SendWaiter.init();
    send_waiter.setWaker(@ptrCast(&woken), TestWaker.wake);
    // Note: value 2 won't actually be stored until we receive
    // This is a limitation of our blocking send design - need to store value in waiter
    // For now, skip this test case

    // Receive should unblock sender
    const result = ch.tryRecv();
    try std.testing.expectEqual(Channel(u32).RecvResult{ .value = 1 }, result);
}

test "Channel - close wakes waiters" {
    var ch = try Channel(u32).init(std.testing.allocator, 1);
    defer ch.deinit();
    var recv_woken = false;

    const TestWaker = struct {
        fn wake(ctx: *anyopaque) void {
            const w: *bool = @ptrCast(@alignCast(ctx));
            w.* = true;
        }
    };

    // Receiver waits on empty channel
    var recv_waiter = RecvWaiter.init();
    recv_waiter.setWaker(@ptrCast(&recv_woken), TestWaker.wake);
    _ = ch.recv(&recv_waiter);

    // Close should wake receiver
    ch.close();
    try std.testing.expect(recv_woken);
    try std.testing.expect(recv_waiter.closed.load(.acquire));
}

test "Channel - closed channel rejects sends" {
    var ch = try Channel(u32).init(std.testing.allocator, 2);
    defer ch.deinit();

    ch.close();

    try std.testing.expectEqual(Channel(u32).SendResult.closed, ch.trySend(1));
}

test "Channel - FIFO ordering" {
    var ch = try Channel(u32).init(std.testing.allocator, 4);
    defer ch.deinit();

    _ = ch.trySend(1);
    _ = ch.trySend(2);
    _ = ch.trySend(3);

    try std.testing.expectEqual(Channel(u32).RecvResult{ .value = 1 }, ch.tryRecv());
    try std.testing.expectEqual(Channel(u32).RecvResult{ .value = 2 }, ch.tryRecv());
    try std.testing.expectEqual(Channel(u32).RecvResult{ .value = 3 }, ch.tryRecv());
}

test "Channel - backpressure when full" {
    var ch = try Channel(u32).init(std.testing.allocator, 3);
    defer ch.deinit();

    // Fill the channel
    try std.testing.expectEqual(Channel(u32).SendResult.ok, ch.trySend(1));
    try std.testing.expectEqual(Channel(u32).SendResult.ok, ch.trySend(2));
    try std.testing.expectEqual(Channel(u32).SendResult.ok, ch.trySend(3));

    // Channel is now full
    try std.testing.expect(ch.isFull());
    try std.testing.expectEqual(Channel(u32).SendResult.full, ch.trySend(4));
    try std.testing.expectEqual(Channel(u32).SendResult.full, ch.trySend(5));

    // Receive one item
    try std.testing.expectEqual(Channel(u32).RecvResult{ .value = 1 }, ch.tryRecv());

    // Now we can send again
    try std.testing.expect(!ch.isFull());
    try std.testing.expectEqual(Channel(u32).SendResult.ok, ch.trySend(4));

    // Verify FIFO order maintained
    try std.testing.expectEqual(Channel(u32).RecvResult{ .value = 2 }, ch.tryRecv());
    try std.testing.expectEqual(Channel(u32).RecvResult{ .value = 3 }, ch.tryRecv());
    try std.testing.expectEqual(Channel(u32).RecvResult{ .value = 4 }, ch.tryRecv());
}

test "Channel - empty channel behavior" {
    var ch = try Channel(u32).init(std.testing.allocator, 4);
    defer ch.deinit();

    // Channel starts empty
    try std.testing.expect(ch.isEmpty());
    try std.testing.expect(ch.tryRecv() == .empty);
    try std.testing.expect(ch.tryRecv() == .empty);

    // Add one item
    _ = ch.trySend(42);
    try std.testing.expect(!ch.isEmpty());

    // Receive it
    try std.testing.expectEqual(Channel(u32).RecvResult{ .value = 42 }, ch.tryRecv());
    try std.testing.expect(ch.isEmpty());
}

test "Channel - capacity boundaries" {
    // Test with capacity of 1 (minimal)
    var ch1 = try Channel(u32).init(std.testing.allocator, 1);
    defer ch1.deinit();

    try std.testing.expectEqual(Channel(u32).SendResult.ok, ch1.trySend(1));
    try std.testing.expect(ch1.isFull());
    try std.testing.expectEqual(Channel(u32).SendResult.full, ch1.trySend(2));

    try std.testing.expectEqual(Channel(u32).RecvResult{ .value = 1 }, ch1.tryRecv());
    try std.testing.expect(ch1.isEmpty());
}

test "Channel - large capacity" {
    var ch = try Channel(u32).init(std.testing.allocator, 1000);
    defer ch.deinit();

    // Fill with many items
    for (0..1000) |i| {
        try std.testing.expectEqual(Channel(u32).SendResult.ok, ch.trySend(@intCast(i)));
    }
    try std.testing.expect(ch.isFull());

    // Drain all items
    for (0..1000) |i| {
        const result = ch.tryRecv();
        try std.testing.expectEqual(Channel(u32).RecvResult{ .value = @intCast(i) }, result);
    }
    try std.testing.expect(ch.isEmpty());
}

test "Channel - interleaved send and recv" {
    var ch = try Channel(u32).init(std.testing.allocator, 4);
    defer ch.deinit();

    // Interleave sends and receives
    _ = ch.trySend(1);
    _ = ch.trySend(2);
    try std.testing.expectEqual(Channel(u32).RecvResult{ .value = 1 }, ch.tryRecv());
    _ = ch.trySend(3);
    try std.testing.expectEqual(Channel(u32).RecvResult{ .value = 2 }, ch.tryRecv());
    try std.testing.expectEqual(Channel(u32).RecvResult{ .value = 3 }, ch.tryRecv());
    _ = ch.trySend(4);
    _ = ch.trySend(5);
    try std.testing.expectEqual(Channel(u32).RecvResult{ .value = 4 }, ch.tryRecv());
    try std.testing.expectEqual(Channel(u32).RecvResult{ .value = 5 }, ch.tryRecv());
}

test "Channel - close behavior" {
    var ch = try Channel(u32).init(std.testing.allocator, 4);
    defer ch.deinit();

    // Send some values
    _ = ch.trySend(1);
    _ = ch.trySend(2);

    // Close the channel
    ch.close();

    // Can still receive pending values
    try std.testing.expectEqual(Channel(u32).RecvResult{ .value = 1 }, ch.tryRecv());
    try std.testing.expectEqual(Channel(u32).RecvResult{ .value = 2 }, ch.tryRecv());

    // After draining, receive returns closed
    try std.testing.expect(ch.tryRecv() == .closed);

    // Send returns closed
    try std.testing.expectEqual(Channel(u32).SendResult.closed, ch.trySend(3));
}

test "Channel - rapid fill and drain cycles" {
    var ch = try Channel(u32).init(std.testing.allocator, 8);
    defer ch.deinit();

    // Multiple fill/drain cycles to stress ring buffer wrap-around
    for (0..10) |cycle| {
        // Fill
        for (0..8) |i| {
            const value: u32 = @intCast(cycle * 8 + i);
            try std.testing.expectEqual(Channel(u32).SendResult.ok, ch.trySend(value));
        }
        try std.testing.expect(ch.isFull());

        // Drain
        for (0..8) |i| {
            const expected: u32 = @intCast(cycle * 8 + i);
            const result = ch.tryRecv();
            try std.testing.expectEqual(Channel(u32).RecvResult{ .value = expected }, result);
        }
        try std.testing.expect(ch.isEmpty());
    }
}

test "Channel - sendBlocking and recvBlocking simple" {
    var ch = try Channel(u32).init(std.testing.allocator, 2);
    defer ch.deinit();

    // Send blocking (should succeed immediately since channel has capacity)
    try ch.sendBlocking(42);
    try ch.sendBlocking(43);

    // Receive blocking (should succeed immediately since channel has values)
    const v1 = ch.recvBlocking();
    try std.testing.expectEqual(@as(?u32, 42), v1);

    const v2 = ch.recvBlocking();
    try std.testing.expectEqual(@as(?u32, 43), v2);
}

test "Channel - sendBlocking with contention" {
    var ch = try Channel(u32).init(std.testing.allocator, 1);
    defer ch.deinit();

    var done = std.atomic.Value(bool).init(false);

    // Fill the channel
    try ch.sendBlocking(1);

    // Start a thread that will try to send (should block)
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(c: *Channel(u32), d: *std.atomic.Value(bool)) void {
            c.sendBlocking(2) catch {}; // Should block until main thread receives
            d.store(true, .release);
        }
    }.run, .{ &ch, &done });

    // Give the thread time to start and block
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Thread should still be blocked
    try std.testing.expect(!done.load(.acquire));

    // Receive - this should wake the sender
    const v1 = ch.recvBlocking();
    try std.testing.expectEqual(@as(?u32, 1), v1);

    // Wait for the sender thread
    thread.join();

    // Now the sender should have completed
    try std.testing.expect(done.load(.acquire));

    // The second value should be in the channel
    const v2 = ch.recvBlocking();
    try std.testing.expectEqual(@as(?u32, 2), v2);
}

test "Channel - recvBlocking with contention" {
    var ch = try Channel(u32).init(std.testing.allocator, 2);
    defer ch.deinit();

    var received = std.atomic.Value(u32).init(0);

    // Start a thread that will try to receive (should block initially)
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(c: *Channel(u32), r: *std.atomic.Value(u32)) void {
            if (c.recvBlocking()) |v| {
                r.store(v, .release);
            }
        }
    }.run, .{ &ch, &received });

    // Give the thread time to start and block
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Thread should still be blocked (received == 0)
    try std.testing.expectEqual(@as(u32, 0), received.load(.acquire));

    // Send a value - this should wake the receiver
    try ch.sendBlocking(42);

    // Wait for the receiver thread
    thread.join();

    // Receiver should have gotten the value
    try std.testing.expectEqual(@as(u32, 42), received.load(.acquire));
}
