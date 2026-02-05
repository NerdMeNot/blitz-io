//! Platform-Specific Coroutine Context
//!
//! This module provides the low-level CPU context switching primitives.
//! Each platform has its own register layout and ABI requirements.
//!
//! Supported platforms:
//! - x86_64 (Linux, macOS, Windows)
//! - aarch64 (Linux, macOS, Windows)
//! - arm/thumb (Linux)
//! - riscv64 (Linux)
//! - riscv32 (Linux)
//! - loongarch64 (Linux)
//!
//! Reference: zio/src/coro/coroutines.zig

const std = @import("std");
const builtin = @import("builtin");

// ═══════════════════════════════════════════════════════════════════════════════
// Platform Detection
// ═══════════════════════════════════════════════════════════════════════════════

const is_windows = builtin.os.tag == .windows;
const is_x86_64 = builtin.cpu.arch == .x86_64;
const is_aarch64 = builtin.cpu.arch == .aarch64;
const is_arm = builtin.cpu.arch == .arm;
const is_thumb = builtin.cpu.arch == .thumb;
const is_riscv64 = builtin.cpu.arch == .riscv64;
const is_riscv32 = builtin.cpu.arch == .riscv32;
const is_loongarch64 = builtin.cpu.arch == .loongarch64;

// ═══════════════════════════════════════════════════════════════════════════════
// Stack Info - Tracks allocated stack memory
// ═══════════════════════════════════════════════════════════════════════════════

/// Information about an allocated stack
pub const StackInfo = extern struct {
    /// Base pointer of allocation (lowest address)
    allocation_ptr: [*]align(page_size) u8 = undefined,

    /// Top of stack (highest usable address, stack grows down)
    base: usize = 0,

    /// Bottom of committed region (lowest usable address)
    limit: usize = 0,

    /// Total allocation size
    allocation_len: usize = 0,

    /// Valgrind stack ID (for debugging)
    valgrind_stack_id: usize = 0,

    pub fn isValid(self: StackInfo) bool {
        return self.base != 0 and self.limit != 0;
    }
};

pub const page_size: usize = std.heap.page_size_min;

// ═══════════════════════════════════════════════════════════════════════════════
// Context - CPU Register State (per architecture)
// ═══════════════════════════════════════════════════════════════════════════════

/// Current coroutine context for this thread. Used by signal handlers
/// to determine if a fault is from a coroutine stack.
pub threadlocal var current_context: ?*Context = null;

/// CPU context for context switching.
pub const Context = switch (builtin.cpu.arch) {
    .x86_64 => X86_64_Context,
    .aarch64 => Aarch64_Context,
    .arm, .thumb => Arm32_Context,
    .riscv64 => Riscv64_Context,
    .riscv32 => Riscv32_Context,
    .loongarch64 => LoongArch64_Context,
    else => |arch| @compileError("Unsupported architecture: " ++ @tagName(arch)),
};

/// x86_64 context (System V ABI or Windows x64 ABI)
pub const X86_64_Context = extern struct {
    rsp: u64 = 0,
    rbp: u64 = 0,
    rip: u64 = 0,
    // Windows TEB fields (offsets 0x20, 0x1478, 0x08, 0x10)
    teb_fiber_data: u64 = 0,
    teb_dealloc_stack: u64 = 0,
    teb_stack_limit: u64 = 0,
    teb_stack_base: u64 = 0,
    stack_info: StackInfo = .{},

    pub const stack_alignment: usize = 16;
};

/// aarch64 context
pub const Aarch64_Context = extern struct {
    sp: u64 = 0, // x31 (stack pointer)
    fp: u64 = 0, // x29 (frame pointer)
    lr: u64 = 0, // x30 (link register)
    pc: u64 = 0,
    // Windows TEB fields
    teb_fiber_data: u64 = 0,
    teb_dealloc_stack: u64 = 0,
    teb_stack_limit: u64 = 0,
    teb_stack_base: u64 = 0,
    stack_info: StackInfo = .{},

    pub const stack_alignment: usize = 16;
};

/// ARM 32-bit context
pub const Arm32_Context = extern struct {
    sp: u32 = 0, // r13 (stack pointer)
    fp: u32 = 0, // r11 (frame pointer, r7 in Thumb)
    lr: u32 = 0, // r14 (link register)
    pc: u32 = 0, // r15 (program counter)
    stack_info: StackInfo = .{},

    pub const stack_alignment: usize = 8; // AAPCS requires 8-byte alignment
};

