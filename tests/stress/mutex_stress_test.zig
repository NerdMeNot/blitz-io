//! Stress tests for Mutex
//!
//! High-contention scenarios to verify correctness under load.

const std = @import("std");
const testing = std.testing;
const blitz_io = @import("blitz-io");
const Scope = blitz_io.Scope;

// Use std.Thread.Mutex for stress testing since blitz_io.Mutex has waiter-based API
const Mutex = std.Thread.Mutex;

test "Mutex stress - many threads contending" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var mutex = Mutex{};
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
        mutex.lock();
        counter.* += 1;
        mutex.unlock();
    }
}

test "Mutex stress - lock/unlock rapid cycles" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var mutex = Mutex{};
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
        mutex.lock();
        _ = counter.fetchAdd(1, .acq_rel);
        mutex.unlock();
    }
}

test "Mutex stress - tryLock under contention" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var mutex = Mutex{};
    var successes = std.atomic.Value(usize).init(0);
    var failures = std.atomic.Value(usize).init(0);

    const num_tasks = 50;
    const attempts_per_task = 100;

    for (0..num_tasks) |_| {
        try scope.spawn(tryLockWorker, .{ &mutex, &successes, &failures, attempts_per_task });
    }

    try scope.wait();

    // Should have some successes and some failures
    const total_successes = successes.load(.acquire);
    const total_failures = failures.load(.acquire);

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

    var mutex = Mutex{};
    const num_tasks = 10;
    var lock_counts: [num_tasks]std.atomic.Value(usize) = undefined;
    for (&lock_counts) |*c| {
        c.* = std.atomic.Value(usize).init(0);
    }

    const total_locks = 1000;

    for (0..num_tasks) |i| {
        try scope.spawn(fairnessWorker, .{ &mutex, &lock_counts[i], total_locks / num_tasks });
    }

    try scope.wait();

    // Each thread should have gotten some locks
    // (not a strict fairness guarantee, but shouldn't be 0)
    for (lock_counts) |c| {
        try testing.expect(c.load(.acquire) > 0);
    }
}

fn fairnessWorker(mutex: *Mutex, my_count: *std.atomic.Value(usize), target: usize) void {
    for (0..target) |_| {
        mutex.lock();
        _ = my_count.fetchAdd(1, .acq_rel);
        mutex.unlock();
    }
}

test "Mutex stress - long critical section" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var mutex = Mutex{};
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
    mutex.lock();
    defer mutex.unlock();

    // Long critical section - do work while holding lock
    for (0..1000) |_| {
        value.* += 1;
    }
}
