# blitz-io Architecture

## Overview

blitz-io is a production-grade async I/O runtime for Zig, modeled after Tokio's
battle-tested architecture. It uses stackless futures (~256-512 bytes per task)
instead of stackful coroutines (16-64KB per task), enabling millions of
concurrent tasks on commodity hardware.

Version: 0.2.0 | Zig: 0.15.x | Platforms: Linux, macOS, Windows

---

## Layered Architecture

```
+=====================================================================+
|                        User Application                             |
|           io.run(myServer)  /  io.task.spawn(...)                   |
+=====================================================================+
                                |
                                v
+=====================================================================+
|                      Public API Modules                             |
|                                                                     |
|  io.task     io.sync     io.channel    io.net    io.time            |
|  io.fs       io.signal   io.process    io.stream io.shutdown        |
|  io.future   io.async_ops (Timeout, Select, Join, Race)            |
+=====================================================================+
                                |
                                v
+=====================================================================+
|                         Runtime Layer                                |
|                                                                     |
|  +------------------+  +---------------+  +-------------------+     |
|  | Work-Stealing    |  | I/O Driver    |  | Timer Wheel       |     |
|  | Scheduler        |  |               |  |                   |     |
|  |                  |  | Platform      |  | 5 levels, 64      |     |
|  | N workers with   |  | backend       |  | slots/level       |     |
|  | 256-slot ring    |  | abstraction   |  | O(1) insert/poll  |     |
|  | buffers, LIFO    |  |               |  |                   |     |
|  | slot, global     |  +---------------+  +-------------------+     |
|  | injection queue  |                                               |
|  +------------------+  +---------------------------------------+    |
|                        | Blocking Pool                         |    |
|                        | On-demand threads (up to 512)         |    |
|                        | 10s idle timeout, auto-shrink         |    |
|                        +---------------------------------------+    |
+=====================================================================+
                                |
                                v
+=====================================================================+
|                       Platform Backends                             |
|                                                                     |
|  +----------+  +---------+  +--------+  +----------+               |
|  | io_uring |  | kqueue  |  |  IOCP  |  |  epoll   |               |
|  | Linux    |  | macOS   |  | Windows|  | Linux    |               |
|  | 5.1+     |  | 10.12+  |  | 10+    |  | fallback |               |
|  +----------+  +---------+  +--------+  +----------+               |
+=====================================================================+
```

---

## Work-Stealing Scheduler

The scheduler is the heart of blitz-io. It distributes tasks across worker
threads using a work-stealing algorithm derived from Tokio's multi-threaded
scheduler.

Source: `src/internal/scheduler/Scheduler.zig`

### Per-Worker Structure

Each worker thread owns:

```
+------------------------------------------------------------------+
| Worker N                                                         |
+------------------------------------------------------------------+
| LIFO Slot        | Single task for immediate execution           |
|                  | Newest task always goes here (cache-hot)      |
+------------------+-----------------------------------------------+
| WorkStealQueue   | 256-slot lock-free ring buffer (FIFO)         |
|                  | Owner pushes to tail, pops from head          |
|                  | Stealers steal half from head                 |
+------------------+-----------------------------------------------+
| Global Batch     | 32-task buffer pre-fetched from global queue  |
| Buffer           | Amortizes lock acquisition cost               |
+------------------+-----------------------------------------------+
| Park State       | Futex-based sleep/wake mechanism              |
+------------------+-----------------------------------------------+
| Budget           | 128 polls per tick (cooperative scheduling)   |
+------------------+-----------------------------------------------+
| PRNG             | xorshift64+ for random victim selection       |
+------------------+-----------------------------------------------+
| EWMA Timer       | Adaptive global queue check interval          |
+------------------+-----------------------------------------------+
```

### Work-Finding Priority

When a worker needs a task, it searches in this order:

```
1. Pre-fetched Global Batch  -- Tasks already pulled from global queue
       |
       v (empty)
2. Local Queue               -- LIFO slot first, then ring buffer
       |
       v (empty)
3. Global Queue (periodic)   -- Every N ticks (adaptive interval)
       |
       v (empty)
4. Work Stealing             -- Steal half from a random victim
       |
       v (nothing found)
5. Global Queue (final)      -- One last check before sleeping
       |
       v (empty)
6. Park                      -- Sleep with futex, timeout-based wake
```

### Lock-Free Ring Buffer (WorkStealQueue)

