//! # Blitz-IO: High-Performance Async I/O for Zig
//!
//! A production-grade async I/O runtime with:
//! - Work-stealing task scheduler
//! - Platform-optimized backends (io_uring, kqueue, epoll, IOCP)
//! - Tokio-style async combinators (Timeout, Select, Join)
//! - Graceful shutdown with signal handling
//! - Seamless blocking pool integration
//!
//! ## Quick Start: TCP Echo Server
//!
//! ```zig
//! const std = @import("std");
//! const io = @import("blitz-io");
//!
//! pub fn main() !void {
//!     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//!     defer _ = gpa.deinit();
//!
//!     var rt = try io.Runtime.init(gpa.allocator(), .{
//!         .workers = 4,
//!         .blocking_threads = 2,
//!     });
//!     defer rt.deinit();
//!
//!     try rt.run(server, .{});
//! }
//!
//! fn server() void {
//!     var listener = io.listen("0.0.0.0:8080") catch return;
//!     defer listener.close();
//!
//!     while (listener.tryAccept() catch null) |result| {
//!         handleClient(result.stream);
//!     }
//! }
//!
//! fn handleClient(conn: io.TcpStream) void {
//!     var stream = conn;
//!     defer stream.close();
//!
//!     var buf: [4096]u8 = undefined;
//!     while (true) {
//!         const n = stream.tryRead(&buf) catch return orelse continue;
//!         if (n == 0) return;  // Client disconnected
//!         stream.writeAll(buf[0..n]) catch return;
//!     }
//! }
//! ```
//!
//! ## Time and Timeouts
//!
//! ```zig
//! // Duration creation
//! const timeout = io.Duration.fromSecs(30);
//! const interval = io.Duration.fromMillis(100);
//! const precise = io.Duration.fromNanos(1_500_000);
//!
//! // Deadline tracking
//! var deadline = io.deadline(io.Duration.fromSecs(5));
//! while (!deadline.isExpired()) {
//!     // Do work...
//!     if (deadline.check()) |_| {} else |err| {
//!         std.log.warn("Timed out: {}", .{err});
//!         break;
//!     }
//! }
//!
//! // Extend deadline if needed
//! deadline.extend(io.Duration.fromSecs(2));
//!
//! // Timing operations
//! const start = io.Instant.now();
//! doExpensiveOperation();
//! const elapsed = start.elapsed();
//! std.log.info("Took {} ms", .{elapsed.asMillis()});
//! ```
//!
//! ## Async Combinators
//!
//! Compose async operations with Tokio-style combinators:
//!
//! ```zig
//! // Timeout: Wrap operation with deadline
//! var timeout = io.Timeout(AcceptFuture).init(
//!     listener.accept(),
//!     io.Duration.fromSecs(30),
//! );
//! switch (timeout.poll(waker)) {
//!     .ready => |conn| handleConnection(conn),
//!     .timeout => log.warn("Accept timed out", .{}),
//!     .pending => {},
//! }
//!
//! // Select: Race two operations, first to complete wins
//! var select = io.Select2(AcceptFuture, ShutdownFuture).init(
//!     listener.accept(),
//!     shutdown.future(),
//! );
//! switch (select.poll(waker)) {
//!     .first => |conn| handleConnection(conn),
//!     .second => |_| break,  // Shutdown signal
//!     .pending => {},
//! }
//!
//! // Join: Run operations concurrently, wait for all
//! var join = io.Join2(UserFuture, PostsFuture).init(
//!     fetchUser(id),
//!     fetchPosts(id),
//! );
//! switch (join.poll(waker)) {
//!     .ready => |results| {
//!         const user = results[0];
//!         const posts = results[1];
//!         renderPage(user, posts);
//!     },
//!     .pending => {},
//! }
//!
//! // Composing: Parallel fetch with timeout
//! var join = io.Join2(UserFuture, PostsFuture).init(
//!     fetchUser(id), fetchPosts(id),
//! );
//! var timeout = io.Timeout(@TypeOf(join)).init(join, io.Duration.fromSecs(5));
//! ```
//!
//! ## Graceful Shutdown
//!
//! Handle SIGINT/SIGTERM with work tracking:
//!
//! ```zig
//! var shutdown = try io.Shutdown.init();
//! defer shutdown.deinit();
//!
//! // Main accept loop
//! while (!shutdown.isShutdown()) {
//!     if (listener.tryAccept() catch null) |result| {
//!         // Track in-flight work
//!         var work = shutdown.startWork();
//!         defer work.deinit();
//!
//!         handleConnection(result.stream);
//!     }
//! }
//!
//! // Wait for pending requests to complete (with timeout)
//! if (shutdown.hasPendingWork()) {
//!     const completed = shutdown.waitPendingTimeout(io.Duration.fromSecs(30));
//!     if (!completed) log.warn("Forcing shutdown with pending work", .{});
//! }
//! ```
//!
//! ## Networking Convenience
//!
//! ```zig
//! // Listen on address string
//! var listener = try io.listen("0.0.0.0:8080");
//! var listener2 = try io.listenPort(9090);
//!
//! // Connect to server
//! var conn = try io.connect("127.0.0.1:8080");
//!
//! // Connect with DNS resolution
//! var conn2 = try io.connectHost(allocator, "example.com", 443);
//!
//! // DNS resolution
//! const addrs = try io.resolve(allocator, "example.com", 80);
//! defer addrs.deinit();
//! for (addrs.addresses()) |addr| {
//!     std.log.info("Resolved: {}", .{addr});
//! }
//! ```
//!
//! ## Stream Processing
//!
//! ```zig
//! // Buffered I/O for efficiency
//! var reader = io.bufReader(stream.reader());
//! var writer = io.bufWriter(stream.writer());
//!
//! // Line-by-line reading
//! var line_iter = io.lines(stream.reader());
//! while (line_iter.next()) |line| {
//!     processLine(line);
//! }
//!
//! // Copy streams
//! const bytes_copied = try io.copy(src, dst);
//! ```
//!
//! ## Synchronization
//!
//! ```zig
//! // Oneshot channel for single value
//! var oneshot = io.Oneshot(Result).init();
//! oneshot.send(result);  // Producer
//! const value = oneshot.recv();  // Consumer
//!
//! // MPSC channel for streaming
//! var channel = try io.Channel(Message).init(allocator, 100);
//! try channel.send(msg);  // Multiple producers
//! const msg = channel.recv();  // Single consumer
//!
//! // Notify for task wakeup
//! var notify = io.Notify.init();
//! notify.notifyOne();  // Wake one waiter
//! notify.notifyAll();  // Wake all waiters
//! ```
//!
//! ## Process Spawning
//!
//! ```zig
//! var cmd = io.Command.init(&.{"ls", "-la"});
//! cmd.setStdout(.pipe);
//! var child = try cmd.spawn();
//!
//! // Read output
//! const output = try child.stdout.?.readAll(allocator);
//! const status = try child.wait();
//! ```

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════════
// Core Runtime
// ═══════════════════════════════════════════════════════════════════════════

