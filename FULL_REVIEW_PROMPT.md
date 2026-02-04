# Blitz-IO Complete Implementation Review

I've implemented a high-performance async I/O runtime in Zig, modeled after Tokio. This prompt contains the critical concurrent data structures and their implementations for verification. Please review for correctness, memory safety, and potential race conditions.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Blitz-IO Runtime                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐        │
│  │  Worker 0   │  │  Worker 1   │  │  Worker 2   │  │  Worker N   │        │
│  │             │  │             │  │             │  │             │        │
│  │ ┌─────────┐ │  │ ┌─────────┐ │  │ ┌─────────┐ │  │ ┌─────────┐ │        │
│  │ │  LIFO   │ │  │ │  LIFO   │ │  │ │  LIFO   │ │  │ │  LIFO   │ │        │
│  │ │ Stack(4)│ │  │ │ Stack(4)│ │  │ │ Stack(4)│ │  │ │ Stack(4)│ │        │
│  │ └─────────┘ │  │ └─────────┘ │  │ └─────────┘ │  │ └─────────┘ │        │
│  │ ┌─────────┐ │  │ ┌─────────┐ │  │ ┌─────────┐ │  │ ┌─────────┐ │        │
│  │ │Chase-Lev│ │  │ │Chase-Lev│ │  │ │Chase-Lev│ │  │ │Chase-Lev│ │        │
│  │ │ Deque   │◄┼──┼─┤  Deque  │◄┼──┼─┤  Deque  │◄┼──┼─┤  Deque  │ │        │
│  │ │  (256)  │ │  │ │  (256)  │ │  │ │  (256)  │ │  │ │  (256)  │ │        │
│  │ └─────────┘ │  │ └─────────┘ │  │ └─────────┘ │  │ └─────────┘ │        │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘        │
│         │                │                │                │               │
│         └────────────────┼────────────────┼────────────────┘               │
│                          │                │                                 │
│                          ▼                ▼                                 │
│              ┌───────────────────────────────────────────┐                 │
│              │         Sharded Global Queue              │                 │
│              │  ┌─────┬─────┬─────┬─────┬─────┬─────┐   │                 │
│              │  │ S0  │ S1  │ S2  │ S3  │ S4  │ ... │   │                 │
│              │  └─────┴─────┴─────┴─────┴─────┴─────┘   │                 │
│              │         Occupancy Bitmask: 0b00101001     │                 │
│              └───────────────────────────────────────────┘                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Part 1: Local Queue (Chase-Lev Work-Stealing Deque)

### Design Decisions

1. **LIFO Stack (4 slots)** - Hot tasks stay on the same worker for cache locality
2. **Packed Head** - `real_head` and `steal_head` in single u64 for ABA prevention
3. **Cache-Line Padding** - Prevent false sharing between owner and stealers
4. **Wait-Free Owner Pop** - Owner returns null instead of spinning during steal
5. **LIFO Flush Before Parking** - Prevent task pinning when worker parks

### Core Data Structure

```zig
pub const LocalQueue = struct {
    const BUFFER_SIZE: u32 = 256;
    const MASK: u32 = BUFFER_SIZE - 1;
    const CACHE_LINE = 64;

    // === Cache line 1: Stealer-contended ===
    head: std.atomic.Value(u64) align(CACHE_LINE),
    _head_padding: [CACHE_LINE - @sizeOf(std.atomic.Value(u64))]u8 = undefined,

    // === Cache line 2: Owner-exclusive ===
    tail: std.atomic.Value(u32) align(CACHE_LINE),
    _tail_padding: [CACHE_LINE - @sizeOf(std.atomic.Value(u32))]u8 = undefined,

    // === Cache line 3+: Buffer ===
    buffer: [BUFFER_SIZE]std.atomic.Value(?*Header) align(CACHE_LINE),

    // === LIFO stack for hot path ===
    lifo_stack: [LIFO_SLOTS]std.atomic.Value(?*Header) align(CACHE_LINE),
    lifo_top: std.atomic.Value(u32),

    // Packed head format:
    // - Bits 0-31:  real_head (actual dequeue position)
    // - Bits 32-63: steal_head (in-progress steal marker)
};
```

### Critical Operation: Work Stealing

