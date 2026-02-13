---
title: Basic Concepts
description: Understand the fundamental programming model of blitz-io -- futures, polling, wakers, the runtime, tasks, and cooperative scheduling.
sidebar:
  order: 3
---

blitz-io uses a **stackless future** model for async programming. This page explains the core concepts you need to understand before writing async code.

## Futures and Polling

A **Future** is a value that represents an async computation that may not have completed yet. Instead of blocking a thread while waiting for I/O, a future returns `.pending` and lets the runtime do other work.

### The Future Protocol

Every future in blitz-io implements the same protocol:

```zig
const MyFuture = struct {
    pub const Output = i32; // The type this future produces

    pub fn poll(self: *@This(), ctx: *io.future.Context) io.future.PollResult(i32) {
        // Attempt to make progress.
        // Return .{ .ready = value } when complete.
        // Return .pending when waiting for something.
    }
};
```

A future has exactly two possible results when polled:

| Result | Meaning |
|--------|---------|
| `.pending` | Not ready yet. The future has registered a waker and will signal when it can make progress. |
| `.{ .ready = value }` | Complete. The final value is available. |

### How Polling Works

The runtime calls `poll()` on a future repeatedly until it resolves:

```
     Runtime                         Future
       |                               |
       |--- poll(ctx) ----------------->|
       |                               |-- check: not ready
       |<------- .pending -------------|  (registered waker)
       |                               |
       |    ... runtime does other      |
       |    work, handles other tasks   |
       |                               |
       |    ... waker fires! ---------->|
       |                               |
       |--- poll(ctx) ----------------->|
       |                               |-- check: data ready!
       |<------- .{ .ready = 42 } -----|
       |                               |
```

This is fundamentally different from blocking I/O, where a thread sits idle waiting for a syscall to return. With futures, the thread is always productive.

### A Concrete Example

Here is a future that yields once before producing a value:

```zig
const io = @import("blitz-io");

const DelayedValue = struct {
    pub const Output = i32;
    state: enum { first_poll, done } = .first_poll,

    pub fn poll(self: *@This(), ctx: *io.future.Context) io.future.PollResult(i32) {
        switch (self.state) {
            .first_poll => {
                // Not ready yet -- register waker so we get polled again
                const waker = ctx.getWaker();
                waker.wakeByRef(); // Immediately schedule re-poll (for demo)
                self.state = .done;
                return .pending;
            },
            .done => {
                return .{ .ready = 42 };
            },
        }
    }
};
```

Key points:

- The future is a **state machine**. Each `poll()` call advances it through states.
- The future stores its progress in `self.state` -- this is what makes it "stackless." There is no hidden call stack to preserve.
- The future uses `ctx.getWaker()` to get a waker that will reschedule the task.

### Built-in Futures

blitz-io provides several ready-made futures:

```zig
const io = @import("blitz-io");

// A future that is immediately ready
var f1 = io.future.ready(@as(i32, 42));

// A future that never completes
var f2 = io.future.pending(i32);

// A future that computes lazily on first poll
var f3 = io.future.lazy(struct {
    fn compute() i32 { return 42; }
}.compute);

// Wrap any function as a single-poll future
const FnFut = io.future.FnFuture(myFunc, @TypeOf(args));
```

---

## The Runtime

The **Runtime** is the engine that drives futures to completion. It owns three subsystems:

### 1. The Work-Stealing Scheduler

The scheduler manages a pool of worker threads, each with:

- A **LIFO slot** -- hot-path shortcut for the most recently spawned task (temporal locality)
- A **local queue** -- 256-slot lock-free ring buffer for pending tasks
- A **global injection queue** -- mutex-protected overflow queue shared by all workers
- A **cooperative budget** -- 128 polls per tick, preventing any single task from starving others

When a worker runs out of local tasks, it **steals** from other workers' queues. The steal target is chosen randomly to avoid contention. Idle workers park on a futex and are woken via a 64-bit bitmap with O(1) lookup using `@ctz`.

### 2. The I/O Driver

Platform-specific I/O multiplexing:

| Platform | Backend | Mechanism |
|----------|---------|-----------|
| Linux 5.1+ | io_uring | Submission/completion queues in shared memory |
| macOS | kqueue | Edge-triggered event notification |
| Windows 10+ | IOCP | I/O Completion Ports |
| Linux (fallback) | epoll | Edge-triggered file descriptor polling |

The backend is auto-detected at startup. All backends present the same interface to the rest of the runtime.

### 3. The Blocking Pool

CPU-intensive or blocking operations must not run on I/O worker threads (they would stall all async tasks on that worker). The blocking pool provides dedicated threads for this:

```zig
// Offload CPU-heavy work to the blocking pool
const hash = try io.task.spawnBlocking(computeExpensiveHash, .{data});
const result = try hash.wait();
```

The pool auto-scales up to 512 threads (configurable) and reclaims idle threads after 10 seconds.

### Starting the Runtime

Two ways to start:

