//! Integration tests for Scope structured concurrency
//!
//! Tests Scope working with other primitives and real workloads.
//! Uses ThreadScope for thread-based testing outside async runtime.

const std = @import("std");
const testing = std.testing;

const config = @import("test_config");
const Scope = config.ThreadScope;

test "Scope - parallel counter with atomic" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var counter = std.atomic.Value(usize).init(0);

    const num_tasks = 100;
    for (0..num_tasks) |_| {
        try scope.spawn(atomicIncrement, .{&counter});
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_tasks), counter.load(.acquire));
}

fn atomicIncrement(counter: *std.atomic.Value(usize)) void {
    _ = counter.fetchAdd(1, .acq_rel);
}

test "Scope - parallel computation with results" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var results: [4]u32 = .{ 0, 0, 0, 0 };

    try scope.spawnWithResult(square, .{@as(u32, 2)}, &results[0]);
    try scope.spawnWithResult(square, .{@as(u32, 3)}, &results[1]);
    try scope.spawnWithResult(square, .{@as(u32, 4)}, &results[2]);
    try scope.spawnWithResult(square, .{@as(u32, 5)}, &results[3]);

    try scope.wait();

    try testing.expectEqual(@as(u32, 4), results[0]); // 2^2
    try testing.expectEqual(@as(u32, 9), results[1]); // 3^2
    try testing.expectEqual(@as(u32, 16), results[2]); // 4^2
    try testing.expectEqual(@as(u32, 25), results[3]); // 5^2
}

fn square(x: u32) u32 {
    return x * x;
}

test "Scope - nested scopes" {
    const allocator = testing.allocator;

    var outer = Scope.init(allocator);
    defer outer.deinit();

    var results: [3]u32 = .{ 0, 0, 0 };

    try outer.spawn(outerTask, .{ allocator, &results });

    try outer.wait();

    try testing.expectEqual(@as(u32, 1), results[0]);
    try testing.expectEqual(@as(u32, 2), results[1]);
    try testing.expectEqual(@as(u32, 3), results[2]);
}

fn outerTask(allocator: std.mem.Allocator, results: *[3]u32) !void {
    var inner = Scope.init(allocator);
    defer inner.deinit();

    try inner.spawnWithResult(computeOne, .{}, &results[0]);
    try inner.spawnWithResult(computeTwo, .{}, &results[1]);
    try inner.spawnWithResult(computeThree, .{}, &results[2]);

    try inner.wait();
}

fn computeOne() u32 {
    return 1;
}
fn computeTwo() u32 {
    return 2;
}
fn computeThree() u32 {
    return 3;
}

test "Scope - producer/consumer pattern with atomics" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // Shared state
    var buffer: [10]u32 = undefined;
    var write_idx = std.atomic.Value(usize).init(0);
    var items_produced = std.atomic.Value(usize).init(0);
    var sum: u64 = 0;

    // Producer writes values
    try scope.spawn(atomicProducer, .{ &buffer, &write_idx, &items_produced });

    // Consumer reads and sums (waits for producer)
    try scope.spawnWithResult(atomicConsumer, .{ &buffer, &items_produced }, &sum);

    try scope.wait();

    // 0 + 1 + 2 + ... + 9 = 45
    try testing.expectEqual(@as(u64, 45), sum);
}

fn atomicProducer(buffer: *[10]u32, write_idx: *std.atomic.Value(usize), produced: *std.atomic.Value(usize)) void {
    for (0..10) |i| {
        const idx = write_idx.fetchAdd(1, .acq_rel);
        buffer[idx] = @intCast(i);
        _ = produced.fetchAdd(1, .release);
    }
}

fn atomicConsumer(buffer: *[10]u32, produced: *std.atomic.Value(usize)) u64 {
    // Spin until all items produced
    while (produced.load(.acquire) < 10) {
        std.Thread.yield() catch {};
    }

    var sum: u64 = 0;
    for (buffer) |v| {
        sum += v;
    }
    return sum;
}

test "Scope - error handling across tasks" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var success_count = std.atomic.Value(usize).init(0);

    // Mix of succeeding and failing tasks
    try scope.spawn(succeedingTask, .{&success_count});
    try scope.spawn(succeedingTask, .{&success_count});
    try scope.spawn(failingTask, .{});
    try scope.spawn(succeedingTask, .{&success_count});

    const result = scope.wait();
    try testing.expectError(error.TaskFailed, result);

    // Some successes should have completed
    try testing.expect(success_count.load(.acquire) > 0);
}

fn succeedingTask(counter: *std.atomic.Value(usize)) void {
    _ = counter.fetchAdd(1, .acq_rel);
}

fn failingTask() !void {
    return error.TaskFailed;
}
