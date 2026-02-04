# Blitz-IO Executor Review Request

I'm building a high-performance async I/O runtime in Zig 0.15, inspired by Tokio (Rust). I'd like a critical review of the queue and scheduler implementation for correctness, performance, and potential improvements.

## Project Overview

**Blitz-IO** is a work-stealing async executor with:
- Per-worker local queues (lock-free, 256 slots)
- Sharded global queue (8 shards, mutex-protected)
- LIFO stack for cache locality (4 slots, improvement over Tokio's single slot)
- Cooperative scheduling with budgets
- Parked worker bitmap for O(1) wake-up

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           SCHEDULER                                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                    SHARDED GLOBAL QUEUE (8 shards)                      ││
│  │  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ... (each mutex-protected) ││
│  │  │ Shard0 │ │ Shard1 │ │ Shard2 │ │ Shard3 │                            ││
│  │  └────────┘ └────────┘ └────────┘ └────────┘                            ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐    │
│  │   Worker 0   │  │   Worker 1   │  │   Worker 2   │  │   Worker N   │    │
│  │              │  │              │  │              │  │              │    │
│  │ ┌──────────┐ │  │ ┌──────────┐ │  │ ┌──────────┐ │  │ ┌──────────┐ │    │
│  │ │LIFO Stack│ │  │ │LIFO Stack│ │  │ │LIFO Stack│ │  │ │LIFO Stack│ │    │
│  │ │ (4 slots)│ │  │ │ (4 slots)│ │  │ │ (4 slots)│ │  │ │ (4 slots)│ │    │
│  │ └──────────┘ │  │ └──────────┘ │  │ └──────────┘ │  │ └──────────┘ │    │
│  │ ┌──────────┐ │  │ ┌──────────┐ │  │ ┌──────────┐ │  │ ┌──────────┐ │    │
│  │ │  Local   │ │  │ │  Local   │ │  │ │  Local   │ │  │ │  Local   │ │    │
│  │ │  Queue   │ │  │ │  Queue   │ │  │ │  Queue   │ │  │ │  Queue   │ │    │
│  │ │(256 slot)│ │  │ │(256 slot)│ │  │ │(256 slot)│ │  │ │(256 slot)│ │    │
│  │ └──────────┘ │  │ └──────────┘ │  │ └──────────┘ │  │ └──────────┘ │    │
│  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘    │
│         │                  │                  │                  │          │
│         └──────────────────┴────── STEALING ──┴──────────────────┘          │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Work Finding Priority (matches Tokio)

1. **Pre-fetched Global Batch** → Already holding tasks from global queue
2. **Local Queue** → Check LIFO stack first, then main circular buffer
3. **Global Queue (periodic)** → Every N ticks, batch-pull tasks
4. **Work Stealing** → Steal from other workers' local queues
5. **Global Queue (final)** → One more check before parking
6. **Park** → Sleep with futex until woken

---

## Key Implementation 1: Local Queue (Chase-Lev style)

### Packed Head for ABA Prevention

```zig
// 64-bit head = [steal_head:32][real_head:32]
//
// real_head:  Where tasks are actually consumed from
// steal_head: Marks in-progress bulk steals
//
// When steal_head == real_head: No steal in progress
// When steal_head > real_head:  Bulk steal is in progress

const PackedHead = struct {
    fn pack(real_val: u32, steal_val: u32) u64 {
        return @as(u64, steal_val) << 32 | @as(u64, real_val);
    }

    fn real(packed_val: u64) u32 {
        return @truncate(packed_val);
    }

    fn steal(packed_val: u64) u32 {
        return @truncate(packed_val >> 32);
    }
};
```

### Cache-Line Layout (prevents false sharing)

```zig
pub const LocalQueue = struct {
    // === Cache line 1: Stealer-contended ===
    head: std.atomic.Value(u64) align(CACHE_LINE),
    _head_padding: [CACHE_LINE - @sizeOf(std.atomic.Value(u64))]u8 = undefined,

    // === Cache line 2: Owner-exclusive ===
    tail: std.atomic.Value(u32) align(CACHE_LINE),
    _tail_padding: [CACHE_LINE - @sizeOf(std.atomic.Value(u32))]u8 = undefined,

    // === Cache line 3+: LIFO stack ===
    lifo_stack: [LIFO_STACK_SIZE]std.atomic.Value(?*Header) align(CACHE_LINE),
    lifo_top: std.atomic.Value(u32),

    // === Main buffer ===
    buffer: [CAPACITY]std.atomic.Value(?*Header),  // 256 slots
};
```

### Single-Task Steal with Exponential Backoff

```zig
fn stealFromBuffer(self: *Self) ?*Header {
    var backoff: u32 = 0;

    while (true) {
        const result = self.tryStealOne();

        switch (result.status) {
            .success => return result.task,
            .empty => return null,
            .retry => {
                // Exponential backoff on contention
                if (backoff < STEAL_SPIN_LIMIT) {  // STEAL_SPIN_LIMIT = 6
                    const spins = @as(u32, 1) << @intCast(backoff);
                    for (0..spins) |_| {
                        std.atomic.spinLoopHint();
                    }
                    backoff += 1;
                } else {
                    std.Thread.yield() catch {};
                }
            },
        }
    }
}

fn tryStealOne(self: *Self) StealAttempt {
    const head_packed = self.head.load(.acquire);
    const tail = self.tail.load(.acquire);

    const real_head = PackedHead.real(head_packed);
    const steal_head = PackedHead.steal(head_packed);

    if (real_head >= tail) {
        return .{ .status = .empty, .task = null };
    }

    if (steal_head != real_head) {
        return .{ .status = .retry, .task = null };  // Another steal in progress
    }

    const task = self.buffer[real_head & MASK].load(.monotonic);
    const new_head = real_head +% 1;
    const new_packed = PackedHead.pack(new_head, new_head);

    const result = self.head.cmpxchgWeak(head_packed, new_packed, .acq_rel, .acquire);

    if (result != null) {
        return .{ .status = .retry, .task = null };
    }

    return .{ .status = .success, .task = task };
}
```

### Two-Phase Bulk Steal Protocol (stealInto)

```zig
fn stealFromMainQueue(self: *Self, dest: *Self, max_steal: usize) usize {
    const head_packed = self.head.load(.acquire);
    const tail = self.tail.load(.acquire);
    const real_head = PackedHead.real(head_packed);
    const steal_head = PackedHead.steal(head_packed);

    if (real_head >= tail or steal_head != real_head) return 0;

    // Calculate steal count (half of available, up to max)
    const available = tail -% real_head;
    var count: u32 = @intCast(@min(available / 2, max_steal));
    if (count == 0 and available > 0) count = 1;

    // Phase 1: Mark steal in progress (advance steal_head only)
    const mid_packed = PackedHead.pack(real_head, real_head +% count);
    if (self.head.cmpxchgStrong(head_packed, mid_packed, .acq_rel, .acquire) != null) {
        return 0;  // Lost race
    }

    // Phase 2: Copy tasks to destination
    self.copyTasksTo(dest, real_head, count);

    // Phase 3: Complete steal (advance real_head to match steal_head)
    self.completeSteal(mid_packed);

    return count;
}

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
```

### Owner Pop (from LIFO stack, then main queue)

```zig
pub fn pop(self: *Self) ?*Header {
    // Fast path: pop from LIFO stack (most recent = cache-hot)
    const top = self.lifo_top.load(.acquire);
    if (top > 0) {
        const new_top = top - 1;
        const task = self.lifo_stack[new_top].swap(null, .acq_rel);
        self.lifo_top.store(new_top, .release);
        if (task != null) {
            return task;
        }
    }

    // Slow path: pop from main queue (FIFO via CAS on head)
    return self.popFromBuffer();
}

pub fn popFromBuffer(self: *Self) ?*Header {
    var head_packed = self.head.load(.acquire);

    while (true) {
        const real_head = PackedHead.real(head_packed);
        const steal_head = PackedHead.steal(head_packed);
        const tail = self.tail.load(.acquire);

        if (real_head == tail) return null;

        // Wait for in-progress steal to complete
        if (steal_head != real_head) {
            std.atomic.spinLoopHint();
            head_packed = self.head.load(.acquire);
            continue;
        }

        const task = self.buffer[real_head & MASK].load(.acquire);

        // Prefetch next task (Zig optimization)
        const next_slot = (real_head +% 1) & MASK;
        @prefetch(@ptrCast(&self.buffer[next_slot]), .{ .rw = .read, .locality = 3, .cache = .data });

        const next_packed = PackedHead.pack(real_head +% 1, real_head +% 1);
        if (self.head.cmpxchgWeak(head_packed, next_packed, .acq_rel, .acquire)) |new_val| {
            head_packed = new_val;
            continue;
        }

        return task;
    }
}
```

---

## Key Implementation 2: Sharded Global Queue

### Sharding to Reduce Contention

```zig
pub const NUM_SHARDS: usize = 8;
const SHARD_MASK: usize = NUM_SHARDS - 1;

pub const ShardedGlobalQueue = struct {
    shards: [NUM_SHARDS]GlobalQueue align(64),  // Each shard cache-line aligned
    pop_index: std.atomic.Value(usize),         // Round-robin for fair pop

    pub fn push(self: *Self, task: *Header) bool {
        const shard_idx = self.hashToShard(@intFromPtr(task));
        return self.shards[shard_idx].push(task);
    }

    pub fn pop(self: *Self) ?*Header {
        const start = self.pop_index.fetchAdd(1, .monotonic) & SHARD_MASK;

        for (0..NUM_SHARDS) |offset| {
            const shard_idx = (start + offset) & SHARD_MASK;
            if (self.shards[shard_idx].pop()) |task| {
                return task;
            }
        }
        return null;
    }

    inline fn hashToShard(self: *const Self, value: usize) usize {
        _ = self;
        const hash = value *% 0x9e3779b97f4a7c15;  // Golden ratio prime
        return (hash >> 32) & SHARD_MASK;
    }
};
```

### Individual Shard (Mutex-Protected FIFO)

```zig
pub const GlobalQueue = struct {
    head: ?*Header,
    tail: ?*Header,
    count: std.atomic.Value(usize),
    mutex: std.Thread.Mutex,
    is_closed: bool,

    pub fn push(self: *Self, task: *Header) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed) return false;

        task.queue_next.store(null, .monotonic);
        if (self.tail) |t| {
            t.queue_next.store(task, .monotonic);
            self.tail = task;
        } else {
            self.head = task;
            self.tail = task;
        }
        _ = self.count.fetchAdd(1, .release);
        return true;
    }

    pub fn pop(self: *Self) ?*Header {
        self.mutex.lock();
        defer self.mutex.unlock();

        const task = self.head orelse return null;
        self.head = task.queue_next.load(.monotonic);
        if (self.head == null) self.tail = null;
        task.queue_next.store(null, .monotonic);
        _ = self.count.fetchSub(1, .release);
        return task;
    }
};
```

---

## Key Implementation 3: Parked Worker Bitmap

```zig
pub const IdleState = struct {
    num_searching: std.atomic.Value(u32),
    num_parked: std.atomic.Value(u32),
    parked_bitmap: std.atomic.Value(u64),  // Supports up to 64 workers
    num_workers: u32,

    pub fn workerParking(self: *IdleState, worker_id: usize) void {
        const mask: u64 = @as(u64, 1) << @intCast(worker_id);
        _ = self.parked_bitmap.fetchOr(mask, .release);
        _ = self.num_parked.fetchAdd(1, .release);
    }

    pub fn workerUnparking(self: *IdleState, worker_id: usize) void {
        const mask: u64 = @as(u64, 1) << @intCast(worker_id);
        _ = self.parked_bitmap.fetchAnd(~mask, .release);
        _ = self.num_parked.fetchSub(1, .release);
    }

    // O(1) find via count trailing zeros
    pub fn findParkedWorker(self: *const IdleState) ?usize {
        const bitmap = self.parked_bitmap.load(.acquire);
        if (bitmap == 0) return null;
        return @ctz(bitmap);
    }
};
```

---

## Key Implementation 4: Task Header (Packed State + Refcount)

```zig
pub const Header = struct {
    vtable: *const VTable,
    state_ref: std.atomic.Value(u64) align(8),  // Lower 16 bits: state, Upper 48 bits: refcount
    queue_next: std.atomic.Value(?*Header),     // Intrusive linked list
    id: u64,

    pub const State = struct {
        pub const IDLE: u64 = 0;
        pub const SCHEDULED: u64 = 1 << 0;
        pub const RUNNING: u64 = 1 << 1;
        pub const COMPLETE: u64 = 1 << 2;
        pub const CANCELLED: u64 = 1 << 3;
        pub const STATE_MASK: u64 = 0xFFFF;
        pub const REF_SHIFT: u6 = 16;
        pub const REF_ONE: u64 = 1 << REF_SHIFT;
    };

    pub fn ref(self: *Header) void {
        _ = self.state_ref.fetchAdd(State.REF_ONE, .monotonic);
    }

    pub fn unref(self: *Header) void {
        const prev = self.state_ref.fetchSub(State.REF_ONE, .acq_rel);
        if (getRefCount(prev) == 1) {
            self.vtable.drop(self);
        }
    }
};
```

---

## Key Implementation 5: Backpressure Signaling

```zig
pub const SpawnResult = enum { ok, backpressure, rejected };

pub fn spawnWithBackpressure(self: *Self, task: *Header) SpawnResult {
    _ = self.tasks_spawned.fetchAdd(1, .monotonic);

    if (!task.transitionToScheduled()) {
        return .rejected;
    }

    const total_depth = self.totalQueueDepth();
    const threshold = self.config.backpressure_threshold * self.workers.len;

    self.scheduleTask(task);

    if (total_depth > threshold) {
        return .backpressure;
    }
    return .ok;
}
```

---

## Claimed Improvements Over Tokio

| Feature | Tokio | Blitz-IO | Claimed Benefit |
|---------|-------|----------|-----------------|
| LIFO slot | Single slot | 4-slot stack | Better burst handling |
| Global queue | Single mutex | 8 shards | Reduced contention |
| Backpressure | No signaling | `SpawnResult.backpressure` | Flow control |
| Batch sizing | Fixed 32 | Adaptive 4-64 | Fair distribution |
| Timer lookup | Runtime calc | Comptime tables | Zero-cost |
| Prefetching | None | `@prefetch` intrinsic | Hide memory latency |

---

## Questions for Review

1. **Memory Ordering Correctness**: Are the atomic orderings (acquire, release, acq_rel, monotonic) correct for:
   - The packed head CAS operations in steal?
   - The two-phase bulk steal protocol?
   - The LIFO stack push/pop?

2. **ABA Problem**: Does the packed head (real + steal in 64-bit) fully prevent ABA issues, or are there edge cases?

3. **Two-Phase Steal**: Is the mark-copy-commit protocol correct? Specifically:
   - What happens if owner pops while steal is in progress?
   - Can the completeSteal CAS loop get stuck?

4. **Cache Line Padding**: Is explicit padding necessary given `align(CACHE_LINE)`, or could the compiler still pack things badly?

5. **Sharded Global Queue**:
   - Is hashing by task pointer address a good distribution strategy?
   - Is O(NUM_SHARDS) pop scan acceptable, or should we track non-empty shards?

6. **LIFO Stack vs Single Slot**: Is there a correctness issue with the LIFO stack when stealers can take from bottom while owner pushes/pops from top?

7. **Backpressure Threshold**: Is checking total queue depth after scheduling (not before) a race that could cause unbounded growth?

8. **Missing Features**: What important Tokio features are we missing that could cause correctness or performance issues?

---

## Test Status

- 194 tests passing
- All tests are unit tests, no loom-style concurrency testing

## File Sizes

| File | Lines | Description |
|------|-------|-------------|
| local_queue.zig | 839 | Work-stealing queue |
| worker.zig | 807 | Worker thread loop |
| task.zig | 738 | Task header + vtable |
| timer.zig | 595 | Hierarchical timer wheel |
| scheduler.zig | 483 | Coordination |
| global_queue.zig | 590 | Sharded MPMC queue |
| pool.zig | 255 | Lock-free object pool |
| **Total** | ~4,300 | |
