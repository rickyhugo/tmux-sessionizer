const std = @import("std");
const A = std.mem.Allocator;
const Io = std.Io;
const Env = std.process.Environ.Map;
const toml = @import("config/toml.zig");
const builtin = @import("builtin");
const unicode = @import("config/unicode_alphanumeric.zig");

pub const VcsProvider = enum { git, jujutsu };
pub const Order = enum { alphabetical, last_attached };
pub const CloneSwitch = enum { always, never, foreground };
pub const InputPosition = enum { top, bottom };
pub const SearchDirectory = struct { path: []const u8, depth: usize };
pub const StartupSession = struct {
    name: ?[]const u8 = null,
    path: ?[]const u8 = null,
    windows: ?[]const Window = null,
};
pub const Window = struct {
    name: ?[]const u8 = null,
    path: ?[]const u8 = null,
    panes: ?[]const Pane = null,
    command: ?[]const u8 = null,
};
pub const Pane = struct {};
pub const SessionConfig = struct { create_script: ?[]const u8 = null };
pub const Mark = struct { index: usize, path: []const u8 };
pub const Color = union(enum) {
    reset,
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    gray,
    dark_gray,
    light_red,
    light_green,
    light_yellow,
    light_blue,
    light_magenta,
    light_cyan,
    white,
    indexed: u8,
    rgb: struct { r: u8, g: u8, b: u8 },
};
pub const PickerColors = struct {
    highlight_color: ?Color = null,
    highlight_text_color: ?Color = null,
    border_color: ?Color = null,
    info_color: ?Color = null,
    prompt_color: ?Color = null,
};
pub const KeyCode = union(enum) {
    char: u21,
    function: u8,
    esc,
    enter,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    back_tab,
    backspace,
    delete,
    insert,
    tab,
};
pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    hyper: bool = false,
    meta: bool = false,
    padding: u2 = 0,
};
pub const Key = struct { code: KeyCode, modifiers: Modifiers = .{} };
pub const PickerAction = enum {
    noop,
    cancel,
    confirm,
    backspace,
    delete,
    move_up,
    move_down,
    cursor_left,
    cursor_right,
    delete_word,
    delete_to_line_start,
    delete_to_line_end,
    move_to_line_start,
    move_to_line_end,
};
pub const Binding = struct { key: Key, action: PickerAction };
pub const PickerOptions = struct {
    colors: PickerColors,
    input_position: InputPosition,
    bindings: []const Binding,
};
pub const Config = struct {
    default_session: ?[]const u8 = null,
    display_full_path: ?bool = null,
    search_submodules: ?bool = null,
    recursive_submodules: ?bool = null,
    switch_filter_unknown: ?bool = null,
    session_sort_order: ?Order = null,
    excluded_dirs: ?[]const []const u8 = null,
    search_paths: ?[]const []const u8 = null,
    search_dirs: ?[]const SearchDirectory = null,
    sessions: ?[]const StartupSession = null,
    picker_colors: ?PickerColors = null,
    input_position: ?InputPosition = null,
    shortcuts: ?[]const Binding = null,
    bookmarks: ?[]const []const u8 = null,
    session_configs: ?std.StringHashMapUnmanaged(SessionConfig) = null,
    marks: ?std.StringHashMapUnmanaged([]const u8) = null,
    clone_repo_switch: ?CloneSwitch = null,
    vcs_providers: ?[]const VcsProvider = null,
    list_worktrees: ?bool = null,
};
pub const SettingsEdit = struct {
    paths: ?[]const []const u8 = null,
    max_depths: ?[]const usize = null,
    default_session: ?[]const u8 = null,
    excluded: ?[]const []const u8 = null,
    remove: ?[]const []const u8 = null,
    display_full_path: ?bool = null,
    search_submodules: ?bool = null,
    recursive_submodules: ?bool = null,
    switch_filter_unknown: ?bool = null,
    picker_colors: ?PickerColors = null,
    session_sort_order: ?Order = null,
    clone_repo_switch: ?CloneSwitch = null,
    list_worktrees: ?bool = null,
};
pub const Edit = union(enum) {
    settings: SettingsEdit,
    add_bookmark: []const u8,
    delete_bookmark: []const u8,
    set_mark: struct { index: ?usize, path: []const u8 },
    delete_mark: usize,
    clear_marks,
};
pub const Diagnostic = struct { text: []const u8, exit_code: u8 = 1 };
pub const LoadResult = union(enum) { config: Config, diagnostic: Diagnostic };
pub threadlocal var failure: ?Diagnostic = null;

pub fn load(io: Io, a: A, env: *const Env) anyerror!Config {
    failure = null;
    var message: ?[]const u8 = null;
    return loadInternal(io, a, env, &message) catch |err| {
        if (err != error.OutOfMemory and err != error.Canceled) failure = .{ .text = message orelse try std.fmt.allocPrint(a, "Error: Config Error\n├─▶ Could not load configuration\n╰─▶ {s}\n", .{@errorName(err)}) };
        return err;
    };
}

pub fn loadDetailed(io: Io, a: A, env: *const Env) !LoadResult {
    const config = load(io, a, env) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return err;
        return .{ .diagnostic = failure.? };
    };
    return .{ .config = config };
}

fn loadInternal(io: Io, a: A, env: *const Env, diagnostic: ?*?[]const u8) anyerror!Config {
    var tree: toml.Value = .{ .table = .empty };
    var source: []const u8 = "";
    if (env.get("TMS_CONFIG_FILE")) |path| {
        if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidConfigEnvironment;
        source = path;
        if (!try loadFile(io, a, &tree, path, diagnostic)) {
            source = try std.fmt.allocPrint(a, "{s}.toml", .{path});
            _ = try loadFile(io, a, &tree, source, diagnostic);
        }
    } else {
        const home = try homeDir(a, env);
        const platform = try platformDir(a, env);
        if (home == null and platform == null) return error.NoConfigLocation;
        if (home) |h| {
            source = try std.fs.path.join(a, &.{ h, ".config/tms/config.toml" });
            _ = try loadFile(io, a, &tree, source, diagnostic);
        }
        if (platform) |p| {
            source = try std.fs.path.join(a, &.{ p, "tms/config.toml" });
            _ = try loadFile(io, a, &tree, source, diagnostic);
        }
    }
    var config: Config = .{};
    inline for (comptime std.meta.fieldNames(Config), comptime std.meta.fieldTypes(Config)) |name, T| {
        if (tree.table.get(name)) |v| @field(config, name) = toml.decode(T, a, v) catch |err| {
            if (diagnostic) |d| d.* = try std.fmt.allocPrint(a, "Error: Config Error\n├─▶ Could not load configuration\n│   ╰╴Could not deserialize configuration\n╰─▶ {s}\n", .{try toml.explain(T, a, v, name, try sourceName(io, a, source))});
            return err;
        };
    }
    return config;
}

