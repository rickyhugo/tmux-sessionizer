const std = @import("std");

pub fn run(
    io: std.Io,
    command: std.mem.Allocator,
    scratch: std.mem.Allocator,
    argv: []const []const u8,
    env: *const std.process.Environ.Map,
) anyerror!void {
    _ = .{ io, command, scratch, argv, env };
    return error.NotImplemented;
}