The local run queue is a 256-slot lock-free single-producer, multi-consumer
ring buffer. The design is based on the Chase-Lev deque.

Source: `src/internal/scheduler/Header.zig` (WorkStealQueue)

```
Ring Buffer (256 slots):
+---+---+---+---+---+---+---+---+---+---+
| 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | . | . |  ...  | 255 |
+---+---+---+---+---+---+---+---+---+---+
  ^                   ^
  |                   |
  head (consumers)    tail (owner only)
```

The head is packed as two `u32` values into a single `u64` for atomic CAS:

```
head = [steal_head (upper 32) | real_head (lower 32)]
```

- When `steal_head == real_head`: no stealer is active.
- When `steal_head != real_head`: a steal is in progress. The producer must
  not overflow past `steal_head`.

Steal protocol (three phases):

1. **Claim** -- CAS `src.head` to advance `real_head` by half, keeping
   `steal_head` unchanged. This reserves the tasks for the stealer.
2. **Copy** -- Copy tasks from the source buffer to the destination buffer.
   The first stolen task is returned directly to the caller.
3. **Release** -- CAS `src.head` to advance `steal_head` to match `real_head`,
   signaling that the steal is complete.

When the ring buffer is full:
- If no stealer is active: overflow half to the global queue, then push.
- If a stealer is active: push directly to the global queue.

### LIFO Slot

The LIFO slot is a single atomic pointer separate from the ring buffer. It
provides cache locality by ensuring the newest task (most likely to reuse hot
cache lines) runs immediately.

LIFO eviction policy: when a new task is pushed, it always goes into the LIFO
slot. If the slot was occupied, the old task is evicted to the ring buffer.

```
Push task T3:
  LIFO: [T2] --> LIFO: [T3], ring buffer: [..., T2]
```

LIFO starvation prevention: a maximum of 3 LIFO polls per tick
(`MAX_LIFO_POLLS_PER_TICK`). After the cap, the LIFO slot is flushed to the
ring buffer so its task becomes visible to the FIFO order and to stealers.

### Global Queue

The global injection queue is a mutex-protected intrusive linked list with an
atomic length counter for lock-free emptiness checks.

```zig
pub const GlobalTaskQueue = struct {
    queue: TaskQueue = .{},
    mutex: std.Thread.Mutex = .{},
    atomic_len: std.atomic.Value(usize) = ...,
};
```

Batch operations reduce mutex contention:

- `popBatch(out, n)` pulls up to N tasks in a single lock acquisition.
- `pushBatch(tasks)` pushes multiple tasks in a single lock acquisition.
- Adaptive batch size: `min(64, max(4, global_len / num_workers))`.

### Cooperative Budgeting

Each worker has a budget of 128 polls per tick (`BUDGET_PER_TICK`). After
exhausting the budget, the worker resets its counters and checks for
maintenance tasks (timer polling, I/O completions). This prevents a single
long-running task from starving I/O and timers.

The LIFO cap of 3 per tick (`MAX_LIFO_POLLS_PER_TICK`) ensures the main queue
is not starved by repeated LIFO hits.

### Adaptive Global Queue Interval

Workers check the global queue every N ticks, where N is computed from an
exponentially weighted moving average (EWMA) of task poll durations:

```
new_avg = (current_avg * 0.1) + (old_avg * 0.9)
interval = clamp(TARGET_LATENCY / avg_task_time, 8, 255)
```

Target latency is 1ms. Short tasks (e.g., 10us) lead to frequent checks
(interval ~100). Long tasks (e.g., 100us) lead to infrequent checks
(interval ~10). This self-tunes to maintain global queue responsiveness.

### Worker Parking and the "Last Searcher Must Notify" Protocol

When a worker has no work, it parks using a futex-based mechanism. The parking
protocol prevents lost wakeups through a bitmap-based coordination system.

Source: `src/internal/scheduler/Scheduler.zig` (IdleState)

**State tracking:**

```zig
pub const IdleState = struct {
    num_searching: std.atomic.Value(u32),   // Workers actively looking for work
    num_parked: std.atomic.Value(u32),      // Workers sleeping
    parked_bitmap: std.atomic.Value(u64),   // Bit per worker: 1 = parked
    num_workers: u32,
};
```

**The protocol:**

1. When a task is enqueued and `num_searching == 0`, one parked worker is
   claimed from the bitmap (using `@ctz` for O(1) lookup) and woken. It
   enters the "searching" state (`num_searching += 1`).

