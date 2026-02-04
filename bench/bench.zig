//! Blitz-IO Benchmark Suite
//!
//! Benchmarks for blitz-io's public sync primitives API.
//! These are the Future-based primitives designed for async tasks.
//!
//! Run with: zig build bench

const std = @import("std");
const blitz = @import("blitz-io");
const Runtime = blitz.Runtime;

// Public sync API (Future-based primitives)
const sync = blitz.sync;
const Mutex = sync.Mutex;
const RwLock = sync.RwLock;
const Semaphore = sync.Semaphore;
const Channel = sync.Channel;
const Oneshot = sync.Oneshot;
const Barrier = sync.Barrier;
const WaitGroup = sync.WaitGroup;
const Event = sync.Event;

const print = std.debug.print;
const Allocator = std.mem.Allocator;

// ============================================================================
// Configuration
// ============================================================================

const ITERATIONS = 10;
const WARMUP_ITERATIONS = 3;
const CHANNEL_SIZE = 1000;

// Benchmark sizes
const TASK_COUNTS = [_]usize{ 1_000, 10_000, 100_000 };

// ============================================================================
// Statistics helpers
// ============================================================================

pub const Stats = struct {
    min_ns: u64,
    max_ns: u64,
    total_ns: u64,
    count: usize,

    pub fn init() Stats {
        return .{
            .min_ns = std.math.maxInt(u64),
            .max_ns = 0,
            .total_ns = 0,
            .count = 0,
        };
    }

    pub fn add(self: *Stats, ns: u64) void {
        self.min_ns = @min(self.min_ns, ns);
        self.max_ns = @max(self.max_ns, ns);
        self.total_ns += ns;
        self.count += 1;
    }

    pub fn avgNs(self: Stats) u64 {
        return if (self.count > 0) self.total_ns / self.count else 0;
    }

    pub fn nsPerOp(self: Stats, ops: usize) f64 {
        return @as(f64, @floatFromInt(self.avgNs())) / @as(f64, @floatFromInt(ops));
    }

    pub fn opsPerSec(self: Stats, ops: usize) f64 {
        const avg_ns = self.avgNs();
        if (avg_ns == 0) return 0;
        return @as(f64, @floatFromInt(ops)) * 1_000_000_000.0 / @as(f64, @floatFromInt(avg_ns));
    }
};

// ============================================================================
// JSON Output for cross-language comparison
// ============================================================================

pub const JsonOutput = struct {
    // Mutex
    mutex_ns: f64 = 0,
    mutex_ops_per_sec: f64 = 0,

    // RwLock
    rwlock_read_ns: f64 = 0,
    rwlock_write_ns: f64 = 0,

    // Semaphore
    semaphore_ns: f64 = 0,

    // Channel
    channel_send_ns: f64 = 0,
    channel_recv_ns: f64 = 0,
    channel_roundtrip_ns: f64 = 0,

    // Oneshot
    oneshot_ns: f64 = 0,

    // WaitGroup
    waitgroup_ns: f64 = 0,

    // Event
    event_ns: f64 = 0,

    // Throughput
    message_throughput: f64 = 0,

    // Metadata
    benchmark_size: u64 = 0,
    iterations: u64 = ITERATIONS,
    warmup_iterations: u64 = WARMUP_ITERATIONS,
    num_workers: u64 = 0,

    pub fn print(self: JsonOutput) void {
        std.debug.print(
            \\{{
            \\  "mutex_ns": {d:.1},
            \\  "mutex_ops_per_sec": {d:.0},
            \\  "rwlock_read_ns": {d:.1},
            \\  "rwlock_write_ns": {d:.1},
            \\  "semaphore_ns": {d:.1},
            \\  "channel_send_ns": {d:.1},
            \\  "channel_recv_ns": {d:.1},
            \\  "channel_roundtrip_ns": {d:.1},
            \\  "oneshot_ns": {d:.1},
            \\  "waitgroup_ns": {d:.1},
            \\  "event_ns": {d:.1},
            \\  "message_throughput": {d:.0},
            \\  "benchmark_size": {d},
            \\  "iterations": {d},
            \\  "warmup_iterations": {d},
            \\  "num_workers": {d}
            \\}}
            \\
        , .{
            self.mutex_ns,
            self.mutex_ops_per_sec,
            self.rwlock_read_ns,
            self.rwlock_write_ns,
            self.semaphore_ns,
            self.channel_send_ns,
            self.channel_recv_ns,
            self.channel_roundtrip_ns,
            self.oneshot_ns,
            self.waitgroup_ns,
            self.event_ns,
            self.message_throughput,
            self.benchmark_size,
            self.iterations,
            self.warmup_iterations,
            self.num_workers,
        });
    }
};

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Check for JSON output mode (for compare.zig)
    var json_mode = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        }
    }

    if (json_mode) {
        try runJsonBenchmarks(allocator);
    } else {
        try runBenchmarks(allocator);
    }
}