```zig
// Zero-config: auto-detect everything
pub fn main() !void {
    try io.run(myApp);
}

// Explicit configuration
pub fn main() !void {
    var rt = try io.Runtime.init(allocator, .{
        .num_workers = 8,
        .max_blocking_threads = 128,
        .blocking_keep_alive_ns = 30 * std.time.ns_per_s,
    });
    defer rt.deinit();
    try rt.run(myApp, .{});
}
```

The `Config` fields:

| Field | Default | Description |
|-------|---------|-------------|
| `num_workers` | 0 (auto) | Number of I/O worker threads. 0 means use CPU core count. |
| `max_blocking_threads` | 512 | Maximum threads in the blocking pool. |
| `blocking_keep_alive_ns` | 10s | How long idle blocking threads stay alive. |
| `backend` | `null` (auto) | Force a specific I/O backend. |

---

## Tasks and Spawning

A **task** is a future scheduled on the runtime. Tasks are the unit of concurrency in blitz-io.

### Spawning Tasks

There are three spawn functions:

```zig
const io = @import("blitz-io");

// 1. Spawn a plain function (most common)
const handle = try io.task.spawn(myFunc, .{arg1, arg2});

// 2. Spawn an existing Future value
var lock_future = mutex.lock();
const handle2 = try io.task.spawnFuture(lock_future);

// 3. Spawn on the blocking thread pool (for CPU-bound work)
const handle3 = try io.task.spawnBlocking(heavyCompute, .{data});
```

| Function | Use case | Runs on |
|----------|----------|---------|
| `spawn(fn, args)` | General async work | Scheduler workers |
| `spawnFuture(future)` | Futures from sync/compose | Scheduler workers |
| `spawnBlocking(fn, args)` | CPU-heavy or blocking I/O | Blocking pool threads |

### JoinHandle

`spawn` and `spawnFuture` return a `JoinHandle` that lets you wait for the result:

```zig
const handle = try io.task.spawn(compute, .{@as(i32, 5)});

// Block the calling thread until the task completes
const result = handle.blockingJoin();
```

### Multi-Task Coordination

When you have multiple concurrent tasks, use the combinator functions:

```zig
const h1 = try io.task.spawn(fetchUser, .{id});
const h2 = try io.task.spawn(fetchPosts, .{id});
const h3 = try io.task.spawn(fetchComments, .{id});

// Wait for ALL tasks
const user, const posts, const comments = try io.task.joinAll(.{ h1, h2, h3 });

// Or: first to complete wins, cancel the rest
const winner = try io.task.race(.{ h1, h2, h3 });

// Or: first to complete, keep others running
const first = try io.task.select(.{ h1, h2, h3 });
```

---

## Cooperative Scheduling

blitz-io uses **cooperative scheduling**: tasks voluntarily yield control to the runtime by returning `.pending` from `poll()`. This is different from preemptive scheduling (like OS threads) where the scheduler forcibly interrupts execution.

### Why Cooperative?

Cooperative scheduling avoids the overhead of context switches, signal handling, and stack switching. But it comes with a responsibility: **tasks must not block the worker thread.**

Bad patterns that block:

```zig
// BAD: Blocks the I/O worker thread
std.Thread.sleep(1_000_000_000);

// BAD: CPU-intensive loop without yielding
while (i < 1_000_000) : (i += 1) {
    result += expensiveComputation(i);
}
```

Good alternatives:

```zig
// GOOD: Async-aware sleep (yields to scheduler)
io.task.sleep(io.time.Duration.fromSecs(1));

// GOOD: Offload to blocking pool
const result = try io.task.spawnBlocking(batchCompute, .{data});
```

### Cooperative Budget

Even well-behaved tasks can accidentally starve others if they generate many sub-tasks. blitz-io enforces a **cooperative budget of 128 polls per tick**. After 128 polls, the worker forces the current task to yield, ensuring other tasks get CPU time.

This matches Tokio's budget and is invisible to application code -- you do not need to insert manual yield points.

### LIFO Slot and Fairness

When a task spawns a new child task, the child is placed in the worker's LIFO slot for temporal locality (the child likely touches the same cache lines). However, the LIFO slot is capped at 3 consecutive polls per tick to prevent starvation of tasks in the FIFO queue.

---

## Wakers and Notification

The **Waker** is the mechanism that connects async operations to the scheduler. When an I/O operation, timer, or sync primitive becomes ready, it calls `waker.wake()` to reschedule the waiting task.

### How Wakers Flow

```
  Task calls mutex.lock()
       |
       v
  LockFuture.poll(ctx)
       |
       |-- mutex is contended
       |-- store ctx.getWaker().clone() in waiter
       |-- return .pending
       |
  (task is suspended, worker picks up other tasks)
       |
  ... later, another task calls mutex.unlock() ...
       |
       v
  Mutex.unlock()
       |-- pops first waiter from the intrusive list
       |-- calls waiter.waker.wake()
       |
       v
  Waker signals the scheduler
       |
       v
  Task is rescheduled, poll() called again
       |
       v
  LockFuture.poll(ctx)
       |-- mutex is now acquired!
       |-- return .{ .ready = Guard{} }
```

