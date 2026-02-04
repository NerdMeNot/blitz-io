# CLAUDE.md - blitz-io Development Guide

## Build Requirements

| Requirement | Version |
|-------------|---------|
| **Zig** | **0.15.2** (minimum 0.15.0) |
| Linux | Kernel 5.1+ for io_uring, 4.x+ for epoll |
| macOS | 10.12+ for kqueue |
| Windows | Windows 10+ for IOCP |

**IMPORTANT:** Zig APIs change between versions. All code must target Zig 0.15.x APIs. When referencing Zig standard library documentation or examples, ensure they are for 0.15.x.

Key 0.15.x API notes:
- `std.atomic.Value(T)` for atomics (not `std.atomic.Atomic`)
- `std.Thread.Futex` for futex operations
- `std.posix` for POSIX syscalls (not `std.os`)
- No `@fence` builtin - use atomic fetchAdd(0, .seq_cst) for fences
- Async/await not yet in 0.15 - manual state machines required

**Collection Initialization Patterns (0.15.x):**
```zig
// ArrayList - unmanaged pattern (pass allocator to methods)
var list: std.ArrayList(T) = .empty;
try list.append(allocator, item);
list.deinit(allocator);

// AutoHashMap - managed pattern (allocator stored internally)
var map = std.AutoHashMap(K, V).init(allocator);
try map.put(key, value);  // no allocator needed
map.deinit();  // no allocator needed
```

## Git Conventions

- **No Co-Authored-By**: Do not add `Co-Authored-By` lines to commit messages
- Keep commit messages concise and descriptive
- Use conventional commit style when appropriate (feat:, fix:, docs:, etc.)

## Project Vision

