//! TcpStream - Connected Socket
//!
//! A connected TCP stream with async read/write, readiness polling, and futures.

const std = @import("std");
const c = @import("common.zig");
const posix = c.posix;
const mem = c.mem;
const builtin = c.builtin;
const Address = c.Address;
const ScheduledIo = c.ScheduledIo;
const Ready = c.Ready;
const Interest = c.Interest;
const Waker = c.Waker;
const FutureWaker = c.FutureWaker;
const FutureContext = c.FutureContext;
const FuturePollResult = c.FuturePollResult;
const Duration = c.Duration;
const io = c.io;

const setBoolOption = c.setBoolOption;
const getBoolOption = c.getBoolOption;
const setIntOption = c.setIntOption;
const getIntOption = c.getIntOption;
const setNonBlocking = c.setNonBlocking;
const updateStoredWaker = c.updateStoredWaker;
const bridgeWaker = c.bridgeWaker;
const cleanupStoredWaker = c.cleanupStoredWaker;

const TcpSocket = @import("socket.zig").TcpSocket;
const Keepalive = @import("socket.zig").Keepalive;
const split = @import("split.zig");
pub const ReadHalf = split.ReadHalf;
pub const WriteHalf = split.WriteHalf;
pub const OwnedReadHalf = split.OwnedReadHalf;
pub const OwnedWriteHalf = split.OwnedWriteHalf;
pub const SharedStream = split.SharedStream;

