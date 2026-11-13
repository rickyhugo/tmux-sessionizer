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
extern "c" fn mbr_uid_to_uuid(c.uid_t, *[16]u8) c_int;

pub fn checkInheritedAcls(move: anytype) !void {
    try inheritedAclsAt(move, null);
}

pub fn checkCrossDeviceMetadata(move: anytype) !void {
    var env = try t.environ.createMap(a);
    defer env.deinit();
    const second = env.get("TMS_TEST_CROSS_DEVICE_DIR") orelse
        if (darwin) return error.SkipZigTest else "/dev/shm";
    var second_dir = std.Io.Dir.openDirAbsolute(io, second, .{}) catch return error.SkipZigTest;
    defer second_dir.close(io);
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const root_z = try a.dupeSentinel(u8, root, 0);
    defer a.free(root_z);
    const second_z = try a.dupeSentinel(u8, second, 0);
    defer a.free(second_z);
    if ((try Metadata.read(root_z)).device == (try Metadata.read(second_z)).device)
        return error.SkipZigTest;
    try preservationAt(move, second);
    if (darwin) {
        try inheritedAclsAt(move, second);
        try flagsAt(move, second);
        try aclHardlinksAt(move, second);
    }
}

fn inheritedAclsAt(move: anytype, second: ?[]const u8) !void {
    if (!darwin) return error.SkipZigTest;
    const principal = try callerPrincipal();
    defer a.free(principal);
    const SourceAcl = enum { none, allow, deny, no_inherit };
    for ([_]SourceAcl{ .none, .allow, .deny, .no_inherit }) |source_kind| {
        const deny = source_kind == .deny;
        for ([_]bool{ false, true }) |directory| {
            var temp = t.tmpDir(.{});
            defer temp.cleanup();
            const root = try temp.dir.realPathFileAlloc(io, ".", a);
            defer a.free(root);
            const parent = try std.fmt.allocPrintSentinel(a, "{s}/source-parent", .{root}, 0);
            defer a.free(parent);
            const target = try std.fmt.allocPrintSentinel(a, "{s}/tms-acl-{s}", .{ second orelse root, temp.sub_path }, 0);
            defer a.free(target);
            const from = try std.fmt.allocPrintSentinel(a, "{s}/item", .{parent}, 0);
            defer a.free(from);
            const to = try std.fmt.allocPrintSentinel(a, "{s}/item", .{target}, 0);
            defer a.free(to);
            defer {
                _ = native.chmod(from, 0o700);
                _ = native.chmod(to, 0o700);
                std.Io.Dir.cwd().deleteTree(io, target) catch unreachable;
            }
            try temp.dir.createDir(io, "source-parent", .default_dir);
            try std.Io.Dir.cwd().createDir(io, target, .default_dir);
            const source_acl = try std.fmt.allocPrintSentinel(a, "!#acl 1\n{s}:{s},file_inherit,directory_inherit,only_inherit:{s}\n", .{
                principal,
                if (deny) "deny" else "allow",
                if (deny) "writeattr" else "read,write,append,delete_child",
            }, 0);
            defer a.free(source_acl);
            if (source_kind != .none) try setAcl(parent, source_acl);
            const target_acl = try std.fmt.allocPrintSentinel(a,
                \\!#acl 1
                \\{s}:allow,file_inherit,directory_inherit,only_inherit:writeattr
                \\{s}:deny,file_inherit,only_inherit:append
                \\{s}:allow,directory_inherit,limit_inherit,only_inherit:readattr
                \\{s}:deny,directory_inherit,only_inherit:writeextattr
                \\
            , .{ principal, principal, principal, principal }, 0);
            defer a.free(target_acl);
            try setAcl(target, target_acl);
            if (directory) {
                try temp.dir.createDir(io, "source-parent/item", .default_dir);
                try temp.dir.writeFile(io, .{ .sub_path = "source-parent/item/child", .data = "protected" });
            } else {
                try temp.dir.writeFile(io, .{ .sub_path = "source-parent/item", .data = "protected" });
            }
            if (source_kind == .no_inherit) {
                const value = acl.acl_get_file(from, acl.ACL_TYPE_EXTENDED) orelse return error.ReadAclFailed;
                defer _ = acl.acl_free(value);
                var flags: ?*anyopaque = null;
                try t.expectEqual(@as(c_int, 0), native.acl_get_flagset_np(value, &flags));
                try t.expectEqual(@as(c_int, 0), native.acl_add_flag_np(flags.?, 1 << 17));
                try t.expectEqual(@as(c_int, 0), acl.acl_set_file(from, acl.ACL_TYPE_EXTENDED, value));
            }
            const mode: c.mode_t = if (deny or source_kind == .none)
                (if (directory) 0o700 else 0o600)
            else
                (if (directory) 0o500 else 0o400);
            try t.expectEqual(@as(c_int, 0), native.chmod(from, mode));
            const before = try aclBytes(from);
            defer a.free(before);
            if (source_kind != .none) {
                try t.expect(std.mem.indexOf(u8, before, "inherited") != null);
                try checkAclAccess(from, deny, directory);
            }
            var child_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const child_before = if (directory)
                try aclBytes(try std.fmt.bufPrintSentinel(&child_buffer, "{s}/child", .{from}, 0))
            else
                null;
            defer if (child_before) |bytes| a.free(bytes);
            if (directory) {
                try std.Io.Dir.cwd().createDir(io, to, .default_dir);
                const child = try std.fmt.bufPrintSentinel(&child_buffer, "{s}/child", .{to}, 0);
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = child, .data = "probe" });
            } else {
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = to, .data = "probe" });
            }
            const destination_acl = try aclBytes(to);
            defer a.free(destination_acl);
            const expected = try appendAclText(before, if (source_kind == .no_inherit) "!#acl 1\n" else destination_acl);
            defer a.free(expected);
            const expected_child = if (child_before) |bytes| blk: {
                const child = try std.fmt.bufPrintSentinel(&child_buffer, "{s}/child", .{to}, 0);
                const destination_child_acl = try aclBytes(child);
                defer a.free(destination_child_acl);
                break :blk try appendAclText(bytes, if (source_kind == .no_inherit) "!#acl 1\n" else destination_child_acl);
            } else null;
            defer if (expected_child) |bytes| a.free(bytes);
            try std.Io.Dir.cwd().deleteTree(io, to);
            if (second != null)
                try t.expectError(error.CrossDevice, std.Io.Dir.cwd().rename(from, .cwd(), to, io));
            try move(io, a, from, to);
            try t.expectError(error.FileNotFound, temp.dir.statFile(io, "source-parent/item", .{}));
            const after = try aclBytes(to);
            defer a.free(after);
            try t.expectEqualSlices(u8, expected, after);
            try t.expectEqual(mode, (try Metadata.read(to)).mode & 0o7777);
            if (source_kind != .none) try checkAclAccess(to, deny, directory);
            if (expected_child) |bytes| {
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const child = try std.fmt.bufPrintSentinel(&buffer, "{s}/child", .{to}, 0);
                const child_after = try aclBytes(child);
                defer a.free(child_after);
                try t.expectEqualSlices(u8, bytes, child_after);
            }
        }
    }
}

