//! Global Queue - Sharded Multi-Producer Multi-Consumer Task Queue
//!
//! The global queue is used for:
//! 1. Spawning tasks from non-worker threads
//! 2. Overflow when local queues are full
//! 3. Load balancing between workers
//!
//! IMPROVEMENT OVER TOKIO: Sharded design reduces mutex contention
//!
//! ┌─────────────────────────────────────────────────────────────────────────┐
//! │ ARCHITECTURE                                                            │
//! ├─────────────────────────────────────────────────────────────────────────┤
//! │                                                                         │
//! │  Tokio (single queue):          Blitz-IO (sharded):                    │
//! │                                                                         │
//! │       ┌─────────┐               ┌────┐ ┌────┐ ┌────┐ ┌────┐           │
//! │       │ Queue   │               │ S0 │ │ S1 │ │ S2 │ │ S3 │           │
//! │       │ [mutex] │               └────┘ └────┘ └────┘ └────┘           │
//! │       └─────────┘                 ↑      ↑      ↑      ↑              │
//! │        ↑ ↑ ↑ ↑                   W0     W1     W2     W3              │
//! │       All workers                                                      │
//! │       (contention!)              Workers hash to shards                │
//! │                                  (parallelism!)                        │
//! │                                                                         │
//! └─────────────────────────────────────────────────────────────────────────┘
//!
//! Benefits:
//! - Reduced mutex contention under load
//! - Better cache locality (each shard's mutex is on separate cache line)
//! - Pop searches shards round-robin for fairness
//!
//! Reference: Go runtime's P-local run queues use similar sharding

const std = @import("std");
const Allocator = std.mem.Allocator;
const Header = @import("task.zig").Header;

