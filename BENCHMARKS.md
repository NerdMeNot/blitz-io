# Blitz-IO Benchmarks

Performance comparison between Blitz-IO and [Tokio](https://github.com/tokio-rs/tokio).

## Standing on Tokio's Shoulders

Tokio has been the gold standard for async I/O runtimes since 2018. It powers networking,
synchronization, and task scheduling in a huge fraction of the Rust ecosystem, and its design
has influenced every async runtime that followed.

Blitz-IO wouldn't exist without Tokio. Its ScheduledIo state machine, its work-stealing
scheduler, its sync primitives, its approach to cooperative budgeting -- we studied and learned
from all of it. Where Blitz-IO differs, it's because Zig's comptime specialization, value
semantics, and zero-cost intrusive data structures open up paths that weren't available in Rust,
not because we found flaws in Tokio's design.

We benchmark against Tokio to keep ourselves honest, not to claim superiority. Tokio is a
mature, battle-tested runtime with years of production use powering services at massive scale.
Blitz-IO is new. These numbers are a snapshot in time on one machine -- your mileage will vary.

## Test Platform

- **Machine**: MacBook Pro (Apple M3 Pro, 11 cores, 18 GB RAM)
- **OS**: macOS (arm64)
- **Zig**: 0.15.2
- **Rust**: 1.86.0 (Tokio 1.43)
- **Warmup**: 3 iterations discarded
- **Measured**: 5 iterations averaged

## Running Benchmarks

```bash
zig build compare
```

This builds and runs both Blitz-IO (Zig) and Tokio (Rust) benchmarks with identical
configurations, then prints a side-by-side comparison table.

## Results

### Synchronization -- Uncontended

Single-thread lock/unlock cycle with no contention.

| Benchmark | Blitz-IO | Tokio | B/op (Blitz) | B/op (Tokio) | Winner |
|-----------|----------|-------|--------------|--------------|--------|
| Mutex | 6.6 ns | 7.8 ns | 0 | 0 | Blitz +1.2x |
| RwLock (read) | 6.8 ns | 7.9 ns | 0 | 0 | Blitz +1.2x |
| RwLock (write) | 6.6 ns | 8.0 ns | 0 | 0 | Blitz +1.2x |
| Semaphore | 6.5 ns | 7.5 ns | 0 | 0 | Blitz +1.2x |

### Synchronization -- Contended

Multiple threads competing for the same lock.

| Benchmark | Blitz-IO | Tokio | B/op (Blitz) | B/op (Tokio) | Winner |
|-----------|----------|-------|--------------|--------------|--------|
| Mutex (4 threads) | 115.5 ns | 81.2 ns | 0.1 | 0.2 | Tokio +1.4x |
| RwLock (4R + 2W) | 108.1 ns | 95.1 ns | 0.1 | 0.2 | Tokio +1.1x |
| Semaphore (8T, 2 permits) | 77.5 ns | 127.7 ns | 0.2 | 0.2 | Blitz +1.6x |

### Channels

Message-passing primitives.

| Benchmark | Blitz-IO | Tokio | B/op (Blitz) | B/op (Tokio) | Winner |
|-----------|----------|-------|--------------|--------------|--------|
| Channel send | 2.7 ns | 5.8 ns | 16 | 9 | Blitz +2.2x |
| Channel recv | 6.1 ns | 9.7 ns | 16 | 9 | Blitz +1.6x |
| Channel roundtrip | 6.3 ns | 12.5 ns | 0 | 0 | Blitz +2.0x |
| Channel MPMC (4P + 4C) | 85.6 ns | 61.1 ns | 1.8 | 2.1 | Tokio +1.4x |
| Oneshot | 3.9 ns | 15.4 ns | 0 | 72 | Blitz +3.9x |
| Broadcast (4 receivers) | 22.2 ns | 48.7 ns | 16 | 126.9 | Blitz +2.2x |
| Watch | 13.1 ns | 43.7 ns | 0 | 0 | Blitz +3.3x |

### OnceCell

One-time initialization primitive.

| Benchmark | Blitz-IO | Tokio | B/op (Blitz) | B/op (Tokio) | Winner |
|-----------|----------|-------|--------------|--------------|--------|
| OnceCell get (hot path) | 0.4 ns | 0.5 ns | 0 | 0 | Blitz +1.1x |
| OnceCell set | 9.5 ns | 30.4 ns | 0 | 64 | Blitz +3.2x |

### Coordination

Multi-party synchronization.

| Benchmark | Blitz-IO | Tokio | B/op (Blitz) | B/op (Tokio) | Winner |
|-----------|----------|-------|--------------|--------------|--------|
| Barrier | 15.4 ns | 368.6 ns | 0 | 1064 | Blitz +23.9x |
| Notify | 9.7 ns | 9.4 ns | 0 | 0 | Tie |

### Summary

```
Blitz-IO wins: 14 / 18    Tokio wins: 3 / 18    Tie: 1 / 18

Total allocations per op:  Blitz-IO 0.003    Tokio 14.07
Total bytes per op:        Blitz-IO 50.2     Tokio 1347.6  (27x less)
```

## Where Tokio Wins

Tokio outperforms Blitz-IO in three areas:

- **Contended mutex and rwlock** (by 1.1-1.4x). Tokio's locking path benefits from
  `parking_lot`-style adaptive spinning -- a hybrid strategy that spins briefly before
  parking the thread, tuned over years of production feedback. Blitz-IO's intrusive waiter
  approach skips spinning and goes straight to futex-based parking, which costs more under
  short hold times with high thread counts.

- **MPMC channel** (by 1.4x). Tokio delegates to a crossbeam-style segmented queue with
  per-segment backoff, purpose-built for multi-producer multi-consumer throughput. Blitz-IO
  uses a Vyukov MPMC bounded ring buffer, which is simpler and faster in SPSC/MPSC modes
  but pays more under symmetric contention from both sides.

## What Helps Blitz-IO

Most of Blitz-IO's advantages come from Zig's language properties and a zero-allocation
architecture rather than algorithmic breakthroughs:

- **Intrusive waiters** -- waiter nodes are embedded directly in futures on the stack,
  eliminating the heap allocations Tokio makes for waiter bookkeeping. This is the single
  largest factor: 50.2 bytes/op vs 1,347.6 bytes/op across all benchmarks.

- **Comptime specialization** -- generic lock and channel types are monomorphized at compile
  time with concrete waker types, removing the virtual dispatch Tokio pays through
  `dyn Future` trait objects and `Waker` vtables.

- **Vyukov MPMC ring buffer** -- the bounded channel uses a lock-free ring buffer with
  per-slot sequence counters, giving excellent throughput in the common single-producer and
  few-producer cases.

- **O(1) bitmap worker waking** -- the scheduler uses `@ctz` on a packed bitmap to find idle
  workers in constant time, where Tokio scans a list.

- **Zero-allocation oneshot and barrier** -- Tokio's oneshot allocates a shared `Arc<Inner>`
  (72 bytes) and its barrier allocates tracking state (1,064 bytes). Blitz-IO uses
  stack-embedded atomics for both, explaining the 3.9x and 23.9x gaps respectively.

The work-stealing scheduler, the cooperative budgeting, the ScheduledIo state machine,
the sync primitive designs -- these are all Tokio's ideas, adapted for Zig.

## Caveats

- Single machine, single OS -- results on Linux x86_64 may differ significantly
- Microbenchmarks, not real workloads -- production performance depends on many factors
- Zig and Rust have different compilation models; some differences may reflect compiler
  optimization strategy rather than runtime design
- Run-to-run variance is typically 5-15% on these benchmarks
- Tokio is mature and battle-tested at scale; Blitz-IO is new and less proven in production
- Bytes-per-op reflects allocator overhead in the benchmark harness, not necessarily
  application-level memory usage

## Acknowledgments

- [Tokio](https://github.com/tokio-rs/tokio) -- the runtime that defined how async I/O should work
- [Mio](https://github.com/tokio-rs/mio) -- platform I/O abstraction we study for every backend
- [parking_lot](https://github.com/Amanieu/parking_lot) -- adaptive locking strategies
- [Crossbeam](https://github.com/crossbeam-rs/crossbeam) -- lock-free channel designs
- [Vyukov MPMC](https://www.1024cores.net/home/lock-free-algorithms/queues/bounded-mpmc-queue) -- bounded ring buffer for channels