```zig
pub fn tryStealOne(self: *Self) ?*Header {
    var head = self.head.load(.acquire);
    var tail = self.tail.load(.acquire);

    while (true) {
        const real_head = unpackRealHead(head);
        const steal_head = unpackStealHead(head);

        // Queue empty or steal already in progress
        if (real_head == tail) return null;
        if (steal_head != real_head) {
            // Another stealer active - back off
            std.atomic.spinLoopHint();
            head = self.head.load(.acquire);
            tail = self.tail.load(.acquire);
            continue;
        }

        // Phase 1: Mark steal in progress (advance steal_head)
        const new_head = packHead(real_head, real_head +% 1);
        const cas_result = self.head.cmpxchgWeak(
            head,
            new_head,
            .acq_rel,
            .acquire,
        );
        if (cas_result) |updated| {
            head = updated;
            continue;
        }

        // Phase 2: Read the task
        // CRITICAL: Must use .acquire to synchronize with owner's .release store
        const task = self.buffer[real_head & MASK].load(.acquire);

        // Phase 3: Complete steal (advance real_head)
        const final_head = packHead(real_head +% 1, real_head +% 1);
        // Note: This store can use .release because we already acquired the data
        self.head.store(final_head, .release);

        return task;
    }
}
```

### Critical Operation: Wait-Free Owner Pop

```zig
fn popFromBuffer(self: *Self) ?*Header {
    const tail = self.tail.load(.monotonic);
    if (tail == 0) return null;

    const new_tail = tail -% 1;
    self.tail.store(new_tail, .release);

    std.atomic.fence(.seq_cst);

    const head = self.head.load(.acquire);
    const real_head = unpackRealHead(head);
    const steal_head = unpackStealHead(head);

    if (new_tail > real_head) {
        // Fast path: queue not empty, no conflict
        return self.buffer[new_tail & MASK].load(.acquire);
    }

    if (new_tail < real_head) {
        // Stealer took our item - restore tail and fail
        self.tail.store(tail, .monotonic);
        return null;
    }

    // new_tail == real_head: Race for the last item

    // WAIT-FREE: If a steal is in progress, don't spin - return null
    if (steal_head != real_head) {
        self.tail.store(tail, .monotonic);
        return null;
    }

    // Try to claim the last item
    const new_head = packHead(real_head +% 1, real_head +% 1);
    if (self.head.cmpxchgStrong(head, new_head, .acq_rel, .acquire)) |_| {
        // Lost race to stealer
        self.tail.store(tail, .monotonic);
        return null;
    }

    // Won the race
    const task = self.buffer[new_tail & MASK].load(.acquire);
    self.tail.store(real_head +% 1, .monotonic);
    return task;
}
```

### Critical Operation: LIFO Flush Before Parking

```zig
pub fn flushLifoToBuffer(self: *Self) ?usize {
    var flushed: usize = 0;
    const top = self.lifo_top.load(.acquire);
    if (top == 0) return 0;

    for (0..top) |i| {
        const task = self.lifo_stack[i].swap(null, .acq_rel);
        if (task) |t| {
            if (!self.pushToBuffer(t)) {
                // Buffer full - restore remaining tasks
                self.lifo_stack[i].store(t, .release);
                self.lifo_top.store(@intCast(top - i), .release);
                return null;
            }
            flushed += 1;
        }
    }
    self.lifo_top.store(0, .release);
    return flushed;
}
```

### Question 1: Two-Phase Steal Correctness

Is the two-phase steal (mark → read → complete) correct? Specifically:
- Can a stealer read stale data if the owner pushes to the same slot?
- Is `.acquire` on the buffer read sufficient to see the owner's `.release` store?

---

## Part 2: Sharded Global Queue

### Design Decisions

1. **8 Shards** - Reduce mutex contention with multiple independent queues
2. **Occupancy Bitmask** - O(popcount) scan for non-empty shards
3. **Task Pointer Hashing** - Distribute tasks across shards

### Core Data Structure

```zig
pub const ShardedGlobalQueue = struct {
    const NUM_SHARDS = 8;

    shards: [NUM_SHARDS]GlobalQueue align(64),
    pop_index: std.atomic.Value(usize),
    occupancy: std.atomic.Value(u64),  // Bitmask: bit i = shard i non-empty

    pub fn push(self: *Self, task: *Header) bool {
        const shard_idx = self.hashToShard(@intFromPtr(task));
        const ok = self.shards[shard_idx].push(task);
        if (ok) {
            // Mark shard as occupied
            const mask = @as(u64, 1) << @intCast(shard_idx);
            _ = self.occupancy.fetchOr(mask, .release);
        }
        return ok;
    }

    pub fn pop(self: *Self) ?*Header {
        const occ = self.occupancy.load(.acquire);
        if (occ == 0) return null;

        const start_idx = self.pop_index.fetchAdd(1, .monotonic) % NUM_SHARDS;

        // Try each shard starting from start_idx
        for (0..NUM_SHARDS) |offset| {
            const idx = (start_idx + offset) % NUM_SHARDS;
            const mask = @as(u64, 1) << @intCast(idx);

            // Skip shards marked as empty
            if (occ & mask == 0) continue;

            if (self.shards[idx].pop()) |task| {
                return task;
            } else {
                // Shard is now empty - clear bit (best effort)
                _ = self.occupancy.fetchAnd(~mask, .release);
            }
        }
        return null;
    }
};
```

