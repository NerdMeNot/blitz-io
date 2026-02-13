# Scheduler Internals

This document describes the work-stealing task scheduler that powers blitz-io's async runtime. The scheduler is modeled after Tokio's multi-threaded scheduler with production-grade optimizations for high-throughput task execution.

Source: `src/internal/scheduler/Scheduler.zig`

---

## Overview

The scheduler is a multi-threaded, work-stealing task scheduler. Each worker thread owns a local task queue and participates in cooperative work stealing when idle. Tasks are stackless futures (~256-512 bytes each), enabling millions of concurrent tasks.

### Per-Worker Resources

Each worker owns:

| Resource | Description |
|----------|-------------|
| LIFO slot | Single-task hot cache for the newest scheduled task |
| Local queue | 256-slot lock-free ring buffer (WorkStealQueue) |
| Global batch buffer | 32 pre-fetched tasks from the global queue |
| Park state | Futex-based sleep/wake mechanism |
| Cooperative budget | 128 polls per tick before yielding |
| PRNG | xorshift64+ for randomized steal victim selection |

### Work Finding Priority

When a worker needs a task, it searches in this order:

```
1. Global batch buffer   -- Already-fetched tasks (no lock needed)
2. LIFO slot             -- Newest scheduled task (cache-hot)
3. Local queue           -- Own work-stealing ring buffer (FIFO pop)
4. Global queue          -- Periodic batch fetch (amortizes lock cost)
5. Work stealing         -- Steal half from another worker's queue
6. Global queue (final)  -- One more check before parking
7. Park                  -- Sleep with 10ms timeout until woken
```

---

## WorkStealQueue (Lock-Free Ring Buffer)

Source: `src/internal/scheduler/Header.zig`

The local queue is a 256-slot lock-free ring buffer based on the Chase-Lev work-stealing deque. It supports three operations with different thread-safety guarantees:

### Layout

```
Capacity: 256 slots (compile-time constant)
Head: packed u32 = { steal_head: u16, real_head: u16 }
Tail: atomic u32
Slots: [256]atomic(?*Header)
```

The head is packed into a single `u32` with two 16-bit halves:

- `real_head`: The true consumer position (only the owner reads here).
- `steal_head`: The position up to which stealers have claimed slots.

This two-head design allows the owner to pop from `real_head` while stealers concurrently steal from `steal_head`, without the two operations conflicting. Both heads and the tail are cache-line aligned to prevent false sharing.

### Producer (owner thread only)

**`push(task, global_queue)`**:

1. Write task to `slots[tail % 256]`.
2. Increment tail.
3. If full, **overflow**: move half the queue (128 tasks) to the global queue in a single batch, freeing space.

Push is wait-free for the common case. Overflow amortizes global queue lock cost over 128 tasks.

### Consumer (owner thread only)

**`pop()`** (used for local FIFO scheduling):

1. Read `real_head`.
2. If `real_head == tail`, queue is empty -- return null.
3. Load `slots[real_head % 256]`.
4. CAS the packed head to advance `real_head` by 1 (and `steal_head` if it was behind).
5. Return the task.

Pop is lock-free. The CAS may fail if a stealer is concurrently advancing `steal_head`, in which case the owner retries.

### Stealer (any thread)

**`steal(target_queue)`** -- 3-phase steal of half the queue:

1. **Claim phase**: Atomically read the victim's head and tail. Calculate half the tasks. CAS the head to advance `steal_head`, claiming those slots.
2. **Copy phase**: Copy claimed tasks from the victim's buffer into the stealer's local queue.
3. **Release phase**: CAS the victim's head to advance `real_head`, confirming the steal. If this CAS fails (victim popped concurrently), the steal is abandoned.

The 3-phase protocol ensures correctness without locks. At most one steal operation can succeed at a time per victim (the claim CAS serializes stealers).

---

## LIFO Slot

