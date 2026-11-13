const std = @import("std");

pub const Id = enum { root, config, config_list, start, switch_session, windows, kill, sessions, rename, refresh, clone_repo, init_repo, bookmark, open_session, marks, marks_list, marks_set, marks_open, marks_delete, help, config_help, marks_help };
pub const OptionId = enum {
    paths,
    session,
    excluded,
    remove,
    full_path,
    search_submodules,
    recursive_submodules,
    switch_filter_unknown,
    max_depths,
    picker_highlight_color,
    picker_highlight_text_color,
    picker_border_color,
    picker_info_color,
    picker_prompt_color,
    session_sort_order,
    clone_repo_switch,
    enable_list_worktrees,
    defaults,
    path,
    name,
    delete,
    all,
    help,
    version,
};
pub const Kind = enum { flag, string, strings, uints, boolean, color, order, clone_switch };
pub const Option = struct {
    id: OptionId,
    long: []const u8,
    short: ?u8 = null,
    value: ?[]const u8 = null,
    kind: Kind = .string,
    about: []const u8,
    pub fn many(self: Option) bool {
        return self.kind == .strings or self.kind == .uints;
    }
};
pub const Spec = struct {
    id: Id,
    parent: ?Id,
    name: []const u8,
    about: []const u8,
    suffix: []const u8 = "",
    positional: ?[]const u8 = null,
    positional_about: []const u8 = "",
    positional_last: bool = false,
    required: bool = false,
    options: []const Option = &.{},
};
pub const help_option = Option{ .id = .help, .long = "help", .short = 'h', .kind = .flag, .about = "Print help" };
pub const version_option = Option{ .id = .version, .long = "version", .short = 'V', .kind = .flag, .about = "Print version" };
pub const config_options = [_]Option{
    .{ .id = .paths, .long = "paths", .short = 'p', .value = "search paths", .kind = .strings, .about = "The paths to search through. Shell like expansions such as '~' are supported" },
    .{ .id = .session, .long = "session", .short = 's', .value = "default session", .about = "The default session to switch to (if available) when killing another session" },
    .{ .id = .excluded, .long = "excluded", .value = "excluded dirs", .kind = .strings, .about = "As many directory names as desired to not be searched over" },
    .{ .id = .remove, .long = "remove", .value = "remove dir", .kind = .strings, .about = "As many directory names to be removed from exclusion list" },
    .{ .id = .full_path, .long = "full-path", .value = "true | false", .kind = .boolean, .about = "Use the full path when displaying directories" },
    .{ .id = .search_submodules, .long = "search-submodules", .value = "true | false", .kind = .boolean, .about = "Also show initialized submodules" },
    .{ .id = .recursive_submodules, .long = "recursive-submodules", .value = "true | false", .kind = .boolean, .about = "Search submodules for submodules" },
    .{ .id = .switch_filter_unknown, .long = "switch-filter-unknown", .value = "true | false", .kind = .boolean, .about = "Only include sessions from search paths in the switcher" },
    .{ .id = .max_depths, .long = "max-depths", .short = 'd', .value = "max depth", .kind = .uints, .about = "The maximum depth to traverse when searching for repositories in search paths, length should match the number of search paths if specified (defaults to 10)" },
    .{ .id = .picker_highlight_color, .long = "picker-highlight-color", .value = "#rrggbb", .kind = .color, .about = "Background color of the highlighted item in the picker" },
    .{ .id = .picker_highlight_text_color, .long = "picker-highlight-text-color", .value = "#rrggbb", .kind = .color, .about = "Text color of the highlighted item in the picker" },
    .{ .id = .picker_border_color, .long = "picker-border-color", .value = "#rrggbb", .kind = .color, .about = "Color of the borders between widgets in the picker" },
    .{ .id = .picker_info_color, .long = "picker-info-color", .value = "#rrggbb", .kind = .color, .about = "Color of the item count in the picker" },
    .{ .id = .picker_prompt_color, .long = "picker-prompt-color", .value = "#rrggbb", .kind = .color, .about = "Color of the prompt in the picker" },
    .{ .id = .session_sort_order, .long = "session-sort-order", .value = "Alphabetical | LastAttached", .kind = .order, .about = "Set the sort order of the sessions in the switch command" },
    .{ .id = .clone_repo_switch, .long = "clone-repo-switch", .value = "Always | Never | Foreground", .kind = .clone_switch, .about = "Whether to automatically switch to the new session after the `clone-repo` command finishes\n" ++
        "`Always` will always switch tmux to the new session\n" ++
        "`Never` will always create the new session in the background\n" ++
        "When set to `Foreground`, the new session will only be opened in the background if the active\n" ++
        "tmux session has changed since starting the clone process (for long clone processes on larger repos)" },
    .{ .id = .enable_list_worktrees, .long = "enable-list-worktrees", .value = "true | false", .kind = .boolean, .about = "Enable listing of woktrees for bare repositories" },
};
pub const specs = [_]Spec{
    .{ .id = .root, .parent = null, .name = "", .about = "Scan for all git folders in specified directories, select one and open it as a new tmux session", .suffix = " [COMMAND]" },
    .{ .id = .config, .parent = .root, .name = "config", .about = "Configure the defaults for search paths and excluded directories", .suffix = " [OPTIONS]", .options = &config_options },
    .{ .id = .config_list, .parent = .config, .name = "list", .about = "List current config including all default values", .suffix = " [OPTIONS]", .options = &.{.{ .id = .defaults, .long = "defaults", .short = 'd', .kind = .flag, .about = "List only defaults without user set values" }} },
    .{ .id = .start, .parent = .root, .name = "start", .about = "Initialize tmux with the default sessions" },
    .{ .id = .switch_session, .parent = .root, .name = "switch", .about = "Display other sessions with a fuzzy finder and a preview window" },
    .{ .id = .windows, .parent = .root, .name = "windows", .about = "Display the current session's windows with a fuzzy finder and a preview window" },
    .{ .id = .kill, .parent = .root, .name = "kill", .about = "Kill the current tmux session and jump to another" },
    .{ .id = .sessions, .parent = .root, .name = "sessions", .about = "Show running tmux sessions with asterisk on the current session" },
    .{ .id = .rename, .parent = .root, .name = "rename", .about = "Rename the active session and the working directory", .suffix = " <NAME>", .positional = "NAME", .positional_about = "The new session's name", .required = true },
    .{ .id = .refresh, .parent = .root, .name = "refresh", .about = "Creates new worktree windows for the selected session", .suffix = " [NAME]", .positional = "NAME", .positional_about = "The session's name. If not provided gets current session" },
    .{ .id = .clone_repo, .parent = .root, .name = "clone-repo", .about = "Clone repository and create a new session for it", .suffix = " [OPTIONS] <REPOSITORY>", .positional = "REPOSITORY", .positional_about = "Git repository to clone", .required = true, .options = &.{
        .{ .id = .path, .long = "path", .value = "PATH", .about = "Directory to create new repository in, if left empty will pick default search path or prompt if multiple are configured" },
        .{ .id = .name, .long = "name", .value = "NAME", .about = "Name of cloned repository directory, will be picked based on remote url if left empty" },
    } },
    .{ .id = .init_repo, .parent = .root, .name = "init-repo", .about = "Initialize empty repository", .suffix = " <REPOSITORY>", .positional = "REPOSITORY", .positional_about = "Name of the repository to initialize", .required = true },
    .{ .id = .bookmark, .parent = .root, .name = "bookmark", .about = "Bookmark a directory so it is available to select along with the Git repositories", .suffix = " [OPTIONS] [PATH]", .positional = "PATH", .positional_about = "Path to bookmark, if left empty bookmark the current directory", .positional_last = true, .options = &.{.{ .id = .delete, .long = "delete", .short = 'd', .kind = .flag, .about = "Delete instead of add a bookmark" }} },
    .{ .id = .open_session, .parent = .root, .name = "open-session", .about = "Open a session", .suffix = " <SESSION>", .positional = "SESSION", .positional_about = "Name of the session to open", .required = true },
    .{ .id = .marks, .parent = .root, .name = "marks", .about = "Manage list of sessions that can be instantly accessed by their index", .suffix = " [INDEX]", .positional = "INDEX", .positional_about = "The index of the mark to open" },
    .{ .id = .marks_list, .parent = .marks, .name = "list", .about = "List all marks" },
    .{ .id = .marks_set, .parent = .marks, .name = "set", .about = "Add a session mark", .suffix = " [OPTIONS] [INDEX]", .positional = "INDEX", .positional_about = "Index of mark to set, if empty will append after the last item", .options = &.{.{ .id = .path, .long = "path", .short = 'p', .value = "PATH", .about = "Path to project directory, if empty will use the current directory" }} },
    .{ .id = .marks_open, .parent = .marks, .name = "open", .about = "Open the session at index", .suffix = " <INDEX>", .positional = "INDEX", .positional_about = "The index of the mark to open", .required = true },
    .{ .id = .marks_delete, .parent = .marks, .name = "delete", .about = "Delete marks", .suffix = " <INDEX|--all>", .positional = "INDEX", .positional_about = "Index of mark to delete", .options = &.{.{ .id = .all, .long = "all", .short = 'a', .kind = .flag, .about = "Delete all items" }} },
    .{ .id = .help, .parent = .root, .name = "help", .about = "Print this message or the help of the given subcommand(s)", .suffix = " [COMMAND]..." },
    .{ .id = .config_help, .parent = .config, .name = "help", .about = "Print this message or the help of the given subcommand(s)", .suffix = " [COMMAND]..." },
    .{ .id = .marks_help, .parent = .marks, .name = "help", .about = "Print this message or the help of the given subcommand(s)", .suffix = " [COMMAND]..." },
};

