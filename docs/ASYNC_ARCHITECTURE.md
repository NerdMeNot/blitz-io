# blitz-io Async Architecture: Simulating Async/Await in Zig 0.15

## Executive Summary

Zig 0.15.x lacks `async/await` syntax, but we can build an equivalent system using:

1. **Comptime-generated state machines** (what `async fn` compiles to)
2. **Waker pattern** (already implemented in `executor/task.zig`)
3. **Two-tier sync primitives** (OS-thread blocking + Task-yielding)
4. **blitz integration** for CPU-bound work offloading

This document outlines how blitz-io can match or exceed Tokio's performance.

---

## Part 1: Understanding What Async Really Is

### What Tokio Does Under the Hood

When you write:
```rust
async fn fetch_and_process(url: &str) -> Result<Data> {
    let response = http_client.get(url).await;  // Yields here
    let parsed = parse(response);                // CPU work
    database.insert(parsed).await                // Yields here
}
```

Rust's compiler transforms this into a state machine:
```rust
enum FetchAndProcessState {
    Start,
    WaitingForHttp { future: HttpFuture },
    WaitingForDb { future: DbFuture, parsed: Data },
    Done,
}
```

The runtime polls this state machine. When it returns `Poll::Pending`, the task yields and the worker thread moves to other work.

### What We Have in Zig

**You've already built the hard parts:**

1. **Task State Machine** (`executor/task.zig`):
   - `Header.State` with IDLE/SCHEDULED/RUNNING/COMPLETE/CANCELLED/NOTIFIED
   - Reference counting in packed u64
   - `transitionToScheduled()`, `transitionToRunning()`, `transitionToIdle()`
   - **NOTIFIED flag** - prevents lost wakeups (critical!)

2. **Waker** (`executor/task.zig:532`):
   ```zig
   pub const Waker = struct {
       header: *Header,
       pub fn wake(self: *Waker) void {
           if (self.header.transitionToScheduled()) {
               self.header.schedule();
           }
           self.header.unref();
       }
   };
   ```

3. **I/O Backend** (`backend/kqueue.zig`):
   - Slab-based registration
   - ScheduledIo with tick-based readiness
   - Completion-based I/O

**What's missing:** The sync primitives don't know about Wakers.

---

## Part 2: Two-Tier Sync Primitives

### The Problem with Current Primitives

```zig
// Current Mutex (mutex.zig) - blocks OS threads
pub fn lock(self: *Self) void {
    if (self.state.cmpxchgWeak(UNLOCKED, LOCKED, .acquire, .monotonic) == null) {
        return;
    }
    self.lockSlow();  // Calls Futex.wait() - blocks the WORKER THREAD
}
```

When a task calls `mutex.lock()`, the entire worker thread blocks. Other tasks on that worker starve.

### The Solution: Task-Aware Primitives

```zig
// New AsyncMutex - yields tasks
pub const AsyncMutex = struct {
    locked: bool = false,
    waiters: WakerQueue = .{},  // Queue of Wakers, not threads!

    pub const LockFuture = struct {
        mutex: *AsyncMutex,
        waker: ?Waker = null,

        /// Called by task poll loop
        pub fn poll(self: *LockFuture, ctx: *PollContext) PollResult {
            if (self.mutex.tryAcquire()) {
                return .ready;
            }

            // Store waker and yield (don't block!)
            self.waker = ctx.waker.clone();
            self.mutex.waiters.push(&self.waker.?);
            return .pending;  // Task yields, worker runs other tasks
        }
    };

    pub fn lock(self: *AsyncMutex) LockFuture {
        return .{ .mutex = self };
    }

    fn tryAcquire(self: *AsyncMutex) bool {
        // Fast path - same as current
        return !@atomicRmw(bool, &self.locked, .Xchg, true, .acquire);
    }

    pub fn unlock(self: *AsyncMutex) void {
        self.locked = false;
        @fence(.release);

        // Wake one waiter (if any)
        if (self.waiters.pop()) |waker| {
            waker.wake();  // Schedules the waiting task
        }
    }
};
```

**Key insight**: Instead of blocking the OS thread, we:
1. Store the task's Waker in a queue
2. Return `.pending` so the task yields
3. When unlocking, wake the waiting task

