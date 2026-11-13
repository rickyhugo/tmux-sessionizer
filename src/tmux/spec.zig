const std = @import("std");
const tmux = @import("tmux");
const fake = @import("process");
const client: tmux.Client = .{ .socket = "tms-private-fixture", .inside_tmux = true };

fn expectArgs(index: usize, args: []const []const u8) !void {
    const request = fake.calls.items[index].request;
    try std.testing.expectEqual(@as(usize, args.len + 3), request.argv.len);
    try std.testing.expectEqualStrings("tmux", request.argv[0]);
    try std.testing.expectEqualStrings("-L", request.argv[1]);
    try std.testing.expectEqualStrings("tms-private-fixture", request.argv[2]);
    for (args, request.argv[3..]) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expectEqual(fake.Input.inherit, request.stdin);
}

test "snapshot preserves timestamp text, attached state, and current path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    fake.reset(arena.allocator(), &.{
        .{ .stdout = "'alpha,0,009'\n'beta,2,10'\n" },
        .{ .stdout = "'beta'\n" },
        .{ .stdout = "'/work/beta'\n" },
    });
    const snapshot = try client.snapshot(std.testing.io, arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), snapshot.sessions.len);
    try std.testing.expectEqualStrings("009", snapshot.sessions[0].last_attached);
    try std.testing.expect(!snapshot.sessions[0].attached);
    try std.testing.expect(snapshot.sessions[1].attached);
    try std.testing.expectEqualStrings("/work/beta", snapshot.current.?.path);
    try expectArgs(0, &.{ "list-sessions", "-F", "'#{session_name},#{session_attached},#{session_last_attached}'" });
    try expectArgs(1, &.{ "display-message", "-p", "'#S'" });
}

test "listing preserves literal apostrophes and comma names while legacy snapshots still clean them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const outputs: []const fake.Output = &.{
        .{ .stdout = "'quo'te,ui,0,009'\n''edge',1,10'\n" },
        .{ .stdout = "''edge''\n" },
        .{ .stdout = "'/work/quo'te'\n" },
    };
    fake.reset(a, outputs);
    const listing = try client.listingSnapshot(std.testing.io, a);
    try std.testing.expectEqualStrings("quo'te,ui", listing.sessions[0].name);
    try std.testing.expectEqualStrings("'edge'", listing.sessions[1].name);
    try std.testing.expectEqualStrings("'edge'", listing.current.?.name);
    try std.testing.expectEqualStrings("/work/quo'te", listing.current.?.path);
    try std.testing.expectEqualStrings("009", listing.sessions[0].last_attached);
    fake.reset(a, outputs);
    const legacy = try client.snapshot(std.testing.io, a);
    try std.testing.expectEqualStrings("quote,ui", legacy.sessions[0].name);
    try std.testing.expectEqualStrings("edge", legacy.current.?.name);
}

test "window active and attached fields remain distinct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    fake.reset(arena.allocator(), &.{.{ .stdout = "'@4,edit,1,0'\n'@9,shell,0,1'\n" }});
    const windows = try client.windows(std.testing.io, arena.allocator(), "project");
    try std.testing.expect(windows[0].active);
    try std.testing.expect(!windows[0].attached);
    try std.testing.expect(!windows[1].active);
    try std.testing.expect(windows[1].attached);
    try expectArgs(0, &.{ "list-windows", "-F", "'#{window_id},#{window_name},#{window_active},#{window_attached}'", "-t", "project" });
}

test "comma session names preserve identity and timestamp fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    fake.reset(a, &.{
        .{ .stdout = "'a,b,0,009'\n'current,1,10'\n" },
        .{ .stdout = "'current'\n" },
        .{ .stdout = "'/work/current'\n" },
    });
    const snapshot = try client.snapshot(std.testing.io, a);
    try std.testing.expectEqualStrings("a,b", snapshot.sessions[0].name);
    try std.testing.expectEqualStrings("009", snapshot.sessions[0].last_attached);
    try std.testing.expect(!snapshot.sessions[0].attached);
    try expectArgs(0, &.{ "list-sessions", "-F", "'#{session_name},#{session_attached},#{session_last_attached}'" });
}

