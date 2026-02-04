//! Timeout Demo
//!
//! Demonstrates async timeout patterns:
//! - Wrapping operations with Timeout
//! - Deadline tracking
//! - Extending and resetting timeouts
//!
//! Run: zig build example-timeout

const std = @import("std");
const io = @import("blitz-io");

pub fn main() !void {
    std.debug.print("Timeout Demo\n", .{});
    std.debug.print("============\n\n", .{});

    // Demo 1: Basic Duration usage
    std.debug.print("1. Duration API\n", .{});
    std.debug.print("---------------\n", .{});

    const one_second = io.Duration.fromSecs(1);
    const half_second = io.Duration.fromMillis(500);
    const two_minutes = io.Duration.fromMinutes(2);
    const one_hour = io.Duration.fromHours(1);

    std.debug.print("1 second    = {} ns\n", .{one_second.asNanos()});
    std.debug.print("500 ms      = {} ms\n", .{half_second.asMillis()});
    std.debug.print("2 minutes   = {} seconds\n", .{two_minutes.asSecs()});
    std.debug.print("1 hour      = {} minutes\n", .{one_hour.asMinutes()});

    // Duration arithmetic
    const combined = one_second.add(half_second);
    std.debug.print("1s + 500ms  = {} ms\n", .{combined.asMillis()});

    std.debug.print("\n", .{});

    // Demo 2: Deadline usage
    std.debug.print("2. Deadline API\n", .{});
    std.debug.print("---------------\n", .{});

    var deadline = io.deadline(io.Duration.fromMillis(100));

    std.debug.print("Deadline expires in: {} ms\n", .{deadline.remaining().asMillis()});
    std.debug.print("Is expired: {}\n", .{deadline.isExpired()});

    // Simulate some work
    std.debug.print("Doing work for 50ms...\n", .{});
    std.Thread.sleep(50_000_000); // 50ms

    std.debug.print("Remaining: {} ms\n", .{deadline.remaining().asMillis()});
    std.debug.print("Is expired: {}\n", .{deadline.isExpired()});

    // Wait for expiration
    std.debug.print("Waiting for deadline to expire...\n", .{});
    std.Thread.sleep(60_000_000); // 60ms more

    std.debug.print("Is expired: {}\n", .{deadline.isExpired()});

    // Check returns error when expired
    if (deadline.check()) {
        std.debug.print("Check passed (unexpected)\n", .{});
    } else |err| {
        std.debug.print("Check failed with: {}\n", .{err});
    }

    std.debug.print("\n", .{});

    // Demo 3: Extending deadlines
    std.debug.print("3. Extending Deadlines\n", .{});
    std.debug.print("----------------------\n", .{});

    var extendable = io.deadline(io.Duration.fromMillis(50));
    std.debug.print("Initial: {} ms remaining\n", .{extendable.remaining().asMillis()});

    extendable.extend(io.Duration.fromMillis(100));
    std.debug.print("After extend(100ms): {} ms remaining\n", .{extendable.remaining().asMillis()});

    extendable.reset(io.Duration.fromSecs(1));
    std.debug.print("After reset(1s): {} ms remaining\n", .{extendable.remaining().asMillis()});

    std.debug.print("\n", .{});

    // Demo 4: Instant for timing
    std.debug.print("4. Instant API (Timing)\n", .{});
    std.debug.print("-----------------------\n", .{});

    const start = io.Instant.now();

    // Do some work
    var sum: u64 = 0;
    for (0..1_000_000) |i| {
        sum += i;
    }

    const elapsed = start.elapsed();
    std.debug.print("Computed sum of 0..1M = {}\n", .{sum});
    std.debug.print("Elapsed time: {} us ({} ns)\n", .{ elapsed.asMicros(), elapsed.asNanos() });

    std.debug.print("\nDemo complete!\n", .{});
}
