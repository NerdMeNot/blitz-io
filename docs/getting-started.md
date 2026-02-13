# Getting Started with blitz-io

## Prerequisites

- **Zig 0.15.2** (minimum 0.15.0). Download from [ziglang.org](https://ziglang.org/download/).

Verify your installation:

```bash
zig version
# 0.15.2
```

## Installation

### Adding blitz-io to an existing project

Add blitz-io to your `build.zig.zon`:

```zon
.{
    .name = .my_project,
    .version = "0.1.0",
    .minimum_zig_version = "0.15.0",

    .dependencies = .{
        .blitz_io = .{
            .url = "https://github.com/NerdMeNot/blitz-io/archive/refs/tags/v0.2.0.tar.gz",
            .hash = "...",  // zig build will tell you the correct hash
        },
    },

    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

Then wire it up in `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Fetch the blitz-io dependency
    const blitz_io_dep = b.dependency("blitz_io", .{
        .target = target,
        .optimize = optimize,
    });
    const blitz_io_mod = blitz_io_dep.module("blitz-io");

    // Create your executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("blitz-io", blitz_io_mod);

    const exe = b.addExecutable(.{
        .name = "my-server",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run_cmd.step);
}
```

### Creating a new project from scratch

```bash
mkdir my-server && cd my-server
zig init
```

Then edit `build.zig.zon` and `build.zig` as shown above.

---

## First Program: TCP Echo Server

Create `src/main.zig`:

```zig
const std = @import("std");
const io = @import("blitz-io");

pub fn main() !void {
    // Run server with default runtime configuration.
    // This initializes the work-stealing scheduler, I/O backend,
    // timer wheel, and blocking pool -- then executes `server`.
    try io.run(server);
}

fn server() void {
    // Bind to port 8080
    var listener = io.net.TcpListener.bind(
        io.net.Address.fromPort(8080),
    ) catch |err| {
        std.debug.print("Failed to bind: {}\n", .{err});
        return;
    };
    defer listener.close();

    const port = listener.localAddr().port();
    std.debug.print("Echo server listening on 0.0.0.0:{}\n", .{port});

    // Accept loop
    while (true) {
        if (listener.tryAccept() catch null) |result| {
            handleClient(result.stream);
        } else {
            // No connection pending, sleep briefly to avoid busy-wait.
            // In a production server, use io_uring/kqueue-based accept.
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
}

fn handleClient(conn: io.net.TcpStream) void {
    var stream = conn;
    defer stream.close();

    var buf: [4096]u8 = undefined;

    while (true) {
        const n = stream.tryRead(&buf) catch return orelse {
            std.Thread.sleep(1 * std.time.ns_per_ms);
            continue;
        };
        if (n == 0) return; // Client disconnected
        stream.writeAll(buf[0..n]) catch return;
    }
}
```

Build and run:

```bash
zig build run
# Echo server listening on 0.0.0.0:8080
```

Test with netcat:

```bash
echo "hello blitz" | nc localhost 8080
# hello blitz
```

---

## Adding Timeouts

blitz-io provides `Duration` and `Instant` types for time-based operations.

```zig
const std = @import("std");
const io = @import("blitz-io");

fn handleClientWithTimeout(conn: io.net.TcpStream) void {
    var stream = conn;
    defer stream.close();

    var buf: [4096]u8 = undefined;
    const deadline = io.Instant.now().add(io.Duration.fromSecs(30));

    while (io.Instant.now().isBefore(deadline)) {
        const n = stream.tryRead(&buf) catch return orelse {
            std.Thread.sleep(1 * std.time.ns_per_ms);
            continue;
        };
        if (n == 0) return;
        stream.writeAll(buf[0..n]) catch return;
    }

    std.debug.print("Client timed out after 30s\n", .{});
}
```

### Using the Timeout combinator with Futures

For async code that uses the Future-based API:

```zig
const io = @import("blitz-io");

// Wrap any future with a timeout
var timeout = io.async_ops.Timeout(MyFuture).init(
    my_future,
    io.Duration.fromSecs(5),
);
// When polled, returns the inner future's result or TimedOut error.
```

---

## Graceful Shutdown with Signals

blitz-io provides a `Shutdown` type that listens for SIGINT (Ctrl+C) and SIGTERM, tracks in-flight work, and enables clean drain of pending requests.

```zig
const std = @import("std");
const io = @import("blitz-io");

pub fn main() !void {
    // Initialize shutdown handler (registers signal handlers)
    var shutdown = io.shutdown.Shutdown.init() catch |err| {
        std.debug.print("Failed to init shutdown: {}\n", .{err});
        return;
    };
    defer shutdown.deinit();

    var listener = try io.net.listen("0.0.0.0:8080");
    defer listener.close();

    std.debug.print("Listening on :8080. Press Ctrl+C to stop.\n", .{});

    // Accept loop -- exits when shutdown signal is received
    while (!shutdown.isShutdown()) {
        if (listener.tryAccept() catch null) |result| {
            // Track in-flight work
            var work = shutdown.startWork();
            defer work.deinit(); // Decrements pending count when done

            handleConnection(result.stream) catch {};
        } else {
            if (shutdown.isShutdown()) break;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    // Shutdown triggered
    std.debug.print("Shutdown signal received.\n", .{});

    if (shutdown.hasPendingWork()) {
        std.debug.print("Waiting for {} pending requests...\n", .{shutdown.pendingCount()});
        if (shutdown.waitPendingTimeout(io.Duration.fromSecs(5))) {
            std.debug.print("All work completed.\n", .{});
        } else {
            std.debug.print("Timeout -- forcing shutdown.\n", .{});
        }
    }
}

fn handleConnection(stream: io.net.TcpStream) !void {
    var conn = stream;
    defer conn.close();

    var buf: [1024]u8 = undefined;
    const n = conn.tryRead(&buf) catch |err| return err orelse return;
    if (n > 0) {
        try conn.writeAll(buf[0..n]);
    }
}
```

---

## Custom Runtime Configuration

The default `io.run()` uses auto-detected settings. For fine-grained control:

```zig
const std = @import("std");
const io = @import("blitz-io");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var rt = try io.Runtime.init(gpa.allocator(), .{
        .num_workers = 4,              // 4 I/O worker threads (0 = auto)
        .max_blocking_threads = 64,    // Cap on blocking pool threads
        .blocking_keep_alive_ns = 10 * std.time.ns_per_s, // 10s idle timeout
    });
    defer rt.deinit();

    try rt.run(server, .{});
}

fn server() void {
    // ...
}
```

---

## Running Tests

blitz-io has a comprehensive test suite:

```bash
# Unit tests (588+ tests)
zig build test

# Loom-style concurrency tests (exhaustive state exploration)
zig build test-concurrency

# Edge case and robustness tests
zig build test-robustness

# Multi-threaded stress tests
zig build test-stress

# All tests combined
zig build test-all
```

---

## Running Benchmarks

### blitz-io primitive benchmarks

```bash
# Run sync primitive and channel benchmarks
zig build bench
```

This builds with `-O ReleaseFast` and outputs timing for each primitive.

### Comparison with Tokio

```bash
# Requires Rust/Cargo installed for the Tokio benchmark
zig build compare
```

This runs both the blitz-io and Tokio benchmark suites and generates a side-by-side comparison table.

---

## Platform Support

| Platform | Backend | Status |
|----------|---------|--------|
| Linux 5.1+ | io_uring | Primary |
| Linux 4.x+ | epoll | Fallback |
| macOS 10.12+ | kqueue | Supported |
| Windows 10+ | IOCP | Supported |

The runtime auto-detects the best available backend. Override with:

```zig
var rt = try io.Runtime.init(allocator, .{
    .backend = .kqueue,  // Force specific backend
});
```

---

## Next Steps

- [Synchronization Primitives](sync-primitives.md) -- Mutex, RwLock, Semaphore, Barrier, Notify, OnceCell
- [Channels](channels.md) -- Channel, Oneshot, Broadcast, Watch, Select
- [Scheduler Internals](scheduler.md) -- Work-stealing scheduler deep dive
