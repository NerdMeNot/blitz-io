//! Task Representation for Async Executor
//!
//! Tasks are stackless state machines with minimal overhead. This design is based on
//! Tokio's task system where tasks are:
//! 1. Type-erased through vtable function pointers
//! 2. Intrusive (contain their own linked list pointers)
//! 3. Reference-counted for safe cancellation
//!
//! The task lifecycle:
//! 1. Created with `init()` - task is IDLE
//! 2. Scheduled with `schedule()` - task is SCHEDULED
//! 3. Polled with `poll()` - task is RUNNING
//! 4. Either completes (COMPLETE) or yields (back to SCHEDULED)
//! 5. Cleaned up with `drop()` when ref count hits 0
//!
//! OPTIMIZATION: Following Tokio, we pack state flags AND reference count into a
//! single atomic u64. This reduces the number of atomic operations needed for
//! state transitions.
//!
//! Layout (64 bits):
//! - Bits 0-15:  State flags (SCHEDULED, RUNNING, COMPLETE, etc.)
//! - Bits 16-63: Reference count (48 bits = 281 trillion refs, more than enough)
//!
//! Reference: tokio/src/runtime/task/state.rs

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Task header - the common prefix for all tasks.
/// This is what the scheduler sees and manipulates.
/// Cache-aligned to prevent false sharing.
///
/// Memory layout follows Tokio's hot/cold separation principle:
/// - Hot fields (state, vtable, queue_next) accessed frequently by scheduler
/// - Cold fields (owned_list pointers) only accessed during spawn/drop/shutdown
pub const Header = struct {
    // === HOT FIELDS (accessed by scheduler on every operation) ===

    /// Virtual table for type-erased operations
    vtable: *const VTable,

    /// Combined state + reference count (packed for single atomic ops)
    /// Lower 16 bits: state flags
    /// Upper 48 bits: reference count
    state_ref: std.atomic.Value(u64) align(8),

    /// Intrusive linked list pointer for run queue
    queue_next: std.atomic.Value(?*Header),

    /// ID for debugging and observability
    id: u64,

    // === COLD FIELDS (only accessed during spawn/drop/shutdown) ===

    /// Intrusive doubly-linked list pointers for OwnedTasks collection.
    /// This allows us to iterate all spawned tasks for graceful shutdown.
    /// Protected by OwnedTasks.mutex when accessed.
    owned_prev: ?*Header,
    owned_next: ?*Header,

    /// The vtable provides type-erased access to the concrete task.
    pub const VTable = struct {
        /// Poll the task, returning true if complete
        poll: *const fn (*Header) bool,

        /// Drop the task and deallocate
        drop: *const fn (*Header) void,

        /// Get the output type (for JoinHandle)
        /// Returns null if task not complete or was cancelled
        get_output: *const fn (*Header) ?*anyopaque,

        /// Schedule the task for execution
        schedule: *const fn (*Header) void,
    };

    /// Task state bits (lower 16 bits of state_ref)
    ///
    /// CRITICAL: The NOTIFIED flag is essential for correct wakeup semantics.
    /// Without it, if wake() is called while task is RUNNING, the wakeup is lost
    /// and the task sits idle until the next accidental poke or timeout.
    ///
    /// State machine:
    /// - IDLE: Task is waiting for external event (I/O, timer, etc.)
    /// - SCHEDULED: Task is in a run queue, waiting to be polled
    /// - RUNNING: Task is currently being polled by a worker
    /// - NOTIFIED: Wake was called while RUNNING - must re-poll after current poll
    /// - COMPLETE: Task finished successfully
    /// - CANCELLED: Task was cancelled
    pub const State = struct {
        /// Task is idle, not yet scheduled
        pub const IDLE: u64 = 0;
        /// Task is in the run queue
        pub const SCHEDULED: u64 = 1 << 0;
        /// Task is currently being polled
        pub const RUNNING: u64 = 1 << 1;
        /// Task has completed successfully
        pub const COMPLETE: u64 = 1 << 2;
        /// Task was cancelled
        pub const CANCELLED: u64 = 1 << 3;
        /// CRITICAL: Wakeup occurred while task was RUNNING
        /// This prevents "lost wakeups" - if wake() is called during poll(),
        /// we must re-poll immediately rather than going idle.
        pub const NOTIFIED: u64 = 1 << 4;

        /// Mask for state bits (lower 16 bits)
        pub const STATE_MASK: u64 = 0xFFFF;
        /// Shift for reference count (upper 48 bits)
        pub const REF_SHIFT: u6 = 16;
        /// One reference count unit
        pub const REF_ONE: u64 = 1 << REF_SHIFT;
    };

    /// Create a new task header with initial ref count of 1
    pub fn init(vtable: *const VTable, id: u64) Header {
        return .{
            .vtable = vtable,
            // Initial state: IDLE with ref count = 1
            .state_ref = std.atomic.Value(u64).init(State.REF_ONE),
            .queue_next = std.atomic.Value(?*Header).init(null),
            .id = id,
            // OwnedTasks list pointers - set when added to collection
            .owned_prev = null,
            .owned_next = null,
        };
    }

    /// Get current state flags (lower 16 bits)
    fn getState(packed_val: u64) u64 {
        return packed_val & State.STATE_MASK;
    }

    /// Get current ref count (upper 48 bits)
    fn getRefCount(packed_val: u64) u64 {
        return packed_val >> State.REF_SHIFT;
    }

    /// Increment reference count
    /// Uses monotonic ordering - safe because the caller must already hold a reference.
    /// Since refcount > 0, the memory is guaranteed valid. We're just incrementing
    /// a counter, not synchronizing with another thread's data access.
    /// This matches Rust's Arc which uses Relaxed (Monotonic) for increments.
    pub fn ref(self: *Header) void {
        const prev = self.state_ref.fetchAdd(State.REF_ONE, .monotonic);
        std.debug.assert(getRefCount(prev) > 0); // Cannot ref a dropped task
    }

    /// Decrement reference count, dropping if zero
    pub fn unref(self: *Header) void {
        // Use acq_rel to ensure all prior accesses are visible before drop
        const prev = self.state_ref.fetchSub(State.REF_ONE, .acq_rel);
        if (getRefCount(prev) == 1) {
            // Last reference dropped - safe to deallocate
            self.vtable.drop(self);
        }
    }

    /// Transition to scheduled state
    /// Returns true if task should be enqueued to a run queue.
    /// Returns false if task is complete/cancelled OR if task is running (NOTIFIED set instead).
    ///
    /// CRITICAL: If task is RUNNING, we set NOTIFIED instead of SCHEDULED.
    /// The worker polling the task will see NOTIFIED after poll() returns and
    /// immediately re-poll, preventing the "lost wakeup" problem.
    pub fn transitionToScheduled(self: *Header) bool {
        var current = self.state_ref.load(.acquire);
        while (true) {
            const state = getState(current);

            // Cannot schedule if complete or cancelled
            if (state & (State.COMPLETE | State.CANCELLED) != 0) {
                return false;
            }

            // Already scheduled - nothing to do
            if (state & State.SCHEDULED != 0) {
                return false;
            }

            // CRITICAL: If task is RUNNING, set NOTIFIED instead of SCHEDULED
            // The worker will check NOTIFIED after poll() and re-poll immediately
            if (state & State.RUNNING != 0) {
                const result = self.state_ref.cmpxchgWeak(
                    current,
                    current | State.NOTIFIED,
                    .acq_rel,
                    .acquire,
                );
                if (result) |new_val| {
                    current = new_val;
                    continue;
                }
                // Successfully set NOTIFIED - don't enqueue, worker will handle it
                return false;
            }

            // Task is IDLE - transition to SCHEDULED
            const result = self.state_ref.cmpxchgWeak(
                current,
                current | State.SCHEDULED,
                .acq_rel,
                .acquire,
            );
            if (result) |new_val| {
                current = new_val;
                continue;
            }
            return true;
        }
    }

    /// Transition from scheduled to running
    /// Returns true if transition was successful
    /// CRITICAL: Clears NOTIFIED flag - we'll check it after poll() completes
    pub fn transitionToRunning(self: *Header) bool {
        var current = self.state_ref.load(.acquire);
        while (true) {
            const state = getState(current);

            // Must be scheduled
            if (state & State.SCHEDULED == 0) {
                return false;
            }
            // Cannot run if cancelled
            if (state & State.CANCELLED != 0) {
                return false;
            }

            // Clear SCHEDULED, set RUNNING, clear NOTIFIED (we'll check after poll)
            const new_state = (state & ~(State.SCHEDULED | State.NOTIFIED)) | State.RUNNING;
            const new_val = (current & ~State.STATE_MASK) | new_state;

            const result = self.state_ref.cmpxchgWeak(
                current,
                new_val,
                .acq_rel,
                .acquire,
            );
            if (result) |v| {
                current = v;
                continue;
            }
            return true;
        }
    }

    /// Transition from running to complete
    pub fn transitionToComplete(self: *Header) void {
        var current = self.state_ref.load(.acquire);
        while (true) {
            const state = getState(current);
            const new_state = (state & ~State.RUNNING) | State.COMPLETE;
            const new_val = (current & ~State.STATE_MASK) | new_state;

            const result = self.state_ref.cmpxchgWeak(
                current,
                new_val,
                .acq_rel,
                .acquire,
            );
            if (result) |v| {
                current = v;
                continue;
            }
            break;
        }
    }

    /// Transition from running back to idle (yielded)
    /// Returns the state flags BEFORE clearing RUNNING, so caller can check NOTIFIED.
    ///
    /// CRITICAL: If NOTIFIED was set while we were RUNNING, the caller must
    /// immediately re-schedule the task rather than letting it go idle.
    /// This is how we prevent "lost wakeups".
    pub fn transitionToIdle(self: *Header) u64 {
        var current = self.state_ref.load(.acquire);
        while (true) {
            const state = getState(current);
            // Clear RUNNING but preserve NOTIFIED so caller can check it
            const new_state = state & ~State.RUNNING;
            const new_val = (current & ~State.STATE_MASK) | new_state;

            const result = self.state_ref.cmpxchgWeak(
                current,
                new_val,
                .acq_rel,
                .acquire,
            );
            if (result) |v| {
                current = v;
                continue;
            }
            // Return the state BEFORE we cleared RUNNING (includes NOTIFIED if set)
            return state;
        }
    }

    /// Clear the NOTIFIED flag after handling it
    pub fn clearNotified(self: *Header) void {
        _ = self.state_ref.fetchAnd(~State.NOTIFIED, .release);
    }

    /// Check if NOTIFIED flag is set
    pub fn isNotified(self: *const Header) bool {
        return getState(self.state_ref.load(.acquire)) & State.NOTIFIED != 0;
    }

    /// Check if task is complete
    pub fn isComplete(self: *const Header) bool {
        return getState(self.state_ref.load(.acquire)) & State.COMPLETE != 0;
    }

    /// Check if task is cancelled
    pub fn isCancelled(self: *const Header) bool {
        return getState(self.state_ref.load(.acquire)) & State.CANCELLED != 0;
    }

    /// Request cancellation
    /// Returns true if task was cancelled (wasn't already complete)
    pub fn cancel(self: *Header) bool {
        var current = self.state_ref.load(.acquire);
        while (true) {
            const state = getState(current);

            // Already complete or cancelled
            if (state & (State.COMPLETE | State.CANCELLED) != 0) {
                return false;
            }

            const result = self.state_ref.cmpxchgWeak(
                current,
                current | State.CANCELLED,
                .acq_rel,
                .acquire,
            );
            if (result) |v| {
                current = v;
                continue;
            }
            return true;
        }
    }

    /// Poll the task
    /// Returns true if the task completed
    pub fn poll(self: *Header) bool {
        return self.vtable.poll(self);
    }

    /// Schedule the task (via vtable callback to scheduler)
    pub fn schedule(self: *Header) void {
        self.vtable.schedule(self);
    }

    /// Get the raw state value (for debugging/testing)
    pub fn getRawState(self: *const Header) u64 {
        return getState(self.state_ref.load(.acquire));
    }

    /// Get the raw ref count (for debugging/testing)
    pub fn getRefCountValue(self: *const Header) u64 {
        return getRefCount(self.state_ref.load(.acquire));
    }
};