pub fn runJsonBenchmarks(allocator: Allocator) !void {
    var output = JsonOutput{};
    const n: usize = 100_000;

    output.benchmark_size = n;
    output.num_workers = 4;

    // Mutex benchmark
    {
        var mutex = Mutex(u64).init(0);
        var stats = Stats.init();

        for (0..WARMUP_ITERATIONS + ITERATIONS) |iter| {
            const start = std.time.nanoTimestamp();
            for (0..n) |_| {
                if (mutex.tryLock()) |g| {
                    var guard = g;
                    guard.value().* += 1;
                    guard.release();
                }
            }
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
            if (iter >= WARMUP_ITERATIONS) {
                stats.add(elapsed);
            }
        }
        output.mutex_ns = stats.nsPerOp(n);
        output.mutex_ops_per_sec = stats.opsPerSec(n);
    }

    // RwLock read benchmark
    {
        var rwlock = RwLock(u64).init(42);
        var stats = Stats.init();

        for (0..WARMUP_ITERATIONS + ITERATIONS) |iter| {
            const start = std.time.nanoTimestamp();
            for (0..n) |_| {
                if (rwlock.tryRead()) |g| {
                    var guard = g;
                    std.mem.doNotOptimizeAway(guard.value().*);
                    guard.release();
                }
            }
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
            if (iter >= WARMUP_ITERATIONS) {
                stats.add(elapsed);
            }
        }
        output.rwlock_read_ns = stats.nsPerOp(n);
    }

    // RwLock write benchmark
    {
        var rwlock = RwLock(u64).init(0);
        var stats = Stats.init();

        for (0..WARMUP_ITERATIONS + ITERATIONS) |iter| {
            const start = std.time.nanoTimestamp();
            for (0..n) |_| {
                if (rwlock.tryWrite()) |g| {
                    var guard = g;
                    guard.value().* += 1;
                    guard.release();
                }
            }
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
            if (iter >= WARMUP_ITERATIONS) {
                stats.add(elapsed);
            }
        }
        output.rwlock_write_ns = stats.nsPerOp(n);
    }

    // Semaphore benchmark
    {
        var sem = Semaphore.init(100);
        var stats = Stats.init();

        for (0..WARMUP_ITERATIONS + ITERATIONS) |iter| {
            const start = std.time.nanoTimestamp();
            for (0..n) |_| {
                if (sem.tryAcquire()) |p| {
                    var permit = p;
                    permit.release();
                }
            }
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
            if (iter >= WARMUP_ITERATIONS) {
                stats.add(elapsed);
            }
        }
        output.semaphore_ns = stats.nsPerOp(n);
    }

    // Channel send benchmark
    {
        var chan = try Channel(u64).init(allocator, CHANNEL_SIZE);
        defer chan.deinit();

        var stats = Stats.init();
        for (0..WARMUP_ITERATIONS + ITERATIONS) |iter| {
            const start = std.time.nanoTimestamp();
            for (0..CHANNEL_SIZE) |i| {
                chan.trySend(i) catch {};
            }
            const send_elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);

            // Drain
            for (0..CHANNEL_SIZE) |_| {
                _ = chan.tryRecv() catch {};
            }

            if (iter >= WARMUP_ITERATIONS) {
                stats.add(send_elapsed);
            }
        }
        output.channel_send_ns = stats.nsPerOp(CHANNEL_SIZE);
    }

    // Channel recv benchmark
    {
        var chan = try Channel(u64).init(allocator, CHANNEL_SIZE);
        defer chan.deinit();

        var stats = Stats.init();
        for (0..WARMUP_ITERATIONS + ITERATIONS) |iter| {
            // Fill first
            for (0..CHANNEL_SIZE) |i| {
                chan.trySend(i) catch {};
            }

            const start = std.time.nanoTimestamp();
            for (0..CHANNEL_SIZE) |_| {
                _ = chan.tryRecv() catch {};
            }
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);

            if (iter >= WARMUP_ITERATIONS) {
                stats.add(elapsed);
            }
        }
        output.channel_recv_ns = stats.nsPerOp(CHANNEL_SIZE);
        output.message_throughput = stats.opsPerSec(CHANNEL_SIZE);
    }

    // Channel roundtrip benchmark
    {
        var chan = try Channel(u64).init(allocator, 1);
        defer chan.deinit();

        var stats = Stats.init();
        for (0..WARMUP_ITERATIONS + ITERATIONS) |iter| {
            const start = std.time.nanoTimestamp();
            for (0..CHANNEL_SIZE) |i| {
                chan.trySend(i) catch {};
                _ = chan.tryRecv() catch {};
            }
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
            if (iter >= WARMUP_ITERATIONS) {
                stats.add(elapsed);
            }
        }
        output.channel_roundtrip_ns = stats.nsPerOp(CHANNEL_SIZE);
    }

    // Oneshot benchmark
    {
        var stats = Stats.init();

        for (0..WARMUP_ITERATIONS + ITERATIONS) |iter| {
            const start = std.time.nanoTimestamp();
            for (0..CHANNEL_SIZE) |i| {
                var oneshot = Oneshot(u64).init();
                _ = oneshot.send(i);
                _ = oneshot.tryRecv();
            }
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
            if (iter >= WARMUP_ITERATIONS) {
                stats.add(elapsed);
            }
        }
        output.oneshot_ns = stats.nsPerOp(CHANNEL_SIZE);
    }

    // WaitGroup benchmark
    {
        var stats = Stats.init();

        for (0..WARMUP_ITERATIONS + ITERATIONS) |iter| {
            const start = std.time.nanoTimestamp();
            for (0..CHANNEL_SIZE) |_| {
                var wg = WaitGroup.init();
                wg.add(1);
                wg.done();
                std.mem.doNotOptimizeAway(wg.isDone());
            }
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
            if (iter >= WARMUP_ITERATIONS) {
                stats.add(elapsed);
            }
        }
        output.waitgroup_ns = stats.nsPerOp(CHANNEL_SIZE);
    }

    // Event benchmark
    {
        var stats = Stats.init();

        for (0..WARMUP_ITERATIONS + ITERATIONS) |iter| {
            const start = std.time.nanoTimestamp();
            for (0..CHANNEL_SIZE) |_| {
                var event = Event.init();
                event.set();
                std.mem.doNotOptimizeAway(event.isSet());
                event.reset();
            }
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
            if (iter >= WARMUP_ITERATIONS) {
                stats.add(elapsed);
            }
        }
        output.event_ns = stats.nsPerOp(CHANNEL_SIZE);
    }

    output.print();
}

