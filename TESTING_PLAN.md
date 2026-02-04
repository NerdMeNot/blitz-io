# blitz-io Testing Plan

This document tracks the testing gaps and progress toward production-ready test coverage.

**Current State:** ~587 tests | **Target:** ~530 tests | **Gap:** Target exceeded by ~57!

---

## Phase 1: Critical Infrastructure (MUST FIX)

These are blocking issues - the core runtime has almost no tests.

### 1.1 Scheduler Tests (`src/executor/scheduler.zig`)
> Current: 15 tests | Target: 15 tests

- [x] Scheduler init and deinit
- [x] Scheduler init with single threaded strategy
- [x] Scheduler start and shutdown
- [x] Spawn enqueues task
- [x] Spawn multiple tasks enqueues all
- [x] spawnWithBackpressure returns ok
- [x] totalQueueDepth tracking
- [x] getMetrics returns valid data
- [x] Metrics update after spawn
- [x] thread_per_core strategy enqueues
- [x] Shutdown with pending tasks - drains properly
- [x] getBackend returns valid backend
- [x] Double start is safe
- [x] blockOnAll with empty queues
- [ ] Task execution end-to-end (integration test - needs worker task completion flow)

### 1.2 Runtime Integration Tests (`src/runtime.zig`)
> Current: 20 tests | Target: 20 tests

- [x] Runtime init with default config
- [x] Runtime init with custom worker count/config
- [x] Runtime deinit - clean shutdown
- [x] `run` - simple sync function
- [x] `run` - function with arguments
- [x] `tick` - with no pending I/O returns 0
- [x] `getRuntime` - inside runtime context returns self
- [x] `getRuntime` - outside runtime returns null
- [x] `getBlockingPool` - returns pool
- [x] `getBackend` - returns backend
- [x] `getScheduler` - returns scheduler
- [x] `getIoDriver` - returns driver
- [x] `sleep` function works
- [x] Config defaults are correct
- [x] shutdown flag tracking
- [x] Multiple sequential `run` calls
- [x] Multi-runtime (separate instances)
- [x] Blocking pool is accessible
- [x] getRuntime thread-local restored after run
- [x] Nested getRuntime calls
- [x] Duration conversions

### 1.3 I/O Driver Tests (`src/io_driver.zig`)
> Current: 12 tests | Target: 12 tests

- [x] IoDriver init with various completion buffer sizes
- [x] IoDriver poll with no pending operations
- [x] IoDriver waitFor with timeout returns empty
- [x] IoDriver submitTimeout and wait
- [x] IoDriver multiple timeout submissions
- [x] IoDriver backend pointer is stored correctly
- [x] IoDriver TCP loopback send/recv
- [x] IoDriver TCP loopback accept/connect
- [x] IoDriver cancel pending operation
- [x] IoDriver user_data preserved in completions
- [x] IoDriver init with max completions of 1
- [x] (Plus 1 existing test from before)

---

## Phase 2: Platform Drivers (HIGH PRIORITY)

Platform-specific code is where subtle bugs hide. Each driver needs edge case coverage.

### 2.1 io_uring Tests (`src/backend/io_uring.zig`) - Linux
> Current: 20 tests | Target: 20 tests

- [x] IoUringBackend isSupported
- [x] IoUringBackend getKernelVersion
- [x] IoUringBackend init and deinit
- [x] IoUringBackend nop operation
- [x] IoUringBackend batching
- [x] IoUringBackend timeout operation
- [x] IoUringBackend multiple timeout submissions
- [x] IoUringBackend wait with zero timeout
- [x] IoUringBackend TCP socket accept
- [x] IoUringBackend TCP socket send/recv
- [x] IoUringBackend cancel operation
- [x] IoUringBackend close operation
- [x] IoUringBackend user_data preserved
- [x] IoUringBackend read and write on pipe
- [x] IoUringBackend high operation count
- [x] IoUringBackend rapid submit cycles
- [x] IoUringBackend inFlightCount tracking
- [x] IoUringBackend multiple nops complete in order
- [x] IoUringBackend fd returns valid ring fd
- [x] IoUringBackend write operation on pipe

### 2.2 kqueue Tests (`src/backend/kqueue.zig`) - macOS/BSD
> Current: 15 tests | Target: 15 tests

