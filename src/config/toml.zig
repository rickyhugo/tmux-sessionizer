const std = @import("std");
const cfg = @import("../config.zig");
const A = std.mem.Allocator;
const c = @import("c.zig");

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    array: []Value,
    table: std.StringHashMapUnmanaged(Value),
};

pub fn parse(a: A, text: []const u8) !Value {
    return parseDetailed(a, text, null);
}

pub fn parseDetailed(a: A, text: []const u8, message: ?*?[]const u8) !Value {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidToml;
    const result = c.toml_parse(text.ptr, std.math.cast(c_int, text.len) orelse return error.InvalidToml);
    defer c.toml_free(result);
    if (!result.ok) {
        if (message) |m| m.* = try @import("diagnostic.zig").format(a, text, std.mem.sliceTo(&result.errmsg, 0));
        return error.InvalidToml;
    }
    return copy(a, text, result.toptab);
}

fn copy(a: A, text: []const u8, value: c.toml_datum_t) anyerror!Value {
    return switch (value.type) {
        c.TOML_STRING => .{ .string = try a.dupe(u8, value.u.str.ptr[0..@intCast(value.u.str.len)]) },
        c.TOML_INT64 => .{ .integer = value.u.int64 },
        c.TOML_FP64 => .{ .float = value.u.fp64 },
        c.TOML_BOOLEAN => .{ .boolean = value.u.boolean },
        c.TOML_ARRAY => blk: {
            const items = try a.alloc(Value, @intCast(value.u.arr.size));
            for (items, 0..) |*item, i| item.* = try copy(a, text, value.u.arr.elem[i]);
            break :blk .{ .array = items };
        },
        c.TOML_TABLE => blk: {
            var table: std.StringHashMapUnmanaged(Value) = .empty;
            for (0..@intCast(value.u.tab.size)) |i| {
                const key = try a.dupe(u8, value.u.tab.key[i][0..@intCast(value.u.tab.len[i])]);
                try table.put(a, key, try copy(a, text, value.u.tab.value[i]));
            }
            break :blk .{ .table = table };
        },
        c.TOML_DATE, c.TOML_TIME, c.TOML_DATETIME, c.TOML_DATETIMETZ => .{ .string = try timestamp(a, text, value) },
        else => error.InvalidToml,
    };
}

fn timestamp(a: A, text: []const u8, value: c.toml_datum_t) ![]const u8 {
    var start: usize = 0;
    for (1..@intCast(value.lineno)) |_| start = (std.mem.indexOfScalarPos(u8, text, start, '\n') orelse unreachable) + 1;
    start += @intCast(value.colno - 1);
    var end = start;
    while (end < text.len and (std.ascii.isDigit(text[end]) or std.mem.indexOfScalar(u8, "-:.TtZz+ ", text[end]) != null)) : (end += 1) {}
    const raw = std.mem.trimEnd(u8, text[start..end], " ");
    const t = value.u.ts;
    const date = if (value.type == c.TOML_TIME) "" else try std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u16, @intCast(t.year)), @as(u16, @intCast(t.month)), @as(u16, @intCast(t.day)) });
    if (value.type == c.TOML_DATE) return date;
    const time = try std.fmt.allocPrint(a, "{d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u16, @intCast(t.hour)), @as(u16, @intCast(t.minute)), @as(u16, @intCast(t.second)) });
    var fraction: []const u8 = "";
    if (std.mem.indexOfScalar(u8, raw, '.')) |dot| {
        var digits_end = dot + 1;
        while (digits_end < raw.len and std.ascii.isDigit(raw[digits_end])) : (digits_end += 1) {}
        const digits = std.mem.trimEnd(u8, raw[dot + 1 .. @min(digits_end, dot + 10)], "0");
        if (digits.len != 0) fraction = try std.fmt.allocPrint(a, ".{s}", .{digits});
    }
    // tomlc17 retains only microseconds and combines Z with zero numeric offsets.
    const zone = if (value.type != c.TOML_DATETIMETZ) "" else if (std.mem.endsWith(u8, raw, "Z") or std.mem.endsWith(u8, raw, "z")) "Z" else try std.fmt.allocPrint(a, "{s}{d:0>2}:{d:0>2}", .{ if (t.tz < 0) "-" else "+", @abs(t.tz) / 60, @abs(t.tz) % 60 });
    return if (value.type == c.TOML_TIME) std.fmt.allocPrint(a, "{s}{s}", .{ time, fraction }) else std.fmt.allocPrint(a, "{s}T{s}{s}{s}", .{ date, time, fraction, zone });
}