test "comma window names do not turn an active window into a filtered attached window" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    fake.reset(a, &.{.{ .stdout = "'@4,topic,ui,1,'\n'@9,other,ui,0,1'\n" }});
    const windows = try client.windows(std.testing.io, a, "a,b");
    try std.testing.expectEqualStrings("@4", windows[0].id);
    try std.testing.expectEqualStrings("topic,ui", windows[0].name);
    try std.testing.expect(windows[0].active);
    try std.testing.expect(!windows[0].attached);
    try std.testing.expect(windows[1].attached);
    try expectArgs(0, &.{ "list-windows", "-F", "'#{window_id},#{window_name},#{window_active},#{window_attached}'", "-t", "a,b" });
}

test "inside switch captures attach fallback before final replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    fake.reset(arena.allocator(), &.{ .{ .term = .{ .exited = 1 } }, .{ .term = .{ .exited = 1 } } });
    try std.testing.expectError(error.Replaced, client.switchTo(std.testing.io, arena.allocator(), "project"));
    try std.testing.expectEqual(@as(usize, 3), fake.calls.items.len);
    try expectArgs(0, &.{ "switch-client", "-t", "project" });
    try expectArgs(1, &.{ "attach-session", "-t", "project" });
    try expectArgs(2, &.{ "attach-session", "-t", "project" });
    try std.testing.expectEqual(.replace, fake.calls.items[2].kind);
}

test "successful captured attach fallback does not replace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    fake.reset(arena.allocator(), &.{ .{ .term = .{ .exited = 1 } }, .{} });
    try client.switchTo(std.testing.io, arena.allocator(), "project");
    try std.testing.expectEqual(@as(usize, 2), fake.calls.items.len);
    try std.testing.expectEqual(.capture, fake.calls.items[1].kind);
}

test "outside tmux replaces directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var outside = client;
    outside.inside_tmux = false;
    fake.reset(arena.allocator(), &.{});
    try std.testing.expectError(error.Replaced, outside.switchTo(std.testing.io, arena.allocator(), "project"));
    try std.testing.expectEqual(@as(usize, 1), fake.calls.items.len);
    try expectArgs(0, &.{ "attach-session", "-t", "project" });
    try std.testing.expectEqual(.replace, fake.calls.items[0].kind);
}

test "creation send keys and attach preserve argv boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    fake.reset(a, &.{});
    _ = try client.newSession(std.testing.io, a, "a-b", "/work/a b");
    _ = try client.newWindow(std.testing.io, a, "topic", "/work/tree", "a-b");
    _ = try client.sendKeys(std.testing.io, a, "/work/a b/.tms-create", "a-b:{start}.{top}");
    try std.testing.expectError(error.Replaced, client.attach(std.testing.io, a, null, "/work/a b"));
    try expectArgs(0, &.{ "new-session", "-d", "-s", "a-b", "-c", "/work/a b" });
    try expectArgs(1, &.{ "new-window", "-n", "topic", "-c", "/work/tree", "-t", "a-b" });
    try expectArgs(2, &.{ "send-keys", "-t", "a-b:{start}.{top}", "/work/a b/.tms-create", "Enter" });
    try expectArgs(3, &.{ "attach-session", "-c", "/work/a b" });
}

test "panes use window and pane targets, capture retains ANSI option" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    fake.reset(a, &.{ .{ .stdout = "'1.0,zsh,/work/a'\n'2.1,vim,/work/a/sub'\n" }, .{ .stdout = "screen" } });
    const panes = try client.panes(std.testing.io, a);
    try std.testing.expectEqualStrings("2.1", panes[1].index);
    try std.testing.expectEqualStrings("vim", panes[1].command);
    try std.testing.expectEqualStrings("screen", try client.capture(std.testing.io, a, "@9"));
    try expectArgs(1, &.{ "capture-pane", "-ep", "-t", "@9" });
}
