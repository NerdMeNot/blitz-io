//! Stress tests for blitz_io.UnboundedChannel
//!
//! Tests the unbounded MPSC channel under high throughput scenarios.

const std = @import("std");
const testing = std.testing;
const blitz_io = @import("blitz-io");
const Scope = blitz_io.Scope;
const UnboundedChannel = blitz_io.sync.UnboundedChannel;

test "UnboundedChannel stress - single producer single consumer" {
    const allocator = testing.allocator;

    var channel = UnboundedChannel(u64).init(allocator);
    defer channel.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_items = 10000;
    var sum_sent: u64 = 0;
    var sum_received: u64 = 0;

    try scope.spawnWithResult(unboundedProducer, .{ &channel, num_items }, &sum_sent);
    try scope.spawnWithResult(unboundedConsumer, .{ &channel, num_items }, &sum_received);

    try scope.wait();

    try testing.expectEqual(sum_sent, sum_received);
}

fn unboundedProducer(channel: *UnboundedChannel(u64), count: usize) u64 {
    var sum: u64 = 0;
    for (0..count) |i| {
        const value: u64 = @intCast(i + 1);
        const result = channel.send(value) catch continue;
        if (result == .ok) {
            sum += value;
        }
    }
    return sum;
}

fn unboundedConsumer(channel: *UnboundedChannel(u64), count: usize) u64 {
    var sum: u64 = 0;
    var received: usize = 0;

    while (received < count) {
        switch (channel.tryRecv()) {
            .value => |value| {
                sum += value;
                received += 1;
            },
            .empty => std.atomic.spinLoopHint(),
            .closed => break,
        }
    }

    return sum;
}

test "UnboundedChannel stress - multiple producers single consumer" {
    const allocator = testing.allocator;

    var channel = UnboundedChannel(u64).init(allocator);
    defer channel.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_producers = 10;
    const items_per_producer = 1000;

    var producer_sums: [num_producers]u64 = undefined;
    var consumer_sum: u64 = 0;

    // Spawn producers
    for (0..num_producers) |i| {
        try scope.spawnWithResult(
            multiUnboundedProducer,
            .{ &channel, items_per_producer, @as(u64, @intCast(i)) },
            &producer_sums[i],
        );
    }

    // Consumer
    try scope.spawnWithResult(
        unboundedConsumer,
        .{ &channel, num_producers * items_per_producer },
        &consumer_sum,
    );

    try scope.wait();

    var expected_sum: u64 = 0;
    for (producer_sums) |s| {
        expected_sum += s;
    }

    try testing.expectEqual(expected_sum, consumer_sum);
}

fn multiUnboundedProducer(channel: *UnboundedChannel(u64), count: usize, producer_id: u64) u64 {
    var sum: u64 = 0;
    for (0..count) |i| {
        const value: u64 = producer_id * 1000000 + @as(u64, @intCast(i + 1));
        const result = channel.send(value) catch continue;
        if (result == .ok) {
            sum += value;
        }
    }
    return sum;
}

test "UnboundedChannel stress - bursty sends" {
    const allocator = testing.allocator;

    var channel = UnboundedChannel(u32).init(allocator);
    defer channel.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var sent_count = std.atomic.Value(usize).init(0);
    var received_count = std.atomic.Value(usize).init(0);

    const num_producers = 5;
    const bursts = 10;
    const items_per_burst = 100;
    const total_items = num_producers * bursts * items_per_burst;

    // Bursty producers
    for (0..num_producers) |_| {
        try scope.spawn(burstyProducer, .{ &channel, bursts, items_per_burst, &sent_count });
    }

    // Consumer
    try scope.spawn(countingUnboundedConsumer, .{ &channel, total_items, &received_count });

    try scope.wait();

    try testing.expectEqual(@as(usize, total_items), sent_count.load(.acquire));
    try testing.expectEqual(@as(usize, total_items), received_count.load(.acquire));
}

fn burstyProducer(
    channel: *UnboundedChannel(u32),
    bursts: usize,
    items_per_burst: usize,
    sent: *std.atomic.Value(usize),
) void {
    for (0..bursts) |_| {
        // Send burst
        for (0..items_per_burst) |i| {
            const result = channel.send(@intCast(i)) catch continue;
            if (result == .ok) {
                _ = sent.fetchAdd(1, .acq_rel);
            }
        }
        // Brief pause between bursts
        std.atomic.spinLoopHint();
    }
}

