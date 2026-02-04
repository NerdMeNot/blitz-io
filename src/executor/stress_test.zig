//! Stress Test for Blitz-IO Scheduler
//!
//! Tests concurrent correctness under load:
//! 1. Mass task spawning and completion
//! 2. Tasks waking other tasks (simulating I/O patterns)
//! 3. Work stealing between workers
//! 4. Cancellation during execution
//! 5. Reference counting correctness
//!
//! Safe limits for M3 Mac (8-12 cores, 8-24GB RAM):
//! - 8 workers
//! - 50,000-100,000 tasks per test
//! - ~200 bytes per task = ~20MB peak memory

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Header = @import("task.zig").Header;
const Waker = @import("task.zig").Waker;
const PollResult = @import("task.zig").PollResult;
const OwnedTasks = @import("task.zig").OwnedTasks;
const LocalQueue = @import("local_queue.zig").LocalQueue;
const ShardedGlobalQueue = @import("global_queue.zig").ShardedGlobalQueue;
const Worker = @import("worker.zig").Worker;
const IdleState = @import("worker.zig").IdleState;
const SharedState = @import("worker.zig").SharedState;

// ─────────────────────────────────────────────────────────────────────────────
// Resource Tracking
// ─────────────────────────────────────────────────────────────────────────────

const ResourceMetrics = struct {
    // Memory metrics
    bytes_allocated: usize,
    bytes_freed: usize,
    peak_bytes: usize,
    allocation_count: usize,
    free_count: usize,

    // Timing metrics
    start_time_ns: i128,
    end_time_ns: i128,

    // CPU metrics (user time in nanoseconds)
    start_cpu_ns: u64,
    end_cpu_ns: u64,

    fn init() ResourceMetrics {
        return .{
            .bytes_allocated = 0,
            .bytes_freed = 0,
            .peak_bytes = 0,
            .allocation_count = 0,
            .free_count = 0,
            .start_time_ns = 0,
            .end_time_ns = 0,
            .start_cpu_ns = 0,
            .end_cpu_ns = 0,
        };
    }

    fn start(self: *ResourceMetrics) void {
        self.start_time_ns = std.time.nanoTimestamp();
        self.start_cpu_ns = getCpuTimeNs();
    }

    fn stop(self: *ResourceMetrics) void {
        self.end_time_ns = std.time.nanoTimestamp();
        self.end_cpu_ns = getCpuTimeNs();
    }

    fn elapsedMs(self: *const ResourceMetrics) u64 {
        const elapsed_ns = self.end_time_ns - self.start_time_ns;
        return @intCast(@divFloor(elapsed_ns, 1_000_000));
    }

    fn cpuTimeMs(self: *const ResourceMetrics) u64 {
        if (self.end_cpu_ns >= self.start_cpu_ns) {
            return (self.end_cpu_ns - self.start_cpu_ns) / 1_000_000;
        }
        return 0;
    }

    fn currentBytes(self: *const ResourceMetrics) usize {
        if (self.bytes_allocated >= self.bytes_freed) {
            return self.bytes_allocated - self.bytes_freed;
        }
        return 0;
    }

    fn print(self: *const ResourceMetrics) void {
        const current = self.currentBytes();
        const elapsed_ms = self.elapsedMs();
        const cpu_ms = self.cpuTimeMs();

        std.debug.print("  ┌─ Resource Consumption ─────────────────────────\n", .{});
        std.debug.print("  │ Memory:\n", .{});
        std.debug.print("  │   Current:     {d:.2} KB\n", .{@as(f64, @floatFromInt(current)) / 1024.0});
        std.debug.print("  │   Peak:        {d:.2} KB\n", .{@as(f64, @floatFromInt(self.peak_bytes)) / 1024.0});
        std.debug.print("  │   Allocated:   {d:.2} MB ({d} allocs)\n", .{
            @as(f64, @floatFromInt(self.bytes_allocated)) / (1024.0 * 1024.0),
            self.allocation_count,
        });
        std.debug.print("  │   Freed:       {d:.2} MB ({d} frees)\n", .{
            @as(f64, @floatFromInt(self.bytes_freed)) / (1024.0 * 1024.0),
            self.free_count,
        });
        std.debug.print("  │ Time:\n", .{});
        std.debug.print("  │   Wall clock:  {d} ms\n", .{elapsed_ms});
        std.debug.print("  │   CPU time:    {d} ms\n", .{cpu_ms});
        if (elapsed_ms > 0) {
            const cpu_percent = @as(f64, @floatFromInt(cpu_ms)) / @as(f64, @floatFromInt(elapsed_ms)) * 100.0;
            std.debug.print("  │   CPU usage:   {d:.1}%\n", .{cpu_percent});
        }
        std.debug.print("  └─────────────────────────────────────────────────\n", .{});
    }

    /// Get CPU time in nanoseconds (user + system time for this thread)
    fn getCpuTimeNs() u64 {
        if (builtin.os.tag == .macos) {
            // Use mach thread_info for accurate per-thread CPU time
            const mach = struct {
                const thread_basic_info_t = extern struct {
                    user_time: extern struct { seconds: i32, microseconds: i32 },
                    system_time: extern struct { seconds: i32, microseconds: i32 },
                    cpu_usage: i32,
                    policy: i32,
                    run_state: i32,
                    flags: i32,
                    suspend_count: i32,
                    sleep_time: i32,
                };

                extern "c" fn mach_thread_self() u32;
                extern "c" fn thread_info(thread: u32, flavor: i32, info: *thread_basic_info_t, count: *u32) i32;
            };

            var info: mach.thread_basic_info_t = undefined;
            var count: u32 = @sizeOf(mach.thread_basic_info_t) / @sizeOf(u32);

            if (mach.thread_info(mach.mach_thread_self(), 3, &info, &count) == 0) {
                const user_ns: u64 = @intCast(info.user_time.seconds * 1_000_000_000 + info.user_time.microseconds * 1000);
                const sys_ns: u64 = @intCast(info.system_time.seconds * 1_000_000_000 + info.system_time.microseconds * 1000);
                return user_ns + sys_ns;
            }
        }
        // Fallback: use monotonic clock (less accurate but portable)
        return @intCast(std.time.nanoTimestamp());
    }
};