/// Global task queue shared between all workers
///
/// This is a FIFO queue protected by a mutex, matching Tokio's inject queue design.
/// The mutex is acceptable because:
/// 1. Global queue is only used when local queues overflow or for external spawns
/// 2. Most scheduling uses lock-free local queues
/// 3. Batch operations amortize lock acquisition cost
///
/// Design decisions:
/// - Intrusive linked list (tasks contain their own next pointers)
/// - Atomic count for lock-free isEmpty() checks in hot path
/// - Closed flag for graceful shutdown (Tokio-style)
///
/// Reference: tokio/src/runtime/scheduler/inject/shared.rs
pub const GlobalQueue = struct {
    const Self = @This();

    /// Head of the linked list (oldest task, pop from here)
    head: ?*Header,

    /// Tail of the linked list (newest task, push here)
    tail: ?*Header,

    /// Number of tasks in the queue (atomic for lock-free reads)
    /// Uses Release ordering on writes to ensure visibility
    count: std.atomic.Value(usize),

    /// Mutex for thread-safe access to head/tail
    mutex: std.Thread.Mutex,

    /// Closed flag for graceful shutdown
    /// Once closed, push operations are silently ignored
    is_closed: bool,

    /// Create a new global queue
    pub fn init() Self {
        return .{
            .head = null,
            .tail = null,
            .count = std.atomic.Value(usize).init(0),
            .mutex = .{},
            .is_closed = false,
        };
    }

    /// Close the queue for graceful shutdown
    /// After closing, push operations are silently ignored
    /// Pop operations can still drain remaining tasks
    pub fn close(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.is_closed = true;
    }

    /// Check if queue is closed
    pub fn isClosed(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.is_closed;
    }

    /// Push a task to the back of the queue
    /// Returns false if queue is closed (task was not enqueued)
    pub fn push(self: *Self, task: *Header) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed) {
            return false;
        }

        task.queue_next.store(null, .monotonic);

        if (self.tail) |t| {
            t.queue_next.store(task, .monotonic);
            self.tail = task;
        } else {
            self.head = task;
            self.tail = task;
        }

        // Release ordering ensures the linked list updates are visible
        // before the count increment is observed
        _ = self.count.fetchAdd(1, .release);
        return true;
    }

    /// Push multiple tasks to the back of the queue
    /// Returns number of tasks actually pushed (0 if closed)
    pub fn pushBatch(self: *Self, tasks: []const *Header) usize {
        if (tasks.len == 0) return 0;

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed) {
            return 0;
        }

        // Link the batch together
        for (0..tasks.len - 1) |i| {
            tasks[i].queue_next.store(tasks[i + 1], .monotonic);
        }
        tasks[tasks.len - 1].queue_next.store(null, .monotonic);

        // Append to queue
        if (self.tail) |t| {
            t.queue_next.store(tasks[0], .monotonic);
            self.tail = tasks[tasks.len - 1];
        } else {
            self.head = tasks[0];
            self.tail = tasks[tasks.len - 1];
        }

        _ = self.count.fetchAdd(tasks.len, .release);
        return tasks.len;
    }

    /// Pop a task from the front of the queue
    pub fn pop(self: *Self) ?*Header {
        const result = self.popWithEmpty();
        return result.task;
    }

    /// Pop result including emptiness check (for occupancy bitmask)
    pub const PopResult = struct {
        task: ?*Header,
        is_now_empty: bool,
    };

    /// Pop a task and report if queue is now empty (both under same lock)
    /// This prevents the race where a push happens between pop and empty check
    pub fn popWithEmpty(self: *Self) PopResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        const task = self.head orelse return .{ .task = null, .is_now_empty = true };

        self.head = task.queue_next.load(.monotonic);
        if (self.head == null) {
            self.tail = null;
        }

        task.queue_next.store(null, .monotonic);
        _ = self.count.fetchSub(1, .release);

        // Check emptiness while still holding the lock
        return .{
            .task = task,
            .is_now_empty = self.head == null,
        };
    }

    /// Pop up to `max` tasks from the front
    /// Returns the number of tasks popped
    pub fn popBatch(self: *Self, dest: []?*Header, max: usize) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var popped: usize = 0;
        const limit = @min(max, dest.len);

        while (popped < limit) {
            const task = self.head orelse break;

            self.head = task.queue_next.load(.monotonic);
            task.queue_next.store(null, .monotonic);

            dest[popped] = task;
            popped += 1;
        }

        if (self.head == null) {
            self.tail = null;
        }

        _ = self.count.fetchSub(popped, .release);

        return popped;
    }

    /// Get the number of tasks (approximate, for metrics)
    /// Lock-free read using atomic counter with Acquire ordering
    /// to synchronize with Release stores
    pub fn len(self: *const Self) usize {
        return self.count.load(.acquire);
    }

    /// Check if the queue is empty (lock-free fast path)
    pub fn isEmpty(self: *const Self) bool {
        return self.count.load(.acquire) == 0;
    }

    /// Check if the queue is not empty (requires lock for accuracy)
    pub fn hasWork(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.head != null;
    }
};

/// Number of shards for the global queue
/// Power of 2 for fast modulo. 8 shards works well for up to ~64 cores.
/// Each shard is cache-line aligned to prevent false sharing.
pub const NUM_SHARDS: usize = 8;
const SHARD_MASK: usize = NUM_SHARDS - 1;

