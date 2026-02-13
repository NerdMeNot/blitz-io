---
title: Core API
description: Runtime lifecycle, configuration, task spawning, Future types, and error handling in blitz-io.
---

Every blitz-io application starts here. The core API gives you the runtime -- the engine that manages worker threads, I/O polling, timers, and task scheduling behind the scenes. You configure it once at startup, hand it your root function, and it takes care of the rest.

Most applications need just two things from this page: an entry point (`io.run` or `io.runWith`) and the `Config` struct. The Future system and manual `Runtime` management are for advanced use cases like custom schedulers, library integration, or composing async pipelines.

### At a Glance

```zig
const io = @import("blitz-io");

// Simplest possible app -- zero config, auto-detect everything:
pub fn main() !void {
    try io.run(myApp);
}

fn myApp() void {
    // Everything inside here runs on the async runtime.
    // io.task, io.sync, io.channel, io.net, io.time -- all available.
}
```

```zig
// Production app -- custom allocator, tuned config, leak detection:
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    try io.runWith(gpa.allocator(), .{
        .num_workers = 4,              // pin to 4 cores
        .max_blocking_threads = 128,   // cap blocking pool
    }, myApp);
}
```

## Module Import

```zig
const io = @import("blitz-io");
```

All types are accessed through the `io` namespace: `io.Runtime`, `io.Config`, `io.task`, `io.sync`, etc.

## Entry Points

### `io.run`

```zig
pub fn run(comptime func: anytype) anyerror!PayloadType(@TypeOf(func))
```

Zero-config entry point. Initializes a runtime with default settings (`page_allocator`, auto-detect workers), runs `func` as the root task, and shuts down.

```zig
const io = @import("blitz-io");

pub fn main() !void {
    try io.run(serve);
}

fn serve() void {
    var listener = io.net.listen("0.0.0.0:8080") catch return;
    defer listener.close();

    while (listener.tryAccept() catch null) |result| {
        _ = io.task.spawn(handleClient, .{result.stream}) catch continue;
    }
}

fn handleClient(conn: io.net.TcpStream) void {
    var stream = conn;
    defer stream.close();

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = stream.tryRead(&buf) catch return orelse continue;
        if (n == 0) return; // Client disconnected
        stream.writeAll(buf[0..n]) catch return;
    }
}
```

:::tip
`io.run` is the simplest way to start. Use `io.runWith` when you need control over the allocator or worker count.
:::

### `io.runWith`

```zig
pub fn runWith(
    allocator: std.mem.Allocator,
    config: Config,
    comptime func: anytype,
) anyerror!PayloadType(@TypeOf(func))
```

Entry point with custom allocator and configuration. This is the recommended production entry point because it gives you control over memory and threading.

```zig
const std = @import("std");
const io = @import("blitz-io");

pub fn main() !void {
    // Use GeneralPurposeAllocator so we can detect memory leaks on exit
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            std.debug.print("Memory leak detected!\n", .{});
        }
    }

    try io.runWith(gpa.allocator(), .{
        .num_workers = 4,
        .max_blocking_threads = 64,
    }, startServer);
}

fn startServer() void {
    // This runs inside the async runtime with 4 I/O workers
    // and up to 64 blocking threads available
}
```

### `io.getRuntime`

```zig
pub fn getRuntime() ?*Runtime
```

Returns the current thread's runtime, or `null` if not running inside one. Useful for libraries that need optional runtime access.

```zig
/// Library function that works both inside and outside a runtime.
fn processData(data: []const u8) ![]u8 {
    if (io.getRuntime()) |rt| {
        // We're inside a runtime -- offload CPU work to the blocking pool
        const handle = try rt.spawnBlocking(compressPayload, .{data});
        return try handle.wait();
    } else {
        // No runtime -- run synchronously on this thread
        return compressPayload(data);
    }
}
```

---

## Runtime

### `io.Runtime`

The async I/O runtime. Combines a work-stealing scheduler, I/O driver, blocking pool, and timer wheel.

#### `init`

```zig
pub fn init(allocator: Allocator, config: Config) !Runtime
```

Initialize the runtime. Spawns worker threads (based on config) and sets up the I/O backend.

#### `deinit`

```zig
pub fn deinit(self: *Runtime) void
```

Shut down the runtime. Signals all workers to stop, joins threads, frees resources.

#### `run`

