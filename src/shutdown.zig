//! Graceful Shutdown
//!
//! Provides a clean API for coordinating graceful shutdown in async servers.
//!
//! ## Usage Pattern
//!
//! ```zig
//! const io = @import("blitz-io");
//!
//! pub fn main() !void {
//!     // Initialize shutdown handler
//!     var shutdown = try io.Shutdown.init();
//!     defer shutdown.deinit();
//!
//!     // Run server with graceful shutdown
//!     try runServer(&shutdown);
//!
//!     log.info("Server shut down gracefully", .{});
//! }
//!
//! fn runServer(shutdown: *io.Shutdown) !void {
//!     var listener = try io.listen("0.0.0.0:8080");
//!     defer listener.close();
//!
//!     log.info("Listening on :8080. Press Ctrl+C to stop.", .{});
//!
//!     while (!shutdown.isShutdown()) {
//!         // Use Select to race accept against shutdown
//!         var select = io.Select2(AcceptFuture, ShutdownFuture).init(
//!             listener.accept(),
//!             shutdown.future(),
//!         );
//!
//!         switch (select.poll(waker)) {
//!             .first => |conn| {
//!                 // Handle connection (spawn task, etc.)
//!                 spawnHandler(conn);
//!             },
//!             .second => |_| {
//!                 log.info("Shutdown signal received", .{});
//!                 break;
//!             },
//!             .pending => suspend(),
//!         }
//!     }
//!
//!     // Wait for pending work to complete
//!     try shutdown.waitPending();
//! }
//! ```
//!
//! ## Design
//!
//! - Wraps AsyncSignal for SIGINT/SIGTERM
//! - Provides shutdown notification via Future
//! - Tracks pending work with counter
//! - Allows graceful drain of in-flight requests

const std = @import("std");
const builtin = @import("builtin");

const signal_mod = @import("signal.zig");
const AsyncSignal = signal_mod.AsyncSignal;
const SignalFuture = signal_mod.SignalFuture;
const Signal = signal_mod.Signal;
const SignalWaiter = signal_mod.SignalWaiter;

const time_mod = @import("time.zig");
const Duration = time_mod.Duration;
const Instant = time_mod.Instant;

// ═══════════════════════════════════════════════════════════════════════════════
// Shutdown
// ═══════════════════════════════════════════════════════════════════════════════

