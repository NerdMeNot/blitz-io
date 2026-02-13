---
title: Runtime
description: Creating and configuring the blitz-io runtime, spawning tasks, and managing the application lifecycle.
---

The `Runtime` is the entry point for every blitz-io application. It owns the work-stealing scheduler, the blocking thread pool, and the I/O driver. All async tasks execute within the context of a runtime.

## Zero-config entry point

The simplest way to run an async program is `io.run()`, which creates a runtime with sensible defaults and blocks the calling thread until the provided function completes:

```zig
const io = @import("blitz-io");

pub fn main() !void {
    try io.run(server);
}

fn server() void {
    // This runs inside the runtime.
    // All blitz-io APIs (net, sync, channel, time) are available here.
}
```

Behind the scenes `io.run` allocates a runtime with `std.heap.page_allocator`, spawns the function as a stackless future, and calls `blockingJoin` on the resulting handle.

## Custom configuration

For production use, pass an allocator and a `Config` struct via `io.runWith`:

```zig
const io = @import("blitz-io");
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    try io.runWith(gpa.allocator(), .{
        .num_workers = 4,
        .max_blocking_threads = 128,
        .blocking_keep_alive_ns = 30 * std.time.ns_per_s,
    }, server);
}

fn server() void {
    // ...
}
```

### Config fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `num_workers` | `usize` | `0` (auto) | I/O worker thread count. `0` means one per logical CPU. |
| `max_blocking_threads` | `usize` | `512` | Upper limit on blocking pool threads. |
| `blocking_keep_alive_ns` | `u64` | 10 seconds | Idle blocking threads exit after this duration. |
| `backend` | `?BackendType` | `null` (auto) | Force a specific I/O backend (io_uring, kqueue, epoll, IOCP). |

When `num_workers` is `0`, the runtime queries the OS for the number of logical CPUs and creates one worker thread per core.

## Manual runtime management

If you need more control, create the `Runtime` directly:

```zig
const io = @import("blitz-io");

pub fn main() !void {
    var rt = try io.Runtime.init(std.heap.page_allocator, .{
        .num_workers = 2,
    });
    defer rt.deinit();

    // Run an async entry point, blocking until it returns.
    try rt.run(myApp, .{});
}

fn myApp() !void {
    // Async work here
}
```

### Spawning futures

`Runtime.spawn` submits a `Future`-implementing type onto the work-stealing scheduler and returns a `JoinHandle`:

```zig
const LockFuture = @import("blitz-io").sync.mutex.LockFuture;

var mutex = io.sync.Mutex.init();

// Spawn a LockFuture onto the scheduler
const handle = try rt.spawn(LockFuture, mutex.lock());
_ = handle.blockingJoin();
defer mutex.unlock();
```

`JoinHandle.blockingJoin()` parks the calling OS thread until the future completes. This is the bridge between synchronous and asynchronous worlds -- typically called only once at the top level of `main`.

### Spawning blocking work

CPU-intensive or legacy blocking I/O should run on the blocking pool so the async workers stay responsive:

```zig
const handle = try rt.spawnBlocking(computeHash, .{data});
const hash = try handle.wait();
```

Blocking pool threads are created on demand (up to `max_blocking_threads`) and reclaimed after the keep-alive timeout.

## Task spawning from within async context

Inside an async context (from functions passed to `rt.run` or spawned futures), use the `task` module:

```zig
const io = @import("blitz-io");

fn myApp() !void {
    // Spawn concurrent tasks
    const user_h = try io.task.spawn(fetchUser, .{user_id});
    const posts_h = try io.task.spawn(fetchPosts, .{user_id});

    // Wait for both
    const user, const posts = try io.task.joinAll(.{ user_h, posts_h });

    // Use results...
    _ = user;
    _ = posts;
}
```

### Available task functions

| Function | Description |
|----------|-------------|
| `task.spawn(func, args)` | Spawn async task, returns `JoinHandle` |
| `task.spawnFuture(future)` | Spawn a `Future`-implementing value |
| `task.spawnBlocking(func, args)` | Run on the blocking thread pool |
| `task.joinAll(handles)` | Wait for all tasks, return tuple of results |
| `task.tryJoinAll(handles)` | Wait for all, collect results and errors |
| `task.race(handles)` | First to complete wins, cancel others |
| `task.select(handles)` | First to complete, keep others running |

## Shutdown and cleanup

Call `rt.deinit()` to shut down the runtime. This:

1. Sets the shutdown flag (atomic store).
2. Stops the blocking pool (joins idle threads, waits for active ones).
3. Stops the scheduler (signals workers, joins threads, frees task memory).

Always use `defer rt.deinit()` immediately after `init` to guarantee cleanup even on error paths:

```zig
var rt = try io.Runtime.init(allocator, .{});
defer rt.deinit();
```

For servers that need to drain in-flight requests before exiting, see [Signals & Shutdown](/usage/signals-shutdown/).

## Thread-local runtime access

Inside a runtime, the current `Runtime` pointer is stored in a thread-local variable. Access it with:

```zig
const runtime_mod = @import("blitz-io").internal.runtime;

// Returns ?*Runtime -- null if not inside a runtime context.
const rt = runtime_mod.getRuntime();

// Panics if not inside a runtime context.
const rt2 = runtime_mod.runtime();
```

This is primarily useful for library code that needs to access the scheduler or blocking pool without threading the runtime through every function signature.

## Architecture at a glance

```
main() thread
  |
  v
Runtime.init()
  |-- Scheduler (N worker threads, work-stealing deques)
  |-- BlockingPool (on-demand threads, up to max_blocking_threads)
  |-- I/O Driver (platform backend: io_uring / kqueue / epoll / IOCP)
  |
  v
rt.run(myApp, .{})  -->  spawn FnFuture  -->  blockingJoin()
  |
  v
rt.deinit()
```

Each worker thread runs a tight loop: poll local deque, steal from siblings, check global queue, poll I/O, advance timers. Tasks are stackless futures weighing approximately 256-512 bytes, enabling millions of concurrent tasks.
