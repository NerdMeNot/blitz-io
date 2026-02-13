# Why Stackless? The Case for Stackless Futures in blitz-io

## The Problem

Async I/O runtimes need to manage thousands or millions of concurrent tasks.
A web server handling 100K connections, a database proxy routing queries, a
message broker dispatching events -- all need to multiplex many logical
operations onto a small number of OS threads.

Each task needs to suspend at I/O boundaries (waiting for data, waiting for
a lock, waiting for a timer) and resume when the operation completes. The
fundamental question is: **how do we represent a suspended task?**

There are two approaches: stackful coroutines and stackless futures.

---

## Stackful Coroutines

A stackful coroutine is a function with its own stack. When it suspends, the
entire register set and stack pointer are saved. When it resumes, they are
restored. The coroutine has a complete call stack, so it can suspend from any
depth in the call chain.

### How It Works

```
                   OS Thread Stack                Coroutine Stack
                   +-----------+                  +-----------+
                   | main()    |                  | handler() |
                   | scheduler |     switch       | parse()   |
                   | resume()  |  ------------>   | read()    |
                   |           |  <------------   | (suspend) |
                   | ...       |     switch       |           |
                   +-----------+                  +-----------+
                                                  16-64 KB each
```

Suspension saves registers + stack pointer:

```
save:   rsp -> coroutine.saved_sp
        push rbx, rbp, r12-r15     (callee-saved registers)
resume: pop r15-r12, rbp, rbx
        rsp <- coroutine.saved_sp
        ret
```

### Examples in the Wild

| Runtime | Stack Model | Initial Stack Size |
|---------|-------------|-------------------|
| Go goroutines | Stackful, growable | 2 KB (grows to 1 MB) |
| Lua coroutines | Stackful, fixed | ~2 KB |
| Java virtual threads (Loom) | Stackful, growable | ~1 KB |
| Zig async (pre-0.14) | Stackful via `@frame` | Frame-sized |
| Boost.Fiber (C++) | Stackful, fixed | 64 KB default |
| Ruby Fiber | Stackful, fixed | 128 KB |

### Advantages

**Natural programming model.** Code reads like synchronous code. There is
no visible difference between a blocking call and a suspending call:

```
// Stackful: looks identical to synchronous code
fn handleConnection(conn: TcpStream) void {
    const request = conn.read(&buf);      // suspends here
    const response = processRequest(request);
    conn.write(response);                  // suspends here
    log("done");
}
```

**Can suspend from any call depth.** A function 10 levels deep in the call
stack can suspend without the intermediate frames knowing or caring:

```
fn outer() void {
    middle();
}

fn middle() void {
    inner();
}

fn inner() void {
    // Suspends -- outer() and middle() don't need to know
    io.read(&buf);
}
```

**Simpler state management.** Local variables live on the coroutine stack.
No need to manually pack them into a struct.

### Disadvantages

**Memory overhead.** Each coroutine needs its own stack. Even with a modest
16 KB stack:

```
10,000 coroutines  x  16 KB  =  160 MB
100,000 coroutines x  16 KB  =  1.6 GB
1,000,000 coroutines x 16 KB = 16 GB
```

Go mitigates this with 2 KB initial stacks that grow, but growth requires
copying the entire stack (expensive), and the minimum 2 KB still adds up.

**Stack sizing dilemma.** Too small and you get stack overflow. Too large and
you waste memory. Growable stacks solve this but add runtime overhead and
complexity (stack relocation, pointer fixup).

**Context switch overhead.** Saving and restoring the full register set takes
200-500ns per switch, depending on the architecture. This cost is paid on
every suspend and resume, even if the coroutine only needs to save a single
integer:

```
Context switch cost breakdown (approximate, x86_64):
  Save 6 callee-saved registers:   ~5ns
  Save SIMD state (if used):       ~50-100ns
  Stack pointer swap:               ~2ns
  Pipeline flush + refill:          ~100-200ns
  Cache miss on new stack:          ~50-200ns
  Total:                            ~200-500ns
```

