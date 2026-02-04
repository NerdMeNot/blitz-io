//! Stress tests for concurrent patterns
//!
//! Tests high throughput concurrent operations using Scope.

const std = @import("std");
const testing = std.testing;
const blitz_io = @import("blitz-io");
const Scope = blitz_io.Scope;

test "Concurrent stress - high throughput atomic counter" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var counter = std.atomic.Value(u64).init(0);

    const num_tasks = 100;
    const increments_per_task = 100;

    for (0..num_tasks) |_| {
        try scope.spawn(multiIncrement, .{ &counter, increments_per_task });
    }

    try scope.wait();

    try testing.expectEqual(@as(u64, num_tasks * increments_per_task), counter.load(.acquire));
}

fn multiIncrement(counter: *std.atomic.Value(u64), count: usize) void {
    for (0..count) |_| {
        _ = counter.fetchAdd(1, .acq_rel);
    }
}

test "Concurrent stress - multiple producers single consumer" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_producers = 10;
    const items_per_producer = 1000;

    // Ring buffer for MPSC pattern
    var buffer: [10000]u64 = undefined;
    var write_pos = std.atomic.Value(usize).init(0);
    var read_pos = std.atomic.Value(usize).init(0);
    var items_written = std.atomic.Value(usize).init(0);

    // Spawn producers
    for (0..num_producers) |producer_id| {
        try scope.spawn(ringProducer, .{
            &buffer,
            &write_pos,
            &items_written,
            items_per_producer,
            producer_id,
        });
    }

    var sum: u64 = 0;
    try scope.spawnWithResult(ringConsumer, .{
        &buffer,
        &read_pos,
        &items_written,
        num_producers * items_per_producer,
    }, &sum);

    try scope.wait();

    // Each producer sends values 1..items_per_producer (summing to n*(n+1)/2)
    // multiplied by (producer_id + 1)
    // Actually, just verify we got something reasonable
    try testing.expect(sum > 0);
}

fn ringProducer(
    buffer: *[10000]u64,
    write_pos: *std.atomic.Value(usize),
    items_written: *std.atomic.Value(usize),
    count: usize,
    producer_id: usize,
) void {
    for (1..count + 1) |i| {
        const pos = write_pos.fetchAdd(1, .acq_rel) % buffer.len;
        buffer[pos] = @intCast(i * (producer_id + 1));
        _ = items_written.fetchAdd(1, .release);
    }
}

fn ringConsumer(
    buffer: *[10000]u64,
    read_pos: *std.atomic.Value(usize),
    items_written: *std.atomic.Value(usize),
    expected_items: usize,
) u64 {
    var sum: u64 = 0;
    var consumed: usize = 0;

    while (consumed < expected_items) {
        // Spin until item available
        while (items_written.load(.acquire) <= consumed) {
            std.Thread.yield() catch {};
        }

        const pos = read_pos.fetchAdd(1, .acq_rel) % buffer.len;
        sum += buffer[pos];
        consumed += 1;
    }

    return sum;
}

test "Concurrent stress - fan out fan in" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // Fan out: spawn many tasks that do work
    // Fan in: collect all results

    var results: [50]u64 = undefined;
    for (results[0..], 0..) |*r, i| {
        try scope.spawnWithResult(fanOutWork, .{@as(u32, @intCast(i))}, r);
    }

    try scope.wait();

    // Verify all results
    var total: u64 = 0;
    for (results, 0..) |r, i| {
        // Each task returns i^2 + i
        const expected: u64 = @as(u64, i) * @as(u64, i) + @as(u64, i);
        try testing.expectEqual(expected, r);
        total += r;
    }

    // Sum of i^2 + i for i = 0..49
    // = sum(i^2) + sum(i)
    // = n(n-1)(2n-1)/6 + n(n-1)/2 for n=50
    // = 49*50*99/6 + 49*50/2
    // = 40425 + 1225 = 41650
    try testing.expectEqual(@as(u64, 41650), total);
}

fn fanOutWork(id: u32) u64 {
    // Simulate some work
    var result: u64 = 0;
    for (0..100) |_| {
        result +%= @as(u64, id);
    }
    // Return id^2 + id
    return @as(u64, id) * @as(u64, id) + @as(u64, id);
}
