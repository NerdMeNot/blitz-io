//! Stress tests for blitz_io.RwLock
//!
//! Tests the read-write lock under high contention scenarios.

const std = @import("std");
const testing = std.testing;
const blitz_io = @import("blitz-io");
const Scope = blitz_io.Scope;
const RwLock = blitz_io.sync.RwLock;
const WriteWaiter = blitz_io.sync.WriteWaiter;

test "RwLock stress - multiple concurrent readers" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var rwlock = RwLock.init();
    var max_concurrent_readers = std.atomic.Value(usize).init(0);
    var current_readers = std.atomic.Value(usize).init(0);
    var read_value: u64 = 42;

    const num_readers = 50;

    for (0..num_readers) |_| {
        try scope.spawn(concurrentReader, .{
            &rwlock,
            &read_value,
            &current_readers,
            &max_concurrent_readers,
        });
    }

    try scope.wait();

    // Should have observed multiple concurrent readers
    try testing.expect(max_concurrent_readers.load(.acquire) > 1);
}

fn concurrentReader(
    rwlock: *RwLock,
    value: *const u64,
    current: *std.atomic.Value(usize),
    max_observed: *std.atomic.Value(usize),
) void {
    for (0..10) |_| {
        while (!rwlock.tryReadLock()) {
            std.atomic.spinLoopHint();
        }

        // Track concurrent readers
        const now_reading = current.fetchAdd(1, .acq_rel) + 1;

        // Update max
        var max = max_observed.load(.acquire);
        while (now_reading > max) {
            const result = max_observed.cmpxchgWeak(max, now_reading, .acq_rel, .acquire);
            if (result) |actual| {
                max = actual;
            } else {
                break;
            }
        }

        // Read the value (verify it's consistent)
        _ = value.*;

        // Hold read lock briefly
        for (0..50) |_| {
            std.atomic.spinLoopHint();
        }

        _ = current.fetchSub(1, .acq_rel);
        rwlock.readUnlock();
    }
}

test "RwLock stress - exclusive write access" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var rwlock = RwLock.init();
    var counter: usize = 0;

    const num_writers = 20;
    const increments = 100;

    for (0..num_writers) |_| {
        try scope.spawn(exclusiveWriter, .{ &rwlock, &counter, increments });
    }

    try scope.wait();

    // All increments should be accounted for
    try testing.expectEqual(@as(usize, num_writers * increments), counter);
}

fn exclusiveWriter(rwlock: *RwLock, counter: *usize, count: usize) void {
    for (0..count) |_| {
        while (!rwlock.tryWriteLock()) {
            std.atomic.spinLoopHint();
        }

        // Critical section
        counter.* += 1;

        rwlock.writeUnlock();
    }
}

test "RwLock stress - readers and writers mixed" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var rwlock = RwLock.init();
    var value: u64 = 0;
    var reads = std.atomic.Value(usize).init(0);
    var writes = std.atomic.Value(usize).init(0);

    const num_readers = 20;
    const num_writers = 5;
    const ops_per_task = 100;

    // Spawn readers
    for (0..num_readers) |_| {
        try scope.spawn(mixedReader, .{ &rwlock, &value, &reads, ops_per_task });
    }

    // Spawn writers
    for (0..num_writers) |_| {
        try scope.spawn(mixedWriter, .{ &rwlock, &value, &writes, ops_per_task });
    }

    try scope.wait();

    // Verify all operations completed
    try testing.expectEqual(@as(usize, num_readers * ops_per_task), reads.load(.acquire));
    try testing.expectEqual(@as(usize, num_writers * ops_per_task), writes.load(.acquire));

    // Value should equal number of writes
    try testing.expectEqual(@as(u64, num_writers * ops_per_task), value);
}

fn mixedReader(
    rwlock: *RwLock,
    value: *const u64,
    reads: *std.atomic.Value(usize),
    count: usize,
) void {
    for (0..count) |_| {
        while (!rwlock.tryReadLock()) {
            std.atomic.spinLoopHint();
        }

        // Read (just access the value)
        _ = value.*;
        _ = reads.fetchAdd(1, .acq_rel);

        rwlock.readUnlock();
    }
}

fn mixedWriter(
    rwlock: *RwLock,
    value: *u64,
    writes: *std.atomic.Value(usize),
    count: usize,
) void {
    for (0..count) |_| {
        while (!rwlock.tryWriteLock()) {
            std.atomic.spinLoopHint();
        }

        // Write
        value.* += 1;
        _ = writes.fetchAdd(1, .acq_rel);

        rwlock.writeUnlock();
    }
}