pub fn runBenchmarks(allocator: Allocator) !void {
    print("\n", .{});
    print("=" ** 80 ++ "\n", .{});
    print("                       Blitz-IO Benchmark Suite\n", .{});
    print("=" ** 80 ++ "\n", .{});
    print("Iterations: {d} (+ {d} warmup)   ", .{ ITERATIONS, WARMUP_ITERATIONS });
    print("Platform: {s}\n\n", .{@tagName(@import("builtin").cpu.arch)});

    for (TASK_COUNTS) |n| {
        print("=" ** 80 ++ "\n", .{});
        print("N = {d:>12}\n", .{n});
        print("=" ** 80 ++ "\n\n", .{});

        // Mutex
        try benchMutex(n);

        // RwLock
        try benchRwLock(n);

        // Semaphore
        try benchSemaphore(n);
        print("\n", .{});

        // Channel (only for smaller N)
        if (n <= 10_000) {
            try benchChannel(allocator, n);
            print("\n", .{});

            // Oneshot
            try benchOneshot(n);

            // WaitGroup
            try benchWaitGroup(n);

            // Event
            try benchEvent(n);
            print("\n", .{});
        }
    }

    print("=" ** 80 ++ "\n", .{});
    print("Benchmark complete.\n", .{});
    print("=" ** 80 ++ "\n\n", .{});
}

