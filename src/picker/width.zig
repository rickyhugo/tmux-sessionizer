// Translated from unicode-width 0.2.0, Unicode 15.1. See LICENSE-unicode-width.
// Grapheme rules derive from unicode-segmentation 1.12.0, Unicode 16.0.
const std = @import("std");
const data = @embedFile("width-data.bin");

const W = struct {
    const normal: u16 = 0;
    const modifier: u16 = 2;
    const regional: u16 = 3;
    const several_regional: u16 = 4;
    const emoji: u16 = 5;
    const zwj_emoji: u16 = 0x1006;
    const vs16_zwj_emoji: u16 = 0x9006;
    const keycap_zwj: u16 = 0x1007;
    const vs16_keycap_zwj: u16 = 0x9007;
    const regional_zwj: u16 = 9;
    const even_regional_zwj: u16 = 10;
    const odd_regional_zwj: u16 = 11;
    const tag_end: u16 = 0x10;
    const tag_d1: u16 = 0x11;
    const tag_d2: u16 = 0x12;
    const tag_d3: u16 = 0x13;
    const tag_a1: u16 = 0x19;
    const tag_a2: u16 = 0x1a;
    const tag_a3: u16 = 0x1b;
    const tag_a4: u16 = 0x1c;
    const tag_a5: u16 = 0x1d;
    const tag_a6: u16 = 0x1e;
    const alef: u16 = 0x30ff;
    const lamed_zwj: u16 = 0x3c00;
    const buginese_zwj: u16 = 0x3c01;
    const buginese_vowel_zwj: u16 = 0x3c02;
    const tifinagh: u16 = 0x3803;
    const tifinagh_zwj: u16 = 0x3c03;
    const tifinagh_joiner: u16 = 0x3c04;
    const lisu: u16 = 0x3c05;
    const turkic_zwj: u16 = 0x3c06;
    const khmer: u16 = 0x3c07;
};
const Record = struct { width: u8, info: u16, properties: u8, grapheme: u8 };
const Step = struct { add: i8, info: u16 };

fn lookup(scalar: u21) Record {
    var lo: usize = 0;
    var hi: usize = data.len / 13;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const bytes = data[mid * 13 ..][0..13];
        const start = std.mem.readInt(u32, bytes[0..4], .little);
        const end = std.mem.readInt(u32, bytes[4..8], .little);
        if (scalar < start) {
            hi = mid;
        } else if (scalar > end) {
            lo = mid + 1;
        } else return .{
            .width = bytes[8],
            .info = std.mem.readInt(u16, bytes[9..11], .little),
            .properties = bytes[11],
            .grapheme = bytes[12],
        };
    }
    unreachable;
}

pub fn single(scalar: u21) usize {
    if (scalar < 32 or (scalar >= 127 and scalar <= 159)) return 0;
    return lookup(scalar).width;
}

pub fn isUpper(scalar: u21) bool {
    return lookup(scalar).properties & 32 != 0;
}

const Category = enum(u4) {
    any,
    cr,
    control,
    extend,
    pictographic,
    consonant,
    l,
    lf,
    lv,
    lvt,
    prepend,
    regional,
    spacing,
    t,
    v,
    zwj,
};

