const std = @import("std");
const darwin = @import("builtin").os.tag == .macos;
const c = std.c;

pub const native = struct {
    pub extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
    pub extern "c" fn chmod([*:0]const u8, c.mode_t) c_int;
    pub extern "c" fn mkfifo([*:0]const u8, c.mode_t) c_int;
    pub extern "c" fn copyfile([*:0]const u8, [*:0]const u8, ?*anyopaque, u32) c_int;
    pub extern "c" fn acl_init(c_int) ?*anyopaque;
    pub extern "c" fn acl_set_file([*:0]const u8, c_int, *anyopaque) c_int;
    pub extern "c" fn acl_free(?*anyopaque) c_int;
    pub extern "c" fn acl_get_link_np([*:0]const u8, c_int) ?*anyopaque;
    pub extern "c" fn acl_set_link_np([*:0]const u8, c_int, *anyopaque) c_int;
    pub const ACL_TYPE_EXTENDED = 0x100;
    pub extern "c" fn llistxattr([*:0]const u8, ?[*]u8, usize) isize;
    pub extern "c" fn listxattr([*:0]const u8, ?[*]u8, usize, c_int) isize;
    pub extern "c" fn lgetxattr([*:0]const u8, [*:0]const u8, ?[*]u8, usize) isize;
    pub extern "c" fn lsetxattr([*:0]const u8, [*:0]const u8, [*]const u8, usize, c_int) c_int;
    pub extern "c" fn lremovexattr([*:0]const u8, [*:0]const u8) c_int;
    pub extern "c" fn getxattr([*:0]const u8, [*:0]const u8, ?[*]u8, usize, u32, c_int) isize;
    pub extern "c" fn setxattr([*:0]const u8, [*:0]const u8, [*]const u8, usize, u32, c_int) c_int;
    pub const COPYFILE_ALL: u32 = 0xf;
    pub const COPYFILE_METADATA: u32 = 0x7;
    pub const COPYFILE_EXCL: u32 = 1 << 17;
    pub const COPYFILE_NOFOLLOW: u32 = (1 << 18) | (1 << 19);
    pub const XATTR_NOFOLLOW: c_int = 1;
};

pub const Metadata = struct {
    device: u64,
    inode: u64,
    mode: c.mode_t,
    nlink: u64,
    uid: c.uid_t,
    gid: c.gid_t,
    atime: c.timespec,
    mtime: c.timespec,

    pub fn read(path: [:0]const u8) !Metadata {
        if (darwin) {
            var value: c.Stat = undefined;
            if (c.fstatat(c.AT.FDCWD, path, &value, c.AT.SYMLINK_NOFOLLOW) != 0) return error.StatFailed;
            return .{
                .device = @as(u32, @bitCast(value.dev)),
                .inode = value.ino,
                .mode = value.mode,
                .nlink = value.nlink,
                .uid = value.uid,
                .gid = value.gid,
                .atime = value.atime(),
                .mtime = value.mtime(),
            };
        }
        const linux = std.os.linux;
        var value: linux.Statx = undefined;
        const wanted: linux.STATX = .{
            .TYPE = true,
            .MODE = true,
            .NLINK = true,
            .UID = true,
            .GID = true,
            .ATIME = true,
            .MTIME = true,
            .INO = true,
        };
        if (linux.errno(linux.statx(c.AT.FDCWD, path, c.AT.SYMLINK_NOFOLLOW, wanted, &value)) != .SUCCESS)
            return error.StatFailed;
        const mask: u32 = @bitCast(wanted);
        if (@as(u32, @bitCast(value.mask)) & mask != mask) return error.IncompleteMetadata;
        return .{
            .device = (@as(u64, value.dev_major) << 32) | value.dev_minor,
            .inode = value.ino,
            .mode = value.mode,
            .nlink = value.nlink,
            .uid = value.uid,
            .gid = value.gid,
            .atime = .{ .sec = @intCast(value.atime.sec), .nsec = @intCast(value.atime.nsec) },
            .mtime = .{ .sec = @intCast(value.mtime.sec), .nsec = @intCast(value.mtime.nsec) },
        };
    }
};

