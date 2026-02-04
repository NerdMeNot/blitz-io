//! Graceful Shutdown Example
//!
//! Demonstrates how to implement graceful shutdown:
//! - Catching SIGINT (Ctrl+C) and SIGTERM
//! - Using Select to race accept against shutdown
//! - Tracking in-flight work
//! - Waiting for pending work to complete
//!
//! Run: zig build example-shutdown
//! Test: Connect with `nc localhost 8080`, then press Ctrl+C

const std = @import("std");
const io = @import("blitz-io");

const log = std.log.scoped(.shutdown_demo);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Initialize shutdown handler
    var shutdown = io.Shutdown.init() catch |err| {
        std.debug.print("Failed to init shutdown handler: {}\n", .{err});
        std.debug.print("(This is normal in some restricted environments)\n", .{});
        return;
    };
    defer shutdown.deinit();

    // Create listener
    var listener = try io.listen("0.0.0.0:8080");
    defer listener.close();

    std.debug.print("Graceful Shutdown Demo\n", .{});
    std.debug.print("======================\n", .{});
    std.debug.print("Listening on 0.0.0.0:8080\n", .{});
    std.debug.print("Connect with: nc localhost 8080\n", .{});
    std.debug.print("Press Ctrl+C to trigger graceful shutdown\n\n", .{});

    var connections_handled: usize = 0;

    // Main accept loop
    while (!shutdown.isShutdown()) {
        // Try to accept (non-blocking)
        if (listener.tryAccept() catch null) |result| {
            connections_handled += 1;

            // Track this work
            var work = shutdown.startWork();
            defer work.deinit();

            var addr_buf: [64]u8 = undefined;
            const addr_str = result.peer_addr.ipString(&addr_buf);
            std.debug.print("[{}] New connection from {s}:{}\n", .{ connections_handled, addr_str, result.peer_addr.port() });
            std.debug.print("    Pending work: {}\n", .{shutdown.pendingCount()});

            // Handle connection (simulating work)
            handleConnection(result.stream) catch |err| {
                std.debug.print("    Connection error: {}\n", .{err});
            };

            std.debug.print("[{}] Connection closed\n", .{connections_handled});
        } else {
            // No connection, check for shutdown signal
            if (shutdown.isShutdown()) break;
            std.Thread.sleep(10_000_000); // 10ms
        }
    }

    // Shutdown triggered
    std.debug.print("\n--- Shutdown Signal Received ---\n", .{});
    if (shutdown.triggerSignal()) |sig| {
        std.debug.print("Signal: {}\n", .{sig});
    } else {
        std.debug.print("Manual shutdown triggered\n", .{});
    }

    std.debug.print("Connections handled: {}\n", .{connections_handled});
    std.debug.print("Pending work: {}\n", .{shutdown.pendingCount()});

    // Wait for pending work
    if (shutdown.hasPendingWork()) {
        std.debug.print("Waiting for pending work to complete...\n", .{});
        if (shutdown.waitPendingTimeout(io.Duration.fromSecs(5))) {
            std.debug.print("All work completed.\n", .{});
        } else {
            std.debug.print("Timeout waiting for work (forcing shutdown)\n", .{});
        }
    }

    std.debug.print("Goodbye!\n", .{});
}

fn handleConnection(stream: io.TcpStream) !void {
    var conn = stream;
    defer conn.close();

    var buf: [1024]u8 = undefined;

    // Simple echo - read once and echo back
    const n = conn.tryRead(&buf) catch |err| {
        return err;
    } orelse return;

    if (n > 0) {
        std.debug.print("    Echoing {} bytes\n", .{n});
        try conn.writeAll(buf[0..n]);
    }
}
