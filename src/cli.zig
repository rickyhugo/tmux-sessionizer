const std = @import("std");
const config = @import("config");
const A = std.mem.Allocator;
const Io = std.Io;
const spec = @import("cli/spec.zig");
const completion = @import("cli/completion.zig");
const suggestions = @import("cli/suggestions.zig");

pub const Diagnostic = struct { text: []const u8, exit_code: u8 = 2 };
pub const ParseResult = union(enum) { command: Command, diagnostic: Diagnostic };
pub threadlocal var failure: ?Diagnostic = null;

pub const ConfigCommand = union(enum) { edit: config.SettingsEdit, list: struct { defaults: bool } };
pub const MarksCommand = union(enum) {
    list,
    set: struct { index: ?usize, path: ?[]const u8 },
    open: usize,
    delete: usize,
    clear,
};
pub const Command = union(enum) {
    pick,
    config: ConfigCommand,
    start,
    switch_session,
    windows,
    kill,
    sessions,
    rename: []const u8,
    refresh: ?[]const u8,
    clone_repo: struct { repository: []const u8, path: ?[]const u8, name: ?[]const u8 },
    init_repo: []const u8,
    bookmark: struct { delete: bool, path: ?[]const u8 },
    open_session: []const u8,
    marks: MarksCommand,
    help: []const []const u8,
    version,
};

pub fn parse(a: A, args: []const []const u8) anyerror!Command {
    failure = null;
    return switch (try parseDetailed(a, args)) {
        .command => |command| command,
        .diagnostic => |diagnostic| {
            failure = diagnostic;
            return error.InvalidArguments;
        },
    };
}

pub fn help(a: A, path: []const []const u8) anyerror![]const u8 {
    var id: spec.Id = .root;
    for (path) |part| id = spec.child(id, part) orelse return error.UnknownCommand;
    return spec.help(a, id);
}

pub fn complete(io: Io, a: A, args: []const []const u8, env: *const std.process.Environ.Map) anyerror!bool {
    failure = null;
    return completion.complete(io, a, args, env) catch |err| {
        const message = switch (err) {
            error.UnknownCompletionShell => try std.fmt.allocPrint(a, "unknown shell `{s}`, expected one of `bash`, `elvish`, `fish`, `powershell`, `zsh`", .{std.fs.path.stem(std.fs.path.basename(env.get("COMPLETE").?))}),
            error.NoCompletionGenerated => "no completion generated",
            else => return err,
        };
        failure = .{ .exit_code = 101, .text = try std.fmt.allocPrint(a, "\npanic:\nfailed to generate completions: error: {s}\nnote: run with `RUST_BACKTRACE=1` environment variable to display a backtrace\n", .{message}) };
        return err;
    };
}

pub fn parseDetailed(a: A, args: []const []const u8) !ParseResult {
    var parser: Parser = .{ .a = a, .args = args };
    const command = parser.run() catch |err| switch (err) {
        error.InvalidArguments => return .{ .diagnostic = .{ .text = parser.message.? } },
        else => return err,
    };
    return .{ .command = command };
}