### Question 2: Occupancy Bitmask Race

There's a race between `push` setting a bit and `pop` clearing it:
1. Thread A: `pop()` finds shard empty, about to clear bit
2. Thread B: `push()` adds task, sets bit
3. Thread A: clears bit (now incorrect - shard has a task!)

Is this acceptable? The task will be found on the next `pop()` call, but there's a temporary inconsistency. Should we use a different approach?

---

## Part 3: Task State Machine

### Design Decisions

1. **Packed 64-bit Atomic** - State flags (16 bits) + refcount (48 bits) in one word
2. **Reference Counting** - Scheduler, JoinHandle, and Waker each hold references
3. **Waker Cleanup** - Caller ensures waker is dropped if user doesn't consume it

### State Flags

```zig
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
```

### State Transitions

```
    ┌──────┐   schedule   ┌───────────┐   poll    ┌─────────┐
    │ IDLE │ ───────────▶ │ SCHEDULED │ ────────▶ │ RUNNING │
    └──────┘              └───────────┘           └─────────┘
        │                       │                      │
        │                       │                      │ yield (pending)
        │ cancel()              │ cancel()             │      │
        │                       │                      ▼      │
        ▼                       ▼                ┌──────────┐ │
    ┌───────────┐         ┌───────────┐         │ COMPLETE │◄┘
    │ CANCELLED │         │ CANCELLED │         └──────────┘
    └───────────┘         └───────────┘               │
                                                      │ refcount → 0
                                                      ▼
                                                ┌──────────┐
                                                │  DROPPED │
                                                └──────────┘
```

### Reference Counting

```zig
/// Increment reference count
/// Uses acquire ordering to ensure we see the latest state before incrementing.
/// The caller must already hold a valid reference (refcount > 0).
pub fn ref(self: *Header) void {
    const prev = self.state_ref.fetchAdd(State.REF_ONE, .acquire);
    std.debug.assert(getRefCount(prev) > 0);
}

/// Decrement reference count, dropping if zero
pub fn unref(self: *Header) void {
    const prev = self.state_ref.fetchSub(State.REF_ONE, .acq_rel);
    if (getRefCount(prev) == 1) {
        self.vtable.drop(self);
    }
}
```

### Question 3: Memory Ordering in `ref()`

We use `.acquire` for `ref()`. Is this necessary? The argument for `.monotonic`:
- Caller already holds a reference, so refcount > 0
- We're only incrementing, not reading any other state

The argument for `.acquire`:
- Ensures we see the latest memory state before proceeding
- Prevents reordering of subsequent accesses before the increment

Which is correct?

### Critical Operation: Poll Implementation

```zig
fn pollImpl(header: *Header) bool {
    const self: *Self = @fieldParentPtr("header", header);

    // Check for cancellation
    if (header.isCancelled()) {
        header.transitionToComplete();
        // Release scheduler's reference on completion
        header.unref();
        return true;
    }

    // Transition to running
    if (!header.transitionToRunning()) {
        return false;
    }

    // Create waker - mutable so we can track consumption
    var waker = Waker.init(header);

    // Poll the user function, passing pointer
    const result = pollFunc(&self.func, &self.output, &waker);

    switch (result) {
        .ready => {
            // CRITICAL: If user didn't consume waker, drop it now
            // Zig has no automatic destructors!
            if (waker.isValid()) {
                waker.drop();
            }
            header.transitionToComplete();
            // Release scheduler's reference on completion
            header.unref();
            return true;
        },
        .pending => {
            // User should have stored waker for later waking
            // If they didn't, clean up to avoid leak
            if (waker.isValid()) {
                waker.drop();
            }
            header.transitionToIdle();
            return false;
        },
    }
}
```

### Reference Ownership Model

| Holder | When Acquired | When Released |
|--------|---------------|---------------|
| **Scheduler** | On `init()` (refcount=1) | On `pollImpl()` completion |
| **JoinHandle** | On `JoinHandle.init()` | On `JoinHandle.deinit()` |
| **Waker** | On `Waker.init()` | On `wake()`, `drop()`, or pollImpl cleanup |

### Question 4: Double-Poll Race Condition

Can two workers both successfully call `transitionToRunning()` on the same task?

