# Blitz-IO Task State Machine & Memory Lifecycle Review

I need a critical review of the task state machine and reference counting implementation in my Zig async executor. This is high-risk code where subtle bugs cause use-after-free, double-free, or memory leaks.

---

## Overview

Tasks use a **packed 64-bit atomic** that combines state flags (16 bits) and reference count (48 bits). This allows single-instruction state transitions that also manipulate refcount.

```
┌────────────────────────────────────────────────────────────────┐
│                        state_ref (u64)                         │
├────────────────────────────────────────────────────────────────┤
│  [63:16] Reference Count (48 bits)  │  [15:0] State Flags     │
│         281 trillion max            │  SCHEDULED, RUNNING...  │
└────────────────────────────────────────────────────────────────┘
```

---

## State Flags

```zig
pub const State = struct {
    pub const IDLE: u64 = 0;           // Not yet scheduled
    pub const SCHEDULED: u64 = 1 << 0; // In run queue
    pub const RUNNING: u64 = 1 << 1;   // Currently being polled
    pub const COMPLETE: u64 = 1 << 2;  // Finished successfully
    pub const CANCELLED: u64 = 1 << 3; // Cancelled
    pub const CLOSED: u64 = 1 << 4;    // Being dropped
    pub const JOIN_INTEREST: u64 = 1 << 5; // JoinHandle waiting
    pub const JOIN_WOKEN: u64 = 1 << 6;    // JoinHandle was woken

    pub const STATE_MASK: u64 = 0xFFFF;
    pub const REF_SHIFT: u6 = 16;
    pub const REF_ONE: u64 = 1 << REF_SHIFT;
};
```

---

## Intended State Machine

```
                    ┌─────────────────────────────────────────┐
                    │                                         │
                    ▼                                         │
    ┌──────┐   schedule   ┌───────────┐   poll    ┌─────────┐│
    │ IDLE │ ───────────▶ │ SCHEDULED │ ────────▶ │ RUNNING ││
    └──────┘              └───────────┘           └─────────┘│
        │                       │                      │     │
        │                       │                      │     │
        │ cancel()              │ cancel()             │     │ yield (pending)
        │                       │                      │     │
        ▼                       ▼                      ▼     │
    ┌───────────┐         ┌───────────┐         ┌──────────┐│
    │ CANCELLED │         │ CANCELLED │         │ COMPLETE │┘
    └───────────┘         └───────────┘         └──────────┘
                                                      │
                                                      │ refcount → 0
                                                      ▼
                                                ┌──────────┐
                                                │  DROPPED │
                                                │ (freed)  │
                                                └──────────┘
```

---

## Reference Holders

| Holder | When Acquired | When Released |
|--------|--------------|---------------|
| **Scheduler** | On spawn | After poll returns `complete` |
| **JoinHandle** | On `JoinHandle.init()` | On `JoinHandle.deinit()` |
| **Waker** | On `Waker.init()` | On `Waker.wake()` or `Waker.drop()` |
| **Run Queue** | Never (queue stores raw pointers) | Never |

---

## Critical Implementation: Reference Counting

```zig
/// Increment reference count
/// Uses relaxed ordering - safe because we already hold a reference
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
```

### Question 1: Is `.monotonic` safe for `ref()`?

The comment says "safe because we already hold a reference" but is this actually true in all cases? What if:
- Thread A calls `ref()` with `.monotonic`
- Thread B concurrently calls `unref()` and sees refcount = 1, drops the task
- Thread A's `ref()` completes on freed memory?

---

## Critical Implementation: State Transitions

### transitionToScheduled

```zig
pub fn transitionToScheduled(self: *Header) bool {
    var current = self.state_ref.load(.acquire);
    while (true) {
        const state = getState(current);

        // Cannot schedule if complete, cancelled, or closed
        if (state & (State.COMPLETE | State.CANCELLED | State.CLOSED) != 0) {
            return false;
        }
        // Cannot schedule if already scheduled or running
        if (state & (State.SCHEDULED | State.RUNNING) != 0) {
            return false;
        }

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
```

### transitionToRunning

```zig
pub fn transitionToRunning(self: *Header) bool {
    var current = self.state_ref.load(.acquire);
    while (true) {
        const state = getState(current);

        // Must be scheduled
        if (state & State.SCHEDULED == 0) {
            return false;
        }
        // Cannot run if cancelled or closed
        if (state & (State.CANCELLED | State.CLOSED) != 0) {
            return false;
        }

        const new_state = (state & ~State.SCHEDULED) | State.RUNNING;
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
```

### Question 2: Can a task be polled twice simultaneously?

If worker A dequeues a task and calls `transitionToRunning()`, then worker B steals the same task pointer from a different queue and also calls `transitionToRunning()`, can both succeed?

**Expected**: No - only one should succeed because we use CAS.
**Concern**: Is there a window where both read `SCHEDULED` and both attempt CAS?

---

## Critical Implementation: Waker Lifecycle

```zig
pub const Waker = struct {
    header: *Header,
    consumed: if (builtin.mode == .Debug) bool else void,

    /// Create a waker for a task
    pub fn init(header: *Header) Waker {
        header.ref(); // Waker holds a reference
        return .{
            .header = header,
            .consumed = if (builtin.mode == .Debug) false else {},
        };
    }

    /// Wake the task (schedule it for polling)
    /// Consumes the waker - do not use after calling this
    pub fn wake(self: *Waker) void {
        if (builtin.mode == .Debug) {
            std.debug.assert(!self.consumed);
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
            std.debug.assert(!self.consumed);
        }
        if (self.header.transitionToScheduled()) {
            self.header.schedule();
        }
        // NOTE: Does NOT unref - waker still valid
    }

    /// Drop the waker without waking
    pub fn drop(self: *Waker) void {
        if (builtin.mode == .Debug) {
            std.debug.assert(!self.consumed);
            self.consumed = true;
        }
        self.header.unref();
        self.header = undefined;
    }
};
```

