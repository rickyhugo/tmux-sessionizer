const std = @import("std");
const t = std.testing;
const io = t.io;
const a = t.allocator;
const darwin = @import("builtin").os.tag == .macos;
const c = std.c;
const native = @import("move.zig").native;
const Metadata = @import("move.zig").Metadata;
const acl = struct {
    extern "c" fn acl_from_text([*:0]const u8) ?*anyopaque;
    extern "c" fn acl_free(?*anyopaque) c_int;
    extern "c" fn acl_set_file([*:0]const u8, c_int, *anyopaque) c_int;
    extern "c" fn acl_get_file([*:0]const u8, c_int) ?*anyopaque;
    extern "c" fn acl_to_text(*anyopaque, *isize) ?[*:0]u8;
    const ACL_TYPE_EXTENDED = 0x100;
};
extern "c" fn getgroups(c_int, [*]c.gid_t) c_int;

pub fn checkPreservation(move: anytype) !void {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const from = try std.fmt.allocPrintSentinel(a, "{s}/source", .{root}, 0);
    defer a.free(from);
    const to = try std.fmt.allocPrintSentinel(a, "{s}/target", .{root}, 0);
    defer a.free(to);
    const file = try std.fmt.allocPrintSentinel(a, "{s}/file", .{from}, 0);
    defer a.free(file);
    const link = try std.fmt.allocPrintSentinel(a, "{s}/hardlink", .{from}, 0);
    defer a.free(link);
    const fifo = try std.fmt.allocPrintSentinel(a, "{s}/fifo", .{from}, 0);
    defer a.free(fifo);
    try temp.dir.createDir(io, "source", .default_dir);
    try temp.dir.writeFile(io, .{ .sub_path = "source/file", .data = "contents" });
    try t.expectEqual(@as(c_int, 0), native.chmod(from, 0o700));
    try t.expectEqual(@as(c_int, 0), native.chmod(file, 0o664));
    var groups: [128]c.gid_t = undefined;
    const group_count = getgroups(groups.len, &groups);
    try t.expect(group_count >= 0);
    for (groups[0..@intCast(group_count)]) |group| {
        if (group == c.getegid()) continue;
        try t.expectEqual(@as(c_int, 0), c.fchownat(c.AT.FDCWD, file, c.geteuid(), group, 0));
        try t.expectEqual(@as(c_int, 0), c.fchownat(c.AT.FDCWD, from, c.geteuid(), group, 0));
        break;
    }
    try t.expectEqual(@as(c_int, 0), c.link(file, link));
    try t.expectEqual(@as(c_int, 0), native.mkfifo(fifo, 0o640));
    try temp.dir.symLink(io, "file", "source/symlink", .{});
    try setXattr(file, if (darwin) "com.tms.test" else "user.tms.test", "attribute");
    try setXattr(from, if (darwin) "com.tms.directory" else "user.tms.directory", "directory");
    if (darwin) try setXattr(file, "com.apple.ResourceFork", "resource fork contents");
    if (darwin) {
        const value = acl.acl_from_text("!#acl 1\nuser:FFFFEEEE-DDDD-CCCC-BBBB-AAAA00000000:0:root:allow:read\n") orelse
            return error.CreateAclFailed;
        defer _ = acl.acl_free(value);
        try t.expectEqual(@as(c_int, 0), acl.acl_set_file(file, acl.ACL_TYPE_EXTENDED, value));
    } else {
        // Linux exposes POSIX ACLs as a versioned, little-endian xattr.
        const value = [_]u32{
            2,
            0x00060001,
            0xffffffff,
            0x00040002,
            @intCast(c.getuid() + 1),
            0x00040004,
            0xffffffff,
            0x00060010,
            0xffffffff,
            0x00040020,
            0xffffffff,
        };
        var encoded: [@sizeOf(@TypeOf(value))]u8 = undefined;
        for (value, 0..) |word, index| std.mem.writeInt(u32, encoded[index * 4 ..][0..4], word, .little);
        try setXattr(file, "system.posix_acl_access", &encoded);
    }
    const before = try Metadata.read(file);
    const directory_before = try Metadata.read(from);
    const file_acl = try aclBytes(file);
    defer a.free(file_acl);
    const times: [2]c.timespec = .{
        .{ .sec = 1234567890, .nsec = 123456000 },
        .{ .sec = 1234567891, .nsec = 654321000 },
    };
    try t.expectEqual(@as(c_int, 0), c.utimensat(c.AT.FDCWD, file, &times, 0));
    try t.expectEqual(@as(c_int, 0), c.utimensat(c.AT.FDCWD, from, &times, 0));
    const old_umask = c.umask(0o077);
    defer _ = c.umask(old_umask);
    try move(io, a, from, to);
    try t.expectError(error.FileNotFound, temp.dir.statFile(io, "source", .{}));
    const moved_file = try std.fmt.allocPrintSentinel(a, "{s}/file", .{to}, 0);
    defer a.free(moved_file);
    const moved_link = try std.fmt.allocPrintSentinel(a, "{s}/hardlink", .{to}, 0);
    defer a.free(moved_link);
    const moved_fifo = try std.fmt.allocPrintSentinel(a, "{s}/fifo", .{to}, 0);
    defer a.free(moved_fifo);
    const after = try Metadata.read(moved_file);
    const directory_after = try Metadata.read(to);
    try t.expectEqual(before.uid, after.uid);
    try t.expectEqual(before.gid, after.gid);
    try t.expectEqual(directory_before.uid, directory_after.uid);
    try t.expectEqual(directory_before.gid, directory_after.gid);
    try t.expectEqual(@as(c.mode_t, 0o664), after.mode & 0o7777);
    try t.expectEqual(@as(c.mode_t, 0o700), directory_after.mode & 0o7777);
    try t.expectEqual(after.inode, (try Metadata.read(moved_link)).inode);
    try t.expectEqual(@as(u64, 2), after.nlink);
    try t.expectEqual(@as(c.mode_t, c.S.IFIFO), (try Metadata.read(moved_fifo)).mode & c.S.IFMT);
    try t.expectEqual(@as(c.mode_t, 0o640), (try Metadata.read(moved_fifo)).mode & 0o7777);
    try checkXattr(moved_file, if (darwin) "com.tms.test" else "user.tms.test", "attribute");
    try checkXattr(to, if (darwin) "com.tms.directory" else "user.tms.directory", "directory");
    if (darwin) try checkXattr(moved_file, "com.apple.ResourceFork", "resource fork contents");
    const moved_acl = try aclBytes(moved_file);
    defer a.free(moved_acl);
    try t.expectEqualSlices(u8, file_acl, moved_acl);
    try t.expectEqual(times[0].sec, after.atime.sec);
    try t.expectEqual(times[0].nsec, after.atime.nsec);
    try t.expectEqual(times[1].sec, after.mtime.sec);
    try t.expectEqual(times[1].nsec, after.mtime.nsec);
    try t.expectEqual(times[1].sec, directory_after.mtime.sec);
    try t.expectEqual(times[1].nsec, directory_after.mtime.nsec);
    var link_buffer: [128]u8 = undefined;
    const len = try temp.dir.readLink(io, "target/symlink", &link_buffer);
    try t.expectEqualStrings("file", link_buffer[0..len]);
    const contents = try temp.dir.readFileAlloc(io, "target/file", a, .limited(32));
    defer a.free(contents);
    try t.expectEqualStrings("contents", contents);
}

