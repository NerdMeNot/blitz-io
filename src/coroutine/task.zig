//! Task - Scheduler-Integrated Coroutine Wrapper
//!
//! A Task wraps a Coroutine with:
//! - Packed atomic state for lock-free transitions
//! - Reference counting for safe memory management
//! - Intrusive list pointers for scheduler queues
//! - Wait queue for join operations
//!
//! State Machine:
//! ```
//!   IDLE ──spawn──> SCHEDULED ──run──> RUNNING ──yield──> IDLE
//!     │                                    │                │
//!     │                                    ▼                │
//!     └────────────────────────────── COMPLETE <────────────┘
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

const coroutine_mod = @import("coroutine.zig");
const Coroutine = coroutine_mod.Coroutine;
const stack_pool = @import("stack_pool.zig");

// ═══════════════════════════════════════════════════════════════════════════════
// Task State (Packed Atomic)
// ═══════════════════════════════════════════════════════════════════════════════

/// Task lifecycle state
pub const Lifecycle = enum(u8) {
    /// Not scheduled, waiting for work or I/O
    idle = 0,
    /// In a run queue, waiting to execute
    scheduled = 1,
    /// Currently executing on a worker
    running = 2,
    /// Finished execution
    complete = 3,
};

/// Packed task state for atomic operations
/// Layout: | ref_count (24 bits) | shield_depth (8 bits) | flags (8 bits) | lifecycle (8 bits) | unused (16 bits) |
///
/// Shield-based cancellation:
/// When shield_depth > 0, cancellation is deferred. The CANCELLED flag
/// can still be set, but isCancelled() returns false until all shields
/// are dropped. This protects critical sections from partial execution.
///
/// Example:
/// ```zig
/// header.beginShield();
/// defer header.endShield();
/// // This section completes even if cancel() is called
/// try db.beginTransaction();
/// try db.execute(query);
/// try db.commit();
/// ```
pub const State = packed struct(u64) {
    /// Reserved for future use
    _reserved: u16 = 0,

    /// Current lifecycle state
    lifecycle: Lifecycle = .idle,

    /// Flags
    notified: bool = false,
    cancelled: bool = false,
    join_interest: bool = false,
    detached: bool = false,
    _flag_reserved: u4 = 0,

    /// Shield depth (0-255) - cancellation deferred while > 0
    shield_depth: u8 = 0,

    /// Reference count (24 bits = 16 million refs, plenty)
    ref_count: u24 = 1,

    const REF_ONE: u64 = 1 << 40;
    const SHIELD_ONE: u64 = 1 << 32;

    pub fn toU64(self: State) u64 {
        return @bitCast(self);
    }

    pub fn fromU64(val: u64) State {
        return @bitCast(val);
    }

    pub fn addRef(self: State) State {
        var s = self;
        s.ref_count += 1;
        return s;
    }

    pub fn decRef(self: State) State {
        var s = self;
        s.ref_count -= 1;
        return s;
    }

    /// Check if cancellation is currently effective (not shielded)
    pub fn isCancellationEffective(self: State) bool {
        return self.cancelled and self.shield_depth == 0;
    }

    /// Add a shield level
    pub fn addShield(self: State) State {
        var s = self;
        if (s.shield_depth < 255) {
            s.shield_depth += 1;
        }
        return s;
    }

    /// Remove a shield level
    pub fn removeShield(self: State) State {
        var s = self;
        if (s.shield_depth > 0) {
            s.shield_depth -= 1;
        }
        return s;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Task Header (Type-Erased)
// ═══════════════════════════════════════════════════════════════════════════════

/// Type-erased task header for scheduler queues
pub const Header = struct {
    /// Packed atomic state
    state: std.atomic.Value(u64),

    /// Intrusive list pointers (for scheduler queues)
    next: ?*Header = null,
    prev: ?*Header = null,

    /// VTable for type-erased operations
    vtable: *const VTable,

    pub const VTable = struct {
        /// Run one step of the task
        poll: *const fn (*Header) PollResult,
        /// Clean up and free the task
        drop: *const fn (*Header) void,
        /// Wake the task (schedule it)
        schedule: *const fn (*Header) void,
    };

    /// Result of polling a task
    pub const PollResult = enum {
        /// Task yielded, needs more work
        pending,
        /// Task completed
        complete,
    };

    /// Initialize header with vtable
    pub fn init(vtable: *const VTable) Header {
        return .{
            .state = std.atomic.Value(u64).init((State{}).toU64()),
            .vtable = vtable,
        };
    }

    // ─────────────────────────────────────────────────────────────────────────
    // State Transitions
    // ─────────────────────────────────────────────────────────────────────────

    /// Transition to scheduled state. Returns true if successful.
    pub fn transitionToScheduled(self: *Header) bool {
        var current = State.fromU64(self.state.load(.acquire));

        while (true) {
            // Can only schedule from idle
            if (current.lifecycle != .idle) {
                // If running, set notified flag instead
                if (current.lifecycle == .running) {
                    var new = current;
                    new.notified = true;
                    if (self.state.cmpxchgWeak(current.toU64(), new.toU64(), .acq_rel, .acquire)) |updated| {
                        current = State.fromU64(updated);
                        continue;
                    }
                    return false; // Notified instead of scheduled
                }
                return false;
            }

            if (current.cancelled or current.lifecycle == .complete) {
                return false;
            }

            var new = current;
            new.lifecycle = .scheduled;
            new.notified = false;

            if (self.state.cmpxchgWeak(current.toU64(), new.toU64(), .acq_rel, .acquire)) |updated| {
                current = State.fromU64(updated);
                continue;
            }
            return true;
        }
    }

    /// Transition to running state. Returns true if successful.
    pub fn transitionToRunning(self: *Header) bool {
        var current = State.fromU64(self.state.load(.acquire));

        while (true) {
            if (current.lifecycle != .scheduled) {
                return false;
            }

            var new = current;
            new.lifecycle = .running;

            if (self.state.cmpxchgWeak(current.toU64(), new.toU64(), .acq_rel, .acquire)) |updated| {
                current = State.fromU64(updated);
                continue;
            }
            return true;
        }
    }

    /// Transition to idle state. Returns previous state.
    pub fn transitionToIdle(self: *Header) State {
        var current = State.fromU64(self.state.load(.acquire));

        while (true) {
            if (current.lifecycle != .running) {
                return current;
            }

            var new = current;
            new.lifecycle = .idle;

            if (self.state.cmpxchgWeak(current.toU64(), new.toU64(), .acq_rel, .acquire)) |updated| {
                current = State.fromU64(updated);
                continue;
            }
            return current;
        }
    }

    /// Mark task as complete
    pub fn transitionToComplete(self: *Header) void {
        var current = State.fromU64(self.state.load(.acquire));

        while (true) {
            var new = current;
            new.lifecycle = .complete;

            if (self.state.cmpxchgWeak(current.toU64(), new.toU64(), .acq_rel, .acquire)) |updated| {
                current = State.fromU64(updated);
                continue;
            }
            return;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Reference Counting
    // ─────────────────────────────────────────────────────────────────────────

    /// Increment reference count
    pub fn ref(self: *Header) void {
        _ = self.state.fetchAdd(State.REF_ONE, .acq_rel);
    }

    /// Decrement reference count. Returns true if this was the last reference.
    pub fn unref(self: *Header) bool {
        const prev = self.state.fetchSub(State.REF_ONE, .acq_rel);
        const prev_state = State.fromU64(prev);
        return prev_state.ref_count == 1;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // State Queries
    // ─────────────────────────────────────────────────────────────────────────

    pub fn isComplete(self: *Header) bool {
        return State.fromU64(self.state.load(.acquire)).lifecycle == .complete;
    }

    /// Check if task is effectively cancelled (cancelled AND not shielded)
    pub fn isCancelled(self: *Header) bool {
        const state = State.fromU64(self.state.load(.acquire));
        return state.isCancellationEffective();
    }

    /// Check if cancellation was requested (ignoring shield)
    pub fn isCancellationRequested(self: *Header) bool {
        return State.fromU64(self.state.load(.acquire)).cancelled;
    }

    pub fn isNotified(self: *Header) bool {
        return State.fromU64(self.state.load(.acquire)).notified;
    }

    pub fn clearNotified(self: *Header) bool {
        var current = State.fromU64(self.state.load(.acquire));
        while (current.notified) {
            var new = current;
            new.notified = false;
            if (self.state.cmpxchgWeak(current.toU64(), new.toU64(), .acq_rel, .acquire)) |updated| {
                current = State.fromU64(updated);
                continue;
            }
            return true;
        }
        return false;
    }

    /// Request cancellation
    pub fn cancel(self: *Header) bool {
        var current = State.fromU64(self.state.load(.acquire));
        while (true) {
            if (current.cancelled or current.lifecycle == .complete) {
                return false;
            }

            var new = current;
            new.cancelled = true;

            if (self.state.cmpxchgWeak(current.toU64(), new.toU64(), .acq_rel, .acquire)) |updated| {
                current = State.fromU64(updated);
                continue;
            }
            return true;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Shield-based Cancellation
    // ─────────────────────────────────────────────────────────────────────────

    /// Begin a cancellation-shielded section.
    /// While shielded, isCancelled() returns false even if cancel() was called.
    /// Use for critical sections that must complete atomically.
    ///
    /// Example:
    /// ```zig
    /// header.beginShield();
    /// defer header.endShield();
    /// try db.beginTransaction();
    /// try db.execute(query);
    /// try db.commit();
    /// ```
    pub fn beginShield(self: *Header) void {
        _ = self.state.fetchAdd(State.SHIELD_ONE, .acq_rel);
    }

    /// End a cancellation-shielded section.
    /// If cancellation was requested while shielded, it becomes effective now.
    pub fn endShield(self: *Header) void {
        _ = self.state.fetchSub(State.SHIELD_ONE, .acq_rel);
    }

    /// Get current shield depth (for debugging)
    pub fn shieldDepth(self: *Header) u8 {
        return State.fromU64(self.state.load(.acquire)).shield_depth;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Operations
    // ─────────────────────────────────────────────────────────────────────────

    /// Poll the task (run one step)
    pub fn poll(self: *Header) PollResult {
        return self.vtable.poll(self);
    }

    /// Schedule the task for execution
    pub fn schedule(self: *Header) void {
        self.vtable.schedule(self);
    }

    /// Drop the task (clean up resources)
    pub fn drop(self: *Header) void {
        self.vtable.drop(self);
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Task - Concrete Implementation
// ═══════════════════════════════════════════════════════════════════════════════

/// Concrete task wrapping a coroutine
pub fn Task(comptime F: type, comptime Args: type) type {
    const FnInfo = @typeInfo(F).@"fn";
    const Result = FnInfo.return_type.?;

    return struct {
        const Self = @This();

        /// Task header (must be first for pointer casting)
        header: Header,

        /// The coroutine
        coro: Coroutine,

        /// Function to execute
        func: *const F,

        /// Arguments
        args: Args,

        /// Result storage
        result: ?Result = null,

        /// Error if failed
        err: ?anyerror = null,

        /// Allocator for cleanup
        allocator: Allocator,

        /// Scheduler reference (for re-scheduling)
        scheduler: ?*anyopaque = null,
        schedule_fn: ?*const fn (*anyopaque, *Header) void = null,

        const vtable = Header.VTable{
            .poll = pollImpl,
            .drop = dropImpl,
            .schedule = scheduleImpl,
        };

        /// Create a new task
        pub fn create(allocator: Allocator, func: *const F, args: Args) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = .{
                .header = Header.init(&vtable),
                .coro = try Coroutine.initDefault(),
                .func = func,
                .args = args,
                .allocator = allocator,
            };

            // Setup coroutine to run our wrapper
            self.coro.setup(runWrapper, .{self});

            return self;
        }

        /// Set the scheduler for re-scheduling
        pub fn setScheduler(self: *Self, scheduler: *anyopaque, schedule_fn: *const fn (*anyopaque, *Header) void) void {
            self.scheduler = scheduler;
            self.schedule_fn = schedule_fn;
        }

        /// Get result (only valid after complete)
        pub fn getResult(self: *Self) ?Result {
            return self.result;
        }

        /// Get error (only valid after complete with error)
        pub fn getError(self: *Self) ?anyerror {
            return self.err;
        }

        // ─────────────────────────────────────────────────────────────────────
        // VTable Implementations
        // ─────────────────────────────────────────────────────────────────────

        fn pollImpl(header: *Header) Header.PollResult {
            const self: *Self = @fieldParentPtr("header", header);

            // Check cancellation
            if (header.isCancelled()) {
                self.err = error.Cancelled;
                return .complete;
            }

            // Run one step
            self.coro.step();

            // Check if complete
            if (self.coro.isComplete()) {
                return .complete;
            }

            return .pending;
        }

        fn dropImpl(header: *Header) void {
            const self: *Self = @fieldParentPtr("header", header);
            self.coro.deinit();
            self.allocator.destroy(self);
        }

        fn scheduleImpl(header: *Header) void {
            const self: *Self = @fieldParentPtr("header", header);
            if (self.scheduler) |sched| {
                if (self.schedule_fn) |schedule_fn| {
                    schedule_fn(sched, header);
                }
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Coroutine Wrapper
        // ─────────────────────────────────────────────────────────────────────

        fn runWrapper(coro: *Coroutine, self: *Self) void {
            // Build args tuple with coroutine pointer prepended
            const full_args = .{coro} ++ self.args;

            // Call the user function
            self.result = @call(.auto, self.func, full_args);
        }
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
// Task Queue (Intrusive MPSC)
// ═══════════════════════════════════════════════════════════════════════════════

/// Simple single-producer single-consumer queue (for local worker queues)
/// For cross-thread use, we'll use a mutex-protected version
pub const TaskQueue = struct {
    head: ?*Header = null,
    tail: ?*Header = null,
    len: usize = 0,

    pub fn init() TaskQueue {
        return .{};
    }

    /// Push a task to the back
    pub fn push(self: *TaskQueue, task: *Header) void {
        task.next = null;
        task.prev = self.tail;

        if (self.tail) |t| {
            t.next = task;
        } else {
            self.head = task;
        }
        self.tail = task;
        self.len += 1;
    }

    /// Pop a task from the front
    pub fn pop(self: *TaskQueue) ?*Header {
        const head = self.head orelse return null;

        self.head = head.next;
        if (self.head) |h| {
            h.prev = null;
        } else {
            self.tail = null;
        }

        head.next = null;
        head.prev = null;
        self.len -= 1;

        return head;
    }

    /// Check if empty
    pub fn isEmpty(self: *const TaskQueue) bool {
        return self.head == null;
    }

    /// Get length
    pub fn length(self: *const TaskQueue) usize {
        return self.len;
    }
};

/// Thread-safe task queue (for global queue)
pub const GlobalTaskQueue = struct {
    queue: TaskQueue = .{},
    mutex: std.Thread.Mutex = .{},

    pub fn init() GlobalTaskQueue {
        return .{};
    }

    pub fn push(self: *GlobalTaskQueue, task: *Header) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.queue.push(task);
    }

    pub fn pop(self: *GlobalTaskQueue) ?*Header {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.queue.pop();
    }

    pub fn isEmpty(self: *GlobalTaskQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.queue.isEmpty();
    }

    pub fn length(self: *GlobalTaskQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.queue.length();
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

test "State - pack/unpack" {
    var state = State{};
    state.lifecycle = .running;
    state.notified = true;
    state.ref_count = 5;

    const packed_val = state.toU64();
    const unpacked = State.fromU64(packed_val);

    try std.testing.expectEqual(Lifecycle.running, unpacked.lifecycle);
    try std.testing.expect(unpacked.notified);
    try std.testing.expectEqual(@as(u32, 5), unpacked.ref_count);
}

test "Header - state transitions" {
    const vtable = Header.VTable{
        .poll = struct {
            fn f(_: *Header) Header.PollResult {
                return .pending;
            }
        }.f,
        .drop = struct {
            fn f(_: *Header) void {}
        }.f,
        .schedule = struct {
            fn f(_: *Header) void {}
        }.f,
    };

    var header = Header.init(&vtable);

    // idle -> scheduled
    try std.testing.expect(header.transitionToScheduled());
    try std.testing.expectEqual(Lifecycle.scheduled, State.fromU64(header.state.load(.acquire)).lifecycle);

    // scheduled -> running
    try std.testing.expect(header.transitionToRunning());
    try std.testing.expectEqual(Lifecycle.running, State.fromU64(header.state.load(.acquire)).lifecycle);

    // running -> idle
    _ = header.transitionToIdle();
    try std.testing.expectEqual(Lifecycle.idle, State.fromU64(header.state.load(.acquire)).lifecycle);
}

test "Header - reference counting" {
    const vtable = Header.VTable{
        .poll = struct {
            fn f(_: *Header) Header.PollResult {
                return .pending;
            }
        }.f,
        .drop = struct {
            fn f(_: *Header) void {}
        }.f,
        .schedule = struct {
            fn f(_: *Header) void {}
        }.f,
    };

    var header = Header.init(&vtable);

    // Initial ref count is 1
    try std.testing.expectEqual(@as(u32, 1), State.fromU64(header.state.load(.acquire)).ref_count);

    header.ref();
    try std.testing.expectEqual(@as(u32, 2), State.fromU64(header.state.load(.acquire)).ref_count);

    try std.testing.expect(!header.unref()); // Not last ref
    try std.testing.expectEqual(@as(u32, 1), State.fromU64(header.state.load(.acquire)).ref_count);

    try std.testing.expect(header.unref()); // Last ref
}

test "TaskQueue - push/pop" {
    var queue = TaskQueue.init();

    const vtable = Header.VTable{
        .poll = struct {
            fn f(_: *Header) Header.PollResult {
                return .pending;
            }
        }.f,
        .drop = struct {
            fn f(_: *Header) void {}
        }.f,
        .schedule = struct {
            fn f(_: *Header) void {}
        }.f,
    };

    var h1 = Header.init(&vtable);
    var h2 = Header.init(&vtable);
    var h3 = Header.init(&vtable);

    queue.push(&h1);
    queue.push(&h2);
    queue.push(&h3);

    try std.testing.expectEqual(&h1, queue.pop());
    try std.testing.expectEqual(&h2, queue.pop());
    try std.testing.expectEqual(&h3, queue.pop());
    try std.testing.expectEqual(@as(?*Header, null), queue.pop());
}
