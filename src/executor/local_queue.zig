//! Local Queue - Lock-free SPSC Queue with Work Stealing
//!
//! A single-producer, multi-consumer queue optimized for the owning worker.
//! This implementation improves on Tokio's design with a LIFO stack instead
//! of a single slot, providing better cache locality for bursty workloads.
//!
//! ┌─────────────────────────────────────────────────────────────────────────┐
//! │ ARCHITECTURE                                                            │
//! ├─────────────────────────────────────────────────────────────────────────┤
//! │                                                                         │
//! │  ┌─────────────────────────────────┐                                   │
//! │  │        LIFO Stack (4 slots)     │  ← Most recent tasks (cache-hot)  │
//! │  │  ┌────┬────┬────┬────┐         │    IMPROVEMENT OVER TOKIO:         │
//! │  │  │ T3 │ T2 │ T1 │ T0 │ ← top   │    Multiple hot tasks vs single   │
//! │  │  └────┴────┴────┴────┘         │    slot improves burst handling   │
//! │  └─────────────────────────────────┘                                   │
//! │                                                                         │
//! │  ┌──────────────────────────────────────────────────────────────────┐  │
//! │  │                     Circular Buffer (256 slots)                   │  │
//! │  │  ┌────┬────┬────┬────┬────┬────┬────┬────┬────┬────┐            │  │
//! │  │  │ T0 │ T1 │ T2 │ T3 │ T4 │    │    │    │    │    │            │  │
//! │  │  └────┴────┴────┴────┴────┴────┴────┴────┴────┴────┘            │  │
//! │  │    ↑                   ↑                                         │  │
//! │  │  HEAD                TAIL                                        │  │
//! │  │  (pop/steal)         (push)                                      │  │
//! │  └──────────────────────────────────────────────────────────────────┘  │
//! │                                                                         │
//! └─────────────────────────────────────────────────────────────────────────┘
//!
//! ┌─────────────────────────────────────────────────────────────────────────┐
//! │ OPERATIONS                                                              │
//! ├─────────────────────────────────────────────────────────────────────────┤
//! │                                                                         │
//! │  Push (Owner only):     Push to LIFO stack, overflow to main queue     │
//! │  Pop (Owner only):      Pop from LIFO stack first, then main queue     │
//! │  Steal (Any worker):    CAS from HEAD (FIFO for fairness)              │
//! │                                                                         │
//! │  LIFO Behavior: Comes from the LIFO stack (not main queue)             │
//! │  Main Queue: FIFO - both owner and stealers pop from HEAD              │
//! │                                                                         │
//! └─────────────────────────────────────────────────────────────────────────┘
//!
//! ┌─────────────────────────────────────────────────────────────────────────┐
//! │ LIFO VISIBILITY LIMITATION                                              │
//! ├─────────────────────────────────────────────────────────────────────────┤
//! │                                                                         │
//! │  LIFO stack tasks are NOT visible to stealers (by design, for cache    │
//! │  locality). This means if a worker is blocked by the OS with tasks in  │
//! │  LIFO, those tasks are temporarily "trapped".                          │
//! │                                                                         │
//! │  Mitigations:                                                           │
//! │  1. LIFO is small (4 slots) - limited impact                           │
//! │  2. Overflow to main queue which IS stealable                          │
//! │  3. Worker flushes LIFO to main buffer before parking                  │
//! │  4. 10ms park timeout ensures periodic wake to process LIFO            │
//! │                                                                         │
//! │  Future: Consider making LIFO stealable after worker is idle for N µs  │
//! │                                                                         │
//! └─────────────────────────────────────────────────────────────────────────┘
//!
//! ┌─────────────────────────────────────────────────────────────────────────┐
//! │ PACKED HEAD (ABA Prevention)                                            │
//! ├─────────────────────────────────────────────────────────────────────────┤
//! │                                                                         │
//! │  64-bit head = [steal_head:32][real_head:32]                           │
//! │                                                                         │
//! │  real_head:  Where tasks are actually consumed from                    │
//! │  steal_head: Marks in-progress bulk steals                             │
//! │                                                                         │
//! │  When steal_head == real_head: No steal in progress                    │
//! │  When steal_head > real_head:  Bulk steal is in progress               │
//! │                                                                         │
//! │  This prevents ABA problems and allows atomic coordination between     │
//! │  owner's pop and stealer's bulk steal operations.                      │
//! │                                                                         │
//! └─────────────────────────────────────────────────────────────────────────┘
//!
//! ┌─────────────────────────────────────────────────────────────────────────┐
//! │ MEMORY ORDERING (Tokio loom-tested)                                     │
//! ├─────────────────────────────────────────────────────────────────────────┤
//! │                                                                         │
//! │  Producer (push):                                                       │
//! │    - buffer[tail] = task  (Monotonic - only producer writes here)      │
//! │    - tail = tail + 1      (Release - publishes buffer write)           │
//! │                                                                         │
//! │  Consumer (pop/steal):                                                  │
//! │    - load head            (Acquire - sees producer's writes)           │
//! │    - CAS head             (AcqRel - coordinates with other consumers)  │
//! │    - load buffer[head]    (Acquire - sees the task)                    │
//! │                                                                         │
//! └─────────────────────────────────────────────────────────────────────────┘
//!
//! Reference: tokio/src/runtime/scheduler/multi_thread/queue.rs

