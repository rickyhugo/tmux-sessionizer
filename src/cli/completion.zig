const std = @import("std");
const config = @import("config");
const sessions = @import("sessions");
const spec = @import("spec.zig");
const A = std.mem.Allocator;
const Env = std.process.Environ.Map;
pub const Candidate = struct { value: []const u8, help: ?[]const u8 = null };
const Shell = enum { bash, elvish, fish, powershell, zsh };
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub fn complete(io: std.Io, a: A, argv: []const []const u8, env: *const Env) !bool {
    const setting = env.get("COMPLETE") orelse return false;
    if (setting.len == 0 or std.mem.eql(u8, setting, "0")) return false;
    // Disable child completion without changing Zig's fixed-length environment block.
    if (setenv("COMPLETE", "0", 1) != 0) return error.OutOfMemory;
    const name = std.fs.path.stem(std.fs.path.basename(setting));
    const shell = if (std.mem.eql(u8, name, "powershell_ise")) Shell.powershell else std.meta.stringToEnum(Shell, name) orelse return error.UnknownCompletionShell;
    var args: []const []const u8 = &.{};
    for (argv, 0..) |arg, i| {
        if (i != 0 and std.mem.eql(u8, arg, "--")) {
            args = argv[i + 1 ..];
            break;
        }
    }
    if (args.len == 0) {
        try std.Io.File.stdout().writeStreamingAll(io, try registration(a, shell, if (argv.len == 0) "tms" else argv[0]));
        return true;
    }
    const index = if (shell == .fish or shell == .powershell) args.len - 1 else if (env.get("_CLAP_COMPLETE_INDEX")) |v| config.parseIndex(v) catch 0 else 0;
    if (index == args.len and shell == .zsh) args = try std.mem.concat(a, []const u8, &.{ args, &.{""} });
    if (index == 0 or index >= args.len) return error.NoCompletionGenerated;
    const items = try candidates(io, a, args, index, env);
    var out: std.Io.Writer.Allocating = .init(a);
    const ifs = env.get("_CLAP_IFS") orelse "\n";
    for (items, 0..) |item, i| {
        if (shell == .bash or shell == .elvish or shell == .zsh) {
            if (i != 0) try out.writer.writeAll(ifs);
        }
        if (shell == .zsh) {
            try escapeZsh(&out.writer, item.value, true);
        } else try out.writer.writeAll(item.value);
        if (shell == .fish or shell == .powershell or shell == .zsh) {
            if (item.help) |description| {
                try out.writer.writeByte(if (shell == .zsh) ':' else '\t');
                const first_line = description[0 .. std.mem.indexOfScalar(u8, description, '\n') orelse description.len];
                if (shell == .zsh) try escapeZsh(&out.writer, first_line, false) else try out.writer.writeAll(first_line);
            }
            if (shell != .zsh) try out.writer.writeByte('\n');
        }
    }
    try std.Io.File.stdout().writeStreamingAll(io, out.written());
    return true;
}

fn escapeZsh(w: *std.Io.Writer, value: []const u8, escape_colon: bool) !void {
    for (value) |ch| {
        if (ch == '\\' or (escape_colon and ch == ':')) try w.writeByte('\\');
        try w.writeByte(ch);
    }
}

fn option(id: spec.Id, value: []const u8) ?spec.Option {
    const long = std.mem.startsWith(u8, value, "--");
    if (long) return spec.findOption(id, .{ .long = value[2 .. std.mem.indexOfScalar(u8, value, '=') orelse value.len] });
    if (value.len >= 2 and value[0] == '-') return spec.findOption(id, .{ .short = value[1] });
    return null;
}

