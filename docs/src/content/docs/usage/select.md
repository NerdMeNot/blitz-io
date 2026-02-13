---
title: Select
description: Waiting on multiple futures simultaneously with Select, Join, Race, and Timeout combinators.
---

When a task needs to wait on multiple async operations and respond to whichever completes first, blitz-io provides several combinator types. These are in the `async_ops` module.

## Combinator overview

| Combinator | Description | Heterogeneous | Homogeneous |
|------------|-------------|:---:|:---:|
| `Select2`, `Select3` | First to complete wins (different types) | Yes | -- |
| `SelectN` | First to complete wins (same type) | -- | Yes |
| `Join2`, `Join3` | Wait for all (different types) | Yes | -- |
| `JoinN` | Wait for all (same type) | -- | Yes |
| `Race` | First value wins | -- | Yes |
| `All` | Collect all values | -- | Yes |
| `Timeout` | Wrap any future with a deadline | Yes | -- |

## Select2 / Select3

Race two or three futures of different types. Returns as soon as the first one completes. The losing futures are not automatically cancelled -- you can inspect them or continue polling.

```zig
const io = @import("blitz-io");
const async_ops = io.async_ops;

// Two futures of different types
var accept_future = listener.accept();
var signal_future = io.signal.signalFuture(&shutdown_handler);

var select = async_ops.Select2(
    @TypeOf(accept_future),
    @TypeOf(signal_future),
).init(accept_future, signal_future);

// Poll the select
switch (select.poll(&ctx)) {
    .first => |conn| {
        // Accept completed first
        handleConnection(conn);
    },
    .second => |sig| {
        // Signal received
        log.info("Shutdown: {}", .{sig});
    },
    .pending => {
        // Neither is ready yet
    },
}
```

`Select3` works the same way with three branches:

```zig
var select = async_ops.Select3(FutA, FutB, FutC).init(a, b, c);
switch (select.poll(&ctx)) {
    .first => |a_result| { ... },
    .second => |b_result| { ... },
    .third => |c_result| { ... },
    .pending => {},
}
```

## SelectN

Race N futures of the **same** type. Returns the index and value of the first to complete:

```zig
var futures = [_]FetchFuture{
    fetch(url1),
    fetch(url2),
    fetch(url3),
};

var selectN = async_ops.SelectN(FetchFuture, 3).init(&futures);

switch (selectN.poll(&ctx)) {
    .ready => |result| {
        log.info("Future {} completed first with: {}", .{
            result.index,
            result.value,
        });
    },
    .pending => {},
}
```

## Join2 / Join3

Wait for all futures to complete. Unlike `Select`, `Join` continues polling until **every** branch is ready.

```zig
var join = async_ops.Join2(UserFuture, PostsFuture).init(
    fetchUser(user_id),
    fetchPosts(user_id),
);

switch (join.poll(&ctx)) {
    .ready => |results| {
        const user = results[0];
        const posts = results[1];
        renderProfile(user, posts);
    },
    .pending => {},
}
```

## JoinN

Wait for N homogeneous futures:

```zig
var futures = [_]HealthCheckFuture{
    checkService("db"),
    checkService("cache"),
    checkService("queue"),
};

var joinN = async_ops.JoinN(HealthCheckFuture, 3).init(&futures);

switch (joinN.poll(&ctx)) {
    .ready => |results| {
        for (results) |health| {
            reportHealth(health);
        }
    },
    .pending => {},
}
```

## Race

A simplified `SelectN` that returns just the winning value (no index):

```zig
var futures = [_]FetchFuture{ fetch(url1), fetch(url2), fetch(url3) };
var racer = async_ops.Race(FetchFuture, 3).init(&futures);

switch (racer.poll(&ctx)) {
    .ready => |value| useFirstResult(value),
    .pending => {},
}
```

## All

A simplified `JoinN` that collects all results into an array:

```zig
var futures = [_]FetchFuture{ fetch(url1), fetch(url2), fetch(url3) };
var joiner = async_ops.All(FetchFuture, 3).init(&futures);

switch (joiner.poll(&ctx)) {
    .ready => |values| {
        for (values) |v| processResult(v);
    },
    .pending => {},
}
```

## Timeout

Wrap any future with a deadline. If the inner future does not complete within the specified duration, the timeout future completes with a timeout indication.

```zig
var read_future = stream.read(&buf);

var timeout = async_ops.Timeout(@TypeOf(read_future)).init(
    read_future,
    io.time.Duration.fromSecs(5),
);

switch (timeout.poll(&ctx)) {
    .ready => |inner_result| {
        // Inner future completed within the deadline
        handleReadResult(inner_result);
    },
    .timed_out => {
        // Deadline expired
        return error.TimedOut;
    },
    .pending => {},
}
```

