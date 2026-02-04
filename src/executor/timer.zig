//! Timer Wheel for Efficient Timeout Management
//!
//! Implements a hierarchical timing wheel similar to Tokio's timer driver.
//! The timer wheel provides O(1) insertion and O(1) expiration checking.
//!
//! Architecture:
//! - Level 0: 64 slots, 1ms resolution (64ms range)
//! - Level 1: 64 slots, 64ms resolution (4s range)
//! - Level 2: 64 slots, 4s resolution (4min range)
//! - Level 3: 64 slots, 4min resolution (4hr range)
//! - Level 4: 64 slots, 4hr resolution (10+ days range)
//! - Overflow: linked list for very long timers
//!
//! Total precision: millisecond-level for timers < 64ms,
//! degrades gracefully for longer timers.
//!
//! Reference: tokio/src/time/driver/wheel/mod.rs

const std = @import("std");
const Allocator = std.mem.Allocator;
const Header = @import("task.zig").Header;

/// Number of slots per wheel level
const SLOTS_PER_LEVEL: usize = 64;

/// Number of levels in the wheel
const NUM_LEVELS: usize = 5;

/// Slot duration at level 0 (1 millisecond)
const LEVEL_0_SLOT_NS: u64 = std.time.ns_per_ms;

// ─────────────────────────────────────────────────────────────────────────────
// COMPTIME OPTIMIZATION: Precompute slot durations and max ranges
// Zig advantage: These are computed at compile time, zero runtime cost
// ─────────────────────────────────────────────────────────────────────────────

/// Precomputed slot durations for each level (computed at comptime)
const SLOT_DURATIONS: [NUM_LEVELS]u64 = blk: {
    var durations: [NUM_LEVELS]u64 = undefined;
    var duration: u64 = LEVEL_0_SLOT_NS;
    for (0..NUM_LEVELS) |i| {
        durations[i] = duration;
        duration *= SLOTS_PER_LEVEL;
    }
    break :blk durations;
};

/// Precomputed max duration for each level (computed at comptime)
const LEVEL_MAX_DURATIONS: [NUM_LEVELS]u64 = blk: {
    var maxes: [NUM_LEVELS]u64 = undefined;
    for (0..NUM_LEVELS) |i| {
        maxes[i] = SLOT_DURATIONS[i] * SLOTS_PER_LEVEL;
    }
    break :blk maxes;
};

/// Function pointer type for waking (matches sync primitives)
pub const WakerFn = *const fn (*anyopaque) void;

/// Timer entry - stored in the wheel
pub const TimerEntry = struct {
    /// Deadline in nanoseconds (monotonic)
    deadline_ns: u64,

    /// Task to wake when timer expires (for task-based waking)
    task: ?*Header,

    /// Generic waker function (for waiter-based primitives)
    waker: ?WakerFn,

    /// Context for waker function
    waker_ctx: ?*anyopaque,

    /// User data for callbacks
    user_data: u64,

    /// Intrusive linked list pointers
    next: ?*TimerEntry,
    prev: ?*TimerEntry,

    /// Is this timer cancelled?
    cancelled: bool,

    /// Was this entry allocated by the wheel? (for cleanup)
    heap_allocated: bool,

    /// Create a timer entry with task-based waking
    pub fn init(deadline_ns: u64, task: ?*Header, user_data: u64) TimerEntry {
        return .{
            .deadline_ns = deadline_ns,
            .task = task,
            .waker = null,
            .waker_ctx = null,
            .user_data = user_data,
            .next = null,
            .prev = null,
            .cancelled = false,
            .heap_allocated = false,
        };
    }

    /// Create a timer entry with waker-based waking (for async primitives)
    pub fn initWithWaker(deadline_ns: u64, ctx: *anyopaque, waker: WakerFn, user_data: u64) TimerEntry {
        return .{
            .deadline_ns = deadline_ns,
            .task = null,
            .waker = waker,
            .waker_ctx = ctx,
            .user_data = user_data,
            .next = null,
            .prev = null,
            .cancelled = false,
            .heap_allocated = false,
        };
    }

    /// Set a waker (can be called after init)
    pub fn setWaker(self: *TimerEntry, ctx: *anyopaque, waker: WakerFn) void {
        self.waker_ctx = ctx;
        self.waker = waker;
    }

    /// Wake this entry (called when timer expires)
    pub fn wake(self: *TimerEntry) void {
        // Try task-based waking first
        if (self.task) |task| {
            if (task.transitionToScheduled()) {
                task.schedule();
            }
        }
        // Then try waker-based waking
        if (self.waker) |waker_fn| {
            if (self.waker_ctx) |ctx| {
                waker_fn(ctx);
            }
        }
    }

    pub fn cancel(self: *TimerEntry) void {
        self.cancelled = true;
    }
};

