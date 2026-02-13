---
title: Channels
description: Message passing between async tasks with Channel, Oneshot, Broadcast, and Watch.
---

Channels are the primary mechanism for passing data between tasks in blitz-io. Four channel types cover the common communication patterns.

## Channel overview

| Type | Pattern | Allocation | Close required |
|------|---------|------------|----------------|
| `Channel(T)` | Bounded MPMC (multi-producer, multi-consumer) | Yes (ring buffer) | `deinit()` |
| `Oneshot(T)` | Single value, one sender, one receiver | No | No |
| `BroadcastChannel(T)` | Fan-out, all receivers get every message | Yes (ring buffer) | `deinit()` |
| `Watch(T)` | Single value with change notification | No | No |

## Channel (bounded MPMC)

A bounded channel backed by a lock-free Vyukov/crossbeam-style ring buffer. Multiple producers and multiple consumers can operate concurrently. When the buffer is full, senders wait; when empty, receivers wait.

### Creation

```zig
const io = @import("blitz-io");

// Using the factory function
var ch = try io.channel.bounded(u32, allocator, 100);
defer ch.deinit();

// Or directly
var ch2 = try io.channel.Channel(u32).init(allocator, 100);
defer ch2.deinit();
```

### Non-blocking API

```zig
// Send
switch (ch.trySend(42)) {
    .ok => {},       // Value was placed in the buffer
    .full => {},     // Buffer is full, try again later
    .closed => {},   // Channel was closed
}

// Receive
switch (ch.tryRecv()) {
    .value => |v| processValue(v),
    .empty => {},     // No values available
    .closed => {},    // Channel closed, no more values
}
```

### Async API (Futures)

```zig
// Send future -- yields until a slot is available
var send_future = ch.send(42);
// Poll through your runtime...

// Receive future -- yields until a value is available
var recv_future = ch.recv();
// When future.poll() returns .ready, you have the value.
```

### Closing

Close the channel to signal that no more values will be sent:

```zig
ch.close();
```

After closing, `trySend` returns `.closed`. `tryRecv` continues to drain buffered values, then returns `.closed`.

### Waiter API

For custom scheduler integration:

```zig
// Receive with waiter
var waiter = io.channel.channel_mod.RecvWaiter.init();
waiter.setWaker(@ptrCast(&my_ctx), myWakeCallback);
ch.recvWait(&waiter);
// Yield to scheduler. When woken, check waiter.complete / waiter.closed.

// Send with waiter
var send_waiter = io.channel.channel_mod.SendWaiter.init();
send_waiter.setWaker(@ptrCast(&my_ctx), myWakeCallback);
ch.sendWait(value, &send_waiter);
```

---

## Oneshot

A oneshot channel delivers exactly one value from a sender to a receiver. It is zero-allocation and ideal for returning results from spawned tasks.

### Creation

```zig
var os = io.channel.oneshot(u32);
// os.sender -- use to send one value
// os.receiver -- use to receive the value
```

### Sending

The sender can send exactly one value. `send` returns `true` if the value was delivered to a waiting receiver or stored for later pickup:

```zig
_ = os.sender.send(42);
```

If the sender is dropped without sending, the receiver sees the channel as closed.

### Receiving

```zig
// Non-blocking
if (os.receiver.tryRecv()) |value| {
    // Got the value
} else {
    // Not sent yet (or sender closed without sending)
}
```

### Async receive

```zig
var waiter = io.channel.oneshot_mod.Oneshot(u32).RecvWaiter.init();
waiter.setWaker(@ptrCast(&my_ctx), myWakeCallback);

if (!os.receiver.recvWait(&waiter)) {
    // Yield to scheduler. Woken when value arrives or sender closes.
}

if (waiter.value) |v| {
    // Got the value
} else if (waiter.closed.load(.acquire)) {
    // Sender closed without sending
}
```

### Pattern: task result delivery

```zig
var os = io.channel.oneshot(ComputeResult);

// Spawn computation
const handle = try io.task.spawn(struct {
    fn run() void {
        const result = expensiveComputation();
        _ = os.sender.send(result);
    }
}.run, .{});

// ... do other work ...

// Collect result
if (os.receiver.tryRecv()) |result| {
    useResult(result);
}
```