pub fn merge(a: A, base: *Value, later: Value) !void {
    if (base.* == .table and later == .table) {
        var it = later.table.iterator();
        while (it.next()) |entry| {
            const slot = try base.table.getOrPut(a, entry.key_ptr.*);
            if (slot.found_existing) {
                try merge(a, slot.value_ptr, entry.value_ptr.*);
            } else {
                slot.value_ptr.* = entry.value_ptr.*;
            }
        }
    } else base.* = later;
}

pub fn string(a: A, value: Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        .integer => |n| std.fmt.allocPrint(a, "{d}", .{n}),
        .float => |n| if (std.math.isNan(n)) "NaN" else std.fmt.allocPrint(a, "{d}", .{n}),
        .boolean => |b| if (b) "true" else "false",
        else => error.InvalidConfigType,
    };
}

pub fn boolean(value: Value) !bool {
    return switch (value) {
        .boolean => |b| b,
        .integer => |n| n != 0,
        .float => |n| n != 0,
        .string => |s| blk: {
            inline for (.{ "true", "yes", "on", "1" }) |yes| if (std.ascii.eqlIgnoreCase(s, yes)) break :blk true;
            inline for (.{ "false", "no", "off", "0" }) |no| if (std.ascii.eqlIgnoreCase(s, no)) break :blk false;
            return error.InvalidConfigType;
        },
        else => error.InvalidConfigType,
    };
}

fn unsigned(value: Value) !usize {
    return switch (value) {
        .integer => |n| std.math.cast(usize, n) orelse error.InvalidConfigType,
        .boolean => |b| @intFromBool(b),
        .float => |n| if (std.math.isNan(n) or n <= 0) 0 else if (n >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) std.math.maxInt(usize) else @intFromFloat(@round(n)),
        .string => |s| cfg.parseIndex(s) catch if (boolean(value)) |b| @intFromBool(b) else |_| return error.InvalidConfigType,
        else => error.InvalidConfigType,
    };
}

pub fn explain(comptime T: type, a: A, value: Value, key: []const u8, source: []const u8) anyerror![]const u8 {
    if (T == cfg.Color) return std.fmt.allocPrint(a, "Failed to parse Colors for key `{s}`", .{key});
    if (T == []const cfg.Binding) return std.fmt.allocPrint(a, "Config Error for key `{s}`", .{key});
    switch (@typeInfo(T)) {
        .optional => |o| return explain(o.child, a, value, key, source),
        .pointer => |p| if (T != []const u8 and value == .array) {
            for (value.array, 0..) |v, i| {
                _ = decode(p.child, a, v) catch return explain(p.child, a, v, try std.fmt.allocPrint(a, "{s}[{d}]", .{ key, i }), source);
            }
        },
        .@"enum" => {
            const name = if (T == cfg.VcsProvider) "VcsProviders" else if (T == cfg.Order) "SessionSortOrderConfig" else if (T == cfg.CloneSwitch) "CloneRepoSwitchConfig" else "InputPosition";
            const variant = enumText(value) catch return std.fmt.allocPrint(a, "value of enum {s} should be represented by either string or table with exactly one key for key `{s}`", .{ name, key });
            return std.fmt.allocPrint(a, "enum {s} does not have variant constructor {s} for key `{s}`", .{ name, variant, key });
        },
        .@"struct" => |s| {
            if (T == std.StringHashMapUnmanaged(cfg.SessionConfig) or T == std.StringHashMapUnmanaged([]const u8)) {
                const Child = if (T == std.StringHashMapUnmanaged(cfg.SessionConfig)) cfg.SessionConfig else []const u8;
                if (value == .table) {
                    var it = value.table.iterator();
                    while (it.next()) |entry| {
                        _ = decode(Child, a, entry.value_ptr.*) catch return explain(Child, a, entry.value_ptr.*, try std.fmt.allocPrint(a, "{s}.{s}", .{ key, entry.key_ptr.* }), source);
                    }
                }
            } else if (value == .array or value == .table) {
                inline for (s.field_names, s.field_types, 0..) |name, Field, i| {
                    if (if (value == .table) value.table.get(name) else if (i < value.array.len) value.array[i] else null) |v| {
                        _ = decode(Field, a, v) catch {
                            // The reference joins a named field directly after an array index.
                            const child_key = if (value == .array)
                                try std.fmt.allocPrint(a, "{s}[{d}]", .{ key, i })
                            else
                                try std.fmt.allocPrint(a, "{s}{s}{s}", .{ key, if (std.mem.endsWith(u8, key, "]")) "" else ".", name });
                            return explain(Field, a, v, child_key, source);
                        };
                    }
                }
                if (value == .array and value.array.len < s.field_names.len) {
                    const name = if (T == cfg.StartupSession) "Session" else if (T == cfg.Window) "Window" else if (T == cfg.SearchDirectory) "SearchDirectory" else if (T == cfg.PickerColors) "PickerColorConfig" else if (T == cfg.SessionConfig) "SessionConfig" else @typeName(T);
                    return std.fmt.allocPrint(a, "invalid length {d}, expected struct {s} with {d} element{s} for key `{s}`", .{ value.array.len, name, s.field_names.len, if (s.field_names.len == 1) "" else "s", key });
                }
            }
        },
        else => {},
    }
    const expected = if (T == bool) "a boolean" else if (T == []const u8) "a string" else if (T == usize) "an integer" else "a valid configuration value";
    const actual = switch (value) {
        .array => "sequence",
        .table => "map",
        .string => |s| try std.fmt.allocPrint(a, "string {s}", .{s}),
        .integer => |n| try std.fmt.allocPrint(a, "integer `{d}`", .{n}),
        .float => |n| try std.fmt.allocPrint(a, "floating point `{d}`", .{n}),
        .boolean => |b| if (b) "boolean `true`" else "boolean `false`",
    };
    return std.fmt.allocPrint(a, "invalid type: {s}, expected {s} for key `{s}`{s}", .{ actual, expected, key, if (source.len == 0) "" else try std.fmt.allocPrint(a, " in {s}", .{source}) });
}