The LIFO slot is a single-task cache that holds the most recently scheduled task. It exploits temporal locality: a task that was just woken is likely to have hot cache lines, so executing it immediately is faster than queueing it.

### Eviction pattern

When a new task is scheduled on a worker:

1. The new task goes into the LIFO slot (it is the hottest).
2. If the LIFO slot was already occupied, the old task is evicted to the back of the local ring buffer.
3. This ensures the newest task always gets priority.

### Starvation prevention

LIFO slot polls are capped at `MAX_LIFO_POLLS_PER_TICK = 3` per tick. After 3 consecutive LIFO executions, the worker forces a check of the local queue. This prevents a pattern where one task keeps re-scheduling itself into the LIFO slot, starving other queued tasks.

### Lost wakeup prevention

The LIFO slot interacts with the parking mechanism through the `transitioning_to_park` flag:

1. Before a worker starts the parking sequence, it sets `transitioning_to_park = true`.
2. `tryScheduleLocal()` checks this flag. If set, it returns false, forcing the caller to use the global queue instead.
3. This prevents the race where a task is pushed into a LIFO slot just as the worker is about to sleep, which would cause a lost wakeup.

---

## Global Queue

The global queue is a mutex-protected task list. It serves two purposes:

1. **Injection point**: External spawns and cross-worker wakeups push tasks here.
2. **Overflow buffer**: When a worker's local queue overflows, half the tasks are batch-moved to the global queue.

### Batch fetch

Workers pull from the global queue in batches to amortize the lock acquisition cost:

```
Batch size = min(len / num_workers, MAX_GLOBAL_QUEUE_BATCH_SIZE)
Minimum:    MIN_GLOBAL_QUEUE_BATCH_SIZE = 4
Default:    GLOBAL_QUEUE_BATCH_SIZE = 32
Maximum:    MAX_GLOBAL_QUEUE_BATCH_SIZE = 64
```

The fair-share formula `len / num_workers` prevents one worker from draining the entire global queue, ensuring other workers also get tasks.

Fetched tasks are stored in the worker's `global_batch_buffer` (32 slots). Subsequent `findWork()` calls check this buffer first (step 1 in the priority order), avoiding the global queue lock entirely until the buffer is exhausted.

### Adaptive check interval

Workers do not check the global queue on every tick. Instead, the check interval adapts based on task duration using EWMA (Exponential Weighted Moving Average):

```
global_queue_interval = TARGET_LATENCY_NS / avg_task_ns
```

- `TARGET_LATENCY_NS = 1ms` -- target maximum latency for global queue starvation.
- `EWMA_ALPHA = 0.1` -- 10% weight to new measurements.
- Clamped to `[MIN_INTERVAL=8, MAX_INTERVAL=255]`.

Short tasks (sub-microsecond) result in a higher interval (less frequent checks). Long tasks result in more frequent checks to prevent starvation.

---

## Worker Lifecycle

```
              +----------+
              |  RUNNING |
              +----+-----+
                   | no work found
              +----v-----+
              | SEARCHING| (try steal, global queue)
              +----+-----+
                   | nothing found
              +----v-----+
              |  PARKED  | (futex sleep, 10ms timeout)
              +----+-----+
                   | woken by notification
              +----v-----+
              |  RUNNING |
              +----------+
```

### Startup

Workers are spawned during `Runtime.init()`. Each worker thread runs the main loop:

1. Find work (priority order described above).
2. Execute task (poll the future).
3. If future returns `.pending`, transition task to IDLE.
4. If future returns `.ready`, mark task COMPLETE and wake JoinHandle if any.
5. Decrement cooperative budget. If exhausted, reset budget and advance tick.
6. Repeat.

### Parking (futex-based)

When a worker exhausts all work sources, it parks using the futex mechanism:

```zig
const ParkState = struct {
    futex: atomic(u32),  // UNPARKED=0, PARKED=1, NOTIFIED=2

    fn park(timeout_ns) {
        if (cmpxchg(UNPARKED -> PARKED)) {
            futex.timedWait(PARKED, timeout_ns);
        }
        futex.store(UNPARKED);
    }

    fn unpark() {
        prev = futex.swap(NOTIFIED);
        if (prev == PARKED) futex.wake(1);
    }
};
```

Park timeout is 10ms. This ensures workers periodically wake to check for new work even without explicit notification, bounding worst-case latency.

---

## Lost Wakeup Prevention

The "last searcher must notify" protocol prevents lost wakeups -- the scenario where tasks sit in queues while all workers sleep.

### Protocol

1. **Task enqueue**: When a task is enqueued and `num_searching == 0`, one parked worker is woken and enters the "searching" state (`num_searching += 1`).

2. **Searcher finds work**: When a searching worker finds a task and starts executing it, it calls `transitionWorkerFromSearching()`. If it was the LAST searcher (`num_searching` goes from 1 to 0), it wakes another parked worker. This creates a chain reaction: each worker that finds work ensures the next one is awake.

3. **Searcher parks without finding work**: If a searching worker exhausts all sources, it decrements `num_searching` when parking. If it was the last searcher, it performs a final global queue check before sleeping.

### IdleState implementation

```zig
pub const IdleState = struct {
    num_searching: atomic(u32),    // Workers actively looking for tasks
    num_parked: atomic(u32),       // Workers sleeping
    parked_bitmap: atomic(u64),    // Bit per worker: 1=parked, 0=running
    num_workers: u32,
};
```

**Parked worker bitmap**: A 64-bit bitmap where each bit represents one worker. To wake a worker, the scheduler uses `@ctz` (count trailing zeros) to find the lowest-indexed parked worker in O(1), then atomically clears that bit. This is more efficient than Tokio's linear search.

**Searcher limiting**: At most `~50%` of workers can be in the searching state simultaneously. This prevents thundering herd when work suddenly appears -- half the workers search while the other half remain parked, ready to be chain-notified as tasks are found.

```zig
pub fn tryBecomeSearcher(self, num_workers) bool {
    if (2 * num_searching >= num_workers) return false;
    num_searching += 1;
    return true;
}
```

### transitioning_to_park flag

A per-worker flag that prevents the LIFO push race:

1. Worker sets `transitioning_to_park = true`.
2. Worker flushes its LIFO slot to the local queue.
3. Worker parks.
4. On wake, clears `transitioning_to_park = false`.

Without this flag, another thread could push a task into the LIFO slot between steps 2 and 3, and the worker would sleep without executing it.

---

## Cooperative Budgeting

### Budget per tick

Each worker has a budget of `BUDGET_PER_TICK = 128` polls per tick. After 128 polls:

1. The budget resets to 128.
2. The tick counter increments.
3. A maintenance pass runs (adaptive interval recalculation, timer wheel check).

This prevents a single task that returns `.pending` rapidly from monopolizing a worker indefinitely.

### LIFO poll cap

LIFO slot polls are limited to `MAX_LIFO_POLLS_PER_TICK = 3` per tick. After 3 LIFO polls, the worker skips the LIFO slot and checks the local queue. This prevents a pathological case where a task repeatedly reschedules itself into the LIFO slot, starving tasks in the local queue.

### Adaptive global queue interval

The global queue check frequency adapts to observed task duration:

```
new_avg = EWMA_ALPHA * sample_ns + (1 - EWMA_ALPHA) * old_avg
interval = clamp(TARGET_LATENCY / new_avg, MIN_INTERVAL, MAX_INTERVAL)
```

| Task duration | Global queue interval |
|---------------|----------------------|
| 1us | 255 (max -- check rarely) |
| 10us | 100 |
| 50us (default) | 20 |
| 100us | 10 |
| 1ms+ | 8 (min -- check frequently) |

---

## Task State Machine

Source: `src/internal/scheduler/Header.zig`

