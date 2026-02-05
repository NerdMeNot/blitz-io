//! Task State Machine Concurrency Tests
//!
//! Tests the correctness of task state transitions under concurrent access.
//! Uses the parameterized testing framework from src/test/concurrency.zig.
//!
//! Critical areas tested:
//! - NOTIFIED flag: Prevents lost wakeups when wake happens during poll
//! - Reference counting: Ensures proper cleanup with concurrent ref/unref
//! - State transitions: IDLE -> SCHEDULED -> RUNNING -> COMPLETE

const std = @import("std");
const Allocator = std.mem.Allocator;
const blitz = @import("blitz-io");

// Import the testing framework
const concurrency = blitz.testing.concurrency;
const Config = concurrency.Config;
const ConcurrentCounter = concurrency.ConcurrentCounter;
const Barrier = concurrency.Barrier;
const ThreadRng = concurrency.ThreadRng;

// Import task types from the correct location
const Header = blitz.coroutine.Header;
const State = blitz.coroutine.State;
const Waker = blitz.executor.Waker;

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
        .schedule = scheduleImpl,
    };

    fn create(allocator: Allocator) !*TestTask {
        const self = try allocator.create(TestTask);
        self.* = .{
            .header = Header.init(&vtable),
            .allocator = allocator,
            .poll_count = std.atomic.Value(usize).init(0),
            .drop_count = std.atomic.Value(usize).init(0),
            .wake_count = std.atomic.Value(usize).init(0),
            .waker_stored = null,
        };
        return self;
    }

    fn pollImpl(header: *Header) Header.PollResult {
        const self: *TestTask = @fieldParentPtr("header", header);
        _ = self.poll_count.fetchAdd(1, .acq_rel);

        // Transition to running
        if (!header.transitionToRunning()) {
            return .pending;
        }

        // Create and store waker
        const waker = Waker.init(header);
        self.waker_stored = waker;

        // Simulate some work
        std.atomic.spinLoopHint();

        // Transition back to idle
        const prev_state = header.transitionToIdle();

        // Check NOTIFIED flag
        if (prev_state.notified) {
            _ = header.clearNotified();
            if (header.transitionToScheduled()) {
                header.schedule();
            }
        }

        return .pending; // Not complete
    }

    fn dropImpl(header: *Header) void {
        const self: *TestTask = @fieldParentPtr("header", header);
        _ = self.drop_count.fetchAdd(1, .acq_rel);

        if (self.waker_stored) |*w| {
            var waker = w.*;
            waker.drop();
        }

        self.allocator.destroy(self);
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
                        if (prev.notified) {
                            _ = ctx.notified_count.increment();
                            _ = ctx.task.header.clearNotified();
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
        // Clean up task
        if (task.header.unref()) {
            task.header.drop();
        }
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
                _ = ctx.task.header.unref();
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
    const state = State.fromU64(task.header.state.load(.acquire));
    if (state.ref_count != 1) {
        std.debug.print("Expected refcount 1, got {d}\n", .{state.ref_count});
        return error.TestFailed;
    }

    // This should trigger drop
    if (task.header.unref()) {
        task.header.drop();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 3: State Transitions Under Contention
// ─────────────────────────────────────────────────────────────────────────────

/// Test state transitions work correctly under high contention.
fn testStateTransitionsContention(config: Config, allocator: Allocator) !void {
    const Context = struct {
        headers: []Header,
        barrier: *Barrier,
        transition_count: ConcurrentCounter,

        fn worker(ctx: *@This(), tid: usize) void {
            const headers_per_thread = ctx.headers.len / 4;
            const start = tid * headers_per_thread;
            const end = @min(start + headers_per_thread, ctx.headers.len);

            // Wait for all threads
            _ = ctx.barrier.wait();

            // Perform state transitions
            for (ctx.headers[start..end]) |*h| {
                // idle -> scheduled
                if (h.transitionToScheduled()) {
                    _ = ctx.transition_count.increment();

                    // scheduled -> running
                    if (h.transitionToRunning()) {
                        _ = ctx.transition_count.increment();

                        // running -> idle
                        _ = h.transitionToIdle();
                        _ = ctx.transition_count.increment();
                    }
                }
            }
        }
    };

    const num_headers = config.task_count;
    const headers = try allocator.alloc(Header, num_headers);
    defer allocator.free(headers);

    const dummy_vtable = Header.VTable{
        .poll = struct {
            fn f(_: *Header) Header.PollResult {
                return .complete;
            }
        }.f,
        .drop = struct {
            fn f(_: *Header) void {}
        }.f,
        .schedule = struct {
            fn f(_: *Header) void {}
        }.f,
    };

    for (headers) |*h| {
        h.* = Header.init(&dummy_vtable);
    }

    var barrier = Barrier.init(4);
    var ctx = Context{
        .headers = headers,
        .barrier = &barrier,
        .transition_count = ConcurrentCounter.init(0),
    };

    try concurrency.runConcurrent(
        Context,
        Context.worker,
        &ctx,
        4,
        allocator,
    );

    // Verify some transitions occurred
    const transitions = ctx.transition_count.load();
    if (transitions == 0) {
        std.debug.print("No transitions occurred - test may be broken\n", .{});
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

test "task state - transitions under contention" {
    const configs = [_]Config{
        .{ .thread_count = 4, .task_count = 1000 },
        .{ .thread_count = 4, .task_count = 4000 },
    };
    for (configs) |config| {
        try testStateTransitionsContention(config, std.testing.allocator);
    }
}
