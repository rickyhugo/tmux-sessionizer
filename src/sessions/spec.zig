const std = @import("std");
const sessions = @import("sessions");
const config = @import("config");
const tmux = @import("tmux");
const fake = @import("process");
const client: tmux.Client = .{ .socket = "tms-session-fixture", .inside_tmux = true };

fn expectArgs(index: usize, args: []const []const u8) !void {
    const request = fake.calls.items[index].request;
    try std.testing.expectEqual(args.len + 3, request.argv.len);
    try std.testing.expectEqualStrings("-L", request.argv[1]);
    try std.testing.expectEqualStrings("tms-session-fixture", request.argv[2]);
    for (args, request.argv[3..]) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "opening bookmark normalizes periods, keeps hyphens, sends nonexecutable script only on creation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(std.testing.io, .{ .sub_path = ".tms-create", .data = "echo ignored" });
    const path = try directory.dir.realPathFileAlloc(std.testing.io, ".", a);
    const entry: sessions.Session = .{ .key = "/visible/key", .name = "project.one-two", .source = .{ .bookmark = path } };
    const cfg: config.Config = .{};
    fake.reset(a, &.{});
    try sessions.open(std.testing.io, a, entry, &client, &cfg);
    try std.testing.expectEqual(@as(usize, 6), fake.calls.items.len);
    try expectArgs(3, &.{ "new-session", "-d", "-s", "project_one-two", "-c", path });
    try expectArgs(4, &.{ "send-keys", "-t", "project_one-two:{start}.{top}", try std.fs.path.join(a, &.{ path, ".tms-create" }), "Enter" });
    try expectArgs(5, &.{ "switch-client", "-t", "project_one-two" });

    fake.reset(a, &.{.{ .stdout = "'project_one-two,0,9'\n" }});
    try sessions.open(std.testing.io, a, entry, &client, &cfg);
    try std.testing.expectEqual(@as(usize, 4), fake.calls.items.len);
    try expectArgs(3, &.{ "switch-client", "-t", "project_one-two" });
}

test "configured creation script is keyed by normalized session name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(std.testing.io, .{ .sub_path = "custom-script", .data = "" });
    const path = try directory.dir.realPathFileAlloc(std.testing.io, ".", a);
    const script = try std.fs.path.join(a, &.{ path, "custom-script" });
    var configs: std.StringHashMapUnmanaged(config.SessionConfig) = .empty;
    try configs.put(a, "project_one", .{ .create_script = script });
    const cfg: config.Config = .{ .session_configs = configs };
    const entry: sessions.Session = .{ .key = "project.one", .name = "project.one", .source = .{ .bookmark = path } };
    fake.reset(a, &.{});
    try sessions.open(std.testing.io, a, entry, &client, &cfg);
    try expectArgs(4, &.{ "send-keys", "-t", "project_one:{start}.{top}", script, "Enter" });
}

test "opening an existing comma session does not recreate it or rerun its script" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(std.testing.io, .{ .sub_path = ".tms-create", .data = "echo should-not-run" });
    const path = try directory.dir.realPathFileAlloc(std.testing.io, ".", a);
    const entry: sessions.Session = .{ .key = "a,b", .name = "a,b", .source = .{ .bookmark = path } };
    const cfg: config.Config = .{};
    fake.reset(a, &.{.{ .stdout = "'a,b,0,'\n" }});
    try sessions.open(std.testing.io, a, entry, &client, &cfg);
    try std.testing.expectEqual(@as(usize, 4), fake.calls.items.len);
    try expectArgs(3, &.{ "switch-client", "-t", "a,b" });
}
