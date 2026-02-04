//! Echo Server Example
//!
//! Demonstrates basic blitz-io usage:
//! - Runtime initialization
//! - TCP listening and accepting
//! - Non-blocking I/O with polling
//!
//! Run: zig build example-echo
//! Test: echo "hello" | nc localhost 8080

const std = @import("std");
const io = @import("blitz-io");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Starting blitz-io runtime...\n", .{});

    var rt = try io.Runtime.init(allocator, .{
        .workers = 2,
        .blocking_threads = 2,
    });
    defer rt.deinit();

    std.debug.print("Runtime initialized.\n", .{});
    std.debug.print("  Backend: {}\n", .{io.detectBestBackend()});
    std.debug.print("  Workers: 2\n", .{});
    std.debug.print("  Blocking threads: 2\n", .{});

    // Run the main function
    try rt.run(server, .{});
}

fn server() void {
    // Bind to port 8080
    var listener = io.net.TcpListener.bind(io.net.Address.fromPort(8080)) catch |err| {
        std.debug.print("Failed to bind: {}\n", .{err});
        return;
    };
    defer listener.close();

    const port = listener.localAddr().port();
    std.debug.print("\nEcho server listening on 0.0.0.0:{}\n", .{port});
    std.debug.print("Test with: echo 'hello' | nc localhost {}\n", .{port});
    std.debug.print("Press Ctrl+C to stop.\n\n", .{});

    // Accept and handle connections
    var connections_handled: usize = 0;
    while (connections_handled < 10) { // Handle 10 connections then exit
        if (listener.tryAccept() catch null) |result| {
            connections_handled += 1;
            var addr_buf: [64]u8 = undefined;
            const addr_str = result.peer_addr.ipString(&addr_buf);
            std.debug.print("Connection #{} from {s}:{}\n", .{ connections_handled, addr_str, result.peer_addr.port() });
            handleClient(result.stream);
        } else {
            // No connection waiting, sleep briefly
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    std.debug.print("\nHandled {} connections, shutting down.\n", .{connections_handled});
}

fn handleClient(conn: io.net.TcpStream) void {
    var stream = conn;
    defer stream.close();

    var buf: [4096]u8 = undefined;

    // Read and echo back
    while (true) {
        const n = stream.tryRead(&buf) catch |err| {
            std.debug.print("  Read error: {}\n", .{err});
            return;
        } orelse {
            // Would block - wait and retry
            std.Thread.sleep(1 * std.time.ns_per_ms);
            continue;
        };

        if (n == 0) {
            std.debug.print("  Client disconnected\n", .{});
            return;
        }

        std.debug.print("  Received {} bytes: {s}\n", .{ n, buf[0..@min(n, 50)] });

        // Echo back
        stream.writeAll(buf[0..n]) catch |err| {
            std.debug.print("  Write error: {}\n", .{err});
            return;
        };
    }
}
