//! TCP Networking - Production-Quality Implementation
//!
//! Provides Tokio-level TCP networking with:
//! - TcpSocket: Pre-connection socket configuration (buffer sizes, keepalive, etc.)
//! - TcpListener: Async server socket with ScheduledIo integration
//! - TcpStream: Async connection with readiness-based I/O
//! - Split halves: Concurrent read/write access
//!
//! ## Server Example
//!
//! ```zig
//! var listener = try TcpListener.bind(Address.fromPort(8080));
//! defer listener.close();
//!
//! while (true) {
//!     if (try listener.tryAccept()) |result| {
//!         // Handle result.stream with result.peer_addr
//!     }
//! }
//! ```
//!
//! ## Client with Options
//!
//! ```zig
//! var socket = try TcpSocket.newV4();
//! try socket.setRecvBufferSize(65536);
//! try socket.setKeepalive(.{ .time = Duration.fromSeconds(60) });
//!
//! var stream = try socket.connect(addr);
//! defer stream.close();
//! ```
//!
//! Reference: tokio/src/net/tcp/*.rs

const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const builtin = @import("builtin");

const Address = @import("address.zig").Address;
const ScheduledIo = @import("../backend/scheduled_io.zig").ScheduledIo;
const io = @import("../io.zig");
const Ready = @import("../backend/scheduled_io.zig").Ready;
const Interest = @import("../backend/scheduled_io.zig").Interest;
const Waker = @import("../backend/scheduled_io.zig").Waker;
const Duration = @import("../time.zig").Duration;
const runtime_mod = @import("../runtime.zig");
const IoDriver = @import("../io_driver.zig").IoDriver;

// ═══════════════════════════════════════════════════════════════════════════════
// TcpSocket - Pre-Connection Socket Builder
// ═══════════════════════════════════════════════════════════════════════════════