pub fn commit(io: Io, a: A, env: *const Env, cfg: *Config, edit: Edit) anyerror!void {
    switch (edit) {
        .settings => |settings| {
            if (settings.paths) |paths| {
                const dirs = try a.alloc(SearchDirectory, paths.len);
                for (paths, dirs, 0..) |path, *dir, i| {
                    const trimmed = if (std.mem.endsWith(u8, path, "/")) path[0 .. path.len - 1] else path;
                    dir.* = .{
                        .path = try canonical(io, a, env, trimmed),
                        .depth = if (settings.max_depths) |depths| if (i < depths.len) depths[i] else 10 else 10,
                    };
                }
                cfg.search_dirs = dirs;
            }
            if (settings.default_session) |name| {
                const normalized = try a.dupe(u8, name);
                std.mem.replaceScalar(u8, normalized, '.', '_');
                cfg.default_session = normalized;
            }
            inline for (.{ "display_full_path", "search_submodules", "recursive_submodules", "switch_filter_unknown", "session_sort_order", "clone_repo_switch", "list_worktrees" }) |name| {
                if (@field(settings, name)) |v| @field(cfg, name) = v;
            }
            if (settings.picker_colors) |colors| {
                var current = cfg.picker_colors orelse PickerColors{};
                inline for (comptime std.meta.fieldNames(PickerColors)) |name| {
                    if (@field(colors, name)) |v| @field(current, name) = v;
                }
                cfg.picker_colors = current;
            }
            if (settings.excluded) |excluded| cfg.excluded_dirs = try std.mem.concat(a, []const u8, &.{ cfg.excluded_dirs orelse &.{}, excluded });
            if (settings.remove) |remove| {
                const current = cfg.excluded_dirs orelse return error.RemoveWithoutExclusions;
                var kept: std.ArrayList([]const u8) = .empty;
                for (current) |item| {
                    var removed = false;
                    for (remove) |r| if (std.mem.eql(u8, item, r)) {
                        removed = true;
                        break;
                    };
                    if (!removed) try kept.append(a, item);
                }
                cfg.excluded_dirs = try kept.toOwnedSlice(a);
            }
        },
        .add_bookmark => |path| {
            const items = cfg.bookmarks orelse &.{};
            var found = false;
            for (items) |item| if (std.mem.eql(u8, item, path)) {
                found = true;
                break;
            };
            if (!found) cfg.bookmarks = try std.mem.concat(a, []const u8, &.{ items, &.{path} });
        },
        .delete_bookmark => |path| if (cfg.bookmarks) |items| {
            var kept: std.ArrayList([]const u8) = .empty;
            var removed = false;
            for (items) |item| {
                if (!removed and std.mem.eql(u8, item, path)) {
                    removed = true;
                    continue;
                }
                try kept.append(a, item);
            }
            cfg.bookmarks = try kept.toOwnedSlice(a);
        },
        .set_mark => |mark| {
            const index = mark.index orelse blk: {
                const items = try validMarks(io, a, env, cfg);
                var next: usize = 0;
                for (items) |item| {
                    if (item.index != next) break;
                    next += 1;
                }
                break :blk next;
            };
            if (cfg.marks == null) cfg.marks = .empty;
            try cfg.marks.?.put(a, try std.fmt.allocPrint(a, "{d}", .{index}), mark.path);
        },
        .delete_mark => |index| if (cfg.marks) |*marks| {
            _ = marks.remove(try std.fmt.allocPrint(a, "{d}", .{index}));
        },
        .clear_marks => cfg.marks = null,
    }
    const path = env.get("TMS_CONFIG_FILE") orelse blk: {
        if (try platformDir(a, env)) |p| break :blk try std.fs.path.join(a, &.{ p, "tms/config.toml" });
        if (try homeDir(a, env)) |h| break :blk try std.fs.path.join(a, &.{ h, ".config/tms/config.toml" });
        return error.NoConfigLocation;
    };
    const text = toml.encode(a, cfg.*) catch |err| switch (err) {
        error.ConfigIntegerOutOfRange => return error.ConfigSerializationOutOfRange,
        else => return err,
    };
    if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
}

pub fn editDiagnostic(err: anyerror) ?Diagnostic {
    return switch (err) {
        error.ConfigIntegerOutOfRange => .{ .text = "Error: Config Error\n╰─▶ out-of-range value for u64 type\n" },
        error.ConfigSerializationOutOfRange => .{ .text = "Error: Config Error\n├─▶ Could not serialize config to TOML\n╰─▶ out-of-range value for u64 type\n" },
        error.RemoveWithoutExclusions => .{ .exit_code = 101, .text = "\npanic:\nnot yet implemented\nnote: run with `RUST_BACKTRACE=1` environment variable to display a backtrace\n" },
        error.MarkHasNoName => .{ .exit_code = 101, .text = "\npanic:\nThe file name doesn't end in `..`\nnote: run with `RUST_BACKTRACE=1` environment variable to display a backtrace\n" },
        error.FileNotFound => .{ .text = "Error: IO Error\n╰─▶ No such file or directory (os error 2)\n" },
        error.AccessDenied => .{ .text = "Error: IO Error\n╰─▶ Permission denied (os error 13)\n" },
        error.NoDefaultSearchPath => .{ .text = "Error: Config Error\n╰─▶ No default search path was found\n    ╰╴You must configure at least one default search path with the `config` subcommand. E.g `tms config` \n" },
        error.NoValidSearchPath => .{ .text = "Error: Config Error\n╰─▶ No valid search path was found\n    ╰╴You must configure at least one valid search path with the `config` subcommand. E.g `tms config` \n" },
        else => null,
    };
}

pub fn exportToml(a: A, cfg: *const Config, defaults: bool) anyerror![]const u8 {
    const raw = if (defaults) Config{} else cfg.*;
    const options = try pickerOptions(a, &raw);
    var exported = raw;
    exported.search_paths = null;
    exported.input_position = null;
    inline for (.{ "display_full_path", "search_submodules", "recursive_submodules", "switch_filter_unknown", "list_worktrees" }) |field| @field(exported, field) = @field(raw, field) orelse false;
    exported.session_sort_order = raw.session_sort_order orelse .alphabetical;
    exported.clone_repo_switch = raw.clone_repo_switch orelse .always;
    exported.excluded_dirs = raw.excluded_dirs orelse &.{};
    exported.search_dirs = raw.search_dirs orelse &.{};
    exported.sessions = raw.sessions orelse &.{};
    exported.bookmarks = raw.bookmarks orelse &.{};
    exported.session_configs = raw.session_configs orelse .empty;
    exported.marks = raw.marks orelse .empty;
    exported.vcs_providers = raw.vcs_providers orelse &.{.git};
    exported.picker_colors = options.colors;
    exported.shortcuts = options.bindings;
    return toml.encode(a, exported);
}