2. When a searching worker finds work, it calls `transitionFromSearching()`.
   If it was the LAST searcher (`num_searching` goes to 0), it wakes another
   parked worker to continue the chain.

3. This chain reaction ensures all queued tasks eventually get processed.

4. When a searching worker parks without finding work, it decrements
   `num_searching`. If it was the last searcher, it does a final check of
   all queues before sleeping.

**Lost wakeup prevention:**

Workers set a `transitioning_to_park` flag before flushing their LIFO slot.
While this flag is set, task producers use the global queue instead of the
worker's LIFO slot, preventing the race where a task is pushed to a LIFO slot
that is about to be flushed.

**Searcher limiting:**

At most ~50% of workers can be searching simultaneously. This prevents
thundering herd behavior when work appears after an idle period.

---

## Task State Machine

Every task in blitz-io is tracked by a type-erased `Header` with a 64-bit
packed atomic state word.

Source: `src/internal/scheduler/Header.zig`

### State Layout

```
 63                  40  39       32  31     24  23     16  15      0
+----------------------+-----------+---------+-----------+----------+
|    ref_count (24)    | shield(8) | flags(8)| lifecycle | reserved |
+----------------------+-----------+---------+-----------+----------+
```

- **ref_count** (24 bits): Reference counting for memory safety. Maximum 16
  million references. Incremented on spawn and waker clone, decremented on
  drop and waker drop. When it reaches zero, the task is freed.

- **shield_depth** (8 bits): Cancellation shield counter. While > 0,
  cancellation is deferred. Protects critical sections from partial execution.

- **flags** (8 bits):
  - `notified`: A waker fired while the task was Running or Scheduled.
  - `cancelled`: Cancellation was requested.
  - `join_interest`: A JoinHandle is waiting for the result.
  - `detached`: The JoinHandle was detached.

- **lifecycle** (8 bits): Current execution state.

### Lifecycle Transitions

```
                    spawn()
        +---------- IDLE --------+
        |            ^           |
        |            |           |
        v       transitionToIdle |
    SCHEDULED        |           |
        |            |           |
        |  transitionToRunning   |
        +------> RUNNING -------+
                     |
                     | transitionToComplete
                     v
                  COMPLETE
```

**Critical path -- the wakeup protocol:**

When a waker fires (e.g., a mutex is unlocked, a timer expires):

- If the task is **IDLE**: transition to SCHEDULED and queue it. Return `true`
  to the caller, who must enqueue the task.
- If the task is **RUNNING** or **SCHEDULED**: set the `notified` bit. Return
  `false` -- the task is already in the system.

After `poll()` returns `.pending`:

1. `transitionToIdle()` atomically clears the `notified` bit and returns the
   previous state.
2. If `prev.notified` was `true`, the task is immediately rescheduled. This
   is essential to prevent lost wakeups when a waker fires while the task is
   still running.

All state transitions use CAS loops with `acq_rel` / `acquire` ordering.

### Type Erasure

Tasks are type-erased through a vtable:

```zig
pub const VTable = struct {
    poll: *const fn (*Header) PollResult_,
    drop: *const fn (*Header) void,
    schedule: *const fn (*Header) void,
    reschedule: *const fn (*Header) void,
};
```

`FutureTask(F)` wraps any Future type into a task:

```zig
pub fn FutureTask(comptime F: type) type {
    return struct {
        header: Header,       // Must be first field for @fieldParentPtr
        future: F,            // The user's future (state machine)
        result: ?F.Output,    // Result storage
        allocator: Allocator, // For cleanup
        scheduler: ?*anyopaque,
        schedule_fn: ?*const fn (*anyopaque, *Header) void,
        reschedule_fn: ?*const fn (*anyopaque, *Header) void,
    };
}
```

The scheduler only ever sees `*Header` pointers. The vtable dispatches to the
concrete `FutureTask(F)` implementation via `@fieldParentPtr`.

### Waker Design

Wakers are 16-byte value types (pointer + vtable pointer) that know how to
reschedule their associated task:

```zig
pub const Waker = struct {
    raw: RawWaker,
};

pub const RawWaker = struct {
    data: *anyopaque,     // Pointer to Header
    vtable: *const VTable,

    pub const VTable = struct {
        wake: *const fn (*anyopaque) void,        // Consume and wake
        wake_by_ref: *const fn (*anyopaque) void,  // Wake without consuming
        clone: *const fn (*anyopaque) RawWaker,    // Clone (ref++)
        drop: *const fn (*anyopaque) void,         // Drop (ref--)
    };
};
```

