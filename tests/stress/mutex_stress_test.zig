//! Stress tests for blitz_io.Mutex
//!
//! Tests the async-aware mutex under high contention scenarios.
//! Uses lockBlocking() for proper blocking without spin-waiting.
//!
//! ## Test Categories
//!
//! - **Basic contention**: Many tasks competing for a single lock
//! - **Rapid cycles**: High-frequency lock/unlock to stress state transitions
//! - **Fairness**: Verify all tasks eventually acquire the lock
//! - **Long critical sections**: Lock held for extended periods
//! - **Mixed acquisition**: Combining tryLock and blocking patterns

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const blitz_io = @import("blitz-io");
const Scope = config.ThreadScope;
const Mutex = blitz_io.Mutex;

const config = @import("test_config");

test "Mutex stress - many threads contending with lockBlocking" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var mutex = Mutex.init();
    var counter: usize = 0;

    // Use standard task counts from config
    const num_tasks = config.stress.tasks_medium;
    const increments_per_task = config.stress.ops_per_task;

    for (0..num_tasks) |_| {
        try scope.spawn(mutexIncrementer, .{ &mutex, &counter, increments_per_task });
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_tasks * increments_per_task), counter);
}

fn mutexIncrementer(mutex: *Mutex, counter: *usize, count: usize) void {
    for (0..count) |_| {
        // Use proper blocking instead of spin-waiting
        mutex.lockBlocking();
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

    // Fewer tasks but more cycles per task to stress state machine transitions
    const num_tasks = config.stress.tasks_low;
    const cycles_per_task = config.stress.iterations;

    for (0..num_tasks) |_| {
        try scope.spawn(rapidLockUnlock, .{ &mutex, &total_locks, cycles_per_task });
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_tasks * cycles_per_task), total_locks.load(.acquire));
}

fn rapidLockUnlock(mutex: *Mutex, counter: *std.atomic.Value(usize), count: usize) void {
    for (0..count) |_| {
        mutex.lockBlocking();
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

    // High task count ensures contention, lower attempts per task
    const num_tasks = config.stress.tasks_low;
    const attempts_per_task = config.stress.ops_per_task;

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
            // Brief yield to allow contention
            std.Thread.yield() catch {};
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
    // Fixed array size - test verifies each task completes all its locks
    const num_tasks = 10;
    var lock_counts: [num_tasks]std.atomic.Value(usize) = undefined;
    for (&lock_counts) |*c| {
        c.* = std.atomic.Value(usize).init(0);
    }

    const locks_per_task = config.stress.ops_per_task;

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
        mutex.lockBlocking();
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

    // Fewer tasks since each holds the lock for longer (1000 iterations inside)
    const num_tasks = config.stress.tasks_low;

    for (0..num_tasks) |_| {
        try scope.spawn(longCriticalSection, .{ &mutex, &value });
    }

    try scope.wait();

    // Each task adds 1000 inside the critical section
    try testing.expectEqual(@as(u64, num_tasks * 1000), value);
}

fn longCriticalSection(mutex: *Mutex, value: *u64) void {
    mutex.lockBlocking();
    defer mutex.unlock();

    // Long critical section - do work while holding lock
    for (0..1000) |_| {
        value.* += 1;
    }
}

test "Mutex stress - blocking acquisition under contention" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var mutex = Mutex.init();
    var counter: usize = 0;

    // Tests the blocking path under high contention
    const num_tasks = config.stress.tasks_low;
    const increments_per_task = config.stress.small;

    for (0..num_tasks) |_| {
        try scope.spawn(blockingIncrement, .{ &mutex, &counter, increments_per_task });
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_tasks * increments_per_task), counter);
}

fn blockingIncrement(mutex: *Mutex, counter: *usize, count: usize) void {
    for (0..count) |_| {
        mutex.lockBlocking();
        counter.* += 1;
        mutex.unlock();
    }
}

test "Mutex stress - mixed tryLock and blocking acquisition" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var mutex = Mutex.init();
    var counter: usize = 0;

    // Half use tryLock (fast path), half use blocking (slow path)
    const num_tasks = config.stress.tasks_low;
    const increments_per_task = config.stress.small;

    // Half use tryLock with fallback to blocking
    for (0..num_tasks / 2) |_| {
        try scope.spawn(tryLockWithFallback, .{ &mutex, &counter, increments_per_task });
    }
    // Half use blocking directly
    for (0..num_tasks / 2) |_| {
        try scope.spawn(blockingIncrement, .{ &mutex, &counter, increments_per_task });
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_tasks * increments_per_task), counter);
}

fn tryLockWithFallback(mutex: *Mutex, counter: *usize, count: usize) void {
    for (0..count) |_| {
        // Try fast path first, fall back to blocking if contended
        if (!mutex.tryLock()) {
            mutex.lockBlocking();
        }
        counter.* += 1;
        mutex.unlock();
    }
}
