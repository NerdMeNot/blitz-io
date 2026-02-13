---
title: Sync Primitives API
description: Complete API reference for Mutex, RwLock, Semaphore, Notify, Barrier, and OnceCell in blitz-io.
---

When multiple tasks need to share state or coordinate work, you reach for sync primitives. blitz-io provides six of them -- each designed for a specific pattern you'll hit in real applications:

- **Mutex** -- protect a shared resource (session cache, counters, connection state)
- **RwLock** -- let many readers proceed in parallel, block only for writes (config stores, routing tables)
- **Semaphore** -- limit concurrency to N (connection pools, rate limiters, batch size caps)
- **Notify** -- signal "something happened" without passing data (producer/consumer wakeups, shutdown signals)
- **Barrier** -- wait until N tasks reach a checkpoint before any proceed (map-reduce phases, parallel test setup)
- **OnceCell** -- initialize something expensive exactly once, then read it for free (database pools, TLS config, singletons)

All primitives are **async-aware**: when contended, they yield to the scheduler instead of blocking the OS thread. They are also **zero-allocation** -- waiter structs are embedded in futures, not heap-allocated. No `deinit()` needed.

### At a Glance

```zig
const io = @import("blitz-io");

// Protect shared state with a Mutex
var mutex = io.sync.Mutex.init();
if (mutex.tryLock()) {
    defer mutex.unlock();
    // critical section -- only one task at a time
}

// Limit concurrent DB connections with a Semaphore
var pool = io.sync.Semaphore.init(10); // 10 permits
if (pool.tryAcquire(1)) {
    defer pool.release(1);
    // use one connection slot
}

// Lazy-init a singleton with OnceCell
var db = io.sync.OnceCell(DbPool).init();
const pool = db.getOrInit(createPool); // first caller inits, rest get cached (~0.4ns)
```

Each primitive provides three API tiers:

| Tier | Pattern | Behavior |
|------|---------|----------|
| Non-blocking | `tryX()` | Returns immediately (lock-free CAS) |
| Waiter | `xWait(waiter)` | Low-level, caller manages waiter lifecycle |
| Async Future | `x()` | Returns a Future for the scheduler |

## Mutex

Mutual exclusion lock. Built on `Semaphore(1)`.

```zig
const Mutex = io.sync.Mutex;
```

### Construction

```zig
var mutex = Mutex.init();
```

### Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `tryLock` | `fn tryLock(self: *Mutex) bool` | Non-blocking lock attempt. Returns `true` if acquired. |
| `unlock` | `fn unlock(self: *Mutex) void` | Release the lock. Wakes the next waiter (FIFO). |
| `lockWait` | `fn lockWait(self: *Mutex, waiter: *Waiter) bool` | Waiter-based lock. Returns `true` if acquired immediately. |
| `cancelLock` | `fn cancelLock(self: *Mutex, waiter: *Waiter) void` | Remove a waiter from the queue. |
| `lock` | `fn lock(self: *Mutex) LockFuture` | Returns a Future that resolves when the lock is acquired. |
| `tryLockGuard` | `fn tryLockGuard(self: *Mutex) ?MutexGuard` | Non-blocking lock with RAII guard. |
| `isLocked` | `fn isLocked(self: *const Mutex) bool` | Debug: check if locked. |
| `waiterCount` | `fn waiterCount(self: *Mutex) usize` | Debug: number of queued waiters. |

### Waiter

```zig
const Waiter = io.sync.mutex.Waiter;

var waiter = Waiter.init();
waiter.setWaker(@ptrCast(&ctx), wakeFn);

if (mutex.lockWait(&waiter)) {
    // Acquired immediately
} else {
    // Queued -- yield and wait for wake
}
// After wake: waiter.isAcquired() == true
defer mutex.unlock();
```

### MutexGuard (RAII)

```zig
if (mutex.tryLockGuard()) |guard| {
    var g = guard;
    defer g.deinit(); // Automatically unlocks
}
```

