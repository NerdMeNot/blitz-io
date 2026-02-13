---
title: Parallel Tasks
description: Concurrent task patterns with joinAll, tryJoinAll, race, and select for health checks, speculative execution, and fan-out work.
---

Most real applications need to do several things at once -- check multiple services, fetch from the fastest mirror, or split a batch across workers. blitz-io's task combinators (`joinAll`, `tryJoinAll`, `race`, `select`) make these patterns safe and ergonomic. This recipe makes them the star of the show.

:::tip[What you will learn]
- **`joinAll`** -- run N tasks in parallel and wait for all results
- **`tryJoinAll`** -- like `joinAll` but collects successes and failures instead of short-circuiting
- **`race`** -- wait for the first task to complete, cancel the rest
- **`select`** -- wait for the first task to complete, keep the rest running
- **Fan-out / scatter-gather** -- split work across workers and collect results
:::

## Complete Example

This example builds a health-check dashboard that probes multiple services concurrently and reports their status.

```zig
const std = @import("std");
const io = @import("blitz-io");

// -- Service definitions ------------------------------------------------------

const Service = struct {
    name: []const u8,
    host: []const u8,
    port: u16,
};

const services = [_]Service{
    .{ .name = "api",      .host = "127.0.0.1", .port = 8001 },
    .{ .name = "database",  .host = "127.0.0.1", .port = 5432 },
    .{ .name = "cache",     .host = "127.0.0.1", .port = 6379 },
    .{ .name = "search",    .host = "127.0.0.1", .port = 9200 },
};

const HealthResult = struct {
    name: []const u8,
    healthy: bool,
    latency_ms: u64,
};

// -- Entry point --------------------------------------------------------------

pub fn main() !void {
    try io.run(dashboard);
}

fn dashboard() void {
    std.debug.print("=== Service Health Dashboard ===\n\n", .{});

    // ── Pattern 1: joinAll ─────────────────────────────────────────────
    // Check ALL services in parallel. joinAll spawns one task per call
    // and waits for every task to complete before returning.
    std.debug.print("--- Check All (joinAll) ---\n", .{});
    checkAllServices();

    // ── Pattern 2: race ────────────────────────────────────────────────
    // Find the fastest responding service. race returns the first result
    // and cancels the remaining tasks.
    std.debug.print("\n--- Fastest Service (race) ---\n", .{});
    findFastestService();

    // ── Pattern 3: tryJoinAll ──────────────────────────────────────────
    // Check all services but tolerate partial failures. tryJoinAll
    // collects both successes and errors instead of short-circuiting.
    std.debug.print("\n--- Partial Failures (tryJoinAll) ---\n", .{});
    checkWithPartialFailures();

    // ── Pattern 4: select ──────────────────────────────────────────────
    // Wait for the first response while keeping other checks running
    // in the background for logging.
    std.debug.print("\n--- First Response (select) ---\n", .{});
    selectFirstResponse();
}

// -- Pattern 1: joinAll -------------------------------------------------------

fn checkAllServices() void {
    // Spawn a health check task for each service.
    var handles: [services.len]io.task.JoinHandle(HealthResult) = undefined;
    for (services, 0..) |svc, i| {
        handles[i] = io.task.spawn(checkService, .{svc}) catch {
            std.debug.print("  Failed to spawn check for {s}\n", .{svc.name});
            return;
        };
    }

    // Wait for ALL checks to complete. This blocks until every task
    // has returned, so the total wall-clock time equals the slowest check.
    const results = io.task.joinAll(&handles) catch {
        std.debug.print("  joinAll failed\n", .{});
        return;
    };

    // Print the results table.
    var healthy_count: usize = 0;
    for (results) |r| {
        const status: []const u8 = if (r.healthy) "UP" else "DOWN";
        std.debug.print("  {s:<12} {s:<6} {d}ms\n", .{
            r.name, status, r.latency_ms,
        });
        if (r.healthy) healthy_count += 1;
    }
    std.debug.print("  {d}/{d} services healthy\n", .{
        healthy_count, services.len,
    });
}

fn checkService(svc: Service) HealthResult {
    const start = io.Instant.now();

    // Attempt a TCP connect as a health probe. If the connection
    // succeeds, the service is considered healthy.
    const addr = io.net.Address.fromHostPort(svc.host, svc.port);
    if (io.net.TcpStream.connect(addr)) |conn| {
        var stream = conn;
        stream.close();
        return .{
            .name = svc.name,
            .healthy = true,
            .latency_ms = start.elapsed().asMillis(),
        };
    } else |_| {
        return .{
            .name = svc.name,
            .healthy = false,
            .latency_ms = start.elapsed().asMillis(),
        };
    }
}

// -- Pattern 2: race ----------------------------------------------------------

fn findFastestService() void {
    // Spawn the same health check for each service, then race them.
    // race returns the result of whichever task finishes first and
    // cancels the remaining tasks.
    var handles: [services.len]io.task.JoinHandle(HealthResult) = undefined;
    for (services, 0..) |svc, i| {
        handles[i] = io.task.spawn(checkService, .{svc}) catch return;
    }

    const fastest = io.task.race(&handles) catch {
        std.debug.print("  race failed\n", .{});
        return;
    };

    std.debug.print("  Fastest: {s} responded in {d}ms\n", .{
        fastest.name, fastest.latency_ms,
    });
}

// -- Pattern 3: tryJoinAll ----------------------------------------------------

fn checkWithPartialFailures() void {
    var handles: [services.len]io.task.JoinHandle(HealthResult) = undefined;
    for (services, 0..) |svc, i| {
        handles[i] = io.task.spawn(checkService, .{svc}) catch return;
    }

    // tryJoinAll returns a TaskResult for each handle: either .ok with
    // the value or .err with the error. It never short-circuits, so you
    // always get a result for every task.
    const results = io.task.tryJoinAll(&handles);

    var up: usize = 0;
    var down: usize = 0;
    for (results) |result| {
        switch (result) {
            .ok => |r| {
                if (r.healthy) {
                    up += 1;
                } else {
                    down += 1;
                }
            },
            .err => {
                down += 1;
            },
        }
    }
    std.debug.print("  Up: {d}, Down: {d}\n", .{ up, down });
}

// -- Pattern 4: select --------------------------------------------------------

fn selectFirstResponse() void {
    var handles: [services.len]io.task.JoinHandle(HealthResult) = undefined;
    for (services, 0..) |svc, i| {
        handles[i] = io.task.spawn(checkService, .{svc}) catch return;
    }

    // select returns the first completed result WITHOUT cancelling the
    // remaining tasks. They continue running in the background. This is
    // useful when you want the first result for a fast response path but
    // still want the other checks to complete (e.g., for logging).
    const first = io.task.select(&handles) catch {
        std.debug.print("  select failed\n", .{});
        return;
    };

    std.debug.print("  First response: {s} ({d}ms)\n", .{
        first.name, first.latency_ms,
    });

    // The remaining tasks will complete in the background.
    // You could join them later if needed.
}
```