- [x] KqueueBackend init and deinit
- [x] KqueueBackend slab-based registration
- [x] KqueueBackend timer expiration
- [x] KqueueBackend timer cancellation
- [x] KqueueBackend multiple timeout submissions
- [x] KqueueBackend wait with zero timeout returns immediately
- [x] KqueueBackend TCP socket accept readiness
- [x] KqueueBackend TCP socket send/recv readiness
- [x] KqueueBackend cancel non-existent operation is safe
- [x] KqueueBackend rapid submit and cancel
- [x] KqueueBackend nop operation completes immediately
- [x] KqueueBackend close operation
- [x] KqueueBackend user_data preserved correctly
- [x] KqueueBackend change list auto-flush on threshold
- [x] KqueueBackend read and write operations

### 2.3 epoll Tests (`src/backend/epoll.zig`) - Linux fallback
> Current: 15 tests | Target: 15 tests

- [x] EpollBackend init and deinit
- [x] EpollBackend slab-based registration
- [x] EpollBackend timer expiration
- [x] EpollBackend timer cancellation cleans up timerfd
- [x] EpollBackend multiple timeout submissions
- [x] EpollBackend wait with zero timeout returns immediately
- [x] EpollBackend TCP socket accept readiness
- [x] EpollBackend TCP socket send/recv readiness
- [x] EpollBackend cancel non-existent operation is safe
- [x] EpollBackend rapid submit and cancel
- [x] EpollBackend nop operation completes immediately
- [x] EpollBackend close operation
- [x] EpollBackend user_data preserved correctly
- [x] EpollBackend read and write on pipe
- [x] EpollBackend EPOLLET edge-triggered behavior

### 2.4 IOCP Tests (`src/backend/iocp.zig`) - Windows
> Current: 19 tests | Target: 15 tests
> Note: Windows-specific tests skip on macOS/Linux, run via Windows CI

**Platform-independent tests (run everywhere):**
- [x] Unsupported on non-Windows check
- [x] TrackedOp initialization
- [x] TrackedOp with offset (OVERLAPPED setup)
- [x] Error mapping (Win32Error to Zig error)
- [x] NTSTATUS mapping
- [x] Timer struct
- [x] Timer deadline saturating add
- [x] calculateTimeout with no timers
- [x] calculateTimeout max value handling
- [x] Overlapped lifecycle tracking (state machine)
- [x] getHandleFromOp (handle extraction)

**Windows-only tests (skip on macOS/Linux):**
- [x] CreateIoCompletionPort and init
- [x] Init with custom config
- [x] NOP operation via PostQueuedCompletionStatus
- [x] Timeout registration and completion
- [x] Cancel timeout
- [x] Multiple timeouts ordering
- [x] Flush is no-op
- [x] fd returns null on Windows

---

## Phase 3: Synchronization Stress Tests

The sync primitives have basic tests but need high-contention scenarios.

### 3.1 Mutex Stress (`tests/stress/mutex_stress_test.zig`)
> Current: 12 tests | Target: 12 tests

- [x] 100 threads contending on single mutex
- [x] Lock/unlock rapid cycles (10000 iterations)
- [x] Mutex with long critical section
- [x] Mutex fairness - no starvation
- [x] tryLock under contention

### 3.2 Channel Stress (`src/sync/channel.zig`)
> Current: 12 tests | Target: 12 tests

- [x] Channel trySend and tryRecv
- [x] Channel blocking send and recv
- [x] Channel close wakes waiters
- [x] Channel closed channel rejects sends
- [x] Channel FIFO ordering
- [x] Channel backpressure when full
- [x] Channel empty channel behavior
- [x] Channel capacity boundaries
- [x] Channel large capacity (1000 items)
- [x] Channel interleaved send and recv
- [x] Channel close behavior (drain pending)
- [x] Channel rapid fill and drain cycles

### 3.3 Semaphore Stress (`src/sync/semaphore.zig`)
> Current: 10 tests | Target: 10 tests

- [x] Semaphore tryAcquire success
- [x] Semaphore tryAcquire failure
- [x] Semaphore acquire and release
- [x] Semaphore FIFO ordering
- [x] Semaphore cancel returns permits
- [x] Semaphore permit RAII
- [x] Semaphore binary (mutex equivalent)
- [x] Semaphore large permit count
- [x] Semaphore multiple acquire release cycles
- [x] Semaphore release increases permits

### 3.4 Barrier Stress (`src/sync/barrier.zig`)
> Current: 8 tests | Target: 8 tests

- [x] Barrier single task (leader, immediate return)
- [x] Barrier multiple tasks sync (wake all waiters)
- [x] Barrier reusable (multiple generations)
- [x] Barrier only one leader
- [x] Barrier large task count (100 tasks)
- [x] Barrier multiple generations leader consistency
- [x] Barrier arrived count tracking
- [x] Barrier waiter reset and reuse

