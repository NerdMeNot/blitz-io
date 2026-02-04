//! Stress tests for blitz_io.Watch
//!
//! Tests the watch channel (single value with change notification) under load.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const blitz_io = @import("blitz-io");
const Scope = blitz_io.Scope;
const Watch = blitz_io.sync.Watch;

// Use smaller iteration counts in debug mode
const is_debug = builtin.mode == .Debug;
const NUM_RECEIVERS: usize = if (is_debug) 5 else 10;
const NUM_UPDATES: usize = if (is_debug) 50 else 100;

test "Watch stress - multiple receivers see updates" {
    const allocator = testing.allocator;

    var watch = Watch(u64).init(0);
    defer watch.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var receivers: [NUM_RECEIVERS]Watch(u64).Receiver = undefined;
    for (&receivers) |*rx| {
        rx.* = watch.subscribe();
    }

    var final_values: [NUM_RECEIVERS]std.atomic.Value(u64) = undefined;
    for (&final_values) |*v| {
        v.* = std.atomic.Value(u64).init(0);
    }

    var receivers_ready = std.atomic.Value(usize).init(0);

    // Receivers first - they signal when ready
    for (0..NUM_RECEIVERS) |i| {
        try scope.spawn(watchReceiver, .{ &receivers[i], &final_values[i], &receivers_ready });
    }

    // Sender waits for receivers, then sends
    try scope.spawn(watchSender, .{ &watch, NUM_UPDATES, &receivers_ready, NUM_RECEIVERS });

    try scope.wait();

    // All receivers should see the final value
    for (final_values) |v| {
        try testing.expectEqual(@as(u64, NUM_UPDATES), v.load(.acquire));
    }
}

fn watchSender(watch: *Watch(u64), count: usize, receivers_ready: *std.atomic.Value(usize), expected_receivers: usize) void {
    // Wait for all receivers to be ready
    while (receivers_ready.load(.acquire) < expected_receivers) {
        std.atomic.spinLoopHint();
    }

    for (0..count) |i| {
        watch.send(@intCast(i + 1));
        // Small delay to let receivers keep up
        for (0..10) |_| {
            std.atomic.spinLoopHint();
        }
    }
    watch.close();
}

fn watchReceiver(rx: *Watch(u64).Receiver, final_value: *std.atomic.Value(u64), ready: *std.atomic.Value(usize)) void {
    // Signal that we're ready
    _ = ready.fetchAdd(1, .acq_rel);

    while (!rx.isClosed()) {
        if (rx.hasChanged()) {
            _ = rx.get();
            rx.markSeen();
        }
        std.atomic.spinLoopHint();
    }

    // After close, always read the final value directly
    // This ensures we don't miss the last update due to race between close and hasChanged
    final_value.store(rx.get(), .release);
}

test "Watch stress - rapid updates" {
    const allocator = testing.allocator;

    var watch = Watch(u64).init(0);
    defer watch.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var rx = watch.subscribe();
    var updates_seen = std.atomic.Value(usize).init(0);
    var receiver_ready = std.atomic.Value(bool).init(false);

    const num_updates = if (is_debug) 1000 else 10000;

    // Receiver first
    try scope.spawn(rapidWatchReceiver, .{ &rx, &updates_seen, &receiver_ready });

    // Fast sender waits for receiver
    try scope.spawn(rapidWatchSender, .{ &watch, num_updates, &receiver_ready });

    try scope.wait();

    // Receiver should see at least some updates (may miss some due to overwrite)
    try testing.expect(updates_seen.load(.acquire) > 0);
}

fn rapidWatchSender(watch: *Watch(u64), count: usize, receiver_ready: *std.atomic.Value(bool)) void {
    // Wait for receiver
    while (!receiver_ready.load(.acquire)) {
        std.atomic.spinLoopHint();
    }

    for (0..count) |i| {
        watch.send(@intCast(i));
    }
    watch.close();
}

fn rapidWatchReceiver(rx: *Watch(u64).Receiver, seen: *std.atomic.Value(usize), ready: *std.atomic.Value(bool)) void {
    ready.store(true, .release);

    while (true) {
        if (rx.hasChanged()) {
            _ = rx.get();
            rx.markSeen();
            _ = seen.fetchAdd(1, .acq_rel);
        }

        if (rx.isClosed()) break;
        std.atomic.spinLoopHint();
    }
}