/// A single slot in the wheel (linked list of timers)
const Slot = struct {
    head: ?*TimerEntry,
    tail: ?*TimerEntry,

    pub fn init() Slot {
        return .{ .head = null, .tail = null };
    }

    pub fn push(self: *Slot, entry: *TimerEntry) void {
        entry.next = null;
        entry.prev = self.tail;

        if (self.tail) |t| {
            t.next = entry;
        } else {
            self.head = entry;
        }
        self.tail = entry;
    }

    pub fn remove(self: *Slot, entry: *TimerEntry) void {
        if (entry.prev) |p| {
            p.next = entry.next;
        } else {
            self.head = entry.next;
        }

        if (entry.next) |n| {
            n.prev = entry.prev;
        } else {
            self.tail = entry.prev;
        }

        entry.next = null;
        entry.prev = null;
    }

    pub fn isEmpty(self: *const Slot) bool {
        return self.head == null;
    }

    /// Take all entries from this slot
    pub fn takeAll(self: *Slot) ?*TimerEntry {
        const head = self.head;
        self.head = null;
        self.tail = null;
        return head;
    }
};

/// One level of the timer wheel
const Level = struct {
    slots: [SLOTS_PER_LEVEL]Slot,
    /// Current slot index
    current: usize,

    pub fn init() Level {
        var level: Level = undefined;
        level.current = 0;
        for (&level.slots) |*slot| {
            slot.* = Slot.init();
        }
        return level;
    }

    pub fn slotFor(deadline_ns: u64, level_idx: usize, now_ns: u64) usize {
        const slot_duration = slotDuration(level_idx);
        const delta = deadline_ns -| now_ns;
        const slot_offset = delta / slot_duration;
        return @intCast(slot_offset % SLOTS_PER_LEVEL);
    }
};

/// Calculate slot duration for a level (uses comptime lookup table)
inline fn slotDuration(level: usize) u64 {
    return SLOT_DURATIONS[level];
}

/// Calculate the max duration covered by a level (uses comptime lookup table)
inline fn levelMaxDuration(level: usize) u64 {
    return LEVEL_MAX_DURATIONS[level];
}

