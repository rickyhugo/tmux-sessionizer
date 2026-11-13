const std = @import("std");
pub const Input = enum { inherit, ignore };
pub const Request = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    env: ?*const std.process.Environ.Map = null,
    stdin: Input = .inherit,
};
pub const Output = struct {
    term: std.process.Child.Term = .{ .exited = 0 },
    stdout: []const u8 = "",
    stderr: []const u8 = "",
};
pub const Call = struct { kind: enum { capture, inherit, replace }, request: Request };
pub var calls: std.ArrayList(Call) = .empty;
pub var outputs: []const Output = &.{};
pub var allocator: std.mem.Allocator = undefined;

pub fn reset(a: std.mem.Allocator, responses: []const Output) void {
    allocator = a;
    calls = .empty;
    outputs = responses;
}

pub fn capture(_: std.Io, _: std.mem.Allocator, request: Request) !Output {
    const i = calls.items.len;
    try calls.append(allocator, .{ .kind = .capture, .request = request });
    return if (i < outputs.len) outputs[i] else .{};
}
pub fn inherit(_: std.Io, request: Request) !std.process.Child.Term {
    try calls.append(allocator, .{ .kind = .inherit, .request = request });
    return .{ .exited = 0 };
}
pub fn replace(_: std.Io, request: Request) !noreturn {
    try calls.append(allocator, .{ .kind = .replace, .request = request });
    return error.Replaced;
}
pub fn movePath(_: std.Io, _: std.mem.Allocator, _: []const u8, _: []const u8) !void {
    return error.MoveFailed;
}
