//! Stress tests for blitz_io.Mutex
//!
//! Tests the async-aware mutex under high contention scenarios.
//! Uses tryLock/unlock for synchronous stress testing.

const std = @import("std");
const testing = std.testing;
const blitz_io = @import("blitz-io");
const Scope = blitz_io.Scope;
const Mutex = blitz_io.Mutex;
const MutexWaiter = blitz_io.sync.MutexWaiter;

test "Mutex stress - many threads contending with tryLock" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var mutex = Mutex.init();
    var counter: usize = 0;

    const num_tasks = 100;
    const increments_per_task = 100;

    for (0..num_tasks) |_| {
        try scope.spawn(mutexIncrementer, .{ &mutex, &counter, increments_per_task });
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_tasks * increments_per_task), counter);
}

fn mutexIncrementer(mutex: *Mutex, counter: *usize, count: usize) void {
    for (0..count) |_| {
        // Spin until we acquire the lock
        while (!mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
        counter.* += 1;
        mutex.unlock();
    }
}

test "Mutex stress - rapid lock/unlock cycles" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var mutex = Mutex.init();
    var total_locks = std.atomic.Value(usize).init(0);

    const num_tasks = 10;
    const cycles_per_task = 1000;

    for (0..num_tasks) |_| {
        try scope.spawn(rapidLockUnlock, .{ &mutex, &total_locks, cycles_per_task });
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_tasks * cycles_per_task), total_locks.load(.acquire));
}

fn rapidLockUnlock(mutex: *Mutex, counter: *std.atomic.Value(usize), count: usize) void {
    for (0..count) |_| {
        while (!mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
        _ = counter.fetchAdd(1, .acq_rel);
        mutex.unlock();
    }
}

test "Mutex stress - tryLock contention statistics" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var mutex = Mutex.init();
    var successes = std.atomic.Value(usize).init(0);
    var failures = std.atomic.Value(usize).init(0);

    const num_tasks = 50;
    const attempts_per_task = 100;

    for (0..num_tasks) |_| {
        try scope.spawn(tryLockWorker, .{ &mutex, &successes, &failures, attempts_per_task });
    }

    try scope.wait();

    const total_successes = successes.load(.acquire);
    const total_failures = failures.load(.acquire);

    // Should have some successes and some failures under contention
    try testing.expect(total_successes > 0);
    try testing.expectEqual(@as(usize, num_tasks * attempts_per_task), total_successes + total_failures);
}

fn tryLockWorker(
    mutex: *Mutex,
    successes: *std.atomic.Value(usize),
    failures: *std.atomic.Value(usize),
    attempts: usize,
) void {
    for (0..attempts) |_| {
        if (mutex.tryLock()) {
            _ = successes.fetchAdd(1, .acq_rel);
            // Hold lock briefly
            std.atomic.spinLoopHint();
            mutex.unlock();
        } else {
            _ = failures.fetchAdd(1, .acq_rel);
        }
    }
}

test "Mutex stress - fairness (no starvation)" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var mutex = Mutex.init();
    const num_tasks = 10;
    var lock_counts: [num_tasks]std.atomic.Value(usize) = undefined;
    for (&lock_counts) |*c| {
        c.* = std.atomic.Value(usize).init(0);
    }

    const locks_per_task = 100;

    for (0..num_tasks) |i| {
        try scope.spawn(fairnessWorker, .{ &mutex, &lock_counts[i], locks_per_task });
    }

    try scope.wait();

    // Each thread should have gotten its locks (not starvation test, just completion)
    for (lock_counts) |c| {
        try testing.expectEqual(@as(usize, locks_per_task), c.load(.acquire));
    }
}

fn fairnessWorker(mutex: *Mutex, my_count: *std.atomic.Value(usize), target: usize) void {
    for (0..target) |_| {
        while (!mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
        _ = my_count.fetchAdd(1, .acq_rel);
        mutex.unlock();
    }
}

test "Mutex stress - long critical section" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var mutex = Mutex.init();
    var value: u64 = 0;

    const num_tasks = 10;

    for (0..num_tasks) |_| {
        try scope.spawn(longCriticalSection, .{ &mutex, &value });
    }

    try scope.wait();

    // Each task adds 1000 inside the critical section
    try testing.expectEqual(@as(u64, num_tasks * 1000), value);
}

fn longCriticalSection(mutex: *Mutex, value: *u64) void {
    while (!mutex.tryLock()) {
        std.atomic.spinLoopHint();
    }
    defer mutex.unlock();

    // Long critical section - do work while holding lock
    for (0..1000) |_| {
        value.* += 1;
    }
}

test "Mutex stress - waiter-based acquisition" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var mutex = Mutex.init();
    var counter: usize = 0;

    const num_tasks = 50;
    const increments_per_task = 20;

    for (0..num_tasks) |_| {
        try scope.spawn(waiterBasedIncrement, .{ &mutex, &counter, increments_per_task });
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_tasks * increments_per_task), counter);
}

fn waiterBasedIncrement(mutex: *Mutex, counter: *usize, count: usize) void {
    for (0..count) |_| {
        var waiter = MutexWaiter.init();

        if (!mutex.lock(&waiter)) {
            // Wait for lock to be granted via polling
            while (!waiter.isAcquired()) {
                std.atomic.spinLoopHint();
            }
        }

        counter.* += 1;
        mutex.unlock();
    }
}

test "Mutex stress - mixed tryLock and waiter acquisition" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var mutex = Mutex.init();
    var counter: usize = 0;

    const num_tasks = 40;
    const increments_per_task = 50;

    // Half use tryLock, half use waiter
    for (0..num_tasks / 2) |_| {
        try scope.spawn(mutexIncrementer, .{ &mutex, &counter, increments_per_task });
    }
    for (0..num_tasks / 2) |_| {
        try scope.spawn(waiterBasedIncrement, .{ &mutex, &counter, increments_per_task });
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_tasks * increments_per_task), counter);
}
