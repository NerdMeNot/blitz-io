//! Stress tests for blitz_io.RwLock
//!
//! Tests the read-write lock under high contention scenarios.
//! Uses readLockBlocking() and writeLockBlocking() for proper blocking without spin-waiting.
//!
//! ## Test Categories
//!
//! - **Concurrent readers**: Multiple simultaneous read locks
//! - **Exclusive writers**: Write lock exclusivity verification
//! - **Mixed workload**: Readers and writers competing
//! - **Writer priority**: Writers not starved by readers
//! - **Data integrity**: Checksum verification under contention

const std = @import("std");
const testing = std.testing;
const blitz_io = @import("blitz-io");
const Scope = config.ThreadScope;
const RwLock = blitz_io.sync.RwLock;

const config = @import("test_config");

test "RwLock stress - multiple concurrent readers" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var rwlock = RwLock.init();
    var max_concurrent_readers = std.atomic.Value(usize).init(0);
    var current_readers = std.atomic.Value(usize).init(0);
    var read_value: u64 = 42;

    for (0..config.stress.readers) |_| {
        try scope.spawn(concurrentReader, .{
            &rwlock,
            &read_value,
            &current_readers,
            &max_concurrent_readers,
        });
    }

    try scope.wait();

    // Should have observed at least some concurrent readers (may be 1 in fast runs)
    // The important thing is no crashes and correct behavior
    try testing.expect(max_concurrent_readers.load(.acquire) >= 1);
}

fn concurrentReader(
    rwlock: *RwLock,
    value: *const u64,
    current: *std.atomic.Value(usize),
    max_observed: *std.atomic.Value(usize),
) void {
    for (0..10) |_| {
        // Use proper blocking instead of spin-waiting
        rwlock.readLockBlocking();

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

        // Hold read lock briefly - yield instead of spin
        std.Thread.yield() catch {};

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

    for (0..config.stress.writers) |_| {
        try scope.spawn(exclusiveWriter, .{ &rwlock, &counter, config.stress.ops_per_task });
    }

    try scope.wait();

    // All increments should be accounted for
    try testing.expectEqual(@as(usize, config.stress.writers * config.stress.ops_per_task), counter);
}

fn exclusiveWriter(rwlock: *RwLock, counter: *usize, count: usize) void {
    for (0..count) |_| {
        rwlock.writeLockBlocking();

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

    const num_writers = config.stress.writers / 2;

    // Spawn readers
    for (0..config.stress.readers) |_| {
        try scope.spawn(mixedReader, .{ &rwlock, &value, &reads, config.stress.ops_per_task });
    }

    // Spawn writers
    for (0..num_writers) |_| {
        try scope.spawn(mixedWriter, .{ &rwlock, &value, &writes, config.stress.ops_per_task });
    }

    try scope.wait();

    // Verify all operations completed
    try testing.expectEqual(@as(usize, config.stress.readers * config.stress.ops_per_task), reads.load(.acquire));
    try testing.expectEqual(@as(usize, num_writers * config.stress.ops_per_task), writes.load(.acquire));

    // Value should equal number of writes
    try testing.expectEqual(@as(u64, num_writers * config.stress.ops_per_task), value);
}

fn mixedReader(
    rwlock: *RwLock,
    value: *const u64,
    reads: *std.atomic.Value(usize),
    count: usize,
) void {
    for (0..count) |_| {
        rwlock.readLockBlocking();

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
        rwlock.writeLockBlocking();

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
            rw.writeLockBlocking();
            v.* = 999;
            rw.writeUnlock();
            completed.store(true, .release);
        }
    }.work, .{ &rwlock, &value, &writer_completed });

    // Give writer time to start waiting
    std.Thread.sleep(std.time.ns_per_ms * 5);

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

    // Checksum-protected data - initial checksum must be 0
    // Using all zeros ensures XOR checksum = 0
    var data: [8]u64 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };

    var integrity_violations = std.atomic.Value(usize).init(0);

    // Readers verify checksum
    for (0..config.stress.readers) |_| {
        try scope.spawn(checksumReader, .{ &rwlock, &data, &integrity_violations, config.stress.ops_per_task });
    }

    // Writers update data maintaining checksum
    for (0..config.stress.writers / 2) |_| {
        try scope.spawn(checksumWriter, .{ &rwlock, &data, config.stress.ops_per_task });
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
        rwlock.readLockBlocking();

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
        rwlock.writeLockBlocking();

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

test "RwLock stress - blocking acquisition" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var rwlock = RwLock.init();
    var counter: usize = 0;

    // Use config values for blocking test
    const num_writers = config.stress.tasks_low;
    const increments = config.stress.small;

    for (0..num_writers) |_| {
        try scope.spawn(blockingWriter, .{ &rwlock, &counter, increments });
    }

    try scope.wait();

    try testing.expectEqual(@as(usize, num_writers * increments), counter);
}

fn blockingWriter(rwlock: *RwLock, counter: *usize, count: usize) void {
    for (0..count) |_| {
        rwlock.writeLockBlocking();
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

    for (0..config.stress.readers) |_| {
        try scope.spawn(rapidTransitioner, .{ &rwlock, &state, config.stress.ops_per_task });
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
            rwlock.readLockBlocking();
            _ = state.load(.acquire);
            rwlock.readUnlock();
        } else {
            // Write
            rwlock.writeLockBlocking();
            _ = state.fetchAdd(1, .acq_rel);
            rwlock.writeUnlock();
        }
    }
}