---

## Part 3: Manual State Machines with Comptime Help

### The Verbose Way (What Users See Today)

Without `async/await`, users write state machines manually:

```zig
const FetchAndProcessTask = struct {
    state: State = .start,
    url: []const u8,

    // State machine states
    const State = enum { start, waiting_http, waiting_db, done };

    // Storage for in-progress work
    http_response: ?HttpResponse = null,
    parsed_data: ?Data = null,

    pub fn poll(self: *@This(), output: *?Data, waker: *Waker) PollResult {
        switch (self.state) {
            .start => {
                // Start HTTP request
                http_client.startRequest(self.url, waker.clone());
                self.state = .waiting_http;
                return .pending;
            },
            .waiting_http => {
                // Check if HTTP response is ready
                if (http_client.tryGetResponse()) |response| {
                    self.http_response = response;
                    self.parsed_data = parse(response);  // Sync CPU work

                    // Start DB insert
                    database.startInsert(self.parsed_data.?, waker.clone());
                    self.state = .waiting_db;
                    return .pending;
                }
                return .pending;
            },
            .waiting_db => {
                if (database.tryGetResult()) |_| {
                    output.* = self.parsed_data;
                    self.state = .done;
                    return .ready;
                }
                return .pending;
            },
            .done => return .ready,
        }
    }
};
```

### The Ergonomic Way (Comptime Builder)

We can use Zig's comptime to reduce boilerplate:

```zig
// User writes this:
const MyTask = AsyncTask(.{
    .steps = .{
        .{ .async_call = http_client.get, .store = "response" },
        .{ .sync_call = parse, .input = "response", .store = "parsed" },
        .{ .async_call = database.insert, .input = "parsed" },
    },
});

// Comptime generates the state machine
```

This is more complex to implement but provides better ergonomics.

### The Practical Middle Ground

For blitz-io v1, we recommend the **Poll Trait Pattern**:

```zig
/// Any type with this interface can be polled as an async operation
pub fn Pollable(comptime Self: type, comptime Output: type) type {
    return struct {
        /// Poll the operation. Returns .ready with output or .pending.
        pub const poll = fn (*Self, *?Output, *Waker) PollResult;
    };
}

/// Combinator: sequence two async operations
pub fn AndThen(comptime First: type, comptime Second: type) type {
    return struct {
        first: First,
        second: ?Second = null,
        first_output: ?First.Output = null,

        pub fn poll(self: *@This(), output: *?Second.Output, waker: *Waker) PollResult {
            if (self.first_output == null) {
                const result = self.first.poll(&self.first_output, waker);
                if (result == .pending) return .pending;
            }

            if (self.second == null) {
                self.second = Second.init(self.first_output.?);
            }

            return self.second.?.poll(output, waker);
        }
    };
}
```

---

## Part 4: blitz Integration for CPU-Bound Work

### The Problem

I/O tasks shouldn't do heavy CPU work - it blocks the event loop. Tokio solves this with `spawn_blocking()` and Rayon integration.

### The Solution: Bridge to blitz

```zig
// In blitz-io
pub fn spawnOnBlitz(
    comptime func: anytype,
    args: anytype,
) SpawnBlockingFuture(@TypeOf(func), @TypeOf(args)) {
    return SpawnBlockingFuture(@TypeOf(func), @TypeOf(args)).init(func, args);
}

pub fn SpawnBlockingFuture(comptime F: type, comptime Args: type) type {
    return struct {
        func: F,
        args: Args,
        result: ?ReturnType = null,
        latch: blitz.OnceLatch = blitz.OnceLatch.init(),
        submitted: bool = false,

        const ReturnType = @typeInfo(F).Fn.return_type.?;

        pub fn poll(self: *@This(), output: *?ReturnType, waker: *Waker) PollResult {
            // Check if already complete
            if (self.latch.probe()) {
                output.* = self.result;
                return .ready;
            }

            if (!self.submitted) {
                // Submit to blitz thread pool
                const cloned_waker = waker.clone();

                blitz.getPool().injectJob(&Job{
                    .handler = struct {
                        fn run(_: *blitz.Task, job: *Job) void {
                            const future: *@This() = @fieldParentPtr("job", job);

                            // Execute CPU-bound work
                            future.result = @call(.auto, future.func, future.args);

                            // Signal completion
                            future.latch.setDone();

                            // Wake the I/O task
                            cloned_waker.wake();
                        }
                    }.run,
                });

                self.submitted = true;
            }

            return .pending;
        }
    };
}
```

