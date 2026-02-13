//! # Blitz-IO: High-Performance Async I/O for Zig
//!
//! A production-grade async I/O runtime with:
//! - Work-stealing task scheduler
//! - Platform-optimized backends (io_uring, kqueue, epoll, IOCP)
//! - Structured concurrency primitives
//! - Graceful shutdown with signal handling
//!
//! ## Quick Start: TCP Echo Server
//!
//! ```zig
//! const std = @import("std");
//! const io = @import("blitz-io");
//!
//! pub fn main() !void {
//!     try io.run(server);
//! }
//!
//! fn server() void {
//!     var listener = io.net.listen("0.0.0.0:8080") catch return;
//!     defer listener.close();
//!
//!     while (listener.tryAccept() catch null) |result| {
//!         _ = io.task.spawn(handleClient, .{result.stream}) catch continue;
//!     }
//! }
//!
//! fn handleClient(conn: io.net.TcpStream) void {
//!     var stream = conn;
//!     defer stream.close();
//!
//!     var buf: [4096]u8 = undefined;
//!     while (true) {
//!         const n = stream.tryRead(&buf) catch return orelse continue;
//!         if (n == 0) return;
//!         stream.writeAll(buf[0..n]) catch return;
//!     }
//! }
//! ```
//!
//! ## Module Organization
//!
//! | Module | Description |
//! |--------|-------------|
//! | `io.task` | Task spawning: spawn, sleep, yield |
//! | `io.sync` | Synchronization: Mutex, RwLock, Semaphore, Notify, Barrier |
//! | `io.channel` | Message passing: Channel, Oneshot, Broadcast, Watch |
//! | `io.net` | Networking: TCP, UDP, Unix sockets, DNS |
//! | `io.fs` | Filesystem operations |
//! | `io.stream` | I/O streams: Reader, Writer, buffered I/O |
//! | `io.time` | Duration, Instant, timers |
//! | `io.signal` | Signal handling |
//! | `io.process` | Process spawning |
//! | `io.shutdown` | Graceful shutdown |
//! | `io.async_ops` | Future combinators (Timeout, Select, Join, Race) |

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════════════
// Namespaced Modules — Primary API
// ═══════════════════════════════════════════════════════════════════════════════

/// Task spawning and concurrency.
pub const task = @import("task.zig");

/// Synchronization primitives for async tasks.
pub const sync = @import("sync.zig");

/// Message passing channels.
pub const channel = @import("channel.zig");

/// Stackless future primitives.
pub const future = @import("future.zig");

/// I/O streams and utilities.
pub const stream = @import("stream.zig");

/// Networking (TCP, UDP, Unix sockets, DNS).
pub const net = @import("net.zig");

/// Filesystem operations.
pub const fs = @import("fs.zig");

/// Time primitives.
pub const time = @import("time.zig");

/// Signal handling.
pub const signal = @import("signal.zig");

/// Process spawning and management.
pub const process = @import("process.zig");

/// Graceful shutdown handler for async servers.
pub const shutdown = @import("shutdown.zig");

/// Async combinators for composing futures.
pub const async_ops = @import("async.zig");

// ═══════════════════════════════════════════════════════════════════════════════
// Runtime Lifecycle
// ═══════════════════════════════════════════════════════════════════════════════

const runtime_mod = @import("runtime.zig");

/// The async I/O runtime.
pub const Runtime = runtime_mod.Runtime;

/// Runtime configuration.
pub const Config = runtime_mod.Config;

/// JoinHandle for spawned futures.
pub const JoinHandle = runtime_mod.JoinHandle;

/// Zero-config entry point — run an async function with default settings.
pub fn run(comptime func: anytype) anyerror!PayloadType(@TypeOf(func)) {
    return runWith(std.heap.page_allocator, .{}, func);
}

/// Entry point with custom allocator and configuration.
pub fn runWith(
    allocator: std.mem.Allocator,
    config: Config,
    comptime func: anytype,
) anyerror!PayloadType(@TypeOf(func)) {
    var rt = try Runtime.init(allocator, config);
    defer rt.deinit();
    return rt.run(func, .{});
}

/// Get the current runtime (if running inside one).
pub const getRuntime = runtime_mod.getRuntime;

