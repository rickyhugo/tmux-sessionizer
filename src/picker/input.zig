const std = @import("std");
const config = @import("config");
const widths = @import("width.zig");

pub const Decoder = struct {
    bytes: [512]u8 = undefined,
    len: usize = 0,

    pub fn pending(self: *const Decoder) bool {
        return self.len != 0;
    }

    pub fn feed(self: *Decoder, bytes: []const u8) void {
        const n = @min(bytes.len, self.bytes.len - self.len);
        @memcpy(self.bytes[self.len..][0..n], bytes[0..n]);
        self.len += n;
    }

    fn consume(self: *Decoder, n: usize) void {
        std.mem.copyForwards(u8, &self.bytes, self.bytes[n..self.len]);
        self.len -= n;
    }

    pub fn next(self: *Decoder, expired: bool) ?config.Key {
        decode: while (self.len > 0) {
            var alt = false;
            var offset: usize = 0;
            if (self.bytes[0] == 0x1b) {
                if (self.len == 1) {
                    if (!expired) return null;
                    self.consume(1);
                    return .{ .code = .esc };
                }
                if (self.bytes[1] == 0x1b) {
                    self.consume(2);
                    return .{ .code = .esc };
                }
                if (self.bytes[1] == '[' or self.bytes[1] == 'O') {
                    var end: usize = 2;
                    while (end < self.len and !(self.bytes[end] >= 0x40 and self.bytes[end] <= 0x7e)) : (end += 1) {
                        if (self.bytes[end] < 0x20 or self.bytes[end] > 0x3f) {
                            self.consume(end);
                            continue :decode;
                        }
                    }
                    if (end == self.len) {
                        if (self.len < 64) return null;
                        self.consume(self.len);
                        continue;
                    }
                    const key = sequence(self.bytes[1 .. end + 1]);
                    self.consume(end + 1);
                    if (key) |value| return value;
                    continue;
                }
                alt = true;
                offset = 1;
            }
            const first = self.bytes[offset];
            const n = std.unicode.utf8ByteSequenceLength(first) catch {
                self.consume(offset + 1);
                continue;
            };
            for (1..@min(n, self.len - offset)) |i| {
                const byte = self.bytes[offset + i];
                if (byte & 0xc0 != 0x80 or (i == 1 and switch (first) {
                    0xe0 => byte < 0xa0,
                    0xed => byte >= 0xa0,
                    0xf0 => byte < 0x90,
                    0xf4 => byte >= 0x90,
                    else => false,
                })) {
                    self.consume(offset + i);
                    continue :decode;
                }
            }
            if (self.len - offset < n) {
                return null;
            }
            const scalar = std.unicode.utf8Decode(self.bytes[offset..][0..n]) catch {
                self.consume(offset + 1);
                continue;
            };
            self.consume(offset + n);
            var key: config.Key = .{ .code = .{ .char = scalar }, .modifiers = .{ .alt = alt } };
            switch (scalar) {
                0 => {
                    key.code = .{ .char = ' ' };
                    key.modifiers.ctrl = true;
                },
                9 => key.code = .tab,
                13 => key.code = .enter,
                27 => key.code = .esc,
                127 => key.code = .backspace,
                1...8, 10...12, 14...26 => {
                    key.code = .{ .char = scalar + 'a' - 1 };
                    key.modifiers.ctrl = true;
                },
                28...31 => {
                    key.code = .{ .char = scalar - 28 + '4' };
                    key.modifiers.ctrl = true;
                },
                else => key.modifiers.shift = widths.isUpper(scalar),
            }
            return key;
        }
        return null;
    }
};

