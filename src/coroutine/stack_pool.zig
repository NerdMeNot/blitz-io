//! Stack Pool - Reusable Stack Allocator
//!
//! Maintains a pool of pre-allocated stacks to avoid repeated mmap/munmap.
//! Key features:
//! - LIFO reuse for cache locality
//! - Configurable pool size limits
//! - Age-based expiration of unused stacks
//! - Thread-safe operations
//! - Stack guard integration for overflow detection
//!
//! ## Stack Guard Integration
//!
//! When enabled, the pool places magic sentinel values at the bottom of each
//! stack. On release, if the sentinel is corrupted, a stack overflow occurred.
//! This helps catch bugs that would otherwise cause mysterious crashes.
//!
//! Reference: zio/src/coro/stack_pool.zig

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const context = @import("context.zig");
const stack_mod = @import("stack.zig");
const StackGuard = @import("../util/stack_guard.zig").StackGuard;

const StackInfo = context.StackInfo;
const page_size = context.page_size;

// ═══════════════════════════════════════════════════════════════════════════════
// Stack Pool Configuration
// ═══════════════════════════════════════════════════════════════════════════════

pub const Config = struct {
    /// Stack allocation config
    stack: stack_mod.Config = .{},

    /// Maximum number of unused stacks to keep in pool
    max_unused: usize = 64,

    /// Maximum age of unused stacks before expiration (nanoseconds)
    /// 0 = never expire
    max_age_ns: u64 = 60 * std.time.ns_per_s, // 60 seconds

    /// Maximum number of stacks to free per release call
    /// Bounds worst-case latency
    max_free_per_release: usize = 4,

    /// Enable stack guard sentinel checking
    /// When enabled, magic sentinel values are placed at the bottom of each
    /// stack and checked on release to detect stack overflow
    enable_guard: bool = true,
};

pub const default_config = Config{};

// ═══════════════════════════════════════════════════════════════════════════════
// Stack Pool
// ═══════════════════════════════════════════════════════════════════════════════