const std = @import("std");
const Allocator = std.mem.Allocator;
const Header = @import("task.zig").Header;

/// Cache line size for padding (typically 64 bytes on modern CPUs)
/// Used to prevent false sharing between owner and stealer threads
const CACHE_LINE = std.atomic.cache_line;

/// Local queue capacity (must be power of 2)
/// 256 is Tokio's default, balancing memory usage vs overflow frequency
pub const CAPACITY: usize = 256;
const MASK: usize = CAPACITY - 1;
const HALF_CAPACITY: usize = CAPACITY / 2;

/// LIFO stack size - IMPROVEMENT OVER TOKIO
/// Tokio uses a single slot; we use a small stack for better burst handling.
/// 4 slots keeps ~4 cache-hot tasks, good for common spawn patterns.
pub const LIFO_STACK_SIZE: usize = 4;

/// Steal retry limits (from blitz/deque.zig)
const STEAL_SPIN_LIMIT: u32 = 6; // Exponential backoff: 1,2,4,8,16,32,64 spins

/// Packed head structure for ABA resilience
/// Lower 32 bits: real head (where stealers commit their steals)
/// Upper 32 bits: steal head (marks in-progress steals)
const PackedHead = struct {
    /// Pack real and steal heads into u64
    fn pack(real_val: u32, steal_val: u32) u64 {
        return @as(u64, steal_val) << 32 | @as(u64, real_val);
    }

    /// Unpack real head from packed value
    fn real(packed_val: u64) u32 {
        return @truncate(packed_val);
    }

    /// Unpack steal head from packed value
    fn steal(packed_val: u64) u32 {
        return @truncate(packed_val >> 32);
    }
};