`wake()` calls `header.schedule()` which invokes `transitionToScheduled()`.
If the task transitions from IDLE to SCHEDULED, the schedule callback pushes
it to the current worker's LIFO slot (if on a worker thread) or the global
queue (otherwise).

---

## Timer Wheel

The timer wheel provides O(1) timer insertion and O(1) expiration checking
using a hierarchical design with bit-manipulation optimizations.

Source: `src/internal/scheduler/TimerWheel.zig`

### Structure

```
Level 0:  64 slots x   1ms =    64ms range
Level 1:  64 slots x  64ms =   4.1s range
Level 2:  64 slots x   4s  =   4.3m range
Level 3:  64 slots x   4m  =   4.5h range
Level 4:  64 slots x   4h  =  10.7d range
Overflow: linked list for timers beyond ~10 days
```

Each level has a 64-bit occupancy bitfield. When a slot contains at least one
timer, its bit is set.

### O(1) Insertion

Level selection uses `@clz` (count leading zeros) on the XOR of current time
and deadline, both converted to level-0 tick units:

```zig
inline fn levelFor(now_ns: u64, deadline_ns: u64) usize {
    const elapsed_ticks = now_ns / LEVEL_0_SLOT_NS;
    const when_ticks = deadline_ns / LEVEL_0_SLOT_NS;
    const masked = (elapsed_ticks ^ when_ticks) | SLOT_MASK;
    const leading_zeros = @clz(masked);
    const significant_bit = 63 - leading_zeros;
    return significant_bit / BITS_PER_LEVEL;
}
```

This replaces the naive O(N_LEVELS) linear scan with a single bit operation.

### O(1) Next-Expiry

Finding the next timer to fire uses `@ctz` (count trailing zeros) on the
occupancy bitfield, starting from the current slot:

```zig
pub fn nextOccupiedSlot(self: *const Level, from_slot: usize) ?usize {
    const from_mask = ~((@as(u64, 1) << @intCast(from_slot)) - 1);
    const masked = self.occupied & from_mask;
    if (masked != 0) return @ctz(masked);
    // Wrap around...
}
```

### Cascading

When level 0's current slot wraps around to 0, timers from level 1's current
slot are cascaded down (re-inserted at level 0 with more precise placement).
This cascading propagates upward: if level 1 wraps, level 2 cascades down,
and so on.

### Timer Entries

Timer entries are intrusive -- they contain their own linked-list pointers
and can be either heap-allocated (by the wheel) or stack-allocated (by the
caller). Each entry can wake via a task header pointer or a generic waker
function callback.

```zig
pub const TimerEntry = struct {
    deadline_ns: u64,
    task: ?*Header,          // Task-based waking
    waker: ?WakerFn,         // Generic waker callback
    waker_ctx: ?*anyopaque,
    next: ?*TimerEntry,      // Intrusive list
    prev: ?*TimerEntry,
    cancelled: bool,
    heap_allocated: bool,
};
```

Worker 0 is the primary timer driver. It polls the timer wheel at the start
of each tick. Other workers contribute to I/O polling but not timer polling,
avoiding contention on the timer mutex.

---

## I/O Driver

The I/O driver abstracts platform-specific async I/O backends behind a
unified interface. The scheduler owns the I/O backend and polls for
completions on each tick.

Source: `src/internal/backend.zig`

### Backend Selection

```
Platform         Primary Backend    Fallback
-----------      ----------------   --------
Linux 5.1+       io_uring           epoll
Linux < 5.1      epoll              poll
macOS 10.12+     kqueue             poll
Windows 10+      IOCP               --
Other            poll               --
```

Backend selection is automatic by default (`backend_type: ?BackendType = null`)
or can be forced via configuration.

### Completion Model

All backends expose the same interface:

```zig
pub const Backend = struct {
    pub fn init(allocator: Allocator, config: Config) !Backend;
    pub fn deinit(self: *Backend) void;
    pub fn submit(self: *Backend, op: Operation) !SubmissionId;
    pub fn wait(self: *Backend, completions: []Completion, timeout_ms: u32) !usize;
};
```