pub fn decode(comptime T: type, a: A, value: Value) anyerror!T {
    if (T == []const u8) return string(a, value);
    if (T == bool) return boolean(value);
    if (T == usize or T == u8) return std.math.cast(T, try unsigned(value)) orelse error.InvalidConfigType;
    if (T == cfg.Color) {
        if (value == .table) {
            if (value.table.count() != 1) return error.InvalidColor;
            if (value.table.get("Indexed")) |v| return .{ .indexed = try colorByte(v) };
            if (value.table.get("Rgb")) |v| {
                if (v != .array or v.array.len != 3) return error.InvalidColor;
                return .{ .rgb = .{ .r = try colorByte(v.array[0]), .g = try colorByte(v.array[1]), .b = try colorByte(v.array[2]) } };
            }
            return error.InvalidColor;
        }
        // Ratatui's untagged string variant does not coerce numbers.
        if (value != .string) return error.InvalidColor;
        return cfg.parseColor(value.string);
    }
    if (T == []const cfg.Binding) {
        if (value != .table) return error.InvalidConfigType;
        var bindings: std.ArrayList(cfg.Binding) = .empty;
        var it = value.table.iterator();
        while (it.next()) |entry| {
            const binding: cfg.Binding = .{ .key = try cfg.parseKey(entry.key_ptr.*), .action = try decode(cfg.PickerAction, a, entry.value_ptr.*) };
            try cfg.setBinding(a, &bindings, binding);
        }
        return bindings.toOwnedSlice(a);
    }
    if (T == std.StringHashMapUnmanaged(cfg.SessionConfig) or T == std.StringHashMapUnmanaged([]const u8)) {
        if (value != .table) return error.InvalidConfigType;
        const Child = if (T == std.StringHashMapUnmanaged(cfg.SessionConfig)) cfg.SessionConfig else []const u8;
        var map: T = .empty;
        var it = value.table.iterator();
        while (it.next()) |entry| try map.put(a, entry.key_ptr.*, try decode(Child, a, entry.value_ptr.*));
        return map;
    }
    return switch (@typeInfo(T)) {
        .optional => |o| try decode(o.child, a, value),
        .pointer => |p| blk: {
            if (value != .array) return error.InvalidConfigType;
            const items = try a.alloc(p.child, value.array.len);
            for (items, value.array) |*item, v| item.* = try decode(p.child, a, v);
            break :blk items;
        },
        .@"struct" => |s| blk: {
            if (value != .table and value != .array) return error.InvalidConfigType;
            // Serde's struct visitor consumes only the declared fields. Keep the
            // minimum length check before indexing, but do not decode its tail.
            if (value == .array and value.array.len < s.field_names.len) return error.InvalidConfigType;
            var result: T = undefined;
            inline for (s.field_names, s.field_types, s.field_attrs, 0..) |name, Field, attrs, i| {
                if (if (value == .table) value.table.get(name) else value.array[i]) |v| {
                    @field(result, name) = try decode(Field, a, v);
                } else if (attrs.default_value_ptr) |ptr| {
                    @field(result, name) = @as(*const Field, @ptrCast(@alignCast(ptr))).*;
                } else return error.MissingConfigField;
            }
            break :blk result;
        },
        .@"enum" => |e| blk: {
            const text = try enumText(value);
            if (T == cfg.VcsProvider and std.mem.eql(u8, text, "jj")) break :blk .jujutsu;
            inline for (e.field_values) |number| {
                const tag: T = @fromBackingInt(@intCast(number));
                if (std.mem.eql(u8, text, enumName(tag))) break :blk tag;
            }
            return error.InvalidConfigEnum;
        },
        else => @compileError("unsupported config type " ++ @typeName(T)),
    };
}

