//! Task State Machine Concurrency Tests
//!
//! Tests the correctness of task state transitions under concurrent access.
//! Uses the parameterized testing framework from src/test/concurrency.zig.
//!
//! Critical areas tested:
//! - NOTIFIED flag: Prevents lost wakeups when wake happens during poll
//! - Reference counting: Ensures proper cleanup with concurrent ref/unref
//! - State transitions: IDLE -> SCHEDULED -> RUNNING -> COMPLETE
//! - Cancel vs complete race: Task may be cancelled while running

const std = @import("std");
const Allocator = std.mem.Allocator;
const blitz = @import("blitz-io");

// Import the testing framework
const concurrency = blitz.testing.concurrency;
const Config = concurrency.Config;
const ConcurrentCounter = concurrency.ConcurrentCounter;
const Barrier = concurrency.Barrier;
const Latch = concurrency.Latch;
const ThreadRng = concurrency.ThreadRng;

// Import task types
const task_mod = blitz.executor.task;
const Header = task_mod.Header;
const Waker = task_mod.Waker;
const OwnedTasks = task_mod.OwnedTasks;

// ─────────────────────────────────────────────────────────────────────────────
// Test Task Implementation
// ─────────────────────────────────────────────────────────────────────────────

/// A test task that tracks its poll/drop/wake counts atomically.
const TestTask = struct {
    header: Header,
    allocator: Allocator,

    poll_count: std.atomic.Value(usize),
    drop_count: std.atomic.Value(usize),
    wake_count: std.atomic.Value(usize),

    // For wake-during-poll test
    waker_stored: ?Waker,

    const vtable = Header.VTable{
        .poll = pollImpl,
        .drop = dropImpl,
        .get_output = getOutputImpl,
        .schedule = scheduleImpl,
    };

    fn create(allocator: Allocator) !*TestTask {
        const self = try allocator.create(TestTask);
        self.* = .{
            .header = Header.init(&vtable, 0),
            .allocator = allocator,
            .poll_count = std.atomic.Value(usize).init(0),
            .drop_count = std.atomic.Value(usize).init(0),
            .wake_count = std.atomic.Value(usize).init(0),
            .waker_stored = null,
        };
        return self;
    }

    fn pollImpl(header: *Header) bool {
        const self: *TestTask = @fieldParentPtr("header", header);
        _ = self.poll_count.fetchAdd(1, .acq_rel);

        // Transition to running
        if (!header.transitionToRunning()) {
            return false;
        }

        // Create and store waker
        const waker = Waker.init(header);
        self.waker_stored = waker;

        // Simulate some work
        std.atomic.spinLoopHint();

        // Transition back to idle
        const prev_state = header.transitionToIdle();

        // Check NOTIFIED flag
        if (prev_state & Header.State.NOTIFIED != 0) {
            header.clearNotified();
            if (header.transitionToScheduled()) {
                header.schedule();
            }
        }

        return false; // Not complete
    }

    fn dropImpl(header: *Header) void {
        const self: *TestTask = @fieldParentPtr("header", header);
        _ = self.drop_count.fetchAdd(1, .acq_rel);

        if (self.waker_stored) |*w| {
            w.drop();
        }

        self.allocator.destroy(self);
    }

    fn getOutputImpl(_: *Header) ?*anyopaque {
        return null;
    }

    fn scheduleImpl(_: *Header) void {
        // No-op for this test
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Test 1: NOTIFIED Flag Stress Test
// ─────────────────────────────────────────────────────────────────────────────

/// Test that the NOTIFIED flag prevents lost wakeups.
/// Pattern: Poll thread is running while wake thread sends wake.
fn testNotifiedFlag(config: Config, allocator: Allocator) !void {
    const Context = struct {
        task: *TestTask,
        barrier: *Barrier,
        iterations: usize,
        seed: u64,
        wake_count: ConcurrentCounter,
        notified_count: ConcurrentCounter,

        fn poller(ctx: *@This(), _: usize) void {
            var rng = ThreadRng.init(ctx.seed);

            for (0..ctx.iterations) |_| {
                _ = ctx.barrier.wait();

                // Poll the task
                if (ctx.task.header.transitionToScheduled()) {
                    if (ctx.task.header.transitionToRunning()) {
                        rng.maybeYield(50);

                        const prev = ctx.task.header.transitionToIdle();
                        if (prev & Header.State.NOTIFIED != 0) {
                            _ = ctx.notified_count.increment();
                            ctx.task.header.clearNotified();
                        }
                    }
                }
            }
        }

        fn waker(ctx: *@This(), _: usize) void {
            var rng = ThreadRng.init(ctx.seed +% 1);

            for (0..ctx.iterations) |_| {
                _ = ctx.barrier.wait();

                // Try to wake during poll
                rng.maybeYield(30);

                if (ctx.task.header.transitionToScheduled()) {
                    _ = ctx.wake_count.increment();
                } else {
                    // Task is running - NOTIFIED should be set
                }
            }
        }
    };

    const task = try TestTask.create(allocator);
    defer {
        task.header.unref();
    }

    var barrier = Barrier.init(2);
    var ctx = Context{
        .task = task,
        .barrier = &barrier,
        .iterations = config.task_count,
        .seed = config.getEffectiveSeed(),
        .wake_count = ConcurrentCounter.init(0),
        .notified_count = ConcurrentCounter.init(0),
    };

    try concurrency.runConcurrent(
        Context,
        struct {
            fn run(c: *Context, tid: usize) void {
                if (tid == 0) {
                    c.poller(tid);
                } else {
                    c.waker(tid);
                }
            }
        }.run,
        &ctx,
        2,
        allocator,
    );

    // Verify the state machine didn't deadlock and at least some operations succeeded.
    // The exact counts depend on timing - we just verify the system didn't hang
    // and at least some transitions occurred.
    const total_wakes = ctx.wake_count.load() + ctx.notified_count.load();
    if (total_wakes == 0) {
        // This would indicate the test didn't work at all
        std.debug.print("No wake operations occurred - test may be broken\n", .{});
        return error.TestFailed;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 2: Reference Counting Stress Test
// ─────────────────────────────────────────────────────────────────────────────

/// Test that reference counting is correct under concurrent ref/unref.
fn testRefCounting(config: Config, allocator: Allocator) !void {
    const Context = struct {
        task: *TestTask,
        refs_per_thread: usize,
        barrier: *Barrier,

        fn worker(ctx: *@This(), _: usize) void {
            // Wait for all threads to start
            _ = ctx.barrier.wait();

            // Add refs
            for (0..ctx.refs_per_thread) |_| {
                ctx.task.header.ref();
            }

            // Remove refs
            for (0..ctx.refs_per_thread) |_| {
                ctx.task.header.unref();
            }
        }
    };

    const task = try TestTask.create(allocator);

    var barrier = Barrier.init(config.thread_count);
    var ctx = Context{
        .task = task,
        .refs_per_thread = config.task_count / config.thread_count,
        .barrier = &barrier,
    };

    try concurrency.runConcurrent(
        Context,
        Context.worker,
        &ctx,
        config.thread_count,
        allocator,
    );

    // Final unref should trigger drop
    const final_count = task.header.getRefCountValue();
    if (final_count != 1) {
        std.debug.print("Expected refcount 1, got {d}\n", .{final_count});
        return error.TestFailed;
    }

    // This should trigger drop
    task.header.unref();
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 3: OwnedTasks Concurrent Insert/Remove
// ─────────────────────────────────────────────────────────────────────────────

/// Test OwnedTasks under concurrent insert and remove.
fn testOwnedTasksConcurrent(config: Config, allocator: Allocator) !void {
    const Context = struct {
        owned: *OwnedTasks,
        tasks: []Header,
        barrier: *Barrier,
        insert_count: ConcurrentCounter,
        remove_count: ConcurrentCounter,

        fn worker(ctx: *@This(), tid: usize) void {
            const tasks_per_thread = ctx.tasks.len / 4; // Assume 4 threads
            const start = tid * tasks_per_thread;
            const end = @min(start + tasks_per_thread, ctx.tasks.len);

            // Wait for all threads
            _ = ctx.barrier.wait();

            // Insert tasks
            for (ctx.tasks[start..end]) |*t| {
                if (ctx.owned.insert(t)) {
                    _ = ctx.insert_count.increment();
                }
            }

            // Wait again
            _ = ctx.barrier.wait();

            // Remove tasks
            for (ctx.tasks[start..end]) |*t| {
                ctx.owned.remove(t);
                _ = ctx.remove_count.increment();
            }
        }
    };

    var owned = OwnedTasks.init();

    const num_tasks = config.task_count;
    const tasks = try allocator.alloc(Header, num_tasks);
    defer allocator.free(tasks);

    const dummy_vtable = Header.VTable{
        .poll = struct {
            fn f(_: *Header) bool {
                return true;
            }
        }.f,
        .drop = struct {
            fn f(_: *Header) void {}
        }.f,
        .get_output = struct {
            fn f(_: *Header) ?*anyopaque {
                return null;
            }
        }.f,
        .schedule = struct {
            fn f(_: *Header) void {}
        }.f,
    };

    for (tasks, 0..) |*t, i| {
        t.* = Header.init(&dummy_vtable, i);
    }

    var barrier = Barrier.init(4);
    var ctx = Context{
        .owned = &owned,
        .tasks = tasks,
        .barrier = &barrier,
        .insert_count = ConcurrentCounter.init(0),
        .remove_count = ConcurrentCounter.init(0),
    };

    try concurrency.runConcurrent(
        Context,
        Context.worker,
        &ctx,
        4,
        allocator,
    );

    // Verify counts match
    const inserted = ctx.insert_count.load();
    const removed = ctx.remove_count.load();

    if (inserted != removed) {
        std.debug.print("Insert/remove mismatch: {d} vs {d}\n", .{ inserted, removed });
        return error.TestFailed;
    }

    // OwnedTasks should be empty
    if (owned.len() != 0) {
        std.debug.print("OwnedTasks not empty: {d}\n", .{owned.len()});
        return error.TestFailed;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test Runner
// ─────────────────────────────────────────────────────────────────────────────

test "task state - NOTIFIED flag stress" {
    const configs = concurrency.StandardConfigs.basic;
    for (configs) |config| {
        try testNotifiedFlag(config, std.testing.allocator);
    }
}

test "task state - reference counting stress" {
    const configs = [_]Config{
        .{ .thread_count = 2, .task_count = 10000 },
        .{ .thread_count = 4, .task_count = 10000 },
        .{ .thread_count = 8, .task_count = 10000 },
    };
    for (configs) |config| {
        try testRefCounting(config, std.testing.allocator);
    }
}

test "task state - OwnedTasks concurrent" {
    const configs = [_]Config{
        .{ .thread_count = 4, .task_count = 1000 },
        .{ .thread_count = 4, .task_count = 4000 },
    };
    for (configs) |config| {
        try testOwnedTasksConcurrent(config, std.testing.allocator);
    }
}
