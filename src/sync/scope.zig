//! Scope - Structured Concurrency for blitz-io
//!
//! A Scope guarantees that all spawned work completes before the scope exits.
//! This is the fundamental building block for safe concurrent programming.
//!
//! ## Design Philosophy
//!
//! 1. **Type-safe results** - `spawn()` returns `Task(T)` with typed `.await()`
//! 2. **Zero-allocation tracking** - Packed atomic state, no per-task allocations for tracking
//! 3. **Efficient waiting** - Futex-based, not polling
//! 4. **Composable** - Works with timeouts, cancellation, and combinators
//! 5. **Hard to misuse** - Compiler enforces structured concurrency
//!
//! ## Quick Start
//!
//! ```zig
//! var scope = Scope{};
//! defer scope.cancel();  // Always clean up
//!
//! // Spawn async tasks (run on I/O workers)
//! const user_task = try scope.spawn(fetchUser, .{id});
//! const posts_task = try scope.spawn(fetchPosts, .{id});
//!
//! // Wait for all tasks
//! try scope.wait();
//!
//! // Get typed results
//! const user = user_task.await();
//! const posts = posts_task.await();
//! ```
//!
//! ## Blocking Operations
//!
//! For CPU-intensive or blocking I/O, use `spawnBlocking()` to run on the
//! dedicated blocking pool instead of starving I/O workers:
//!
//! ```zig
//! // CPU-bound: runs on blocking pool
//! const hash_task = try scope.spawnBlocking(computeHash, .{data});
//!
//! // I/O-bound: runs on async workers
//! const fetch_task = try scope.spawn(fetchData, .{url});
//!
//! try scope.wait();
//! ```
//!
//! ## Error Handling
//!
//! Errors from tasks are captured and returned by `wait()`:
//!
//! ```zig
//! scope.setFailFast();  // Cancel remaining on first error
//!
//! try scope.go(mightFail1, .{});
//! try scope.go(mightFail2, .{});
//!
//! scope.wait() catch |err| {
//!     // First error from any task
//! };
//! ```
//!
//! ## Timeouts
//!
//! ```zig
//! scope.waitTimeout(Duration.fromSeconds(5)) catch |err| switch (err) {
//!     error.Timeout => { scope.cancel(); return error.TooSlow; },
//!     else => |e| return e,
//! };
//! ```

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const runtime_mod = @import("../runtime.zig");
const blocking_mod = @import("../blocking.zig");
const time_mod = @import("../time.zig");
const Duration = time_mod.Duration;
const Instant = time_mod.Instant;

const task_mod = @import("../coroutine/task.zig");
const Header = task_mod.Header;

// ═══════════════════════════════════════════════════════════════════════════════
// Task Handle - Type-safe result handle
// ═══════════════════════════════════════════════════════════════════════════════

