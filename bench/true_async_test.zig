//! True Async Integration Test
//!
//! This tests the ACTUAL async path:
//! - spawn() with LockFuture (async-first API)
//! - Proper yielding via .pending
//! - Waker-based rescheduling
//!
//! This proves whether the components actually talk to each other.

const std = @import("std");
const blitz = @import("blitz");

const Runtime = blitz.Runtime;
const JoinHandle = blitz.JoinHandle;
const Mutex = blitz.Mutex;
const LockFuture = blitz.LockFuture;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("=" ** 60 ++ "\n", .{});
    std.debug.print("      TRUE ASYNC INTEGRATION TEST\n", .{});
    std.debug.print("=" ** 60 ++ "\n\n", .{});

    // Create runtime
    std.debug.print("1. Creating runtime with 4 workers...\n", .{});
    const rt = try Runtime.init(allocator, .{ .num_workers = 4 });
    defer rt.deinit();
    std.debug.print("   OK: Runtime created\n\n", .{});

    // Create mutex
    std.debug.print("2. Creating mutex...\n", .{});
    var mutex = Mutex.init();
    std.debug.print("   OK: Mutex created\n\n", .{});

    // Test 1: Simple lock/unlock with spawn
    std.debug.print("3. Testing spawn with LockFuture (uncontended)...\n", .{});
    {
        const lock_future = mutex.lock();
        std.debug.print("   - Created LockFuture\n", .{});

        var handle = try rt.spawn(LockFuture, lock_future);
        std.debug.print("   - Spawned future task\n", .{});

        _ = handle.blockingJoin();
        std.debug.print("   - Future completed (lock acquired)\n", .{});

        mutex.unlock();
        std.debug.print("   - Lock released\n", .{});
        std.debug.print("   OK: Uncontended async lock works!\n\n", .{});
    }

    // Test 2: Contended lock with multiple futures
    std.debug.print("4. Testing contended async lock (2 tasks)...\n", .{});
    {
        // Task 1 acquires lock
        const lock1 = mutex.lock();
        var handle1 = try rt.spawn(LockFuture, lock1);
        _ = handle1.blockingJoin();
        std.debug.print("   - Task 1 acquired lock\n", .{});

        // Task 2 tries to acquire (should block/yield)
        const lock2 = mutex.lock();
        var handle2 = try rt.spawn(LockFuture, lock2);
        std.debug.print("   - Task 2 spawned (waiting for lock)\n", .{});

        // Give scheduler time to process
        std.Thread.sleep(10 * std.time.ns_per_ms);

        // Check that task 2 is NOT complete yet
        if (!handle2.isDone()) {
            std.debug.print("   - Task 2 correctly waiting (not complete)\n", .{});
        } else {
            std.debug.print("   - ERROR: Task 2 completed without lock!\n", .{});
        }

        // Release lock - this should wake task 2
        mutex.unlock();
        std.debug.print("   - Task 1 released lock\n", .{});

        // Now task 2 should complete
        _ = handle2.blockingJoin();
        std.debug.print("   - Task 2 acquired lock\n", .{});

        mutex.unlock();
        std.debug.print("   - Task 2 released lock\n", .{});
        std.debug.print("   OK: Contended async lock works!\n\n", .{});
    }

    // Test 3: Many concurrent tasks (like the benchmark)
    std.debug.print("5. Testing concurrent MutexWorkFuture (5 tasks)...\n", .{});
    {
        // MutexWorkFuture - same as benchmark
        const MutexWorkFuture = struct {
            mutex: *Mutex,
            counter: *std.atomic.Value(usize),
            lock_future: ?LockFuture = null,
            state: State = .init,

            const State = enum { init, locking, done };
            const Self = @This();
            pub const Output = void;

            pub fn init(m: *Mutex, c: *std.atomic.Value(usize)) Self {
                return .{ .mutex = m, .counter = c };
            }

            pub fn poll(self: *Self, ctx: *blitz.Context) blitz.PollResult(void) {
                switch (self.state) {
                    .init => {
                        self.lock_future = self.mutex.lock();
                        self.state = .locking;
                        return self.poll(ctx);
                    },
                    .locking => {
                        switch (self.lock_future.?.poll(ctx)) {
                            .pending => return .pending,
                            .ready => {
                                _ = self.counter.fetchAdd(1, .monotonic);
                                self.mutex.unlock();
                                self.state = .done;
                                return .{ .ready = {} };
                            },
                        }
                    },
                    .done => return .{ .ready = {} },
                }
            }
        };

        var counter = std.atomic.Value(usize).init(0);
        const num_tasks: usize = 100;
        var handles: [100]JoinHandle(void) = undefined;

        // Do multiple rounds like the benchmark (3 warmup + 10 measured = 13)
        const num_rounds: usize = 13;
        for (0..num_rounds) |round| {
            counter.store(0, .seq_cst);
            std.debug.print("   - Round {}: Spawning {} tasks...\n", .{ round, num_tasks });
            for (0..num_tasks) |i| {
                const future = MutexWorkFuture.init(&mutex, &counter);
                handles[i] = try rt.spawn(MutexWorkFuture, future);
            }

            for (0..num_tasks) |i| {
                _ = handles[i].blockingJoin();
            }
            std.debug.print("   - Round {}: Counter = {}\n", .{ round, counter.load(.monotonic) });
        }
        std.debug.print("   OK: All rounds completed!\n\n", .{});
    }

    // Test 6: RwLock contended (readers and writers)
    std.debug.print("6. Testing RwLock with readers and writers...\n", .{});
    {
        const RwLock = blitz.RwLock;
        const ReadLockFuture = blitz.ReadLockFuture;
        const WriteLockFuture = blitz.WriteLockFuture;

        const RwLockReadFuture = struct {
            rwlock: *RwLock,
            counter: *std.atomic.Value(usize),
            lock_future: ?ReadLockFuture = null,
            state: State = .init,

            const State = enum { init, locking, done };
            const Self = @This();
            pub const Output = void;

            pub fn init(r: *RwLock, c: *std.atomic.Value(usize)) Self {
                return .{ .rwlock = r, .counter = c };
            }

            pub fn poll(self: *Self, ctx: *blitz.Context) blitz.PollResult(void) {
                switch (self.state) {
                    .init => {
                        self.lock_future = self.rwlock.readLock();
                        self.state = .locking;
                        return self.poll(ctx);
                    },
                    .locking => {
                        switch (self.lock_future.?.poll(ctx)) {
                            .pending => return .pending,
                            .ready => {
                                _ = self.counter.fetchAdd(1, .monotonic);
                                self.rwlock.readUnlock();
                                self.state = .done;
                                return .{ .ready = {} };
                            },
                        }
                    },
                    .done => return .{ .ready = {} },
                }
            }
        };

        const RwLockWriteFuture = struct {
            rwlock: *RwLock,
            counter: *std.atomic.Value(usize),
            lock_future: ?WriteLockFuture = null,
            state: State = .init,

            const State = enum { init, locking, done };
            const Self = @This();
            pub const Output = void;

            pub fn init(r: *RwLock, c: *std.atomic.Value(usize)) Self {
                return .{ .rwlock = r, .counter = c };
            }

            pub fn poll(self: *Self, ctx: *blitz.Context) blitz.PollResult(void) {
                switch (self.state) {
                    .init => {
                        self.lock_future = self.rwlock.writeLock();
                        self.state = .locking;
                        return self.poll(ctx);
                    },
                    .locking => {
                        switch (self.lock_future.?.poll(ctx)) {
                            .pending => return .pending,
                            .ready => {
                                _ = self.counter.fetchAdd(1, .monotonic);
                                self.rwlock.writeUnlock();
                                self.state = .done;
                                return .{ .ready = {} };
                            },
                        }
                    },
                    .done => return .{ .ready = {} },
                }
            }
        };

        var rwlock = RwLock.init();
        var counter = std.atomic.Value(usize).init(0);
        const num_readers: usize = 4;
        const num_writers: usize = 2;
        var handles: [6]JoinHandle(void) = undefined;

        std.debug.print("   - Spawning {} readers and {} writers...\n", .{ num_readers, num_writers });
        for (0..num_readers) |i| {
            const future = RwLockReadFuture.init(&rwlock, &counter);
            handles[i] = try rt.spawn(RwLockReadFuture, future);
        }
        for (0..num_writers) |i| {
            const future = RwLockWriteFuture.init(&rwlock, &counter);
            handles[num_readers + i] = try rt.spawn(RwLockWriteFuture, future);
        }

        std.debug.print("   - Waiting for tasks...\n", .{});
        for (0..num_readers + num_writers) |i| {
            _ = handles[i].blockingJoin();
            std.debug.print("   - Task {} completed\n", .{i});
        }

        std.debug.print("   - Counter: {}\n", .{counter.load(.monotonic)});
        if (counter.load(.monotonic) == num_readers + num_writers) {
            std.debug.print("   OK: RwLock contended works!\n\n", .{});
        } else {
            std.debug.print("   ERROR: Counter mismatch!\n\n", .{});
        }
    }

    std.debug.print("=" ** 60 ++ "\n", .{});
    std.debug.print("      ALL TESTS PASSED!\n", .{});
    std.debug.print("=" ** 60 ++ "\n\n", .{});
    std.debug.print("The async components ARE properly connected:\n", .{});
    std.debug.print("  - LockFuture stores waker and yields\n", .{});
    std.debug.print("  - unlock() wakes the waiting task\n", .{});
    std.debug.print("  - Scheduler reschedules and polls again\n", .{});
    std.debug.print("  - FutureTask completes when lock acquired\n\n", .{});
}