fn sequence(bytes: []const u8) ?config.Key {
    const final = bytes[bytes.len - 1];
    var params: [8]u32 = @splat(0);
    var count: usize = 0;
    var tokens = std.mem.splitScalar(u8, bytes[1 .. bytes.len - 1], ';');
    while (tokens.next()) |token| {
        if (count == params.len) return null;
        params[count] = if (token.len == 0) 0 else std.fmt.parseInt(u32, token, 10) catch return null;
        count += 1;
    }
    var key: config.Key = .{ .code = switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'Z' => .back_tab,
        'P' => .{ .function = 1 },
        'Q' => .{ .function = 2 },
        'R' => .{ .function = 3 },
        'S' => .{ .function = 4 },
        '~' => switch (params[0]) {
            1, 7 => .home,
            2 => .insert,
            3 => .delete,
            4, 8 => .end,
            5 => .page_up,
            6 => .page_down,
            11...15 => .{ .function = @intCast(params[0] - 10) },
            17...21 => .{ .function = @intCast(params[0] - 11) },
            23, 24 => .{ .function = @intCast(params[0] - 12) },
            27 => .{ .char = if (count >= 3) std.math.cast(u21, params[2]) orelse return null else return null },
            else => return null,
        },
        'u' => .{ .char = std.math.cast(u21, params[0]) orelse return null },
        else => return null,
    } };
    if (count > 1 and params[1] > 0) {
        const bits = params[1] - 1;
        key.modifiers.shift = bits & 1 != 0;
        key.modifiers.alt = bits & 2 != 0;
        key.modifiers.ctrl = bits & 4 != 0;
        key.modifiers.super = bits & 8 != 0;
        key.modifiers.hyper = bits & 16 != 0;
        key.modifiers.meta = bits & 32 != 0;
    }
    if (final == 'Z') key.modifiers.shift = true;
    if (final == 'u' or (final == '~' and params[0] == 27)) {
        switch (key.code.char) {
            13 => key.code = .enter,
            27 => key.code = .esc,
            9 => key.code = .tab,
            127 => key.code = .backspace,
            else => {},
        }
    }
    return key;
}

test "fragmented UTF-8 and CSI, Alt, Ctrl-J distinct from Enter" {
    var decoder: Decoder = .{};
    decoder.feed("\xc3");
    try std.testing.expect(decoder.next(false) == null);
    decoder.feed("\xa4\x1b[1;");
    try std.testing.expectEqual(@as(u21, 'ä'), decoder.next(false).?.code.char);
    try std.testing.expect(decoder.next(false) == null);
    decoder.feed("5D\x1bx\n\r");
    const left = decoder.next(false).?;
    try std.testing.expect(left.code == .left and left.modifiers.ctrl);
    const alt = decoder.next(false).?;
    try std.testing.expect(alt.code.char == 'x' and alt.modifiers.alt);
    const ctrl_j = decoder.next(false).?;
    try std.testing.expect(ctrl_j.code.char == 'j' and ctrl_j.modifiers.ctrl);
    try std.testing.expect(decoder.next(false).?.code == .enter);
}

test "escape timeout, SS3 and unknown CSI do not insert bytes" {
    var decoder: Decoder = .{};
    decoder.feed("\x1b");
    try std.testing.expect(decoder.next(false) == null);
    try std.testing.expect(decoder.next(true).?.code == .esc);
    decoder.feed("\x1bOP\x1b[200~x\x1b[Z");
    try std.testing.expectEqual(@as(u8, 1), decoder.next(false).?.code.function);
    try std.testing.expectEqual(@as(u21, 'x'), decoder.next(false).?.code.char);
    const backtab = decoder.next(false).?;
    try std.testing.expect(backtab.code == .back_tab and backtab.modifiers.shift);
}

test "incomplete sequences retain fragmented UTF-8 but cannot swallow cancellation" {
    var decoder: Decoder = .{};
    decoder.feed("\xc3");
    try std.testing.expect(decoder.next(true) == null);
    decoder.feed("\xa4");
    try std.testing.expectEqual(@as(u21, 'ä'), decoder.next(false).?.code.char);
    decoder.feed("\x1b[1;");
    try std.testing.expect(decoder.next(true) == null);
    decoder.feed("\x03");
    const cancel = decoder.next(false).?;
    try std.testing.expect(cancel.code.char == 'c' and cancel.modifiers.ctrl);
}

test "every UTF-8 prefix rejects an invalid continuation without swallowing Ctrl-C" {
    for ([_][]const u8{ "ä", "界", "🙂" }) |text| {
        for (1..text.len) |length| {
            var decoder: Decoder = .{};
            decoder.feed(text[0..length]);
            try std.testing.expect(decoder.next(false) == null);
            decoder.feed("\x03");
            const key = decoder.next(false) orelse return error.CancellationLost;
            try std.testing.expect(key.code == .char and key.code.char == 'c' and key.modifiers.ctrl);
        }
    }
}

test "buffered double escape is plain Escape" {
    var decoder: Decoder = .{};
    decoder.feed("\x1b\x1b");
    const key = decoder.next(false).?;
    try std.testing.expect(key.code == .esc and !key.modifiers.alt);
}