Completions carry a `user_data` field that contains the task header pointer.
When a completion arrives, the scheduler transitions the associated task to
SCHEDULED and enqueues it:

```zig
fn processCompletion(self: *Self, completion: Completion) void {
    if (completion.user_data != 0) {
        const task: *Header = @ptrFromInt(completion.user_data);
        if (task.transitionToScheduled()) {
            task.ref();
            self.global_queue.push(task);
            self.wakeWorkerIfNeeded();
        }
    }
}
```

### Polling Strategy

I/O polling is distributed across all workers:

- Any worker can poll I/O by attempting `io_mutex.tryLock()`.
- Only one worker polls at a time (non-blocking tryLock prevents contention).
- Polling uses zero timeout (non-blocking) during normal operation.
- During parking, worker 0 may use the timer-based timeout for combined
  I/O + timer waiting.

---

## Blocking Pool

The blocking pool handles CPU-intensive or synchronous blocking work on
dedicated threads, separate from the async I/O workers. This prevents
blocking operations from starving async tasks.

Source: `src/internal/blocking.zig`

### Design

- **Dynamic scaling**: threads spawn on demand, up to a configurable cap
  (default: 512).
- **Idle timeout**: threads exit after 10 seconds of inactivity.
- **Self-cleanup**: exiting threads join the previous exiting thread,
  preventing handle leaks.
- **Intrusive task queue**: zero-allocation task dispatching.
- **Spurious wakeup handling**: `num_notify` counter ensures correct
  wakeup behavior.

### Usage from the Runtime

```zig
// From outside async context:
var handle = try rt.spawnBlocking(computeHash, .{large_data});
const hash = try handle.wait();

// From inside async context:
const hash = try io.task.spawnBlocking(computeHash, .{data});
```

---

## Synchronization Primitives

All sync primitives are async-aware: when contended, they yield to the
scheduler instead of blocking the OS thread. Waiters are intrusive
(embedded in the Future struct), requiring zero allocation per wait.

Source: `src/sync/`

### Mutex

Built on `Semaphore(1)`. The mutex reduces to a single-permit semaphore,
inheriting all of the semaphore's correctness guarantees.

```zig
pub const Mutex = struct {
    sem: Semaphore,

    pub fn tryLock(self: *Self) bool {
        return self.sem.tryAcquire(1);
    }

    pub fn unlock(self: *Self) void {
        self.sem.release(1);
    }

    pub fn lock(self: *Self) LockFuture { ... }
};
```

### RwLock

Allows multiple concurrent readers or one exclusive writer. The
implementation uses a state machine tracking reader count and writer
presence, with a waiter queue for contended access.

### Semaphore

Counting semaphore with a proven anti-starvation algorithm:

- `release()` always takes the mutex to check the waiter queue.
- `acquireWait()` locks before the CAS, eliminating the permit starvation
  race where permits "slip through" between CAS and queue insertion.
- Permits go directly to waiters, preventing indefinite starvation.

### Barrier

Generation-based barrier. N tasks call `wait()`. The Nth task (the "leader")
wakes all others. A generation counter prevents waiters from the previous
round from interfering with the current round.

### Notify

Permit-based task notification. `notify_one()` stores a permit or wakes one
waiter. `notify_waiters()` wakes all waiters. Permits are one-shot: each
`notified()` call consumes one permit.

### OnceCell

CAS-based lazy initialization. Multiple tasks can race to initialize; only
one succeeds. Others wait on a waiter queue and are woken when initialization
completes.

```
State Machine:
  UNINITIALIZED --CAS--> INITIALIZING --set--> INITIALIZED
                              |
                     (concurrent callers wait)
```

---

## Channel Design

Source: `src/channel/`

### Channel (Bounded MPMC)

Lock-free Vyukov ring buffer with per-slot sequence numbers:

```
Slot Layout:
+--------------------------------------------------+
| sequence: atomic(usize) | value: T               |
+--------------------------------------------------+

Ring Buffer:
  slot[0]  slot[1]  slot[2]  ...  slot[capacity-1]
    ^                                     ^
    |                                     |
    head (consumers, atomic CAS)          tail (producers, atomic CAS)
```

Algorithm:
- Each slot has a sequence counter initialized to its index.
- To send at position `tail`: if `slot.sequence == tail`, the slot is
  writable. After writing, set `slot.sequence = tail + 1`.
