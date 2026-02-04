//! # Networking Module
//!
//! High-performance async networking for TCP, UDP, and Unix sockets.
//!
//! ## TCP Server (Simplest Form)
//!
//! ```zig
//! const io = @import("blitz-io");
//!
//! var listener = try io.listen("0.0.0.0:8080");
//! defer listener.close();
//!
//! while (listener.tryAccept() catch null) |result| {
//!     handleClient(result.stream);
//! }
//!
//! fn handleClient(conn: io.TcpStream) void {
//!     var stream = conn;
//!     defer stream.close();
//!     var buf: [4096]u8 = undefined;
//!     const n = stream.tryRead(&buf) catch return orelse return;
//!     stream.writeAll(buf[0..n]) catch {};
//! }
//! ```
//!
//! ## TCP Client (Simplest Form)
//!
//! ```zig
//! var stream = try io.connect("127.0.0.1:8080");
//! defer stream.close();
//!
//! try stream.writeAll("GET / HTTP/1.0\r\n\r\n");
//!
//! var buf: [4096]u8 = undefined;
//! while (stream.tryRead(&buf) catch null) |n| {
//!     if (n == 0) break;
//!     std.debug.print("{s}", .{buf[0..n]});
//! }
//! ```
//!
//! ## TcpSocket Builder (Advanced Configuration)
//!
//! Configure socket options before connecting:
//!
//! ```zig
//! var socket = try io.TcpSocket.newV4();
//!
//! // Performance tuning
//! try socket.setSendBufferSize(65536);
//! try socket.setRecvBufferSize(65536);
//!
//! // Keepalive for long connections
//! try socket.setKeepalive(.{
//!     .time = io.Duration.fromSecs(60),
//!     .interval = io.Duration.fromSecs(10),
//!     .retries = 5,
//! });
//!
//! // Connect with configured socket
//! var stream = try socket.connect(io.Address.parse("127.0.0.1:8080"));
//! ```
//!
//! ## Stream Splitting for Concurrent Read/Write
//!
//! Split a stream into read and write halves for concurrent access:
//!
//! ```zig
//! // Borrowed halves (tied to stream lifetime)
//! var halves = stream.split();
//! // Use halves.read and halves.write from different tasks
//!
//! // Owned halves (can be moved to different tasks)
//! var owned = stream.intoSplit();
//! // owned.read and owned.write are independent
//! // Reunite later: var stream = try owned.read.reunite(owned.write);
//! ```
//!
//! ## UDP Sockets
//!
//! ```zig
//! var socket = try io.UdpSocket.bind(io.Address.fromPort(5000));
//! defer socket.close();
//!
//! // Send/receive with addresses
//! const recv_result = socket.tryRecvFrom(&buf) orelse continue;
//! try socket.sendTo(response, recv_result.addr);
//!
//! // Connected UDP (for single peer)
//! try socket.connect(peer_addr);
//! try socket.send(data);
//! const n = socket.tryRecv(&buf) orelse continue;
//! ```
//!
//! ## DNS Resolution
//!
//! ```zig
//! // Resolve hostname to addresses
//! var result = try io.resolve(allocator, "example.com", 80);
//! defer result.deinit();
//! for (result.addresses) |addr| {
//!     std.debug.print("Address: {s}\n", .{addr});
//! }
//!
//! // Or get first address directly
//! const addr = try io.resolveFirst(allocator, "example.com", 80);
//! var stream = try io.TcpStream.connect(addr);
//!
//! // Convenience: connect with hostname
//! var stream = try io.connectHost(allocator, "example.com", 80);
//! ```
//!
//! ## Unix Domain Sockets
//!
//! ```zig
//! // Server
//! var listener = try io.net.UnixListener.bind("/tmp/my.sock");
//! defer listener.close();
//!
//! // Client
//! var stream = try io.net.UnixStream.connect("/tmp/my.sock");
//! defer stream.close();
//! ```
//!
//! ## Address Parsing
//!
//! ```zig
//! const addr1 = try io.Address.parse("127.0.0.1:8080");    // IPv4
//! const addr2 = try io.Address.parse("[::1]:8080");        // IPv6
//! const addr3 = io.Address.fromPort(8080);                  // 0.0.0.0:8080
//! const addr4 = io.Address.initIpv4(.{192, 168, 1, 1}, 443);
//! ```

// Submodules
pub const address = @import("net/address.zig");
pub const tcp = @import("net/tcp.zig");
pub const udp = @import("net/udp.zig");
pub const unix = @import("net/unix.zig");

// Re-export commonly used types
pub const Address = address.Address;

