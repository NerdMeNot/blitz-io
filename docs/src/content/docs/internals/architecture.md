---
title: Architecture Overview
description: High-level architecture of the blitz-io runtime -- how the scheduler, I/O driver, timer wheel, and blocking pool fit together.
---

blitz-io is a production-grade async I/O runtime for Zig, modeled after Tokio's battle-tested architecture. It uses stackless futures (~256--512 bytes per task) instead of stackful coroutines (16--64KB per task), enabling millions of concurrent tasks on commodity hardware.

## Layered architecture

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

## Key components

### Runtime (`src/runtime.zig`)

The `Runtime` struct is the top-level entry point. It owns and coordinates all other components:

```zig
pub const Runtime = struct {
    allocator: Allocator,
    sched_runtime: *SchedulerRuntime,  // Owns the scheduler
    blocking_pool: BlockingPool,        // Dedicated blocking threads
    shutdown: std.atomic.Value(bool),
};
```

Users interact with the runtime through `init`, `spawn`, and `deinit`:

```zig
var rt = try Runtime.init(allocator, .{
    .num_workers = 0,              // Auto-detect (CPU count)
    .max_blocking_threads = 512,
    .backend = null,               // Auto-detect I/O backend
});
defer rt.deinit();

var handle = try rt.spawn(MyFuture, my_future);
_ = handle.blockingJoin();
```

### Scheduler (`src/internal/scheduler/Scheduler.zig`)

The heart of the runtime. A multi-threaded, work-stealing task scheduler derived from Tokio's multi-threaded scheduler. Each worker thread owns a local task queue and participates in cooperative work stealing when idle. See the [Scheduler](/internals/scheduler/) page for full details.

### I/O driver (`src/internal/backend.zig`)

Abstracts platform-specific async I/O behind a unified `Backend` interface. The scheduler owns the I/O backend and polls for completions on each tick. See the [I/O Driver](/internals/io-driver/) page.

### Timer wheel (`src/internal/scheduler/TimerWheel.zig`)

A hierarchical timer wheel with 5 levels and 64 slots per level, providing O(1) insertion and O(1) next-expiry lookup using bit-manipulation. Covers durations from 1ms to ~10.7 days, with an overflow list for longer timers.

```
Level 0:  64 slots x   1ms =    64ms range
Level 1:  64 slots x  64ms =   4.1s range
Level 2:  64 slots x   4s  =   4.3m range
Level 3:  64 slots x   4m  =   4.5h range
Level 4:  64 slots x   4h  =  10.7d range
Overflow: linked list for timers beyond ~10 days
```

Worker 0 is the primary timer driver. It polls the timer wheel at the start of each tick. Other workers contribute to I/O polling but not timer polling, avoiding contention on the timer mutex.

### Blocking pool (`src/internal/blocking.zig`)

A separate thread pool for CPU-intensive or synchronous blocking work. Threads are spawned on demand and exit after 10 seconds of idleness. See the [Blocking Pool](/internals/blocking-pool/) page.

## Thread model

blitz-io uses three categories of threads:

```
+--------------------------------------------+
|  Worker Threads (N, default = CPU count)   |
|  - Run the scheduler loop                  |
|  - Poll futures (async tasks)              |
|  - Poll I/O completions                    |
|  - Poll timers (worker 0 only)             |
+--------------------------------------------+

+--------------------------------------------+
|  Blocking Pool Threads (0 to 512)          |
|  - Spawned on demand                       |
|  - CPU-intensive or blocking I/O           |
|  - 10s idle timeout, auto-shrink           |
+--------------------------------------------+
```

Worker threads are created during `Runtime.init()` and run until `deinit()`. Blocking pool threads are created dynamically when `spawnBlocking()` is called and no idle thread is available.

### Thread-local context

Each worker thread has thread-local storage for runtime context:

```zig
threadlocal var current_worker_idx: ?usize = null;
threadlocal var current_scheduler: ?*Scheduler = null;
threadlocal var current_header: ?*Header = null;
```

- `current_worker_idx` -- Used by schedule callbacks to push to the local LIFO slot instead of the global queue.
- `current_scheduler` -- Used by `io.task.spawn()` and sleep/timeout to access the scheduler from within a task.
- `current_header` -- Used by async primitives (sleep, mutex.lock) to find the currently executing task and register wakers.

## How components interact

### Task spawning flow

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

### Task execution flow

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

### I/O completion flow

```
Worker tick
    |
    +--> scheduler.pollIo()
    |        |
    |        +--> io_mutex.tryLock()  // Non-blocking, only one worker polls
    |        +--> backend.wait(completions, timeout=0)
    |        +--> for each completion:
    |                 task = @ptrFromInt(completion.user_data)
    |                 task.transitionToScheduled()
    |                 global_queue.push(task)
    |                 wakeWorkerIfNeeded()
    |
    +--> scheduler.pollTimers()  // Worker 0 only
             |
             +--> timer_mutex.lock()
             +--> timer_wheel.poll()
             +--> wake expired tasks
```

### Shutdown flow

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

## Key constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `BUDGET_PER_TICK` | 128 | Max polls per tick per worker |
| `MAX_LIFO_POLLS_PER_TICK` | 3 | LIFO cap to prevent starvation |
| `MAX_GLOBAL_QUEUE_BATCH_SIZE` | 64 | Max tasks per global batch pull |
| `MAX_WORKERS` | 64 | Max workers (bitmap width) |
| `PARK_TIMEOUT_NS` | 10ms | Default park timeout |
| `WorkStealQueue.CAPACITY` | 256 | Ring buffer slots per worker |
| `NUM_LEVELS` | 5 | Timer wheel levels |
| `SLOTS_PER_LEVEL` | 64 | Slots per timer wheel level |
| `LEVEL_0_SLOT_NS` | 1ms | Level 0 timer resolution |

## Source files

| File | Purpose |
|------|---------|
| `src/runtime.zig` | Top-level Runtime struct |
| `src/internal/scheduler/Scheduler.zig` | Work-stealing scheduler |
| `src/internal/scheduler/Header.zig` | Task state machine + WorkStealQueue |
| `src/internal/scheduler/TimerWheel.zig` | Hierarchical timer wheel |
| `src/internal/scheduler/Runtime.zig` | Scheduler runtime wrapper |
| `src/internal/blocking.zig` | Blocking thread pool |
| `src/internal/backend.zig` | Platform I/O backend interface |
| `src/internal/backend/kqueue.zig` | macOS kqueue backend |
| `src/internal/backend/io_uring.zig` | Linux io_uring backend |
| `src/internal/backend/epoll.zig` | Linux epoll backend |
| `src/internal/backend/iocp.zig` | Windows IOCP backend |
