# Channels

blitz-io provides four channel types and a Select mechanism for message passing between tasks. Channels are the primary way to communicate data between concurrent tasks without shared mutable state.

## Which Channel to Use?

| Need | Channel Type | Allocation |
|------|-------------|------------|
| Request/response (single value) | `Oneshot` | None |
| Work queue (many producers, one consumer) | `Channel` (MPSC) | Heap (ring buffer) |
| Work queue (many producers, many consumers) | `Channel` (MPMC) | Heap (ring buffer) |
| Event fan-out (all receivers get every message) | `BroadcastChannel` | Heap (ring buffer) |
| Latest value / config broadcasting | `Watch` | None |
| First of many channel ops | `Select` | None (stack-allocated) |

## API Tiers

Like sync primitives, channels expose multiple API tiers:

| Tier | Send | Receive |
|------|------|---------|
| Non-blocking | `trySend(v)` | `tryRecv()` |
| Waiter | (via SendWaiter) | (via RecvWaiter) |
| Async Future | `send(v)` -> SendFuture | `recv()` -> RecvFuture |

## Factory Functions

The `io.channel` namespace provides convenience factory functions:

```zig
const io = @import("blitz-io");

var ch = try io.channel.bounded(u32, allocator, 100);
var os = io.channel.oneshot(Result);
var bc = try io.channel.broadcast(Event, allocator, 16);
var wt = io.channel.watch(Config, default_config);
```

---

## Channel (Bounded MPSC/MPMC)

A bounded channel backed by a Vyukov/crossbeam-style lock-free ring buffer. Supports multiple producers and multiple consumers with per-slot sequence numbers.

### Algorithm

Each slot has a sequence counter initialized to its index:

- **Send at position `tail`**: If `slot.sequence == tail`, the slot is writable. After writing, set `slot.sequence = tail + 1`.
- **Receive at position `head`**: If `slot.sequence == head + 1`, the slot has data. After reading, set `slot.sequence = head + capacity`.

Buffer operations (`trySend`/`tryRecv`) are fully lock-free using CAS on head/tail positions. A separate `waiter_mutex` protects only the waiter lists for async operations, never touching the hot data path.

### API

```zig
var ch = try io.channel.Channel(u32).init(allocator, 256);
defer ch.deinit();
```

**Non-blocking send:**

```zig
switch (ch.trySend(42)) {
    .ok => {},           // Value sent
    .full => {},         // Buffer full -- handle backpressure
    .closed => {},       // Channel was closed
}
```

**Non-blocking receive:**

```zig
switch (ch.tryRecv()) {
    .value => |v| processValue(v),
    .empty => {},        // No value available
    .closed => {},       // Channel closed, no more values
}
```

**Async Future send/recv:**

```zig
var send_future = ch.send(42);    // Returns SendFuture
var recv_future = ch.recv();      // Returns RecvFuture
defer send_future.deinit();
defer recv_future.deinit();
// Poll through runtime until ready.
```

**Close:**

```zig
ch.close();
// Subsequent sends return .closed.
// Receivers drain remaining values, then get .closed.
```

### Resource management

`Channel(T)` requires an allocator for the ring buffer. Call `deinit()` when done.

### Example: Work queue

```zig
const io = @import("blitz-io");

var work_queue = try io.channel.bounded(Task, allocator, 1024);
defer work_queue.deinit();

// Producer
fn enqueueWork(task: Task) void {
    switch (work_queue.trySend(task)) {
        .ok => {},
        .full => dropTask(task),     // Backpressure
        .closed => return,
    }
}

// Consumer
fn processLoop() void {
    while (true) {
        switch (work_queue.tryRecv()) {
            .value => |task| executeTask(task),
            .empty => std.Thread.sleep(1 * std.time.ns_per_ms),
            .closed => return,
        }
    }
}
```

---

## Oneshot

A single-value, single-use channel. The sender sends exactly one value; the receiver receives it. Zero allocation -- sender and receiver are value types backed by shared state.

### API

```zig
var pair = io.channel.oneshot(u32);
// pair.sender  -- Oneshot(u32).Sender
// pair.receiver -- Oneshot(u32).Receiver
```

**Sender:**

```zig
const delivered = pair.sender.send(42);
// Returns true if receiver was waiting and value was delivered.
// Returns false if receiver was dropped or value already sent.
```

**Receiver (non-blocking):**

