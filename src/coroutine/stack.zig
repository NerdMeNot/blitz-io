//! Stack Allocation for Coroutines
//!
//! Manages memory for coroutine stacks. Key features:
//! - Lazy commitment: Reserve large VA space, commit pages on demand
//! - Guard pages: Detect stack overflow via SIGSEGV/SIGBUS
//! - Growth support: Extend committed region when needed
//!
//! Stack layout (grows downward - high to low addresses):
//! ```
//! +------------------+ <- allocation_ptr + allocation_len (base)
//! |   Committed      |    <- Stack usage grows down from here
//! |   Region         |
//! +------------------+ <- limit (bottom of committed region)
//! |   Uncommitted    |    <- PROT_NONE, faults on access
//! |   Region         |
//! +------------------+
//! |   Guard Page     |    <- PROT_NONE, catches overflow
//! +------------------+ <- allocation_ptr
//! ```
//!
//! Reference: zio/src/coro/stack.zig

const std = @import("std");
const builtin = @import("builtin");
const context = @import("context.zig");

const StackInfo = context.StackInfo;
const page_size = context.page_size;

// ═══════════════════════════════════════════════════════════════════════════════
// Configuration
// ═══════════════════════════════════════════════════════════════════════════════

/// Default stack configuration
pub const Config = struct {
    /// Maximum virtual address space to reserve per stack.
    /// This is the upper limit for stack growth.
    max_size: usize = 1 * 1024 * 1024, // 1 MiB

    /// Initially committed stack size.
    /// Start small, grow as needed.
    initial_committed: usize = 64 * 1024, // 64 KiB

    /// Minimum committed size (including guard page)
    min_committed: usize = 4 * page_size,
};

pub const default_config = Config{};

// ═══════════════════════════════════════════════════════════════════════════════
// Stack Allocation
// ═══════════════════════════════════════════════════════════════════════════════

/// Allocate a stack with the given configuration.
///
/// The stack is allocated with:
/// - A guard page at the bottom (PROT_NONE)
/// - Committed region at the top
/// - Uncommitted region in between (can grow into)
pub fn alloc(info: *StackInfo, config: Config) !void {
    const max_size = alignUp(config.max_size, page_size);
    const committed_size = @min(alignUp(config.initial_committed, page_size), max_size);

    if (builtin.os.tag == .windows) {
        try allocWindows(info, max_size, committed_size);
    } else {
        try allocPosix(info, max_size, committed_size);
    }
}

/// Allocate a stack with default configuration
pub fn allocDefault(info: *StackInfo) !void {
    try alloc(info, default_config);
}

/// Free a stack
pub fn free(info: StackInfo) void {
    if (!info.isValid()) return;

    if (builtin.os.tag == .windows) {
        freeWindows(info);
    } else {
        freePosix(info);
    }
}