/// OwnedTasks - Collection of all spawned tasks for graceful shutdown.
///
/// This is essential for:
/// 1. Graceful shutdown: Cancel all in-flight tasks
/// 2. Debugging: List all active tasks
/// 3. Leak detection: Verify all tasks completed
///
/// Uses an intrusive doubly-linked list through Header.owned_prev/owned_next.
/// Protected by a mutex since task spawn/drop are relatively rare operations.
///
/// Reference: tokio/src/runtime/task/list.rs
pub const OwnedTasks = struct {
    const Self = @This();

    /// Head of the doubly-linked list
    head: ?*Header,

    /// Mutex protecting the list
    mutex: std.Thread.Mutex,

    /// Number of tasks in the collection
    count: std.atomic.Value(usize),

    /// Whether the collection is closed (no new tasks allowed)
    closed: std.atomic.Value(bool),

    pub fn init() Self {
        return .{
            .head = null,
            .mutex = .{},
            .count = std.atomic.Value(usize).init(0),
            .closed = std.atomic.Value(bool).init(false),
        };
    }

    /// Insert a task into the collection.
    /// Returns false if collection is closed (task was not inserted).
    /// The task's refcount should already be set appropriately.
    pub fn insert(self: *Self, task: *Header) bool {
        // Fast-path check without lock
        if (self.closed.load(.acquire)) {
            return false;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        // Re-check under lock
        if (self.closed.load(.monotonic)) {
            return false;
        }

        // Insert at head (standard intrusive list push)
        task.owned_next = self.head;
        task.owned_prev = null;

        if (self.head) |h| {
            h.owned_prev = task;
        }
        self.head = task;

        _ = self.count.fetchAdd(1, .release);
        return true;
    }

    /// Remove a task from the collection.
    /// Called when task is dropped. Safe to call if task wasn't in list.
    pub fn remove(self: *Self, task: *Header) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Unlink from doubly-linked list
        if (task.owned_prev) |prev| {
            prev.owned_next = task.owned_next;
        } else {
            // Task was head
            self.head = task.owned_next;
        }

        if (task.owned_next) |next| {
            next.owned_prev = task.owned_prev;
        }

        task.owned_prev = null;
        task.owned_next = null;

        _ = self.count.fetchSub(1, .release);
    }

    /// Close the collection and cancel all tasks.
    /// After this, no new tasks can be inserted.
    /// Returns the number of tasks that were cancelled.
    pub fn closeAndCancelAll(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Mark as closed
        self.closed.store(true, .release);

        // Cancel all tasks
        var cancelled: usize = 0;
        var curr = self.head;
        while (curr) |task| {
            if (task.cancel()) {
                cancelled += 1;
            }
            curr = task.owned_next;
        }

        return cancelled;
    }

    /// Check if collection is closed
    pub fn isClosed(self: *const Self) bool {
        return self.closed.load(.acquire);
    }

    /// Get number of tasks (approximate, for metrics)
    pub fn len(self: *const Self) usize {
        return self.count.load(.acquire);
    }

    /// Check if empty
    pub fn isEmpty(self: *const Self) bool {
        return self.count.load(.acquire) == 0;
    }

    /// Iterate all tasks (for debugging). Caller must hold... actually,
    /// this is unsafe without proper synchronization. Use with caution.
    pub fn debugIterator(self: *Self) DebugIterator {
        return .{ .owned = self, .current = null, .started = false };
    }

    pub const DebugIterator = struct {
        owned: *OwnedTasks,
        current: ?*Header,
        started: bool,

        pub fn next(self: *DebugIterator) ?*Header {
            self.owned.mutex.lock();
            defer self.owned.mutex.unlock();

            if (!self.started) {
                self.started = true;
                self.current = self.owned.head;
            } else if (self.current) |c| {
                self.current = c.owned_next;
            }

            return self.current;
        }
    };
};

