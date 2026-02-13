# Synchronization Primitives

blitz-io provides six async-aware synchronization primitives that integrate with the work-stealing scheduler. Unlike OS-level blocking primitives (`std.Thread.Mutex`, etc.), these yield to the scheduler when contended, allowing other tasks to make progress on the same worker thread.

All primitives are zero-allocation and require no `deinit()`.

## API Tiers

Every primitive exposes three tiers of API:

| Tier | Pattern | Behavior |
|------|---------|----------|
| Non-blocking | `tryX()` | Returns immediately. Returns `bool` or optional. |
| Waiter | `xWait(waiter)` | Low-level. Caller manages waiter lifetime and waker callback. |
| Async Future | `x()` -> Future | Returns a Future for integration with the scheduler's poll loop. |

The non-blocking tier is lock-free (CAS loops, no mutex). The waiter tier takes the internal mutex only on the slow path. The Future tier wraps the waiter tier with waker management.

---

## Mutex

Mutual exclusion. Protects shared state from concurrent access. Built on `Semaphore(1)` -- all correctness flows through the semaphore's proven direct-handoff algorithm.

### API

```zig
var mutex = io.sync.Mutex.init();
```

**Non-blocking:**

```zig
if (mutex.tryLock()) {
    defer mutex.unlock();
    // critical section
}
```

**Guard (RAII):**

```zig
if (mutex.tryLockGuard()) |guard| {
    var g = guard;
    defer g.deinit(); // unlocks automatically
    // critical section
}
```

**Waiter (low-level):**

```zig
var waiter = io.sync.mutex.Waiter.init();
waiter.setWaker(@ptrCast(&my_ctx), myWakeFn);

if (mutex.lockWait(&waiter)) {
    // Acquired immediately
} else {
    // Waiter queued -- yield to scheduler.
    // When woken: waiter.isAcquired() == true
}
defer mutex.unlock();
```

**Async Future:**

```zig
var future = mutex.lock(); // Returns LockFuture
defer future.deinit();

// Poll through the runtime. Resolves to void when lock is acquired.
// After resolution, caller owns the lock and must call mutex.unlock().
```

### Semantics

- FIFO ordering: waiters are served in the order they arrived.
- Direct handoff: `unlock()` transfers ownership directly to the next waiter. The lock is never momentarily "free" when waiters exist.
- Cancellation: `mutex.cancelLock(&waiter)` removes a waiter from the queue.

### Example: Protecting shared state

```zig
const io = @import("blitz-io");

var mutex = io.sync.Mutex.init();
var shared_counter: u64 = 0;

fn incrementTask() void {
    if (mutex.tryLock()) {
        defer mutex.unlock();
        shared_counter += 1;
    }
}
```

---

## RwLock

Read-write lock. Multiple concurrent readers OR one exclusive writer. Built on `Semaphore(MAX_READS)` where `MAX_READS = ~536 million`.

- Read lock = acquire 1 permit
- Write lock = acquire MAX_READS permits (drains all)

### Writer Priority

Writer priority emerges naturally from the semaphore's FIFO queue. When a writer is queued, its partial acquisition drains available permits toward zero, causing subsequent `tryReadLock()` calls to fail. The FIFO queue ensures the writer is served before any reader queued behind it.

### API

```zig
var rwlock = io.sync.RwLock.init();
```

**Non-blocking:**

```zig
// Read lock (concurrent)
if (rwlock.tryReadLock()) {
    defer rwlock.readUnlock();
    const value = shared_data;
}

// Write lock (exclusive)
if (rwlock.tryWriteLock()) {
    defer rwlock.writeUnlock();
    shared_data = new_value;
}
```

**Guards (RAII):**

```zig
if (rwlock.tryReadLockGuard()) |guard| {
    var g = guard;
    defer g.deinit();
    // read shared data
}

if (rwlock.tryWriteLockGuard()) |guard| {
    var g = guard;
    defer g.deinit();
    // write shared data
}
```

**Waiter (low-level):**

```zig
var read_waiter = io.sync.rwlock.ReadWaiter.init();
read_waiter.setWaker(@ptrCast(&ctx), wakeFn);
if (!rwlock.readLockWait(&read_waiter)) {
    // Queued -- yield
}
defer rwlock.readUnlock();

var write_waiter = io.sync.rwlock.WriteWaiter.init();
write_waiter.setWaker(@ptrCast(&ctx), wakeFn);
if (!rwlock.writeLockWait(&write_waiter)) {
    // Queued -- yield
}
defer rwlock.writeUnlock();
```

**Async Future:**

```zig
var read_future = rwlock.readLock();   // Returns ReadLockFuture
var write_future = rwlock.writeLock(); // Returns WriteLockFuture
defer read_future.deinit();
defer write_future.deinit();
```

**Diagnostics (zero extra atomics on hot path):**

```zig
rwlock.isWriteLocked()   // true when writer holds lock
rwlock.getReaderCount()  // number of active readers
rwlock.waitingReaders()  // O(n) queue walk
rwlock.waitingWriters()  // O(n) queue walk
```

