//! TCP Integration Tests
//!
//! Tests realistic TCP server scenarios including:
//! - Echo server patterns
//! - Concurrent client handling
//! - Connection lifecycle
//! - Graceful shutdown
//!
//! These tests use threads to simulate concurrent server/client interactions.

const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const Thread = std.Thread;

const tcp = @import("blitz-io").net.tcp;
const TcpSocket = tcp.TcpSocket;
const TcpListener = tcp.TcpListener;
const TcpStream = tcp.TcpStream;
const Address = @import("blitz-io").net.Address;

// ═══════════════════════════════════════════════════════════════════════════════
// Echo Server Tests
// ═══════════════════════════════════════════════════════════════════════════════

test "TCP integration - echo server single client" {
    // Start echo server in background thread
    var server_ready = std.atomic.Value(bool).init(false);
    var server_port = std.atomic.Value(u16).init(0);
    var server_error: ?anyerror = null;

    const server_thread = try Thread.spawn(.{}, struct {
        fn run(ready: *std.atomic.Value(bool), port_out: *std.atomic.Value(u16), err_out: *?anyerror) void {
            runEchoServer(ready, port_out, 1) catch |e| {
                err_out.* = e;
            };
        }
    }.run, .{ &server_ready, &server_port, &server_error });

    // Wait for server to be ready
    while (!server_ready.load(.acquire)) {
        Thread.sleep(1 * std.time.ns_per_ms);
    }

    if (server_error) |err| {
        server_thread.join();
        return err;
    }

    const port = server_port.load(.acquire);
    defer server_thread.join();

    // Connect client
    var client = try TcpStream.connect(Address.loopbackV4(port));
    defer client.close();

    // Send and receive
    const message = "Hello, Echo Server!";
    try client.writeAll(message);

    var buf: [64]u8 = undefined;
    var total: usize = 0;
    for (0..100) |_| {
        if (try client.tryRead(buf[total..])) |n| {
            if (n == 0) break;
            total += n;
            if (total >= message.len) break;
        }
        Thread.sleep(10 * std.time.ns_per_ms);
    }

    try testing.expectEqualStrings(message, buf[0..total]);
}

test "TCP integration - echo server concurrent clients" {
    const NUM_CLIENTS = 50; // Test with 50 concurrent clients

    var server_ready = std.atomic.Value(bool).init(false);
    var server_port = std.atomic.Value(u16).init(0);
    var server_error: ?anyerror = null;

    const server_thread = try Thread.spawn(.{}, struct {
        fn run(ready: *std.atomic.Value(bool), port_out: *std.atomic.Value(u16), err_out: *?anyerror) void {
            runEchoServer(ready, port_out, NUM_CLIENTS) catch |e| {
                err_out.* = e;
            };
        }
    }.run, .{ &server_ready, &server_port, &server_error });

    // Wait for server to be ready
    while (!server_ready.load(.acquire)) {
        Thread.sleep(1 * std.time.ns_per_ms);
    }

    if (server_error) |err| {
        server_thread.join();
        return err;
    }

    const port = server_port.load(.acquire);

    // Spawn client threads
    var client_threads: [NUM_CLIENTS]Thread = undefined;
    var client_errors: [NUM_CLIENTS]?anyerror = [_]?anyerror{null} ** NUM_CLIENTS;

    for (0..NUM_CLIENTS) |i| {
        client_threads[i] = try Thread.spawn(.{}, struct {
            fn run(p: u16, id: usize, err_out: *?anyerror) void {
                runEchoClient(p, id) catch |e| {
                    err_out.* = e;
                };
            }
        }.run, .{ port, i, &client_errors[i] });
    }

    // Wait for all clients
    for (&client_threads) |*t| {
        t.join();
    }

    // Wait for server
    server_thread.join();

    // Check for errors
    for (client_errors, 0..) |err, i| {
        if (err) |e| {
            std.debug.print("Client {} error: {}\n", .{ i, e });
            return e;
        }
    }
}