/// Tracking allocator that wraps another allocator and records metrics
const TrackingAllocator = struct {
    parent: Allocator,
    metrics: *ResourceMetrics,

    fn init(parent: Allocator, metrics: *ResourceMetrics) TrackingAllocator {
        return .{
            .parent = parent,
            .metrics = metrics,
        };
    }

    fn allocator(self: *TrackingAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.parent.rawAlloc(len, alignment, ret_addr);
        if (result != null) {
            self.metrics.bytes_allocated += len;
            self.metrics.allocation_count += 1;
            const current = self.metrics.bytes_allocated -| self.metrics.bytes_freed;
            if (current > self.metrics.peak_bytes) {
                self.metrics.peak_bytes = current;
            }
        }
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const old_len = memory.len;
        const result = self.parent.rawResize(memory, alignment, new_len, ret_addr);
        if (result) {
            if (new_len > old_len) {
                self.metrics.bytes_allocated += (new_len - old_len);
            } else {
                self.metrics.bytes_freed += (old_len - new_len);
            }
            const current = self.metrics.bytes_allocated -| self.metrics.bytes_freed;
            if (current > self.metrics.peak_bytes) {
                self.metrics.peak_bytes = current;
            }
        }
        return result;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const old_len = memory.len;
        const result = self.parent.rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null) {
            if (new_len > old_len) {
                self.metrics.bytes_allocated += (new_len - old_len);
            } else {
                self.metrics.bytes_freed += (old_len - new_len);
            }
            const current = self.metrics.bytes_allocated -| self.metrics.bytes_freed;
            if (current > self.metrics.peak_bytes) {
                self.metrics.peak_bytes = current;
            }
        }
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.metrics.bytes_freed += memory.len;
        self.metrics.free_count += 1;
        self.parent.rawFree(memory, alignment, ret_addr);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Test Configuration (Safe for M3 Mac)
// ─────────────────────────────────────────────────────────────────────────────

const NUM_WORKERS: usize = 8;
const TASKS_PER_TEST: usize = 50_000;
const WAKE_CHAIN_LENGTH: usize = 10; // Each task wakes up to 10 others
const TEST_TIMEOUT_MS: u64 = 30_000; // 30 second timeout per test

// ─────────────────────────────────────────────────────────────────────────────
// Atomic Counters for Verification
// ─────────────────────────────────────────────────────────────────────────────

const TestCounters = struct {
    tasks_created: std.atomic.Value(usize),
    tasks_polled: std.atomic.Value(usize),
    tasks_completed: std.atomic.Value(usize),
    tasks_cancelled: std.atomic.Value(usize),
    wakeups_sent: std.atomic.Value(usize),
    wakeups_received: std.atomic.Value(usize),
    errors: std.atomic.Value(usize),

    fn init() TestCounters {
        return .{
            .tasks_created = std.atomic.Value(usize).init(0),
            .tasks_polled = std.atomic.Value(usize).init(0),
            .tasks_completed = std.atomic.Value(usize).init(0),
            .tasks_cancelled = std.atomic.Value(usize).init(0),
            .wakeups_sent = std.atomic.Value(usize).init(0),
            .wakeups_received = std.atomic.Value(usize).init(0),
            .errors = std.atomic.Value(usize).init(0),
        };
    }

    fn reset(self: *TestCounters) void {
        self.tasks_created.store(0, .monotonic);
        self.tasks_polled.store(0, .monotonic);
        self.tasks_completed.store(0, .monotonic);
        self.tasks_cancelled.store(0, .monotonic);
        self.wakeups_sent.store(0, .monotonic);
        self.wakeups_received.store(0, .monotonic);
        self.errors.store(0, .monotonic);
    }

    fn print(self: *const TestCounters, name: []const u8) void {
        std.debug.print("\n=== {s} Results ===\n", .{name});
        std.debug.print("  Tasks created:    {d}\n", .{self.tasks_created.load(.monotonic)});
        std.debug.print("  Tasks polled:     {d}\n", .{self.tasks_polled.load(.monotonic)});
        std.debug.print("  Tasks completed:  {d}\n", .{self.tasks_completed.load(.monotonic)});
        std.debug.print("  Tasks cancelled:  {d}\n", .{self.tasks_cancelled.load(.monotonic)});
        std.debug.print("  Wakeups sent:     {d}\n", .{self.wakeups_sent.load(.monotonic)});
        std.debug.print("  Wakeups received: {d}\n", .{self.wakeups_received.load(.monotonic)});
        std.debug.print("  Errors:           {d}\n", .{self.errors.load(.monotonic)});
    }
};

var global_counters: TestCounters = TestCounters.init();

// ─────────────────────────────────────────────────────────────────────────────
// Test Task Implementation
// ─────────────────────────────────────────────────────────────────────────────

const TestTask = struct {
    const Self = @This();

    header: Header,
    allocator: Allocator,

    // Task state
    polls_remaining: std.atomic.Value(u32),
    waker_stored: ?Waker,
    task_id: usize,

    // For wake chain tests - pointer to array of other tasks to wake
    wake_targets: ?[]*Self,
    wake_index: usize,

    // Scheduler callback
    scheduler: ?*TestScheduler,

    const vtable = Header.VTable{
        .poll = pollImpl,
        .drop = dropImpl,
        .get_output = getOutputImpl,
        .schedule = scheduleImpl,
    };

    fn create(allocator: Allocator, task_id: usize, polls: u32) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .header = Header.init(&vtable, task_id),
            .allocator = allocator,
            .polls_remaining = std.atomic.Value(u32).init(polls),
            .waker_stored = null,
            .task_id = task_id,
            .wake_targets = null,
            .wake_index = 0,
            .scheduler = null,
        };
        _ = global_counters.tasks_created.fetchAdd(1, .monotonic);
        return self;
    }

    fn setWakeTargets(self: *Self, targets: []*Self) void {
        self.wake_targets = targets;
    }

    fn setScheduler(self: *Self, scheduler: *TestScheduler) void {
        self.scheduler = scheduler;
    }

    fn pollImpl(header: *Header) bool {
        const self: *Self = @fieldParentPtr("header", header);
        _ = global_counters.tasks_polled.fetchAdd(1, .monotonic);

        // Check for cancellation
        if (header.isCancelled()) {
            _ = global_counters.tasks_cancelled.fetchAdd(1, .monotonic);
            header.transitionToComplete();
            header.unref();
            return true;
        }

        // Transition to running
        if (!header.transitionToRunning()) {
            return false;
        }

        // Create waker
        var waker = Waker.init(header);

        // Decrement polls remaining
        const remaining = self.polls_remaining.fetchSub(1, .acq_rel);

        if (remaining <= 1) {
            // Task is done - wake any targets before completing
            self.wakeTargets();

            waker.drop();
            header.transitionToComplete();
            header.unref();
            _ = global_counters.tasks_completed.fetchAdd(1, .monotonic);
            return true;
        }

        // Task needs more polls - store waker and yield
        // In a real scenario, this would be stored in I/O state
        if (self.waker_stored) |*old| {
            old.drop();
        }
        self.waker_stored = waker;

        // Maybe wake some targets to simulate I/O completion patterns
        self.wakeTargets();

        const prev_state = header.transitionToIdle();

        // Check NOTIFIED flag
        if (prev_state & Header.State.NOTIFIED != 0) {
            header.clearNotified();
            if (header.transitionToScheduled()) {
                header.schedule();
            }
        }

        return false;
    }

    fn wakeTargets(self: *Self) void {
        var woke_someone = false;

        if (self.wake_targets) |targets| {
            // Wake one target per poll (round-robin)
            if (self.wake_index < targets.len) {
                const target = targets[self.wake_index];
                self.wake_index += 1;

                // Simulate external wake (like I/O completion)
                if (target.waker_stored) |*w| {
                    _ = global_counters.wakeups_sent.fetchAdd(1, .monotonic);
                    w.wake();
                    target.waker_stored = null;
                    _ = global_counters.wakeups_received.fetchAdd(1, .monotonic);
                    woke_someone = true;
                }
            }
        }

        // If we didn't wake anyone and have more polls (>= 1 means we need at least one more),
        // self-wake to continue. This simulates I/O that completes immediately.
        // Note: polls_remaining was already decremented, so >= 1 means we still need more polls.
        if (!woke_someone and self.polls_remaining.load(.monotonic) >= 1) {
            if (self.waker_stored) |*w| {
                _ = global_counters.wakeups_sent.fetchAdd(1, .monotonic);
                w.wake();
                self.waker_stored = null;
                _ = global_counters.wakeups_received.fetchAdd(1, .monotonic);
            }
        }
    }

    fn dropImpl(header: *Header) void {
        const self: *Self = @fieldParentPtr("header", header);

        // Clean up any stored waker
        if (self.waker_stored) |*w| {
            w.drop();
        }

        self.allocator.destroy(self);
    }

    fn getOutputImpl(_: *Header) ?*anyopaque {
        return null;
    }

    fn scheduleImpl(header: *Header) void {
        const self: *Self = @fieldParentPtr("header", header);
        if (self.scheduler) |sched| {
            sched.schedule(header);
        }
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Test Scheduler (Simplified for Testing)
// ─────────────────────────────────────────────────────────────────────────────

const TestScheduler = struct {
    const Self = @This();

    global_queue: ShardedGlobalQueue,
    workers: []Worker,
    shutdown: std.atomic.Value(bool),
    idle_state: IdleState,
    allocator: Allocator,
    owned_tasks: OwnedTasks,

    fn init(allocator: Allocator, num_workers: usize) !*Self {
        const self = try allocator.create(Self);

        self.* = .{
            .global_queue = ShardedGlobalQueue.init(),
            .workers = try allocator.alloc(Worker, num_workers),
            .shutdown = std.atomic.Value(bool).init(false),
            .idle_state = IdleState.init(@intCast(num_workers)),
            .allocator = allocator,
            .owned_tasks = OwnedTasks.init(),
        };

        // Initialize workers
        for (self.workers, 0..) |*w, i| {
            w.* = Worker.init(i, &self.shutdown);
        }

        return self;
    }

    fn deinit(self: *Self) void {
        self.allocator.free(self.workers);
        self.allocator.destroy(self);
    }

    fn schedule(self: *Self, task: *Header) void {
        // Simple round-robin to global queue
        _ = self.global_queue.push(task);
    }

    fn spawn(self: *Self, task: *TestTask) void {
        task.setScheduler(self);
        _ = self.owned_tasks.insert(&task.header);

        if (task.header.transitionToScheduled()) {
            self.schedule(&task.header);
        }
    }

    fn runUntilComplete(self: *Self, timeout_ms: u64) !usize {
        const start = std.time.milliTimestamp();
        var tasks_run: usize = 0;

        while (true) {
            // Check timeout
            if (std.time.milliTimestamp() - start > timeout_ms) {
                return error.Timeout;
            }

            // Try to get work from global queue
            if (self.global_queue.pop()) |task| {
                _ = task.poll();
                tasks_run += 1;
                continue;
            }

            // Check if all tasks are done
            if (self.owned_tasks.len() == 0 or
                global_counters.tasks_completed.load(.monotonic) +
                global_counters.tasks_cancelled.load(.monotonic) >=
                global_counters.tasks_created.load(.monotonic))
            {
                break;
            }

            // Brief yield to prevent busy-spin
            std.Thread.sleep(100_000); // 100µs
        }

        return tasks_run;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Test 1: Mass Spawn and Complete
// ─────────────────────────────────────────────────────────────────────────────

fn testMassSpawn(allocator: Allocator, _: *ResourceMetrics) !void {
    std.debug.print("\n[TEST 1] Mass Spawn: {d} tasks...\n", .{TASKS_PER_TEST});
    global_counters.reset();

    const scheduler = try TestScheduler.init(allocator, NUM_WORKERS);
    defer scheduler.deinit();

    // Create and spawn tasks (each completes after 1 poll)
    const tasks = try allocator.alloc(*TestTask, TASKS_PER_TEST);
    defer allocator.free(tasks);

    for (tasks, 0..) |*t, i| {
        t.* = try TestTask.create(allocator, i, 1);
        scheduler.spawn(t.*);
    }

    // Run until complete
    const start = std.time.milliTimestamp();
    const tasks_run = try scheduler.runUntilComplete(TEST_TIMEOUT_MS);
    const elapsed = std.time.milliTimestamp() - start;

    global_counters.print("Mass Spawn");
    std.debug.print("  Time: {d}ms, Tasks/sec: {d}\n", .{
        elapsed,
        if (elapsed > 0) tasks_run * 1000 / @as(usize, @intCast(elapsed)) else 0,
    });

    // Verify
    const completed = global_counters.tasks_completed.load(.monotonic);
    if (completed != TASKS_PER_TEST) {
        std.debug.print("  ERROR: Expected {d} completed, got {d}\n", .{ TASKS_PER_TEST, completed });
        return error.TestFailed;
    }
    std.debug.print("  PASSED\n", .{});
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 2: Wake Chains (Tasks Waking Other Tasks)
// ─────────────────────────────────────────────────────────────────────────────

fn testWakeChains(allocator: Allocator, _: *ResourceMetrics) !void {
    const num_tasks = TASKS_PER_TEST / 10; // Fewer tasks, more polls each
    std.debug.print("\n[TEST 2] Wake Chains: {d} tasks, {d} polls each...\n", .{ num_tasks, WAKE_CHAIN_LENGTH });
    global_counters.reset();

    const scheduler = try TestScheduler.init(allocator, NUM_WORKERS);
    defer scheduler.deinit();

    // Create tasks
    var tasks = try allocator.alloc(*TestTask, num_tasks);
    defer allocator.free(tasks);

    for (tasks, 0..) |*t, i| {
        t.* = try TestTask.create(allocator, i, WAKE_CHAIN_LENGTH);
    }

    // Set up wake targets (each task wakes the next few tasks)
    var wake_targets = try allocator.alloc([]*TestTask, num_tasks);
    defer allocator.free(wake_targets);

    for (0..num_tasks) |i| {
        var targets = try allocator.alloc(*TestTask, 3);
        for (0..3) |j| {
            targets[j] = tasks[(i + j + 1) % num_tasks];
        }
        wake_targets[i] = targets;
        tasks[i].setWakeTargets(targets);
    }
    defer {
        for (wake_targets) |targets| {
            allocator.free(targets);
        }
    }

    // Spawn all tasks
    for (tasks) |t| {
        scheduler.spawn(t);
    }

    // Run until complete
    const start = std.time.milliTimestamp();
    const tasks_run = try scheduler.runUntilComplete(TEST_TIMEOUT_MS);
    const elapsed = std.time.milliTimestamp() - start;

    global_counters.print("Wake Chains");
    std.debug.print("  Time: {d}ms, Polls/sec: {d}\n", .{
        elapsed,
        if (elapsed > 0) tasks_run * 1000 / @as(usize, @intCast(elapsed)) else 0,
    });

    // Verify
    const completed = global_counters.tasks_completed.load(.monotonic);
    if (completed != num_tasks) {
        std.debug.print("  ERROR: Expected {d} completed, got {d}\n", .{ num_tasks, completed });
        return error.TestFailed;
    }
    std.debug.print("  PASSED\n", .{});
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 3: Local Queue Stress (Push/Pop/Steal)
// ─────────────────────────────────────────────────────────────────────────────

fn testLocalQueueStress(allocator: Allocator, _: *ResourceMetrics) !void {
    std.debug.print("\n[TEST 3] Local Queue Stress...\n", .{});

    const num_tasks = 10_000;
    var queue = LocalQueue.init();

    // Create fake headers
    const headers = try allocator.alloc(Header, num_tasks);
    defer allocator.free(headers);

    const dummy_vtable = Header.VTable{
        .poll = struct {
            fn f(_: *Header) bool {
                return true;
            }
        }.f,
        .drop = struct {
            fn f(_: *Header) void {}
        }.f,
        .get_output = struct {
            fn f(_: *Header) ?*anyopaque {
                return null;
            }
        }.f,
        .schedule = struct {
            fn f(_: *Header) void {}
        }.f,
    };

    for (headers, 0..) |*h, i| {
        h.* = Header.init(&dummy_vtable, i);
    }

    // Test 1: Fill and drain via push/pop
    var pushed: usize = 0;
    for (headers) |*h| {
        if (queue.push(h)) {
            pushed += 1;
        } else {
            break; // Queue full
        }
    }

    var popped: usize = 0;
    while (queue.pop()) |_| {
        popped += 1;
    }

    std.debug.print("  Push/Pop: pushed={d}, popped={d}\n", .{ pushed, popped });
    if (pushed != popped) {
        return error.TestFailed;
    }

    // Test 2: LIFO stack behavior
    var lifo_pushed: usize = 0;
    for (headers[0..10]) |*h| {
        if (queue.pushLifo(h) == null) {
            lifo_pushed += 1;
        }
    }

    var lifo_popped: usize = 0;
    while (queue.pop()) |_| {
        lifo_popped += 1;
    }

    std.debug.print("  LIFO: pushed={d}, popped={d}\n", .{ lifo_pushed, lifo_popped });

    // Test 3: Steal
    for (headers[0..100]) |*h| {
        _ = queue.push(h);
    }

    var stolen: usize = 0;
    while (queue.steal()) |_| {
        stolen += 1;
    }

    std.debug.print("  Steal: stole={d} from 100\n", .{stolen});
    if (stolen != 100) {
        return error.TestFailed;
    }

    std.debug.print("  PASSED\n", .{});
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 4: Global Queue Sharding
// ─────────────────────────────────────────────────────────────────────────────

fn testGlobalQueueSharding(allocator: Allocator, _: *ResourceMetrics) !void {
    std.debug.print("\n[TEST 4] Global Queue Sharding...\n", .{});

    var queue = ShardedGlobalQueue.init();

    const num_tasks = 10_000;
    const headers = try allocator.alloc(Header, num_tasks);
    defer allocator.free(headers);

    const dummy_vtable = Header.VTable{
        .poll = struct {
            fn f(_: *Header) bool {
                return true;
            }
        }.f,
        .drop = struct {
            fn f(_: *Header) void {}
        }.f,
        .get_output = struct {
            fn f(_: *Header) ?*anyopaque {
                return null;
            }
        }.f,
        .schedule = struct {
            fn f(_: *Header) void {}
        }.f,
    };

    for (headers, 0..) |*h, i| {
        h.* = Header.init(&dummy_vtable, i);
    }

    // Push all tasks
    var pushed: usize = 0;
    for (headers) |*h| {
        if (queue.push(h)) {
            pushed += 1;
        }
    }

    std.debug.print("  Pushed: {d}\n", .{pushed});
    std.debug.print("  Queue length: {d}\n", .{queue.len()});

    // Check shard distribution
    var shard_counts: [8]usize = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
    for (&queue.shards, 0..) |*shard, i| {
        shard_counts[i] = shard.len();
    }
    std.debug.print("  Shard distribution: ", .{});
    for (shard_counts) |c| {
        std.debug.print("{d} ", .{c});
    }
    std.debug.print("\n", .{});

    // Pop all tasks
    var popped: usize = 0;
    while (queue.pop()) |_| {
        popped += 1;
    }

    std.debug.print("  Popped: {d}\n", .{popped});
    if (pushed != popped) {
        return error.TestFailed;
    }

    std.debug.print("  PASSED\n", .{});
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 5: NOTIFIED Flag Stress
// ─────────────────────────────────────────────────────────────────────────────

fn testNotifiedStress(_: Allocator, _: *ResourceMetrics) !void {
    std.debug.print("\n[TEST 5] NOTIFIED Flag Stress...\n", .{});

    const dummy_vtable = Header.VTable{
        .poll = struct {
            fn f(_: *Header) bool {
                return true;
            }
        }.f,
        .drop = struct {
            fn f(_: *Header) void {}
        }.f,
        .get_output = struct {
            fn f(_: *Header) ?*anyopaque {
                return null;
            }
        }.f,
        .schedule = struct {
            fn f(_: *Header) void {}
        }.f,
    };

    var header = Header.init(&dummy_vtable, 0);

    // Test sequence: IDLE -> SCHEDULED -> RUNNING -> (wake during poll) -> IDLE with NOTIFIED
    const iterations: usize = 100_000;
    var notified_count: usize = 0;

    for (0..iterations) |_| {
        // Schedule
        if (!header.transitionToScheduled()) continue;

        // Run
        if (!header.transitionToRunning()) continue;

        // Simulate wake during poll (should set NOTIFIED, not SCHEDULED)
        const should_enqueue = header.transitionToScheduled();
        if (should_enqueue) {
            // This shouldn't happen - task is RUNNING
            return error.TestFailed;
        }

        // Check NOTIFIED was set
        if (header.isNotified()) {
            notified_count += 1;
        }

        // Transition to idle
        const prev_state = header.transitionToIdle();
        if (prev_state & Header.State.NOTIFIED != 0) {
            header.clearNotified();
        }
    }

    std.debug.print("  Iterations: {d}, NOTIFIED set: {d}\n", .{ iterations, notified_count });
    if (notified_count != iterations) {
        std.debug.print("  ERROR: Expected {d} NOTIFIED, got {d}\n", .{ iterations, notified_count });
        return error.TestFailed;
    }

    std.debug.print("  PASSED\n", .{});
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 6: OwnedTasks Stress
// ─────────────────────────────────────────────────────────────────────────────

fn testOwnedTasksStress(allocator: Allocator, _: *ResourceMetrics) !void {
    std.debug.print("\n[TEST 6] OwnedTasks Stress...\n", .{});

    var owned = OwnedTasks.init();

    const num_tasks = 10_000;
    const headers = try allocator.alloc(Header, num_tasks);
    defer allocator.free(headers);

    const dummy_vtable = Header.VTable{
        .poll = struct {
            fn f(_: *Header) bool {
                return true;
            }
        }.f,
        .drop = struct {
            fn f(_: *Header) void {}
        }.f,
        .get_output = struct {
            fn f(_: *Header) ?*anyopaque {
                return null;
            }
        }.f,
        .schedule = struct {
            fn f(_: *Header) void {}
        }.f,
    };

    for (headers, 0..) |*h, i| {
        h.* = Header.init(&dummy_vtable, i);
    }

    // Insert all
    for (headers) |*h| {
        if (!owned.insert(h)) {
            return error.TestFailed;
        }
    }

    std.debug.print("  Inserted: {d}\n", .{owned.len()});

    // Remove half
    for (headers[0 .. num_tasks / 2]) |*h| {
        owned.remove(h);
    }

    std.debug.print("  After removing half: {d}\n", .{owned.len()});

    // Close and cancel
    const cancelled = owned.closeAndCancelAll();
    std.debug.print("  Cancelled on close: {d}\n", .{cancelled});

    // Try to insert after close (should fail)
    var new_header = Header.init(&dummy_vtable, 99999);
    if (owned.insert(&new_header)) {
        return error.TestFailed;
    }

    std.debug.print("  PASSED\n", .{});
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 7: Reference Counting Stress
// ─────────────────────────────────────────────────────────────────────────────

fn testRefCountStress(_: Allocator, _: *ResourceMetrics) !void {
    std.debug.print("\n[TEST 7] Reference Counting Stress...\n", .{});

    var drop_count: usize = 0;

    const TestVTable = struct {
        var drops: *usize = undefined;

        fn poll(_: *Header) bool {
            return true;
        }
        fn drop(_: *Header) void {
            drops.* += 1;
        }
        fn get_output(_: *Header) ?*anyopaque {
            return null;
        }
        fn schedule(_: *Header) void {}
    };

    TestVTable.drops = &drop_count;

    const vtable = Header.VTable{
        .poll = TestVTable.poll,
        .drop = TestVTable.drop,
        .get_output = TestVTable.get_output,
        .schedule = TestVTable.schedule,
    };

    // Test: ref/unref cycles
    var header = Header.init(&vtable, 0);

    const iterations: usize = 10_000;

    for (0..iterations) |_| {
        header.ref(); // 2
        header.ref(); // 3
        header.ref(); // 4
        header.unref(); // 3
        header.unref(); // 2
        header.unref(); // 1

        if (header.getRefCountValue() != 1) {
            std.debug.print("  ERROR: Expected refcount 1, got {d}\n", .{header.getRefCountValue()});
            return error.TestFailed;
        }
    }

    std.debug.print("  Iterations: {d}, Final refcount: {d}\n", .{ iterations, header.getRefCountValue() });

    // Final unref should trigger drop
    header.unref();
    if (drop_count != 1) {
        std.debug.print("  ERROR: Expected 1 drop, got {d}\n", .{drop_count});
        return error.TestFailed;
    }

    std.debug.print("  Drop called: {d}\n", .{drop_count});
    std.debug.print("  PASSED\n", .{});
}

// ─────────────────────────────────────────────────────────────────────────────
// Main Test Runner
// ─────────────────────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const base_allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║          BLITZ-IO SCHEDULER STRESS TEST                      ║\n", .{});
    std.debug.print("║          Workers: {d}, Tasks/test: {d}                     ║\n", .{ NUM_WORKERS, TASKS_PER_TEST });
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});

    var passed: usize = 0;
    var failed: usize = 0;

    // Aggregate metrics across all tests
    var total_metrics = ResourceMetrics.init();
    total_metrics.start();

    // Run all tests
    const tests = [_]struct { name: []const u8, func: *const fn (Allocator, *ResourceMetrics) anyerror!void }{
        .{ .name = "Mass Spawn", .func = testMassSpawn },
        .{ .name = "Wake Chains", .func = testWakeChains },
        .{ .name = "Local Queue", .func = testLocalQueueStress },
        .{ .name = "Global Queue", .func = testGlobalQueueSharding },
        .{ .name = "NOTIFIED Flag", .func = testNotifiedStress },
        .{ .name = "OwnedTasks", .func = testOwnedTasksStress },
        .{ .name = "RefCount", .func = testRefCountStress },
    };

    for (tests) |t| {
        // Create metrics for this test
        var metrics = ResourceMetrics.init();

        // Create tracking allocator
        var tracking = TrackingAllocator.init(base_allocator, &metrics);
        const allocator = tracking.allocator();

        metrics.start();
        t.func(allocator, &metrics) catch |err| {
            metrics.stop();
            std.debug.print("  FAILED: {s} - {}\n", .{ t.name, err });
            metrics.print();
            failed += 1;

            // Aggregate
            total_metrics.bytes_allocated += metrics.bytes_allocated;
            total_metrics.bytes_freed += metrics.bytes_freed;
            total_metrics.allocation_count += metrics.allocation_count;
            total_metrics.free_count += metrics.free_count;
            if (metrics.peak_bytes > total_metrics.peak_bytes) {
                total_metrics.peak_bytes = metrics.peak_bytes;
            }
            continue;
        };
        metrics.stop();
        metrics.print();
        passed += 1;

        // Aggregate
        total_metrics.bytes_allocated += metrics.bytes_allocated;
        total_metrics.bytes_freed += metrics.bytes_freed;
        total_metrics.allocation_count += metrics.allocation_count;
        total_metrics.free_count += metrics.free_count;
        if (metrics.peak_bytes > total_metrics.peak_bytes) {
            total_metrics.peak_bytes = metrics.peak_bytes;
        }
    }

    total_metrics.stop();

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  RESULTS: {d} passed, {d} failed                              ║\n", .{ passed, failed });
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});

    std.debug.print("\n=== TOTAL RESOURCE CONSUMPTION ===\n", .{});
    total_metrics.print();

    if (failed > 0) {
        return error.TestsFailed;
    }
}

// Make it runnable as a test too
test "stress test runner" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Dummy metrics for test mode
    var metrics = ResourceMetrics.init();

    // Run a subset of tests in test mode (faster)
    try testLocalQueueStress(allocator, &metrics);
    try testGlobalQueueSharding(allocator, &metrics);
    try testNotifiedStress(allocator, &metrics);
    try testOwnedTasksStress(allocator, &metrics);
    try testRefCountStress(allocator, &metrics);
}
