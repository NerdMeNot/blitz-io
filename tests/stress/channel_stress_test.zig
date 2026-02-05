//! Stress tests for blitz_io.Channel
//!
//! Tests the bounded MPSC channel under high contention scenarios.
//! Uses sendBlocking() and recvBlocking() for proper blocking without spin-waiting.
//!
//! ## Test Categories
//!
//! - **SPSC**: Single producer, single consumer baseline
//! - **MPSC**: Multiple producers, single consumer (primary use case)
//! - **High contention**: Small buffer forces frequent blocking
//! - **Close semantics**: Proper behavior when channel closes
//! - **Throughput**: High message count with data integrity verification

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const blitz_io = @import("blitz-io");
const Scope = config.ThreadScope;
const Channel = blitz_io.Channel;

const config = @import("test_config");

test "Channel stress - single producer single consumer" {
    const allocator = testing.allocator;

    // Medium buffer size - not too small (avoids excessive blocking), not too large
    var channel = try Channel(u64).init(allocator, config.stress.buffer_medium);
    defer channel.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // Large item count to test sustained throughput
    const num_items = config.stress.high_throughput;
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
        // Use proper blocking instead of spin-waiting
        channel.sendBlocking(value) catch break;
        sum += value;
    }
    return sum;
}

fn singleConsumer(channel: *Channel(u64), count: usize) u64 {
    var sum: u64 = 0;
    var received: usize = 0;
    while (received < count) {
        if (channel.recvBlocking()) |value| {
            sum += value;
            received += 1;
        } else {
            // Channel closed
            break;
        }
    }
    return sum;
}

test "Channel stress - multiple producers single consumer" {
    const allocator = testing.allocator;

    // Larger buffer for MPSC to reduce producer blocking
    var channel = try Channel(u64).init(allocator, config.stress.buffer_medium * 2);
    defer channel.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_producers = config.stress.producers;
    const items_per_producer = config.stress.items_per_producer;

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
        channel.sendBlocking(value) catch break;
        sum += value;
    }
    return sum;
}

test "Channel stress - small buffer high contention" {
    const allocator = testing.allocator;

    // Small buffer (4 slots) forces frequent blocking and tests backpressure
    var channel = try Channel(u32).init(allocator, config.stress.buffer_small);
    defer channel.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_producers = config.stress.producers;
    const items_per_producer = config.stress.items_per_producer;

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
        channel.sendBlocking(@intCast(i)) catch break;
        _ = sent.fetchAdd(1, .acq_rel);
    }
}

fn countingConsumer(channel: *Channel(u32), expected: usize, received: *std.atomic.Value(usize)) void {
    var count: usize = 0;
    while (count < expected) {
        if (channel.recvBlocking()) |_| {
            count += 1;
            _ = received.fetchAdd(1, .acq_rel);
        } else {
            // Channel closed
            break;
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

    // Wait for producer to send at least 10 items before closing
    // (10 chosen as minimum to ensure producer is actively sending)
    const min_sends_before_close = 10;
    while (sends_before_close.load(.acquire) < min_sends_before_close) {
        std.Thread.yield() catch {};
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
        channel.sendBlocking(i) catch {
            detected_close.store(true, .release);
            break;
        };
        _ = sends.fetchAdd(1, .acq_rel);
        i += 1;
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
        if (channel.recvBlocking()) |_| {
            count += 1;
        } else {
            // Channel closed
            return .{ count, true };
        }
    }
}

test "Channel stress - throughput" {
    const allocator = testing.allocator;

    // Large buffer for throughput test to minimize blocking
    var channel = try Channel(u64).init(allocator, config.stress.buffer_large);
    defer channel.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // High item count with checksum verification for data integrity
    const num_items = config.stress.high_throughput;
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
        channel.sendBlocking(value) catch break;
        checksum ^= value;
    }
    return checksum;
}

fn checksumConsumer(channel: *Channel(u64), count: usize) u64 {
    var checksum: u64 = 0;
    var received: usize = 0;

    while (received < count) {
        if (channel.recvBlocking()) |value| {
            checksum ^= value;
            received += 1;
        } else {
            // Channel closed
            break;
        }
    }
    return checksum;
}