// ============================================================================
// Mutex Benchmark
// ============================================================================

fn benchMutex(n: usize) !void {
    var mutex = Mutex(u64).init(0);
    var stats = Stats.init();

    for (0..WARMUP_ITERATIONS + ITERATIONS) |iter| {
        const start = std.time.nanoTimestamp();
        for (0..n) |_| {
            if (mutex.tryLock()) |g| {
                var guard = g;
                guard.value().* += 1;
                guard.release();
            }
        }
        const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
        if (iter >= WARMUP_ITERATIONS) {
            stats.add(elapsed);
        }
    }

    print("  Mutex:         {d:>8.1}ns/op    {d:>10.0} ops/sec\n", .{ stats.nsPerOp(n), stats.opsPerSec(n) });
}

// ============================================================================
// RwLock Benchmark
// ============================================================================

fn benchRwLock(n: usize) !void {
    // Read
    {
        var rwlock = RwLock(u64).init(42);
        var stats = Stats.init();

        for (0..WARMUP_ITERATIONS + ITERATIONS) |iter| {
            const start = std.time.nanoTimestamp();
            for (0..n) |_| {
                if (rwlock.tryRead()) |g| {
                    var guard = g;
                    std.mem.doNotOptimizeAway(guard.value().*);
                    guard.release();
                }
            }
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
            if (iter >= WARMUP_ITERATIONS) {
                stats.add(elapsed);
            }
        }
        print("  RwLock read:   {d:>8.1}ns/op    {d:>10.0} ops/sec\n", .{ stats.nsPerOp(n), stats.opsPerSec(n) });
    }

    // Write
    {
        var rwlock = RwLock(u64).init(0);
        var stats = Stats.init();

        for (0..WARMUP_ITERATIONS + ITERATIONS) |iter| {
            const start = std.time.nanoTimestamp();
            for (0..n) |_| {
                if (rwlock.tryWrite()) |g| {
                    var guard = g;
                    guard.value().* += 1;
                    guard.release();
                }
            }
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
            if (iter >= WARMUP_ITERATIONS) {
                stats.add(elapsed);
            }
        }
        print("  RwLock write:  {d:>8.1}ns/op    {d:>10.0} ops/sec\n", .{ stats.nsPerOp(n), stats.opsPerSec(n) });
    }
}

// ============================================================================
// Semaphore Benchmark
// ============================================================================

fn benchSemaphore(n: usize) !void {
    var sem = Semaphore.init(100);
    var stats = Stats.init();

    for (0..WARMUP_ITERATIONS + ITERATIONS) |iter| {
        const start = std.time.nanoTimestamp();
        for (0..n) |_| {
            if (sem.tryAcquire()) |p| {
                var permit = p;
                permit.release();
            }
        }
        const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
        if (iter >= WARMUP_ITERATIONS) {
            stats.add(elapsed);
        }
    }

    print("  Semaphore:     {d:>8.1}ns/op    {d:>10.0} ops/sec\n", .{ stats.nsPerOp(n), stats.opsPerSec(n) });
}

// ============================================================================
// Channel Benchmark
// ============================================================================