```zig
pub fn run(self: *Runtime, comptime func: anytype, args: anytype) anyerror!FnPayload(@TypeOf(func))
```

Run a function on the runtime, blocking the calling thread until complete. Creates a `FnFuture` from the function, spawns it, and blocks via `blockingJoin()`.

```zig
var rt = try io.Runtime.init(allocator, .{});
defer rt.deinit();
try rt.run(myServer, .{});
```

#### `spawn`

```zig
pub fn spawn(self: *Runtime, comptime F: type, future: F) !JoinHandle(F.Output)
```

Spawn a Future onto the scheduler. The future will be polled by worker threads until completion. Returns a `JoinHandle` to await or cancel the task.

`F` must be a type with:
- `pub const Output = T;` -- the result type
- `pub fn poll(self: *F, ctx: *Context) PollResult(T)` -- the poll function

```zig
// Spawn a mutex lock future and wait for it
const handle = try rt.spawn(@TypeOf(lock_future), lock_future);
_ = handle.blockingJoin();
```

#### `spawnBlocking`

```zig
pub fn spawnBlocking(self: *Runtime, comptime func: anytype, args: anytype) !*BlockingHandle(ResultType(@TypeOf(func)))
```

Spawn a function on the blocking thread pool. Use for CPU-intensive or blocking I/O work that would starve the async I/O workers.

```zig
// Offload a heavy computation so it doesn't block I/O workers
const handle = try rt.spawnBlocking(computeSha256, .{file_bytes});
const digest = try handle.wait();
```

:::note
Blocking threads are spawned on demand and expire after an idle timeout (default 10 seconds). The pool never exceeds `max_blocking_threads`.
:::

#### `getBlockingPool`

```zig
pub fn getBlockingPool(self: *Runtime) *BlockingPool
```

Access the blocking pool directly.

#### `getScheduler`

```zig
pub fn getScheduler(self: *Runtime) *Scheduler
```

Access the underlying work-stealing scheduler.

---

## Configuration

### `io.Config`

```zig
pub const Config = struct {
    /// Number of I/O worker threads (0 = auto based on CPU count).
    num_workers: usize = 0,

    /// Maximum blocking pool threads (default: 512).
    max_blocking_threads: usize = 512,

    /// Blocking thread idle timeout in nanoseconds (default: 10 seconds).
    blocking_keep_alive_ns: u64 = 10 * std.time.ns_per_s,

    /// I/O backend type (null = auto-detect).
    backend: ?BackendType = null,
};
```

| Field | Default | Description |
|-------|---------|-------------|
| `num_workers` | `0` (auto) | Worker thread count. 0 = `std.Thread.getCpuCount()`. |
| `max_blocking_threads` | `512` | Upper bound on blocking pool threads. |
| `blocking_keep_alive_ns` | 10s | Idle blocking threads exit after this duration. |
| `backend` | `null` (auto) | I/O backend: `.io_uring`, `.kqueue`, `.epoll`, `.iocp`, or `null` for auto-detect. |

### Configuration Profiles

Different workloads benefit from different configurations. Here are recommended starting points:

```zig
const std = @import("std");
const io = @import("blitz-io");

/// High-throughput web server: many connections, mostly I/O-bound.
/// Workers match CPU count so each core handles its own event loop.
/// Large blocking pool absorbs occasional disk I/O or DNS lookups.
const web_server_config = io.Config{
    .num_workers = 0, // auto-detect CPU count
    .max_blocking_threads = 256,
    .blocking_keep_alive_ns = 30 * std.time.ns_per_s, // keep threads warm
};

/// CPU-heavy pipeline: data parsing, compression, image processing.
/// Fewer I/O workers since most work happens on blocking threads.
/// Blocking pool sized to saturate cores without over-subscribing.
const cpu_pipeline_config = io.Config{
    .num_workers = 2, // minimal I/O workers
    .max_blocking_threads = 16, // bounded to avoid context-switch overhead
    .blocking_keep_alive_ns = 60 * std.time.ns_per_s,
};

/// Latency-sensitive service: trading, gaming, real-time control.
/// Pinned worker count prevents OS scheduling jitter.
/// Short keep-alive so idle threads release resources quickly.
const low_latency_config = io.Config{
    .num_workers = 4, // fixed, no auto-detect
    .max_blocking_threads = 8,
    .blocking_keep_alive_ns = 2 * std.time.ns_per_s, // reclaim fast
    .backend = .io_uring, // lowest latency on Linux 5.11+
};
```

