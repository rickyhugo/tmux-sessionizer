// Translated from nucleo-matcher 0.3.1. SPDX-License-Identifier: MPL-2.0
// See vendor/licenses/matcher/ for upstream licenses and provenance.

const std = @import("std");
const unicode = @import("unicode.zig");
const pattern = @import("pattern.zig");
const Text = unicode.Text;
const Class = unicode.Class;
const Atom = pattern.Atom;

const Cell = struct {
    score: u16 = 0,
    consecutive: u16 = 0,
};

pub const Workspace = struct {
    normalized: std.ArrayList(u21) = .empty,
    bonuses: std.ArrayList(u16) = .empty,
    offsets: std.ArrayList(usize) = .empty,
    row: std.ArrayList(Cell) = .empty,

    pub fn deinit(self: *Workspace, allocator: std.mem.Allocator) void {
        self.normalized.deinit(allocator);
        self.bonuses.deinit(allocator);
        self.offsets.deinit(allocator);
        self.row.deinit(allocator);
    }
};

fn bonus(previous: Class, current: Class) u16 {
    if (@backingInt(current) > @backingInt(Class.delimiter)) {
        switch (previous) {
            .whitespace => return 10,
            .delimiter => return 9,
            .non_word => return 8,
            else => {},
        }
    }
    if ((previous == .lower and current == .upper) or
        (previous != .number and current == .number)) return 5;
    if (current == .whitespace) return 10;
    if (current == .non_word) return 8;
    return 0;
}

fn normalized(cp: u21, atom: Atom) u21 {
    var result = cp;
    if (atom.normalize) result = unicode.normalize(result);
    if (atom.ignore_case) result = unicode.lower(result);
    return result;
}

fn classNormalized(cp: u21, atom: Atom) u21 {
    if (cp < 128) return if (atom.ignore_case) unicode.lower(cp) else cp;
    const fold = unicode.class(cp) == .upper or atom.normalize;
    var result = if (atom.normalize) unicode.normalize(cp) else cp;
    if (fold and atom.ignore_case) result = unicode.lower(result);
    return result;
}

fn previousClass(haystack: Text, start: usize) Class {
    return if (start == 0) .whitespace else unicode.class(haystack.chars[start - 1]);
}

fn calculate(haystack: Text, atom: Atom, start: usize, end: usize) u16 {
    const needle = atom.needle.chars;
    var previous = unicode.class(haystack.chars[start]);
    var first_bonus = bonus(previousClass(haystack, start), previous);
    var result: u16 = 16 + 2 * first_bonus;
    var needle_index: usize = @intFromBool(needle.len > 1);
    var in_gap = false;
    var consecutive = true;
    for (haystack.chars[start + 1 .. end]) |cp| {
        const current = unicode.class(cp);
        if (classNormalized(cp, atom) == needle[needle_index]) {
            var current_bonus = bonus(previous, current);
            if (consecutive) {
                if (current_bonus >= 8 and current_bonus > first_bonus) first_bonus = current_bonus;
                current_bonus = @max(@max(current_bonus, first_bonus), 4);
            } else first_bonus = current_bonus;
            result +%= 16 + current_bonus;
            in_gap = false;
            consecutive = true;
            if (needle_index + 1 < needle.len) needle_index += 1;
        } else {
            result -|= if (in_gap) @as(u16, 1) else 3;
            in_gap = true;
            consecutive = false;
        }
        previous = current;
    }
    return result;
}

fn exact(haystack: Text, atom: Atom, start: usize, end: usize) ?u16 {
    const needle = atom.needle;
    if (end - start != needle.chars.len) return null;
    if (haystack.ascii and !needle.ascii) return null;
    if (haystack.ascii and needle.ascii and !atom.ignore_case) {
        // Upstream compares the whole ASCII haystack in this branch, not its slice.
        if (!std.mem.eql(u21, haystack.chars, needle.chars)) return null;
    } else {
        for (haystack.chars[start..end], needle.chars) |cp, expected| {
            if (normalized(cp, atom) != normalized(expected, atom)) return null;
        }
    }
    return calculate(haystack, atom, start, end);
}

