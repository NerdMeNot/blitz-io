# blitz-io Sync Primitives - Second Opinion Request

## Context

**blitz-io** is a high-performance async I/O runtime for Zig, inspired by Tokio (Rust). We're optimizing synchronization primitives and comparing performance against Tokio.

- **Platform**: macOS aarch64 (Apple Silicon)
- **Zig version**: 0.15.2
- **Benchmark**: 100,000 operations, 10 iterations, 4 worker threads

## Current Benchmark Results

### Overall: blitz-io wins 16/22 benchmarks

```
┌──────────────────────┬────────────────┬────────────────┬────────────────┐
│ Benchmark            │       Blitz-IO │          Tokio │ Winner         │
├──────────────────────┼────────────────┼────────────────┼────────────────┤
│ Mutex (uncontended)  │          1.9ns │         10.5ns │ Blitz +5.5x    │
│ Mutex (contended)    │         67.8ns │         60.3ns │ Tokio +0.9x    │
│ RwLock (read)        │          4.0ns │          9.9ns │ Blitz +2.5x    │
│ RwLock (write)       │          5.4ns │         10.3ns │ Blitz +1.9x    │
│ RwLock (contended)   │         96.9ns │         60.8ns │ Tokio +0.6x    │
│ Semaphore            │          4.0ns │          9.9ns │ Blitz +2.5x    │
│ Semaphore (contend)  │        184.3ns │         66.2ns │ Tokio +0.4x    │
│ Barrier (4 threads)  │      84600.0ns │       8095.0ns │ Tokio +0.1x    │
│ Parker               │          2.9ns │          4.9ns │ Blitz +1.7x    │
│ Notify               │    1336700.0ns │    1262891.0ns │ Tokio +0.9x    │
└──────────────────────┴────────────────┴────────────────┴────────────────┘
```

### Key Observations

1. **Uncontended paths are excellent** - 2-5x faster than Tokio
2. **Contended paths are slower** - especially Semaphore (2.8x) and Barrier (10x)
3. **Barrier is 10x slower** - this is the main concern

---

## Changes Made

### 1. Mutex - Rewritten with Futex (3-state machine)

**Before**: Used condvar + mutex for blocking
**After**: Direct Futex with UNLOCKED/LOCKED/CONTENDED states

```zig
pub const Mutex = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(UNLOCKED),

    const UNLOCKED: u32 = 0;
    const LOCKED: u32 = 1;
    const CONTENDED: u32 = 2;
    const SPIN_COUNT: u32 = if (builtin.single_threaded) 0 else 100;

    pub fn lock(self: *Self) void {
        // Fast path: uncontended acquire
        if (self.state.cmpxchgWeak(UNLOCKED, LOCKED, .acquire, .monotonic) == null) {
            return;
        }
        self.lockSlow();
    }

    fn lockSlow(self: *Self) void {
        var status = self.state.load(.monotonic);

        // Adaptive spin phase
        var spin: u32 = SPIN_COUNT;
        while (spin > 0) : (spin -= 1) {
            if (status == UNLOCKED) {
                if (self.state.cmpxchgWeak(UNLOCKED, LOCKED, .acquire, .monotonic) == null) {
                    return;
                }
            }
            std.atomic.spinLoopHint();
            status = self.state.load(.monotonic);
        }

        // Futex wait phase
        while (true) {
            if (status != CONTENDED) {
                status = self.state.swap(CONTENDED, .acquire);
                if (status == UNLOCKED) {
                    return;
                }
            }
            Futex.wait(&self.state, CONTENDED);
            status = self.state.swap(CONTENDED, .acquire);
            if (status == UNLOCKED) {
                return;
            }
        }
    }

    pub fn unlock(self: *Self) void {
        const prev = self.state.swap(UNLOCKED, .release);
        if (prev == CONTENDED) {
            Futex.wake(&self.state, 1);
        }
    }
};
```

**Result**: Contention improved from 91.6ns to 67.8ns (now only 1.1x slower than Tokio)

