//! Stress tests for blitz_io.BroadcastChannel
//!
//! Tests the broadcast channel with multiple receivers under high throughput.

const std = @import("std");
const testing = std.testing;
const blitz_io = @import("blitz-io");
const Scope = blitz_io.Scope;
const BroadcastChannel = blitz_io.sync.BroadcastChannel;

test "BroadcastChannel stress - all receivers get all messages" {
    const allocator = testing.allocator;

    var channel = try BroadcastChannel(u64).init(allocator, 256);
    defer channel.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_receivers = 5;
    const num_messages = 1000;

    // Create receivers
    var receivers: [num_receivers]BroadcastChannel(u64).Receiver = undefined;
    for (&receivers) |*rx| {
        rx.* = channel.subscribe();
    }

    var receiver_sums: [num_receivers]u64 = undefined;
    var sender_sum: u64 = 0;

    // Spawn sender
    try scope.spawnWithResult(broadcastSender, .{ &channel, num_messages }, &sender_sum);

    // Spawn receivers
    for (0..num_receivers) |i| {
        try scope.spawnWithResult(broadcastReceiver, .{ &receivers[i], num_messages }, &receiver_sums[i]);
    }

    try scope.wait();

    // All receivers should have the same sum as sender
    for (receiver_sums) |sum| {
        try testing.expectEqual(sender_sum, sum);
    }
}

fn broadcastSender(channel: *BroadcastChannel(u64), count: usize) u64 {
    var sum: u64 = 0;
    for (0..count) |i| {
        const value: u64 = @intCast(i + 1);
        _ = channel.send(value);
        sum += value;
    }
    return sum;
}

fn broadcastReceiver(receiver: *BroadcastChannel(u64).Receiver, count: usize) u64 {
    var sum: u64 = 0;
    var received: usize = 0;

    while (received < count) {
        switch (receiver.tryRecv()) {
            .value => |v| {
                sum += v;
                received += 1;
            },
            .empty => {
                std.atomic.spinLoopHint();
            },
            .lagged => |_| {
                // Skip lagged messages
            },
            .closed => break,
        }
    }

    return sum;
}

test "BroadcastChannel stress - concurrent subscribe/receive" {
    const allocator = testing.allocator;

    var channel = try BroadcastChannel(u64).init(allocator, 64);
    defer channel.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var messages_received = std.atomic.Value(usize).init(0);

    const num_receivers = 10;
    const num_messages = 500;

    // Start sender first
    try scope.spawn(concurrentBroadcastSender, .{ &channel, num_messages });

    // Spawn receivers that subscribe dynamically
    for (0..num_receivers) |_| {
        try scope.spawn(dynamicSubscriber, .{ &channel, &messages_received });
    }

    try scope.wait();

    // Should have received some messages (exact count depends on timing)
    try testing.expect(messages_received.load(.acquire) > 0);
}

fn concurrentBroadcastSender(channel: *BroadcastChannel(u64), count: usize) void {
    for (0..count) |i| {
        _ = channel.send(@intCast(i));
        // Small delay to let receivers catch up
        if (i % 50 == 0) {
            std.atomic.spinLoopHint();
        }
    }
    channel.close();
}

fn dynamicSubscriber(channel: *BroadcastChannel(u64), received: *std.atomic.Value(usize)) void {
    var rx = channel.subscribe();

    while (true) {
        switch (rx.tryRecv()) {
            .value => |_| {
                _ = received.fetchAdd(1, .acq_rel);
            },
            .empty => {
                std.atomic.spinLoopHint();
            },
            .lagged => |_| {
                // Expected under contention
            },
            .closed => break,
        }
    }
}

test "BroadcastChannel stress - slow receiver lagging" {
    const allocator = testing.allocator;

    // Small buffer to cause lagging
    var channel = try BroadcastChannel(u64).init(allocator, 8);
    defer channel.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var rx = channel.subscribe();
    var lagged_count = std.atomic.Value(usize).init(0);
    var received_count = std.atomic.Value(usize).init(0);

    const num_messages = 1000;

    // Fast sender
    try scope.spawn(fastBroadcastSender, .{ &channel, num_messages });

    // Slow receiver
    try scope.spawn(slowBroadcastReceiver, .{ &rx, &received_count, &lagged_count });

    try scope.wait();

    // Should have some lag events
    try testing.expect(lagged_count.load(.acquire) > 0);
    // But also received some messages
    try testing.expect(received_count.load(.acquire) > 0);
}

