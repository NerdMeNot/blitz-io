//! Stress tests for Scope structured concurrency
//!
//! High-volume concurrent task spawning to verify correctness under load.

const std = @import("std");
const testing = std.testing;
const blitz_io = @import("blitz-io");
const Scope = blitz_io.Scope;

test "Scope stress - 1000 concurrent tasks" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var counter = std.atomic.Value(usize).init(0);

    const num_tasks = 1000;
    for (0..num_tasks) |_| {
        try scope.spawn(atomicIncrement, .{&counter});
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_tasks), counter.load(.acquire));
}

fn atomicIncrement(counter: *std.atomic.Value(usize)) void {
    _ = counter.fetchAdd(1, .acq_rel);
}

test "Scope stress - rapid spawn/wait cycles" {
    const allocator = testing.allocator;

    const cycles = 100;
    const tasks_per_cycle = 10;

    for (0..cycles) |_| {
        var scope = Scope.init(allocator);
        defer scope.deinit();

        var counter = std.atomic.Value(usize).init(0);

        for (0..tasks_per_cycle) |_| {
            try scope.spawn(atomicIncrement, .{&counter});
        }

        try scope.wait();

        try testing.expectEqual(@as(usize, tasks_per_cycle), counter.load(.acquire));
    }
}

test "Scope stress - cancellation under load" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var started = std.atomic.Value(usize).init(0);

    // Spawn many long-running tasks
    for (0..100) |_| {
        try scope.spawn(longRunningTask, .{ &scope, &started });
    }

    // Let some tasks start
    while (started.load(.acquire) < 10) {
        std.Thread.yield() catch {};
    }

    // Cancel
    scope.cancel();

    const result = scope.wait();
    try testing.expectError(error.Cancelled, result);

    // All tasks should have seen cancellation eventually
    // (they check isCancelled in their loop)
}

fn longRunningTask(scope: *const Scope, started: *std.atomic.Value(usize)) void {
    _ = started.fetchAdd(1, .acq_rel);

    var i: usize = 0;
    while (i < 10000 and !scope.isCancelled()) : (i += 1) {
        std.Thread.yield() catch {};
    }
}

test "Scope stress - mixed success and failure" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var successes = std.atomic.Value(usize).init(0);

    // Spawn mix of succeeding and failing tasks
    for (0..100) |i| {
        if (i % 10 == 0) {
            try scope.spawn(failingTask, .{});
        } else {
            try scope.spawn(succeedingTask, .{&successes});
        }
    }

    const result = scope.wait();

    // Should get first error
    try testing.expectError(error.IntentionalFailure, result);

    // Some successes should have completed
    try testing.expect(successes.load(.acquire) > 0);
}

fn succeedingTask(counter: *std.atomic.Value(usize)) void {
    _ = counter.fetchAdd(1, .acq_rel);
}

fn failingTask() !void {
    return error.IntentionalFailure;
}