**Cache pollution.** When switching between coroutines, the CPU cache is
polluted by the new stack's memory. If you have thousands of coroutines
cycling through, the cache hit rate drops significantly.

**Platform-specific assembly.** Stack switching requires assembly code for
each target architecture:

```
Architecture    Registers to Save    Stack Switch Mechanism
x86_64          rbx, rbp, r12-r15   mov rsp
aarch64         x19-x28, x29, lr    mov sp
RISC-V          s0-s11, ra          mv sp
WASM            N/A                  Not supported
```

This is a maintenance burden and a source of subtle bugs on each new platform.

---

## Stackless Futures

A stackless future is a state machine. Each possible suspend point becomes a
state. The future's `poll()` method advances through states, returning
`.pending` when it needs to wait and `.ready` when it has a result. Only the
data needed to continue from the current state is stored -- not an entire
call stack.

### How It Works

```
                   OS Thread Stack
                   +-----------+
                   | main()    |
                   | scheduler |
                   | poll()    | ----> future.poll(&ctx)
                   |           | <---- return .pending  (or .ready)
                   | ...       |
                   +-----------+

                   Future (on heap)
                   +-----------+
                   | state: u8 |
                   | buf: [N]u8|     100-512 bytes
                   | partial: T|
                   +-----------+
```

No stack switching. Suspension is a function return. Resumption is a function
call. The scheduler simply calls `poll()` again when the waker fires.

### Examples in the Wild

| Runtime | Stack Model | Per-Task Size |
|---------|-------------|---------------|
| Rust async/await | Stackless state machines | Compiler-computed |
| JavaScript Promises | Stackless closures | ~100-200 bytes |
| C# async/await | Stackless state machines | Compiler-computed |
| Python asyncio | Stackless generators | ~500 bytes |
| blitz-io (Zig) | Stackless futures | ~256-512 bytes |
| Tokio (Rust) | Stackless futures | ~256-512 bytes |

### Advantages

**Tiny memory footprint.** A future stores only the state enum and the
variables live across the current suspend point:

```
10,000 futures  x  256 B  =  2.5 MB
100,000 futures x  256 B  =  25 MB
1,000,000 futures x 256 B = 256 MB
```

That is 64x less memory than stackful at 16 KB per stack.

**Cache-friendly.** Small futures fit in a few cache lines. When the scheduler
polls a future, all its state is likely already in L1/L2 cache:

```
Cache line:  128 bytes (x86_64 with spatial prefetcher)
Future size: ~256 bytes = 2 cache lines
Stack size:  ~16 KB = 128 cache lines
```

Polling a future touches 2 cache lines. Switching to a coroutine stack touches
potentially hundreds. The difference in cache miss rate is dramatic under load.

**No platform-specific assembly.** Suspension is a function return. Resumption
is a function call. Both are standard calling convention operations that work
on every platform without architecture-specific code.

**Zero-allocation waiters.** With intrusive linked lists, the waiter struct is
embedded directly in the future. No heap allocation is needed to wait on a
mutex, semaphore, or channel:

```zig
const LockFuture = struct {
    state: enum { init, waiting, acquired },
    waiter: Mutex.Waiter,          // Embedded, not heap-allocated
    mutex: *Mutex,

    pub fn poll(self: *@This(), ctx: *Context) PollResult(void) {
        // ...
    }
};
```

**Compiler optimization.** Because the state machine is visible to the
compiler, it can optimize across suspend points -- inlining state transitions,
eliminating dead states, and computing sizes at comptime.

### Disadvantages

**More complex programming model.** In Zig 0.15, without language-level
async/await, futures must be written as explicit state machines:

```zig
// Must manually track state across suspend points
const MyFuture = struct {
    state: enum { init, waiting_for_lock, waiting_for_read, done },
    mutex_waiter: Mutex.Waiter,
    read_buf: [4096]u8,
    bytes_read: usize,

    pub fn poll(self: *@This(), ctx: *Context) PollResult(void) {
        switch (self.state) {
            .init => { ... },
            .waiting_for_lock => { ... },
            .waiting_for_read => { ... },
            .done => return .{ .ready = {} },
        }
    }
};
```