const Parser = struct {
    a: A,
    args: []const []const u8,
    id: spec.Id = .root,
    values: std.EnumArray(spec.OptionId, ?[]const []const u8) = .initFill(null),
    positional: ?[]const u8 = null,
    message: ?[]const u8 = null,
    first_option: ?spec.Option = null,
    pending_group: bool = false,
    resolved_group: bool = false,

    fn fail(p: *Parser, comptime fmt: []const u8, args: anytype) anyerror {
        p.message = std.fmt.allocPrint(p.a, fmt, args) catch return error.OutOfMemory;
        return error.InvalidArguments;
    }
    fn usageError(p: *Parser, text: []const u8) anyerror {
        const usage = spec.usage(p.a, p.id) catch return error.OutOfMemory;
        return p.fail("error: {s}\n\nUsage: {s}\n{s}", .{ text, usage, if (spec.isHelp(p.id)) "" else "\nFor more information, try '--help'.\n" });
    }
    fn unexpected(p: *Parser, value: []const u8) anyerror {
        const text = std.fmt.allocPrint(p.a, "unexpected argument '{s}' found{s}", .{ value, if (spec.get(p.id).positional != null and std.mem.startsWith(u8, value, "-")) std.fmt.allocPrint(p.a, "\n\n  tip: to pass '{s}' as a value, use '-- {s}'", .{ value, value }) catch return error.OutOfMemory else "" }) catch return error.OutOfMemory;
        return p.usageError(text);
    }
    fn optionUsage(p: *Parser, suggested: ?spec.Option) ![]const u8 {
        var labels: std.ArrayList([]const u8) = .empty;
        for (spec.get(p.id).options) |o| {
            if (p.id == .marks_delete and o.id == .all) continue;
            if (p.flag(o.id) or (suggested != null and suggested.?.id == o.id)) try labels.append(p.a, try spec.label(p.a, o));
        }
        if (suggested) |o| if (o.id == .help or o.id == .version) {
            try labels.append(p.a, try spec.label(p.a, o));
        };
        if (labels.items.len == 0) return spec.usage(p.a, p.id);
        std.mem.sort([]const u8, labels.items, {}, struct {
            fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.lessThan(u8, lhs, rhs);
            }
        }.lessThan);
        return std.fmt.allocPrint(p.a, "{s} {s}{s}", .{ try spec.invocation(p.a, p.id), try std.mem.join(p.a, " ", labels.items), try spec.positionalUsage(p.a, p.id) });
    }
    fn unexpectedLong(p: *Parser, name: []const u8) anyerror {
        var names: std.ArrayList([]const u8) = .empty;
        for (spec.get(p.id).options) |o| try names.append(p.a, o.long);
        try names.append(p.a, spec.help_option.long);
        if (p.id == .root) try names.append(p.a, spec.version_option.long);
        const similar = try suggestions.best(p.a, name, names.items);
        const suggested = if (similar) |long| spec.findOption(p.id, .{ .long = long }) else null;
        const hint = if (similar) |long|
            try std.fmt.allocPrint(p.a, "\n\n  tip: a similar argument exists: '--{s}'", .{long})
        else if (spec.get(p.id).positional != null)
            try std.fmt.allocPrint(p.a, "\n\n  tip: to pass '--{f}' as a value, use '-- --{f}'", .{ std.unicode.fmtUtf8(name), std.unicode.fmtUtf8(name) })
        else
            "";
        return p.fail("error: unexpected argument '--{f}' found{s}\n\nUsage: {s}\n\nFor more information, try '--help'.\n", .{ std.unicode.fmtUtf8(name), hint, try p.optionUsage(suggested) });
    }
    fn unexpectedValue(p: *Parser, o: spec.Option, value: []const u8) anyerror {
        // Attached flag errors include resolved argument groups, not a pending value.
        const group = p.resolved_group or p.id == .marks_delete;
        const suffix = if (group) try std.fmt.allocPrint(p.a, " {s}", .{try spec.argumentGroup(p.a, p.id)}) else try spec.positionalUsage(p.a, p.id);
        const flag_usage = if (p.id == .marks_delete and o.id == .all) "" else try std.fmt.allocPrint(p.a, " --{s}", .{o.long});
        return p.fail("error: unexpected value '{f}' for '--{s}' found; no more were expected\n\nUsage: {s}{s}{s}\n\nFor more information, try '--help'.\n", .{ std.unicode.fmtUtf8(value), o.long, try spec.invocation(p.a, p.id), flag_usage, suffix });
    }
    fn validateUtf8(p: *Parser, value: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(value)) return p.usageError("invalid UTF-8 was detected in one or more arguments");
    }
    fn number(p: *Parser, value: []const u8, label: []const u8) !usize {
        return config.parseIndex(value) catch {
            const reason = if (value.len == 0) "cannot parse integer from empty string" else blk: {
                const s = if (value[0] == '+') value[1..] else value;
                if (s.len == 0) break :blk "invalid digit found in string";
                for (s) |ch| if (!std.ascii.isDigit(ch)) break :blk "invalid digit found in string";
                break :blk "number too large to fit in target type";
            };
            return p.fail("error: invalid value '{s}' for '{s}': {s}\n\nFor more information, try '--help'.\n", .{ value, label, reason });
        };
    }
    fn validate(p: *Parser, o: spec.Option, value: []const u8) !void {
        // Clap's possible-value parser reports lossy text; other values require UTF-8.
        if (spec.values(o.kind).len == 0) try p.validateUtf8(value);
        const label = try spec.label(p.a, o);
        if (o.kind == .uints) {
            _ = try p.number(value, label);
        } else if (o.kind == .color) {
            _ = config.parseColor(value) catch return p.fail("error: invalid value '{s}' for '{s}': Failed to parse Colors\n\nFor more information, try '--help'.\n", .{ value, label });
        } else {
            const possible = spec.values(o.kind);
            if (possible.len == 0) return;
            for (possible) |candidate| if (std.mem.eql(u8, value, candidate)) return;
            const similar = try suggestions.best(p.a, value, possible);
            return p.fail("error: invalid value '{f}' for '{s}'\n  [possible values: {s}]\n{s}\nFor more information, try '--help'.\n", .{
                std.unicode.fmtUtf8(value),                                                                             label, try std.mem.join(p.a, ", ", possible),
                if (similar) |s| try std.fmt.allocPrint(p.a, "\n  tip: a similar value exists: '{s}'\n", .{s}) else "",
            });
        }
    }
    fn store(p: *Parser, o: spec.Option, values: []const []const u8) !void {
        const previous = p.values.get(o.id);
        if (previous != null and !o.many()) return p.usageError(try std.fmt.allocPrint(p.a, "the argument '{s}' cannot be used multiple times", .{try spec.label(p.a, o)}));
        for (values) |value| try p.validate(o, value);
        p.values.set(o.id, if (previous) |v| try std.mem.concat(p.a, []const u8, &.{ v, values }) else values);
        if (p.first_option == null) p.first_option = o;
        if (o.kind == .flag) p.resolved_group = true else p.pending_group = true;
    }
    fn one(p: *Parser, id: spec.OptionId) ?[]const u8 {
        const vals = p.values.get(id) orelse return null;
        if (vals.len == 0) return null;
        return vals[0];
    }
    fn flag(p: *Parser, id: spec.OptionId) bool {
        return p.values.get(id) != null;
    }
    fn boolean(p: *Parser, id: spec.OptionId) ?bool {
        return if (p.one(id)) |v| std.mem.eql(u8, v, "true") else null;
    }
    fn run(p: *Parser) anyerror!Command {
        var i: usize = 0;
        var literal = false;
        while (i < p.args.len) : (i += 1) {
            const arg = p.args[i];
            if (!literal and std.mem.eql(u8, arg, "--")) {
                literal = true;
                continue;
            }
            if (!literal and arg.len > 1 and arg[0] == '-') {
                var cursor: usize = 1;
                const long = arg[1] == '-';
                while (cursor < arg.len) {
                    const eq = if (long) std.mem.indexOfScalar(u8, arg, '=') else null;
                    const o = spec.findOption(p.id, if (long) .{ .long = arg[2 .. eq orelse arg.len] } else .{ .short = arg[cursor] });
                    const selected = o orelse return if (long) p.unexpectedLong(arg[2 .. eq orelse arg.len]) else p.unexpected(try std.fmt.allocPrint(p.a, "-{c}", .{arg[cursor]}));
                    if (eq) |n| if (selected.kind == .flag) return p.unexpectedValue(selected, arg[n + 1 ..]);
                    if (p.pending_group) {
                        p.resolved_group = true;
                        p.pending_group = false;
                    }
                    if (selected.id == .help) return .{ .help = try spec.path(p.a, p.id) };
                    if (selected.id == .version) return .version;
                    if (selected.kind == .flag) {
                        if (eq != null) return p.unexpected(arg);
                        try p.store(selected, &.{});
                        if (long) break;
                        cursor += 1;
                        continue;
                    }
                    var vals: std.ArrayList([]const u8) = .empty;
                    const attached = if (long) if (eq) |n| arg[n + 1 ..] else null else if (cursor + 1 < arg.len) arg[cursor + 1 + @intFromBool(arg[cursor + 1] == '=') ..] else null;
                    if (attached) |v| try vals.append(p.a, v);
                    if (attached == null or selected.many()) {
                        while (i + 1 < p.args.len) {
                            const next = p.args[i + 1];
                            if (next.len > 1 and next[0] == '-') {
                                if (vals.items.len == 0) {
                                    if (std.mem.eql(u8, next, "--")) {
                                        if (p.id == .config and i + 2 < p.args.len) {
                                            const command = p.args[i + 2];
                                            if (p.first_option) |first| return p.usageError(try std.fmt.allocPrint(p.a, "the subcommand '{s}' cannot be used with '{s}'", .{ command, try spec.label(p.a, first) }));
                                            return p.usageError(try std.fmt.allocPrint(p.a, "the subcommand '{s}' cannot be used with one or more of the other specified arguments", .{command}));
                                        }
                                    } else if (std.mem.startsWith(u8, next, "--")) {
                                        const next_eq = std.mem.indexOfScalar(u8, next, '=');
                                        const name = next[2 .. next_eq orelse next.len];
                                        const next_option = spec.findOption(p.id, .{ .long = name }) orelse return p.unexpectedLong(name);
                                        if (next_eq) |n| if (next_option.kind == .flag) return p.unexpectedValue(next_option, next[n + 1 ..]);
                                    } else if (spec.findOption(p.id, .{ .short = next[1] }) == null) {
                                        return p.unexpected(try std.fmt.allocPrint(p.a, "-{c}", .{next[1]}));
                                    }
                                }
                                break;
                            }
                            if (vals.items.len != 0 and !selected.many()) break;
                            i += 1;
                            try vals.append(p.a, next);
                        }
                    }
                    if (vals.items.len == 0) {
                        const possible = spec.values(selected.kind);
                        return p.fail("error: a value is required for '{s}' but none was supplied{s}\n\nFor more information, try '--help'.\n", .{ try spec.label(p.a, selected), if (possible.len == 0) "" else try std.fmt.allocPrint(p.a, "\n  [possible values: {s}]", .{try std.mem.join(p.a, ", ", possible)}) });
                    }
                    try p.store(selected, try vals.toOwnedSlice(p.a));
                    break;
                }
                continue;
            }
            if (!literal) {
                if (std.mem.eql(u8, arg, "help") and (p.id == .root or p.id == .config or p.id == .marks)) {
                    for (p.args[i + 1 ..]) |part| p.id = spec.child(p.id, part) orelse return p.usageError(try std.fmt.allocPrint(p.a, "unrecognized subcommand '{s}'", .{part}));
                    return .{ .help = try spec.path(p.a, p.id) };
                }
                if (spec.child(p.id, arg)) |child| {
                    if (p.first_option) |first| return p.usageError(try std.fmt.allocPrint(p.a, "the subcommand '{s}' cannot be used with '{s}'", .{ arg, try spec.label(p.a, first) }));
                    if (p.positional) |_| return p.usageError(try std.fmt.allocPrint(p.a, "the subcommand '{s}' cannot be used with '[INDEX]'", .{arg}));
                    p.id = child;
                    continue;
                }
            }
            const s = spec.get(p.id);
            if (s.positional == null) {
                if (p.id == .config) if (p.first_option) |first| return p.usageError(try std.fmt.allocPrint(p.a, "the subcommand '{s}' cannot be used with '{s}'", .{ arg, try spec.label(p.a, first) }));
                if (literal and spec.child(p.id, arg) != null) return p.usageError(try std.fmt.allocPrint(p.a, "unexpected argument '{s}' found\n\n  tip: subcommand '{s}' exists; to use it, remove the '--' before it", .{ arg, arg }));
                if (p.id == .root or p.id == .config) return p.usageError(try std.fmt.allocPrint(p.a, "unrecognized subcommand '{s}'", .{arg}));
                return p.unexpected(arg);
            }
            if (p.positional != null) return p.unexpected(arg);
            try p.validateUtf8(arg);
            if (std.mem.eql(u8, s.positional.?, "INDEX")) _ = try p.number(arg, if (s.required) "<INDEX>" else "[INDEX]");
            p.positional = arg;
            p.pending_group = true;
        }
        const s = spec.get(p.id);
        if ((p.id == .config and p.first_option == null) or (p.id == .rename and p.positional == null)) return p.fail("{s}", .{try spec.help(p.a, p.id)});
        if ((s.required and p.positional == null) or (p.id == .marks_delete and p.positional == null and !p.flag(.all))) {
            const name = if (p.id == .marks_delete) "INDEX|--all" else s.positional.?;
            return p.fail("error: the following required arguments were not provided:\n  <{s}>\n\nUsage: {s} <{s}>\n\nFor more information, try '--help'.\n", .{ name, try spec.invocation(p.a, p.id), name });
        }
        if (p.id == .marks_delete and p.positional != null and p.flag(.all)) return p.usageError("the argument '[INDEX]' cannot be used with '--all'");
        return switch (p.id) {
            .root => .pick,
            .config => .{ .config = .{ .edit = try p.settings() } },
            .config_list => .{ .config = .{ .list = .{ .defaults = p.flag(.defaults) } } },
            .start => .start,
            .switch_session => .switch_session,
            .windows => .windows,
            .kill => .kill,
            .sessions => .sessions,
            .rename => .{ .rename = p.positional.? },
            .refresh => .{ .refresh = p.positional },
            .clone_repo => .{ .clone_repo = .{ .repository = p.positional.?, .path = p.one(.path), .name = p.one(.name) } },
            .init_repo => .{ .init_repo = p.positional.? },
            .bookmark => .{ .bookmark = .{ .delete = p.flag(.delete), .path = p.positional } },
            .open_session => .{ .open_session = p.positional.? },
            .marks => .{ .marks = if (p.positional) |v| .{ .open = try config.parseIndex(v) } else .list },
            .marks_list => .{ .marks = .list },
            .marks_set => .{ .marks = .{ .set = .{ .index = if (p.positional) |v| try config.parseIndex(v) else null, .path = p.one(.path) } } },
            .marks_open => .{ .marks = .{ .open = try config.parseIndex(p.positional.?) } },
            .marks_delete => .{ .marks = if (p.flag(.all)) .clear else .{ .delete = try config.parseIndex(p.positional.?) } },
            .help, .config_help, .marks_help => .{ .help = try spec.path(p.a, p.id) },
        };
    }
    fn settings(p: *Parser) !config.SettingsEdit {
        var result: config.SettingsEdit = .{
            .paths = p.values.get(.paths),
            .default_session = p.one(.session),
            .excluded = p.values.get(.excluded),
            .remove = p.values.get(.remove),
            .display_full_path = p.boolean(.full_path),
            .search_submodules = p.boolean(.search_submodules),
            .recursive_submodules = p.boolean(.recursive_submodules),
            .switch_filter_unknown = p.boolean(.switch_filter_unknown),
            .list_worktrees = p.boolean(.enable_list_worktrees),
        };
        if (p.values.get(.max_depths)) |values| {
            const depths = try p.a.alloc(usize, values.len);
            for (values, depths) |v, *depth| depth.* = try config.parseIndex(v);
            result.max_depths = depths;
        }
        var colors: config.PickerColors = .{};
        var has_colors = false;
        inline for (.{ "highlight_color", "highlight_text_color", "border_color", "info_color", "prompt_color" }, .{ spec.OptionId.picker_highlight_color, .picker_highlight_text_color, .picker_border_color, .picker_info_color, .picker_prompt_color }) |field, id| {
            if (p.one(id)) |value| {
                @field(colors, field) = try config.parseColor(value);
                has_colors = true;
            }
        }
        if (has_colors) result.picker_colors = colors;
        if (p.one(.session_sort_order)) |value| result.session_sort_order = if (std.mem.eql(u8, value, "Alphabetical")) .alphabetical else .last_attached;
        if (p.one(.clone_repo_switch)) |value| result.clone_repo_switch = if (std.mem.eql(u8, value, "Always")) .always else if (std.mem.eql(u8, value, "Never")) .never else .foreground;
        return result;
    }
};

