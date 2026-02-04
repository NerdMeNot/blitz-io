# Blitz-IO Production Implementation Plan

Based on analysis of Tokio's architecture, here's the comprehensive implementation plan.

## Phase 1: Async Task System (Core)

### 1.1 Task State Machine
- **File**: `src/runtime/task/state.zig`
- Atomic state with bitfields:
  - RUNNING (0b0001) - Task being polled
  - COMPLETE (0b0010) - Future completed
  - NOTIFIED (0b0100) - In run queue
  - CANCELLED (0b1000) - Should cancel
  - REF_COUNT - Upper bits for refcounting

### 1.2 Task Cell Structure
- **File**: `src/runtime/task/cell.zig`
- Header (cache-aligned 128 bytes)
- Core (future storage, scheduler ref)
- Trailer (cold data)

### 1.3 Task Harness
- **File**: `src/runtime/task/harness.zig`
- Poll wrapper with state transitions
- Proper cleanup on completion/cancel

### 1.4 JoinHandle
- **File**: `src/runtime/task/join.zig`
- Future that resolves to task output
- Abort capability

### 1.5 OwnedTasks
- **File**: `src/runtime/task/owned.zig`
- Sharded list for lock-free task tracking
- Intrusive linked list

## Phase 2: Timer Wheel

### 2.1 Hierarchical Wheel
- **File**: `src/runtime/time/wheel.zig`
- 6 levels with 64 slots each
- Level 0: 1ms, Level 5: ~12 days
- O(1) insert/remove

### 2.2 Timer Entry
- **File**: `src/runtime/time/entry.zig`
- Deadline, waker, state
- Intrusive list node

### 2.3 Wheel Operations
- Insert with level calculation
- Advance/cascade expired entries
- Process wakeups

## Phase 3: Lock-Free MPMC Channel

### 3.1 Block-Based List
- **File**: `src/sync/mpsc/list.zig`
- Fixed-size blocks (32 slots on 64-bit)
- Atomic head/tail pointers
- Block recycling

### 3.2 Channel Core
- **File**: `src/sync/mpsc/chan.zig`
- Cache-padded tx/rx
- Semaphore for bounded capacity
- AtomicWaker for notifications

### 3.3 Bounded/Unbounded
- **File**: `src/sync/mpsc/bounded.zig`
- Backpressure via semaphore
- Unbounded variant

## Phase 4: I/O Driver Integration

### 4.1 Driver Core
- **File**: `src/runtime/io/driver.zig`
- Poll loop with backend abstraction
- Event processing

### 4.2 ScheduledIo
- **File**: `src/runtime/io/scheduled_io.zig`
- Per-resource readiness state
- Waiter list for blocking

### 4.3 Registration
- **File**: `src/runtime/io/registration.zig`
- User-facing API
- poll_read_ready/poll_write_ready

### 4.4 Backend Integration
- Connect io_uring completions
- Connect kqueue/epoll events
- Waker integration

## Phase 5: Higher-Level APIs

### 5.1 UDP Socket
- **File**: `src/net/udp.zig`
- Async send/recv
- Multicast support

### 5.2 Async File I/O
- **File**: `src/fs/async_file.zig`
- io_uring-backed on Linux
- Thread pool fallback

### 5.3 Connection Pool
- **File**: `src/net/pool.zig`
- Generic pooling
- Health checks

## Phase 6: Testing & Benchmarks

### 6.1 Stress Tests
- Task spawn/cancel cycles
- Channel contention
- Timer accuracy

### 6.2 Integration Tests
- Full echo server
- HTTP-like workload
- Mixed I/O patterns

## Implementation Order

1. Task State Machine → Task Cell → Harness → JoinHandle
2. Timer Wheel → Entry → Operations
3. MPMC List → Channel Core → Bounded
4. I/O Driver → ScheduledIo → Registration → Backend
5. UDP → Async File → Pool
6. Tests throughout

## Key Design Decisions

1. **Cache Alignment**: 128-byte padding on hot structs
2. **Atomic Ordering**: Acquire/Release for most, SeqCst for state transitions
3. **Reference Counting**: Embedded in state word
4. **Intrusive Lists**: No allocations for queue operations
5. **Block Allocation**: Amortize allocation overhead
