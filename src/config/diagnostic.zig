const std = @import("std");
const A = std.mem.Allocator;

const Frame = struct {
    kind: enum { array, header },
    needs_comma: bool = false,
};

pub fn format(a: A, text: []const u8, native: []const u8) ![]const u8 {
    const end = std.mem.indexOf(u8, native, ") ") orelse return a.dupe(u8, native);
    if (!std.mem.startsWith(u8, native, "(line ")) return a.dupe(u8, native);
    const line = std.fmt.parseInt(usize, native[6..end], 10) catch return a.dupe(u8, native);
    const reason = native[end + 2 ..];
    const eof_error = std.mem.eql(u8, reason, "missing value") or
        std.mem.eql(u8, reason, "syntax error while parsing array: missing comma") or
        std.mem.startsWith(u8, reason, "unterminated");
    if (!eof_error or line != std.mem.count(u8, text, "\n") + 1 or !try endsInArray(a, text))
        return a.dupe(u8, native);
    return eofDiagnostic(a, text, "unclosed array, expected `]`");
}

fn endsInArray(a: A, text: []const u8) !bool {
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(a);
    var expect_value = false;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (std.ascii.isWhitespace(ch)) {
            if (ch == '\n' and stack.items.len == 0) expect_value = false;
            i += 1;
            continue;
        }
        if (ch == '#') {
            i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            if (!value(&stack)) return false;
            const multiline = i + 2 < text.len and text[i + 1] == ch and text[i + 2] == ch;
            i += if (multiline) @as(usize, 3) else 1;
            while (i < text.len) {
                if (ch == '"' and text[i] == '\\') {
                    i = @min(i + 2, text.len);
                } else if (text[i] == ch and (!multiline or
                    (i + 2 < text.len and text[i + 1] == ch and text[i + 2] == ch)))
                {
                    i += if (multiline) @as(usize, 3) else 1;
                    // TOML permits one or two quote characters before a triple terminator.
                    if (multiline) {
                        var extra: usize = 0;
                        while (i < text.len and text[i] == ch and extra < 2) : (extra += 1) i += 1;
                    }
                    break;
                } else i += 1;
            }
            expect_value = false;
            continue;
        }
        switch (ch) {
            '=' => {
                if (stack.items.len != 0 and stack.items[stack.items.len - 1].kind == .array) return false;
                expect_value = true;
            },
            '{', '}' => return false,
            '[' => {
                const array = expect_value or
                    (stack.items.len != 0 and stack.items[stack.items.len - 1].kind == .array);
                if (!value(&stack)) return false;
                try stack.append(a, .{ .kind = if (array) .array else .header });
                expect_value = false;
            },
            ']' => {
                _ = stack.pop() orelse return false;
                expect_value = false;
            },
            ',' => {
                if (stack.items.len == 0) return false;
                const frame = &stack.items[stack.items.len - 1];
                if (frame.kind == .array) {
                    if (!frame.needs_comma) return false;
                    frame.needs_comma = false;
                }
                expect_value = false;
            },
            else => {
                if (!value(&stack)) return false;
                const start = i;
                while (i < text.len and std.mem.indexOfScalar(u8, " \t\r\n,[]{}=#\"'", text[i]) == null) : (i += 1) {}
                if (i == start) return false;
                // The sole whitespace inside an unquoted TOML value separates date and time.
                if (i - start == 10 and i < text.len and text[i] == ' ' and
                    i + 1 < text.len and std.ascii.isDigit(text[i + 1]) and
                    text[start + 4] == '-' and text[start + 7] == '-')
                {
                    i += 1;
                    while (i < text.len and std.mem.indexOfScalar(u8, " \t\r\n,[]{}=#\"'", text[i]) == null) : (i += 1) {}
                }
                expect_value = false;
                continue;
            },
        }
        i += 1;
    }
    return stack.items.len != 0 and stack.items[stack.items.len - 1].kind == .array;
}

fn value(stack: *std.ArrayList(Frame)) bool {
    if (stack.items.len == 0) return true;
    const frame = &stack.items[stack.items.len - 1];
    if (frame.kind != .array) return true;
    if (frame.needs_comma) return false;
    frame.needs_comma = true;
    return true;
}

fn eofDiagnostic(a: A, text: []const u8, reason: []const u8) ![]const u8 {
    // toml 0.9 anchors EOF to the last byte, then adds one column, even after LF.
    const last = text.len - 1;
    const start = if (std.mem.lastIndexOfScalar(u8, text[0..last], '\n')) |n| n + 1 else 0;
    const line = std.mem.count(u8, text[0..start], "\n") + 1;
    const column = try std.unicode.utf8CountCodepoints(text[start..]);
    const content = std.mem.trimEnd(u8, text[start..], "\r\n");
    const digits = (try std.fmt.allocPrint(a, "{d}", .{line})).len;
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print("TOML parse error at line {d}, column {d}\n", .{ line, column + 1 });
    try w.splatByteAll(' ', digits + 5);
    try w.print("|\n    {d} | {s}\n", .{ line, content });
    try w.splatByteAll(' ', digits + 5);
    try w.writeByte('|');
    try w.splatByteAll(' ', column + 1);
    try w.print("^\n    {s}\n    ", .{reason});
    return out.toOwnedSlice();
}