/// Coordinates graceful shutdown for async servers.
///
/// Listens for SIGINT (Ctrl+C) and SIGTERM (kill), provides a Future for
/// integration with Select, and tracks pending work for clean shutdown.
pub const Shutdown = struct {
    /// Signal handler
    signal_handler: AsyncSignal,

    /// Whether shutdown has been triggered
    triggered: std.atomic.Value(bool),

    /// The signal that triggered shutdown (if any)
    trigger_signal: ?Signal,

    /// Pending work counter
    pending_count: std.atomic.Value(usize),

    /// Mutex for state changes
    mutex: std.Thread.Mutex,

    const Self = @This();

    /// Initialize shutdown handler.
    ///
    /// Listens for SIGINT (Ctrl+C) and SIGTERM (termination).
    pub fn init() !Self {
        return .{
            .signal_handler = try AsyncSignal.shutdown(),
            .triggered = std.atomic.Value(bool).init(false),
            .trigger_signal = null,
            .pending_count = std.atomic.Value(usize).init(0),
            .mutex = .{},
        };
    }

    /// Initialize with custom signals.
    pub fn initWithSignals(signals: signal_mod.SignalSet) !Self {
        return .{
            .signal_handler = try AsyncSignal.init(signals),
            .triggered = std.atomic.Value(bool).init(false),
            .trigger_signal = null,
            .pending_count = std.atomic.Value(usize).init(0),
            .mutex = .{},
        };
    }

    /// Clean up resources.
    pub fn deinit(self: *Self) void {
        self.signal_handler.deinit();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Shutdown State
    // ═══════════════════════════════════════════════════════════════════════════

    /// Check if shutdown has been triggered.
    pub fn isShutdown(self: *Self) bool {
        // First check atomic flag (fast path)
        if (self.triggered.load(.acquire)) {
            return true;
        }

        // Try to poll for signals (non-blocking)
        if (self.signal_handler.tryRecv() catch null) |sig| {
            self.triggerShutdown(sig);
            return true;
        }

        return false;
    }

    /// Manually trigger shutdown (e.g., from a /shutdown endpoint).
    pub fn trigger(self: *Self) void {
        self.triggerShutdown(null);
    }

    /// Get the signal that triggered shutdown (if any).
    pub fn triggerSignal(self: *const Self) ?Signal {
        return self.trigger_signal;
    }

    fn triggerShutdown(self: *Self, sig: ?Signal) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.triggered.load(.acquire)) return;

        self.trigger_signal = sig;
        self.triggered.store(true, .release);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Future for Select Integration
    // ═══════════════════════════════════════════════════════════════════════════

    /// Create a future for use with Select.
    ///
    /// The future completes when a shutdown signal is received.
    ///
    /// ## Example
    ///
    /// ```zig
    /// var select = Select2(AcceptFuture, ShutdownFuture).init(
    ///     listener.accept(),
    ///     shutdown.future(),
    /// );
    /// ```
    pub fn future(self: *Self) ShutdownFuture {
        return ShutdownFuture.init(self);
    }

    /// Get the underlying SignalFuture.
    pub fn signalFuture(self: *Self) SignalFuture {
        return signal_mod.signalFuture(&self.signal_handler);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Pending Work Tracking
    // ═══════════════════════════════════════════════════════════════════════════

    /// Start tracking pending work.
    ///
    /// Call this when starting a new request/task.
    /// Returns a guard that decrements the counter when dropped.
    pub fn startWork(self: *Self) WorkGuard {
        _ = self.pending_count.fetchAdd(1, .acq_rel);
        return WorkGuard{ .shutdown = self };
    }

    /// Get the count of pending work items.
    pub fn pendingCount(self: *const Self) usize {
        return self.pending_count.load(.acquire);
    }

    /// Check if there's pending work.
    pub fn hasPendingWork(self: *const Self) bool {
        return self.pendingCount() > 0;
    }

    /// Wait for all pending work to complete.
    ///
    /// Blocks until pending count reaches zero or timeout expires.
    /// Returns true if all work completed, false on timeout.
    pub fn waitPending(self: *Self) bool {
        return self.waitPendingTimeout(Duration.fromSecs(30));
    }

    /// Wait for pending work with a custom timeout.
    pub fn waitPendingTimeout(self: *Self, timeout: Duration) bool {
        const deadline = Instant.now().add(timeout);

        while (self.pendingCount() > 0) {
            if (!Instant.now().isBefore(deadline)) {
                return false; // Timeout
            }
            std.Thread.sleep(1_000_000); // 1ms
        }

        return true;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// ShutdownFuture
// ═══════════════════════════════════════════════════════════════════════════════

/// Poll result for ShutdownFuture.
pub fn PollResult(comptime T: type) type {
    return union(enum) {
        ready: T,
        pending: void,
        err: anyerror,
    };
}

/// A future that completes when shutdown is triggered.
pub const ShutdownFuture = struct {
    shutdown: *Shutdown,
    inner_future: ?SignalFuture,

    const Self = @This();

    pub fn init(shutdown: *Shutdown) Self {
        return .{
            .shutdown = shutdown,
            .inner_future = null,
        };
    }

    /// Poll for shutdown.
    pub fn poll(self: *Self, waker: signal_mod.Waker) PollResult(void) {
        // Check if already triggered
        if (self.shutdown.triggered.load(.acquire)) {
            return .{ .ready = {} };
        }

        // Initialize inner future if needed
        if (self.inner_future == null) {
            self.inner_future = signal_mod.signalFuture(&self.shutdown.signal_handler);
        }

        // Poll the signal future
        const result = self.inner_future.?.poll(waker);
        switch (result) {
            .ready => |sig| {
                self.shutdown.triggerShutdown(sig);
                return .{ .ready = {} };
            },
            .pending => return .pending,
            .err => |e| return .{ .err = e },
        }
    }

    /// Cancel the wait.
    pub fn cancel(self: *Self) void {
        if (self.inner_future) |*f| {
            f.cancel();
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// WorkGuard
// ═══════════════════════════════════════════════════════════════════════════════

/// RAII guard for tracking pending work.
///
/// Automatically decrements the pending counter when dropped.
pub const WorkGuard = struct {
    shutdown: *Shutdown,
    completed: bool = false,

    /// Mark work as complete (decrements counter).
    pub fn complete(self: *WorkGuard) void {
        if (!self.completed) {
            self.completed = true;
            _ = self.shutdown.pending_count.fetchSub(1, .acq_rel);
        }
    }

    /// Complete the guard on scope exit.
    pub fn deinit(self: *WorkGuard) void {
        self.complete();
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

test "Shutdown - init and deinit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var shutdown = Shutdown.init() catch |err| {
        // May fail in restricted environments
        if (err == error.SignalfdFailed or err == error.KqueueFailed) return;
        return err;
    };
    defer shutdown.deinit();

    try std.testing.expect(!shutdown.isShutdown());
}

test "Shutdown - manual trigger" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var shutdown = Shutdown.init() catch |err| {
        if (err == error.SignalfdFailed or err == error.KqueueFailed) return;
        return err;
    };
    defer shutdown.deinit();

    try std.testing.expect(!shutdown.isShutdown());

    shutdown.trigger();

    try std.testing.expect(shutdown.isShutdown());
    try std.testing.expect(shutdown.triggerSignal() == null); // Manual trigger has no signal
}

test "Shutdown - pending work tracking" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var shutdown = Shutdown.init() catch |err| {
        if (err == error.SignalfdFailed or err == error.KqueueFailed) return;
        return err;
    };
    defer shutdown.deinit();

    try std.testing.expectEqual(@as(usize, 0), shutdown.pendingCount());

    {
        var guard1 = shutdown.startWork();
        defer guard1.deinit();

        try std.testing.expectEqual(@as(usize, 1), shutdown.pendingCount());
        try std.testing.expect(shutdown.hasPendingWork());

        {
            var guard2 = shutdown.startWork();
            defer guard2.deinit();

            try std.testing.expectEqual(@as(usize, 2), shutdown.pendingCount());
        }

        try std.testing.expectEqual(@as(usize, 1), shutdown.pendingCount());
    }

    try std.testing.expectEqual(@as(usize, 0), shutdown.pendingCount());
    try std.testing.expect(!shutdown.hasPendingWork());
}

test "Shutdown - waitPending with no work" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var shutdown = Shutdown.init() catch |err| {
        if (err == error.SignalfdFailed or err == error.KqueueFailed) return;
        return err;
    };
    defer shutdown.deinit();

    // Should return immediately when no pending work
    const completed = shutdown.waitPending();
    try std.testing.expect(completed);
}