pub fn clusterLen(text: []const u8) usize {
    var pos: usize = 0;
    var previous: Category = .control;
    var regional_count: usize = 0;
    var pictographic = false;
    var pictographic_zwj = false;
    var consonant = false;
    var linked = false;
    while (pos < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[pos]) catch break;
        if (text.len - pos < n) break;
        const scalar = std.unicode.utf8Decode(text[pos..][0..n]) catch break;
        const record = lookup(scalar);
        const next: Category = @fromBackingInt(@intCast(@as(u4, @truncate(record.grapheme))));
        if (pos != 0) {
            const boundary = if (previous == .cr and next == .lf)
                false
            else if (control(previous) or control(next))
                true
            else if (previous == .l and (next == .l or next == .v or next == .lv or next == .lvt))
                false
            else if ((previous == .lv or previous == .v) and (next == .v or next == .t))
                false
            else if ((previous == .lvt or previous == .t) and next == .t)
                false
            else if (next == .extend or next == .zwj or next == .spacing or previous == .prepend)
                false
            else if (next == .consonant and consonant and linked)
                false
            else if (previous == .zwj and next == .pictographic and pictographic_zwj)
                false
            else if (previous == .regional and next == .regional and regional_count % 2 == 1)
                false
            else
                true;
            if (boundary) break;
        }
        pictographic_zwj = next == .zwj and pictographic;
        if (next != .extend) pictographic = next == .pictographic;
        if (next == .consonant) {
            consonant = true;
            linked = false;
        } else if (record.grapheme & 32 != 0) {
            linked = consonant;
        } else if (record.grapheme & 16 == 0) {
            consonant = false;
            linked = false;
        }
        regional_count = if (next == .regional) regional_count + 1 else 0;
        previous = next;
        pos += n;
    }
    return pos;
}

fn control(category: Category) bool {
    return category == .control or category == .cr or category == .lf;
}

pub fn prefix(text: []const u8, scalar_cursor: usize) usize {
    var pos: usize = 0;
    var count: usize = 0;
    while (pos < text.len and count < scalar_cursor) : (count += 1) {
        pos += std.unicode.utf8ByteSequenceLength(text[pos]) catch 1;
    }
    return width(text[0..@min(pos, text.len)]);
}

pub const Clip = struct { bytes: usize = 0, cells: usize = 0 };

const contexts = blk: {
    const plain = [_]u16{
        0,    2,    3,      4,      5,      9,      10,     11,
        0x10, 0x11, 0x12,   0x13,   0x19,   0x1a,   0x1b,   0x1c,
        0x1d, 0x1e, 0x1006, 0x1007, 0x4000, 0x8000, 0x9006, 0x9007,
    };
    const families = [_]u16{
        0x30ff, 0x3800, 0x3801, 0x3803, 0x3806,
        0x3c00, 0x3c01, 0x3c02, 0x3c03, 0x3c04,
        0x3c05, 0x3c06, 0x3c07,
    };
    var values: [plain.len + families.len * 4]u16 = undefined;
    @memcpy(values[0..plain.len], &plain);
    for (0..4) |mask| {
        for (families, 0..) |base, i|
            values[plain.len + mask * families.len + i] = base | (@as(u16, @intCast(mask)) << 14);
    }
    break :blk values;
};

fn contextIndex(value: u16) usize {
    inline for (contexts, 0..) |context, i| {
        if (value == context) return i;
    }
    unreachable;
}

pub fn clip(text: []const u8, max: usize) Clip {
    return clipCount(text, max, null);
}

fn clipCount(text: []const u8, max: usize, work: ?*usize) Clip {
    if (max == 0) return .{};
    var result: Clip = .{};
    var costs: [contexts.len]isize = @splat(0);
    var pos: usize = 0;
    while (pos < text.len) {
        const end = pos + clusterLen(text[pos..]);
        if (end == pos) break;
        while (pos < end) {
            const n = std.unicode.utf8ByteSequenceLength(text[pos]) catch unreachable;
            const scalar = std.unicode.utf8Decode(text[pos..][0..n]) catch unreachable;
            pos += n;
            if (scalar < 32 or (scalar >= 127 and scalar <= 159)) continue;
            const record = lookup(scalar);
            var next: [contexts.len]isize = undefined;
            for (contexts, 0..) |context, i| {
                if (work) |count| count.* += 1;
                const value = stepWithRecord(scalar, context, record);
                // A reverse scan of P+c starts with c, then scans P in c's output context.
                next[i] = value.add + costs[contextIndex(value.info)];
            }
            costs = next;
        }
        const cells: usize = @intCast(@max(0, costs[contextIndex(W.normal)]));
        if (cells <= max) result = .{ .bytes = end, .cells = cells };
    }
    return result;
}

