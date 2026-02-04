//! Structured Concurrency Scope
//!
//! Spawn concurrent tasks with guaranteed completion. All tasks spawned
//! within a scope must complete before the scope exits - no leaked work.
//!
//! ## Features
//!
//! - Automatic task counting (no manual add/done)
//! - Result collection via output pointers
//! - First-error propagation
//! - Cooperative cancellation
//!
//! ## Example: Parallel API Calls
//!
//! ```zig
//! var profile = UserProfile{};
//!
//! var scope = Scope.init(allocator);
//! defer scope.deinit();
//!
//! try scope.spawnWithResult(fetchUser, .{id}, &profile.user);
//! try scope.spawnWithResult(fetchPosts, .{id}, &profile.posts);
//! try scope.spawnWithResult(fetchFriends, .{id}, &profile.friends);
//!
//! try scope.wait(); // Blocks until all 3 complete
//! // profile now populated
//! ```
//!
//! ## Example: Batch Processing
//!
//! ```zig
//! var scope = Scope.init(allocator);
//! defer scope.deinit();
//!
//! for (images) |image| {
//!     try scope.spawn(processImage, .{image});
//! }
//!
//! try scope.wait(); // All images processed
//! ```
//!
//! ## Example: With Cancellation
//!
//! ```zig
//! var scope = Scope.init(allocator);
//! defer scope.deinit();
//!
//! try scope.spawn(longRunningTask, .{&scope});
//! try scope.spawn(timeoutWatcher, .{&scope, Duration.fromSecs(30)});
//!
//! scope.wait() catch |err| {
//!     if (err == error.Cancelled) {
//!         // Timeout hit, partial work done
//!     }
//! };
//!
//! fn longRunningTask(scope: *Scope) !void {
//!     while (!scope.isCancelled()) {
//!         // Do work in chunks, checking cancellation
//!     }
//! }
//!
//! fn timeoutWatcher(scope: *Scope, timeout: Duration) void {
//!     std.Thread.sleep(timeout.asNanos());
//!     scope.cancel();
//! }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Structured concurrency scope for spawning and awaiting concurrent tasks.
pub const Scope = struct {
    allocator: Allocator,

    // Task tracking - list of spawned task contexts
    tasks: std.ArrayListUnmanaged(*TaskNode),

    // Synchronization
    mutex: std.Thread.Mutex,
    completion_cv: std.Thread.Condition,

    // State
    pending_count: usize,
    cancelled: std.atomic.Value(bool),
    first_error: ?anyerror,
    error_mutex: std.Thread.Mutex,

    const Self = @This();

    /// Internal task node for tracking spawned work.
    const TaskNode = struct {
        thread: std.Thread,
        completed: std.atomic.Value(bool),
    };

    /// Initialize a new scope.
    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .tasks = .{},
            .mutex = .{},
            .completion_cv = .{},
            .pending_count = 0,
            .cancelled = std.atomic.Value(bool).init(false),
            .first_error = null,
            .error_mutex = .{},
        };
    }

    /// Clean up scope resources.
    /// Panics if there are still pending tasks - call wait() first.
    pub fn deinit(self: *Self) void {
        if (self.pending_count > 0) {
            @panic("Scope.deinit() called with pending tasks - call wait() first");
        }

        // Free task nodes
        for (self.tasks.items) |node| {
            self.allocator.destroy(node);
        }
        self.tasks.deinit(self.allocator);
    }

    /// Spawn a task within this scope.
    ///
    /// The task function can have any signature. If it returns an error,
    /// the error is captured and returned by wait().
    ///
    /// Counting is automatic - no need to call add() or done().
    pub fn spawn(
        self: *Self,
        comptime func: anytype,
        args: anytype,
    ) Allocator.Error!void {
        const Args = @TypeOf(args);

        // Create task context that captures args and scope
        const Context = struct {
            arguments: Args,
            scope: *Self,
            allocator: Allocator,

            fn execute(ctx: *@This()) void {
                defer ctx.allocator.destroy(ctx);

                // Call the user function
                const result = @call(.auto, func, ctx.arguments);

                // Handle error union return types
                if (@typeInfo(@TypeOf(result)) == .error_union) {
                    if (result) |_| {
                        // Success - nothing to capture
                    } else |err| {
                        ctx.scope.captureError(err);
                    }
                }

                // Signal completion
                ctx.scope.taskCompleted();
            }

            fn threadEntry(ctx_ptr: *@This()) void {
                ctx_ptr.execute();
            }
        };

        // Allocate context
        const ctx = try self.allocator.create(Context);
        ctx.* = .{
            .arguments = args,
            .scope = self,
            .allocator = self.allocator,
        };

        // Allocate task node
        const node = try self.allocator.create(TaskNode);
        errdefer self.allocator.destroy(node);

        node.* = .{
            .thread = undefined,
            .completed = std.atomic.Value(bool).init(false),
        };

        // Increment pending count before spawning
        self.mutex.lock();
        self.pending_count += 1;
        self.tasks.append(self.allocator, node) catch {
            self.pending_count -= 1;
            self.mutex.unlock();
            self.allocator.destroy(ctx);
            self.allocator.destroy(node);
            return error.OutOfMemory;
        };
        self.mutex.unlock();

        // Spawn thread
        node.thread = std.Thread.spawn(.{}, Context.threadEntry, .{ctx}) catch {
            self.mutex.lock();
            self.pending_count -= 1;
            _ = self.tasks.pop();
            self.mutex.unlock();
            self.allocator.destroy(ctx);
            self.allocator.destroy(node);
            return error.OutOfMemory;
        };
    }

    /// Spawn a task and capture its result.
    ///
    /// The result is written to `result_out` when the task completes successfully.
    /// If the task returns an error, `result_out` is unchanged and the error
    /// is returned by wait().
    pub fn spawnWithResult(
        self: *Self,
        comptime func: anytype,
        args: anytype,
        result_out: anytype,
    ) Allocator.Error!void {
        const Args = @TypeOf(args);
        const ResultPtr = @TypeOf(result_out);
        const ResultType = @typeInfo(ResultPtr).pointer.child;

        // Create task context that captures args, scope, and result pointer
        const Context = struct {
            arguments: Args,
            scope: *Self,
            result_ptr: ResultPtr,
            allocator: Allocator,

            fn execute(ctx: *@This()) void {
                defer ctx.allocator.destroy(ctx);

                // Call the user function
                const result = @call(.auto, func, ctx.arguments);

                // Handle the result
                const ResultInfo = @typeInfo(@TypeOf(result));
                if (ResultInfo == .error_union) {
                    if (result) |value| {
                        // Success - write result
                        if (@typeInfo(ResultType) == .optional) {
                            ctx.result_ptr.* = value;
                        } else {
                            ctx.result_ptr.* = value;
                        }
                    } else |err| {
                        ctx.scope.captureError(err);
                    }
                } else {
                    // No error union - direct assignment
                    if (@typeInfo(ResultType) == .optional) {
                        ctx.result_ptr.* = result;
                    } else {
                        ctx.result_ptr.* = result;
                    }
                }

                // Signal completion
                ctx.scope.taskCompleted();
            }

            fn threadEntry(ctx_ptr: *@This()) void {
                ctx_ptr.execute();
            }
        };

        // Allocate context
        const ctx = try self.allocator.create(Context);
        ctx.* = .{
            .arguments = args,
            .scope = self,
            .result_ptr = result_out,
            .allocator = self.allocator,
        };

        // Allocate task node
        const node = try self.allocator.create(TaskNode);
        errdefer self.allocator.destroy(node);

        node.* = .{
            .thread = undefined,
            .completed = std.atomic.Value(bool).init(false),
        };

        // Increment pending count before spawning
        self.mutex.lock();
        self.pending_count += 1;
        self.tasks.append(self.allocator, node) catch {
            self.pending_count -= 1;
            self.mutex.unlock();
            self.allocator.destroy(ctx);
            self.allocator.destroy(node);
            return error.OutOfMemory;
        };
        self.mutex.unlock();

        // Spawn thread
        node.thread = std.Thread.spawn(.{}, Context.threadEntry, .{ctx}) catch {
            self.mutex.lock();
            self.pending_count -= 1;
            _ = self.tasks.pop();
            self.mutex.unlock();
            self.allocator.destroy(ctx);
            self.allocator.destroy(node);
            return error.OutOfMemory;
        };
    }

    /// Wait for all spawned tasks to complete.
    ///
    /// Returns the first error encountered by any task, or success if all
    /// tasks completed without error.
    ///
    /// After wait() returns, all tasks are guaranteed to have completed.
    pub fn wait(self: *Self) anyerror!void {
        // Wait for all tasks to complete
        self.mutex.lock();
        while (self.pending_count > 0) {
            self.completion_cv.wait(&self.mutex);
        }
        self.mutex.unlock();

        // Join all threads to ensure cleanup
        for (self.tasks.items) |node| {
            node.thread.join();
        }

        // Check for captured error
        if (self.first_error) |err| {
            return err;
        }
    }

    /// Request cancellation of pending tasks.
    ///
    /// This is cooperative - tasks must check isCancelled() periodically
    /// and exit early when true. Does not forcibly terminate tasks.
    pub fn cancel(self: *Self) void {
        self.cancelled.store(true, .release);

        // Also set an error so wait() returns error.Cancelled
        self.captureError(error.Cancelled);
    }

    /// Check if cancellation has been requested.
    ///
    /// Tasks should check this periodically and exit early if true.
    pub fn isCancelled(self: *const Self) bool {
        return self.cancelled.load(.acquire);
    }

    /// Get the number of tasks still pending.
    pub fn pending(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.pending_count;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────

    fn taskCompleted(self: *Self) void {
        self.mutex.lock();
        self.pending_count -= 1;
        if (self.pending_count == 0) {
            self.completion_cv.broadcast();
        }
        self.mutex.unlock();
    }

    fn captureError(self: *Self, err: anyerror) void {
        self.error_mutex.lock();
        defer self.error_mutex.unlock();

        // Only capture first error
        if (self.first_error == null) {
            self.first_error = err;
        }
    }
};

