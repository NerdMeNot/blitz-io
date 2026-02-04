//! Stress tests for blitz_io.Oneshot
//!
//! Tests the single-value channel under concurrent scenarios.

const std = @import("std");
const testing = std.testing;
const blitz_io = @import("blitz-io");
const Scope = blitz_io.Scope;
const Oneshot = blitz_io.sync.Oneshot;

test "Oneshot stress - many send/recv pairs" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_pairs = 100;
    var received_values: [num_pairs]std.atomic.Value(u64) = undefined;
    for (&received_values) |*v| {
        v.* = std.atomic.Value(u64).init(0);
    }

    // Create oneshot channels and spawn sender/receiver pairs
    for (0..num_pairs) |i| {
        const expected_value: u64 = @as(u64, @intCast(i + 1)) * 1000;

        try scope.spawn(oneshotSender, .{ allocator, expected_value, &received_values[i] });
    }

    try scope.wait();

    // Verify all values received correctly
    for (received_values, 0..) |v, i| {
        const expected: u64 = @as(u64, @intCast(i + 1)) * 1000;
        try testing.expectEqual(expected, v.load(.acquire));
    }
}

fn oneshotSender(allocator: std.mem.Allocator, value: u64, result: *std.atomic.Value(u64)) void {
    var shared = Oneshot(u64).Shared.init();

    // Spawn receiver in nested scope
    var inner_scope = Scope.init(allocator);
    defer inner_scope.deinit();

    inner_scope.spawn(oneshotReceiver, .{ &shared, result }) catch return;

    // Small delay to let receiver start waiting
    std.atomic.spinLoopHint();

    // Send value
    Oneshot(u64).Sender.send(&shared, value);

    inner_scope.wait() catch {};
}

fn oneshotReceiver(shared: *Oneshot(u64).Shared, result: *std.atomic.Value(u64)) void {
    var receiver = Oneshot(u64).Receiver{ .shared = shared };

    // Try to receive
    if (receiver.tryRecv()) |value| {
        result.store(value, .release);
    } else {
        // Poll until value arrives
        while (true) {
            if (receiver.tryRecv()) |value| {
                result.store(value, .release);
                break;
            }
            std.atomic.spinLoopHint();
        }
    }
}

test "Oneshot stress - receiver waits before send" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_channels = 50;
    var results: [num_channels]std.atomic.Value(u64) = undefined;
    for (&results) |*r| {
        r.* = std.atomic.Value(u64).init(0);
    }

    for (0..num_channels) |i| {
        try scope.spawn(waitBeforeSendTest, .{ allocator, @as(u64, @intCast(i)), &results[i] });
    }

    try scope.wait();

    for (results, 0..) |r, i| {
        try testing.expectEqual(@as(u64, @intCast(i)), r.load(.acquire));
    }
}

fn waitBeforeSendTest(allocator: std.mem.Allocator, value: u64, result: *std.atomic.Value(u64)) void {
    var shared = Oneshot(u64).Shared.init();

    var inner_scope = Scope.init(allocator);
    defer inner_scope.deinit();

    // Start receiver first
    inner_scope.spawn(waitingReceiver, .{ &shared, result }) catch return;

    // Delay before sending
    std.time.sleep(std.time.ns_per_ms * 1);

    // Now send
    Oneshot(u64).Sender.send(&shared, value);

    inner_scope.wait() catch {};
}

fn waitingReceiver(shared: *Oneshot(u64).Shared, result: *std.atomic.Value(u64)) void {
    var receiver = Oneshot(u64).Receiver{ .shared = shared };

    // Spin wait for value
    while (true) {
        if (receiver.tryRecv()) |value| {
            result.store(value, .release);
            break;
        }
        std.atomic.spinLoopHint();
    }
}

test "Oneshot stress - send before receiver starts" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_channels = 50;
    var results: [num_channels]std.atomic.Value(u64) = undefined;
    for (&results) |*r| {
        r.* = std.atomic.Value(u64).init(0);
    }

    for (0..num_channels) |i| {
        try scope.spawn(sendBeforeRecvTest, .{ allocator, @as(u64, @intCast(i * 100)), &results[i] });
    }

    try scope.wait();

    for (results, 0..) |r, i| {
        try testing.expectEqual(@as(u64, @intCast(i * 100)), r.load(.acquire));
    }
}