fn appendAclText(source: []const u8, inherited: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}{s}", .{ source, inherited["!#acl 1\n".len..] });
}

fn callerPrincipal() ![]u8 {
    var uuid: [16]u8 = undefined;
    try t.expectEqual(@as(c_int, 0), mbr_uid_to_uuid(c.geteuid(), &uuid));
    return std.fmt.allocPrint(a, "user:{s}-{s}-{s}-{s}-{s}:owner:{d}", .{
        std.fmt.bytesToHex(uuid[0..4], .upper),
        std.fmt.bytesToHex(uuid[4..6], .upper),
        std.fmt.bytesToHex(uuid[6..8], .upper),
        std.fmt.bytesToHex(uuid[8..10], .upper),
        std.fmt.bytesToHex(uuid[10..16], .upper),
        c.geteuid(),
    });
}

pub fn checkAclHardlinks(move: anytype) !void {
    try aclHardlinksAt(move, null);
}

fn aclHardlinksAt(move: anytype, second: ?[]const u8) !void {
    if (!darwin) return error.SkipZigTest;
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const from = try std.fmt.allocPrintSentinel(a, "{s}/source", .{root}, 0);
    defer a.free(from);
    const target = try std.fmt.allocPrintSentinel(a, "{s}/tms-hardlinks-{s}", .{ second orelse root, temp.sub_path }, 0);
    defer a.free(target);
    const to = try std.fmt.allocPrintSentinel(a, "{s}/source", .{target}, 0);
    defer a.free(to);
    defer std.Io.Dir.cwd().deleteTree(io, target) catch unreachable;
    try temp.dir.createDirPath(io, "source/first");
    try temp.dir.createDirPath(io, "source/second");
    try temp.dir.writeFile(io, .{ .sub_path = "source/first/file", .data = "linked contents" });
    const first = try std.fmt.allocPrintSentinel(a, "{s}/first/file", .{from}, 0);
    defer a.free(first);
    const other = try std.fmt.allocPrintSentinel(a, "{s}/second/file", .{from}, 0);
    defer a.free(other);
    try t.expectEqual(@as(c_int, 0), c.link(first, other));
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, other, a, .limited(64));
    defer a.free(contents);
    try t.expectEqualStrings("linked contents", contents);
    const principal = try callerPrincipal();
    defer a.free(principal);
    const allow = try std.fmt.allocPrintSentinel(a, "!#acl 1\n{s}:allow:execute\n", .{principal}, 0);
    defer a.free(allow);
    try setAcl(from, allow);
    try std.Io.Dir.cwd().createDir(io, target, .default_dir);
    const deny = try std.fmt.allocPrintSentinel(a, "!#acl 1\n{s}:deny,directory_inherit,only_inherit:execute\n", .{principal}, 0);
    defer a.free(deny);
    try setAcl(target, deny);
    if (second != null)
        try t.expectError(error.CrossDevice, std.Io.Dir.cwd().rename(from, .cwd(), to, io));
    try move(io, a, from, to);
    try t.expectError(error.FileNotFound, temp.dir.statFile(io, "source", .{}));
    var inode: ?u64 = null;
    for ([_][]const u8{ "first", "second" }) |name| {
        const directory = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ to, name }, 0);
        defer a.free(directory);
        defer setAcl(directory, "!#acl 1\n") catch unreachable;
        const file = try std.fmt.allocPrintSentinel(a, "{s}/file", .{directory}, 0);
        defer a.free(file);
        try t.expectError(error.AccessDenied, std.Io.Dir.cwd().openFile(io, file, .{}));
        const permissions = try aclBytes(directory);
        defer a.free(permissions);
        try t.expect(std.mem.indexOf(u8, permissions, "deny") != null);
        try t.expect(std.mem.indexOf(u8, permissions, "inherited") != null);
        try t.expect(std.mem.indexOf(u8, permissions, "execute") != null);
        try setAcl(directory, "!#acl 1\n");
        const stat = try Metadata.read(file);
        if (inode) |previous| try t.expectEqual(previous, stat.inode);
        inode = stat.inode;
        try t.expectEqual(@as(u64, 2), stat.nlink);
        const moved = try std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(64));
        defer a.free(moved);
        try t.expectEqualStrings("linked contents", moved);
    }
}