const runtime_mod = @import("runtime.zig");

/// The async I/O runtime.
pub const Runtime = runtime_mod.Runtime;

/// Runtime configuration.
pub const Config = runtime_mod.Config;

// ═══════════════════════════════════════════════════════════════════════════
// Runtime Functions (use inside Runtime.run())
// ═══════════════════════════════════════════════════════════════════════════

/// Sleep for a duration.
pub const sleep = runtime_mod.sleep;

/// Run a function on the blocking pool.
/// Use this for CPU-intensive or blocking work that would block I/O workers.
pub const blocking = runtime_mod.blocking;

/// Spawn a concurrent task.
pub const spawn = runtime_mod.spawn;

/// Get the current runtime (if inside one).
pub const getRuntime = runtime_mod.getRuntime;

// ═══════════════════════════════════════════════════════════════════════════
// Time
// ═══════════════════════════════════════════════════════════════════════════

/// Time module with Duration, Instant, and async sleep/timer primitives.
///
/// ## Example: Duration arithmetic
/// ```zig
/// const one_second = io.Duration.fromSecs(1);
/// const half_second = io.Duration.fromMillis(500);
/// const combined = one_second.add(half_second);  // 1.5 seconds
/// std.debug.print("Total: {} ms\n", .{combined.asMillis()});
/// ```
pub const time = @import("time.zig");

