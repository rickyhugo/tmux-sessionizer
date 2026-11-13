const std = @import("std");
const A = std.mem.Allocator;

// Clap uses Jaro confidence > 0.7, preferring the last candidate on ties.
pub fn best(a: A, value: []const u8, candidates: []const []const u8) !?[]const u8 {
    const lossy = try std.fmt.allocPrint(a, "{f}", .{std.unicode.fmtUtf8(value)});
    defer a.free(lossy);
    const input = try codepoints(a, lossy);
    defer a.free(input);
    var confidence: f64 = 0.7;
    var result: ?[]const u8 = null;
    for (candidates) |candidate| {
        const points = try codepoints(a, candidate);
        defer a.free(points);
        const score = try jaro(a, input, points);
        if (score > 0.7 and score >= confidence) {
            confidence = score;
            result = candidate;
        }
    }
    return result;
}

fn codepoints(a: A, text: []const u8) ![]u21 {
    var result: std.ArrayList(u21) = .empty;
    errdefer result.deinit(a);
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    while (it.nextCodepoint()) |point| try result.append(a, point);
    return result.toOwnedSlice(a);
}

fn jaro(a: A, lhs: []const u21, rhs: []const u21) !f64 {
    if (lhs.len == 0 and rhs.len == 0) return 1;
    if (lhs.len == 0 or rhs.len == 0) return 0;
    const flags = try a.alloc(bool, lhs.len + rhs.len);
    defer a.free(flags);
    @memset(flags, false);
    const left = flags[0..lhs.len];
    const right = flags[lhs.len..];
    const radius = @max(lhs.len, rhs.len) / 2 -| 1;
    var matches: usize = 0;
    for (lhs, 0..) |point, i| {
        var j = i -| radius;
        const end = @min(rhs.len, i + radius + 1);
        while (j < end) : (j += 1) {
            if (point == rhs[j] and !right[j]) {
                left[i] = true;
                right[j] = true;
                matches += 1;
                break;
            }
        }
    }
    if (matches == 0) return 0;
    var transpositions: usize = 0;
    var j: usize = 0;
    for (lhs, left) |point, matched| {
        if (!matched) continue;
        while (!right[j]) j += 1;
        if (point != rhs[j]) transpositions += 1;
        j += 1;
    }
    const m: f64 = @floatFromInt(matches);
    const l: f64 = @floatFromInt(lhs.len);
    const r: f64 = @floatFromInt(rhs.len);
    const ordered: f64 = @floatFromInt(matches - transpositions / 2);
    return (m / l + m / r + ordered / m) / 3;
}

test "suggestions match Jaro thresholds, lossy Unicode, and tie order" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("true", (try best(a, "true\xff", &.{ "true", "false" })).?);
    try std.testing.expectEqualStrings("session", (try best(a, "version", &.{ "paths", "session", "help" })).?);
    try std.testing.expectEqualStrings("foob", (try best(a, "foo", &.{ "fooa", "foob" })).?);
    try std.testing.expectEqualStrings("é猫", (try best(a, "é猫猫", &.{ "é猫", "abc" })).?);
    try std.testing.expect(try best(a, "TRUE", &.{ "true", "false" }) == null);
    try std.testing.expect(try best(a, "unrelated", &.{ "true", "false" }) == null);
}