### LockFuture

```zig
var future = mutex.lock();
defer future.deinit();
// Output: void. Resolves when lock is acquired.
// Caller must call mutex.unlock() after use.
```

`LockFuture` implements the Future trait (`pub const Output = void`).

### Example: Thread-Safe Counter

A counter shared across multiple tasks. Each task increments the counter under the mutex, ensuring no updates are lost.

```zig
const std = @import("std");
const io = @import("blitz-io");

const SharedCounter = struct {
    mutex: io.sync.Mutex,
    value: u64,

    fn init() SharedCounter {
        return .{
            .mutex = io.sync.Mutex.init(),
            .value = 0,
        };
    }

    /// Increment the counter by 1, returning the previous value.
    /// Uses tryLock for the non-blocking fast path. In a real
    /// async task, you would use lock() to get a Future instead.
    fn increment(self: *SharedCounter) ?u64 {
        if (self.mutex.tryLock()) {
            defer self.mutex.unlock();
            const prev = self.value;
            self.value += 1;
            return prev;
        }
        return null; // Could not acquire -- another task holds the lock
    }

    fn get(self: *SharedCounter) ?u64 {
        if (self.mutex.tryLock()) {
            defer self.mutex.unlock();
            return self.value;
        }
        return null;
    }
};

var counter = SharedCounter.init();

// From task A:
if (counter.increment()) |prev| {
    std.log.info("counter was {d}, now {d}", .{ prev, prev + 1 });
}

// From task B (concurrent):
if (counter.get()) |val| {
    std.log.info("counter is currently {d}", .{val});
}
```

### Example: Shared Cache with MutexGuard

Protecting a HashMap with a Mutex so multiple tasks can read and write cached values. The RAII guard ensures the lock is always released, even if lookup logic returns early.

```zig
const std = @import("std");
const io = @import("blitz-io");

const SessionCache = struct {
    mutex: io.sync.Mutex,
    // The map itself is not thread-safe, so all access goes through the mutex.
    sessions: std.StringHashMap(SessionData),

    const SessionData = struct {
        user_id: u64,
        expires_at: i64,
    };

    fn init(allocator: std.mem.Allocator) SessionCache {
        return .{
            .mutex = io.sync.Mutex.init(),
            .sessions = std.StringHashMap(SessionData).init(allocator),
        };
    }

    fn deinit(self: *SessionCache) void {
        self.sessions.deinit();
    }

    /// Look up a session by token. Returns null if not found or expired.
    fn lookup(self: *SessionCache, token: []const u8, now: i64) ?SessionData {
        // tryLockGuard returns an RAII guard that auto-unlocks on scope exit.
        if (self.mutex.tryLockGuard()) |guard| {
            var g = guard;
            defer g.deinit();

            const entry = self.sessions.get(token) orelse return null;
            if (entry.expires_at < now) return null; // Expired
            return entry;
        }
        return null; // Lock contended, caller can retry
    }

    /// Store a session. Overwrites any existing entry for this token.
    fn store(self: *SessionCache, token: []const u8, data: SessionData) !void {
        if (self.mutex.tryLockGuard()) |guard| {
            var g = guard;
            defer g.deinit();

            try self.sessions.put(token, data);
        }
        // In an async context, use mutex.lock() to get a Future
        // that yields instead of returning null.
    }
};
```

:::note
The `tryLock` / `tryLockGuard` variants are best for fast non-blocking paths. In an async task where you can afford to yield, prefer `mutex.lock()` which returns a `LockFuture`. The scheduler will wake your task when the lock becomes available.
:::

---

## RwLock

Read-write lock. Multiple concurrent readers OR one exclusive writer. Built on `Semaphore(MAX_READS)`.

```zig
const RwLock = io.sync.RwLock;
```

### Construction

```zig
var rwlock = RwLock.init();
```

### Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `tryReadLock` | `fn tryReadLock(self: *RwLock) bool` | Non-blocking read lock. |
| `readUnlock` | `fn readUnlock(self: *RwLock) void` | Release read lock. |
| `readLockWait` | `fn readLockWait(self: *RwLock, waiter: *ReadWaiter) bool` | Waiter-based read lock. |
| `cancelReadLock` | `fn cancelReadLock(self: *RwLock, waiter: *ReadWaiter) void` | Cancel pending read lock. |
| `tryWriteLock` | `fn tryWriteLock(self: *RwLock) bool` | Non-blocking write lock. |
| `writeUnlock` | `fn writeUnlock(self: *RwLock) void` | Release write lock. |
| `writeLockWait` | `fn writeLockWait(self: *RwLock, waiter: *WriteWaiter) bool` | Waiter-based write lock. |
| `cancelWriteLock` | `fn cancelWriteLock(self: *RwLock, waiter: *WriteWaiter) void` | Cancel pending write lock. |
| `readLock` | `fn readLock(self: *RwLock) ReadLockFuture` | Returns a Future for read lock. |
| `writeLock` | `fn writeLock(self: *RwLock) WriteLockFuture` | Returns a Future for write lock. |
| `tryReadLockGuard` | `fn tryReadLockGuard(self: *RwLock) ?ReadGuard` | Non-blocking read lock with guard. |
| `tryWriteLockGuard` | `fn tryWriteLockGuard(self: *RwLock) ?WriteGuard` | Non-blocking write lock with guard. |
| `isWriteLocked` | `fn isWriteLocked(self: *RwLock) bool` | Debug: check if write-locked. |
| `getReaderCount` | `fn getReaderCount(self: *RwLock) usize` | Debug: number of active readers. |
| `waitingReaders` | `fn waitingReaders(self: *RwLock) usize` | Debug: queued reader count (O(n)). |
| `waitingWriters` | `fn waitingWriters(self: *RwLock) usize` | Debug: queued writer count (O(n)). |

### Writer Priority

Writers have natural priority: a queued writer drains semaphore permits toward zero, causing `tryReadLock()` to fail for new readers. Waiters are served FIFO, so the writer runs before any reader queued behind it.

### Guards

```zig
if (rwlock.tryReadLockGuard()) |guard| {
    var g = guard;
    defer g.deinit();
    // read shared data
}

if (rwlock.tryWriteLockGuard()) |guard| {
    var g = guard;
    defer g.deinit();
    // modify shared data
}
```

### Example: Shared Configuration Store

A configuration store where many tasks read settings frequently but an admin task writes updates infrequently. RwLock allows all readers to proceed in parallel -- they only block when a writer is active.

```zig
const std = @import("std");
const io = @import("blitz-io");

const AppConfig = struct {
    max_connections: u32,
    request_timeout_ms: u64,
    feature_flags: u64,
    log_level: enum { debug, info, warn, err },
};

const ConfigStore = struct {
    rwlock: io.sync.RwLock,
    config: AppConfig,

    fn init(defaults: AppConfig) ConfigStore {
        return .{
            .rwlock = io.sync.RwLock.init(),
            .config = defaults,
        };
    }

    /// Read the current configuration. Multiple tasks can call this
    /// concurrently without blocking each other.
    fn read(self: *ConfigStore) ?AppConfig {
        if (self.rwlock.tryReadLock()) {
            defer self.rwlock.readUnlock();
            return self.config;
        }
        return null; // A writer is active, caller can retry or yield
    }

    /// Check a single feature flag without copying the whole config.
    fn hasFeatureFlag(self: *ConfigStore, flag_bit: u6) ?bool {
        if (self.rwlock.tryReadLock()) {
            defer self.rwlock.readUnlock();
            return (self.config.feature_flags & (@as(u64, 1) << flag_bit)) != 0;
        }
        return null;
    }

    /// Update the configuration. Blocks all readers until complete.
    /// Only one writer can hold the lock at a time.
    fn update(self: *ConfigStore, new_config: AppConfig) bool {
        if (self.rwlock.tryWriteLock()) {
            defer self.rwlock.writeUnlock();
            self.config = new_config;
            return true;
        }
        return false; // Another writer or readers are active
    }

    /// Partially update: change only the timeout, leave everything else.
    fn setTimeout(self: *ConfigStore, timeout_ms: u64) bool {
        if (self.rwlock.tryWriteLock()) {
            defer self.rwlock.writeUnlock();
            self.config.request_timeout_ms = timeout_ms;
            return true;
        }
        return false;
    }
};

var store = ConfigStore.init(.{
    .max_connections = 1000,
    .request_timeout_ms = 30_000,
    .feature_flags = 0,
    .log_level = .info,
});

// Task A, B, C, D (concurrent readers -- all proceed in parallel):
if (store.read()) |cfg| {
    std.log.info("timeout = {d}ms, max_conn = {d}", .{
        cfg.request_timeout_ms,
        cfg.max_connections,
    });
}

// Admin task (exclusive writer -- blocks readers while active):
_ = store.update(.{
    .max_connections = 2000,
    .request_timeout_ms = 15_000,
    .feature_flags = 0b0000_0011, // Enable features 0 and 1
    .log_level = .warn,
});
```