- To receive at position `head`: if `slot.sequence == head + 1`, the slot
  has data. After reading, set `slot.sequence = head + capacity`.
- All operations are lock-free CAS loops on head/tail.

A separate `waiter_mutex` protects the waiter lists for async send/recv
futures. It never touches the hot data path.

### Oneshot

Single-value delivery channel with a 4-state atomic state machine:

```
State Machine:
  EMPTY --------send()--------> VALUE_SENT
    |                               |
    +--recvWait()---> RECEIVER_WAITING
    |                               |
    +--close()-----> CLOSED         |
                                    +--recv()--> (value delivered)
```

Zero-allocation: sender and receiver are value types with a shared state
pointer. Thread-safe through atomic state transitions.

### BroadcastChannel

Tail-index ring buffer where each receiver tracks its own read position:

```
Writer:  tail -->  [slot 0] [slot 1] [slot 2] [slot 3] ...
Reader A: pos=1 ----^
Reader B: pos=3 ----------------^
```

All receivers get all messages. If a receiver falls behind and the writer
laps it, the receiver skips to the current tail (missed messages are lost).

### Watch

Single-value container with a generation counter. Receivers wait for the
generation to change:

```
Writer: send(new_value)  -->  value = new_value, generation++
Reader: changed()        -->  (blocks until generation > last_seen)
```

---

## Runtime Lifecycle

### Initialization

```zig
var rt = try Runtime.init(allocator, .{
    .num_workers = 0,              // Auto-detect (CPU count)
    .max_blocking_threads = 512,   // Blocking pool cap
    .backend = null,               // Auto-detect I/O backend
});
```

Initialization creates:
1. The Scheduler (allocates workers, ring buffers, idle state)
2. The I/O Backend (auto-detects platform)
3. The Timer Wheel (5 levels, overflow list)
4. The Blocking Pool (no threads yet -- spawned on demand)

Workers are NOT started until the first task is spawned (lazy start).

### Task Spawning

```
Runtime.spawn(F, future)
    |
    +--> FutureTask(F).create(allocator, future)
    |        |
    |        +--> Sets up vtable, result storage, scheduler callbacks
    |
    +--> Scheduler.spawn(&task.header)
             |
             +--> transitionToScheduled() (IDLE -> SCHEDULED)
             +--> task.ref() (scheduler holds a reference)
             +--> global_queue.push(task)
             +--> wakeWorkerIfNeeded()
```

### Task Execution

```
Worker.executeTask(task)
    |
    +--> transitionFromSearching()    // Chain notification protocol
    |
    +--> task.transitionToRunning()   // SCHEDULED -> RUNNING
    |
    +--> task.poll()                  // Calls FutureTask.pollImpl()
    |        |
    |        +--> future.poll(&ctx)   // User's Future.poll()
    |
    +--> (result = .complete)
    |        |
    |        +--> task.transitionToComplete()
    |        +--> task.unref() -> task.drop() if last ref
    |
    +--> (result = .pending)
             |
             +--> prev = task.transitionToIdle()  // RUNNING -> IDLE
             |        (atomically clears notified, returns prev state)
             |
             +--> if prev.notified:
                      task.transitionToScheduled()
                      worker.tryScheduleLocal(task) or global_queue.push(task)
```

### Shutdown

```
Runtime.deinit()
    |
    +--> blocking_pool.deinit()      // Drain queue, join all threads
    |
    +--> scheduler.shutdown.store(true)
    |
    +--> Wake all workers (futex)
    |
    +--> Each worker:
    |        +--> Drain LIFO slot (cancel + drop)
    |        +--> Drain run queue (cancel + drop)
    |        +--> Drain batch buffer (cancel + drop)
    |        +--> Thread exits
    |
    +--> Join all worker threads
    |
    +--> timer_wheel.deinit() (free heap-allocated entries)
    +--> backend.deinit()
    +--> Free workers array, completions buffer
```

---

## Thread-Local Context

Each worker thread has thread-local storage for runtime context:

```zig
threadlocal var current_worker_idx: ?usize = null;
threadlocal var current_scheduler: ?*Scheduler = null;
threadlocal var current_header: ?*Header = null;
```

- `current_worker_idx`: Used by schedule callbacks to push to the local LIFO
  slot instead of the global queue.
- `current_scheduler`: Used by `io.task.spawn()` and sleep/timeout to access
  the scheduler from within a task.
