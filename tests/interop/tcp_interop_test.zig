//! Interoperability tests for TCP
//!
//! Tests compatibility with standard network tools (nc, curl, etc.)
//! These tests require external tools and may be skipped in CI.

const std = @import("std");
const testing = std.testing;
const blitz_io = @import("blitz-io");

// Note: These tests interact with external processes and the network.
// They should be run separately from unit tests and may have environmental
// dependencies.

test "TCP interop - connect to external HTTP server" {
    // Test connecting to a known HTTP server
    // This test requires network access and may fail in isolated environments

    // TODO: Implement when TcpStream.connect is ready
    // const stream = try blitz_io.TcpStream.connect(
    //     try blitz_io.Address.parse("httpbin.org:80")
    // );
    // defer stream.close();
    //
    // try stream.writeAll("GET / HTTP/1.0\r\nHost: httpbin.org\r\n\r\n");
    //
    // var buf: [1024]u8 = undefined;
    // const n = try stream.read(&buf);
    // try testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1."));
}

test "TCP interop - listen and accept from nc" {
    // Test that our listener works with netcat
    // Run: echo "hello" | nc localhost <port>

    // TODO: Implement when TcpListener is ready
    // This would be a manual test or use std.process to spawn nc
}

test "TCP interop - echo server roundtrip" {
    // Start our echo server, connect with nc, verify response

    // TODO: Implement integration with examples/echo_server.zig
}