/// Poll result from task poll function
pub const PollResult = enum {
    /// Task yielded, waiting for I/O or other event
    pending,
    /// Task completed successfully
    ready,
};

/// Waker - handle to wake a task when I/O is ready.
/// This is a lightweight handle that can be cloned and stored.
/// IMPORTANT: Wakers are single-use. Calling wake() or drop() twice is a bug.
pub const Waker = struct {
    /// Pointer to the task header
    header: *Header,

    /// Debug flag to detect double-use (only in debug builds)
    consumed: if (builtin.mode == .Debug) bool else void,

    /// Create a waker for a task
    pub fn init(header: *Header) Waker {
        header.ref(); // Waker holds a reference
        return .{
            .header = header,
            .consumed = if (builtin.mode == .Debug) false else {},
        };
    }

    /// Clone the waker (increments ref count)
    pub fn clone(self: Waker) Waker {
        if (builtin.mode == .Debug) {
            std.debug.assert(!self.consumed); // Cannot clone consumed waker
        }
        self.header.ref();
        return .{
            .header = self.header,
            .consumed = if (builtin.mode == .Debug) false else {},
        };
    }

    /// Wake the task (schedule it for polling)
    /// Consumes the waker - do not use after calling this
    pub fn wake(self: *Waker) void {
        if (builtin.mode == .Debug) {
            std.debug.assert(!self.consumed); // Double wake detected!
            self.consumed = true;
        }

        if (self.header.transitionToScheduled()) {
            self.header.schedule();
        }
        // Drop our reference
        self.header.unref();
        self.header = undefined;
    }

    /// Wake by reference (doesn't consume the waker)
    pub fn wakeByRef(self: *const Waker) void {
        if (builtin.mode == .Debug) {
            std.debug.assert(!self.consumed); // Cannot use consumed waker
        }
        if (self.header.transitionToScheduled()) {
            self.header.schedule();
        }
    }

    /// Drop the waker without waking
    /// Consumes the waker - do not use after calling this
    pub fn drop(self: *Waker) void {
        if (builtin.mode == .Debug) {
            std.debug.assert(!self.consumed); // Double drop detected!
            self.consumed = true;
        }

        self.header.unref();
        self.header = undefined;
    }

    /// Check if waker is still valid (debug builds only)
    pub fn isValid(self: *const Waker) bool {
        if (builtin.mode == .Debug) {
            return !self.consumed;
        }
        return true;
    }
};