---

## BroadcastChannel

A broadcast channel delivers every sent message to **all** subscribed receivers. It uses a ring buffer, and slow receivers that fall behind may miss messages.

### Creation

```zig
var bc = try io.channel.broadcast(Event, allocator, 16);
defer bc.deinit();
```

The capacity (16) is the size of the ring buffer.

### Subscribing

Create receivers by subscribing to the channel:

```zig
var rx1 = bc.subscribe();
var rx2 = bc.subscribe();
```

Each receiver maintains its own read position in the ring buffer.

### Sending

Sends are non-blocking and never fail (unless the channel is closed):

```zig
_ = bc.send(Event{ .kind = .user_joined, .user_id = 42 });
```

If a receiver is too slow and the ring buffer wraps, that receiver's oldest unread messages are overwritten.

### Receiving

```zig
switch (rx1.tryRecv()) {
    .value => |event| handleEvent(event),
    .empty => {},     // No new messages
    .lagged => |n| {
        // Missed n messages due to slow consumption
        // The next tryRecv will return the oldest available message
    },
    .closed => {},    // Channel was closed
}
```

### Async receive

```zig
var waiter = io.channel.broadcast_mod.RecvWaiter.init();
waiter.setWaker(@ptrCast(&my_ctx), myWakeCallback);
rx1.recvWait(&waiter);
// Yield until a new message arrives.
```

---

## Watch

A watch channel holds a single value and notifies receivers when it changes. Only the latest value is kept -- there is no history. This is perfect for configuration or state that changes over time.

### Creation

```zig
var watch = io.channel.watch(Config, default_config);
```

Zero-allocation, no `deinit` required.

### Updating the value

```zig
watch.send(Config{
    .max_connections = 200,
    .timeout_ms = 5000,
});
```

### Observing changes

```zig
var rx = watch.subscribe();

// Check if value changed since last read
if (rx.hasChanged()) {
    const config = rx.borrow();
    applyConfig(config.*);
    rx.markSeen();
}
```

### Async: wait for changes

```zig
var waiter = io.channel.watch_mod.ChangeWaiter.init();
waiter.setWaker(@ptrCast(&my_ctx), myWakeCallback);
rx.waitForChange(&waiter);
// Yield to scheduler. Woken when value is updated.
```

### Pattern: config hot-reload

```zig
var config_watch = io.channel.watch(AppConfig, default_config);

// Config reloader task
fn reloadLoop() void {
    while (running) {
        const new_config = loadConfigFromFile("config.toml");
        config_watch.send(new_config);
        sleep(Duration.fromSecs(30));
    }
}

// Worker task
fn workerLoop() void {
    var rx = config_watch.subscribe();
    while (running) {
        if (rx.hasChanged()) {
            const cfg = rx.borrow();
            updateWorkerSettings(cfg.*);
            rx.markSeen();
        }
        doWork();
    }
}
```

---

## Choosing the right channel

| Need | Channel type |
|------|-------------|
| Work queue with backpressure | `Channel` (bounded MPMC) |
| Return a single result from a task | `Oneshot` |
| Configuration that changes at runtime | `Watch` |
| Event fan-out to multiple consumers | `BroadcastChannel` |
| Multiple producers, single consumer | `Channel` |
| Multiple producers, multiple consumers | `Channel` |
| Fire-and-forget notifications | `BroadcastChannel` |
| Latest-value observation | `Watch` |

### Resource management summary

| Type | Needs allocator | Needs `deinit()` |
|------|:---------------:|:----------------:|
| `Channel(T)` | Yes | Yes |
| `BroadcastChannel(T)` | Yes | Yes |
| `Oneshot(T)` | No | No |
| `Watch(T)` | No | No |

### Performance notes

- `Channel` uses a lock-free ring buffer for `trySend`/`tryRecv`. The waiter queue uses a separate mutex that never touches the data path.
- `Oneshot` is entirely lock-free (atomic state machine).
- `BroadcastChannel` uses atomic sequence numbers per slot for lock-free reads.
- `Watch` uses a version counter with atomic compare-and-swap.
