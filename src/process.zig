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
    _ = .{ io, a, request };
    return error.NotImplemented;
}

pub fn inherit(io: Io, request: Request) anyerror!std.process.Child.Term {
    _ = .{ io, request };
    return error.NotImplemented;
}

pub fn replace(io: Io, request: Request) anyerror!noreturn {
    _ = .{ io, request };
    return error.NotImplemented;
}

pub fn movePath(io: Io, a: A, from: []const u8, to: []const u8) anyerror!void {
    _ = .{ io, a, from, to };
    return error.NotImplemented;
}