fn leading(haystack: Text) usize {
    for (haystack.chars, 0..) |cp, i| {
        if (!(if (haystack.ascii) unicode.asciiWhitespace(cp) else unicode.whitespace(cp))) return i;
    }
    return 0;
}

fn trailing(haystack: Text) usize {
    var i = haystack.chars.len;
    while (i > 0) {
        i -= 1;
        const cp = haystack.chars[i];
        if (!(if (haystack.ascii) unicode.asciiWhitespace(cp) else unicode.whitespace(cp)))
            return haystack.chars.len - i - 1;
    }
    return 0;
}

fn anchored(haystack: Text, atom: Atom) ?u16 {
    const needle = atom.needle.chars;
    const start = if (atom.kind != .postfix and !unicode.whitespace(needle[0])) leading(haystack) else 0;
    const trim = if (atom.kind != .prefix and !unicode.whitespace(needle[needle.len - 1])) trailing(haystack) else 0;
    if (haystack.chars.len - start < needle.len or haystack.chars.len - trim < needle.len) return null;
    return switch (atom.kind) {
        .prefix => exact(haystack, atom, start, start + needle.len),
        .postfix => exact(haystack, atom, haystack.chars.len - trim - needle.len, haystack.chars.len - trim),
        .exact => if (start > haystack.chars.len - trim) null else exact(haystack, atom, start, haystack.chars.len - trim),
        else => unreachable,
    };
}

const Bounds = struct { start: usize, greedy_end: usize, end: usize };

fn prefilter(haystack: Text, atom: Atom) ?Bounds {
    const hay = haystack.chars;
    const needle = atom.needle.chars;
    var start: usize = 0;
    while (start < hay.len - needle.len + 1) : (start += 1) {
        if (normalized(hay[start], atom) == needle[0]) break;
    } else return null;
    if (haystack.ascii) {
        var greedy_end = start + 1;
        for (needle[1..]) |expected| {
            while (greedy_end < hay.len and normalized(hay[greedy_end], atom) != expected) : (greedy_end += 1) {}
            if (greedy_end == hay.len) return null;
            greedy_end += 1;
        }
        var end = hay.len;
        while (end > greedy_end and normalized(hay[end - 1], atom) != needle[needle.len - 1]) : (end -= 1) {}
        return .{ .start = start, .greedy_end = greedy_end, .end = end };
    }
    var end = hay.len;
    while (end > start + 1 and normalized(hay[end - 1], atom) != needle[needle.len - 1]) : (end -= 1) {}
    if (end == start + 1 or end - start < needle.len) return null;
    return .{ .start = start, .greedy_end = start + 1, .end = end };
}

fn single(haystack: Text, atom: Atom) ?u16 {
    var start: usize = 0;
    while (start < haystack.chars.len and normalized(haystack.chars[start], atom) != atom.needle.chars[0]) : (start += 1) {}
    if (start == haystack.chars.len) return null;
    var previous = previousClass(haystack, start);
    var best: u16 = 0;
    for (haystack.chars[start..], start..) |cp, i| {
        if (classNormalized(cp, atom) != atom.needle.chars[0]) continue;
        const current = unicode.class(cp);
        if (haystack.ascii) previous = previousClass(haystack, i);
        const current_bonus = bonus(previous, current);
        previous = current;
        best = @max(best, 16 + 2 * current_bonus);
        if (current_bonus >= 10) break;
    }
    return best;
}

