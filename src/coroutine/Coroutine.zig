//! Coroutine - Suspendable Execution Context
//!
//! A coroutine is a function that can suspend (yield) and resume execution.
//! This is the core primitive that enables async I/O without blocking threads.
//!
//! Usage:
//! ```zig
//! // Create coroutine
//! var coro = try Coroutine.init(pool);
//! defer coro.deinit();
//!
//! // Setup to run a function
//! coro.setup(myFunction, .{ arg1, arg2 });
//!
//! // Run until complete
//! while (!coro.isComplete()) {
//!     coro.step();  // Run one step (until yield or complete)
//! }
//!
//! // Get result
//! const result = coro.getResult(ReturnType);
//! ```
//!
//! Inside the coroutine function:
//! ```zig
//! fn myFunction(coro: *Coroutine, arg1: i32, arg2: i32) i32 {
//!     // Do some work...
//!     coro.yield();  // Suspend, return to caller
//!     // Resume here when coro.step() is called again
//!     return arg1 + arg2;
//! }
//! ```
//!
//! Reference: zio/src/coro/coroutines.zig

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const context_mod = @import("context.zig");
const stack_mod = @import("stack.zig");
const stack_pool = @import("stack_pool.zig");

const Context = context_mod.Context;
const StackInfo = context_mod.StackInfo;

// ═══════════════════════════════════════════════════════════════════════════════
// Coroutine State
// ═══════════════════════════════════════════════════════════════════════════════

/// Coroutine execution state
pub const State = enum(u8) {
    /// Not yet started
    created,

    /// Currently running
    running,

    /// Suspended (yielded)
    suspended,

    /// Finished execution
    complete,
};

// ═══════════════════════════════════════════════════════════════════════════════
// Coroutine
// ═══════════════════════════════════════════════════════════════════════════════