### 2. ParkingLot - Rewritten with Futex (Tokio's state machine)

**Before**: Used condvar + wait_count/notify_count (had notification loss bugs)
**After**: Atomic state machine with EMPTY/PARKED/NOTIFIED

```zig
pub const ParkingLot = struct {
    state: std.atomic.Value(u32),

    const EMPTY: u32 = 0;
    const PARKED: u32 = 1;
    const NOTIFIED: u32 = 2;

    pub fn wait(self: *Self) void {
        // Fast path: consume existing notification
        if (self.state.cmpxchgStrong(NOTIFIED, EMPTY, .acquire, .monotonic) == null) {
            return;
        }

        // Try to transition EMPTY -> PARKED
        var expected: u32 = EMPTY;
        while (true) {
            if (self.state.cmpxchgWeak(expected, PARKED, .acquire, .monotonic)) |actual| {
                if (actual == NOTIFIED) {
                    _ = self.state.swap(EMPTY, .acquire);
                    return;
                }
                expected = actual;
                continue;
            }
            break;
        }

        // Block on futex until notified
        while (true) {
            Futex.wait(&self.state, PARKED);
            if (self.state.cmpxchgStrong(NOTIFIED, EMPTY, .acquire, .monotonic) == null) {
                return;
            }
        }
    }

    pub fn notifyOne(self: *Self) void {
        // ALWAYS write NOTIFIED - never drop notification
        const prev = self.state.swap(NOTIFIED, .release);
        if (prev == PARKED) {
            Futex.wake(&self.state, 1);
        }
    }
};
```

**Key insight**: `swap(NOTIFIED)` ALWAYS writes, ensuring notifications are never lost.

### 3. Semaphore - Added waiter count optimization

```zig
pub const Semaphore = struct {
    permits: std.atomic.Value(u32),
    waiters: std.atomic.Value(u32),  // Track waiting threads
    max_permits: u32,

    const SPIN_COUNT: u32 = if (builtin.single_threaded) 0 else 100;

    pub fn releaseMany(self: *Self, count: u32) void {
        const prev = self.permits.fetchAdd(count, .release);

        if (prev + count > self.max_permits) {
            @panic("Semaphore over-released");
        }

        // Only wake if there are waiters - avoids unnecessary syscalls
        if (self.waiters.load(.acquire) > 0) {
            Futex.wake(&self.permits, count);
        }
    }

    fn acquireSlow(self: *Self, count: u32) void {
        // Adaptive spin phase
        var spin: u32 = SPIN_COUNT;
        while (spin > 0) : (spin -= 1) {
            if (self.tryAcquireManyFast(count)) return;
            std.atomic.spinLoopHint();
        }

        // Futex wait phase
        while (true) {
            const current = self.permits.load(.acquire);
            if (current >= count) {
                if (self.permits.cmpxchgWeak(current, current - count, .acquire, .monotonic) == null) {
                    return;
                }
                continue;
            }

            // Register as waiter before sleeping
            _ = self.waiters.fetchAdd(1, .release);

            // Double-check after registering
            const recheck = self.permits.load(.acquire);
            if (recheck >= count) {
                _ = self.waiters.fetchSub(1, .release);
                if (self.permits.cmpxchgWeak(recheck, recheck - count, .acquire, .monotonic) == null) {
                    return;
                }
                continue;
            }

            Futex.wait(&self.permits, recheck);
            _ = self.waiters.fetchSub(1, .release);
        }
    }
};
```

### 4. Barrier - Implemented 4-state "Tickle-Then-Get-Sleepy" protocol

This pattern comes from our sister project (blitz - CPU parallelism library) to prevent missed wakes:

```zig
pub const Barrier = struct {
    count: u32,
    waiting: std.atomic.Value(u32),
    generation: std.atomic.Value(u32),
    sleeping: std.atomic.Value(u32),  // Track threads in futex wait

    const SPIN_LIMIT: u32 = 10;
    const YIELD_LIMIT: u32 = 20;

    pub fn wait(self: *Self) bool {
        const gen = self.generation.load(.acquire);
        const pos = self.waiting.fetchAdd(1, .acq_rel) + 1;

        if (pos == self.count) {
            // Leader: release everyone
            self.waiting.store(0, .release);
            _ = self.generation.fetchAdd(1, .seq_cst);

            // Only wake if there are sleeping threads
            const num_sleeping = self.sleeping.load(.acquire);
            if (num_sleeping > 0) {
                Futex.wake(&self.generation, num_sleeping);
            }
            return true;
        }

        // Waiter: adaptive spin then sleep
        var iteration: u32 = 0;

        while (self.generation.load(.acquire) == gen) {
            if (iteration < SPIN_LIMIT) {
                // Exponential backoff spin
                var spins: u32 = @as(u32, 1) << @min(iteration, 5);
                while (spins > 0) : (spins -= 1) {
                    std.atomic.spinLoopHint();
                }
                iteration += 1;
                continue;
            }

            if (iteration < YIELD_LIMIT) {
                std.Thread.yield() catch {};
                iteration += 1;
                continue;
            }

            // CRITICAL: Announce intent to sleep BEFORE checking condition
            _ = self.sleeping.fetchAdd(1, .seq_cst);

            // Check condition AGAIN after announcing (prevents missed wake)
            if (self.generation.load(.seq_cst) != gen) {
                _ = self.sleeping.fetchSub(1, .release);
                break;
            }

            // Actually sleep
            Futex.wait(&self.generation, gen);
            _ = self.sleeping.fetchSub(1, .release);
        }

        return false;
    }
};
```

---

## The Barrier Problem

### The 10x Performance Gap

| Implementation | Time | Notes |
|----------------|------|-------|
| blitz-io Barrier | 84.6µs | OS threads + Futex |
| Tokio Barrier | 8.1µs | Async tasks + cooperative yield |

### Root Cause Analysis

The benchmark comparison is **apples vs oranges**:

**blitz-io benchmark:**
```zig
var threads: [4]std.Thread = undefined;
for (&threads) |*t| {
    t.* = try std.Thread.spawn(.{}, struct {
        fn run(b: *Barrier) void {
            _ = b.wait();  // Blocks OS thread with Futex
        }
    }.run, .{&barrier});
}
```

**Tokio benchmark:**
```rust
for _ in 0..4 {
    let barrier = barrier.clone();
    tokio::spawn(async move {
        barrier.wait().await;  // Yields async task, no kernel
    });
}
```

**The difference:**
- `std.Thread.spawn` creates real OS threads → kernel scheduling overhead
- `tokio::spawn` creates async tasks → cooperative yielding, no kernel
- Each OS context switch costs ~1-2µs vs ~200ns for async yield
- For 4 threads with contention, this multiplies

### Possible Solutions

#### Option A: Keep current Barrier for OS threads, document the use case
The current Futex-based barrier is **correct** for synchronizing OS threads. The benchmark comparison with Tokio isn't fair because Tokio's barrier is for async tasks.

#### Option B: Create AsyncBarrier using WaiterQueue
```zig
pub const AsyncBarrier = struct {
    count: u32,
    waiting: std.atomic.Value(u32),
    generation: std.atomic.Value(u32),
    waiters: WaiterQueue,
    lock: std.Thread.Mutex,

    pub fn wait(self: *Self) void {
        // ... similar logic but use WaiterQueue instead of Futex
        // Waiters spin-wait instead of blocking
    }
};
```

#### Option C: Pure spin barrier for short waits
```zig
pub const SpinBarrier = struct {
    // No Futex at all, pure spinning
    // Good when threads arrive within ~1µs
};
```

#### Option D: Sense-reversing barrier
More efficient for repeated barrier use (avoids generation counter).

---

## Questions for Second Opinion

