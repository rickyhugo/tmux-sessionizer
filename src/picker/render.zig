const std = @import("std");
const config = @import("config");
const picker = @import("../picker.zig");
const widths = @import("width.zig");
const A = std.mem.Allocator;

const Rect = struct { x: usize = 0, y: usize = 0, width: usize, height: usize };

pub fn draw(a: A, state: picker.State, items: []const picker.Item, options: config.PickerOptions, preview: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "\x1b[?25l\x1b[0m\x1b[2J");
    const width: usize = state.size.width;
    const height: usize = state.size.height;
    if (width == 0 or height == 0) return out.toOwnedSlice(a);
    var list: Rect = .{ .width = width, .height = height };
    var pane: ?Rect = null;
    var vertical = false;
    var position = options.input_position;
    for (items) |item| {
        if (item.preview != .none) {
            if ((width + 1) / 2 >= height) {
                list.width = (width + 1) / 2;
                pane = .{ .x = list.width, .width = width - list.width, .height = height };
            } else {
                vertical = true;
                const preview_height = (height + 1) / 2;
                pane = .{ .width = width, .height = preview_height };
                list.y = preview_height;
                list.height = height - preview_height;
                position = .bottom;
            }
            break;
        }
    }
    if (list.height > 0 and list.width > 0) {
        const top = position == .top;
        const prompt_y = list.y + if (top) @as(usize, 0) else list.height - 1;
        if (list.height >= 2) {
            const border_y = list.y + if (top) @as(usize, 1) else list.height - 2;
            try move(a, &out, list.x, border_y);
            try color(a, &out, options.colors.border_color orelse .dark_gray, false);
            try repeated(a, &out, "─", list.width);
            try move(a, &out, list.x, border_y);
            try color(a, &out, options.colors.info_color orelse .light_yellow, false);
            const info = try std.fmt.allocPrint(a, "{d}/{d}", .{ state.ranked.len, items.len });
            defer a.free(info);
            try text(a, &out, info, list.width, false);
        }
        const rows = list.height -| 2;
        var scroll = state.scroll;
        if (state.selection) |selected| {
            scroll = @min(scroll, selected);
            if (rows > 0 and selected - scroll >= rows) scroll = selected - rows + 1;
        }
        for (0..rows) |row| {
            const rank = scroll + row;
            if (rank >= state.ranked.len) break;
            const item = items[state.ranked[rank]];
            const selected = state.selection != null and state.selection.? == rank;
            const y = list.y + if (top) row + 2 else list.height - 3 - row;
            try move(a, &out, list.x, y);
            try out.appendSlice(a, "\x1b[0m");
            if (selected) {
                try color(a, &out, options.colors.highlight_color orelse .light_blue, true);
                try color(a, &out, options.colors.highlight_text_color orelse .black, false);
            }
            if (selected or item.active) try out.appendSlice(a, "\x1b[1m");
            const marker = if (selected) "> " else "  ";
            try out.appendSlice(a, marker[0..@min(list.width, 2)]);
            const available = list.width -| 2;
            const used = try clippedText(a, &out, item.label, available, false);
            if (selected) try repeated(a, &out, " ", available - used);
            try out.appendSlice(a, "\x1b[0m");
        }
        try move(a, &out, list.x, prompt_y);
        try out.appendSlice(a, "\x1b[0m");
        try color(a, &out, options.colors.prompt_color orelse .light_green, false);
        try out.appendSlice(a, "> "[0..@min(2, list.width)]);
        try out.appendSlice(a, "\x1b[0m");
        try text(a, &out, state.query.items, list.width -| 2, false);
    }
    if (pane) |area| {
        if (area.width > 0 and area.height > 0) {
            try out.appendSlice(a, "\x1b[0m");
            try color(a, &out, options.colors.border_color orelse .dark_gray, false);
            if (vertical) {
                try move(a, &out, area.x, area.y + area.height - 1);
                try repeated(a, &out, "─", area.width);
            } else for (0..area.height) |row| {
                try move(a, &out, area.x, area.y + row);
                try out.appendSlice(a, "│");
            }
            try out.appendSlice(a, "\x1b[0m");
            const preview_width = area.width -| @intFromBool(!vertical);
            const preview_height = area.height -| @intFromBool(vertical);
            var lines = std.mem.splitScalar(u8, preview, '\n');
            var row: usize = 0;
            while (row < preview_height) : (row += 1) {
                const line = lines.next() orelse break;
                try move(a, &out, area.x + @intFromBool(!vertical), area.y + row);
                try text(a, &out, line, preview_width, true);
            }
        }
    }
    try out.appendSlice(a, "\x1b[0m");
    if (list.width > 0 and list.height > 0) {
        const prompt_y = list.y + if (position == .top) @as(usize, 0) else list.height - 1;
        const cursor_x = @min(list.width - 1, widths.prefix(state.query.items, state.scalar_cursor) + 2);
        try move(a, &out, list.x + cursor_x, prompt_y);
        try out.appendSlice(a, "\x1b[?25h");
    }
    return out.toOwnedSlice(a);
}

fn move(a: A, out: *std.ArrayList(u8), x: usize, y: usize) !void {
    var buf: [64]u8 = undefined;
    try out.appendSlice(a, try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ y + 1, x + 1 }));
}

fn repeated(a: A, out: *std.ArrayList(u8), glyph: []const u8, count: usize) !void {
    for (0..count) |_| try out.appendSlice(a, glyph);
}