/// Duration of time (nanosecond precision).
///
/// Create with: `fromNanos`, `fromMicros`, `fromMillis`, `fromSecs`, `fromMinutes`, `fromHours`
/// Convert with: `asNanos`, `asMicros`, `asMillis`, `asSecs`, `asMinutes`, `asHours`
pub const Duration = time.Duration;

/// Point in time (monotonic clock). Use for timing operations.
///
/// ## Example
/// ```zig
/// const start = io.Instant.now();
/// doWork();
/// const elapsed = start.elapsed();
/// ```
pub const Instant = time.Instant;

/// Async sleep primitive.
pub const Sleep = time.Sleep;

/// Waiter for async sleep.
pub const SleepWaiter = time.SleepWaiter;

/// Recurring interval timer.
pub const Interval = time.Interval;

/// Waiter for interval tick.
pub const IntervalWaiter = time.IntervalWaiter;

/// Deadline for timeout tracking.
pub const Deadline = time.Deadline;

/// Waiter for deadline expiration.
pub const DeadlineWaiter = time.DeadlineWaiter;

/// Error returned when timeout expires.
pub const TimeoutError = time.TimeoutError;

/// Timer driver for runtime integration.
pub const TimerDriver = time.TimerDriver;

/// Handle to a registered timer.
pub const TimerHandle = time.TimerHandle;

// ═══════════════════════════════════════════════════════════════════════════
// Networking
// ═══════════════════════════════════════════════════════════════════════════

/// Networking module (TCP, UDP, addresses).
///
/// ## Example: TCP Server
/// ```zig
/// var listener = try io.TcpListener.bind(io.Address.fromPort(8080));
/// defer listener.close();
/// while (listener.tryAccept() catch null) |result| {
///     handleClient(result.stream);
/// }
/// ```
///
/// ## Example: TCP Client
/// ```zig
/// var stream = try io.TcpStream.connect(io.Address.parse("127.0.0.1:8080"));
/// defer stream.close();
/// try stream.writeAll("Hello!");
/// ```
pub const net = @import("net.zig");

/// Socket address for TCP/UDP (IPv4 and IPv6).
///
/// ## Example
/// ```zig
/// const addr1 = io.Address.parse("127.0.0.1:8080");
/// const addr2 = io.Address.fromPort(8080);  // 0.0.0.0:8080
/// const addr3 = io.Address.initIpv4(.{192, 168, 1, 1}, 443);
/// ```
pub const Address = net.Address;

/// TCP socket builder for configuring options before connect/listen.
///
/// ## Example: Client with custom buffer sizes
/// ```zig
/// var socket = try io.TcpSocket.newV4();
/// try socket.setSendBufferSize(65536);
/// try socket.setRecvBufferSize(65536);
/// try socket.setKeepalive(.{ .time = io.Duration.fromSecs(60) });
/// var stream = try socket.connect(addr);
/// ```
pub const TcpSocket = net.TcpSocket;

/// TCP server listener. Use `bind()` to create, then `tryAccept()` for connections.
pub const TcpListener = net.TcpListener;

/// TCP stream (connected socket). Use `tryRead`/`tryWrite` for non-blocking I/O.
pub const TcpStream = net.TcpStream;

/// TCP keepalive configuration for detecting dead connections.
pub const Keepalive = net.Keepalive;

/// UDP socket for connectionless datagram communication.
///
/// ## Example
/// ```zig
/// var socket = try io.UdpSocket.bind(io.Address.fromPort(5000));
/// const result = try socket.recvFrom(&buf);
/// try socket.sendTo(response, result.addr);
/// ```
pub const UdpSocket = net.UdpSocket;

// Network convenience functions
/// Create a TCP listener from an address string (e.g., "0.0.0.0:8080").
pub const listen = net.listen;

/// Create a TCP listener on a port (binds to all interfaces).
pub const listenPort = net.listenPort;

/// Connect to a TCP server by address string (e.g., "127.0.0.1:8080").
pub const connect = net.connect;

/// Connect to a TCP server by hostname (with DNS resolution).
pub const connectHost = net.connectHost;