## Walkthrough

### joinAll: wait for everything

`joinAll` is the concurrent equivalent of a for loop. Instead of checking services one at a time (total time = sum of all latencies), it runs them all in parallel (total time = max latency). The result array has the same order as the input handles, so `results[0]` always corresponds to `handles[0]`.

Use `joinAll` when you need **all** results before you can proceed -- building a dashboard, aggregating data from multiple sources, or validating multiple preconditions.

### race: first one wins

`race` returns as soon as **any** task completes and cancels the rest. This is ideal for:

- **Fastest mirror selection** -- send the same request to N mirrors, use the first response
- **Redundant health checks** -- if any path is healthy, the system is reachable
- **Timeout via racing** -- race your operation against a sleep task (see Variations)

Cancelled tasks release their resources promptly. The runtime will not poll a cancelled task again after cancellation.

### tryJoinAll: tolerate partial failure

`joinAll` propagates the first error and cancels remaining tasks. When you need a result for **every** task regardless of errors, use `tryJoinAll`. Each element in the result is a `TaskResult` union:

- `.ok` -- the task returned successfully
- `.err` -- the task returned an error

This pattern is essential for dashboards, batch processing, and any scenario where partial results are better than no results.

### select: first result, keep the rest

`select` is like `race` but does **not** cancel the remaining tasks. The other tasks continue running in the background. Use this when:

- You want a fast initial response but still need the other results for logging or metrics
- You are implementing a "respond immediately, process in background" pattern
- You need to collect all results eventually but want to start acting on the first one

## Variations

### Scatter-gather with timeout

Race all health checks against a deadline. If no service responds within the timeout, report a failure immediately rather than waiting indefinitely.