test "TCP integration - client disconnect handling" {
    var server_ready = std.atomic.Value(bool).init(false);
    var server_port = std.atomic.Value(u16).init(0);
    var server_saw_eof = std.atomic.Value(bool).init(false);

    const server_thread = try Thread.spawn(.{}, struct {
        fn run(ready: *std.atomic.Value(bool), port_out: *std.atomic.Value(u16), saw_eof: *std.atomic.Value(bool)) void {
            var listener = TcpListener.bind(Address.fromPort(0)) catch return;
            defer listener.close();

            port_out.store(listener.localAddr().port(), .release);
            ready.store(true, .release);

            // Accept one client
            var conn: ?TcpStream = null;
            for (0..100) |_| {
                if (listener.tryAccept() catch null) |result| {
                    conn = result.stream;
                    break;
                }
                Thread.sleep(10 * std.time.ns_per_ms);
            }

            if (conn) |*c| {
                defer c.close();

                // Read until EOF
                var buf: [64]u8 = undefined;
                var got_data = false;
                for (0..200) |_| {
                    if (c.tryRead(&buf) catch null) |n| {
                        if (n == 0) {
                            // EOF - client closed connection
                            if (got_data) {
                                saw_eof.store(true, .release);
                            }
                            break;
                        }
                        got_data = true;
                        // Continue reading to drain any remaining data
                    }
                    Thread.sleep(10 * std.time.ns_per_ms);
                }
            }
        }
    }.run, .{ &server_ready, &server_port, &server_saw_eof });

    // Wait for server
    while (!server_ready.load(.acquire)) {
        Thread.sleep(1 * std.time.ns_per_ms);
    }

    const port = server_port.load(.acquire);

    // Connect, send data, then close
    {
        var client = try TcpStream.connect(Address.loopbackV4(port));
        defer client.close();  // Explicit close when scope ends
        try client.writeAll("goodbye");
    }

    server_thread.join();

    try testing.expect(server_saw_eof.load(.acquire));
}

test "TCP integration - server shutdown with active client" {
    var server_ready = std.atomic.Value(bool).init(false);
    var server_port = std.atomic.Value(u16).init(0);
    var shutdown_signal = std.atomic.Value(bool).init(false);

    const server_thread = try Thread.spawn(.{}, struct {
        fn run(ready: *std.atomic.Value(bool), port_out: *std.atomic.Value(u16), shutdown: *std.atomic.Value(bool)) void {
            var listener = TcpListener.bind(Address.fromPort(0)) catch return;
            defer listener.close();

            port_out.store(listener.localAddr().port(), .release);
            ready.store(true, .release);

            // Accept one client
            var conn: ?TcpStream = null;
            for (0..100) |_| {
                if (shutdown.load(.acquire)) break;
                if (listener.tryAccept() catch null) |result| {
                    conn = result.stream;
                    break;
                }
                Thread.sleep(10 * std.time.ns_per_ms);
            }

            if (conn) |*c| {
                defer c.close();

                // Keep connection alive until shutdown signal
                var buf: [64]u8 = undefined;
                while (!shutdown.load(.acquire)) {
                    _ = c.tryRead(&buf) catch break;
                    Thread.sleep(10 * std.time.ns_per_ms);
                }

                // Graceful shutdown - send FIN
                c.shutdown(.both) catch {};
            }
        }
    }.run, .{ &server_ready, &server_port, &shutdown_signal });

    // Wait for server
    while (!server_ready.load(.acquire)) {
        Thread.sleep(1 * std.time.ns_per_ms);
    }

    const port = server_port.load(.acquire);

    // Connect client
    var client = try TcpStream.connect(Address.loopbackV4(port));
    defer client.close();

    // Give server time to accept
    Thread.sleep(50 * std.time.ns_per_ms);

    // Signal shutdown
    shutdown_signal.store(true, .release);

    // Wait for server to shutdown
    server_thread.join();

    // Client should see connection closed
    var buf: [64]u8 = undefined;
    for (0..50) |_| {
        if (try client.tryRead(&buf)) |n| {
            // Either EOF (0) or error expected after shutdown
            try testing.expect(n == 0);
            break;
        }
        Thread.sleep(10 * std.time.ns_per_ms);
    }
}