/// Resolve a hostname to IP addresses (blocking, uses system resolver).
pub const resolve = net.resolve;

/// Resolve a hostname and return the first address.
pub const resolveFirst = net.resolveFirst;

// ═══════════════════════════════════════════════════════════════════════════
// Filesystem
// ═══════════════════════════════════════════════════════════════════════════

/// Filesystem module (files, directories, paths).
pub const fs = @import("fs.zig");

/// File handle for reading and writing (synchronous).
pub const File = fs.File;

/// Async file handle (uses io_uring on Linux, blocking pool elsewhere).
pub const AsyncFile = fs.AsyncFile;

/// Options for opening files.
pub const OpenOptions = fs.OpenOptions;

// ═══════════════════════════════════════════════════════════════════════════
// I/O Interfaces (for stream composition)
// ═══════════════════════════════════════════════════════════════════════════

/// I/O Reader/Writer interfaces for layered stream composition.
/// Enables TLS, compression, and other stream wrappers.
pub const io = @import("io.zig");

/// Polymorphic reader interface.
pub const Reader = io.Reader;

/// Polymorphic writer interface.
pub const Writer = io.Writer;

/// Combined reader and writer.
pub const ReadWriter = io.ReadWriter;

// ═══════════════════════════════════════════════════════════════════════════
// I/O Utilities (buffering, copying, line iteration)
// ═══════════════════════════════════════════════════════════════════════════

/// Buffered reader - wraps any reader with an internal buffer.
/// Use for efficient small reads (e.g., line-by-line processing).
pub const BufReader = io.BufReader;

/// Create a buffered reader from any reader.
pub const bufReader = io.bufReader;

/// Buffered writer - wraps any writer with an internal buffer.
/// Use for efficient small writes (reduces syscalls).
pub const BufWriter = io.BufWriter;

/// Create a buffered writer from any writer.
pub const bufWriter = io.bufWriter;

/// Copy all data from reader to writer.
/// Returns total bytes copied.
pub const copy = io.copy;

/// Copy data with a custom buffer.
pub const copyBuf = io.copyBuf;

/// Copy at most n bytes from reader to writer.
pub const copyN = io.copyN;

/// Copy at most n bytes with a custom buffer.
pub const copyNBuf = io.copyNBuf;

/// Line iterator - reads lines from any reader.
/// Handles both \n and \r\n line endings.
pub const Lines = io.Lines;

/// Create a line iterator from any reader.
pub const lines = io.lines;

/// Create a line iterator with a custom buffer.
pub const linesWithBuffer = io.linesWithBuffer;

/// Split iterator - splits input by a delimiter byte.
pub const Split = io.Split;

/// Create a split iterator from any reader.
pub const split = io.split;

// Timeout utilities
/// Create a deadline for timeout tracking.
pub const deadline = io.deadline;

/// Run a function with a timeout (checks after completion).
pub const withTimeout = io.withTimeout;

/// Try to run a function within a timeout, returning a result union.
///
/// ## Example
/// ```zig
/// const result = io.tryTimeout(io.Duration.fromSecs(5), compute, .{data});
/// switch (result) {
///     .ok => |v| use(v),
///     .err => |e| log.err("Failed: {}", .{e}),
///     .timeout => log.warn("Timed out", .{}),
/// }
/// ```
pub const tryTimeout = io.tryTimeout;

/// Result type for tryTimeout operations.
pub const TryTimeoutResult = io.TryTimeoutResult;

// ═══════════════════════════════════════════════════════════════════════════
// Synchronization Primitives
// ═══════════════════════════════════════════════════════════════════════════

/// Synchronization primitives for async tasks.
///
/// All primitives are designed for async/await patterns with `tryX()` for
/// non-blocking fast paths and futures for async waiting.
pub const sync = @import("sync.zig");

/// Task notification primitive. Wake waiting tasks without sending data.
///
/// ## Example
/// ```zig
/// var notify = io.Notify.init();
///
/// // Waiter side
/// notify.wait();  // Block until notified
///
/// // Notifier side
/// notify.notifyOne();  // Wake one waiter
/// notify.notifyAll();  // Wake all waiters
/// ```
pub const Notify = sync.Notify;