/// Create a concrete task type for a given function.
/// This wraps user code in a type-erased task that can be scheduled.
pub fn RawTask(comptime F: type, comptime Output: type) type {
    return struct {
        const Self = @This();

        /// Task header (must be first field for pointer casting)
        header: Header,

        /// The user's function/state machine
        func: F,

        /// Output storage
        output: ?Output,

        /// Scheduler callback (set by scheduler on spawn)
        scheduler: ?*anyopaque,
        schedule_fn: ?*const fn (*anyopaque, *Header) void,

        /// Allocator used to create this task
        allocator: Allocator,

        const vtable = Header.VTable{
            .poll = pollImpl,
            .drop = dropImpl,
            .get_output = getOutputImpl,
            .schedule = scheduleImpl,
        };

        /// Create a new task
        pub fn init(allocator: Allocator, func: F, id: u64) !*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .header = Header.init(&vtable, id),
                .func = func,
                .output = null,
                .scheduler = null,
                .schedule_fn = null,
                .allocator = allocator,
            };
            return self;
        }

        /// Set the scheduler (called by scheduler when task is spawned)
        pub fn setScheduler(
            self: *Self,
            scheduler: *anyopaque,
            schedule_fn: *const fn (*anyopaque, *Header) void,
        ) void {
            self.scheduler = scheduler;
            self.schedule_fn = schedule_fn;
        }

        /// Get task header
        pub fn getHeader(self: *Self) *Header {
            return &self.header;
        }

        /// Poll the task. Returns true if task completed.
        ///
        /// CRITICAL: This implements the NOTIFIED flag logic to prevent lost wakeups.
        /// If wake() is called while we're polling, NOTIFIED gets set, and we
        /// immediately re-schedule rather than going idle.
        fn pollImpl(header: *Header) bool {
            const self: *Self = @fieldParentPtr("header", header);

            // Outer loop handles NOTIFIED - if wake() was called during poll,
            // we immediately re-poll rather than losing the wakeup
            while (true) {
                // Check for cancellation
                if (header.isCancelled()) {
                    header.transitionToComplete();
                    header.unref();
                    return true;
                }

                // Transition to running (also clears NOTIFIED)
                if (!header.transitionToRunning()) {
                    return false;
                }

                // Create waker for this poll - mutable so we can track consumption
                var waker = Waker.init(header);

                // Poll the user function
                const result = pollFunc(&self.func, &self.output, &waker);

                switch (result) {
                    .ready => {
                        // Clean up waker if user didn't consume it
                        if (waker.isValid()) {
                            waker.drop();
                        }
                        header.transitionToComplete();
                        header.unref();
                        return true;
                    },
                    .pending => {
                        // Clean up waker if user didn't consume it
                        if (waker.isValid()) {
                            waker.drop();
                        }

                        // Transition to idle and check if NOTIFIED was set during poll
                        const prev_state = header.transitionToIdle();

                        if (prev_state & Header.State.NOTIFIED != 0) {
                            // CRITICAL: wake() was called while we were polling!
                            // Clear NOTIFIED and re-schedule immediately.
                            // We loop back to poll again rather than going idle.
                            header.clearNotified();

                            // Re-schedule the task
                            if (header.transitionToScheduled()) {
                                header.schedule();
                            }
                            // Don't loop here - let the scheduler decide when to re-poll
                            // This prevents unbounded polling of a hot task
                            return false;
                        }

                        // Task is truly idle, waiting for external event
                        return false;
                    },
                }
            }
        }

        fn pollFunc(func: *F, output: *?Output, waker: *Waker) PollResult {
            // The function should implement a `poll` method that takes *Waker
            // The poll method can:
            // - Store the waker (clone it first) and return .pending
            // - Drop the waker and return .ready
            // - Let the caller handle cleanup (waker.isValid() will be true)
            if (@hasDecl(F, "poll")) {
                return func.poll(output, waker);
            } else {
                // For simple functions that don't need poll semantics
                // Just call it directly (blocking)
                // Waker is not needed for synchronous functions - drop it properly
                waker.drop();
                if (@typeInfo(@TypeOf(func.*)) == .@"fn") {
                    output.* = func.*();
                    return .ready;
                }
                @compileError("Task function must have a poll method or be a simple function");
            }
        }

        fn dropImpl(header: *Header) void {
            const self: *Self = @fieldParentPtr("header", header);
            self.allocator.destroy(self);
        }

        fn getOutputImpl(header: *Header) ?*anyopaque {
            const self: *Self = @fieldParentPtr("header", header);
            if (self.output) |*out| {
                return @ptrCast(out);
            }
            return null;
        }

        fn scheduleImpl(header: *Header) void {
            const self: *Self = @fieldParentPtr("header", header);
            if (self.schedule_fn) |f| {
                if (self.scheduler) |s| {
                    f(s, header);
                }
            }
        }
    };
}