test "typed CLI commands preserve absent values and literal strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(Command.pick, try parse(a, &.{}));
    const edit = (try parse(a, &.{ "config", "-p", "路径", "~/code", "-d2", "--excluded=vendor*", "--full-path", "false" })).config.edit;
    try std.testing.expectEqualStrings("路径", edit.paths.?[0]);
    try std.testing.expectEqualStrings("vendor*", edit.excluded.?[0]);
    try std.testing.expectEqual(@as(usize, 2), edit.max_depths.?[0]);
    try std.testing.expectEqual(false, edit.display_full_path.?);
    try std.testing.expect(edit.search_submodules == null);
    try std.testing.expectEqualStrings("-project", (try parse(a, &.{ "open-session", "--", "-project" })).open_session);
    try std.testing.expectEqual(@as(usize, 3), (try parse(a, &.{ "marks", "+3" })).marks.open);
    try std.testing.expect((try parse(a, &.{ "marks", "delete", "-a" })).marks == .clear);
    try std.testing.expectEqualStrings("a", (try parse(a, &.{ "clone-repo", "--path=a", "--name", "b", "url" })).clone_repo.path.?);
}

test "CLI diagnostics reject invalid values and conflicting commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][]const []const u8{
        &.{"unknown"},                                      &.{"--unknown"},                               &.{"config"},                         &.{"rename"},                          &.{"clone-repo"},                     &.{"open-session"},
        &.{ "marks", "-1" },                                &.{ "marks", "set", "abc" },                   &.{ "marks", "delete" },              &.{ "marks", "delete", "1", "--all" }, &.{ "config", "--full-path", "yes" }, &.{ "config", "--session-sort-order", "alphabetical" },
        &.{ "config", "--picker-border-color", "invalid" }, &.{ "config", "--full-path", "true", "list" }, &.{ "config", "--max-depths", "-1" },
    };
    for (cases) |args| {
        const result = try parseDetailed(a, args);
        try std.testing.expect(result == .diagnostic);
        try std.testing.expectEqual(@as(u8, 2), result.diagnostic.exit_code);
        try std.testing.expect(result.diagnostic.text.len > 20);
    }
    const result = try parseDetailed(a, &.{"unknown"});
    try std.testing.expectEqualStrings("error: unrecognized subcommand 'unknown'\n\nUsage: tms [COMMAND]\n\nFor more information, try '--help'.\n", result.diagnostic.text);
    try std.testing.expectError(error.InvalidArguments, parse(a, &.{"unknown"}));
    try std.testing.expectEqual(@as(u8, 2), failure.?.exit_code);
    _ = try parse(a, &.{"--help"});
    try std.testing.expect(failure == null);
    var env: std.process.Environ.Map = .init(a);
    try env.put("COMPLETE", "unsupported");
    try std.testing.expectError(error.UnknownCompletionShell, complete(std.testing.io, a, &.{"tms"}, &env));
    try std.testing.expectEqual(@as(u8, 101), failure.?.exit_code);
    try env.put("COMPLETE", "0");
    try std.testing.expectEqual(false, try complete(std.testing.io, a, &.{"tms"}, &env));
    try std.testing.expect(failure == null);
}

