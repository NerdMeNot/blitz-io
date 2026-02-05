//! # Synchronization Primitives for Async Tasks
//!
//! This module provides async-aware synchronization primitives that integrate
//! with the blitz-io task system. Unlike blocking OS primitives, these yield
//! to the scheduler when contended, allowing other tasks to make progress.
//!
//! ## Available Primitives
//!
//! | Primitive | Use Case |
//! |-----------|----------|
//! | `Notify` | Task wake-up (like condvar) |
//! | `Semaphore` | Limit concurrent access |
//! | `Mutex` | Protect shared state |
//! | `RwLock` | Many readers, one writer |
//! | `Oneshot` | Single-value delivery |
//! | `Channel` | Bounded MPSC queue |
//! | `BroadcastChannel` | Multi-consumer pub/sub |
//! | `Watch` | Single value with change notification |
//! | `Barrier` | Wait for N tasks |
//! | `OnceCell` | Lazy one-time init |
//! | `Scope` | Structured concurrency (spawn + wait) |
//!
//! ## Quick Examples
//!
//! ### Mutex (Protect Shared State)
//! ```zig
//! var mutex = io.Mutex.init();
//!
//! // Try lock (non-blocking, fast path)
//! if (mutex.tryLock()) {
//!     defer mutex.unlock();
//!     shared_state.update();
//! }
//!
//! // Blocking lock
//! mutex.lock();
//! defer mutex.unlock();
//! shared_state.update();
//! ```
//!
//! ### Semaphore (Connection Limiter)
//! ```zig
//! var sem = io.Semaphore.init(100);  // Max 100 concurrent
//!
//! sem.acquire();  // Blocks if at limit
//! defer sem.release();
//! handleConnection();
//! ```
//!
//! ### Oneshot (Async Result Delivery)
//! ```zig
//! var result = io.Oneshot(ComputeResult).init();
//!
//! // Producer (background task)
//! result.send(computeHeavyResult());
//!
//! // Consumer
//! const value = result.recv();  // Blocks until ready
//! ```
//!
//! ### Channel (Work Queue)
//! ```zig
//! var queue = try io.Channel(Task).init(allocator, 100);
//! defer queue.deinit();
//!
//! // Producers (multiple)
//! try queue.send(task);
//!
//! // Consumer (single)
//! while (queue.tryRecv()) |task| {
//!     processTask(task);
//! }
//! ```
//!
//! ### RwLock (Read-Heavy Workloads)
//! ```zig
//! var rwlock = io.RwLock.init();
//!
//! // Many concurrent readers
//! rwlock.lockRead();
//! defer rwlock.unlockRead();
//! const value = shared_data.get();
//!
//! // Exclusive writer
//! rwlock.lockWrite();
//! defer rwlock.unlockWrite();
//! shared_data.set(new_value);
//! ```
//!
//! ### Barrier (Coordinate N Tasks)
//! ```zig
//! var barrier = io.Barrier.init(4);  // Wait for 4 tasks
//!
//! // Each task calls wait()
//! const result = barrier.wait();
//! if (result == .leader) {
//!     // This task is the last to arrive
//!     combineResults();
//! }
//! ```
//!
//! ### Watch (Config Reload)
//! ```zig
//! var config = io.Watch(Config).init(default_config);
//!
//! // Writer (config reloader)
//! config.send(new_config);
//!
//! // Readers (workers)
//! config.waitForChange();  // Blocks until config changes
//! const current = config.borrow();
//! applyConfig(current.*);
//! ```
//!
//! ### Notify (Condition Variable Pattern)
//! ```zig
//! var notify = io.Notify.init();
//!
//! // Waiter
//! notify.wait();  // Blocks until notified
//!
//! // Notifier
//! notify.notifyOne();  // Wake one waiter
//! notify.notifyAll();  // Wake all waiters
//! ```
//!
//! ## Design Philosophy
//!
//! All primitives follow a consistent pattern:
//! 1. `tryX()` - Non-blocking attempt, returns immediately
//! 2. `x(waiter)` - Potentially blocking, returns true if immediate, false if waiting
//! 3. `cancelX(waiter)` - Cancel a pending wait
//! 4. Waiter structs are stack-allocated by the caller (zero allocation)
//!
//! This design allows callers to decide how to handle waiting:
//! - Yield to async scheduler
//! - Spin wait (for very short waits)
//! - Timeout with deadline
//! - Cancel on external signal
//!
//! ## Waiter Lifetime Requirements
//!
//! **CRITICAL:** Waiters must remain valid for the entire wait operation.
//!
//! ### Rules
//!
//! 1. **Stack allocation is safe** when the waiter outlives the wait:
//!    ```zig
//!    var waiter = Mutex.Waiter.init();
//!    if (!mutex.lock(&waiter)) {
//!        // waiter is still on stack, valid until function returns
//!        yield_to_scheduler();  // OK
//!    }
//!    defer mutex.unlock();
//!    ```
//!
//! 2. **Always cancel before returning** if wait was not completed:
//!    ```zig
//!    var waiter = Mutex.Waiter.init();
//!    if (!mutex.lock(&waiter)) {
//!        if (should_timeout()) {
//!            mutex.cancelLock(&waiter);  // REQUIRED before return
//!            return error.Timeout;
//!        }
//!    }
//!    ```
//!
//! 3. **Never move a waiter** while it's in a wait queue:
//!    ```zig
//!    // WRONG - waiter may be moved/invalidated
//!    var waiters = ArrayList(Waiter).init(alloc);
//!    waiters.append(Waiter.init());  // May reallocate and move!
//!
//!    // CORRECT - use pointers or pre-allocate
//!    var waiter = Waiter.init();
//!    waiters.append(&waiter);  // Pointer is stable
//!    ```
//!
//! 4. **Heap allocation** works but is rarely needed:
//!    ```zig
//!    const waiter = try alloc.create(Waiter);
//!    defer alloc.destroy(waiter);
//!    waiter.* = Waiter.init();
//!    // Use waiter...
//!    ```
//!
//! ### Why This Design?
//!
//! - Zero allocation per wait operation
//! - No internal memory management in sync primitives
//! - Clear ownership: caller owns waiter memory
//! - Matches Tokio's waiter pattern for familiarity
//!
//! Reference: tokio/src/sync/

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════════════
// Notify - Task Wake-up
// ═══════════════════════════════════════════════════════════════════════════════