### Usage

```zig
const ProcessTask = struct {
    state: enum { fetch, compute, store } = .fetch,
    data: ?[]const u8 = null,
    result: ?ProcessedData = null,
    compute_future: ?SpawnBlockingFuture(heavyComputation, .{[]const u8}) = null,

    pub fn poll(self: *@This(), output: *?void, waker: *Waker) PollResult {
        switch (self.state) {
            .fetch => {
                // ... fetch data from I/O
            },
            .compute => {
                if (self.compute_future == null) {
                    // Offload to blitz for CPU work
                    self.compute_future = spawnOnBlitz(heavyComputation, .{self.data.?});
                }

                const result = self.compute_future.?.poll(&self.result, waker);
                if (result == .pending) return .pending;

                self.state = .store;
                return .pending;
            },
            .store => {
                // ... store result via I/O
            },
        }
    }
};
```

---

## Part 5: Sync Primitive Architecture

### The Dual-Mode Pattern

Keep both OS-thread and Task-yielding versions:

```
src/sync/
├── mutex.zig           # OS-thread blocking (current, for non-async code)
├── async_mutex.zig     # Task-yielding (new)
├── semaphore.zig       # OS-thread blocking
├── async_semaphore.zig # Task-yielding
├── barrier.zig         # OS-thread blocking
├── async_barrier.zig   # Task-yielding (comparable to Tokio!)
├── channel.zig         # Already has WaiterQueue - enhance
└── waiter.zig          # Core waiter infrastructure
```

### WakerQueue (New Core Primitive)

The key building block for all async sync primitives:

```zig
/// Queue of Wakers waiting for a condition.
/// Lock-free for single-producer, uses spinlock for multi-producer.
pub const WakerQueue = struct {
    head: std.atomic.Value(?*WakerNode) = .init(null),
    tail: std.atomic.Value(?*WakerNode) = .init(null),

    const WakerNode = struct {
        waker: Waker,
        next: ?*WakerNode,
    };

    /// Push a waker (clones it)
    pub fn push(self: *WakerQueue, waker: *const Waker) void {
        const node = // allocate from pool
        node.waker = waker.clone();
        node.next = null;

        // CAS into tail (Treiber stack or Michael-Scott queue)
        // ...
    }

    /// Pop and wake one waiter
    pub fn wakeOne(self: *WakerQueue) bool {
        if (self.pop()) |node| {
            node.waker.wake();
            // return to pool
            return true;
        }
        return false;
    }

    /// Wake all waiters
    pub fn wakeAll(self: *WakerQueue) usize {
        var count: usize = 0;
        while (self.pop()) |node| {
            node.waker.wake();
            count += 1;
        }
        return count;
    }
};
```

---

## Part 6: Achieving Tokio Parity

### Benchmark Comparison Strategy

| Primitive | blitz-io Today | Tokio | After This Work |
|-----------|---------------|-------|-----------------|
| Mutex (uncontended) | 1.9ns ✓ | 10.5ns | 1.9ns |
| Mutex (contended, OS threads) | 67.8ns | N/A | 67.8ns |
| Mutex (contended, tasks) | N/A | 60.3ns | ~50ns target |
| Barrier (OS threads) | 84.6µs | N/A | 84.6µs |
| Barrier (tasks) | N/A | 8.1µs | ~5µs target |

**The key insight**: We should be *faster* than Tokio because:
1. Zig has no runtime overhead (no trait objects, no async transform)
2. Comptime specialization eliminates vtable dispatch
3. We can inline the state machine

### Where blitz-io Can Beat Tokio

1. **Task spawn cost**: Tokio allocates ~100-256 bytes per task. We can pool aggressively.

2. **Waker efficiency**: Tokio's `Waker` has vtable indirection. Our comptime-specialized wakers have none.

