//! Stress tests for blitz_io.Semaphore
//!
//! Tests the counting semaphore under high contention scenarios.
//! Uses acquireBlocking() for proper blocking without spin-waiting.
//!
//! ## Test Categories
//!
//! - **Concurrency limiting**: Verify max concurrent holders respects permit count
//! - **Multi-permit**: Acquire/release multiple permits atomically
//! - **Binary semaphore**: Semaphore(1) as mutex equivalent
//! - **Batch release**: Release many permits at once
//! - **Mixed acquisition**: Combining tryAcquire and blocking patterns

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const blitz_io = @import("blitz-io");
const Scope = config.ThreadScope;
const Semaphore = blitz_io.Semaphore;

const config = @import("test_config");

test "Semaphore stress - concurrent access within limit" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // 5 permits allows parallelism while testing contention
    const max_concurrent = config.stress.semaphore_permits;
    var sem = Semaphore.init(max_concurrent);
    var current_holders = std.atomic.Value(usize).init(0);
    var max_observed = std.atomic.Value(usize).init(0);

    const num_tasks = config.stress.tasks_low;

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
    // Use proper blocking instead of spin-waiting
    sem.acquireBlocking(1);

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

    // Simulate work - brief yield to create timing variation
    std.Thread.yield() catch {};

    // Release
    _ = current.fetchSub(1, .acq_rel);
    sem.release(1);
}

test "Semaphore stress - acquire multiple permits" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // 10 total permits, each task takes 2, so max 5 concurrent
    const total_permits = 10;
    var sem = Semaphore.init(total_permits);
    var completed = std.atomic.Value(usize).init(0);

    const num_tasks = config.stress.tasks_low;
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
    sem.acquireBlocking(permits);

    // Hold permits briefly - yield to create contention
    std.Thread.yield() catch {};

    sem.release(permits);
    _ = completed.fetchAdd(1, .acq_rel);
}

test "Semaphore stress - single permit (binary semaphore)" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // Binary semaphore (1 permit) = mutex behavior, tests exclusivity
    var sem = Semaphore.init(1);
    var counter: usize = 0;

    const num_tasks = config.stress.tasks_medium;
    const increments = config.stress.ops_per_task;

    for (0..num_tasks) |_| {
        try scope.spawn(binarySemIncrement, .{ &sem, &counter, increments });
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_tasks * increments), counter);
}

fn binarySemIncrement(sem: *Semaphore, counter: *usize, count: usize) void {
    for (0..count) |_| {
        sem.acquireBlocking(1);
        counter.* += 1;
        sem.release(1);
    }
}

test "Semaphore stress - release batching" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // Start with 0 permits - all tasks must wait
    const initial_permits = 0;
    var sem = Semaphore.init(initial_permits);
    var acquired_count = std.atomic.Value(usize).init(0);

    // 10 acquirers will all wait, then all wake on batch release
    const num_acquirers = 10;

    // Spawn acquirers that will wait
    for (0..num_acquirers) |_| {
        try scope.spawn(blockingAcquire, .{ &sem, &acquired_count });
    }

    // Give threads time to start waiting
    std.Thread.sleep(std.time.ns_per_ms * 10);

    // Release all permits at once
    sem.release(num_acquirers);

    try scope.wait();

    // All should have acquired
    try testing.expectEqual(@as(usize, num_acquirers), acquired_count.load(.acquire));
}

fn blockingAcquire(sem: *Semaphore, acquired: *std.atomic.Value(usize)) void {
    sem.acquireBlocking(1);
    _ = acquired.fetchAdd(1, .acq_rel);
    // Don't release - we're testing batch release
}

test "Semaphore stress - fairness under contention" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // Only 2 permits for 10 tasks = high contention
    const permits = 2;
    var sem = Semaphore.init(permits);

    // Fixed array size for tracking per-task counts
    const num_tasks = 10;
    var acquire_counts: [num_tasks]std.atomic.Value(usize) = undefined;
    for (&acquire_counts) |*c| {
        c.* = std.atomic.Value(usize).init(0);
    }

    const acquires_per_task = config.stress.ops_per_task;

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
        sem.acquireBlocking(1);
        _ = my_count.fetchAdd(1, .acq_rel);
        sem.release(1);
    }
}

test "Semaphore stress - blocking acquisition under contention" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // 3 permits for many tasks tests the blocking path thoroughly
    var sem = Semaphore.init(3);
    var completed = std.atomic.Value(usize).init(0);

    const num_tasks = config.stress.tasks_low;

    for (0..num_tasks) |_| {
        try scope.spawn(blockingWork, .{ &sem, &completed });
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_tasks), completed.load(.acquire));
}

fn blockingWork(sem: *Semaphore, completed: *std.atomic.Value(usize)) void {
    sem.acquireBlocking(1);

    // Simulate work - yield to create timing variation
    std.Thread.yield() catch {};

    sem.release(1);
    _ = completed.fetchAdd(1, .acq_rel);
}

test "Semaphore stress - mixed try and blocking acquisition" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // 5 permits limits concurrency
    var sem = Semaphore.init(config.stress.semaphore_permits);
    var counter: usize = 0;
    var guard_sem = Semaphore.init(1); // Use semaphore as mutex for counter

    // Half use tryAcquire (fast path), half use blocking (slow path)
    const num_tasks = config.stress.tasks_low;
    const ops_per_task = config.stress.small;

    // Half use tryAcquire with fallback to blocking
    for (0..num_tasks / 2) |_| {
        try scope.spawn(tryAcquireWork, .{ &sem, &guard_sem, &counter, ops_per_task });
    }
    // Half use blocking directly
    for (0..num_tasks / 2) |_| {
        try scope.spawn(blockingAcquireWork, .{ &sem, &guard_sem, &counter, ops_per_task });
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
        // Try fast path, fall back to blocking
        if (!sem.tryAcquire(1)) {
            sem.acquireBlocking(1);
        }

        // Safely increment counter
        guard.acquireBlocking(1);
        counter.* += 1;
        guard.release(1);

        sem.release(1);
    }
}

fn blockingAcquireWork(
    sem: *Semaphore,
    guard: *Semaphore,
    counter: *usize,
    count: usize,
) void {
    for (0..count) |_| {
        sem.acquireBlocking(1);

        // Safely increment counter
        guard.acquireBlocking(1);
        counter.* += 1;
        guard.release(1);

        sem.release(1);
    }
}