This is verbose compared to stackful code where the same logic would be a
sequence of function calls.

**Cannot suspend from arbitrary call depth.** Every function in the call chain
that might suspend must return a future. You cannot call a synchronous library
function that internally does I/O -- it will block the worker thread:

```zig
// This BLOCKS the worker thread -- bad!
fn processRequest(data: []const u8) []const u8 {
    const extra = std.fs.cwd().readFile("config.json", ...);  // blocks!
    return transform(data, extra);
}

// This YIELDS correctly -- but requires threading futures through
const ProcessFuture = struct {
    pub fn poll(self: *@This(), ctx: *Context) PollResult([]const u8) {
        // Must manually manage the read-file-then-transform sequence
    }
};
```

**Larger generated code for complex state machines.** Each state transition
generates branching code. A future with many states produces a large switch
statement, which can increase instruction cache pressure.

---

## Why blitz-io Chose Stackless

### 1. Scale

The target workload is millions of concurrent I/O tasks -- connection handlers,
timer callbacks, channel waiters, lock holders. At 256 bytes per task:

```
1,000,000 tasks x 256 bytes = 256 MB
```

This is manageable on any modern server. At 16 KB per stackful coroutine:

```
1,000,000 tasks x 16 KB = 16 GB
```

This requires a large-memory machine and leaves little room for actual data.

### 2. Performance

**No stack switching overhead.** Suspending a future is a function return
(~5ns). Resuming is a function call (~5ns). Total: ~10ns per
suspend/resume cycle.

A stackful context switch costs ~200-500ns: register save/restore, pipeline
flush, and likely cache miss on the new stack.

This is a 20-50x difference per suspend point. In a runtime processing millions
of suspend/resume cycles per second, this adds up to meaningful throughput
gains.

**Better cache utilization.** Consider a scheduler polling 1000 tasks per tick:

```
Stackless: 1000 tasks x 2 cache lines = 2000 cache line accesses
           Working set: ~250 KB (fits in L2)

Stackful:  1000 stacks x 128+ cache lines (active portion)
           Working set: ~16 MB (exceeds L2, thrashes L3)
```

The stackless approach keeps the working set small enough to stay in cache.

**Zero-allocation waiters.** blitz-io embeds waiter structs directly in
futures using intrusive linked lists. No `malloc` or `free` on the wait path:

```zig
// Mutex.LockFuture -- waiter is a field, not a heap allocation
const LockFuture = struct {
    waiter: Mutex.Waiter,    // 40-50 bytes, embedded
    // ...
};
```

Tokio uses the same pattern. This is critical for sync primitives that may be
acquired and released millions of times per second.

### 3. Memory Predictability

Zig's comptime type system knows the exact size of every future at compile
time:

```zig
const LockFuture = Mutex.LockFuture;
// @sizeOf(LockFuture) is known at comptime -- no runtime surprises

const Task = FutureTask(LockFuture);
// @sizeOf(Task) is known at comptime -- exact allocation size
```

There are no guard pages, no stack growth, no `mmap` overhead, no
fragmentation from variable-sized stack allocations. The runtime allocates
exactly what it needs.

With stackful coroutines, stack sizing is a runtime guess. Too small means
stack overflow (a crash). Too large means wasted memory. Growable stacks
add complexity and runtime cost.

### 4. Cross-Platform Simplicity

blitz-io targets Linux (x86_64, aarch64), macOS (x86_64, aarch64), and
Windows (x86_64). Stackful coroutines would require:

```
Platform-specific code for stackful:
  - x86_64 Linux:   setjmp/longjmp or custom assembly
  - aarch64 Linux:  custom assembly (different register ABI)
  - x86_64 macOS:   makecontext/swapcontext or custom assembly
  - aarch64 macOS:  custom assembly + Apple ABI quirks
  - x86_64 Windows: Fiber API or custom assembly + SEH unwinding
  - WASM:           Not possible (no stack switching)
```

