//! Async Combinators Demo
//!
//! Demonstrates the async combinator patterns:
//! - Timeout: Wrap operations with deadlines
//! - Select: Race multiple operations
//! - Join: Run operations concurrently
//!
//! Run: zig build example-combinators

const std = @import("std");
const io = @import("blitz-io");

pub fn main() !void {
    std.debug.print("Async Combinators Demo\n", .{});
    std.debug.print("======================\n\n", .{});

    // Demo 1: Timeout combinator
    std.debug.print("1. Timeout Combinator\n", .{});
    std.debug.print("---------------------\n", .{});
    std.debug.print("Wraps any future with a deadline.\n", .{});
    std.debug.print("If the inner future doesn't complete in time, .timeout is returned.\n\n", .{});

    std.debug.print("Example pattern:\n", .{});
    std.debug.print("  var timeout = io.Timeout(AcceptFuture).init(\n", .{});
    std.debug.print("      listener.accept(),\n", .{});
    std.debug.print("      io.Duration.fromSecs(30),\n", .{});
    std.debug.print("  );\n", .{});
    std.debug.print("  \n", .{});
    std.debug.print("  switch (timeout.poll(waker)) {{\n", .{});
    std.debug.print("      .ready => |conn| handleConnection(conn),\n", .{});
    std.debug.print("      .timeout => log.warn(\"Accept timed out\"),\n", .{});
    std.debug.print("      .pending => {{}},\n", .{});
    std.debug.print("  }}\n\n", .{});

    // Demo 2: Select combinator
    std.debug.print("2. Select Combinator (Race)\n", .{});
    std.debug.print("---------------------------\n", .{});
    std.debug.print("Polls multiple futures, returns first to complete.\n", .{});
    std.debug.print("Great for graceful shutdown patterns.\n\n", .{});

    std.debug.print("Example pattern:\n", .{});
    std.debug.print("  var select = io.Select2(AcceptFuture, ShutdownFuture).init(\n", .{});
    std.debug.print("      listener.accept(),\n", .{});
    std.debug.print("      shutdown.future(),\n", .{});
    std.debug.print("  );\n", .{});
    std.debug.print("  \n", .{});
    std.debug.print("  switch (select.poll(waker)) {{\n", .{});
    std.debug.print("      .first => |conn| handleConnection(conn),\n", .{});
    std.debug.print("      .second => |_| break,  // Shutdown\n", .{});
    std.debug.print("      .pending => {{}},\n", .{});
    std.debug.print("  }}\n\n", .{});

    // Demo 3: Join combinator
    std.debug.print("3. Join Combinator (Parallel)\n", .{});
    std.debug.print("-----------------------------\n", .{});
    std.debug.print("Polls multiple futures concurrently, waits for all.\n", .{});
    std.debug.print("Perfect for parallel data fetching.\n\n", .{});

    std.debug.print("Example pattern:\n", .{});
    std.debug.print("  var join = io.Join2(UserFuture, PostsFuture).init(\n", .{});
    std.debug.print("      fetchUser(id),\n", .{});
    std.debug.print("      fetchPosts(id),\n", .{});
    std.debug.print("  );\n", .{});
    std.debug.print("  \n", .{});
    std.debug.print("  switch (join.poll(waker)) {{\n", .{});
    std.debug.print("      .ready => |results| {{\n", .{});
    std.debug.print("          const user = results[0];\n", .{});
    std.debug.print("          const posts = results[1];\n", .{});
    std.debug.print("          renderPage(user, posts);\n", .{});
    std.debug.print("      }},\n", .{});
    std.debug.print("      .pending => {{}},\n", .{});
    std.debug.print("  }}\n\n", .{});

    // Demo 4: Combining combinators
    std.debug.print("4. Composing Combinators\n", .{});
    std.debug.print("------------------------\n", .{});
    std.debug.print("Combinators can be nested for complex patterns.\n\n", .{});

    std.debug.print("Example: Parallel fetch with timeout\n", .{});
    std.debug.print("  // Join two fetches\n", .{});
    std.debug.print("  var join = io.Join2(UserFuture, PostsFuture).init(...);\n", .{});
    std.debug.print("  \n", .{});
    std.debug.print("  // Wrap with timeout\n", .{});
    std.debug.print("  var timeout = io.Timeout(@TypeOf(join)).init(\n", .{});
    std.debug.print("      join,\n", .{});
    std.debug.print("      io.Duration.fromSecs(5),\n", .{});
    std.debug.print("  );\n\n", .{});

    std.debug.print("Example: Accept with shutdown and timeout\n", .{});
    std.debug.print("  // First, race accept against shutdown\n", .{});
    std.debug.print("  var select = io.Select2(AcceptFuture, ShutdownFuture).init(...);\n", .{});
    std.debug.print("  \n", .{});
    std.debug.print("  // Then wrap with timeout\n", .{});
    std.debug.print("  var timeout = io.Timeout(@TypeOf(select)).init(\n", .{});
    std.debug.print("      select,\n", .{});
    std.debug.print("      io.Duration.fromSecs(30),\n", .{});
    std.debug.print("  );\n\n", .{});

    // Demo: Actual combinator test
    std.debug.print("5. Live Test\n", .{});
    std.debug.print("-----------\n", .{});

    const MockFuture = struct {
        value: u32,
        polls_remaining: u32,

        pub fn init(value: u32, polls: u32) @This() {
            return .{ .value = value, .polls_remaining = polls };
        }

        pub fn poll(self: *@This(), _: io.async_ops.Waker) io.async_ops.PollResult(u32) {
            if (self.polls_remaining == 0) {
                return .{ .ready = self.value };
            }
            self.polls_remaining -= 1;
            return .pending;
        }
    };

    // Test Timeout
    std.debug.print("Testing Timeout with immediate completion...\n", .{});
    const future1 = MockFuture.init(42, 0);
    var timeout1 = io.Timeout(MockFuture).init(future1, io.Duration.fromSecs(10));
    const result1 = timeout1.poll(.{});
    std.debug.print("  Result: {}\n", .{result1});

    // Test Join2
    std.debug.print("Testing Join2 with two futures...\n", .{});
    const f1 = MockFuture.init(1, 0);
    const f2 = MockFuture.init(2, 0);
    var join = io.Join2(MockFuture, MockFuture).init(f1, f2);
    const result2 = join.poll(.{});
    std.debug.print("  Result: {}\n", .{result2});

    // Test Select2
    std.debug.print("Testing Select2 with two futures...\n", .{});
    const s1 = MockFuture.init(10, 1); // Takes 1 poll
    const s2 = MockFuture.init(20, 0); // Ready immediately
    var select = io.Select2(MockFuture, MockFuture).init(s1, s2);
    const result3 = select.poll(.{});
    std.debug.print("  Result: {} (second completed first)\n", .{result3});

    std.debug.print("\nDemo complete!\n", .{});
}
