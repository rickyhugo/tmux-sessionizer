const std = @import("std");
const A = std.mem.Allocator;
const Io = std.Io;
const Env = std.process.Environ.Map;

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

pub fn load(io: Io, a: A, env: *const Env) anyerror!Config {
    _ = .{ io, a, env };
    return error.NotImplemented;
}

pub fn commit(io: Io, a: A, env: *const Env, cfg: *Config, edit: Edit) anyerror!void {
    _ = .{ io, a, env, cfg, edit };
    return error.NotImplemented;
}

pub fn exportToml(a: A, cfg: *const Config, defaults: bool) anyerror![]const u8 {
    _ = .{ a, cfg, defaults };
    return error.NotImplemented;
}

pub fn searchRoots(io: Io, a: A, env: *const Env, cfg: *const Config) anyerror![]const SearchDirectory {
    _ = .{ io, a, env, cfg };
    return error.NotImplemented;
}

pub fn bookmarkPaths(io: Io, a: A, env: *const Env, cfg: *const Config) anyerror![]const []const u8 {
    _ = .{ io, a, env, cfg };
    return error.NotImplemented;
}

pub fn validMarks(io: Io, a: A, env: *const Env, cfg: *const Config) anyerror![]const Mark {
    _ = .{ io, a, env, cfg };
    return error.NotImplemented;
}

pub fn expandPath(io: Io, a: A, env: *const Env, path: []const u8) anyerror![]const u8 {
    _ = .{ io, a, env, path };
    return error.NotImplemented;
}

pub fn pickerOptions(a: A, cfg: *const Config) anyerror!PickerOptions {
    _ = .{ a, cfg };
    return error.NotImplemented;
}

pub fn parseKey(text: []const u8) anyerror!Key {
    _ = text;
    return error.NotImplemented;
}