With stackless futures, none of this exists. Suspension is a function return.
Resumption is a function call. The same code works on every platform and every
architecture, including WASM where stack switching is fundamentally impossible.

### 5. Alignment with Zig's Philosophy

Zig values explicitness: no hidden control flow, no hidden allocations, no
hidden state. Stackless futures are explicit state machines where:

- Every suspend point is visible (the `.pending` return).
- Every piece of state is a named field in the struct.
- Every allocation is explicit (the `FutureTask.create` call).
- Sizes are known at comptime (`@sizeOf(MyFuture)`).

Stackful coroutines hide the suspend mechanism (it looks like a normal function
call), hide the stack allocation, and hide the state (local variables on an
invisible stack).

When Zig reintroduces async/await (planned for a future release), it will
compile to stackless state machines -- the same model blitz-io uses today.
The manual state machines will be replaced by compiler-generated ones, but the
runtime's polling and scheduling infrastructure will remain unchanged.

---

## The Trade-off in Practice

### Stackful (Hypothetical)

```zig
fn handleConnection(conn: TcpStream) void {
    // Each of these "just works" -- suspend is invisible
    const request = conn.read(&buf);
    const db_result = db.query("SELECT ...");
    const response = render(request, db_result);
    conn.write(response);
    log.info("handled request");
}
```

Clean, readable, sequential. The programmer does not think about suspend
points. But each of these calls allocates a hidden stack frame, and the
coroutine's 16 KB stack sits in memory for the entire duration.

### Stackless (blitz-io Today)

Without language-level async/await, the same logic requires a manual state
machine:

```zig
const HandleFuture = struct {
    pub const Output = void;

    state: enum { reading, querying, writing, done } = .reading,
    conn: *TcpStream,
    buf: [4096]u8 = undefined,
    request: ?Request = null,
    db_future: ?DbQueryFuture = null,

    pub fn poll(self: *@This(), ctx: *Context) PollResult(void) {
        while (true) {
            switch (self.state) {
                .reading => {
                    // tryRead returns data or null (would-block)
                    const n = self.conn.tryRead(&self.buf) orelse {
                        // Register waker, return pending
                        self.conn.registerWaker(ctx.getWaker());
                        return .pending;
                    };
                    self.request = parseRequest(self.buf[0..n]);
                    self.db_future = db.query("SELECT ...");
                    self.state = .querying;
                },
                .querying => {
                    // Poll the inner database future
                    const result = self.db_future.?.poll(ctx);
                    if (result.isPending()) return .pending;
                    const response = render(self.request.?, result.unwrap());
                    self.conn.writeAll(response) catch {};
                    self.state = .done;
                },
                .writing => {
                    // ... handle partial writes ...
                },
                .done => return .{ .ready = {} },
            }
        }
    }
};
```

More verbose. The programmer must explicitly manage states and thread data
between them. But the future is ~4 KB (dominated by the buffer) instead of
16 KB, and there is no stack switching overhead.

### Stackless with Combinators (blitz-io API)

In practice, most users do not write raw futures. blitz-io provides
higher-level APIs that compose futures:

```zig
const io = @import("blitz-io");

// Spawn tasks and await results using combinators
const user_handle = try io.task.spawn(fetchUser, .{user_id});
const posts_handle = try io.task.spawn(fetchPosts, .{user_id});

// Wait for both concurrently
const user, const posts = try io.task.joinAll(.{ user_handle, posts_handle });

// Timeout a slow operation
const result = try io.async_ops.Timeout(FetchFuture).init(
    fetch_future,
    io.time.Duration.fromSecs(5),
);

// Race two operations
const winner = try io.task.race(.{
    io.task.spawn(fetchFromPrimary, .{key}),
    io.task.spawn(fetchFromReplica, .{key}),
});
```

The `FnFuture` wrapper converts any regular function into a single-poll
future, so spawning "just works" for simple cases:

