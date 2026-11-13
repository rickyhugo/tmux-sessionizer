const std = @import("std");
const darwin = @import("builtin").os.tag == .macos;
const c = std.c;

pub const native = struct {
    pub extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
    pub extern "c" fn chmod([*:0]const u8, c.mode_t) c_int;
    pub extern "c" fn lchflags([*:0]const u8, u32) c_int;
    pub extern "c" fn mkfifo([*:0]const u8, c.mode_t) c_int;
    pub extern "c" fn copyfile([*:0]const u8, [*:0]const u8, ?*anyopaque, u32) c_int;
    pub extern "c" fn acl_init(c_int) ?*anyopaque;
    pub extern "c" fn acl_free(?*anyopaque) c_int;
    pub extern "c" fn acl_get_link_np([*:0]const u8, c_int) ?*anyopaque;
    pub extern "c" fn acl_set_link_np([*:0]const u8, c_int, *anyopaque) c_int;
    pub extern "c" fn acl_get_entry(*anyopaque, c_int, *?*anyopaque) c_int;
    pub extern "c" fn acl_create_entry(*?*anyopaque, *?*anyopaque) c_int;
    pub extern "c" fn acl_copy_entry(*anyopaque, *anyopaque) c_int;
    pub extern "c" fn acl_get_flagset_np(*anyopaque, *?*anyopaque) c_int;
    pub extern "c" fn acl_get_flag_np(*anyopaque, c_int) c_int;
    pub extern "c" fn acl_add_flag_np(*anyopaque, c_int) c_int;
    pub extern "c" fn acl_delete_flag_np(*anyopaque, c_int) c_int;
    pub const ACL_TYPE_EXTENDED = 0x100;
    pub extern "c" fn llistxattr([*:0]const u8, ?[*]u8, usize) isize;
    pub extern "c" fn listxattr([*:0]const u8, ?[*]u8, usize, c_int) isize;
    pub extern "c" fn lgetxattr([*:0]const u8, [*:0]const u8, ?[*]u8, usize) isize;
    pub extern "c" fn lsetxattr([*:0]const u8, [*:0]const u8, [*]const u8, usize, c_int) c_int;
    pub extern "c" fn lremovexattr([*:0]const u8, [*:0]const u8) c_int;
    pub extern "c" fn getxattr([*:0]const u8, [*:0]const u8, ?[*]u8, usize, u32, c_int) isize;
    pub extern "c" fn setxattr([*:0]const u8, [*:0]const u8, [*]const u8, usize, u32, c_int) c_int;
    pub const COPYFILE_XATTR: u32 = 1 << 2;
    pub const COPYFILE_DATA: u32 = 1 << 3;
    pub const COPYFILE_EXCL: u32 = 1 << 17;
    pub const COPYFILE_NOFOLLOW: u32 = (1 << 18) | (1 << 19);
    pub const XATTR_NOFOLLOW: c_int = 1;
    pub const UF_IMMUTABLE: u32 = 0x2;
    pub const UF_APPEND: u32 = 0x4;
    pub const UF_COMPRESSED: u32 = 0x20;
    pub const UF_TRACKED: u32 = 0x40;
    pub const UF_DATAVAULT: u32 = 0x80;
    pub const SF_IMMUTABLE: u32 = 0x20000;
    pub const SF_APPEND: u32 = 0x40000;
    pub const SF_RESTRICTED: u32 = 0x80000;
    pub const SF_NOUNLINK: u32 = 0x100000;
    pub const COPYFILE_PRESERVE_FLAGS: u32 = UF_DATAVAULT | SF_RESTRICTED | SF_NOUNLINK;
    pub const COPYFILE_OMIT_FLAGS: u32 = UF_TRACKED | COPYFILE_PRESERVE_FLAGS;
    pub const BLOCKING_FLAGS: u32 = UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND;
};

