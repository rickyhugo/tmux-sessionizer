const std = @import("std");
const Size = @import("../picker.zig").Size;
const c = std.c;
extern "c" fn cfmakeraw(*c.termios) void;
extern "c" fn ttyname_r(c_int, [*]u8, usize) c_int;

const signals = [_]c.SIG{ .TERM, .HUP, .INT, .QUIT, .WINCH, .TSTP, .CONT };
var owned = std.atomic.Value(bool).init(false);
var terminating = std.atomic.Value(c_int).init(0);
var resized = std.atomic.Value(bool).init(false);
var suspended = std.atomic.Value(bool).init(false);

fn signalHandler(signal: c.SIG) callconv(.c) void {
    switch (signal) {
        .WINCH, .CONT => resized.store(true, .monotonic),
        .TSTP => suspended.store(true, .monotonic),
        else => terminating.store(@intCast(@backingInt(signal)), .monotonic),
    }
}

pub const Terminal = struct {
    fd: c_int,
    original: c.termios,
    handlers: [signals.len]c.Sigaction,
    raw: bool = false,
    handlers_set: usize = 0,

    pub fn init() !Terminal {
        if (owned.swap(true, .acquire)) return error.TerminalAlreadyOwned;
        errdefer owned.store(false, .release);
        terminating.store(0, .monotonic);
        resized.store(false, .monotonic);
        suspended.store(false, .monotonic);
        var fd = if (c.isatty(0) == 1) c.dup(0) else c.open("/dev/tty", .{ .ACCMODE = .RDWR, .CLOEXEC = true });
        if (fd < 0) return error.NotATerminal;
        errdefer _ = c.close(fd);
        // Darwin poll rejects the /dev/tty alias, but accepts the concrete device.
        var path: [std.fs.max_path_bytes:0]u8 = @splat(0);
        if (ttyname_r(fd, &path, path.len) == 0) {
            const concrete = c.open(&path, .{ .ACCMODE = .RDWR, .CLOEXEC = true });
            if (concrete >= 0) {
                _ = c.close(fd);
                fd = concrete;
            }
        }
        if (c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return error.TerminalDescriptor;
        var self: Terminal = .{ .fd = fd, .original = undefined, .handlers = undefined };
        if (c.tcgetattr(fd, &self.original) != 0) return error.TerminalAttributes;
        errdefer self.restoreHandlers();
        for (signals) |signal| {
            var action: c.Sigaction = std.mem.zeroes(c.Sigaction);
            action.handler.handler = signalHandler;
            _ = c.sigemptyset(&action.mask);
            if (c.sigaction(signal, &action, &self.handlers[self.handlers_set]) != 0) return error.SignalHandler;
            self.handlers_set += 1;
        }
        errdefer self.leave();
        try self.enter();
        return self;
    }

    fn enter(self: *Terminal) !void {
        var raw = self.original;
        cfmakeraw(&raw);
        raw.cc[@backingInt(c.V.MIN)] = 1;
        raw.cc[@backingInt(c.V.TIME)] = 0;
        if (c.tcsetattr(self.fd, .NOW, &raw) != 0) return error.TerminalAttributes;
        self.raw = true;
        try self.write("\x1b[?1049h\x1b[?25l\x1b[0m");
    }

    fn leave(self: *Terminal) void {
        if (!self.raw) return;
        self.write("\x1b[0m\x1b[?25h\x1b[?1049l") catch {};
        while (c.tcsetattr(self.fd, .NOW, &self.original) != 0) {
            if (c._errno().* != @backingInt(c.E.INTR)) break;
        }
        self.raw = false;
    }

    fn restoreHandlers(self: *Terminal) void {
        while (self.handlers_set > 0) {
            self.handlers_set -= 1;
            _ = c.sigaction(signals[self.handlers_set], &self.handlers[self.handlers_set], null);
        }
    }

    pub fn deinit(self: *Terminal) void {
        self.leave();
        self.restoreHandlers();
        _ = c.close(self.fd);
        owned.store(false, .release);
    }

    pub fn checkSignals(self: *Terminal) !bool {
        const signal = terminating.swap(0, .monotonic);
        if (signal != 0) {
            self.leave();
            self.restoreHandlers();
            _ = c.raise(@fromBackingInt(@intCast(signal)));
            return error.Terminated;
        }
        if (suspended.swap(false, .monotonic)) {
            self.leave();
            _ = c.raise(.STOP);
            try self.enter();
            return true;
        }
        return resized.swap(false, .monotonic);
    }

    pub fn size(self: *const Terminal) Size {
        var value: c.winsize = std.mem.zeroes(c.winsize);
        if (c.ioctl(self.fd, c.T.IOCGWINSZ, @intFromPtr(&value)) != 0) return .{ .width = 80, .height = 24 };
        return .{ .width = value.col, .height = value.row };
    }

    pub fn write(self: *const Terminal, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len > 0) {
            const n = c.write(self.fd, rest.ptr, rest.len);
            if (n < 0) {
                if (std.c._errno().* == @backingInt(c.E.INTR)) continue;
                return error.TerminalWrite;
            }
            if (n == 0) return error.TerminalWrite;
            rest = rest[@intCast(n)..];
        }
    }

    pub fn wait(self: *const Terminal, timeout: c_int) !bool {
        var fd: c.pollfd = .{ .fd = self.fd, .events = c.POLL.IN, .revents = 0 };
        const n = c.poll(@ptrCast(&fd), 1, timeout);
        if (n < 0) {
            if (std.c._errno().* == @backingInt(c.E.INTR)) return false;
            return error.TerminalPoll;
        }
        if (fd.revents & (c.POLL.HUP | c.POLL.ERR | c.POLL.NVAL) != 0) return error.TerminalClosed;
        return n > 0 and fd.revents & c.POLL.IN != 0;
    }

    pub fn read(self: *const Terminal, bytes: []u8) !usize {
        while (true) {
            const n = c.read(self.fd, bytes.ptr, bytes.len);
            if (n >= 0) return @intCast(n);
            if (std.c._errno().* != @backingInt(c.E.INTR)) return error.TerminalRead;
            if (terminating.load(.monotonic) != 0) return error.Terminated;
        }
    }
};