fn fastBroadcastSender(channel: *BroadcastChannel(u64), count: usize) void {
    for (0..count) |i| {
        _ = channel.send(@intCast(i));
    }
    channel.close();
}

fn slowBroadcastReceiver(
    rx: *BroadcastChannel(u64).Receiver,
    received: *std.atomic.Value(usize),
    lagged: *std.atomic.Value(usize),
) void {
    while (true) {
        switch (rx.tryRecv()) {
            .value => |_| {
                _ = received.fetchAdd(1, .acq_rel);
                // Simulate slow processing
                for (0..10) |_| {
                    std.atomic.spinLoopHint();
                }
            },
            .empty => {
                std.atomic.spinLoopHint();
            },
            .lagged => |missed| {
                _ = lagged.fetchAdd(missed, .acq_rel);
            },
            .closed => break,
        }
    }
}

test "BroadcastChannel stress - many receivers same speed" {
    const allocator = testing.allocator;

    var channel = try BroadcastChannel(u64).init(allocator, 128);
    defer channel.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_receivers = 20;
    const num_messages = 500;

    var receivers: [num_receivers]BroadcastChannel(u64).Receiver = undefined;
    for (&receivers) |*rx| {
        rx.* = channel.subscribe();
    }

    var counts: [num_receivers]std.atomic.Value(usize) = undefined;
    for (&counts) |*c| {
        c.* = std.atomic.Value(usize).init(0);
    }

    // Sender
    try scope.spawn(struct {
        fn send(ch: *BroadcastChannel(u64), n: usize) void {
            for (0..n) |i| {
                _ = ch.send(@intCast(i));
            }
            ch.close();
        }
    }.send, .{ &channel, num_messages });

    // Receivers
    for (0..num_receivers) |i| {
        try scope.spawn(countingBroadcastReceiver, .{ &receivers[i], &counts[i] });
    }

    try scope.wait();

    // All receivers should get all messages (no lag with sufficient buffer)
    for (counts) |c| {
        try testing.expectEqual(@as(usize, num_messages), c.load(.acquire));
    }
}

fn countingBroadcastReceiver(
    rx: *BroadcastChannel(u64).Receiver,
    count: *std.atomic.Value(usize),
) void {
    while (true) {
        switch (rx.tryRecv()) {
            .value => |_| {
                _ = count.fetchAdd(1, .acq_rel);
            },
            .empty => {
                std.atomic.spinLoopHint();
            },
            .lagged => |_| {},
            .closed => break,
        }
    }
}

test "BroadcastChannel stress - data integrity" {
    const allocator = testing.allocator;

    var channel = try BroadcastChannel(u64).init(allocator, 256);
    defer channel.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_receivers = 3;
    const num_messages = 2000;

    var receivers: [num_receivers]BroadcastChannel(u64).Receiver = undefined;
    for (&receivers) |*rx| {
        rx.* = channel.subscribe();
    }

    var checksums: [num_receivers]u64 = undefined;
    var sender_checksum: u64 = 0;

    try scope.spawnWithResult(checksumBroadcastSender, .{ &channel, num_messages }, &sender_checksum);

    for (0..num_receivers) |i| {
        try scope.spawnWithResult(checksumBroadcastReceiver, .{ &receivers[i], num_messages }, &checksums[i]);
    }

    try scope.wait();

    // All checksums should match
    for (checksums) |cs| {
        try testing.expectEqual(sender_checksum, cs);
    }
}

fn checksumBroadcastSender(channel: *BroadcastChannel(u64), count: usize) u64 {
    var checksum: u64 = 0;
    var prng = std.Random.DefaultPrng.init(99999);
    const random = prng.random();

    for (0..count) |_| {
        const value = random.int(u64);
        _ = channel.send(value);
        checksum ^= value;
    }

    channel.close();
    return checksum;
}

fn checksumBroadcastReceiver(rx: *BroadcastChannel(u64).Receiver, expected_count: usize) u64 {
    var checksum: u64 = 0;
    var received: usize = 0;

    while (received < expected_count) {
        switch (rx.tryRecv()) {
            .value => |v| {
                checksum ^= v;
                received += 1;
            },
            .empty => {
                std.atomic.spinLoopHint();
            },
            .lagged => |_| {
                // This shouldn't happen with large enough buffer
            },
            .closed => break,
        }
    }

    return checksum;
}