fn colorByte(value: Value) !u8 {
    return if (value == .integer) std.math.cast(u8, value.integer) orelse error.InvalidColor else error.InvalidColor;
}

fn enumText(value: Value) ![]const u8 {
    if (value == .string) return value.string;
    if (value == .table and value.table.count() == 1) {
        var it = value.table.keyIterator();
        return it.next().?.*;
    }
    return error.InvalidConfigEnum;
}

pub fn enumName(value: anytype) []const u8 {
    const T = @TypeOf(value);
    if (T == cfg.Order) return switch (value) {
        .alphabetical => "Alphabetical",
        .last_attached => "LastAttached",
    };
    if (T == cfg.CloneSwitch) return switch (value) {
        .always => "Always",
        .never => "Never",
        .foreground => "Foreground",
    };
    if (T == cfg.InputPosition) return switch (value) {
        .top => "Top",
        .bottom => "Bottom",
    };
    if (T == cfg.PickerAction and value == .noop) return "";
    return @tagName(value);
}

pub fn encode(a: A, config: cfg.Config) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    inline for (comptime std.meta.fieldNames(cfg.Config)) |name| {
        if (@field(config, name)) |v| {
            try out.writer.print("{s} = ", .{name});
            try write(a, &out.writer, v);
            try out.writer.writeByte('\n');
        }
    }
    return out.toOwnedSlice();
}

fn quote(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11, 12, 14...31, 127 => try w.print("\\u{X:0>4}", .{@as(u16, ch)}),
        else => try w.writeByte(ch),
    };
    try w.writeByte('"');
}

fn write(a: A, w: *std.Io.Writer, value: anytype) anyerror!void {
    const T = @TypeOf(value);
    if (T == []const u8) return quote(w, value);
    if (T == cfg.Color) return quote(w, try cfg.colorName(a, value));
    if (T == []const cfg.Binding) {
        try w.writeAll("{");
        for (value, 0..) |binding, i| {
            if (i != 0) try w.writeAll(", ");
            try quote(w, try cfg.keyName(a, binding.key));
            try w.writeAll(" = ");
            try quote(w, enumName(binding.action));
        }
        return w.writeAll("}");
    }
    if (T == std.StringHashMapUnmanaged(cfg.SessionConfig) or T == std.StringHashMapUnmanaged([]const u8)) {
        try w.writeAll("{");
        var it = value.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) try w.writeAll(", ");
            first = false;
            try quote(w, entry.key_ptr.*);
            try w.writeAll(" = ");
            try write(a, w, entry.value_ptr.*);
        }
        return w.writeAll("}");
    }
    switch (@typeInfo(T)) {
        .bool => try w.writeAll(if (value) "true" else "false"),
        .int => {
            const integer = std.math.cast(i64, value) orelse return error.ConfigIntegerOutOfRange;
            try w.print("{d}", .{integer});
        },
        .@"enum" => try quote(w, enumName(value)),
        .pointer => {
            try w.writeByte('[');
            for (value, 0..) |v, i| {
                if (i != 0) try w.writeAll(", ");
                try write(a, w, v);
            }
            try w.writeByte(']');
        },
        .@"struct" => |s| {
            try w.writeByte('{');
            var first = true;
            inline for (s.field_names, s.field_types) |name, Field| {
                const v = @field(value, name);
                if (@typeInfo(Field) == .optional) {
                    if (v) |present| {
                        if (!first) try w.writeAll(", ");
                        first = false;
                        try w.print("{s} = ", .{name});
                        try write(a, w, present);
                    }
                } else {
                    if (!first) try w.writeAll(", ");
                    first = false;
                    try w.print("{s} = ", .{name});
                    try write(a, w, v);
                }
            }
            try w.writeByte('}');
        },
        else => @compileError("unsupported serialized config type " ++ @typeName(T)),
    }
}