/// Thread-safe pool of reusable stacks
pub const StackPool = struct {
    const Self = @This();

    /// Configuration
    config: Config,

    /// Mutex for thread safety
    mutex: std.Thread.Mutex = .{},

    /// Free list head (newest first)
    head: ?*FreeNode = null,

    /// Free list tail (oldest)
    tail: ?*FreeNode = null,

    /// Current pool size
    pool_size: usize = 0,

    /// Statistics
    stats: Stats = .{},

    pub const Stats = struct {
        /// Total stacks allocated
        allocated: u64 = 0,

        /// Total stacks freed
        freed: u64 = 0,

        /// Stacks reused from pool
        reused: u64 = 0,

        /// Stacks expired due to age
        expired: u64 = 0,

        /// Stack guard failures (overflow detected)
        guard_failures: u64 = 0,
    };

    /// Free node stored at the base of an unused stack
    /// This is clever: we reuse the stack memory itself for pool metadata
    const FreeNode = struct {
        /// Stack info for this stack
        info: StackInfo,

        /// Timestamp when released to pool
        released_at: i128,

        /// Next node in list (older)
        next: ?*FreeNode,

        /// Previous node in list (newer)
        prev: ?*FreeNode,
    };

    /// Initialize a stack pool with given configuration
    pub fn init(config: Config) Self {
        return .{ .config = config };
    }

    /// Initialize with default configuration
    pub fn initDefault() Self {
        return init(default_config);
    }

    /// Deinitialize and free all pooled stacks
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Free all stacks in pool
        var node = self.head;
        while (node) |n| {
            const next = n.next;
            stack_mod.free(n.info);
            self.stats.freed += 1;
            node = next;
        }

        self.head = null;
        self.tail = null;
        self.pool_size = 0;
    }

    /// Acquire a stack from the pool or allocate a new one
    pub fn acquire(self: *Self) !StackInfo {
        self.mutex.lock();

        // Try to get from pool
        if (self.head) |node| {
            // Remove from list
            self.head = node.next;
            if (self.head) |h| {
                h.prev = null;
            } else {
                self.tail = null;
            }
            self.pool_size -= 1;
            self.stats.reused += 1;

            const info = node.info;
            self.mutex.unlock();

            // Re-initialize stack guard for reused stack
            // Use the committed region (limit..base), not allocation_ptr (guard page)
            if (self.config.enable_guard) {
                const committed_len = info.base - info.limit;
                const committed_ptr: [*]u8 = @ptrFromInt(info.limit);
                const stack_slice = committed_ptr[0..committed_len];
                StackGuard.init(stack_slice);
            }

            return info;
        }

        self.mutex.unlock();

        // Pool empty - allocate new stack
        var info: StackInfo = .{};
        try stack_mod.alloc(&info, self.config.stack);

        // Initialize stack guard sentinel at the bottom of the committed region
        // Note: allocation_ptr is a guard page (PROT_NONE), so we use limit..base
        // which is the committed (writable) region
        if (self.config.enable_guard) {
            const committed_len = info.base - info.limit;
            const committed_ptr: [*]u8 = @ptrFromInt(info.limit);
            const stack_slice = committed_ptr[0..committed_len];
            StackGuard.init(stack_slice);
        }

        self.mutex.lock();
        self.stats.allocated += 1;
        self.mutex.unlock();

        return info;
    }

    /// Release a stack back to the pool
    pub fn release(self: *Self, info: StackInfo) void {
        if (!info.isValid()) return;

        // Check stack guard sentinel for overflow detection
        // Use the committed region (limit..base), not allocation_ptr (guard page)
        if (self.config.enable_guard) {
            const committed_len = info.base - info.limit;
            const committed_ptr: [*]const u8 = @ptrFromInt(info.limit);
            const stack_slice = committed_ptr[0..committed_len];
            if (!StackGuard.check(stack_slice)) {
                // Stack overflow detected! Log and free directly - don't reuse
                self.mutex.lock();
                self.stats.guard_failures += 1;
                self.stats.freed += 1;
                self.mutex.unlock();

                // Log in debug builds
                if (builtin.mode == .Debug) {
                    std.debug.print("WARNING: Stack overflow detected during release!\n", .{});
                }

                stack_mod.free(info);
                return;
            }
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.nanoTimestamp();

        // Check if pool is full
        if (self.pool_size >= self.config.max_unused) {
            // Pool full - free directly
            stack_mod.free(info);
            self.stats.freed += 1;
            return;
        }

        // Recycle the stack (mark pages as reclaimable)
        stack_mod.recycle(info);

        // Create FreeNode at the base of the stack
        // The stack grows down, so base is the highest address
        // We store FreeNode just below base
        const node_addr = info.base - @sizeOf(FreeNode);
        const aligned_addr = node_addr & ~(@as(usize, @alignOf(FreeNode)) - 1);
        const node: *FreeNode = @ptrFromInt(aligned_addr);

        node.* = .{
            .info = info,
            .released_at = now,
            .next = self.head,
            .prev = null,
        };

        // Add to front of list (LIFO for cache locality)
        if (self.head) |h| {
            h.prev = node;
        } else {
            self.tail = node;
        }
        self.head = node;
        self.pool_size += 1;

        // Expire old stacks
        self.expireOldStacksLocked(now);
    }

    /// Expire stacks that are too old (called with mutex held)
    fn expireOldStacksLocked(self: *Self, now: i128) void {
        if (self.config.max_age_ns == 0) return;

        const max_age: i128 = @intCast(self.config.max_age_ns);
        var freed: usize = 0;

        // Start from tail (oldest)
        while (self.tail) |node| {
            if (freed >= self.config.max_free_per_release) break;

            const age = now - node.released_at;
            if (age < max_age) break;

            // Remove from list
            if (node.prev) |prev| {
                prev.next = null;
                self.tail = prev;
            } else {
                // Last node
                self.head = null;
                self.tail = null;
            }

            self.pool_size -= 1;
            stack_mod.free(node.info);
            self.stats.freed += 1;
            self.stats.expired += 1;
            freed += 1;
        }
    }

    /// Get current statistics
    pub fn getStats(self: *Self) Stats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats;
    }

    /// Get current pool size
    pub fn size(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.pool_size;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Global Pool (convenience)
// ═══════════════════════════════════════════════════════════════════════════════

var global_pool: ?*StackPool = null;
var global_pool_storage: StackPool = undefined;

/// Initialize the global stack pool
pub fn initGlobal(config: Config) void {
    global_pool_storage = StackPool.init(config);
    global_pool = &global_pool_storage;
}

/// Initialize the global stack pool with default config
pub fn initGlobalDefault() void {
    initGlobal(default_config);
}

/// Deinitialize the global stack pool
pub fn deinitGlobal() void {
    if (global_pool) |pool| {
        pool.deinit();
        global_pool = null;
    }
}

/// Get the global stack pool
pub fn getGlobal() ?*StackPool {
    return global_pool;
}

/// Acquire a stack from the global pool
pub fn acquireGlobal() !StackInfo {
    if (global_pool) |pool| {
        return pool.acquire();
    }
    // No pool - allocate directly
    var info: StackInfo = .{};
    try stack_mod.allocDefault(&info);
    return info;
}

/// Release a stack to the global pool
pub fn releaseGlobal(info: StackInfo) void {
    if (global_pool) |pool| {
        pool.release(info);
    } else {
        // No pool - free directly
        stack_mod.free(info);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

test "StackPool - basic acquire/release" {
    var pool = StackPool.init(.{
        .max_unused = 4,
        .max_age_ns = 0, // Never expire
    });
    defer pool.deinit();

    // Acquire a stack
    const info1 = try pool.acquire();
    try std.testing.expect(info1.isValid());

    // Release it
    pool.release(info1);
    try std.testing.expectEqual(@as(usize, 1), pool.size());

    // Acquire again - should reuse
    const info2 = try pool.acquire();
    try std.testing.expect(info2.isValid());
    try std.testing.expectEqual(@as(usize, 0), pool.size());

    // Stats check
    const stats = pool.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.allocated);
    try std.testing.expectEqual(@as(u64, 1), stats.reused);

    pool.release(info2);
}

test "StackPool - pool limit" {
    var pool = StackPool.init(.{
        .max_unused = 2,
        .max_age_ns = 0,
    });
    defer pool.deinit();

    // Acquire 4 stacks
    var stacks: [4]StackInfo = undefined;
    for (&stacks) |*s| {
        s.* = try pool.acquire();
    }

    // Release all 4
    for (stacks) |s| {
        pool.release(s);
    }

    // Only 2 should be in pool (limit)
    try std.testing.expectEqual(@as(usize, 2), pool.size());

    const stats = pool.getStats();
    try std.testing.expectEqual(@as(u64, 4), stats.allocated);
    try std.testing.expectEqual(@as(u64, 2), stats.freed); // 2 freed because over limit
}

test "StackPool - global pool" {
    initGlobalDefault();
    defer deinitGlobal();

    const info = try acquireGlobal();
    try std.testing.expect(info.isValid());

    releaseGlobal(info);
}

test "StackPool - stack guard initialization" {
    var pool = StackPool.init(.{
        .max_unused = 4,
        .max_age_ns = 0,
        .enable_guard = true,
    });
    defer pool.deinit();

    // Acquire a stack - should have guard initialized
    const info = try pool.acquire();
    try std.testing.expect(info.isValid());

    // Verify guard sentinel is present at bottom of committed region
    const committed_len = info.base - info.limit;
    const committed_ptr: [*]const u8 = @ptrFromInt(info.limit);
    const stack_slice = committed_ptr[0..committed_len];
    try std.testing.expect(StackGuard.check(stack_slice));

    // Release - should pass guard check
    pool.release(info);
    try std.testing.expectEqual(@as(usize, 1), pool.size());

    // No guard failures
    const stats = pool.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.guard_failures);
}

test "StackPool - stack guard overflow detection" {
    var pool = StackPool.init(.{
        .max_unused = 4,
        .max_age_ns = 0,
        .enable_guard = true,
    });
    defer pool.deinit();

    // Acquire a stack
    const info = try pool.acquire();
    try std.testing.expect(info.isValid());

    // Corrupt the guard sentinel to simulate overflow
    const committed_ptr: [*]u8 = @ptrFromInt(info.limit);
    committed_ptr[0] = 0xFF; // Corrupt first byte of sentinel

    // Release - should detect overflow and NOT return to pool
    pool.release(info);

    // Pool should be empty (corrupted stack was freed, not pooled)
    try std.testing.expectEqual(@as(usize, 0), pool.size());

    // Should have recorded guard failure
    const stats = pool.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.guard_failures);
    try std.testing.expectEqual(@as(u64, 1), stats.freed);
}

test "StackPool - guard disabled" {
    var pool = StackPool.init(.{
        .max_unused = 4,
        .max_age_ns = 0,
        .enable_guard = false,
    });
    defer pool.deinit();

    // Acquire a stack
    const info = try pool.acquire();

    // Corrupt the guard area (should be ignored since guards disabled)
    const committed_ptr: [*]u8 = @ptrFromInt(info.limit);
    committed_ptr[0] = 0xFF;

    // Release - should NOT check guard and still pool the stack
    pool.release(info);

    // Stack should be in pool (guard check skipped)
    try std.testing.expectEqual(@as(usize, 1), pool.size());

    // No guard failures recorded
    const stats = pool.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.guard_failures);
}