---

## Future System

The Future system is the foundation of all async operations in blitz-io. Every sync primitive, channel, timer, and I/O operation produces a Future.

### `io.future.PollResult`

```zig
pub fn PollResult(comptime T: type) type {
    return union(enum) {
        ready: T,
        pending: void,
    };
}
```

The result of polling a future. Either the value is ready, or the future is still pending.

```zig
const result = my_future.poll(&ctx);
if (result.isReady()) {
    const value = result.ready;
}
```

### `io.future.Context`

```zig
pub const Context = struct {
    waker: *const Waker,

    pub fn getWaker(self: *Context) Waker { ... }
};
```

Passed to `poll()`. Contains the waker that the future must use to signal when it can make progress.

### `io.future.Waker`

The mechanism for waking a suspended task. When a future returns `.pending`, it must store the waker and call `waker.wakeByRef()` when the operation completes.

```zig
pub const Waker = struct {
    raw: RawWaker,

    pub fn wakeByRef(self: *const Waker) void { ... }
    pub fn clone(self: *const Waker) Waker { ... }
    pub fn deinit(self: *Waker) void { ... }
    pub fn willWakeSame(self: *const Waker, other: Waker) bool { ... }
};
```

### Future Trait

Any type `F` is a valid Future if it has:

```zig
pub const Output = T;
pub fn poll(self: *F, ctx: *Context) PollResult(T);
```

Check at comptime with `io.future.isFuture(F)`.

Here is a complete example of implementing a custom Future. This one retries an operation up to a fixed number of times before giving up:

```zig
const io = @import("blitz-io");

/// A future that polls an inner future, retrying on failure up to
/// `max_retries` times. Each retry re-initializes the inner future.
fn RetryFuture(comptime Inner: type) type {
    return struct {
        const Self = @This();
        pub const Output = Inner.Output;

        inner: Inner,
        create_fn: *const fn () Inner,
        retries_left: u32,

        pub fn init(create: *const fn () Inner, max_retries: u32) Self {
            return .{
                .inner = create(),
                .create_fn = create,
                .retries_left = max_retries,
            };
        }

        pub fn poll(self: *Self, ctx: *io.future.Context) io.future.PollResult(Output) {
            const result = self.inner.poll(ctx);
            switch (result) {
                .ready => return result,
                .pending => {
                    // Inner future is not done yet. If it signals an
                    // error state internally, we could retry here.
                    // For now, just propagate pending.
                    if (self.retries_left > 0) {
                        self.retries_left -= 1;
                        self.inner = self.create_fn();
                        // Immediately re-poll the fresh future
                        return self.inner.poll(ctx);
                    }
                    return .pending;
                },
            }
        }
    };
}
```

### Built-in Futures

| Type | Description |
|------|-------------|
| `Ready(T)` | Immediately ready with a value |
| `Pending(T)` | Never completes |
| `Lazy(F)` | Computes on first poll |
| `FnFuture(func, Args)` | Wraps a plain function as a single-poll future |
| `MapFuture(F, G)` | Transform a future's output |
| `AndThenFuture(F, G)` | Chain two futures sequentially |

```zig
const io = @import("blitz-io");

// Ready: a future that resolves immediately.
// Useful as a return value when no async work is needed.
var immediate = io.future.Ready(i32).init(42);

// Pending: a future that never completes.
// Useful as a placeholder or in select() where you want one branch
// to never fire.
var never: io.future.Pending(i32) = .{};
_ = &never;
```

### Compose (Fluent API)

```zig
const result = io.future.compose(my_future)
    .map(transformFn)
    .andThen(nextAsyncOp);
```

`Compose` wraps any future with fluent combinator methods: `.map()`, `.andThen()`.

Here is a longer example showing how to build a processing pipeline by chaining `.map()` and `.andThen()`. Each step transforms or extends the result of the previous one:

