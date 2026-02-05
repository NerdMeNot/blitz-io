//! Test Configuration Module
//!
//! Provides standardized iteration counts and configuration for tests across
//! the test suite. Uses smaller values in Debug mode for faster development
//! cycles while maintaining thorough coverage in Release mode.
//!
//! ## Design Rationale
//!
//! The iteration counts are chosen based on:
//! - **Debug mode**: Fast feedback (<1s per test), still catches most bugs
//! - **Release mode**: Thorough coverage, stress tests run longer
//!
//! ## Usage
//!
//! ```zig
//! const config = @import("../test_config.zig");
//!
//! test "example stress test" {
//!     for (0..config.stress.iterations) |_| {
//!         // test body
//!     }
//! }
//! ```

const std = @import("std");
const builtin = @import("builtin");

/// Whether we're running in debug mode (affects iteration counts)
pub const is_debug = builtin.mode == .Debug;

// ═══════════════════════════════════════════════════════════════════════════════
// Stress Test Configuration
// ═══════════════════════════════════════════════════════════════════════════════

/// Standard stress test iteration counts
pub const stress = struct {
    // ─────────────────────────────────────────────────────────────────────────
    // General Iterations
    // ─────────────────────────────────────────────────────────────────────────

    /// Standard number of iterations for stress tests
    /// Debug: 100 (fast feedback)
    /// Release: 1000 (thorough coverage)
    pub const iterations: usize = if (is_debug) 100 else 1000;

    /// High-throughput iteration count for throughput tests
    /// Debug: 1000 (still tests batching behavior)
    /// Release: 100000 (tests sustained throughput)
    pub const high_throughput: usize = if (is_debug) 1000 else 100000;

    /// Small iteration count for quick sanity checks
    /// Debug: 50
    /// Release: 100
    pub const small: usize = if (is_debug) 50 else 100;

    // ─────────────────────────────────────────────────────────────────────────
    // Task/Thread Counts
    // ─────────────────────────────────────────────────────────────────────────

    /// Number of concurrent tasks for low-contention tests
    /// Debug: 10 (enough to test concurrency)
    /// Release: 50 (higher parallelism)
    pub const tasks_low: usize = if (is_debug) 10 else 50;

    /// Number of concurrent tasks for medium-contention tests
    /// Debug: 20
    /// Release: 100
    pub const tasks_medium: usize = if (is_debug) 20 else 100;

    /// Number of concurrent tasks for high-contention tests
    /// Debug: 50
    /// Release: 200
    pub const tasks_high: usize = if (is_debug) 50 else 200;

    // ─────────────────────────────────────────────────────────────────────────
    // Channel/Buffer Sizes
    // ─────────────────────────────────────────────────────────────────────────

    /// Small buffer size (high contention)
    /// Chosen to be small enough to cause frequent blocking
    pub const buffer_small: usize = 4;

    /// Medium buffer size
    pub const buffer_medium: usize = 64;

    /// Large buffer size (low contention)
    pub const buffer_large: usize = 256;

    // ─────────────────────────────────────────────────────────────────────────
    // Sync Primitive Specific
    // ─────────────────────────────────────────────────────────────────────────

    /// Number of receivers for broadcast/watch tests
    /// Debug: 5 (enough to test broadcast semantics)
    /// Release: 20 (tests scalability)
    pub const receivers: usize = if (is_debug) 5 else 20;

    /// Number of producers for MPSC tests
    /// Debug: 5
    /// Release: 10
    pub const producers: usize = if (is_debug) 5 else 10;

    /// Items per producer in channel tests
    /// Debug: 100
    /// Release: 1000
    pub const items_per_producer: usize = if (is_debug) 100 else 1000;

    /// Number of readers for RwLock tests
    /// Debug: 10
    /// Release: 50
    pub const readers: usize = if (is_debug) 10 else 50;

    /// Number of writers for RwLock/Mutex tests
    /// Debug: 5
    /// Release: 20
    pub const writers: usize = if (is_debug) 5 else 20;

    /// Operations per task in lock tests
    /// Debug: 50
    /// Release: 100
    pub const ops_per_task: usize = if (is_debug) 50 else 100;

    /// Number of semaphore permits
    /// Chosen to allow some parallelism while testing contention
    pub const semaphore_permits: usize = 5;
};