1. **Is our Futex usage correct?** Particularly:
   - Memory ordering choices (.acquire/.release vs .seq_cst)
   - The "announce intent to sleep before checking" pattern
   - Waiter count tracking to avoid unnecessary wakes

2. **Semaphore contention (2.8x slower than Tokio)** - What are we missing?
   - Tokio's semaphore uses a different approach?
   - Is our waiter management inefficient?

3. **RwLock contention (1.6x slower)** - The writer priority handling seems correct but slow

4. **Barrier: Should we provide multiple implementations?**
   - FutexBarrier for OS threads (current)
   - AsyncBarrier for async tasks (new)
   - SpinBarrier for ultra-fast sync (new)

5. **Are there better patterns for ARM64 (Apple Silicon)?**
   - Current spin count is 100, is this optimal?
   - Any ARM64-specific Futex considerations?

6. **Tokio comparison fairness** - Is comparing our Futex-based primitives against Tokio's async primitives meaningful? Should we compare against:
   - `std::sync::Barrier` (Rust's OS thread barrier)
   - `parking_lot` crate (Rust's optimized blocking primitives)

---

## File Locations

| File | Description |
|------|-------------|
| `src/sync/mutex.zig` | Mutex, RwLock, MutexGuard |
| `src/sync/semaphore.zig` | Semaphore, Barrier, OnceLock |
| `src/sync/park.zig` | Parker, ParkingLot |
| `src/sync/waiter.zig` | Waiter, WaiterQueue |
| `src/sync/channel.zig` | Channel, Oneshot, MpmcChannel |
| `bench/bench.zig` | Zig benchmarks |
| `bench/rust_bench/src/main.rs` | Tokio benchmarks |
| `bench/compare.zig` | Comparison tool |

---

## Reference: blitz latch.zig (4-state protocol origin)

From our CPU parallelism library that solved similar Futex issues:

```zig
// The 4-state protocol prevents missed wakes
const State = enum(u8) {
    UNSET = 0,    // Initial state
    SLEEPY = 1,   // Thread announced intent to sleep
    SLEEPING = 2, // Thread is actually in Futex.wait
    SET = 3,      // Latch has been triggered
};

// SpinWait with exponential backoff
pub const SpinWait = struct {
    counter: u8 = 0,
    const SPIN_LIMIT: u8 = 6;
    const YIELD_LIMIT: u8 = 10;

    pub fn spinOne(self: *SpinWait) void {
        if (self.counter < SPIN_LIMIT) {
            // Exponential backoff: 1, 2, 4, 8, 16, 32 spins
            var spins = @as(u32, 1) << @intCast(self.counter);
            while (spins > 0) : (spins -= 1) {
                std.atomic.spinLoopHint();
            }
        } else if (self.counter < YIELD_LIMIT) {
            std.Thread.yield() catch {};
        } else {
            std.Thread.sleep(1_000); // 1µs
        }
        self.counter +|= 1;
    }
};
```

---

## Appendix: Full Benchmark Output

```
================================================================================
                       Blitz-IO Benchmark Suite
================================================================================
Iterations: 10 (+ 3 warmup)   Platform: aarch64
Workers: 4

N = 100000
================================================================================
  Task alloc:         0.5ns/op    1901140684 ops/sec
  Mutex:              1.9ns/op     532765051 ops/sec
  Mutex (4T):        69.5ns/op      14388489 ops/sec
  RwLock read:        3.9ns/op     256937307 ops/sec
  RwLock write:       5.2ns/op     191350938 ops/sec
  Semaphore:          3.9ns/op     255558395 ops/sec
  Sem (8T/2P):      188.8ns/op       5298013 ops/sec

N = 10000 (includes blocking benchmarks)
================================================================================
  Barrier (4T):   85900.0ns total
  Parker:             3.4ns/op     296735905 ops/sec
  Notify (4T):   1369000.0ns total
  Oneshot:            2.9ns/op     343642612 ops/sec
  MPMC (LF):          7.7ns/op     129701686 ops/sec
```
