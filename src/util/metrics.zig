//! Metrics - Runtime Observability
//!
//! Production-grade metrics for monitoring blitz-io health.
//! Designed for low overhead - all counters are atomic with relaxed ordering.
//!
//! Key metrics:
//! - Operations submitted/completed/cancelled
//! - Wakeups (total, spurious)
//! - Backend-specific stats (ring utilization, batch sizes)
//! - Latency histograms (optional)
//!
//! Usage:
//!   var metrics = GlobalMetrics.init();
//!   metrics.recordSubmission();
//!   metrics.recordCompletion(.success, latency_ns);
//!
//!   const snapshot = metrics.snapshot();
//!   log.info("completions: {}", .{snapshot.completions});

const std = @import("std");

/// Global metrics for the I/O runtime.
/// Thread-safe via atomic operations.
pub const GlobalMetrics = struct {
    // ─────────────────────────────────────────────────────────────────────
    // Operation counters
    // ─────────────────────────────────────────────────────────────────────

    /// Operations submitted to backend
    submissions: std.atomic.Value(u64),

    /// Operations completed successfully
    completions_success: std.atomic.Value(u64),

    /// Operations completed with error
    completions_error: std.atomic.Value(u64),

    /// Operations cancelled
    cancellations: std.atomic.Value(u64),

    // ─────────────────────────────────────────────────────────────────────
    // Wake metrics (thundering herd monitoring)
    // ─────────────────────────────────────────────────────────────────────

    /// Total wakeups issued
    wakeups: std.atomic.Value(u64),

    /// Spurious wakeups (task woke but no work)
    spurious_wakeups: std.atomic.Value(u64),

    // ─────────────────────────────────────────────────────────────────────
    // Resource tracking
    // ─────────────────────────────────────────────────────────────────────

    /// Currently registered file descriptors
    active_fds: std.atomic.Value(u64),

    /// Peak registered file descriptors
    peak_fds: std.atomic.Value(u64),

    /// Currently pending operations
    pending_ops: std.atomic.Value(u64),

    /// Peak pending operations
    peak_pending_ops: std.atomic.Value(u64),

    // ─────────────────────────────────────────────────────────────────────
    // Backend-specific metrics
    // ─────────────────────────────────────────────────────────────────────

    /// io_uring: submissions batched together
    uring_batched_submissions: std.atomic.Value(u64),

    /// io_uring: SQ full events (needed to flush)
    uring_sq_full_events: std.atomic.Value(u64),

    /// Poll iterations (for all backends)
    poll_iterations: std.atomic.Value(u64),

    /// Poll iterations with no events
    poll_empty_iterations: std.atomic.Value(u64),

    const Self = @This();

    pub fn init() Self {
        return .{
            .submissions = std.atomic.Value(u64).init(0),
            .completions_success = std.atomic.Value(u64).init(0),
            .completions_error = std.atomic.Value(u64).init(0),
            .cancellations = std.atomic.Value(u64).init(0),
            .wakeups = std.atomic.Value(u64).init(0),
            .spurious_wakeups = std.atomic.Value(u64).init(0),
            .active_fds = std.atomic.Value(u64).init(0),
            .peak_fds = std.atomic.Value(u64).init(0),
            .pending_ops = std.atomic.Value(u64).init(0),
            .peak_pending_ops = std.atomic.Value(u64).init(0),
            .uring_batched_submissions = std.atomic.Value(u64).init(0),
            .uring_sq_full_events = std.atomic.Value(u64).init(0),
            .poll_iterations = std.atomic.Value(u64).init(0),
            .poll_empty_iterations = std.atomic.Value(u64).init(0),
        };
    }

    /// Reset all metrics to zero
    pub fn reset(self: *Self) void {
        self.submissions.store(0, .monotonic);
        self.completions_success.store(0, .monotonic);
        self.completions_error.store(0, .monotonic);
        self.cancellations.store(0, .monotonic);
        self.wakeups.store(0, .monotonic);
        self.spurious_wakeups.store(0, .monotonic);
        self.active_fds.store(0, .monotonic);
        self.peak_fds.store(0, .monotonic);
        self.pending_ops.store(0, .monotonic);
        self.peak_pending_ops.store(0, .monotonic);
        self.uring_batched_submissions.store(0, .monotonic);
        self.uring_sq_full_events.store(0, .monotonic);
        self.poll_iterations.store(0, .monotonic);
        self.poll_empty_iterations.store(0, .monotonic);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Recording methods
    // ─────────────────────────────────────────────────────────────────────

    pub fn recordSubmission(self: *Self) void {
        _ = self.submissions.fetchAdd(1, .monotonic);
        const pending = self.pending_ops.fetchAdd(1, .monotonic) + 1;
        self.updatePeak(&self.peak_pending_ops, pending);
    }

    pub fn recordCompletion(self: *Self, success: bool) void {
        if (success) {
            _ = self.completions_success.fetchAdd(1, .monotonic);
        } else {
            _ = self.completions_error.fetchAdd(1, .monotonic);
        }
        _ = self.pending_ops.fetchSub(1, .monotonic);
    }

    pub fn recordCancellation(self: *Self) void {
        _ = self.cancellations.fetchAdd(1, .monotonic);
        _ = self.pending_ops.fetchSub(1, .monotonic);
    }

    pub fn recordWakeup(self: *Self) void {
        _ = self.wakeups.fetchAdd(1, .monotonic);
    }

    pub fn recordSpuriousWakeup(self: *Self) void {
        _ = self.spurious_wakeups.fetchAdd(1, .monotonic);
    }

    pub fn recordFdRegistration(self: *Self) void {
        const active = self.active_fds.fetchAdd(1, .monotonic) + 1;
        self.updatePeak(&self.peak_fds, active);
    }

    pub fn recordFdDeregistration(self: *Self) void {
        _ = self.active_fds.fetchSub(1, .monotonic);
    }

    pub fn recordPollIteration(self: *Self, had_events: bool) void {
        _ = self.poll_iterations.fetchAdd(1, .monotonic);
        if (!had_events) {
            _ = self.poll_empty_iterations.fetchAdd(1, .monotonic);
        }
    }

    pub fn recordUringSqFull(self: *Self) void {
        _ = self.uring_sq_full_events.fetchAdd(1, .monotonic);
    }

    pub fn recordUringBatch(self: *Self, count: u64) void {
        _ = self.uring_batched_submissions.fetchAdd(count, .monotonic);
    }

    fn updatePeak(self: *Self, peak: *std.atomic.Value(u64), current: u64) void {
        _ = self;
        var old_peak = peak.load(.monotonic);
        while (current > old_peak) {
            if (peak.cmpxchgWeak(old_peak, current, .monotonic, .monotonic)) |updated| {
                old_peak = updated;
            } else {
                break;
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Snapshot
    // ─────────────────────────────────────────────────────────────────────

    pub fn snapshot(self: *const Self) Snapshot {
        return .{
            .submissions = self.submissions.load(.monotonic),
            .completions_success = self.completions_success.load(.monotonic),
            .completions_error = self.completions_error.load(.monotonic),
            .cancellations = self.cancellations.load(.monotonic),
            .wakeups = self.wakeups.load(.monotonic),
            .spurious_wakeups = self.spurious_wakeups.load(.monotonic),
            .active_fds = self.active_fds.load(.monotonic),
            .peak_fds = self.peak_fds.load(.monotonic),
            .pending_ops = self.pending_ops.load(.monotonic),
            .peak_pending_ops = self.peak_pending_ops.load(.monotonic),
            .uring_batched_submissions = self.uring_batched_submissions.load(.monotonic),
            .uring_sq_full_events = self.uring_sq_full_events.load(.monotonic),
            .poll_iterations = self.poll_iterations.load(.monotonic),
            .poll_empty_iterations = self.poll_empty_iterations.load(.monotonic),
        };
    }
};

/// Immutable snapshot of metrics at a point in time.
pub const Snapshot = struct {
    submissions: u64,
    completions_success: u64,
    completions_error: u64,
    cancellations: u64,
    wakeups: u64,
    spurious_wakeups: u64,
    active_fds: u64,
    peak_fds: u64,
    pending_ops: u64,
    peak_pending_ops: u64,
    uring_batched_submissions: u64,
    uring_sq_full_events: u64,
    poll_iterations: u64,
    poll_empty_iterations: u64,

    /// Total completions (success + error)
    pub fn totalCompletions(self: Snapshot) u64 {
        return self.completions_success + self.completions_error;
    }

    /// Error rate (0.0 to 1.0)
    pub fn errorRate(self: Snapshot) f64 {
        const total = self.totalCompletions();
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.completions_error)) /
            @as(f64, @floatFromInt(total));
    }

    /// Spurious wakeup rate (0.0 to 1.0)
    pub fn spuriousWakeupRate(self: Snapshot) f64 {
        if (self.wakeups == 0) return 0.0;
        return @as(f64, @floatFromInt(self.spurious_wakeups)) /
            @as(f64, @floatFromInt(self.wakeups));
    }

    /// Poll efficiency (fraction of polls that had events)
    pub fn pollEfficiency(self: Snapshot) f64 {
        if (self.poll_iterations == 0) return 1.0;
        const productive = self.poll_iterations - self.poll_empty_iterations;
        return @as(f64, @floatFromInt(productive)) /
            @as(f64, @floatFromInt(self.poll_iterations));
    }

    /// Format as a human-readable string
    pub fn format(
        self: Snapshot,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print(
            \\Metrics:
            \\  Submissions:     {}
            \\  Completions:     {} (success: {}, error: {})
            \\  Cancellations:   {}
            \\  Wakeups:         {} (spurious: {}, rate: {d:.2}%)
            \\  Active FDs:      {} (peak: {})
            \\  Pending Ops:     {} (peak: {})
            \\  Poll Efficiency: {d:.2}%
        ,
            .{
                self.submissions,
                self.totalCompletions(),
                self.completions_success,
                self.completions_error,
                self.cancellations,
                self.wakeups,
                self.spurious_wakeups,
                self.spuriousWakeupRate() * 100,
                self.active_fds,
                self.peak_fds,
                self.pending_ops,
                self.peak_pending_ops,
                self.pollEfficiency() * 100,
            },
        );
    }
};

/// Thread-local metrics for reduced contention.
/// Use when high-frequency updates are needed.
pub const LocalMetrics = struct {
    submissions: u64 = 0,
    completions_success: u64 = 0,
    completions_error: u64 = 0,
    wakeups: u64 = 0,
    spurious_wakeups: u64 = 0,

    /// Flush local metrics to global metrics.
    pub fn flushTo(self: *LocalMetrics, global: *GlobalMetrics) void {
        if (self.submissions > 0) {
            _ = global.submissions.fetchAdd(self.submissions, .monotonic);
            self.submissions = 0;
        }
        if (self.completions_success > 0) {
            _ = global.completions_success.fetchAdd(self.completions_success, .monotonic);
            self.completions_success = 0;
        }
        if (self.completions_error > 0) {
            _ = global.completions_error.fetchAdd(self.completions_error, .monotonic);
            self.completions_error = 0;
        }
        if (self.wakeups > 0) {
            _ = global.wakeups.fetchAdd(self.wakeups, .monotonic);
            self.wakeups = 0;
        }
        if (self.spurious_wakeups > 0) {
            _ = global.spurious_wakeups.fetchAdd(self.spurious_wakeups, .monotonic);
            self.spurious_wakeups = 0;
        }
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "GlobalMetrics - basic counting" {
    var metrics = GlobalMetrics.init();

    metrics.recordSubmission();
    metrics.recordSubmission();
    metrics.recordCompletion(true);
    metrics.recordCompletion(false);

    const snap = metrics.snapshot();
    try std.testing.expectEqual(@as(u64, 2), snap.submissions);
    try std.testing.expectEqual(@as(u64, 1), snap.completions_success);
    try std.testing.expectEqual(@as(u64, 1), snap.completions_error);
    try std.testing.expectEqual(@as(u64, 0), snap.pending_ops);
}

test "GlobalMetrics - peak tracking" {
    var metrics = GlobalMetrics.init();

    metrics.recordSubmission();
    metrics.recordSubmission();
    metrics.recordSubmission();
    // Peak should be 3

    metrics.recordCompletion(true);
    metrics.recordCompletion(true);
    // Current should be 1

    const snap = metrics.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snap.pending_ops);
    try std.testing.expectEqual(@as(u64, 3), snap.peak_pending_ops);
}

test "GlobalMetrics - spurious wakeup rate" {
    var metrics = GlobalMetrics.init();

    metrics.recordWakeup();
    metrics.recordWakeup();
    metrics.recordWakeup();
    metrics.recordWakeup();
    metrics.recordSpuriousWakeup();

    const snap = metrics.snapshot();
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), snap.spuriousWakeupRate(), 0.001);
}

test "LocalMetrics - flush to global" {
    var global = GlobalMetrics.init();
    var local = LocalMetrics{};

    local.submissions = 10;
    local.completions_success = 5;
    local.flushTo(&global);

    try std.testing.expectEqual(@as(u64, 0), local.submissions);
    try std.testing.expectEqual(@as(u64, 10), global.submissions.load(.monotonic));
}

test "GlobalMetrics - reset" {
    var metrics = GlobalMetrics.init();

    metrics.recordSubmission();
    metrics.recordWakeup();
    metrics.reset();

    const snap = metrics.snapshot();
    try std.testing.expectEqual(@as(u64, 0), snap.submissions);
    try std.testing.expectEqual(@as(u64, 0), snap.wakeups);
}
