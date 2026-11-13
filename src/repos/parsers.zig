const std = @import("std");
const A = std.mem.Allocator;
const Worktree = @import("../repos.zig").Worktree;

pub fn boolean(text: []const u8) !bool {
    if (std.mem.eql(u8, text, "true")) return true;
    if (std.mem.eql(u8, text, "false")) return false;
    return error.InvalidBoolean;
}

pub fn gitdir(a: A, base: []const u8, bytes: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, bytes, "gitdir: ")) return error.InvalidGitdir;
    const path = std.mem.trimEnd(u8, bytes["gitdir: ".len..], std.ascii.whitespace[0..]);
    if (path.len == 0) return error.InvalidGitdir;
    return std.fs.path.resolve(a, &.{ base, path });
}

pub fn worktreePath(a: A, pointer: []const u8, bytes: []const u8) ![]const u8 {
    const path = std.mem.trimEnd(u8, bytes, std.ascii.whitespace[0..]);
    if (path.len == 0) return error.InvalidGitdir;
    const absolute = try std.fs.path.resolve(a, &.{ std.fs.path.dirname(pointer) orelse ".", path });
    return if (std.mem.eql(u8, std.fs.path.basename(absolute), ".git"))
        std.fs.path.dirname(absolute) orelse absolute
    else
        absolute;
}

pub const Module = struct { name: []const u8, path: []const u8 };

pub fn submoduleEntries(a: A, bytes: []const u8) ![]const Module {
    var modules: std.ArrayList(Module) = .empty;
    var records = std.mem.splitScalar(u8, bytes, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        const newline = std.mem.indexOfScalar(u8, record, '\n') orelse return error.InvalidSubmodules;
        const key = record[0..newline];
        if (key.len < "submodule..path".len or
            !std.mem.startsWith(u8, key, "submodule.") or !std.mem.endsWith(u8, key, ".path"))
            return error.InvalidSubmodules;
        const module: Module = .{
            .name = key["submodule.".len .. key.len - ".path".len],
            .path = record[newline + 1 ..],
        };
        var duplicate = false;
        for (modules.items) |*existing| {
            if (std.mem.eql(u8, existing.name, module.name)) {
                existing.path = module.path;
                duplicate = true;
                break;
            }
        }
        if (!duplicate) try modules.append(a, module);
    }
    var count: usize = 0;
    for (modules.items) |module| {
        if (!validModule(module)) continue;
        modules.items[count] = module;
        count += 1;
    }
    modules.shrinkRetainingCapacity(count);
    return modules.toOwnedSlice(a);
}

fn validModule(module: Module) bool {
    if (module.name.len == 0 or module.path.len == 0 or std.fs.path.isAbsolute(module.path)) return false;
    var names = std.mem.tokenizeAny(u8, module.name, "/\\");
    while (names.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return false;
    }
    var paths = std.mem.tokenizeScalar(u8, module.path, '/');
    var depth: usize = 0;
    while (paths.next()) |component| {
        if (std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (depth == 0) return false;
            depth -= 1;
        } else {
            depth += 1;
        }
    }
    return true;
}

pub fn workspaceStore(a: A, bytes: []const u8) ![]const Worktree {
    var result: std.ArrayList(Worktree) = .empty;
    var reader: Proto = .{ .bytes = bytes };
    while (try reader.next()) |field| {
        if (field.number != 1) continue;
        const record = field.bytes orelse return error.InvalidWorkspaceStore;
        var workspace: Proto = .{ .bytes = record };
        var name: []const u8 = "";
        var path: []const u8 = "";
        while (try workspace.next()) |value| switch (value.number) {
            1 => {
                name = value.bytes orelse return error.InvalidWorkspaceStore;
                if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidWorkspaceStore;
            },
            2 => path = value.bytes orelse return error.InvalidWorkspaceStore,
            else => {},
        };
        if (!std.unicode.utf8ValidateSlice(path)) continue;
        try result.append(a, .{ .name = name, .path = path, .prunable = false });
    }
    return result.toOwnedSlice(a);
}

pub fn checkoutName(bytes: []const u8) ![]const u8 {
    var reader: Proto = .{ .bytes = bytes };
    var name: []const u8 = "";
    while (try reader.next()) |field| {
        if (field.number == 3) {
            name = field.bytes orelse return error.InvalidWorkspaceStore;
            if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidWorkspaceStore;
        }
    }
    return if (name.len == 0) "default" else name;
}