/// Counting semaphore. Limit concurrent access to a resource.
///
/// ## Example: Connection limiter
/// ```zig
/// var sem = io.Semaphore.init(100);  // Max 100 connections
/// sem.acquire();  // Blocks if at limit
/// defer sem.release();
/// handleConnection();
/// ```
pub const Semaphore = sync.Semaphore;

/// Async mutex. Protects shared state across async tasks.
///
/// ## Example
/// ```zig
/// var mutex = io.Mutex.init();
/// mutex.lock();
/// defer mutex.unlock();
/// shared_state.update();
/// ```
pub const Mutex = sync.Mutex;

/// Single-value channel (oneshot). Send exactly one value from producer to consumer.
///
/// ## Example: Async result delivery
/// ```zig
/// var oneshot = io.Oneshot(Result).init();
///
/// // Producer (e.g., background task)
/// oneshot.send(computeResult());
///
/// // Consumer
/// const result = oneshot.recv();  // Blocks until value available
/// ```
pub const Oneshot = sync.Oneshot;

/// Bounded MPSC channel. Multiple producers, single consumer with backpressure.
///
/// ## Example: Work queue
/// ```zig
/// var channel = try io.Channel(Task).init(allocator, 100);  // Buffer 100 items
/// defer channel.deinit();
///
/// // Producers (multiple threads)
/// try channel.send(task);  // Blocks if full
///
/// // Consumer (single thread)
/// while (channel.tryRecv()) |task| {
///     processTask(task);
/// }
/// ```
pub const Channel = sync.Channel;

/// Structured concurrency scope - spawn tasks and wait for all to complete.
/// No manual counting (add/done), just spawn and wait.
///
/// ## Example: Parallel API Calls
/// ```zig
/// var scope = io.Scope.init(allocator);
/// defer scope.deinit();
///
/// try scope.spawnWithResult(fetchUser, .{id}, &profile.user);
/// try scope.spawnWithResult(fetchPosts, .{id}, &profile.posts);
///
/// try scope.wait();  // Blocks until all complete
/// ```
///
/// ## Example: Batch Processing
/// ```zig
/// var scope = io.Scope.init(allocator);
/// defer scope.deinit();
///
/// for (images) |image| {
///     try scope.spawn(processImage, .{image});
/// }
///
/// try scope.wait();
/// ```
pub const Scope = sync.Scope;

/// Convenience: run a function with a scope that auto-waits on exit.
pub const scoped = sync.scoped;

// ═══════════════════════════════════════════════════════════════════════════
// Signal Handling
// ═══════════════════════════════════════════════════════════════════════════

/// Signal handling module with async integration.
pub const signal = @import("signal.zig");

/// Unix signal identifier.
pub const Signal = signal.Signal;

/// Set of signals for filtering/masking.
pub const SignalSet = signal.SignalSet;

/// Low-level signal handler (file descriptor based).
pub const SignalHandler = signal.SignalHandler;

/// Async signal handler with waiter-based API.
pub const AsyncSignal = signal.AsyncSignal;

/// Waiter for async signal notification.
pub const SignalWaiter = signal.SignalWaiter;

/// Future for async signal handling - use with Select for graceful shutdown.
pub const SignalFuture = signal.SignalFuture;

/// Create a SignalFuture from an AsyncSignal handler.
pub const signalFuture = signal.signalFuture;

/// Wait for shutdown signal (SIGTERM or SIGINT, blocking).
pub const waitForShutdown = signal.waitForShutdown;

/// Wait for Ctrl+C signal (blocking).
pub const waitForCtrlC = signal.waitForCtrlC;

// ═══════════════════════════════════════════════════════════════════════════
// Graceful Shutdown
// ═══════════════════════════════════════════════════════════════════════════

/// Graceful shutdown coordination.
const shutdown_mod = @import("shutdown.zig");

/// Graceful shutdown handler for async servers.
///
/// ## Example
///
/// ```zig
/// var shutdown = try io.Shutdown.init();
/// defer shutdown.deinit();
///
/// while (!shutdown.isShutdown()) {
///     var select = io.Select2(AcceptFuture, ShutdownFuture).init(
///         listener.accept(),
///         shutdown.future(),
///     );
///     // ...
/// }
///
/// _ = shutdown.waitPending();  // Wait for in-flight work
/// ```
pub const Shutdown = shutdown_mod.Shutdown;

