//! Stress tests for blitz_io.Watch
//!
//! Tests the watch channel (single value with change notification) under load.

const std = @import("std");
const testing = std.testing;
const blitz_io = @import("blitz-io");
const Scope = blitz_io.Scope;
const Watch = blitz_io.sync.Watch;

test "Watch stress - multiple receivers see updates" {
    const allocator = testing.allocator;

    var watch = Watch(u64).init(0);
    defer watch.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_receivers = 10;
    const num_updates = 100;

    var receivers: [num_receivers]Watch(u64).Receiver = undefined;
    for (&receivers) |*rx| {
        rx.* = watch.subscribe();
    }

    var final_values: [num_receivers]std.atomic.Value(u64) = undefined;
    for (&final_values) |*v| {
        v.* = std.atomic.Value(u64).init(0);
    }

    // Sender
    try scope.spawn(watchSender, .{ &watch, num_updates });

    // Receivers
    for (0..num_receivers) |i| {
        try scope.spawn(watchReceiver, .{ &receivers[i], &final_values[i] });
    }

    try scope.wait();

    // All receivers should see the final value
    for (final_values) |v| {
        try testing.expectEqual(@as(u64, num_updates), v.load(.acquire));
    }
}

fn watchSender(watch: *Watch(u64), count: usize) void {
    for (0..count) |i| {
        watch.send(@intCast(i + 1));
        std.atomic.spinLoopHint();
    }
    watch.close();
}

fn watchReceiver(rx: *Watch(u64).Receiver, final_value: *std.atomic.Value(u64)) void {
    var last_seen: u64 = 0;

    while (!rx.isClosed()) {
        if (rx.hasChanged()) {
            const value = rx.borrow().*;
            last_seen = value;
            rx.markSeen();
        } else {
            std.atomic.spinLoopHint();
        }
    }

    // Read final value
    final_value.store(last_seen, .release);
}

test "Watch stress - rapid updates" {
    const allocator = testing.allocator;

    var watch = Watch(u64).init(0);
    defer watch.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var rx = watch.subscribe();
    var updates_seen = std.atomic.Value(usize).init(0);

    const num_updates = 10000;

    // Fast sender
    try scope.spawn(rapidWatchSender, .{ &watch, num_updates });

    // Receiver trying to keep up
    try scope.spawn(rapidWatchReceiver, .{ &rx, &updates_seen });

    try scope.wait();

    // Receiver should see at least some updates (may miss some due to overwrite)
    try testing.expect(updates_seen.load(.acquire) > 0);
}

fn rapidWatchSender(watch: *Watch(u64), count: usize) void {
    for (0..count) |i| {
        watch.send(@intCast(i));
    }
    watch.close();
}

fn rapidWatchReceiver(rx: *Watch(u64).Receiver, seen: *std.atomic.Value(usize)) void {
    while (!rx.isClosed()) {
        if (rx.hasChanged()) {
            _ = rx.borrow();
            rx.markSeen();
            _ = seen.fetchAdd(1, .acq_rel);
        } else {
            std.atomic.spinLoopHint();
        }
    }
}

test "Watch stress - concurrent subscribers" {
    const allocator = testing.allocator;

    var watch = Watch(u64).init(0);
    defer watch.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var subscribers_done = std.atomic.Value(usize).init(0);

    const num_subscribers = 50;

    // Sender
    try scope.spawn(struct {
        fn send(w: *Watch(u64)) void {
            for (0..100) |i| {
                w.send(@intCast(i));
                std.time.sleep(std.time.ns_per_us * 100);
            }
            w.close();
        }
    }.send, .{&watch});

    // Dynamic subscribers
    for (0..num_subscribers) |_| {
        try scope.spawn(dynamicWatchSubscriber, .{ &watch, &subscribers_done });
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_subscribers), subscribers_done.load(.acquire));
}

