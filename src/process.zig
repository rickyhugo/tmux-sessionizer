const std = @import("std");
const A = std.mem.Allocator;
const Io = std.Io;

pub const Input = enum { inherit, ignore };
pub const Request = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    env: ?*const std.process.Environ.Map = null,
    stdin: Input = .inherit,
};
pub const Output = struct {
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,
};

pub fn capture(io: Io, a: A, request: Request) anyerror!Output {
    if (request.argv.len == 0) return error.EmptyArgv;
    var child = try std.process.spawn(io, .{
        .argv = request.argv,
        .cwd = cwd(request),
        .environ_map = request.env,
        .stdin = switch (request.stdin) {
            .inherit => .inherit,
            .ignore => .ignore,
        },
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var reader: Io.File.MultiReader = undefined;
    reader.init(a, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    try reader.checkAnyError();
    while (reader.fill(4096, .none)) |_| {
        try reader.checkAnyError();
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try reader.checkAnyError();
    const term = try child.wait(io);
    const stdout = try reader.toOwnedSlice(0);
    errdefer a.free(stdout);
    const stderr = try reader.toOwnedSlice(1);
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}

pub fn inherit(io: Io, request: Request) anyerror!std.process.Child.Term {
    if (request.argv.len == 0) return error.EmptyArgv;
    var child = try std.process.spawn(io, .{
        .argv = request.argv,
        .cwd = cwd(request),
        .environ_map = request.env,
        .stdin = switch (request.stdin) {
            .inherit => .inherit,
            .ignore => .ignore,
        },
    });
    defer child.kill(io);
    return try child.wait(io);
}

pub fn replace(io: Io, request: Request) anyerror!noreturn {
    if (request.argv.len == 0) return error.EmptyArgv;
    var saved_input: ?Io.File = null;
    defer if (saved_input) |file| {
        Io.Threaded.dup2(file.handle, Io.File.stdin().handle) catch {};
        file.close(io);
    };
    if (request.stdin == .ignore) {
        const null_input = try Io.Dir.openFileAbsolute(io, "/dev/null", .{});
        defer null_input.close(io);
        const saved = std.c.fcntl(Io.File.stdin().handle, std.posix.F.DUPFD_CLOEXEC, @as(c_int, 3));
        if (saved < 0) return error.DuplicateStdinFailed;
        saved_input = .{ .handle = saved, .flags = .{ .nonblocking = false } };
        // Replace has no stream options. Restore stdin if exec fails.
        try Io.Threaded.dup2(null_input.handle, Io.File.stdin().handle);
    }
    var saved_cwd: ?Io.Dir = null;
    defer if (saved_cwd) |dir| {
        std.process.setCurrentDir(io, dir) catch {};
        dir.close(io);
    };
    if (request.cwd) |path| {
        saved_cwd = try Io.Dir.cwd().openDir(io, ".", .{});
        // The 0.17 POSIX replace backend does not apply ReplaceOptions.cwd.
        try std.process.setCurrentPath(io, path);
    }
    return std.process.replace(io, .{
        .argv = request.argv,
        .environ_map = request.env,
    });
}

pub fn movePath(io: Io, a: A, from: []const u8, to: []const u8) anyerror!void {
    const dir = Io.Dir.cwd();
    const destination_stat = dir.statFile(io, to, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const destination = if (destination_stat != null and destination_stat.?.kind == .directory)
        try std.fs.path.join(a, &.{ to, std.fs.path.basename(from) })
    else
        try a.dupe(u8, to);
    defer a.free(destination);

    dir.rename(from, dir, destination, io) catch |err| switch (err) {
        error.CrossDevice => try moveAcrossDevices(io, a, from, destination),
        else => return err,
    };
}

fn cwd(request: Request) std.process.Child.Cwd {
    return if (request.cwd) |path| .{ .path = path } else .inherit;
}

fn moveAcrossDevices(io: Io, a: A, from: []const u8, to: []const u8) anyerror!void {
    const dir = Io.Dir.cwd();
    const source = try dir.statFile(io, from, .{ .follow_symlinks = false });
    if (source.kind == .directory) {
        const source_path = try dir.realPathFileAlloc(io, from, a);
        defer a.free(source_path);
        const parent_path = try dir.realPathFileAlloc(io, std.fs.path.dirname(to) orelse ".", a);
        defer a.free(parent_path);
        if (std.mem.eql(u8, source_path, parent_path) or
            (std.mem.startsWith(u8, parent_path, source_path) and
                (std.mem.endsWith(u8, source_path, "/") or parent_path[source_path.len] == '/')))
            return error.InvalidDestination;
    }
    var context: @import("process/move.zig").CopyContext = .init(a);
    defer context.deinit();
    try context.publish(io, from, to);
    try dir.deleteTree(io, from);
}

test {
    _ = @import("process/tests.zig");
}

test "cross-device fallback copies before removing and does not merge" {
    try @import("process/tests.zig").checkCopyFallback(moveAcrossDevices);
}

test "cross-device fallback preserves native metadata and hardlinks" {
    try @import("process/move_tests.zig").checkPreservation(moveAcrossDevices);
}

test "cross-device fallback keeps failed copies private and retryable" {
    try @import("process/move_tests.zig").checkFailure(moveAcrossDevices);
}

test "cross-device fallback preserves inherited Darwin file and directory ACLs" {
    try @import("process/move_tests.zig").checkInheritedAcls(moveAcrossDevices);
}

test "failed publication removes read-only staging directories without following links" {
    try @import("process/move_tests.zig").checkPublishFailure(moveAcrossDevices);
}

test "native move preserves metadata and ACLs across a real device boundary" {
    try @import("process/move_tests.zig").checkCrossDeviceMetadata(movePath);
}

test "cross-device fallback finishes sibling hardlinks before restrictive ACLs" {
    try @import("process/move_tests.zig").checkAclHardlinks(moveAcrossDevices);
}

test "cross-device fallback preserves Darwin flags and cleans failed publication" {
    try @import("process/move_tests.zig").checkFlags(moveAcrossDevices);
}
