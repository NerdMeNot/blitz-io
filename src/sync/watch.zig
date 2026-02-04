//! Watch Channel - Single Value with Change Notification
//!
//! A watch channel holds a single value. The sender can update the value,
//! and multiple receivers can watch for changes. Only the latest value is kept.
//!
//! ## Usage
//!
//! ```zig
//! var watch = Watch(Config).init(default_config);
//! defer watch.deinit();
//!
//! // Sender updates value
//! watch.send(new_config);
//!
//! // Receivers watch for changes
//! var rx = watch.subscribe();
//! if (rx.hasChanged()) {
//!     const config = rx.borrow();
//!     // Use config
//!     rx.markSeen();
//! }
//! ```
//!
//! ## Design
//!
//! - Single value storage with version number
//! - Receivers track last seen version
//! - No history - only latest value kept
//! - Good for configuration/state broadcasting
//!
//! Reference: tokio/src/sync/watch.rs

const std = @import("std");
const builtin = @import("builtin");

const LinkedList = @import("../util/linked_list.zig").LinkedList;
const Pointers = @import("../util/linked_list.zig").Pointers;
const WakeList = @import("../util/wake_list.zig").WakeList;

// ─────────────────────────────────────────────────────────────────────────────
// Waiter
// ─────────────────────────────────────────────────────────────────────────────

/// Function pointer type for waking
pub const WakerFn = *const fn (*anyopaque) void;

/// Waiter for change notification
pub const ChangeWaiter = struct {
    waker: ?WakerFn = null,
    waker_ctx: ?*anyopaque = null,
    notified: bool = false,
    closed: bool = false,
    pointers: Pointers(ChangeWaiter) = .{},

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
        return self.notified or self.closed;
    }

    pub fn reset(self: *Self) void {
        self.notified = false;
        self.closed = false;
        self.waker = null;
        self.waker_ctx = null;
        self.pointers.reset();
    }
};

const ChangeWaiterList = LinkedList(ChangeWaiter, "pointers");

// ─────────────────────────────────────────────────────────────────────────────
// Watch
// ─────────────────────────────────────────────────────────────────────────────