fn countingUnboundedConsumer(
    channel: *UnboundedChannel(u32),
    expected: usize,
    received: *std.atomic.Value(usize),
) void {
    var count: usize = 0;
    while (count < expected) {
        switch (channel.tryRecv()) {
            .value => {
                count += 1;
                _ = received.fetchAdd(1, .acq_rel);
            },
            .empty => std.atomic.spinLoopHint(),
            .closed => break,
        }
    }
}

test "UnboundedChannel stress - close while sending" {
    const allocator = testing.allocator;

    var channel = UnboundedChannel(u32).init(allocator);
    defer channel.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var sends = std.atomic.Value(usize).init(0);
    var close_detected = std.atomic.Value(bool).init(false);

    try scope.spawn(sendUntilClosedUnbounded, .{ &channel, &sends, &close_detected });

    // Let producer send some items
    while (sends.load(.acquire) < 100) {
        std.atomic.spinLoopHint();
    }

    channel.close();

    try scope.wait();

    try testing.expect(close_detected.load(.acquire));
}

fn sendUntilClosedUnbounded(
    channel: *UnboundedChannel(u32),
    sends: *std.atomic.Value(usize),
    detected: *std.atomic.Value(bool),
) void {
    var i: u32 = 0;
    while (true) {
        const result = channel.send(i) catch {
            // Allocation failure
            continue;
        };
        switch (result) {
            .ok => {
                _ = sends.fetchAdd(1, .acq_rel);
                i += 1;
            },
            .closed => {
                detected.store(true, .release);
                break;
            },
        }
    }
}

test "UnboundedChannel stress - drain on close" {
    const allocator = testing.allocator;

    var channel = UnboundedChannel(u64).init(allocator);
    defer channel.deinit();

    // Send items
    const num_items = 100;
    var expected_sum: u64 = 0;
    for (0..num_items) |i| {
        const value: u64 = @intCast(i + 1);
        const result = try channel.send(value);
        if (result == .ok) {
            expected_sum += value;
        }
    }

    // Close
    channel.close();

    // Drain remaining items
    var received_sum: u64 = 0;
    while (true) {
        switch (channel.tryRecv()) {
            .value => |value| received_sum += value,
            .empty, .closed => break,
        }
    }

    try testing.expectEqual(expected_sum, received_sum);
}

test "UnboundedChannel stress - throughput" {
    const allocator = testing.allocator;

    var channel = UnboundedChannel(u64).init(allocator);
    defer channel.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_items = 100000;
    var checksum_sent: u64 = 0;
    var checksum_recv: u64 = 0;

    try scope.spawnWithResult(checksumUnboundedProducer, .{ &channel, num_items }, &checksum_sent);
    try scope.spawnWithResult(checksumUnboundedConsumer, .{ &channel, num_items }, &checksum_recv);

    try scope.wait();

    try testing.expectEqual(checksum_sent, checksum_recv);
}

fn checksumUnboundedProducer(channel: *UnboundedChannel(u64), count: usize) u64 {
    var checksum: u64 = 0;
    var prng = std.Random.DefaultPrng.init(54321);
    const random = prng.random();

    for (0..count) |_| {
        const value = random.int(u64);
        const result = channel.send(value) catch continue;
        if (result == .ok) {
            checksum ^= value;
        }
    }

    return checksum;
}

fn checksumUnboundedConsumer(channel: *UnboundedChannel(u64), count: usize) u64 {
    var checksum: u64 = 0;
    var received: usize = 0;

    while (received < count) {
        switch (channel.tryRecv()) {
            .value => |value| {
                checksum ^= value;
                received += 1;
            },
            .empty => std.atomic.spinLoopHint(),
            .closed => break,
        }
    }

    return checksum;
}

test "UnboundedChannel stress - queue growth" {
    const allocator = testing.allocator;

    var channel = UnboundedChannel(u64).init(allocator);
    defer channel.deinit();

    // Send many items without consuming (test queue growth)
    const num_items = 10000;
    for (0..num_items) |i| {
        _ = try channel.send(@intCast(i));
    }

    try testing.expectEqual(@as(usize, num_items), channel.len());

    // Now drain
    var count: usize = 0;
    while (true) {
        switch (channel.tryRecv()) {
            .value => count += 1,
            .empty, .closed => break,
        }
    }

    try testing.expectEqual(num_items, count);
    try testing.expectEqual(@as(usize, 0), channel.len());
}
