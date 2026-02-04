//! Stress tests for blitz_io.Barrier
//!
//! Tests the N-way synchronization barrier under high contention scenarios.

const std = @import("std");
const testing = std.testing;
const blitz_io = @import("blitz-io");
const Scope = blitz_io.Scope;
const Barrier = blitz_io.sync.Barrier;
const BarrierWaiter = blitz_io.sync.BarrierWaiter;

test "Barrier stress - basic N-way synchronization" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_tasks = 10;
    var barrier = Barrier.init(num_tasks);
    var arrivals = std.atomic.Value(usize).init(0);
    var completions = std.atomic.Value(usize).init(0);
    var leader_count = std.atomic.Value(usize).init(0);

    for (0..num_tasks) |_| {
        try scope.spawn(barrierTask, .{ &barrier, &arrivals, &completions, &leader_count });
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_tasks), arrivals.load(.acquire));
    try testing.expectEqual(@as(usize, num_tasks), completions.load(.acquire));
    try testing.expectEqual(@as(usize, 1), leader_count.load(.acquire));
}

fn barrierTask(
    barrier: *Barrier,
    arrivals: *std.atomic.Value(usize),
    completions: *std.atomic.Value(usize),
    leaders: *std.atomic.Value(usize),
) void {
    _ = arrivals.fetchAdd(1, .acq_rel);

    var waiter = BarrierWaiter.init();
    if (!barrier.wait(&waiter)) {
        while (!waiter.isReleased()) {
            std.atomic.spinLoopHint();
        }
    }

    if (waiter.is_leader) {
        _ = leaders.fetchAdd(1, .acq_rel);
    }

    _ = completions.fetchAdd(1, .acq_rel);
}

test "Barrier stress - multiple generations" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_tasks = 8;
    const generations = 5;

    var barrier = Barrier.init(num_tasks);
    var phase_counters: [generations]std.atomic.Value(usize) = undefined;
    for (&phase_counters) |*c| {
        c.* = std.atomic.Value(usize).init(0);
    }

    for (0..num_tasks) |_| {
        try scope.spawn(multiGenTask, .{ &barrier, &phase_counters, generations });
    }

    try scope.wait();

    // Each phase should have exactly num_tasks completions
    for (phase_counters) |c| {
        try testing.expectEqual(@as(usize, num_tasks), c.load(.acquire));
    }
}

fn multiGenTask(
    barrier: *Barrier,
    counters: *[5]std.atomic.Value(usize),
    generations: usize,
) void {
    for (0..generations) |gen| {
        var waiter = BarrierWaiter.init();

        if (!barrier.wait(&waiter)) {
            while (!waiter.isReleased()) {
                std.atomic.spinLoopHint();
            }
        }

        _ = counters[gen].fetchAdd(1, .acq_rel);

        waiter.reset();
    }
}

test "Barrier stress - large group synchronization" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_tasks = 100;
    var barrier = Barrier.init(num_tasks);
    var completed = std.atomic.Value(usize).init(0);

    for (0..num_tasks) |_| {
        try scope.spawn(largeGroupTask, .{ &barrier, &completed });
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_tasks), completed.load(.acquire));
}

fn largeGroupTask(barrier: *Barrier, completed: *std.atomic.Value(usize)) void {
    var waiter = BarrierWaiter.init();

    if (!barrier.wait(&waiter)) {
        while (!waiter.isReleased()) {
            std.atomic.spinLoopHint();
        }
    }

    _ = completed.fetchAdd(1, .acq_rel);
}

test "Barrier stress - staggered arrivals" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_tasks = 10;
    var barrier = Barrier.init(num_tasks);
    var completed = std.atomic.Value(usize).init(0);

    // Spawn tasks with staggered delays
    for (0..num_tasks) |i| {
        try scope.spawn(staggeredTask, .{ &barrier, &completed, @as(u64, @intCast(i)) });
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_tasks), completed.load(.acquire));
}

fn staggeredTask(barrier: *Barrier, completed: *std.atomic.Value(usize), delay_factor: u64) void {
    // Stagger arrivals
    std.Thread.sleep(delay_factor * std.time.ns_per_ms);

    var waiter = BarrierWaiter.init();

    if (!barrier.wait(&waiter)) {
        while (!waiter.isReleased()) {
            std.atomic.spinLoopHint();
        }
    }

    _ = completed.fetchAdd(1, .acq_rel);
}

test "Barrier stress - leader does work" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    const num_tasks = 20;
    var barrier = Barrier.init(num_tasks);

    var shared_result = std.atomic.Value(u64).init(0);
    var contributions: [num_tasks]std.atomic.Value(u64) = undefined;
    for (&contributions) |*c| {
        c.* = std.atomic.Value(u64).init(0);
    }

    for (0..num_tasks) |i| {
        try scope.spawn(leaderWorkTask, .{
            &barrier,
            &shared_result,
            &contributions,
            @as(usize, i),
        });
    }

    try scope.wait();

    // Leader should have combined all contributions
    var expected: u64 = 0;
    for (contributions) |c| {
        expected += c.load(.acquire);
    }

    try testing.expectEqual(expected, shared_result.load(.acquire));
}

fn leaderWorkTask(
    barrier: *Barrier,
    result: *std.atomic.Value(u64),
    contributions: *[20]std.atomic.Value(u64),
    task_id: usize,
) void {
    // Each task contributes its ID + 1
    contributions[task_id].store(@as(u64, @intCast(task_id + 1)), .release);

    var waiter = BarrierWaiter.init();

    if (!barrier.wait(&waiter)) {
        while (!waiter.isReleased()) {
            std.atomic.spinLoopHint();
        }
    }

    if (waiter.is_leader) {
        // Leader combines all contributions
        var sum: u64 = 0;
        for (contributions) |c| {
            sum += c.load(.acquire);
        }
        result.store(sum, .release);
    }
}

test "Barrier stress - two-task barrier rapid cycles" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var barrier = Barrier.init(2);
    var cycles_a = std.atomic.Value(usize).init(0);
    var cycles_b = std.atomic.Value(usize).init(0);

    const target_cycles = 100;

    try scope.spawn(rapidCycleTask, .{ &barrier, &cycles_a, target_cycles });
    try scope.spawn(rapidCycleTask, .{ &barrier, &cycles_b, target_cycles });

    try scope.wait();

    try testing.expectEqual(@as(usize, target_cycles), cycles_a.load(.acquire));
    try testing.expectEqual(@as(usize, target_cycles), cycles_b.load(.acquire));
}

fn rapidCycleTask(
    barrier: *Barrier,
    cycles: *std.atomic.Value(usize),
    target: usize,
) void {
    for (0..target) |_| {
        var waiter = BarrierWaiter.init();

        if (!barrier.wait(&waiter)) {
            while (!waiter.isReleased()) {
                std.atomic.spinLoopHint();
            }
        }

        _ = cycles.fetchAdd(1, .acq_rel);

        waiter.reset();
    }
}