:::tip
Use RwLock when reads vastly outnumber writes. If reads and writes are equally frequent, a plain Mutex is simpler and avoids the overhead of tracking reader counts.
:::

---

## Semaphore

Counting semaphore. Limits concurrent access to a resource.

```zig
const Semaphore = io.sync.Semaphore;
```

### Construction

```zig
var sem = Semaphore.init(10); // 10 permits
```

### Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `tryAcquire` | `fn tryAcquire(self: *Semaphore, num: usize) bool` | Non-blocking acquire (lock-free CAS). |
| `acquireWait` | `fn acquireWait(self: *Semaphore, waiter: *Waiter) bool` | Waiter-based acquire. |
| `release` | `fn release(self: *Semaphore, num: usize) void` | Release permits. Wakes queued waiters. |
| `cancelAcquire` | `fn cancelAcquire(self: *Semaphore, waiter: *Waiter) void` | Cancel and return partial permits. |
| `acquire` | `fn acquire(self: *Semaphore, num: usize) AcquireFuture` | Returns a Future that resolves when permits are acquired. |
| `tryAcquirePermit` | `fn tryAcquirePermit(self: *Semaphore, num: usize) ?SemaphorePermit` | Non-blocking acquire with RAII permit. |
| `availablePermits` | `fn availablePermits(self: *const Semaphore) usize` | Current available permits. |
| `waiterCount` | `fn waiterCount(self: *Semaphore) usize` | Debug: queued waiter count (O(n)). |

### Algorithm

- `tryAcquire`: Lock-free CAS loop. No mutex.
- `release`: Always takes the mutex, serves waiters directly (direct handoff). Only surplus permits go to the atomic counter.
- `acquireWait`: Lock-free fast path for full acquisition. If insufficient permits, locks mutex BEFORE CAS to close the race window.

Key invariant: permits never float in the atomic when waiters are queued.

### SemaphorePermit (RAII)

```zig
if (sem.tryAcquirePermit(1)) |permit| {
    var p = permit;
    defer p.deinit(); // Releases permits
    doWork();
}
```

Methods: `release()`, `forget()` (leak the permit), `deinit()`.

### Example: Connection Pool Limiter

A database connection pool that limits the number of concurrent connections. The semaphore acts as a gatekeeper: each task must acquire a permit before using a connection, and releases it when done.