pub fn searchRoots(io: Io, a: A, env: *const Env, cfg: *const Config) anyerror![]const SearchDirectory {
    const dirs = cfg.search_dirs orelse &.{};
    const legacy = cfg.search_paths orelse &.{};
    if (dirs.len == 0 and legacy.len == 0) return error.NoDefaultSearchPath;
    var roots: std.ArrayList(SearchDirectory) = .empty;
    for (dirs) |dir| {
        const path = canonical(io, a, env, dir.path) catch continue;
        try roots.append(a, .{ .path = path, .depth = dir.depth });
    }
    for (legacy) |old| {
        const path = canonical(io, a, env, old) catch continue;
        try roots.append(a, .{ .path = path, .depth = 10 });
    }
    if (roots.items.len == 0) return error.NoValidSearchPath;
    return roots.toOwnedSlice(a);
}

pub fn bookmarkPaths(io: Io, a: A, env: *const Env, cfg: *const Config) anyerror![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    for (cfg.bookmarks orelse &.{}) |path| try paths.append(a, canonical(io, a, env, path) catch continue);
    return paths.toOwnedSlice(a);
}

pub fn validMarks(io: Io, a: A, env: *const Env, cfg: *const Config) anyerror![]const Mark {
    var marks: std.ArrayList(Mark) = .empty;
    if (cfg.marks) |map| {
        var it = map.iterator();
        while (it.next()) |entry| {
            const index = parseIndex(entry.key_ptr.*) catch continue;
            const path = canonical(io, a, env, entry.value_ptr.*) catch continue;
            if (std.mem.eql(u8, path, "/")) return error.MarkHasNoName;
            try marks.append(a, .{ .index = index, .path = path });
        }
    }
    std.mem.sort(Mark, marks.items, {}, struct {
        fn less(_: void, l: Mark, r: Mark) bool {
            return l.index < r.index;
        }
    }.less);
    return marks.toOwnedSlice(a);
}

pub fn expandPath(io: Io, a: A, env: *const Env, path: []const u8) anyerror![]const u8 {
    _ = io;
    if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidPath;
    var out: std.Io.Writer.Allocating = .init(a);
    var i: usize = 0;
    while (i < path.len) {
        if (path[i] != '$') {
            try out.writer.writeByte(path[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i < path.len and path[i] == '$') {
            try out.writer.writeByte('$');
            i += 1;
            continue;
        }
        if (i < path.len and path[i] == '{') {
            if (std.mem.indexOfScalarPos(u8, path, i + 1, '}')) |end| {
                const expression = path[i + 1 .. end];
                const split = std.mem.indexOf(u8, expression, ":-");
                const fallback = if (split) |n| if (n != 0) expression[n + 2 ..] else null else null;
                const name = if (fallback != null) expression[0..split.?] else expression;
                const value = env.get(name) orelse fallback orelse return error.MissingEnvironmentVariable;
                if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidEnvironmentVariable;
                try out.writer.writeAll(value);
                i = end + 1;
                continue;
            }
            try out.writer.writeAll("${");
            i += 1;
            continue;
        }
        const start = i;
        while (i < path.len) {
            const size = try std.unicode.utf8ByteSequenceLength(path[i]);
            const scalar = try std.unicode.utf8Decode(path[i .. i + size]);
            if (!variableCharacter(scalar)) break;
            i += size;
        }
        if (i == start) {
            try out.writer.writeByte('$');
        } else {
            const value = env.get(path[start..i]) orelse return error.MissingEnvironmentVariable;
            if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidEnvironmentVariable;
            try out.writer.writeAll(value);
        }
    }
    const expanded = try out.toOwnedSlice();
    if (path.len > 0 and path[0] == '~' and expanded.len > 0 and expanded[0] == '~' and (expanded.len == 1 or expanded[1] == '/')) {
        if (try homeDir(a, env)) |home| return std.mem.concat(a, u8, &.{ home, expanded[1..] });
    }
    return expanded;
}

fn variableCharacter(scalar: u21) bool {
    if (scalar == '_') return true;
    var low: usize = 0;
    var high: usize = unicode.ranges.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const range = unicode.ranges[mid];
        if (scalar < range[0]) {
            high = mid;
        } else if (scalar > range[1]) {
            low = mid + 1;
        } else return true;
    }
    return false;
}

pub fn setBinding(a: A, bindings: *std.ArrayList(Binding), binding: Binding) !void {
    for (bindings.items) |*old| {
        if (std.meta.eql(old.key, binding.key)) {
            old.* = binding;
            return;
        }
    }
    try bindings.append(a, binding);
}

pub fn pickerOptions(a: A, cfg: *const Config) anyerror!PickerOptions {
    var colors = cfg.picker_colors orelse PickerColors{};
    const defaults = PickerColors{ .highlight_color = .light_blue, .highlight_text_color = .black, .border_color = .dark_gray, .info_color = .light_yellow, .prompt_color = .light_green };
    inline for (comptime std.meta.fieldNames(PickerColors)) |name| @field(colors, name) = @field(colors, name) orelse @field(defaults, name);
    var bindings: std.ArrayList(Binding) = .empty;
    const names = [_][]const u8{ "ctrl-c", "esc", "enter", "delete", "ctrl-d", "backspace", "down", "ctrl-j", "ctrl-n", "up", "ctrl-k", "ctrl-p", "left", "right", "ctrl-w", "ctrl-u", "ctrl-a", "ctrl-e" };
    const actions = [_]PickerAction{ .cancel, .cancel, .confirm, .delete, .delete, .backspace, .move_down, .move_down, .move_down, .move_up, .move_up, .move_up, .cursor_left, .cursor_right, .delete_word, .delete_to_line_start, .move_to_line_start, .move_to_line_end };
    for (names, actions) |name, action| try bindings.append(a, .{ .key = try parseKey(name), .action = action });
    for (cfg.shortcuts orelse &.{}) |binding| try setBinding(a, &bindings, binding);
    return .{ .colors = colors, .input_position = cfg.input_position orelse .bottom, .bindings = try bindings.toOwnedSlice(a) };
}

pub fn parseKey(text: []const u8) anyerror!Key {
    var tokens = std.mem.splitScalar(u8, text, '-');
    var mods: Modifiers = .{};
    var last = tokens.next().?;
    while (tokens.next()) |next| {
        inline for (.{ "shift", "ctrl", "alt", "super", "hyper", "meta" }) |name| if (std.ascii.eqlIgnoreCase(last, name)) {
            @field(mods, name) = true;
        };
        last = next;
    }
    const names = .{ "esc", "enter", "left", "right", "up", "down", "home", "end", "pageup", "pagedown", "backtab", "backspace", "delete", "insert", "tab" };
    const codes = [_]KeyCode{ .esc, .enter, .left, .right, .up, .down, .home, .end, .page_up, .page_down, .back_tab, .backspace, .delete, .insert, .tab };
    inline for (names, codes) |name, code| if (std.ascii.eqlIgnoreCase(last, name)) return .{ .code = code, .modifiers = mods };
    if (std.ascii.eqlIgnoreCase(last, "del")) return .{ .code = .delete, .modifiers = mods };
    if (std.ascii.eqlIgnoreCase(last, "ins")) return .{ .code = .insert, .modifiers = mods };
    if (std.ascii.eqlIgnoreCase(last, "space")) return .{ .code = .{ .char = ' ' }, .modifiers = mods };
    if (last.len >= 2 and std.ascii.toLower(last[0]) == 'f') {
        const n = std.fmt.parseInt(u8, last[1..], 10) catch 0;
        if (n >= 1 and n <= 12 and last[1] != '0' and last[1] != '+' and last.len == (if (n < 10) @as(usize, 2) else 3)) return .{ .code = .{ .function = n }, .modifiers = mods };
    }
    // The reference accepts one byte, not one Unicode scalar, and folds ASCII.
    if (last.len == 1 and last[0] < 128) return .{ .code = .{ .char = std.ascii.toLower(last[0]) }, .modifiers = mods };
    return error.InvalidKey;
}

pub fn keyName(a: A, key: Key) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    inline for (.{ "shift", "ctrl", "alt", "super", "hyper", "meta" }) |name| if (@field(key.modifiers, name)) try out.writer.print("{s}-", .{name});
    switch (key.code) {
        .char => |ch| if (ch == ' ') try out.writer.writeAll("space") else {
            var buf: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(ch, &buf);
            try out.writer.writeAll(buf[0..n]);
        },
        .function => |n| try out.writer.print("f{d}", .{n}),
        .page_up => try out.writer.writeAll("pageup"),
        .page_down => try out.writer.writeAll("pagedown"),
        .back_tab => try out.writer.writeAll("backtab"),
        else => try out.writer.writeAll(@tagName(key.code)),
    }
    return out.toOwnedSlice();
}