pub fn candidates(io: std.Io, a: A, args: []const []const u8, index: usize, env: *const Env) ![]const Candidate {
    var id: spec.Id = .root;
    var pending: ?spec.Option = null;
    var consumed: usize = 0;
    var positional_used = false;
    var escaped = false;
    var help_context = false;
    var help_from_root = false;
    for (args[1..index]) |arg| {
        if (std.mem.eql(u8, arg, "help") and (id == .root or id == .config or id == .marks)) {
            help_context = true;
            help_from_root = id == .root;
            pending = null;
            continue;
        }
        if (spec.child(id, arg)) |child| {
            id = child;
            positional_used = false;
            pending = null;
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            escaped = true;
            pending = null;
            continue;
        }
        if (!escaped and arg.len > 1 and arg[0] == '-') {
            pending = null;
            if (option(id, arg)) |o| {
                if (o.kind != .flag and std.mem.indexOfScalar(u8, arg, '=') == null and (std.mem.startsWith(u8, arg, "--") or arg.len == 2)) {
                    pending = o;
                    consumed = 0;
                }
            }
            continue;
        }
        if (pending) |o| {
            consumed += 1;
            if (!o.many()) pending = null;
        } else positional_used = true;
    }
    const current = args[index];
    var items: std.ArrayList(Candidate) = .empty;
    if (pending) |o| {
        try valueCandidates(a, &items, o, current, "");
        if (!o.many() or consumed == 0) return items.toOwnedSlice(a);
    }
    if (help_context) {
        try subcommands(a, &items, id, current, !help_from_root or id == .root);
        return items.toOwnedSlice(a);
    }
    if (!escaped or !positional_used) {
        try subcommands(a, &items, id, current, true);
        if (!positional_used) {
            if (id == .open_session) {
                const cfg = config.load(io, a, env) catch null;
                if (cfg) |c| {
                    const catalog = sessions.discover(io, a, env, &c) catch null;
                    if (catalog) |cat| for (cat.entries) |entry| if (std.mem.startsWith(u8, entry.key, current)) {
                        try items.append(a, .{ .value = entry.key });
                    };
                }
            } else if (id == .marks or id == .marks_open or id == .marks_delete) {
                const cfg = config.load(io, a, env) catch config.Config{};
                for (try config.validMarks(io, a, env, &cfg)) |mark| {
                    const value = try std.fmt.allocPrint(a, "{d}", .{mark.index});
                    if (std.mem.startsWith(u8, value, current)) try items.append(a, .{ .value = value, .help = std.fs.path.basename(mark.path) });
                }
            }
        }
    }
    if (!escaped or !positional_used) try optionCandidates(a, &items, id, current);
    return items.toOwnedSlice(a);
}

fn subcommands(a: A, items: *std.ArrayList(Candidate), id: spec.Id, prefix: []const u8, include_help: bool) !void {
    if (id != .root and id != .marks and id != .config) return;
    for (spec.specs) |s| if (s.parent == id and !spec.isHelp(s.id) and std.mem.startsWith(u8, s.name, prefix)) {
        try items.append(a, .{ .value = s.name, .help = s.about });
    };
    if (include_help and std.mem.startsWith(u8, "help", prefix)) try items.append(a, .{ .value = "help", .help = "Print this message or the help of the given subcommand(s)" });
}

fn valueCandidates(a: A, items: *std.ArrayList(Candidate), o: spec.Option, prefix: []const u8, added: []const u8) !void {
    for (spec.values(o.kind)) |value| if (std.mem.startsWith(u8, value, prefix)) {
        try items.append(a, .{ .value = try std.mem.concat(a, u8, &.{ added, value }) });
    };
}

fn optionCandidates(a: A, items: *std.ArrayList(Candidate), id: spec.Id, prefix: []const u8) !void {
    if (std.mem.startsWith(u8, prefix, "--")) if (std.mem.indexOfScalar(u8, prefix, '=')) |equal| {
        if (option(id, prefix)) |o| try valueCandidates(a, items, o, prefix[equal + 1 ..], prefix[0 .. equal + 1]);
        return;
    };
    var options: std.ArrayList(spec.Option) = .empty;
    try options.appendSlice(a, spec.get(id).options);
    try options.append(a, spec.help_option);
    if (id == .root) try options.append(a, spec.version_option);
    const short = std.mem.startsWith(u8, prefix, "-") and !std.mem.startsWith(u8, prefix, "--");
    if (prefix.len > 1 and short) {
        if (option(id, prefix)) |o| if (o.kind != .flag) {
            try valueCandidates(a, items, o, prefix[2..], prefix[0..2]);
            return;
        };
    }
    for (options.items) |o| {
        if (short) {
            if (o.short) |ch| {
                try items.append(a, .{ .value = try std.fmt.allocPrint(a, "{s}{c}", .{ prefix, ch }), .help = o.about });
            } else if (prefix.len == 1) try items.append(a, .{ .value = try std.fmt.allocPrint(a, "--{s}", .{o.long}), .help = o.about });
        } else {
            const value = try std.fmt.allocPrint(a, "--{s}", .{o.long});
            if (std.mem.startsWith(u8, value, prefix)) try items.append(a, .{ .value = value, .help = o.about });
        }
    }
}

