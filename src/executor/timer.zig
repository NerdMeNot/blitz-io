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
//! Optimizations (matching Tokio):
//! - Bit-based level selection: O(1) using leading zeros instead of linear search
//! - Occupancy bitfield: 64-bit field per level for O(1) next-slot lookup
//! - Intrusive linked list: Zero allocation per timer entry
//!
//! Total precision: millisecond-level for timers < 64ms,
//! degrades gracefully for longer timers.
//!
//! Reference: tokio/src/time/driver/wheel/mod.rs

const std = @import("std");
const Allocator = std.mem.Allocator;
const Header = @import("task.zig").Header;

/// Number of slots per wheel level (must be 64 for bit tricks)
const SLOTS_PER_LEVEL: usize = 64;

/// Bits per level (log2(64) = 6)
const BITS_PER_LEVEL: u6 = 6;

/// Slot mask for extracting slot index
const SLOT_MASK: u64 = SLOTS_PER_LEVEL - 1;

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

/// Maximum duration that can be handled by the wheel (before overflow).
const MAX_WHEEL_DURATION: u64 = LEVEL_MAX_DURATIONS[NUM_LEVELS - 1];

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
    /// Number of entries in this slot (for quick empty check)
    entry_count: usize,

    pub fn init() Slot {
        return .{ .head = null, .tail = null, .entry_count = 0 };
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
        self.entry_count += 1;
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
        self.entry_count -|= 1;
    }

    pub fn isEmpty(self: *const Slot) bool {
        return self.entry_count == 0;
    }

    /// Take all entries from this slot
    pub fn takeAll(self: *Slot) ?*TimerEntry {
        const head = self.head;
        self.head = null;
        self.tail = null;
        self.entry_count = 0;
        return head;
    }

    /// Get the count of entries
    pub fn len(self: *const Slot) usize {
        return self.entry_count;
    }
};