pub fn parseColor(text: []const u8) !Color {
    var buffer: [128]u8 = undefined;
    var n: usize = 0;
    for (text) |ch| {
        if (ch == ' ' or ch == '-' or ch == '_') continue;
        if (n == buffer.len) return error.InvalidColor;
        buffer[n] = std.ascii.toLower(ch);
        n += 1;
    }
    var name: []const u8 = buffer[0..n];
    var aliases: [128]u8 = undefined;
    if (std.mem.startsWith(u8, name, "bright")) {
        @memcpy(aliases[0..5], "light");
        @memcpy(aliases[5 .. 5 + name.len - 6], name[6..]);
        name = aliases[0 .. name.len - 1];
    }
    if (std.mem.eql(u8, name, "grey") or std.mem.eql(u8, name, "silver")) return .gray;
    if (std.mem.eql(u8, name, "darkgrey") or std.mem.eql(u8, name, "darksilver") or std.mem.eql(u8, name, "lightblack")) return .dark_gray;
    if (std.mem.eql(u8, name, "lightwhite") or std.mem.eql(u8, name, "lightgray") or std.mem.eql(u8, name, "lightgrey") or std.mem.eql(u8, name, "lightsilver")) return .white;
    const names = .{ "reset", "black", "red", "green", "yellow", "blue", "magenta", "cyan", "gray", "darkgray", "lightred", "lightgreen", "lightyellow", "lightblue", "lightmagenta", "lightcyan", "white" };
    const colors = [_]Color{ .reset, .black, .red, .green, .yellow, .blue, .magenta, .cyan, .gray, .dark_gray, .light_red, .light_green, .light_yellow, .light_blue, .light_magenta, .light_cyan, .white };
    inline for (names, colors) |candidate, color| if (std.mem.eql(u8, name, candidate)) return color;
    if (text.len == 7 and text[0] == '#') return .{ .rgb = .{
        .r = std.fmt.parseInt(u8, text[1..3], 16) catch return error.InvalidColor,
        .g = std.fmt.parseInt(u8, text[3..5], 16) catch return error.InvalidColor,
        .b = std.fmt.parseInt(u8, text[5..7], 16) catch return error.InvalidColor,
    } };
    return .{ .indexed = std.math.cast(u8, parseIndex(text) catch return error.InvalidColor) orelse return error.InvalidColor };
}

pub fn colorName(a: A, color: Color) ![]const u8 {
    return switch (color) {
        .reset => "Reset",
        .black => "Black",
        .red => "Red",
        .green => "Green",
        .yellow => "Yellow",
        .blue => "Blue",
        .magenta => "Magenta",
        .cyan => "Cyan",
        .gray => "Gray",
        .dark_gray => "DarkGray",
        .light_red => "LightRed",
        .light_green => "LightGreen",
        .light_yellow => "LightYellow",
        .light_blue => "LightBlue",
        .light_magenta => "LightMagenta",
        .light_cyan => "LightCyan",
        .white => "White",
        .indexed => |n| std.fmt.allocPrint(a, "{d}", .{n}),
        .rgb => |rgb| std.fmt.allocPrint(a, "#{X:0>2}{X:0>2}{X:0>2}", .{ rgb.r, rgb.g, rgb.b }),
    };
}

pub fn parseIndex(text: []const u8) !usize {
    const digits = if (std.mem.startsWith(u8, text, "+")) text[1..] else text;
    if (digits.len == 0) return error.InvalidIndex;
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidIndex;
    return std.fmt.parseInt(usize, digits, 10) catch error.InvalidIndex;
}

fn canonical(io: Io, a: A, env: *const Env, path: []const u8) ![]const u8 {
    const expanded = try expandPath(io, a, env, path);
    if (expanded.len == 0) return error.FileNotFound;
    const result = try Io.Dir.cwd().realPathFileAlloc(io, expanded, a);
    if (!std.unicode.utf8ValidateSlice(result)) return error.InvalidPath;
    return result;
}

fn homeDir(a: A, env: *const Env) !?[]const u8 {
    if (env.get("HOME")) |home| if (home.len != 0) return home;
    if (std.c.getpwuid(std.c.getuid())) |user| if (user.dir) |dir| return try a.dupe(u8, std.mem.span(dir));
    return null;
}

fn platformDir(a: A, env: *const Env) !?[]const u8 {
    if (builtin.os.tag != .macos) if (env.get("XDG_CONFIG_HOME")) |p| if (std.fs.path.isAbsolute(p)) return p;
    if (try homeDir(a, env)) |h| return try std.fs.path.join(a, &.{ h, if (builtin.os.tag == .macos) "Library/Application Support" else ".config" });
    return null;
}

