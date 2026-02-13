//! # Task Module - Task Spawning and Concurrency
//!
//! This module provides the public API for spawning and managing async tasks.
//! It is the primary interface for concurrent programming in blitz-io.
//!
//! ## Quick Reference
//!
//! | Function | Description |
//! |----------|-------------|
//! | `spawn` | Spawn async task, returns `JoinHandle` |
//! | `spawnBlocking` | CPU-intensive work on blocking pool |
//! | `sleep` | Sleep for a duration (async-aware) |
//! | `yield` | Yield control to other tasks |
//! | `joinAll` | Wait for all tasks, return tuple of results |
//! | `tryJoinAll` | Wait for all, collect results and errors |
//! | `race` | First to complete wins, cancel others |
//! | `select` | First to complete, keep others running |
//!
//! ## Quick Start
//!
//! ```zig
//! const io = @import("blitz-io");
//!
//! // Spawn a task and await result
//! const handle = try io.task.spawn(myFunc, .{arg1, arg2});
//! const result = try handle.join();
//!
//! // Sleep (yields to scheduler in task context)
//! io.task.sleep(io.time.Duration.fromSecs(1));
//! ```
//!
//! ## Multiple Tasks
//!
//! ```zig
//! // Spawn concurrent tasks
//! const user_h = try io.task.spawn(fetchUser, .{id});
//! const posts_h = try io.task.spawn(fetchPosts, .{id});
//!
//! // Wait for both
//! const user, const posts = try io.task.joinAll(.{user_h, posts_h});
//! ```
//!
//! ## Blocking Operations
//!
//! CPU-intensive or blocking I/O work should run on the blocking pool
//! to avoid starving the async I/O workers:
//!
//! ```zig
//! // Runs on dedicated blocking threads
//! const hash = try io.task.spawnBlocking(computeExpensiveHash, .{data});
//! ```
//!
//! ## Design Notes
//!
//! - Tasks are lightweight (~256 bytes) and scheduled cooperatively
//! - The blocking pool has separate threads from I/O workers
//! - JoinHandle allows awaiting, cancelling, or detaching tasks
//! - In the future, `spawnBlocking` may integrate with Blitz for true CPU parallelism

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════════════
// Re-exports from task/ directory
// ═══════════════════════════════════════════════════════════════════════════════

// Spawn functions
pub const spawn = @import("task/spawn.zig").spawn;
pub const spawnFuture = @import("task/spawn.zig").spawnFuture;
pub const spawnBlocking = @import("task/spawn.zig").spawnBlocking;

// JoinHandle type
const join_handle_mod = @import("task/JoinHandle.zig");
pub const JoinHandle = join_handle_mod.JoinHandle;
pub const CoroJoinHandle = join_handle_mod.CoroJoinHandle;

// Duration type (for timeout specifications)
const sleep_mod = @import("task/sleep.zig");
pub const Duration = sleep_mod.Duration;

// Multi-task coordination helpers
const helpers_mod = @import("task/combinators.zig");
pub const joinAll = helpers_mod.joinAll;
pub const tryJoinAll = helpers_mod.tryJoinAll;
pub const race = helpers_mod.race;
pub const @"select" = helpers_mod.@"select";
pub const TaskResult = helpers_mod.TaskResult;

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

test {
    // Run all sub-module tests
    _ = @import("task/spawn.zig");
    _ = @import("task/JoinHandle.zig");
    _ = @import("task/sleep.zig");
    _ = @import("task/combinators.zig");
}

test "task module exports" {
    // Verify all exports are available
    _ = spawn;
    _ = JoinHandle;
    _ = Duration;
    _ = joinAll;
    _ = tryJoinAll;
    _ = race;
    _ = @"select";
}
