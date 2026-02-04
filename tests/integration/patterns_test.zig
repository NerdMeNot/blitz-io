//! Real-World Patterns Tests
//!
//! Tests demonstrating common async programming patterns using blitz-io primitives:
//! - Fan-out/fan-in (scatter-gather)
//! - Producer/consumer with channels
//! - Worker pool
//! - Rate limiting with semaphores
//! - Circuit breaker
//! - Retry with exponential backoff
//! - Request timeout

const std = @import("std");
const testing = std.testing;
const Thread = std.Thread;
const Atomic = std.atomic.Value;

const blitz_io = @import("blitz-io");
const Channel = blitz_io.sync.Channel;
const Semaphore = blitz_io.sync.Semaphore;
const Mutex = blitz_io.sync.Mutex;

// ═══════════════════════════════════════════════════════════════════════════════
// Pattern 1: Fan-Out/Fan-In (Scatter-Gather)
// ═══════════════════════════════════════════════════════════════════════════════

test "Pattern - fan-out/fan-in scatter gather" {
    // Simulate parallel "HTTP" calls by spawning multiple workers
    // that each compute a result, then gather all results
    const NUM_WORKERS = 5;

    var results: [NUM_WORKERS]Atomic(i32) = undefined;
    var completed = Atomic(u32).init(0);

    for (&results) |*r| {
        r.* = Atomic(i32).init(0);
    }

    // Fan-out: spawn workers
    var threads: [NUM_WORKERS]Thread = undefined;
    for (0..NUM_WORKERS) |i| {
        threads[i] = try Thread.spawn(.{}, struct {
            fn work(idx: usize, res: *Atomic(i32), done: *Atomic(u32)) void {
                // Simulate work with different latencies
                Thread.sleep((idx + 1) * 10 * std.time.ns_per_ms);

                // Store result (e.g., "fetched" data)
                res.store(@intCast((idx + 1) * 10), .release);
                _ = done.fetchAdd(1, .release);
            }
        }.work, .{ i, &results[i], &completed });
    }

    // Fan-in: wait for all workers
    for (&threads) |*t| {
        t.join();
    }

    // Verify all completed
    try testing.expectEqual(@as(u32, NUM_WORKERS), completed.load(.acquire));

    // Aggregate results
    var total: i32 = 0;
    for (&results) |*r| {
        total += r.load(.acquire);
    }

    // Expected: 10 + 20 + 30 + 40 + 50 = 150
    try testing.expectEqual(@as(i32, 150), total);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Pattern 2: Producer/Consumer with Channel
// ═══════════════════════════════════════════════════════════════════════════════

test "Pattern - producer consumer with channel" {
    const NUM_ITEMS = 100;

    var channel = try Channel(u32).init(testing.allocator, 10);
    defer channel.deinit();

    var produced = Atomic(u32).init(0);
    var consumed = Atomic(u32).init(0);
    var sum_produced = Atomic(u64).init(0);
    var sum_consumed = Atomic(u64).init(0);

    // Producer thread
    const producer = try Thread.spawn(.{}, struct {
        fn run(ch: *Channel(u32), count: *Atomic(u32), sum: *Atomic(u64)) void {
            for (0..NUM_ITEMS) |i| {
                const value: u32 = @intCast(i);

                // Keep trying until sent
                while (true) {
                    switch (ch.trySend(value)) {
                        .ok => {
                            _ = count.fetchAdd(1, .monotonic);
                            _ = sum.fetchAdd(value, .monotonic);
                            break;
                        },
                        .full => {
                            Thread.sleep(1 * std.time.ns_per_ms);
                        },
                        .closed => return,
                    }
                }
            }

            // Signal done by closing
            ch.close();
        }
    }.run, .{ &channel, &produced, &sum_produced });

    // Consumer thread
    const consumer = try Thread.spawn(.{}, struct {
        fn run(ch: *Channel(u32), count: *Atomic(u32), sum: *Atomic(u64)) void {
            while (true) {
                switch (ch.tryRecv()) {
                    .value => |v| {
                        _ = count.fetchAdd(1, .monotonic);
                        _ = sum.fetchAdd(v, .monotonic);
                    },
                    .empty => {
                        Thread.sleep(1 * std.time.ns_per_ms);
                    },
                    .closed => return,
                }
            }
        }
    }.run, .{ &channel, &consumed, &sum_consumed });

    producer.join();
    consumer.join();

    try testing.expectEqual(@as(u32, NUM_ITEMS), produced.load(.acquire));
    try testing.expectEqual(@as(u32, NUM_ITEMS), consumed.load(.acquire));
    try testing.expectEqual(sum_produced.load(.acquire), sum_consumed.load(.acquire));
}

// ═══════════════════════════════════════════════════════════════════════════════
// Pattern 3: Worker Pool
// ═══════════════════════════════════════════════════════════════════════════════

test "Pattern - worker pool" {
    const NUM_WORKERS = 4;
    const NUM_TASKS = 20;

    // Task channel (job queue)
    var task_queue = try Channel(u32).init(testing.allocator, NUM_TASKS);
    defer task_queue.deinit();

    // Results
    var results_processed = Atomic(u32).init(0);
    var shutdown = Atomic(bool).init(false);

    // Start worker threads
    var workers: [NUM_WORKERS]Thread = undefined;
    for (0..NUM_WORKERS) |i| {
        workers[i] = try Thread.spawn(.{}, struct {
            fn work(queue: *Channel(u32), processed: *Atomic(u32), done: *Atomic(bool)) void {
                while (!done.load(.acquire)) {
                    switch (queue.tryRecv()) {
                        .value => |task_id| {
                            // Simulate processing
                            Thread.sleep(5 * std.time.ns_per_ms);
                            _ = task_id; // Use task_id
                            _ = processed.fetchAdd(1, .release);
                        },
                        .empty => {
                            Thread.sleep(1 * std.time.ns_per_ms);
                        },
                        .closed => return,
                    }
                }
            }
        }.work, .{ &task_queue, &results_processed, &shutdown });
    }

    // Submit tasks
    for (0..NUM_TASKS) |i| {
        while (task_queue.trySend(@intCast(i)) == .full) {
            Thread.sleep(1 * std.time.ns_per_ms);
        }
    }

    // Wait for all tasks to be processed
    for (0..500) |_| {
        if (results_processed.load(.acquire) >= NUM_TASKS) break;
        Thread.sleep(10 * std.time.ns_per_ms);
    }

    // Shutdown workers
    shutdown.store(true, .release);
    task_queue.close();

    for (&workers) |*w| {
        w.join();
    }

    try testing.expectEqual(@as(u32, NUM_TASKS), results_processed.load(.acquire));
}

// ═══════════════════════════════════════════════════════════════════════════════
// Pattern 4: Rate Limiter with Semaphore
// ═══════════════════════════════════════════════════════════════════════════════

test "Pattern - rate limiter with semaphore" {
    const MAX_CONCURRENT = 3;
    const NUM_REQUESTS = 10;

    var sem = Semaphore.init(MAX_CONCURRENT);
    var concurrent_count = Atomic(u32).init(0);
    var max_concurrent_seen = Atomic(u32).init(0);
    var completed = Atomic(u32).init(0);

    // Spawn request threads
    var threads: [NUM_REQUESTS]Thread = undefined;
    for (0..NUM_REQUESTS) |i| {
        threads[i] = try Thread.spawn(.{}, struct {
            fn request(s: *Semaphore, concurrent: *Atomic(u32), max_seen: *Atomic(u32), done: *Atomic(u32)) void {
                // Acquire permit (rate limit)
                while (!s.tryAcquire(1)) {
                    Thread.sleep(1 * std.time.ns_per_ms);
                }

                // Track concurrent requests
                const current = concurrent.fetchAdd(1, .acq_rel) + 1;

                // Update max seen
                var max = max_seen.load(.acquire);
                while (current > max) {
                    if (max_seen.cmpxchgWeak(max, current, .release, .acquire)) |old| {
                        max = old;
                    } else {
                        break;
                    }
                }

                // Simulate request processing
                Thread.sleep(20 * std.time.ns_per_ms);

                // Release
                _ = concurrent.fetchSub(1, .release);
                s.release(1);
                _ = done.fetchAdd(1, .release);
            }
        }.request, .{ &sem, &concurrent_count, &max_concurrent_seen, &completed });
    }

    // Wait for all requests
    for (&threads) |*t| {
        t.join();
    }

    try testing.expectEqual(@as(u32, NUM_REQUESTS), completed.load(.acquire));
    // Max concurrent should never exceed the limit
    try testing.expect(max_concurrent_seen.load(.acquire) <= MAX_CONCURRENT);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Pattern 5: Circuit Breaker
// ═══════════════════════════════════════════════════════════════════════════════

const CircuitBreaker = struct {
    state: Atomic(u8),
    failure_count: Atomic(u32),
    last_failure_time: Atomic(i64),
    threshold: u32,
    reset_timeout_ms: i64,

    const State = enum(u8) {
        closed = 0, // Normal operation
        open = 1, // Failing, reject requests
        half_open = 2, // Testing if recovered
    };

    fn init(threshold: u32, reset_timeout_ms: i64) CircuitBreaker {
        return .{
            .state = Atomic(u8).init(@intFromEnum(State.closed)),
            .failure_count = Atomic(u32).init(0),
            .last_failure_time = Atomic(i64).init(0),
            .threshold = threshold,
            .reset_timeout_ms = reset_timeout_ms,
        };
    }

    fn canExecute(self: *CircuitBreaker) bool {
        const state: State = @enumFromInt(self.state.load(.acquire));

        switch (state) {
            .closed => return true,
            .open => {
                // Check if enough time has passed to try again
                const now = std.time.milliTimestamp();
                const last = self.last_failure_time.load(.acquire);
                if (now - last > self.reset_timeout_ms) {
                    // Transition to half-open
                    self.state.store(@intFromEnum(State.half_open), .release);
                    return true;
                }
                return false;
            },
            .half_open => return true,
        }
    }

    fn recordSuccess(self: *CircuitBreaker) void {
        const state: State = @enumFromInt(self.state.load(.acquire));
        if (state == .half_open) {
            // Recovery successful, close circuit
            self.state.store(@intFromEnum(State.closed), .release);
            self.failure_count.store(0, .release);
        }
    }

    fn recordFailure(self: *CircuitBreaker) void {
        const new_count = self.failure_count.fetchAdd(1, .acq_rel) + 1;
        self.last_failure_time.store(std.time.milliTimestamp(), .release);

        if (new_count >= self.threshold) {
            self.state.store(@intFromEnum(State.open), .release);
        }
    }
};

test "Pattern - circuit breaker" {
    var breaker = CircuitBreaker.init(3, 100); // 3 failures, 100ms reset

    // Initially closed, can execute
    try testing.expect(breaker.canExecute());

    // Record failures up to threshold
    breaker.recordFailure();
    try testing.expect(breaker.canExecute());
    breaker.recordFailure();
    try testing.expect(breaker.canExecute());
    breaker.recordFailure(); // Third failure trips the breaker

    // Now open, cannot execute
    try testing.expect(!breaker.canExecute());

    // Wait for reset timeout
    Thread.sleep(150 * std.time.ns_per_ms);

    // Should be half-open now, can try
    try testing.expect(breaker.canExecute());

    // Success closes the circuit
    breaker.recordSuccess();
    try testing.expect(breaker.canExecute());

    // Verify state is closed
    const state: CircuitBreaker.State = @enumFromInt(breaker.state.load(.acquire));
    try testing.expectEqual(CircuitBreaker.State.closed, state);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Pattern 6: Retry with Exponential Backoff
// ═══════════════════════════════════════════════════════════════════════════════

fn retryWithBackoff(
    comptime max_retries: u32,
    comptime base_delay_ms: u64,
    operation: *const fn () error{TransientError}!u32,
) !u32 {
    var delay_ms = base_delay_ms;

    for (0..max_retries) |attempt| {
        if (operation()) |result| {
            return result;
        } else |err| {
            if (attempt + 1 >= max_retries) {
                return err;
            }

            // Exponential backoff
            Thread.sleep(delay_ms * std.time.ns_per_ms);
            delay_ms *= 2;
        }
    }

    return error.TransientError;
}

test "Pattern - retry with exponential backoff" {
    // Counter to track attempts
    var attempts = Atomic(u32).init(0);

    // Operation that fails first 2 times, succeeds on 3rd
    const operation = struct {
        var counter: *Atomic(u32) = undefined;

        fn init(c: *Atomic(u32)) void {
            counter = c;
        }

        fn call() error{TransientError}!u32 {
            const n = counter.fetchAdd(1, .monotonic);
            if (n < 2) {
                return error.TransientError;
            }
            return 42; // Success on 3rd attempt
        }
    };

    operation.init(&attempts);

    const result = try retryWithBackoff(5, 10, operation.call);

    try testing.expectEqual(@as(u32, 42), result);
    try testing.expectEqual(@as(u32, 3), attempts.load(.acquire)); // Took 3 attempts
}

test "Pattern - retry exhausted" {
    var attempts = Atomic(u32).init(0);

    // Operation that always fails
    const operation = struct {
        var counter: *Atomic(u32) = undefined;

        fn init(c: *Atomic(u32)) void {
            counter = c;
        }

        fn call() error{TransientError}!u32 {
            _ = counter.fetchAdd(1, .monotonic);
            return error.TransientError;
        }
    };

    operation.init(&attempts);

    const result = retryWithBackoff(3, 5, operation.call);

    try testing.expectError(error.TransientError, result);
    try testing.expectEqual(@as(u32, 3), attempts.load(.acquire)); // All 3 attempts made
}

// ═══════════════════════════════════════════════════════════════════════════════
// Pattern 7: Request Timeout
// ═══════════════════════════════════════════════════════════════════════════════

test "Pattern - request timeout success" {
    var result = Atomic(u32).init(0);
    var completed = Atomic(bool).init(false);
    var timed_out = Atomic(bool).init(false);

    const TIMEOUT_MS = 100;

    // Worker thread (completes quickly)
    const worker = try Thread.spawn(.{}, struct {
        fn work(res: *Atomic(u32), done: *Atomic(bool)) void {
            Thread.sleep(20 * std.time.ns_per_ms); // Fast operation
            res.store(42, .release);
            done.store(true, .release);
        }
    }.work, .{ &result, &completed });

    // Timeout thread
    const timeout = try Thread.spawn(.{}, struct {
        fn wait(timeout_flag: *Atomic(bool), done: *Atomic(bool)) void {
            Thread.sleep(TIMEOUT_MS * std.time.ns_per_ms);
            if (!done.load(.acquire)) {
                timeout_flag.store(true, .release);
            }
        }
    }.wait, .{ &timed_out, &completed });

    worker.join();
    timeout.join();

    try testing.expect(completed.load(.acquire));
    try testing.expect(!timed_out.load(.acquire));
    try testing.expectEqual(@as(u32, 42), result.load(.acquire));
}

test "Pattern - request timeout exceeded" {
    var completed = Atomic(bool).init(false);
    var timed_out = Atomic(bool).init(false);

    const TIMEOUT_MS = 50;

    // Worker thread (takes too long)
    const worker = try Thread.spawn(.{}, struct {
        fn work(done: *Atomic(bool)) void {
            Thread.sleep(200 * std.time.ns_per_ms); // Slow operation
            done.store(true, .release);
        }
    }.work, .{ &completed });

    // Wait for timeout
    Thread.sleep(TIMEOUT_MS * std.time.ns_per_ms);

    if (!completed.load(.acquire)) {
        timed_out.store(true, .release);
    }

    // Wait for worker to finish (cleanup)
    worker.join();

    // The worker eventually completed, but we detected timeout first
    try testing.expect(timed_out.load(.acquire));
}
