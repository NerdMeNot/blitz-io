//! Stress tests for blitz_io.Notify
//!
//! Tests the task notification primitive under high contention scenarios.
//!
//! ## Test Categories
//!
//! - **notifyOne**: Single waiter wakeup semantics
//! - **notifyAll**: Broadcast wakeup to all waiters
//! - **Rapid cycles**: High-frequency notify/wait patterns
//! - **Permit semantics**: notify-before-wait behavior
//! - **Multiple bursts**: Batch registration and wakeup

const std = @import("std");
const testing = std.testing;
const blitz_io = @import("blitz-io");
const Scope = config.ThreadScope;
const Notify = blitz_io.sync.Notify;
const NotifyWaiter = blitz_io.sync.NotifyWaiter;

const config = @import("test_config");

test "Notify stress - notifyOne wakes single waiter" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var notify = Notify.init();
    var woken_count = std.atomic.Value(usize).init(0);
    var registered_count = std.atomic.Value(usize).init(0);

    // Use tasks_low for debug/release scaling
    const num_waiters = config.stress.tasks_low;

    // Spawn waiters - they signal when registered
    for (0..num_waiters) |_| {
        try scope.spawn(notifyWaiter, .{ &notify, &woken_count, &registered_count });
    }

    // Wait for ALL waiters to actually register (not just sleep and hope)
    while (registered_count.load(.acquire) < num_waiters) {
        std.Thread.yield() catch {};
    }

    // Now all waiters are in the queue - wake them one by one
    for (0..num_waiters) |_| {
        notify.notifyOne();
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_waiters), woken_count.load(.acquire));
}

fn notifyWaiter(notify: *Notify, woken: *std.atomic.Value(usize), registered: *std.atomic.Value(usize)) void {
    var waiter = NotifyWaiter.init();

    // wait() returns true if notified immediately (permit consumed), false if we need to wait
    const immediate = notify.wait(&waiter);

    // Signal AFTER wait() so main thread knows we're actually in the queue
    _ = registered.fetchAdd(1, .acq_rel);

    if (!immediate) {
        // Spin until notified
        while (!waiter.isNotified()) {
            std.Thread.yield() catch {};
        }
    }

    _ = woken.fetchAdd(1, .acq_rel);
}

test "Notify stress - notifyAll wakes all waiters" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var notify = Notify.init();
    var woken_count = std.atomic.Value(usize).init(0);
    var all_registered = std.atomic.Value(usize).init(0);

    // Use tasks_medium for larger broadcast test
    const num_waiters = config.stress.tasks_medium;

    // Spawn waiters that signal when registered
    for (0..num_waiters) |_| {
        try scope.spawn(notifyAllWaiter, .{ &notify, &woken_count, &all_registered });
    }

    // Wait for all to register
    while (all_registered.load(.acquire) < num_waiters) {
        std.Thread.yield() catch {};
    }

    // Wake all at once
    notify.notifyAll();

    try scope.wait();

    try testing.expectEqual(@as(usize, num_waiters), woken_count.load(.acquire));
}

fn notifyAllWaiter(
    notify: *Notify,
    woken: *std.atomic.Value(usize),
    registered: *std.atomic.Value(usize),
) void {
    var waiter = NotifyWaiter.init();

    // wait() returns true if notified immediately, false if we need to wait
    // IMPORTANT: Register AFTER wait() so main only calls notifyAll once
    // all waiters are actually in the queue
    const immediate = notify.wait(&waiter);

    _ = registered.fetchAdd(1, .acq_rel);

    if (!immediate) {
        while (!waiter.isNotified()) {
            std.Thread.yield() catch {};
        }
    }

    _ = woken.fetchAdd(1, .acq_rel);
}