// ═══════════════════════════════════════════════════════════════════════════════
// Common Re-exports
// ═══════════════════════════════════════════════════════════════════════════════

/// Duration of time (nanosecond precision).
pub const Duration = time.Duration;

/// Point in time (monotonic clock).
pub const Instant = time.Instant;

// ═══════════════════════════════════════════════════════════════════════════════
// Internal — For Advanced Users
// ═══════════════════════════════════════════════════════════════════════════════

/// Internal implementation details (not part of the stable public API).
pub const internal = @import("internal.zig");

// ═══════════════════════════════════════════════════════════════════════════════
// Version
// ═══════════════════════════════════════════════════════════════════════════════

pub const version = struct {
    pub const major = 0;
    pub const minor = 2;
    pub const patch = 0;
    pub const string = "0.2.0";
};

// ═══════════════════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════════════════

fn PayloadType(comptime Func: type) type {
    const info = @typeInfo(Func);
    const fn_info = switch (info) {
        .pointer => |p| @typeInfo(p.child).@"fn",
        .@"fn" => info.@"fn",
        else => @compileError("expected function type"),
    };
    const raw = fn_info.return_type.?;
    return switch (@typeInfo(raw)) {
        .error_union => |eu| eu.payload,
        else => raw,
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

test {
    // Run all module tests
    _ = @import("time.zig");
    _ = @import("internal/blocking.zig");
    _ = @import("runtime.zig");
    _ = @import("internal/backend.zig");
    _ = @import("internal/executor.zig");
    _ = @import("net.zig");
    _ = @import("stream.zig");
    _ = @import("fs.zig");
    _ = @import("sync.zig");
    _ = @import("channel.zig");
    _ = @import("task.zig");
    _ = @import("internal/util/signal.zig");
    _ = @import("signal.zig");
    _ = @import("process.zig");
    _ = @import("async.zig");
    _ = @import("shutdown.zig");

    // Scheduler tests
    _ = @import("internal/scheduler/Header.zig");
    _ = @import("internal/scheduler/Scheduler.zig");
    _ = @import("internal/scheduler/Runtime.zig");
    _ = @import("internal/scheduler/TimerWheel.zig");

    // Future tests
    _ = @import("future.zig");

    // Utility tests
    _ = @import("internal/util/pool.zig");

    // Internal module tests
    _ = @import("internal.zig");
}

test "0 - unit test suite header" {
    std.debug.print(
        \\
        \\┌──────────────────────────────────────────────────────────────┐
        \\│  Unit Tests (inline)                                         │
        \\├──────────────────────────────────────────────────────────────┤
        \\│  sync       channel     net         fs          time         │
        \\│  task       future      stream      signal      process      │
        \\│  scheduler  backend     runtime     shutdown    internal     │
        \\└──────────────────────────────────────────────────────────────┘
        \\
    , .{});
}

test "version" {
    try std.testing.expect(version.major >= 0);
    try std.testing.expect(version.string.len > 0);
}

test "run function compiles" {
    _ = run;
    _ = runWith;
}

test "namespace structure" {
    _ = task.spawn;
    _ = task.spawnFuture;
    _ = task.spawnBlocking;
    _ = sync.Mutex;
    _ = sync.RwLock;
    _ = channel.Channel;
    _ = channel.Oneshot;
    _ = stream.Reader;
    _ = stream.Writer;
    _ = net.TcpListener;
    _ = fs.File;
    _ = time.Duration;
    _ = signal.AsyncSignal;
    _ = process.Command;

    // Future types
    _ = future.FnFuture;
    _ = future.FnReturnType;
    _ = future.FnPayload;
    _ = future.Compose;
    _ = future.compose;
    _ = future.MapFuture;
    _ = future.AndThenFuture;

    // Shutdown accessed via namespace
    _ = shutdown.Shutdown;
    _ = shutdown.ShutdownFuture;
    _ = shutdown.WorkGuard;

    // Combinators accessed via namespace
    _ = async_ops.Timeout;
    _ = async_ops.Select2;
    _ = async_ops.Join2;
}

test "z - unit test suite complete" {
    std.debug.print(
        \\
        \\┌──────────────────────────────────────────────────────────────┐
        \\│  All unit tests passed                                       │
        \\└──────────────────────────────────────────────────────────────┘
        \\
    , .{});
}