fn substring(haystack: Text, atom: Atom) ?u16 {
    const hay = haystack.chars;
    const needle = atom.needle.chars;
    if (needle.len > hay.len) return null;
    if (needle.len == hay.len) return exact(haystack, atom, 0, hay.len);
    if (haystack.ascii and !atom.needle.ascii) return null;
    if (needle.len == 1) return single(haystack, atom);
    var start: usize = 0;
    if (!haystack.ascii) start = (prefilter(haystack, atom) orelse return null).start;
    var previous = previousClass(haystack, start);
    var best: u16 = 0;
    var position: usize = 0;
    var i = start;
    var first_letter: ?usize = null;
    if (haystack.ascii and atom.ignore_case) {
        for (needle, 0..) |cp, j| {
            if (cp >= 'a' and cp <= 'z') {
                first_letter = j;
                break;
            }
        }
    }
    const memmem = haystack.ascii and (!atom.ignore_case or first_letter == null or first_letter.? >= 2);
    // The Unicode implementation excludes the last possible substring start.
    const limit = hay.len - needle.len + @as(usize, @intFromBool(haystack.ascii));
    while (i < limit) {
        const cp = hay[i];
        const current = unicode.class(cp);
        if (!haystack.ascii and classNormalized(cp, atom) != needle[0]) {
            i += 1;
            continue;
        }
        if (haystack.ascii) previous = previousClass(haystack, i);
        const current_bonus = bonus(previous, current);
        previous = current;
        var matched = true;
        if (memmem) {
            // memmem's iterator is non-overlapping, including its truncated prefilter.
            if (atom.ignore_case and first_letter != null and
                i + needle.len > hay.len - needle.len + first_letter.?)
            {
                matched = false;
            } else matched = std.mem.eql(u21, hay[i .. i + needle.len], needle);
        } else {
            for (hay[i .. i + needle.len], needle) |actual, expected| {
                if (normalized(actual, atom) != expected) {
                    matched = false;
                    break;
                }
            }
        }
        if (matched and 16 + 2 * current_bonus > best) {
            best = 16 + 2 * current_bonus;
            position = i;
            if (current_bonus >= 10) break;
        }
        i += if (memmem and matched) needle.len else 1;
    }
    if (best == 0) return null;
    return calculate(haystack, atom, position, position + needle.len);
}

fn greedy(haystack: Text, atom: Atom, bounds: Bounds) ?u16 {
    const hay = haystack.chars;
    const needle = atom.needle.chars;
    var end = bounds.greedy_end;
    if (!haystack.ascii) {
        var cursor = end;
        for (needle[1..]) |expected| {
            while (cursor < hay.len and normalized(hay[cursor], atom) != expected) : (cursor += 1) {}
            if (cursor == hay.len) return null;
            cursor += 1;
        }
        end = cursor;
    }
    var cursor = end;
    var index = needle.len;
    while (cursor > bounds.start) {
        cursor -= 1;
        if (normalized(hay[cursor], atom) == needle[index - 1]) {
            index -= 1;
            if (index == 0) return calculate(haystack, atom, cursor, end);
        }
    }
    unreachable;
}

fn nextCell(p_score: u16, current_bonus: u16, cell: Cell) Cell {
    if (cell.score == 0 and cell.consecutive == 0)
        return .{ .score = p_score + current_bonus + 16, .consecutive = current_bonus };
    var consecutive = @max(cell.consecutive, 4);
    if (current_bonus >= 8 and current_bonus > consecutive) consecutive = current_bonus;
    const matched = cell.score + @max(consecutive, current_bonus);
    const skipped = p_score + current_bonus;
    return if (matched > skipped)
        .{ .score = matched + 16, .consecutive = consecutive }
    else
        .{ .score = skipped + 16, .consecutive = current_bonus };
}

fn scoreRow(
    hay: []const u21,
    bonuses: []const u16,
    row: []Cell,
    row_offset: usize,
    next_offset: usize,
    needle_index: usize,
    cp: u21,
    next_cp: u21,
) void {
    const first = needle_index == 0;
    var previous_p: u16 = 0;
    var previous_m: u16 = 0;
    var j = row_offset;
    while (j + 1 < next_offset) : (j += 1) {
        const p = @max(previous_m -| 3, previous_p -| 1);
        const cell: Cell = if (first)
            (if (hay[j] == cp) .{ .score = 16 + 2 * bonuses[j], .consecutive = bonuses[j] } else .{})
        else
            row[j - needle_index];
        previous_p = p;
        previous_m = cell.score;
    }
    j = next_offset - 1;
    while (j + 1 < hay.len and j - needle_index < row.len) : (j += 1) {
        const p = @max(previous_m -| 3, previous_p -| 1);
        const cell: Cell = if (first)
            (if (hay[j] == cp) .{ .score = 16 + 2 * bonuses[j], .consecutive = bonuses[j] } else .{})
        else
            row[j - needle_index];
        row[j - needle_index] = if (hay[j + 1] == next_cp) nextCell(p, bonuses[j + 1], cell) else .{};
        previous_p = p;
        previous_m = cell.score;
    }
}

