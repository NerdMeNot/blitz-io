//! Stress tests for blitz_io.Semaphore
//!
//! Tests the counting semaphore under high contention scenarios.

const std = @import("std");
const testing = std.testing;
const blitz_io = @import("blitz-io");
const Scope = blitz_io.Scope;
const Semaphore = blitz_io.Semaphore;
const SemaphoreWaiter = blitz_io.sync.SemaphoreWaiter;

test "Semaphore stress - concurrent access within limit" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const max_concurrent = 5;
    var sem = Semaphore.init(max_concurrent);
    var current_holders = std.atomic.Value(usize).init(0);
    var max_observed = std.atomic.Value(usize).init(0);

    const num_tasks = 50;

    for (0..num_tasks) |_| {
        try scope.spawn(trackConcurrency, .{ &sem, &current_holders, &max_observed });
    }

    try scope.wait();

    // Max observed should never exceed the permit count
    try testing.expect(max_observed.load(.acquire) <= max_concurrent);
}

fn trackConcurrency(
    sem: *Semaphore,
    current: *std.atomic.Value(usize),
    max_observed: *std.atomic.Value(usize),
) void {
    // Acquire permit
    while (!sem.tryAcquire(1)) {
        std.atomic.spinLoopHint();
    }

    // Track concurrency
    const now_holding = current.fetchAdd(1, .acq_rel) + 1;

    // Update max observed
    var max = max_observed.load(.acquire);
    while (now_holding > max) {
        const result = max_observed.cmpxchgWeak(max, now_holding, .acq_rel, .acquire);
        if (result) |actual| {
            max = actual;
        } else {
            break;
        }
    }

    // Simulate work
    std.atomic.spinLoopHint();
    for (0..100) |_| {
        std.atomic.spinLoopHint();
    }

    // Release
    _ = current.fetchSub(1, .acq_rel);
    sem.release(1);
}

test "Semaphore stress - acquire multiple permits" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const total_permits = 10;
    var sem = Semaphore.init(total_permits);
    var completed = std.atomic.Value(usize).init(0);

    const num_tasks = 20;
    const permits_per_task = 2;

    for (0..num_tasks) |_| {
        try scope.spawn(acquireMultiple, .{ &sem, permits_per_task, &completed });
    }

    try scope.wait();

    // All tasks should complete
    try testing.expectEqual(@as(usize, num_tasks), completed.load(.acquire));

    // All permits should be returned
    try testing.expectEqual(@as(usize, total_permits), sem.availablePermits());
}

fn acquireMultiple(
    sem: *Semaphore,
    permits: usize,
    completed: *std.atomic.Value(usize),
) void {
    while (!sem.tryAcquire(permits)) {
        std.atomic.spinLoopHint();
    }

    // Hold permits briefly
    for (0..50) |_| {
        std.atomic.spinLoopHint();
    }

    sem.release(permits);
    _ = completed.fetchAdd(1, .acq_rel);
}

test "Semaphore stress - single permit (binary semaphore)" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // Binary semaphore = mutex behavior
    var sem = Semaphore.init(1);
    var counter: usize = 0;

    const num_tasks = 100;
    const increments = 100;

    for (0..num_tasks) |_| {
        try scope.spawn(binarySemIncrement, .{ &sem, &counter, increments });
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_tasks * increments), counter);
}

fn binarySemIncrement(sem: *Semaphore, counter: *usize, count: usize) void {
    for (0..count) |_| {
        while (!sem.tryAcquire(1)) {
            std.atomic.spinLoopHint();
        }
        counter.* += 1;
        sem.release(1);
    }
}

test "Semaphore stress - release batching" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const initial_permits = 0;
    var sem = Semaphore.init(initial_permits);
    var acquired_count = std.atomic.Value(usize).init(0);

    const num_acquirers = 10;

    // Spawn acquirers that will wait
    for (0..num_acquirers) |_| {
        try scope.spawn(spinAcquire, .{ &sem, &acquired_count });
    }

    // Give threads time to start waiting
    std.time.sleep(std.time.ns_per_ms * 10);

    // Release all permits at once
    sem.release(num_acquirers);

    try scope.wait();

    // All should have acquired
    try testing.expectEqual(@as(usize, num_acquirers), acquired_count.load(.acquire));
}