/// Recycle a stack for potential reuse.
/// Marks pages as available for reclamation but keeps VA reserved.
pub fn recycle(info: StackInfo) void {
    if (!info.isValid()) return;

    if (builtin.os.tag == .windows) {
        // Windows: No-op, pages will be reclaimed on memory pressure
    } else {
        // POSIX: Use MADV_FREE to mark pages as reclaimable
        recyclePosix(info);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Stack Growth
// ═══════════════════════════════════════════════════════════════════════════════

/// Stack growth mode
pub const GrowMode = enum {
    /// Grow by a fixed amount (incremental)
    incremental,

    /// Commit the entire reserved region
    full,
};

/// Extend the committed region of a stack.
/// Called when the stack grows into uncommitted memory.
pub fn extend(info: *StackInfo, mode: GrowMode) !void {
    if (builtin.os.tag == .windows) {
        // Windows handles growth automatically via PAGE_GUARD
        return;
    }

    const guard_size = page_size;
    const min_limit = @intFromPtr(info.allocation_ptr) + guard_size;

    switch (mode) {
        .incremental => {
            // Grow by 1.5x in 64KB chunks
            const current_committed = info.base - info.limit;
            const growth = alignUp(@max(current_committed / 2, 64 * 1024), page_size);
            const new_limit = @max(info.limit - growth, min_limit);

            if (new_limit < info.limit) {
                try commitRegion(new_limit, info.limit - new_limit);
                info.limit = new_limit;
            }
        },
        .full => {
            // Commit everything
            if (info.limit > min_limit) {
                try commitRegion(min_limit, info.limit - min_limit);
                info.limit = min_limit;
            }
        },
    }
}

/// Check if a fault address is within a stack's uncommitted region
pub fn isFaultInStack(info: StackInfo, fault_addr: usize) bool {
    if (!info.isValid()) return false;

    const guard_end = @intFromPtr(info.allocation_ptr) + page_size;
    const limit = info.limit;

    // Fault is in stack if it's between guard page and current limit
    return fault_addr >= guard_end and fault_addr < limit;
}

// ═══════════════════════════════════════════════════════════════════════════════
// POSIX Implementation
// ═══════════════════════════════════════════════════════════════════════════════

fn allocPosix(info: *StackInfo, max_size: usize, committed_size: usize) !void {
    const posix = std.posix;

    // Reserve entire address space with PROT_NONE
    const ptr = posix.mmap(
        null,
        max_size,
        posix.PROT.NONE,
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    ) catch return error.OutOfMemory;

    const allocation_ptr: [*]align(page_size) u8 = @alignCast(ptr.ptr);
    const base_addr = @intFromPtr(allocation_ptr);

    // Stack layout:
    // [guard page][uncommitted...][committed region]
    //             ^                ^                ^
    //             |                |                |
    //             guard_end        limit            base

    // Guard page stays at PROT_NONE (set by initial mmap)
    const base = base_addr + max_size; // Top of stack
    const limit = base - committed_size; // Bottom of committed region

    // Commit the top region (where stack starts)
    const committed_ptr: [*]align(page_size) u8 = @ptrFromInt(limit);

    posix.mprotect(committed_ptr[0..committed_size], posix.PROT.READ | posix.PROT.WRITE) catch {
        posix.munmap(allocation_ptr[0..max_size]);
        return error.OutOfMemory;
    };

    // Guard page stays PROT_NONE (already set by mmap)

    info.* = .{
        .allocation_ptr = allocation_ptr,
        .base = base,
        .limit = limit,
        .allocation_len = max_size,
    };
}

fn freePosix(info: StackInfo) void {
    std.posix.munmap(info.allocation_ptr[0..info.allocation_len]);
}

fn recyclePosix(info: StackInfo) void {
    const posix = std.posix;

    // Mark committed pages as reclaimable
    const committed_start = info.limit;
    const committed_len = info.base - info.limit;

    if (committed_len > 0) {
        // MADV_FREE: Pages can be reclaimed, but contents preserved until then
        const ptr: [*]align(page_size) u8 = @ptrFromInt(committed_start);
        posix.madvise(ptr, committed_len, posix.MADV.FREE) catch {};
    }
}

fn commitRegion(addr: usize, len: usize) !void {
    const ptr: [*]align(page_size) u8 = @ptrFromInt(addr);
    std.posix.mprotect(ptr[0..len], std.posix.PROT.READ | std.posix.PROT.WRITE) catch return error.OutOfMemory;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Windows Implementation
// ═══════════════════════════════════════════════════════════════════════════════

fn allocWindows(info: *StackInfo, max_size: usize, committed_size: usize) !void {
    const windows = std.os.windows;

    // Reserve address space
    const ptr = windows.VirtualAlloc(
        null,
        max_size,
        windows.MEM_RESERVE,
        windows.PAGE_NOACCESS,
    ) orelse return error.OutOfMemory;

    const allocation_ptr: [*]align(page_size) u8 = @alignCast(@ptrCast(ptr));
    const base_addr = @intFromPtr(allocation_ptr);

    // Commit the top region
    const base = base_addr + max_size;
    const limit = base - committed_size;
    const committed_start = limit;

    _ = windows.VirtualAlloc(
        @ptrFromInt(committed_start),
        committed_size,
        windows.MEM_COMMIT,
        windows.PAGE_READWRITE,
    ) orelse {
        _ = windows.VirtualFree(allocation_ptr, 0, windows.MEM_RELEASE);
        return error.OutOfMemory;
    };

    // Set guard page at the bottom of committed region
    var old_protect: windows.DWORD = undefined;
    _ = windows.VirtualProtect(
        @ptrFromInt(committed_start),
        page_size,
        windows.PAGE_READWRITE | windows.PAGE_GUARD,
        &old_protect,
    );

    info.* = .{
        .allocation_ptr = allocation_ptr,
        .base = base,
        .limit = limit,
        .allocation_len = max_size,
    };
}

fn freeWindows(info: StackInfo) void {
    _ = std.os.windows.VirtualFree(info.allocation_ptr, 0, std.os.windows.MEM_RELEASE);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Utilities
// ═══════════════════════════════════════════════════════════════════════════════

fn alignUp(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

test "stack alloc and free" {
    var info: StackInfo = .{};

    try alloc(&info, .{
        .max_size = 64 * 1024,
        .initial_committed = 16 * 1024,
    });
    defer free(info);

    try std.testing.expect(info.isValid());
    try std.testing.expect(info.base > info.limit);
    try std.testing.expect(info.base - info.limit >= 16 * 1024);
}

test "stack default config" {
    var info: StackInfo = .{};
    try allocDefault(&info);
    defer free(info);

    try std.testing.expect(info.isValid());
}

test "stack recycle" {
    var info: StackInfo = .{};
    try allocDefault(&info);
    defer free(info);

    // Should not crash
    recycle(info);
    try std.testing.expect(info.isValid());
}