fn optimal(allocator: std.mem.Allocator, workspace: *Workspace, haystack: Text, atom: Atom, bounds: Bounds) !?u16 {
    const length = bounds.end - bounds.start;
    const needle = atom.needle.chars;
    const width = length + 1 - needle.len;
    // Match MatrixLayout and the 133120-byte upstream slab, including alignment.
    var bytes = length * @as(usize, if (haystack.ascii) 1 else 4) + length;
    bytes = std.mem.alignForward(usize, bytes, 2) + 2 * needle.len;
    bytes = std.mem.alignForward(usize, bytes, 8) + 8 * width + width * needle.len;
    if (length > 65535 or needle.len > 2048 or length * needle.len > 100 * 1024 or bytes > 133120)
        return greedy(haystack, atom, bounds);

    try workspace.normalized.resize(allocator, length);
    try workspace.bonuses.resize(allocator, length);
    try workspace.offsets.resize(allocator, needle.len);
    try workspace.row.resize(allocator, width);
    const hay = workspace.normalized.items;
    const bonuses = workspace.bonuses.items;
    const offsets = workspace.offsets.items;
    const row = workspace.row.items;
    @memset(row, .{});
    var previous = previousClass(haystack, bounds.start);
    var index: usize = 0;
    for (haystack.chars[bounds.start..bounds.end], 0..) |cp, i| {
        const current = unicode.class(cp);
        hay[i] = classNormalized(cp, atom);
        bonuses[i] = bonus(previous, current);
        previous = current;
        if (index < needle.len and hay[i] == needle[index]) {
            offsets[index] = i;
            index += 1;
        }
    }
    if (index != needle.len) return null;
    for (0..needle.len - 1) |i|
        scoreRow(hay, bonuses, row, offsets[i], offsets[i + 1], i, needle[i], needle[i + 1]);
    var best: u16 = 0;
    for (row[offsets[needle.len - 1] + 1 - needle.len ..]) |cell| best = @max(best, cell.score);
    return best;
}

pub fn score(allocator: std.mem.Allocator, workspace: *Workspace, haystack: Text, atom: Atom) !?u16 {
    const needle = atom.needle.chars;
    if (needle.len > haystack.chars.len) return null;
    if (atom.kind == .prefix or atom.kind == .postfix or atom.kind == .exact) return anchored(haystack, atom);
    if (atom.kind == .substring) return substring(haystack, atom);
    if (needle.len == haystack.chars.len) return exact(haystack, atom, 0, haystack.chars.len);
    if (haystack.ascii and !atom.needle.ascii) return null;
    if (needle.len == 1) return single(haystack, atom);
    const bounds = prefilter(haystack, atom) orelse return null;
    if (bounds.end - bounds.start == needle.len) {
        if (haystack.ascii) return calculate(haystack, atom, bounds.start, bounds.greedy_end);
        return exact(haystack, atom, bounds.start, bounds.end);
    }
    return optimal(allocator, workspace, haystack, atom, bounds);
}