fn loadFile(io: Io, a: A, tree: *toml.Value, path: []const u8, diagnostic: ?*?[]const u8) !bool {
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    if (stat.kind != .file) return false;
    // Optional config sources ignore existing files with unregistered extensions.
    if (!std.mem.eql(u8, std.fs.path.extension(path), ".toml")) return true;
    // Once selected, an optional source suppresses IO failures without selecting
    // a different filename. Only an absent source permits extension inference.
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return true;
    defer file.close(io);
    var reader = file.reader(io, &.{});
    const bytes = reader.interface.allocRemaining(a, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return true,
    };
    const text = try utf8Lossy(a, if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) bytes[3..] else bytes);
    var message: ?[]const u8 = null;
    const parsed = toml.parseDetailed(a, text, &message) catch |err| {
        if (diagnostic) |d| d.* = try std.fmt.allocPrint(a, "Error: Config Error\n├─▶ Could not load configuration\n│   ╰╴Could not parse configuration\n╰─▶ {s} in {s}\n", .{ message orelse @errorName(err), try sourceName(io, a, path) });
        return err;
    };
    try toml.merge(a, tree, parsed);
    return true;
}

fn utf8Lossy(a: A, bytes: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    var out: std.Io.Writer.Allocating = .init(a);
    var i: usize = 0;
    while (i < bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            try out.writer.writeAll("\xef\xbf\xbd");
            i += 1;
            continue;
        };
        var count: usize = 1;
        if (i + 1 < bytes.len and
            ((bytes[i] == 0xE0 and bytes[i + 1] < 0xA0) or
                (bytes[i] == 0xED and bytes[i + 1] >= 0xA0) or
                (bytes[i] == 0xF0 and bytes[i + 1] < 0x90) or
                (bytes[i] == 0xF4 and bytes[i + 1] >= 0x90)))
        {
            try out.writer.writeAll("\xef\xbf\xbd");
            i += 1;
            continue;
        }
        while (count < n and i + count < bytes.len and (bytes[i + count] & 0xC0) == 0x80) : (count += 1) {}
        if (count != n) {
            try out.writer.writeAll("\xef\xbf\xbd");
            i += count;
        } else if (std.unicode.utf8Decode(bytes[i .. i + n])) |_| {
            try out.writer.writeAll(bytes[i .. i + n]);
            i += n;
        } else |_| {
            try out.writer.writeAll("\xef\xbf\xbd");
            i += 1;
        }
    }
    return out.toOwnedSlice();
}

fn sourceName(io: Io, a: A, path: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(path)) return path;
    const cwd = try Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    return std.fs.path.relativeAlloc(a, cwd, null, cwd, path);
}

test "TOML coercions, optional empties, export omissions, and nested models" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try toml.parse(a,
        \\display_full_path = "yes"
        \\search_submodules = 1
        \\search_paths = ["legacy"]
        \\search_dirs = []
        \\input_position = "Top"
        \\vcs_providers = ["jj"]
        \\unknown = "ignored"
        \\sessions = [{name = 42, windows = [{command = true, panes = [{}]}]}]
        \\[shortcuts]
        \\ctrl-Q = "cancel"
        \\[picker_colors]
        \\prompt_color = {Rgb = [1, 2, 255]}
    );
    const config = try toml.decode(Config, a, raw);
    try std.testing.expectEqual(true, config.display_full_path.?);
    try std.testing.expectEqual(true, config.search_submodules.?);
    try std.testing.expectEqual(@as(usize, 0), config.search_dirs.?.len);
    try std.testing.expect(config.bookmarks == null);
    try std.testing.expectEqual(VcsProvider.jujutsu, config.vcs_providers.?[0]);
    try std.testing.expectEqualStrings("42", config.sessions.?[0].name.?);
    const exported = try toml.parse(a, try exportToml(a, &config, false));
    try std.testing.expect(exported.table.get("input_position") == null);
    try std.testing.expect(exported.table.get("search_paths") == null);
    try std.testing.expectEqualStrings("cancel", exported.table.get("shortcuts").?.table.get("ctrl-q").?.string);
    try std.testing.expectEqualStrings("#0102FF", exported.table.get("picker_colors").?.table.get("prompt_color").?.string);
}

test "merge recursively replaces arrays before validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var raw = try toml.parse(a, "display_full_path = []\nsessions = [{ name = 'old' }]\n[picker_colors]\ninfo_color = 'red'\nprompt_color = 'blue'");
    try toml.merge(a, &raw, try toml.parse(a, "display_full_path = true\nsessions = []\n[picker_colors]\nprompt_color = 'green'"));
    const config = try toml.decode(Config, a, raw);
    try std.testing.expectEqual(true, config.display_full_path.?);
    try std.testing.expectEqual(@as(usize, 0), config.sessions.?.len);
    try std.testing.expectEqual(Color.red, config.picker_colors.?.info_color.?);
    try std.testing.expectEqual(Color.green, config.picker_colors.?.prompt_color.?);
    try std.testing.expectError(error.InvalidToml, toml.parse(a, "x = ["));
    try std.testing.expectError(error.InvalidConfigType, toml.decode(Config, a, try toml.parse(a, "display_full_path = []")));
    try std.testing.expectError(error.InvalidConfigEnum, toml.decode(Config, a, try toml.parse(a, "session_sort_order = 'alphabetical'")));
    try std.testing.expectError(error.InvalidKey, toml.decode(Config, a, try toml.parse(a, "[shortcuts]\ninvalid = 'cancel'")));
}

test "key aliases and ASCII folding match reference" {
    try std.testing.expect(std.meta.eql(try parseKey("SHIFT-CTRL-X"), Key{ .code = .{ .char = 'x' }, .modifiers = .{ .shift = true, .ctrl = true } }));
    try std.testing.expect(std.meta.eql(try parseKey("ignored-ins"), Key{ .code = .insert }));
    try std.testing.expectError(error.InvalidKey, parseKey("é"));
    try std.testing.expectError(error.InvalidKey, parseKey("ctrl--"));
    try std.testing.expectError(error.InvalidKey, parseKey("f13"));
}

test "defaults and shortcut overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const options = try pickerOptions(a, &.{ .shortcuts = &.{.{ .key = try parseKey("ctrl-c"), .action = .noop }} });
    try std.testing.expectEqual(@as(usize, 18), options.bindings.len);
    try std.testing.expectEqual(PickerAction.noop, options.bindings[0].action);
    try std.testing.expectEqual(InputPosition.bottom, options.input_position);
    try std.testing.expectEqual(Color.light_blue, options.colors.highlight_color.?);
    try std.testing.expectEqual(Color.white, try parseColor("bright-grey"));
}