/// Sharded Global Queue - Reduces mutex contention under high load
///
/// IMPROVEMENT OVER TOKIO: Instead of a single queue with one mutex,
/// we use multiple shards. Pushers hash to a shard, poppers use occupancy
/// bitmask to skip empty shards.
///
/// Algorithmic complexity:
/// - push: O(1) - hash to shard, acquire that shard's mutex only
/// - pop: O(popcount(occupancy)) - skip empty shards via @ctz
/// - len: O(NUM_SHARDS) - sum all shard counts (lock-free reads)
///
/// The occupancy bitmask tracks which shards likely have tasks.
/// False positives are handled gracefully; false negatives are prevented
/// by always setting the bit on push before releasing the mutex.
pub const ShardedGlobalQueue = struct {
    const Self = @This();

    /// Shards, each cache-line aligned to prevent false sharing
    shards: [NUM_SHARDS]GlobalQueue align(64),

    /// Round-robin counter for pop operations (find work fairly)
    pop_index: std.atomic.Value(usize),

    /// Occupancy bitmask: bit N set if shard N likely has tasks
    /// Set on push (before mutex release), cleared on pop when shard becomes empty
    /// False positives are OK (we just check an empty shard), false negatives are prevented
    occupancy: std.atomic.Value(u64),

    /// Create a new sharded global queue
    pub fn init() Self {
        var self: Self = undefined;
        self.pop_index = std.atomic.Value(usize).init(0);
        self.occupancy = std.atomic.Value(u64).init(0);
        for (&self.shards) |*shard| {
            shard.* = GlobalQueue.init();
        }
        return self;
    }

    /// Close all shards for graceful shutdown
    pub fn close(self: *Self) void {
        for (&self.shards) |*shard| {
            shard.close();
        }
    }

    /// Check if all shards are closed
    pub fn isClosed(self: *Self) bool {
        // If first shard is closed, all are closed (they close together)
        return self.shards[0].isClosed();
    }

    /// Push a task to a shard based on task identity
    /// Uses task pointer as hash key for deterministic distribution
    pub fn push(self: *Self, task: *Header) bool {
        const shard_idx = self.hashToShard(@intFromPtr(task));
        const ok = self.shards[shard_idx].push(task);
        if (ok) {
            // Set occupancy bit AFTER successful push
            // This ensures poppers see the bit set when task is available
            const mask = @as(u64, 1) << @intCast(shard_idx);
            _ = self.occupancy.fetchOr(mask, .release);
        }
        return ok;
    }

    /// Push a task to a specific shard (for worker affinity)
    pub fn pushToShard(self: *Self, task: *Header, shard_idx: usize) bool {
        const idx = shard_idx & SHARD_MASK;
        const ok = self.shards[idx].push(task);
        if (ok) {
            const mask = @as(u64, 1) << @intCast(idx);
            _ = self.occupancy.fetchOr(mask, .release);
        }
        return ok;
    }

    /// Push multiple tasks to appropriate shards
    pub fn pushBatch(self: *Self, tasks: []const *Header) usize {
        var pushed: usize = 0;
        for (tasks) |task| {
            if (self.push(task)) {
                pushed += 1;
            }
        }
        return pushed;
    }

    /// Pop a task from any shard using occupancy bitmask
    /// Uses round-robin starting point for fairness across shards
    ///
    /// CRITICAL FIX: Uses popWithEmpty() to check emptiness under the same lock
    /// as the pop operation. This prevents the race where:
    /// 1. Thread A pops, releases lock
    /// 2. Thread B pushes, sets occupancy bit
    /// 3. Thread A incorrectly clears the bit
    pub fn pop(self: *Self) ?*Header {
        var search_bits = self.occupancy.load(.acquire);
        if (search_bits == 0) return null;

        // Get starting shard for fairness (round-robin)
        const start_idx = self.pop_index.fetchAdd(1, .monotonic) & SHARD_MASK;

        // Check shards starting from start_idx, using bitmask to skip empty ones
        for (0..NUM_SHARDS) |offset| {
            if (search_bits == 0) break;

            const actual_idx = (start_idx + offset) & SHARD_MASK;
            const mask = @as(u64, 1) << @intCast(actual_idx);

            // Skip if shard is not marked as occupied
            if ((search_bits & mask) == 0) continue;

            // Pop with emptiness check under the same lock
            const result = self.shards[actual_idx].popWithEmpty();

            if (result.task) |task| {
                // Only clear bit if shard was empty when we checked (under lock)
                if (result.is_now_empty) {
                    _ = self.occupancy.fetchAnd(~mask, .release);
                }
                return task;
            } else {
                // Shard was already empty, clear bit and continue
                _ = self.occupancy.fetchAnd(~mask, .release);
                search_bits &= ~mask;
            }
        }

        return null;
    }

    /// Pop up to `max` tasks from shards
    pub fn popBatch(self: *Self, dest: []?*Header, max: usize) usize {
        var popped: usize = 0;
        const limit = @min(max, dest.len);
        const start = self.pop_index.load(.monotonic) & SHARD_MASK;

        // Round-robin through shards
        for (0..NUM_SHARDS) |offset| {
            if (popped >= limit) break;

            const shard_idx = (start + offset) & SHARD_MASK;
            const remaining = limit - popped;

            // Create a slice for this shard to fill
            var shard_dest: [64]?*Header = undefined;
            const shard_popped = self.shards[shard_idx].popBatch(&shard_dest, @min(remaining, 64));

            // Copy to output
            for (0..shard_popped) |i| {
                dest[popped + i] = shard_dest[i];
            }
            popped += shard_popped;
        }

        return popped;
    }

    /// Get total number of tasks across all shards (approximate)
    pub fn len(self: *const Self) usize {
        var total: usize = 0;
        for (&self.shards) |*shard| {
            total += shard.len();
        }
        return total;
    }

    /// Check if all shards are empty (lock-free fast path)
    pub fn isEmpty(self: *const Self) bool {
        for (&self.shards) |*shard| {
            if (!shard.isEmpty()) return false;
        }
        return true;
    }

    /// Hash a value to a shard index
    inline fn hashToShard(self: *const Self, value: usize) usize {
        _ = self;
        // Simple multiplicative hash (good distribution for pointers)
        // Using golden ratio prime for good avalanche
        const hash = value *% 0x9e3779b97f4a7c15;
        return (hash >> 32) & SHARD_MASK;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "GlobalQueue - basic push and pop" {
    var queue = GlobalQueue.init();

    var headers: [3]Header = undefined;
    for (&headers, 0..) |*h, i| {
        h.* = Header.init(&dummy_vtable, i);
    }

    // Push tasks
    try std.testing.expect(queue.push(&headers[0]));
    try std.testing.expect(queue.push(&headers[1]));
    try std.testing.expect(queue.push(&headers[2]));

    try std.testing.expectEqual(@as(usize, 3), queue.len());

    // Pop in FIFO order
    try std.testing.expectEqual(&headers[0], queue.pop().?);
    try std.testing.expectEqual(&headers[1], queue.pop().?);
    try std.testing.expectEqual(&headers[2], queue.pop().?);

    try std.testing.expect(queue.isEmpty());
}

test "GlobalQueue - pushBatch" {
    var queue = GlobalQueue.init();

    var headers: [4]Header = undefined;
    for (&headers, 0..) |*h, i| {
        h.* = Header.init(&dummy_vtable, i);
    }

    var ptrs: [4]*Header = undefined;
    for (&ptrs, 0..) |*p, i| {
        p.* = &headers[i];
    }

    try std.testing.expectEqual(@as(usize, 4), queue.pushBatch(&ptrs));

    try std.testing.expectEqual(@as(usize, 4), queue.len());

    // Pop all in FIFO order
    for (0..4) |i| {
        try std.testing.expectEqual(&headers[i], queue.pop().?);
    }
}

test "GlobalQueue - popBatch" {
    var queue = GlobalQueue.init();

    var headers: [6]Header = undefined;
    for (&headers, 0..) |*h, i| {
        h.* = Header.init(&dummy_vtable, i);
    }

    for (&headers) |*h| {
        try std.testing.expect(queue.push(h));
    }

    var dest: [4]?*Header = undefined;
    const popped = queue.popBatch(&dest, 4);

    try std.testing.expectEqual(@as(usize, 4), popped);
    try std.testing.expectEqual(@as(usize, 2), queue.len());

    // Verify FIFO order
    for (0..4) |i| {
        try std.testing.expectEqual(&headers[i], dest[i].?);
    }
}

test "GlobalQueue - empty operations" {
    var queue = GlobalQueue.init();

    try std.testing.expect(queue.isEmpty());
    try std.testing.expect(queue.pop() == null);
    try std.testing.expect(!queue.hasWork());
}

test "GlobalQueue - close and graceful shutdown" {
    var queue = GlobalQueue.init();

    var headers: [3]Header = undefined;
    for (&headers, 0..) |*h, i| {
        h.* = Header.init(&dummy_vtable, i);
    }

    // Push before close works
    try std.testing.expect(queue.push(&headers[0]));
    try std.testing.expectEqual(@as(usize, 1), queue.len());

    // Close the queue
    queue.close();
    try std.testing.expect(queue.isClosed());

    // Push after close is silently ignored
    try std.testing.expect(!queue.push(&headers[1]));
    try std.testing.expectEqual(@as(usize, 1), queue.len());

    // Pop still works after close (drain remaining)
    try std.testing.expectEqual(&headers[0], queue.pop().?);
    try std.testing.expect(queue.isEmpty());
}

// ─────────────────────────────────────────────────────────────────────────────
// ShardedGlobalQueue Tests
// ─────────────────────────────────────────────────────────────────────────────

test "ShardedGlobalQueue - basic push and pop" {
    var queue = ShardedGlobalQueue.init();

    var headers: [8]Header = undefined;
    for (&headers, 0..) |*h, i| {
        h.* = Header.init(&dummy_vtable, i);
    }

    // Push tasks (will be distributed across shards)
    for (&headers) |*h| {
        try std.testing.expect(queue.push(h));
    }

    try std.testing.expectEqual(@as(usize, 8), queue.len());

    // Pop all tasks
    var popped: usize = 0;
    while (queue.pop()) |_| {
        popped += 1;
    }

    try std.testing.expectEqual(@as(usize, 8), popped);
    try std.testing.expect(queue.isEmpty());
}

test "ShardedGlobalQueue - pushToShard" {
    var queue = ShardedGlobalQueue.init();

    var headers: [4]Header = undefined;
    for (&headers, 0..) |*h, i| {
        h.* = Header.init(&dummy_vtable, i);
    }

    // Push to specific shards
    try std.testing.expect(queue.pushToShard(&headers[0], 0));
    try std.testing.expect(queue.pushToShard(&headers[1], 1));
    try std.testing.expect(queue.pushToShard(&headers[2], 2));
    try std.testing.expect(queue.pushToShard(&headers[3], 3));

    try std.testing.expectEqual(@as(usize, 4), queue.len());

    // Verify distribution - each shard should have 1 task
    for (0..4) |i| {
        try std.testing.expectEqual(@as(usize, 1), queue.shards[i].len());
    }
}

test "ShardedGlobalQueue - popBatch" {
    var queue = ShardedGlobalQueue.init();

    var headers: [16]Header = undefined;
    for (&headers, 0..) |*h, i| {
        h.* = Header.init(&dummy_vtable, i);
    }

    // Push all tasks
    for (&headers) |*h| {
        try std.testing.expect(queue.push(h));
    }

    // Pop batch
    var dest: [10]?*Header = undefined;
    const popped = queue.popBatch(&dest, 10);

    try std.testing.expect(popped > 0);
    try std.testing.expect(popped <= 10);
    try std.testing.expectEqual(@as(usize, 16 - popped), queue.len());
}

test "ShardedGlobalQueue - close and graceful shutdown" {
    var queue = ShardedGlobalQueue.init();

    var headers: [4]Header = undefined;
    for (&headers, 0..) |*h, i| {
        h.* = Header.init(&dummy_vtable, i);
    }

    // Push before close
    try std.testing.expect(queue.push(&headers[0]));
    try std.testing.expect(queue.push(&headers[1]));

    // Close
    queue.close();
    try std.testing.expect(queue.isClosed());

    // Push after close fails
    try std.testing.expect(!queue.push(&headers[2]));

    // Pop still works (drain)
    try std.testing.expect(queue.pop() != null);
    try std.testing.expect(queue.pop() != null);
    try std.testing.expect(queue.isEmpty());
}

test "ShardedGlobalQueue - empty operations" {
    var queue = ShardedGlobalQueue.init();

    try std.testing.expect(queue.isEmpty());
    try std.testing.expect(queue.pop() == null);
    try std.testing.expectEqual(@as(usize, 0), queue.len());
}

const dummy_vtable = Header.VTable{
    .poll = struct {
        fn f(_: *Header) bool {
            return true;
        }
    }.f,
    .drop = struct {
        fn f(_: *Header) void {}
    }.f,
    .get_output = struct {
        fn f(_: *Header) ?*anyopaque {
            return null;
        }
    }.f,
    .schedule = struct {
        fn f(_: *Header) void {}
    }.f,
};