fn sendBeforeRecvTest(allocator: std.mem.Allocator, value: u64, result: *std.atomic.Value(u64)) void {
    var shared = Oneshot(u64).Shared.init();

    // Send first
    Oneshot(u64).Sender.send(&shared, value);

    // Then start receiver
    var inner_scope = Scope.init(allocator);
    defer inner_scope.deinit();

    inner_scope.spawn(immediateReceiver, .{ &shared, result }) catch return;

    inner_scope.wait() catch {};
}

fn immediateReceiver(shared: *Oneshot(u64).Shared, result: *std.atomic.Value(u64)) void {
    var receiver = Oneshot(u64).Receiver{ .shared = shared };

    // Value should be available immediately
    if (receiver.tryRecv()) |value| {
        result.store(value, .release);
    } else {
        // Shouldn't happen, but handle it
        while (true) {
            if (receiver.tryRecv()) |value| {
                result.store(value, .release);
                break;
            }
            std.atomic.spinLoopHint();
        }
    }
}

test "Oneshot stress - large values" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const LargeValue = struct {
        data: [64]u64,

        fn init(seed: u64) @This() {
            var self: @This() = undefined;
            for (&self.data, 0..) |*d, i| {
                d.* = seed + @as(u64, @intCast(i));
            }
            return self;
        }

        fn checksum(self: *const @This()) u64 {
            var sum: u64 = 0;
            for (self.data) |d| {
                sum ^= d;
            }
            return sum;
        }
    };

    const num_channels = 30;
    var checksums: [num_channels]std.atomic.Value(u64) = undefined;
    for (&checksums) |*c| {
        c.* = std.atomic.Value(u64).init(0);
    }

    for (0..num_channels) |i| {
        try scope.spawn(largeValueTest, .{ allocator, LargeValue, @as(u64, @intCast(i)), &checksums[i] });
    }

    try scope.wait();

    // Verify checksums
    for (checksums, 0..) |c, i| {
        const expected = LargeValue.init(@as(u64, @intCast(i))).checksum();
        try testing.expectEqual(expected, c.load(.acquire));
    }
}

fn largeValueTest(
    allocator: std.mem.Allocator,
    comptime LargeValue: type,
    seed: u64,
    checksum_result: *std.atomic.Value(u64),
) void {
    var shared = Oneshot(LargeValue).Shared.init();

    var inner_scope = Scope.init(allocator);
    defer inner_scope.deinit();

    inner_scope.spawn(largeValueReceiver, .{ LargeValue, &shared, checksum_result }) catch return;

    const value = LargeValue.init(seed);
    Oneshot(LargeValue).Sender.send(&shared, value);

    inner_scope.wait() catch {};
}

fn largeValueReceiver(
    comptime LargeValue: type,
    shared: *Oneshot(LargeValue).Shared,
    checksum_result: *std.atomic.Value(u64),
) void {
    var receiver = Oneshot(LargeValue).Receiver{ .shared = shared };

    while (true) {
        if (receiver.tryRecv()) |value| {
            checksum_result.store(value.checksum(), .release);
            break;
        }
        std.atomic.spinLoopHint();
    }
}

test "Oneshot stress - rapid creation and completion" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var completed = std.atomic.Value(usize).init(0);

    const iterations = 500;

    for (0..iterations) |i| {
        try scope.spawn(rapidOneshotCycle, .{ allocator, @as(u64, @intCast(i)), &completed });
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, iterations), completed.load(.acquire));
}

fn rapidOneshotCycle(allocator: std.mem.Allocator, value: u64, completed: *std.atomic.Value(usize)) void {
    var shared = Oneshot(u64).Shared.init();

    var inner_scope = Scope.init(allocator);
    defer inner_scope.deinit();

    inner_scope.spawn(rapidReceiver, .{ &shared }) catch return;

    Oneshot(u64).Sender.send(&shared, value);

    inner_scope.wait() catch {};

    _ = completed.fetchAdd(1, .acq_rel);
}

fn rapidReceiver(shared: *Oneshot(u64).Shared) void {
    var receiver = Oneshot(u64).Receiver{ .shared = shared };

    while (receiver.tryRecv() == null) {
        std.atomic.spinLoopHint();
    }
}
