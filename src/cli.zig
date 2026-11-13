const std = @import("std");
const config = @import("config");
const A = std.mem.Allocator;
const Io = std.Io;

pub const ConfigCommand = union(enum) { edit: config.SettingsEdit, list: struct { defaults: bool } };
pub const MarksCommand = union(enum) {
    list,
    set: struct { index: ?usize, path: ?[]const u8 },
    open: usize,
    delete: usize,
    clear,
};
pub const Command = union(enum) {
    pick,
    config: ConfigCommand,
    start,
    switch_session,
    windows,
    kill,
    sessions,
    rename: []const u8,
    refresh: ?[]const u8,
    clone_repo: struct { repository: []const u8, path: ?[]const u8, name: ?[]const u8 },
    init_repo: []const u8,
    bookmark: struct { delete: bool, path: ?[]const u8 },
    open_session: []const u8,
    marks: MarksCommand,
    help: []const []const u8,
    version,
};

pub fn parse(a: A, args: []const []const u8) anyerror!Command {
    _ = .{ a, args };
    return error.NotImplemented;
}

pub fn help(a: A, path: []const []const u8) anyerror![]const u8 {
    _ = .{ a, path };
    return error.NotImplemented;
}

pub fn complete(io: Io, a: A, args: []const []const u8, env: *const std.process.Environ.Map) anyerror!bool {
    _ = .{ io, a, args, env };
    return error.NotImplemented;
}
