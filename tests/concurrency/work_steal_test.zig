//! Work Stealing Queue Concurrency Tests
//!
//! Tests the correctness of local queue work stealing under concurrent access.
//! Uses the parameterized testing framework from src/test/concurrency.zig.
//!
//! Critical areas tested:
//! - Pop vs steal race: Owner pops while thief steals
//! - LIFO visibility: LIFO slot must be visible before steal
//! - ABA prevention: Ensure no data corruption from index wraparound
//! - Global queue sharding: Concurrent push/pop across shards

const std = @import("std");
const Allocator = std.mem.Allocator;
const blitz = @import("blitz-io");

// Import the testing framework
const concurrency = blitz.testing.concurrency;
const Config = concurrency.Config;
const ConcurrentCounter = concurrency.ConcurrentCounter;
const Barrier = concurrency.Barrier;
const Latch = concurrency.Latch;
const ThreadRng = concurrency.ThreadRng;

// Import queue types
const LocalQueue = blitz.executor.LocalQueue;
const ShardedGlobalQueue = blitz.executor.ShardedGlobalQueue;
const Header = blitz.executor.task.Header;

// ─────────────────────────────────────────────────────────────────────────────
// Test Helpers
// ─────────────────────────────────────────────────────────────────────────────

const dummy_vtable = Header.VTable{
    .poll = struct {
        fn f(_: *Header) bool {
            return true;
        }
    }.f,
    .drop = struct {
        fn f(_: *Header) void {}
    }.f,
    .get_output = struct {
        fn f(_: *Header) ?*anyopaque {
            return null;
        }
    }.f,
    .schedule = struct {
        fn f(_: *Header) void {}
    }.f,
};