test "Watch stress - concurrent subscribers" {
    const allocator = testing.allocator;

    var watch = Watch(u64).init(0);
    defer watch.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var subscribers_done = std.atomic.Value(usize).init(0);
    var subscribers_ready = std.atomic.Value(usize).init(0);

    const num_subscribers = if (is_debug) 10 else 50;

    // Dynamic subscribers first
    for (0..num_subscribers) |_| {
        try scope.spawn(dynamicWatchSubscriber, .{ &watch, &subscribers_done, &subscribers_ready });
    }

    // Sender waits for some subscribers
    try scope.spawn(struct {
        fn send(w: *Watch(u64), ready: *std.atomic.Value(usize), expected: usize) void {
            // Wait for at least half the subscribers to be ready
            while (ready.load(.acquire) < expected / 2) {
                std.atomic.spinLoopHint();
            }

            const count = if (is_debug) 50 else 100;
            for (0..count) |i| {
                w.send(@intCast(i));
                // Small delay
                for (0..100) |_| {
                    std.atomic.spinLoopHint();
                }
            }
            w.close();
        }
    }.send, .{ &watch, &subscribers_ready, num_subscribers });

    try scope.wait();

    try testing.expectEqual(@as(usize, num_subscribers), subscribers_done.load(.acquire));
}

fn dynamicWatchSubscriber(watch: *Watch(u64), done: *std.atomic.Value(usize), ready: *std.atomic.Value(usize)) void {
    var rx = watch.subscribe();
    _ = ready.fetchAdd(1, .acq_rel);

    while (true) {
        if (rx.hasChanged()) {
            _ = rx.get();
            rx.markSeen();
        }

        if (rx.isClosed()) break;
        std.atomic.spinLoopHint();
    }

    _ = done.fetchAdd(1, .acq_rel);
}

test "Watch stress - value integrity" {
    const allocator = testing.allocator;

    const Config = struct {
        version: u64,
        checksum: u64,

        fn init(v: u64) @This() {
            return .{
                .version = v,
                .checksum = v ^ 0xDEADBEEF,
            };
        }

        fn isValid(self: @This()) bool {
            return self.checksum == (self.version ^ 0xDEADBEEF);
        }
    };

    var watch = Watch(Config).init(Config.init(0));
    defer watch.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_receivers = if (is_debug) 3 else 5;
    var receivers: [5]Watch(Config).Receiver = undefined;
    for (receivers[0..num_receivers]) |*rx| {
        rx.* = watch.subscribe();
    }

    var integrity_ok: [5]std.atomic.Value(bool) = undefined;
    for (&integrity_ok) |*ok| {
        ok.* = std.atomic.Value(bool).init(true);
    }

    var receivers_ready = std.atomic.Value(usize).init(0);
    const num_updates = if (is_debug) 100 else 1000;

    // Receivers first
    for (0..num_receivers) |i| {
        try scope.spawn(configReceiver, .{ &receivers[i], Config, &integrity_ok[i], &receivers_ready });
    }

    // Sender waits for receivers
    try scope.spawn(configSender, .{ &watch, Config, num_updates, &receivers_ready, num_receivers });

    try scope.wait();

    // All receivers should have seen only valid configs
    for (integrity_ok[0..num_receivers]) |ok| {
        try testing.expect(ok.load(.acquire));
    }
}

fn configSender(watch: anytype, comptime Config: type, count: usize, ready: *std.atomic.Value(usize), expected: usize) void {
    // Wait for receivers
    while (ready.load(.acquire) < expected) {
        std.atomic.spinLoopHint();
    }

    for (0..count) |i| {
        watch.send(Config.init(@intCast(i + 1)));
    }
    watch.close();
}

fn configReceiver(rx: anytype, comptime Config: type, ok: *std.atomic.Value(bool), ready: *std.atomic.Value(usize)) void {
    _ = ready.fetchAdd(1, .acq_rel);

    while (true) {
        if (rx.hasChanged()) {
            // Use get() which is properly synchronized
            const config: Config = rx.get();
            if (!config.isValid()) {
                ok.store(false, .release);
            }
            rx.markSeen();
        }

        if (rx.isClosed()) break;
        std.atomic.spinLoopHint();
    }
}