pub fn checkFlags(move: anytype) !void {
    try flagsAt(move, null);
}

fn flagsAt(move: anytype, second: ?[]const u8) !void {
    if (!darwin) return error.SkipZigTest;
    for ([_]u32{ native.UF_IMMUTABLE, native.UF_APPEND }) |flags| {
        var temp = t.tmpDir(.{});
        defer temp.cleanup();
        const root = try temp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        const from = try std.fmt.allocPrintSentinel(a, "{s}/source", .{root}, 0);
        defer a.free(from);
        const target = try std.fmt.allocPrintSentinel(a, "{s}/tms-flags-{s}", .{ second orelse root, temp.sub_path }, 0);
        defer a.free(target);
        const to = try std.fmt.allocPrintSentinel(a, "{s}/source", .{target}, 0);
        defer a.free(to);
        const move_to = if (second != null) target else to;
        const file = try std.fmt.allocPrintSentinel(a, "{s}/file", .{from}, 0);
        defer a.free(file);
        const moved = try std.fmt.allocPrintSentinel(a, "{s}/file", .{to}, 0);
        defer a.free(moved);
        const locked = try std.fmt.allocPrintSentinel(a, "{s}/locked", .{from}, 0);
        defer a.free(locked);
        const moved_locked = try std.fmt.allocPrintSentinel(a, "{s}/locked", .{to}, 0);
        defer a.free(moved_locked);
        const outside = try std.fmt.allocPrintSentinel(a, "{s}/outside", .{root}, 0);
        defer a.free(outside);
        defer {
            _ = native.lchflags(from, 0);
            _ = native.lchflags(file, 0);
            _ = native.lchflags(moved, 0);
            _ = native.lchflags(locked, 0);
            _ = native.lchflags(moved_locked, 0);
            _ = native.lchflags(outside, 0);
            var dir = std.Io.Dir.cwd().openDir(io, target, .{ .iterate = true }) catch unreachable;
            defer dir.close(io);
            var iterator = dir.iterate();
            while (iterator.next(io) catch unreachable) |entry| {
                if (!std.mem.startsWith(u8, entry.name, ".tms-move-")) continue;
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                for ([_][]const u8{ "item", "item/file", "item/locked" }) |suffix| {
                    const path = std.fmt.bufPrintSentinel(&buffer, "{s}/{s}/{s}", .{ target, entry.name, suffix }, 0) catch unreachable;
                    _ = native.lchflags(path, 0);
                }
            }
            std.Io.Dir.cwd().deleteTree(io, target) catch unreachable;
        }
        try temp.dir.createDir(io, "source", .default_dir);
        try temp.dir.writeFile(io, .{ .sub_path = "source/file", .data = "protected contents" });
        try temp.dir.createDirPath(io, "source/locked");
        try temp.dir.writeFile(io, .{ .sub_path = "source/locked/file", .data = "locked contents" });
        try temp.dir.writeFile(io, .{ .sub_path = "outside", .data = "outside contents" });
        try temp.dir.symLink(io, outside, "source/link", .{});
        try t.expectEqual(@as(c_int, 0), native.lchflags(locked, flags));
        try t.expectEqual(@as(c_int, 0), native.lchflags(outside, flags));
        try std.Io.Dir.cwd().createDir(io, target, .default_dir);
        try std.Io.Dir.cwd().createDir(io, to, .default_dir);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = moved, .data = "old destination" });
        try setXattr(file, "com.tms.test", "attribute");
        try setXattr(file, "com.apple.ResourceFork", "resource fork contents");
        try t.expectEqual(@as(c_int, 0), native.chmod(file, 0o640));
        const times: [2]c.timespec = .{
            .{ .sec = 1234567890, .nsec = 123456000 },
            .{ .sec = 1234567891, .nsec = 654321000 },
        };
        try t.expectEqual(@as(c_int, 0), c.utimensat(c.AT.FDCWD, file, &times, 0));
        const principal = try callerPrincipal();
        defer a.free(principal);
        const permissions = try std.fmt.allocPrintSentinel(a, "!#acl 1\n{s}:deny:writeattr\n", .{principal}, 0);
        defer a.free(permissions);
        try setAcl(file, permissions);
        const before_acl = try aclBytes(file);
        defer a.free(before_acl);
        try t.expectEqual(@as(c_int, 0), native.lchflags(file, flags));
        const before = try Metadata.read(file);
        const old = try Metadata.read(moved);
        if (second != null)
            try t.expectError(error.CrossDevice, std.Io.Dir.cwd().rename(from, .cwd(), to, io));
        const result = move(io, a, from, move_to);
        try expectNoStaging(target);
        try t.expectError(error.DirNotEmpty, result);
        try t.expectEqual(before.inode, (try Metadata.read(file)).inode);
        try t.expectEqual(flags, (try Metadata.read(file)).flags);
        try t.expectEqual(flags, (try Metadata.read(locked)).flags);
        try t.expectEqual(flags, (try Metadata.read(outside)).flags);
        try t.expectEqual(old.inode, (try Metadata.read(moved)).inode);
        const old_contents = try std.Io.Dir.cwd().readFileAlloc(io, moved, a, .limited(64));
        defer a.free(old_contents);
        try t.expectEqualStrings("old destination", old_contents);
        try std.Io.Dir.cwd().deleteTree(io, to);
        const retry_before = try Metadata.read(file);
        try t.expectError(error.PermissionDenied, move(io, a, from, move_to));
        try expectNoStaging(target);
        try t.expectEqual(before.inode, (try Metadata.read(file)).inode);
        const after = try Metadata.read(moved);
        try t.expectEqual(before.uid, after.uid);
        try t.expectEqual(before.gid, after.gid);
        try t.expectEqual(before.mode, after.mode);
        try t.expectEqual(retry_before.atime, after.atime);
        try t.expectEqual(before.mtime, after.mtime);
        try t.expectEqual(flags, (try Metadata.read(file)).flags);
        try t.expectEqual(flags, after.flags);
        try t.expectEqual(flags, (try Metadata.read(moved_locked)).flags);
        try t.expectEqual(flags, (try Metadata.read(outside)).flags);
        const after_acl = try aclBytes(moved);
        defer a.free(after_acl);
        try t.expectEqualSlices(u8, before_acl, after_acl);
        try checkXattr(moved, "com.tms.test", "attribute");
        try checkXattr(moved, "com.apple.ResourceFork", "resource fork contents");
        const contents = try std.Io.Dir.cwd().readFileAlloc(io, moved, a, .limited(64));
        defer a.free(contents);
        try t.expectEqualStrings("protected contents", contents);
        const published = try Metadata.read(to);
        try t.expectEqual(@as(c_int, 0), native.lchflags(from, flags));
        try t.expectError(error.PermissionDenied, move(io, a, from, move_to));
        try expectNoStaging(target);
        try t.expectEqual(flags, (try Metadata.read(from)).flags);
        try t.expectEqual(published.inode, (try Metadata.read(to)).inode);
    }
}