test "clipping work is bounded for nonconverging Tifinagh contexts" {
    var bounded = true;
    for ([_]usize{ 512, 1024 }) |pairs| {
        const pair = "\u{2d31}\u{2d7f}";
        const text = try std.testing.allocator.alloc(u8, pair.len * pairs);
        defer std.testing.allocator.free(text);
        for (0..pairs) |i| @memcpy(text[i * pair.len ..][0..pair.len], pair);
        var work: usize = 0;
        const actual = clipCount(text, 1, &work);
        try std.testing.expectEqual(Clip{}, actual);
        bounded = bounded and work <= pairs * 2 * 128;
    }
    try std.testing.expect(bounded);
}

test "prefix contexts are closed under table records and contextual transitions" {
    for (0..data.len / 13) |i| {
        const bytes = data[i * 13 ..][0..13];
        for ([_]u32{
            std.mem.readInt(u32, bytes[0..4], .little),
            std.mem.readInt(u32, bytes[4..8], .little),
        }) |scalar| try checkContexts(@intCast(scalar));
    }
    for ([_]u21{
        '#',     '*',     '0',     '9',     0xa0,    0x5d0,   0x644,   0x6b5,   0x6b8,   0x76a,
        0x8a6,   0x8c7,   0x17d2,  0x1a15,  0x1a17,  0x200d,  0x20e3,  0x2d31,  0x2d65,  0x2d6f,
        0x2d7f,  0xa4f8,  0xa4fb,  0xfe0e,  0xfe0f,  0x10c32, 0x1f1e6, 0x1f1ff, 0x1f3f4, 0x1f3fb,
        0x1f3ff, 0xe0030, 0xe0039, 0xe0061, 0xe007a, 0xe007f,
    }) |scalar| try checkContexts(scalar);
}

fn checkContexts(scalar: u21) !void {
    if (scalar < 32 or (scalar >= 127 and scalar <= 159)) return;
    for (contexts) |context| {
        const value = step(scalar, context);
        try std.testing.expect(std.mem.indexOfScalar(u16, &contexts, value.info) != null);
    }
}

pub fn width(text: []const u8) usize {
    var end = text.len;
    var sum: isize = 0;
    var next: u16 = W.normal;
    while (end > 0) {
        var start = end - 1;
        while (start > 0 and text[start] & 0xc0 == 0x80) start -= 1;
        const scalar = std.unicode.utf8Decode(text[start..end]) catch {
            end = start;
            continue;
        };
        end = start;
        if (scalar < 32 or (scalar >= 127 and scalar <= 159)) continue;
        const value = step(scalar, next);
        sum += value.add;
        next = value.info;
    }
    return @intCast(@max(0, sum));
}

fn step(c: u21, following: u16) Step {
    return stepWithRecord(c, following, lookup(c));
}

