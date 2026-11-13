const std = @import("std");
const tmux = @import("tmux");
const process = @import("process");
const io = std.testing.io;

fn command(a: std.mem.Allocator, socket: []const u8, args: []const []const u8) !process.Output {
    return process.capture(io, a, .{ .argv = try std.mem.concat(a, []const u8, &.{ &.{ "tmux", "-L", socket }, args }) });
}

test "real tmux session window pane and socket lifecycle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env = try std.testing.environ.createMap(a);
    const socket = env.get("TMS_TMUX_SOCKET") orelse return error.SkipZigTest;
    if (!std.mem.startsWith(u8, socket, "tms-port-test-")) return error.UnsafeTestSocket;
    const client: tmux.Client = .{ .socket = socket, .inside_tmux = true };
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const path = try directory.dir.realPathFileAlloc(io, ".", a);
    try directory.dir.writeFile(io, .{
        .sub_path = "tmux.conf",
        .data = "set -g default-shell /bin/sh\nset -g default-command 'sleep 300'\nset -g base-index 1\n",
    });
    const fixture_config = try std.fs.path.join(a, &.{ path, "tmux.conf" });
    const started = try command(a, socket, &.{ "-f", fixture_config, "new-session", "-d", "-s", "alpha", "-c", path });
    defer _ = command(a, socket, &.{"kill-server"}) catch {};
    try std.testing.expect(tmux.succeeded(started.term));
    try std.testing.expect(tmux.succeeded((try client.newSession(io, a, "beta,ui", path)).term));
    var snapshot = try client.snapshot(io, a);
    try std.testing.expectEqual(@as(usize, 2), snapshot.sessions.len);
    try std.testing.expectEqualStrings("alpha", snapshot.sessions[0].name);
    try std.testing.expectEqualStrings("beta,ui", snapshot.sessions[1].name);
    try std.testing.expect(tmux.succeeded((try client.newWindow(io, a, "topic,ui", path, "beta,ui")).term));
    const windows = try client.windows(io, a, "beta,ui");
    try std.testing.expectEqual(@as(usize, 2), windows.len);
    try std.testing.expectEqualStrings("topic,ui", windows[1].name);
    try std.testing.expect(windows[1].active);
    try std.testing.expect(!windows[1].attached);
    try std.testing.expect(tmux.succeeded((try client.selectWindow(io, a, windows[0].id)).term));
    try std.testing.expect((try client.windows(io, a, "beta,ui"))[0].active);
    const panes = try client.panes(io, a);
    try std.testing.expect(panes.len > 0);
    try std.testing.expectEqualStrings(path, panes[0].cwd);
    _ = try client.capture(io, a, windows[0].id);
    try std.testing.expect(tmux.succeeded((try client.sendKeys(io, a, "not-executed-by-sleep", windows[0].id)).term));
    try std.testing.expect(tmux.succeeded((try client.renameSession(io, a, "renamed")).term));
    snapshot = try client.snapshot(io, a);
    var renamed = false;
    for (snapshot.sessions) |s| {
        if (std.mem.eql(u8, s.name, "renamed")) renamed = true;
    }
    try std.testing.expect(renamed);
    try std.testing.expect(tmux.succeeded((try client.killWindow(io, a, windows[1].id)).term));
    try std.testing.expect(tmux.succeeded((try client.killSession(io, a, "renamed")).term));
    try std.testing.expectEqual(@as(usize, 1), (try client.snapshot(io, a)).sessions.len);
    const remaining = (try client.snapshot(io, a)).sessions[0].name;
    try std.testing.expect(tmux.succeeded((try client.newSession(io, a, "quo'te,ui", path)).term));
    try std.testing.expect(tmux.succeeded((try client.killSession(io, a, remaining)).term));
    const listing = try client.listingSnapshot(io, a);
    try std.testing.expectEqual(@as(usize, 1), listing.sessions.len);
    try std.testing.expectEqualStrings("quo'te,ui", listing.sessions[0].name);
    try std.testing.expectEqualStrings("quo'te,ui", listing.current.?.name);
    try std.testing.expectEqualStrings("quote,ui", (try client.snapshot(io, a)).sessions[0].name);
}