fn expectNoStaging(path: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry|
        try t.expect(!std.mem.startsWith(u8, entry.name, ".tms-move-"));
}

fn setAcl(path: [:0]const u8, text: [:0]const u8) !void {
    const value = acl.acl_from_text(text) orelse return error.CreateAclFailed;
    defer _ = acl.acl_free(value);
    try t.expectEqual(@as(c_int, 0), acl.acl_set_file(path, acl.ACL_TYPE_EXTENDED, value));
}

fn checkAclAccess(path: [:0]const u8, deny: bool, directory: bool) !void {
    if (deny) {
        const times: [2]c.timespec = .{ .{ .sec = 1234567890, .nsec = 0 }, .{ .sec = 1234567891, .nsec = 0 } };
        try t.expectEqual(@as(c_int, -1), c.utimensat(c.AT.FDCWD, path, &times, 0));
        try t.expectEqual(c.E.ACCES, c.errno(@as(c_int, -1)));
    } else if (directory) {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const child = try std.fmt.bufPrintSentinel(&buffer, "{s}/access-probe", .{path}, 0);
        try t.expectEqual(@as(c_int, 0), c.mkdir(child, 0o700));
        try t.expectEqual(@as(c_int, 0), c.unlinkat(c.AT.FDCWD, child, c.AT.REMOVEDIR));
    } else {
        const fd = c.open(path, .{ .ACCMODE = .WRONLY, .NOFOLLOW = true, .CLOEXEC = true });
        try t.expect(fd >= 0);
        _ = c.close(fd);
    }
}

