//! Robustness tests for Address parsing
//!
//! Tests edge cases and malformed input handling.

const std = @import("std");
const testing = std.testing;
const blitz_io = @import("blitz-io");
const Address = blitz_io.Address;

test "Address robustness - valid IPv4 addresses" {
    // Standard addresses
    _ = try Address.parse("127.0.0.1:8080");
    _ = try Address.parse("0.0.0.0:80");
    _ = try Address.parse("255.255.255.255:65535");
    _ = try Address.parse("192.168.1.1:443");
}

test "Address robustness - valid IPv6 addresses" {
    _ = try Address.parse("[::1]:8080");
    _ = try Address.parse("[::]:80");
    _ = try Address.parse("[2001:db8::1]:443");
}

test "Address robustness - invalid addresses should error" {
    // Missing port
    try testing.expectError(error.InvalidAddress, Address.parse("127.0.0.1"));

    // Invalid port (empty)
    try testing.expectError(error.InvalidPort, Address.parse("127.0.0.1:"));

    // Invalid port (non-numeric)
    try testing.expectError(error.InvalidPort, Address.parse("127.0.0.1:abc"));

    // Invalid port (overflow)
    try testing.expectError(error.InvalidPort, Address.parse("127.0.0.1:99999"));

    // Invalid IPv4
    try testing.expectError(error.InvalidAddress, Address.parse("256.0.0.1:80"));
    try testing.expectError(error.InvalidAddress, Address.parse("1.2.3:80"));
    try testing.expectError(error.InvalidAddress, Address.parse("1.2.3.4.5:80"));

    // Invalid IPv6
    try testing.expectError(error.InvalidAddress, Address.parse("[::1:8080")); // Missing ]
}

test "Address robustness - edge cases" {
    // Empty string
    try testing.expectError(error.InvalidAddress, Address.parse(""));

    // Just colon - port part is empty after colon
    try testing.expectError(error.InvalidPort, Address.parse(":"));

    // Just port (no host) - host part is empty before colon
    try testing.expectError(error.InvalidAddress, Address.parse(":8080"));
}

test "Address robustness - port boundaries" {
    // Port 0 (valid, means OS assigns)
    _ = try Address.parse("127.0.0.1:0");

    // Port 1 (lowest usable)
    _ = try Address.parse("127.0.0.1:1");

    // Port 65535 (max)
    _ = try Address.parse("127.0.0.1:65535");

    // Port 65536 (overflow)
    try testing.expectError(error.InvalidPort, Address.parse("127.0.0.1:65536"));
}

test "Address robustness - utility methods" {
    const loopback = try Address.parse("127.0.0.1:8080");
    try testing.expect(loopback.isLoopback());

    const any = Address.fromPort(8080);
    try testing.expect(any.isUnspecified());

    const private = try Address.parse("192.168.1.1:80");
    try testing.expect(private.isPrivate());
}