test "CLI rejects invalid UTF-8 values with command-specific usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { args: []const []const u8, id: spec.Id }{
        .{ .args = &.{ "bookmark", "invalid-\xff" }, .id = .bookmark },
        .{ .args = &.{ "bookmark", "--", "\xff" }, .id = .bookmark },
        .{ .args = &.{ "config", "--session", "invalid-\xff" }, .id = .config },
        .{ .args = &.{ "config", "--session=\xff" }, .id = .config },
        .{ .args = &.{ "config", "-s\xff" }, .id = .config },
        .{ .args = &.{ "config", "--paths", "valid", "\xff" }, .id = .config },
        .{ .args = &.{ "config", "--max-depths", "\xff" }, .id = .config },
        .{ .args = &.{ "marks", "open", "\xff" }, .id = .marks_open },
    };
    for (cases) |case| {
        const result = try parseDetailed(a, case.args);
        try std.testing.expect(result == .diagnostic);
        try std.testing.expectEqual(@as(u8, 2), result.diagnostic.exit_code);
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "error: invalid UTF-8 was detected in one or more arguments\n\nUsage: {s}\n\nFor more information, try '--help'.\n", .{try spec.usage(a, case.id)}), result.diagnostic.text);
    }
}

test "CLI diagnostics retain help targets and end-marker context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { args: []const []const u8, text: []const u8 }{
        .{
            .args = &.{ "help", "config", "--help" },
            .text = "error: unrecognized subcommand '--help'\n\nUsage: tms config [OPTIONS]\n       tms config <COMMAND>\n\nFor more information, try '--help'.\n",
        },
        .{
            .args = &.{ "help", "marks", "--help" },
            .text = "error: unrecognized subcommand '--help'\n\nUsage: tms marks [INDEX]\n       tms marks <COMMAND>\n\nFor more information, try '--help'.\n",
        },
        .{
            .args = &.{ "help", "help", "config" },
            .text = "error: unrecognized subcommand 'config'\n\nUsage: tms help [COMMAND]...\n",
        },
        .{
            .args = &.{ "config", "--", "list" },
            .text = "error: unexpected argument 'list' found\n\n  tip: subcommand 'list' exists; to use it, remove the '--' before it\n\nUsage: tms config [OPTIONS]\n       tms config <COMMAND>\n\nFor more information, try '--help'.\n",
        },
        .{
            .args = &.{ "config", "--paths", "--" },
            .text = "error: a value is required for '--paths <search paths>...' but none was supplied\n\nFor more information, try '--help'.\n",
        },
        .{
            .args = &.{ "config", "--full-path", "true", "--", "list" },
            .text = "error: the subcommand 'list' cannot be used with '--full-path <true | false>'\n\nUsage: tms config [OPTIONS]\n       tms config <COMMAND>\n\nFor more information, try '--help'.\n",
        },
        .{
            .args = &.{ "config", "--full-path", "\xff" },
            .text = "error: invalid value '�' for '--full-path <true | false>'\n  [possible values: true, false]\n\nFor more information, try '--help'.\n",
        },
    };
    for (cases) |case| {
        const result = try parseDetailed(a, case.args);
        try std.testing.expect(result == .diagnostic);
        try std.testing.expectEqual(@as(u8, 2), result.diagnostic.exit_code);
        try std.testing.expectEqualStrings(case.text, result.diagnostic.text);
    }
}