Each task's lifecycle is tracked by a packed 64-bit atomic state:

```
| ref_count (24 bits) | shield_depth (8 bits) | flags (8 bits) | lifecycle (8 bits) | reserved (16 bits) |
```

### Lifecycle states

```
IDLE ----spawn----> SCHEDULED ----run----> RUNNING ----yield----> IDLE
  |                                           |                     |
  |                                           v                     |
  +-------------------------------------- COMPLETE <----------------+
```

- **IDLE**: Not scheduled. Waiting for I/O, timer, or sync primitive wake.
- **SCHEDULED**: In a run queue. Waiting for a worker to execute it.
- **RUNNING**: Currently being polled by a worker.
- **COMPLETE**: Future returned `.ready`. Result available via JoinHandle.

### Wakeup protocol

The `notified` bit is the sole signal for "task needs to be polled again":

1. When a waker fires while task is IDLE: transition to SCHEDULED and enqueue.
2. When a waker fires while task is RUNNING or SCHEDULED: set `notified` bit.
3. After poll returns `.pending`: atomically transition RUNNING -> IDLE, capturing `notified`.
4. If `notified` was set, immediately reschedule (do not park).

This single-bit protocol replaces the error-prone pattern of separate "waiting" and "notified" flags, which can cause split-brain lost wakeups under contention.

### Reference counting

The 24-bit reference count (up to 16 million refs) tracks ownership:

- Spawn: ref=1 (scheduler owns)
- JoinHandle: ref+1
- Waker clone: ref+1
- Waker drop / JoinHandle drop: ref-1
- When ref reaches 0: deallocate task

### Shield-based cancellation

Shield depth (8 bits, 0-255) implements deferred cancellation:

- `addShield()`: Increments depth. While depth > 0, `isCancellationEffective()` returns false even if the `cancelled` flag is set.
- `removeShield()`: Decrements depth. When depth returns to 0, cancellation takes effect.

This protects critical sections (e.g., a transaction commit) from partial execution due to cancellation.

---

## Configuration

```zig
const Config = struct {
    num_workers: usize = 0,           // 0 = auto (CPU count)
    global_queue_capacity: usize = 65536,
    enable_stealing: bool = true,
    backend_type: ?BackendType = null, // auto-detect
    max_io_completions: u32 = 256,
};
```

### Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `BUDGET_PER_TICK` | 128 | Max polls before maintenance tick |
| `MAX_LIFO_POLLS_PER_TICK` | 3 | LIFO starvation prevention |
| `MAX_GLOBAL_QUEUE_BATCH_SIZE` | 64 | Upper bound on batch fetch |
| `MIN_GLOBAL_QUEUE_BATCH_SIZE` | 4 | Lower bound on batch fetch |
| `GLOBAL_QUEUE_BATCH_SIZE` | 32 | Default batch buffer size |
| `MAX_WORKERS` | 64 | Bitmap width limit |
| `PARK_TIMEOUT_NS` | 10ms | Worker park timeout |
| `TARGET_GLOBAL_QUEUE_LATENCY_NS` | 1ms | Adaptive interval target |
| `EWMA_ALPHA` | 0.1 | Smoothing factor |

---

## Comparison with Tokio

| Feature | blitz-io | Tokio |
|---------|----------|-------|
| Worker wake | O(1) bitmap + @ctz | Linear search |
| LIFO slot | Yes (with eviction) | Yes |
| Local queue | 256-slot lock-free ring | 256-slot lock-free ring |
| Global batch | 32-task buffer | Batch fetch |
| Cooperative budget | 128 polls/tick | 128 polls/tick |
| Adaptive interval | EWMA-based | Fixed interval |
| Searcher limiting | ~50% cap | ~50% cap |
| Park mechanism | Futex with timeout | Condvar |
| Task state | 64-bit packed atomic | 64-bit packed atomic |
| Lost wakeup prevention | transitioning_to_park flag | Similar flag |