test "shortcut replacement coalesces parsed aliases and keeps the last override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = try toml.decode(Config, a, try toml.parse(a, "[shortcuts]\nctrl-C = 'confirm'\nCTRL-c = ''\n"));
    try std.testing.expectEqual(@as(usize, 1), cfg.shortcuts.?.len);
    const options = try pickerOptions(a, &.{ .shortcuts = &.{
        .{ .key = try parseKey("ctrl-C"), .action = .confirm },
        .{ .key = try parseKey("ctrl-c"), .action = .noop },
        .{ .key = try parseKey("ctrl-X"), .action = .cancel },
        .{ .key = try parseKey("CTRL-x"), .action = .delete },
    } });
    try std.testing.expectEqual(@as(usize, 19), options.bindings.len);
    try std.testing.expectEqual(PickerAction.noop, options.bindings[0].action);
    try std.testing.expectEqual(PickerAction.delete, options.bindings[18].action);
}

test "path expansion preserves empty variables, literal defaults, and variable tildes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: Env = .init(a);
    try env.put("HOME", "/a home");
    try env.put("EMPTY", "");
    try env.put("VAR", "~");
    try env.put("项目", "项目");
    const io = std.testing.io;
    try std.testing.expectEqualStrings("/a home/项目", try expandPath(io, a, &env, "~/${项目}"));
    try std.testing.expectEqualStrings("项目🙂", try expandPath(io, a, &env, "$项目🙂"));
    try std.testing.expectEqualStrings("~/x", try expandPath(io, a, &env, "$VAR/x"));
    try std.testing.expectEqualStrings("/x", try expandPath(io, a, &env, "${EMPTY:-fallback}/x"));
    try std.testing.expectEqualStrings("$HOME", try expandPath(io, a, &env, "${ABSENT:-$HOME}"));
    try std.testing.expectEqualStrings("$HOME/${broken", try expandPath(io, a, &env, "$$HOME/${broken"));
    try std.testing.expectEqualStrings("~someone/x", try expandPath(io, a, &env, "~someone/x"));
    try std.testing.expectError(error.MissingEnvironmentVariable, expandPath(io, a, &env, "$ABSENT"));
}

test "enum tables, sequence structs, precise timestamps, and UTF-8 file conversion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = try toml.decode(Config, a, try toml.parse(a,
        \\default_session = 1979-05-27t07:32:00.1234567899z
        \\search_dirs = [["a", 2]]
        \\sessions = [["一", "b", []]]
        \\session_sort_order = {LastAttached = false}
        \\vcs_providers = [{jj = 1}]
        \\[shortcuts]
        \\ctrl-c = {cancel = []}
    ));
    try std.testing.expectEqualStrings("1979-05-27T07:32:00.123456789Z", cfg.default_session.?);
    try std.testing.expectEqualStrings("一", cfg.sessions.?[0].name.?);
    try std.testing.expectEqual(@as(usize, 2), cfg.search_dirs.?[0].depth);
    try std.testing.expectEqual(Order.last_attached, cfg.session_sort_order.?);
    try std.testing.expectEqual(VcsProvider.jujutsu, cfg.vcs_providers.?[0]);
    try std.testing.expectError(error.InvalidColor, toml.decode(Color, a, (try toml.parse(a, "x = {Indexed = '5'}")).table.get("x").?));
    try std.testing.expectEqualStrings("\xef\xbf\xbdA\xef\xbf\xbd", try utf8Lossy(a, "\xe1\x80A\xff"));
    try std.testing.expectEqualStrings("a\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbdb", try utf8Lossy(a, "a\xed\xa0\x80b"));
}

test "clearing saved marks reveals exact marks inherited from the earlier location" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    var env: Env = .init(a);
    try env.put("HOME", root);
    try env.put("XDG_CONFIG_HOME", try std.fs.path.join(a, &.{ root, "platform" }));
    const legacy = try std.fs.path.join(a, &.{ root, ".config/tms" });
    try Io.Dir.cwd().createDirPath(io, legacy);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ legacy, "config.toml" }), .data = "display_full_path = []\nsearch_paths = ['~']\n[marks]\n'0' = '/a/path/that/does/not/exist'\n[ picker_colors ]\ninfo_color = 'red'\n" });
    const platform = (try platformDir(a, &env)).?;
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ platform, "tms" }));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ platform, "tms/config.toml" }), .data = "display_full_path = true\nsearch_dirs = []\nunknown = 4\n[picker_colors]\nprompt_color = 'green'\n" });
    var loaded = try load(io, a, &env);
    try std.testing.expectEqual(true, loaded.display_full_path.?);
    try std.testing.expectEqual(Color.red, loaded.picker_colors.?.info_color.?);
    try std.testing.expectEqual(Color.green, loaded.picker_colors.?.prompt_color.?);
    try std.testing.expectEqual(@as(usize, 1), loaded.marks.?.count());
    try std.testing.expectEqualStrings("/a/path/that/does/not/exist", loaded.marks.?.get("0").?);
    try commit(io, a, &env, &loaded, .{ .set_mark = .{ .index = 0, .path = root } });
    const overridden = try load(io, a, &env);
    try std.testing.expectEqual(@as(usize, 1), overridden.marks.?.count());
    try std.testing.expectEqualStrings(root, overridden.marks.?.get("0").?);
    try commit(io, a, &env, &loaded, .clear_marks);
    const inherited = try load(io, a, &env);
    try std.testing.expectEqual(@as(usize, 1), inherited.marks.?.count());
    try std.testing.expectEqualStrings("/a/path/that/does/not/exist", inherited.marks.?.get("0").?);
}