```zig
if (pair.receiver.tryRecv()) |value| {
    // Got value
} else {
    // Not yet available
}
```

**Receiver (waiter):**

```zig
var waiter = io.channel.oneshot_mod.Oneshot(u32).RecvWaiter.init();
waiter.setWaker(@ptrCast(&ctx), wakeFn);

if (!pair.receiver.recvWait(&waiter)) {
    // Yield -- will be woken when value arrives or sender drops
}
// After waking:
if (waiter.value) |v| {
    // Use v
} else if (waiter.closed.load(.acquire)) {
    // Sender dropped without sending
}
```

**Receiver (async Future):**

```zig
var future = pair.receiver.recv(); // Returns RecvFuture
defer future.deinit();
// Resolves to ?T (null if sender dropped without sending).
```

### State machine

```
EMPTY ---send---> VALUE_SENT ---recv---> (consumed)
  |
  +---recvWait---> RECEIVER_WAITING ---send---> (delivered directly)
  |
  +---drop sender---> CLOSED
```

### Performance

Oneshot round-trip: 4.0ns (3.7x faster than Tokio's 14.7ns).

### Example: Request/response

```zig
const io = @import("blitz-io");

fn fetchUser(id: u64) ?User {
    var pair = io.channel.oneshot(User);

    // Send request to service
    requestService(.{ .get_user = id, .reply = &pair.sender });

    // Wait for response
    if (pair.receiver.tryRecv()) |user| {
        return user;
    }
    return null;
}
```

---

## BroadcastChannel

A broadcast channel where every sent value is received by ALL receivers. Uses a ring buffer with reference counting per slot. Senders never block.

### API

```zig
var bc = try io.channel.broadcast(Event, allocator, 16);
defer bc.deinit();
```

**Subscribe (create a receiver):**

```zig
var rx1 = bc.subscribe();
var rx2 = bc.subscribe();
// Each receiver independently tracks its position in the ring.
```

**Send (broadcasts to all receivers):**

```zig
const num_receivers = bc.send(Event{ .type = .user_login, .user_id = 42 });
// Returns number of active receivers that will see this message.
```

**Receive (non-blocking):**

```zig
switch (rx1.tryRecv()) {
    .value => |event| handleEvent(event),
    .empty => {},        // No new messages
    .lagged => |count| {
        // Receiver fell behind by `count` messages.
        // Oldest messages were overwritten. Position auto-advanced.
    },
    .closed => {},       // Channel closed
}
```

**Receive (async Future):**

```zig
var future = rx1.recv(); // Returns RecvFuture
defer future.deinit();
// Resolves to the next broadcast value.
```

### Lagging receivers

When a receiver falls behind and the ring buffer wraps around, the oldest messages are lost. The receiver gets a `.lagged` result with the count of missed messages, and its position is automatically advanced to the oldest available message.

### Resource management

`BroadcastChannel(T)` requires an allocator. Call `deinit()` when done. Receivers do not need explicit cleanup.

### Example: Event bus

```zig
const io = @import("blitz-io");

var events = try io.channel.broadcast(AppEvent, allocator, 64);
defer events.deinit();

// Multiple subscribers
var audit_rx = events.subscribe();
var metrics_rx = events.subscribe();
var ui_rx = events.subscribe();

// Publisher
fn publishEvent(event: AppEvent) void {
    _ = events.send(event);
}

// Each subscriber processes independently
fn auditLoop() void {
    while (true) {
        switch (audit_rx.tryRecv()) {
            .value => |e| writeAuditLog(e),
            .lagged => |n| logWarning("audit missed {} events", .{n}),
            .empty => std.Thread.sleep(1 * std.time.ns_per_ms),
            .closed => return,
        }
    }
}
```

### Performance

Broadcast send: 23.4ns (2.1x faster than Tokio's 49.5ns).

---

## Watch

A watch channel holds a single value with change notification. The sender can update the value, and multiple receivers can watch for changes. Only the latest value is kept -- there is no history.

Ideal for configuration values, feature flags, or any state where receivers only care about the current value, not every intermediate update.

### API

```zig
var config = io.channel.watch(Config, default_config);
```

**Send (update value):**

```zig
config.send(new_config);
// Wakes all receivers that are waiting for changes.
```

**Receiver:**

```zig
var rx = config.subscribe();
```

**Check for changes:**

```zig
if (rx.hasChanged()) {
    const cfg = rx.borrow();
    // Use cfg (pointer to current value)
    rx.markSeen(); // Mark current version as seen
}
```

**Receive (blocking wait for next change):**

```zig
switch (rx.tryRecv()) {
    .value => |cfg| {
        // New value available
    },
    .empty => {
        // No change since last seen
    },
    .closed => {
        // Sender dropped
    },
}
```

**Receive (async Future):**

```zig
var future = rx.recv(); // Returns RecvFuture
defer future.deinit();
// Resolves to T when value changes.
```

### Version tracking

Watch uses an internal version counter. Each receiver tracks the last version it has seen. `hasChanged()` compares the receiver's version against the current version.

### Resource management

`Watch(T)` is zero-allocation. No `deinit()` required.

### Performance

Watch round-trip: 13.0ns (3.4x faster than Tokio's 44.2ns).

### Example: Runtime configuration

```zig
const io = @import("blitz-io");

const FeatureFlags = struct {
    enable_cache: bool = true,
    max_connections: u32 = 1000,
    log_level: enum { debug, info, warn, err } = .info,
};

var flags = io.channel.watch(FeatureFlags, .{});

// Config updater (e.g., from admin API)
fn updateFlags(new: FeatureFlags) void {
    flags.send(new);
}

// Worker reads current config
fn getMaxConnections() u32 {
    var rx = flags.subscribe();
    return rx.borrow().max_connections;
}
```

---

## Select

Select races multiple channel operations. The first to complete wins; other branches are cancelled.

### API

```zig
const io = @import("blitz-io");

var ch1 = try io.channel.bounded(u32, allocator, 10);
var ch2 = try io.channel.bounded([]const u8, allocator, 10);

// Create selector
var sel = io.channel.selector(4); // max 4 branches

// Register branches
const branch0 = sel.addRecv(&ch1);
const branch1 = sel.addRecv(&ch2);

// Wait for first ready (blocking)
const result = sel.selectBlocking();
switch (result.branch) {
    branch0 => {
        if (ch1.tryRecv()) |v| {
            processNumber(v.value);
        }
    },
    branch1 => {
        if (ch2.tryRecv()) |v| {
            processMessage(v.value);
        }
    },
}
```

### Design

- Uses `SelectContext` for coordination across branches.
- First branch to complete claims a `CancelToken`.
- Non-winning branches are automatically cancelled.
- All waiter storage is stack-allocated (zero heap allocation).

### Future-based Select

For integration with the scheduler's Future system, use the combinator types:

```zig
const io = @import("blitz-io");

// Select2: race two futures
var select = io.async_ops.Select2(FutureA, FutureB).init(
    future_a,
    future_b,
);
// Poll returns .first, .second, or .pending
```

### Example: Graceful shutdown with Select

A common pattern is to race the accept loop against a shutdown signal:

```zig
const io = @import("blitz-io");

fn serverLoop(shutdown: *io.shutdown.Shutdown) void {
    var listener = io.net.listen("0.0.0.0:8080") catch return;
    defer listener.close();

    while (!shutdown.isShutdown()) {
        if (listener.tryAccept() catch null) |result| {
            handleConnection(result.stream);
        } else {
            if (shutdown.isShutdown()) break;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }
}
```

---

## Channel Performance Summary

Benchmark results on Apple M3 (nanoseconds per operation):

| Channel | Operation | blitz-io | Tokio | Ratio |
|---------|-----------|----------|-------|-------|
| Channel | send | 5.3ns | 5.7ns | 1.1x faster |
| Channel | recv | 3.1ns | 9.6ns | 3.1x faster |
| Channel | roundtrip | 4.8ns | 12.4ns | 2.6x faster |
| Channel | MPMC | 190.8ns | 60.5ns | 3.2x slower |
| Oneshot | roundtrip | 4.0ns | 14.7ns | 3.7x faster |
| Broadcast | send | 23.4ns | 49.5ns | 2.1x faster |
| Watch | update | 13.0ns | 44.2ns | 3.4x faster |

The MPMC contended case is the main area where Tokio currently leads. SPSC and MPSC patterns are where blitz-io excels.

Run `zig build compare` for the full comparison on your hardware.

---

## Resource Management Summary

| Type | Allocator | `deinit()` Required |
|------|-----------|---------------------|
| `Channel(T)` | Yes | Yes |
| `BroadcastChannel(T)` | Yes | Yes |
| `Oneshot(T)` | No | No |
| `Watch(T)` | No | No |