```zig
const std = @import("std");
const io = @import("blitz-io");

// Suppose we have a channel that delivers raw sensor readings.
// We want to: receive a reading -> convert units -> validate range ->
// produce a ValidatedReading future that stores the result.

const SensorReading = struct { raw_value: f64, sensor_id: u32 };
const CalibratedReading = struct { celsius: f64, sensor_id: u32 };

const ValidatedReading = struct {
    celsius: f64,
    sensor_id: u32,
    in_range: bool,
};

/// Step 1: Convert raw ADC counts to Celsius.
fn calibrate(reading: SensorReading) CalibratedReading {
    // Linear calibration: raw 0-4095 maps to -40..+125 C
    const celsius = (reading.raw_value / 4095.0) * 165.0 - 40.0;
    return .{ .celsius = celsius, .sensor_id = reading.sensor_id };
}

/// Step 2: Validate that the reading is within operational range.
/// Returns a Ready future so it can be used with .andThen().
fn validateRange(cal: CalibratedReading) io.future.Ready(ValidatedReading) {
    const in_range = cal.celsius >= -20.0 and cal.celsius <= 80.0;
    return io.future.Ready(ValidatedReading).init(.{
        .celsius = cal.celsius,
        .sensor_id = cal.sensor_id,
        .in_range = in_range,
    });
}

/// Build the full pipeline from a RecvFuture.
fn buildPipeline(recv_future: anytype) @TypeOf(io.future.compose(recv_future)
    .map(calibrate)
    .andThen(validateRange)) {
    // compose() wraps the recv future, then we chain:
    //   .map(calibrate)    -- synchronous transform (SensorReading -> CalibratedReading)
    //   .andThen(validate) -- async step (CalibratedReading -> Ready(ValidatedReading))
    return io.future.compose(recv_future)
        .map(calibrate)
        .andThen(validateRange);
}
```

:::note
`Compose(F)` is itself a Future, so composed pipelines can be passed directly to `rt.spawn()` or `io.task.spawnFuture()`.
:::

---

## JoinHandle

Returned by `spawn()`. Provides methods to interact with a running task.

### Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `join` | `fn join(self: *JoinHandle) !T` | Block until the task completes and return its result. |
| `blockingJoin` | `fn blockingJoin(self: *JoinHandle) T` | Block until complete. Panics on error. |
| `tryJoin` | `fn tryJoin(self: *JoinHandle) ?T` | Non-blocking check. Returns `null` if not finished. |
| `cancel` | `fn cancel(self: *JoinHandle) void` | Request cancellation. |
| `isFinished` | `fn isFinished(self: *JoinHandle) bool` | Check if the task has completed. |
| `deinit` | `fn deinit(self: *JoinHandle) void` | Detach from the task (fire-and-forget). |

### Spawn and Join with Error Handling

This example shows the typical lifecycle of spawning a task, handling errors from `join()`, and falling back gracefully:

```zig
const std = @import("std");
const io = @import("blitz-io");
const log = std.log.scoped(.worker);

const UserProfile = struct {
    id: u64,
    name: []const u8,
    email: []const u8,
};

fn fetchUserProfile(user_id: u64) UserProfile {
    // Simulate fetching a user profile from a database or API.
    // In a real application, this would involve I/O.
    return .{
        .id = user_id,
        .name = "Alice",
        .email = "alice@example.com",
    };
}

fn fetchUserPosts(user_id: u64) u32 {
    // Simulate counting user posts.
    _ = user_id;
    return 42;
}

fn handleRequest(user_id: u64) void {
    // Spawn two concurrent tasks to fetch data in parallel
    const profile_handle = io.task.spawn(fetchUserProfile, .{user_id}) catch {
        log.err("Failed to spawn profile fetch task", .{});
        return;
    };

    const posts_handle = io.task.spawn(fetchUserPosts, .{user_id}) catch {
        log.err("Failed to spawn posts fetch task", .{});
        // Cancel the first task since we cannot complete the request
        profile_handle.cancel();
        return;
    };

    // Wait for both tasks. join() returns an error union.
    const profile = profile_handle.join() catch |err| {
        log.err("Profile fetch failed: {}", .{err});
        posts_handle.cancel(); // Clean up the other task
        return;
    };

    const post_count = posts_handle.join() catch |err| {
        log.err("Posts fetch failed: {}", .{err});
        return;
    };

    log.info("User {s} (id={}) has {} posts", .{
        profile.name,
        profile.id,
        post_count,
    });
}
```

### Fire-and-Forget Tasks

If you do not need the result, call `deinit()` on the handle to detach:

