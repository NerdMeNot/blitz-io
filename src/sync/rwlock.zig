//! RwLock - Async Read-Write Lock
//!
//! A read-write lock that allows multiple concurrent readers OR a single writer.
//! Writers have priority to prevent writer starvation.
//!
//! ## Usage
//!
//! ```zig
//! var rwlock = RwLock.init();
//!
//! // Multiple readers allowed concurrently
//! if (rwlock.tryReadLock()) {
//!     defer rwlock.readUnlock();
//!     // Read shared data
//! }
//!
//! // Only one writer, excludes all readers
//! if (rwlock.tryWriteLock()) {
//!     defer rwlock.writeUnlock();
//!     // Modify shared data
//! }
//! ```
//!
//! ## Design
//!
//! - State tracks: reader count, writer active, writer waiting
//! - Writers have priority: new readers wait if writer is waiting
//! - FIFO ordering within reader/writer queues
//!
//! Reference: tokio/src/sync/rwlock.rs

const std = @import("std");
const builtin = @import("builtin");

const LinkedList = @import("../util/linked_list.zig").LinkedList;
const Pointers = @import("../util/linked_list.zig").Pointers;
const WakeList = @import("../util/wake_list.zig").WakeList;

// ─────────────────────────────────────────────────────────────────────────────
// Waiters
// ─────────────────────────────────────────────────────────────────────────────

/// Function pointer type for waking
pub const WakerFn = *const fn (*anyopaque) void;

/// Waiter for read lock acquisition
pub const ReadWaiter = struct {
    waker: ?WakerFn = null,
    waker_ctx: ?*anyopaque = null,
    acquired: bool = false,
    pointers: Pointers(ReadWaiter) = .{},

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

    pub fn isAcquired(self: *const Self) bool {
        return self.acquired;
    }

    pub fn reset(self: *Self) void {
        self.acquired = false;
        self.waker = null;
        self.waker_ctx = null;
        self.pointers.reset();
    }
};

/// Waiter for write lock acquisition
pub const WriteWaiter = struct {
    waker: ?WakerFn = null,
    waker_ctx: ?*anyopaque = null,
    acquired: bool = false,
    pointers: Pointers(WriteWaiter) = .{},

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

    pub fn isAcquired(self: *const Self) bool {
        return self.acquired;
    }

    pub fn reset(self: *Self) void {
        self.acquired = false;
        self.waker = null;
        self.waker_ctx = null;
        self.pointers.reset();
    }
};

const ReadWaiterList = LinkedList(ReadWaiter, "pointers");
const WriteWaiterList = LinkedList(WriteWaiter, "pointers");

// ─────────────────────────────────────────────────────────────────────────────
// RwLock
// ─────────────────────────────────────────────────────────────────────────────