```zig
pub fn transitionToRunning(self: *Header) bool {
    var current = self.state_ref.load(.acquire);
    while (true) {
        const state = getState(current);

        // Must be scheduled
        if (state & State.SCHEDULED == 0) {
            return false;
        }
        // Cannot run if cancelled
        if (state & State.CANCELLED != 0) {
            return false;
        }

        const new_state = (state & ~State.SCHEDULED) | State.RUNNING;
        const new_val = (current & ~State.STATE_MASK) | new_state;

        const result = self.state_ref.cmpxchgWeak(
            current,
            new_val,
            .acq_rel,
            .acquire,
        );
        if (result) |v| {
            current = v;
            continue;
        }
        return true;
    }
}
```

My analysis: Only one can succeed because:
1. Both read `SCHEDULED` state
2. Both attempt CAS to set `RUNNING` and clear `SCHEDULED`
3. Only one CAS succeeds; the other retries and sees `RUNNING` (not `SCHEDULED`)
4. The retry fails the `SCHEDULED` check and returns false

Is this analysis correct?

### Question 5: Waker Stored in I/O, Task Cancelled

Scenario:
1. Task polls, returns `pending`, stores Waker in epoll interest
2. User calls `JoinHandle.cancel()`, task is marked CANCELLED
3. epoll triggers, calls `waker.wake()`
4. `transitionToScheduled()` fails (task is CANCELLED)
5. `waker.wake()` still calls `unref()`

Ownership trace:
- After poll: refcount = 2 (scheduler + waker)
- After cancel: refcount = 2, state = CANCELLED
- After wake: refcount = 1 (waker's unref)
- Next poll sees CANCELLED, calls unref: refcount = 0, task dropped

Is this correct? The task gets cleaned up properly through the normal poll path.

### Question 6: Output Read After Scheduler Unref

Scenario:
1. Task completes, pollImpl calls `header.unref()` → refcount = 1 (JoinHandle)
2. JoinHandle calls `tryJoin()`, reads output
3. JoinHandle calls `deinit()` → refcount = 0, task dropped

Is step 2 safe? The output is stored inline in the task struct:

```zig
pub fn RawTask(comptime F: type, comptime Output: type) type {
    return struct {
        header: Header,
        func: F,
        output: ?Output,  // Inline storage
        // ...
    };
}
```

Since refcount > 0 during `tryJoin()`, the task memory is valid, and output is inline, this should be safe. Correct?

---

## Part 4: Worker Integration

### Flush Before Parking

```zig
fn runWorkerLoop(self: *Worker) void {
    while (!self.should_stop.load(.acquire)) {
        const tasks_run = self.runBatch();

        if (tasks_run == 0) {
            // CRITICAL: Flush LIFO stack before parking
            // Otherwise tasks in LIFO could be stuck if no one steals
            _ = self.local_queue.flushLifoToBuffer();

            if (self.shared) |shared| {
                shared.idle_state.workerParking(self.id);
            }
            self.park_state.park(10 * std.time.ns_per_ms);
        }
    }
}
```

### Question 7: LIFO Flush Timing

Is flushing the LIFO stack sufficient before parking? Consider:
1. Worker flushes LIFO to buffer
2. Before parking, another task is pushed to LIFO
3. Worker parks with task in LIFO

Should we check LIFO again after the flush, or is this acceptable (the task will be processed when worker wakes)?

---

## Summary Questions

1. **Two-phase steal**: Is the memory ordering correct for the steal protocol?
2. **Occupancy bitmask race**: Is the push/pop race on the occupancy bits acceptable?
3. **ref() ordering**: Is `.acquire` necessary or is `.monotonic` sufficient?
4. **Double-poll prevention**: Does CAS correctly prevent two workers from running the same task?
5. **Cancelled task cleanup**: Is the waker→wake→unref→poll→unref chain correct?
6. **Output lifetime**: Is inline output safe to read when refcount > 0?
7. **LIFO flush timing**: Should we re-check LIFO after flushing before parking?

---

## Test Coverage

Current tests:
- State transition correctness
- Reference counting (packed format)
- Queue push/pop/steal operations
- LIFO stack operations

Missing tests (acknowledged):
- Concurrent stress tests
- Loom-style model checking
- Waker → I/O → wake cycle
- Cancellation during I/O wait

---

## Reference: Tokio Comparison

Key differences from Tokio:
1. **LIFO stack**: We use 4 slots vs Tokio's single slot
2. **Sharded global queue**: We use 8 shards with occupancy bitmask
3. **Wait-free owner pop**: We return null instead of spinning
4. **Explicit waker cleanup**: Required because Zig lacks destructors

Please verify these implementations are correct and identify any subtle bugs or race conditions.