/// JoinHandle - handle to await a spawned task's result.
///
/// IMPORTANT: JoinHandle holds a reference to the task. You MUST call `deinit()`
/// when you're done with the handle to release the reference. Failing to do so
/// will leak the task memory.
///
/// Example usage:
/// ```
/// var handle = JoinHandle(u32).init(task_header);
/// defer handle.deinit(); // Always clean up!
///
/// // Check if complete
/// if (handle.tryJoin()) |result| {
///     // Use result
/// }
/// ```
pub fn JoinHandle(comptime Output: type) type {
    return struct {
        const Self = @This();

        header: *Header,

        pub fn init(header: *Header) Self {
            header.ref(); // JoinHandle holds a reference
            return .{ .header = header };
        }

        /// Check if the task is complete
        pub fn isFinished(self: *const Self) bool {
            return self.header.isComplete();
        }

        /// Cancel the task
        pub fn cancel(self: *Self) void {
            _ = self.header.cancel();
        }

        /// Get the output if complete
        /// Returns null if not complete or cancelled
        pub fn tryJoin(self: *Self) ?Output {
            if (!self.header.isComplete()) {
                return null;
            }
            const ptr = self.header.vtable.get_output(self.header);
            if (ptr) |p| {
                return @as(*Output, @ptrCast(@alignCast(p))).*;
            }
            return null;
        }

        /// Drop the join handle (decrements ref count)
        pub fn deinit(self: *Self) void {
            self.header.unref();
            self.header = undefined;
        }
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// Thread-local task ID generation
// ─────────────────────────────────────────────────────────────────────────────

var global_task_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub fn nextTaskId() u64 {
    return global_task_id.fetchAdd(1, .monotonic);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "Header - state transitions" {
    const vtable = Header.VTable{
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

    var header = Header.init(&vtable, 1);

    // Initial state is IDLE with ref count 1
    try std.testing.expectEqual(Header.State.IDLE, header.getRawState());
    try std.testing.expectEqual(@as(u64, 1), header.getRefCountValue());

    // Can transition to scheduled
    try std.testing.expect(header.transitionToScheduled());
    try std.testing.expect(header.getRawState() & Header.State.SCHEDULED != 0);

    // Can transition to running
    try std.testing.expect(header.transitionToRunning());
    try std.testing.expect(header.getRawState() & Header.State.RUNNING != 0);
    try std.testing.expect(header.getRawState() & Header.State.SCHEDULED == 0);

    // Can complete
    header.transitionToComplete();
    try std.testing.expect(header.isComplete());
}

test "Header - cancellation" {
    const vtable = Header.VTable{
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

    var header = Header.init(&vtable, 2);

    // Can cancel
    try std.testing.expect(header.cancel());
    try std.testing.expect(header.isCancelled());

    // Cannot schedule cancelled task
    try std.testing.expect(!header.transitionToScheduled());
}

test "Header - reference counting (packed)" {
    const vtable = Header.VTable{
        .poll = struct {
            fn f(_: *Header) bool {
                return true;
            }
        }.f,
        .drop = struct {
            fn f(_: *Header) void {
                // In a real implementation this would free memory
            }
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

    var header = Header.init(&vtable, 3);

    // Initial ref count is 1
    try std.testing.expectEqual(@as(u64, 1), header.getRefCountValue());

    // Ref increments
    header.ref();
    try std.testing.expectEqual(@as(u64, 2), header.getRefCountValue());

    // Unref decrements
    header.unref();
    try std.testing.expectEqual(@as(u64, 1), header.getRefCountValue());

    // State should be preserved through ref/unref
    try std.testing.expectEqual(Header.State.IDLE, header.getRawState());
}

test "Header - packed state and ref count independence" {
    const vtable = Header.VTable{
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

    var header = Header.init(&vtable, 4);

    // Add refs
    header.ref();
    header.ref();
    try std.testing.expectEqual(@as(u64, 3), header.getRefCountValue());

    // Change state - ref count should be preserved
    _ = header.transitionToScheduled();
    try std.testing.expectEqual(@as(u64, 3), header.getRefCountValue());
    try std.testing.expect(header.getRawState() & Header.State.SCHEDULED != 0);

    // Remove refs - state should be preserved
    header.unref();
    try std.testing.expectEqual(@as(u64, 2), header.getRefCountValue());
    try std.testing.expect(header.getRawState() & Header.State.SCHEDULED != 0);
}

test "nextTaskId - monotonic" {
    const id1 = nextTaskId();
    const id2 = nextTaskId();
    const id3 = nextTaskId();

    try std.testing.expect(id2 > id1);
    try std.testing.expect(id3 > id2);
}

test "Header - NOTIFIED flag prevents lost wakeups" {
    const vtable = Header.VTable{
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

    var header = Header.init(&vtable, 100);

    // Schedule and run the task
    try std.testing.expect(header.transitionToScheduled());
    try std.testing.expect(header.transitionToRunning());
    try std.testing.expect(header.getRawState() & Header.State.RUNNING != 0);

    // While RUNNING, try to schedule again (simulating wake() during poll)
    // This should NOT add to queue (returns false) but SHOULD set NOTIFIED
    try std.testing.expect(!header.transitionToScheduled());
    try std.testing.expect(header.isNotified());

    // Transition to idle and check NOTIFIED was set
    const prev_state = header.transitionToIdle();
    try std.testing.expect(prev_state & Header.State.NOTIFIED != 0);

    // Clear NOTIFIED after handling
    header.clearNotified();
    try std.testing.expect(!header.isNotified());
}

test "OwnedTasks - basic operations" {
    var owned = OwnedTasks.init();

    const vtable = Header.VTable{
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

    var headers: [3]Header = undefined;
    for (&headers, 0..) |*h, i| {
        h.* = Header.init(&vtable, i);
    }

    // Initially empty
    try std.testing.expect(owned.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), owned.len());

    // Insert tasks
    try std.testing.expect(owned.insert(&headers[0]));
    try std.testing.expect(owned.insert(&headers[1]));
    try std.testing.expect(owned.insert(&headers[2]));

    try std.testing.expectEqual(@as(usize, 3), owned.len());
    try std.testing.expect(!owned.isEmpty());

    // Remove one task
    owned.remove(&headers[1]);
    try std.testing.expectEqual(@as(usize, 2), owned.len());

    // Close and cancel all
    const cancelled = owned.closeAndCancelAll();
    try std.testing.expect(cancelled > 0);
    try std.testing.expect(owned.isClosed());

    // Cannot insert after close
    var new_header = Header.init(&vtable, 99);
    try std.testing.expect(!owned.insert(&new_header));
}