```zig
const std = @import("std");
const io = @import("blitz-io");

const DbConnectionPool = struct {
    /// Controls how many tasks can hold a connection simultaneously.
    /// Each permit represents one available connection slot.
    semaphore: io.sync.Semaphore,
    max_connections: usize,

    fn init(max_connections: usize) DbConnectionPool {
        return .{
            .semaphore = io.sync.Semaphore.init(max_connections),
            .max_connections = max_connections,
        };
    }

    /// Attempt to acquire a connection slot without waiting.
    /// Returns a permit that MUST be released when the connection is
    /// returned to the pool.
    fn tryGetConnection(self: *DbConnectionPool) ?io.sync.semaphore.SemaphorePermit {
        return self.semaphore.tryAcquirePermit(1);
    }

    /// How many connections are currently available.
    fn availableConnections(self: *DbConnectionPool) usize {
        return self.semaphore.availablePermits();
    }

    /// How many tasks are waiting for a connection.
    fn waitingTasks(self: *DbConnectionPool) usize {
        return self.semaphore.waiterCount();
    }
};

var pool = DbConnectionPool.init(5); // Max 5 concurrent DB connections

fn handleRequest(pool_ptr: *DbConnectionPool) !void {
    // Try to get a connection slot. In an async task, use
    // pool.semaphore.acquire(1) to get a Future that yields.
    if (pool_ptr.tryGetConnection()) |permit| {
        var p = permit;
        defer p.deinit(); // Connection slot is returned to the pool

        // Use the connection for the duration of this scope.
        // Even if executeQuery returns an error, deinit runs
        // and the permit is released.
        try executeQuery();
    } else {
        // All 5 connections are in use. In production you would
        // yield via pool.semaphore.acquire(1) instead of failing.
        return error.PoolExhausted;
    }
}

fn executeQuery() !void {
    // ... actual database work ...
}
```

:::note
`SemaphorePermit` is the recommended way to use semaphores. It guarantees permits are returned even when the task encounters an error, preventing permit leaks that would permanently reduce pool capacity.
:::

### Example: Rate Limiter

Limiting concurrent outbound HTTP requests to avoid overwhelming a downstream service.

```zig
const io = @import("blitz-io");

/// Allow at most 20 outbound requests in flight at once.
var request_limiter = io.sync.Semaphore.init(20);

fn fetchFromUpstream(url: []const u8) ![]const u8 {
    // Acquire 1 permit. If 20 requests are already in flight,
    // this blocks (or yields in async mode) until one finishes.
    if (request_limiter.tryAcquire(1)) {
        defer request_limiter.release(1);
        return doHttpGet(url);
    }
    return error.TooManyRequests;
}

fn doBulkFetch(urls: []const []const u8) !void {
    // Acquire 5 permits at once for a batch operation.
    // This reserves 5 of the 20 slots, leaving 15 for other tasks.
    if (request_limiter.tryAcquire(5)) {
        defer request_limiter.release(5);
        for (urls) |url| {
            _ = try doHttpGet(url);
        }
    }
}

fn doHttpGet(url: []const u8) ![]const u8 {
    _ = url;
    // ... actual HTTP request ...
    return "";
}
```

---

## Notify

Task notification. Wake one or all waiting tasks without passing data.

```zig
const Notify = io.sync.Notify;
```

### Construction

```zig
var notify = Notify.init();
```

### Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `notifyOne` | `fn notifyOne(self: *Notify) void` | Wake one waiting task (FIFO). |
| `notifyAll` | `fn notifyAll(self: *Notify) void` | Wake all waiting tasks. |
| `waitWith` | `fn waitWith(self: *Notify, waiter: *Waiter) void` | Add a waiter. |
| `cancelWait` | `fn cancelWait(self: *Notify, waiter: *Waiter) void` | Remove a waiter. |
| `wait` | `fn wait(self: *Notify) NotifyFuture` | Returns a Future. |

### Waiter

```zig
const Waiter = io.sync.notify.Waiter;

var waiter = Waiter.init();
waiter.setWaker(@ptrCast(&ctx), wakeFn);
notify.waitWith(&waiter);
// After wake: waiter.isNotified() == true
```

Methods on Waiter: `init()`, `initWithWaker(ctx, fn)`, `setWaker(ctx, fn)`, `isReady()`, `isNotified()`, `reset()`.

### Example: Producer Wakes Consumer