/// Task notification primitive. Wake waiters without passing data.
/// Use when tasks need to signal each other (e.g., "data is ready").
pub const notify = @import("sync/notify.zig");
pub const Notify = notify.Notify;
pub const NotifyWaiter = notify.Waiter;

// ═══════════════════════════════════════════════════════════════════════════════
// Semaphore - Concurrency Limiter
// ═══════════════════════════════════════════════════════════════════════════════

/// Counting semaphore. Limit concurrent access to a resource.
/// Initialize with count N, at most N tasks can hold permits simultaneously.
pub const semaphore = @import("sync/semaphore.zig");
pub const Semaphore = semaphore.Semaphore;
pub const SemaphoreWaiter = semaphore.Waiter;
pub const SemaphorePermit = semaphore.SemaphorePermit;

// ═══════════════════════════════════════════════════════════════════════════════
// Mutex - Mutual Exclusion
// ═══════════════════════════════════════════════════════════════════════════════

/// Async mutual exclusion. Protect shared state from concurrent access.
/// Use `tryLock()` for non-blocking, `lock()` for blocking.
pub const mutex = @import("sync/mutex.zig");
pub const Mutex = mutex.Mutex;
pub const MutexWaiter = mutex.Waiter;
pub const MutexGuard = mutex.MutexGuard;

// ═══════════════════════════════════════════════════════════════════════════════
// Oneshot - Single Value Channel
// ═══════════════════════════════════════════════════════════════════════════════

/// Single-value channel. Send exactly one value from producer to consumer.
/// Perfect for returning results from background tasks.
pub const oneshot = @import("sync/oneshot.zig");
pub const Oneshot = oneshot.Oneshot;

// ═══════════════════════════════════════════════════════════════════════════════
// Channel - Bounded MPSC Queue
// ═══════════════════════════════════════════════════════════════════════════════

/// Bounded MPSC (multi-producer, single-consumer) channel.
/// Provides backpressure when buffer is full. Use for work queues.
pub const channel = @import("sync/channel.zig");
pub const Channel = channel.Channel;
pub const SendWaiter = channel.SendWaiter;
pub const RecvWaiter = channel.RecvWaiter;

// ═══════════════════════════════════════════════════════════════════════════════
// RwLock - Read-Write Lock
// ═══════════════════════════════════════════════════════════════════════════════

/// Async read-write lock. Many readers OR one writer at a time.
/// Use for read-heavy workloads where writes are infrequent.
pub const rwlock = @import("sync/rwlock.zig");
pub const RwLock = rwlock.RwLock;
pub const ReadWaiter = rwlock.ReadWaiter;
pub const WriteWaiter = rwlock.WriteWaiter;
pub const ReadGuard = rwlock.ReadGuard;
pub const WriteGuard = rwlock.WriteGuard;