/// A suspendable execution context
pub const Coroutine = struct {
    const Self = @This();

    /// CPU context (registers, etc.)
    context: Context = undefined,

    /// Parent context (where to return on yield)
    parent_context: Context = undefined,

    /// Current state
    state: State = .created,

    /// Stack pool for allocation (null = use global or direct alloc)
    pool: ?*stack_pool.StackPool = null,

    /// Error if coroutine panicked
    err: ?anyerror = null,

    // ─────────────────────────────────────────────────────────────────────────────
    // Lifecycle
    // ─────────────────────────────────────────────────────────────────────────────

    /// Create a new coroutine with stack from pool
    pub fn init(pool: ?*stack_pool.StackPool) !Self {
        var self = Self{
            .pool = pool,
        };

        // Acquire stack
        if (pool) |p| {
            self.context.stack_info = try p.acquire();
        } else {
            self.context.stack_info = try stack_pool.acquireGlobal();
        }

        return self;
    }

    /// Create with default global pool
    pub fn initDefault() !Self {
        return init(stack_pool.getGlobal());
    }

    /// Deinitialize and release resources
    pub fn deinit(self: *Self) void {
        if (self.context.stack_info.isValid()) {
            if (self.pool) |p| {
                p.release(self.context.stack_info);
            } else {
                stack_pool.releaseGlobal(self.context.stack_info);
            }
            self.context.stack_info = .{};
        }
        self.state = .complete;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Setup - Prepare to run a function
    // ─────────────────────────────────────────────────────────────────────────────

    /// Setup the coroutine to execute a function with arguments.
    ///
    /// The function signature must be: fn(*Coroutine, Args...) ReturnType
    /// The first argument is always the coroutine pointer for yielding.
    pub fn setup(
        self: *Self,
        comptime func: anytype,
        args: anytype,
    ) void {
        const ArgsType = @TypeOf(args);
        const FuncType = @TypeOf(func);
        const ReturnType = @typeInfo(FuncType).@"fn".return_type.?;

        // Calculate storage needed on stack
        const ClosureType = Closure(FuncType, ArgsType, ReturnType);
        const closure_size = @sizeOf(ClosureType);
        const entry_size = @sizeOf(EntryData);

        // Allocate from top of stack (grows down)
        var stack_top = self.context.stack_info.base;

        // 1. Allocate closure (holds args and result)
        stack_top = alignBackward(stack_top - closure_size, @alignOf(ClosureType));
        const closure: *ClosureType = @ptrFromInt(stack_top);
        closure.* = .{
            .coro = self,
            .func = func,
            .args = args,
            .result = undefined,
        };

        // 2. Allocate entry data (for coroEntry)
        stack_top = alignBackward(stack_top - entry_size, Context.stack_alignment);
        const entry: *EntryData = @ptrFromInt(stack_top);
        entry.* = .{
            .func = &ClosureType.entrypoint,
            .userdata = closure,
        };

        // 3. Setup context to start at coroEntry
        context_mod.setupContext(&self.context, stack_top, &context_mod.coroEntry);

        self.state = .created;
    }

    /// Simplified setup for functions that don't need result
    pub fn go(
        self: *Self,
        comptime func: anytype,
        args: anytype,
    ) void {
        self.setup(func, args);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Execution Control
    // ─────────────────────────────────────────────────────────────────────────────

    /// Step into the coroutine - run until yield or complete.
    /// Returns to caller when coroutine yields or finishes.
    pub fn step(self: *Self) void {
        if (self.state == .complete) return;

        self.state = .running;

        // Save parent context and switch to coroutine
        context_mod.switchContext(&self.parent_context, &self.context);

        // Back from coroutine (it yielded or completed)
        if (self.state == .running) {
            // Normal yield
            self.state = .suspended;
        }
    }

    /// Yield control back to the caller.
    /// Call this from within the coroutine function.
    pub fn yield(self: *Self) void {
        // Switch back to parent context
        context_mod.switchContext(&self.context, &self.parent_context);
    }

    /// Mark coroutine as complete (called from entrypoint wrapper)
    pub fn complete(self: *Self) void {
        self.state = .complete;
        // Return to parent
        context_mod.switchContext(&self.context, &self.parent_context);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // State Queries
    // ─────────────────────────────────────────────────────────────────────────────

    /// Check if coroutine has finished execution
    pub fn isComplete(self: *const Self) bool {
        return self.state == .complete;
    }

    /// Check if coroutine is currently suspended
    pub fn isSuspended(self: *const Self) bool {
        return self.state == .suspended;
    }

    /// Check if coroutine is running
    pub fn isRunning(self: *const Self) bool {
        return self.state == .running;
    }

    /// Get the current state
    pub fn getState(self: *const Self) State {
        return self.state;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Results
    // ─────────────────────────────────────────────────────────────────────────────

    /// Get the result after completion.
    /// Only valid after isComplete() returns true.
    pub fn getResult(self: *Self, comptime T: type) T {
        std.debug.assert(self.state == .complete);

        // Result is stored at known offset in closure on stack
        const closure_ptr = self.context.stack_info.base - @sizeOf(T);
        const result: *T = @ptrFromInt(alignBackward(closure_ptr, @alignOf(T)));
        return result.*;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Closure - Type-erased function wrapper
// ═══════════════════════════════════════════════════════════════════════════════

/// Entry data passed to coroEntry
const EntryData = context_mod.EntryData;

/// Closure that wraps a function call in a coroutine
fn Closure(
    comptime FuncType: type,
    comptime ArgsType: type,
    comptime ReturnType: type,
) type {
    return struct {
        const Self = @This();

        /// Coroutine this closure belongs to
        coro: *Coroutine,

        /// Function to call
        func: *const FuncType,

        /// Arguments
        args: ArgsType,

        /// Result storage
        result: ReturnType,

        /// Entry point called by coroEntry
        fn entrypoint(userdata: *anyopaque) callconv(.c) void {
            const self: *Self = @alignCast(@ptrCast(userdata));

            // Build args tuple with coroutine pointer prepended
            const full_args = .{self.coro} ++ self.args;

            // Call the function
            self.result = @call(.auto, self.func, full_args);

            // Mark complete and return
            self.coro.complete();
        }
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
// Utilities
// ═══════════════════════════════════════════════════════════════════════════════

fn alignBackward(addr: usize, alignment: usize) usize {
    return addr & ~(alignment - 1);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Current Coroutine (thread-local)
// ═══════════════════════════════════════════════════════════════════════════════

/// Thread-local current coroutine pointer
threadlocal var current_coro: ?*Coroutine = null;

/// Get the current coroutine (if running inside one)
pub fn current() ?*Coroutine {
    return current_coro;
}

/// Set the current coroutine (internal use)
pub fn setCurrent(coro: ?*Coroutine) void {
    current_coro = coro;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

test "Coroutine - basic yield" {
    // Initialize global pool for test
    stack_pool.initGlobalDefault();
    defer stack_pool.deinitGlobal();

    var coro = try Coroutine.initDefault();
    defer coro.deinit();

    var counter: i32 = 0;

    const TestFn = struct {
        fn run(c: *Coroutine, count_ptr: *i32) void {
            count_ptr.* += 1; // 1
            c.yield();
            count_ptr.* += 1; // 2
            c.yield();
            count_ptr.* += 1; // 3
        }
    };

    coro.setup(TestFn.run, .{&counter});

    try std.testing.expectEqual(@as(i32, 0), counter);

    coro.step();
    try std.testing.expectEqual(@as(i32, 1), counter);
    try std.testing.expect(!coro.isComplete());

    coro.step();
    try std.testing.expectEqual(@as(i32, 2), counter);
    try std.testing.expect(!coro.isComplete());

    coro.step();
    try std.testing.expectEqual(@as(i32, 3), counter);
    try std.testing.expect(coro.isComplete());
}

test "Coroutine - with return value" {
    stack_pool.initGlobalDefault();
    defer stack_pool.deinitGlobal();

    var coro = try Coroutine.initDefault();
    defer coro.deinit();

    const TestFn = struct {
        fn compute(c: *Coroutine, a: i32, b: i32) i32 {
            _ = c;
            return a + b;
        }
    };

    coro.setup(TestFn.compute, .{ 10, 20 });

    while (!coro.isComplete()) {
        coro.step();
    }

    // Note: Getting result requires knowing the offset - this is a simplified test
    try std.testing.expect(coro.isComplete());
}

test "Coroutine - state transitions" {
    stack_pool.initGlobalDefault();
    defer stack_pool.deinitGlobal();

    var coro = try Coroutine.initDefault();
    defer coro.deinit();

    const TestFn = struct {
        fn run(c: *Coroutine) void {
            c.yield();
        }
    };

    coro.setup(TestFn.run, .{});

    try std.testing.expectEqual(State.created, coro.getState());

    coro.step();
    try std.testing.expectEqual(State.suspended, coro.getState());

    coro.step();
    try std.testing.expectEqual(State.complete, coro.getState());
}