test "Notify stress - rapid notify/wait cycles" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var notify = Notify.init();
    var notify_count = std.atomic.Value(usize).init(0);
    var wait_count = std.atomic.Value(usize).init(0);

    // 10 each for moderate contention, cycles from config
    const num_notifiers = 10;
    const num_waiters = 10;
    const cycles = config.stress.iterations;

    // Spawn notifiers
    for (0..num_notifiers) |_| {
        try scope.spawn(rapidNotifier, .{ &notify, &notify_count, cycles });
    }

    // Spawn waiters
    for (0..num_waiters) |_| {
        try scope.spawn(rapidWaiter, .{ &notify, &wait_count, cycles });
    }

    try scope.wait();

    // All notifiers should complete
    try testing.expectEqual(@as(usize, num_notifiers * cycles), notify_count.load(.acquire));
    // All waiters should complete
    try testing.expectEqual(@as(usize, num_waiters * cycles), wait_count.load(.acquire));
}

fn rapidNotifier(notify: *Notify, count: *std.atomic.Value(usize), cycles: usize) void {
    for (0..cycles) |_| {
        notify.notifyOne();
        _ = count.fetchAdd(1, .acq_rel);
        std.Thread.yield() catch {};
    }
}

fn rapidWaiter(notify: *Notify, count: *std.atomic.Value(usize), cycles: usize) void {
    for (0..cycles) |_| {
        var waiter = NotifyWaiter.init();

        // Try to wait, but don't block forever
        // wait() returns true if notified immediately, false if added to queue
        if (!notify.wait(&waiter)) {
            // Spin briefly, then give up (permit may have been consumed)
            var spins: usize = 0;
            while (!waiter.isNotified() and spins < 1000) : (spins += 1) {
                std.Thread.yield() catch {};
            }
            if (!waiter.isNotified()) {
                notify.cancelWait(&waiter);
            }
        }

        _ = count.fetchAdd(1, .acq_rel);
    }
}

test "Notify stress - permit semantics (notify before wait)" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var completed = std.atomic.Value(usize).init(0);

    // Use iterations for task spawning (1000 in release, not 100k)
    // Each task gets its own Notify to test permit semantics correctly
    // (permits don't accumulate, so sharing would cause races)
    const iterations = config.stress.iterations;

    for (0..iterations) |_| {
        try scope.spawn(permitTest, .{&completed});
    }

    try scope.wait();

    // All tasks should have completed
    try testing.expectEqual(@as(usize, iterations), completed.load(.acquire));
}

fn permitTest(completed: *std.atomic.Value(usize)) void {
    // Each task uses its own Notify to test permit semantics
    var notify = Notify.init();

    // Notify first (stores permit)
    notify.notifyOne();

    // Wait should consume permit immediately
    var waiter = NotifyWaiter.init();
    // wait() returns true if permit consumed immediately
    const was_immediate = notify.wait(&waiter);

    if (!was_immediate) {
        // Should not happen with own Notify, but handle it
        while (!waiter.isNotified()) {
            std.Thread.yield() catch {};
        }
    }

    _ = completed.fetchAdd(1, .acq_rel);
}

test "Notify stress - multiple notifyAll bursts" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var notify = Notify.init();
    var total_wakes = std.atomic.Value(usize).init(0);
    var registered = std.atomic.Value(usize).init(0);

    // 20 waiters × 5 bursts tests repeated batch notification
    const num_waiters = 20;
    const bursts = 5;

    for (0..bursts) |burst| {
        // Spawn batch of waiters
        for (0..num_waiters) |_| {
            try scope.spawn(burstWaiter, .{ &notify, &total_wakes, &registered });
        }

        // Wait for this batch to actually register
        const expected = (burst + 1) * num_waiters;
        while (registered.load(.acquire) < expected) {
            std.Thread.yield() catch {};
        }

        // Wake all
        notify.notifyAll();
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_waiters * bursts), total_wakes.load(.acquire));
}

fn burstWaiter(notify: *Notify, wakes: *std.atomic.Value(usize), registered: *std.atomic.Value(usize)) void {
    var waiter = NotifyWaiter.init();

    // wait() returns true if notified immediately, false if we need to wait
    const immediate = notify.wait(&waiter);

    // Signal AFTER wait() so main knows we're in the queue
    _ = registered.fetchAdd(1, .acq_rel);

    if (!immediate) {
        while (!waiter.isNotified()) {
            std.Thread.yield() catch {};
        }
    }

    _ = wakes.fetchAdd(1, .acq_rel);
}