test "TCP integration - HTTP-like request response" {
    var server_ready = std.atomic.Value(bool).init(false);
    var server_port = std.atomic.Value(u16).init(0);

    const server_thread = try Thread.spawn(.{}, struct {
        fn run(ready: *std.atomic.Value(bool), port_out: *std.atomic.Value(u16)) void {
            var listener = TcpListener.bind(Address.fromPort(0)) catch return;
            defer listener.close();

            port_out.store(listener.localAddr().port(), .release);
            ready.store(true, .release);

            // Accept one client
            var conn: ?TcpStream = null;
            for (0..100) |_| {
                if (listener.tryAccept() catch null) |result| {
                    conn = result.stream;
                    break;
                }
                Thread.sleep(10 * std.time.ns_per_ms);
            }

            if (conn) |*c| {
                defer c.close();

                // Read HTTP-like request (until \r\n\r\n)
                var buf: [1024]u8 = undefined;
                var total: usize = 0;
                for (0..100) |_| {
                    if (c.tryRead(buf[total..]) catch null) |n| {
                        if (n == 0) break;
                        total += n;
                        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |_| break;
                    }
                    Thread.sleep(10 * std.time.ns_per_ms);
                }

                // Send HTTP-like response
                const response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nHello";
                c.writeAll(response) catch {};
            }
        }
    }.run, .{ &server_ready, &server_port });

    // Wait for server
    while (!server_ready.load(.acquire)) {
        Thread.sleep(1 * std.time.ns_per_ms);
    }

    const port = server_port.load(.acquire);
    defer server_thread.join();

    // Send HTTP-like request
    var client = try TcpStream.connect(Address.loopbackV4(port));
    defer client.close();

    const request = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try client.writeAll(request);

    // Read response
    var buf: [256]u8 = undefined;
    var total: usize = 0;
    for (0..100) |_| {
        if (try client.tryRead(buf[total..])) |n| {
            if (n == 0) break;
            total += n;
            if (std.mem.endsWith(u8, buf[0..total], "Hello")) break;
        }
        Thread.sleep(10 * std.time.ns_per_ms);
    }

    try testing.expect(std.mem.startsWith(u8, buf[0..total], "HTTP/1.1 200 OK"));
    try testing.expect(std.mem.endsWith(u8, buf[0..total], "Hello"));
}

test "TCP integration - long-lived connection" {
    var server_ready = std.atomic.Value(bool).init(false);
    var server_port = std.atomic.Value(u16).init(0);
    var messages_received = std.atomic.Value(u32).init(0);

    const NUM_MESSAGES = 10;

    const server_thread = try Thread.spawn(.{}, struct {
        fn run(ready: *std.atomic.Value(bool), port_out: *std.atomic.Value(u16), msg_count: *std.atomic.Value(u32)) void {
            var listener = TcpListener.bind(Address.fromPort(0)) catch return;
            defer listener.close();

            port_out.store(listener.localAddr().port(), .release);
            ready.store(true, .release);

            var conn: ?TcpStream = null;
            for (0..100) |_| {
                if (listener.tryAccept() catch null) |result| {
                    conn = result.stream;
                    break;
                }
                Thread.sleep(10 * std.time.ns_per_ms);
            }

            if (conn) |*c| {
                defer c.close();

                // Echo messages back
                var buf: [64]u8 = undefined;
                for (0..NUM_MESSAGES * 100) |_| {
                    if (c.tryRead(&buf) catch null) |n| {
                        if (n == 0) break;
                        c.writeAll(buf[0..n]) catch break;
                        _ = msg_count.fetchAdd(1, .monotonic);
                    }
                    Thread.sleep(5 * std.time.ns_per_ms);
                    if (msg_count.load(.monotonic) >= NUM_MESSAGES) break;
                }
            }
        }
    }.run, .{ &server_ready, &server_port, &messages_received });

    // Wait for server
    while (!server_ready.load(.acquire)) {
        Thread.sleep(1 * std.time.ns_per_ms);
    }

    const port = server_port.load(.acquire);
    defer server_thread.join();

    // Connect and send multiple messages
    var client = try TcpStream.connect(Address.loopbackV4(port));
    defer client.close();

    for (0..NUM_MESSAGES) |i| {
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Message {}", .{i}) catch "Message";
        try client.writeAll(msg);

        // Wait for echo
        var recv_buf: [64]u8 = undefined;
        var total: usize = 0;
        for (0..50) |_| {
            if (try client.tryRead(recv_buf[total..])) |n| {
                if (n == 0) break;
                total += n;
                if (total >= msg.len) break;
            }
            Thread.sleep(10 * std.time.ns_per_ms);
        }

        try testing.expectEqualStrings(msg, recv_buf[0..total]);
    }

    try testing.expectEqual(@as(u32, NUM_MESSAGES), messages_received.load(.acquire));
}