pub fn isHelp(id: Id) bool {
    return id == .help or id == .config_help or id == .marks_help;
}
pub fn get(id: Id) Spec {
    for (specs) |s| if (s.id == id) return s;
    unreachable;
}
pub fn child(parent: Id, name: []const u8) ?Id {
    for (specs) |s| if (s.parent == parent and std.mem.eql(u8, s.name, name)) return s.id;
    return null;
}
pub const OptionName = union(enum) { long: []const u8, short: u8 };

pub fn findOption(id: Id, name: OptionName) ?Option {
    for (get(id).options) |o| if (matches(o, name)) return o;
    if (matches(help_option, name)) return help_option;
    if (id == .root and matches(version_option, name)) return version_option;
    return null;
}

fn matches(o: Option, name: OptionName) bool {
    return switch (name) {
        .long => |long| std.mem.eql(u8, o.long, long),
        .short => |short| o.short == short,
    };
}

pub fn path(a: std.mem.Allocator, id: Id) ![]const []const u8 {
    const s = get(id);
    if (s.parent == null) return &.{};
    return std.mem.concat(a, []const u8, &.{ try path(a, s.parent.?), &.{s.name} });
}
pub fn invocation(a: std.mem.Allocator, id: Id) ![]const u8 {
    const pieces = try path(a, id);
    return std.mem.join(a, " ", try std.mem.concat(a, []const u8, &.{ &.{"tms"}, pieces }));
}
pub fn usage(a: std.mem.Allocator, id: Id) ![]const u8 {
    const s = get(id);
    const base = try invocation(a, id);
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ base, s.suffix, if (id == .config or id == .marks) try std.fmt.allocPrint(a, "\n       {s} <COMMAND>", .{base}) else "" });
}
pub fn label(a: std.mem.Allocator, option: Option) ![]const u8 {
    return std.fmt.allocPrint(a, "--{s}{s}", .{ option.long, if (option.value) |v| try std.fmt.allocPrint(a, " <{s}>{s}", .{ v, if (option.many()) "..." else "" }) else "" });
}
pub fn positionalUsage(a: std.mem.Allocator, id: Id) ![]const u8 {
    const s = get(id);
    if (id == .marks_delete) return s.suffix;
    return if (s.positional) |name| std.fmt.allocPrint(a, " {s}{s}{s}", .{ if (s.required) "<" else "[", name, if (s.required) ">" else "]" }) else "";
}

