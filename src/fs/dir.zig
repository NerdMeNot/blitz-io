//! Directory Operations
//!
//! Functions for creating, reading, and removing directories.
//!
//! ## Example
//!
//! ```zig
//! // Create a directory
//! try createDir("new_folder");
//!
//! // Create nested directories
//! try createDirAll("path/to/nested/folder");
//!
//! // List directory contents
//! var iter = try readDir(".");
//! defer iter.close();
//!
//! while (try iter.next()) |entry| {
//!     std.debug.print("{s}\n", .{entry.name});
//! }
//! ```

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const mem = std.mem;

const Metadata = @import("metadata.zig").Metadata;
const FileType = @import("metadata.zig").FileType;

/// Create a new directory.
pub fn createDir(path: []const u8) !void {
    const path_z = try posix.toPosixPath(path);
    try posix.mkdiratZ(posix.AT.FDCWD, &path_z, 0o755);
}

/// Create a new directory with specific permissions.
pub fn createDirMode(path: []const u8, mode: u32) !void {
    const path_z = try posix.toPosixPath(path);
    try posix.mkdiratZ(posix.AT.FDCWD, &path_z, mode);
}

/// Create a directory and all parent directories as needed.
pub fn createDirAll(path: []const u8) !void {
    // Find each path component and create if missing
    var end: usize = 0;

    while (end < path.len) {
        // Find next separator
        while (end < path.len and path[end] != '/') : (end += 1) {}

        if (end > 0) {
            const subpath = path[0..end];
            createDir(subpath) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        end += 1;
    }

    // Create the final directory
    if (path.len > 0) {
        createDir(path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
}

/// Remove an empty directory.
pub fn removeDir(path: []const u8) !void {
    const path_z = try posix.toPosixPath(path);
    try posix.unlinkatZ(posix.AT.FDCWD, &path_z, posix.AT.REMOVEDIR);
}

/// Remove a directory and all its contents recursively.
pub fn removeDirAll(allocator: mem.Allocator, path: []const u8) !void {
    // Open the directory
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => {
            // It's a file, just remove it
            return removeFile(path);
        },
        else => return err,
    };
    defer dir.close();

    // Iterate and remove contents
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const full_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(full_path);

        switch (entry.kind) {
            .directory => try removeDirAll(allocator, full_path),
            else => try removeFile(full_path),
        }
    }

    // Now remove the empty directory
    try removeDir(path);
}

/// Remove a file.
pub fn removeFile(path: []const u8) !void {
    const path_z = try posix.toPosixPath(path);
    try posix.unlinkatZ(posix.AT.FDCWD, &path_z, 0);
}

/// Directory entry from readDir.
pub const DirEntry = struct {
    name: []const u8,
    kind: FileType,

    /// Check if this entry is a file.
    pub fn isFile(self: DirEntry) bool {
        return self.kind == .file;
    }

    /// Check if this entry is a directory.
    pub fn isDir(self: DirEntry) bool {
        return self.kind == .directory;
    }

    /// Check if this entry is a symbolic link.
    pub fn isSymlink(self: DirEntry) bool {
        return self.kind == .sym_link;
    }
};

/// Iterator over directory entries.
pub const ReadDir = struct {
    inner: std.fs.Dir.Iterator,
    dir: std.fs.Dir,

    /// Get the next entry, or null if done.
    pub fn next(self: *ReadDir) !?DirEntry {
        if (try self.inner.next()) |entry| {
            return DirEntry{
                .name = entry.name,
                .kind = fromStdKind(entry.kind),
            };
        }
        return null;
    }

    /// Close the directory iterator.
    pub fn close(self: *ReadDir) void {
        self.dir.close();
    }

    fn fromStdKind(kind: std.fs.Dir.Entry.Kind) FileType {
        return switch (kind) {
            .file => .file,
            .directory => .directory,
            .sym_link => .sym_link,
            .block_device => .block_device,
            .character_device => .char_device,
            .named_pipe => .fifo,
            .unix_domain_socket => .socket,
            else => .unknown,
        };
    }
};

/// Open a directory for iteration.
pub fn readDir(path: []const u8) !ReadDir {
    const dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    return ReadDir{
        .inner = dir.iterate(),
        .dir = dir,
    };
}

/// Directory builder with configurable options.
pub const DirBuilder = struct {
    recursive: bool = false,
    mode: u32 = 0o755,

    pub fn new() DirBuilder {
        return .{};
    }

    /// Create parent directories as needed.
    pub fn setRecursive(self: DirBuilder, value: bool) DirBuilder {
        var builder = self;
        builder.recursive = value;
        return builder;
    }

    /// Set the directory permissions.
    pub fn setMode(self: DirBuilder, mode: u32) DirBuilder {
        var builder = self;
        builder.mode = mode;
        return builder;
    }

    /// Create the directory.
    pub fn create(self: DirBuilder, path: []const u8) !void {
        if (self.recursive) {
            try createDirAll(path);
            // Set final mode
            const path_z = try posix.toPosixPath(path);
            try posix.chmodZ(&path_z, self.mode);
        } else {
            try createDirMode(path, self.mode);
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

test "createDir and removeDir" {
    const path = "/tmp/blitz_io_test_dir";

    try createDir(path);
    defer removeDir(path) catch {};

    // Verify it exists
    const path_z = try posix.toPosixPath(path);
    const stat = try posix.fstatatZ(posix.AT.FDCWD, &path_z, 0);
    try std.testing.expect((stat.mode & posix.S.IFMT) == posix.S.IFDIR);
}

test "createDirAll" {
    const path = "/tmp/blitz_io_test_nested/a/b/c";

    try createDirAll(path);
    defer removeDirAll(std.testing.allocator, "/tmp/blitz_io_test_nested") catch {};

    // Verify deepest dir exists
    const path_z = try posix.toPosixPath(path);
    const stat = try posix.fstatatZ(posix.AT.FDCWD, &path_z, 0);
    try std.testing.expect((stat.mode & posix.S.IFMT) == posix.S.IFDIR);
}

test "readDir" {
    const path = "/tmp/blitz_io_test_readdir";

    try createDir(path);
    defer removeDirAll(std.testing.allocator, path) catch {};

    // Create some files
    {
        var f = try std.fs.cwd().createFile("/tmp/blitz_io_test_readdir/file1.txt", .{});
        f.close();
    }
    {
        var f = try std.fs.cwd().createFile("/tmp/blitz_io_test_readdir/file2.txt", .{});
        f.close();
    }

    // Read directory
    var iter = try readDir(path);
    defer iter.close();

    var count: usize = 0;
    while (try iter.next()) |entry| {
        try std.testing.expect(entry.isFile());
        count += 1;
    }

    try std.testing.expectEqual(@as(usize, 2), count);
}

test "DirBuilder" {
    const builder = DirBuilder.new()
        .setRecursive(true)
        .setMode(0o700);

    try std.testing.expect(builder.recursive);
    try std.testing.expectEqual(@as(u32, 0o700), builder.mode);
}