3. **I/O completion**: Our direct Slab indexing (token → registration) is O(1) with no hash.

4. **blitz integration**: Native Zig → Zig FFI is zero-cost vs Rust → Rayon overhead.

---

## Part 7: Implementation Roadmap

### Phase 1: Core Infrastructure (Week 1-2)
- [ ] `WakerQueue` - lock-free queue of wakers
- [ ] `AsyncMutex` - task-yielding mutex
- [ ] `AsyncSemaphore` - task-yielding semaphore
- [ ] Tests proving task yielding vs OS blocking

### Phase 2: Barrier and Notify (Week 3)
- [ ] `AsyncBarrier` - apples-to-apples Tokio comparison
- [ ] `AsyncNotify` - task notification
- [ ] Benchmark showing parity/improvement vs Tokio

### Phase 3: blitz Integration (Week 4)
- [ ] `spawnOnBlitz()` future
- [ ] Oneshot channel for result delivery
- [ ] Integration tests with mixed I/O + CPU work

### Phase 4: Ergonomics (Week 5+)
- [ ] Combinators (andThen, race, select)
- [ ] Timeout wrapper
- [ ] Error handling patterns

---

## Part 8: Code Examples

### Example 1: Async Mutex in Action

```zig
const Counter = struct {
    mutex: AsyncMutex = .{},
    value: u64 = 0,

    const IncrementTask = struct {
        counter: *Counter,
        lock_future: ?AsyncMutex.LockFuture = null,

        pub fn poll(self: *@This(), output: *?void, waker: *Waker) PollResult {
            if (self.lock_future == null) {
                self.lock_future = self.counter.mutex.lock();
            }

            const lock_result = self.lock_future.?.poll(&{}, waker);
            if (lock_result == .pending) return .pending;

            // Got the lock!
            self.counter.value += 1;
            self.counter.mutex.unlock();

            output.* = {};
            return .ready;
        }
    };
};
```

### Example 2: HTTP Server with blitz Offload

```zig
const RequestHandler = struct {
    state: enum { accept, read, compute, write } = .accept,
    socket: ?Socket = null,
    request: ?Request = null,
    response: ?Response = null,
    compute_future: ?SpawnBlockingFuture = null,

    pub fn poll(self: *@This(), output: *?void, waker: *Waker) PollResult {
        switch (self.state) {
            .accept => {
                // Accept connection (yields if not ready)
                if (try_accept()) |sock| {
                    self.socket = sock;
                    self.state = .read;
                } else {
                    register_accept_waker(waker.clone());
                    return .pending;
                }
            },
            .read => {
                // Read request (yields if not ready)
                if (try_read(self.socket.?)) |req| {
                    self.request = req;
                    self.state = .compute;
                } else {
                    register_read_waker(self.socket.?, waker.clone());
                    return .pending;
                }
            },
            .compute => {
                // CPU-heavy work - offload to blitz!
                if (self.compute_future == null) {
                    self.compute_future = spawnOnBlitz(
                        processRequest,
                        .{self.request.?},
                    );
                }

                const result = self.compute_future.?.poll(&self.response, waker);
                if (result == .pending) return .pending;

                self.state = .write;
            },
            .write => {
                // Write response (yields if not ready)
                if (try_write(self.socket.?, self.response.?)) {
                    output.* = {};
                    return .ready;
                } else {
                    register_write_waker(self.socket.?, waker.clone());
                    return .pending;
                }
            },
        }
        return .pending;
    }
};
```

---

## Conclusion

blitz-io has already built the hard parts of an async runtime:
- Task state machines with proper state transitions
- Wakers with reference counting
- NOTIFIED flag for lost wakeup prevention
- Solid I/O backends

The missing piece is **task-aware sync primitives** that yield instead of blocking.

By implementing `WakerQueue`, `AsyncMutex`, `AsyncSemaphore`, and `AsyncBarrier`, plus the blitz integration bridge, blitz-io can achieve full Tokio parity - and likely exceed it due to Zig's zero-overhead abstractions.

The Barrier benchmark gap (84µs vs 8µs) will close completely when comparing `AsyncBarrier` to Tokio's barrier, because both will be yielding tasks rather than blocking OS threads.
