const std = @import("std");
const sessions = @import("sessions");
const config = @import("config");
const process = @import("process");
const io = std.testing.io;

fn git(a: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    const output = try process.capture(io, a, .{
        .argv = try std.mem.concat(a, []const u8, &.{ &.{
            "git", "-c", "user.name=tms-test", "-c", "user.email=tms-test@example.com", "-c", "core.hooksPath=/dev/null",
        }, args }),
        .cwd = cwd,
        .stdin = .ignore,
    });
    if (output.term != .exited or output.term.exited != 0) {
        std.debug.print("{s}\n", .{output.stderr});
        return error.FixtureCommandFailed;
    }
}

test "repeated repository roots and bookmarks retain the first repository and its bare cwd" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    const bare = try std.fs.path.join(a, &.{ project, ".bare" });
    try git(a, project, &.{ "init", "--bare", "--quiet", bare });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/.git", .data = "gitdir: .bare\n" });
    var env = std.process.Environ.Map.init(a);
    for ([_]bool{ false, true }) |full_path| {
        const cfg: config.Config = .{
            .search_dirs = &.{ .{ .path = project, .depth = 0 }, .{ .path = project, .depth = 0 } },
            .bookmarks = &.{ project, project },
            .display_full_path = full_path,
        };
        const catalog = try sessions.discover(io, a, &env, &cfg);
        try std.testing.expectEqual(@as(usize, 1), catalog.entries.len);
        const entry = catalog.entries[0];
        try std.testing.expect(entry.source == .repository);
        try std.testing.expectEqualStrings(project, entry.source.repository.path);
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "/{s}", .{project}), entry.name);
        try std.testing.expectEqualStrings(if (full_path) project else entry.name, entry.key);
        try std.testing.expectEqualStrings(bare, try sessions.path(io, a, entry));
        try std.testing.expectEqual(@as(usize, 0), catalog.by_key.get(entry.key).?);
    }
}

test "generated worktrees deduplicate with bookmarks before full path insertion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const project = try std.fs.path.join(a, &.{ root, "project" });
    const original = try std.fs.path.join(a, &.{ root, "topic" });
    const checkout = try std.fs.path.join(a, &.{ root, "project#topic" });
    try git(a, root, &.{ "init", "--bare", "--quiet", project });
    try git(a, project, &.{ "worktree", "add", "--quiet", "--orphan", "-b", "topic", original });
    try git(a, project, &.{ "worktree", "move", original, checkout });
    var env = std.process.Environ.Map.init(a);
    for ([_]bool{ false, true }) |full_path| {
        const cfg: config.Config = .{
            .search_dirs = &.{.{ .path = project, .depth = 0 }},
            .bookmarks = &.{checkout},
            .list_worktrees = true,
            .display_full_path = full_path,
        };
        const catalog = try sessions.discover(io, a, &env, &cfg);
        try std.testing.expectEqual(@as(usize, 2), catalog.entries.len);
        const name = try std.fmt.allocPrint(a, "/{s}", .{checkout});
        const entry = catalog.entries[catalog.by_key.get(if (full_path) checkout else name).?];
        try std.testing.expect(entry.source == .repository);
        try std.testing.expectEqualStrings(name, entry.name);
        try std.testing.expectEqualStrings(checkout, try sessions.path(io, a, entry));
        const parent = catalog.entries[catalog.by_key.get(if (full_path) project else "project").?];
        try std.testing.expectEqualStrings("project", parent.name);
        try std.testing.expectEqualStrings(project, try sessions.path(io, a, parent));
    }
}