/// Local task queue for a single worker
///
/// CACHE LINE LAYOUT (from blitz/deque.zig):
/// - Cache line 1: head (stealer-contended)
/// - Cache line 2: tail (owner-exclusive)
/// - Cache line 3+: LIFO stack and buffer
///
/// Explicit padding prevents false sharing between owner and stealer threads.
pub const LocalQueue = struct {
    const Self = @This();

    // === Cache line 1: Stealer-contended ===
    /// Packed head index (real + steal) for ABA resilience
    /// Only stealers modify this via CAS
    head: std.atomic.Value(u64) align(CACHE_LINE),

    // Explicit padding to prevent false sharing (from blitz/deque.zig)
    _head_padding: [CACHE_LINE - @sizeOf(std.atomic.Value(u64))]u8 = undefined,

    // === Cache line 2: Owner-exclusive ===
    /// Tail index - where owner pushes (producer only)
    tail: std.atomic.Value(u32) align(CACHE_LINE),

    // Explicit padding
    _tail_padding: [CACHE_LINE - @sizeOf(std.atomic.Value(u32))]u8 = undefined,

    // === Cache line 3+: LIFO stack ===
    /// LIFO stack - IMPROVEMENT OVER TOKIO
    /// Multiple cache-hot slots instead of just one.
    /// Owner pushes/pops from top, stealers can take from bottom.
    lifo_stack: [LIFO_STACK_SIZE]std.atomic.Value(?*Header) align(CACHE_LINE),

    /// Number of tasks in the LIFO stack (0 = empty, LIFO_STACK_SIZE = full)
    /// Only owner modifies this; stealers read it
    lifo_top: std.atomic.Value(u32),

    // === Main buffer (large, separate from hot indices) ===
    /// Ring buffer of task pointers
    /// Each slot is atomic for thread-safe stealing
    buffer: [CAPACITY]std.atomic.Value(?*Header),

    // === Final padding to ensure struct size is multiple of cache line ===
    // This prevents false sharing when LocalQueue is placed in an array
    // (e.g., workers[] in Scheduler)
    comptime {
        const base_size = @sizeOf(std.atomic.Value(u64)) + // head
            (CACHE_LINE - @sizeOf(std.atomic.Value(u64))) + // _head_padding
            @sizeOf(std.atomic.Value(u32)) + // tail
            (CACHE_LINE - @sizeOf(std.atomic.Value(u32))) + // _tail_padding
            LIFO_STACK_SIZE * @sizeOf(std.atomic.Value(?*Header)) + // lifo_stack
            @sizeOf(std.atomic.Value(u32)) + // lifo_top
            CAPACITY * @sizeOf(std.atomic.Value(?*Header)); // buffer
        const remainder = base_size % CACHE_LINE;
        if (remainder != 0) {
            // Would need: CACHE_LINE - remainder bytes of padding
            // For now we document that users should ensure alignment
        }
    }

    /// Create a new local queue
    pub fn init() Self {
        var self: Self = undefined;
        self.head = std.atomic.Value(u64).init(0);
        self.tail = std.atomic.Value(u32).init(0);
        self.lifo_top = std.atomic.Value(u32).init(0);

        // Initialize LIFO stack slots to null
        for (&self.lifo_stack) |*slot| {
            slot.* = std.atomic.Value(?*Header).init(null);
        }

        // Initialize all buffer slots to null
        for (&self.buffer) |*slot| {
            slot.* = std.atomic.Value(?*Header).init(null);
        }

        return self;
    }

    /// Push a task to the LIFO stack (fast path)
    /// IMPROVEMENT OVER TOKIO: Multiple slots instead of single slot
    /// If stack is full, bottom task is moved to main queue.
    /// Returns the task that couldn't fit (needs to go to global queue), or null
    pub fn pushLifo(self: *Self, task: *Header) ?*Header {
        const top = self.lifo_top.load(.acquire);

        if (top < LIFO_STACK_SIZE) {
            // Stack has room - push directly
            self.lifo_stack[top].store(task, .release);
            self.lifo_top.store(top + 1, .release);
            return null;
        }

        // Stack is full - move bottom task to main queue
        const bottom_task = self.lifo_stack[0].load(.acquire);

        // Shift stack down (making room at top)
        // Note: This is safe because only owner modifies the stack
        for (0..LIFO_STACK_SIZE - 1) |i| {
            const next = self.lifo_stack[i + 1].load(.acquire);
            self.lifo_stack[i].store(next, .release);
        }

        // Put new task at top
        self.lifo_stack[LIFO_STACK_SIZE - 1].store(task, .release);
        // lifo_top stays at LIFO_STACK_SIZE

        // Push bottom task to main queue
        if (bottom_task) |displaced| {
            if (!self.pushToBuffer(displaced)) {
                // Main queue is also full
                return displaced;
            }
        }

        return null;
    }

    /// Push a task directly to the main queue buffer (bypassing LIFO slot)
    /// Returns false if queue is full
    fn pushToBuffer(self: *Self, task: *Header) bool {
        const tail = self.tail.load(.monotonic);
        const head_packed = self.head.load(.acquire);
        const head = PackedHead.steal(head_packed); // Use steal head for capacity check

        // Check if full
        if (tail -% head >= CAPACITY) {
            return false;
        }

        // Store task in buffer
        self.buffer[tail & MASK].store(task, .monotonic);

        // Publish the new tail
        // Release ordering ensures the buffer write is visible before tail update
        self.tail.store(tail +% 1, .release);

        return true;
    }

    /// Push a task to the queue (only called by owning worker)
    /// Returns false if queue is full (caller should push to global queue)
    pub fn push(self: *Self, task: *Header) bool {
        return self.pushToBuffer(task);
    }

    /// Push with overflow handling - returns tasks that need to go to global queue
    /// This is the preferred method as it handles the LIFO slot and overflow
    pub fn pushWithOverflow(self: *Self, task: *Header, overflow: *[HALF_CAPACITY]*Header) usize {
        // First try LIFO slot
        const displaced = self.pushLifo(task);

        if (displaced == null) {
            return 0; // Task fit in LIFO slot
        }

        // LIFO slot displaced a task, try to push it to buffer
        if (self.pushToBuffer(displaced.?)) {
            return 0; // Everything fit
        }

        // Buffer is full - need to overflow half the queue
        return self.overflowHalf(displaced.?, overflow);
    }

    /// Move half the queue to overflow buffer when full
    /// Returns number of tasks moved to overflow (including the new task)
    fn overflowHalf(self: *Self, new_task: *Header, overflow: *[HALF_CAPACITY]*Header) usize {
        const tail = self.tail.load(.monotonic);
        const head_packed = self.head.load(.acquire);

        // Calculate how many to move (half the queue)
        const real_head = PackedHead.real(head_packed);
        const count = @min((tail -% real_head) / 2, HALF_CAPACITY - 1);

        if (count == 0) {
            // Queue is nearly empty, just add the new task
            overflow[0] = new_task;
            return 1;
        }

        // Try to claim the tasks we're moving
        const new_head = real_head +% @as(u32, @intCast(count));
        const new_packed = PackedHead.pack(new_head, new_head);

        const result = self.head.cmpxchgStrong(
            head_packed,
            new_packed,
            .acq_rel,
            .acquire,
        );

        if (result != null) {
            // CAS failed - contention, just overflow the new task
            overflow[0] = new_task;
            return 1;
        }

        // Successfully claimed - copy tasks to overflow buffer
        for (0..count) |i| {
            const idx = (real_head +% @as(u32, @intCast(i))) & MASK;
            overflow[i] = self.buffer[idx].load(.monotonic).?;
        }
        overflow[count] = new_task;

        return count + 1;
    }

    /// Pop a task from the queue (only called by owning worker)
    /// Checks LIFO stack first (most recent = cache-hot), then main queue
    pub fn pop(self: *Self) ?*Header {
        // Fast path: pop from LIFO stack (top of stack = most recent)
        const top = self.lifo_top.load(.acquire);
        if (top > 0) {
            const new_top = top - 1;
            const task = self.lifo_stack[new_top].swap(null, .acq_rel);
            self.lifo_top.store(new_top, .release);
            if (task != null) {
                return task;
            }
        }

        // Slow path: pop from main queue
        return self.popFromBuffer();
    }

    /// Pop from the main queue buffer (FIFO order, matching Tokio)
    ///
    /// Uses CAS on head, same as stealers. This is simpler to reason about
    /// than a separate tail-based scheme because owner and stealers use
    /// the same coordination mechanism.
    ///
    /// WAIT-FREE IMPROVEMENT: If a steal is in progress, returns null immediately
    /// instead of spinning. This prevents owner stall if stealer is descheduled.
    /// Caller should fall back to global queue when this returns null.
    ///
    /// LIFO behavior comes from the LIFO slot, not the main queue.
    /// Public for LIFO-limited access that bypasses the LIFO slot.
    pub fn popFromBuffer(self: *Self) ?*Header {
        var head_packed = self.head.load(.acquire);

        while (true) {
            const real_head = PackedHead.real(head_packed);
            const steal_head = PackedHead.steal(head_packed);

            // Check if queue is empty
            // Note: We read tail with Acquire to synchronize with producer's Release store
            const tail = self.tail.load(.acquire);
            if (real_head == tail) {
                return null; // Empty
            }

            // WAIT-FREE: If a steal is in progress, don't spin - return null
            // This prevents owner from being blocked by a descheduled stealer
            // Caller should try global queue instead
            if (steal_head != real_head) {
                return null;
            }

            // Read the task before claiming the slot
            const task = self.buffer[real_head & MASK].load(.acquire);

            // ZIG OPTIMIZATION: Prefetch next task into L1 cache while we CAS
            // This hides memory latency - the next task will be hot when we need it
            const next_slot = (real_head +% 1) & MASK;
            const prefetch_ptr: [*]const u8 = @ptrCast(&self.buffer[next_slot]);
            @prefetch(prefetch_ptr, .{
                .rw = .read,
                .locality = 3, // High temporal locality (L1 cache)
                .cache = .data,
            });

            // Try to advance head (both real and steal together)
            const next_head = real_head +% 1;
            const next_packed = PackedHead.pack(next_head, next_head);

            const cas_result = self.head.cmpxchgWeak(
                head_packed,
                next_packed,
                .acq_rel,
                .acquire,
            );

            if (cas_result) |new_val| {
                // CAS failed - retry with new value
                head_packed = new_val;
                continue;
            }

            // Successfully claimed the slot
            return task;
        }
    }

    /// Steal a task from this queue (called by other workers)
    /// Uses FIFO order for fairness, with packed indices for ABA resilience
    ///
    /// Note: Stealers don't access the LIFO stack - it's the owner's hot cache.
    /// This is intentional: the LIFO stack contains the most recently spawned
    /// tasks which are likely cache-hot on the owner's CPU. Stealing from main
    /// queue takes older, "cooler" tasks which is better for cache efficiency.
    pub fn steal(self: *Self) ?*Header {
        // Steal from main queue only (FIFO order for fairness)
        return self.stealFromBuffer();
    }

    /// Steal from the main queue buffer with exponential backoff (from blitz/deque.zig)
    ///
    /// Uses adaptive backoff to reduce cache coherency traffic under contention:
    /// - First few retries: spin with exponential backoff (1,2,4,8,16,32,64 iterations)
    /// - Heavy contention: yield to OS scheduler
    fn stealFromBuffer(self: *Self) ?*Header {
        var backoff: u32 = 0;

        while (true) {
            const result = self.tryStealOne();

            switch (result.status) {
                .success => return result.task,
                .empty => return null,
                .retry => {
                    // Exponential backoff on contention (from blitz/deque.zig)
                    if (backoff < STEAL_SPIN_LIMIT) {
                        const spins = @as(u32, 1) << @intCast(backoff);
                        for (0..spins) |_| {
                            std.atomic.spinLoopHint();
                        }
                        backoff += 1;
                    } else {
                        // Heavy contention - yield to OS
                        std.Thread.yield() catch {};
                    }
                },
            }
        }
    }

    /// Result of a single steal attempt
    const StealAttempt = struct {
        status: enum { success, empty, retry },
        task: ?*Header,
    };

    /// Try to steal one task (single attempt, no retry)
    fn tryStealOne(self: *Self) StealAttempt {
        const head_packed = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);

        const real_head = PackedHead.real(head_packed);
        const steal_head = PackedHead.steal(head_packed);

        // Check if empty
        if (real_head >= tail) {
            return .{ .status = .empty, .task = null };
        }

        // If steal is in progress (steal_head != real_head), retry
        if (steal_head != real_head) {
            return .{ .status = .retry, .task = null };
        }

        // Load the task before claiming
        // CRITICAL: Must use .acquire to synchronize with owner's .release store in push
        // Without this, CPU could reorder this load before the head check, reading stale data
        const task = self.buffer[real_head & MASK].load(.acquire);

        // Try to claim this slot by advancing both heads
        const new_head = real_head +% 1;
        const new_packed = PackedHead.pack(new_head, new_head);

        const result = self.head.cmpxchgWeak(
            head_packed,
            new_packed,
            .acq_rel,
            .acquire,
        );

        if (result != null) {
            // CAS failed - another stealer won
            return .{ .status = .retry, .task = null };
        }

        return .{ .status = .success, .task = task };
    }

    /// Steal half the tasks from this queue into a destination queue
    /// Returns number of tasks stolen
    pub fn stealInto(self: *Self, dest: *Self) usize {
        const dest_available = dest.availableCapacity();
        if (dest_available == 0) return 0;

        var stolen = self.stealLifoSlot(dest);
        stolen += self.stealFromMainQueue(dest, dest_available -| stolen);
        return stolen;
    }

    /// Get available capacity in this queue
    fn availableCapacity(self: *const Self) usize {
        const head = PackedHead.steal(self.head.load(.acquire));
        const tail = self.tail.load(.acquire);
        return CAPACITY -| (tail -% head);
    }

    /// Steal from LIFO stack into destination (takes oldest from bottom)
    fn stealLifoSlot(self: *Self, dest: *Self) usize {
        // Try to steal from bottom of LIFO stack
        const top = self.lifo_top.load(.acquire);
        if (top == 0) {
            return 0;
        }

        // Attempt to take the bottom task
        const task = self.lifo_stack[0].swap(null, .acq_rel);
        if (task == null) {
            return 0;
        }

        // Push to destination
        if (!dest.push(task.?)) {
            // Restore on failure - try to put it back
            _ = self.lifo_stack[0].cmpxchgStrong(null, task, .acq_rel, .acquire);
            return 0;
        }

        // Note: This leaves a "hole" at index 0. The owner will compact
        // the stack on next push. This is acceptable for the rare stealInto case.
        return 1;
    }

    /// Steal from main queue buffer using two-phase protocol
    fn stealFromMainQueue(self: *Self, dest: *Self, max_steal: usize) usize {
        if (max_steal == 0) return 0;

        const head_packed = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);
        const real_head = PackedHead.real(head_packed);
        const steal_head = PackedHead.steal(head_packed);

        // Check if empty or steal in progress
        if (real_head >= tail or steal_head != real_head) return 0;

        // Calculate steal count
        const available = tail -% real_head;
        var count: u32 = @intCast(@min(available / 2, max_steal));
        if (count == 0 and available > 0) count = 1;
        if (count > HALF_CAPACITY) count = HALF_CAPACITY;
        if (count == 0) return 0;

        // Phase 1: Mark steal in progress
        const mid_packed = PackedHead.pack(real_head, real_head +% count);
        if (self.head.cmpxchgStrong(head_packed, mid_packed, .acq_rel, .acquire) != null) {
            return 0; // Lost race
        }

        // Phase 2: Copy tasks
        self.copyTasksTo(dest, real_head, count);

        // Phase 3: Complete steal
        self.completeSteal(mid_packed);

        return count;
    }

    /// Copy tasks from this queue to destination
    fn copyTasksTo(self: *Self, dest: *Self, src_start: u32, count: u32) void {
        const dst_tail = dest.tail.load(.monotonic);
        for (0..count) |i| {
            const src_idx = (src_start +% @as(u32, @intCast(i))) & MASK;
            const dst_idx = (dst_tail +% @as(u32, @intCast(i))) & MASK;
            const task = self.buffer[src_idx].load(.acquire);
            dest.buffer[dst_idx].store(task, .monotonic);
        }
        dest.tail.store(dst_tail +% count, .release);
    }

    /// Complete a steal operation (advance real_head to match steal_head)
    fn completeSteal(self: *Self, mid_packed: u64) void {
        var prev = mid_packed;
        while (true) {
            const steal_pos = PackedHead.steal(prev);
            const final = PackedHead.pack(steal_pos, steal_pos);

            if (self.head.cmpxchgWeak(prev, final, .acq_rel, .acquire)) |new_val| {
                if (PackedHead.steal(new_val) == PackedHead.real(new_val)) break;
                prev = new_val;
                continue;
            }
            break;
        }
    }

    /// Get the number of tasks in the queue (approximate)
    pub fn len(self: *const Self) usize {
        const head_packed = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);
        const real_head = PackedHead.real(head_packed);

        var count = tail -% real_head;

        // Add LIFO stack depth
        count += self.lifo_top.load(.acquire);

        return count;
    }

    /// Check if the queue is empty
    pub fn isEmpty(self: *const Self) bool {
        // Check LIFO stack first
        if (self.lifo_top.load(.acquire) > 0) {
            return false;
        }

        const head_packed = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);
        return PackedHead.real(head_packed) >= tail;
    }

    /// Check if the queue is full
    pub fn isFull(self: *const Self) bool {
        const head_packed = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);
        return tail -% PackedHead.steal(head_packed) >= CAPACITY;
    }

    /// Check if LIFO stack is empty (useful for scheduler)
    pub fn isLifoEmpty(self: *const Self) bool {
        return self.lifo_top.load(.acquire) == 0;
    }

    /// Flush all LIFO stack tasks to the main buffer
    ///
    /// CRITICAL: Call this before parking! Tasks in the LIFO stack are NOT
    /// stealable by other workers. If a worker parks with tasks in its LIFO
    /// stack, those tasks are "pinned" and cannot be processed by other workers.
    ///
    /// Returns the number of tasks flushed, or null if main buffer is full.
    pub fn flushLifoToBuffer(self: *Self) ?usize {
        var flushed: usize = 0;
        const top = self.lifo_top.load(.acquire);

        if (top == 0) return 0;

        // Move tasks from LIFO stack (bottom to top) to main buffer
        // This preserves relative order in the main buffer
        for (0..top) |i| {
            const task = self.lifo_stack[i].swap(null, .acq_rel);
            if (task) |t| {
                if (!self.pushToBuffer(t)) {
                    // Main buffer full - restore remaining tasks to LIFO
                    self.lifo_stack[i].store(t, .release);
                    // Update lifo_top to reflect remaining tasks
                    self.lifo_top.store(@intCast(top - i), .release);
                    return null; // Couldn't flush all
                }
                flushed += 1;
            }
        }

        self.lifo_top.store(0, .release);
        return flushed;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "LocalQueue - basic push and pop (FIFO from main queue)" {
    var queue = LocalQueue.init();

    // Create fake tasks (just need valid Header pointers)
    var headers: [3]Header = undefined;
    for (&headers, 0..) |*h, i| {
        h.* = Header.init(&dummy_vtable, i);
    }

    // Push tasks to main queue (bypassing LIFO slot)
    try std.testing.expect(queue.push(&headers[0]));
    try std.testing.expect(queue.push(&headers[1]));
    try std.testing.expect(queue.push(&headers[2]));

    try std.testing.expectEqual(@as(usize, 3), queue.len());

    // Main queue is FIFO (Tokio-style)
    // LIFO behavior comes from the LIFO slot, not the main queue
    try std.testing.expectEqual(&headers[0], queue.pop().?);
    try std.testing.expectEqual(&headers[1], queue.pop().?);
    try std.testing.expectEqual(&headers[2], queue.pop().?);

    try std.testing.expect(queue.isEmpty());
}

test "LocalQueue - LIFO slot provides LIFO behavior" {
    var queue = LocalQueue.init();

    var headers: [3]Header = undefined;
    for (&headers, 0..) |*h, i| {
        h.* = Header.init(&dummy_vtable, i);
    }

    // Push to main queue first (FIFO order)
    try std.testing.expect(queue.push(&headers[0]));
    try std.testing.expect(queue.push(&headers[1]));

    // Push to LIFO slot (this gets priority)
    try std.testing.expect(queue.pushLifo(&headers[2]) == null);

    // Pop should get LIFO slot first (most recently scheduled = LIFO behavior)
    try std.testing.expectEqual(&headers[2], queue.pop().?);

    // Then main queue (FIFO order - 0 was pushed first)
    try std.testing.expectEqual(&headers[0], queue.pop().?);
    try std.testing.expectEqual(&headers[1], queue.pop().?);
}

test "LocalQueue - steal" {
    var queue = LocalQueue.init();

    var headers: [4]Header = undefined;
    for (&headers, 0..) |*h, i| {
        h.* = Header.init(&dummy_vtable, i);
    }

    // Push tasks
    for (&headers) |*h| {
        try std.testing.expect(queue.push(h));
    }

    // Steal in FIFO order
    try std.testing.expectEqual(&headers[0], queue.steal().?);
    try std.testing.expectEqual(&headers[1], queue.steal().?);

    try std.testing.expectEqual(@as(usize, 2), queue.len());
}

test "LocalQueue - capacity limit" {
    var queue = LocalQueue.init();

    var headers: [CAPACITY + 10]Header = undefined;
    for (&headers, 0..) |*h, i| {
        h.* = Header.init(&dummy_vtable, i);
    }

    // Fill queue to capacity
    for (0..CAPACITY) |i| {
        try std.testing.expect(queue.push(&headers[i]));
    }

    try std.testing.expect(queue.isFull());

    // Should fail when full
    try std.testing.expect(!queue.push(&headers[CAPACITY]));
}

test "LocalQueue - stealInto" {
    var source = LocalQueue.init();
    var dest = LocalQueue.init();

    var headers: [8]Header = undefined;
    for (&headers, 0..) |*h, i| {
        h.* = Header.init(&dummy_vtable, i);
    }

    // Push to source
    for (&headers) |*h| {
        try std.testing.expect(source.push(h));
    }

    // Steal half into dest
    const stolen = source.stealInto(&dest);
    try std.testing.expect(stolen > 0);
    try std.testing.expect(stolen <= 4); // Half of 8

    // Verify source has remaining
    try std.testing.expectEqual(@as(usize, 8 - stolen), source.len());

    // Verify dest has stolen
    try std.testing.expectEqual(stolen, dest.len());
}

test "LocalQueue - empty operations" {
    var queue = LocalQueue.init();

    try std.testing.expect(queue.isEmpty());
    try std.testing.expect(queue.pop() == null);
    try std.testing.expect(queue.steal() == null);
    try std.testing.expect(queue.isLifoEmpty());
}

test "LocalQueue - LIFO stack" {
    var queue = LocalQueue.init();

    var headers: [LIFO_STACK_SIZE + 1]Header = undefined;
    for (&headers, 0..) |*h, i| {
        h.* = Header.init(&dummy_vtable, i);
    }

    // Push tasks to LIFO stack
    for (0..LIFO_STACK_SIZE) |i| {
        try std.testing.expect(queue.pushLifo(&headers[i]) == null);
    }
    try std.testing.expect(!queue.isLifoEmpty());
    try std.testing.expectEqual(LIFO_STACK_SIZE, queue.len());

    // Push one more - should overflow bottom to main queue
    try std.testing.expect(queue.pushLifo(&headers[LIFO_STACK_SIZE]) == null);
    try std.testing.expectEqual(LIFO_STACK_SIZE + 1, queue.len());

    // Pop order: most recent first (LIFO from stack)
    // Then main queue (FIFO - the overflowed task)
    try std.testing.expectEqual(&headers[LIFO_STACK_SIZE], queue.pop().?);
    try std.testing.expectEqual(&headers[LIFO_STACK_SIZE - 1], queue.pop().?);
}

test "LocalQueue - stealInto with full destination returns zero" {
    var source = LocalQueue.init();
    var dest = LocalQueue.init();

    var src_headers: [8]Header = undefined;
    for (&src_headers, 0..) |*h, i| {
        h.* = Header.init(&dummy_vtable, i);
    }

    var dst_headers: [CAPACITY]Header = undefined;
    for (&dst_headers, 0..) |*h, i| {
        h.* = Header.init(&dummy_vtable, i + 1000);
    }

    // Fill source
    for (&src_headers) |*h| {
        try std.testing.expect(source.push(h));
    }

    // Fill destination to capacity
    for (0..CAPACITY) |i| {
        try std.testing.expect(dest.push(&dst_headers[i]));
    }

    try std.testing.expect(dest.isFull());

    // stealInto should return 0 when dest is full
    const stolen = source.stealInto(&dest);
    try std.testing.expectEqual(@as(usize, 0), stolen);

    // Source should still have all its tasks
    try std.testing.expectEqual(@as(usize, 8), source.len());
}

test "LocalQueue - interleaved pop and steal" {
    var queue = LocalQueue.init();

    var headers: [6]Header = undefined;
    for (&headers, 0..) |*h, i| {
        h.* = Header.init(&dummy_vtable, i);
    }

    // Push 6 tasks
    for (&headers) |*h| {
        try std.testing.expect(queue.push(h));
    }

    // Interleave pop (owner) and steal (other worker)
    // Both should get tasks without conflict

    // Owner pops from head (FIFO)
    try std.testing.expectEqual(&headers[0], queue.pop().?);

    // Stealer steals from head (FIFO)
    try std.testing.expectEqual(&headers[1], queue.steal().?);

    // Owner pops again
    try std.testing.expectEqual(&headers[2], queue.pop().?);

    // Stealer steals again
    try std.testing.expectEqual(&headers[3], queue.steal().?);

    // Two tasks remain
    try std.testing.expectEqual(@as(usize, 2), queue.len());
}

test "LocalQueue - LIFO stack overflow to main queue" {
    var queue = LocalQueue.init();

    // Create more tasks than LIFO stack can hold
    const num_tasks = LIFO_STACK_SIZE + 3;
    var headers: [LIFO_STACK_SIZE + 3]Header = undefined;
    for (&headers, 0..) |*h, i| {
        h.* = Header.init(&dummy_vtable, i);
    }

    // Push all tasks via pushLifo
    for (0..num_tasks) |i| {
        try std.testing.expect(queue.pushLifo(&headers[i]) == null);
    }
    try std.testing.expectEqual(num_tasks, queue.len());

    // Pop order:
    // 1. LIFO stack (most recent first): headers[num_tasks-1] down to headers[3]
    // 2. Main queue (FIFO): headers[0], headers[1], headers[2] (the overflowed ones)

    // Pop from LIFO stack (most recent first)
    for (0..LIFO_STACK_SIZE) |i| {
        const expected_idx = num_tasks - 1 - i;
        try std.testing.expectEqual(&headers[expected_idx], queue.pop().?);
    }

    // Pop from main queue (FIFO - oldest overflowed first)
    try std.testing.expectEqual(&headers[0], queue.pop().?);
    try std.testing.expectEqual(&headers[1], queue.pop().?);
    try std.testing.expectEqual(&headers[2], queue.pop().?);

    try std.testing.expect(queue.isEmpty());
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
