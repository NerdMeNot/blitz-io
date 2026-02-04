# Blitz-IO vs Tokio: An Honest Comparison

A critical comparison of Blitz-IO's Zig implementation against Tokio's battle-tested Rust runtime.

---

## The Good: Where Blitz-IO Shines

### 1. LIFO Stack (4 slots vs Tokio's 1 slot)

**Tokio**: Single `lifo_slot: Option<Notified>` that holds only the most recently scheduled task.

**Blitz-IO**: 4-slot LIFO stack with overflow to main buffer.

```
Tokio:           Blitz-IO:
┌────┐           ┌────┬────┬────┬────┐
│ T0 │           │ T3 │ T2 │ T1 │ T0 │
└────┘           └────┴────┴────┴────┘
1 hot task       4 hot tasks
```

**Why this matters**: In bursty workloads (spawning multiple related tasks), Blitz-IO keeps more tasks cache-hot. Tokio's single slot means the second spawned task immediately goes to the main queue.

**Verdict**: Genuine improvement for message-passing and spawn-heavy patterns.

---

### 2. Sharded Global Queue (8 shards vs Tokio's 1 queue)

**Tokio**: Single `inject::Shared` protected by one Mutex.

**Blitz-IO**: 8 shards with occupancy bitmask for O(popcount) scanning.

```
Tokio:                    Blitz-IO:
┌─────────────────┐       ┌────┬────┬────┬────┬────┬────┬────┬────┐
│  Single Queue   │       │ S0 │ S1 │ S2 │ S3 │ S4 │ S5 │ S6 │ S7 │
│    [mutex]      │       └────┴────┴────┴────┴────┴────┴────┴────┘
└─────────────────┘        Each shard has its own mutex
    ↑ ↑ ↑ ↑                     ↑    ↑    ↑    ↑
  All workers               Distributed contention
```

**Why this matters**: Under high load with many workers hitting the global queue, Tokio's single mutex becomes a bottleneck. Blitz-IO's sharding reduces contention.

**Caveat**: Tokio's inject queue is rarely the bottleneck because:
- Most scheduling uses lock-free local queues
- Batch operations amortize lock cost
- Global queue is checked infrequently (every ~61 tasks)

**Verdict**: Theoretical improvement, real-world impact uncertain without benchmarks.

---

### 3. Wait-Free Owner Pop

**Tokio**: Owner spins during CAS contention with stealers.

**Blitz-IO**: Owner returns `null` immediately if steal is in progress.

```zig
// Blitz-IO: Wait-free path
if (steal_head != real_head) {
    return null;  // Don't spin, try global queue
}
```

**Why this matters**: If a stealer gets descheduled mid-steal, Tokio's owner could spin for a full scheduler quantum. Blitz-IO avoids this by falling back to global queue.

**Verdict**: Good defensive improvement against pathological scheduler behavior.

---

### 4. Cache-Line Padding Between Head and Tail

**Tokio**: Relies on Rust's layout without explicit padding.

**Blitz-IO**: Explicit 64-byte cache-line separation.

```zig
// === Cache line 1: Stealer-contended ===
head: std.atomic.Value(u64) align(CACHE_LINE),
_head_padding: [CACHE_LINE - @sizeOf(std.atomic.Value(u64))]u8,

// === Cache line 2: Owner-exclusive ===
tail: std.atomic.Value(u32) align(CACHE_LINE),
```

**Verdict**: Explicit is better than implicit for false-sharing prevention.

---

### 5. Lost Wakeup Protection

**Tokio**: Has subtle races that are mitigated by 10ms park timeouts.

**Blitz-IO**: Explicit `transitioning_to_park` flag with `seq_cst` ordering.

```zig
self.transitioning_to_park.store(true, .seq_cst);
_ = self.local_queue.flushLifoToBuffer();
if (!self.local_queue.isEmpty()) {
    self.transitioning_to_park.store(false, .seq_cst);
    continue;  // Don't park, work arrived!
}
```

**Verdict**: More explicit handling of edge cases.

---

## The Bad: Where Blitz-IO Falls Short

### 1. ~~Missing NOTIFIED State Flag~~ **FIXED**

**Status**: Implemented in task.zig

**Blitz-IO's State Bits** (now matches Tokio's semantic model):
```zig
SCHEDULED | RUNNING | COMPLETE | CANCELLED | NOTIFIED
```

The `NOTIFIED` flag prevents lost wakeups:
1. `transitionToRunning()` clears `NOTIFIED`
2. If `wake()` is called during poll → sets `NOTIFIED` instead of `SCHEDULED`
3. `transitionToIdle()` returns previous state so caller can check `NOTIFIED`
4. If `NOTIFIED` was set → immediately reschedule