/// Future for shutdown notification - use with Select.
pub const ShutdownFuture = shutdown_mod.ShutdownFuture;

/// Guard for tracking pending work during shutdown.
pub const WorkGuard = shutdown_mod.WorkGuard;

// ═══════════════════════════════════════════════════════════════════════════
// Async Combinators (Timeout, Select, Join)
// ═══════════════════════════════════════════════════════════════════════════

/// Async combinators for composing futures.
///
/// Provides Tokio-style combinators:
/// - `Timeout`: Wrap a future with a deadline
/// - `Select2`, `Select3`: Race futures, return first to complete
/// - `Join2`, `Join3`: Run futures concurrently, wait for all
///
/// ## Example: Timeout
///
/// ```zig
/// var timeout = async_ops.Timeout(AcceptFuture).init(
///     listener.accept(),
///     Duration.fromSecs(30),
/// );
///
/// switch (timeout.poll(waker)) {
///     .ready => |conn| handleConnection(conn),
///     .timeout => log.warn("Accept timed out", .{}),
///     .pending => {},
/// }
/// ```
///
/// ## Example: Select (Race)
///
/// ```zig
/// var select = async_ops.Select2(AcceptFuture, ShutdownFuture).init(
///     listener.accept(),
///     shutdown.wait(),
/// );
///
/// switch (select.poll(waker)) {
///     .first => |conn| handleConnection(conn),
///     .second => |_| break,  // Shutdown
///     .pending => {},
/// }
/// ```
pub const async_ops = @import("async.zig");

/// Timeout combinator - wraps a future with a deadline.
pub const Timeout = async_ops.Timeout;

/// Select2 combinator - race two futures.
pub const Select2 = async_ops.Select2;

/// Select3 combinator - race three futures.
pub const Select3 = async_ops.Select3;

/// Join2 combinator - wait for two futures concurrently.
pub const Join2 = async_ops.Join2;

/// Join3 combinator - wait for three futures concurrently.
pub const Join3 = async_ops.Join3;

/// SelectN combinator - race N homogeneous futures.
///
/// ## Example
/// ```zig
/// var futures = [_]FetchFuture{ fetch(url1), fetch(url2), fetch(url3) };
/// var select = io.SelectN(FetchFuture, 3).init(&futures);
/// switch (select.poll(waker)) {
///     .ready => |r| std.debug.print("Future {} won\n", .{r.index}),
///     .pending => {},
///     .err => |e| return e.@"error",
/// }
/// ```
pub const SelectN = async_ops.SelectN;

/// JoinN combinator - wait for N homogeneous futures.
///
/// ## Example
/// ```zig
/// var futures = [_]FetchFuture{ fetch(url1), fetch(url2) };
/// var join = io.JoinN(FetchFuture, 2).init(&futures);
/// switch (join.poll(waker)) {
///     .ready => |results| for (results) |r| process(r),
///     .pending => {},
///     .err => |e| return e.@"error",
/// }
/// ```
pub const JoinN = async_ops.JoinN;

/// Race combinator - like Promise.race(). Returns first value.
///
/// ## Example
/// ```zig
/// var futures = [_]FetchFuture{ fetch(url1), fetch(url2) };
/// var racer = io.Race(FetchFuture, 2).init(&futures);
/// switch (racer.poll(waker)) {
///     .ok => |value| return value,
///     .err => |e| return e,
///     .pending => {},
/// }
/// ```
pub const Race = async_ops.Race;

/// All combinator - like Promise.all(). Waits for all, returns array.
///
/// ## Example
/// ```zig
/// var futures = [_]FetchFuture{ fetch(url1), fetch(url2) };
/// var joiner = io.All(FetchFuture, 2).init(&futures);
/// switch (joiner.poll(waker)) {
///     .ok => |values| for (values) |v| process(v),
///     .err => |e| return e,
///     .pending => {},
/// }
/// ```
pub const All = async_ops.All;

// Convenience functions for creating combinators
pub const selectN = async_ops.selectN;
pub const joinN = async_ops.joinN;
pub const race = async_ops.race;
pub const all = async_ops.all;

