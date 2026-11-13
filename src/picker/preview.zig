const std = @import("std");
const builtin = @import("builtin");
const Preview = @import("../picker.zig").Preview;
const Locale = opaque {};
extern "c" fn newlocale(c_int, [*:0]const u8, ?*Locale) ?*Locale;
extern "c" fn freelocale(*Locale) void;
extern "c" fn strcoll_l([*:0]const u8, [*:0]const u8, *Locale) c_int;

pub fn read(io: std.Io, a: std.mem.Allocator, request: Preview) ![]const u8 {
    return switch (request) {
        .none => "",
        .pane => |pane| try pane.client.capture(io, a, pane.target),
        .directory => |path| try directory(io, a, path),
    };
}

fn directory(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([:0]const u8) = .empty;
    defer names.deinit(a);
    defer for (names.items) |name| a.free(name);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const name = try a.dupeSentinel(u8, entry.name, 0);
        errdefer a.free(name);
        try names.append(a, name);
    }
    const collate_mask: c_int = if (builtin.os.tag.isDarwin()) 1 else 1 << 3;
    const locale = newlocale(collate_mask, "", null);
    defer if (locale) |value| freelocale(value);
    std.mem.sort([:0]const u8, names.items, locale, struct {
        fn less(context: ?*Locale, lhs: [:0]const u8, rhs: [:0]const u8) bool {
            if (context) |value| {
                const order = strcoll_l(lhs, rhs, value);
                if (order != 0) return order < 0;
            }
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.less);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(a);
    for (names.items) |name| {
        try output.appendSlice(a, name);
        try output.append(a, '\n');
    }
    return output.toOwnedSlice(a);
}

test "native directory preview sorts names and omits hidden entries" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "zebra", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "alpha", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".hidden", .data = "" });
    try tmp.dir.createDirPath(io, "middle");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    const output = try directory(io, arena.allocator(), path[0..n]);
    try std.testing.expectEqualStrings("alpha\nmiddle\nzebra\n", output);
}