pub const CopyContext = struct {
    arena: std.heap.ArenaAllocator,
    hardlinks: std.AutoHashMapUnmanaged(Inode, [:0]const u8) = .empty,

    const Inode = struct { device: u64, inode: u64 };

    pub fn init(a: std.mem.Allocator) CopyContext {
        return .{ .arena = .init(a) };
    }

    pub fn deinit(self: *CopyContext) void {
        self.arena.deinit();
    }

    pub fn copy(self: *CopyContext, io: std.Io, from: []const u8, to: []const u8) anyerror!void {
        const a = self.arena.allocator();
        const source = try a.dupeSentinel(u8, from, 0);
        const destination = try a.dupeSentinel(u8, to, 0);
        const stat = try Metadata.read(source);
        const kind = stat.mode & c.S.IFMT;
        const inode: Inode = .{ .device = stat.device, .inode = stat.inode };
        if (kind != c.S.IFDIR and stat.nlink > 1) {
            if (self.hardlinks.get(inode)) |previous| {
                if (c.linkat(c.AT.FDCWD, previous, c.AT.FDCWD, destination, 0) != 0)
                    return error.HardlinkFailed;
                return;
            }
        }

        switch (kind) {
            c.S.IFDIR => {
                if (c.mkdir(destination, 0o700) != 0) return error.CreateDirectoryFailed;
                if (native.chmod(destination, 0o700) != 0) return error.SetPermissionsFailed;
                var input = try std.Io.Dir.cwd().openDir(io, from, .{ .iterate = true });
                defer input.close(io);
                var iterator = input.iterate();
                while (try iterator.next(io)) |entry| {
                    try self.copy(io, try std.fs.path.join(a, &.{ from, entry.name }), try std.fs.path.join(a, &.{ to, entry.name }));
                }
            },
            c.S.IFREG => {
                if (darwin) {
                    if (native.copyfile(source, destination, null, native.COPYFILE_ALL | native.COPYFILE_NOFOLLOW | native.COPYFILE_EXCL) != 0)
                        return error.CopyFileFailed;
                } else {
                    const input = c.open(source, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true });
                    if (input < 0) return error.OpenSourceFailed;
                    defer _ = c.close(input);
                    const output = c.open(destination, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
                    if (output < 0) return error.CreateFileFailed;
                    defer _ = c.close(output);
                    var buffer: [64 * 1024]u8 = undefined;
                    while (true) {
                        const count = c.read(input, &buffer, buffer.len);
                        if (count < 0) {
                            if (std.c.errno(count) == .INTR) continue;
                            return error.ReadFailed;
                        }
                        if (count == 0) break;
                        var written: usize = 0;
                        while (written < count) {
                            const size = c.write(output, buffer[written..].ptr, @as(usize, @intCast(count)) - written);
                            if (size < 0) {
                                if (std.c.errno(size) == .INTR) continue;
                                return error.WriteFailed;
                            }
                            if (size == 0) return error.WriteFailed;
                            written += @intCast(size);
                        }
                    }
                }
            },
            c.S.IFLNK => {
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const len = try std.Io.Dir.cwd().readLink(io, from, &buffer);
                const target = try a.dupeSentinel(u8, buffer[0..len], 0);
                if (c.symlink(target, destination) != 0) return error.CreateSymlinkFailed;
            },
            c.S.IFIFO => {
                if (native.mkfifo(destination, 0o600) != 0) return error.CreateFifoFailed;
            },
            else => return error.UnsupportedFileType,
        }

        if (c.fchownat(c.AT.FDCWD, destination, stat.uid, stat.gid, c.AT.SYMLINK_NOFOLLOW) != 0)
            return error.PreserveOwnershipFailed;
        if (darwin) {
            if (kind == c.S.IFIFO) {
                const acl = native.acl_get_link_np(source, native.ACL_TYPE_EXTENDED) orelse blk: {
                    if (c.errno(@as(c_int, -1)) != .NOENT) return error.ReadAclFailed;
                    break :blk native.acl_init(0) orelse return error.CreateAclFailed;
                };
                defer _ = native.acl_free(acl);
                if (native.acl_set_link_np(destination, native.ACL_TYPE_EXTENDED, acl) != 0)
                    return error.PreserveAclFailed;
                try self.copyXattrs(source, destination);
            } else if (native.copyfile(source, destination, null, native.COPYFILE_METADATA | native.COPYFILE_NOFOLLOW) != 0)
                return error.PreserveMetadataFailed;
        } else {
            try self.copyXattrs(source, destination);
        }
        if (kind != c.S.IFLNK) {
            if (c.fchmodat(c.AT.FDCWD, destination, stat.mode & 0o7777, 0) != 0)
                return error.SetPermissionsFailed;
        } else if (darwin) {
            if (c.fchmodat(c.AT.FDCWD, destination, stat.mode & 0o7777, c.AT.SYMLINK_NOFOLLOW) != 0)
                return error.SetPermissionsFailed;
        }
        const times: [2]c.timespec = .{ stat.atime, stat.mtime };
        if (c.utimensat(c.AT.FDCWD, destination, &times, c.AT.SYMLINK_NOFOLLOW) != 0)
            return error.PreserveTimestampsFailed;
        if (kind != c.S.IFDIR and stat.nlink > 1)
            try self.hardlinks.put(a, inode, destination);
    }

    fn copyXattrs(self: *CopyContext, from: [:0]const u8, to: [:0]const u8) !void {
        const a = self.arena.allocator();
        const size = if (darwin) native.listxattr(from, null, 0, native.XATTR_NOFOLLOW) else native.llistxattr(from, null, 0);
        if (size < 0) {
            if (std.c.errno(size) == .OPNOTSUPP) return;
            return error.ListXattrsFailed;
        }
        const names = try a.alloc(u8, @intCast(size));
        const count = if (darwin) native.listxattr(from, names.ptr, names.len, native.XATTR_NOFOLLOW) else native.llistxattr(from, names.ptr, names.len);
        if (count < 0 or count > names.len) return error.ListXattrsFailed;
        var start: usize = 0;
        while (start < count) {
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(names[start..].ptr)), 0);
            const length = if (darwin) native.getxattr(from, name, null, 0, 0, native.XATTR_NOFOLLOW) else native.lgetxattr(from, name, null, 0);
            if (length < 0) return error.ReadXattrFailed;
            const value = try a.alloc(u8, @intCast(length));
            const read = if (darwin) native.getxattr(from, name, value.ptr, value.len, 0, native.XATTR_NOFOLLOW) else native.lgetxattr(from, name, value.ptr, value.len);
            if (read != length) return error.ReadXattrFailed;
            const result = if (darwin) native.setxattr(to, name, value.ptr, value.len, 0, native.XATTR_NOFOLLOW) else native.lsetxattr(to, name, value.ptr, value.len, 0);
            if (result != 0)
                return error.PreserveXattrFailed;
            start += name.len + 1;
        }
    }
};