/// An async-aware read-write lock.
pub const RwLock = struct {
    /// Number of active readers (0 if writer holds lock)
    readers: usize,

    /// Whether a writer holds the lock
    writer_active: bool,

    /// Mutex protecting internal state
    mutex: std.Thread.Mutex,

    /// Waiting readers
    read_waiters: ReadWaiterList,

    /// Waiting writers
    write_waiters: WriteWaiterList,

    const Self = @This();

    /// Create a new unlocked RwLock.
    pub fn init() Self {
        return .{
            .readers = 0,
            .writer_active = false,
            .mutex = .{},
            .read_waiters = .{},
            .write_waiters = .{},
        };
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Read Lock
    // ═══════════════════════════════════════════════════════════════════════

    /// Try to acquire read lock without waiting.
    /// Returns true if acquired, false if writer holds lock or is waiting.
    pub fn tryReadLock(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Can't read if writer is active or waiting (writer priority)
        if (self.writer_active or self.write_waiters.count() > 0) {
            return false;
        }

        self.readers += 1;
        return true;
    }

    /// Acquire read lock, potentially waiting.
    /// Returns true if acquired immediately, false if waiting.
    pub fn readLock(self: *Self, waiter: *ReadWaiter) bool {
        self.mutex.lock();

        // Can acquire if no writer active and no writers waiting
        if (!self.writer_active and self.write_waiters.count() == 0) {
            self.readers += 1;
            self.mutex.unlock();
            waiter.acquired = true;
            return true;
        }

        // Must wait
        waiter.acquired = false;
        self.read_waiters.pushBack(waiter);
        self.mutex.unlock();

        return false;
    }

    /// Release read lock.
    pub fn readUnlock(self: *Self) void {
        var writer_to_wake: ?*WriteWaiter = null;

        self.mutex.lock();

        std.debug.assert(self.readers > 0);
        self.readers -= 1;

        // If no more readers and writers waiting, wake one writer
        if (self.readers == 0 and self.write_waiters.count() > 0) {
            writer_to_wake = self.write_waiters.popFront();
            if (writer_to_wake) |w| {
                w.acquired = true;
                self.writer_active = true;
            }
        }

        self.mutex.unlock();

        // Wake outside lock
        if (writer_to_wake) |w| {
            w.wake();
        }
    }

    /// Cancel a pending read lock.
    pub fn cancelReadLock(self: *Self, waiter: *ReadWaiter) void {
        if (waiter.isAcquired()) return;

        self.mutex.lock();

        if (waiter.isAcquired()) {
            self.mutex.unlock();
            return;
        }

        if (ReadWaiterList.isLinked(waiter) or self.read_waiters.front() == waiter) {
            self.read_waiters.remove(waiter);
            waiter.pointers.reset();
        }

        self.mutex.unlock();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Write Lock
    // ═══════════════════════════════════════════════════════════════════════

    /// Try to acquire write lock without waiting.
    /// Returns true if acquired, false if any readers or writer active.
    pub fn tryWriteLock(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.writer_active or self.readers > 0) {
            return false;
        }

        self.writer_active = true;
        return true;
    }

    /// Acquire write lock, potentially waiting.
    /// Returns true if acquired immediately, false if waiting.
    pub fn writeLock(self: *Self, waiter: *WriteWaiter) bool {
        self.mutex.lock();

        // Can acquire if no readers and no writer
        if (!self.writer_active and self.readers == 0) {
            self.writer_active = true;
            self.mutex.unlock();
            waiter.acquired = true;
            return true;
        }

        // Must wait
        waiter.acquired = false;
        self.write_waiters.pushBack(waiter);
        self.mutex.unlock();

        return false;
    }

    /// Release write lock.
    pub fn writeUnlock(self: *Self) void {
        var wake_list: WakeList(32) = .{};
        var writer_to_wake: ?*WriteWaiter = null;

        self.mutex.lock();

        std.debug.assert(self.writer_active);
        self.writer_active = false;

        // Prefer waking writers (writer priority) OR wake all waiting readers
        if (self.write_waiters.count() > 0) {
            // Wake one writer
            writer_to_wake = self.write_waiters.popFront();
            if (writer_to_wake) |w| {
                w.acquired = true;
                self.writer_active = true;
            }
        } else {
            // Wake all waiting readers
            while (self.read_waiters.popFront()) |r| {
                r.acquired = true;
                self.readers += 1;
                if (r.waker) |wf| {
                    if (r.waker_ctx) |ctx| {
                        wake_list.push(.{ .context = ctx, .wake_fn = wf });
                    }
                }
            }
        }

        self.mutex.unlock();

        // Wake outside lock
        if (writer_to_wake) |w| {
            w.wake();
        }
        wake_list.wakeAll();
    }

    /// Cancel a pending write lock.
    pub fn cancelWriteLock(self: *Self, waiter: *WriteWaiter) void {
        if (waiter.isAcquired()) return;

        self.mutex.lock();

        if (waiter.isAcquired()) {
            self.mutex.unlock();
            return;
        }

        if (WriteWaiterList.isLinked(waiter) or self.write_waiters.front() == waiter) {
            self.write_waiters.remove(waiter);
            waiter.pointers.reset();
        }

        self.mutex.unlock();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Diagnostics
    // ═══════════════════════════════════════════════════════════════════════

    /// Check if write-locked.
    pub fn isWriteLocked(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.writer_active;
    }

    /// Get reader count.
    pub fn readerCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.readers;
    }

    /// Get waiting reader count.
    pub fn waitingReaders(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.read_waiters.count();
    }

    /// Get waiting writer count.
    pub fn waitingWriters(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.write_waiters.count();
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// RAII Guards
// ─────────────────────────────────────────────────────────────────────────────

/// RAII guard for read lock.
pub const ReadGuard = struct {
    rwlock: *RwLock,
    active: bool,

    const Self = @This();

    pub fn init(rwlock: *RwLock) Self {
        return .{ .rwlock = rwlock, .active = true };
    }

    pub fn unlock(self: *Self) void {
        if (self.active) {
            self.rwlock.readUnlock();
            self.active = false;
        }
    }

    pub fn deinit(self: *Self) void {
        self.unlock();
    }
};

/// RAII guard for write lock.
pub const WriteGuard = struct {
    rwlock: *RwLock,
    active: bool,

    const Self = @This();

    pub fn init(rwlock: *RwLock) Self {
        return .{ .rwlock = rwlock, .active = true };
    }

    pub fn unlock(self: *Self) void {
        if (self.active) {
            self.rwlock.writeUnlock();
            self.active = false;
        }
    }

    pub fn deinit(self: *Self) void {
        self.unlock();
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "RwLock - multiple readers" {
    var rwlock = RwLock.init();

    // Multiple readers can acquire
    try std.testing.expect(rwlock.tryReadLock());
    try std.testing.expect(rwlock.tryReadLock());
    try std.testing.expect(rwlock.tryReadLock());

    try std.testing.expectEqual(@as(usize, 3), rwlock.readerCount());

    // Writer cannot acquire while readers hold
    try std.testing.expect(!rwlock.tryWriteLock());

    rwlock.readUnlock();
    rwlock.readUnlock();
    rwlock.readUnlock();

    try std.testing.expectEqual(@as(usize, 0), rwlock.readerCount());
}

test "RwLock - exclusive writer" {
    var rwlock = RwLock.init();

    try std.testing.expect(rwlock.tryWriteLock());
    try std.testing.expect(rwlock.isWriteLocked());

    // No one else can acquire
    try std.testing.expect(!rwlock.tryReadLock());
    try std.testing.expect(!rwlock.tryWriteLock());

    rwlock.writeUnlock();
    try std.testing.expect(!rwlock.isWriteLocked());
}

test "RwLock - writer priority" {
    var rwlock = RwLock.init();

    // Reader holds lock
    try std.testing.expect(rwlock.tryReadLock());

    // Writer waits
    var write_waiter = WriteWaiter.init();
    try std.testing.expect(!rwlock.writeLock(&write_waiter));
    try std.testing.expectEqual(@as(usize, 1), rwlock.waitingWriters());

    // New reader should wait (writer priority)
    try std.testing.expect(!rwlock.tryReadLock());

    // Release reader - writer should get lock
    rwlock.readUnlock();
    try std.testing.expect(write_waiter.isAcquired());
    try std.testing.expect(rwlock.isWriteLocked());

    rwlock.writeUnlock();
}

test "RwLock - wake all readers after writer" {
    var rwlock = RwLock.init();
    var woken: [3]bool = .{ false, false, false };

    const TestWaker = struct {
        fn wake(ctx: *anyopaque) void {
            const w: *bool = @ptrCast(@alignCast(ctx));
            w.* = true;
        }
    };

    // Writer holds lock
    try std.testing.expect(rwlock.tryWriteLock());

    // Readers wait
    var read_waiters: [3]ReadWaiter = undefined;
    for (&read_waiters, 0..) |*w, i| {
        w.* = ReadWaiter.init();
        w.setWaker(@ptrCast(&woken[i]), TestWaker.wake);
        _ = rwlock.readLock(w);
    }

    try std.testing.expectEqual(@as(usize, 3), rwlock.waitingReaders());

    // Writer releases - all readers should wake
    rwlock.writeUnlock();

    for (woken) |w| {
        try std.testing.expect(w);
    }
    try std.testing.expectEqual(@as(usize, 3), rwlock.readerCount());

    // Clean up
    rwlock.readUnlock();
    rwlock.readUnlock();
    rwlock.readUnlock();
}

test "RwLock - read guard RAII" {
    var rwlock = RwLock.init();

    {
        try std.testing.expect(rwlock.tryReadLock());
        var guard = ReadGuard.init(&rwlock);
        try std.testing.expectEqual(@as(usize, 1), rwlock.readerCount());
        guard.deinit();
    }

    try std.testing.expectEqual(@as(usize, 0), rwlock.readerCount());
}

test "RwLock - write guard RAII" {
    var rwlock = RwLock.init();

    {
        try std.testing.expect(rwlock.tryWriteLock());
        var guard = WriteGuard.init(&rwlock);
        try std.testing.expect(rwlock.isWriteLocked());
        guard.deinit();
    }

    try std.testing.expect(!rwlock.isWriteLocked());
}

test "RwLock - many concurrent readers" {
    var rwlock = RwLock.init();
    const num_readers = 100;

    // Acquire many read locks
    for (0..num_readers) |_| {
        try std.testing.expect(rwlock.tryReadLock());
    }

    try std.testing.expectEqual(@as(usize, num_readers), rwlock.readerCount());

    // Writer still cannot acquire
    try std.testing.expect(!rwlock.tryWriteLock());

    // Release all readers
    for (0..num_readers) |_| {
        rwlock.readUnlock();
    }

    try std.testing.expectEqual(@as(usize, 0), rwlock.readerCount());

    // Now writer can acquire
    try std.testing.expect(rwlock.tryWriteLock());
    rwlock.writeUnlock();
}

test "RwLock - reader writer contention" {
    var rwlock = RwLock.init();
    var reader_woken = false;
    var writer_woken = false;

    const TestWaker = struct {
        fn wake(ctx: *anyopaque) void {
            const w: *bool = @ptrCast(@alignCast(ctx));
            w.* = true;
        }
    };

    // Reader 1 holds lock
    try std.testing.expect(rwlock.tryReadLock());

    // Writer waits
    var write_waiter = WriteWaiter.init();
    write_waiter.setWaker(@ptrCast(&writer_woken), TestWaker.wake);
    try std.testing.expect(!rwlock.writeLock(&write_waiter));

    // Reader 2 should wait (due to writer priority)
    var read_waiter = ReadWaiter.init();
    read_waiter.setWaker(@ptrCast(&reader_woken), TestWaker.wake);
    try std.testing.expect(!rwlock.readLock(&read_waiter));

    // Check waiter counts
    try std.testing.expectEqual(@as(usize, 1), rwlock.waitingWriters());
    try std.testing.expectEqual(@as(usize, 1), rwlock.waitingReaders());

    // Release reader 1 - writer should wake (has priority)
    rwlock.readUnlock();
    try std.testing.expect(writer_woken);
    try std.testing.expect(!reader_woken); // Reader still waiting
    try std.testing.expect(write_waiter.isAcquired());

    // Release writer - reader 2 should wake
    rwlock.writeUnlock();
    try std.testing.expect(reader_woken);
    try std.testing.expect(read_waiter.isAcquired());

    // Clean up
    rwlock.readUnlock();
}

test "RwLock - tryReadLock tryWriteLock under contention" {
    var rwlock = RwLock.init();

    // Writer holds lock - tryReadLock and tryWriteLock fail
    try std.testing.expect(rwlock.tryWriteLock());

    try std.testing.expect(!rwlock.tryReadLock());
    try std.testing.expect(!rwlock.tryWriteLock());

    rwlock.writeUnlock();

    // Reader holds lock - tryWriteLock fails, tryReadLock succeeds
    try std.testing.expect(rwlock.tryReadLock());

    try std.testing.expect(rwlock.tryReadLock()); // Second reader OK
    try std.testing.expect(!rwlock.tryWriteLock());

    rwlock.readUnlock();
    rwlock.readUnlock();

    // Writer waiting - new tryReadLock fails
    try std.testing.expect(rwlock.tryReadLock());

    var write_waiter = WriteWaiter.init();
    _ = rwlock.writeLock(&write_waiter);

    // tryReadLock should fail due to waiting writer (writer priority)
    try std.testing.expect(!rwlock.tryReadLock());

    // Clean up
    rwlock.readUnlock();
    try std.testing.expect(write_waiter.isAcquired());
    rwlock.writeUnlock();
}

test "RwLock - cancel read lock" {
    var rwlock = RwLock.init();

    // Writer holds lock
    try std.testing.expect(rwlock.tryWriteLock());

    // Reader waits
    var read_waiter = ReadWaiter.init();
    try std.testing.expect(!rwlock.readLock(&read_waiter));
    try std.testing.expectEqual(@as(usize, 1), rwlock.waitingReaders());

    // Cancel the read lock
    rwlock.cancelReadLock(&read_waiter);
    try std.testing.expectEqual(@as(usize, 0), rwlock.waitingReaders());
    try std.testing.expect(!read_waiter.isAcquired());

    rwlock.writeUnlock();
}

test "RwLock - cancel write lock" {
    var rwlock = RwLock.init();

    // Reader holds lock
    try std.testing.expect(rwlock.tryReadLock());

    // Writer waits
    var write_waiter = WriteWaiter.init();
    try std.testing.expect(!rwlock.writeLock(&write_waiter));
    try std.testing.expectEqual(@as(usize, 1), rwlock.waitingWriters());

    // Cancel the write lock
    rwlock.cancelWriteLock(&write_waiter);
    try std.testing.expectEqual(@as(usize, 0), rwlock.waitingWriters());
    try std.testing.expect(!write_waiter.isAcquired());

    // New reader should be able to acquire (no waiting writer)
    try std.testing.expect(rwlock.tryReadLock());

    rwlock.readUnlock();
    rwlock.readUnlock();
}

test "RwLock - writer FIFO ordering" {
    var rwlock = RwLock.init();

    // Reader holds lock
    try std.testing.expect(rwlock.tryReadLock());

    // Three writers wait in order
    var write_waiters: [3]WriteWaiter = undefined;
    for (&write_waiters) |*w| {
        w.* = WriteWaiter.init();
        try std.testing.expect(!rwlock.writeLock(w));
    }

    try std.testing.expectEqual(@as(usize, 3), rwlock.waitingWriters());

    // Release reader - first writer should get lock (FIFO)
    rwlock.readUnlock();
    try std.testing.expect(write_waiters[0].isAcquired());
    try std.testing.expect(!write_waiters[1].isAcquired());
    try std.testing.expect(!write_waiters[2].isAcquired());

    // Release first writer - second writer should get lock (FIFO)
    rwlock.writeUnlock();
    try std.testing.expect(write_waiters[1].isAcquired());
    try std.testing.expect(!write_waiters[2].isAcquired());

    // Release second writer - third writer should get lock (FIFO)
    rwlock.writeUnlock();
    try std.testing.expect(write_waiters[2].isAcquired());

    // Release third writer
    rwlock.writeUnlock();

    // All writers should have been acquired in FIFO order
    for (&write_waiters) |*w| {
        try std.testing.expect(w.isAcquired());
    }
}
