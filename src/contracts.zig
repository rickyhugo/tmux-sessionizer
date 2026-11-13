const std = @import("std");
const config = @import("config");
const repos = @import("repos");
const sessions = @import("sessions");
const picker = @import("picker");

test "all public domain declarations are analyzed" {
    inline for (.{
        config,          repos,              sessions,       picker,         @import("process"),
        @import("tmux"), @import("matcher"), @import("cli"), @import("app"),
    }) |domain| std.testing.refAllDecls(domain);
    std.testing.refAllDecls(@import("tmux").Client);
}

test "raw configuration preserves absent versus empty lists and maps" {
    const absent: config.Config = .{};
    const empty: config.Config = .{
        .bookmarks = &.{},
        .search_dirs = &.{},
        .vcs_providers = &.{},
        .marks = .{},
    };
    try std.testing.expect(absent.bookmarks == null);
    try std.testing.expect(absent.search_dirs == null);
    try std.testing.expect(absent.vcs_providers == null);
    try std.testing.expect(absent.marks == null);
    try std.testing.expectEqual(@as(usize, 0), empty.bookmarks.?.len);
    try std.testing.expectEqual(@as(usize, 0), empty.search_dirs.?.len);
    try std.testing.expectEqual(@as(usize, 0), empty.vcs_providers.?.len);
    try std.testing.expectEqual(@as(u32, 0), empty.marks.?.count());
}

test "catalog index and picker identity do not depend on injection order" {
    const entries = [_]sessions.Session{
        .{ .key = "/a", .name = "a", .source = .{ .bookmark = "/a" } },
        .{ .key = "/b", .name = "b", .source = .{ .repository = .{ .path = "/b", .provider = .git } } },
    };
    var by_key: std.StringHashMapUnmanaged(sessions.Index) = .empty;
    defer by_key.deinit(std.testing.allocator);
    try by_key.put(std.testing.allocator, "/a", 0);
    try by_key.put(std.testing.allocator, "/b", 1);
    const catalog: sessions.Catalog = .{ .entries = &entries, .by_key = by_key };
    const items = [_]picker.Item{
        .{ .id = 1, .label = entries[1].key },
        .{ .id = 0, .label = entries[0].key },
    };
    try std.testing.expectEqual(catalog.by_key.get("/b").?, items[0].id);
    try std.testing.expectEqualStrings("/b", catalog.entries[items[0].id].key);
}

test "picker cursor is a scalar index independent of query byte length" {
    var state: picker.State = .{ .size = .{ .width = 1, .height = 1 } };
    defer state.query.deinit(std.testing.allocator);
    try state.query.appendSlice(std.testing.allocator, "é");
    state.scalar_cursor = 1;
    try std.testing.expectEqual(@as(usize, 2), state.query.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.scalar_cursor);
}