- `current_header`: Used by async primitives (sleep, mutex.lock) to find the
  currently executing task and register wakers.

---

## Cache Line Alignment

Source: `src/internal/util/cacheline.zig`

Critical data structures use cache-line alignment to prevent false sharing:

```
Architecture          Cache Line Size
-----------           ---------------
x86_64, aarch64       128 bytes (spatial prefetcher)
PowerPC64             128 bytes
ARM, MIPS, SPARC      32 bytes
s390x                 256 bytes
Others (RISC-V, WASM) 64 bytes
```

The `WorkStealQueue` aligns its `head`, `tail`, and `buffer` fields to
separate cache lines:

```zig
head: std.atomic.Value(u64) align(CACHE_LINE_SIZE),
tail: std.atomic.Value(u32) align(CACHE_LINE_SIZE),
buffer: [CAPACITY]std.atomic.Value(?*Header) align(CACHE_LINE_SIZE),
```

This ensures that the producer (writing `tail`) and consumers (reading/writing
`head`) do not cause false-sharing cache invalidations.

---

## Statistics and Observability

The scheduler tracks per-worker and global statistics:

```zig
pub const Stats = struct {
    total_spawned: u64,    // Total tasks ever spawned
    total_polled: u64,     // Total poll() calls across all workers
    total_stolen: u64,     // Total work-stealing operations
    total_parked: u64,     // Total times workers parked
    num_workers: usize,    // Number of worker threads
};
```

Per-worker stats include:
- `tasks_polled`: Number of tasks polled by this worker
- `tasks_stolen`: Number of tasks stolen from other workers
- `times_parked`: Number of times this worker parked
- `lifo_hits`: Number of LIFO slot hits
- `global_batch_fetches`: Number of global queue batch pulls

The blocking pool provides:
- `threadCount()`: Current number of threads
- `idleCount()`: Number of idle threads
- `pendingTasks()`: Number of tasks in the queue

---

## Key Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `BUDGET_PER_TICK` | 128 | Max polls per tick per worker |
| `MAX_LIFO_POLLS_PER_TICK` | 3 | LIFO cap to prevent starvation |
| `MAX_GLOBAL_QUEUE_BATCH_SIZE` | 64 | Max tasks per global batch pull |
| `GLOBAL_QUEUE_BATCH_SIZE` | 32 | Default batch size |
| `MIN_GLOBAL_QUEUE_BATCH_SIZE` | 4 | Min batch (amortize lock cost) |
| `MAX_WORKERS` | 64 | Max workers (bitmap width) |
| `PARK_TIMEOUT_NS` | 10ms | Default park timeout |
| `WorkStealQueue.CAPACITY` | 256 | Ring buffer slots per worker |
| `NUM_LEVELS` | 5 | Timer wheel levels |
| `SLOTS_PER_LEVEL` | 64 | Slots per timer wheel level |
| `LEVEL_0_SLOT_NS` | 1ms | Level 0 timer resolution |
| `MAX_WHEEL_DURATION` | ~10.7 days | Max timer before overflow |
| `EWMA_ALPHA` | 0.1 | Adaptive interval smoothing |
| `TARGET_GLOBAL_QUEUE_LATENCY_NS` | 1ms | Target global queue check latency |

---

## Comparison with Tokio

blitz-io closely follows Tokio's architecture with Zig-specific adaptations:

| Component | Tokio | blitz-io |
|-----------|-------|----------|
| Task state | `AtomicUsize` with bit packing | `packed struct(u64)` with CAS |
| Work-steal queue | Chase-Lev deque (256 slots) | Chase-Lev deque (256 slots) |
| LIFO slot | Separate atomic pointer | Separate atomic pointer |
| Global queue | `Mutex<VecDeque>` | `Mutex` + intrusive linked list |
| Timer wheel | Hierarchical (6 levels) | Hierarchical (5 levels) |
| Worker parking | `AtomicUsize` packed state | Bitmap + futex |
| Idle coordination | `num_searching` counter | `num_searching` + parked bitmap |
| Worker wakeup | Linear scan for idle worker | O(1) `@ctz` on bitmap |
| I/O driver | mio (epoll/kqueue/IOCP) | Direct platform backends |
| Waker | `RawWaker` + vtable | `RawWaker` + vtable (same pattern) |
| Blocking pool | `spawn_blocking()` | `spawnBlocking()` |
| Cooperative budget | 128 polls per tick | 128 polls per tick |
