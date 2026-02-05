//! Stress tests for blitz_io.BroadcastChannel
//!
//! Tests the broadcast channel with multiple receivers under high throughput.
//! Uses recvBlocking() for proper blocking without spin-waiting.
//!
//! ## Test Categories
//!
//! - **All receivers**: Every receiver gets every message
//! - **Concurrent subscribe**: Dynamic subscription during sends
//! - **Slow receiver lagging**: Handling of lag in small buffers
//! - **Many receivers**: Scalability with large receiver counts
//! - **Data integrity**: Checksum verification

const std = @import("std");
const testing = std.testing;
const blitz_io = @import("blitz-io");
const Scope = config.ThreadScope;
const BroadcastChannel = blitz_io.sync.BroadcastChannel;

const config = @import("test_config");

test "BroadcastChannel stress - all receivers get all messages" {
    const allocator = testing.allocator;

    // Use config values for message and receiver counts
    const num_messages = config.stress.iterations;
    const num_receivers = config.stress.receivers;

    // Buffer must hold all messages to guarantee no lag
    var channel = try BroadcastChannel(u64).init(allocator, num_messages + 64);
    defer channel.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // Create receivers BEFORE spawning sender to ensure they don't miss messages
    // Fixed array size to accommodate max receivers (20 in release)
    var receivers: [20]BroadcastChannel(u64).Receiver = undefined;
    for (receivers[0..num_receivers]) |*rx| {
        rx.* = channel.subscribe();
    }

    var receiver_sums: [20]u64 = undefined;
    var sender_sum: u64 = 0;
    var receivers_ready = std.atomic.Value(usize).init(0);

    // Spawn receivers first - they signal when in their loop
    for (0..num_receivers) |i| {
        try scope.spawnWithResult(broadcastReceiverWithReady, .{ &receivers[i], &receivers_ready }, &receiver_sums[i]);
    }

    // Spawn sender - it waits for all receivers to be ready
    try scope.spawnWithResult(broadcastSenderWithReady, .{ &channel, num_messages, &receivers_ready, num_receivers }, &sender_sum);

    try scope.wait();

    // All receivers should have the same sum as sender
    for (receiver_sums[0..num_receivers]) |sum| {
        try testing.expectEqual(sender_sum, sum);
    }
}

fn broadcastSenderWithReady(channel: *BroadcastChannel(u64), count: usize, ready: *std.atomic.Value(usize), expected: usize) u64 {
    // Wait for all receivers to be in their polling loop - yield instead of spin
    while (ready.load(.acquire) < expected) {
        std.Thread.yield() catch {};
    }

    var sum: u64 = 0;
    for (0..count) |i| {
        const value: u64 = @intCast(i + 1);
        _ = channel.send(value);
        sum += value;
    }
    channel.close();
    return sum;
}

