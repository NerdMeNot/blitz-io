//! Robustness tests for Scope
//!
//! Tests edge cases, error conditions, and recovery scenarios.
//! Uses ThreadScope for thread-based testing outside async runtime.

const std = @import("std");
const testing = std.testing;

const config = @import("test_config");
const Scope = config.ThreadScope;

test "Scope robustness - empty scope wait" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // Should succeed immediately
    try scope.wait();
}

fn atomicIncrement(counter: *std.atomic.Value(usize)) void {
    _ = counter.fetchAdd(1, .acq_rel);
}

test "Scope robustness - cancel before spawn" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // Cancel before any tasks
    scope.cancel();

    var executed = std.atomic.Value(bool).init(false);

    // Spawn after cancel - task should see cancelled state
    try scope.spawn(checkCancelled, .{ &scope, &executed });

    const result = scope.wait();
    try testing.expectError(error.Cancelled, result);

    // Task ran but should have seen cancellation
    try testing.expect(executed.load(.acquire));
}

fn checkCancelled(scope: *const Scope, executed: *std.atomic.Value(bool)) void {
    executed.store(true, .release);
    // Task can check isCancelled
    _ = scope.isCancelled();
}

test "Scope robustness - cancel during wait" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // Spawn task that will cancel the scope
    try scope.spawn(delayedCancel, .{&scope});

    // Spawn long-running task
    try scope.spawn(longTask, .{&scope});

    const result = scope.wait();
    try testing.expectError(error.Cancelled, result);
}

fn delayedCancel(scope: *Scope) void {
    std.Thread.sleep(5_000_000); // 5ms
    scope.cancel();
}

fn longTask(scope: *const Scope) void {
    var i: usize = 0;
    while (i < 1000 and !scope.isCancelled()) : (i += 1) {
        std.Thread.sleep(1_000_000); // 1ms
    }
}

test "Scope robustness - first error wins" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // Spawn multiple failing tasks
    try scope.spawn(failWithError1, .{});
    try scope.spawn(failWithError2, .{});
    try scope.spawn(failWithError3, .{});

    const result = scope.wait();

    // Should get one of the errors (first to complete)
    if (result) {
        try testing.expect(false); // Should have errored
    } else |err| {
        try testing.expect(
            err == error.Error1 or
                err == error.Error2 or
                err == error.Error3,
        );
    }
}

fn failWithError1() !void {
    return error.Error1;
}

fn failWithError2() !void {
    std.Thread.sleep(1_000_000); // 1ms delay
    return error.Error2;
}

fn failWithError3() !void {
    std.Thread.sleep(2_000_000); // 2ms delay
    return error.Error3;
}

test "Scope robustness - result pointer unchanged on error" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var result: u32 = 42; // Sentinel value

    try scope.spawnWithResult(failingComputation, .{}, &result);

    const wait_result = scope.wait();
    try testing.expectError(error.ComputationFailed, wait_result);

    // Result should be unchanged
    try testing.expectEqual(@as(u32, 42), result);
}

fn failingComputation() !u32 {
    return error.ComputationFailed;
}

test "Scope robustness - large task count" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var counter = std.atomic.Value(usize).init(0);

    // Spawn many tasks
    const num_tasks = 500;
    for (0..num_tasks) |_| {
        try scope.spawn(atomicIncrement, .{&counter});
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_tasks), counter.load(.acquire));
}

test "Scope robustness - mixed result types" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var int_result: u64 = 0;
    var bool_result: bool = false;
    var optional_result: ?u32 = null;

    try scope.spawnWithResult(computeU64, .{}, &int_result);
    try scope.spawnWithResult(computeBool, .{}, &bool_result);
    try scope.spawnWithResult(computeOptional, .{}, &optional_result);

    try scope.wait();

    try testing.expectEqual(@as(u64, 12345), int_result);
    try testing.expect(bool_result);
    try testing.expectEqual(@as(?u32, 42), optional_result);
}

fn computeU64() u64 {
    return 12345;
}

fn computeBool() bool {
    return true;
}

fn computeOptional() ?u32 {
    return 42;
}
