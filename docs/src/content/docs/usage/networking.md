---
title: Networking
description: TCP, UDP, and Unix domain socket networking with blitz-io.
---

The `net` module provides production-grade networking with non-blocking I/O, async futures, and full socket option control.

## Socket types

| Type | Description |
|------|-------------|
| `TcpListener` | Accept incoming TCP connections |
| `TcpStream` | Bidirectional TCP connection |
| `TcpSocket` | Socket builder for pre-connection configuration |
| `UdpSocket` | Connectionless datagram socket |
| `UnixStream` | Unix domain stream socket |
| `UnixListener` | Unix domain socket listener |
| `UnixDatagram` | Unix domain datagram socket |
| `Address` | IPv4/IPv6 socket address |

## TCP server

### Quick start with convenience functions

```zig
const io = @import("blitz-io");

// Bind to an address string
var listener = try io.net.listen("0.0.0.0:8080");
defer listener.close();

// Or bind to a port on all interfaces
var listener2 = try io.net.listenPort(8080);
defer listener2.close();
```

### Accept loop

`tryAccept` returns an `AcceptResult` containing the new stream and the peer address:

```zig
while (true) {
    if (try listener.tryAccept()) |result| {
        var stream = result.stream;
        const peer = result.peer_addr;
        // Handle connection...
        handleClient(&stream, peer);
    }
}
```

### Async accept

`accept()` returns an `AcceptFuture` for scheduler integration:

```zig
var future = listener.accept();
// Poll through your runtime...
// When ready, result contains the stream and peer address.
```

## TCP client

### Quick connect

```zig
var stream = try io.net.connect("127.0.0.1:8080");
defer stream.close();
```

### Connect with DNS resolution

```zig
var stream = try io.net.connectHost(allocator, "example.com", 443);
defer stream.close();
```

### Custom socket options

Use `TcpSocket` as a builder to configure options before connecting:

```zig
var socket = try io.net.TcpSocket.newV4();

// Set buffer sizes
try socket.setRecvBufferSize(65536);
try socket.setSendBufferSize(65536);

// Enable TCP keepalive
try socket.setKeepalive(.{
    .time = io.time.Duration.fromSecs(60),
});

// Enable TCP_NODELAY (disable Nagle's algorithm)
try socket.setNodelay(true);

// Connect
var stream = try socket.connect(addr);
defer stream.close();
```

## TCP stream I/O

### Non-blocking read/write

```zig
var buf: [4096]u8 = undefined;

// tryRead returns ?usize -- null means WouldBlock
if (try stream.tryRead(&buf)) |n| {
    if (n == 0) {
        // Connection closed by peer
        return;
    }
    processData(buf[0..n]);
}

// tryWrite returns ?usize -- null means WouldBlock
if (try stream.tryWrite(response_data)) |n| {
    // n bytes were written
}

// writeAll blocks (retries) until all data is written
try stream.writeAll("HTTP/1.1 200 OK\r\n\r\nHello!");
```

### Async futures

```zig
// Read future
var read_future = stream.read(&buf);

// Write future
var write_future = stream.write(data);

// Write-all future
var write_all_future = stream.writeAllAsync(data);

// Readiness futures (wait for socket to be readable/writable)
var readable_future = stream.readable();
var writable_future = stream.writable();
```

### Peek

Read data without consuming it from the receive buffer:

```zig
if (try stream.tryPeek(&buf)) |n| {
    // Peeked n bytes, data is still in the buffer
}
```

### Shutdown

Shut down one or both directions of the connection:

```zig
try stream.shutdown(.write); // No more writes (sends FIN)
try stream.shutdown(.read);  // No more reads
try stream.shutdown(.both);  // Both directions
```

### Splitting a stream

Split a `TcpStream` into independent read and write halves for concurrent I/O:

```zig
// Borrowed split -- halves reference the original stream
const halves = stream.split();
var reader = halves.read_half;
var writer = halves.write_half;

// Owned split -- halves can be moved to different tasks
const owned = stream.intoSplit();
var owned_reader = owned.read_half;  // Can move to reader task
var owned_writer = owned.write_half; // Can move to writer task
```

## UDP

### One-to-many (sendTo/recvFrom)

```zig
var socket = try io.net.UdpSocket.bind(io.net.Address.fromPort(8080));
defer socket.close();

var buf: [1024]u8 = undefined;

// Receive from any sender
if (try socket.tryRecvFrom(&buf)) |result| {
    const data = buf[0..result.len];
    const sender = result.addr;

    // Echo back to sender
    _ = try socket.trySendTo(data, sender);
}
```

### One-to-one (connect + send/recv)

```zig
var socket = try io.net.UdpSocket.bind(io.net.Address.fromPort(0));
try socket.connect(server_addr);

_ = try socket.trySend("hello");
const n = try socket.tryRecv(&buf) orelse 0;
```

### Socket options

```zig
try socket.setBroadcast(true);
try socket.setMulticastLoop(true);
try socket.setMulticastTtl(2);
try socket.setTtl(64);

// Join a multicast group
try socket.joinMulticast(multicast_addr, interface_addr);
try socket.leaveMulticast(multicast_addr, interface_addr);
```

## Unix domain sockets

Unix sockets provide local inter-process communication, faster than TCP loopback.

### Stream (connection-oriented)

```zig
// Server
var listener = try io.net.UnixListener.bind("/tmp/myapp.sock");
defer listener.close();

if (try listener.tryAccept()) |result| {
    var stream = result.stream;
    defer stream.close();
    // Handle connection...
}

// Client
var stream = try io.net.UnixStream.connect("/tmp/myapp.sock");
defer stream.close();
try stream.writeAll("hello");
```

### Datagram (connectionless)

```zig
var sock = try io.net.UnixDatagram.bind("/tmp/myapp-dgram.sock");
defer sock.close();

_ = try sock.trySendTo("message", "/tmp/other.sock");

var buf: [1024]u8 = undefined;
if (try sock.tryRecvFrom(&buf)) |result| {
    processMessage(buf[0..result.len]);
}
```

## DNS resolution

DNS lookups are blocking operations. Use them from the blocking pool in production:

```zig
// Resolve all addresses
var result = try io.net.resolve(allocator, "example.com", 443);
defer result.deinit();

for (result.addresses) |addr| {
    // Try connecting to each address
}

// Resolve first address only
const addr = try io.net.resolveFirst(allocator, "example.com", 443);
var stream = try io.net.TcpStream.connect(addr);
```

## Address

The `Address` type wraps `sockaddr_storage` and supports both IPv4 and IPv6:

```zig
// Parse from string
const addr = try io.net.Address.parse("127.0.0.1:8080");

// From port only (binds to 0.0.0.0)
const addr2 = io.net.Address.fromPort(8080);

// Get components
const port = addr.port();
const family = addr.family(); // AF.INET or AF.INET6
```

## Async server pattern

A complete async TCP server skeleton:

```zig
const io = @import("blitz-io");

pub fn main() !void {
    try io.run(server);
}

fn server() void {
    var listener = io.net.listen("0.0.0.0:8080") catch return;
    defer listener.close();

    while (true) {
        if (listener.tryAccept() catch null) |result| {
            _ = io.task.spawn(handleClient, .{result.stream}) catch continue;
        }
    }
}

fn handleClient(conn: io.net.TcpStream) void {
    var stream = conn;
    defer stream.close();

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = stream.tryRead(&buf) catch return orelse continue;
        if (n == 0) return; // Client disconnected
        stream.writeAll(buf[0..n]) catch return;
    }
}
```