A common pattern where one task produces data and another task waits to consume it. The producer writes data into a shared location and then calls `notifyOne()` to wake the consumer.

Without Notify, the consumer would need to spin-poll the shared data, wasting CPU. With Notify, the consumer sleeps efficiently and is woken precisely when data is available.

```zig
const std = @import("std");
const io = @import("blitz-io");

const WorkQueue = struct {
    notify: io.sync.Notify,
    mutex: io.sync.Mutex,
    head: ?*WorkItem,

    const WorkItem = struct {
        payload: []const u8,
        next: ?*WorkItem,
    };

    fn init() WorkQueue {
        return .{
            .notify = io.sync.Notify.init(),
            .mutex = io.sync.Mutex.init(),
            .head = null,
        };
    }

    /// Producer: push work and wake one waiting consumer.
    fn push(self: *WorkQueue, item: *WorkItem) void {
        // Acquire mutex to modify the linked list.
        if (self.mutex.tryLock()) {
            defer self.mutex.unlock();
            item.next = self.head;
            self.head = item;
        }
        // Wake exactly one consumer. If no consumer is waiting,
        // the notification is stored as a permit -- the next call
        // to wait() will return immediately instead of blocking.
        self.notify.notifyOne();
    }

    /// Consumer: wait for work to arrive, then pop it.
    /// In an async context, use notify.wait() to get a Future that
    /// yields to the scheduler instead of blocking.
    fn tryPop(self: *WorkQueue) ?*WorkItem {
        if (self.mutex.tryLock()) {
            defer self.mutex.unlock();
            if (self.head) |item| {
                self.head = item.next;
                item.next = null;
                return item;
            }
        }
        return null;
    }
};

var queue = WorkQueue.init();

// --- Producer task ---
var item = WorkQueue.WorkItem{ .payload = "process this row", .next = null };
queue.push(&item);

// --- Consumer task ---
// In a real async task, you would loop:
//   var future = queue.notify.wait();
//   // ... poll future until ready ...
//   const work = queue.tryPop() orelse continue;
//   handleWork(work);
if (queue.tryPop()) |work| {
    std.log.info("got work: {s}", .{work.payload});
}
```

### Example: Broadcast Shutdown Signal

Use `notifyAll()` to wake every waiting task at once -- for example, to signal that the server is shutting down.

```zig
const io = @import("blitz-io");

var shutdown_signal = io.sync.Notify.init();

// Worker tasks each register a waiter on the same Notify:
// var future = shutdown_signal.wait();
// ... yield until notified ...
// std.log.info("shutting down, cleaning up resources", .{});

// Main task triggers shutdown:
fn initiateShutdown() void {
    // Wake ALL waiting workers simultaneously.
    shutdown_signal.notifyAll();
}
```

---

## Barrier

Synchronization point. Blocks until N tasks arrive, then releases all.

```zig
const Barrier = io.sync.Barrier;
```

### Construction

```zig
var barrier = Barrier.init(4); // 4 tasks must arrive
```

### Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `waitWith` | `fn waitWith(self: *Barrier, waiter: *Waiter) bool` | Arrive at barrier. Returns `true` if this was the last arrival. |
| `wait` | `fn wait(self: *Barrier) BarrierFuture` | Returns a Future. |

### Waiter

```zig
const Waiter = io.sync.barrier.Waiter;

var waiter = Waiter.init();
if (barrier.waitWith(&waiter)) {
    // This task was the leader (last to arrive)
}
// waiter.is_leader.load(.acquire) == true for the leader
// waiter.isReleased() == true for all tasks after release
```

### Leader Election

The last task to arrive is the "leader". Check via `waiter.is_leader.load(.acquire)`. The leader can perform one-time finalization before all tasks proceed.

### Example: Parallel Computation with Checkpoint

Four worker tasks each process a chunk of data, then synchronize at a barrier before the second phase begins. This ensures no worker starts phase 2 until all workers have finished phase 1.