fn broadcastReceiverWithReady(receiver: *BroadcastChannel(u64).Receiver, ready: *std.atomic.Value(usize)) u64 {
    // Signal that we're about to start polling
    _ = ready.fetchAdd(1, .acq_rel);

    var sum: u64 = 0;
    while (true) {
        // Use proper blocking instead of spin-waiting
        switch (receiver.recvBlocking()) {
            .value => |v| {
                sum += v;
            },
            .lagged => |_| {
                // Shouldn't happen with large buffer
            },
            .closed => break,
            .empty => unreachable, // recvBlocking never returns empty
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
    var receivers_ready = std.atomic.Value(usize).init(0);

    // Use config values
    const num_receivers = config.stress.receivers;
    const num_messages = config.stress.iterations;

    // Spawn receivers first so they can subscribe
    for (0..num_receivers) |_| {
        try scope.spawn(dynamicSubscriber, .{ &channel, &messages_received, &receivers_ready });
    }

    // Start sender - it waits for receivers to be ready
    try scope.spawn(concurrentBroadcastSender, .{ &channel, num_messages, &receivers_ready, num_receivers });

    try scope.wait();

    // Should have received some messages (exact count depends on timing)
    try testing.expect(messages_received.load(.acquire) > 0);
}

fn concurrentBroadcastSender(channel: *BroadcastChannel(u64), count: usize, receivers_ready: *std.atomic.Value(usize), expected_receivers: usize) void {
    // Wait for all receivers to subscribe - yield instead of spin
    while (receivers_ready.load(.acquire) < expected_receivers) {
        std.Thread.yield() catch {};
    }

    for (0..count) |i| {
        _ = channel.send(@intCast(i));
        // Small delay to let receivers catch up - yield instead of spin
        if (i % 50 == 0) {
            std.Thread.yield() catch {};
        }
    }
    channel.close();
}

fn dynamicSubscriber(channel: *BroadcastChannel(u64), received: *std.atomic.Value(usize), ready: *std.atomic.Value(usize)) void {
    var rx = channel.subscribe();
    _ = ready.fetchAdd(1, .acq_rel); // Signal that we're ready

    while (true) {
        // Use proper blocking instead of spin-waiting
        switch (rx.recvBlocking()) {
            .value => |_| {
                _ = received.fetchAdd(1, .acq_rel);
            },
            .lagged => |_| {
                // Expected under contention
            },
            .closed => break,
            .empty => unreachable, // recvBlocking never returns empty
        }
    }
}

test "BroadcastChannel stress - slow receiver lagging" {
    const allocator = testing.allocator;

    // Small buffer (8 slots) to cause lagging
    var channel = try BroadcastChannel(u64).init(allocator, 8);
    defer channel.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var rx = channel.subscribe();
    var lagged_count = std.atomic.Value(usize).init(0);
    var received_count = std.atomic.Value(usize).init(0);

    // Use config iterations for message count
    const num_messages = config.stress.iterations;

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
        // Use proper blocking instead of spin-waiting
        switch (rx.recvBlocking()) {
            .value => |_| {
                _ = received.fetchAdd(1, .acq_rel);
                // Simulate slow processing - yield to create timing variation
                std.Thread.yield() catch {};
            },
            .lagged => |missed| {
                _ = lagged.fetchAdd(missed, .acq_rel);
            },
            .closed => break,
            .empty => unreachable, // recvBlocking never returns empty
        }
    }
}

test "BroadcastChannel stress - many receivers same speed" {
    const allocator = testing.allocator;

    // Use config values - higher receiver count tests scalability
    const num_messages = config.stress.iterations;
    const num_receivers_large = config.stress.receivers;

    // Buffer must be large enough to hold all messages to guarantee no lag
    var channel = try BroadcastChannel(u64).init(allocator, num_messages + 64);
    defer channel.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // Fixed array size to accommodate max receivers (20 in release)
    var receivers: [20]BroadcastChannel(u64).Receiver = undefined;
    for (receivers[0..num_receivers_large]) |*rx| {
        rx.* = channel.subscribe();
    }

    var counts: [20]std.atomic.Value(usize) = undefined;
    for (&counts) |*c| {
        c.* = std.atomic.Value(usize).init(0);
    }

    var receivers_ready = std.atomic.Value(usize).init(0);

    // Spawn receivers first to ensure they're ready
    for (0..num_receivers_large) |i| {
        try scope.spawn(countingBroadcastReceiverWithReady, .{ &receivers[i], &counts[i], &receivers_ready });
    }

    // Sender waits for receivers
    try scope.spawn(struct {
        fn send(ch: *BroadcastChannel(u64), n: usize, ready: *std.atomic.Value(usize), expected: usize) void {
            // Wait for all receivers to be ready - yield instead of spin
            while (ready.load(.acquire) < expected) {
                std.Thread.yield() catch {};
            }
            for (0..n) |i| {
                _ = ch.send(@intCast(i));
            }
            ch.close();
        }
    }.send, .{ &channel, num_messages, &receivers_ready, num_receivers_large });

    try scope.wait();

    // All receivers should get all messages (no lag with sufficient buffer)
    for (counts[0..num_receivers_large]) |c| {
        try testing.expectEqual(@as(usize, num_messages), c.load(.acquire));
    }
}

fn countingBroadcastReceiverWithReady(
    rx: *BroadcastChannel(u64).Receiver,
    count: *std.atomic.Value(usize),
    ready: *std.atomic.Value(usize),
) void {
    _ = ready.fetchAdd(1, .acq_rel);

    while (true) {
        // Use proper blocking instead of spin-waiting
        switch (rx.recvBlocking()) {
            .value => |_| {
                _ = count.fetchAdd(1, .acq_rel);
            },
            .lagged => |_| {},
            .closed => break,
            .empty => unreachable, // recvBlocking never returns empty
        }
    }
}

fn countingBroadcastReceiver(
    rx: *BroadcastChannel(u64).Receiver,
    count: *std.atomic.Value(usize),
) void {
    while (true) {
        // Use proper blocking instead of spin-waiting
        switch (rx.recvBlocking()) {
            .value => |_| {
                _ = count.fetchAdd(1, .acq_rel);
            },
            .lagged => |_| {},
            .closed => break,
            .empty => unreachable, // recvBlocking never returns empty
        }
    }
}

test "BroadcastChannel stress - data integrity" {
    const allocator = testing.allocator;

    // Use high_throughput for data integrity test
    const num_messages_large = config.stress.high_throughput;
    const num_receivers = config.stress.receivers;

    // Buffer must be large enough to hold all messages to guarantee no lag
    var channel = try BroadcastChannel(u64).init(allocator, num_messages_large + 64);
    defer channel.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // Fixed array size to accommodate max receivers (20 in release)
    var receivers: [20]BroadcastChannel(u64).Receiver = undefined;
    for (receivers[0..num_receivers]) |*rx| {
        rx.* = channel.subscribe();
    }

    var checksums: [20]u64 = undefined;
    var sender_checksum: u64 = 0;
    var receivers_ready = std.atomic.Value(usize).init(0);

    // Spawn receivers first to ensure they're ready
    for (0..num_receivers) |i| {
        try scope.spawnWithResult(checksumBroadcastReceiverWithReady, .{ &receivers[i], &receivers_ready }, &checksums[i]);
    }

    // Sender waits for receivers
    try scope.spawnWithResult(checksumBroadcastSenderWithReady, .{ &channel, num_messages_large, &receivers_ready, num_receivers }, &sender_checksum);

    try scope.wait();

    // All checksums should match
    for (checksums[0..num_receivers]) |cs| {
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

fn checksumBroadcastReceiver(rx: *BroadcastChannel(u64).Receiver) u64 {
    var checksum: u64 = 0;

    while (true) {
        // Use proper blocking instead of spin-waiting
        switch (rx.recvBlocking()) {
            .value => |v| {
                checksum ^= v;
            },
            .lagged => |_| {
                // This shouldn't happen with large enough buffer
            },
            .closed => break,
            .empty => unreachable, // recvBlocking never returns empty
        }
    }

    return checksum;
}

fn checksumBroadcastSenderWithReady(channel: *BroadcastChannel(u64), count: usize, ready: *std.atomic.Value(usize), expected: usize) u64 {
    // Wait for all receivers to be ready - yield instead of spin
    while (ready.load(.acquire) < expected) {
        std.Thread.yield() catch {};
    }

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

fn checksumBroadcastReceiverWithReady(rx: *BroadcastChannel(u64).Receiver, ready: *std.atomic.Value(usize)) u64 {
    _ = ready.fetchAdd(1, .acq_rel);

    var checksum: u64 = 0;

    while (true) {
        // Use proper blocking instead of spin-waiting
        switch (rx.recvBlocking()) {
            .value => |v| {
                checksum ^= v;
            },
            .lagged => |_| {
                // This shouldn't happen with large enough buffer
            },
            .closed => break,
            .empty => unreachable, // recvBlocking never returns empty
        }
    }

    return checksum;
}
