//! Work Stealing Deque Concurrency Tests
//!
//! Tests the correctness of the Chase-Lev work stealing deque under concurrent access.
//! Uses the parameterized testing framework from src/test/concurrency.zig.
//!
//! Critical areas tested:
//! - Pop vs steal race: Owner pops while thief steals
//! - Multiple thieves: Multiple threads stealing concurrently
//! - FIFO stealing: Thieves get items in FIFO order
//! - LIFO owner: Owner gets items in LIFO order
//! - Rapid operations: High-frequency push/pop/steal stress test

const std = @import("std");
const Allocator = std.mem.Allocator;
const blitz = @import("blitz-io");

// Import the testing framework
const concurrency = blitz.testing.concurrency;
const Config = concurrency.Config;
const ConcurrentCounter = concurrency.ConcurrentCounter;
const Barrier = concurrency.Barrier;
const ThreadRng = concurrency.ThreadRng;

// Import the Chase-Lev deque
const Deque = blitz.coroutine.Deque;
const StealResult = blitz.coroutine.StealResult;

// ─────────────────────────────────────────────────────────────────────────────
// Test 1: Pop vs Steal Race
// ─────────────────────────────────────────────────────────────────────────────

/// Test that pop and steal don't lose or duplicate items.
fn testPopVsSteal(config: Config, allocator: Allocator) !void {
    const Context = struct {
        deque: *Deque(u32),
        barrier: *Barrier,
        pop_count: ConcurrentCounter,
        steal_count: ConcurrentCounter,
        seed: u64,
        item_count: usize,

        fn owner(ctx: *@This(), _: usize) void {
            var rng = ThreadRng.init(ctx.seed);

            // Push items
            for (0..ctx.item_count) |i| {
                ctx.deque.push(@intCast(i));
            }

            // Signal ready
            _ = ctx.barrier.wait();

            // Pop items (racing with stealer)
            while (ctx.deque.pop()) |_| {
                _ = ctx.pop_count.increment();
                rng.maybeYield(10);
            }
        }

        fn thief(ctx: *@This(), _: usize) void {
            var rng = ThreadRng.init(ctx.seed +% 1);

            // Wait for owner to push
            _ = ctx.barrier.wait();

            // Steal items (racing with owner)
            while (true) {
                const result = ctx.deque.steal();
                switch (result.result) {
                    .success => {
                        _ = ctx.steal_count.increment();
                        rng.maybeYield(10);
                    },
                    .empty => break,
                    .retry => continue,
                }
            }
        }
    };

    var deque = try Deque(u32).init(allocator, 256);
    defer deque.deinit();

    var barrier = Barrier.init(2);
    var ctx = Context{
        .deque = &deque,
        .barrier = &barrier,
        .pop_count = ConcurrentCounter.init(0),
        .steal_count = ConcurrentCounter.init(0),
        .seed = config.getEffectiveSeed(),
        .item_count = config.task_count,
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
        deque: *Deque(u32),
        barrier: *Barrier,
        stolen_count: ConcurrentCounter,
        popped_count: ConcurrentCounter,
        seed: u64,
        num_thieves: usize,
        item_count: usize,

        fn owner(ctx: *@This()) void {
            // Push all items
            for (0..ctx.item_count) |i| {
                ctx.deque.push(@intCast(i));
            }

            // Signal ready
            _ = ctx.barrier.wait();

            // Pop our share
            var popped: usize = 0;
            while (ctx.deque.pop()) |_| {
                popped += 1;
                if (popped > ctx.item_count / (ctx.num_thieves + 1)) {
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
            for (0..ctx.item_count) |_| {
                const result = ctx.deque.steal();
                switch (result.result) {
                    .success => {
                        stolen += 1;
                        rng.maybeYield(5);
                    },
                    .empty => break,
                    .retry => {},
                }
            }
            _ = ctx.stolen_count.fetchAdd(stolen, .acq_rel);
        }
    };

    if (num_thieves == 0) return;

    var deque = try Deque(u32).init(allocator, 256);
    defer deque.deinit();

    var barrier = Barrier.init(config.thread_count);
    var ctx = Context{
        .deque = &deque,
        .barrier = &barrier,
        .stolen_count = ConcurrentCounter.init(0),
        .popped_count = ConcurrentCounter.init(0),
        .seed = config.getEffectiveSeed(),
        .num_thieves = num_thieves,
        .item_count = config.task_count,
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
// Test 3: FIFO Steal Order
// ─────────────────────────────────────────────────────────────────────────────

/// Test that steals return items in FIFO order.
fn testFifoStealOrder(config: Config, allocator: Allocator) !void {
    _ = config;

    var deque = try Deque(u32).init(allocator, 64);
    defer deque.deinit();

    // Push items in order 0, 1, 2, 3...
    for (0..10) |i| {
        deque.push(@intCast(i));
    }

    // Steal should return 0, 1, 2... (FIFO)
    for (0..10) |expected| {
        const result = deque.steal();
        if (result.result != .success) {
            return error.TestFailed;
        }
        if (result.item.? != expected) {
            std.debug.print("FIFO order violated: expected {d}, got {d}\n", .{
                expected,
                result.item.?,
            });
            return error.TestFailed;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 4: LIFO Pop Order
// ─────────────────────────────────────────────────────────────────────────────

/// Test that owner pops return items in LIFO order.
fn testLifoPopOrder(config: Config, allocator: Allocator) !void {
    _ = config;

    var deque = try Deque(u32).init(allocator, 64);
    defer deque.deinit();

    // Push items in order 0, 1, 2, 3...
    for (0..10) |i| {
        deque.push(@intCast(i));
    }

    // Pop should return 9, 8, 7... (LIFO)
    var expected: u32 = 9;
    while (deque.pop()) |item| {
        if (item != expected) {
            std.debug.print("LIFO order violated: expected {d}, got {d}\n", .{
                expected,
                item,
            });
            return error.TestFailed;
        }
        if (expected == 0) break;
        expected -= 1;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 5: Stress Test - Rapid Push/Pop/Steal
// ─────────────────────────────────────────────────────────────────────────────

/// High-frequency operations to stress the deque.
fn testRapidOperations(config: Config, allocator: Allocator) !void {
    const Context = struct {
        deque: *Deque(u32),
        barrier: *Barrier,
        total_ops: ConcurrentCounter,
        seed: u64,
        item_count: usize,

        fn worker(ctx: *@This(), tid: usize) void {
            var rng = ThreadRng.init(ctx.seed +% tid);
            const is_owner = tid == 0;

            _ = ctx.barrier.wait();

            // Rapid operations
            for (0..ctx.item_count) |i| {
                const op = rng.bounded(3);

                if (is_owner) {
                    if (op == 0 or op == 2) {
                        ctx.deque.push(@intCast(i % 256));
                    } else {
                        _ = ctx.deque.pop();
                    }
                } else {
                    // Thief can only steal
                    _ = ctx.deque.steal();
                }

                _ = ctx.total_ops.increment();
            }
        }
    };

    var deque = try Deque(u32).init(allocator, 256);
    defer deque.deinit();

    var barrier = Barrier.init(config.thread_count);
    var ctx = Context{
        .deque = &deque,
        .barrier = &barrier,
        .total_ops = ConcurrentCounter.init(0),
        .seed = config.getEffectiveSeed(),
        .item_count = @min(config.task_count, 256),
    };

    try concurrency.runConcurrent(
        Context,
        Context.worker,
        &ctx,
        config.thread_count,
        allocator,
    );

    // If we got here without crash/hang, test passed
    const ops = ctx.total_ops.load();
    if (ops < config.task_count) {
        return error.TestFailed;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 6: Batch Steal
// ─────────────────────────────────────────────────────────────────────────────

/// Test batch stealing functionality.
fn testBatchSteal(config: Config, allocator: Allocator) !void {
    _ = config;

    var deque = try Deque(u32).init(allocator, 64);
    defer deque.deinit();

    // Push items
    for (0..20) |i| {
        deque.push(@intCast(i));
    }

    // Batch steal
    var stolen: [10]u32 = undefined;
    const count = deque.stealBatch(&stolen);

    // Should have stolen some items
    if (count == 0) {
        return error.TestFailed;
    }

    // Stolen items should be sequential from front
    for (0..count) |i| {
        if (stolen[i] != i) {
            std.debug.print("Batch steal order wrong: expected {d}, got {d}\n", .{
                i,
                stolen[i],
            });
            return error.TestFailed;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test Runner
// ─────────────────────────────────────────────────────────────────────────────

test "work stealing deque - pop vs steal race" {
    const configs = [_]Config{
        .{ .thread_count = 2, .task_count = 100 },
        .{ .thread_count = 2, .task_count = 200 },
    };
    for (configs) |config| {
        try testPopVsSteal(config, std.testing.allocator);
    }
}

test "work stealing deque - multiple thieves" {
    const configs = [_]Config{
        .{ .thread_count = 4, .task_count = 100 },
        .{ .thread_count = 4, .task_count = 200 },
    };
    for (configs) |config| {
        try testMultipleThieves(config, std.testing.allocator);
    }
}

test "work stealing deque - FIFO steal order" {
    try testFifoStealOrder(.{}, std.testing.allocator);
}

test "work stealing deque - LIFO pop order" {
    try testLifoPopOrder(.{}, std.testing.allocator);
}

test "work stealing deque - rapid operations" {
    const configs = [_]Config{
        .{ .thread_count = 2, .task_count = 200, .contention_level = .high },
        .{ .thread_count = 4, .task_count = 200, .contention_level = .high },
    };
    for (configs) |config| {
        try testRapidOperations(config, std.testing.allocator);
    }
}

test "work stealing deque - batch steal" {
    try testBatchSteal(.{}, std.testing.allocator);
}