### Question 3: Waker stored in I/O completion, task cancelled

Scenario:
1. Task polls, returns `pending`, stores Waker in epoll interest
2. User calls `JoinHandle.cancel()`, task is marked CANCELLED
3. epoll triggers, calls `waker.wake()`
4. `transitionToScheduled()` fails (task is CANCELLED)
5. `waker.wake()` still calls `unref()`

Is this correct? The task is scheduled for cancellation cleanup but never actually polled again. Who cleans up the task output/state?

---

## Critical Implementation: Poll and Complete

```zig
fn pollImpl(header: *Header) bool {
    const self: *Self = @fieldParentPtr("header", header);

    // Check for cancellation
    if (header.isCancelled()) {
        header.transitionToComplete();
        return true;
    }

    // Transition to running
    if (!header.transitionToRunning()) {
        return false;
    }

    // Create waker for this poll
    const waker = Waker.init(header);

    // Poll the user function
    const result = pollFunc(&self.func, &self.output, waker);

    switch (result) {
        .ready => {
            header.transitionToComplete();
            return true;
        },
        .pending => {
            header.transitionToIdle();
            return false;
        },
    }
}
```

### Question 4: Waker created but poll returns immediately

If `pollFunc` returns `.ready` immediately:
1. `Waker.init(header)` calls `header.ref()` → refcount = 2
2. `pollFunc` returns `.ready`, Waker goes out of scope
3. Waker is NOT explicitly dropped - **memory leak?**

I don't see `waker.drop()` called on the `.ready` path. Does Zig automatically call a destructor? (No, it doesn't!)

---

## Critical Implementation: JoinHandle

```zig
pub fn JoinHandle(comptime Output: type) type {
    return struct {
        header: *Header,

        pub fn init(header: *Header) Self {
            header.ref(); // JoinHandle holds a reference
            return .{ .header = header };
        }

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

        pub fn deinit(self: *Self) void {
            self.header.unref();
            self.header = undefined;
        }
    };
}
```

### Question 5: Output accessed after task dropped

Scenario:
1. Scheduler holds refcount = 1
2. JoinHandle created, refcount = 2
3. Task completes, scheduler calls `unref()`, refcount = 1
4. JoinHandle calls `tryJoin()`, reads output
5. JoinHandle calls `deinit()`, refcount = 0, task dropped

Is step 4 safe? The task memory is valid (refcount > 0), but is the output storage guaranteed to be valid? What if the task allocates output on its own heap that gets freed on drop?

---

## Question 6: Scheduler's Reference

The scheduler code (from context):

```zig
pub fn spawn(self: *Self, task: *Header) void {
    _ = self.spawnWithBackpressure(task);
}

pub fn spawnWithBackpressure(self: *Self, task: *Header) SpawnResult {
    _ = self.tasks_spawned.fetchAdd(1, .monotonic);

    if (!task.transitionToScheduled()) {
        return .rejected;
    }

    // ... schedule task ...
}
```

I don't see the scheduler calling `ref()` when enqueueing or `unref()` when dequeuing. This suggests the **queue holds raw pointers without owning references**.

### Who holds the "scheduler reference"?

Looking at `RawTask.init()`:
```zig
pub fn init(allocator: Allocator, func: F, id: u64) !*Self {
    const self = try allocator.create(Self);
    self.* = .{
        .header = Header.init(&vtable, id),  // refcount = 1
        // ...
    };
    return self;
}
```

So the initial refcount = 1 is the "creator's reference". But:
- If `spawn()` is called and returns `.rejected`, who owns that reference?
- If `spawn()` succeeds, does the scheduler now own it? When does it `unref()`?

---

## Specific Review Questions

1. **Is `.monotonic` ordering safe for `ref()`?** Could a concurrent `unref()` drop the task before `ref()` completes?

2. **Double-poll race**: Can two workers both successfully transition the same task to RUNNING?

3. **Waker leak on immediate completion**: When poll returns `.ready` immediately, the Waker is never dropped. Is this a refcount leak?

4. **Cancelled task cleanup**: If a task is cancelled while a Waker is stored in I/O state, who cleans up the task?

5. **Output validity**: Is reading output via `get_output()` safe if the task could be dropped by another thread?

6. **Scheduler reference ownership**: The scheduler doesn't seem to call `ref()`/`unref()`. What's the ownership model?

7. **JOIN_INTEREST / JOIN_WOKEN flags**: These are defined but I don't see them being used. Are they dead code, or am I missing something?

8. **CLOSED flag**: When is this set? I don't see any code setting it.

---

## Test Status

The implementation has basic unit tests for state transitions and refcounting, but:
- No concurrent stress tests
- No loom-style model checking
- No tests for the Waker → I/O → wake cycle
- No tests for cancellation during I/O wait

---

## Reference: Tokio's Approach

Tokio's task state machine (for comparison):
- Uses `loom` for concurrency testing
- Has explicit states for `NOTIFIED` (wake pending)
- Uses `JOIN_WAKER` stored atomically in the task
- Has careful memory ordering annotations throughout

I'm concerned we may have missed subtle cases that Tokio handles.