const Proto = struct {
    bytes: []const u8,
    position: usize = 0,
    const Field = struct { number: u32, bytes: ?[]const u8 };

    fn varint(self: *Proto) !u64 {
        var value: u64 = 0;
        var shift: u6 = 0;
        for (0..10) |index| {
            if (self.position == self.bytes.len) return error.InvalidWorkspaceStore;
            const byte = self.bytes[self.position];
            self.position += 1;
            if (index == 9 and byte > 1) return error.InvalidWorkspaceStore;
            value |= @as(u64, byte & 0x7f) << shift;
            if (byte & 0x80 == 0) return value;
            if (index != 9) shift += 7;
        }
        return error.InvalidWorkspaceStore;
    }

    fn take(self: *Proto, length: u64) ![]const u8 {
        if (length > self.bytes.len - self.position) return error.InvalidWorkspaceStore;
        const end = self.position + @as(usize, @intCast(length));
        defer self.position = end;
        return self.bytes[self.position..end];
    }

    fn next(self: *Proto) !?Field {
        if (self.position == self.bytes.len) return null;
        const tag = try self.varint();
        const number = tag >> 3;
        if (number == 0 or number > 0x1fffffff) return error.InvalidWorkspaceStore;
        var field: Field = .{ .number = @intCast(number), .bytes = null };
        switch (tag & 7) {
            0 => _ = try self.varint(),
            1 => _ = try self.take(8),
            2 => field.bytes = try self.take(try self.varint()),
            5 => _ = try self.take(4),
            else => return error.InvalidWorkspaceStore,
        }
        return field;
    }
};

test "git metadata pointers and administrative paths retain spaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/repo/.bare", try gitdir(a, "/repo", "gitdir: .bare\n"));
    try std.testing.expectEqualStrings("/space dir/meta", try gitdir(a, "/repo", "gitdir: /space dir/meta\r\n"));
    try std.testing.expectEqualStrings("/repo/topic", try worktreePath(a, "/repo/worktrees/id/gitdir", "../../topic/.git\n"));
    try std.testing.expectEqualStrings("/repo/worktrees/id/ leading", try worktreePath(a, "/repo/worktrees/id/gitdir", " leading/.git \t\n"));
    try std.testing.expectError(error.InvalidGitdir, gitdir(a, "/repo", "gitdir:\n"));
    try std.testing.expectError(error.InvalidGitdir, worktreePath(a, "/repo/gitdir", "\n"));
}

test "submodule config is nul delimited and names come from paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = try submoduleEntries(arena.allocator(), "submodule.custom-name.path\nvendor/child\x00submodule.other.path\nline\nbreak\x00");
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("custom-name", paths[0].name);
    try std.testing.expectEqualStrings("vendor/child", paths[0].path);
    try std.testing.expectEqualStrings("line\nbreak", paths[1].path);
    try std.testing.expectError(error.InvalidSubmodules, submoduleEntries(arena.allocator(), "submodule.path\nbad\x00"));
}

test "submodule config keeps the last path and rejects invalid names and escaped roots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entries = try submoduleEntries(arena.allocator(), "submodule.same.path\nold\x00" ++
        "submodule.invalid/../name.path\nsafe\x00" ++
        "submodule.absolute.path\n/elsewhere\x00" ++
        "submodule.outside.path\n../elsewhere\x00" ++
        "submodule.same.path\nnested/../final\x00");
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("nested/../final", entries[0].path);
}

test "workspace protobuf retains current and stale records and skips unknown fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const records = try workspaceStore(arena.allocator(), "\x0a\x0d\x0a\x07default\x12\x02/a\x0a\x0b\x0a\x05stale\x12\x02/b\x18\x01");
    try std.testing.expectEqual(@as(usize, 2), records.len);
    try std.testing.expectEqualStrings("default", records[0].name);
    try std.testing.expectEqualStrings("/b", records[1].path);
    try std.testing.expect(!records[1].prunable);
}

test "workspace protobuf rejects truncation overflow and invalid UTF-8" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "\x0a\x02\x0a", "\x00", "\x80", "\x0a\xff\xff\xff\xff\xff\xff\xff\xff\xff\x02", "\x08\x01" }) |invalid| {
        try std.testing.expectError(error.InvalidWorkspaceStore, workspaceStore(arena.allocator(), invalid));
    }
    try std.testing.expectEqual(@as(usize, 0), (try workspaceStore(arena.allocator(), "\x0a\x03\x12\x01\xff")).len);
    try std.testing.expectError(error.InvalidWorkspaceStore, workspaceStore(arena.allocator(), "\x0a\x03\x0a\x01\xff"));
}

test "checkout name preserves raw workspace names and old default fallback" {
    try std.testing.expectEqualStrings("with space", try checkoutName("\x12\x02op\x1a\x0awith space"));
    try std.testing.expectEqualStrings("default", try checkoutName(""));
    try std.testing.expectError(error.InvalidWorkspaceStore, checkoutName("\x1a\x01\xff"));
}