## SelectContext (low-level)

For advanced use cases or custom select implementations, `SelectContext` provides the coordination primitive that powers `Select`. It uses atomic operations and a `CancelToken` to ensure exactly one branch wins.

```zig
const SelectContext = io.sync.select_context.SelectContext;

// Create a context for 3 branches
var ctx = SelectContext.init(3);

// Set the external waker (your task's waker)
ctx.setWaker(@ptrCast(&my_task), myWakeCallback);

// Create branch wakers to register with channels
var waker0 = ctx.branchWaker(0);
var waker1 = ctx.branchWaker(1);
var waker2 = ctx.branchWaker(2);

// Register with channels (pass waker function and context)
channel1.recvWait(&recv_waiter1);
recv_waiter1.setWaker(waker0.wakerCtx(), waker0.wakerFn());

channel2.recvWait(&recv_waiter2);
recv_waiter2.setWaker(waker1.wakerCtx(), waker1.wakerFn());

// When any channel has data, the branch waker fires,
// which calls branchReady(branch_id) on the SelectContext.
// The first branch to call branchReady wins (claims the CancelToken).

// Check the result
if (ctx.isComplete()) {
    const winner = ctx.getWinner().?;
    switch (winner) {
        0 => handleChannel1(channel1.tryRecv()),
        1 => handleChannel2(channel2.tryRecv()),
        2 => handleTimeout(),
        else => unreachable,
    }
}

// Reset for reuse
ctx.reset();
```

### BranchWaker

Each `BranchWaker` wraps a `SelectContext` and a branch ID. When its waker function is called (by a channel, signal handler, or timer), it atomically claims the `CancelToken`. If it wins, the `SelectContext` is marked complete and the external task is woken.

```zig
var bw = ctx.branchWaker(0);

bw.isWinner();     // true if this branch won
bw.isCancelled();  // true if another branch won
```

### Selector (channel-specific)

The `channel.Selector` type provides a higher-level API specifically for selecting across multiple channels:

```zig
const channel = io.channel;

var ch1 = try channel.bounded(u32, allocator, 10);
var ch2 = try channel.bounded([]const u8, allocator, 10);

var sel = channel.selector();
const branch0 = sel.addRecv(&ch1);
const branch1 = sel.addRecv(&ch2);

const result = sel.selectBlocking();
switch (result.branch) {
    branch0 => {
        if (ch1.tryRecv()) |v| processNumber(v.value);
    },
    branch1 => {
        if (ch2.tryRecv()) |v| processString(v.value);
    },
    else => {},
}
```

## Pattern: server with graceful shutdown

The most common select pattern races `accept` against a shutdown signal:

```zig
fn serverLoop(
    listener: *io.net.TcpListener,
    shutdown: *io.shutdown.Shutdown,
) !void {
    while (!shutdown.isShutdown()) {
        var accept_future = listener.accept();
        var shutdown_future = shutdown.future();

        var select = io.async_ops.Select2(
            @TypeOf(accept_future),
            io.shutdown.ShutdownFuture,
        ).init(accept_future, shutdown_future);

        switch (select.poll(&ctx)) {
            .first => |conn| {
                var guard = shutdown.startWork();
                _ = io.task.spawn(handleConn, .{ conn, &guard }) catch {
                    guard.complete();
                    continue;
                };
            },
            .second => |_| {
                log.info("Shutdown signal received", .{});
                break;
            },
            .pending => {
                // Yield to scheduler
            },
        }
    }
}
```

## Pattern: channel + timeout

Wait for a channel message with a timeout:

```zig
var recv_future = channel.recv();
var timeout = io.async_ops.Timeout(@TypeOf(recv_future)).init(
    recv_future,
    Duration.fromSecs(10),
);

switch (timeout.poll(&ctx)) {
    .ready => |msg| handleMessage(msg),
    .timed_out => handleTimeout(),
    .pending => {},
}
```

## Pattern: first successful fetch

Race multiple fetch operations, use whichever responds first:

```zig
var futures = [_]FetchFuture{
    fetchFromPrimary(key),
    fetchFromReplica(key),
};

var race = io.async_ops.Race(FetchFuture, 2).init(&futures);

switch (race.poll(&ctx)) {
    .ready => |value| return value,
    .pending => {},
}
```

## Limits

`SelectContext` supports up to `MAX_SELECT_BRANCHES` (16) branches. This limit avoids dynamic allocation -- all branch state is stack-allocated. For more than 16 branches, use `SelectN` or `JoinN` with homogeneous future types, which support arbitrary counts.
