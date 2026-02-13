---
title: Semaphore & Barrier
description: Counting semaphores for limiting concurrency and barriers for synchronizing groups of tasks in blitz-io.
---

## Semaphore

A counting semaphore limits how many tasks can access a resource concurrently. Initialize it with N permits; at most N tasks can hold permits at the same time. When all permits are consumed, subsequent acquirers are suspended until permits are released.

### Initialization

```zig
const io = @import("blitz-io");

// Allow up to 10 concurrent database connections
var sem = io.sync.Semaphore.init(10);
```

No allocator needed. Zero-allocation, no `deinit` required.

### Non-blocking: tryAcquire / release

```zig
if (sem.tryAcquire(1)) {
    defer sem.release(1);
    // Got a permit -- do work
    try handleConnection(conn);
}
```

`tryAcquire` uses a lock-free CAS loop and never blocks. `release` always takes the internal mutex to check for queued waiters (this ensures no wakeups are lost).

You can acquire and release multiple permits at once:

```zig
// Acquire 3 permits for a batch operation
if (sem.tryAcquire(3)) {
    defer sem.release(3);
    try processBatch(items);
}
```

### RAII permit guard

`tryAcquirePermit` returns an optional `SemaphorePermit` that releases automatically:

```zig
if (sem.tryAcquirePermit(1)) |p| {
    var permit = p;
    defer permit.deinit();
    try handleRequest(req);
}
```

Use `permit.forget()` to intentionally leak the permit (useful when transferring ownership):

```zig
var permit = sem.tryAcquirePermit(1).?;
// Transfer ownership to the connection object
connection.permit = permit;
permit.forget(); // Don't release on scope exit
```

### Async: acquire()

`acquire(n)` returns an `AcquireFuture` that yields to the scheduler until N permits are available:

```zig
var future = sem.acquire(2);
// Poll through your runtime...
// When future.poll() returns .ready, permits are held.
defer sem.release(2);
```

The `AcquireFuture` implements the `Future` trait (`Output = void`).

### Low-level: acquireWait with explicit Waiter

```zig
var waiter = io.sync.semaphore.Waiter.init(1);
waiter.setWaker(@ptrCast(&my_ctx), myWakeCallback);

if (!sem.acquireWait(&waiter)) {
    // Waiter queued. Yield to scheduler.
    // When woken, waiter.isComplete() will be true.
}
defer sem.release(1);
```

### Cancellation

Cancel a pending acquisition. Any partially acquired permits are returned to the semaphore:

```zig
sem.cancelAcquire(&waiter);

// Or on the future:
future.cancel();
```

### Diagnostics

```zig
sem.availablePermits();  // usize -- currently available permits
sem.waiterCount();       // usize -- queued waiters (O(n) list walk)
```

### Common patterns

#### Rate limiting

```zig
// Limit to 100 concurrent requests
var rate_limiter = io.sync.Semaphore.init(100);

fn handleIncoming(conn: TcpStream) void {
    if (rate_limiter.tryAcquire(1)) {
        defer rate_limiter.release(1);
        processRequest(conn);
    } else {
        conn.writeAll("429 Too Many Requests\r\n") catch {};
        conn.close();
    }
}
```

#### Connection pool

```zig
const POOL_SIZE = 20;
var pool_sem = io.sync.Semaphore.init(POOL_SIZE);

fn getConnection() !*Connection {
    // Async wait for a connection slot
    var future = pool_sem.acquire(1);
    // ... poll until ready ...
    return pool.checkout();
}

fn releaseConnection(conn: *Connection) void {
    pool.checkin(conn);
    pool_sem.release(1);
}
```

### Algorithm details

blitz-io's semaphore uses a batch algorithm with direct handoff to prevent starvation:

- **tryAcquire**: Lock-free CAS loop (no mutex).
- **release**: Always takes the mutex. Serves queued waiters directly from the released amount. Only surplus permits go to the atomic counter.
- **acquireWait**: Lock-free CAS fast path for full acquisition. If insufficient permits, locks the mutex *before* draining remaining permits, eliminating the classic release-before-queue race.

Key invariant: permits never float in the atomic counter when waiters are queued.

---

## Barrier

A `Barrier` synchronizes N tasks at a common rendezvous point. All N tasks must arrive at the barrier before any can proceed past it.

### Initialization

```zig
// Synchronize 4 worker tasks
var barrier = io.sync.Barrier.init(4);
```

`num_tasks` must be greater than zero. No allocator needed.

### Low-level: waitWith

```zig
var waiter = io.sync.barrier.Waiter.init();
if (barrier.waitWith(&waiter)) {
    // This task was the LAST to arrive (the "leader").
    // All other waiters have been woken.
} else {
    // Waiting for other tasks. Yield to scheduler.
    // When woken, waiter.isReleased() is true.
}

// Check if this task was the leader
if (waiter.is_leader.load(.acquire)) {
    // Perform one-time post-barrier work
    consolidateResults();
}
```

The leader designation is useful for post-barrier work that should happen exactly once (aggregating results, printing summaries, etc.).

### Async: wait()

`wait()` returns a `WaitFuture` that resolves with a `BarrierWaitResult`:

```zig
var future = barrier.wait();
// Poll through your runtime...
// When future.poll() returns .ready:
const result = ...; // BarrierWaitResult
if (result.is_leader) {
    // This task was the last to arrive
    try publishResults();
}
```

### Reusability

Barriers automatically reset after all tasks pass through. This enables multiple synchronization rounds:

```zig
// Round 1
var w1 = io.sync.barrier.Waiter.init();
_ = barrier.waitWith(&w1);
// ... all tasks proceed ...

// Round 2 (barrier automatically reset)
var w2 = io.sync.barrier.Waiter.init();
_ = barrier.waitWith(&w2);
// ... all tasks proceed again ...
```

Each release increments a generation counter:

```zig
barrier.currentGeneration(); // 0, 1, 2, ...
```

### Diagnostics

```zig
barrier.arrivedCount();      // tasks arrived at current barrier
barrier.totalTasks();        // N (configured task count)
barrier.waiterCount();       // tasks waiting (in the queue)
barrier.currentGeneration(); // number of times barrier has released
```

### Example: parallel computation phases

```zig
const NUM_WORKERS = 8;
var barrier = io.sync.Barrier.init(NUM_WORKERS);

fn workerTask(worker_id: usize) void {
    // Phase 1: Compute partial results
    results[worker_id] = computePartial(worker_id);

    // Synchronize -- all workers must finish phase 1
    var waiter = io.sync.barrier.Waiter.init();
    _ = barrier.waitWith(&waiter);

    // Phase 2: Use combined results
    if (waiter.is_leader.load(.acquire)) {
        // Leader merges partial results
        final_result = mergeResults(&results);
    }

    // Synchronize again before reading final_result
    var waiter2 = io.sync.barrier.Waiter.init();
    _ = barrier.waitWith(&waiter2);

    // Phase 3: All workers use the final result
    applyResult(final_result, worker_id);
}
```

### Important notes

- Once a task calls `waitWith` or polls a `WaitFuture`, the arrival count is incremented. Barrier waits **cannot be cancelled** -- the task count has already been committed.
- Waiter objects can be reset and reused across generations with `waiter.reset()`.
- The barrier handles large task counts efficiently (tested with 100+ tasks in unit tests).