fn color(a: A, out: *std.ArrayList(u8), value: config.Color, background: bool) !void {
    const base: u16 = if (background) 40 else 30;
    var buf: [64]u8 = undefined;
    const code: u16 = switch (value) {
        .reset => base + 9,
        .black => base,
        .red => base + 1,
        .green => base + 2,
        .yellow => base + 3,
        .blue => base + 4,
        .magenta => base + 5,
        .cyan => base + 6,
        .gray => base + 7,
        .dark_gray => base + 60,
        .light_red => base + 61,
        .light_green => base + 62,
        .light_yellow => base + 63,
        .light_blue => base + 64,
        .light_magenta => base + 65,
        .light_cyan => base + 66,
        .white => base + 67,
        .indexed => |index| {
            try out.appendSlice(a, try std.fmt.bufPrint(&buf, "\x1b[{d};5;{d}m", .{ base + 8, index }));
            return;
        },
        .rgb => |rgb| {
            try out.appendSlice(a, try std.fmt.bufPrint(&buf, "\x1b[{d};2;{d};{d};{d}m", .{ base + 8, rgb.r, rgb.g, rgb.b }));
            return;
        },
    };
    try out.appendSlice(a, try std.fmt.bufPrint(&buf, "\x1b[{d}m", .{code}));
}

fn text(a: A, out: *std.ArrayList(u8), source: []const u8, max: usize, sgr: bool) !void {
    _ = try clippedText(a, out, source, max, sgr);
}

fn clippedText(a: A, out: *std.ArrayList(u8), source: []const u8, max: usize, sgr: bool) !usize {
    const start_out = out.items.len;
    var visible: std.ArrayList(u8) = .empty;
    defer visible.deinit(a);
    var i: usize = 0;
    while (i < source.len) {
        if (source[i] == 0x1b) {
            const start = i;
            i += 1;
            if (i == source.len) break;
            if (source[i] == '[') {
                i += 1;
                var safe = true;
                while (i < source.len and !(source[i] >= 0x40 and source[i] <= 0x7e)) : (i += 1) {
                    safe = safe and (std.ascii.isDigit(source[i]) or source[i] == ';');
                }
                if (i == source.len) break;
                if (sgr and safe and source[i] == 'm' and i - start <= 64) {
                    try out.appendSlice(a, source[start .. i + 1]);
                }
                i += 1;
            } else if (source[i] == ']' or source[i] == 'P' or source[i] == '_' or source[i] == '^' or source[i] == 'X') {
                i += 1;
                while (i < source.len) : (i += 1) {
                    if (source[i] == 7) {
                        i += 1;
                        break;
                    }
                    if (source[i] == 0x1b and i + 1 < source.len and source[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                }
            } else {
                while (i < source.len and source[i] >= 0x20 and source[i] <= 0x2f) : (i += 1) {}
                if (i < source.len) i += 1;
            }
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(source[i]) catch {
            i += 1;
            continue;
        };
        if (source.len - i < n) break;
        const scalar = std.unicode.utf8Decode(source[i..][0..n]) catch {
            i += 1;
            continue;
        };
        if (scalar < 32 or (scalar >= 127 and scalar <= 159)) {
            i += n;
            continue;
        }
        const length = widths.clusterLen(source[i..]);
        const bytes = source[i..][0..length];
        i += length;
        try out.appendSlice(a, bytes);
        try visible.appendSlice(a, bytes);
    }
    const clipped = widths.clip(visible.items, max);
    var read_pos = start_out;
    var write_pos = start_out;
    var text_pos: usize = 0;
    while (read_pos < out.items.len) {
        const start = read_pos;
        if (out.items[read_pos] == 0x1b) {
            while (out.items[read_pos] != 'm') : (read_pos += 1) {}
            read_pos += 1;
        } else {
            read_pos += 1;
            text_pos += 1;
            if (text_pos > clipped.bytes) continue;
        }
        const bytes = out.items[start..read_pos];
        std.mem.copyForwards(u8, out.items[write_pos..][0..bytes.len], bytes);
        write_pos += bytes.len;
    }
    out.items.len = write_pos;
    return clipped.cells;
}

test "labels cannot emit controls, preview only passes bounded numeric SGR" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try text(a, &out, "a\x1b[2Jb\x1b]52;c;secret\x07c\x1b[31md\n", 100, false);
    try std.testing.expectEqualStrings("abcd", out.items);
    out.clearRetainingCapacity();
    try text(a, &out, "\x1b[31mred\x1b[0m\x1b[9;9H\x1b]0;title\x1b\\!", 100, true);
    try std.testing.expectEqualStrings("\x1b[31mred\x1b[0m!", out.items);
}

test "wide and combining labels fit the row" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try text(a, &out, "界a\u{301}b", 3, false);
    try std.testing.expectEqualStrings("界a\u{301}", out.items);
    out.clearRetainingCapacity();
    try text(a, &out, "👩‍👩‍👧‍👦x", 2, false);
    try std.testing.expectEqualStrings("👩‍👩‍👧‍👦", out.items);
    out.clearRetainingCapacity();
    try text(a, &out, "❤️x", 1, false);
    try std.testing.expectEqualStrings("", out.items);
}

test "clipping and cursor widths share whole-prefix accounting" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    for ([_][]const u8{ "لاx", "\u{a4f8}\u{a4fc}x", "\u{5d0}\u{200d}\u{5dc}x" }) |text_value| {
        out.clearRetainingCapacity();
        const cells = try clippedText(a, &out, text_value, 2, false);
        try std.testing.expectEqualStrings(text_value, out.items);
        try std.testing.expectEqual(widths.prefix(text_value, 100), cells);
    }
    out.clearRetainingCapacity();
    try text(a, &out, "\x1b[31mلاx\x1b[0m", 1, true);
    try std.testing.expectEqualStrings("\x1b[31mلا\x1b[0m", out.items);
}