fn stepWithRecord(c: u21, following: u16, record: Record) Step {
    var next = following;
    if (next & 0x8000 != 0) {
        if (record.properties & 1 != 0) {
            return .{ .add = if (next & 0xb000 == 0x9000) 0 else 2, .info = W.emoji };
        }
        next = if (next & 0x2000 != 0) next & 0x7fff else W.normal;
    }
    if (c <= 0xa0) return .{ .add = 1, .info = W.normal };
    if (next != W.normal) {
        if (c == 0xfe0f) return .{
            .add = 0,
            .info = if (next & 0x2000 != 0 or next & 0x9000 == 0x1000) next | 0x8000 else 0x8000,
        };
        if (c == 0xfe0e) return .{ .add = 0, .info = if (next & 0x2000 != 0) next | 0x4000 else 0x4000 };
        if (next & 0x4000 != 0) {
            if (record.properties & 2 != 0) return .{ .add = 1, .info = W.normal };
            next &= 0xbfff;
        }
        if (next & 0x0800 != 0) {
            if (c == 0x200d) return .{ .add = 0, .info = next | 0x0400 };
            if (record.properties & 16 != 0) return .{ .add = 0, .info = next };
        }
        switch (next) {
            W.alef => {
                if (c == 0x644 or (c >= 0x6b5 and c <= 0x6b8) or c == 0x76a or c == 0x8a6 or c == 0x8c7)
                    return .{ .add = 0, .info = W.normal };
                if (record.properties & 8 != 0) return .{ .add = 0, .info = W.alef };
            },
            W.lamed_zwj => if (c == 0x5d0) {
                return .{ .add = 0, .info = W.normal };
            },
            W.khmer => if (c == 0x17d2) {
                return .{ .add = -1, .info = W.normal };
            },
            W.buginese_zwj => if (c == 0x1a17) {
                return .{ .add = 0, .info = W.buginese_vowel_zwj };
            },
            W.buginese_vowel_zwj => if (c == 0x1a15) {
                return .{ .add = 0, .info = W.normal };
            },
            W.tifinagh, W.tifinagh_zwj => {
                if (c == 0x2d7f) return .{ .add = 1, .info = W.tifinagh_joiner };
                if (next == W.tifinagh_zwj and tifinagh(c)) return .{ .add = 0, .info = W.normal };
            },
            W.tifinagh_joiner => if (tifinagh(c)) {
                return .{ .add = -1, .info = W.normal };
            },
            W.lisu => if (c >= 0xa4f8 and c <= 0xa4fb) {
                return .{ .add = 0, .info = W.normal };
            },
            W.turkic_zwj => if (c == 0x10c32) {
                return .{ .add = 0, .info = W.normal };
            },
            W.modifier => if (record.properties & 4 != 0) {
                return .{ .add = 0, .info = W.emoji };
            },
            else => {},
        }
        if ((next == W.regional or next == W.several_regional) and regional(c))
            return .{ .add = 1, .info = W.several_regional };
        if ((next == W.emoji or next == W.several_regional or next == W.even_regional_zwj or
            next == W.odd_regional_zwj or next == W.modifier) and c == 0x200d)
            return .{ .add = 0, .info = W.zwj_emoji };
        if (next == W.zwj_emoji) {
            if (c == 0x20e3) return .{ .add = 0, .info = W.keycap_zwj };
            if (regional(c)) return .{ .add = 1, .info = W.regional_zwj };
            if (c >= 0x1f3fb and c <= 0x1f3ff) return .{ .add = 0, .info = W.modifier };
            if (c == 0xe007f) return .{ .add = 0, .info = W.tag_end };
            if (record.info == W.emoji) return .{ .add = 0, .info = W.emoji };
        }
        if (next == W.vs16_zwj_emoji and record.properties & 1 != 0)
            return .{ .add = 0, .info = W.emoji };
        if (next == W.vs16_keycap_zwj and ((c >= '0' and c <= '9') or c == '#' or c == '*'))
            return .{ .add = 0, .info = W.emoji };
        if ((next == W.regional_zwj or next == W.odd_regional_zwj) and regional(c))
            return .{ .add = -1, .info = W.even_regional_zwj };
        if (next == W.even_regional_zwj and regional(c))
            return .{ .add = 3, .info = W.odd_regional_zwj };
        if (c >= 0xe0061 and c <= 0xe007a) {
            if (next == W.tag_end) return .{ .add = 0, .info = W.tag_a1 };
            if (next >= W.tag_a1 and next < W.tag_a6) return .{ .add = 0, .info = next + 1 };
        }
        if (c >= 0xe0030 and c <= 0xe0039) {
            if (next == W.tag_end or (next >= W.tag_a1 and next <= W.tag_a4))
                return .{ .add = 0, .info = W.tag_d1 };
            if (next == W.tag_d1 or next == W.tag_d2) return .{ .add = 0, .info = next + 1 };
        }
        if (c == 0x1f3f4 and ((next >= W.tag_a3 and next <= W.tag_a6) or next == W.tag_d3))
            return .{ .add = 0, .info = W.emoji };
    }
    return .{ .add = @intCast(record.width), .info = record.info };
}