```zig
// This function becomes a future automatically via FnFuture
fn processRequest(data: []const u8) !Response {
    // Regular synchronous code
    return Response.from(data);
}

// Spawn it as a task
const handle = try io.task.spawn(processRequest, .{data});
const response = try handle.blockingJoin();
```

---

## Memory Comparison

| Metric | Stackful (16 KB) | Stackless (blitz-io) |
|--------|------------------|---------------------|
| Per-task memory | 16,384 bytes | 256-512 bytes |
| 1,000 tasks | 16 MB | 0.25-0.5 MB |
| 10,000 tasks | 160 MB | 2.5-5 MB |
| 100,000 tasks | 1.6 GB | 25-50 MB |
| 1,000,000 tasks | 16 GB | 256-512 MB |
| Allocations per wait | 0 (on stack) | 0 (intrusive) |
| Context switch cost | ~200-500 ns | ~5-20 ns |
| Cache lines touched | 100+ (stack) | 2-4 (future) |
| Guard pages needed | Yes (1 per stack) | No |
| Platform assembly | Yes (per arch) | No |
| Size known at comptime | No (runtime growth) | Yes (@sizeOf) |

---

## How blitz-io Futures Work Internally

### The Future Trait

Any type with a `poll` method and an `Output` type is a future:

```zig
// The "trait" is structural -- no interface or vtable needed at the user level
const MyFuture = struct {
    pub const Output = i32;

    state: enum { init, done } = .init,

    pub fn poll(self: *@This(), ctx: *Context) PollResult(i32) {
        switch (self.state) {
            .init => {
                // Not ready yet -- store waker and return pending
                const waker = ctx.getWaker();
                storeWakerSomewhere(waker);
                self.state = .done;
                return .pending;
            },
            .done => return .{ .ready = 42 },
        }
    }
};
```

### Poll and PollResult

The polling result type is simple:

```zig
pub fn PollResult(comptime T: type) type {
    return union(enum) {
        pending: void,      // Not ready, waker registered
        ready: T,           // Complete with value
    };
}
```

No error state -- errors are part of `T` (e.g., `PollResult(error{Timeout}!Data)`).

### Wakers

When a future returns `.pending`, it must have registered a waker that will
be called when progress can be made. The waker is a 16-byte value:

```zig
pub const Waker = struct {
    raw: RawWaker,          // { data: *anyopaque, vtable: *const VTable }
};
```

The vtable provides four operations:

| Operation | Purpose |
|-----------|---------|
| `wake` | Reschedule the task (consumes the waker) |
| `wake_by_ref` | Reschedule without consuming |
| `clone` | Duplicate the waker (ref++) |
| `drop` | Release the waker (ref--) |

The scheduler's task waker implementation:

- `wake` calls `header.schedule()` then `header.unref()`.
- `clone` calls `header.ref()` and returns a new `RawWaker`.
- `drop` calls `header.unref()`, dropping the task if it was the last ref.

### FutureTask: Wrapping a Future into a Schedulable Task

The scheduler operates on type-erased `Header` pointers. `FutureTask(F)`
wraps a concrete future type into a header + vtable:

```
+----------------------------------------------+
| FutureTask(MyFuture)                         |
+----------------------------------------------+
| header: Header          | 64 bytes           |
|   state: atomic(u64)    |   packed state word |
|   next/prev: ?*Header   |   intrusive list    |
|   vtable: *const VTable |   type erasure      |
+-------------------------+--------------------+
| future: MyFuture        | User's state       |
|   state: enum           |   machine          |
|   data: ...             |                    |
+-------------------------+--------------------+
| result: ?Output         | Result storage     |
+-------------------------+--------------------+
| allocator: Allocator    | For cleanup        |
+-------------------------+--------------------+
| scheduler: ?*anyopaque  | Scheduler ref      |
| schedule_fn: ?*fn       | Callback for wake  |
| reschedule_fn: ?*fn     | Callback for       |
|                         | reschedule         |
+----------------------------------------------+
```

Total size: Header (~64 bytes) + Future (user-defined) + overhead (~40 bytes).
For a simple future with a few fields, this is typically 200-400 bytes.

