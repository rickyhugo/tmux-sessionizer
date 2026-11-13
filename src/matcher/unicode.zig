// Translated from nucleo-matcher 0.3.1. SPDX-License-Identifier: MPL-2.0
// Grapheme rules derive from unicode-segmentation 1.12.0, MIT OR Apache-2.0.
// Copyright 2012-2018 The Rust Project Developers.
// See vendor/licenses/matcher/ for upstream licenses and provenance.

const std = @import("std");
const tables = @import("tables.zig");

pub const Class = enum(u8) { whitespace, non_word, delimiter, lower, upper, letter, number };
const Grapheme = enum(u8) {
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
    spacing_mark,
    t,
    v,
    zwj,
};

fn rangeValue(ranges: []const tables.Range, cp: u21, default: u8) u8 {
    var lo: usize = 0;
    var hi = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const range = ranges[mid];
        if (cp < range.lo) {
            hi = mid;
        } else if (cp > range.hi) {
            lo = mid + 1;
        } else return range.value;
    }
    return default;
}

fn mapping(mappings: []const tables.Mapping, cp: u21) u21 {
    var lo: usize = 0;
    var hi = mappings.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < mappings[mid].from) {
            hi = mid;
        } else if (cp > mappings[mid].from) {
            lo = mid + 1;
        } else return mappings[mid].to;
    }
    return cp;
}

pub fn normalize(cp: u21) u21 {
    return mapping(&tables.normalize, cp);
}

pub fn lower(cp: u21) u21 {
    return mapping(&tables.case_fold, cp);
}

pub fn isUpper(cp: u21) bool {
    return lower(cp) != cp;
}

pub fn asciiWhitespace(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp == '\n' or cp == '\x0c' or cp == '\r';
}

pub fn whitespace(cp: u21) bool {
    if (cp < 128) return asciiWhitespace(cp) or cp == '\x0b';
    return rangeValue(&tables.classes, cp, 1) == 0;
}

pub fn class(cp: u21) Class {
    if (cp < 128) {
        if (cp >= 'a' and cp <= 'z') return .lower;
        if (cp >= 'A' and cp <= 'Z') return .upper;
        if (cp >= '0' and cp <= '9') return .number;
        if (asciiWhitespace(cp)) return .whitespace;
        if (cp == '/' or cp == ',' or cp == ':' or cp == ';' or cp == '|') return .delimiter;
        return .non_word;
    }
    return @fromBackingInt(@intCast(rangeValue(&tables.classes, cp, 1)));
}

fn category(cp: u21) Grapheme {
    return @fromBackingInt(@intCast(rangeValue(&tables.graphemes, cp, 0)));
}

fn linker(cp: u21) bool {
    return switch (cp) {
        0x94d, 0x9cd, 0xacd, 0xb4d, 0xc4d, 0xd4d => true,
        else => false,
    };
}

const GraphemeState = struct {
    previous: Grapheme = .control,
    regional_count: usize = 0,
    pictographic_extend: bool = false,
    zwj_after_pictographic: bool = false,
    consonant: bool = false,
    linked: bool = false,

    fn boundary(self: GraphemeState, next: Grapheme) bool {
        const previous = self.previous;
        if (previous == .cr and next == .lf) return false;
        if (previous == .cr or previous == .lf or previous == .control) return true;
        if (next == .cr or next == .lf or next == .control) return true;
        if (previous == .l and (next == .l or next == .v or next == .lv or next == .lvt)) return false;
        if ((previous == .lv or previous == .v) and (next == .v or next == .t)) return false;
        if ((previous == .lvt or previous == .t) and next == .t) return false;
        if (next == .extend or next == .zwj or next == .spacing_mark or previous == .prepend) return false;
        if (next == .consonant and self.consonant and self.linked) return false;
        if (previous == .zwj and next == .pictographic and self.zwj_after_pictographic) return false;
        if (previous == .regional and next == .regional and self.regional_count % 2 == 1) return false;
        return true;
    }

    fn advance(self: *GraphemeState, cp: u21, next: Grapheme) void {
        self.zwj_after_pictographic = next == .zwj and self.pictographic_extend;
        if (next != .extend) self.pictographic_extend = next == .pictographic;
        if (next == .consonant) {
            self.consonant = true;
            self.linked = false;
        } else if (linker(cp)) {
            self.linked = self.consonant;
        } else if (rangeValue(&tables.incb_extend, cp, 0) == 0) {
            self.consonant = false;
            self.linked = false;
        }
        self.regional_count = if (next == .regional) self.regional_count + 1 else 0;
        self.previous = next;
    }
};

pub const Text = struct {
    chars: []const u21,
    ascii: bool,
};

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, buffer: *std.ArrayList(u21)) !Text {
    buffer.clearRetainingCapacity();
    var ascii = true;
    for (bytes) |byte| {
        if (byte >= 128) {
            ascii = false;
            break;
        }
    }
    if (ascii) {
        try buffer.ensureTotalCapacity(allocator, bytes.len);
        for (bytes) |byte| buffer.appendAssumeCapacity(byte);
    } else {
        var iterator = (try std.unicode.Utf8View.init(bytes)).iterator();
        var state: GraphemeState = .{};
        var first = true;
        while (iterator.nextCodepoint()) |cp| {
            const next = category(cp);
            if (first or state.boundary(next)) try buffer.append(allocator, cp);
            first = false;
            state.advance(cp, next);
        }
    }
    return .{ .chars = buffer.items, .ascii = ascii };
}
