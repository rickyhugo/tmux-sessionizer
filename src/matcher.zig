const std = @import("std");

pub fn rank(allocator: std.mem.Allocator, query: []const u8, candidates: []const []const u8) anyerror![]usize {
    _ = .{ allocator, query, candidates };
    return error.NotImplemented;
}
