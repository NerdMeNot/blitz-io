//! Stress tests for blitz_io.OnceCell
//!
//! Tests the lazy one-time initialization under concurrent access.

const std = @import("std");
const testing = std.testing;
const blitz_io = @import("blitz-io");
const Scope = blitz_io.Scope;
const OnceCell = blitz_io.sync.OnceCell;
const OnceCellWaiter = blitz_io.sync.OnceCellWaiter;

/// Large value type for stress testing
const LargeValue = struct {
    data: [256]u64,

    fn initWithSeed(seed: u64) @This() {
        var self: @This() = undefined;
        for (&self.data, 0..) |*d, i| {
            d.* = seed + @as(u64, @intCast(i));
        }
        return self;
    }

    fn checksum(self: *const @This()) u64 {
        var sum: u64 = 0;
        for (self.data) |d| {
            sum ^= d;
        }
        return sum;
    }
};

test "OnceCell stress - many threads race to initialize" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var cell = OnceCell(u64).init();
    var init_count = std.atomic.Value(usize).init(0);
    var values_seen: [100]std.atomic.Value(u64) = undefined;
    for (&values_seen) |*v| {
        v.* = std.atomic.Value(u64).init(0);
    }

    const num_accessors = 100;

    for (0..num_accessors) |i| {
        try scope.spawn(raceToInit, .{ &cell, &init_count, &values_seen[i] });
    }

    try scope.wait();

    // Only one initialization should have happened
    try testing.expectEqual(@as(usize, 1), init_count.load(.acquire));

    // All should have seen the same value
    const expected_value: u64 = 42;
    for (values_seen) |v| {
        try testing.expectEqual(expected_value, v.load(.acquire));
    }
}

fn raceToInit(
    cell: *OnceCell(u64),
    init_count: *std.atomic.Value(usize),
    value_seen: *std.atomic.Value(u64),
) void {
    const Ctx = *std.atomic.Value(usize);
    const value_ptr = cell.getOrInitCtx(Ctx, init_count, struct {
        fn init(count: Ctx) u64 {
            _ = count.fetchAdd(1, .acq_rel);
            return 42;
        }
    }.init);

    value_seen.store(value_ptr.*, .release);
}

test "OnceCell stress - slow initialization with waiters" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var cell = OnceCell(u64).init();
    var init_count = std.atomic.Value(usize).init(0);
    var access_count = std.atomic.Value(usize).init(0);

    const num_accessors = 50;

    for (0..num_accessors) |_| {
        try scope.spawn(slowInitAccess, .{ &cell, &init_count, &access_count });
    }

    try scope.wait();

    // Only one initialization
    try testing.expectEqual(@as(usize, 1), init_count.load(.acquire));

    // All accessors should have completed
    try testing.expectEqual(@as(usize, num_accessors), access_count.load(.acquire));

    // Cell should have the value
    try testing.expectEqual(@as(u64, 999), cell.get().?.*);
}

fn slowInitAccess(
    cell: *OnceCell(u64),
    init_count: *std.atomic.Value(usize),
    access_count: *std.atomic.Value(usize),
) void {
    const Ctx = *std.atomic.Value(usize);
    const value_ptr = cell.getOrInitCtx(Ctx, init_count, struct {
        fn init(count: Ctx) u64 {
            _ = count.fetchAdd(1, .acq_rel);
            // Simulate slow initialization
            std.Thread.sleep(std.time.ns_per_ms * 10);
            return 999;
        }
    }.init);

    _ = value_ptr;
    _ = access_count.fetchAdd(1, .acq_rel);
}

test "OnceCell stress - get after initialized" {
    const allocator = testing.allocator;

    var cell = OnceCell(u64).init();

    // Initialize first
    const init_value_ptr = cell.getOrInit(struct {
        fn init() u64 {
            return 12345;
        }
    }.init);

    try testing.expectEqual(@as(u64, 12345), init_value_ptr.*);

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var access_count = std.atomic.Value(usize).init(0);

    const num_accessors = 100;

    // Many concurrent accesses to already-initialized cell
    for (0..num_accessors) |_| {
        try scope.spawn(fastGet, .{ &cell, &access_count });
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_accessors), access_count.load(.acquire));
}

fn fastGet(cell: *OnceCell(u64), count: *std.atomic.Value(usize)) void {
    // Should return immediately since already initialized
    const value = cell.get();
    if (value) |v| {
        if (v.* == 12345) {
            _ = count.fetchAdd(1, .acq_rel);
        }
    }
}