fn shQuote(a: A, value: []const u8) ![]const u8 {
    var safe = value.len != 0;
    for (value) |ch| if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "@%_-+=:,./", ch) == null) {
        safe = false;
    };
    if (safe) return value;
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.writeByte('\'');
    for (value) |ch| if (ch == '\'') {
        try out.writer.writeAll("'\"'\"'");
    } else try out.writer.writeByte(ch);
    try out.writer.writeByte('\'');
    return out.toOwnedSlice();
}

fn registration(a: A, shell: Shell, executable: []const u8) ![]const u8 {
    const bin = try shQuote(a, std.fs.path.basename(executable));
    const quoted = try shQuote(a, executable);
    const template = switch (shell) {
        .bash => @embedFile("registration/bash"),
        .elvish => @embedFile("registration/elvish"),
        .fish => @embedFile("registration/fish"),
        .powershell => @embedFile("registration/powershell"),
        .zsh => @embedFile("registration/zsh"),
    };
    const with_bin = try std.mem.replaceOwned(u8, a, template, "@BIN@", bin);
    const script = try std.mem.replaceOwned(u8, a, with_bin, "@COMPLETER@", quoted);
    return switch (shell) {
        .bash, .elvish => std.mem.concat(a, u8, &.{ script, "\n" }),
        .powershell => std.mem.concat(a, u8, &.{ script, "        \n" }),
        else => script,
    };
}

test "static completion order, values, prefixes, and multi-value arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: Env = .init(a);
    const root = try candidates(std.testing.io, a, &.{ "tms", "" }, 1, &env);
    try std.testing.expectEqual(@as(usize, 16), root.len);
    try std.testing.expectEqualStrings("config", root[0].value);
    try std.testing.expectEqualStrings("--version", root[15].value);
    const bools = try candidates(std.testing.io, a, &.{ "tms", "config", "--full-path", "" }, 3, &env);
    try std.testing.expectEqual(@as(usize, 2), bools.len);
    try std.testing.expectEqualStrings("true", bools[0].value);
    const inline_value = try candidates(std.testing.io, a, &.{ "tms", "config", "--session-sort-order=L" }, 2, &env);
    try std.testing.expectEqualStrings("--session-sort-order=LastAttached", inline_value[0].value);
    const multi = try candidates(std.testing.io, a, &.{ "tms", "config", "--paths", "code", "" }, 4, &env);
    try std.testing.expectEqualStrings("list", multi[0].value);
}

test "equals in short flag clusters preserves short-option completions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: Env = .init(a);
    const root = try candidates(std.testing.io, a, &.{ "tms", "-h=x" }, 1, &env);
    try std.testing.expectEqual(@as(usize, 2), root.len);
    try std.testing.expectEqualStrings("-h=xh", root[0].value);
    try std.testing.expectEqualStrings("-h=xV", root[1].value);
    const config_items = try candidates(std.testing.io, a, &.{ "tms", "config", "-h=x" }, 2, &env);
    try std.testing.expectEqual(@as(usize, 4), config_items.len);
    try std.testing.expectEqualStrings("-h=xp", config_items[0].value);
    try std.testing.expectEqualStrings("-h=xh", config_items[3].value);
    const marks = try candidates(std.testing.io, a, &.{ "tms", "marks", "-h=x" }, 2, &env);
    try std.testing.expectEqual(@as(usize, 1), marks.len);
    try std.testing.expectEqualStrings("-h=xh", marks[0].value);
}