fn benchChannel(allocator: Allocator, n: usize) !void {
    const capacity = @min(n, CHANNEL_SIZE);
    var chan = try Channel(u64).init(allocator, capacity);
    defer chan.deinit();

    // Send throughput
    {
        var stats = Stats.init();
        for (0..WARMUP_ITERATIONS + ITERATIONS) |iter| {
            const start = std.time.nanoTimestamp();
            for (0..capacity) |i| {
                chan.trySend(i) catch {};
            }
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
            for (0..capacity) |_| {
                _ = chan.tryRecv() catch {};
            }
            if (iter >= WARMUP_ITERATIONS) {
                stats.add(elapsed);
            }
        }
        print("  Chan send:     {d:>8.1}ns/op    {d:>10.0} ops/sec\n", .{ stats.nsPerOp(capacity), stats.opsPerSec(capacity) });
    }

    // Recv throughput
    {
        var stats = Stats.init();
        for (0..WARMUP_ITERATIONS + ITERATIONS) |iter| {
            for (0..capacity) |i| {
                chan.trySend(i) catch {};
            }
            const start = std.time.nanoTimestamp();
            for (0..capacity) |_| {
                _ = chan.tryRecv() catch {};
            }
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
            if (iter >= WARMUP_ITERATIONS) {
                stats.add(elapsed);
            }
        }
        print("  Chan recv:     {d:>8.1}ns/op    {d:>10.0} ops/sec\n", .{ stats.nsPerOp(capacity), stats.opsPerSec(capacity) });
    }

    // Roundtrip
    {
        var rt_chan = try Channel(u64).init(allocator, 1);
        defer rt_chan.deinit();

        var stats = Stats.init();
        for (0..WARMUP_ITERATIONS + ITERATIONS) |iter| {
            const start = std.time.nanoTimestamp();
            for (0..capacity) |i| {
                rt_chan.trySend(i) catch {};
                _ = rt_chan.tryRecv() catch {};
            }
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
            if (iter >= WARMUP_ITERATIONS) {
                stats.add(elapsed);
            }
        }
        print("  Chan round:    {d:>8.1}ns/op    {d:>10.0} ops/sec\n", .{ stats.nsPerOp(capacity), stats.opsPerSec(capacity) });
    }
}

// ============================================================================
// Oneshot Benchmark
// ============================================================================

fn benchOneshot(n: usize) !void {
    var stats = Stats.init();

    for (0..WARMUP_ITERATIONS + ITERATIONS) |iter| {
        const start = std.time.nanoTimestamp();
        for (0..n) |i| {
            var oneshot = Oneshot(u64).init();
            _ = oneshot.send(i);
            _ = oneshot.tryRecv();
        }
        const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
        if (iter >= WARMUP_ITERATIONS) {
            stats.add(elapsed);
        }
    }

    print("  Oneshot:       {d:>8.1}ns/op    {d:>10.0} ops/sec\n", .{ stats.nsPerOp(n), stats.opsPerSec(n) });
}

// ============================================================================
// WaitGroup Benchmark
// ============================================================================

fn benchWaitGroup(n: usize) !void {
    var stats = Stats.init();

    for (0..WARMUP_ITERATIONS + ITERATIONS) |iter| {
        const start = std.time.nanoTimestamp();
        for (0..n) |_| {
            var wg = WaitGroup.init();
            wg.add(1);
            wg.done();
            std.mem.doNotOptimizeAway(wg.isDone());
        }
        const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
        if (iter >= WARMUP_ITERATIONS) {
            stats.add(elapsed);
        }
    }

    print("  WaitGroup:     {d:>8.1}ns/op    {d:>10.0} ops/sec\n", .{ stats.nsPerOp(n), stats.opsPerSec(n) });
}

// ============================================================================
// Event Benchmark
// ============================================================================

fn benchEvent(n: usize) !void {
    var stats = Stats.init();

    for (0..WARMUP_ITERATIONS + ITERATIONS) |iter| {
        const start = std.time.nanoTimestamp();
        for (0..n) |_| {
            var event = Event.init();
            event.set();
            std.mem.doNotOptimizeAway(event.isSet());
            event.reset();
        }
        const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
        if (iter >= WARMUP_ITERATIONS) {
            stats.add(elapsed);
        }
    }

    print("  Event:         {d:>8.1}ns/op    {d:>10.0} ops/sec\n", .{ stats.nsPerOp(n), stats.opsPerSec(n) });
}