/// One level of the timer wheel
const Level = struct {
    slots: [SLOTS_PER_LEVEL]Slot,
    /// Current slot index
    current: usize,
    /// Occupancy bitfield: bit i is set if slots[i] is non-empty.
    /// Enables O(1) lookup of next non-empty slot using @ctz.
    occupied: u64,

    pub fn init() Level {
        var level: Level = undefined;
        level.current = 0;
        level.occupied = 0;
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

    /// Add an entry to a slot and update occupancy.
    pub fn addEntry(self: *Level, slot_idx: usize, entry: *TimerEntry) void {
        self.slots[slot_idx].push(entry);
        self.occupied |= (@as(u64, 1) << @intCast(slot_idx));
    }

    /// Remove an entry from a slot and update occupancy if slot becomes empty.
    pub fn removeEntry(self: *Level, slot_idx: usize, entry: *TimerEntry) void {
        self.slots[slot_idx].remove(entry);
        if (self.slots[slot_idx].isEmpty()) {
            self.occupied &= ~(@as(u64, 1) << @intCast(slot_idx));
        }
    }

    /// Take all entries from a slot and clear its occupancy bit.
    pub fn takeAllFromSlot(self: *Level, slot_idx: usize) ?*TimerEntry {
        const entries = self.slots[slot_idx].takeAll();
        self.occupied &= ~(@as(u64, 1) << @intCast(slot_idx));
        return entries;
    }

    /// Find the next occupied slot starting from (and including) current.
    /// Returns null if no slots are occupied.
    /// Uses bit manipulation for O(1) lookup.
    pub fn nextOccupiedSlot(self: *const Level, from_slot: usize) ?usize {
        if (self.occupied == 0) return null;

        // Create a mask for slots >= from_slot
        const from_mask: u64 = if (from_slot >= 64) 0 else ~((@as(u64, 1) << @intCast(from_slot)) - 1);
        const masked = self.occupied & from_mask;

        if (masked != 0) {
            // Found an occupied slot at or after from_slot
            return @ctz(masked);
        }

        // Wrap around: check slots before from_slot
        const wrap_mask: u64 = (@as(u64, 1) << @intCast(from_slot)) - 1;
        const wrapped = self.occupied & wrap_mask;

        if (wrapped != 0) {
            return @ctz(wrapped);
        }

        return null;
    }

    /// Check if any slot is occupied.
    pub fn hasEntries(self: *const Level) bool {
        return self.occupied != 0;
    }

    /// Count number of occupied slots.
    pub fn occupiedCount(self: *const Level) usize {
        return @popCount(self.occupied);
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

/// Calculate the appropriate level for a timer using bit manipulation.
/// This is O(1) using leading zeros, replacing the O(NUM_LEVELS) linear search.
///
/// The key insight (from Tokio): the level is determined by the most significant
/// differing bit between `elapsed` (current wheel position) and `when` (deadline),
/// both measured in ticks (level 0 slot durations).
/// Each level covers 6 bits (64 slots), so level = significant_bit / 6.
///
/// Reference: tokio/src/time/driver/wheel/mod.rs::Wheel::level_for
inline fn levelFor(now_ns: u64, deadline_ns: u64) usize {
    // Convert from nanoseconds to ticks (level 0 slot durations)
    const elapsed_ticks = now_ns / LEVEL_0_SLOT_NS;
    const when_ticks = deadline_ns / LEVEL_0_SLOT_NS;

    // XOR gives us the differing bits between elapsed and when.
    // OR with SLOT_MASK ensures we consider at least level 0.
    const masked = (elapsed_ticks ^ when_ticks) | SLOT_MASK;

    // Clamp to max wheel duration (in ticks) to prevent overflow
    // MAX_WHEEL_DURATION is in nanoseconds, convert to ticks
    const max_ticks = MAX_WHEEL_DURATION / LEVEL_0_SLOT_NS;
    if (masked >= max_ticks) {
        return NUM_LEVELS; // Overflow level
    }

    // Find the position of the most significant set bit.
    // @clz counts leading zeros in a 64-bit value.
    const leading_zeros = @clz(masked);
    const significant_bit = 63 - leading_zeros;

    // Each level handles BITS_PER_LEVEL (6) bits.
    // Level 0: bits 0-5, Level 1: bits 6-11, etc.
    return significant_bit / BITS_PER_LEVEL;
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

    /// Insert a timer using O(1) bit-based level selection.
    pub fn insert(self: *Self, entry: *TimerEntry) void {
        const entry_deadline = entry.deadline_ns;
        const current_now = self.now_ns;

        // Use bit-based level calculation - O(1) instead of O(NUM_LEVELS)
        const level_idx = levelFor(current_now, entry_deadline);

        if (level_idx >= NUM_LEVELS) {
            // Overflow - timer is beyond wheel capacity
            self.overflow.push(entry);
        } else {
            const slot_idx = Level.slotFor(entry_deadline, level_idx, current_now);
            // Use the new addEntry that maintains occupancy bitfield
            self.levels[level_idx].addEntry(slot_idx, entry);
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
            // Use takeAllFromSlot which updates occupancy bitfield
            const entries = self.levels[0].takeAllFromSlot(current);
            self.appendExpired(&expired_head, &expired_tail, entries);

            current = (current + 1) % SLOTS_PER_LEVEL;

            // Cascade from higher levels when slot wraps
            if (current == 0) {
                self.cascade(1);
            }
        }

        // Check current slot for expired entries
        const slot = &self.levels[0].slots[current];
        var entry = slot.head;
        while (entry) |e| {
            const next = e.next;
            if (e.deadline_ns <= self.now_ns) {
                // Use removeEntry which updates occupancy
                self.levels[0].removeEntry(current, e);
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
        // Use takeAllFromSlot which updates occupancy bitfield
        var entry = level.takeAllFromSlot(slot_idx);
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

    /// Get time until next timer expires (for poll timeout).
    /// Uses occupancy bitfield for O(1) lookup per level.
    pub fn nextExpiration(self: *const Self) ?u64 {
        // Check each level using the occupancy bitfield
        for (0..NUM_LEVELS) |level_idx| {
            const level = &self.levels[level_idx];

            if (!level.hasEntries()) continue;

            // Use O(1) bit lookup to find next occupied slot
            if (level.nextOccupiedSlot(level.current)) |next_slot| {
                // Calculate time until this slot
                const slot_duration = slotDuration(level_idx);
                const slots_until: u64 = if (next_slot >= level.current)
                    next_slot - level.current
                else
                    (SLOTS_PER_LEVEL - level.current) + next_slot;

                // Time until start of that slot
                const time_until = slots_until * slot_duration;

                // For level 0, we can be more precise by checking actual deadlines
                if (level_idx == 0 and slots_until == 0) {
                    // Current slot - find earliest deadline
                    var earliest: ?u64 = null;
                    var entry = level.slots[next_slot].head;
                    while (entry) |e| {
                        if (!e.cancelled) {
                            if (earliest == null or e.deadline_ns < earliest.?) {
                                earliest = e.deadline_ns;
                            }
                        }
                        entry = e.next;
                    }
                    if (earliest) |earliest_ns| {
                        return earliest_ns -| self.now_ns;
                    }
                }

                return time_until;
            }
        }

        // Check overflow list
        if (!self.overflow.isEmpty()) {
            // Find earliest in overflow
            var earliest: ?u64 = null;
            var entry = self.overflow.head;
            while (entry) |e| {
                if (!e.cancelled) {
                    if (earliest == null or e.deadline_ns < earliest.?) {
                        earliest = e.deadline_ns;
                    }
                }
                entry = e.next;
            }
            if (earliest) |earliest_ns| {
                return earliest_ns -| self.now_ns;
            }
        }

        // No timers
        if (self.count > 0) {
            // Timers exist but all might be cancelled
            return LEVEL_0_SLOT_NS;
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

test "levelFor - bit-based level calculation" {
    // Same time = level 0
    try std.testing.expectEqual(@as(usize, 0), levelFor(0, 0));

    // Small delta (within 64ms) = level 0
    try std.testing.expectEqual(@as(usize, 0), levelFor(0, 10 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(usize, 0), levelFor(0, 63 * std.time.ns_per_ms));

    // Delta in level 1 range (64ms - 4s)
    try std.testing.expectEqual(@as(usize, 1), levelFor(0, 100 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(usize, 1), levelFor(0, 1 * std.time.ns_per_s));

    // Delta in level 2 range (4s - 4min)
    try std.testing.expectEqual(@as(usize, 2), levelFor(0, 10 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(usize, 2), levelFor(0, 60 * std.time.ns_per_s));

    // Very large delta = overflow (level >= NUM_LEVELS)
    const huge_delta: u64 = 100 * 24 * 60 * 60 * std.time.ns_per_s; // 100 days
    try std.testing.expect(levelFor(0, huge_delta) >= NUM_LEVELS);
}

test "Level - occupancy bitfield" {
    var level = Level.init();

    // Initially no entries
    try std.testing.expect(!level.hasEntries());
    try std.testing.expectEqual(@as(u64, 0), level.occupied);

    // Create dummy entries
    var entry1 = TimerEntry.init(1000, null, 1);
    var entry2 = TimerEntry.init(2000, null, 2);
    var entry3 = TimerEntry.init(3000, null, 3);

    // Add entries to different slots
    level.addEntry(0, &entry1);
    try std.testing.expect(level.hasEntries());
    try std.testing.expectEqual(@as(u64, 1), level.occupied);

    level.addEntry(5, &entry2);
    try std.testing.expectEqual(@as(u64, 0b100001), level.occupied);

    level.addEntry(63, &entry3);
    try std.testing.expectEqual(@as(u64, 0b100001) | (@as(u64, 1) << 63), level.occupied);

    // Check occupiedCount
    try std.testing.expectEqual(@as(usize, 3), level.occupiedCount());

    // Test nextOccupiedSlot
    try std.testing.expectEqual(@as(?usize, 0), level.nextOccupiedSlot(0));
    try std.testing.expectEqual(@as(?usize, 5), level.nextOccupiedSlot(1));
    try std.testing.expectEqual(@as(?usize, 5), level.nextOccupiedSlot(5));
    try std.testing.expectEqual(@as(?usize, 63), level.nextOccupiedSlot(6));
    // Test wrapping: from slot 62 (past slot 63) should wrap to find slot 0
    try std.testing.expectEqual(@as(?usize, 63), level.nextOccupiedSlot(62));
    // From slot 0 should find slot 0
    try std.testing.expectEqual(@as(?usize, 0), level.nextOccupiedSlot(0));

    // Remove entry and check occupancy updates
    level.removeEntry(0, &entry1);
    try std.testing.expectEqual(@as(u64, 0b100000) | (@as(u64, 1) << 63), level.occupied);
    try std.testing.expectEqual(@as(usize, 2), level.occupiedCount());

    // Take all from slot 5
    _ = level.takeAllFromSlot(5);
    try std.testing.expectEqual(@as(u64, 1) << 63, level.occupied);
    try std.testing.expectEqual(@as(usize, 1), level.occupiedCount());
}

test "Level - nextOccupiedSlot wraparound" {
    var level = Level.init();

    var entry = TimerEntry.init(1000, null, 1);

    // Add entry to slot 10
    level.addEntry(10, &entry);

    // Search from slot 50 should wrap around to find slot 10
    try std.testing.expectEqual(@as(?usize, 10), level.nextOccupiedSlot(50));

    // Search from slot 5 should find 10 directly
    try std.testing.expectEqual(@as(?usize, 10), level.nextOccupiedSlot(5));
}

test "TimerWheel - insert uses bit-based level" {
    var wheel = TimerWheel.init(std.testing.allocator);
    defer wheel.deinit();

    // Insert timers at different durations
    var entry_short = TimerEntry.init(wheel.now() + 10 * std.time.ns_per_ms, null, 1);
    var entry_medium = TimerEntry.init(wheel.now() + 1 * std.time.ns_per_s, null, 2);
    var entry_long = TimerEntry.init(wheel.now() + 60 * std.time.ns_per_s, null, 3);

    wheel.insert(&entry_short);
    wheel.insert(&entry_medium);
    wheel.insert(&entry_long);

    try std.testing.expectEqual(@as(usize, 3), wheel.len());

    // Check that levels have entries via occupancy
    try std.testing.expect(wheel.levels[0].hasEntries()); // short timer
    try std.testing.expect(wheel.levels[1].hasEntries()); // medium timer
    try std.testing.expect(wheel.levels[2].hasEntries()); // long timer
}

test "TimerWheel - nextExpiration uses occupancy bitfield" {
    var wheel = TimerWheel.init(std.testing.allocator);
    defer wheel.deinit();

    // No timers - should return null
    try std.testing.expect(wheel.nextExpiration() == null);

    // Add a timer
    var entry = TimerEntry.init(wheel.now() + 10 * std.time.ns_per_ms, null, 1);
    wheel.insert(&entry);

    // Should have a next expiration
    const next = wheel.nextExpiration();
    try std.testing.expect(next != null);
    try std.testing.expect(next.? <= 10 * std.time.ns_per_ms);
}