### 3.5 RwLock Stress (`src/sync/rwlock.zig`)
> Current: 12 tests | Target: 12 tests

- [x] RwLock multiple readers
- [x] RwLock exclusive writer
- [x] RwLock writer priority
- [x] RwLock wake all readers after writer
- [x] RwLock read guard RAII
- [x] RwLock write guard RAII
- [x] RwLock many concurrent readers (100)
- [x] RwLock reader/writer contention
- [x] RwLock tryReadLock/tryWriteLock under contention
- [x] RwLock cancel read lock
- [x] RwLock cancel write lock
- [x] RwLock writer FIFO ordering

### 3.6 Notify Stress (`src/sync/notify.zig`)
> Current: 10 tests | Target: 10 tests

- [x] Notify before wait consumes permit
- [x] Notify wait then notify
- [x] NotifyAll wakes all waiters
- [x] Cancel removes waiter
- [x] NotifyAll with no waiters is no-op
- [x] NotifyOne wakes exactly one waiter
- [x] Permit does not accumulate
- [x] Rapid notify/wait cycles
- [x] Many waiters (100) notify one at a time
- [x] Waiter reset and reuse

---

## Phase 4: I/O Operations

### 4.1 File Tests (`src/fs/file.zig`)
> Current: 20 tests | Target: 15 tests

- [x] File create and write
- [x] File seek
- [x] File metadata
- [x] File reader/writer interface
- [x] File vectored I/O (scatter/gather)
- [x] File setLen truncate
- [x] File not found error
- [x] File read past EOF returns 0
- [x] File pread and pwrite (positioned I/O)
- [x] File readToEnd
- [x] File position tracking
- [x] File getLen
- [x] File setLen extend (with zeros)
- [x] File fromRawFd
- [x] File createNew fails if exists
- [x] File syncData
- [x] File readAll error on short file
- [x] File empty file operations
- [x] File large write and read (1MB)
- [x] AsyncFile basic operations (placeholder)

### 4.2 Unix Socket Tests (`src/net/unix/`)
> Current: 19 tests | Target: 12 tests

**stream.zig:**
- [x] UnixAddr from path
- [x] UnixAddr path too long error
- [x] UnixStream create socket
- [x] UnixAddr abstract namespace (Linux)
- [x] UnixAddr abstract not supported on non-Linux
- [x] UnixStream shutdown modes
- [x] UnixStream writeAll
- [x] UnixStream tryRead/tryWrite

**listener.zig:**
- [x] UnixListener bind and close
- [x] UnixListener tryAccept returns null
- [x] UnixListener accept connection

**datagram.zig:**
- [x] UnixDatagram unbound
- [x] UnixDatagram bind
- [x] UnixDatagram pair (socketpair)
- [x] UnixDatagram tryRecv returns null when empty
- [x] UnixDatagram sendTo/recvFrom
- [x] UnixDatagram connected mode
- [x] UnixDatagram peek
- [x] UnixDatagram trySend

### 4.3 Blocking Pool Tests (`src/blocking.zig`)
> Current: 10 tests | Target: 10 tests

- [x] BlockingPool init and deinit
- [x] BlockingPool submit task
- [x] BlockingPool multiple tasks
- [x] BlockingPool pool metrics (threadCount, pendingTasks)
- [x] BlockingPool tasks complete before shutdown
- [x] BlockingPool submit after shutdown fails
- [x] BlockingHandle wait and isComplete
- [x] BlockingHandle error completion
- [x] BlockingPool dynamic thread scaling

---

## Phase 5: Integration & End-to-End

### 5.1 TCP Server Integration
> Location: `tests/integration/tcp_integration_test.zig` | Current: 9 tests | Target: 9 tests

- [x] Echo server - single client
- [x] Echo server - 50 concurrent clients (stress test)
- [x] Echo server - client disconnect handling
- [x] Echo server - server shutdown with clients
- [x] Large data transfer (1MB)
- [x] HTTP-like request/response
- [x] Long-lived connections (multiple messages)
- [x] Half-close (shutdown write, continue read)
- [x] Rapid connect/disconnect stress

### 5.2 Real-World Patterns
> Location: `tests/integration/patterns_test.zig` | Current: 9 tests | Target: 7 tests