test "TCP integration - half-close (shutdown write)" {
    var server_ready = std.atomic.Value(bool).init(false);
    var server_port = std.atomic.Value(u16).init(0);
    var server_received = std.atomic.Value(bool).init(false);

    const server_thread = try Thread.spawn(.{}, struct {
        fn run(ready: *std.atomic.Value(bool), port_out: *std.atomic.Value(u16), received: *std.atomic.Value(bool)) void {
            var listener = TcpListener.bind(Address.fromPort(0)) catch return;
            defer listener.close();

            port_out.store(listener.localAddr().port(), .release);
            ready.store(true, .release);

            var conn: ?TcpStream = null;
            for (0..100) |_| {
                if (listener.tryAccept() catch null) |result| {
                    conn = result.stream;
                    break;
                }
                Thread.sleep(10 * std.time.ns_per_ms);
            }

            if (conn) |*c| {
                defer c.close();

                // Read until EOF
                var buf: [256]u8 = undefined;
                var total: usize = 0;
                for (0..100) |_| {
                    if (c.tryRead(buf[total..]) catch null) |n| {
                        if (n == 0) {
                            // EOF received - client shutdown write
                            if (total > 0) received.store(true, .release);

                            // Send response after client's write shutdown
                            c.writeAll("Response after half-close") catch {};
                            break;
                        }
                        total += n;
                    }
                    Thread.sleep(10 * std.time.ns_per_ms);
                }
            }
        }
    }.run, .{ &server_ready, &server_port, &server_received });

    // Wait for server
    while (!server_ready.load(.acquire)) {
        Thread.sleep(1 * std.time.ns_per_ms);
    }

    const port = server_port.load(.acquire);
    defer server_thread.join();

    // Connect and send data
    var client = try TcpStream.connect(Address.loopbackV4(port));
    defer client.close();

    try client.writeAll("Data before shutdown");

    // Half-close: shutdown write but keep read open
    try client.shutdown(.write);

    // Should still be able to read
    var buf: [64]u8 = undefined;
    var total: usize = 0;
    for (0..100) |_| {
        if (try client.tryRead(buf[total..])) |n| {
            if (n == 0) break;
            total += n;
            if (std.mem.endsWith(u8, buf[0..total], "half-close")) break;
        }
        Thread.sleep(10 * std.time.ns_per_ms);
    }

    try testing.expect(server_received.load(.acquire));
    try testing.expectEqualStrings("Response after half-close", buf[0..total]);
}

test "TCP integration - large data transfer" {
    const DATA_SIZE: usize = 1024 * 1024; // 1MB

    var server_ready = std.atomic.Value(bool).init(false);
    var server_port = std.atomic.Value(u16).init(0);
    var bytes_received = std.atomic.Value(usize).init(0);

    const server_thread = try Thread.spawn(.{}, struct {
        fn run(ready: *std.atomic.Value(bool), port_out: *std.atomic.Value(u16), total_bytes: *std.atomic.Value(usize)) void {
            var listener = TcpListener.bind(Address.fromPort(0)) catch return;
            defer listener.close();

            port_out.store(listener.localAddr().port(), .release);
            ready.store(true, .release);

            var conn: ?TcpStream = null;
            for (0..100) |_| {
                if (listener.tryAccept() catch null) |result| {
                    conn = result.stream;
                    break;
                }
                Thread.sleep(10 * std.time.ns_per_ms);
            }

            if (conn) |*c| {
                defer c.close();

                // Read all data (sink it)
                var buf: [8192]u8 = undefined;
                var total: usize = 0;
                while (total < DATA_SIZE) {
                    if (c.tryRead(&buf) catch null) |n| {
                        if (n == 0) break;
                        total += n;
                    } else {
                        Thread.sleep(1 * std.time.ns_per_ms);
                    }
                }
                total_bytes.store(total, .release);
            }
        }
    }.run, .{ &server_ready, &server_port, &bytes_received });

    // Wait for server
    while (!server_ready.load(.acquire)) {
        Thread.sleep(1 * std.time.ns_per_ms);
    }

    const port = server_port.load(.acquire);
    defer server_thread.join();

    // Connect and send large data
    var client = try TcpStream.connect(Address.loopbackV4(port));

    // Allocate and fill buffer
    const data = try testing.allocator.alloc(u8, DATA_SIZE);
    defer testing.allocator.free(data);
    @memset(data, 'A');

    // Send all data
    var sent: usize = 0;
    while (sent < DATA_SIZE) {
        if (try client.tryWrite(data[sent..])) |n| {
            sent += n;
        } else {
            Thread.sleep(1 * std.time.ns_per_ms);
        }
    }

    // Close to signal EOF (no defer since we need to close before waiting for server)
    client.close();

    // Wait for server to finish
    for (0..500) |_| {
        if (bytes_received.load(.acquire) >= DATA_SIZE) break;
        Thread.sleep(10 * std.time.ns_per_ms);
    }

    try testing.expectEqual(DATA_SIZE, bytes_received.load(.acquire));
}