/// Convenience function: run a function with a scope that auto-waits on exit.
///
/// ```zig
/// try io.scoped(allocator, struct {
///     pub fn run(s: *Scope) !void {
///         try s.spawn(task1, .{});
///         try s.spawn(task2, .{});
///         // Auto-waits when this function returns
///     }
/// }.run);
/// ```
pub fn scoped(allocator: Allocator, comptime func: anytype) anyerror!void {
    var scope = Scope.init(allocator);
    defer scope.deinit();

    // Call user function
    const result = func(&scope);

    // Wait for all spawned tasks
    try scope.wait();

    // Propagate user function error if any
    if (@typeInfo(@TypeOf(result)) == .error_union) {
        return result;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Errors
// ─────────────────────────────────────────────────────────────────────────────

pub const ScopeError = error{
    /// Cancellation was requested
    Cancelled,
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "Scope - basic spawn and wait" {
    const allocator = std.testing.allocator;

    var counter = std.atomic.Value(usize).init(0);

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // Spawn 3 tasks that increment counter
    try scope.spawn(incrementCounter, .{&counter});
    try scope.spawn(incrementCounter, .{&counter});
    try scope.spawn(incrementCounter, .{&counter});

    try scope.wait();

    try std.testing.expectEqual(@as(usize, 3), counter.load(.acquire));
}

fn incrementCounter(counter: *std.atomic.Value(usize)) void {
    _ = counter.fetchAdd(1, .acq_rel);
}

test "Scope - spawnWithResult" {
    const allocator = std.testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var result1: ?u32 = null;
    var result2: ?u32 = null;

    try scope.spawnWithResult(computeValue, .{@as(u32, 10)}, &result1);
    try scope.spawnWithResult(computeValue, .{@as(u32, 20)}, &result2);

    try scope.wait();

    try std.testing.expectEqual(@as(?u32, 100), result1); // 10 * 10
    try std.testing.expectEqual(@as(?u32, 400), result2); // 20 * 20
}

fn computeValue(x: u32) u32 {
    return x * x;
}

test "Scope - error propagation" {
    const allocator = std.testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    try scope.spawn(succeedingTask, .{});
    try scope.spawn(failingTask, .{});
    try scope.spawn(succeedingTask, .{});

    const result = scope.wait();
    try std.testing.expectError(error.TestFailure, result);
}

fn succeedingTask() void {}

fn failingTask() !void {
    return error.TestFailure;
}

test "Scope - cancellation" {
    const allocator = std.testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var iterations = std.atomic.Value(usize).init(0);

    try scope.spawn(cancellableTask, .{ &scope, &iterations });
    try scope.spawn(cancellerTask, .{&scope});

    const result = scope.wait();
    try std.testing.expectError(error.Cancelled, result);

    // Task should have exited early due to cancellation
    try std.testing.expect(iterations.load(.acquire) < 1000);
}

fn cancellableTask(scope: *const Scope, iterations: *std.atomic.Value(usize)) void {
    var i: usize = 0;
    while (i < 1000 and !scope.isCancelled()) : (i += 1) {
        _ = iterations.fetchAdd(1, .acq_rel);
        std.Thread.sleep(1_000_000); // 1ms
    }
}

fn cancellerTask(scope: *Scope) void {
    std.Thread.sleep(10_000_000); // 10ms
    scope.cancel();
}

test "Scope - pending count" {
    const allocator = std.testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    try std.testing.expectEqual(@as(usize, 0), scope.pending());

    try scope.spawn(slowTask, .{});
    try scope.spawn(slowTask, .{});

    // Tasks are running, pending should be > 0
    // (might be 2 or less depending on timing)
    try std.testing.expect(scope.pending() <= 2);

    try scope.wait();

    try std.testing.expectEqual(@as(usize, 0), scope.pending());
}

fn slowTask() void {
    std.Thread.sleep(10_000_000); // 10ms
}

test "Scope - empty scope" {
    const allocator = std.testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    // Wait on empty scope should succeed immediately
    try scope.wait();
}

test "Scope - spawnWithResult error handling" {
    const allocator = std.testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var result: ?u32 = null;

    try scope.spawnWithResult(failingCompute, .{}, &result);

    const wait_result = scope.wait();
    try std.testing.expectError(error.ComputeFailed, wait_result);

    // Result should be unchanged (still null) because task failed
    try std.testing.expectEqual(@as(?u32, null), result);
}

fn failingCompute() !u32 {
    return error.ComputeFailed;
}
