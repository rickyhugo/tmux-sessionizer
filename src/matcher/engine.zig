// Translated from nucleo-matcher 0.3.1 and nucleo 0.5.0.
// SPDX-License-Identifier: MPL-2.0
// See vendor/licenses/matcher/ for upstream licenses and provenance.

const std = @import("std");
const pattern = @import("pattern.zig");
const unicode = @import("unicode.zig");
const scoring = @import("scoring.zig");

const Match = struct {
    index: usize,
    score: u32,
    length: usize,

    fn lessThan(_: void, left: Match, right: Match) bool {
        if (left.score != right.score) return left.score > right.score;
        if (left.length != right.length) return left.length < right.length;
        return left.index < right.index;
    }
};

/// Returns caller-owned original candidate indices. Inputs remain borrowed.
/// All query, Unicode, and scoring scratch is freed before returning.
pub fn rank(allocator: std.mem.Allocator, query: []const u8, candidates: []const []const u8) ![]usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const atoms = try pattern.parse(&arena, query);
    if (atoms.len == 0) {
        const result = try allocator.alloc(usize, candidates.len);
        for (result, 0..) |*index, i| index.* = i;
        return result;
    }
    var matches: std.ArrayList(Match) = .empty;
    defer matches.deinit(allocator);
    var text_buffer: std.ArrayList(u21) = .empty;
    defer text_buffer.deinit(allocator);
    var workspace: scoring.Workspace = .{};
    defer workspace.deinit(allocator);
    for (candidates, 0..) |candidate, index| {
        const text = try unicode.decode(allocator, candidate, &text_buffer);
        var total: u32 = 0;
        var matched = true;
        for (atoms) |atom| {
            const score = try scoring.score(allocator, &workspace, text, atom);
            if (atom.negative) {
                if (score != null) {
                    matched = false;
                    break;
                }
            } else {
                total +%= score orelse {
                    matched = false;
                    break;
                };
            }
        }
        if (matched) try matches.append(allocator, .{ .index = index, .score = total, .length = text.chars.len });
    }
    std.mem.sort(Match, matches.items, {}, Match.lessThan);
    const result = try allocator.alloc(usize, matches.items.len);
    for (matches.items, result) |match, *index| index.* = match.index;
    return result;
}

test "empty patterns retain injection order and duplicates" {
    const items = [_][]const u8{ "z", "alpha", "z" };
    const result = try rank(std.testing.allocator, " ! ^ $ ' ", &items);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, result);
}

test "optimal fuzzy scores beat greedy paths" {
    const items = [_][]const u8{ "a___b___c", "abxabc", "a/b/c", "abc", "ABC" };
    const result = try rank(std.testing.allocator, "abc", &items);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(usize, &.{ 3, 4, 2, 0, 1 }, result);
    const optimal = try rank(std.testing.allocator, "xx", &.{ "axxx xx ", "xx", "x_x" });
    defer std.testing.allocator.free(optimal);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 2 }, optimal);
}

test "smart case belongs to each atom" {
    const items = [_][]const u8{ "foo bar", "Foo BAR", "FOO bar", "bar Foo", "FooBar" };
    const result = try rank(std.testing.allocator, "Foo bar", &items);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(usize, &.{ 1, 3, 4 }, result);
}

test "normalization is asymmetric and graphemes retain original identity" {
    const items = [_][]const u8{ "a", "ä", "Ä", "bär", "bar" };
    const result = try rank(std.testing.allocator, "ä", &items);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 3 }, result);
    const emoji = [_][]const u8{ "👩‍💻", "👩", "x👩‍🔬", "🧑‍💻" };
    const emoji_result = try rank(std.testing.allocator, "👩‍🔬", &emoji);
    defer std.testing.allocator.free(emoji_result);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, emoji_result);
}

test "nonempty ties use matching-unit length then original index" {
    const result = try rank(std.testing.allocator, "ab", &.{ "aba", "ab", "ab", "a\u{301}b", "a-b" });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 3, 0, 4 }, result);
    const ties = try rank(std.testing.allocator, "a", &.{ "za", "ya", "xa", "wa", "za" });
    defer std.testing.allocator.free(ties);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4 }, ties);
}

test "case-sensitive ASCII anchors retain upstream whole-haystack comparison" {
    const items = [_][]const u8{ "Foo", "FooBar", "Foo bar", "bar Foo", " Foo" };
    const result = try rank(std.testing.allocator, "^Foo", &items);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(usize, &.{0}, result);
    const suffix = try rank(std.testing.allocator, "Foo$", &.{ "Foo", "barFoo", "bar Foo", "Foo ", "éFoo" });
    defer std.testing.allocator.free(suffix);
    try std.testing.expectEqualSlices(usize, &.{ 0, 4 }, suffix);
}

test "Unicode substring excludes final start while ASCII includes it" {
    const result = try rank(std.testing.allocator, "'ab", &.{ "éab", "éabc", "abé", "é ab", "xab" });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(usize, &.{ 2, 4, 1 }, result);
}

test "exact atoms trim whitespace and negation contributes no score" {
    const result = try rank(std.testing.allocator, "^foo$", &.{ " foo ", "foo", "\tfoo\t", "foobar", "   " });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 2 }, result);
    const negative = try rank(std.testing.allocator, "!^foo", &.{ "foo", "Foo", "foobar", "barfoo", "bar" });
    defer std.testing.allocator.free(negative);
    try std.testing.expectEqualSlices(usize, &.{ 4, 3 }, negative);
}

test "literal pipe and escaped markers do not become operators" {
    const pipe = try rank(std.testing.allocator, "a|b", &.{ "ab", "a|b", "a/b", "a|xb" });
    defer std.testing.allocator.free(pipe);
    try std.testing.expectEqualSlices(usize, &.{ 1, 3 }, pipe);
    const dollar = try rank(std.testing.allocator, "foo\\$", &.{ "foo$", "foo", "xfoo$" });
    defer std.testing.allocator.free(dollar);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, dollar);
    const escaped_unicode = try rank(std.testing.allocator, "é\\x", &.{ "é\\x", "é\\\\x", "éx" });
    defer std.testing.allocator.free(escaped_unicode);
    try std.testing.expectEqualSlices(usize, &.{1}, escaped_unicode);
}

test "combining marks flags Hangul and Indic clusters use first codepoint" {
    const cases = [_]struct { query: []const u8, items: []const []const u8, expected: []const usize }{
        .{ .query = "a", .items = &.{ "a\u{301}", "a", "a\u{308}", "xa" }, .expected = &.{ 0, 1, 2, 3 } },
        .{ .query = "🇸", .items = &.{ "🇸🇪", "🇸", "🇪", "🇸🇩" }, .expected = &.{ 0, 1, 3 } },
        .{ .query = "ᄀ", .items = &.{ "가", "ᄀ", "가", "각" }, .expected = &.{ 0, 1, 3 } },
        .{ .query = "क", .items = &.{ "क्ष", "क", "ष", "क्‍ष" }, .expected = &.{ 0, 1, 3 } },
    };
    for (cases) |case| {
        const result = try rank(std.testing.allocator, case.query, case.items);
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualSlices(usize, case.expected, result);
    }
}

fn allocationFailures(allocator: std.mem.Allocator) !void {
    const result = try rank(allocator, "ab !z", &.{ "a/b", "abc", "éabc", "axz", "👩ab" });
    defer allocator.free(result);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 4, 2 }, result);
}

test "rank frees scratch on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailures, .{});
}