test "default general-text scores match upstream score vectors" {
    const cases = [_]struct { haystack: []const u8, query: []const u8, expected: u16 }{
        .{ .haystack = "fooBarbaz1", .query = "obr", .expected = 50 },
        .{ .haystack = "/usr/share/doc/at/ChangeLog", .query = "changelog", .expected = 234 },
        .{ .haystack = "fooBarbaz1", .query = "br", .expected = 39 },
        .{ .haystack = "foo bar baz", .query = "fbb", .expected = 78 },
        .{ .haystack = "/AutomatorDocument.icns", .query = "rdoc", .expected = 77 },
        .{ .haystack = "/man1/zshcompctl.1", .query = "zshc", .expected = 109 },
        .{ .haystack = "/.oh-my-zsh/cache", .query = "zshc", .expected = 102 },
        .{ .haystack = "ab0123 456", .query = "12356", .expected = 88 },
        .{ .haystack = "abc123 456", .query = "12356", .expected = 100 },
        .{ .haystack = "foo/bar/baz", .query = "fbb", .expected = 76 },
        .{ .haystack = "fooBarBaz", .query = "fbb", .expected = 70 },
        .{ .haystack = "foo barbaz", .query = "fbb", .expected = 69 },
        .{ .haystack = "fooBar Baz", .query = "foob", .expected = 114 },
        .{ .haystack = "xFoo-Bar Baz", .query = "foo-b", .expected = 116 },
        .{ .haystack = "axxx xx ", .query = "xx", .expected = 62 },
        .{ .haystack = "SS!H", .query = "s!", .expected = 57 },
        .{ .haystack = "xf.foo", .query = "xfoo", .expected = 104 },
        .{ .haystack = "xf fo", .query = "xfo", .expected = 84 },
        .{ .haystack = "你好世界", .query = "你好", .expected = 62 },
        .{ .haystack = "你好世界", .query = "你世", .expected = 49 },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var workspace: Workspace = .{};
    defer workspace.deinit(std.testing.allocator);
    var text_buffer: std.ArrayList(u21) = .empty;
    defer text_buffer.deinit(std.testing.allocator);
    for (cases) |case| {
        const atom = (try pattern.parse(&arena, case.query))[0];
        const haystack = try unicode.decode(std.testing.allocator, case.haystack, &text_buffer);
        try std.testing.expectEqual(@as(?u16, case.expected), try score(std.testing.allocator, &workspace, haystack, atom));
    }
}

test "matrix-cell boundary switches from optimal to greedy scores" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var query: [128]u8 = @splat('a');
    query[127] = 'b';
    const atom = (try pattern.parse(&arena, &query))[0];
    var workspace: Workspace = .{};
    defer workspace.deinit(allocator);
    var text_buffer: std.ArrayList(u21) = .empty;
    defer text_buffer.deinit(allocator);
    for ([_]usize{ 543, 544 }, [_]u16{ 3338, 2782 }) |gap, expected| {
        const haystack = try allocator.alloc(u8, 257 + gap);
        defer allocator.free(haystack);
        @memset(haystack[0..127], 'a');
        @memset(haystack[127 .. 127 + gap], 'x');
        haystack[127 + gap] = 'b';
        haystack[128 + gap] = ' ';
        @memcpy(haystack[129 + gap ..], &query);
        const text = try unicode.decode(allocator, haystack, &text_buffer);
        try std.testing.expectEqual(@as(?u16, expected), try score(allocator, &workspace, text, atom));
    }
}

test "slab byte budget preserves ASCII and Unicode fallback differences" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const atom = (try pattern.parse(&arena, "ab"))[0];
    var workspace: Workspace = .{};
    defer workspace.deinit(allocator);
    var text_buffer: std.ArrayList(u21) = .empty;
    defer text_buffer.deinit(allocator);
    for ([_]usize{ 100, 10000, 12000, 20000, 51200, 65536 }) |length| {
        const padding = try allocator.alloc(u8, length);
        defer allocator.free(padding);
        @memset(padding, 'x');
        for ([_][]const u8{ "", "é" }) |prefix| {
            const haystack = try std.fmt.allocPrint(allocator, "{s}a{s}b ab", .{ prefix, padding });
            defer allocator.free(haystack);
            const expected: u16 = if (length == 100 or (length == 10000 and prefix.len == 0)) 62 else 16;
            const text = try unicode.decode(allocator, haystack, &text_buffer);
            try std.testing.expectEqual(@as(?u16, expected), try score(allocator, &workspace, text, atom));
        }
    }
}