// ═══════════════════════════════════════════════════════════════════════════════
// Barrier - N-Way Synchronization
// ═══════════════════════════════════════════════════════════════════════════════

/// Synchronization barrier. Block until N tasks have arrived.
/// One task is designated "leader" for final processing.
pub const barrier = @import("sync/barrier.zig");
pub const Barrier = barrier.Barrier;
pub const BarrierWaiter = barrier.Waiter;
pub const BarrierWaitResult = barrier.BarrierWaitResult;

// ═══════════════════════════════════════════════════════════════════════════════
// BroadcastChannel - Multi-Consumer Pub/Sub
// ═══════════════════════════════════════════════════════════════════════════════

/// Broadcast channel. All receivers get every message (fan-out pattern).
/// Each receiver maintains its own position; slow receivers may miss messages.
pub const broadcast = @import("sync/broadcast.zig");
pub const BroadcastChannel = broadcast.BroadcastChannel;
pub const BroadcastRecvWaiter = broadcast.RecvWaiter;

// ═══════════════════════════════════════════════════════════════════════════════
// Watch - Single Value with Change Notification
// ═══════════════════════════════════════════════════════════════════════════════

/// Watch channel. Holds a single value; receivers wait for changes.
/// Perfect for configuration that can be updated at runtime.
pub const watch = @import("sync/watch.zig");
pub const Watch = watch.Watch;
pub const WatchChangeWaiter = watch.ChangeWaiter;

// ═══════════════════════════════════════════════════════════════════════════════
// OnceCell - Lazy Initialization
// ═══════════════════════════════════════════════════════════════════════════════

/// Lazy one-time initialization. Value computed on first access.
/// Safe for concurrent initialization - only one task does the work.
pub const once_cell = @import("sync/once_cell.zig");
pub const OnceCell = once_cell.OnceCell;
pub const OnceCellWaiter = once_cell.InitWaiter;

// ═══════════════════════════════════════════════════════════════════════════════
// Scope - Structured Concurrency
// ═══════════════════════════════════════════════════════════════════════════════

/// Structured concurrency scope. Spawn tasks and wait for all to complete.
/// All spawned work is guaranteed to complete before the scope exits.
///
/// ```zig
/// var scope = Scope{};
/// defer scope.cancel();  // Clean up on any exit
///
/// // Spawn async tasks (I/O workers)
/// const user_task = try scope.spawn(fetchUser, .{id});
/// const posts_task = try scope.spawn(fetchPosts, .{id});
///
/// // Spawn blocking tasks (thread pool)
/// const hash_task = try scope.spawnBlocking(computeHash, .{data});
///
/// try scope.wait();  // Blocks until all complete
///
/// // Get typed results
/// const user = user_task.await();
/// const posts = posts_task.await();
/// const hash = hash_task.await();
/// ```
pub const scope_mod = @import("sync/scope.zig");
pub const Scope = scope_mod.Scope;
pub const Task = scope_mod.Task;
pub const BlockingTask = scope_mod.BlockingTask;
pub const scoped = scope_mod.scoped;
pub const ScopeError = scope_mod.ScopeError;

// ═══════════════════════════════════════════════════════════════════════════════
// Unified Waiter
// ═══════════════════════════════════════════════════════════════════════════════

/// Unified waiter type that works in both async task context and blocking thread context.
/// New sync primitives should use this instead of defining their own waiter types.
pub const waiter = @import("sync/waiter.zig");
pub const Waiter = waiter.Waiter;
pub const WaiterList = waiter.WaiterList;
pub const WaiterState = waiter.State;

// ═══════════════════════════════════════════════════════════════════════════════
// Common Types
// ═══════════════════════════════════════════════════════════════════════════════

/// Function pointer type for waking tasks.
/// Used by all synchronization primitives.
/// @deprecated Use the unified Waiter type instead.
pub const WakerFn = *const fn (*anyopaque) void;

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

test {
    // Run all sub-module tests
    _ = @import("sync/waiter.zig");
    _ = @import("sync/notify.zig");
    _ = @import("sync/semaphore.zig");
    _ = @import("sync/mutex.zig");
    _ = @import("sync/oneshot.zig");
    _ = @import("sync/channel.zig");
    _ = @import("sync/rwlock.zig");
    _ = @import("sync/barrier.zig");
    _ = @import("sync/broadcast.zig");
    _ = @import("sync/watch.zig");
    _ = @import("sync/once_cell.zig");
    _ = @import("sync/scope.zig");
}