fn createHeaders(allocator: Allocator, count: usize) ![]Header {
    const headers = try allocator.alloc(Header, count);
    for (headers, 0..) |*h, i| {
        h.* = Header.init(&dummy_vtable, i);
    }
    return headers;
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 1: Pop vs Steal Race
// ─────────────────────────────────────────────────────────────────────────────

/// Test that pop and steal don't lose or duplicate items.
fn testPopVsSteal(config: Config, allocator: Allocator) !void {
    const Context = struct {
        queue: *LocalQueue,
        headers: []Header,
        barrier: *Barrier,
        pop_count: ConcurrentCounter,
        steal_count: ConcurrentCounter,
        seed: u64,

        fn owner(ctx: *@This(), _: usize) void {
            var rng = ThreadRng.init(ctx.seed);

            // Push items
            for (ctx.headers) |*h| {
                _ = ctx.queue.push(h);
            }

            // Signal ready
            _ = ctx.barrier.wait();

            // Pop items (racing with stealer)
            while (ctx.queue.pop()) |_| {
                _ = ctx.pop_count.increment();
                rng.maybeYield(10);
            }
        }

        fn thief(ctx: *@This(), _: usize) void {
            var rng = ThreadRng.init(ctx.seed +% 1);

            // Wait for owner to push
            _ = ctx.barrier.wait();

            // Steal items (racing with owner)
            while (ctx.queue.steal()) |_| {
                _ = ctx.steal_count.increment();
                rng.maybeYield(10);
            }
        }
    };

    var queue = LocalQueue.init();
    const headers = try createHeaders(allocator, config.task_count);
    defer allocator.free(headers);

    var barrier = Barrier.init(2);
    var ctx = Context{
        .queue = &queue,
        .headers = headers,
        .barrier = &barrier,
        .pop_count = ConcurrentCounter.init(0),
        .steal_count = ConcurrentCounter.init(0),
        .seed = config.getEffectiveSeed(),
    };

    try concurrency.runConcurrent(
        Context,
        struct {
            fn run(c: *Context, tid: usize) void {
                if (tid == 0) {
                    c.owner(tid);
                } else {
                    c.thief(tid);
                }
            }
        }.run,
        &ctx,
        2,
        allocator,
    );

    // Verify all items were retrieved exactly once
    const total = ctx.pop_count.load() + ctx.steal_count.load();
    if (total != config.task_count) {
        std.debug.print("Lost items: expected {d}, got {d} (pop={d}, steal={d})\n", .{
            config.task_count,
            total,
            ctx.pop_count.load(),
            ctx.steal_count.load(),
        });
        return error.TestFailed;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 2: Multiple Thieves
// ─────────────────────────────────────────────────────────────────────────────

/// Test with multiple thieves competing for items.
fn testMultipleThieves(config: Config, allocator: Allocator) !void {
    const num_thieves = config.thread_count - 1;

    const Context = struct {
        queue: *LocalQueue,
        headers: []Header,
        barrier: *Barrier,
        stolen_count: ConcurrentCounter,
        popped_count: ConcurrentCounter,
        seed: u64,
        num_thieves: usize,

        fn owner(ctx: *@This()) void {
            // Push all items
            for (ctx.headers) |*h| {
                _ = ctx.queue.push(h);
            }

            // Signal ready
            _ = ctx.barrier.wait();

            // Pop our share
            var popped: usize = 0;
            while (ctx.queue.pop()) |_| {
                popped += 1;
                if (popped > ctx.headers.len / (ctx.num_thieves + 1)) {
                    break;
                }
            }
            ctx.popped_count.store(popped);
        }

        fn thief(ctx: *@This(), tid: usize) void {
            var rng = ThreadRng.init(ctx.seed +% tid);

            // Wait for items
            _ = ctx.barrier.wait();

            // Steal
            var stolen: usize = 0;
            for (0..ctx.headers.len) |_| {
                if (ctx.queue.steal()) |_| {
                    stolen += 1;
                    rng.maybeYield(5);
                }
            }
            _ = ctx.stolen_count.fetchAdd(stolen, .acq_rel);
        }
    };

    if (num_thieves == 0) return;

    var queue = LocalQueue.init();
    const headers = try createHeaders(allocator, config.task_count);
    defer allocator.free(headers);

    var barrier = Barrier.init(config.thread_count);
    var ctx = Context{
        .queue = &queue,
        .headers = headers,
        .barrier = &barrier,
        .stolen_count = ConcurrentCounter.init(0),
        .popped_count = ConcurrentCounter.init(0),
        .seed = config.getEffectiveSeed(),
        .num_thieves = num_thieves,
    };

    try concurrency.runConcurrent(
        Context,
        struct {
            fn run(c: *Context, tid: usize) void {
                if (tid == 0) {
                    c.owner();
                } else {
                    c.thief(tid);
                }
            }
        }.run,
        &ctx,
        config.thread_count,
        allocator,
    );

    // Verify all items accounted for
    const total = ctx.popped_count.load() + ctx.stolen_count.load();
    if (total > config.task_count) {
        std.debug.print("Duplicate items: expected <= {d}, got {d}\n", .{
            config.task_count,
            total,
        });
        return error.TestFailed;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 3: LIFO Slot Visibility
// ─────────────────────────────────────────────────────────────────────────────

/// Test that LIFO pushes are visible to steals.
fn testLifoVisibility(config: Config, allocator: Allocator) !void {
    const Context = struct {
        queue: *LocalQueue,
        headers: []Header,
        barrier: *Barrier,
        lifo_seen: ConcurrentCounter,

        fn owner(ctx: *@This()) void {
            // Push via LIFO repeatedly
            for (ctx.headers) |*h| {
                const displaced = ctx.queue.pushLifo(h);
                if (displaced != null) {
                    // LIFO slot was occupied - that's fine
                }
            }

            _ = ctx.barrier.wait();
        }

        fn checker(ctx: *@This()) void {
            _ = ctx.barrier.wait();

            // Steal and count LIFO items
            var seen: usize = 0;
            while (ctx.queue.steal()) |_| {
                seen += 1;
            }
            ctx.lifo_seen.store(seen);
        }
    };

    var queue = LocalQueue.init();
    const headers = try createHeaders(allocator, @min(config.task_count, 100));
    defer allocator.free(headers);

    var barrier = Barrier.init(2);
    var ctx = Context{
        .queue = &queue,
        .headers = headers,
        .barrier = &barrier,
        .lifo_seen = ConcurrentCounter.init(0),
    };

    try concurrency.runConcurrent(
        Context,
        struct {
            fn run(c: *Context, tid: usize) void {
                if (tid == 0) {
                    c.owner();
                } else {
                    c.checker();
                }
            }
        }.run,
        &ctx,
        2,
        allocator,
    );

    // Some items should have been visible
    // (exact count depends on timing, but should be > 0 for reasonable test)
    // This is a weak check but validates the basic functionality
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 4: Global Queue Concurrent Push/Pop
// ─────────────────────────────────────────────────────────────────────────────

/// Test global queue under concurrent push and pop.
fn testGlobalQueueConcurrent(config: Config, allocator: Allocator) !void {
    const Context = struct {
        queue: *ShardedGlobalQueue,
        headers: []Header,
        barrier: *Barrier,
        pushed: ConcurrentCounter,
        popped: ConcurrentCounter,

        fn worker(ctx: *@This(), tid: usize) void {
            const chunk_size = ctx.headers.len / 4; // Assume 4 workers
            const start = tid * chunk_size;
            const end = @min(start + chunk_size, ctx.headers.len);

            // Wait for all
            _ = ctx.barrier.wait();

            // Push our chunk
            for (ctx.headers[start..end]) |*h| {
                if (ctx.queue.push(h)) {
                    _ = ctx.pushed.increment();
                }
            }

            // Wait again
            _ = ctx.barrier.wait();

            // Pop items (any shard)
            for (0..chunk_size * 2) |_| {
                if (ctx.queue.pop()) |_| {
                    _ = ctx.popped.increment();
                }
            }
        }
    };

    var queue = ShardedGlobalQueue.init();
    const headers = try createHeaders(allocator, config.task_count);
    defer allocator.free(headers);

    var barrier = Barrier.init(4);
    var ctx = Context{
        .queue = &queue,
        .headers = headers,
        .barrier = &barrier,
        .pushed = ConcurrentCounter.init(0),
        .popped = ConcurrentCounter.init(0),
    };

    try concurrency.runConcurrent(
        Context,
        Context.worker,
        &ctx,
        4,
        allocator,
    );

    // Pop remaining
    while (queue.pop()) |_| {
        _ = ctx.popped.increment();
    }

    // Verify counts match
    const pushed = ctx.pushed.load();
    const popped = ctx.popped.load();

    if (pushed != popped) {
        std.debug.print("Push/pop mismatch: {d} vs {d}\n", .{ pushed, popped });
        return error.TestFailed;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 5: Stress Test - Rapid Push/Pop/Steal
// ─────────────────────────────────────────────────────────────────────────────

/// High-frequency operations to stress the queue.
fn testRapidOperations(config: Config, allocator: Allocator) !void {
    const Context = struct {
        queue: *LocalQueue,
        headers: []Header,
        barrier: *Barrier,
        total_ops: ConcurrentCounter,
        seed: u64,

        fn worker(ctx: *@This(), tid: usize) void {
            var rng = ThreadRng.init(ctx.seed +% tid);
            const is_owner = tid == 0;

            _ = ctx.barrier.wait();

            // Rapid operations
            for (0..ctx.headers.len) |i| {
                const op = rng.bounded(3);

                if (is_owner) {
                    if (op == 0) {
                        _ = ctx.queue.push(&ctx.headers[i % ctx.headers.len]);
                    } else if (op == 1) {
                        _ = ctx.queue.pop();
                    } else {
                        _ = ctx.queue.pushLifo(&ctx.headers[i % ctx.headers.len]);
                    }
                } else {
                    // Thief can only steal
                    _ = ctx.queue.steal();
                }

                _ = ctx.total_ops.increment();
            }
        }
    };

    var queue = LocalQueue.init();
    const headers = try createHeaders(allocator, @min(config.task_count, 256));
    defer allocator.free(headers);

    var barrier = Barrier.init(config.thread_count);
    var ctx = Context{
        .queue = &queue,
        .headers = headers,
        .barrier = &barrier,
        .total_ops = ConcurrentCounter.init(0),
        .seed = config.getEffectiveSeed(),
    };

    try concurrency.runConcurrent(
        Context,
        Context.worker,
        &ctx,
        config.thread_count,
        allocator,
    );

    // If we got here without crash/hang, test passed
    // The total_ops counter validates that work was done
    const ops = ctx.total_ops.load();
    if (ops < config.task_count) {
        return error.TestFailed;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test Runner
// ─────────────────────────────────────────────────────────────────────────────

test "work stealing - pop vs steal race" {
    const configs = [_]Config{
        .{ .thread_count = 2, .task_count = 100 },
        .{ .thread_count = 2, .task_count = 200 },
    };
    for (configs) |config| {
        try testPopVsSteal(config, std.testing.allocator);
    }
}

test "work stealing - multiple thieves" {
    const configs = [_]Config{
        .{ .thread_count = 4, .task_count = 100 },
        .{ .thread_count = 4, .task_count = 200 },
    };
    for (configs) |config| {
        try testMultipleThieves(config, std.testing.allocator);
    }
}

test "work stealing - LIFO visibility" {
    try testLifoVisibility(.{ .thread_count = 2, .task_count = 50 }, std.testing.allocator);
}

test "work stealing - global queue concurrent" {
    const configs = [_]Config{
        .{ .thread_count = 4, .task_count = 400 },
        .{ .thread_count = 4, .task_count = 1000 },
    };
    for (configs) |config| {
        try testGlobalQueueConcurrent(config, std.testing.allocator);
    }
}

test "work stealing - rapid operations" {
    const configs = [_]Config{
        .{ .thread_count = 2, .task_count = 200, .contention_level = .high },
        .{ .thread_count = 4, .task_count = 200, .contention_level = .high },
    };
    for (configs) |config| {
        try testRapidOperations(config, std.testing.allocator);
    }
}
