const std = @import("std");
const A = std.mem.Allocator;
const Io = std.Io;
const Output = @import("process").Output;

pub const SessionInfo = struct {
    name: []const u8,
    attached: bool,
    last_attached: []const u8,
};
pub const Current = struct { name: []const u8, path: []const u8 };
pub const Snapshot = struct { sessions: []const SessionInfo, current: ?Current };
pub const Window = struct { id: []const u8, name: []const u8, active: bool, attached: bool };
pub const Pane = struct { index: []const u8, command: []const u8, cwd: []const u8 };
pub const Client = struct {
    socket: []const u8,
    inside_tmux: bool,

    pub fn snapshot(self: *const Client, io: Io, a: A) anyerror!Snapshot {
        _ = .{ self, io, a };
        return error.NotImplemented;
    }

    pub fn windows(self: *const Client, io: Io, a: A, session: ?[]const u8) anyerror![]const Window {
        _ = .{ self, io, a, session };
        return error.NotImplemented;
    }

    pub fn panes(self: *const Client, io: Io, a: A) anyerror![]const Pane {
        _ = .{ self, io, a };
        return error.NotImplemented;
    }

    pub fn capture(self: *const Client, io: Io, a: A, target: []const u8) anyerror![]const u8 {
        _ = .{ self, io, a, target };
        return error.NotImplemented;
    }

    pub fn attachedSession(self: *const Client, io: Io, a: A) anyerror![]const u8 {
        _ = .{ self, io, a };
        return error.NotImplemented;
    }

    pub fn newSession(self: *const Client, io: Io, a: A, name: ?[]const u8, path: ?[]const u8) anyerror!Output {
        _ = .{ self, io, a, name, path };
        return error.NotImplemented;
    }

    pub fn newWindow(self: *const Client, io: Io, a: A, name: ?[]const u8, path: ?[]const u8, session: ?[]const u8) anyerror!Output {
        _ = .{ self, io, a, name, path, session };
        return error.NotImplemented;
    }

    pub fn killSession(self: *const Client, io: Io, a: A, name: []const u8) anyerror!Output {
        _ = .{ self, io, a, name };
        return error.NotImplemented;
    }

    pub fn killWindow(self: *const Client, io: Io, a: A, target: []const u8) anyerror!Output {
        _ = .{ self, io, a, target };
        return error.NotImplemented;
    }

    pub fn selectWindow(self: *const Client, io: Io, a: A, target: []const u8) anyerror!Output {
        _ = .{ self, io, a, target };
        return error.NotImplemented;
    }

    pub fn renameSession(self: *const Client, io: Io, a: A, name: []const u8) anyerror!Output {
        _ = .{ self, io, a, name };
        return error.NotImplemented;
    }

    pub fn sendKeys(self: *const Client, io: Io, a: A, text: []const u8, target: ?[]const u8) anyerror!Output {
        _ = .{ self, io, a, text, target };
        return error.NotImplemented;
    }

    pub fn switchClient(self: *const Client, io: Io, a: A, name: []const u8) anyerror!Output {
        _ = .{ self, io, a, name };
        return error.NotImplemented;
    }

    pub fn switchTo(self: *const Client, io: Io, a: A, name: []const u8) anyerror!void {
        _ = .{ self, io, a, name };
        return error.NotImplemented;
    }

    pub fn attach(self: *const Client, io: Io, a: A, name: ?[]const u8, path: ?[]const u8) anyerror!noreturn {
        _ = .{ self, io, a, name, path };
        return error.NotImplemented;
    }

    pub fn refreshClient(self: *const Client, io: Io, a: A) anyerror!Output {
        _ = .{ self, io, a };
        return error.NotImplemented;
    }

    pub fn start(self: *const Client, io: Io, a: A) anyerror!Output {
        _ = .{ self, io, a };
        return error.NotImplemented;
    }
};