fn regional(c: u21) bool {
    return c >= 0x1f1e6 and c <= 0x1f1ff;
}

fn tifinagh(c: u21) bool {
    return (c >= 0x2d31 and c <= 0x2d65) or c == 0x2d6f;
}

test "display width is locale independent and handles combining and emoji sequences" {
    try std.testing.expectEqual(@as(usize, 2), width("界"));
    try std.testing.expectEqual(@as(usize, 1), width("e\u{301}"));
    try std.testing.expectEqual(@as(usize, 2), width("👩‍👩‍👧‍👦"));
    try std.testing.expectEqual(@as(usize, 2), width("👍🏽"));
    try std.testing.expectEqual(@as(usize, 2), width("❤️"));
    try std.testing.expectEqual(@as(usize, 1), width("❤"));
    try std.testing.expectEqual(@as(usize, 1), width("لا"));
    try std.testing.expectEqual(@as(usize, 0), single(0x94d));
}

test "clipping keeps complete extended grapheme clusters" {
    for ([_][]const u8{ "e\u{301}", "👩‍👩‍👧‍👦", "👍🏽", "❤️", "🇸🇪" }) |cluster| {
        try std.testing.expectEqual(cluster.len, clusterLen(cluster));
    }
    try std.testing.expectEqual("e\u{301}".len, clusterLen("e\u{301}x"));
}

test "clipping uses contextual widths across grapheme boundaries" {
    for ([_][]const u8{ "لا", "\u{a4f8}\u{a4fc}", "\u{5d0}\u{200d}\u{5dc}", "\u{2d31}\u{2d7f}\u{2d31}" }) |text| {
        const with_suffix = try std.mem.concat(std.testing.allocator, u8, &.{ text, "xy" });
        defer std.testing.allocator.free(with_suffix);
        for (0..5) |max| {
            const actual = clip(with_suffix, max);
            var expected: Clip = .{};
            var end: usize = 0;
            while (end < with_suffix.len and max > 0) {
                end += clusterLen(with_suffix[end..]);
                const cells = width(with_suffix[0..end]);
                if (cells <= max) expected = .{ .bytes = end, .cells = cells };
            }
            try std.testing.expectEqualDeep(expected, actual);
        }
    }
}

test "incremental clipping matches complete-prefix widths for mixed Unicode" {
    const parts = [_][]const u8{
        "a",
        "e\u{301}",
        "界",
        "🙂",
        "👩‍👩‍👧‍👦",
        "👍🏽",
        "❤️",
        "❤",
        "\u{fe0e}",
        "\u{fe0f}",
        "🇸🇪",
        "1️⃣",
        "\u{e007f}",
        "\u{e0061}",
        "\u{e0031}",
        "لا",
        "א‍ל",
        "ᨕᨗ‍ᨐ",
        "ⵏ⵿ⴾ",
        "ⵏ‍ⴾ",
        "ꓹꓼ",
        "𐰲‍𐰃",
        "हिन्दी",
        "\u{200d}",
        "\u{17d2}",
    };
    var random = std.Random.DefaultPrng.init(171);
    const rng = random.random();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    for (0..500) |_| {
        text.clearRetainingCapacity();
        for (0..rng.intRangeAtMost(usize, 1, 9)) |_| {
            try text.appendSlice(std.testing.allocator, parts[rng.uintLessThan(usize, parts.len)]);
        }
        for (0..7) |max| {
            var expected: Clip = .{};
            var end: usize = 0;
            while (end < text.items.len and max > 0) {
                end += clusterLen(text.items[end..]);
                const cells = width(text.items[0..end]);
                if (cells <= max) expected = .{ .bytes = end, .cells = cells };
            }
            try std.testing.expectEqualDeep(expected, clip(text.items, max));
        }
    }
}
