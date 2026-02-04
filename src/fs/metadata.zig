//! File Metadata - Information about files and directories
//!
//! Provides types for querying file metadata including size, timestamps,
//! permissions, and file type.

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

/// Metadata about a file or directory.
pub const Metadata = struct {
    inner: posix.Stat,

    /// Create Metadata from a posix Stat.
    pub fn fromStat(stat: posix.Stat) Metadata {
        return .{ .inner = stat };
    }

    /// Get the file type.
    pub fn fileType(self: Metadata) FileType {
        return FileType.fromMode(self.inner.mode);
    }

    /// Returns true if this is a regular file.
    pub fn isFile(self: Metadata) bool {
        return self.fileType() == .file;
    }

    /// Returns true if this is a directory.
    pub fn isDir(self: Metadata) bool {
        return self.fileType() == .directory;
    }

    /// Returns true if this is a symbolic link.
    pub fn isSymlink(self: Metadata) bool {
        return self.fileType() == .sym_link;
    }

    /// Get the size of the file in bytes.
    pub fn size(self: Metadata) u64 {
        return @intCast(self.inner.size);
    }

    /// Get the permissions.
    pub fn permissions(self: Metadata) Permissions {
        return Permissions.fromMode(self.inner.mode);
    }

    /// Get the last modification time as seconds since Unix epoch.
    pub fn modified(self: Metadata) i64 {
        return self.inner.mtime().tv_sec;
    }

    /// Get the last access time as seconds since Unix epoch.
    pub fn accessed(self: Metadata) i64 {
        return self.inner.atime().tv_sec;
    }

    /// Get the creation time as seconds since Unix epoch (if available).
    /// Returns null on platforms that don't support creation time.
    pub fn created(self: Metadata) ?i64 {
        if (comptime builtin.os.tag == .linux) {
            // Linux doesn't have creation time in stat
            return null;
        } else if (comptime builtin.os.tag == .macos or builtin.os.tag == .freebsd) {
            return self.inner.birthtime().tv_sec;
        } else {
            return null;
        }
    }

    /// Get the raw mode bits.
    pub fn mode(self: Metadata) u32 {
        return self.inner.mode;
    }

    /// Get the device ID (Unix).
    pub fn dev(self: Metadata) u64 {
        return self.inner.dev;
    }

    /// Get the inode number (Unix).
    pub fn ino(self: Metadata) u64 {
        return self.inner.ino;
    }

    /// Get the number of hard links.
    pub fn nlink(self: Metadata) u64 {
        return self.inner.nlink;
    }

    /// Get the user ID of the owner (Unix).
    pub fn uid(self: Metadata) u32 {
        return self.inner.uid;
    }

    /// Get the group ID of the owner (Unix).
    pub fn gid(self: Metadata) u32 {
        return self.inner.gid;
    }

    /// Get the block size for filesystem I/O.
    pub fn blksize(self: Metadata) u64 {
        return @intCast(self.inner.blksize);
    }

    /// Get the number of 512-byte blocks allocated.
    pub fn blocks(self: Metadata) u64 {
        return @intCast(self.inner.blocks);
    }
};

/// Type of a file system entry.
pub const FileType = enum {
    file,
    directory,
    sym_link,
    block_device,
    char_device,
    fifo,
    socket,
    unknown,

    /// Extract file type from mode bits.
    pub fn fromMode(mode: u32) FileType {
        const kind = mode & posix.S.IFMT;
        return switch (kind) {
            posix.S.IFREG => .file,
            posix.S.IFDIR => .directory,
            posix.S.IFLNK => .sym_link,
            posix.S.IFBLK => .block_device,
            posix.S.IFCHR => .char_device,
            posix.S.IFIFO => .fifo,
            posix.S.IFSOCK => .socket,
            else => .unknown,
        };
    }

    pub fn isFile(self: FileType) bool {
        return self == .file;
    }

    pub fn isDir(self: FileType) bool {
        return self == .directory;
    }

    pub fn isSymlink(self: FileType) bool {
        return self == .sym_link;
    }
};

/// File permissions.
pub const Permissions = struct {
    mode: u32,

    /// Create Permissions from mode bits.
    pub fn fromMode(mode: u32) Permissions {
        return .{ .mode = mode & 0o7777 };
    }

    /// Create Permissions from an octal mode (e.g., 0o755).
    pub fn fromOctal(octal: u32) Permissions {
        return .{ .mode = octal & 0o7777 };
    }

    /// Check if the file is readonly (no write permission for anyone).
    pub fn readonly(self: Permissions) bool {
        return (self.mode & 0o222) == 0;
    }

    /// Set readonly status.
    pub fn setReadonly(self: *Permissions, value: bool) void {
        if (value) {
            self.mode &= ~@as(u32, 0o222);
        } else {
            self.mode |= 0o200; // At least owner write
        }
    }

    /// Get the raw mode bits (e.g., 0o755).
    pub fn getMode(self: Permissions) u32 {
        return self.mode;
    }

    /// Check owner read permission.
    pub fn ownerRead(self: Permissions) bool {
        return (self.mode & posix.S.IRUSR) != 0;
    }

    /// Check owner write permission.
    pub fn ownerWrite(self: Permissions) bool {
        return (self.mode & posix.S.IWUSR) != 0;
    }

    /// Check owner execute permission.
    pub fn ownerExecute(self: Permissions) bool {
        return (self.mode & posix.S.IXUSR) != 0;
    }

    /// Check group read permission.
    pub fn groupRead(self: Permissions) bool {
        return (self.mode & posix.S.IRGRP) != 0;
    }

    /// Check group write permission.
    pub fn groupWrite(self: Permissions) bool {
        return (self.mode & posix.S.IWGRP) != 0;
    }

    /// Check group execute permission.
    pub fn groupExecute(self: Permissions) bool {
        return (self.mode & posix.S.IXGRP) != 0;
    }

    /// Check other read permission.
    pub fn otherRead(self: Permissions) bool {
        return (self.mode & posix.S.IROTH) != 0;
    }

    /// Check other write permission.
    pub fn otherWrite(self: Permissions) bool {
        return (self.mode & posix.S.IWOTH) != 0;
    }

    /// Check other execute permission.
    pub fn otherExecute(self: Permissions) bool {
        return (self.mode & posix.S.IXOTH) != 0;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

test "Permissions - basic operations" {
    var perm = Permissions.fromOctal(0o755);

    try std.testing.expect(perm.ownerRead());
    try std.testing.expect(perm.ownerWrite());
    try std.testing.expect(perm.ownerExecute());
    try std.testing.expect(perm.groupRead());
    try std.testing.expect(!perm.groupWrite());
    try std.testing.expect(perm.groupExecute());
    try std.testing.expect(!perm.readonly());

    perm.setReadonly(true);
    try std.testing.expect(perm.readonly());
}

test "FileType - from mode" {
    try std.testing.expectEqual(FileType.file, FileType.fromMode(posix.S.IFREG));
    try std.testing.expectEqual(FileType.directory, FileType.fromMode(posix.S.IFDIR));
    try std.testing.expectEqual(FileType.sym_link, FileType.fromMode(posix.S.IFLNK));
}