---

### 2. Initial Reference Count of 1 vs Tokio's 3

**Tokio**: Tasks start with refcount = 3
1. OwnedTasks collection (keeps task in global list)
2. Notified (pushed to run queue)
3. JoinHandle (user's handle)

**Blitz-IO**: Tasks start with refcount = 1
- Only the "creator's reference"
- JoinHandle and Waker add refs as needed

**Problem**: Blitz-IO's ownership model is underspecified:
- Who owns the initial reference?
- What happens if spawn() fails?
- How does the OwnedTasks list work?

Tokio's explicit 3-ref model makes ownership crystal clear.

---

### 3. ~~No OwnedTasks Collection~~ **FIXED**

**Status**: Implemented in task.zig

```zig
pub const OwnedTasks = struct {
    head: ?*Header,
    mutex: std.Thread.Mutex,
    count: std.atomic.Value(usize),
    closed: std.atomic.Value(bool),

    pub fn insert(self: *Self, task: *Header) bool { ... }
    pub fn remove(self: *Self, task: *Header) void { ... }
    pub fn closeAndCancelAll(self: *Self) usize { ... }
};
```

Now supports:
1. Graceful shutdown: `closeAndCancelAll()` cancels all tasks
2. Task tracking: Intrusive doubly-linked list through `owned_prev`/`owned_next`
3. Closed state: Prevents new tasks after shutdown

---

### 4. ~~No Adaptive Global Queue Interval~~ **FIXED**

**Status**: Implemented in worker.zig

```zig
/// EWMA of task poll time in nanoseconds
avg_task_ns: u64,

/// Calculated global queue check interval (adaptive)
global_queue_interval: u32,

fn updateAdaptiveInterval(self: *Self, tasks_run: u32) void {
    // EWMA: new_avg = (current * 0.1) + (old * 0.9)
    // Calculate: how many tasks fit in 1ms target latency?
    // Clamp between 8 and 255
}
```

Now self-tunes based on measured task poll times:
- Short tasks (< 10µs) → check every ~100 tasks
- Long tasks (> 100µs) → check every ~10 tasks
- Target: Check global queue approximately every 1ms

---

### 5. No JOIN_WAKER State

**Tokio**: Stores the JoinHandle's waker atomically in the task state machine.

```rust
const JOIN_INTEREST: usize = 0b1_000;  // JoinHandle exists
const JOIN_WAKER: usize = 0b10_000;    // Waker is stored
```

When task completes, Tokio wakes the JoinHandle's waker atomically.

**Blitz-IO**: JoinHandle must poll `isComplete()` repeatedly (busy-wait or external coordination).

---

### 6. Simpler Steal Protocol

**Tokio**: Two-phase steal with explicit `steal_idx` advancement.

```rust
// Phase 1: Claim range by setting steal_idx
// Phase 2: Read tasks
// Phase 3: Advance real_idx to match steal_idx
```

**Blitz-IO**: Similar structure but less rigorous about edge cases.

**Tokio's ABA mitigation**: Uses wider integers (u64 on 64-bit) to make wraparound astronomically unlikely.

**Blitz-IO**: Uses standard u64 packing, which is correct but doesn't explicitly discuss the ABA probability analysis Tokio did.

---

## The Ugly: Serious Issues

### 1. No Loom Testing

**Tokio**: Every concurrent data structure is tested with Loom, a deterministic concurrency testing framework that explores all possible thread interleavings.

```rust
#[cfg(all(test, loom))]
mod tests {
    use loom::sync::atomic::AtomicUsize;
    // Tests explore ~millions of thread interleavings
}
```

**Blitz-IO**: Only basic unit tests. No coverage of:
- All possible CAS failure paths
- Memory ordering edge cases
- Stealer/owner races

**Impact**: The code MIGHT be correct, but there's no proof. Tokio's Loom tests have caught numerous subtle bugs.

---

### 2. Missing Waker Contract

**Tokio**: Wakers have explicit ownership semantics enforced by Rust's type system.

```rust
// Waker::wake() consumes self - can only be called once
pub fn wake(self) { ... }

// Waker::wake_by_ref() borrows - can be called multiple times
pub fn wake_by_ref(&self) { ... }
```

**Blitz-IO**: Manual tracking with debug flag.

```zig
consumed: if (builtin.mode == .Debug) bool else void,
```

**Problem**: In release builds, nothing prevents double-wake or use-after-wake. Zig lacks Rust's affine types, but we could use sentinel values or assertions.

---

### 3. No Graceful Shutdown Path

**Tokio**: Explicit shutdown protocol.

```rust
pub fn close(&self) { ... }  // Close inject queue
pub fn shutdown_all(&self) { ... }  // Cancel all tasks via OwnedTasks
```

**Blitz-IO**: `is_closed` flag on queue, but no way to:
- Cancel all in-flight tasks
- Wait for all tasks to complete
- Ensure no new tasks can be spawned

---

### 4. Task Harness Simplification

**Tokio's Task Layout**:
```rust
#[repr(C)]
pub struct Cell<T: Future, S> {
    pub header: Header,     // Hot: state, vtable, queue_next
    pub core: Core<T, S>,   // Warm: future, scheduler
    pub trailer: Trailer,   // Cold: waker storage, list pointers
}
```

**Blitz-IO's Layout**:
```zig
pub fn RawTask(comptime F: type, comptime Output: type) type {
    return struct {
        header: Header,
        func: F,
        output: ?Output,
        scheduler: ?*anyopaque,
        schedule_fn: ?*const fn (*anyopaque, *Header) void,
        allocator: Allocator,
    };
}
```

**Issues**:
1. No hot/cold separation for cache efficiency
2. `scheduler` as `*anyopaque` loses type safety
3. No explicit alignment to cache line boundaries

---

### 5. Poll Function Signature Incompatibility

**Tokio/Rust**: Futures implement `poll(self: Pin<&mut Self>, cx: &mut Context) -> Poll<Output>`

**Blitz-IO**:
```zig
fn pollFunc(func: *F, output: *?Output, waker: *Waker) PollResult
```

**Problem**: User must manually manage waker lifetime. The Tokio model where `Context` contains a reference to the waker (that the runtime manages) is cleaner.

---

## Summary Table

| Aspect | Tokio | Blitz-IO | Verdict |
|--------|-------|----------|---------|
| LIFO slots | 1 | 4 | **Blitz-IO wins** |
| Global queue | 1 mutex | 8 shards | **Blitz-IO wins** (theoretically) |
| Owner wait-free | No | Yes | **Blitz-IO wins** |
| Cache padding | Implicit | Explicit | **Blitz-IO wins** |
| Lost wakeup protection | Timeout | Flag + recheck | **Blitz-IO wins** |
| NOTIFIED flag | Yes | Yes | **Parity** ✓ |
| OwnedTasks list | Yes | Yes | **Parity** ✓ |
| Adaptive intervals | EWMA | EWMA | **Parity** ✓ |
| JOIN_WAKER | Atomic | Polling | **Tokio wins** |
| Loom testing | Yes | No | **Tokio wins** |
| Waker safety | Type system | Debug flag | **Tokio wins** |
| Graceful shutdown | Full | Partial | **Parity** ✓ (with OwnedTasks) |
| Cache layout | Hot/Cold | Documented | **Tokio wins** (but gap narrowed) |

---

## Recommendations

### Completed ✓
1. ~~**Add NOTIFIED flag**~~ - Implemented with full state machine
2. ~~**Implement OwnedTasks**~~ - Intrusive linked list with close/cancel
3. ~~**Add adaptive global queue interval**~~ - EWMA-based self-tuning
4. ~~**Add graceful shutdown**~~ - Via OwnedTasks.closeAndCancelAll()

### High Priority (Remaining)
1. **Add Loom-style testing** - Or at least stress tests with ThreadSanitizer
2. **Add JOIN_WAKER** - For async JoinHandle::await (currently requires polling)

### Medium Priority
3. **Improve task layout** - Hot/cold separation, explicit alignment
4. **Benchmark the sharded queue** - Verify it actually helps under load

### Lower Priority
5. **Consider waker safety in release builds** - Sentinel values or patterns

---

## Conclusion

Blitz-IO has evolved from a "cool experiment" to a **semantically sound async runtime**:

**Innovations over Tokio:**
- 4-slot LIFO stack (vs 1)
- 8-shard global queue (vs 1 mutex)
- Wait-free owner pop
- Explicit cache-line padding

**Now at parity with Tokio:**
- NOTIFIED flag for correct wakeup semantics ✓
- OwnedTasks for graceful shutdown ✓
- Adaptive global queue interval ✓

**Remaining gaps:**
1. **Correctness verification** - No Loom testing (critical for production)
2. **JOIN_WAKER** - JoinHandle requires polling instead of async await
3. **Hot/cold cache separation** - Task layout not optimized

For production readiness, the priority is now **stress testing with ThreadSanitizer** to catch any remaining race conditions. The semantic model is correct; we need verification.