/// TCP socket builder for pre-connection configuration.
///
/// Configure socket options BEFORE connecting or binding. This matches Tokio's
/// TcpSocket which allows setting buffer sizes, keepalive, etc. before the
/// connection is established.
///
/// ## Example
///
/// ```zig
/// var socket = try TcpSocket.newV4();
/// try socket.setReuseAddr(true);
/// try socket.setRecvBufferSize(65536);
/// try socket.setKeepalive(.{ .time = Duration.fromSeconds(60) });
///
/// // Connect consumes the socket
/// var stream = try socket.connect(addr);
/// ```
pub const TcpSocket = struct {
    fd: posix.socket_t,

    // ═══════════════════════════════════════════════════════════════════════════
    // Construction
    // ═══════════════════════════════════════════════════════════════════════════

    /// Create a new IPv4 TCP socket.
    pub fn newV4() !TcpSocket {
        const fd = try posix.socket(
            posix.AF.INET,
            posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
            0,
        );
        return .{ .fd = fd };
    }

    /// Create a new IPv6 TCP socket.
    pub fn newV6() !TcpSocket {
        const fd = try posix.socket(
            posix.AF.INET6,
            posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
            0,
        );
        return .{ .fd = fd };
    }

    /// Create from raw file descriptor (takes ownership).
    pub fn fromRaw(fd: posix.socket_t) TcpSocket {
        return .{ .fd = fd };
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Socket Options (Before Connect/Bind)
    // ═══════════════════════════════════════════════════════════════════════════

    /// Set SO_REUSEADDR - allows binding to a recently used address.
    pub fn setReuseAddr(self: *TcpSocket, value: bool) !void {
        try setBoolOption(self.fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, value);
    }

    /// Get SO_REUSEADDR value.
    pub fn getReuseAddr(self: TcpSocket) !bool {
        return getBoolOption(self.fd, posix.SOL.SOCKET, posix.SO.REUSEADDR);
    }

    /// Set SO_REUSEPORT - allows multiple sockets to bind to the same port.
    /// Only available on Linux and BSD.
    pub fn setReusePort(self: *TcpSocket, value: bool) !void {
        if (comptime builtin.os.tag == .windows) {
            return error.NotSupported;
        }
        try setBoolOption(self.fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, value);
    }

    /// Get SO_REUSEPORT value.
    pub fn getReusePort(self: TcpSocket) !bool {
        if (comptime builtin.os.tag == .windows) {
            return error.NotSupported;
        }
        return getBoolOption(self.fd, posix.SOL.SOCKET, posix.SO.REUSEPORT);
    }

    /// Set send buffer size (SO_SNDBUF).
    /// Setting this before connect ensures proper TCP window scaling.
    pub fn setSendBufferSize(self: *TcpSocket, size: u32) !void {
        try setIntOption(self.fd, posix.SOL.SOCKET, posix.SO.SNDBUF, size);
    }

    /// Get send buffer size.
    pub fn getSendBufferSize(self: TcpSocket) !u32 {
        return getIntOption(self.fd, posix.SOL.SOCKET, posix.SO.SNDBUF);
    }

    /// Set receive buffer size (SO_RCVBUF).
    /// Setting this before connect ensures proper TCP window scaling.
    pub fn setRecvBufferSize(self: *TcpSocket, size: u32) !void {
        try setIntOption(self.fd, posix.SOL.SOCKET, posix.SO.RCVBUF, size);
    }

    /// Get receive buffer size.
    pub fn getRecvBufferSize(self: TcpSocket) !u32 {
        return getIntOption(self.fd, posix.SOL.SOCKET, posix.SO.RCVBUF);
    }

    /// Set TCP keepalive options.
    pub fn setKeepalive(self: *TcpSocket, keepalive: ?Keepalive) !void {
        if (keepalive) |ka| {
            // Enable keepalive
            try setBoolOption(self.fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, true);

            // Set idle time before probes start
            if (comptime builtin.os.tag == .linux) {
                try setIntOption(self.fd, posix.IPPROTO.TCP, std.posix.TCP.KEEPIDLE, @intCast(ka.time.asSeconds()));

                // Set probe interval (Linux only)
                if (ka.interval) |interval| {
                    try setIntOption(self.fd, posix.IPPROTO.TCP, std.posix.TCP.KEEPINTVL, @intCast(interval.asSeconds()));
                }

                // Set probe count (Linux only)
                if (ka.retries) |retries| {
                    try setIntOption(self.fd, posix.IPPROTO.TCP, std.posix.TCP.KEEPCNT, retries);
                }
            } else if (comptime builtin.os.tag == .macos or builtin.os.tag == .freebsd) {
                // macOS uses TCP_KEEPALIVE for the idle time
                try setIntOption(self.fd, posix.IPPROTO.TCP, std.posix.TCP.KEEPALIVE, @intCast(ka.time.asSeconds()));
            }
        } else {
            // Disable keepalive
            try setBoolOption(self.fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, false);
        }
    }

    /// Get keepalive settings.
    pub fn getKeepalive(self: TcpSocket) !?Keepalive {
        const enabled = try getBoolOption(self.fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE);
        if (!enabled) return null;

        var ka = Keepalive{ .time = Duration.fromSeconds(0) };

        if (comptime builtin.os.tag == .linux) {
            const idle = try getIntOption(self.fd, posix.IPPROTO.TCP, std.posix.TCP.KEEPIDLE);
            ka.time = Duration.fromSeconds(idle);

            const interval = try getIntOption(self.fd, posix.IPPROTO.TCP, std.posix.TCP.KEEPINTVL);
            ka.interval = Duration.fromSeconds(interval);

            const retries = try getIntOption(self.fd, posix.IPPROTO.TCP, std.posix.TCP.KEEPCNT);
            ka.retries = retries;
        } else if (comptime builtin.os.tag == .macos or builtin.os.tag == .freebsd) {
            const idle = try getIntOption(self.fd, posix.IPPROTO.TCP, std.posix.TCP.KEEPALIVE);
            ka.time = Duration.fromSeconds(idle);
        }

        return ka;
    }

    /// Set SO_LINGER - controls behavior on close().
    pub fn setLinger(self: *TcpSocket, duration: ?Duration) !void {
        const linger_val = posix.linger{
            .enabled = if (duration != null) 1 else 0,
            .seconds = if (duration) |d| @intCast(d.asSeconds()) else 0,
        };
        try posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.LINGER, mem.asBytes(&linger_val));
    }

    /// Get SO_LINGER value.
    pub fn getLinger(self: TcpSocket) !?Duration {
        var linger_val: posix.linger = undefined;
        var len: posix.socklen_t = @sizeOf(posix.linger);
        try posix.getsockopt(self.fd, posix.SOL.SOCKET, posix.SO.LINGER, mem.asBytes(&linger_val), &len);

        if (linger_val.enabled != 0) {
            return Duration.fromSeconds(linger_val.seconds);
        }
        return null;
    }

    /// Bind to a local address before connecting.
    /// Use this when you need to select the source address/port.
    pub fn bind(self: *TcpSocket, addr: Address) !void {
        try posix.bind(self.fd, addr.sockaddr(), addr.len);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Connection Methods (Consume Socket)
    // ═══════════════════════════════════════════════════════════════════════════

    /// Connect to a remote address, returning a TcpStream.
    /// This consumes the socket.
    pub fn connect(self: TcpSocket, addr: Address) !TcpStream {
        // Set non-blocking for async connect
        try setNonBlocking(self.fd, true);

        // Initiate connect
        posix.connect(self.fd, addr.sockaddr(), addr.len) catch |err| switch (err) {
            error.WouldBlock => {
                // Connection in progress - wait for completion
                try waitForConnect(self.fd);
            },
            else => {
                posix.close(self.fd);
                return err;
            },
        };

        return TcpStream{
            .fd = self.fd,
            .peer_addr = addr,
            .local_addr = null,
            .scheduled_io = null, // Will be set when registered with runtime
        };
    }

    /// Start listening on the bound address, returning a TcpListener.
    /// Must have called bind() first.
    pub fn listen(self: TcpSocket, backlog: u31) !TcpListener {
        // Set non-blocking
        try setNonBlocking(self.fd, true);

        // Get local address
        var local_addr: Address = undefined;
        local_addr.len = @sizeOf(posix.sockaddr.storage);
        try posix.getsockname(self.fd, local_addr.sockaddrMut(), &local_addr.len);

        // Start listening
        try posix.listen(self.fd, backlog);

        return TcpListener{
            .fd = self.fd,
            .local_addr = local_addr,
            .scheduled_io = null, // Will be set when registered with runtime
        };
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Low-Level Access
    // ═══════════════════════════════════════════════════════════════════════════

    /// Get local address after bind.
    pub fn localAddr(self: TcpSocket) !Address {
        var addr: Address = undefined;
        addr.len = @sizeOf(posix.sockaddr.storage);
        try posix.getsockname(self.fd, addr.sockaddrMut(), &addr.len);
        return addr;
    }

    /// Get underlying file descriptor.
    pub fn fileno(self: TcpSocket) posix.socket_t {
        return self.fd;
    }

    /// Close without converting to stream/listener.
    pub fn close(self: *TcpSocket) void {
        posix.close(self.fd);
        self.fd = -1;
    }
};

/// TCP keepalive configuration.
pub const Keepalive = struct {
    /// Idle time before keepalive probes start.
    time: Duration,
    /// Time between probes (Linux only).
    interval: ?Duration = null,
    /// Number of probes before connection is dropped (Linux only).
    retries: ?u32 = null,
};

// ═══════════════════════════════════════════════════════════════════════════════
// TcpListener - Server Socket
// ═══════════════════════════════════════════════════════════════════════════════

/// TCP listener for accepting incoming connections.
///
/// Uses ScheduledIo for readiness tracking when registered with the runtime.
///
/// ## Example
///
/// ```zig
/// var listener = try TcpListener.bind(Address.fromPort(8080));
/// defer listener.close();
///
/// while (true) {
///     if (try listener.tryAccept()) |result| {
///         // Handle result.stream, result.peer_addr
///     }
/// }
/// ```
pub const TcpListener = struct {
    fd: posix.socket_t,
    local_addr: Address,
    scheduled_io: ?*ScheduledIo,

    // ═══════════════════════════════════════════════════════════════════════════
    // Construction
    // ═══════════════════════════════════════════════════════════════════════════

    /// Bind and listen on an address with default backlog (128).
    pub fn bind(addr: Address) !TcpListener {
        return bindWithBacklog(addr, 128);
    }

    /// Bind and listen with a specific backlog.
    pub fn bindWithBacklog(addr: Address, backlog: u31) !TcpListener {
        // Create socket
        const family = addr.family();
        const fd = try posix.socket(
            family,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            0,
        );
        errdefer posix.close(fd);

        // Set SO_REUSEADDR
        try setBoolOption(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, true);

        // Bind
        try posix.bind(fd, addr.sockaddr(), addr.len);

        // Get actual bound address
        var local_addr: Address = undefined;
        local_addr.len = @sizeOf(posix.sockaddr.storage);
        try posix.getsockname(fd, local_addr.sockaddrMut(), &local_addr.len);

        // Listen
        try posix.listen(fd, backlog);

        return .{
            .fd = fd,
            .local_addr = local_addr,
            .scheduled_io = null,
        };
    }

    /// Create from a pre-configured TcpSocket.
    pub fn fromSocket(socket: TcpSocket, backlog: u31) !TcpListener {
        return socket.listen(backlog);
    }

    /// Create from a std.net.Server (takes ownership).
    /// Use this for interop with standard library code.
    pub fn fromStd(std_server: std.net.Server) TcpListener {
        var local_addr: Address = undefined;
        local_addr.len = @sizeOf(posix.sockaddr.storage);
        posix.getsockname(std_server.stream.handle, local_addr.sockaddrMut(), &local_addr.len) catch {
            local_addr = Address.fromPort(0);
        };

        return .{
            .fd = std_server.stream.handle,
            .local_addr = local_addr,
            .scheduled_io = null,
        };
    }

    /// Convert to std.net.Server.
    /// The underlying fd is transferred (this TcpListener becomes invalid).
    pub fn toStd(self: *TcpListener) std.net.Server {
        const fd = self.fd;
        self.fd = -1;
        return .{ .stream = .{ .handle = fd } };
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Accept Methods
    // ═══════════════════════════════════════════════════════════════════════════

    /// Non-blocking accept - returns null if no connection waiting.
    pub fn tryAccept(self: *TcpListener) !?AcceptResult {
        var peer_addr: Address = undefined;
        peer_addr.len = @sizeOf(posix.sockaddr.storage);

        const client_fd = posix.accept(
            self.fd,
            peer_addr.sockaddrMut(),
            &peer_addr.len,
            posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
        ) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };

        return .{
            .stream = .{
                .fd = client_fd,
                .peer_addr = peer_addr,
                .local_addr = null,
                .scheduled_io = null,
            },
            .peer_addr = peer_addr,
        };
    }

    /// Return a future for async accept.
    /// The future polls for readiness using ScheduledIo.
    pub fn accept(self: *TcpListener) AcceptFuture {
        return .{ .listener = self };
    }

    /// Return a future that resolves when the listener is readable.
    pub fn readable(self: *TcpListener) ReadableFuture {
        return .{ .fd = self.fd, .scheduled_io = self.scheduled_io };
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Configuration
    // ═══════════════════════════════════════════════════════════════════════════

    /// Get local address.
    pub fn localAddr(self: TcpListener) Address {
        return self.local_addr;
    }

    /// Get underlying file descriptor.
    pub fn fileno(self: TcpListener) posix.socket_t {
        return self.fd;
    }

    /// Set IP TTL.
    pub fn setTtl(self: *TcpListener, ttl: u8) !void {
        try setIntOption(self.fd, posix.IPPROTO.IP, posix.IP.TTL, ttl);
    }

    /// Get IP TTL.
    pub fn getTtl(self: TcpListener) !u8 {
        const val = try getIntOption(self.fd, posix.IPPROTO.IP, posix.IP.TTL);
        return @intCast(val);
    }

    /// Close the listener.
    pub fn close(self: *TcpListener) void {
        if (self.scheduled_io) |sio| {
            sio.shutdown();
        }
        posix.close(self.fd);
        self.fd = -1;
    }

    /// Register with ScheduledIo for async operations.
    pub fn register(self: *TcpListener, sio: *ScheduledIo) void {
        self.scheduled_io = sio;
    }
};

/// Result of a successful accept.
///
/// Contains both the connected stream and the peer's address.
/// Use `intoStream()` if you only need the stream.
///
/// ## Example
///
/// ```zig
/// if (try listener.tryAccept()) |result| {
///     // Access both
///     log.info("Connection from {}", .{result.peer_addr});
///     handleClient(result.stream);
///
///     // Or just get the stream
///     const stream = result.intoStream();
/// }
/// ```
pub const AcceptResult = struct {
    stream: TcpStream,
    peer_addr: Address,

    /// Get just the stream, discarding the peer address.
    /// Use this when you don't need the peer address.
    pub fn intoStream(self: AcceptResult) TcpStream {
        return self.stream;
    }

    /// Get the peer address as a formatted string.
    /// Useful for logging.
    pub fn peerAddrString(self: AcceptResult, buf: []u8) []u8 {
        return self.peer_addr.format(buf);
    }
};

/// Future for async accept.
pub const AcceptFuture = struct {
    listener: *TcpListener,

    /// Poll for a new connection.
    pub fn poll(self: *AcceptFuture, waker: Waker) PollResult(AcceptResult) {
        // Try non-blocking accept
        if (self.listener.tryAccept()) |result| {
            return .{ .ready = result };
        } else |err| {
            if (err == error.WouldBlock) {
                // Register for readiness notification
                if (self.listener.scheduled_io) |sio| {
                    sio.setReaderWaker(waker);
                }
                return .pending;
            }
            return .{ .err = err };
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TcpStream - Connected Socket
// ═══════════════════════════════════════════════════════════════════════════════

/// A connected TCP stream with async read/write.
///
/// Provides both non-blocking try* methods and async futures for I/O.
///
/// ## Example
///
/// ```zig
/// var stream = try TcpStream.connect(addr);
/// defer stream.close();
///
/// // Non-blocking
/// if (try stream.tryWrite("Hello")) |n| {
///     // Wrote n bytes
/// }
///
/// // Or with futures (when runtime is available)
/// const future = stream.write("Hello");
/// ```
pub const TcpStream = struct {
    fd: posix.socket_t,
    peer_addr: Address,
    local_addr: ?Address,
    scheduled_io: ?*ScheduledIo,

    // ═══════════════════════════════════════════════════════════════════════════
    // Construction
    // ═══════════════════════════════════════════════════════════════════════════

    /// Connect to a remote address.
    pub fn connect(addr: Address) !TcpStream {
        var socket = if (addr.isIpv6())
            try TcpSocket.newV6()
        else
            try TcpSocket.newV4();

        return socket.connect(addr);
    }

    /// Create from a TcpSocket (consumes the socket).
    pub fn fromSocket(socket: TcpSocket, addr: Address) !TcpStream {
        return socket.connect(addr);
    }

    /// Create from a std.net.Stream (takes ownership).
    /// Use this for interop with standard library code.
    pub fn fromStd(std_stream: std.net.Stream) TcpStream {
        // Get peer address
        var peer_addr: Address = undefined;
        peer_addr.len = @sizeOf(posix.sockaddr.storage);
        posix.getpeername(std_stream.handle, peer_addr.sockaddrMut(), &peer_addr.len) catch {
            peer_addr = Address.fromPort(0);
        };

        return .{
            .fd = std_stream.handle,
            .peer_addr = peer_addr,
            .local_addr = null,
            .scheduled_io = null,
        };
    }

    /// Convert to std.net.Stream.
    /// The underlying fd is transferred (this TcpStream becomes invalid).
    pub fn toStd(self: *TcpStream) std.net.Stream {
        const fd = self.fd;
        self.fd = -1;
        return .{ .handle = fd };
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Non-Blocking I/O
    // ═══════════════════════════════════════════════════════════════════════════

    /// Try to read without blocking.
    /// Returns: bytes read, 0 for EOF, null for WouldBlock.
    pub fn tryRead(self: *TcpStream, buf: []u8) !?usize {
        const n = posix.recv(self.fd, buf, 0) catch |err| switch (err) {
            error.WouldBlock => return null,
            error.ConnectionResetByPeer => return 0,
            else => return err,
        };
        return n;
    }

    /// Try to write without blocking.
    /// Returns: bytes written, null for WouldBlock.
    pub fn tryWrite(self: *TcpStream, data: []const u8) !?usize {
        const n = posix.send(self.fd, data, 0) catch |err| switch (err) {
            error.WouldBlock => return null,
            error.BrokenPipe, error.ConnectionResetByPeer => return 0,
            else => return err,
        };
        return n;
    }

    /// Try to read vectored (scatter I/O).
    pub fn tryReadVectored(self: *TcpStream, iovs: []posix.iovec) !?usize {
        const n = posix.readv(self.fd, iovs) catch |err| switch (err) {
            error.WouldBlock => return null,
            error.ConnectionResetByPeer => return 0,
            else => return err,
        };
        return n;
    }

    /// Try to write vectored (gather I/O).
    pub fn tryWriteVectored(self: *TcpStream, iovs: []const posix.iovec_const) !?usize {
        const n = posix.writev(self.fd, iovs) catch |err| switch (err) {
            error.WouldBlock => return null,
            error.BrokenPipe, error.ConnectionResetByPeer => return 0,
            else => return err,
        };
        return n;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Async I/O (Futures)
    // ═══════════════════════════════════════════════════════════════════════════

    /// Return a future for async read.
    pub fn read(self: *TcpStream, buf: []u8) ReadFuture {
        return .{ .stream = self, .buf = buf };
    }

    /// Return a future for async write.
    pub fn write(self: *TcpStream, data: []const u8) WriteFuture {
        return .{ .stream = self, .data = data };
    }

    /// Write all data, retrying on partial writes (synchronous).
    pub fn writeAll(self: *TcpStream, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            if (try self.tryWrite(data[written..])) |n| {
                if (n == 0) return error.BrokenPipe;
                written += n;
            } else {
                // Would block - in sync mode, just retry
                // In async mode, caller should use futures
                std.Thread.yield() catch {};
            }
        }
    }

    /// Return a future that writes all data (async version of writeAll).
    pub fn writeAllAsync(self: *TcpStream, data: []const u8) WriteAllFuture {
        return WriteAllFuture.init(self, data);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Reader/Writer Interfaces (for TLS composition)
    // ═══════════════════════════════════════════════════════════════════════════

    /// Get a polymorphic Reader interface for this stream.
    ///
    /// Enables layered stream composition (TLS, compression, etc.):
    /// ```zig
    /// var tcp = try TcpStream.connect(addr);
    /// var tls = try TlsStream.init(tcp.reader(), tcp.writer());
    /// ```
    pub fn reader(self: *TcpStream) io.Reader {
        return .{
            .context = @ptrCast(self),
            .readFn = tcpReadFn,
        };
    }

    /// Get a polymorphic Writer interface for this stream.
    ///
    /// Enables layered stream composition (TLS, compression, etc.):
    /// ```zig
    /// var tcp = try TcpStream.connect(addr);
    /// var tls = try TlsStream.init(tcp.reader(), tcp.writer());
    /// ```
    pub fn writer(self: *TcpStream) io.Writer {
        return .{
            .context = @ptrCast(self),
            .writeFn = tcpWriteFn,
            .flushFn = null, // TCP doesn't buffer at this level
        };
    }

    fn tcpReadFn(ctx: *anyopaque, buffer: []u8) io.Error!usize {
        const self: *TcpStream = @ptrCast(@alignCast(ctx));
        const n = posix.recv(self.fd, buffer, 0) catch |err| switch (err) {
            error.WouldBlock => return error.WouldBlock,
            error.ConnectionResetByPeer => return error.ConnectionReset,
            error.ConnectionRefused => return error.ConnectionRefused,
            error.ConnectionTimedOut => return error.TimedOut,
            else => return error.Unexpected,
        };
        return n;
    }

    fn tcpWriteFn(ctx: *anyopaque, data: []const u8) io.Error!usize {
        const self: *TcpStream = @ptrCast(@alignCast(ctx));
        const n = posix.send(self.fd, data, 0) catch |err| switch (err) {
            error.WouldBlock => return error.WouldBlock,
            error.ConnectionResetByPeer => return error.ConnectionReset,
            error.BrokenPipe => return error.BrokenPipe,
            error.ConnectionRefused => return error.ConnectionRefused,
            error.NetworkUnreachable => return error.NetworkUnreachable,
            else => return error.Unexpected,
        };
        return n;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Readiness Polling
    // ═══════════════════════════════════════════════════════════════════════════

    /// Return a future that resolves when the stream is readable.
    pub fn readable(self: *TcpStream) ReadableFuture {
        return .{ .fd = self.fd, .scheduled_io = self.scheduled_io };
    }

    /// Return a future that resolves when the stream is writable.
    pub fn writable(self: *TcpStream) WritableFuture {
        return .{ .fd = self.fd, .scheduled_io = self.scheduled_io };
    }

    /// Return a future that resolves when any of the specified interests is ready.
    /// This allows waiting for multiple conditions at once.
    pub fn ready(self: *TcpStream, interest: Interest) ReadyFuture {
        return .{ .fd = self.fd, .scheduled_io = self.scheduled_io, .interest = interest };
    }

    /// Return a future for async peek (waits for data, then peeks).
    pub fn peekAsync(self: *TcpStream, buf: []u8) PeekFuture {
        return .{ .stream = self, .buf = buf };
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Custom I/O Operations
    // ═══════════════════════════════════════════════════════════════════════════

    /// Try to perform a custom I/O operation.
    ///
    /// This method allows you to perform arbitrary I/O operations while
    /// utilizing the readiness tracking. The closure receives the raw fd
    /// and should return either a result or WouldBlock.
    ///
    /// Example:
    /// ```zig
    /// const result = stream.tryIo(.{ .readable = true }, struct {
    ///     fn io(fd: posix.socket_t) !usize {
    ///         return posix.recv(fd, &buf, posix.MSG.OOB);
    ///     }
    /// }.io);
    /// ```
    pub fn tryIo(
        self: *TcpStream,
        interest: Interest,
        comptime io_fn: fn (posix.socket_t) anyerror!usize,
    ) !?usize {
        _ = interest; // Used for documentation, actual readiness check is on caller
        return io_fn(self.fd) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Socket Options
    // ═══════════════════════════════════════════════════════════════════════════

    /// Set TCP_NODELAY (disable Nagle's algorithm).
    pub fn setNoDelay(self: *TcpStream, value: bool) !void {
        try setBoolOption(self.fd, posix.IPPROTO.TCP, std.posix.TCP.NODELAY, value);
    }

    /// Get TCP_NODELAY.
    pub fn getNoDelay(self: TcpStream) !bool {
        return getBoolOption(self.fd, posix.IPPROTO.TCP, std.posix.TCP.NODELAY);
    }

    /// Set IP TTL.
    pub fn setTtl(self: *TcpStream, ttl: u8) !void {
        try setIntOption(self.fd, posix.IPPROTO.IP, posix.IP.TTL, ttl);
    }

    /// Get IP TTL.
    pub fn getTtl(self: TcpStream) !u8 {
        const val = try getIntOption(self.fd, posix.IPPROTO.IP, posix.IP.TTL);
        return @intCast(val);
    }

    /// Set keepalive options.
    pub fn setKeepalive(self: *TcpStream, keepalive: ?Keepalive) !void {
        var socket = TcpSocket{ .fd = self.fd };
        try socket.setKeepalive(keepalive);
    }

    /// Set SO_LINGER.
    pub fn setLinger(self: *TcpStream, duration: ?Duration) !void {
        var socket = TcpSocket{ .fd = self.fd };
        try socket.setLinger(duration);
    }

    /// Get and clear the pending socket error (SO_ERROR).
    pub fn takeError(self: *TcpStream) !?anyerror {
        var buf: [4]u8 = undefined;
        try posix.getsockopt(self.fd, posix.SOL.SOCKET, posix.SO.ERROR, &buf);
        const err_val = mem.readInt(u32, &buf, .little);
        if (err_val == 0) return null;
        return posix.unexpectedErrno(@enumFromInt(@as(u16, @intCast(err_val))));
    }

    /// Set TCP_QUICKACK (Linux only) - disable delayed ACKs.
    pub fn setQuickAck(self: *TcpStream, value: bool) !void {
        if (comptime builtin.os.tag != .linux) {
            return error.NotSupported;
        }
        try setBoolOption(self.fd, posix.IPPROTO.TCP, std.posix.TCP.QUICKACK, value);
    }

    /// Get TCP_QUICKACK (Linux only).
    pub fn getQuickAck(self: TcpStream) !bool {
        if (comptime builtin.os.tag != .linux) {
            return error.NotSupported;
        }
        return getBoolOption(self.fd, posix.IPPROTO.TCP, std.posix.TCP.QUICKACK);
    }

    /// Set IP_TOS (Type of Service / DSCP) for IPv4.
    /// Common values: 0 (normal), 0x10 (low delay), 0x08 (high throughput).
    pub fn setTos(self: *TcpStream, tos: u8) !void {
        const IP_TOS: u32 = if (builtin.os.tag == .linux) 1 else 3;
        try setIntOption(self.fd, posix.IPPROTO.IP, IP_TOS, tos);
    }

    /// Get IP_TOS value.
    pub fn getTos(self: TcpStream) !u8 {
        const IP_TOS: u32 = if (builtin.os.tag == .linux) 1 else 3;
        const val = try getIntOption(self.fd, posix.IPPROTO.IP, IP_TOS);
        return @intCast(val);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Stream Control
    // ═══════════════════════════════════════════════════════════════════════════

    /// Shutdown the connection.
    pub fn shutdown(self: *TcpStream, how: ShutdownHow) !void {
        try posix.shutdown(self.fd, how.toNative());
    }

    /// Peek at data without consuming it.
    pub fn peek(self: *TcpStream, buf: []u8) !usize {
        return posix.recv(self.fd, buf, posix.MSG.PEEK) catch |err| switch (err) {
            error.WouldBlock => return 0,
            else => return err,
        };
    }

    /// Get peer address.
    pub fn peerAddr(self: TcpStream) Address {
        return self.peer_addr;
    }

    /// Get local address (lazily resolved).
    pub fn localAddr(self: *TcpStream) !Address {
        if (self.local_addr) |addr| return addr;

        var addr: Address = undefined;
        addr.len = @sizeOf(posix.sockaddr.storage);
        try posix.getsockname(self.fd, addr.sockaddrMut(), &addr.len);
        self.local_addr = addr;
        return addr;
    }

    /// Get underlying file descriptor.
    pub fn fileno(self: TcpStream) posix.socket_t {
        return self.fd;
    }

    /// Close the stream.
    pub fn close(self: *TcpStream) void {
        if (self.scheduled_io) |sio| {
            sio.shutdown();
        }
        posix.close(self.fd);
        self.fd = -1;
    }

    /// Register with ScheduledIo for async operations.
    pub fn register(self: *TcpStream, sio: *ScheduledIo) void {
        self.scheduled_io = sio;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Splitting
    // ═══════════════════════════════════════════════════════════════════════════

    /// Split into borrowed read and write halves.
    /// The halves borrow from this stream and cannot outlive it.
    pub fn split(self: *TcpStream) struct { read: ReadHalf, write: WriteHalf } {
        return .{
            .read = .{ .stream = self },
            .write = .{ .stream = self },
        };
    }

    /// Split into owned halves that can be sent to different tasks.
    /// The stream is consumed. Use reunite() to reconstruct.
    pub fn intoSplit(self: *TcpStream, allocator: mem.Allocator) !struct { read: OwnedReadHalf, write: OwnedWriteHalf } {
        const shared = try allocator.create(SharedStream);
        shared.* = .{
            .fd = self.fd,
            .peer_addr = self.peer_addr,
            .local_addr = self.local_addr,
            .scheduled_io = self.scheduled_io,
            .ref_count = std.atomic.Value(u32).init(2),
            .id = @intFromPtr(shared),
            .allocator = allocator,
        };

        // Invalidate the original stream
        self.fd = -1;

        return .{
            .read = .{ .inner = shared },
            .write = .{ .inner = shared, .shutdown_on_drop = true },
        };
    }
};

/// Shutdown direction.
pub const ShutdownHow = enum {
    read,
    write,
    both,

    fn toNative(self: ShutdownHow) posix.ShutdownHow {
        return switch (self) {
            .read => .recv,
            .write => .send,
            .both => .both,
        };
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Split Halves
// ═══════════════════════════════════════════════════════════════════════════════

/// Borrowed read half - lifetime tied to TcpStream.
pub const ReadHalf = struct {
    stream: *TcpStream,

    pub fn tryRead(self: *ReadHalf, buf: []u8) !?usize {
        return self.stream.tryRead(buf);
    }

    pub fn tryReadVectored(self: *ReadHalf, iovs: []posix.iovec) !?usize {
        return self.stream.tryReadVectored(iovs);
    }

    pub fn read(self: *ReadHalf, buf: []u8) ReadFuture {
        return self.stream.read(buf);
    }

    pub fn readable(self: *ReadHalf) ReadableFuture {
        return self.stream.readable();
    }

    pub fn peek(self: *ReadHalf, buf: []u8) !usize {
        return self.stream.peek(buf);
    }

    pub fn peekAsync(self: *ReadHalf, buf: []u8) PeekFuture {
        return self.stream.peekAsync(buf);
    }

    pub fn ready(self: *ReadHalf, interest: Interest) ReadyFuture {
        return self.stream.ready(interest);
    }

    pub fn peerAddr(self: ReadHalf) Address {
        return self.stream.peer_addr;
    }

    pub fn localAddr(self: *ReadHalf) !Address {
        return self.stream.localAddr();
    }
};

/// Borrowed write half - lifetime tied to TcpStream.
pub const WriteHalf = struct {
    stream: *TcpStream,

    pub fn tryWrite(self: *WriteHalf, data: []const u8) !?usize {
        return self.stream.tryWrite(data);
    }

    pub fn tryWriteVectored(self: *WriteHalf, iovs: []const posix.iovec_const) !?usize {
        return self.stream.tryWriteVectored(iovs);
    }

    pub fn write(self: *WriteHalf, data: []const u8) WriteFuture {
        return self.stream.write(data);
    }

    pub fn writeAll(self: *WriteHalf, data: []const u8) !void {
        return self.stream.writeAll(data);
    }

    pub fn writeAllAsync(self: *WriteHalf, data: []const u8) WriteAllFuture {
        return self.stream.writeAllAsync(data);
    }

    pub fn writable(self: *WriteHalf) WritableFuture {
        return self.stream.writable();
    }

    pub fn ready(self: *WriteHalf, interest: Interest) ReadyFuture {
        return self.stream.ready(interest);
    }

    pub fn peerAddr(self: WriteHalf) Address {
        return self.stream.peer_addr;
    }

    pub fn localAddr(self: *WriteHalf) !Address {
        return self.stream.localAddr();
    }
};

/// Shared stream state for owned halves.
const SharedStream = struct {
    fd: posix.socket_t,
    peer_addr: Address,
    local_addr: ?Address,
    scheduled_io: ?*ScheduledIo,
    ref_count: std.atomic.Value(u32),
    id: u64,
    allocator: mem.Allocator,
};

/// Owned read half - can be moved to different tasks.
pub const OwnedReadHalf = struct {
    inner: *SharedStream,

    pub fn tryRead(self: *OwnedReadHalf, buf: []u8) !?usize {
        const n = posix.recv(self.inner.fd, buf, 0) catch |err| switch (err) {
            error.WouldBlock => return null,
            error.ConnectionResetByPeer => return 0,
            else => return err,
        };
        return n;
    }

    pub fn tryReadVectored(self: *OwnedReadHalf, iovs: []posix.iovec) !?usize {
        const n = posix.readv(self.inner.fd, iovs) catch |err| switch (err) {
            error.WouldBlock => return null,
            error.ConnectionResetByPeer => return 0,
            else => return err,
        };
        return n;
    }

    pub fn read(self: *OwnedReadHalf, buf: []u8) OwnedReadFuture {
        return .{ .half = self, .buf = buf };
    }

    pub fn peek(self: *OwnedReadHalf, buf: []u8) !usize {
        return posix.recv(self.inner.fd, buf, posix.MSG.PEEK) catch |err| switch (err) {
            error.WouldBlock => return 0,
            else => return err,
        };
    }

    pub fn readable(self: *OwnedReadHalf) OwnedReadableFuture {
        return .{ .fd = self.inner.fd, .scheduled_io = self.inner.scheduled_io };
    }

    pub fn ready(self: *OwnedReadHalf, interest: Interest) OwnedReadyFuture {
        return .{ .fd = self.inner.fd, .scheduled_io = self.inner.scheduled_io, .interest = interest };
    }

    pub fn peerAddr(self: OwnedReadHalf) Address {
        return self.inner.peer_addr;
    }

    pub fn localAddr(self: *OwnedReadHalf) !Address {
        if (self.inner.local_addr) |addr| return addr;

        var addr: Address = undefined;
        addr.len = @sizeOf(posix.sockaddr.storage);
        try posix.getsockname(self.inner.fd, addr.sockaddrMut(), &addr.len);
        self.inner.local_addr = addr;
        return addr;
    }

    /// Reunite with write half to reconstruct TcpStream.
    pub fn reunite(self: OwnedReadHalf, write_half: OwnedWriteHalf) !TcpStream {
        if (self.inner != write_half.inner or self.inner.id != write_half.inner.id) {
            return error.ReuniteError;
        }

        const stream = TcpStream{
            .fd = self.inner.fd,
            .peer_addr = self.inner.peer_addr,
            .local_addr = self.inner.local_addr,
            .scheduled_io = self.inner.scheduled_io,
        };

        // Free the shared state
        self.inner.allocator.destroy(self.inner);

        return stream;
    }

    pub fn deinit(self: *OwnedReadHalf) void {
        const prev = self.inner.ref_count.fetchSub(1, .acq_rel);
        if (prev == 1) {
            // Last reference - close the socket
            posix.close(self.inner.fd);
            self.inner.allocator.destroy(self.inner);
        }
    }
};

/// Owned write half - can be moved to different tasks.
pub const OwnedWriteHalf = struct {
    inner: *SharedStream,
    shutdown_on_drop: bool,

    pub fn tryWrite(self: *OwnedWriteHalf, data: []const u8) !?usize {
        const n = posix.send(self.inner.fd, data, 0) catch |err| switch (err) {
            error.WouldBlock => return null,
            error.BrokenPipe, error.ConnectionResetByPeer => return 0,
            else => return err,
        };
        return n;
    }

    pub fn tryWriteVectored(self: *OwnedWriteHalf, iovs: []const posix.iovec_const) !?usize {
        const n = posix.writev(self.inner.fd, iovs) catch |err| switch (err) {
            error.WouldBlock => return null,
            error.BrokenPipe, error.ConnectionResetByPeer => return 0,
            else => return err,
        };
        return n;
    }

    pub fn write(self: *OwnedWriteHalf, data: []const u8) OwnedWriteFuture {
        return .{ .half = self, .data = data };
    }

    pub fn writeAll(self: *OwnedWriteHalf, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            if (try self.tryWrite(data[written..])) |n| {
                if (n == 0) return error.BrokenPipe;
                written += n;
            } else {
                std.Thread.yield() catch {};
            }
        }
    }

    pub fn writeAllAsync(self: *OwnedWriteHalf, data: []const u8) OwnedWriteAllFuture {
        return OwnedWriteAllFuture.init(self, data);
    }

    pub fn writable(self: *OwnedWriteHalf) OwnedWritableFuture {
        return .{ .fd = self.inner.fd, .scheduled_io = self.inner.scheduled_io };
    }

    pub fn ready(self: *OwnedWriteHalf, interest: Interest) OwnedReadyFuture {
        return .{ .fd = self.inner.fd, .scheduled_io = self.inner.scheduled_io, .interest = interest };
    }

    pub fn peerAddr(self: OwnedWriteHalf) Address {
        return self.inner.peer_addr;
    }

    pub fn localAddr(self: *OwnedWriteHalf) !Address {
        if (self.inner.local_addr) |addr| return addr;

        var addr: Address = undefined;
        addr.len = @sizeOf(posix.sockaddr.storage);
        try posix.getsockname(self.inner.fd, addr.sockaddrMut(), &addr.len);
        self.inner.local_addr = addr;
        return addr;
    }

    /// Prevent shutdown on drop.
    /// After calling this, the write direction will NOT be shut down when
    /// this OwnedWriteHalf is dropped. Use when you want to keep the
    /// connection fully open.
    pub fn forget(self: *OwnedWriteHalf) void {
        self.shutdown_on_drop = false;
    }

    /// Reunite with read half to reconstruct TcpStream.
    pub fn reunite(self: OwnedWriteHalf, read_half: OwnedReadHalf) !TcpStream {
        return read_half.reunite(self);
    }

    pub fn deinit(self: *OwnedWriteHalf) void {
        if (self.shutdown_on_drop) {
            posix.shutdown(self.inner.fd, .send) catch {};
        }

        const prev = self.inner.ref_count.fetchSub(1, .acq_rel);
        if (prev == 1) {
            // Last reference - close the socket
            posix.close(self.inner.fd);
            self.inner.allocator.destroy(self.inner);
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Future Types
// ═══════════════════════════════════════════════════════════════════════════════

/// Generic poll result (like Rust's Poll).
pub fn PollResult(comptime T: type) type {
    return union(enum) {
        ready: T,
        pending: void,
        err: anyerror,
    };
}

/// Future for async read.
pub const ReadFuture = struct {
    stream: *TcpStream,
    buf: []u8,

    pub fn poll(self: *ReadFuture, waker: Waker) PollResult(usize) {
        if (self.stream.tryRead(self.buf)) |n_opt| {
            if (n_opt) |n| {
                return .{ .ready = n };
            }
        } else |err| {
            return .{ .err = err };
        }

        // WouldBlock - register for notification
        if (self.stream.scheduled_io) |sio| {
            sio.setReaderWaker(waker);
        }
        return .pending;
    }
};

/// Future for async write.
pub const WriteFuture = struct {
    stream: *TcpStream,
    data: []const u8,

    pub fn poll(self: *WriteFuture, waker: Waker) PollResult(usize) {
        if (self.stream.tryWrite(self.data)) |n_opt| {
            if (n_opt) |n| {
                return .{ .ready = n };
            }
        } else |err| {
            return .{ .err = err };
        }

        // WouldBlock - register for notification
        if (self.stream.scheduled_io) |sio| {
            sio.setWriterWaker(waker);
        }
        return .pending;
    }
};

/// Future for readable readiness.
pub const ReadableFuture = struct {
    fd: posix.socket_t,
    scheduled_io: ?*ScheduledIo,

    pub fn poll(self: *ReadableFuture, waker: Waker) PollResult(void) {
        if (self.scheduled_io) |sio| {
            const event = sio.readiness();
            if (event.ready.isReadable()) {
                return .{ .ready = {} };
            }
            sio.setReaderWaker(waker);
        }
        return .pending;
    }
};

/// Future for writable readiness.
pub const WritableFuture = struct {
    fd: posix.socket_t,
    scheduled_io: ?*ScheduledIo,

    pub fn poll(self: *WritableFuture, waker: Waker) PollResult(void) {
        if (self.scheduled_io) |sio| {
            const event = sio.readiness();
            if (event.ready.isWritable()) {
                return .{ .ready = {} };
            }
            sio.setWriterWaker(waker);
        }
        return .pending;
    }
};

/// Future for generic interest-based readiness.
/// Allows waiting for multiple conditions at once.
pub const ReadyFuture = struct {
    fd: posix.socket_t,
    scheduled_io: ?*ScheduledIo,
    interest: Interest,

    pub fn poll(self: *ReadyFuture, waker: Waker) PollResult(Ready) {
        if (self.scheduled_io) |sio| {
            const event = sio.readiness();

            // Check if any requested interest is ready
            var matched = Ready{};
            if (self.interest.readable and event.ready.isReadable()) {
                matched.read = true;
            }
            if (self.interest.writable and event.ready.isWritable()) {
                matched.write = true;
            }

            if (matched.read or matched.write) {
                return .{ .ready = matched };
            }

            // Register for all requested interests
            if (self.interest.readable) {
                sio.setReaderWaker(waker);
            }
            if (self.interest.writable) {
                sio.setWriterWaker(waker);
            }
        }
        return .pending;
    }
};

/// Future for async peek.
pub const PeekFuture = struct {
    stream: *TcpStream,
    buf: []u8,

    pub fn poll(self: *PeekFuture, waker: Waker) PollResult(usize) {
        // Try to peek
        const n = posix.recv(self.stream.fd, self.buf, posix.MSG.PEEK) catch |err| switch (err) {
            error.WouldBlock => {
                // Register for readable notification
                if (self.stream.scheduled_io) |sio| {
                    sio.setReaderWaker(waker);
                }
                return .pending;
            },
            else => return .{ .err = err },
        };
        return .{ .ready = n };
    }
};

/// Future for write all (loops until complete).
pub const WriteAllFuture = struct {
    stream: *TcpStream,
    data: []const u8,
    written: usize,

    pub fn init(stream: *TcpStream, data: []const u8) WriteAllFuture {
        return .{ .stream = stream, .data = data, .written = 0 };
    }

    pub fn poll(self: *WriteAllFuture, waker: Waker) PollResult(void) {
        while (self.written < self.data.len) {
            if (self.stream.tryWrite(self.data[self.written..])) |n_opt| {
                if (n_opt) |n| {
                    if (n == 0) return .{ .err = error.BrokenPipe };
                    self.written += n;
                    continue;
                }
            } else |err| {
                return .{ .err = err };
            }

            // WouldBlock - register for notification
            if (self.stream.scheduled_io) |sio| {
                sio.setWriterWaker(waker);
            }
            return .pending;
        }
        return .{ .ready = {} };
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Owned Half Futures
// ═══════════════════════════════════════════════════════════════════════════════

/// Future for async read on OwnedReadHalf.
pub const OwnedReadFuture = struct {
    half: *OwnedReadHalf,
    buf: []u8,

    pub fn poll(self: *OwnedReadFuture, waker: Waker) PollResult(usize) {
        if (self.half.tryRead(self.buf)) |n_opt| {
            if (n_opt) |n| {
                return .{ .ready = n };
            }
        } else |err| {
            return .{ .err = err };
        }

        // WouldBlock - register for notification
        if (self.half.inner.scheduled_io) |sio| {
            sio.setReaderWaker(waker);
        }
        return .pending;
    }
};

/// Future for async write on OwnedWriteHalf.
pub const OwnedWriteFuture = struct {
    half: *OwnedWriteHalf,
    data: []const u8,

    pub fn poll(self: *OwnedWriteFuture, waker: Waker) PollResult(usize) {
        if (self.half.tryWrite(self.data)) |n_opt| {
            if (n_opt) |n| {
                return .{ .ready = n };
            }
        } else |err| {
            return .{ .err = err };
        }

        // WouldBlock - register for notification
        if (self.half.inner.scheduled_io) |sio| {
            sio.setWriterWaker(waker);
        }
        return .pending;
    }
};

/// Future for write all on OwnedWriteHalf.
pub const OwnedWriteAllFuture = struct {
    half: *OwnedWriteHalf,
    data: []const u8,
    written: usize,

    pub fn init(half: *OwnedWriteHalf, data: []const u8) OwnedWriteAllFuture {
        return .{ .half = half, .data = data, .written = 0 };
    }

    pub fn poll(self: *OwnedWriteAllFuture, waker: Waker) PollResult(void) {
        while (self.written < self.data.len) {
            if (self.half.tryWrite(self.data[self.written..])) |n_opt| {
                if (n_opt) |n| {
                    if (n == 0) return .{ .err = error.BrokenPipe };
                    self.written += n;
                    continue;
                }
            } else |err| {
                return .{ .err = err };
            }

            // WouldBlock - register for notification
            if (self.half.inner.scheduled_io) |sio| {
                sio.setWriterWaker(waker);
            }
            return .pending;
        }
        return .{ .ready = {} };
    }
};

/// Future for readable readiness on owned half.
pub const OwnedReadableFuture = struct {
    fd: posix.socket_t,
    scheduled_io: ?*ScheduledIo,

    pub fn poll(self: *OwnedReadableFuture, waker: Waker) PollResult(void) {
        if (self.scheduled_io) |sio| {
            const event = sio.readiness();
            if (event.ready.isReadable()) {
                return .{ .ready = {} };
            }
            sio.setReaderWaker(waker);
        }
        return .pending;
    }
};

/// Future for writable readiness on owned half.
pub const OwnedWritableFuture = struct {
    fd: posix.socket_t,
    scheduled_io: ?*ScheduledIo,

    pub fn poll(self: *OwnedWritableFuture, waker: Waker) PollResult(void) {
        if (self.scheduled_io) |sio| {
            const event = sio.readiness();
            if (event.ready.isWritable()) {
                return .{ .ready = {} };
            }
            sio.setWriterWaker(waker);
        }
        return .pending;
    }
};

/// Future for generic interest-based readiness on owned half.
pub const OwnedReadyFuture = struct {
    fd: posix.socket_t,
    scheduled_io: ?*ScheduledIo,
    interest: Interest,

    pub fn poll(self: *OwnedReadyFuture, waker: Waker) PollResult(Ready) {
        if (self.scheduled_io) |sio| {
            const event = sio.readiness();

            // Check if any requested interest is ready
            var matched = Ready{};
            if (self.interest.readable and event.ready.isReadable()) {
                matched.read = true;
            }
            if (self.interest.writable and event.ready.isWritable()) {
                matched.write = true;
            }

            if (matched.read or matched.write) {
                return .{ .ready = matched };
            }

            // Register for all requested interests
            if (self.interest.readable) {
                sio.setReaderWaker(waker);
            }
            if (self.interest.writable) {
                sio.setWriterWaker(waker);
            }
        }
        return .pending;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Helper Functions
// ═══════════════════════════════════════════════════════════════════════════════

fn setBoolOption(fd: posix.socket_t, level: i32, opt: u32, value: bool) !void {
    const v: u32 = if (value) 1 else 0;
    try posix.setsockopt(fd, level, opt, &mem.toBytes(v));
}

fn getBoolOption(fd: posix.socket_t, level: i32, opt: u32) !bool {
    var buf: [4]u8 = undefined;
    try posix.getsockopt(fd, level, opt, &buf);
    return mem.readInt(u32, &buf, .little) != 0;
}

fn setIntOption(fd: posix.socket_t, level: i32, opt: u32, value: u32) !void {
    try posix.setsockopt(fd, level, opt, &mem.toBytes(value));
}

fn getIntOption(fd: posix.socket_t, level: i32, opt: u32) !u32 {
    var buf: [4]u8 = undefined;
    try posix.getsockopt(fd, level, opt, &buf);
    return mem.readInt(u32, &buf, .little);
}

fn setNonBlocking(fd: posix.socket_t, value: bool) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    const new_flags = if (value)
        flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true }))
    else
        flags & ~@as(u32, @bitCast(posix.O{ .NONBLOCK = true }));

    _ = try posix.fcntl(fd, posix.F.SETFL, new_flags);
}

fn waitForConnect(sock_fd: posix.socket_t) !void {
    // Poll for writability (connect complete)
    var pfd = [_]posix.pollfd{
        .{
            .fd = sock_fd,
            .events = posix.POLL.OUT,
            .revents = 0,
        },
    };

    const timeout_ms = 30000; // 30 second timeout
    const n = try posix.poll(&pfd, timeout_ms);

    if (n == 0) return error.TimedOut;

    // Check for connection error
    var err_buf: [4]u8 = undefined;
    try posix.getsockopt(sock_fd, posix.SOL.SOCKET, posix.SO.ERROR, &err_buf);
    const err = mem.readInt(u32, &err_buf, .little);

    if (err != 0) {
        return posix.unexpectedErrno(@enumFromInt(err));
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

test "TcpSocket - create and close" {
    var socket = try TcpSocket.newV4();
    socket.close();
}

test "TcpSocket - set options" {
    var socket = try TcpSocket.newV4();
    defer socket.close();

    try socket.setReuseAddr(true);
    try std.testing.expect(try socket.getReuseAddr());

    try socket.setSendBufferSize(65536);
    // Kernel may adjust the value, just check it's non-zero
    try std.testing.expect((try socket.getSendBufferSize()) > 0);

    try socket.setRecvBufferSize(65536);
    try std.testing.expect((try socket.getRecvBufferSize()) > 0);
}

test "TcpListener - bind and close" {
    var listener = try TcpListener.bind(Address.fromPort(0));
    defer listener.close();

    // Should have been assigned a port
    const port = listener.localAddr().port();
    try std.testing.expect(port > 0);
}

test "TcpListener - accept returns null when no connection" {
    var listener = try TcpListener.bind(Address.fromPort(0));
    defer listener.close();

    // No one connecting, should return null (EAGAIN)
    const conn = try listener.tryAccept();
    try std.testing.expect(conn == null);
}

test "TCP - connect and transfer" {
    // Create listener
    var listener = try TcpListener.bind(Address.fromPort(0));
    defer listener.close();

    const lport = listener.localAddr().port();

    // Connect from client
    var client = try TcpStream.connect(Address.loopbackV4(lport));
    defer client.close();

    // Accept on server - retry with backoff
    var server_conn: ?TcpStream = null;
    for (0..50) |_| {
        if (try listener.tryAccept()) |result| {
            server_conn = result.stream;
            break;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    var conn = server_conn orelse return error.NoConnection;
    defer conn.close();

    // Send data client -> server
    try client.writeAll("Hello, server!");

    // Receive on server with retry
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (0..50) |_| {
        if (try conn.tryRead(&buf)) |bytes| {
            n = bytes;
            break;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    if (n == 0) return error.NoData;

    try std.testing.expectEqualStrings("Hello, server!", buf[0..n]);
}

test "TcpStream - socket options" {
    var listener = try TcpListener.bind(Address.fromPort(0));
    defer listener.close();

    var stream = try TcpStream.connect(Address.loopbackV4(listener.localAddr().port()));
    defer stream.close();

    // Wait for connection
    for (0..50) |_| {
        if (try listener.tryAccept()) |_| break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try stream.setNoDelay(true);
    try std.testing.expect(try stream.getNoDelay());

    try stream.setNoDelay(false);
    try std.testing.expect(!try stream.getNoDelay());
}

test "TcpStream - split" {
    var listener = try TcpListener.bind(Address.fromPort(0));
    defer listener.close();

    var stream = try TcpStream.connect(Address.loopbackV4(listener.localAddr().port()));
    defer stream.close();

    // Wait for connection
    for (0..50) |_| {
        if (try listener.tryAccept()) |_| break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    const halves = stream.split();
    _ = halves.read.peerAddr();
    _ = halves.write.peerAddr();
}

test "TcpStream - reader/writer interface" {
    // Create listener
    var listener = try TcpListener.bind(Address.fromPort(0));
    defer listener.close();

    const lport = listener.localAddr().port();

    // Connect from client
    var client = try TcpStream.connect(Address.loopbackV4(lport));
    defer client.close();

    // Accept on server
    var server_conn: ?TcpStream = null;
    for (0..50) |_| {
        if (try listener.tryAccept()) |result| {
            server_conn = result.stream;
            break;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    var conn = server_conn orelse return error.NoConnection;
    defer conn.close();

    // Get reader/writer interfaces
    var w = client.writer();
    var r = conn.reader();

    // Write using the io.Writer interface
    try w.writeAll("Hello via Writer!");

    // Read using the io.Reader interface
    var buf: [64]u8 = undefined;
    var total: usize = 0;
    for (0..50) |_| {
        const n = r.read(buf[total..]) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (n == 0) break;
        total += n;
        if (total >= 17) break; // "Hello via Writer!" is 17 chars
    }

    try std.testing.expectEqualStrings("Hello via Writer!", buf[0..total]);
}

test "TcpStream - takeError" {
    var listener = try TcpListener.bind(Address.fromPort(0));
    defer listener.close();

    var stream = try TcpStream.connect(Address.loopbackV4(listener.localAddr().port()));
    defer stream.close();

    // Accept to complete connection
    for (0..50) |_| {
        if (try listener.tryAccept()) |_| break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    // No error should be pending
    const err = try stream.takeError();
    try std.testing.expect(err == null);
}

test "TcpStream - TOS option" {
    var listener = try TcpListener.bind(Address.fromPort(0));
    defer listener.close();

    var stream = try TcpStream.connect(Address.loopbackV4(listener.localAddr().port()));
    defer stream.close();

    // Accept to complete connection
    for (0..50) |_| {
        if (try listener.tryAccept()) |_| break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    // Set TOS (low delay)
    try stream.setTos(0x10);
    try std.testing.expectEqual(@as(u8, 0x10), try stream.getTos());
}

test "TcpStream - fromStd/toStd" {
    var listener = try TcpListener.bind(Address.fromPort(0));
    defer listener.close();

    var stream = try TcpStream.connect(Address.loopbackV4(listener.localAddr().port()));

    // Accept to complete connection
    for (0..50) |_| {
        if (try listener.tryAccept()) |_| break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    // Convert to std
    const std_stream = stream.toStd();

    // Convert back
    var stream2 = TcpStream.fromStd(std_stream);
    defer stream2.close();

    // Should still work
    try stream2.setNoDelay(true);
}

test "OwnedWriteHalf - forget" {
    var listener = try TcpListener.bind(Address.fromPort(0));
    defer listener.close();

    var stream = try TcpStream.connect(Address.loopbackV4(listener.localAddr().port()));

    // Accept to complete connection
    for (0..50) |_| {
        if (try listener.tryAccept()) |_| break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    // Split into owned halves
    const halves = try stream.intoSplit(std.testing.allocator);
    var read_half = halves.read;
    var write_half = halves.write;

    // Forget to prevent shutdown on drop
    write_half.forget();

    // Cleanup
    write_half.deinit();
    read_half.deinit();
}

test "OwnedHalves - localAddr" {
    var listener = try TcpListener.bind(Address.fromPort(0));
    defer listener.close();

    var stream = try TcpStream.connect(Address.loopbackV4(listener.localAddr().port()));

    // Accept to complete connection
    for (0..50) |_| {
        if (try listener.tryAccept()) |_| break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    // Split into owned halves
    const halves = try stream.intoSplit(std.testing.allocator);
    var read_half = halves.read;
    var write_half = halves.write;
    defer {
        write_half.deinit();
        read_half.deinit();
    }

    // Both halves should be able to get local address
    const read_addr = try read_half.localAddr();
    const write_addr = try write_half.localAddr();
    try std.testing.expectEqual(read_addr.port(), write_addr.port());
}

test "OwnedHalves - vectored I/O" {
    var listener = try TcpListener.bind(Address.fromPort(0));
    defer listener.close();

    var client = try TcpStream.connect(Address.loopbackV4(listener.localAddr().port()));

    // Accept connection
    var server_conn: ?TcpStream = null;
    for (0..50) |_| {
        if (try listener.tryAccept()) |result| {
            server_conn = result.stream;
            break;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    var conn = server_conn orelse return error.NoConnection;
    defer conn.close();

    // Split client into owned halves
    const halves = try client.intoSplit(std.testing.allocator);
    var read_half = halves.read;
    var write_half = halves.write;
    defer {
        write_half.deinit();
        read_half.deinit();
    }

    // Write vectored
    const header = "HDR:";
    const body = "data";
    const iovecs = [_]posix.iovec_const{
        .{ .base = header.ptr, .len = header.len },
        .{ .base = body.ptr, .len = body.len },
    };

    // May need retries for non-blocking I/O
    var written: usize = 0;
    for (0..50) |_| {
        if (try write_half.tryWriteVectored(&iovecs)) |n| {
            written = n;
            break;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(usize, 8), written);
}

test "TcpStream - tryIo custom operation" {
    var listener = try TcpListener.bind(Address.fromPort(0));
    defer listener.close();

    var stream = try TcpStream.connect(Address.loopbackV4(listener.localAddr().port()));
    defer stream.close();

    // Accept to complete connection
    var server_conn: ?TcpStream = null;
    for (0..50) |_| {
        if (try listener.tryAccept()) |result| {
            server_conn = result.stream;
            break;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    var conn = server_conn orelse return error.NoConnection;
    defer conn.close();

    // Try custom I/O - would block since no data
    const result = try stream.tryIo(.{ .readable = true }, struct {
        fn io(fd: posix.socket_t) !usize {
            var buf: [64]u8 = undefined;
            return posix.recv(fd, &buf, 0);
        }
    }.io);

    // Should return null (would block)
    try std.testing.expect(result == null);
}