test "raw saves, canonical roots, bookmarks, and valid mark allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    var env: Env = .init(a);
    try env.put("HOME", root);
    const path = try std.fs.path.join(a, &.{ root, "config.toml" });
    try env.put("TMS_CONFIG_FILE", path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "display_full_path = true\nsearch_paths = ['~']\nsearch_dirs = []\ninput_position = 'Top'\nunknown = 4\n[marks]\n'0' = '/a/path/that/does/not/exist'\n" });
    var loaded = try load(io, a, &env);
    try std.testing.expectEqualStrings(root, (try searchRoots(io, a, &env, &loaded))[0].path);
    try commit(io, a, &env, &loaded, .{ .settings = .{ .paths = &.{root}, .max_depths = &.{ 0, 9 }, .default_session = "a.b-c", .excluded = &.{ "vendor*", "vendor*" } } });
    try commit(io, a, &env, &loaded, .{ .settings = .{ .max_depths = &.{7} } });
    try std.testing.expectEqual(@as(usize, 0), loaded.search_dirs.?[0].depth);
    try std.testing.expectEqualStrings("a_b-c", loaded.default_session.?);
    try std.testing.expectEqual(@as(usize, 2), loaded.excluded_dirs.?.len);
    try commit(io, a, &env, &loaded, .{ .set_mark = .{ .index = null, .path = root } });
    try std.testing.expectEqualStrings(root, loaded.marks.?.get("0").?);
    try commit(io, a, &env, &loaded, .{ .set_mark = .{ .index = null, .path = root } });
    try std.testing.expectEqual(@as(usize, 2), (try validMarks(io, a, &env, &loaded)).len);
    try commit(io, a, &env, &loaded, .{ .add_bookmark = root });
    try commit(io, a, &env, &loaded, .{ .add_bookmark = root });
    try commit(io, a, &env, &loaded, .{ .add_bookmark = "$ABSENT/invalid" });
    try std.testing.expectEqual(@as(usize, 2), loaded.bookmarks.?.len);
    try std.testing.expectEqual(@as(usize, 1), (try bookmarkPaths(io, a, &env, &loaded)).len);
    try commit(io, a, &env, &loaded, .{ .delete_bookmark = root });
    try commit(io, a, &env, &loaded, .{ .delete_mark = 0 });
    try commit(io, a, &env, &loaded, .clear_marks);
    const reloaded = try load(io, a, &env);
    try std.testing.expect(reloaded.marks == null);
    try std.testing.expectEqualStrings("$ABSENT/invalid", reloaded.bookmarks.?[0]);
    try std.testing.expectEqual(InputPosition.top, reloaded.input_position.?);
    try std.testing.expect(std.mem.indexOf(u8, try exportToml(a, &reloaded, false), "input_position") == null);
    try env.put("TMS_CONFIG_FILE", try std.fs.path.join(a, &.{ root, "isolated.toml" }));
    var isolated = try load(io, a, &env);
    try std.testing.expect(isolated.display_full_path == null);
    try std.testing.expectError(error.NoDefaultSearchPath, searchRoots(io, a, &env, &isolated));
    isolated.search_dirs = &.{.{ .path = "/no/such/directory", .depth = 1 }};
    try std.testing.expectError(error.NoValidSearchPath, searchRoots(io, a, &env, &isolated));
    try std.testing.expectError(error.RemoveWithoutExclusions, commit(io, a, &env, &isolated, .{ .settings = .{ .remove = &.{"missing"} } }));
}

test "out-of-range TOML depths fail before replacing a saved configuration" {
    if (@bitSizeOf(usize) < 64) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    var env: Env = .init(a);
    const file = try std.fs.path.join(a, &.{ path, "config.toml" });
    try env.put("TMS_CONFIG_FILE", file);
    const saved = "default_session = 'preserved'\n";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = saved });
    for ([_]usize{ @as(usize, std.math.maxInt(i64)) + 1, std.math.maxInt(usize) }) |depth| {
        var cfg = try load(io, a, &env);
        try std.testing.expectError(error.ConfigSerializationOutOfRange, commit(io, a, &env, &cfg, .{ .settings = .{
            .paths = &.{path},
            .max_depths = &.{depth},
        } }));
        try std.testing.expectEqualStrings(saved, try Io.Dir.cwd().readFileAlloc(io, file, a, .unlimited));
        try std.testing.expectEqualStrings("preserved", (try load(io, a, &env)).default_session.?);
        try std.testing.expectError(error.ConfigIntegerOutOfRange, exportToml(a, &cfg, false));
    }
    const valid: Config = .{ .search_dirs = &.{.{ .path = path, .depth = std.math.maxInt(i64) }} };
    const exported = try toml.parse(a, try exportToml(a, &valid, false));
    try std.testing.expectEqual(std.math.maxInt(i64), exported.table.get("search_dirs").?.array[0].table.get("depth").?.integer);
}

test "an unreadable selected config source does not fall back to another filename" {
    if (std.c.getuid() == 0) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const path = try std.fs.path.join(a, &.{ root, "config.toml" });
    const fallback = try std.fmt.allocPrint(a, "{s}.toml", .{path});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "default_session = 'unreadable'\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = fallback, .data = "default_session = 'fallback'\n" });
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    try file.setPermissions(io, .fromMode(0));
    defer file.setPermissions(io, .fromMode(0o600)) catch {};
    var env: Env = .init(a);
    try env.put("TMS_CONFIG_FILE", path);
    try std.testing.expect((try load(io, a, &env)).default_session == null);
    try file.setPermissions(io, .fromMode(0o600));
    try std.testing.expectEqualStrings("unreadable", (try load(io, a, &env)).default_session.?);
    try Io.Dir.cwd().deleteFile(io, path);
    try std.testing.expectEqualStrings("fallback", (try load(io, a, &env)).default_session.?);
}

test "year-zero TOML timestamps survive decoding and export" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "0000-01-01", "0000-02-29", "0000-01-01T00:00:00Z" }) |timestamp| {
        const cfg = try toml.decode(Config, a, try toml.parse(a, try std.fmt.allocPrint(a, "default_session = {s}\n", .{timestamp})));
        const exported = try toml.parse(a, try exportToml(a, &cfg, false));
        try std.testing.expectEqualStrings(timestamp, exported.table.get("default_session").?.string);
    }
    try std.testing.expectError(error.InvalidToml, toml.parse(a, "default_session = 0000-02-30\n"));
    try std.testing.expectError(error.InvalidToml, toml.parse(a, "default_session = 0001-02-29\n"));
}

test "TOML floats underflow to signed zero without becoming parse errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "1e-999", "-1e-999" }, [_][]const u8{ "0", "-0" }) |literal, expected| {
        const cfg = try toml.decode(Config, a, try toml.parse(a, try std.fmt.allocPrint(
            a,
            "default_session = {s}\ndisplay_full_path = {s}\nsearch_dirs = [{{path = 'a', depth = {s}}}]\n",
            .{ literal, literal, literal },
        )));
        const exported = try toml.parse(a, try exportToml(a, &cfg, false));
        try std.testing.expectEqualStrings(expected, exported.table.get("default_session").?.string);
        try std.testing.expectEqual(false, cfg.display_full_path.?);
        try std.testing.expectEqual(@as(usize, 0), cfg.search_dirs.?[0].depth);
    }
    try std.testing.expectError(error.InvalidToml, toml.parse(a, "default_session = 1e999\n"));
    try std.testing.expectError(error.InvalidToml, toml.parse(a, "default_session = -1e999\n"));
}