test "OnceCell stress - large value initialization" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var cell = OnceCell(LargeValue).init();
    var checksums: [50]std.atomic.Value(u64) = undefined;
    for (&checksums) |*c| {
        c.* = std.atomic.Value(u64).init(0);
    }

    const num_accessors = 50;

    for (0..num_accessors) |i| {
        try scope.spawn(largeValueAccess, .{ &cell, &checksums[i] });
    }

    try scope.wait();

    // All should have same checksum
    const expected_checksum = LargeValue.initWithSeed(7777).checksum();
    for (checksums) |c| {
        try testing.expectEqual(expected_checksum, c.load(.acquire));
    }
}

fn largeValueAccess(
    cell: *OnceCell(LargeValue),
    checksum_result: *std.atomic.Value(u64),
) void {
    const value_ptr = cell.getOrInit(struct {
        fn init() LargeValue {
            return LargeValue.initWithSeed(7777);
        }
    }.init);

    checksum_result.store(value_ptr.checksum(), .release);
}

test "OnceCell stress - repeated getOrInit calls" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var cell = OnceCell(u64).init();
    var total_accesses = std.atomic.Value(usize).init(0);
    var init_count = std.atomic.Value(usize).init(0);

    const num_tasks = 20;
    const accesses_per_task = 100;

    for (0..num_tasks) |_| {
        try scope.spawn(repeatedAccess, .{ &cell, &total_accesses, &init_count, accesses_per_task });
    }

    try scope.wait();

    // Only one init
    try testing.expectEqual(@as(usize, 1), init_count.load(.acquire));

    // All accesses completed
    try testing.expectEqual(@as(usize, num_tasks * accesses_per_task), total_accesses.load(.acquire));
}

fn repeatedAccess(
    cell: *OnceCell(u64),
    total: *std.atomic.Value(usize),
    init_count: *std.atomic.Value(usize),
    count: usize,
) void {
    const Ctx = *std.atomic.Value(usize);
    for (0..count) |_| {
        const value_ptr = cell.getOrInitCtx(Ctx, init_count, struct {
            fn init(counter: Ctx) u64 {
                _ = counter.fetchAdd(1, .acq_rel);
                return 42;
            }
        }.init);

        if (value_ptr.* == 42) {
            _ = total.fetchAdd(1, .acq_rel);
        }
    }
}

test "OnceCell stress - async initialization" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var cell = OnceCell(u64).init();
    var completed = std.atomic.Value(usize).init(0);

    const num_tasks = 30;

    for (0..num_tasks) |_| {
        try scope.spawn(asyncInit, .{ &cell, &completed });
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_tasks), completed.load(.acquire));
    try testing.expectEqual(@as(u64, 555), cell.get().?.*);
}

fn asyncInit(cell: *OnceCell(u64), completed: *std.atomic.Value(usize)) void {
    var waiter = OnceCellWaiter.init();

    const result = cell.getOrInitAsync(struct {
        fn init() u64 {
            // Simulate slow init
            for (0..100) |_| {
                std.atomic.spinLoopHint();
            }
            return 555;
        }
    }.init, &waiter);

    if (result) |value_ptr| {
        // Got value immediately (either we initialized or it was already done)
        if (value_ptr.* == 555) {
            _ = completed.fetchAdd(1, .acq_rel);
        }
    } else {
        // Wait for completion
        while (!waiter.isComplete()) {
            std.atomic.spinLoopHint();
        }
        // Now get the value
        if (cell.get()) |value_ptr| {
            if (value_ptr.* == 555) {
                _ = completed.fetchAdd(1, .acq_rel);
            }
        }
    }
}

test "OnceCell stress - with set" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var cell = OnceCell(u64).init();
    var set_successes = std.atomic.Value(usize).init(0);
    var get_successes = std.atomic.Value(usize).init(0);

    const num_setters = 20;
    const num_getters = 30;

    // Setters race to set
    for (0..num_setters) |i| {
        try scope.spawn(racingSetter, .{ &cell, @as(u64, @intCast(i)), &set_successes });
    }

    // Getters wait for value
    for (0..num_getters) |_| {
        try scope.spawn(waitingGetter, .{ &cell, &get_successes });
    }

    try scope.wait();

    // Exactly one set should succeed
    try testing.expectEqual(@as(usize, 1), set_successes.load(.acquire));

    // All getters should eventually get a value
    try testing.expectEqual(@as(usize, num_getters), get_successes.load(.acquire));
}

fn racingSetter(cell: *OnceCell(u64), value: u64, successes: *std.atomic.Value(usize)) void {
    if (cell.set(value)) {
        _ = successes.fetchAdd(1, .acq_rel);
    }
}

fn waitingGetter(cell: *OnceCell(u64), successes: *std.atomic.Value(usize)) void {
    // Spin until value is available
    while (cell.get() == null) {
        std.atomic.spinLoopHint();
    }

    if (cell.get()) |_| {
        _ = successes.fetchAdd(1, .acq_rel);
    }
}