fn dynamicWatchSubscriber(watch: *Watch(u64), done: *std.atomic.Value(usize)) void {
    var rx = watch.subscribe();

    while (!rx.isClosed()) {
        if (rx.hasChanged()) {
            _ = rx.borrow();
            rx.markSeen();
        }
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

        fn isValid(self: *const @This()) bool {
            return self.checksum == (self.version ^ 0xDEADBEEF);
        }
    };

    var watch = Watch(Config).init(Config.init(0));
    defer watch.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_receivers = 5;
    var receivers: [num_receivers]Watch(Config).Receiver = undefined;
    for (&receivers) |*rx| {
        rx.* = watch.subscribe();
    }

    var integrity_ok: [num_receivers]std.atomic.Value(bool) = undefined;
    for (&integrity_ok) |*ok| {
        ok.* = std.atomic.Value(bool).init(true);
    }

    const num_updates = 1000;

    // Sender
    try scope.spawn(configSender, .{ &watch, Config, num_updates });

    // Receivers checking integrity
    for (0..num_receivers) |i| {
        try scope.spawn(configReceiver, .{ &receivers[i], Config, &integrity_ok[i] });
    }

    try scope.wait();

    // All receivers should have seen only valid configs
    for (integrity_ok) |ok| {
        try testing.expect(ok.load(.acquire));
    }
}

fn configSender(watch: anytype, comptime Config: type, count: usize) void {
    for (0..count) |i| {
        watch.send(Config.init(@intCast(i + 1)));
    }
    watch.close();
}

fn configReceiver(rx: anytype, comptime Config: type, ok: *std.atomic.Value(bool)) void {
    while (!rx.isClosed()) {
        if (rx.hasChanged()) {
            const config = rx.borrow();
            if (!config.isValid()) {
                ok.store(false, .release);
            }
            rx.markSeen();
        }
        std.atomic.spinLoopHint();
    }
}

test "Watch stress - close propagation" {
    const allocator = testing.allocator;

    var watch = Watch(u64).init(0);
    defer watch.deinit();

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_receivers = 20;
    var receivers: [num_receivers]Watch(u64).Receiver = undefined;
    for (&receivers) |*rx| {
        rx.* = watch.subscribe();
    }

    var close_detected: [num_receivers]std.atomic.Value(bool) = undefined;
    for (&close_detected) |*d| {
        d.* = std.atomic.Value(bool).init(false);
    }

    // Receivers waiting for close
    for (0..num_receivers) |i| {
        try scope.spawn(closeDetector, .{ &receivers[i], &close_detected[i] });
    }

    // Give receivers time to start
    std.time.sleep(std.time.ns_per_ms * 10);

    // Close the watch
    watch.close();

    try scope.wait();

    // All receivers should have detected close
    for (close_detected) |d| {
        try testing.expect(d.load(.acquire));
    }
}

fn closeDetector(rx: *Watch(u64).Receiver, detected: *std.atomic.Value(bool)) void {
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

    const num_readers = 10;
    var readers: [num_readers]Watch(u64).Receiver = undefined;
    for (&readers) |*rx| {
        rx.* = watch.subscribe();
    }

    var read_counts: [num_readers]std.atomic.Value(usize) = undefined;
    for (&read_counts) |*c| {
        c.* = std.atomic.Value(usize).init(0);
    }

    const num_updates = 500;

    // Updater
    try scope.spawn(struct {
        fn update(w: *Watch(u64), count: usize) void {
            for (0..count) |i| {
                w.send(@intCast(i));
            }
            w.close();
        }
    }.update, .{ &watch, num_updates });

    // Readers
    for (0..num_readers) |i| {
        try scope.spawn(mixedPatternReader, .{ &readers[i], &read_counts[i] });
    }

    try scope.wait();

    // All readers should have completed
    for (read_counts) |c| {
        try testing.expect(c.load(.acquire) > 0);
    }
}

fn mixedPatternReader(rx: *Watch(u64).Receiver, reads: *std.atomic.Value(usize)) void {
    while (!rx.isClosed()) {
        // Sometimes check hasChanged, sometimes just borrow
        if (reads.load(.acquire) % 3 == 0) {
            if (rx.hasChanged()) {
                _ = rx.borrow();
                rx.markSeen();
                _ = reads.fetchAdd(1, .acq_rel);
            }
        } else {
            _ = rx.borrow();
            _ = reads.fetchAdd(1, .acq_rel);
        }
        std.atomic.spinLoopHint();
    }
}