// ═══════════════════════════════════════════════════════════════════════════
// Convenience Functions
// ═══════════════════════════════════════════════════════════════════════════

/// Create a TCP listener bound to the given address.
///
/// This is a convenience wrapper around `TcpListener.bind()`.
///
/// ## Examples
///
/// ```zig
/// // Listen on all interfaces, port 8080
/// var listener = try net.listen("0.0.0.0:8080");
///
/// // Listen on localhost only
/// var listener = try net.listen("127.0.0.1:3000");
///
/// // Listen on IPv6
/// var listener = try net.listen("[::]:8080");
/// ```
pub fn listen(addr_str: []const u8) !TcpListener {
    const addr = try Address.parse(addr_str);
    return TcpListener.bind(addr);
}

/// Create a TCP listener bound to a port on all interfaces (0.0.0.0).
///
/// ## Example
///
/// ```zig
/// var listener = try net.listenPort(8080);
/// ```
pub fn listenPort(port: u16) !TcpListener {
    return TcpListener.bind(Address.fromPort(port));
}

/// Connect to a TCP server at the given address.
///
/// This is a convenience wrapper around `TcpStream.connect()`.
///
/// ## Examples
///
/// ```zig
/// // Connect to a server
/// var stream = try net.connect("127.0.0.1:8080");
///
/// // Connect to a remote server
/// var stream = try net.connect("example.com:80");  // Note: requires DNS resolution
/// ```
pub fn connect(addr_str: []const u8) !TcpStream {
    const addr = try Address.parse(addr_str);
    return TcpStream.connect(addr);
}

// ═══════════════════════════════════════════════════════════════════════════
// DNS Resolution
// ═══════════════════════════════════════════════════════════════════════════

const std = @import("std");

/// DNS lookup result.
pub const LookupResult = struct {
    addresses: []Address,
    allocator: std.mem.Allocator,

    /// Free the lookup result.
    pub fn deinit(self: *LookupResult) void {
        self.allocator.free(self.addresses);
    }
};

/// Resolve a hostname to IP addresses.
///
/// Uses the system resolver (getaddrinfo). This is a blocking call.
/// For async DNS resolution, use the runtime's blocking pool.
///
/// ## Example
///
/// ```zig
/// var result = try net.resolve(allocator, "example.com", 80);
/// defer result.deinit();
///
/// for (result.addresses) |addr| {
///     std.debug.print("Address: {}\n", .{addr});
/// }
/// ```
pub fn resolve(allocator: std.mem.Allocator, host: []const u8, port: u16) !LookupResult {
    const list = try std.net.getAddressList(allocator, host, port);
    defer list.deinit();

    var addresses = try allocator.alloc(Address, list.addrs.len);
    errdefer allocator.free(addresses);

    for (list.addrs, 0..) |addr, i| {
        addresses[i] = Address.fromStd(addr);
    }

    return .{
        .addresses = addresses,
        .allocator = allocator,
    };
}

/// Resolve a hostname and return the first address.
///
/// Convenience wrapper around `resolve()` when you just need one address.
///
/// ## Example
///
/// ```zig
/// const addr = try net.resolveFirst(allocator, "example.com", 80);
/// var stream = try net.TcpStream.connect(addr);
/// ```
pub fn resolveFirst(allocator: std.mem.Allocator, host: []const u8, port: u16) !Address {
    var result = try resolve(allocator, host, port);
    defer result.deinit();

    if (result.addresses.len == 0) {
        return error.HostNotFound;
    }

    return result.addresses[0];
}

/// Connect to a hostname (with DNS resolution).
///
/// Resolves the hostname and connects to the first address.
/// This is a blocking call due to DNS resolution.
///
/// ## Example
///
/// ```zig
/// var stream = try net.connectHost(allocator, "example.com", 80);
/// defer stream.close();
/// ```
pub fn connectHost(allocator: std.mem.Allocator, host: []const u8, port: u16) !TcpStream {
    const addr = try resolveFirst(allocator, host, port);
    return TcpStream.connect(addr);
}

// ═══════════════════════════════════════════════════════════════════════════
// Unix Domain Sockets
// ═══════════════════════════════════════════════════════════════════════════

/// Unix domain stream socket (connection-oriented).
pub const UnixStream = unix.UnixStream;

/// Unix domain socket listener (for stream connections).
pub const UnixListener = unix.UnixListener;

/// Unix domain datagram socket (connectionless).
pub const UnixDatagram = unix.UnixDatagram;

/// Unix socket address (filesystem path).
pub const UnixAddr = unix.UnixAddr;