// ═══════════════════════════════════════════════════════════════════════════════
// TcpStream
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

    /// Return a future that writes all data.
    pub fn writeAll(self: *TcpStream, data: []const u8) WriteAllFuture {
        return WriteAllFuture.init(self, data);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Reader/Writer Interfaces (for TLS composition)
    // ═══════════════════════════════════════════════════════════════════════════

    /// Get a polymorphic Reader interface for this stream.
    pub fn reader(self: *TcpStream) io.Reader {
        return .{
            .context = @ptrCast(self),
            .readFn = tcpReadFn,
        };
    }

    /// Get a polymorphic Writer interface for this stream.
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
    pub fn tryIo(
        self: *TcpStream,
        interest: Interest,
        comptime io_fn: fn (posix.socket_t) anyerror!usize,
    ) !?usize {
        _ = interest;
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
    pub fn split_halves(self: *TcpStream) struct { read: ReadHalf, write: WriteHalf } {
        return .{
            .read = .{ .stream = self },
            .write = .{ .stream = self },
        };
    }

    // Alias for backward compatibility
    pub const split = split_halves;

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

// ═══════════════════════════════════════════════════════════════════════════════
// ShutdownHow
// ═══════════════════════════════════════════════════════════════════════════════

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
// Future Types
// ═══════════════════════════════════════════════════════════════════════════════

/// Future for async read.
pub const ReadFuture = struct {
    pub const Output = anyerror!usize;

    stream: *TcpStream,
    buf: []u8,
    stored_waker: ?FutureWaker = null,

    pub fn poll(self: *ReadFuture, ctx: *FutureContext) FuturePollResult(Output) {
        if (self.stream.tryRead(self.buf)) |n_opt| {
            if (n_opt) |n| {
                return .{ .ready = n };
            }
        } else |err| {
            return .{ .ready = err };
        }

        // WouldBlock - register for notification
        updateStoredWaker(&self.stored_waker, ctx);
        if (self.stream.scheduled_io) |sio| {
            sio.setReaderWaker(bridgeWaker(&self.stored_waker));
        }
        return .pending;
    }

    pub fn deinit(self: *ReadFuture) void {
        cleanupStoredWaker(&self.stored_waker);
    }
};

/// Future for async write.
pub const WriteFuture = struct {
    pub const Output = anyerror!usize;

    stream: *TcpStream,
    data: []const u8,
    stored_waker: ?FutureWaker = null,

    pub fn poll(self: *WriteFuture, ctx: *FutureContext) FuturePollResult(Output) {
        if (self.stream.tryWrite(self.data)) |n_opt| {
            if (n_opt) |n| {
                return .{ .ready = n };
            }
        } else |err| {
            return .{ .ready = err };
        }

        // WouldBlock - register for notification
        updateStoredWaker(&self.stored_waker, ctx);
        if (self.stream.scheduled_io) |sio| {
            sio.setWriterWaker(bridgeWaker(&self.stored_waker));
        }
        return .pending;
    }

    pub fn deinit(self: *WriteFuture) void {
        cleanupStoredWaker(&self.stored_waker);
    }
};

/// Future for readable readiness.
pub const ReadableFuture = struct {
    pub const Output = void;

    fd: posix.socket_t,
    scheduled_io: ?*ScheduledIo,
    stored_waker: ?FutureWaker = null,

    pub fn poll(self: *ReadableFuture, ctx: *FutureContext) FuturePollResult(Output) {
        if (self.scheduled_io) |sio| {
            const event = sio.readiness();
            if (event.ready.isReadable()) {
                return .{ .ready = {} };
            }
            updateStoredWaker(&self.stored_waker, ctx);
            sio.setReaderWaker(bridgeWaker(&self.stored_waker));
        }
        return .pending;
    }

    pub fn deinit(self: *ReadableFuture) void {
        cleanupStoredWaker(&self.stored_waker);
    }
};

/// Future for writable readiness.
pub const WritableFuture = struct {
    pub const Output = void;

    fd: posix.socket_t,
    scheduled_io: ?*ScheduledIo,
    stored_waker: ?FutureWaker = null,

    pub fn poll(self: *WritableFuture, ctx: *FutureContext) FuturePollResult(Output) {
        if (self.scheduled_io) |sio| {
            const event = sio.readiness();
            if (event.ready.isWritable()) {
                return .{ .ready = {} };
            }
            updateStoredWaker(&self.stored_waker, ctx);
            sio.setWriterWaker(bridgeWaker(&self.stored_waker));
        }
        return .pending;
    }

    pub fn deinit(self: *WritableFuture) void {
        cleanupStoredWaker(&self.stored_waker);
    }
};

/// Future for generic interest-based readiness.
pub const ReadyFuture = struct {
    pub const Output = Ready;

    fd: posix.socket_t,
    scheduled_io: ?*ScheduledIo,
    interest: Interest,
    stored_waker: ?FutureWaker = null,

    pub fn poll(self: *ReadyFuture, ctx: *FutureContext) FuturePollResult(Output) {
        if (self.scheduled_io) |sio| {
            const event = sio.readiness();

            // Check if any requested interest is ready
            var matched = Ready{};
            if (self.interest.readable and event.ready.isReadable()) {
                matched.readable = true;
            }
            if (self.interest.writable and event.ready.isWritable()) {
                matched.writable = true;
            }

            if (matched.readable or matched.writable) {
                return .{ .ready = matched };
            }

            // Register for all requested interests
            updateStoredWaker(&self.stored_waker, ctx);
            if (self.interest.readable) {
                sio.setReaderWaker(bridgeWaker(&self.stored_waker));
            }
            if (self.interest.writable) {
                sio.setWriterWaker(bridgeWaker(&self.stored_waker));
            }
        }
        return .pending;
    }

    pub fn deinit(self: *ReadyFuture) void {
        cleanupStoredWaker(&self.stored_waker);
    }
};

/// Future for async peek.
pub const PeekFuture = struct {
    pub const Output = anyerror!usize;

    stream: *TcpStream,
    buf: []u8,
    stored_waker: ?FutureWaker = null,

    pub fn poll(self: *PeekFuture, ctx: *FutureContext) FuturePollResult(Output) {
        // Try to peek
        const n = posix.recv(self.stream.fd, self.buf, posix.MSG.PEEK) catch |err| switch (err) {
            error.WouldBlock => {
                // Register for readable notification
                updateStoredWaker(&self.stored_waker, ctx);
                if (self.stream.scheduled_io) |sio| {
                    sio.setReaderWaker(bridgeWaker(&self.stored_waker));
                }
                return .pending;
            },
            else => return .{ .ready = err },
        };
        return .{ .ready = n };
    }

    pub fn deinit(self: *PeekFuture) void {
        cleanupStoredWaker(&self.stored_waker);
    }
};

/// Future for write all (loops until complete).
pub const WriteAllFuture = struct {
    pub const Output = anyerror!void;

    stream: *TcpStream,
    data: []const u8,
    written: usize,
    stored_waker: ?FutureWaker = null,

    pub fn init(stream: *TcpStream, data: []const u8) WriteAllFuture {
        return .{ .stream = stream, .data = data, .written = 0 };
    }

    pub fn poll(self: *WriteAllFuture, ctx: *FutureContext) FuturePollResult(Output) {
        while (self.written < self.data.len) {
            if (self.stream.tryWrite(self.data[self.written..])) |n_opt| {
                if (n_opt) |n| {
                    if (n == 0) return .{ .ready = error.BrokenPipe };
                    self.written += n;
                    continue;
                }
            } else |err| {
                return .{ .ready = err };
            }

            // WouldBlock - register for notification
            updateStoredWaker(&self.stored_waker, ctx);
            if (self.stream.scheduled_io) |sio| {
                sio.setWriterWaker(bridgeWaker(&self.stored_waker));
            }
            return .pending;
        }
        return .{ .ready = {} };
    }

    pub fn deinit(self: *WriteAllFuture) void {
        cleanupStoredWaker(&self.stored_waker);
    }
};