/// A watch channel for a single value.
pub fn Watch(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Current value
        value: T,

        /// Version number (increments on each update)
        version: u64,

        /// Number of receivers
        receiver_count: usize,

        /// Whether the sender is closed
        closed: bool,

        /// Mutex protecting internal state
        mutex: std.Thread.Mutex,

        /// Waiters for change notification
        waiters: ChangeWaiterList,

        /// Receiver handle
        pub const Receiver = struct {
            watch: *Self,
            /// Last seen version
            seen_version: u64,

            /// Check if value has changed since last seen.
            pub fn hasChanged(self: *const Receiver) bool {
                self.watch.mutex.lock();
                defer self.watch.mutex.unlock();
                return self.seen_version < self.watch.version;
            }

            /// Borrow the current value (read-only reference).
            pub fn borrow(self: *const Receiver) *const T {
                return &self.watch.value;
            }

            /// Get a copy of the current value.
            pub fn get(self: *const Receiver) T {
                self.watch.mutex.lock();
                defer self.watch.mutex.unlock();
                return self.watch.value;
            }

            /// Get the current value and mark as seen.
            pub fn getAndUpdate(self: *Receiver) T {
                self.watch.mutex.lock();
                defer self.watch.mutex.unlock();
                self.seen_version = self.watch.version;
                return self.watch.value;
            }

            /// Mark current value as seen.
            pub fn markSeen(self: *Receiver) void {
                self.watch.mutex.lock();
                defer self.watch.mutex.unlock();
                self.seen_version = self.watch.version;
            }

            /// Wait for a change.
            /// Returns true if change detected immediately.
            /// Returns false if waiting (task should yield).
            pub fn changed(self: *Receiver, waiter: *ChangeWaiter) bool {
                self.watch.mutex.lock();

                // Check if already changed
                if (self.seen_version < self.watch.version) {
                    self.watch.mutex.unlock();
                    waiter.notified = true;
                    return true;
                }

                // Check if closed
                if (self.watch.closed) {
                    self.watch.mutex.unlock();
                    waiter.closed = true;
                    return true;
                }

                // Wait for change
                waiter.notified = false;
                waiter.closed = false;
                self.watch.waiters.pushBack(waiter);

                self.watch.mutex.unlock();
                return false;
            }

            /// Cancel pending wait.
            pub fn cancelChanged(self: *Receiver, waiter: *ChangeWaiter) void {
                if (waiter.isComplete()) return;

                self.watch.mutex.lock();

                if (waiter.isComplete()) {
                    self.watch.mutex.unlock();
                    return;
                }

                if (ChangeWaiterList.isLinked(waiter) or self.watch.waiters.front() == waiter) {
                    self.watch.waiters.remove(waiter);
                    waiter.pointers.reset();
                }

                self.watch.mutex.unlock();
            }

            /// Check if sender is closed.
            pub fn isClosed(self: *const Receiver) bool {
                self.watch.mutex.lock();
                defer self.watch.mutex.unlock();
                return self.watch.closed;
            }
        };

        /// Create a new watch channel with initial value.
        pub fn init(initial: T) Self {
            return .{
                .value = initial,
                .version = 1, // Start at 1 so receivers can detect initial value
                .receiver_count = 0,
                .closed = false,
                .mutex = .{},
                .waiters = .{},
            };
        }

        /// No cleanup needed (no allocations).
        pub fn deinit(self: *Self) void {
            _ = self;
        }

        /// Subscribe to changes.
        pub fn subscribe(self: *Self) Receiver {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.receiver_count += 1;
            return .{
                .watch = self,
                .seen_version = 0, // Will see initial value as "changed"
            };
        }

        /// Subscribe but mark current value as already seen.
        pub fn subscribeNoInitial(self: *Self) Receiver {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.receiver_count += 1;
            return .{
                .watch = self,
                .seen_version = self.version,
            };
        }

        /// Send a new value, waking all waiters.
        pub fn send(self: *Self, value: T) void {
            var wake_list: WakeList(64) = .{};

            self.mutex.lock();

            self.value = value;
            self.version +%= 1;

            // Wake all waiters
            while (self.waiters.popFront()) |w| {
                w.notified = true;
                if (w.waker) |wf| {
                    if (w.waker_ctx) |ctx| {
                        wake_list.push(.{ .context = ctx, .wake_fn = wf });
                    }
                }
            }

            self.mutex.unlock();

            wake_list.wakeAll();
        }

        /// Modify the value in place.
        pub fn sendModify(self: *Self, modify_fn: *const fn (*T) void) void {
            var wake_list: WakeList(64) = .{};

            self.mutex.lock();

            modify_fn(&self.value);
            self.version +%= 1;

            while (self.waiters.popFront()) |w| {
                w.notified = true;
                if (w.waker) |wf| {
                    if (w.waker_ctx) |ctx| {
                        wake_list.push(.{ .context = ctx, .wake_fn = wf });
                    }
                }
            }

            self.mutex.unlock();

            wake_list.wakeAll();
        }

        /// Borrow current value (read-only).
        pub fn borrow(self: *const Self) *const T {
            return &self.value;
        }

        /// Close the sender, waking all waiters.
        pub fn close(self: *Self) void {
            var wake_list: WakeList(64) = .{};

            self.mutex.lock();

            if (self.closed) {
                self.mutex.unlock();
                return;
            }

            self.closed = true;

            while (self.waiters.popFront()) |w| {
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

test "Watch - initial value" {
    var watch = Watch(u32).init(42);
    defer watch.deinit();

    var rx = watch.subscribe();

    // New subscriber sees initial value as changed
    try std.testing.expect(rx.hasChanged());
    try std.testing.expectEqual(@as(u32, 42), rx.get());

    rx.markSeen();
    try std.testing.expect(!rx.hasChanged());
}

test "Watch - send updates value" {
    var watch = Watch(u32).init(1);
    defer watch.deinit();

    var rx = watch.subscribe();
    rx.markSeen();

    try std.testing.expect(!rx.hasChanged());

    watch.send(2);

    try std.testing.expect(rx.hasChanged());
    try std.testing.expectEqual(@as(u32, 2), rx.getAndUpdate());
    try std.testing.expect(!rx.hasChanged());
}

test "Watch - multiple receivers" {
    var watch = Watch(u32).init(0);
    defer watch.deinit();

    var rx1 = watch.subscribe();
    var rx2 = watch.subscribe();
    rx1.markSeen();
    rx2.markSeen();

    watch.send(100);

    // Both see the change
    try std.testing.expect(rx1.hasChanged());
    try std.testing.expect(rx2.hasChanged());
    try std.testing.expectEqual(@as(u32, 100), rx1.get());
    try std.testing.expectEqual(@as(u32, 100), rx2.get());
}

test "Watch - wait for change" {
    var watch = Watch(u32).init(0);
    defer watch.deinit();
    var woken = false;

    const TestWaker = struct {
        fn wake(ctx: *anyopaque) void {
            const w: *bool = @ptrCast(@alignCast(ctx));
            w.* = true;
        }
    };

    var rx = watch.subscribe();
    rx.markSeen();

    var waiter = ChangeWaiter.init();
    waiter.setWaker(@ptrCast(&woken), TestWaker.wake);

    // Should wait (no change yet)
    const immediate = rx.changed(&waiter);
    try std.testing.expect(!immediate);

    // Send wakes waiter
    watch.send(42);
    try std.testing.expect(woken);
    try std.testing.expect(waiter.notified);
}

test "Watch - close wakes waiters" {
    var watch = Watch(u32).init(0);
    defer watch.deinit();
    var woken = false;

    const TestWaker = struct {
        fn wake(ctx: *anyopaque) void {
            const w: *bool = @ptrCast(@alignCast(ctx));
            w.* = true;
        }
    };

    var rx = watch.subscribe();
    rx.markSeen();

    var waiter = ChangeWaiter.init();
    waiter.setWaker(@ptrCast(&woken), TestWaker.wake);
    _ = rx.changed(&waiter);

    watch.close();

    try std.testing.expect(woken);
    try std.testing.expect(waiter.closed);
    try std.testing.expect(rx.isClosed());
}

test "Watch - subscribeNoInitial" {
    var watch = Watch(u32).init(42);
    defer watch.deinit();

    var rx = watch.subscribeNoInitial();

    // Should not see initial value as changed
    try std.testing.expect(!rx.hasChanged());

    watch.send(100);
    try std.testing.expect(rx.hasChanged());
}

test "Watch - sendModify" {
    var watch = Watch(u32).init(10);
    defer watch.deinit();

    var rx = watch.subscribe();
    rx.markSeen();

    const double = struct {
        fn f(val: *u32) void {
            val.* *= 2;
        }
    }.f;

    watch.sendModify(double);

    try std.testing.expect(rx.hasChanged());
    try std.testing.expectEqual(@as(u32, 20), rx.get());
}