pub fn checkPublishFailure(move: anytype) !void {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const from = try std.fmt.allocPrintSentinel(a, "{s}/source", .{root}, 0);
    defer a.free(from);
    const to = try std.fmt.allocPrintSentinel(a, "{s}/target", .{root}, 0);
    defer a.free(to);
    const locked = try std.fmt.allocPrintSentinel(a, "{s}/locked", .{from}, 0);
    defer a.free(locked);
    const outside = try std.fmt.allocPrintSentinel(a, "{s}/outside", .{root}, 0);
    defer a.free(outside);
    defer {
        _ = native.chmod(locked, 0o700);
        _ = native.chmod(outside, 0o700);
        var dir = temp.dir.openDir(io, ".", .{ .iterate = true }) catch unreachable;
        defer dir.close(io);
        var iterator = dir.iterate();
        while (iterator.next(io) catch unreachable) |entry| {
            if (!std.mem.startsWith(u8, entry.name, ".tms-move-")) continue;
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&buffer, "{s}/{s}/item/locked", .{ root, entry.name }, 0) catch unreachable;
            _ = native.chmod(path, 0o700);
        }
    }
    try temp.dir.createDirPath(io, "source/locked");
    try temp.dir.createDir(io, "outside", .default_dir);
    try temp.dir.createDir(io, "target", .default_dir);
    try temp.dir.writeFile(io, .{ .sub_path = "source/locked/file", .data = "source contents" });
    try temp.dir.writeFile(io, .{ .sub_path = "outside/file", .data = "outside contents" });
    try temp.dir.writeFile(io, .{ .sub_path = "target/file", .data = "old destination" });
    try temp.dir.symLink(io, "../outside", "source/link", .{ .is_directory = true });
    try t.expectEqual(@as(c_int, 0), native.chmod(locked, 0o500));
    try t.expectEqual(@as(c_int, 0), native.chmod(outside, 0o500));
    const source_before = try Metadata.read(locked);
    const target_before = try Metadata.read(to);
    try t.expectError(error.DirNotEmpty, move(io, a, from, to));
    try t.expectEqual(@as(c.mode_t, 0o500), (try Metadata.read(locked)).mode & 0o7777);
    try t.expectEqual(@as(c.mode_t, 0o500), (try Metadata.read(outside)).mode & 0o7777);
    try t.expectEqual(source_before.inode, (try Metadata.read(locked)).inode);
    try t.expectEqual(target_before.inode, (try Metadata.read(to)).inode);
    try t.expectEqual(target_before.mode, (try Metadata.read(to)).mode);
    const source_contents = try temp.dir.readFileAlloc(io, "source/locked/file", a, .limited(64));
    defer a.free(source_contents);
    try t.expectEqualStrings("source contents", source_contents);
    const target_contents = try temp.dir.readFileAlloc(io, "target/file", a, .limited(64));
    defer a.free(target_contents);
    try t.expectEqualStrings("old destination", target_contents);
    const outside_contents = try temp.dir.readFileAlloc(io, "outside/file", a, .limited(64));
    defer a.free(outside_contents);
    try t.expectEqualStrings("outside contents", outside_contents);
    var dir = try temp.dir.openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry|
        try t.expect(!std.mem.startsWith(u8, entry.name, ".tms-move-"));
}

