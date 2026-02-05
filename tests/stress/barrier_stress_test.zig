//! Stress tests for blitz_io.Barrier
//!
//! Tests the N-way synchronization barrier under high contention scenarios.
//! Uses waitBlocking() for proper blocking without spin-waiting.
//!
//! ## Test Categories
//!
//! - **Basic N-way**: Verify all tasks reach barrier before any proceed
//! - **Multiple generations**: Barrier reuse across multiple synchronization points
//! - **Large groups**: Scalability with many concurrent tasks
//! - **Staggered arrivals**: Tasks arriving at different times
//! - **Leader election**: Exactly one leader per generation

const std = @import("std");
const testing = std.testing;
const blitz_io = @import("blitz-io");
const Scope = config.ThreadScope;
const Barrier = blitz_io.sync.Barrier;

const config = @import("test_config");

test "Barrier stress - basic N-way synchronization" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // 10 tasks chosen as moderate size for basic synchronization test
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

    // Use proper blocking instead of spin-waiting
    const result = barrier.waitBlocking();

    if (result.is_leader) {
        _ = leaders.fetchAdd(1, .acq_rel);
    }

    _ = completions.fetchAdd(1, .acq_rel);
}

test "Barrier stress - multiple generations" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // 8 tasks × 5 generations tests barrier reuse without being too expensive
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
        _ = barrier.waitBlocking();
        _ = counters[gen].fetchAdd(1, .acq_rel);
    }
}

test "Barrier stress - large group synchronization" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // Large group tests scalability - use tasks_medium for debug/release scaling
    const num_tasks = config.stress.tasks_medium;
    var barrier = Barrier.init(num_tasks);
    var completed = std.atomic.Value(usize).init(0);

    for (0..num_tasks) |_| {
        try scope.spawn(largeGroupTask, .{ &barrier, &completed });
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_tasks), completed.load(.acquire));
}

fn largeGroupTask(barrier: *Barrier, completed: *std.atomic.Value(usize)) void {
    _ = barrier.waitBlocking();
    _ = completed.fetchAdd(1, .acq_rel);
}

test "Barrier stress - staggered arrivals" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // 10 tasks with staggered delays (0-9ms) - tests barrier with varied arrival times
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

    _ = barrier.waitBlocking();

    _ = completed.fetchAdd(1, .acq_rel);
}

test "Barrier stress - leader does work" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // Fixed at 20 tasks to match the array size in leaderWorkTask
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

    const wait_result = barrier.waitBlocking();

    if (wait_result.is_leader) {
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

    // Two-task barrier is simplest case for rapid cycling
    var barrier = Barrier.init(2);
    var cycles_a = std.atomic.Value(usize).init(0);
    var cycles_b = std.atomic.Value(usize).init(0);

    // Use config iterations for debug/release scaling
    const target_cycles = config.stress.iterations;

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
        _ = barrier.waitBlocking();
        _ = cycles.fetchAdd(1, .acq_rel);
    }
}