```zig
fn emitMetrics(event_name: []const u8, latency_ns: u64) void {
    // Send metrics to a stats collector. We do not care about
    // the result -- if it fails, we just lose that data point.
    _ = event_name;
    _ = latency_ns;
}

fn processRequest(payload: []const u8) void {
    const start = std.time.nanoTimestamp();

    // ... process the request ...
    _ = payload;

    const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);

    // Fire-and-forget: spawn the metrics task and immediately detach
    if (io.task.spawn(emitMetrics, .{ "request_processed", elapsed })) |handle| {
        handle.deinit(); // Detach -- task runs in background
    } else |_| {
        // Spawning failed; metrics are best-effort, so just continue
    }
}
```

### Multi-Task Coordination

The `io.task` module provides helpers for common multi-task patterns:

```zig
const io = @import("blitz-io");

// joinAll: wait for all tasks, fail on first error.
// Returns a tuple of results in the same order as the handles.
const h1 = try io.task.spawn(fetchUser, .{id});
const h2 = try io.task.spawn(fetchPosts, .{id});
const user, const posts = try io.task.joinAll(.{ h1, h2 });

// tryJoinAll: wait for all tasks, collecting successes AND errors.
// Never fails early -- every task runs to completion.
const results = io.task.tryJoinAll(.{ h1, h2, h3 });
for (results) |result| {
    switch (result) {
        .ok => |value| handleSuccess(value),
        .err => |e| handleError(e),
    }
}

// race: first to complete wins, cancel the rest.
// All handles must have the same Output type.
const h_primary = try io.task.spawn(fetchFromPrimary, .{key});
const h_replica = try io.task.spawn(fetchFromReplica, .{key});
const fastest_result = try io.task.race(.{ h_primary, h_replica });

// select: first to complete wins, others keep running.
// Returns both the result and the index of the winning task.
const result, const winner_index = try io.task.select(.{ h1, h2 });
```

---

## Version

```zig
pub const version = struct {
    pub const major = 0;
    pub const minor = 2;
    pub const patch = 0;
    pub const string = "0.2.0";
};
```

Access via `io.version.string` or individual components.

---

## Common Patterns

### Web Server Bootstrap

A complete startup pattern for a production web server, including allocator setup, configuration, graceful shutdown wiring, and connection handling:

```zig
const std = @import("std");
const io = @import("blitz-io");
const log = std.log.scoped(.server);

pub fn main() !void {
    // 1. Set up a leak-detecting allocator for the runtime.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            log.err("Memory leak detected on shutdown", .{});
        }
    }
    const allocator = gpa.allocator();

    // 2. Initialize shutdown handler BEFORE the runtime.
    //    This registers SIGINT/SIGTERM so Ctrl+C triggers clean exit.
    var shutdown_handler = try io.shutdown.Shutdown.init();
    defer shutdown_handler.deinit();

    // 3. Start the runtime with a tuned configuration.
    try io.runWith(allocator, .{
        .num_workers = 0, // auto-detect CPU count
        .max_blocking_threads = 128,
    }, struct {
        fn entry() void {
            // This is the root task -- runs on the scheduler.
            serveHttp(&shutdown_handler) catch |err| {
                log.err("Server error: {}", .{err});
            };
        }
        // Use a closure-like pattern: capture shutdown_handler
        // by referencing the outer scope. In Zig 0.15, we pass
        // it via the struct's comptime-known pointer.
        var shutdown_handler: *io.shutdown.Shutdown = undefined;
    }.entry);

    // 4. After runWith returns, the runtime is fully stopped.
    log.info("Server exited cleanly", .{});
}

fn serveHttp(shutdown_handler: *io.shutdown.Shutdown) !void {
    var listener = try io.net.listen("0.0.0.0:8080");
    defer listener.close();

    log.info("Listening on :8080", .{});

    while (!shutdown_handler.isShutdown()) {
        if (listener.tryAccept() catch null) |result| {
            // Track in-flight work for graceful drain
            var guard = shutdown_handler.startWork();

            _ = io.task.spawn(struct {
                fn handle(stream: io.net.TcpStream, work: *io.shutdown.WorkGuard) void {
                    defer work.deinit(); // Decrements pending count on exit

                    var conn = stream;
                    defer conn.close();

                    var buf: [4096]u8 = undefined;
                    while (true) {
                        const n = conn.tryRead(&buf) catch return orelse continue;
                        if (n == 0) return;
                        conn.writeAll(buf[0..n]) catch return;
                    }
                }
            }.handle, .{ result.stream, &guard }) catch {
                guard.deinit(); // Release the guard if spawn fails
                continue;
            };
        } else {
            // No pending connection -- check shutdown between polls
            if (shutdown_handler.isShutdown()) break;
            std.Thread.sleep(1_000_000); // 1ms
        }
    }

    // Drain: wait for in-flight requests to finish (up to 10 seconds)
    log.info("Shutting down, waiting for {} pending requests...", .{
        shutdown_handler.pendingCount(),
    });
    if (!shutdown_handler.waitPendingTimeout(io.time.Duration.fromSecs(10))) {
        log.warn("Timed out waiting for pending requests", .{});
    }
}
```