fn spinAcquire(sem: *Semaphore, acquired: *std.atomic.Value(usize)) void {
    while (!sem.tryAcquire(1)) {
        std.atomic.spinLoopHint();
    }
    _ = acquired.fetchAdd(1, .acq_rel);
    // Don't release - we're testing batch release
}

test "Semaphore stress - fairness under contention" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const permits = 2;
    var sem = Semaphore.init(permits);

    const num_tasks = 10;
    var acquire_counts: [num_tasks]std.atomic.Value(usize) = undefined;
    for (&acquire_counts) |*c| {
        c.* = std.atomic.Value(usize).init(0);
    }

    const acquires_per_task = 100;

    for (0..num_tasks) |i| {
        try scope.spawn(fairnessAcquire, .{ &sem, &acquire_counts[i], acquires_per_task });
    }

    try scope.wait();

    // Each task should complete all its acquisitions
    for (acquire_counts) |c| {
        try testing.expectEqual(@as(usize, acquires_per_task), c.load(.acquire));
    }
}

fn fairnessAcquire(
    sem: *Semaphore,
    my_count: *std.atomic.Value(usize),
    target: usize,
) void {
    for (0..target) |_| {
        while (!sem.tryAcquire(1)) {
            std.atomic.spinLoopHint();
        }
        _ = my_count.fetchAdd(1, .acq_rel);
        sem.release(1);
    }
}

test "Semaphore stress - waiter-based acquisition" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var sem = Semaphore.init(3);
    var completed = std.atomic.Value(usize).init(0);

    const num_tasks = 30;

    for (0..num_tasks) |_| {
        try scope.spawn(waiterAcquire, .{ &sem, &completed });
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_tasks), completed.load(.acquire));
}

fn waiterAcquire(sem: *Semaphore, completed: *std.atomic.Value(usize)) void {
    var waiter = SemaphoreWaiter.init(1);

    if (!sem.acquire(&waiter)) {
        // Wait for acquisition to complete
        while (!waiter.isComplete()) {
            std.atomic.spinLoopHint();
        }
    }

    // Simulate work
    for (0..100) |_| {
        std.atomic.spinLoopHint();
    }

    sem.release(1);
    _ = completed.fetchAdd(1, .acq_rel);
}

test "Semaphore stress - mixed try and waiter acquisition" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var sem = Semaphore.init(5);
    var counter: usize = 0;
    var guard_mutex = Semaphore.init(1); // Use semaphore as mutex for counter

    const num_tasks = 40;
    const ops_per_task = 50;

    // Half use tryAcquire, half use waiter
    for (0..num_tasks / 2) |_| {
        try scope.spawn(tryAcquireWork, .{ &sem, &guard_mutex, &counter, ops_per_task });
    }
    for (0..num_tasks / 2) |_| {
        try scope.spawn(waiterAcquireWork, .{ &sem, &guard_mutex, &counter, ops_per_task });
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_tasks * ops_per_task), counter);
}

fn tryAcquireWork(
    sem: *Semaphore,
    guard: *Semaphore,
    counter: *usize,
    count: usize,
) void {
    for (0..count) |_| {
        while (!sem.tryAcquire(1)) {
            std.atomic.spinLoopHint();
        }

        // Safely increment counter
        while (!guard.tryAcquire(1)) {
            std.atomic.spinLoopHint();
        }
        counter.* += 1;
        guard.release(1);

        sem.release(1);
    }
}

fn waiterAcquireWork(
    sem: *Semaphore,
    guard: *Semaphore,
    counter: *usize,
    count: usize,
) void {
    for (0..count) |_| {
        var waiter = SemaphoreWaiter.init(1);

        if (!sem.acquire(&waiter)) {
            while (!waiter.isComplete()) {
                std.atomic.spinLoopHint();
            }
        }

        // Safely increment counter
        while (!guard.tryAcquire(1)) {
            std.atomic.spinLoopHint();
        }
        counter.* += 1;
        guard.release(1);

        sem.release(1);
    }
}