pub fn checkFailure(move: anytype) !void {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const from = try std.fs.path.join(a, &.{ root, "source" });
    defer a.free(from);
    const to = try std.fs.path.join(a, &.{ root, "target" });
    defer a.free(to);
    try temp.dir.createDir(io, "source", .default_dir);
    try temp.dir.writeFile(io, .{ .sub_path = "source/file", .data = "keep" });
    try temp.dir.createDir(io, "target", .default_dir);
    for (0..32) |index| {
        var failing: t.FailingAllocator = .init(a, .{ .fail_index = index });
        move(io, failing.allocator(), from, to) catch |err| {
            try t.expectEqual(error.OutOfMemory, err);
            try t.expectEqual(std.Io.File.Kind.directory, (try temp.dir.statFile(io, "source", .{})).kind);
            try t.expectEqual(std.Io.File.Kind.directory, (try temp.dir.statFile(io, "target", .{})).kind);
            var directory = try temp.dir.openDir(io, ".", .{ .iterate = true });
            defer directory.close(io);
            var iterator = directory.iterate();
            while (try iterator.next(io)) |entry|
                try t.expect(!std.mem.startsWith(u8, entry.name, ".tms-move-"));
            continue;
        };
        try t.expectError(error.FileNotFound, temp.dir.statFile(io, "source", .{}));
        break;
    }
    try t.expectError(error.FileNotFound, temp.dir.statFile(io, "source", .{}));
    try temp.dir.createDir(io, "source", .default_dir);
    for (0..128) |index| {
        var buffer: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&buffer, "source/file-{d}", .{index});
        try temp.dir.writeFile(io, .{ .sub_path = path, .data = "private contents" });
    }
    const source_path = try a.dupeSentinel(u8, from, 0);
    defer a.free(source_path);
    try t.expectEqual(@as(c_int, 0), native.chmod(source_path, 0o700));
    var observer: PrivacyAllocator = .{ .dir = temp.dir, .root = root };
    try t.expectError(error.OutOfMemory, move(io, observer.allocator(), from, to));
    try t.expect(observer.saw_partial);
    try t.expect(!observer.failed);
    try t.expectEqual(std.Io.File.Kind.directory, (try temp.dir.statFile(io, "source", .{})).kind);
    const old = try temp.dir.readFileAlloc(io, "target/file", a, .limited(32));
    defer a.free(old);
    try t.expectEqualStrings("keep", old);
    try temp.dir.deleteTree(io, "target");
    try move(io, a, from, to);
}