### Intrusive Waiters: Zero-Allocation Waiting

The key insight that makes stackless futures practical for sync primitives is
intrusive waiting. The waiter struct is embedded directly in the future that
is waiting:

```zig
// Mutex.LockFuture embeds its waiter
const LockFuture = struct {
    pub const Output = void;

    state: enum { init, waiting, acquired } = .init,
    waiter: Mutex.Waiter = Mutex.Waiter.init(),  // Embedded, not allocated
    mutex: *Mutex,
    stored_waker: ?Waker = null,

    pub fn poll(self: *@This(), ctx: *Context) PollResult(void) {
        switch (self.state) {
            .init => {
                if (self.mutex.tryLock()) {
                    self.state = .acquired;
                    return .{ .ready = {} };
                }
                // Store waker, add self.waiter to mutex's intrusive list
                self.stored_waker = ctx.getWaker().clone();
                self.waiter.setWaker(@ptrCast(self), wakeCallback);
                if (!self.mutex.lockWait(&self.waiter)) {
                    self.state = .waiting;
                    return .pending;
                }
                self.state = .acquired;
                return .{ .ready = {} };
            },
            .waiting => {
                if (self.waiter.isAcquired()) {
                    self.state = .acquired;
                    return .{ .ready = {} };
                }
                return .pending;
            },
            .acquired => return .{ .ready = {} },
        }
    }
};
```

The `Mutex.Waiter` struct contains intrusive list pointers (`next`, `prev`)
that the mutex uses to track waiting tasks. When the mutex is unlocked, it
walks the list and wakes the first waiter -- no heap allocation needed.

Compare with a stackful approach where the runtime would need to allocate a
waiter node and enqueue it:

```
Stackful:   waiter = allocator.create(WaiterNode);  // heap allocation
            mutex.enqueue(waiter);
            suspend();  // stack switch

Stackless:  self.waiter already exists in the future struct
            mutex.enqueue(&self.waiter);   // no allocation
            return .pending;               // function return
```

---

## The Future of Futures in Zig

Zig 0.15 does not have language-level async/await. The manual state machines
shown above are the current cost of the stackless approach. But this is
temporary.

When Zig reintroduces async/await (planned for a future version), the compiler
will transform code like this:

```zig
// Future Zig async/await (speculative syntax)
fn handleConnection(conn: TcpStream) async void {
    const request = await conn.read(&buf);
    const response = processRequest(request);
    await conn.write(response);
}
```

Into a state machine equivalent to what blitz-io users write by hand today.
The generated state machine will have the same characteristics:

- Small, known size at comptime.
- No stack allocation.
- Explicit `.pending` / `.ready` returns.
- Waker-based notification.

blitz-io's `Future` trait, `PollResult` type, `Waker` mechanism, and
scheduler are all designed to be compatible with this future direction. When
async/await lands, the manual state machines go away but the runtime stays.

The investment in a stackless runtime is not a compromise for today's Zig
limitations. It is the architecture that Zig async will compile to, and that
Rust's async ecosystem has proven at scale.

---

## Summary

| Criterion | Stackful | Stackless |
|-----------|----------|-----------|
| Memory per task | 8-64 KB | 100-512 bytes |
| Million-task feasibility | Difficult (8-64 GB) | Practical (100-512 MB) |
| Context switch cost | 200-500 ns | 5-20 ns |
| Cache behavior | Poor (stack pollution) | Excellent (compact) |
| Platform portability | Assembly per arch | Zero platform code |
| Wait allocation | 0 (on stack) | 0 (intrusive) |
| Programming model | Natural (sync-looking) | Explicit (state machine) |
| Future Zig compat | Unclear | Direct match |
| Size at comptime | No | Yes |
| Guard pages | Required | Not needed |

blitz-io chose stackless because the target is millions of concurrent tasks
with minimal overhead, and because the architecture aligns with where Zig is
headed. The manual state machines are the price paid today. The runtime is the
investment that pays off regardless of how the language evolves.