test "RwLock stress - writer priority" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var rwlock = RwLock.init();
    var value: u64 = 0;
    var writer_completed = std.atomic.Value(bool).init(false);

    // Take read lock first
    try testing.expect(rwlock.tryReadLock());

    // Spawn a writer that will wait
    try scope.spawn(struct {
        fn work(rw: *RwLock, v: *u64, completed: *std.atomic.Value(bool)) void {
            while (!rw.tryWriteLock()) {
                std.atomic.spinLoopHint();
            }
            v.* = 999;
            rw.writeUnlock();
            completed.store(true, .release);
        }
    }.work, .{ &rwlock, &value, &writer_completed });

    // Give writer time to start waiting
    std.time.sleep(std.time.ns_per_ms * 5);

    // Writer should not have completed yet
    try testing.expect(!writer_completed.load(.acquire));

    // Release read lock
    rwlock.readUnlock();

    // Wait for completion
    try scope.wait();

    // Writer should have completed
    try testing.expect(writer_completed.load(.acquire));
    try testing.expectEqual(@as(u64, 999), value);
}

test "RwLock stress - data integrity under contention" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var rwlock = RwLock.init();

    // Checksum-protected data
    var data: [8]u64 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };

    const num_readers = 30;
    const num_writers = 5;
    const ops_per_task = 100;

    var integrity_violations = std.atomic.Value(usize).init(0);

    // Readers verify checksum
    for (0..num_readers) |_| {
        try scope.spawn(checksumReader, .{ &rwlock, &data, &integrity_violations, ops_per_task });
    }

    // Writers update data maintaining checksum
    for (0..num_writers) |_| {
        try scope.spawn(checksumWriter, .{ &rwlock, &data, ops_per_task });
    }

    try scope.wait();

    // Should have no integrity violations
    try testing.expectEqual(@as(usize, 0), integrity_violations.load(.acquire));
}

fn computeChecksum(data: *const [8]u64) u64 {
    var sum: u64 = 0;
    for (data) |v| {
        sum ^= v;
    }
    return sum;
}

fn checksumReader(
    rwlock: *RwLock,
    data: *const [8]u64,
    violations: *std.atomic.Value(usize),
    count: usize,
) void {
    for (0..count) |_| {
        while (!rwlock.tryReadLock()) {
            std.atomic.spinLoopHint();
        }

        // Read and verify checksum
        const checksum = computeChecksum(data);
        if (checksum != 0) {
            // Writers maintain checksum = 0, so any non-zero is a violation
            // (This detects torn reads)
            _ = violations.fetchAdd(1, .acq_rel);
        }

        rwlock.readUnlock();
    }
}

fn checksumWriter(
    rwlock: *RwLock,
    data: *[8]u64,
    count: usize,
) void {
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const random = prng.random();

    for (0..count) |_| {
        while (!rwlock.tryWriteLock()) {
            std.atomic.spinLoopHint();
        }

        // Update data while maintaining checksum = 0
        // Change a random element and adjust last element to maintain checksum
        const idx = random.intRangeAtMost(usize, 0, 6);
        const old_value = data[idx];
        const new_value = random.int(u64);

        data[idx] = new_value;
        // Adjust last element to maintain checksum = 0
        data[7] ^= old_value ^ new_value;

        rwlock.writeUnlock();
    }
}

test "RwLock stress - waiter-based acquisition" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var rwlock = RwLock.init();
    var counter: usize = 0;

    const num_writers = 30;
    const increments = 20;

    for (0..num_writers) |_| {
        try scope.spawn(waiterWriter, .{ &rwlock, &counter, increments });
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_writers * increments), counter);
}

fn waiterWriter(rwlock: *RwLock, counter: *usize, count: usize) void {
    for (0..count) |_| {
        var waiter = WriteWaiter.init();

        if (!rwlock.writeLock(&waiter)) {
            while (!waiter.isAcquired()) {
                std.atomic.spinLoopHint();
            }
        }

        counter.* += 1;
        rwlock.writeUnlock();
    }
}

test "RwLock stress - rapid read/write transitions" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var rwlock = RwLock.init();
    var state = std.atomic.Value(u64).init(0);

    const num_tasks = 20;
    const transitions = 100;

    for (0..num_tasks) |_| {
        try scope.spawn(rapidTransitioner, .{ &rwlock, &state, transitions });
    }

    try scope.wait();

    // Just verify no crashes/deadlocks - state value doesn't matter
    try testing.expect(state.load(.acquire) >= 0);
}

fn rapidTransitioner(
    rwlock: *RwLock,
    state: *std.atomic.Value(u64),
    count: usize,
) void {
    var prng = std.Random.DefaultPrng.init(@intCast(@intFromPtr(state)));
    const random = prng.random();

    for (0..count) |_| {
        if (random.boolean()) {
            // Read
            while (!rwlock.tryReadLock()) {
                std.atomic.spinLoopHint();
            }
            _ = state.load(.acquire);
            rwlock.readUnlock();
        } else {
            // Write
            while (!rwlock.tryWriteLock()) {
                std.atomic.spinLoopHint();
            }
            _ = state.fetchAdd(1, .acq_rel);
            rwlock.writeUnlock();
        }
    }
}