```zig
const std = @import("std");
const io = @import("blitz-io");

const NUM_WORKERS = 4;

const ParallelJob = struct {
    barrier: io.sync.Barrier,
    // Each worker writes to its own slot -- no locking needed.
    phase1_results: [NUM_WORKERS]f64,
    combined_result: f64,

    fn init() ParallelJob {
        return .{
            .barrier = io.sync.Barrier.init(NUM_WORKERS),
            .phase1_results = [_]f64{0} ** NUM_WORKERS,
            .combined_result = 0,
        };
    }

    /// Each worker calls this with its own index.
    fn runWorker(self: *ParallelJob, worker_id: usize, data_chunk: []const f64) void {
        // --- Phase 1: independent computation ---
        var sum: f64 = 0;
        for (data_chunk) |val| {
            sum += val;
        }
        self.phase1_results[worker_id] = sum;

        // --- Barrier: wait for all workers ---
        var waiter = io.sync.barrier.Waiter.init();
        const is_last = self.barrier.waitWith(&waiter);

        if (is_last) {
            // The leader (last to arrive) combines all partial results.
            // At this point, every phase1_results[i] is written.
            var total: f64 = 0;
            for (self.phase1_results) |partial| {
                total += partial;
            }
            self.combined_result = total;
        }

        // After the barrier releases, all workers can read combined_result.
        // In an async context you would use barrier.wait() to get a Future.
    }
};

// Usage:
var job = ParallelJob.init();

// Spawn NUM_WORKERS tasks, each calling job.runWorker(id, chunk).
// After all return, job.combined_result holds the global sum.
```

:::tip
The leader election pattern lets you avoid a separate "reduce" step. The last worker to arrive already knows all other workers are done, so it can safely aggregate the results without additional synchronization.
:::

---

## OnceCell

Lazy one-time initialization. Safe for concurrent access.

```zig
const OnceCell = io.sync.OnceCell;
```

### Construction

```zig
var cell = OnceCell(ExpensiveResource).init();
```

### Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `get` | `fn get(self: *const OnceCell(T)) ?*const T` | Get the value if initialized. Lock-free. |
| `getOrInit` | `fn getOrInit(self: *OnceCell(T), comptime init_fn: fn() T) *const T` | Get or initialize. First caller does the work. |
| `getOrInitWith` | `fn getOrInitWith(self: *OnceCell(T), waiter: *InitWaiter) ?*const T` | Waiter-based init. |
| `set` | `fn set(self: *OnceCell(T), value: T) bool` | Set value. Returns `false` if already initialized. |
| `isInitialized` | `fn isInitialized(self: *const OnceCell(T)) bool` | Check state. |

### State Machine

```
EMPTY --> INITIALIZING --> INITIALIZED
```

- `get()` is lock-free (atomic load).
- `getOrInit()` uses CAS to race for INITIALIZING state. The winner initializes; losers wait.
- After INITIALIZED, all calls return instantly (0.4ns in benchmarks).

### Example: Init-Once Database Pool

A global database connection pool that is created on first access. No matter how many tasks call `getPool()` concurrently, the pool is created exactly once.

```zig
const std = @import("std");
const io = @import("blitz-io");

const DbPool = struct {
    host: []const u8,
    port: u16,
    max_connections: u32,
    // In a real implementation: actual connection handles, etc.
};

/// Global, lazily initialized. No allocator needed for OnceCell itself.
var db_pool_cell = io.sync.OnceCell(DbPool).init();

fn createDbPool() DbPool {
    // This function runs exactly once, even if 100 tasks call getPool()
    // at the same time. The first task to arrive runs this; all others
    // wait and then receive the same pointer.
    std.log.info("initializing database pool (this runs once)", .{});
    return DbPool{
        .host = "db.internal.example.com",
        .port = 5432,
        .max_connections = 20,
    };
}

/// Safe to call from any task, any thread, at any time.
/// First call initializes, all subsequent calls return in ~0.4ns.
fn getPool() *const DbPool {
    return db_pool_cell.getOrInit(createDbPool);
}

// --- In request handler tasks ---
fn handleRequest() void {
    const pool = getPool();
    std.log.info("using pool at {s}:{d}", .{ pool.host, pool.port });
    // ... use pool ...
}
```

