//! Interoperability tests for TCP
//!
//! Tests compatibility with standard network tools (nc, curl, etc.)
//! These tests require external tools and may be skipped in CI.
//!
//! ## Status
//!
//! These tests are currently skipped pending TcpStream/TcpListener implementation.
//! They will be enabled once the networking layer is complete.

const std = @import("std");
const testing = std.testing;
const blitz_io = @import("blitz-io");

// Note: These tests interact with external processes and the network.
// They should be run separately from unit tests and may have environmental
// dependencies.

test "TCP interop - connect to external HTTP server" {
    // Test connecting to a known HTTP server
    // This test requires network access and may fail in isolated environments
    //
    // When implemented, this will:
    // 1. Connect to httpbin.org:80
    // 2. Send a simple HTTP GET request
    // 3. Verify we receive an HTTP response
    //
    // Example implementation:
    // const stream = try blitz_io.TcpStream.connect(
    //     try blitz_io.Address.parse("httpbin.org:80")
    // );
    // defer stream.close();
    // try stream.writeAll("GET / HTTP/1.0\r\nHost: httpbin.org\r\n\r\n");
    // var buf: [1024]u8 = undefined;
    // const n = try stream.read(&buf);
    // try testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1."));

    return error.SkipZigTest; // Pending TcpStream.connect implementation
}

test "TCP interop - listen and accept from nc" {
    // Test that our listener works with netcat
    // Run: echo "hello" | nc localhost <port>
    //
    // When implemented, this will:
    // 1. Start a TcpListener on a random port
    // 2. Spawn nc to connect and send data
    // 3. Verify we receive the data correctly
    //
    // This would use std.process to spawn nc for automation

    return error.SkipZigTest; // Pending TcpListener implementation
}

test "TCP interop - echo server roundtrip" {
    // Start our echo server, connect with nc, verify response
    //
    // When implemented, this will:
    // 1. Start the echo server from examples/echo_server.zig
    // 2. Connect with nc and send test data
    // 3. Verify the echoed response matches

    return error.SkipZigTest; // Pending examples/echo_server.zig integration
}
