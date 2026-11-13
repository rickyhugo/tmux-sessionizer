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
    defer abortChild(io, &child);

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
    const term = try waitOwnedChild(io, &child);
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
    defer abortChild(io, &child);
    return try waitOwnedChild(io, &child);
}

fn waitOwnedChild(io: Io, child: *std.process.Child) !std.process.Child.Term {
    const pid = child.id.?;
    // Zig 0.17 closes streams and clears id even when wait is canceled before
    // reaping. Keep ownership of that PID for the caller's abort cleanup.
    errdefer child.id = pid;
    return try child.wait(io);
}

fn abortChild(io: Io, child: *std.process.Child) void {
    const pid = child.id orelse return; // A successful wait already reaped it.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    // Child.kill sends TERM and waits indefinitely in Zig 0.17. Abort must not
    // depend on the child's signal handlers or ability to drain its output.
    while (std.c.kill(pid, .KILL) != 0) {
        if (std.c.errno(@as(c_int, -1)) != .INTR) break;
    }
    // ESRCH can mean the child exited before signaling; still collect its
    // status. wait also closes any remaining streams. Preserve the caller error.
    _ = child.wait(io) catch {};
}

pub fn replace(io: Io, request: Request) anyerror!noreturn {
    if (request.argv.len == 0) return error.EmptyArgv;
    var input: ReplacementInput = if (request.stdin == .ignore) try .save() else .{};
    defer if (input.saved) |file| file.close(io);
    var saved_cwd: ?Io.Dir = null;
    defer if (saved_cwd) |dir| dir.close(io);
    const failure = exec: {
        if (request.stdin == .ignore) input.ignore(io) catch |err| break :exec err;
        if (request.cwd) |path| {
            saved_cwd = Io.Dir.cwd().openDir(io, ".", .{}) catch |err| break :exec err;
            // The 0.17 POSIX replace backend does not apply ReplaceOptions.cwd.
            std.process.setCurrentPath(io, path) catch |err| break :exec err;
        }
        break :exec std.process.replace(io, .{
            .argv = request.argv,
            .environ_map = request.env,
        });
    };
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    // Attempt both rollbacks even if one fails; never hide a restoration error.
    const cwd_result = if (saved_cwd) |dir| std.process.setCurrentDir(io, dir) else {};
    const input_result = input.restore();
    try cwd_result;
    try input_result;
    return failure;
}

const ReplacementInput = struct {
    saved: ?Io.File = null,
    flags: c_int = 0,
    changed: bool = false,

    fn save() !ReplacementInput {
        const flags = std.c.fcntl(0, std.posix.F.GETFD);
        if (flags < 0) {
            if (std.c.errno(flags) == .BADF) return .{};
            return error.ReadStdinFlagsFailed;
        }
        const fd = std.c.fcntl(0, std.posix.F.DUPFD_CLOEXEC, @as(c_int, 3));
        if (fd < 0) return error.DuplicateStdinFailed;
        return .{
            .saved = .{ .handle = fd, .flags = .{ .nonblocking = false } },
            .flags = flags,
        };
    }

    fn ignore(self: *ReplacementInput, io: Io) !void {
        const file = try Io.Dir.openFileAbsolute(io, "/dev/null", .{});
        if (file.handle == 0) {
            // With originally closed stdin, open already installed /dev/null.
            // Transfer ownership to rollback and clear open's close-on-exec bit.
            self.changed = true;
            try setFlags(0);
        } else {
            defer file.close(io);
            try Io.Threaded.dup2(file.handle, 0);
            self.changed = true;
        }
    }

    fn restore(self: ReplacementInput) !void {
        if (!self.changed) return;
        if (self.saved) |file| {
            try Io.Threaded.dup2(file.handle, 0);
            try setFlags(self.flags);
        } else {
            if (std.c.close(0) != 0) return error.CloseStdinFailed;
        }
    }

    fn setFlags(flags: c_int) !void {
        while (std.c.fcntl(0, std.posix.F.SETFD, flags) < 0) {
            if (std.c.errno(@as(c_int, -1)) != .INTR) return error.SetStdinFlagsFailed;
        }
    }
};

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