const PrivacyAllocator = struct {
    dir: std.Io.Dir,
    root: []const u8,
    saw_partial: bool = false,
    failed: bool = false,

    fn allocator(self: *PrivacyAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = free,
        } };
    }

    fn inspect(self: *PrivacyAllocator) !void {
        var dir = try self.dir.openDir(io, ".", .{ .iterate = true });
        defer dir.close(io);
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (!std.mem.startsWith(u8, entry.name, ".tms-move-")) continue;
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const path = try std.fmt.bufPrintSentinel(&buffer, "{s}/{s}", .{ self.root, entry.name }, 0);
            try t.expectEqual(@as(c.mode_t, 0o700), (try Metadata.read(path)).mode & 0o7777);
            if (darwin) {
                const value = @import("move.zig").native.acl_get_link_np(path, acl.ACL_TYPE_EXTENDED);
                if (value) |permissions| {
                    defer _ = acl.acl_free(permissions);
                    var len: isize = 0;
                    const text = acl.acl_to_text(permissions, &len) orelse return error.ReadAclFailed;
                    defer _ = acl.acl_free(text);
                    try t.expectEqualStrings("!#acl 1\n", text[0..@intCast(len)]);
                }
            }
            var staging = try dir.openDir(io, entry.name, .{});
            defer staging.close(io);
            var item = staging.openDir(io, "item", .{ .iterate = true }) catch continue;
            defer item.close(io);
            var children = item.iterate();
            self.saw_partial = (try children.next(io)) != null;
        }
    }

    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *PrivacyAllocator = @ptrCast(@alignCast(raw));
        self.inspect() catch {
            self.failed = true;
            return null;
        };
        if (self.saw_partial) return null;
        return a.rawAlloc(len, alignment, ret);
    }

    fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        a.rawFree(memory, alignment, ret);
    }
};

fn setXattr(path: [:0]const u8, name: [:0]const u8, bytes: []const u8) !void {
    const result = if (darwin)
        native.setxattr(path, name, bytes.ptr, bytes.len, 0, native.XATTR_NOFOLLOW)
    else
        native.lsetxattr(path, name, bytes.ptr, bytes.len, 0);
    try t.expectEqual(@as(c_int, 0), result);
}

fn checkXattr(path: [:0]const u8, name: [:0]const u8, expected: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    const len = if (darwin)
        native.getxattr(path, name, &buffer, buffer.len, 0, native.XATTR_NOFOLLOW)
    else
        native.lgetxattr(path, name, &buffer, buffer.len);
    try t.expect(len >= 0);
    try t.expectEqualSlices(u8, expected, buffer[0..@intCast(len)]);
}

fn aclBytes(path: [:0]const u8) ![]u8 {
    if (darwin) {
        const value = acl.acl_get_file(path, acl.ACL_TYPE_EXTENDED) orelse return error.ReadAclFailed;
        defer _ = acl.acl_free(value);
        var len: isize = 0;
        const text = acl.acl_to_text(value, &len) orelse return error.ReadAclFailed;
        defer _ = acl.acl_free(text);
        return a.dupe(u8, text[0..@intCast(len)]);
    }
    var buffer: [1024]u8 = undefined;
    const len = native.lgetxattr(path, "system.posix_acl_access", &buffer, buffer.len);
    try t.expect(len >= 0);
    return a.dupe(u8, buffer[0..@intCast(len)]);
}