// ═══════════════════════════════════════════════════════════════════════════════
// Concurrency Test Configuration
// ═══════════════════════════════════════════════════════════════════════════════

/// Configuration for concurrency tests (race detection, etc.)
pub const concurrency = struct {
    /// Standard thread count for concurrency tests
    pub const threads: usize = if (is_debug) 4 else 8;

    /// Task count for work-stealing tests
    pub const work_steal_tasks: usize = if (is_debug) 100 else 1000;

    /// Iterations for state machine tests
    pub const state_iterations: usize = if (is_debug) 1000 else 10000;
};

// ═══════════════════════════════════════════════════════════════════════════════
// Fuzz Test Configuration
// ═══════════════════════════════════════════════════════════════════════════════

/// Configuration for fuzz tests
pub const fuzz = struct {
    /// Number of random inputs to try
    /// Debug: 100 (quick sanity check)
    /// Release: 1000 (thorough fuzzing)
    pub const iterations: usize = if (is_debug) 100 else 1000;

    /// Maximum input size for string fuzzing
    pub const max_input_size: usize = 256;
};

// ═══════════════════════════════════════════════════════════════════════════════
// Integration Test Configuration
// ═══════════════════════════════════════════════════════════════════════════════

/// Configuration for integration tests
pub const integration = struct {
    /// Number of concurrent clients for server tests
    pub const clients: usize = if (is_debug) 10 else 50;

    /// Number of messages for long-lived connection tests
    pub const messages: usize = if (is_debug) 10 else 100;

    /// Large data transfer size in bytes
    pub const large_data_size: usize = if (is_debug) 64 * 1024 else 1024 * 1024;
};

// ═══════════════════════════════════════════════════════════════════════════════
// Spin Loop Configuration
// ═══════════════════════════════════════════════════════════════════════════════

/// Configuration for spin loops and polling
pub const spin = struct {
    /// Number of spin iterations to simulate brief work
    /// This is intentionally small to avoid wasting CPU while still
    /// providing some timing variation between threads.
    pub const brief_work: usize = 10;

    /// Number of spin iterations to simulate moderate work
    pub const moderate_work: usize = 50;

    /// Number of spin iterations to simulate longer work
    pub const long_work: usize = 100;

    /// Maximum spin iterations before giving up (for bounded waits)
    pub const max_spins: usize = 1000;
};

// ═══════════════════════════════════════════════════════════════════════════════
// Helper Functions
// ═══════════════════════════════════════════════════════════════════════════════

/// Brief spin loop to simulate work without sleeping
pub inline fn spinBrief() void {
    for (0..spin.brief_work) |_| {
        std.atomic.spinLoopHint();
    }
}

/// Moderate spin loop to simulate work
pub inline fn spinModerate() void {
    for (0..spin.moderate_work) |_| {
        std.atomic.spinLoopHint();
    }
}

