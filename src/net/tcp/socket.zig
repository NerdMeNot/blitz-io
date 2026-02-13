//! TcpSocket - Pre-Connection Socket Builder
//!
//! Configure socket options BEFORE connecting or binding. The builder pattern
//! allows setting buffer sizes, keepalive, etc. before the connection is
//! established, which is important for proper TCP window scaling.

const c = @import("common.zig");
const posix = c.posix;
const mem = c.mem;
const builtin = c.builtin;
const Address = c.Address;
const Duration = c.Duration;

const setBoolOption = c.setBoolOption;
const getBoolOption = c.getBoolOption;
const setIntOption = c.setIntOption;
const getIntOption = c.getIntOption;
const setNonBlocking = c.setNonBlocking;
const waitForConnect = c.waitForConnect;

const TcpStream = @import("stream.zig").TcpStream;
const TcpListener = @import("listener.zig").TcpListener;

// ═══════════════════════════════════════════════════════════════════════════════
// TcpSocket
// ═══════════════════════════════════════════════════════════════════════════════

/// TCP socket builder for pre-connection configuration.
///
/// Configure socket options BEFORE connecting or binding. The builder pattern
/// allows setting buffer sizes, keepalive, etc. before the connection is
/// established, which is important for proper TCP window scaling.
///
/// ## Example
///
/// ```zig
/// var socket = try TcpSocket.newV4();
/// try socket.setReuseAddr(true);
/// try socket.setRecvBufferSize(65536);
/// try socket.setKeepalive(.{ .time = Duration.fromSecs(60) });
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
                try setIntOption(self.fd, posix.IPPROTO.TCP, @import("std").posix.TCP.KEEPIDLE, @intCast(ka.time.asSeconds()));

                // Set probe interval (Linux only)
                if (ka.interval) |interval| {
                    try setIntOption(self.fd, posix.IPPROTO.TCP, @import("std").posix.TCP.KEEPINTVL, @intCast(interval.asSeconds()));
                }

                // Set probe count (Linux only)
                if (ka.retries) |retries| {
                    try setIntOption(self.fd, posix.IPPROTO.TCP, @import("std").posix.TCP.KEEPCNT, retries);
                }
            } else if (comptime builtin.os.tag == .macos or builtin.os.tag == .freebsd) {
                // macOS uses TCP_KEEPALIVE for the idle time
                try setIntOption(self.fd, posix.IPPROTO.TCP, @import("std").posix.TCP.KEEPALIVE, @intCast(ka.time.asSeconds()));
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

        var ka = Keepalive{ .time = Duration.fromSecs(0) };

        if (comptime builtin.os.tag == .linux) {
            const idle = try getIntOption(self.fd, posix.IPPROTO.TCP, @import("std").posix.TCP.KEEPIDLE);
            ka.time = Duration.fromSecs(idle);

            const interval = try getIntOption(self.fd, posix.IPPROTO.TCP, @import("std").posix.TCP.KEEPINTVL);
            ka.interval = Duration.fromSecs(interval);

            const retries = try getIntOption(self.fd, posix.IPPROTO.TCP, @import("std").posix.TCP.KEEPCNT);
            ka.retries = retries;
        } else if (comptime builtin.os.tag == .macos or builtin.os.tag == .freebsd) {
            const idle = try getIntOption(self.fd, posix.IPPROTO.TCP, @import("std").posix.TCP.KEEPALIVE);
            ka.time = Duration.fromSecs(idle);
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
            return Duration.fromSecs(linger_val.seconds);
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

    // ═══════════════════════════════════════════════════════════════════════════
    // Builder Pattern
    // ═══════════════════════════════════════════════════════════════════════════

    /// Configure socket options using a builder pattern.
    pub fn configure(self: *TcpSocket) SocketConfigBuilder {
        return .{ .socket = self, .err = null };
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// SocketConfigBuilder
// ═══════════════════════════════════════════════════════════════════════════════

/// Fluent builder for socket configuration.
///
/// Collects configuration options and applies them atomically.
/// If any option fails to set, the error is captured and returned by `apply()`.
pub const SocketConfigBuilder = struct {
    socket: *TcpSocket,
    err: ?anyerror,

    /// Set SO_REUSEADDR.
    pub fn reuseAddr(self: *SocketConfigBuilder, value: bool) *SocketConfigBuilder {
        if (self.err == null) {
            self.socket.setReuseAddr(value) catch |e| {
                self.err = e;
            };
        }
        return self;
    }

    /// Set SO_REUSEPORT (Linux/BSD only).
    pub fn reusePort(self: *SocketConfigBuilder, value: bool) *SocketConfigBuilder {
        if (self.err == null) {
            self.socket.setReusePort(value) catch |e| {
                self.err = e;
            };
        }
        return self;
    }

    /// Set send buffer size (SO_SNDBUF).
    pub fn sendBufferSize(self: *SocketConfigBuilder, size: u32) *SocketConfigBuilder {
        if (self.err == null) {
            self.socket.setSendBufferSize(size) catch |e| {
                self.err = e;
            };
        }
        return self;
    }

    /// Set receive buffer size (SO_RCVBUF).
    pub fn recvBufferSize(self: *SocketConfigBuilder, size: u32) *SocketConfigBuilder {
        if (self.err == null) {
            self.socket.setRecvBufferSize(size) catch |e| {
                self.err = e;
            };
        }
        return self;
    }

    /// Set TCP keepalive options.
    pub fn keepalive(self: *SocketConfigBuilder, ka: ?Keepalive) *SocketConfigBuilder {
        if (self.err == null) {
            self.socket.setKeepalive(ka) catch |e| {
                self.err = e;
            };
        }
        return self;
    }

    /// Set SO_LINGER.
    pub fn linger(self: *SocketConfigBuilder, duration: ?Duration) *SocketConfigBuilder {
        if (self.err == null) {
            self.socket.setLinger(duration) catch |e| {
                self.err = e;
            };
        }
        return self;
    }

    /// Finalize configuration, returning any error that occurred.
    pub fn apply(self: *SocketConfigBuilder) !void {
        if (self.err) |e| return e;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Keepalive
// ═══════════════════════════════════════════════════════════════════════════════

/// TCP keepalive configuration.
pub const Keepalive = struct {
    /// Idle time before keepalive probes start.
    time: Duration,
    /// Time between probes (Linux only).
    interval: ?Duration = null,
    /// Number of probes before connection is dropped (Linux only).
    retries: ?u32 = null,
};