### The Waker API

```zig
const Waker = struct {
    /// Wake the task (consumes the waker)
    pub fn wake(self: Waker) void;

    /// Wake without consuming (for repeated wakes)
    pub fn wakeByRef(self: *const Waker) void;

    /// Create a copy of this waker
    pub fn clone(self: *const Waker) Waker;

    /// Release this waker's resources
    pub fn deinit(self: *Waker) void;
};
```

Wakers are lightweight (16 bytes) and use a vtable for type erasure. The scheduler creates wakers that know how to put tasks back on the run queue. Async primitives store wakers and invoke them when conditions are met.

### Zero-Allocation Waiters

A key design principle: **waiter structs are embedded directly in the future, not heap-allocated.** When you call `mutex.lock()`, the returned `LockFuture` contains an intrusive list node. When the future is polled and the mutex is contended, that node is linked into the mutex's waiter list -- without any heap allocation.

This is why blitz-io achieves 50 B/op vs Tokio's 1348 B/op: the waiter storage is part of the future's stack frame.

---

## How blitz-io Relates to Zig's Planned Async

Zig's language-level async/await is planned but not yet available in 0.15.x. blitz-io fills this gap with manual state machines:

| Aspect | Zig async (future) | blitz-io (today) |
|--------|---------------------|-------------------|
| Syntax | `async`/`await` keywords | Manual `poll()` state machines |
| Task size | Compiler-determined | ~256-512 bytes |
| Scheduling | TBD | Work-stealing, cooperative budget |
| I/O integration | Via `std.Io` interface | Built-in backends |
| Sync primitives | None built-in | Mutex, RwLock, Semaphore, Barrier, Notify, OnceCell |
| Channels | None built-in | Channel, Oneshot, Broadcast, Watch, Select |

When Zig adds language-level async, blitz-io's runtime, scheduler, sync primitives, and channels will remain valuable -- the language feature replaces the manual state machine boilerplate, but the runtime infrastructure is still needed.

For most users, the `io.task.spawn(fn, args)` API already hides the future machinery. You write plain functions and `spawn` wraps them in a `FnFuture` automatically:

```zig
// You write this:
fn fetchUser(id: u64) User {
    // plain function, no poll() needed
}
const handle = try io.task.spawn(fetchUser, .{id});

// blitz-io wraps it as:
// FnFuture(fetchUser, .{id}) -- a single-poll future that calls fetchUser once
```

---

## The Two-Tier API Pattern

Every sync primitive and channel in blitz-io provides two tiers:

### Tier 1: `tryX()` -- Non-Blocking

Returns immediately. Use when you can handle failure without yielding.

```zig
// Non-blocking lock attempt
if (mutex.tryLock()) {
    defer mutex.unlock();
    // critical section
} else {
    // Lock is held, do something else
}

// Non-blocking channel receive
switch (ch.tryRecv()) {
    .ok => |item| processItem(item),
    .empty => {}, // No data available
    .closed => break,
}
```

### Tier 2: `x()` -- Future-Based

Returns a Future that can be spawned or polled. Use when you want to yield to the scheduler while waiting.

```zig
// Async lock -- yields to scheduler if contended
var lock_future = mutex.lock();
const handle = try io.task.spawnFuture(lock_future);

// Async channel send with backpressure
var send_future = ch.send(item);
const handle2 = try io.task.spawnFuture(send_future);
```

### Choosing the Right Tier

| Situation | Use |
|-----------|-----|
| Hot path, lock rarely contended | `tryLock()` |
| Must acquire, can yield | `lock()` (Future) |
| Polling a channel in a loop | `tryRecv()` |
| Waiting for the next message | `recv()` (Future) |
| Checking semaphore availability | `tryAcquire(n)` |
| Rate limiting with backpressure | `acquire(n)` (Future) |

---

## Summary

| Concept | What it is |
|---------|-----------|
| **Future** | A state machine representing an incomplete async operation. Has a `poll()` method returning `.pending` or `.ready`. |
| **Runtime** | The engine: scheduler + I/O driver + blocking pool. Created via `io.run()` or `Runtime.init()`. |
| **Task** | A future scheduled on the runtime. Created via `io.task.spawn()` or `io.task.spawnFuture()`. |
| **Waker** | Lightweight callback (16 bytes) that reschedules a task when an async event fires. |
| **Cooperative scheduling** | Tasks yield voluntarily by returning `.pending`. Budget of 128 polls/tick prevents starvation. |
| **Two-tier API** | `tryX()` for non-blocking, `x()` for Future-based -- available on all sync and channel types. |

Next: explore the [Usage](/usage/runtime/) guides for detailed coverage of each module, or jump to the [Cookbook](/cookbook/) for real-world patterns.
