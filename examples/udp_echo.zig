//! UDP Echo Server Example
//!
//! Demonstrates basic blitz-io UDP usage:
//! - Socket binding
//! - Receiving datagrams with sender address
//! - Echoing data back to sender
//!
//! Run: zig build example-udp-echo
//! Test: echo "hello" | nc -u localhost 8081

const std = @import("std");
const io = @import("blitz-io");

pub fn main() !void {
    const port: u16 = 8081;

    std.debug.print("Starting UDP echo server...\n", .{});

    // Bind to port
    var socket = try io.UdpSocket.bind(io.Address.fromPort(port));
    defer socket.close();

    const local = socket.localAddr();
    var addr_buf: [64]u8 = undefined;
    const addr_str = local.ipString(&addr_buf);

    std.debug.print("\nUDP echo server listening on {s}:{}\n", .{ addr_str, local.port() });
    std.debug.print("Test with: echo 'hello' | nc -u localhost {}\n", .{port});
    std.debug.print("Press Ctrl+C to stop.\n\n", .{});

    var buf: [4096]u8 = undefined;
    var packets_handled: usize = 0;

    // Echo loop - handle 20 packets then exit
    while (packets_handled < 20) {
        if (try socket.tryRecvFrom(&buf)) |result| {
            packets_handled += 1;

            var peer_buf: [64]u8 = undefined;
            const peer_str = result.addr.ipString(&peer_buf);

            std.debug.print("Packet #{}: {} bytes from {s}:{}\n", .{
                packets_handled,
                result.len,
                peer_str,
                result.addr.port(),
            });

            // Show content (up to 50 bytes)
            const preview_len = @min(result.len, 50);
            std.debug.print("  Data: {s}\n", .{buf[0..preview_len]});

            // Echo back
            if (try socket.trySendTo(buf[0..result.len], result.addr)) |sent| {
                std.debug.print("  Echoed {} bytes\n\n", .{sent});
            } else {
                std.debug.print("  Send would block, skipping\n\n", .{});
            }
        } else {
            // No packet waiting, sleep briefly
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    std.debug.print("Handled {} packets, shutting down.\n", .{packets_handled});
}
