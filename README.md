<p align="center">
  <strong>blitz-io</strong>
</p>

<p align="center">
  <strong>Tokio-style async I/O for Zig. Lightweight tasks, serious throughput.</strong>
</p>

<p align="center">
  <a href="https://github.com/NerdMeNot/blitz-io/actions/workflows/ci.yml"><img src="https://github.com/NerdMeNot/blitz-io/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache_2.0-blue.svg" alt="License"></a>
</p>

blitz-io is a high-performance async I/O runtime for Zig. It is the I/O counterpart to [Blitz](https://github.com/NerdMeNot/blitz) (CPU parallelism) -- analogous to how Tokio complements Rayon in the Rust ecosystem.

- **Work-stealing scheduler**: Lock-free 256-slot ring buffer with LIFO slot, cooperative budgeting (128 polls/tick), O(1) bitmap worker waking
- **Platform-optimized I/O**: io_uring (Linux), kqueue (macOS), IOCP (Windows), epoll (fallback) -- auto-detected at startup
- **Zero-allocation sync primitives**: Mutex, RwLock, Semaphore, Barrier, Notify, OnceCell -- intrusive waiters embedded in futures, no heap per wait
- **Structured channels**: MPSC, MPMC (Vyukov lock-free), Oneshot, Broadcast, Watch, Select -- 50 B/op vs 1348 B/op (Tokio)

```zig
const io = @import("blitz-io");

pub fn main() !void {
    try io.run(serve);
}

fn serve() void {
    var listener = io.net.listen("0.0.0.0:8080") catch return;
    defer listener.close();
    while (listener.tryAccept() catch null) |conn| {
        _ = io.task.spawn(echo, .{conn.stream}) catch continue;
    }
}

fn echo(stream: io.net.TcpStream) void {
    var s = stream;
    defer s.close();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = s.tryRead(&buf) catch return orelse continue;
        if (n == 0) return;
        s.writeAll(buf[0..n]) catch return;
    }
}
```

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [API Reference](#api-reference)
  - [Modules](#modules)
  - [Task Spawning](#task-spawning)
  - [Synchronization](#synchronization)
  - [Channels](#channels)
  - [Networking](#networking)
  - [Time](#time)
- [Performance](#performance)
- [Architecture](#architecture)
- [Best Practices](#best-practices)
- [Limitations](#limitations)
- [Acknowledgments](#acknowledgments)

## Installation

### Requirements

- Zig 0.15.0 or later
- Linux, macOS, or Windows

### Using Zig Package Manager

Add to your `build.zig.zon`:

```zig
.{
    .name = .my_project,
    .version = "0.1.0",
    .minimum_zig_version = "0.15.0",

    .dependencies = .{
        .blitz_io = .{
            .url = "https://github.com/NerdMeNot/blitz-io/archive/refs/tags/v0.1.0.tar.gz",
            .hash = "blitz_io-0.1.0-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
            // Run `zig build` to get the correct hash
        },
    },

    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

Add to your `build.zig`:

```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get blitz-io dependency
    const blitz_io_dep = b.dependency("blitz_io", .{
        .target = target,
        .optimize = optimize,
    });

    // Create your executable
    const exe = b.addExecutable(.{
        .name = "my_app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add blitz-io module
    exe.root_module.addImport("blitz-io", blitz_io_dep.module("blitz-io"));

    b.installArtifact(exe);
}
```

### Building from Source

```bash
git clone https://github.com/NerdMeNot/blitz-io.git
cd blitz-io
zig build              # Build library
zig build test         # Run unit tests (588+ tests)
zig build test-stress  # Run stress tests
zig build test-all     # Run all test suites
```

## Quick Start

### TCP Echo Server

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
        if (n == 0) return;
        stream.writeAll(buf[0..n]) catch return;
    }
}
```

### Concurrent Tasks

```zig
const io = @import("blitz-io");

pub fn main() !void {
    try io.run(fetchAll);
}

fn fetchAll() !void {
    // Spawn concurrent tasks
    const user_h = try io.task.spawn(fetchUser, .{42});
    const posts_h = try io.task.spawn(fetchPosts, .{42});

    // Wait for both
    const user, const posts = try io.task.joinAll(.{ user_h, posts_h });
    _ = user;
    _ = posts;
}
```

### Graceful Shutdown

```zig
const io = @import("blitz-io");

pub fn main() !void {
    var shutdown = try io.shutdown.Shutdown.init();
    defer shutdown.deinit();

    var listener = try io.net.listen("0.0.0.0:8080");
    defer listener.close();

    while (!shutdown.isShutdown()) {
        if (listener.tryAccept() catch null) |result| {
            var work = shutdown.startWork();
            defer work.deinit();
            handleConnection(result.stream);
        }
    }

    shutdown.waitForPending();
}
```

## API Reference

### Modules

| Module | Description |
|--------|-------------|
| `io.task` | Task spawning: spawn, sleep, yield, joinAll, race, select |
| `io.sync` | Synchronization: Mutex, RwLock, Semaphore, Notify, Barrier, OnceCell |
| `io.channel` | Message passing: Channel, Oneshot, Broadcast, Watch, Select |
| `io.net` | Networking: TCP, UDP, Unix sockets, DNS resolution |
| `io.fs` | Filesystem operations |
| `io.stream` | I/O streams: Reader, Writer, buffered I/O |
| `io.time` | Duration, Instant, Sleep, Timeout, Interval |
| `io.signal` | Signal handling (SIGINT, SIGTERM) |
| `io.process` | Process spawning and piped I/O |
| `io.shutdown` | Graceful shutdown coordination |
| `io.async_ops` | Future combinators: Timeout, Select, Join, Race |
| `io.future` | Low-level future types: Poll, Waker, Context |

### Task Spawning

| Function | Description |
|----------|-------------|
| `task.spawn(fn, args)` | Spawn async task, returns `JoinHandle` |
| `task.spawnFuture(future)` | Spawn a Future directly |
| `task.spawnBlocking(fn, args)` | Run on dedicated blocking pool thread |
| `task.sleep(duration)` | Async-aware sleep |
| `task.yield()` | Yield to scheduler |
| `task.joinAll(handles)` | Wait for all tasks, return results tuple |
| `task.tryJoinAll(handles)` | Wait for all, collect results and errors |
| `task.race(handles)` | First to complete wins, cancel others |
| `task.select(handles)` | First to complete, keep others running |

### Synchronization

All primitives are zero-allocation and require no `deinit()`. Each provides two tiers: `tryX()` (non-blocking, returns immediately) and `x()` (returns a Future for the scheduler).

| Primitive | Use Case | API |
|-----------|----------|-----|
| `Mutex` | Protect shared state | `tryLock()`, `lock()` -> Future |
| `RwLock` | Many readers, one writer | `tryReadLock()`, `readLock()` / `writeLock()` |
| `Semaphore` | Limit concurrent access | `tryAcquire(n)`, `acquire(n)` -> Future |
| `Notify` | Task wake-up signal | `notifyOne()`, `notifyAll()`, `wait()` |
| `Barrier` | Wait for N tasks | `wait()` -> leader/follower result |
| `OnceCell` | Lazy one-time init | `get()`, `getOrInit(fn)` |

### Channels

| Channel | Pattern | Allocation | Description |
|---------|---------|------------|-------------|
| `Channel(T)` | MPSC / MPMC | Heap (bounded) | Bounded work queue with backpressure |
| `Oneshot(T)` | 1:1 | None | Single-value delivery |
| `BroadcastChannel(T)` | 1:N | Heap (bounded) | All receivers get all messages |
| `Watch(T)` | 1:N | None | Single value with change notification |

Each channel provides `trySend()`/`tryRecv()` (non-blocking) and `send()`/`recv()` (Future-based).

```zig
// Bounded channel
var ch = try io.channel.bounded(Task, allocator, 100);
defer ch.deinit();

switch (ch.trySend(task)) {
    .ok => {},
    .full => {},     // backpressure
    .closed => {},   // receiver dropped
}

// Oneshot
var os = io.channel.oneshot(Result);
os.sender.send(computeResult());
if (os.receiver.tryRecv()) |result| { ... }

// Watch
var config = io.channel.watch(Config, default_config);
config.send(new_config);
```

### Networking

| Type | Description |
|------|-------------|
| `TcpListener` | Accept incoming TCP connections |
| `TcpStream` | Bidirectional TCP connection |
| `TcpSocket` | Socket builder for custom configuration |
| `UdpSocket` | Connectionless datagram socket |
| `UnixStream` | Unix domain stream socket |
| `UnixListener` | Unix domain socket listener |
| `UnixDatagram` | Unix domain datagram socket |
| `Address` | IPv4/IPv6 socket address |

Convenience functions: `net.listen(addr)`, `net.connect(addr)`, `net.listenPort(port)`, `net.resolve(host, port)`, `net.connectHost(host, port)`.

### Time

| Type / Function | Description |
|-----------------|-------------|
| `Duration` | Span of time (nanosecond precision) |
| `Instant` | Point in time (monotonic clock) |
| `Sleep` | Async-aware sleep future |
| `Interval` | Recurring timer |
| `Deadline` | Timeout tracking |

```zig
const dur = io.time.Duration.fromSecs(5);
const start = io.time.Instant.now();
io.task.sleep(dur);
const elapsed = start.elapsed();
```

## Performance

Benchmarks on Apple M3, comparing blitz-io to Tokio (Rust). All measurements in nanoseconds per operation.

### Uncontended Synchronization

| Benchmark | blitz-io (ns) | Tokio (ns) | Winner |
|-----------|---------------|------------|--------|
| Mutex | 6.6 | 7.8 | blitz-io +1.2x |
| RwLock (read) | 6.8 | 7.9 | blitz-io +1.2x |
| RwLock (write) | 6.6 | 8.0 | blitz-io +1.2x |
| Semaphore | 6.5 | 7.5 | blitz-io +1.2x |

### Channels

| Benchmark | blitz-io (ns) | Tokio (ns) | Winner |
|-----------|---------------|------------|--------|
| Channel send | 2.7 | 5.8 | blitz-io +2.2x |
| Channel recv | 6.1 | 9.7 | blitz-io +1.6x |
| Channel roundtrip | 6.3 | 12.5 | blitz-io +2.0x |
| Oneshot | 3.9 | 15.4 | blitz-io +3.9x |
| Broadcast (4 recv) | 22.2 | 48.7 | blitz-io +2.2x |
| Watch | 13.1 | 43.7 | blitz-io +3.3x |

### Coordination

| Benchmark | blitz-io (ns) | Tokio (ns) | Winner |
|-----------|---------------|------------|--------|
| OnceCell get | 0.4 | 0.5 | blitz-io +1.1x |
| OnceCell set | 9.5 | 30.4 | blitz-io +3.2x |
| Barrier | 15.4 | 368.6 | blitz-io +23.9x |
| Notify | 9.7 | 9.4 | Tie |

### Contended (Multi-threaded)

| Benchmark | blitz-io (ns) | Tokio (ns) | Winner |
|-----------|---------------|------------|--------|
| Mutex (4 threads) | 115.5 | 81.2 | Tokio +1.4x |
| RwLock (4R + 2W) | 108.1 | 95.1 | Tokio +1.1x |
| Semaphore (8T, 2 permits) | 77.5 | 127.7 | blitz-io +1.6x |
| Channel MPMC (4P + 4C) | 85.6 | 61.1 | Tokio +1.4x |

### Summary

**blitz-io wins 14/18 benchmarks, Tokio wins 3/18, 1 tie.**

Memory efficiency: blitz-io averages **50.2 B/op** vs Tokio's **1347.6 B/op** -- 27x less memory per operation.

## Architecture

```
+-----------------------------------------------------------------+
|                       User Application                          |
|            io.run(fn) / Runtime.init() + rt.run()               |
+-----------------------------------------------------------------+
                              |
+-----------------------------------------------------------------+
|                        Public API                               |
|  io.task    io.sync    io.channel    io.net    io.fs    io.time |
|  io.signal  io.process io.shutdown   io.stream io.async_ops    |
+-----------------------------------------------------------------+
                              |
+-----------------------------------------------------------------+
|                     Runtime Core                                |
|  +------------------+  +---------------+  +------------------+  |
|  |    Scheduler     |  |   I/O Driver  |  |   Timer Wheel    |  |
|  |                  |  |               |  |                  |  |
|  | - LIFO slot      |  | - Submit ops  |  | - Hierarchical   |  |
|  | - Local queue    |  | - Poll events |  | - Tick-based     |  |
|  |   (256-slot ring)|  | - Complete    |  | - Cancel support |  |
|  | - Global inject  |  |               |  |                  |  |
|  | - Work stealing  |  |               |  |                  |  |
|  | - Coop budget    |  |               |  |                  |  |
|  |   (128 polls)    |  |               |  |                  |  |
|  +------------------+  +---------------+  +------------------+  |
|                              |                                  |
|  +----------------------------------------------------------+  |
|  |                   Blocking Pool                           |  |
|  |  - Dedicated threads for CPU-heavy / blocking work        |  |
|  |  - Auto-scaling up to 512 threads                         |  |
|  |  - 10s idle timeout                                       |  |
|  +----------------------------------------------------------+  |
+-----------------------------------------------------------------+
                              |
+-----------------------------------------------------------------+
|                    Platform Backend                              |
|  +----------+  +----------+  +----------+  +----------+        |
|  | io_uring |  |  kqueue  |  |   IOCP   |  |  epoll   |        |
|  | (Linux)  |  | (macOS)  |  | (Windows)|  |(fallback)|        |
|  +----------+  +----------+  +----------+  +----------+        |
+-----------------------------------------------------------------+
```

### Key Design Decisions

1. **Stackless by choice**: blitz-io deliberately uses stackless futures -- each task is a compiler-generated state machine at ~256-512 bytes rather than a full coroutine stack (16-64KB). Stackful coroutines offer nicer ergonomics (suspend anywhere, natural call stacks), but stackless wins on the metrics that matter for a high-performance runtime: predictable memory (no stack growth surprises), cache-friendly layout, and the ability to run millions of concurrent tasks without blowing through memory. This is the same tradeoff Tokio and Go made in opposite directions -- we side with Tokio.

2. **Tokio-style state machine**: Single 64-bit packed atomic with CAS transitions for task state. The `notified` bit is cleared atomically in `transitionToIdle`, returning previous state to detect missed wakeups.

3. **Work-stealing scheduler**: LIFO slot for hot-path locality, local FIFO ring buffer (256 slots), global injection queue with mutex. O(1) worker waking via bitmap with `@ctz`.

4. **Cooperative budgeting**: 128 polls per tick (matching Tokio). Prevents a single task from starving others.

5. **Zero-allocation waiters**: Waiter structs are embedded directly in `LockFuture`/`AcquireFuture` types. No heap allocation per contended wait.

6. **Two-tier API**: Every sync primitive and channel offers `tryX()` (non-blocking, returns immediately) and `x()` (returns a Future for the scheduler). Use the right tier for your context.

## Best Practices

### Do

```zig
// DO: Use io.run() for simple programs
pub fn main() !void {
    try io.run(myApp);
}

// DO: Wrap operations with timeouts
var timeout_future = io.async_ops.Timeout(MyFuture).init(
    my_future,
    io.time.Duration.fromSecs(5),
);

// DO: Use spawnBlocking for CPU-intensive work
const hash = try io.task.spawnBlocking(computeExpensiveHash, .{data});

// DO: Use tryX() when you can handle failure immediately
if (mutex.tryLock()) {
    defer mutex.unlock();
    // critical section
}

// DO: Track in-flight work for graceful shutdown
var work = shutdown.startWork();
defer work.deinit();
handleRequest(conn);

// DO: Use bounded channels for backpressure
var ch = try io.channel.bounded(Job, allocator, 1000);
```

### Don't

```zig
// DON'T: Block the I/O thread with CPU-heavy work
fn handleRequest(conn: io.net.TcpStream) void {
    // BAD: This blocks a scheduler worker thread
    const hash = expensiveSha256(huge_payload);
    // GOOD: Offload to blocking pool
    const hash = try io.task.spawnBlocking(expensiveSha256, .{huge_payload});
}

// DON'T: Use OS blocking primitives inside async tasks
fn badTask() void {
    std.Thread.sleep(1_000_000_000);  // BAD: blocks worker thread
    io.task.sleep(io.time.Duration.fromSecs(1));  // GOOD: yields to scheduler
}

// DON'T: Forget to close resources
fn leaky() void {
    var listener = io.net.listen("0.0.0.0:8080") catch return;
    // BAD: listener never closed!
    // GOOD: defer listener.close();
}

// DON'T: Ignore channel backpressure
switch (ch.trySend(item)) {
    .ok => {},
    .full => {},     // BAD: silently dropping work
    .closed => {},
}
```

## Limitations

### Current Limitations

1. **No coroutine/async-await syntax**: Zig 0.15.x does not have async/await. All async operations use manual state machines and the Future/Poll interface. This will improve when Zig adds language-level async support.

2. **No TLS/SSL**: blitz-io provides raw TCP/UDP/Unix sockets. TLS must be handled by a separate library layered on top.

3. **DNS resolution is blocking**: `net.resolve()` and `net.connectHost()` use blocking OS calls. Use `task.spawnBlocking()` to avoid stalling I/O workers.

4. **No HTTP protocol**: blitz-io is a runtime, not a web framework. HTTP servers/clients should be built on top of `io.net`.

5. **Single runtime per process**: The runtime uses thread-local state. Running multiple `Runtime` instances concurrently is not supported.

6. **Contended lock performance**: Under high contention (4+ threads on the same lock), Tokio's mutex and MPMC channel are 1.1-1.4x faster. Uncontended and channel operations favor blitz-io.

### Platform-Specific Notes

- **Linux**: Full support. io_uring (kernel 5.1+) preferred, epoll fallback for older kernels.
- **macOS**: Full support via kqueue. Tested on both x86_64 and Apple Silicon.
- **Windows**: IOCP backend. Requires Windows 10+.

## Documentation

- Source-level documentation: every public module has doc comments with usage examples
- Examples: `examples/` directory (build with `zig build example-shutdown`, etc.)
- Tests: `zig build test-all` runs all test suites (588+ unit, 83 concurrency, 35+ robustness)

## Contributing

Contributions are welcome. Please read [CLAUDE.md](CLAUDE.md) for development guidelines, architecture details, and the implementation roadmap.

```bash
zig build test         # Unit tests
zig build test-stress  # Stress tests (real threads)
zig build test-all     # Everything
```

## License

Apache 2.0. See [LICENSE](LICENSE).

## Acknowledgments

- [Tokio](https://github.com/tokio-rs/tokio) -- Design inspiration for the runtime architecture, scheduler, and sync primitives. Tokio's battle-tested platform-specific code informed many of our edge case handlers.
- [Blitz](https://github.com/NerdMeNot/blitz) -- Sibling project for CPU-bound parallelism. blitz-io handles I/O; Blitz handles compute.
- The Zig community for building a language that makes systems programming accessible without sacrificing control.