/// Result from accepting a Unix connection.
pub const UnixAcceptResult = unix.AcceptResult;

/// Result from receiving a Unix datagram.
pub const UnixRecvFromResult = unix.RecvFromResult;

// ═══════════════════════════════════════════════════════════════════════════
// TCP
// ═══════════════════════════════════════════════════════════════════════════

/// TCP socket builder. Configure options before connect/listen.
/// Use `newV4()` or `newV6()` to create, then set options, then `connect()` or `listen()`.
pub const TcpSocket = tcp.TcpSocket;

/// TCP server listener. Use `bind()` to create, then `tryAccept()` for connections.
pub const TcpListener = tcp.TcpListener;

/// TCP stream (connected socket). Use `tryRead`/`tryWrite`/`writeAll` for I/O.
pub const TcpStream = tcp.TcpStream;

/// TCP keepalive configuration: time, interval, retries.
pub const Keepalive = tcp.Keepalive;

/// Result from accepting a TCP connection: stream + peer address.
pub const AcceptResult = tcp.AcceptResult;

/// Shutdown direction: read, write, or both.
pub const ShutdownHow = tcp.ShutdownHow;

// ═══════════════════════════════════════════════════════════════════════════
// TCP Split Halves (Concurrent Read/Write)
// ═══════════════════════════════════════════════════════════════════════════

/// Borrowed read half of a split TcpStream. Lifetime tied to stream.
pub const ReadHalf = tcp.ReadHalf;

/// Borrowed write half of a split TcpStream. Lifetime tied to stream.
pub const WriteHalf = tcp.WriteHalf;

/// Owned read half. Can be moved to different tasks. Use `reunite()` to reconstruct stream.
pub const OwnedReadHalf = tcp.OwnedReadHalf;

/// Owned write half. Can be moved to different tasks. Use `reunite()` to reconstruct stream.
pub const OwnedWriteHalf = tcp.OwnedWriteHalf;

// ═══════════════════════════════════════════════════════════════════════════
// UDP
// ═══════════════════════════════════════════════════════════════════════════

/// UDP socket for connectionless datagram communication.
/// Use `sendTo`/`recvFrom` for multi-peer, or `connect`+`send`/`recv` for single peer.
pub const UdpSocket = udp.UdpSocket;

/// Result from receiving a UDP datagram: bytes read + sender address.
pub const RecvFromResult = udp.UdpSocket.RecvFromResult;

// ═══════════════════════════════════════════════════════════════════════════
// Internal Types (for advanced use)
// ═══════════════════════════════════════════════════════════════════════════

/// Future types for async operations.
///
/// These are implementation details for the async runtime integration.
/// Most users won't need to interact with these directly - use the
/// tryX() methods for non-blocking I/O or the runtime's await for async.
pub const futures = struct {
    // TCP futures
    pub const AcceptFuture = tcp.AcceptFuture;
    pub const ReadFuture = tcp.ReadFuture;
    pub const WriteFuture = tcp.WriteFuture;
    pub const WriteAllFuture = tcp.WriteAllFuture;
    pub const ReadableFuture = tcp.ReadableFuture;
    pub const WritableFuture = tcp.WritableFuture;
    pub const ReadyFuture = tcp.ReadyFuture;
    pub const PeekFuture = tcp.PeekFuture;

    // Owned half futures
    pub const OwnedReadFuture = tcp.OwnedReadFuture;
    pub const OwnedWriteFuture = tcp.OwnedWriteFuture;
    pub const OwnedWriteAllFuture = tcp.OwnedWriteAllFuture;
    pub const OwnedReadableFuture = tcp.OwnedReadableFuture;
    pub const OwnedWritableFuture = tcp.OwnedWritableFuture;
    pub const OwnedReadyFuture = tcp.OwnedReadyFuture;

    // UDP futures
    pub const UdpReadableFuture = udp.ReadableFuture;
    pub const UdpWritableFuture = udp.WritableFuture;
    pub const UdpReadyFuture = udp.ReadyFuture;
    pub const SendFuture = udp.SendFuture;
    pub const RecvFuture = udp.RecvFuture;
    pub const SendToFuture = udp.SendToFuture;
    pub const RecvFromFuture = udp.RecvFromFuture;
    pub const UdpPeekFuture = udp.PeekFuture;
};

/// Polling result types for future implementations.
pub const PollResult = tcp.PollResult;
pub const UdpPollResult = udp.PollResult;

test {
    _ = address;
    _ = tcp;
    _ = udp;
    _ = unix;
}
