---
title: Quick Start
description: Build a TCP echo server with blitz-io in under 30 lines of Zig.
sidebar:
  order: 2
---

This guide walks through a complete TCP echo server -- from runtime initialization to handling connections -- with a line-by-line explanation.

## The Complete Example

```zig
const std = @import("std");
const io = @import("blitz-io");

pub fn main() !void {
    try io.run(serve);
}

fn serve() void {
    var listener = io.net.listen("0.0.0.0:8080") catch return;
    defer listener.close();

    std.debug.print("Listening on 0.0.0.0:8080\n", .{});

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

## Step-by-Step Walkthrough

### 1. Import blitz-io

```zig
const io = @import("blitz-io");
```

The `blitz-io` module is the single entry point. All sub-modules are accessed through it: `io.net`, `io.task`, `io.sync`, `io.channel`, `io.time`, and so on.

### 2. Start the runtime

```zig
pub fn main() !void {
    try io.run(serve);
}
```

`io.run()` is the zero-config entry point. It:

1. Creates a `Runtime` with default settings (auto-detected worker count, page allocator)
2. Wraps your function in a `FnFuture` and spawns it on the work-stealing scheduler
3. Blocks `main` until the function completes
4. Cleans up all resources on return

For more control, use the explicit `Runtime` API:

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var rt = try io.Runtime.init(gpa.allocator(), .{
        .num_workers = 4,              // Fixed worker count
        .max_blocking_threads = 64,    // Cap blocking pool
    });
    defer rt.deinit();

    try rt.run(serve, .{});
}
```

### 3. Bind a TCP listener

```zig
var listener = io.net.listen("0.0.0.0:8080") catch return;
defer listener.close();
```

`io.net.listen()` is a convenience function that parses an address string and binds a `TcpListener`. Under the hood it calls `Address.parse()` followed by `TcpListener.bind()`.

Other listener options:

```zig
// Bind to a specific port on all interfaces
var listener = try io.net.listenPort(8080);

// Full control via TcpSocket builder
var socket = io.net.TcpSocket.init(.ipv4);
socket.setReuseAddress(true);
socket.bind(io.net.Address.fromPort(8080));
var listener = socket.listen(128); // backlog
```

### 4. Accept connections

```zig
while (listener.tryAccept() catch null) |result| {
    _ = io.task.spawn(handleClient, .{result.stream}) catch continue;
}
```

`tryAccept()` is the non-blocking accept call. It returns:

- `AcceptResult` containing `.stream` (a `TcpStream`) and `.peer_addr` (the client's `Address`) -- when a connection is ready
- `null` -- when no connection is pending (would block)
- An error -- on actual failure

Each accepted connection is handed off to a new task via `io.task.spawn()`. This spawns `handleClient` as a lightweight async task (~256 bytes) on the work-stealing scheduler. The `.{result.stream}` syntax passes the `TcpStream` as the function argument.

### 5. Echo data back

```zig
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

Inside the handler:

- **`stream.tryRead(&buf)`** attempts a non-blocking read. It returns the number of bytes read, `null` if it would block, or an error.
- **`orelse continue`** handles the would-block case by looping back to retry.
- **`n == 0`** means the client closed the connection (EOF).
- **`stream.writeAll(buf[0..n])`** writes the full buffer back. Unlike `tryWrite`, `writeAll` loops internally until all bytes are sent.

## Running the Example

Build and run:

```bash
zig build example-echo
# Or if it's your own project:
zig build run
```

Test with netcat in another terminal:

```bash
echo "hello blitz-io" | nc localhost 8080
```

You should see `hello blitz-io` echoed back.

## What Happens Under the Hood

When you call `io.run(serve)`, here is what the runtime does:

1. **Worker threads start.** The scheduler spawns N worker threads (default: number of CPU cores). Each worker has a local task queue (256-slot ring buffer) and a LIFO slot for hot-path locality.

2. **Your function becomes a task.** `serve` is wrapped in a `FnFuture` -- a single-poll future that calls your function once. This future is placed in the global injection queue.

3. **A worker picks it up.** One of the idle workers wakes (via futex), pulls the task from the global queue, and begins executing `serve()`.

4. **Each `spawn` creates a new task.** When `io.task.spawn(handleClient, .{result.stream})` is called, a new `FnFuture` is created and pushed to the current worker's LIFO slot. If that slot is full, it goes to the local queue. If the local queue is also full, it overflows to the global queue.

5. **Work stealing keeps everyone busy.** If a worker runs out of tasks in its own queue, it steals from other workers' queues. The steal order is randomized to avoid contention.

6. **Cooperative budgeting prevents starvation.** Each worker has a budget of 128 polls per tick. After 128 polls, the current task is rescheduled so other tasks get a turn.

7. **Cleanup on exit.** When `serve()` returns (or all tasks complete), the runtime shuts down workers and frees resources.

## Concurrent Tasks Example

Here is a more advanced example showing concurrent task coordination:

```zig
const io = @import("blitz-io");

pub fn main() !void {
    try io.run(app);
}

fn app() !void {
    // Spawn concurrent tasks
    const user_h = try io.task.spawn(fetchUser, .{@as(u64, 42)});
    const posts_h = try io.task.spawn(fetchPosts, .{@as(u64, 42)});

    // Wait for both to complete
    const user, const posts = try io.task.joinAll(.{ user_h, posts_h });
    _ = user;
    _ = posts;
}

fn fetchUser(id: u64) []const u8 {
    _ = id;
    return "Alice";
}

fn fetchPosts(user_id: u64) u32 {
    _ = user_id;
    return 15;
}
```

`io.task.joinAll` waits for all handles in the tuple to complete and returns a tuple of their results. Other coordination patterns:

| Function | Behavior |
|----------|----------|
| `io.task.joinAll(handles)` | Wait for all, return results tuple |
| `io.task.tryJoinAll(handles)` | Wait for all, collect results and errors |
| `io.task.race(handles)` | First to complete wins, cancel others |
| `io.task.select(handles)` | First to complete, keep others running |

## Graceful Shutdown Example

For production servers, you typically want to catch signals and drain connections:

```zig
const io = @import("blitz-io");

pub fn main() !void {
    var shutdown = try io.shutdown.Shutdown.init();
    defer shutdown.deinit();

    var listener = try io.net.listen("0.0.0.0:8080");
    defer listener.close();

    while (!shutdown.isShutdown()) {
        if (listener.tryAccept() catch null) |result| {
            // Track in-flight work
            var work = shutdown.startWork();
            defer work.deinit();
            handleConnection(result.stream);
        }
    }

    // Wait for in-flight requests to finish (with timeout)
    _ = shutdown.waitPendingTimeout(io.Duration.fromSecs(5));
}

fn handleConnection(stream: io.net.TcpStream) void {
    var conn = stream;
    defer conn.close();
    // ... handle the request ...
}
```

The `Shutdown` type catches SIGINT and SIGTERM, and the `WorkGuard` returned by `startWork()` tracks active connections so you know when it is safe to exit.

## Next Steps

Now that you have a working server, learn about the programming model:

- [Basic Concepts](/getting-started/basic-concepts/) -- Futures, the runtime, wakers, and cooperative scheduling
- [Runtime Configuration](/usage/runtime/) -- Worker count, blocking pool, backend selection
- [Networking](/usage/networking/) -- TCP, UDP, Unix sockets, DNS
- [Channels](/usage/channels/) -- MPSC, Oneshot, Broadcast, Watch
