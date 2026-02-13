---
title: Comparing with Tokio
description: How blitz-io benchmarks against Tokio, the comparison framework, current results, and methodology.
---

blitz-io includes a head-to-head comparison framework that runs identical benchmarks against [Tokio](https://github.com/tokio-rs/tokio), the Rust async I/O runtime that inspired much of blitz-io's architecture.

## Running the comparison

```bash
zig build compare
```

This single command:

1. Builds the Tokio benchmark (`cargo build --release` in `bench/rust_bench/`)
2. Runs the blitz-io benchmark (`zig-out/bench/blitz_bench --json`)
3. Runs the Tokio benchmark (`bench/rust_bench/target/release/blitz_rust_bench --json`)
4. Parses both JSON outputs and prints a formatted comparison table

### Prerequisites

- **Zig 0.15.2+** for blitz-io
- **Rust 1.86+** with Cargo for Tokio
- Both toolchains must be in your `PATH`

## The comparison framework

### Architecture

```
bench/
  blitz_bench.zig             # Blitz-IO benchmarks (Zig)
  compare.zig                 # Comparison driver (Zig)
  rust_bench/
    Cargo.toml                # Tokio dependency
    src/main.rs               # Tokio benchmarks (Rust)
```

The `compare.zig` driver is a standalone Zig program that:

1. Resolves the project root directory from its own executable path.
2. Invokes both benchmark binaries with `--json` flags via `std.process.Child`.
3. Parses the JSON output into `BenchmarkResults` structs.
4. Computes winners using a 5% tolerance band (ratios within 0.95--1.05 are reported as ties).
5. Prints a Unicode box-drawing table with ANSI color coding.

### Matching methodology

Both benchmark suites share identical configuration constants to ensure a fair comparison:

| Constant | Value | Applies to |
|----------|-------|------------|
| `SYNC_OPS` | 1,000,000 | Tier 1 |
| `CHANNEL_OPS` | 100,000 | Tier 2 |
| `ASYNC_OPS` | 10,000 | Tier 3 |
| `ITERATIONS` | 10 | All tiers |
| `WARMUP` | 5 | All tiers |
| `NUM_WORKERS` | 4 | Tier 3 |
| `MPMC_BUFFER` | 1,000 | MPMC benchmark |
| `CONTENDED_MUTEX_TASKS` | 4 | Contended mutex |
| `CONTENDED_SEM_TASKS` | 8 | Contended semaphore |
| `CONTENDED_SEM_PERMITS` | 2 | Contended semaphore |

Both sides use the same statistical methodology: median of 10 iterations after 5 warmup iterations discarded.

### Allocation tracking

Both sides track heap allocations:

- **Blitz-IO**: `CountingAllocator` wrapping `GeneralPurposeAllocator`, using atomics for thread safety.
- **Tokio**: Custom `GlobalAlloc` wrapper around `System`, using `AtomicUsize` counters.

This allows comparing not just speed but memory efficiency (bytes per operation).

### What each tier measures

**Tier 1 (Sync fast path)**: Both sides call `try_lock`/`try_acquire` -- the synchronous, non-blocking API. No runtime overhead. This isolates the raw cost of the data structure: CAS operations, atomic fences, and memory barriers.

**Tier 2 (Channel fast path)**: Both sides call `try_send`/`try_recv` -- synchronous buffer operations. No scheduling or waking. This isolates the channel's ring buffer implementation.

**Tier 3 (Async multi-task)**: Both sides use their full runtimes. Blitz-IO uses `Runtime.spawn()` with `FutureTask` state machines. Tokio uses `tokio::spawn()` with `async`/`.await`. This measures real-world contention including scheduling, waking, and backpressure.

## Current results

Test platform: MacBook Pro (Apple M3 Pro, 11 cores, 18 GB RAM), macOS arm64, Zig 0.15.2, Rust 1.86.0 (Tokio 1.43).

### Synchronization -- Uncontended

| Benchmark | Blitz-IO | Tokio | B/op (Blitz) | B/op (Tokio) | Winner |
|-----------|----------|-------|--------------|--------------|--------|
| Mutex | 6.6 ns | 7.8 ns | 0 | 0 | Blitz +1.2x |
| RwLock (read) | 6.8 ns | 7.9 ns | 0 | 0 | Blitz +1.2x |
| RwLock (write) | 6.6 ns | 8.0 ns | 0 | 0 | Blitz +1.2x |
| Semaphore | 6.5 ns | 7.5 ns | 0 | 0 | Blitz +1.2x |

### Synchronization -- Contended

| Benchmark | Blitz-IO | Tokio | B/op (Blitz) | B/op (Tokio) | Winner |
|-----------|----------|-------|--------------|--------------|--------|
| Mutex (4 threads) | 115.5 ns | 81.2 ns | 0.1 | 0.2 | Tokio +1.4x |
| RwLock (4R + 2W) | 108.1 ns | 95.1 ns | 0.1 | 0.2 | Tokio +1.1x |
| Semaphore (8T, 2 permits) | 77.5 ns | 127.7 ns | 0.2 | 0.2 | Blitz +1.6x |

### Channels

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

| Benchmark | Blitz-IO | Tokio | B/op (Blitz) | B/op (Tokio) | Winner |
|-----------|----------|-------|--------------|--------------|--------|
| OnceCell get (hot path) | 0.4 ns | 0.5 ns | 0 | 0 | Blitz +1.1x |
| OnceCell set | 9.5 ns | 30.4 ns | 0 | 64 | Blitz +3.2x |

### Coordination

| Benchmark | Blitz-IO | Tokio | B/op (Blitz) | B/op (Tokio) | Winner |
|-----------|----------|-------|--------------|--------------|--------|
| Barrier | 15.4 ns | 368.6 ns | 0 | 1064 | Blitz +23.9x |
| Notify | 9.7 ns | 9.4 ns | 0 | 0 | Tie |

### Summary

```
Blitz-IO wins: 14 / 18    Tokio wins: 3 / 18    Tie: 1 / 18

Total bytes per op:   Blitz-IO 50.2    Tokio 1347.6  (27x less)
Total allocs per op:  Blitz-IO 0.003   Tokio 14.07
```

## Where blitz-io wins and why

blitz-io leads in 14 of 18 benchmarks. The primary advantages come from language-level properties and a zero-allocation architecture:

**Intrusive waiters** -- Waiter nodes are embedded directly in futures on the stack, eliminating the heap allocations that Tokio makes for waiter bookkeeping. This is the single largest factor: 50.2 bytes/op vs 1,347.6 bytes/op across all benchmarks.

**Comptime specialization** -- Generic lock and channel types are monomorphized at compile time with concrete waker types, removing the virtual dispatch Tokio pays through `dyn Future` trait objects and `Waker` vtables.

**Vyukov MPMC ring buffer** -- The bounded channel uses a lock-free ring buffer with per-slot sequence counters, giving excellent throughput in single-producer and few-producer cases.

**O(1) bitmap worker waking** -- The scheduler uses `@ctz` on a packed 64-bit bitmap to find idle workers in constant time, where Tokio scans a list.

**Zero-allocation oneshot and barrier** -- Tokio's oneshot allocates a shared `Arc<Inner>` (72 bytes) and its barrier allocates tracking state (1,064 bytes). Blitz-IO uses stack-embedded atomics for both.

## Where Tokio wins and why

Tokio outperforms blitz-io in three areas:

**Contended mutex and rwlock** (by 1.1--1.4x) -- Tokio's locking path benefits from `parking_lot`-style adaptive spinning: a hybrid strategy that spins briefly before parking the thread, tuned over years of production feedback. Blitz-IO's intrusive waiter approach skips spinning and goes straight to futex-based parking, which costs more under short hold times with high thread counts.

**MPMC channel** (by 1.4x) -- Tokio delegates to a `crossbeam`-style segmented queue with per-segment backoff, purpose-built for multi-producer multi-consumer throughput. Blitz-IO uses a Vyukov MPMC bounded ring buffer, which is simpler and faster in SPSC/MPSC modes but pays more under symmetric contention from both sides.

## Interpreting results

### Caveats

- These are **microbenchmarks** on a single machine (Apple M3 Pro, macOS arm64). Results on Linux x86_64 may differ significantly due to different cache hierarchies, memory ordering costs, and kernel scheduling.
- Run-to-run variance is typically 5--15%. The 5% tie band accounts for this.
- Zig and Rust have different compilation models. Some differences may reflect compiler optimization strategy rather than runtime design.
- Tokio is mature and battle-tested at scale. Blitz-IO is new and less proven in production.
- Bytes-per-op reflects allocator overhead in the benchmark harness, not necessarily application-level memory usage.

### When to re-run

Re-run the comparison after:

- Changing any sync primitive, channel, or scheduler code
- Updating the Zig or Rust compiler version
- Changing the benchmark configuration constants
- Testing on a different platform

### Adding a new benchmark to the comparison

1. Add the benchmark to both `bench/blitz_bench.zig` and `bench/rust_bench/src/main.rs` with identical configuration.
2. Add a field to the `BenchmarkResults` struct in `bench/compare.zig`.
3. Add a mapping in the `getBenchEntry` function.
4. Add a `printRow` call in the appropriate section of `main()`.

## Acknowledgments

Tokio has been the gold standard for async I/O runtimes since 2018. Blitz-IO's scheduler, sync primitives, cooperative budgeting, and ScheduledIo state machine are all adapted from Tokio's design. We benchmark against Tokio to keep ourselves honest, not to claim superiority.