const Acl = struct {
    value: ?*anyopaque = null,

    const inherited = 1 << 4;
    const file_inherit = 1 << 5;
    const directory_inherit = 1 << 6;
    const limit_inherit = 1 << 7;
    const only_inherit = 1 << 8;
    const no_inherit = 1 << 17;

    fn read(path: [:0]const u8) !Acl {
        const value = native.acl_get_link_np(path, native.ACL_TYPE_EXTENDED);
        if (value == null and c.errno(@as(c_int, -1)) != .NOENT) return error.ReadAclFailed;
        return .{ .value = value };
    }

    fn deinit(self: Acl) void {
        if (darwin) {
            if (self.value) |value| _ = native.acl_free(value);
        }
    }

    fn blocksInheritance(self: Acl) !bool {
        const value = self.value orelse return false;
        var flags: ?*anyopaque = null;
        if (native.acl_get_flagset_np(value, &flags) != 0) return error.ReadAclFailed;
        return native.acl_get_flag_np(flags.?, no_inherit) == 1;
    }

    fn inherit(parent: Acl, directory: bool) !Acl {
        var result: Acl = .{};
        errdefer result.deinit();
        const value = parent.value orelse return result;
        var entry: ?*anyopaque = null;
        var next: c_int = 0;
        while (native.acl_get_entry(value, next, &entry) == 0) {
            next = -1;
            var flags: ?*anyopaque = null;
            if (native.acl_get_flagset_np(entry.?, &flags) != 0) return error.ReadAclFailed;
            if (native.acl_get_flag_np(flags.?, if (directory) directory_inherit else file_inherit) != 1)
                continue;
            const copied = try result.appendEntry(entry.?);
            if (native.acl_get_flagset_np(copied, &flags) != 0) return error.ReadAclFailed;
            if (native.acl_add_flag_np(flags.?, inherited) != 0 or
                native.acl_delete_flag_np(flags.?, only_inherit) != 0)
                return error.PreserveAclFailed;
            if (!directory or native.acl_get_flag_np(flags.?, limit_inherit) == 1) {
                for ([_]c_int{ file_inherit, directory_inherit, limit_inherit, only_inherit }) |flag| {
                    if (native.acl_delete_flag_np(flags.?, flag) != 0) return error.PreserveAclFailed;
                }
            }
        }
        return result;
    }

    fn appendEntry(self: *Acl, entry: *anyopaque) !*anyopaque {
        if (self.value == null) self.value = native.acl_init(0) orelse return error.CreateAclFailed;
        var copied: ?*anyopaque = null;
        if (native.acl_create_entry(&self.value, &copied) != 0 or native.acl_copy_entry(copied.?, entry) != 0)
            return error.PreserveAclFailed;
        return copied.?;
    }

    fn append(self: *Acl, other: Acl) !void {
        const value = other.value orelse return;
        var entry: ?*anyopaque = null;
        var next: c_int = 0;
        while (native.acl_get_entry(value, next, &entry) == 0) {
            next = -1;
            _ = try self.appendEntry(entry.?);
        }
    }

    fn apply(self: Acl, path: [:0]const u8) !void {
        const value = self.value orelse return;
        if (native.acl_set_link_np(path, native.ACL_TYPE_EXTENDED, value) != 0)
            return error.PreserveAclFailed;
    }
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
    flags: u32 = 0,

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
                .flags = value.flags,
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
    pending: std.ArrayList(FinalMetadata) = .empty,

    const Inode = struct { device: u64, inode: u64 };

    pub fn init(a: std.mem.Allocator) CopyContext {
        return .{ .arena = .init(a) };
    }

    pub fn deinit(self: *CopyContext) void {
        for (self.pending.items) |metadata| metadata.acl.deinit();
        self.arena.deinit();
    }

    pub fn publish(self: *CopyContext, io: std.Io, from: []const u8, to: []const u8) !void {
        const staging = try std.fmt.allocPrintSentinel(self.arena.allocator(), "{s}/.tms-move-XXXXXX", .{
            std.fs.path.dirname(to) orelse ".",
        }, 0);
        if (native.mkdtemp(staging) == null) return error.CreateStagingFailed;
        const result = self.copyStaged(io, from, to, staging);
        try makeStagingWritable(io, staging);
        try std.Io.Dir.cwd().deleteTree(io, staging);
        return result;
    }

    fn copyStaged(self: *CopyContext, io: std.Io, from: []const u8, to: []const u8, staging: [:0]const u8) !void {
        if (darwin) {
            try clearAcl(staging);
        } else {
            for ([_][:0]const u8{ "system.posix_acl_access", "system.posix_acl_default" }) |name| {
                if (native.lremovexattr(staging, name) != 0) switch (c.errno(@as(c_int, -1))) {
                    .NODATA, .OPNOTSUPP => {},
                    else => return error.SetAclFailed,
                };
            }
        }
        if (native.chmod(staging, 0o700) != 0) return error.SetPermissionsFailed;
        const item = try std.fs.path.join(self.arena.allocator(), &.{ staging, "item" });
        const parent = try self.arena.allocator().dupeSentinel(u8, std.fs.path.dirname(to) orelse ".", 0);
        const parent_acl: Acl = if (darwin) try .read(parent) else .{};
        defer parent_acl.deinit();
        try self.copy(io, from, item, parent_acl);
        for (self.pending.items) |metadata| try metadata.apply();
        try std.Io.Dir.cwd().rename(item, .cwd(), to, io);
    }

    fn copy(self: *CopyContext, io: std.Io, from: []const u8, to: []const u8, parent_acl: Acl) anyerror!void {
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
        var source_acl: Acl = if (darwin) try .read(source) else .{};
        defer source_acl.deinit();
        const inherited_acl: Acl = if (darwin and kind != c.S.IFLNK and !try source_acl.blocksInheritance())
            try .inherit(parent_acl, kind == c.S.IFDIR)
        else
            .{};
        defer inherited_acl.deinit();

        switch (kind) {
            c.S.IFDIR => {
                if (c.mkdir(destination, 0o700) != 0) return error.CreateDirectoryFailed;
                if (native.chmod(destination, 0o700) != 0) return error.SetPermissionsFailed;
                var input = try std.Io.Dir.cwd().openDir(io, from, .{ .iterate = true });
                defer input.close(io);
                var iterator = input.iterate();
                while (try iterator.next(io)) |entry| {
                    try self.copy(io, try std.fs.path.join(a, &.{ from, entry.name }), try std.fs.path.join(a, &.{ to, entry.name }), inherited_acl);
                }
            },
            c.S.IFREG => {
                if (darwin) {
                    if (native.copyfile(source, destination, null, native.COPYFILE_DATA | native.COPYFILE_XATTR | native.COPYFILE_NOFOLLOW | native.COPYFILE_EXCL) != 0)
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

        if (darwin) {
            if (kind == c.S.IFIFO) {
                try self.copyXattrs(source, destination);
            } else if (kind != c.S.IFREG and native.copyfile(source, destination, null, native.COPYFILE_XATTR | native.COPYFILE_NOFOLLOW) != 0)
                return error.PreserveMetadataFailed;
            try source_acl.append(inherited_acl);
            try self.pending.append(a, .{ .destination = destination, .stat = stat, .acl = source_acl });
            source_acl = .{};
        } else {
            if (c.fchownat(c.AT.FDCWD, destination, stat.uid, stat.gid, c.AT.SYMLINK_NOFOLLOW) != 0)
                return error.PreserveOwnershipFailed;
            try self.copyXattrs(source, destination);
            try (FinalMetadata{ .destination = destination, .stat = stat }).apply();
        }
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

const FinalMetadata = struct {
    destination: [:0]const u8,
    stat: Metadata,
    acl: Acl = .{},

    fn apply(self: FinalMetadata) !void {
        const path = self.destination;
        const stat = self.stat;
        if (darwin and c.fchownat(c.AT.FDCWD, path, stat.uid, stat.gid, c.AT.SYMLINK_NOFOLLOW) != 0)
            return error.PreserveOwnershipFailed;
        if (stat.mode & c.S.IFMT != c.S.IFLNK or darwin) {
            if (c.fchmodat(c.AT.FDCWD, path, stat.mode & 0o7777, if (darwin) c.AT.SYMLINK_NOFOLLOW else 0) != 0)
                return error.SetPermissionsFailed;
        }
        const times: [2]c.timespec = .{ stat.atime, stat.mtime };
        if (c.utimensat(c.AT.FDCWD, path, &times, c.AT.SYMLINK_NOFOLLOW) != 0)
            return error.PreserveTimestampsFailed;
        if (darwin) {
            const current = (try Metadata.read(path)).flags;
            // copyfile may preserve compression or fall back to uncompressed data.
            const flags = (stat.flags & ~(native.COPYFILE_OMIT_FLAGS | native.UF_COMPRESSED)) |
                (current & (native.COPYFILE_PRESERVE_FLAGS | native.UF_COMPRESSED));
            try self.acl.apply(path);
            if (flags != current and native.lchflags(path, flags) != 0)
                return error.PreserveFlagsFailed;
        }
    }
};

fn clearAcl(path: [:0]const u8) !void {
    const acl = native.acl_init(0) orelse return error.CreateAclFailed;
    defer _ = native.acl_free(acl);
    if (native.acl_set_link_np(path, native.ACL_TYPE_EXTENDED, acl) != 0)
        return error.SetAclFailed;
}

fn makeStagingWritable(io: std.Io, path: [:0]const u8) anyerror!void {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (darwin) {
        const flags = (try Metadata.read(path)).flags;
        if (flags & native.BLOCKING_FLAGS != 0 and native.lchflags(path, flags & ~native.BLOCKING_FLAGS) != 0)
            return error.ClearFlagsFailed;
    }
    if (stat.kind == .sym_link) return;
    if (darwin) try clearAcl(path);
    if (stat.kind != .directory) return;
    if (darwin and c.fchmodat(c.AT.FDCWD, path, 0o700, c.AT.SYMLINK_NOFOLLOW) != 0)
        return error.SetPermissionsFailed;
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    if (!darwin and c.fchmod(dir.handle, 0o700) != 0) return error.SetPermissionsFailed;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const child = try std.fmt.bufPrintSentinel(&buffer, "{s}/{s}", .{ path, entry.name }, 0);
        try makeStagingWritable(io, child);
    }
}
