// Translated from nucleo-matcher 0.3.1. SPDX-License-Identifier: MPL-2.0
// See vendor/licenses/matcher/ for upstream licenses and provenance.

const std = @import("std");
const unicode = @import("unicode.zig");

pub const Kind = enum { fuzzy, substring, prefix, postfix, exact };
pub const Atom = struct {
    needle: unicode.Text,
    kind: Kind,
    negative: bool,
    ignore_case: bool,
    normalize: bool,
};

fn atom(allocator: std.mem.Allocator, raw: []const u8) !Atom {
    var bytes = raw;
    var negative = false;
    if (std.mem.startsWith(u8, bytes, "!")) {
        negative = true;
        bytes = bytes[1..];
    } else if (std.mem.startsWith(u8, bytes, "\\!")) bytes = bytes[1..];
    var kind: Kind = .fuzzy;
    if (std.mem.startsWith(u8, bytes, "^")) {
        kind = .prefix;
        bytes = bytes[1..];
    } else if (std.mem.startsWith(u8, bytes, "'")) {
        kind = .substring;
        bytes = bytes[1..];
    } else if (std.mem.startsWith(u8, bytes, "\\^") or std.mem.startsWith(u8, bytes, "\\'")) {
        bytes = bytes[1..];
    }
    var append_dollar = false;
    if (std.mem.endsWith(u8, bytes, "\\$")) {
        bytes = bytes[0 .. bytes.len - 2];
        append_dollar = true;
    } else if (std.mem.endsWith(u8, bytes, "$")) {
        kind = if (kind == .fuzzy) .postfix else .exact;
        bytes = bytes[0 .. bytes.len - 1];
    }
    if (negative and kind == .fuzzy) kind = .substring;

    var decoded: std.ArrayList(u21) = .empty;
    const text = try unicode.decode(allocator, bytes, &decoded);
    var needle: std.ArrayList(u21) = .empty;
    var ignore_case = true;
    var normalize = true;
    var i: usize = 0;
    var saw_backslash = false;
    while (i < text.chars.len) : (i += 1) {
        const cp = text.chars[i];
        if (text.ascii) {
            if (cp == '\\' and i + 1 < text.chars.len and text.chars[i + 1] == ' ') continue;
        } else {
            // The upstream Unicode escape loop retains a backslash before non-space.
            if (saw_backslash) {
                if (cp == ' ') {
                    try needle.append(allocator, ' ');
                    saw_backslash = false;
                    continue;
                }
                try needle.append(allocator, '\\');
            }
            saw_backslash = cp == '\\';
        }
        ignore_case = ignore_case and !unicode.isUpper(cp);
        normalize = normalize and unicode.normalize(cp) == cp;
        try needle.append(allocator, cp);
    }
    if (append_dollar) try needle.append(allocator, '$');
    return .{
        .needle = .{ .chars = needle.items, .ascii = text.ascii },
        .kind = kind,
        .negative = negative,
        .ignore_case = ignore_case,
        .normalize = normalize,
    };
}

pub fn parse(arena: *std.heap.ArenaAllocator, query: []const u8) ![]const Atom {
    const allocator = arena.allocator();
    var atoms: std.ArrayList(Atom) = .empty;
    var start: usize = 0;
    var saw_backslash = false;
    for (query, 0..) |byte, i| {
        if (byte == ' ' and !saw_backslash) {
            const parsed = try atom(allocator, query[start..i]);
            if (parsed.needle.chars.len != 0) try atoms.append(allocator, parsed);
            start = i + 1;
        } else saw_backslash = byte == '\\';
    }
    const parsed = try atom(allocator, query[start..]);
    if (parsed.needle.chars.len != 0) try atoms.append(allocator, parsed);
    return atoms.items;
}