test "TCP integration - rapid connect disconnect" {
    var server_ready = std.atomic.Value(bool).init(false);
    var server_port = std.atomic.Value(u16).init(0);
    var connections_seen = std.atomic.Value(u32).init(0);

    const NUM_CONNECTIONS = 20;

    const server_thread = try Thread.spawn(.{}, struct {
        fn run(ready: *std.atomic.Value(bool), port_out: *std.atomic.Value(u16), conn_count: *std.atomic.Value(u32)) void {
            var listener = TcpListener.bind(Address.fromPort(0)) catch return;
            defer listener.close();

            port_out.store(listener.localAddr().port(), .release);
            ready.store(true, .release);

            // Accept connections until we've seen enough
            while (conn_count.load(.monotonic) < NUM_CONNECTIONS) {
                if (listener.tryAccept() catch null) |result| {
                    var c = result.stream;
                    _ = conn_count.fetchAdd(1, .monotonic);
                    c.close();
                }
                Thread.sleep(1 * std.time.ns_per_ms);
            }
        }
    }.run, .{ &server_ready, &server_port, &connections_seen });

    // Wait for server
    while (!server_ready.load(.acquire)) {
        Thread.sleep(1 * std.time.ns_per_ms);
    }

    const port = server_port.load(.acquire);
    defer server_thread.join();

    // Rapidly connect and disconnect
    for (0..NUM_CONNECTIONS) |_| {
        var client = try TcpStream.connect(Address.loopbackV4(port));
        client.close();
    }

    // Wait for server to see all connections
    for (0..100) |_| {
        if (connections_seen.load(.acquire) >= NUM_CONNECTIONS) break;
        Thread.sleep(10 * std.time.ns_per_ms);
    }

    try testing.expect(connections_seen.load(.acquire) >= NUM_CONNECTIONS);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Helper Functions
// ═══════════════════════════════════════════════════════════════════════════════

fn runEchoServer(ready: *std.atomic.Value(bool), port_out: *std.atomic.Value(u16), max_clients: usize) !void {
    var listener = try TcpListener.bind(Address.fromPort(0));
    defer listener.close();

    port_out.store(listener.localAddr().port(), .release);
    ready.store(true, .release);

    var clients_served: usize = 0;

    while (clients_served < max_clients) {
        if (try listener.tryAccept()) |result| {
            var conn = result.stream;
            defer conn.close();

            // Echo data
            var buf: [256]u8 = undefined;
            for (0..100) |_| {
                if (try conn.tryRead(&buf)) |n| {
                    if (n == 0) break;
                    try conn.writeAll(buf[0..n]);
                    break;
                }
                Thread.sleep(10 * std.time.ns_per_ms);
            }

            clients_served += 1;
        } else {
            Thread.sleep(10 * std.time.ns_per_ms);
        }
    }
}

fn runEchoClient(port: u16, id: usize) !void {
    var client = try TcpStream.connect(Address.loopbackV4(port));
    defer client.close();

    var msg_buf: [64]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "Client {} says hello", .{id});

    try client.writeAll(msg);

    var recv_buf: [64]u8 = undefined;
    var total: usize = 0;
    for (0..100) |_| {
        if (try client.tryRead(recv_buf[total..])) |n| {
            if (n == 0) break;
            total += n;
            if (total >= msg.len) break;
        }
        Thread.sleep(10 * std.time.ns_per_ms);
    }

    if (!std.mem.eql(u8, msg, recv_buf[0..total])) {
        return error.EchoMismatch;
    }
}