```zig
const std = @import("std");
const io = @import("blitz-io");

fn checkAllWithTimeout(timeout: io.Duration) ![]HealthResult {
    var handles: [services.len]io.task.JoinHandle(HealthResult) = undefined;
    for (services, 0..) |svc, i| {
        handles[i] = try io.task.spawn(checkService, .{svc});
    }

    // Create a "deadline" task that sleeps for the timeout duration.
    // By racing joinAll against the deadline, we get a hard upper bound
    // on wall-clock time.
    const check_handle = try io.task.spawn(struct {
        fn run(hs: *[services.len]io.task.JoinHandle(HealthResult)) ![]HealthResult {
            return io.task.joinAll(hs);
        }
    }.run, .{&handles});

    const timer_handle = try io.task.spawn(struct {
        fn run(dur: io.Duration) error{TimedOut}![]HealthResult {
            io.time.blockingSleep(dur);
            return error.TimedOut;
        }
    }.run, .{timeout});

    // race: whichever finishes first wins.
    return io.task.race(.{ check_handle, timer_handle });
}
```

### Speculative execution

Send the same request to two different backends. Use the first response and discard the other. This is the classic "hedged request" pattern used by systems like Google's Bigtable.

```zig
const std = @import("std");
const io = @import("blitz-io");

fn speculativeFetch(
    primary: io.net.Address,
    secondary: io.net.Address,
) ![]u8 {
    // Send the same request to both backends.
    const h1 = try io.task.spawn(fetchFrom, .{primary});
    const h2 = try io.task.spawn(fetchFrom, .{secondary});

    // race cancels the slower backend automatically.
    return io.task.race(.{ h1, h2 });
}

fn fetchFrom(addr: io.net.Address) ![]u8 {
    var stream = try io.net.TcpStream.connect(addr);
    defer stream.close();

    try stream.writeAll("GET /data HTTP/1.1\r\nConnection: close\r\n\r\n");

    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = stream.tryRead(buf[total..]) catch |err| return err orelse {
            std.Thread.sleep(1 * std.time.ns_per_ms);
            continue;
        };
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}
```

The cost is doubled network traffic, but latency drops to the minimum of the two backends. Use this pattern sparingly -- only for latency-critical paths where the extra load is acceptable.

### Fan-out work distribution

Split a large batch of items across N worker tasks and collect results with `joinAll`. This is the concurrent equivalent of a parallel for loop.

```zig
const std = @import("std");
const io = @import("blitz-io");

const NUM_WORKERS = 4;

fn processBatchParallel(items: []const Item) ![NUM_WORKERS]BatchResult {
    // Divide items into roughly equal chunks.
    const chunk_size = (items.len + NUM_WORKERS - 1) / NUM_WORKERS;

    var handles: [NUM_WORKERS]io.task.JoinHandle(BatchResult) = undefined;
    for (0..NUM_WORKERS) |i| {
        const start = i * chunk_size;
        const end = @min(start + chunk_size, items.len);
        if (start >= items.len) {
            // Fewer items than workers -- spawn a no-op.
            handles[i] = try io.task.spawn(emptyBatch, .{});
        } else {
            handles[i] = try io.task.spawn(processChunk, .{
                items[start..end],
            });
        }
    }

    // Wait for all workers. Total time = slowest chunk.
    return io.task.joinAll(&handles);
}

fn processChunk(chunk: []const Item) BatchResult {
    var total: u64 = 0;
    for (chunk) |item| {
        total += processItem(item);
    }
    return .{ .count = chunk.len, .total = total };
}

fn emptyBatch() BatchResult {
    return .{ .count = 0, .total = 0 };
}

const Item = struct { value: u64 };
const BatchResult = struct { count: usize, total: u64 };

fn processItem(item: Item) u64 {
    // Simulate CPU work.
    return item.value *% 31;
}
```

The chunk-based approach ensures even distribution. If items have highly variable processing times, consider using a channel-based work queue instead (see [Producer/Consumer](/cookbook/producer-consumer)) so fast workers can steal from slow ones.

## Choosing the Right Combinator

| Combinator | Waits for | On error | Cancels remaining | Best for |
|------------|-----------|----------|-------------------|----------|
| `joinAll` | All tasks | Short-circuits | Yes | Aggregation, batch processing |
| `tryJoinAll` | All tasks | Collects all | No | Dashboards, partial-failure tolerance |
| `race` | First task | Returns first | Yes | Fastest mirror, timeout via racing |
| `select` | First task | Returns first | No | Fast initial response, background work |