pub fn argumentGroup(a: std.mem.Allocator, id: Id) ![]const u8 {
    const s = get(id);
    var members: std.ArrayList([]const u8) = .empty;
    if (!s.positional_last) if (s.positional) |name| try members.append(a, name);
    for (s.options) |o| try members.append(a, try label(a, o));
    if (s.positional_last) if (s.positional) |name| try members.append(a, name);
    return std.fmt.allocPrint(a, "<{s}>", .{try std.mem.join(a, "|", members.items)});
}

pub fn values(kind: Kind) []const []const u8 {
    return switch (kind) {
        .boolean => &.{ "true", "false" },
        .order => &.{ "Alphabetical", "LastAttached" },
        .clone_switch => &.{ "Always", "Never", "Foreground" },
        else => &.{},
    };
}

pub fn help(a: std.mem.Allocator, id: Id) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    const s = get(id);
    try w.print("{s}\n\nUsage: {s}\n", .{ s.about, try usage(a, id) });
    if (isHelp(id)) {
        try w.writeAll("\nArguments:\n  [COMMAND]...  Print help for the subcommand(s)\n");
        return out.toOwnedSlice();
    }
    if (id == .root or id == .config or id == .marks) {
        try w.writeAll("\nCommands:\n");
        var width: usize = 4;
        for (specs) |entry| if (entry.parent == id) {
            width = @max(width, entry.name.len);
        };
        for (specs) |entry| if (entry.parent == id and !isHelp(entry.id)) {
            try w.print("  {s}", .{entry.name});
            try w.splatByteAll(' ', width + 2 - entry.name.len);
            try w.print("{s}\n", .{entry.about});
        };
        try w.writeAll("  help");
        try w.splatByteAll(' ', width - 2);
        try w.writeAll("Print this message or the help of the given subcommand(s)\n");
    }
    if (s.positional) |name| {
        const required = s.required;
        try w.print("\nArguments:\n  {s}{s}{s}  {s}\n", .{ if (required) "<" else "[", name, if (required) ">" else "]", s.positional_about });
    }
    try w.writeAll("\nOptions:\n");
    var options: std.ArrayList(Option) = .empty;
    try options.appendSlice(a, s.options);
    try options.append(a, help_option);
    if (id == .root) try options.append(a, version_option);
    var width: usize = 0;
    for (options.items) |option| width = @max(width, (try label(a, option)).len + 4);
    for (options.items) |option| {
        const text = try label(a, option);
        try w.writeAll("  ");
        if (option.short) |ch| try w.print("-{c}, ", .{ch}) else try w.writeAll("    ");
        try w.writeAll(text);
        if (id == .config) {
            try w.writeAll("\n          ");
            var lines = std.mem.splitScalar(u8, option.about, '\n');
            var first = true;
            while (lines.next()) |line| {
                if (!first) try w.writeAll("\n          ");
                first = false;
                try w.writeAll(line);
            }
        } else {
            try w.splatByteAll(' ', width + 2 - text.len - 4);
            try w.writeAll(option.about);
        }
        const possible = values(option.kind);
        if (possible.len != 0) try w.print(" [possible values: {s}]", .{try std.mem.join(a, ", ", possible)});
        try w.writeByte('\n');
    }
    return out.toOwnedSlice();
}

test "normalized option lookup shares command options and built-ins" {
    for (specs) |s| {
        for (s.options) |o| {
            try std.testing.expectEqual(o.id, findOption(s.id, .{ .long = o.long }).?.id);
            if (o.short) |short| try std.testing.expectEqual(o.id, findOption(s.id, .{ .short = short }).?.id);
        }
        try std.testing.expectEqual(OptionId.help, findOption(s.id, .{ .long = "help" }).?.id);
        try std.testing.expectEqual(OptionId.help, findOption(s.id, .{ .short = 'h' }).?.id);
        if (s.id != .root) {
            try std.testing.expect(findOption(s.id, .{ .long = "version" }) == null);
            try std.testing.expect(findOption(s.id, .{ .short = 'V' }) == null);
        }
    }
    try std.testing.expectEqual(OptionId.version, findOption(.root, .{ .long = "version" }).?.id);
    try std.testing.expectEqual(OptionId.version, findOption(.root, .{ .short = 'V' }).?.id);
    try std.testing.expect(findOption(.root, .{ .long = "paths" }) == null);
    try std.testing.expect(findOption(.config, .{ .long = "paths=value" }) == null);
    try std.testing.expect(findOption(.config, .{ .short = '?' }) == null);
}