/// A handle to a spawned task's result.
///
/// The task runs concurrently and the handle can be used to:
/// - Check if complete with `poll()`
/// - Wait and get result with `await()`
/// - Cancel with `cancel()`
/// - Detach (fire-and-forget) with `detach()`
pub fn Task(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Pointer to the task header
        header: *Header,

        /// Scope that owns this task (for counter management)
        scope: *Scope,

        /// Whether this handle has been consumed (await/detach called)
        consumed: bool = false,

        /// Wait for the task to complete and return its result.
        ///
        /// If the task returned an error, the error is propagated.
        /// This is a blocking operation that yields to the scheduler.
        pub fn await(self: *Self) T {
            if (self.consumed) {
                @panic("Task.await() called on already-consumed handle");
            }
            self.consumed = true;

            // Spin-wait for completion (TODO: proper async yield)
            while (!self.header.isComplete()) {
                std.Thread.yield() catch {};
            }

            // Get the result
            if (self.header.vtable.get_output(self.header)) |ptr| {
                const result = @as(*T, @ptrCast(@alignCast(ptr))).*;
                self.header.unref();
                return result;
            }

            // Task was cancelled or has no output
            @panic("Task completed without result (cancelled?)");
        }

        /// Check if the task is complete without blocking.
        /// Returns the result if ready, null otherwise.
        pub fn poll(self: *Self) ?T {
            if (self.consumed) return null;
            if (!self.header.isComplete()) return null;

            self.consumed = true;
            if (self.header.vtable.get_output(self.header)) |ptr| {
                const result = @as(*T, @ptrCast(@alignCast(ptr))).*;
                self.header.unref();
                return result;
            }
            return null;
        }

        /// Check if the task has finished (success, error, or cancelled).
        pub fn isFinished(self: *const Self) bool {
            return self.header.isComplete();
        }

        /// Request cancellation of this task.
        /// The task will stop at the next yield point.
        /// Returns immediately; use `await()` to wait for actual completion.
        pub fn cancel(self: *Self) void {
            _ = self.header.cancel();
        }

        /// Detach the task - it continues running but result is discarded.
        /// The scope still waits for it to complete.
        /// Use sparingly; prefer structured concurrency.
        pub fn detach(self: *Self) void {
            if (self.consumed) return;
            self.consumed = true;
            self.header.unref();
        }

        /// Clean up if the handle wasn't consumed.
        /// Called automatically if handle goes out of scope without await/detach.
        pub fn deinit(self: *Self) void {
            if (!self.consumed) {
                self.header.unref();
            }
        }
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
// Scope State - Packed for atomic operations and futex
// ═══════════════════════════════════════════════════════════════════════════════

/// Scope state packed into a single u32 for atomic operations.
///
/// Layout: [4 flags (high)][28 counter (low)]
///
/// This design enables:
/// - Single CAS for all state transitions
/// - Futex can observe counter AND flags atomically
/// - 28-bit counter supports ~268 million concurrent tasks
const State = packed struct(u32) {
    /// Number of active tasks (28 bits = 268,435,455 max)
    counter: u28 = 0,

    /// Cancellation was requested
    cancelled: bool = false,

    /// At least one task failed with an error
    failed: bool = false,

    /// Cancel remaining tasks on first error
    fail_fast: bool = false,

    /// Scope is closed - no more spawns allowed
    closed: bool = false,

    const COUNTER_MASK: u32 = 0x0FFFFFFF;
    const COUNTER_ONE: u32 = 1;

    fn fromU32(val: u32) State {
        return @bitCast(val);
    }

    fn toU32(self: State) u32 {
        return @bitCast(self);
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Scope - The main structured concurrency primitive
// ═══════════════════════════════════════════════════════════════════════════════

/// Structured concurrency scope for managing concurrent tasks.
///
/// All tasks spawned within a scope are guaranteed to complete before
/// the scope exits. Tasks can be async (I/O workers) or blocking (thread pool).
pub const Scope = struct {
    const Self = @This();

    /// Packed state: counter (28 bits) + flags (4 bits)
    /// Supports futex-based waiting
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// First error captured from any task
    first_error: ?anyerror = null,

    /// Mutex protecting first_error (only for writes)
    error_mutex: std.Thread.Mutex = .{},

    // ───────────────────────────────────────────────────────────────────────────
    // Initialization
    // ───────────────────────────────────────────────────────────────────────────

    /// Default initialization - use `var scope = Scope{};`
    pub const init: Scope = .{};

    /// Initialize with an allocator (for compatibility, allocator not currently used)
    pub fn initWithAllocator(allocator: Allocator) Scope {
        _ = allocator;
        return .{};
    }

    /// Clean up scope resources.
    /// Panics if there are pending tasks - call `wait()` or `cancel()` first.
    pub fn deinit(self: *Self) void {
        const state = State.fromU32(self.state.load(.acquire));
        if (state.counter > 0) {
            @panic("Scope.deinit() called with pending tasks - call wait() or cancel() first");
        }
    }

    // ───────────────────────────────────────────────────────────────────────────
    // Spawning - Async Tasks (I/O Workers)
    // ───────────────────────────────────────────────────────────────────────────

    /// Spawn an async task and get a handle to its result.
    ///
    /// The task runs on the runtime's I/O worker threads using cooperative
    /// scheduling. Use this for I/O-bound work that yields at async points.
    ///
    /// ```zig
    /// const task = try scope.spawn(fetchUser, .{user_id});
    /// // ... do other work ...
    /// const user = task.await();
    /// ```
    pub fn spawn(
        self: *Self,
        comptime func: anytype,
        args: std.meta.ArgsTuple(@TypeOf(func)),
    ) !Task(ReturnType(@TypeOf(func))) {
        const state = State.fromU32(self.state.load(.acquire));
        if (state.closed) return error.ScopeClosed;

        // Get runtime
        const rt = runtime_mod.runtime();

        const Result = ReturnType(@TypeOf(func));
        const Args = @TypeOf(args);
        const TaskType = ScopedTask(Result, Args);

        // Allocate task
        const task = try rt.allocator.create(TaskType);
        task.* = TaskType.init(args, rt.allocator, self);

        // Create wrapper that handles error unions
        const FuncReturnType = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
        const Wrapper = struct {
            fn call(scope_ptr: *Scope, a: Args) ?Result {
                const res = @call(.auto, func, a);

                // Handle error union return types
                if (@typeInfo(FuncReturnType) == .error_union) {
                    if (res) |val| {
                        return val;
                    } else |err| {
                        scope_ptr.captureError(err);
                        return null;
                    }
                } else {
                    return res;
                }
            }
        };

        task.setWrapperFunc(Wrapper.call, self);
        task.setRuntime(rt);

        // Increment counter before scheduling
        self.incrementCounter();

        // Schedule task
        rt.getScheduler().spawn(&task.header);

        // Return handle
        return .{
            .header = &task.header,
            .scope = self,
        };
    }

    /// Spawn a task without tracking its result (fire-and-forget within scope).
    ///
    /// The scope still waits for the task to complete, but you don't get
    /// a handle to its result. Task errors are captured by the scope.
    ///
    /// ```zig
    /// for (urls) |url| {
    ///     try scope.go(fetch, .{url});
    /// }
    /// try scope.wait();  // Waits for all
    /// ```
    pub fn go(
        self: *Self,
        comptime func: anytype,
        args: std.meta.ArgsTuple(@TypeOf(func)),
    ) !void {
        var task = try self.spawn(func, args);
        task.detach();
    }

    // ───────────────────────────────────────────────────────────────────────────
    // Spawning - Blocking Tasks (Thread Pool)
    // ───────────────────────────────────────────────────────────────────────────

    /// Spawn a blocking task on the dedicated thread pool.
    ///
    /// Use this for CPU-intensive work or blocking I/O that would otherwise
    /// stall the async I/O workers. The task runs on a separate thread pool.
    ///
    /// ```zig
    /// // CPU-bound work
    /// const hash_task = try scope.spawnBlocking(computeExpensiveHash, .{data});
    ///
    /// // Blocking file I/O
    /// const file_task = try scope.spawnBlocking(readLargeFile, .{path});
    ///
    /// try scope.wait();
    /// const hash = hash_task.await();
    /// const contents = file_task.await();
    /// ```
    pub fn spawnBlocking(
        self: *Self,
        comptime func: anytype,
        args: std.meta.ArgsTuple(@TypeOf(func)),
    ) !BlockingTask(ReturnType(@TypeOf(func))) {
        const state = State.fromU32(self.state.load(.acquire));
        if (state.closed) return error.ScopeClosed;

        const rt = runtime_mod.runtime();
        const pool = rt.getBlockingPool();

        const Result = ReturnType(@TypeOf(func));
        const Args = @TypeOf(args);
        const CtxHeader = BlockingContextHeader(Result);

        // Context struct with header at start for type-safe access
        const Context = struct {
            // Header must be first for pointer casting
            header: CtxHeader,
            args: Args,

            fn execute(ctx: *@This()) void {
                defer {
                    ctx.header.completed.store(true, .release);
                    ctx.header.scope.decrementCounter();
                }

                const res = @call(.auto, func, ctx.args);

                // Handle error union
                if (@typeInfo(@TypeOf(res)) == .error_union) {
                    if (res) |val| {
                        ctx.header.result = val;
                    } else |err| {
                        ctx.header.scope.captureError(err);
                    }
                } else {
                    ctx.header.result = res;
                }
            }

            fn executeWrapper(context_ptr: *anyopaque) void {
                const ctx: *@This() = @ptrCast(@alignCast(context_ptr));
                ctx.execute();
            }
        };

        const ctx = try rt.allocator.create(Context);
        ctx.* = .{
            .header = .{
                .scope = self,
                .allocator = rt.allocator,
            },
            .args = args,
        };

        // Increment counter
        self.incrementCounter();

        // Submit to blocking pool
        var blocking_task = blocking_mod.BlockingPool.Task{
            .func = Context.executeWrapper,
            .context = ctx,
        };
        pool.submit(&blocking_task) catch |err| {
            self.decrementCounter();
            rt.allocator.destroy(ctx);
            return err;
        };

        return .{
            .header = &ctx.header,
        };
    }

    /// Spawn blocking task without tracking result.
    pub fn goBlocking(
        self: *Self,
        comptime func: anytype,
        args: std.meta.ArgsTuple(@TypeOf(func)),
    ) !void {
        var task = try self.spawnBlocking(func, args);
        task.detach();
    }

    // ───────────────────────────────────────────────────────────────────────────
    // Waiting
    // ───────────────────────────────────────────────────────────────────────────

    /// Wait for all tasks to complete.
    ///
    /// Returns the first error encountered by any task, or success if all
    /// tasks completed without error.
    ///
    /// ```zig
    /// var scope = Scope{};
    /// defer scope.cancel();  // Clean up on early return
    ///
    /// try scope.go(task1, .{});
    /// try scope.go(task2, .{});
    /// try scope.wait();  // Blocks until both complete
    /// ```
    pub fn wait(self: *Self) !void {
        // Mark closed - no more spawns
        self.close();

        // Wait for counter to reach 0 using futex
        const state_ptr: *std.atomic.Value(u32) = &self.state;

        while (true) {
            const state_val = state_ptr.load(.acquire);
            const state = State.fromU32(state_val);
            if (state.counter == 0) break;

            // Use futex to wait for state change
            // Tasks decrement counter and wake on completion
            std.Thread.Futex.wait(state_ptr, state_val);
        }

        // Return first error if any
        if (self.first_error) |err| {
            return err;
        }
    }

    /// Wait for all tasks with a timeout.
    ///
    /// Returns `error.Timeout` if the deadline is exceeded.
    /// On timeout, tasks are NOT automatically cancelled - call `cancel()` if needed.
    ///
    /// ```zig
    /// scope.waitTimeout(Duration.fromSeconds(5)) catch |err| switch (err) {
    ///     error.Timeout => {
    ///         scope.cancel();
    ///         return error.TooSlow;
    ///     },
    ///     else => |e| return e,
    /// };
    /// ```
    pub fn waitTimeout(self: *Self, timeout: Duration) !void {
        self.close();

        const deadline = Instant.now().add(timeout);
        const state_ptr: *std.atomic.Value(u32) = &self.state;

        while (true) {
            const state_val = state_ptr.load(.acquire);
            const state = State.fromU32(state_val);
            if (state.counter == 0) break;

            const now = Instant.now();
            if (now.order(deadline) != .lt) {
                return error.Timeout;
            }

            const remaining = deadline.since(now);

            // Futex wait with timeout (timeout in nanoseconds)
            _ = std.Thread.Futex.timedWait(state_ptr, state_val, remaining.asNanos()) catch {};
        }

        if (self.first_error) |err| {
            return err;
        }
    }

    // ───────────────────────────────────────────────────────────────────────────
    // Cancellation
    // ───────────────────────────────────────────────────────────────────────────

    /// Cancel all pending tasks and wait for them to complete.
    ///
    /// Tasks observe cancellation at yield points and exit early.
    /// Safe to call multiple times. Safe to use with `defer`.
    ///
    /// ```zig
    /// var scope = Scope{};
    /// defer scope.cancel();  // Clean up on any exit path
    ///
    /// try scope.go(task1, .{});
    /// try scope.go(task2, .{});
    /// // ... if we return early, cancel() runs via defer
    /// try scope.wait();
    /// ```
    pub fn cancel(self: *Self) void {
        // Set cancelled flag
        var state = State.fromU32(self.state.load(.acquire));
        state.cancelled = true;
        state.closed = true;
        _ = self.state.fetchOr(state.toU32(), .acq_rel);

        // Wait for all tasks (they'll check cancellation and exit)
        self.wait() catch {};
    }

    /// Check if cancellation was requested.
    pub fn isCancelled(self: *const Self) bool {
        const state = State.fromU32(self.state.load(.acquire));
        return state.cancelled;
    }

    // ───────────────────────────────────────────────────────────────────────────
    // Configuration
    // ───────────────────────────────────────────────────────────────────────────

    /// Enable fail-fast mode: cancel remaining tasks on first error.
    ///
    /// When any task returns an error, all other tasks are cancelled
    /// immediately rather than waiting for them to complete.
    ///
    /// ```zig
    /// var scope = Scope{};
    /// scope.setFailFast();
    ///
    /// try scope.go(mightFail1, .{});
    /// try scope.go(mightFail2, .{});
    /// // If one fails, the other is cancelled
    /// scope.wait() catch |err| { ... };
    /// ```
    pub fn setFailFast(self: *Self) void {
        var state = State.fromU32(self.state.load(.acquire));
        state.fail_fast = true;
        _ = self.state.fetchOr(state.toU32(), .acq_rel);
    }

    /// Check if fail-fast is enabled.
    pub fn isFailFast(self: *const Self) bool {
        const state = State.fromU32(self.state.load(.acquire));
        return state.fail_fast;
    }

    /// Check if any task has failed.
    pub fn hasFailed(self: *const Self) bool {
        const state = State.fromU32(self.state.load(.acquire));
        return state.failed;
    }

    /// Get the number of pending tasks.
    pub fn pending(self: *const Self) u28 {
        const state = State.fromU32(self.state.load(.acquire));
        return state.counter;
    }

    // ───────────────────────────────────────────────────────────────────────────
    // Internal
    // ───────────────────────────────────────────────────────────────────────────

    fn incrementCounter(self: *Self) void {
        _ = self.state.fetchAdd(State.COUNTER_ONE, .acq_rel);
    }

    fn decrementCounter(self: *Self) void {
        const prev = self.state.fetchSub(State.COUNTER_ONE, .acq_rel);
        const prev_state = State.fromU32(prev);

        // If this was the last task, wake waiters
        if (prev_state.counter == 1) {
            std.Thread.Futex.wake(&self.state, std.math.maxInt(u32));
        }
    }

    fn close(self: *Self) void {
        var state = State.fromU32(0);
        state.closed = true;
        _ = self.state.fetchOr(state.toU32(), .acq_rel);
    }

    fn captureError(self: *Self, err: anyerror) void {
        self.error_mutex.lock();
        defer self.error_mutex.unlock();

        // Only capture first error
        if (self.first_error == null) {
            self.first_error = err;
        }

        // Set failed flag
        var state = State.fromU32(0);
        state.failed = true;
        const prev = self.state.fetchOr(state.toU32(), .acq_rel);

        // If fail-fast, trigger cancellation
        const prev_state = State.fromU32(prev);
        if (prev_state.fail_fast and !prev_state.cancelled) {
            self.cancel();
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Blocking Task Context Header
// ═══════════════════════════════════════════════════════════════════════════════

/// Common header for blocking task contexts.
/// This is embedded at the start of every blocking task context struct.
pub fn BlockingContextHeader(comptime T: type) type {
    return struct {
        result: ?T = null,
        completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        scope: *Scope,
        allocator: Allocator,
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
// Blocking Task Handle
// ═══════════════════════════════════════════════════════════════════════════════

/// Handle to a blocking task's result.
pub fn BlockingTask(comptime T: type) type {
    return struct {
        const Self = @This();
        const CtxHeader = BlockingContextHeader(T);

        header: *CtxHeader,
        consumed: bool = false,

        /// Wait for the blocking task to complete and return its result.
        pub fn await(self: *Self) T {
            if (self.consumed) {
                @panic("BlockingTask.await() called on already-consumed handle");
            }
            self.consumed = true;

            // Wait for completion
            while (!self.header.completed.load(.acquire)) {
                std.Thread.yield() catch {};
            }

            const result = self.header.result orelse @panic("Blocking task completed without result");

            return result;
        }

        /// Check if complete without blocking.
        pub fn poll(self: *Self) ?T {
            if (self.consumed) return null;

            if (!self.header.completed.load(.acquire)) return null;

            self.consumed = true;
            return self.header.result;
        }

        /// Detach - result will be discarded when complete.
        pub fn detach(self: *Self) void {
            if (self.consumed) return;
            self.consumed = true;
            // Context will be cleaned up when task completes
        }
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
// Scoped Task - Task type that integrates with Scope
// ═══════════════════════════════════════════════════════════════════════════════

/// A task that belongs to a scope and decrements the counter on completion.
fn ScopedTask(comptime Result: type, comptime Args: type) type {
    return struct {
        const Self = @This();

        /// Wrapper function type: takes scope and args, returns optional result
        /// (null means error was captured to scope)
        const WrapperFuncPtr = *const fn (*Scope, Args) ?Result;

        /// Task header for scheduler
        header: Header,

        /// Wrapper function to call (handles error capture)
        wrapper_func: ?WrapperFuncPtr = null,

        /// Arguments
        args: Args,

        /// Result storage
        result: ?Result = null,

        /// Owning scope
        scope: *Scope,

        /// Runtime for scheduling
        runtime_ptr: ?*runtime_mod.Runtime = null,

        /// Allocator for cleanup
        allocator: Allocator,

        const vtable = Header.VTable{
            .poll = pollImpl,
            .drop = dropImpl,
            .get_output = getOutputImpl,
            .schedule = scheduleImpl,
        };

        pub fn init(args: Args, allocator: Allocator, scope: *Scope) Self {
            return .{
                .header = Header.init(&vtable, task_mod.nextTaskId()),
                .args = args,
                .scope = scope,
                .allocator = allocator,
            };
        }

        pub fn setWrapperFunc(self: *Self, func: WrapperFuncPtr, scope: *Scope) void {
            self.wrapper_func = func;
            self.scope = scope;
        }

        pub fn setRuntime(self: *Self, rt: *runtime_mod.Runtime) void {
            self.runtime_ptr = rt;
        }

        fn pollImpl(header: *Header) bool {
            const self: *Self = @fieldParentPtr("header", header);

            // Check if cancelled
            if (header.isCancelled() or self.scope.isCancelled()) {
                // Clean up and mark complete
                self.scope.decrementCounter();
                return true;
            }

            // Execute wrapper function (handles errors internally)
            if (self.wrapper_func) |wrapper| {
                self.result = wrapper(self.scope, self.args);
            }

            // Decrement scope counter
            self.scope.decrementCounter();

            return true; // Task complete
        }

        fn dropImpl(header: *Header) void {
            const self: *Self = @fieldParentPtr("header", header);
            self.allocator.destroy(self);
        }

        fn getOutputImpl(header: *Header) ?*anyopaque {
            const self: *Self = @fieldParentPtr("header", header);
            if (self.result) |*r| {
                return @ptrCast(r);
            }
            return null;
        }

        fn scheduleImpl(header: *Header) void {
            const self: *Self = @fieldParentPtr("header", header);
            if (self.runtime_ptr) |rt| {
                rt.getScheduler().spawn(header);
            }
        }
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════════════════

fn ReturnType(comptime Func: type) type {
    const info = @typeInfo(Func);
    const fn_info = if (info == .pointer)
        @typeInfo(info.pointer.child).@"fn"
    else
        info.@"fn";

    const ret = fn_info.return_type.?;

    // Unwrap error union for result type
    if (@typeInfo(ret) == .error_union) {
        return @typeInfo(ret).error_union.payload;
    }
    return ret;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Errors
// ═══════════════════════════════════════════════════════════════════════════════

pub const ScopeError = error{
    /// Scope is closed - no more spawns allowed after wait() starts
    ScopeClosed,
    /// Operation timed out
    Timeout,
    /// Cancellation was requested
    Cancelled,
};

// ═══════════════════════════════════════════════════════════════════════════════
// Convenience Functions
// ═══════════════════════════════════════════════════════════════════════════════

/// Run a function with an auto-cleaned scope.
///
/// The scope is automatically cancelled on any exit path (success, error, or panic).
///
/// ```zig
/// const result = try scoped(allocator, struct {
///     pub fn run(s: *Scope) !u32 {
///         const a = try s.spawn(compute, .{1});
///         const b = try s.spawn(compute, .{2});
///         try s.wait();
///         return a.await() + b.await();
///     }
/// }.run);
/// ```
pub fn scoped(allocator: Allocator, comptime func: anytype) !ReturnTypeOf(func) {
    _ = allocator;
    var scope = Scope{};
    defer scope.cancel();

    return try func(&scope);
}

fn ReturnTypeOf(comptime func: anytype) type {
    const info = @typeInfo(@TypeOf(func));
    const ret = info.@"fn".return_type.?;
    if (@typeInfo(ret) == .error_union) {
        return ret;
    }
    return ret;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

test "Scope - state packing" {
    // Verify state packing works correctly
    var state = State{ .counter = 100, .cancelled = true, .fail_fast = true };
    const packed_val = state.toU32();
    const unpacked = State.fromU32(packed_val);

    try std.testing.expectEqual(@as(u28, 100), unpacked.counter);
    try std.testing.expect(unpacked.cancelled);
    try std.testing.expect(unpacked.fail_fast);
    try std.testing.expect(!unpacked.failed);
    try std.testing.expect(!unpacked.closed);
}

test "Scope - init and flags" {
    var scope = Scope{};

    try std.testing.expect(!scope.isCancelled());
    try std.testing.expect(!scope.hasFailed());
    try std.testing.expect(!scope.isFailFast());
    try std.testing.expectEqual(@as(u28, 0), scope.pending());

    scope.setFailFast();
    try std.testing.expect(scope.isFailFast());
}

test "Scope - counter increment/decrement" {
    var scope = Scope{};

    scope.incrementCounter();
    try std.testing.expectEqual(@as(u28, 1), scope.pending());

    scope.incrementCounter();
    try std.testing.expectEqual(@as(u28, 2), scope.pending());

    scope.decrementCounter();
    try std.testing.expectEqual(@as(u28, 1), scope.pending());

    scope.decrementCounter();
    try std.testing.expectEqual(@as(u28, 0), scope.pending());
}

test "Scope - empty wait succeeds" {
    var scope = Scope{};
    try scope.wait();
}