### Example: Lazy TLS Configuration

Initialize a TLS configuration once, then share the immutable config across all connection-handling tasks.

```zig
const std = @import("std");
const io = @import("blitz-io");

const TlsConfig = struct {
    cipher_suites: []const u8,
    min_version: u16,
    max_version: u16,
    session_ticket_key: [32]u8,
};

var tls_config_cell = io.sync.OnceCell(TlsConfig).init();

fn loadTlsConfig() TlsConfig {
    // Expensive: reads certificates from disk, generates session keys.
    // Runs once, no matter how many tasks call getTlsConfig().
    var key: [32]u8 = undefined;
    std.crypto.random.bytes(&key);

    return TlsConfig{
        .cipher_suites = "TLS_AES_256_GCM_SHA384",
        .min_version = 0x0303, // TLS 1.2
        .max_version = 0x0304, // TLS 1.3
        .session_ticket_key = key,
    };
}

fn getTlsConfig() *const TlsConfig {
    return tls_config_cell.getOrInit(loadTlsConfig);
}

// You can also use set() if you want to initialize from outside:
fn initFromExternalConfig(config: TlsConfig) bool {
    // Returns false if someone already initialized it.
    return tls_config_cell.set(config);
}
```

:::note
`getOrInit` is the preferred API. It handles the race internally: the first caller to transition state from EMPTY to INITIALIZING does the work, and all other callers block-wait until INITIALIZED. After initialization, `get()` and `getOrInit()` are a single atomic load -- effectively free.
:::

---

## Thread Safety

All sync primitives are safe for concurrent access from multiple tasks and threads. They use:

- **Atomic operations** for lock-free fast paths
- **Intrusive linked lists** for zero-allocation waiter queues
- **Batch waking** (wake outside the critical section) to minimize lock hold time

No raw pointers survive across yield points. Waiters are designed to be stack-allocated by the waiting task.

---

## Choosing the Right Primitive

Use this table to pick the correct primitive for your use case.

| Use Case | Primitive | Why |
|----------|-----------|-----|
| Protect mutable shared state | **Mutex** | Simplest exclusive lock. One holder at a time. |
| Read-heavy shared state with rare writes | **RwLock** | Readers proceed in parallel; only writers block. |
| Limit concurrent access (connection pool, rate limiter) | **Semaphore** | N permits = N concurrent holders. Flexible counting. |
| Signal "something happened" without data | **Notify** | `notifyOne()` for producer/consumer, `notifyAll()` for broadcast signals. |
| Wait for N tasks to reach a checkpoint | **Barrier** | All tasks block until the last one arrives. Leader election included. |
| Expensive one-time initialization | **OnceCell** | First caller initializes, all others get the cached value. Lock-free after init. |
| Pass a single value between two tasks | **Oneshot** channel | See the [Channels API](/api/channel-api). One send, one recv. |
| Multi-producer message queue | **Channel** | See the [Channels API](/api/channel-api). Bounded MPMC queue. |

### Decision Flowchart

1. **Do you need to pass data between tasks?** Use a Channel or Oneshot (see [Channels API](/api/channel-api)).
2. **Do you need to protect shared mutable state?**
   - Reads vastly outnumber writes? Use **RwLock**.
   - Otherwise? Use **Mutex**.
3. **Do you need to limit concurrency (not protect state)?** Use **Semaphore**.
4. **Do you need to signal events without data?**
   - Wake one waiter? `Notify.notifyOne()`.
   - Wake all waiters? `Notify.notifyAll()`.
5. **Do you need all tasks to reach a synchronization point?** Use **Barrier**.
6. **Do you need lazy one-time initialization?** Use **OnceCell**.