- [x] Fan-out/fan-in (scatter-gather pattern)
- [x] Producer/consumer with Channel
- [x] Worker pool pattern
- [x] Rate limiter with Semaphore
- [x] Circuit breaker pattern
- [x] Retry with exponential backoff (success case)
- [x] Retry exhausted (all retries fail)
- [x] Request timeout success (fast operation)
- [x] Request timeout exceeded (slow operation)

---

## Progress Tracking

### Summary

| Phase | Area | Current | Target | Status |
|-------|------|---------|--------|--------|
| 1.1 | Scheduler | 15 | 15 | 🟢 Done |
| 1.2 | Runtime | 20 | 20 | 🟢 Done |
| 1.3 | I/O Driver | 12 | 12 | 🟢 Done |
| 2.1 | io_uring | 20 | 20 | 🟢 Done |
| 2.2 | kqueue | 15 | 15 | 🟢 Done |
| 2.3 | epoll | 15 | 15 | 🟢 Done |
| 2.4 | IOCP | 19 | 15 | 🟢 Done |
| 3.1 | Mutex Stress | 12 | 12 | 🟢 Done |
| 3.2 | Channel Stress | 12 | 12 | 🟢 Done |
| 3.3 | Semaphore Stress | 10 | 10 | 🟢 Done |
| 3.4 | Barrier Stress | 8 | 8 | 🟢 Done |
| 3.5 | RwLock Stress | 12 | 12 | 🟢 Done |
| 3.6 | Notify Stress | 10 | 10 | 🟢 Done |
| 4.1 | File | 20 | 15 | 🟢 Done |
| 4.2 | Unix Sockets | 19 | 12 | 🟢 Done |
| 4.3 | Blocking Pool | 10 | 10 | 🟢 Done |
| 5.1 | TCP Integration | 9 | 9 | 🟢 Done |
| 5.2 | Real-World | 9 | 7 | 🟢 Done |

### Completed Tests Log

```
Date       | Phase | Tests Added | Notes
-----------|-------|-------------|-------
2026-02-02 | 1.1   | +13         | Scheduler: init, spawn, metrics, config, shutdown
2026-02-02 | 1.2   | +12         | Runtime: init, run, tick, getters, config
2026-02-02 | 3.1   | +5          | Mutex stress: contention, rapid cycles, fairness
2026-02-02 | 1.3   | +11         | IoDriver: init, poll, timeout, TCP loopback, cancel
2026-02-02 | 1.2   | +6          | Runtime: multi-run, multi-instance, Duration, nested
2026-02-02 | 2.2   | +11         | kqueue: TCP accept/send/recv, timers, cancel, pipe I/O
2026-02-02 | 2.3   | +11         | epoll: TCP sockets, timers, cancel, pipe I/O, edge-triggered
2026-02-02 | 2.1   | +15         | io_uring: TCP sockets, timers, nops, batching, pipe I/O
2026-02-02 | 3.2   | +7          | Channel: backpressure, capacity, FIFO, close, fill/drain
2026-02-02 | 3.3   | +4          | Semaphore: binary, large permits, cycles, release
2026-02-02 | 3.4   | +4          | Barrier: large count, generations, arrived tracking, reset
2026-02-02 | 3.5   | +6          | RwLock: many readers, contention, try locks, cancel, FIFO
2026-02-02 | 3.6   | +5          | Notify: exactly one, no accumulate, cycles, 100 waiters, reset
2026-02-02 | 4.1   | +14         | File: not found, EOF, pread/pwrite, readToEnd, position, extend, etc.
2026-02-02 | 4.2   | +9          | Unix: abstract, shutdown, writeAll, tryRead/tryWrite, sendTo, peek
2026-02-03 | 4.3   | +7          | BlockingPool: multiple tasks, metrics, shutdown, handle, scaling
2026-02-03 | 5.1   | +9          | TCP integration: echo server, concurrent clients, disconnect, HTTP-like, large data
2026-02-03 | 5.2   | +9          | Patterns: fan-out/in, producer/consumer, worker pool, rate limiter, circuit breaker, retry, timeout
2026-02-03 | 2.4   | +10         | IOCP: CreateIoCompletionPort, NOP, timeouts, cancel, lifecycle, config
```

---

## Running Tests

```bash
# Unit tests (inline in source)
zig build test

# By category
zig build test-integration
zig build test-stress
zig build test-robustness
zig build test-fuzz
zig build test-interop

# All tests
zig build test-all
```

---

## Notes

- Phase 1 is **blocking** - don't ship without it
- Phase 2 is **platform-critical** - bugs here are subtle and dangerous
- Phase 3 can be done incrementally
- Phase 4 & 5 are for production hardening