test "NaN string coercion matches Rust for every TOML sign" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "nan", "+nan", "-nan" }) |literal| {
        const cfg = try toml.decode(Config, a, try toml.parse(a, try std.fmt.allocPrint(
            a,
            "default_session = {s}\nbookmarks = [{s}]\n[marks]\n'0' = {s}\n",
            .{ literal, literal, literal },
        )));
        const exported = try toml.parse(a, try exportToml(a, &cfg, false));
        try std.testing.expectEqualStrings("NaN", exported.table.get("default_session").?.string);
        try std.testing.expectEqualStrings("NaN", cfg.bookmarks.?[0]);
        try std.testing.expectEqualStrings("NaN", cfg.marks.?.get("0").?);
    }
}

test "load diagnostics preserve enum representation, variant, and indexed keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const path = try std.fs.path.join(a, &.{ root, "config.toml" });
    var env: Env = .init(a);
    try env.put("TMS_CONFIG_FILE", path);
    const Case = struct { text: []const u8, expected: []const u8 };
    for ([_]Case{
        .{ .text = "session_sort_order = {Bad = []}", .expected = "enum SessionSortOrderConfig does not have variant constructor Bad for key `session_sort_order`" },
        .{ .text = "vcs_providers = [{Bad = []}]", .expected = "enum VcsProviders does not have variant constructor Bad for key `vcs_providers[0]`" },
        .{ .text = "session_sort_order = 1", .expected = "value of enum SessionSortOrderConfig should be represented by either string or table with exactly one key for key `session_sort_order`" },
        .{ .text = "vcs_providers = [1]", .expected = "value of enum VcsProviders should be represented by either string or table with exactly one key for key `vcs_providers[0]`" },
        .{ .text = "session_sort_order = {}", .expected = "value of enum SessionSortOrderConfig should be represented by either string or table with exactly one key for key `session_sort_order`" },
        .{ .text = "session_sort_order = []", .expected = "value of enum SessionSortOrderConfig should be represented by either string or table with exactly one key for key `session_sort_order`" },
        .{ .text = "session_sort_order = {Bad = [], Wrong = []}", .expected = "value of enum SessionSortOrderConfig should be represented by either string or table with exactly one key for key `session_sort_order`" },
    }) |case| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = case.text });
        const result = try loadDetailed(io, a, &env);
        try std.testing.expect(result == .diagnostic);
        try std.testing.expectEqual(@as(u8, 1), result.diagnostic.exit_code);
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(
            a,
            "Error: Config Error\n├─▶ Could not load configuration\n│   ╰╴Could not deserialize configuration\n╰─▶ {s}\n",
            .{case.expected},
        ), result.diagnostic.text);
    }
}

test "sequence structs ignore trailing values without decoding their types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { template: []const u8, has_fields: bool = true };
    inline for ([_]Case{
        .{ .template = "session_configs = {{a = [\"ok\"{s}]}}" },
        .{ .template = "search_dirs = [[\"path\", 7{s}]]" },
        .{ .template = "sessions = [{{windows = [[\"window\", \"path\", [], \"cmd\"{s}]]}}]" },
        .{ .template = "sessions = [[\"session\", \"path\", []{s}]]" },
        .{ .template = "picker_colors = [\"red\", \"blue\", \"black\", \"green\", \"white\"{s}]" },
        .{ .template = "sessions = [{{windows = [{{panes = [[{s}]]}}]}}]", .has_fields = false },
    }) |case| {
        const baseline = try toml.decode(Config, a, try toml.parse(a, try std.fmt.allocPrint(a, case.template, .{""})));
        const expected = try toml.encode(a, baseline);
        for ([_][]const u8{ "{Rgb = [\"invalid\"]}", "[false, {bad = [1, 2]}]", "false, nan, 42" }) |unused| {
            const tail = if (case.has_fields) try std.fmt.allocPrint(a, ", {s}", .{unused}) else unused;
            const actual = try toml.decode(Config, a, try toml.parse(a, try std.fmt.allocPrint(a, case.template, .{tail})));
            try std.testing.expectEqualStrings(expected, try toml.encode(a, actual));
        }
    }
}

test "sequence struct tails do not bypass declared field or TOML validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { text: []const u8, err: anyerror = error.InvalidConfigType };
    for ([_]Case{
        .{ .text = "session_configs = {a = [{}, 42]}" },
        .{ .text = "search_dirs = [[{}, 7, 42]]" },
        .{ .text = "sessions = [{windows = [[{}, 'path', [], 'cmd', 42]]}]" },
        .{ .text = "sessions = [[{}, 'path', [], 42]]" },
        .{ .text = "picker_colors = [{Rgb=['bad']}, 'blue', 'black', 'green', 'white', 42]", .err = error.InvalidColor },
    }) |case| {
        try std.testing.expectError(case.err, toml.decode(Config, a, try toml.parse(a, case.text)));
    }
    for ([_][]const u8{
        "session_configs = {a = ['ok', 1e999]}",
        "session_configs = {a = ['ok', \"bad\\q\"]}",
    }) |text| {
        try std.testing.expectError(error.InvalidToml, toml.parse(a, text));
    }
}

test "load diagnostics describe short sequence structs and their nested keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const path = try std.fs.path.join(a, &.{ root, "config.toml" });
    var env: Env = .init(a);
    try env.put("TMS_CONFIG_FILE", path);
    const Case = struct { text: []const u8, expected: []const u8 };
    for ([_]Case{
        .{ .text = "sessions = [['a']]", .expected = "invalid length 1, expected struct Session with 3 elements for key `sessions[0]`" },
        .{ .text = "sessions = [['a', 'b']]", .expected = "invalid length 2, expected struct Session with 3 elements for key `sessions[0]`" },
        .{ .text = "search_dirs = [['a']]", .expected = "invalid length 1, expected struct SearchDirectory with 2 elements for key `search_dirs[0]`" },
        .{ .text = "sessions = [{windows = [['a']]}]", .expected = "invalid length 1, expected struct Window with 4 elements for key `sessions[0]windows[0]`" },
        .{ .text = "sessions = [{windows = [['a', 'b', []]]}]", .expected = "invalid length 3, expected struct Window with 4 elements for key `sessions[0]windows[0]`" },
        .{ .text = "picker_colors = []", .expected = "invalid length 0, expected struct PickerColorConfig with 5 elements for key `picker_colors`" },
        .{ .text = "picker_colors = ['red', 'blue', 'black', 'green']", .expected = "invalid length 4, expected struct PickerColorConfig with 5 elements for key `picker_colors`" },
        .{ .text = "session_configs = {a = []}", .expected = "invalid length 0, expected struct SessionConfig with 1 element for key `session_configs.a`" },
    }) |case| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = case.text });
        const result = try loadDetailed(io, a, &env);
        try std.testing.expect(result == .diagnostic);
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(
            a,
            "Error: Config Error\n├─▶ Could not load configuration\n│   ╰╴Could not deserialize configuration\n╰─▶ {s}\n",
            .{case.expected},
        ), result.diagnostic.text);
    }
}
