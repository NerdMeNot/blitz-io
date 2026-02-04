//! Stress tests for blitz_io.Channel
//!
//! Tests the bounded MPSC channel under high contention scenarios.

const std = @import("std");
const testing = std.testing;
const blitz_io = @import("blitz-io");
const Scope = blitz_io.Scope;
const Channel = blitz_io.Channel;

test "Channel stress - single producer single consumer" {
    const allocator = testing.allocator;

    var channel = try Channel(u64).init(allocator, 64);
    defer channel.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_items = 10000;
    var sum_sent: u64 = 0;
    var sum_received: u64 = 0;

    // Producer
    try scope.spawnWithResult(singleProducer, .{ &channel, num_items }, &sum_sent);

    // Consumer
    try scope.spawnWithResult(singleConsumer, .{ &channel, num_items }, &sum_received);

    try scope.wait();

    try testing.expectEqual(sum_sent, sum_received);
}

fn singleProducer(channel: *Channel(u64), count: usize) u64 {
    var sum: u64 = 0;
    for (0..count) |i| {
        const value: u64 = @intCast(i + 1);
        // Spin until send succeeds
        while (channel.trySend(value) != .ok) {
            std.atomic.spinLoopHint();
        }
        sum += value;
    }
    return sum;
}

fn singleConsumer(channel: *Channel(u64), count: usize) u64 {
    var sum: u64 = 0;
    var received: usize = 0;
    while (received < count) {
        switch (channel.tryRecv()) {
            .value => |value| {
                sum += value;
                received += 1;
            },
            .empty, .closed => {
                std.atomic.spinLoopHint();
            },
        }
    }
    return sum;
}

test "Channel stress - multiple producers single consumer" {
    const allocator = testing.allocator;

    var channel = try Channel(u64).init(allocator, 128);
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
            multiProducer,
            .{ &channel, items_per_producer, @as(u64, @intCast(i)) },
            &producer_sums[i],
        );
    }

    // Consumer
    try scope.spawnWithResult(
        singleConsumer,
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

fn multiProducer(channel: *Channel(u64), count: usize, producer_id: u64) u64 {
    var sum: u64 = 0;
    for (0..count) |i| {
        // Encode producer ID and sequence number
        const value: u64 = producer_id * 1000000 + @as(u64, @intCast(i + 1));
        while (channel.trySend(value) != .ok) {
            std.atomic.spinLoopHint();
        }
        sum += value;
    }
    return sum;
}

test "Channel stress - small buffer high contention" {
    const allocator = testing.allocator;

    // Small buffer = high contention
    var channel = try Channel(u32).init(allocator, 4);
    defer channel.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_producers = 5;
    const items_per_producer = 500;

    var sent_count = std.atomic.Value(usize).init(0);
    var received_count = std.atomic.Value(usize).init(0);

    // Spawn producers
    for (0..num_producers) |_| {
        try scope.spawn(countingProducer, .{ &channel, items_per_producer, &sent_count });
    }

    // Consumer
    try scope.spawn(countingConsumer, .{
        &channel,
        num_producers * items_per_producer,
        &received_count,
    });

    try scope.wait();

    try testing.expectEqual(@as(usize, num_producers * items_per_producer), sent_count.load(.acquire));
    try testing.expectEqual(@as(usize, num_producers * items_per_producer), received_count.load(.acquire));
}

fn countingProducer(channel: *Channel(u32), count: usize, sent: *std.atomic.Value(usize)) void {
    for (0..count) |i| {
        while (channel.trySend(@intCast(i)) != .ok) {
            std.atomic.spinLoopHint();
        }
        _ = sent.fetchAdd(1, .acq_rel);
    }
}

fn countingConsumer(channel: *Channel(u32), expected: usize, received: *std.atomic.Value(usize)) void {
    var count: usize = 0;
    while (count < expected) {
        switch (channel.tryRecv()) {
            .value => |_| {
                count += 1;
                _ = received.fetchAdd(1, .acq_rel);
            },
            .empty, .closed => {
                std.atomic.spinLoopHint();
            },
        }
    }
}

test "Channel stress - close while sending" {
    const allocator = testing.allocator;

    var channel = try Channel(u32).init(allocator, 16);
    defer channel.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var sends_before_close = std.atomic.Value(usize).init(0);
    var close_detected = std.atomic.Value(bool).init(false);

    // Producer that sends until channel is closed
    try scope.spawn(sendUntilClosed, .{ &channel, &sends_before_close, &close_detected });

    // Let producer send some items
    while (sends_before_close.load(.acquire) < 10) {
        std.atomic.spinLoopHint();
    }

    // Close the channel
    channel.close();

    try scope.wait();

    // Producer should have detected the close
    try testing.expect(close_detected.load(.acquire));
}

fn sendUntilClosed(
    channel: *Channel(u32),
    sends: *std.atomic.Value(usize),
    detected_close: *std.atomic.Value(bool),
) void {
    var i: u32 = 0;
    while (true) {
        const result = channel.trySend(i);
        switch (result) {
            .ok => {
                _ = sends.fetchAdd(1, .acq_rel);
                i += 1;
            },
            .full => {
                std.atomic.spinLoopHint();
            },
            .closed => {
                detected_close.store(true, .release);
                break;
            },
        }
    }
}

test "Channel stress - close while receiving" {
    const allocator = testing.allocator;

    var channel = try Channel(u32).init(allocator, 16);
    defer channel.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // Send some items
    for (0..10) |i| {
        try testing.expect(channel.trySend(@intCast(i)) == .ok);
    }

    // Close channel
    channel.close();

    var result: struct { usize, bool } = .{ 0, false };

    // Receive all items and detect close
    try scope.spawnWithResult(recvUntilClosed, .{&channel}, &result);

    try scope.wait();

    // Should have received all items before close
    try testing.expectEqual(@as(usize, 10), result[0]);
}

fn recvUntilClosed(channel: *Channel(u32)) struct { usize, bool } {
    var count: usize = 0;
    while (true) {
        switch (channel.tryRecv()) {
            .value => |_| {
                count += 1;
            },
            .empty => {
                if (channel.isClosed()) {
                    return .{ count, true };
                }
                std.atomic.spinLoopHint();
            },
            .closed => {
                return .{ count, true };
            },
        }
    }
}

test "Channel stress - throughput" {
    const allocator = testing.allocator;

    var channel = try Channel(u64).init(allocator, 256);
    defer channel.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_items = 100000;
    var checksum_sent: u64 = 0;
    var checksum_recv: u64 = 0;

    // Producer
    try scope.spawnWithResult(checksumProducer, .{ &channel, num_items }, &checksum_sent);

    // Consumer
    try scope.spawnWithResult(checksumConsumer, .{ &channel, num_items }, &checksum_recv);

    try scope.wait();

    // Verify data integrity
    try testing.expectEqual(checksum_sent, checksum_recv);
}

fn checksumProducer(channel: *Channel(u64), count: usize) u64 {
    var checksum: u64 = 0;
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    for (0..count) |_| {
        const value = random.int(u64);
        while (channel.trySend(value) != .ok) {
            std.atomic.spinLoopHint();
        }
        checksum ^= value;
    }
    return checksum;
}

fn checksumConsumer(channel: *Channel(u64), count: usize) u64 {
    var checksum: u64 = 0;
    var received: usize = 0;

    while (received < count) {
        switch (channel.tryRecv()) {
            .value => |value| {
                checksum ^= value;
                received += 1;
            },
            .empty, .closed => {
                std.atomic.spinLoopHint();
            },
        }
    }
    return checksum;
}