/// RISC-V 64-bit context
pub const Riscv64_Context = extern struct {
    sp: u64 = 0,
    fp: u64 = 0,
    pc: u64 = 0,
    stack_info: StackInfo = .{},

    pub const stack_alignment: usize = 16;
};

/// RISC-V 32-bit context
pub const Riscv32_Context = extern struct {
    sp: u32 = 0,
    fp: u32 = 0,
    pc: u32 = 0,
    stack_info: StackInfo = .{},

    pub const stack_alignment: usize = 16;
};

/// LoongArch 64-bit context
pub const LoongArch64_Context = extern struct {
    sp: u64 = 0,
    fp: u64 = 0,
    pc: u64 = 0,
    stack_info: StackInfo = .{},

    pub const stack_alignment: usize = 16;
};

// ═══════════════════════════════════════════════════════════════════════════════
// Context Setup - Initialize a context to start at an entry point
// ═══════════════════════════════════════════════════════════════════════════════

/// Entry point function type (naked for assembly entry)
pub const EntryPointFn = fn () callconv(.naked) noreturn;

/// Initialize a context to begin execution at the given entry point
pub fn setupContext(
    ctx: *Context,
    stack_ptr: usize,
    entry_point: *const EntryPointFn,
) void {
    std.debug.assert(stack_ptr % Context.stack_alignment == 0);

    if (is_x86_64) {
        ctx.rsp = stack_ptr;
        ctx.rbp = 0;
        ctx.rip = @intFromPtr(entry_point);
    } else if (is_aarch64) {
        ctx.sp = stack_ptr;
        ctx.fp = 0;
        ctx.lr = @returnAddress(); // CRITICAL: Set valid return address (from zio)
        ctx.pc = @intFromPtr(entry_point);
    } else if (is_arm or is_thumb) {
        ctx.sp = @intCast(stack_ptr);
        ctx.fp = 0;
        ctx.lr = @intCast(@returnAddress());
        ctx.pc = @intCast(@intFromPtr(entry_point));
    } else if (is_riscv64) {
        ctx.sp = stack_ptr;
        ctx.fp = 0;
        ctx.pc = @intFromPtr(entry_point);
    } else if (is_riscv32) {
        ctx.sp = @intCast(stack_ptr);
        ctx.fp = 0;
        ctx.pc = @intCast(@intFromPtr(entry_point));
    } else if (is_loongarch64) {
        ctx.sp = stack_ptr;
        ctx.fp = 0;
        ctx.pc = @intFromPtr(entry_point);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Context Switching - Save current context, restore new context
// ═══════════════════════════════════════════════════════════════════════════════

/// Switch from current context to new context.
/// Saves the current CPU state to `current`, then restores state from `new`.
pub inline fn switchContext(
    current: *Context,
    new: *Context,
) void {
    // Update thread-local context pointer for signal handlers
    current_context = new;

    if (is_x86_64) {
        switchContextX86_64(current, new);
    } else if (is_aarch64) {
        switchContextAarch64(current, new);
    } else if (is_arm) {
        switchContextArm(current, new);
    } else if (is_thumb) {
        switchContextThumb(current, new);
    } else if (is_riscv64) {
        switchContextRiscv64(current, new);
    } else if (is_riscv32) {
        switchContextRiscv32(current, new);
    } else if (is_loongarch64) {
        switchContextLoongArch64(current, new);
    }
}

/// x86_64 context switch
fn switchContextX86_64(current: *X86_64_Context, new: *X86_64_Context) void {
    if (is_windows) {
        // Windows x64 ABI: Must save/restore TEB fields
        asm volatile (
            \\ leaq 0f(%%rip), %%rdx
            \\ movq %%rsp, 0(%%rax)
            \\ movq %%rbp, 8(%%rax)
            \\ movq %%rdx, 16(%%rax)
            \\ movq %%gs:0x30, %%r10
            \\ movq 0x20(%%r10), %%r11
            \\ movq %%r11, 24(%%rax)
            \\ movq 0x1478(%%r10), %%r11
            \\ movq %%r11, 32(%%rax)
            \\ movq 0x08(%%r10), %%r11
            \\ movq %%r11, 40(%%rax)
            \\ movq 0x10(%%r10), %%r11
            \\ movq %%r11, 48(%%rax)
            \\ movq 0(%%rcx), %%rsp
            \\ movq 8(%%rcx), %%rbp
            \\ movq %%gs:0x30, %%r10
            \\ movq 24(%%rcx), %%r11
            \\ movq %%r11, 0x20(%%r10)
            \\ movq 32(%%rcx), %%r11
            \\ movq %%r11, 0x1478(%%r10)
            \\ movq 40(%%rcx), %%r11
            \\ movq %%r11, 0x08(%%r10)
            \\ movq 48(%%rcx), %%r11
            \\ movq %%r11, 0x10(%%r10)
            \\ jmpq *16(%%rcx)
            \\ 0:
            :
            : [current] "{rax}" (current),
              [new] "{rcx}" (new),
            : .{ .rdx = true, .r10 = true, .r11 = true, .memory = true }
        );
    } else {
        // System V AMD64 ABI (Linux, macOS)
        asm volatile (
            \\ leaq 0f(%%rip), %%rdx
            \\ movq %%rsp, 0(%%rax)
            \\ movq %%rbp, 8(%%rax)
            \\ movq %%rdx, 16(%%rax)
            \\ movq 0(%%rcx), %%rsp
            \\ movq 8(%%rcx), %%rbp
            \\ jmpq *16(%%rcx)
            \\ 0:
            :
            : [current] "{rax}" (current),
              [new] "{rcx}" (new),
            : .{ .rdx = true, .memory = true }
        );
    }
}

/// aarch64 context switch
fn switchContextAarch64(current: *Aarch64_Context, new: *Aarch64_Context) void {
    if (is_windows) {
        // Windows ARM64 ABI
        asm volatile (
            \\ adr x9, 0f
            \\ mov x10, sp
            \\ stp x10, fp, [x0, #0]
            \\ stp lr, x9, [x0, #16]
            \\ ldr x10, [x18, #0x20]
            \\ ldr x11, [x18, #0x1478]
            \\ stp x10, x11, [x0, #32]
            \\ ldp x10, x11, [x18, #0x08]
            \\ stp x10, x11, [x0, #48]
            \\ ldp x9, fp, [x1, #0]
            \\ mov sp, x9
            \\ ldp lr, x9, [x1, #16]
            \\ ldp x10, x11, [x1, #32]
            \\ str x10, [x18, #0x20]
            \\ str x11, [x18, #0x1478]
            \\ ldp x10, x11, [x1, #48]
            \\ stp x10, x11, [x18, #0x08]
            \\ br x9
            \\0:
            :
            : [current] "{x0}" (current),
              [new] "{x1}" (new),
            : .{ .x9 = true, .x10 = true, .x11 = true, .memory = true }
        );
    } else {
        // Unix (Linux, macOS)
        asm volatile (
            \\ adr x9, 0f
            \\ mov x10, sp
            \\ stp x10, fp, [x0, #0]
            \\ stp lr, x9, [x0, #16]
            \\ ldp x9, fp, [x1, #0]
            \\ mov sp, x9
            \\ ldp lr, x9, [x1, #16]
            \\ br x9
            \\0:
            :
            : [current] "{x0}" (current),
              [new] "{x1}" (new),
            : .{ .x9 = true, .x10 = true, .memory = true }
        );
    }
}

/// ARM (32-bit) context switch
fn switchContextArm(current: *Arm32_Context, new: *Arm32_Context) void {
    asm volatile (
        \\ adr r2, 0f
        \\ str sp, [r0, #0]
        \\ str r11, [r0, #4]
        \\ str lr, [r0, #8]
        \\ str r2, [r0, #12]
        \\ ldr sp, [r1, #0]
        \\ ldr r11, [r1, #4]
        \\ ldr lr, [r1, #8]
        \\ ldr r2, [r1, #12]
        \\ bx r2
        \\0:
        :
        : [current] "{r0}" (current),
          [new] "{r1}" (new),
        : .{ .r2 = true, .r3 = true, .memory = true }
    );
}

/// Thumb (ARM 32-bit Thumb mode) context switch
fn switchContextThumb(current: *Arm32_Context, new: *Arm32_Context) void {
    asm volatile (
    // Calculate return address and set Thumb bit (LSB=1)
        \\ adr r2, 0f
        \\ adds r2, #1
        \\ mov r3, sp
        \\ str r3, [r0, #0]
        \\ str r7, [r0, #4]
        \\ mov r3, lr
        \\ str r3, [r0, #8]
        \\ str r2, [r0, #12]
        \\ ldr r3, [r1, #0]
        \\ mov sp, r3
        \\ ldr r7, [r1, #4]
        \\ ldr r3, [r1, #8]
        \\ mov lr, r3
        \\ ldr r2, [r1, #12]
        \\ bx r2
        \\.balign 4
        \\0:
        :
        : [current] "{r0}" (current),
          [new] "{r1}" (new),
        : .{ .r2 = true, .r3 = true, .memory = true }
    );
}

/// RISC-V 64-bit context switch
fn switchContextRiscv64(current: *Riscv64_Context, new: *Riscv64_Context) void {
    asm volatile (
        \\ lla t0, 0f
        \\ sd t0, 16(a0)
        \\ sd sp, 0(a0)
        \\ sd s0, 8(a0)
        \\ ld sp, 0(a1)
        \\ ld s0, 8(a1)
        \\ ld t0, 16(a1)
        \\ jr t0
        \\0:
        :
        : [current] "{a0}" (current),
          [new] "{a1}" (new),
        : .{ .t0 = true, .t1 = true, .memory = true }
    );
}

/// RISC-V 32-bit context switch
fn switchContextRiscv32(current: *Riscv32_Context, new: *Riscv32_Context) void {
    asm volatile (
        \\ lla t0, 0f
        \\ sw t0, 8(a0)
        \\ sw sp, 0(a0)
        \\ sw s0, 4(a0)
        \\ lw sp, 0(a1)
        \\ lw s0, 4(a1)
        \\ lw t0, 8(a1)
        \\ jr t0
        \\0:
        :
        : [current] "{a0}" (current),
          [new] "{a1}" (new),
        : .{ .t0 = true, .t1 = true, .memory = true }
    );
}

/// LoongArch 64-bit context switch
fn switchContextLoongArch64(current: *LoongArch64_Context, new: *LoongArch64_Context) void {
    asm volatile (
        \\ la.local $t0, 0f
        \\ st.d $t0, $a0, 16
        \\ st.d $sp, $a0, 0
        \\ st.d $fp, $a0, 8
        \\ ld.d $sp, $a1, 0
        \\ ld.d $fp, $a1, 8
        \\ ld.d $t0, $a1, 16
        \\ jr $t0
        \\0:
        :
        : [current] "{$r4}" (current),
          [new] "{$r5}" (new),
        : .{ .@"$t0" = true, .@"$t1" = true, .memory = true }
    );
}

// ═══════════════════════════════════════════════════════════════════════════════
// Coroutine Entry Point - Bootstrap into user function
// ═══════════════════════════════════════════════════════════════════════════════

/// Coroutine entry data stored on the coroutine's stack
pub const EntryData = extern struct {
    /// Function to call
    func: *const fn (*anyopaque) callconv(.c) void,

    /// User data to pass to function
    userdata: *anyopaque,
};

/// Entry point that bootstraps into the user's coroutine function.
pub fn coroEntry() callconv(.naked) noreturn {
    if (is_x86_64) {
        if (is_windows) {
            asm volatile (
                \\ subq $32, %%rsp
                \\ pushq $0
                \\ movq 48(%%rsp), %%rcx
                \\ jmpq *40(%%rsp)
            );
        } else {
            asm volatile (
                \\ pushq $0
                \\ movq 16(%%rsp), %%rdi
                \\ jmpq *8(%%rsp)
            );
        }
    } else if (is_aarch64) {
        asm volatile (
            \\ ldp x2, x0, [sp]
            \\ br x2
        );
    } else if (is_arm or is_thumb) {
        asm volatile (
            \\ ldr r0, [sp, #4]
            \\ ldr r2, [sp, #0]
            \\ bx r2
        );
    } else if (is_riscv64) {
        asm volatile (
            \\ ld a0, 8(sp)
            \\ ld t0, 0(sp)
            \\ jr t0
        );
    } else if (is_riscv32) {
        asm volatile (
            \\ lw a0, 4(sp)
            \\ lw t0, 0(sp)
            \\ jr t0
        );
    } else if (is_loongarch64) {
        asm volatile (
            \\ ld.d $a0, $sp, 8
            \\ ld.d $t0, $sp, 0
            \\ jr $t0
        );
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

test "Context size" {
    try std.testing.expect(@sizeOf(Context) < 256);
}

test "StackInfo validity" {
    var info = StackInfo{};
    try std.testing.expect(!info.isValid());

    info.base = 0x1000;
    info.limit = 0x100;
    try std.testing.expect(info.isValid());
}

test "Context alignment" {
    try std.testing.expect(Context.stack_alignment >= 8);
    try std.testing.expect(Context.stack_alignment <= 16);
}