**blitz-io** is a high-performance, cross-platform async I/O runtime for Zig. It serves as the I/O counterpart to [Blitz](https://github.com/your-repo/blitz) (CPU parallelism) - analogous to how Tokio complements Rayon in the Rust ecosystem.

This library aims to become foundational infrastructure for the Zig ecosystem. **Correctness is non-negotiable.** We would rather ship later with bulletproof platform support than ship early with subtle bugs that surface under load in production.

## Core Principles

### 1. Platform Correctness Above All

The #1 priority is getting platform-specific details **exactly right**. Tokio has accumulated years of battle-tested fixes for edge cases in:
- Socket option handling
- Signal delivery semantics
- Timer precision and drift
- File descriptor lifecycle
- Memory ordering in lock-free structures
- Platform-specific error codes and their meanings

**We port Tokio's platform logic with a hawk eye.** Every syscall wrapper, every edge case handler, every platform-specific workaround must be studied and understood before implementing.

### 2. Developer Ergonomics

This could be the async I/O foundation for countless Zig projects. The API must be:
- **Intuitive** - Follow Zig idioms, not Rust/Go patterns forced into Zig
- **Hard to misuse** - Compile-time errors over runtime surprises
- **Zero-surprise** - Predictable behavior, explicit trade-offs
- **Debuggable** - Clear error messages, observable internal state

### 3. Performance Through Correctness

Fast but wrong is useless. We optimize only after proving correctness:
1. Implement correctly with clear code
2. Add comprehensive tests
3. Benchmark against baselines
4. Optimize hot paths with profiler guidance
5. Re-verify correctness after optimization

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         User Application                             │
│                    (uses std.Io interface)                          │
└─────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                           std.Io Interface                           │
│              (Zig standard library abstraction)                      │
└─────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         blitz-io Runtime                             │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌────────────┐ │
│  │   Executor  │  │  I/O Driver │  │   Timers    │  │   Sync     │ │
│  │             │  │             │  │             │  │ Primitives │ │
│  │ • Scheduler │  │ • Submit    │  │ • Wheel     │  │            │ │
│  │ • Task Pool │  │ • Complete  │  │ • Deadline  │  │ • Channel  │ │
│  │ • Work Steal│  │ • Poll      │  │ • Interval  │  │ • Mutex    │ │
│  └─────────────┘  └─────────────┘  └─────────────┘  └────────────┘ │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │                      Platform Backend                            ││
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐        ││
│  │  │ io_uring │  │  kqueue  │  │   IOCP   │  │   epoll  │        ││
│  │  │ (Linux)  │  │ (macOS)  │  │ (Windows)│  │(fallback)│        ││
│  │  └──────────┘  └──────────┘  └──────────┘  └──────────┘        ││
│  └─────────────────────────────────────────────────────────────────┘│
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                              Blitz                                   │
│                    (CPU-bound work handoff)                         │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Tokio Reference Guide

The `tokio/` directory contains the complete Tokio source for reference. **Study these files carefully before implementing corresponding blitz-io components.**

### Critical Platform-Specific Code to Study

#### I/O Driver Layer
```
tokio/tokio/src/runtime/io/
├── driver.rs              # Core I/O driver - event loop integration
├── registration.rs        # How I/O resources register with the driver
├── scheduled_io.rs        # Per-resource state machine (CRITICAL)
└── registration_set.rs    # Managing sets of registrations
```

**Key insight:** `scheduled_io.rs` contains the state machine for tracking I/O readiness. This is where subtle bugs hide. Study the state transitions carefully.

#### Scheduler Implementations
```
tokio/tokio/src/runtime/scheduler/
├── mod.rs                 # Scheduler abstraction
├── current_thread/        # Single-threaded scheduler
├── multi_thread/          # Work-stealing multi-threaded scheduler
│   ├── worker.rs          # Worker thread logic (CRITICAL)
│   ├── queue.rs           # Lock-free work queue
│   ├── park.rs            # Thread parking/unparking
│   └── idle.rs            # Idle worker management
└── inject/                # Global injection queue
```

**Key insight:** The work-stealing queue in `queue.rs` and the parking logic in `park.rs` are where race conditions lurk. Every atomic operation has a reason.

#### Timer Wheel
```
tokio/tokio/src/runtime/time_alt/
├── wheel/                 # Hierarchical timing wheel
├── entry.rs               # Timer entry representation
├── timer.rs               # Timer driver
├── wake_queue.rs          # Waking expired timers
├── cancellation_queue.rs  # Timer cancellation
└── registration_queue.rs  # Timer registration
```

**Key insight:** Timer implementations have subtle bugs around:
- What happens when timers fire at exactly the same time?
- Timer drift under load
- Cancellation races

#### Network I/O
```
tokio/tokio/src/net/
├── tcp/
│   ├── listener.rs        # TcpListener - accept() edge cases
│   ├── stream.rs          # TcpStream - read/write state
│   └── split.rs           # Splitting read/write halves
├── udp.rs                 # UDP socket handling
└── unix/                  # Unix domain sockets
```

**Key insight:** Socket options, shutdown semantics, and half-close handling vary significantly between platforms.

#### Synchronization Primitives
```
tokio/tokio/src/sync/
├── mpsc/                  # Multi-producer single-consumer channel
├── oneshot.rs             # One-shot channel
├── watch.rs               # Watch channel (single value broadcast)
├── broadcast.rs           # Broadcast channel
├── mutex.rs               # Async mutex
├── rwlock.rs              # Async read-write lock
├── semaphore.rs           # Counting semaphore
└── notify.rs              # Task notification
```

**Key insight:** The `mpsc` channel implementation is particularly complex. Study how it handles:
- Sender/receiver lifecycle
- Backpressure
- Waker management

### Mio: The Platform Abstraction

Tokio uses [mio](https://github.com/tokio-rs/mio) for platform-specific I/O. Key areas:

- **Linux**: epoll with edge-triggered mode, careful handling of EAGAIN/EWOULDBLOCK
- **macOS/BSD**: kqueue with EV_CLEAR for edge-triggered behavior
- **Windows**: IOCP (I/O Completion Ports) - fundamentally different model

We must implement equivalent abstractions in Zig, handling the same edge cases.

---

## Implementation Guidelines

### Before Writing Any Code

1. **Find the Tokio equivalent** - What file(s) in Tokio handle this?
2. **Read the Tokio code** - Understand what it does and why
3. **Read the comments** - Tokio comments often explain non-obvious edge cases
4. **Check git blame** - Bug fix commits explain what went wrong
5. **Search Tokio issues** - Related bugs and discussions

### Platform-Specific Checklist

Before marking any platform backend as "complete":

#### Linux (io_uring)
- [ ] Kernel version detection and feature probing
- [ ] Graceful fallback when features unavailable
- [ ] SQ/CQ ring overflow handling
- [ ] EAGAIN handling in non-blocking mode
- [ ] Registered buffers setup and teardown
- [ ] Registered file descriptors
- [ ] Multishot operations (accept, recv)
- [ ] Linked operations for atomic sequences
- [ ] SQPOLL mode and its implications
- [ ] Signal handling interaction

#### Linux (epoll fallback)
- [ ] Edge-triggered vs level-triggered semantics
- [ ] EPOLLONESHOT for thread safety
- [ ] EPOLLET edge cases
- [ ] epoll_pwait for signal safety
- [ ] Handling EINTR correctly

#### macOS (kqueue)
- [ ] EV_CLEAR for edge-triggered behavior
- [ ] EV_ONESHOT implications
- [ ] EVFILT_READ/EVFILT_WRITE registration
- [ ] NOTE_* flags for extended info
- [ ] kevent64 vs kevent
- [ ] Descriptor lifetime and close races

#### Windows (IOCP)
- [ ] CreateIoCompletionPort association
- [ ] GetQueuedCompletionStatus vs GetQueuedCompletionStatusEx
- [ ] Overlapped structure lifetime
- [ ] CancelIoEx for cancellation
- [ ] Socket-specific: WSARecv, WSASend, ConnectEx, AcceptEx
- [ ] File-specific: ReadFile, WriteFile with OVERLAPPED

### Code Style

```zig
// GOOD: Explain WHY, not WHAT
// We must check for EAGAIN even after epoll indicates readiness because
// another thread may have consumed the data between epoll_wait returning
// and our read() call (spurious wakeup).
const n = posix.read(fd, buf) catch |err| switch (err) {
    error.WouldBlock => return .pending,
    else => return err,
};

// BAD: States the obvious
// Check if read would block
const n = posix.read(fd, buf) catch |err| switch (err) {
    error.WouldBlock => return .pending,
    else => return err,
};
```

### Error Handling Philosophy

1. **Never swallow errors** - Log or propagate, never ignore
2. **Distinguish recoverable vs fatal** - WouldBlock is normal, EBADF is a bug
3. **Platform-specific error mapping** - Same logical error may have different codes
4. **Include context** - Error messages should help debugging

### Memory Safety

1. **No raw pointers across await points** - Task may resume on different thread
2. **Clear ownership** - Who allocates? Who frees? Document it.
3. **Arena allocators for request-scoped data**
4. **Pool long-lived objects** - Tasks, buffers, timers

### Concurrency Rules

1. **Document thread safety** - Is this type Send? Sync? Neither?
2. **Atomic operations need memory ordering justification**
3. **Lock ordering** - Document to prevent deadlocks
4. **Prefer lock-free for hot paths** - But prove correctness first

---

## Testing Requirements

### Unit Tests
Every module must have tests covering:
- Happy path
- Error conditions
- Edge cases (empty input, max values, etc.)
- Platform-specific behavior

### Integration Tests
- Multi-threaded stress tests
- High connection count tests
- Timer accuracy tests
- Cancellation tests

### Platform Matrix
CI must test on:
- Linux x86_64 (io_uring kernel 5.11+)
- Linux x86_64 (epoll fallback, kernel 4.x)
- Linux aarch64
- macOS x86_64
- macOS aarch64 (Apple Silicon)
- Windows x86_64

### Loom Testing (Concurrency)
For lock-free structures, we need exhaustive concurrency testing similar to Tokio's use of Loom. Investigate Zig equivalents or build custom test harnesses.

---

## Project Structure

```
blitz-io/
├── build.zig
├── build.zig.zon
├── README.md
├── CLAUDE.md              # This file
├── LICENSE
│
├── src/
│   ├── lib.zig            # Public API entry point
│   ├── runtime.zig        # Runtime lifecycle
│   ├── config.zig         # Configuration
│   ├── io.zig             # std.Io implementation
│   ├── future.zig         # Future type
│   ├── time.zig           # Duration, Instant
│   │
│   ├── util/              # Core data structures (port from Tokio)
│   │   ├── slab.zig       # Slab allocator - O(1) insert/remove/access
│   │   ├── linked_list.zig # Intrusive doubly-linked list
│   │   ├── bit.zig        # Bit packing utilities
│   │   ├── cacheline.zig  # Cache-line alignment
│   │   └── wake_list.zig  # Batch waker invocation
│   │
│   ├── backend/           # Platform-specific I/O
│   │   ├── completion.zig # Common types (Operation, Completion)
│   │   ├── scheduled_io.zig # Per-resource state (tick + readiness)
│   │   ├── io_uring.zig   # Linux io_uring
│   │   ├── epoll.zig      # Linux epoll
│   │   ├── kqueue.zig     # macOS/BSD kqueue
│   │   ├── iocp.zig       # Windows IOCP
│   │   └── poll.zig       # Universal fallback
│   │
│   ├── executor/          # Task execution
│   │   ├── scheduler.zig  # Task scheduling
│   │   ├── worker.zig     # Worker threads
│   │   ├── task.zig       # Task representation
│   │   ├── local_queue.zig
│   │   └── global_queue.zig
│   │
│   ├── timer/             # Time management
│   │   ├── wheel.zig      # Timer wheel
│   │   └── sleep.zig      # sleep, timeout
│   │
│   ├── net/               # Networking
│   │   ├── tcp.zig
│   │   ├── udp.zig
│   │   └── address.zig
│   │
│   ├── fs/                # Filesystem
│   │   └── file.zig
│   │
│   ├── sync/              # Synchronization
│   │   ├── channel.zig
│   │   ├── mutex.zig
│   │   ├── semaphore.zig
│   │   └── waiter.zig
│   │
│   └── bridge/            # Blitz integration
│       └── blitz.zig
│
├── examples/
├── benchmarks/
└── tests/
```

---

## Development Workflow

### Adding a New Feature

1. **Design doc** - Write a brief design in an issue/PR description
2. **Find Tokio reference** - Link to relevant Tokio code
3. **Implement** - Follow the guidelines above
4. **Test** - Unit + integration tests
5. **Document** - API docs + any gotchas
6. **Review** - At least one other pair of eyes

### Debugging Platform Issues

1. **Reproduce consistently** - Create minimal reproduction
2. **Check Tokio issues** - Has this been seen before?
3. **Add tracing** - Instrument the code path
4. **Bisect** - Find which change introduced it
5. **Fix and add test** - Prevent regression

### Performance Work

1. **Benchmark first** - Establish baseline
2. **Profile** - Find actual bottleneck (don't guess)
3. **Optimize** - Make targeted change
4. **Benchmark again** - Verify improvement
5. **Test correctness** - Optimization must not break things

---

## Key Decisions Log

Document major architectural decisions here with rationale.

| Decision | Rationale | Date |
|----------|-----------|------|
| Port Tokio's platform logic | Battle-tested, years of edge case fixes | 2025-01-31 |
| Stackless coroutines | ~100-256 bytes per task vs KB for stackful | 2025-01-31 |
| io_uring as primary Linux backend | Highest performance, true async | 2025-01-31 |
| Work-stealing optional | Thread-per-core better for io_uring | 2025-01-31 |
| Production-grade from start | Powers haul (CSV/Parquet/JSON/Arrow/Excel I/O) | 2025-01-31 |
| Slab + Intrusive Lists, no HashMap | Match Tokio's hot path - O(1) everything | 2025-01-31 |
| Skip switz intermediate | Go straight to production architecture | 2025-01-31 |

---

## Data Structures: Our Approach vs Tokio

### Tokio's Hot Path Data Structures

After analyzing Tokio's implementation, they **avoid HashMaps on hot paths**:

1. **Intrusive Linked Lists** (`tokio/src/util/linked_list.rs`)
   - Waiters are embedded in the objects themselves (zero allocation per wait)
   - O(1) insertion and removal
   - No hash computation overhead

2. **Atomic Bit-Packed State** (`scheduled_io.rs`)
   ```rust
   // | shutdown (1 bit) | tick (15 bits) | readiness (16 bits) |
   readiness: AtomicUsize
   ```
   - Single CAS operation for state updates
   - Tick counter prevents ABA problem (lost wakeups)

3. **Token-Based Direct Indexing**
   - Convert pointer to token: `mio::Token(ptr as usize)`
   - No hash lookup needed - O(1) direct access

4. **Slab Allocator** (external `slab` crate)
   - Used for io_uring operation tracking
   - Compact allocation with stable indices

5. **Reserved Waker Slots**
   - Special `reader` and `writer` fields in `Waiters`
   - Fast path for common read/write operations

### Our Current Approach (MVP)

For the initial implementation, we use simpler data structures:

```zig
// kqueue.zig / epoll.zig
pending: std.AutoHashMap(u64, PendingOp),  // Track by user_data
```

**Trade-offs:**
- ✅ Simpler to implement and verify correct
- ✅ Good enough for moderate connection counts
- ❌ Hash computation on every lookup
- ❌ Potential cache misses from pointer chasing

### Target Architecture (Production-Grade)

**No intermediate steps. We implement Tokio's production patterns directly.**

This library will power **haul** (CSV, Parquet, JSON, Arrow IPC, Excel I/O), so it must be production-ready from day one.

```
Current (Scaffolding)              Target (Production)
─────────────────────────────────────────────────────────────────────
std.AutoHashMap              →     Slab allocator + Token indexing
HashMap lookup per event     →     Direct pointer cast (O(1))
No state versioning          →     Tick-based readiness (ABA prevention)
Basic structs                →     Cache-aligned (128 bytes on x86_64)
```

### Required Data Structures

**1. Slab Allocator** - Compact allocation with stable indices
```zig
// Provides O(1) insert, remove, and index-based access
// Used for tracking pending operations and registered I/O resources
pub const Slab(T) = struct {
    entries: []Entry,
    next_free: usize,
    len: usize,

    pub fn insert(self: *Slab, value: T) !usize { ... }
    pub fn remove(self: *Slab, key: usize) T { ... }
    pub fn get(self: *Slab, key: usize) ?*T { ... }
};
```

**2. Intrusive Linked List** - Zero-allocation waiter tracking
```zig
// Waiters embed their own list pointers - no separate allocation
pub const IntrusiveList(T) = struct {
    head: ?*T,
    tail: ?*T,

    pub fn push(self: *IntrusiveList, node: *T) void { ... }
    pub fn remove(self: *IntrusiveList, node: *T) void { ... }
};
```

**3. Bit-Packed State** - Single atomic for readiness + tick + shutdown
```zig
// | shutdown (1 bit) | tick (15 bits) | readiness (16 bits) |
pub const PackedState = struct {
    value: std.atomic.Value(u32),

    const READINESS_MASK: u32 = 0xFFFF;
    const TICK_SHIFT: u5 = 16;
    const TICK_MASK: u32 = 0x7FFF << TICK_SHIFT;
    const SHUTDOWN_BIT: u32 = 1 << 31;

    pub fn setReadiness(self: *PackedState, ready: Ready) void { ... }
    pub fn getTickAndReadiness(self: *PackedState) struct { tick: u15, ready: Ready } { ... }
};
```

**4. Cache-Aligned Wrapper** - Prevent false sharing
```zig
pub fn CacheAligned(comptime T: type) type {
    const CACHE_LINE = switch (builtin.cpu.arch) {
        .x86_64, .aarch64, .powerpc64 => 128,
        .arm, .mips, .mips64, .sparc, .hexagon => 32,
        .s390x => 256,
        else => 64,
    };
    return struct {
        data: T align(CACHE_LINE),
    };
}
```

### Tokio Utilities to Port

From `tokio/src/util/`:

| Utility | Purpose | Port Priority |
|---------|---------|---------------|
| `linked_list.rs` | Intrusive doubly-linked list | Phase 3 |
| `bit.rs` | Bit packing utilities | Phase 2 |
| `wake_list.rs` | Batch waker invocation | Phase 2 |
| `cacheline.rs` | Cache line alignment | Phase 2 |
| `sharded_list.rs` | Lock-sharded list | Phase 3 |

---

## Current Implementation vs Tokio: Gap Analysis

### What We Have (Scaffolding)
```zig
// kqueue.zig wait() - current scaffolding
for (events) |event| {
    const pending = self.pending.get(user_data) orelse continue;  // HashMap lookup - REPLACE
    const result = self.performOperation(pending.op);
    completions[count] = Completion{ ... };
    _ = self.pending.remove(user_data);  // HashMap remove - REPLACE
}
```

### What Tokio Does (Our Target)
```rust
// driver.rs turn() - Tokio's production implementation
for event in events.iter() {
    if token == TOKEN_WAKEUP { ... }        // 1. Wakeup handling
    else if token == TOKEN_SIGNAL { ... }    // 2. Signal handling
    else {
        let io: &ScheduledIo = unsafe { &*ptr };  // 3. Direct pointer (no HashMap!)
        io.set_readiness(Tick::Set, |curr| curr | ready);  // 4. Tick-based state
        io.wake(ready);  // 5. Wake matching waiters
    }
}
```

### Implementation Roadmap

All items are required. No optional "nice-to-haves".

**Phase 1: Core Data Structures**
- [ ] Slab allocator (`src/util/slab.zig`)
- [ ] Intrusive linked list (`src/util/linked_list.zig`)
- [ ] Bit packing utilities (`src/util/bit.zig`)
- [ ] Cache-aligned wrapper (`src/util/cacheline.zig`)

**Phase 2: Replace HashMap with Production Structures**
- [ ] `ScheduledIo` equivalent with packed atomic state
- [ ] Token-based direct indexing (pointer ↔ token)
- [ ] Replace `pending: AutoHashMap` with Slab
- [ ] Tick-based readiness for ABA prevention

**Phase 3: Event Loop Completeness**
- [ ] Wakeup mechanism (cross-thread notification)
- [ ] Signal handling integration
- [ ] Proper cancellation support
- [ ] Batch waker invocation (`WakeList`)

**Phase 4: Production Hardening**
- [ ] Graceful shutdown
- [ ] Metrics and observability
- [ ] Memory pooling for buffers
- [ ] Comprehensive error mapping per platform

---

## Blitz Integration

blitz-io and Blitz are designed to work together like Tokio and Rayon in Rust. The key insight: **I/O-bound work stays in blitz-io, CPU-bound work goes to Blitz**.

### Blitz Architecture Summary

Blitz (`/Users/srini/Code/blitz/`) provides:
- **Lock-free work-stealing** - Chase-Lev deques per worker
- **Zero-allocation fork-join** - Stack-allocated `Future` with embedded latch
- **JEC protocol** - Jobs Event Counter for efficient sleep/wake
- **Parallel iterators** - `iter()`, `iterMut()`, `range()`

Key files to understand:
```
blitz/
├── pool.zig      # ThreadPool, Worker, Sleep manager, AtomicCounters
├── future.zig    # Future<Input, Output> with embedded OnceLatch
├── api.zig       # High-level API (join, parallelFor, iter)
├── deque.zig     # Chase-Lev lock-free deque
└── latch.zig     # OnceLatch, CountLatch, SpinWait
```

### Integration Patterns

#### 1. CPU-Bound Work Offload

When blitz-io encounters CPU-intensive work, hand it to Blitz:

```zig
// In blitz-io user code
fn processData(io: blitz_io.Io, data: []const u8) !ProcessedData {
    // I/O: fetch more data (stays in blitz-io)
    const extra = try io.fs.readFile("extra.dat", allocator);

    // CPU: heavy computation (goes to Blitz)
    const result = try blitz_io.computeOnBlitz(io, heavyComputation, .{ data, extra });

    // I/O: write result (back to blitz-io)
    try io.fs.writeFile("output.dat", result);

    return result;
}
```

#### 2. Parallel Map with I/O

```zig
fn fetchAndProcess(io: blitz_io.Io, urls: []const []const u8) ![]Result {
    // Fetch all URLs concurrently (I/O-bound, blitz-io)
    var futures: [MAX_URLS]blitz_io.Future([]u8) = undefined;
    for (urls, 0..) |url, i| {
        futures[i] = io.@"async"(fetchUrl, .{ io, url });
    }

    // Collect responses
    var responses = try allocator.alloc([]u8, urls.len);
    for (&futures, 0..) |*f, i| {
        responses[i] = try f.await(io);
    }

    // Process all responses in parallel (CPU-bound, Blitz)
    return blitz_io.parallelMap(io, []u8, Result, responses, processResponse);
}
```

### Bridge Implementation

The bridge module must handle:

1. **Oneshot channel** - Send result from Blitz worker back to blitz-io task
2. **Task waking** - Blitz completion must wake the waiting blitz-io task
3. **Error propagation** - Blitz panics/errors must propagate to blitz-io

```zig
// src/bridge/blitz.zig (conceptual)

pub fn computeOnBlitz(
    io: Io,
    comptime func: anytype,
    args: std.meta.ArgsTuple(@TypeOf(func)),
) !ReturnType(func) {
    const Result = ReturnType(func);

    // 1. Create oneshot for result delivery
    var channel = Oneshot(Result).init();

    // 2. Create waker that blitz-io understands
    const current_task = getCurrentTask();

    // 3. Wrap the work to send result back
    const wrapper = struct {
        fn run(a: @TypeOf(args), ch: *Oneshot(Result), waker: *Waker) void {
            const result = @call(.auto, func, a);
            ch.send(result);
            waker.wake();  // Wake the blitz-io task
        }
    };

    // 4. Submit to Blitz via job injection
    try blitz.getPool().injectJob(...);

    // 5. Yield blitz-io task until result ready
    return channel.recv(io);
}
```

### Blitz Changes to Consider

Current Blitz may need enhancements for clean integration:

| Change | Rationale | Priority |
|--------|-----------|----------|
| Public `injectJobWithCallback` | Allow external result notification | High |
| `Oneshot` channel primitive | Zero-alloc single-value delivery | Medium |
| Task context for injected jobs | Injected jobs don't have `*Task` | Medium |
| Configurable wake callback | Let blitz-io provide custom waker | Low |

### Thread Safety Considerations

1. **blitz-io tasks are NOT Blitz workers** - They don't have deques, can't steal
2. **Blitz workers are NOT blitz-io executors** - They don't poll I/O
3. **Shared resources need synchronization** - Allocators, channels, etc.
4. **Don't block Blitz workers on I/O** - Use `spawnBlocking` for blocking ops

### Testing the Integration

```zig
test "blitz-io + Blitz integration" {
    // 1. Initialize both runtimes
    var io_runtime = try blitz_io.Runtime.init(allocator, .{});
    defer io_runtime.deinit();

    try blitz.init();
    defer blitz.deinit();

    // 2. Run mixed workload
    const result = try io_runtime.block_on(mixedWorkload, .{io_runtime.io});

    try testing.expect(result.success);
}

fn mixedWorkload(io: blitz_io.Io) !TestResult {
    // I/O: read file
    const data = try io.fs.readFile("input.dat", allocator);

    // CPU: process with Blitz
    const processed = try blitz_io.computeOnBlitz(io, processData, .{data});

    // I/O: write result
    try io.fs.writeFile("output.dat", processed);

    return .{ .success = true };
}
```

---

## Resources

### Zig
- [Zig Language Reference](https://ziglang.org/documentation/master/)
- [Zig's New Async I/O](https://kristoff.it/blog/zig-new-async-io/) - Loris Cro
- [zig-aio](https://github.com/Cloudef/zig-aio) - Existing Zig async I/O

### Tokio (Reference Implementation)
- [Tokio Tutorial](https://tokio.rs/tokio/tutorial)
- [Tokio Internals](https://tokio.rs/tokio/tutorial/internals)
- [Mio](https://github.com/tokio-rs/mio) - Platform abstraction

### io_uring
- [Lord of the io_uring](https://unixism.net/loti/)
- [io_uring and Zig](https://gavinray97.github.io/blog/io-uring-fixed-bufferpool-zig)
- [liburing](https://github.com/axboe/liburing)
- [io_uring kernel docs](https://kernel.dk/io_uring.pdf)

### kqueue
- [FreeBSD kqueue man page](https://www.freebsd.org/cgi/man.cgi?query=kqueue)
- [macOS kqueue](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/KernelQueues/KernelQueues.html)

### IOCP
- [Windows IOCP docs](https://docs.microsoft.com/en-us/windows/win32/fileio/i-o-completion-ports)
- [IOCP internals](https://www.microsoftpressstore.com/articles/article.aspx?p=2224373)

---

## Contact & Contribution

- Issues: Report bugs, request features
- PRs: Follow the development workflow above
- Discussions: Architecture questions, design debates

**Remember: We're building infrastructure that others will depend on. Take the time to get it right.**