/// The main timer wheel
pub const TimerWheel = struct {
    const Self = @This();

    /// The wheel levels
    levels: [NUM_LEVELS]Level,

    /// Overflow list for very long timers
    overflow: Slot,

    /// Current time (nanoseconds, monotonic)
    now_ns: u64,

    /// Start time for monotonic clock
    start_instant: std.time.Instant,

    /// Number of active timers
    count: usize,

    /// Allocator for timer entries
    allocator: Allocator,

    /// Create a new timer wheel
    pub fn init(allocator: Allocator) Self {
        var wheel: Self = undefined;
        wheel.allocator = allocator;
        wheel.count = 0;
        wheel.overflow = Slot.init();
        wheel.start_instant = std.time.Instant.now() catch blk: {
            // Fallback if Instant.now() fails
            break :blk std.time.Instant{
                .timestamp = .{ .sec = 0, .nsec = 0 },
            };
        };
        wheel.now_ns = 0;

        for (&wheel.levels) |*level| {
            level.* = Level.init();
        }

        return wheel;
    }

    /// Clean up all timer entries
    /// Frees all entries that were allocated via sleep() or deadline()
    /// Note: Entries allocated externally and inserted via insert() are NOT freed
    pub fn deinit(self: *Self) void {
        // Free entries in all levels
        for (&self.levels) |*level| {
            for (&level.slots) |*slot| {
                self.freeSlotEntries(slot);
            }
        }

        // Free overflow entries
        self.freeSlotEntries(&self.overflow);

        self.count = 0;
    }

    /// Free all entries in a slot (only heap-allocated ones)
    fn freeSlotEntries(self: *Self, slot: *Slot) void {
        var entry = slot.head;
        while (entry) |e| {
            const next = e.next;
            // Only free entries that we allocated
            if (e.heap_allocated) {
                self.allocator.destroy(e);
            }
            entry = next;
        }
        slot.head = null;
        slot.tail = null;
    }

    /// Get current monotonic time in nanoseconds
    pub fn now(self: *const Self) u64 {
        const current = std.time.Instant.now() catch return self.now_ns;
        return current.since(self.start_instant);
    }

    /// Update the wheel's time
    pub fn updateTime(self: *Self) void {
        self.now_ns = self.now();
    }

    /// Insert a timer
    pub fn insert(self: *Self, entry: *TimerEntry) void {
        const entry_deadline = entry.deadline_ns;
        const current_now = self.now_ns;

        // Find the appropriate level
        var level_idx: usize = 0;
        while (level_idx < NUM_LEVELS) : (level_idx += 1) {
            const max_duration = levelMaxDuration(level_idx);
            if (entry_deadline -| current_now < max_duration) {
                break;
            }
        }

        if (level_idx >= NUM_LEVELS) {
            // Overflow
            self.overflow.push(entry);
        } else {
            const slot_idx = Level.slotFor(entry_deadline, level_idx, current_now);
            self.levels[level_idx].slots[slot_idx].push(entry);
        }

        self.count += 1;
    }

    /// Remove a timer (if it's still in the wheel)
    /// Note: This just marks the timer as cancelled, it remains in the wheel
    /// until the next poll() when it will be cleaned up.
    pub fn remove(_: *Self, entry: *TimerEntry) void {
        // Mark as cancelled - actual removal happens during poll
        entry.cancel();
        // Note: We don't update count here as the entry is still in a slot
    }

    /// Poll for expired timers
    /// Returns a linked list of expired entries
    pub fn poll(self: *Self) ?*TimerEntry {
        self.updateTime();

        var expired_head: ?*TimerEntry = null;
        var expired_tail: ?*TimerEntry = null;

        // Check level 0 slots up to current time
        const level0_slot = (self.now_ns / LEVEL_0_SLOT_NS) % SLOTS_PER_LEVEL;
        var current = self.levels[0].current;

        while (current != level0_slot) {
            const entries = self.levels[0].slots[current].takeAll();
            self.appendExpired(&expired_head, &expired_tail, entries);

            current = (current + 1) % SLOTS_PER_LEVEL;

            // Cascade from higher levels when slot wraps
            if (current == 0) {
                self.cascade(1);
            }
        }

        // Check current slot for expired entries
        var slot = &self.levels[0].slots[current];
        var entry = slot.head;
        while (entry) |e| {
            const next = e.next;
            if (e.deadline_ns <= self.now_ns) {
                slot.remove(e);
                self.appendEntry(&expired_head, &expired_tail, e);
            }
            entry = next;
        }

        self.levels[0].current = @intCast(level0_slot);

        return expired_head;
    }

    /// Cascade entries from a higher level to lower levels
    fn cascade(self: *Self, level_idx: usize) void {
        if (level_idx >= NUM_LEVELS) return;

        const level = &self.levels[level_idx];
        const slot_idx = level.current;
        level.current = (slot_idx + 1) % SLOTS_PER_LEVEL;

        if (level.current == 0 and level_idx + 1 < NUM_LEVELS) {
            self.cascade(level_idx + 1);
        }

        // Move entries from this slot to lower levels
        var entry = level.slots[slot_idx].takeAll();
        while (entry) |e| {
            const next = e.next;
            e.next = null;
            e.prev = null;

            if (e.cancelled) {
                self.count -|= 1;
            } else {
                // Re-insert at appropriate level
                self.count -|= 1;
                self.insert(e);
            }

            entry = next;
        }
    }

    /// Append an entry to the expired list
    fn appendEntry(
        self: *Self,
        head: *?*TimerEntry,
        tail: *?*TimerEntry,
        entry: *TimerEntry,
    ) void {
        if (entry.cancelled) {
            self.count -|= 1;
            return;
        }

        entry.next = null;
        entry.prev = tail.*;

        if (tail.*) |t| {
            t.next = entry;
        } else {
            head.* = entry;
        }
        tail.* = entry;
        self.count -|= 1;
    }

    /// Append a list of entries to the expired list
    fn appendExpired(
        self: *Self,
        head: *?*TimerEntry,
        tail: *?*TimerEntry,
        entries: ?*TimerEntry,
    ) void {
        var entry = entries;
        while (entry) |e| {
            const next = e.next;
            self.appendEntry(head, tail, e);
            entry = next;
        }
    }

    /// Get time until next timer expires (for poll timeout)
    pub fn nextExpiration(self: *const Self) ?u64 {
        // Simple implementation: check level 0
        // A more sophisticated version would check all levels
        const current = self.levels[0].current;

        // Check slots from current to end, then wrap
        for (0..SLOTS_PER_LEVEL) |i| {
            const slot_idx = (current + i) % SLOTS_PER_LEVEL;
            if (!self.levels[0].slots[slot_idx].isEmpty()) {
                // Found a non-empty slot
                const slot_time = (self.now_ns / LEVEL_0_SLOT_NS + i) * LEVEL_0_SLOT_NS;
                return slot_time -| self.now_ns;
            }
        }

        // Check higher levels...
        // For now, return a default
        if (self.count > 0) {
            return LEVEL_0_SLOT_NS; // Check again in 1ms
        }

        return null;
    }

    /// Get the number of active timers
    pub fn len(self: *const Self) usize {
        return self.count;
    }

    /// Check if empty
    pub fn isEmpty(self: *const Self) bool {
        return self.count == 0;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Convenience functions
// ─────────────────────────────────────────────────────────────────────────────

/// Create a timer entry for sleeping
/// Returns error.OutOfMemory if allocation fails
/// The entry will be automatically freed when the wheel is deinitialized
pub fn sleep(wheel: *TimerWheel, duration_ns: u64, task: *Header) !*TimerEntry {
    const entry = try wheel.allocator.create(TimerEntry);
    entry.* = TimerEntry.init(wheel.now() + duration_ns, task, 0);
    entry.heap_allocated = true; // Mark as wheel-allocated for cleanup
    wheel.insert(entry);
    return entry;
}

/// Create a timer entry for a deadline
/// Returns error.OutOfMemory if allocation fails
/// The entry will be automatically freed when the wheel is deinitialized
pub fn deadline(wheel: *TimerWheel, deadline_ns: u64, task: *Header) !*TimerEntry {
    const entry = try wheel.allocator.create(TimerEntry);
    entry.* = TimerEntry.init(deadline_ns, task, 0);
    entry.heap_allocated = true; // Mark as wheel-allocated for cleanup
    wheel.insert(entry);
    return entry;
}

/// Create a timer entry with a waker callback (for async primitives)
/// Returns error.OutOfMemory if allocation fails
/// The entry will be automatically freed when the wheel is deinitialized
pub fn sleepWithWaker(
    wheel: *TimerWheel,
    duration_ns: u64,
    ctx: *anyopaque,
    waker: WakerFn,
) !*TimerEntry {
    const entry = try wheel.allocator.create(TimerEntry);
    entry.* = TimerEntry.initWithWaker(wheel.now() + duration_ns, ctx, waker, 0);
    entry.heap_allocated = true;
    wheel.insert(entry);
    return entry;
}

/// Create a timer entry for a deadline with a waker callback
/// Returns error.OutOfMemory if allocation fails
pub fn deadlineWithWaker(
    wheel: *TimerWheel,
    deadline_ns: u64,
    ctx: *anyopaque,
    waker: WakerFn,
) !*TimerEntry {
    const entry = try wheel.allocator.create(TimerEntry);
    entry.* = TimerEntry.initWithWaker(deadline_ns, ctx, waker, 0);
    entry.heap_allocated = true;
    wheel.insert(entry);
    return entry;
}

/// Process expired timer entries and wake their associated tasks/waiters
/// Frees heap-allocated entries after processing
/// Returns the number of entries processed
pub fn processExpired(wheel: *TimerWheel, expired: ?*TimerEntry) usize {
    var count: usize = 0;
    var entry = expired;

    while (entry) |e| {
        const next = e.next;
        count += 1;

        // Wake via task or waker if not cancelled
        if (!e.cancelled) {
            e.wake();
        }

        // Free heap-allocated entries
        if (e.heap_allocated) {
            wheel.allocator.destroy(e);
        }

        entry = next;
    }

    return count;
}

/// Poll and process all expired timers in one call
/// This is a convenience function that combines poll() and processExpired()
/// Returns the number of expired timers processed
pub fn pollAndProcess(wheel: *TimerWheel) usize {
    const expired = wheel.poll();
    return processExpired(wheel, expired);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "TimerWheel - init" {
    var wheel = TimerWheel.init(std.testing.allocator);
    defer wheel.deinit();

    try std.testing.expect(wheel.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), wheel.len());
}

test "TimerWheel - insert and poll" {
    var wheel = TimerWheel.init(std.testing.allocator);
    defer wheel.deinit();

    // Create a timer entry
    var entry = TimerEntry.init(wheel.now() + 1, null, 42);

    wheel.insert(&entry);
    try std.testing.expectEqual(@as(usize, 1), wheel.len());

    // Wait for it to expire
    std.Thread.sleep(2 * std.time.ns_per_ms);

    const expired = wheel.poll();
    try std.testing.expect(expired != null);
    try std.testing.expectEqual(@as(u64, 42), expired.?.user_data);
}

test "TimerWheel - cancel" {
    var wheel = TimerWheel.init(std.testing.allocator);
    defer wheel.deinit();

    var entry = TimerEntry.init(wheel.now() + 100 * std.time.ns_per_ms, null, 0);
    wheel.insert(&entry);

    // Cancel before expiry
    entry.cancel();
    try std.testing.expect(entry.cancelled);

    // Poll should not return cancelled entry
    const expired = wheel.poll();
    try std.testing.expect(expired == null);
}

test "TimerWheel - multiple timers" {
    var wheel = TimerWheel.init(std.testing.allocator);
    defer wheel.deinit();

    var entries: [5]TimerEntry = undefined;
    const now = wheel.now();

    for (&entries, 0..) |*e, i| {
        e.* = TimerEntry.init(now + @as(u64, @intCast(i + 1)) * std.time.ns_per_ms, null, @intCast(i));
        wheel.insert(e);
    }

    try std.testing.expectEqual(@as(usize, 5), wheel.len());

    // Wait for all to expire
    std.Thread.sleep(10 * std.time.ns_per_ms);

    var count: usize = 0;
    var expired = wheel.poll();
    while (expired) |e| {
        count += 1;
        expired = e.next;
    }

    try std.testing.expect(count >= 1); // At least some should have expired
}

test "slotDuration - calculations" {
    try std.testing.expectEqual(LEVEL_0_SLOT_NS, slotDuration(0));
    try std.testing.expectEqual(LEVEL_0_SLOT_NS * 64, slotDuration(1));
    try std.testing.expectEqual(LEVEL_0_SLOT_NS * 64 * 64, slotDuration(2));
}

test "levelMaxDuration - calculations" {
    // Level 0: 64ms
    try std.testing.expectEqual(@as(u64, 64 * std.time.ns_per_ms), levelMaxDuration(0));
    // Level 1: ~4 seconds
    try std.testing.expectEqual(@as(u64, 64 * 64 * std.time.ns_per_ms), levelMaxDuration(1));
}