### Example: Concurrent cache

```zig
const io = @import("blitz-io");

var rwlock = io.sync.RwLock.init();
var cache: [256]?CacheEntry = [_]?CacheEntry{null} ** 256;

fn lookup(key: u8) ?CacheEntry {
    if (rwlock.tryReadLock()) {
        defer rwlock.readUnlock();
        return cache[key];
    }
    return null;
}

fn insert(key: u8, entry: CacheEntry) void {
    if (rwlock.tryWriteLock()) {
        defer rwlock.writeUnlock();
        cache[key] = entry;
    }
}
```

---

## Semaphore

Counting semaphore. Limits concurrent access to a shared resource. Uses a batch algorithm with direct-handoff to prevent starvation.

### Algorithm

- `tryAcquire(n)`: Lock-free CAS loop. No mutex taken.
- `acquireWait(waiter)`: Lock-free CAS fast path for full acquisition. If insufficient permits, locks mutex BEFORE the CAS that drains remaining permits -- this closes the race window between draining and queueing.
- `release(n)`: ALWAYS takes the mutex to check for waiters. Permits are handed directly to queued waiters; only surplus goes to the atomic counter. This ensures no permits "float" in the atomic when waiters are queued.

### API

```zig
var sem = io.sync.Semaphore.init(100); // 100 permits
```

**Non-blocking:**

```zig
if (sem.tryAcquire(1)) {
    defer sem.release(1);
    // hold one permit
}

// Batch acquire
if (sem.tryAcquire(10)) {
    defer sem.release(10);
    // hold 10 permits
}
```

**Permit guard (RAII):**

```zig
if (sem.tryAcquirePermit(1)) |permit| {
    var p = permit;
    defer p.deinit(); // releases automatically

    // Or: p.forget() to leak the permit intentionally
}
```

**Waiter (low-level):**

```zig
var waiter = io.sync.semaphore.Waiter.init(5); // request 5 permits
waiter.setWaker(@ptrCast(&ctx), wakeFn);

if (sem.acquireWait(&waiter)) {
    // All 5 permits acquired immediately
} else {
    // Queued with partial acquisition -- yield
    // waiter.isComplete() becomes true when all permits granted
}
defer sem.release(5);
```

**Async Future:**

```zig
var future = sem.acquire(3); // Returns AcquireFuture
defer future.deinit();

// Resolves to void when 3 permits are acquired.
// Caller must call sem.release(3) after use.
```

**Cancellation:**

```zig
sem.cancelAcquire(&waiter);
// Returns any partially acquired permits back to the semaphore.
```

### Example: Connection pool limiter

```zig
const io = @import("blitz-io");

var pool_sem = io.sync.Semaphore.init(50); // max 50 connections

fn handleRequest() void {
    if (pool_sem.tryAcquire(1)) {
        defer pool_sem.release(1);
        processRequest();
    } else {
        rejectWithServiceUnavailable();
    }
}
```

---

## Barrier

Synchronization barrier for N tasks. All tasks must arrive before any can proceed. One task is designated the "leader" (the last to arrive).

### API

```zig
var barrier = io.sync.Barrier.init(4); // 4 tasks must arrive
```

**Waiter (low-level):**

```zig
var waiter = io.sync.barrier.Waiter.init();
waiter.setWaker(@ptrCast(&ctx), wakeFn);

if (barrier.waitWith(&waiter)) {
    // We are the leader (last to arrive). All others are woken.
} else {
    // Queued -- yield. waiter.isReleased() becomes true when all arrive.
}

if (waiter.is_leader.load(.acquire)) {
    // Perform one-time post-barrier work
}
```

**Async Future:**

```zig
var future = barrier.wait(); // Returns WaitFuture
defer future.deinit();

// Resolves to BarrierWaitResult when all tasks have arrived.
// result.is_leader is true for exactly one task per generation.
```

**Diagnostics:**

```zig
barrier.arrivedCount()      // tasks arrived at current generation
barrier.totalTasks()        // total required
barrier.currentGeneration() // increments each time barrier releases
```

### Reusable across generations

After all N tasks pass, the barrier resets automatically. The generation counter increments, and the barrier can be used again immediately.

### Example: Phased computation

```zig
const io = @import("blitz-io");

var barrier = io.sync.Barrier.init(4);

fn workerPhase(phase: usize) void {
    // Do phase work...
    computePhase(phase);

    // Synchronize
    var waiter = io.sync.barrier.Waiter.init();
    if (barrier.waitWith(&waiter)) {
        // Leader: merge results from all workers
        mergeResults();
    }
    // All workers proceed to next phase together
}
```

---

## Notify

Task notification primitive. Wakes one or all waiting tasks. Similar to a condition variable but designed for async task coordination.

### Permit-based semantics

If `notifyOne()` is called with no waiters, a **permit** is stored. The next `waitWith()` call consumes the permit and returns immediately. This prevents the notify-before-wait race condition. Permits do not accumulate -- multiple `notifyOne()` calls store at most one permit.

