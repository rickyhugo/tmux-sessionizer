const std = @import("std");
const process = @import("process");
const A = std.mem.Allocator;
const Io = std.Io;
pub const Output = process.Output;

pub const SessionInfo = struct {
    name: []const u8,
    attached: bool,
    last_attached: []const u8,
};
pub const Current = struct { name: []const u8, path: []const u8 };
pub const Snapshot = struct { sessions: []const SessionInfo, current: ?Current };
pub const Window = struct { id: []const u8, name: []const u8, active: bool, attached: bool };
pub const Pane = struct { index: []const u8, command: []const u8, cwd: []const u8 };

fn clean(a: A, text: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, a, std.mem.trim(u8, text, " \r\n"), "'", "");
}

fn snapshotText(a: A, text: []const u8, literal: bool) ![]const u8 {
    if (!literal) return clean(a, text);
    const trimmed = std.mem.trim(u8, text, " \r\n");
    return if (trimmed.len >= 2 and trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'')
        trimmed[1 .. trimmed.len - 1]
    else
        trimmed;
}

pub fn succeeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

pub const Client = struct {
    socket: []const u8,
    inside_tmux: bool,

    fn argv(self: *const Client, a: A, args: []const []const u8) ![]const []const u8 {
        return std.mem.concat(a, []const u8, &.{ &.{ "tmux", "-L", self.socket }, args });
    }

    fn execute(self: *const Client, io: Io, a: A, args: []const []const u8) !Output {
        return process.capture(io, a, .{ .argv = try self.argv(a, args) });
    }

    pub fn snapshot(self: *const Client, io: Io, a: A) anyerror!Snapshot {
        return self.readSnapshot(io, a, false);
    }

    pub fn listingSnapshot(self: *const Client, io: Io, a: A) anyerror!Snapshot {
        // Listing uses literal names. Other commands retain Rust's historical
        // apostrophe stripping through snapshot().
        return self.readSnapshot(io, a, true);
    }

    fn readSnapshot(self: *const Client, io: Io, a: A, literal: bool) anyerror!Snapshot {
        const output = try self.execute(io, a, &.{ "list-sessions", "-F", "'#{session_name},#{session_attached},#{session_last_attached}'" });
        var list: std.ArrayList(SessionInfo) = .empty;
        var lines = std.mem.tokenizeScalar(u8, output.stdout, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.splitBackwardsScalar(u8, try snapshotText(a, line, literal), ',');
            const timestamp = fields.next() orelse continue;
            const attached = fields.next() orelse continue;
            const name = fields.rest();
            try list.append(a, .{ .name = name, .attached = !std.mem.eql(u8, attached, "0"), .last_attached = timestamp });
        }
        const name = try snapshotText(a, (try self.execute(io, a, &.{ "display-message", "-p", "'#S'" })).stdout, literal);
        const cwd = try snapshotText(a, (try self.execute(io, a, &.{ "display-message", "-p", "'#{session_path}'" })).stdout, literal);
        return .{ .sessions = try list.toOwnedSlice(a), .current = if (name.len == 0) null else .{ .name = name, .path = cwd } };
    }

    pub fn windows(self: *const Client, io: Io, a: A, session: ?[]const u8) anyerror![]const Window {
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(a, &.{ "list-windows", "-F", "'#{window_id},#{window_name},#{window_active},#{window_attached}'" });
        if (session) |s| try args.appendSlice(a, &.{ "-t", s });
        const output = try self.execute(io, a, args.items);
        var result: std.ArrayList(Window) = .empty;
        var lines = std.mem.tokenizeScalar(u8, output.stdout, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.splitBackwardsScalar(u8, try clean(a, line), ',');
            const attached = fields.next() orelse continue;
            const active = fields.next() orelse continue;
            const prefix = fields.rest();
            const separator = std.mem.indexOfScalar(u8, prefix, ',') orelse continue;
            const id = prefix[0..separator];
            const name = prefix[separator + 1 ..];
            try result.append(a, .{ .id = id, .name = name, .active = std.mem.eql(u8, active, "1"), .attached = std.mem.eql(u8, attached, "1") });
        }
        return result.toOwnedSlice(a);
    }

    pub fn panes(self: *const Client, io: Io, a: A) anyerror![]const Pane {
        const output = try self.execute(io, a, &.{ "list-windows", "-F", "'#{window_index}.#{pane_index},#{pane_current_command},#{pane_current_path}'" });
        var result: std.ArrayList(Pane) = .empty;
        var lines = std.mem.tokenizeScalar(u8, output.stdout, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.splitScalar(u8, try clean(a, line), ',');
            const index = fields.next() orelse continue;
            const command = fields.next() orelse continue;
            const cwd = fields.next() orelse continue;
            try result.append(a, .{ .index = index, .command = command, .cwd = cwd });
        }
        return result.toOwnedSlice(a);
    }

    pub fn capture(self: *const Client, io: Io, a: A, target: []const u8) anyerror![]const u8 {
        const output = try self.execute(io, a, &.{ "capture-pane", "-ep", "-t", target });
        return if (succeeded(output.term)) output.stdout else "";
    }

    pub fn attachedSession(self: *const Client, io: Io, a: A) anyerror![]const u8 {
        return (try self.execute(io, a, &.{ "list-sessions", "-F", "#{session_name}", "-f", "#{session_attached}" })).stdout;
    }

    pub fn newSession(self: *const Client, io: Io, a: A, name: ?[]const u8, path: ?[]const u8) anyerror!Output {
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(a, &.{ "new-session", "-d" });
        if (name) |n| try args.appendSlice(a, &.{ "-s", n });
        if (path) |p| try args.appendSlice(a, &.{ "-c", p });
        return self.execute(io, a, args.items);
    }

    pub fn newWindow(self: *const Client, io: Io, a: A, name: ?[]const u8, path: ?[]const u8, session: ?[]const u8) anyerror!Output {
        var args: std.ArrayList([]const u8) = .empty;
        try args.append(a, "new-window");
        if (name) |n| try args.appendSlice(a, &.{ "-n", n });
        if (path) |p| try args.appendSlice(a, &.{ "-c", p });
        if (session) |s| try args.appendSlice(a, &.{ "-t", s });
        return self.execute(io, a, args.items);
    }

    pub fn killSession(self: *const Client, io: Io, a: A, name: []const u8) anyerror!Output {
        return self.execute(io, a, &.{ "kill-session", "-t", name });
    }
    pub fn killWindow(self: *const Client, io: Io, a: A, target: []const u8) anyerror!Output {
        return self.execute(io, a, &.{ "kill-window", "-t", target });
    }
    pub fn selectWindow(self: *const Client, io: Io, a: A, target: []const u8) anyerror!Output {
        return self.execute(io, a, &.{ "select-window", "-t", target });
    }
    pub fn renameSession(self: *const Client, io: Io, a: A, name: []const u8) anyerror!Output {
        return self.execute(io, a, &.{ "rename-session", name });
    }
    pub fn sendKeys(self: *const Client, io: Io, a: A, text: []const u8, target: ?[]const u8) anyerror!Output {
        var args: std.ArrayList([]const u8) = .empty;
        try args.append(a, "send-keys");
        if (target) |t| try args.appendSlice(a, &.{ "-t", t });
        try args.appendSlice(a, &.{ text, "Enter" });
        return self.execute(io, a, args.items);
    }
    pub fn switchClient(self: *const Client, io: Io, a: A, name: []const u8) anyerror!Output {
        const output = try self.execute(io, a, &.{ "switch-client", "-t", name });
        if (!succeeded(output.term)) return self.execute(io, a, &.{ "attach-session", "-t", name });
        return output;
    }
    pub fn switchTo(self: *const Client, io: Io, a: A, name: []const u8) anyerror!void {
        if (!self.inside_tmux) try self.attach(io, a, name, null);
        const output = try self.switchClient(io, a, name);
        if (!succeeded(output.term)) try self.attach(io, a, name, null);
    }
    pub fn attach(self: *const Client, io: Io, a: A, name: ?[]const u8, path: ?[]const u8) anyerror!noreturn {
        var args: std.ArrayList([]const u8) = .empty;
        try args.append(a, "attach-session");
        if (name) |n| try args.appendSlice(a, &.{ "-t", n });
        if (path) |p| try args.appendSlice(a, &.{ "-c", p });
        return process.replace(io, .{ .argv = try self.argv(a, args.items) });
    }
    pub fn refreshClient(self: *const Client, io: Io, a: A) anyerror!Output {
        return self.execute(io, a, &.{ "refresh-client", "-S" });
    }
    pub fn start(self: *const Client, io: Io, a: A) anyerror!Output {
        return self.execute(io, a, &.{});
    }
};

test "socket selector always precedes command" {
    const a = std.testing.allocator;
    const client: Client = .{ .socket = "tms-test-only", .inside_tmux = true };
    const args = try client.argv(a, &.{ "new-session", "-d" });
    defer a.free(args);
    try std.testing.expectEqualSlices([]const u8, &.{ "tmux", "-L", "tms-test-only", "new-session", "-d" }, args);
}