/// Long spin loop to simulate work
pub inline fn spinLong() void {
    for (0..spin.long_work) |_| {
        std.atomic.spinLoopHint();
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Thread-Based Scope for Testing
// ═══════════════════════════════════════════════════════════════════════════════

/// A simple thread-based scope for stress tests.
/// This is used for testing sync primitives outside of the async runtime context.
/// For production code inside runtime.run(), use blitz_io.Scope instead.
pub const ThreadScope = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    threads: std.ArrayListUnmanaged(std.Thread),
    mutex: std.Thread.Mutex,
    first_error: ?anyerror,
    error_mutex: std.Thread.Mutex,
    cancelled: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .threads = .{},
            .mutex = .{},
            .first_error = null,
            .error_mutex = .{},
            .cancelled = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        self.threads.deinit(self.allocator);
    }

    pub fn spawn(self: *Self, comptime func: anytype, args: anytype) !void {
        const Args = @TypeOf(args);
        const Context = struct {
            arguments: Args,
            scope: *Self,
            allocator: std.mem.Allocator,

            fn execute(ctx: *@This()) void {
                defer ctx.allocator.destroy(ctx);

                const result = @call(.auto, func, ctx.arguments);

                if (@typeInfo(@TypeOf(result)) == .error_union) {
                    if (result) |_| {} else |err| {
                        ctx.scope.captureError(err);
                    }
                }
            }

            fn threadEntry(ctx_ptr: *@This()) void {
                ctx_ptr.execute();
            }
        };

        const ctx = try self.allocator.create(Context);
        ctx.* = .{
            .arguments = args,
            .scope = self,
            .allocator = self.allocator,
        };

        const thread = std.Thread.spawn(.{}, Context.threadEntry, .{ctx}) catch |err| {
            self.allocator.destroy(ctx);
            return err;
        };

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.threads.append(self.allocator, thread);
    }

    /// Spawn a task and capture its result via output pointer.
    pub fn spawnWithResult(
        self: *Self,
        comptime func: anytype,
        args: anytype,
        result_out: anytype,
    ) !void {
        const Args = @TypeOf(args);
        const ResultPtr = @TypeOf(result_out);
        const Context = struct {
            arguments: Args,
            scope: *Self,
            result_ptr: ResultPtr,
            allocator: std.mem.Allocator,

            fn execute(ctx: *@This()) void {
                defer ctx.allocator.destroy(ctx);

                const result = @call(.auto, func, ctx.arguments);
                const ResultType = @TypeOf(result);

                if (@typeInfo(ResultType) == .error_union) {
                    if (result) |value| {
                        ctx.result_ptr.* = value;
                    } else |err| {
                        ctx.scope.captureError(err);
                    }
                } else {
                    ctx.result_ptr.* = result;
                }
            }

            fn threadEntry(ctx_ptr: *@This()) void {
                ctx_ptr.execute();
            }
        };

        const ctx = try self.allocator.create(Context);
        ctx.* = .{
            .arguments = args,
            .scope = self,
            .result_ptr = result_out,
            .allocator = self.allocator,
        };

        const thread = std.Thread.spawn(.{}, Context.threadEntry, .{ctx}) catch |err| {
            self.allocator.destroy(ctx);
            return err;
        };

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.threads.append(self.allocator, thread);
    }

    pub fn wait(self: *Self) anyerror!void {
        // Copy threads to join (avoid holding lock during join)
        self.mutex.lock();
        const threads_to_join = self.threads.items;
        self.mutex.unlock();

        for (threads_to_join) |thread| {
            thread.join();
        }

        if (self.first_error) |err| {
            return err;
        }
    }

    /// Request cancellation - cooperative, tasks must check isCancelled()
    pub fn cancel(self: *Self) void {
        self.cancelled.store(true, .release);
        self.captureError(error.Cancelled);
    }

    /// Check if cancellation has been requested
    pub fn isCancelled(self: *const Self) bool {
        return self.cancelled.load(.acquire);
    }

    fn captureError(self: *Self, err: anyerror) void {
        self.error_mutex.lock();
        defer self.error_mutex.unlock();
        if (self.first_error == null) {
            self.first_error = err;
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Tests for this module
// ═══════════════════════════════════════════════════════════════════════════════

test "test_config - debug vs release values differ" {
    // This test verifies that the config is set up correctly
    // In debug mode, values should be smaller
    if (is_debug) {
        try std.testing.expect(stress.iterations <= 1000);
        try std.testing.expect(stress.tasks_low <= 50);
    } else {
        try std.testing.expect(stress.iterations >= 1000);
        try std.testing.expect(stress.tasks_low >= 50);
    }
}

test "test_config - spin helpers work" {
    spinBrief();
    spinModerate();
    spinLong();
}