`notifyAll()` does NOT store a permit if no tasks are waiting.

### API

```zig
var notify = io.sync.Notify.init();
```

**Non-blocking check:**

```zig
notify.hasPermit() // true if a stored permit exists
```

**Waiter (low-level):**

```zig
var waiter = io.sync.notify.Waiter.init();
waiter.setWaker(@ptrCast(&ctx), wakeFn);

if (notify.waitWith(&waiter)) {
    // Consumed a stored permit -- immediate return
} else {
    // Queued -- yield. waiter.isNotified() becomes true when woken.
}
```

**Async Future:**

```zig
var future = notify.wait(); // Returns WaitFuture
defer future.deinit();

// Resolves to void when notified.
```

**Notifying:**

```zig
notify.notifyOne(); // Wake one waiter (or store permit)
notify.notifyAll(); // Wake all waiters (no permit stored if none waiting)
```

**Cancellation:**

```zig
notify.cancelWait(&waiter); // Remove from queue if not yet notified
```

### Example: Work queue signaling

```zig
const io = @import("blitz-io");

var notify = io.sync.Notify.init();
var work_available = false;

fn producer() void {
    // Produce work...
    work_available = true;
    notify.notifyOne();
}

fn consumer() void {
    var waiter = io.sync.notify.Waiter.init();
    if (!notify.waitWith(&waiter)) {
        // Yield until notified
    }
    if (work_available) {
        processWork();
    }
}
```

---

## OnceCell

Thread-safe lazy one-time initialization. The value is computed on first access; concurrent callers either race to initialize or wait for the winner to finish.

### State machine

```
EMPTY ---> INITIALIZING ---> INITIALIZED
```

- First caller to CAS `EMPTY -> INITIALIZING` runs the init function.
- Other callers see `INITIALIZING` and register as waiters.
- When init completes, all waiters are woken and see the value.

### API

```zig
var cell = io.sync.OnceCell(Config).init();

// Or pre-initialize:
var cell = io.sync.OnceCell(Config).initWith(default_config);
```

**Non-blocking get:**

```zig
if (cell.get()) |config| {
    // Already initialized -- use config
}

cell.isInitialized() // bool
```

**Set (try once):**

```zig
if (cell.set(my_config)) {
    // We initialized it
} else {
    // Someone else already initialized
}
```

**Waiter (low-level):**

```zig
const initFn = struct {
    fn f() Config {
        return loadConfigFromDisk();
    }
}.f;

var waiter = io.sync.once_cell.InitWaiter.init();
waiter.setWaker(@ptrCast(&ctx), wakeFn);

if (cell.getOrInitWith(initFn, &waiter)) |config_ptr| {
    // Got value immediately (already initialized or we initialized it)
} else {
    // Another task is initializing -- yield.
    // waiter.isComplete() becomes true when done.
    // Then: cell.get().? gives the value.
}
```

**Async Future:**

```zig
const initFn = struct {
    fn f() Config {
        return loadConfigFromDisk();
    }
}.f;

var future = cell.getOrInit(initFn); // Returns GetOrInitFuture
defer future.deinit();

// Resolves to *Config when initialization is complete.
```

### Example: Singleton configuration

```zig
const io = @import("blitz-io");

var global_config = io.sync.OnceCell(AppConfig).init();

fn getConfig() *AppConfig {
    if (global_config.get()) |cfg| return cfg;

    // Race to initialize
    const initFn = struct {
        fn f() AppConfig {
            return AppConfig.loadFromFile("config.toml");
        }
    }.f;

    var waiter = io.sync.once_cell.InitWaiter.init();
    if (global_config.getOrInitWith(initFn, &waiter)) |cfg| {
        return cfg;
    }

    // Spin-wait (in practice, use the Future API with scheduler)
    while (!waiter.isComplete()) {
        std.Thread.yield() catch {};
    }
    return global_config.get().?;
}
```

---

## Performance

Benchmark results on Apple M3 (nanoseconds per operation):

| Primitive | blitz-io | Tokio | Ratio |
|-----------|----------|-------|-------|
| OnceCell get | 0.4ns | 0.5ns | 1.2x faster |
| OnceCell set | 9.4ns | 28.6ns | 3.0x faster |
| Mutex (uncontended) | 10.2ns | 7.9ns | 1.3x slower |
| RwLock read | 11.0ns | 8.0ns | 1.4x slower |
| RwLock write | 10.2ns | 8.0ns | 1.3x slower |
| Semaphore | 9.7ns | 7.2ns | 1.3x slower |
| Notify | 9.9ns | 9.1ns | 1.1x slower |
| Barrier | 15.3ns | 397.9ns | 26.0x faster |
| Mutex (contended) | 99.1ns | 77.1ns | 1.3x slower |
| Semaphore (contended) | 162.5ns | 135.5ns | 1.2x slower |
| RwLock (contended) | 94.4ns | 94.7ns | Tie |

Run benchmarks with `zig build bench` or `zig build compare` for the full comparison.