### Background Worker Pattern

Spawn long-running background tasks alongside the main server loop. This pattern is common for periodic cleanup, metric flushing, or queue processing:

```zig
const std = @import("std");
const io = @import("blitz-io");
const log = std.log.scoped(.worker);

/// Background worker that periodically flushes an in-memory buffer
/// to disk. Runs on the blocking pool so it never stalls I/O workers.
fn flushLoop(interval_secs: u64, shutdown: *io.shutdown.Shutdown) void {
    while (!shutdown.isShutdown()) {
        // Sleep without blocking I/O workers
        std.Thread.sleep(interval_secs * std.time.ns_per_s);

        // Flush is CPU/disk-bound, so run it on the blocking pool
        const handle = io.task.spawnBlocking(flushBufferToDisk, .{}) catch {
            log.warn("Failed to spawn flush task", .{});
            continue;
        };

        // Wait for the flush to finish before scheduling the next one
        _ = handle.wait() catch |err| {
            log.err("Flush failed: {}", .{err});
        };
    }
    log.info("Flush worker exiting", .{});
}

fn flushBufferToDisk() void {
    // Simulate writing buffered data to disk.
    // In a real system, this would serialize and fsync.
    std.Thread.sleep(50_000_000); // 50ms simulated I/O
}

/// Start the server with a background flush worker alongside it.
fn startWithBackgroundWorker(shutdown: *io.shutdown.Shutdown) void {
    // Spawn the background flush worker.
    // It runs concurrently with the main accept loop.
    const worker_handle = io.task.spawn(flushLoop, .{
        @as(u64, 30), // flush every 30 seconds
        shutdown,
    }) catch {
        log.err("Failed to spawn background worker", .{});
        return;
    };

    // Run the main server loop (blocks until shutdown)
    serveRequests(shutdown);

    // After the server loop exits, wait for the worker to finish
    _ = worker_handle.join() catch |err| {
        log.warn("Background worker error on join: {}", .{err});
    };
}

fn serveRequests(shutdown: *io.shutdown.Shutdown) void {
    // Main accept loop (simplified)
    while (!shutdown.isShutdown()) {
        std.Thread.sleep(10_000_000); // 10ms poll interval
    }
}
```

### Graceful Runtime Setup with GPA

A minimal but complete pattern for setting up the runtime with proper resource cleanup. This is the recommended starting template for any blitz-io application:

```zig
const std = @import("std");
const io = @import("blitz-io");

pub fn main() !void {
    // GeneralPurposeAllocator catches leaks and double-frees in debug builds.
    // In ReleaseFast, it compiles to a thin wrapper over the page allocator.
    var gpa = std.heap.GeneralPurposeAllocator(.{
        // Optional: enable stack traces for allocation tracking.
        // Helpful when debugging leaks, but has overhead.
        .stack_trace_frames = 8,
    }){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            @panic("Memory leak detected -- check allocation sites above");
        }
    }

    // Initialize the runtime manually for full control over lifecycle.
    var runtime = try io.Runtime.init(gpa.allocator(), .{
        .num_workers = 0, // auto-detect
    });
    defer runtime.deinit(); // Joins all worker threads, frees scheduler memory

    // Run the application. The return value propagates from appMain().
    try runtime.run(appMain, .{});
}

fn appMain() void {
    // Application logic runs here, inside the async runtime.
    // All io.task, io.sync, io.channel, and io.net APIs are available.

    const handle = io.task.spawn(doWork, .{}) catch return;
    _ = handle.join() catch |err| {
        std.debug.print("Work failed: {}\n", .{err});
    };
}

fn doWork() void {
    // Your application logic
}
```

:::tip
The three-step pattern -- allocator setup, runtime init, defer cleanup -- ensures that resources are released in the correct order even when errors occur. Always `defer runtime.deinit()` immediately after `init()` succeeds.
:::