// ═══════════════════════════════════════════════════════════════════════════
// Process Management
// ═══════════════════════════════════════════════════════════════════════════

/// Process spawning and management module.
///
/// ## Example: Run command and capture output
/// ```zig
/// var cmd = io.Command.init(&.{"ls", "-la", "/tmp"});
/// cmd.setStdout(.pipe);
/// cmd.setStderr(.pipe);
/// var child = try cmd.spawn();
///
/// const stdout = try child.stdout.?.readAll(allocator);
/// defer allocator.free(stdout);
///
/// const status = try child.wait();
/// if (status.success()) {
///     std.debug.print("Output: {s}\n", .{stdout});
/// }
/// ```
///
/// ## Example: Pipe data to command
/// ```zig
/// var cmd = io.Command.init(&.{"wc", "-l"});
/// cmd.setStdin(.pipe);
/// cmd.setStdout(.pipe);
/// var child = try cmd.spawn();
///
/// try child.stdin.?.writeAll("line1\nline2\nline3\n");
/// child.stdin.?.close();
///
/// const output = try child.stdout.?.readAll(allocator);
/// _ = try child.wait();
/// ```
pub const process = @import("process.zig");

/// Command builder for spawning processes. Configure args, env, cwd, and stdio.
pub const Command = process.Command;

/// Child process handle. Use `wait()` to get exit status.
pub const Child = process.Child;

/// Exit status of a child process. Check `success()` or `code()`.
pub const ExitStatus = process.ExitStatus;

/// Piped stdin for a child process. Write data to the child.
pub const ChildStdin = process.ChildStdin;

/// Piped stdout from a child process. Read command output.
pub const ChildStdout = process.ChildStdout;

/// Piped stderr from a child process. Read error output.
pub const ChildStderr = process.ChildStderr;

/// Waiter for async process waiting.
pub const WaitWaiter = process.WaitWaiter;

// ═══════════════════════════════════════════════════════════════════════════
// Low-Level Access (for advanced users)
// ═══════════════════════════════════════════════════════════════════════════

/// I/O backend abstraction (io_uring, kqueue, epoll, etc.)
pub const backend = @import("backend.zig");

/// Task executor (scheduler, workers, queues)
pub const executor = @import("executor.zig");

/// Utility data structures (slab, linked list, etc.)
pub const util = struct {
    pub const Slab = @import("util/slab.zig").Slab;
    pub const LinkedList = @import("util/linked_list.zig").LinkedList;
    pub const Pointers = @import("util/linked_list.zig").Pointers;
};

/// Testing utilities (concurrency framework, atomic logging)
pub const testing = struct {
    pub const concurrency = @import("test/concurrency.zig");
    pub const atomic_log = @import("test/atomic_log.zig");
};

/// Blocking thread pool
pub const BlockingPool = @import("blocking.zig").BlockingPool;

// ═══════════════════════════════════════════════════════════════════════════
// Version
// ═══════════════════════════════════════════════════════════════════════════

pub const version = struct {
    pub const major = 0;
    pub const minor = 1;
    pub const patch = 0;
    pub const string = "0.1.0";
};

// ═══════════════════════════════════════════════════════════════════════════
// Platform Detection
// ═══════════════════════════════════════════════════════════════════════════

/// Detect the best I/O backend for this platform.
pub const detectBestBackend = backend.detectBestBackend;

/// Check if io_uring is supported.
pub const isIoUringSupported = backend.isIoUringSupported;

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test {
    // Run all module tests
    _ = @import("time.zig");
    _ = @import("blocking.zig");
    _ = @import("runtime.zig");
    _ = @import("backend.zig");
    _ = @import("executor.zig");
    _ = @import("net.zig");
    _ = @import("io.zig");
    _ = @import("fs.zig");
    _ = @import("sync.zig");
    _ = @import("util/signal.zig");
    _ = @import("signal.zig");
    _ = @import("process.zig");
    _ = @import("async.zig");
    _ = @import("shutdown.zig");
}

test "version" {
    try std.testing.expect(version.major >= 0);
    try std.testing.expect(version.string.len > 0);
}