pub fn checkPreservation(move: anytype) !void {
    try preservationAt(move, null);
}

fn preservationAt(move: anytype, second: ?[]const u8) !void {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const from = try std.fmt.allocPrintSentinel(a, "{s}/source", .{root}, 0);
    defer a.free(from);
    const to = if (second) |target|
        try std.fmt.allocPrintSentinel(a, "{s}/tms-metadata-{s}", .{ target, temp.sub_path }, 0)
    else
        try std.fmt.allocPrintSentinel(a, "{s}/target", .{root}, 0);
    defer a.free(to);
    defer std.Io.Dir.cwd().deleteTree(io, to) catch unreachable;
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
        try t.expectEqual(@as(c_int, 0), acl.acl_set_file(from, acl.ACL_TYPE_EXTENDED, value));
        try t.expectEqual(@as(c_int, 0), acl.acl_set_file(fifo, acl.ACL_TYPE_EXTENDED, value));
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
    const directory_acl: ?[]u8 = if (darwin) try aclBytes(from) else null;
    defer if (directory_acl) |bytes| a.free(bytes);
    const fifo_acl: ?[]u8 = if (darwin) try aclBytes(fifo) else null;
    defer if (fifo_acl) |bytes| a.free(bytes);
    const times: [2]c.timespec = .{
        .{ .sec = 1234567890, .nsec = 123456000 },
        .{ .sec = 1234567891, .nsec = 654321000 },
    };
    try t.expectEqual(@as(c_int, 0), c.utimensat(c.AT.FDCWD, file, &times, 0));
    try t.expectEqual(@as(c_int, 0), c.utimensat(c.AT.FDCWD, from, &times, 0));
    const old_umask = c.umask(0o077);
    defer _ = c.umask(old_umask);
    if (second != null)
        try t.expectError(error.CrossDevice, std.Io.Dir.cwd().rename(from, .cwd(), to, io));
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
    if (directory_acl) |bytes| {
        const moved = try aclBytes(to);
        defer a.free(moved);
        try t.expectEqualSlices(u8, bytes, moved);
    }
    if (fifo_acl) |bytes| {
        const moved = try aclBytes(moved_fifo);
        defer a.free(moved);
        try t.expectEqualSlices(u8, bytes, moved);
    }
    try t.expectEqual(times[0].sec, after.atime.sec);
    try t.expectEqual(times[0].nsec, after.atime.nsec);
    try t.expectEqual(times[1].sec, after.mtime.sec);
    try t.expectEqual(times[1].nsec, after.mtime.nsec);
    try t.expectEqual(times[1].sec, directory_after.mtime.sec);
    try t.expectEqual(times[1].nsec, directory_after.mtime.nsec);
    var link_buffer: [128]u8 = undefined;
    const moved_symlink = try std.fs.path.join(a, &.{ to, "symlink" });
    defer a.free(moved_symlink);
    const len = try std.Io.Dir.cwd().readLink(io, moved_symlink, &link_buffer);
    try t.expectEqualStrings("file", link_buffer[0..len]);
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, moved_file, a, .limited(32));
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
    if (darwin) {
        const root_path = try a.dupeSentinel(u8, root, 0);
        defer a.free(root_path);
        try setAcl(root_path, "!#acl 1\nuser:FFFFEEEE-DDDD-CCCC-BBBB-AAAA00000000:0:root:allow,file_inherit,directory_inherit:read\n");
    }
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
    if (result != 0 and c.errno(result) == .OPNOTSUPP) {
        var env = try t.environ.createMap(a);
        defer env.deinit();
        if (std.mem.eql(u8, env.get("TMS_TEST_ALLOW_UNSUPPORTED_XATTR") orelse "", "1"))
            return error.SkipZigTest;
    }
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
        const value = acl.acl_get_file(path, acl.ACL_TYPE_EXTENDED) orelse {
            if (c.errno(@as(c_int, -1)) == .NOENT) return a.dupe(u8, "!#acl 1\n");
            return error.ReadAclFailed;
        };
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