test "Watch stress - close propagation" {
    const allocator = testing.allocator;

    var watch = Watch(u64).init(0);
    defer watch.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_receivers = if (is_debug) 10 else 20;
    var receivers: [20]Watch(u64).Receiver = undefined;
    for (receivers[0..num_receivers]) |*rx| {
        rx.* = watch.subscribe();
    }

    var close_detected: [20]std.atomic.Value(bool) = undefined;
    for (&close_detected) |*d| {
        d.* = std.atomic.Value(bool).init(false);
    }

    var receivers_ready = std.atomic.Value(usize).init(0);

    // Receivers waiting for close
    for (0..num_receivers) |i| {
        try scope.spawn(closeDetector, .{ &receivers[i], &close_detected[i], &receivers_ready });
    }

    // Wait for all receivers to be ready, then close
    try scope.spawn(struct {
        fn doClose(w: *Watch(u64), ready: *std.atomic.Value(usize), expected: usize) void {
            while (ready.load(.acquire) < expected) {
                std.atomic.spinLoopHint();
            }
            w.close();
        }
    }.doClose, .{ &watch, &receivers_ready, num_receivers });

    try scope.wait();

    // All receivers should have detected close
    for (close_detected[0..num_receivers]) |d| {
        try testing.expect(d.load(.acquire));
    }
}

fn closeDetector(rx: *Watch(u64).Receiver, detected: *std.atomic.Value(bool), ready: *std.atomic.Value(usize)) void {
    _ = ready.fetchAdd(1, .acq_rel);

    while (!rx.isClosed()) {
        std.atomic.spinLoopHint();
    }
    detected.store(true, .release);
}

test "Watch stress - mixed read/update patterns" {
    const allocator = testing.allocator;

    var watch = Watch(u64).init(0);
    defer watch.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_readers = if (is_debug) 5 else 10;
    var readers: [10]Watch(u64).Receiver = undefined;
    for (readers[0..num_readers]) |*rx| {
        rx.* = watch.subscribe();
    }

    var read_counts: [10]std.atomic.Value(usize) = undefined;
    for (&read_counts) |*c| {
        c.* = std.atomic.Value(usize).init(0);
    }

    var readers_ready = std.atomic.Value(usize).init(0);
    const num_updates = if (is_debug) 100 else 500;

    // Readers first
    for (0..num_readers) |i| {
        try scope.spawn(mixedPatternReader, .{ &readers[i], &read_counts[i], &readers_ready });
    }

    // Updater waits for readers
    try scope.spawn(struct {
        fn update(w: *Watch(u64), count: usize, ready: *std.atomic.Value(usize), expected: usize) void {
            while (ready.load(.acquire) < expected) {
                std.atomic.spinLoopHint();
            }

            for (0..count) |i| {
                w.send(@intCast(i));
                // Small delay to let readers observe
                for (0..10) |_| {
                    std.atomic.spinLoopHint();
                }
            }
            w.close();
        }
    }.update, .{ &watch, num_updates, &readers_ready, num_readers });

    try scope.wait();

    // All readers should have completed with at least some reads
    for (read_counts[0..num_readers]) |c| {
        try testing.expect(c.load(.acquire) > 0);
    }
}

fn mixedPatternReader(rx: *Watch(u64).Receiver, reads: *std.atomic.Value(usize), ready: *std.atomic.Value(usize)) void {
    _ = ready.fetchAdd(1, .acq_rel);

    while (true) {
        // Sometimes check hasChanged, sometimes just get
        const count = reads.load(.acquire);
        if (count % 3 == 0) {
            if (rx.hasChanged()) {
                _ = rx.get();
                rx.markSeen();
                _ = reads.fetchAdd(1, .acq_rel);
            }
        } else {
            _ = rx.get();
            _ = reads.fetchAdd(1, .acq_rel);
        }

        if (rx.isClosed()) break;
        std.atomic.spinLoopHint();
    }
}
