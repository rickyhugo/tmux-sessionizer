const std = @import("std");
const cli = @import("cli");
const config = @import("config");
const repos = @import("repos");
const sessions = @import("sessions");
const tmux = @import("tmux");
const picker = @import("picker");
const process = @import("process");
const A = std.mem.Allocator;
const Io = std.Io;
const Env = std.process.Environ.Map;

pub const Failure = union(enum) {
    session_not_found: []const u8,
    mark_not_found: usize,
    no_search_path,
    invalid_repository_name,
};
pub threadlocal var failure: ?Failure = null;

const App = struct {
    io: Io,
    a: A,
    scratch: A,
    env: *const Env,
    cfg: *config.Config,
    client: tmux.Client,

    fn print(self: App, text: []const u8) !void {
        try std.Io.File.stdout().writeStreamingAll(self.io, text);
    }

    fn choose(self: App, items: []const picker.Item) !?usize {
        return picker.choose(self.io, self.a, self.scratch, items, try config.pickerOptions(self.a, self.cfg));
    }

    fn pick(self: App) !void {
        const catalog = try sessions.discover(self.io, self.a, self.env, self.cfg);
        const order = self.cfg.session_sort_order orelse .alphabetical;
        const snapshot: tmux.Snapshot = if (order == .last_attached)
            try self.client.snapshot(self.io, self.a)
        else
            .{ .sessions = &.{}, .current = null };
        const indices = try sessions.orderedIndices(self.a, catalog, snapshot, order);
        const items = try self.a.alloc(picker.Item, indices.len);
        for (indices, items) |index, *item| {
            const entry = catalog.entries[index];
            item.* = .{ .id = index, .label = entry.key, .active = sessions.activeTimestamp(entry.key, snapshot) != null };
        }
        if (try self.choose(items)) |index| try sessions.open(self.io, self.a, catalog.entries[index], &self.client, self.cfg);
    }

    fn start(self: App) !void {
        if (self.cfg.sessions) |startup| {
            for (startup) |session| {
                const session_path = if (session.path) |p| try config.expandPath(self.io, self.a, self.env, p) else null;
                _ = try self.client.newSession(self.io, self.a, session.name, session_path);
                if (session.windows) |startup_windows| {
                    for (startup_windows) |window| {
                        const p = if (window.path) |value| try config.expandPath(self.io, self.a, self.env, value) else null;
                        _ = try self.client.newWindow(self.io, self.a, window.name, p, null);
                        if (window.command) |text| _ = try self.client.sendKeys(self.io, self.a, text, null);
                    }
                    _ = try self.client.killWindow(self.io, self.a, ":1");
                }
            }
            try self.client.attach(self.io, self.a, null, null);
        } else {
            _ = try self.client.start(self.io, self.a);
        }
    }

    fn switchSession(self: App) !void {
        const snapshot = try self.client.snapshot(self.io, self.a);
        const available = try unattached(self.a, snapshot, self.cfg.session_sort_order orelse .alphabetical);
        const catalog: ?sessions.Catalog = if (self.cfg.switch_filter_unknown == true)
            try sessions.discover(self.io, self.a, self.env, self.cfg)
        else
            null;
        var items: std.ArrayList(picker.Item) = .empty;
        for (available, 0..) |entry, i| {
            if (catalog) |known| {
                if (!known.by_key.contains(entry.name)) continue;
            }
            try items.append(self.a, .{
                .id = i,
                .label = entry.name,
                .preview = .{ .pane = .{ .client = &self.client, .target = entry.name } },
            });
        }
        if (try self.choose(items.items)) |index| {
            const target = try std.mem.replaceOwned(u8, self.a, available[index].name, ".", "_");
            _ = try self.client.switchClient(self.io, self.a, target);
        }
    }

    fn windows(self: App) !void {
        const windows_list = try self.client.windows(self.io, self.a, null);
        var items: std.ArrayList(picker.Item) = .empty;
        for (windows_list, 0..) |window, i| {
            if (window.attached) continue;
            try items.append(self.a, .{
                .id = i,
                .label = try std.fmt.allocPrint(self.a, "{s} {s}", .{ window.id, window.name }),
                .preview = .{ .pane = .{ .client = &self.client, .target = window.id } },
            });
        }
        if (items.items.len == 0) try items.append(self.a, .{ .id = windows_list.len, .label = "" });
        if (try self.choose(items.items)) |index| {
            if (index < windows_list.len) _ = try self.client.selectWindow(self.io, self.a, windows_list[index].id);
        }
    }

    fn kill(self: App) !void {
        const snapshot = try self.client.snapshot(self.io, self.a);
        const current = if (snapshot.current) |s| s.name else "";
        const available = try unattached(self.a, snapshot, self.cfg.session_sort_order orelse .alphabetical);
        var target: ?[]const u8 = if (available.len > 0) available[0].name else null;
        if (self.cfg.default_session) |default| {
            if (!std.mem.eql(u8, default, current)) {
                for (available) |entry| {
                    if (std.mem.eql(u8, entry.name, default)) target = default;
                }
            }
        }
        if (target) |name| _ = try self.client.switchClient(self.io, self.a, name);
        _ = try self.client.killSession(self.io, self.a, current);
    }

    fn listSessions(self: App) !void {
        const snapshot = try self.client.listingSnapshot(self.io, self.a);
        try self.print(try sessionListing(self.a, snapshot));
        try self.io.sleep(.fromMilliseconds(100), .awake);
        _ = try self.client.refreshClient(self.io, self.a);
    }

    fn rename(self: App, name: []const u8) !void {
        const snapshot = try self.client.snapshot(self.io, self.a);
        const current = if (snapshot.current) |s| s.name else "";
        const panes = try self.client.panes(self.io, self.a);
        if (panes.len == 0) return error.NoCurrentPane;
        const destination = try std.mem.replaceOwned(u8, self.a, panes[0].cwd, current, name);
        process.movePath(self.io, self.a, panes[0].cwd, destination) catch {};
        for (panes) |pane| {
            const pane_path = try std.mem.replaceOwned(u8, self.a, pane.cwd, current, name);
            _ = try self.client.sendKeys(self.io, self.a, try std.fmt.allocPrint(self.a, "cd {s}", .{pane_path}), pane.index);
        }
        _ = try self.client.renameSession(self.io, self.a, name);
        try self.client.attach(self.io, self.a, null, destination);
    }

    fn refresh(self: App, requested: ?[]const u8) !void {
        const snapshot = try self.client.snapshot(self.io, self.a);
        const current = snapshot.current orelse return;
        const name = try std.mem.replaceOwned(u8, self.a, std.mem.trim(u8, requested orelse current.name, " \r\n"), "'", "");
        const existing = try self.client.windows(self.io, self.a, name);
        const providers: []const repos.Provider = self.cfg.vcs_providers orelse &.{.git};
        const ref = (repos.detect(self.io, current.path, providers) catch null) orelse return;
        const resolved = repos.resolve(self.io, self.a, ref) catch return;
        var count: usize = 0;
        const worktrees = repos.worktrees(self.io, self.a, ref, .active_other) catch &.{};
        for (worktrees) |tree| {
            var exists = false;
            for (existing) |window| {
                if (std.mem.eql(u8, window.name, tree.name)) exists = true;
            }
            if (exists) {
                count += 1;
                continue;
            }
            if (tree.prunable) continue;
            count += 1;
            _ = try self.client.newWindow(self.io, self.a, tree.name, tree.path, name);
        }
        if (!resolved.bare) {
            if ((try self.client.windows(self.io, self.a, name)).len <= count)
                _ = try self.client.newWindow(self.io, self.a, null, current.path, name);
        }
    }

    fn searchPath(self: App) !?[]const u8 {
        const roots = self.cfg.search_dirs orelse {
            failure = .no_search_path;
            return error.NoSearchPath;
        };
        var items: std.ArrayList(picker.Item) = .empty;
        for (roots, 0..) |root, i| {
            if (root.depth == 0) continue;
            try items.append(self.a, .{ .id = i, .label = root.path, .preview = .{ .directory = root.path } });
        }
        if (items.items.len == 0) {
            failure = .no_search_path;
            return error.NoSearchPath;
        }
        const index = if (items.items.len == 1) items.items[0].id else (try self.choose(items.items)) orelse return null;
        return try config.expandPath(self.io, self.a, self.env, roots[index].path);
    }

    fn creationName(self: App, name: []const u8, target: []const u8) ![]const u8 {
        const snapshot = try self.client.snapshot(self.io, self.a);
        for (snapshot.sessions) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                const parent = std.fs.path.basename(std.fs.path.dirname(target) orelse return error.InvalidRepositoryName);
                return std.fmt.allocPrint(self.a, "{s}/{s}", .{ parent, name });
            }
        }
        return name;
    }

    fn clone(self: App, args: @FieldType(cli.Command, "clone_repo")) !void {
        const root = if (args.path) |p| try std.Io.Dir.cwd().realPathFileAlloc(self.io, p, self.a) else (try self.searchPath()) orelse return;
        const name = args.name orelse try inferredName(args.repository);
        const target = if (std.fs.path.isAbsolute(name)) name else try std.fs.path.join(self.a, &.{ root, name });
        const previous = try self.client.attachedSession(self.io, self.a);
        try repos.cloneRepo(self.io, self.a, args.repository, target);
        const should_switch = switch (self.cfg.clone_repo_switch orelse .always) {
            .always => true,
            .never => false,
            .foreground => std.mem.eql(u8, previous, try self.client.attachedSession(self.io, self.a)),
        };
        const session_name = try self.creationName(name, target);
        _ = try self.client.newSession(self.io, self.a, session_name, target);
        if (should_switch) try self.client.switchTo(self.io, self.a, session_name);
    }

    fn initRepo(self: App, name: []const u8) !void {
        const root = (try self.searchPath()) orelse return;
        const target = if (std.fs.path.isAbsolute(name)) name else try std.fs.path.join(self.a, &.{ root, name });
        try repos.initRepo(self.io, self.a, target, self.env);
        const session_name = try self.creationName(name, target);
        _ = try self.client.newSession(self.io, self.a, session_name, target);
        try self.client.switchTo(self.io, self.a, session_name);
    }

    fn marks(self: App, cmd: cli.MarksCommand) !void {
        switch (cmd) {
            .list => {
                for (try config.validMarks(self.io, self.a, self.env, self.cfg)) |mark| {
                    const session = try sessions.fromPath(self.io, self.a, self.env, mark.path);
                    try self.print(try std.fmt.allocPrint(self.a, "{d}: {s} ({s})\n", .{ mark.index, session.name, try sessions.path(self.io, self.a, session) }));
                }
            },
            .set => |args| try config.commit(self.io, self.a, self.env, self.cfg, .{ .set_mark = .{ .index = args.index, .path = args.path orelse try self.cwd() } }),
            .open => |index| {
                const key = try std.fmt.allocPrint(self.a, "{d}", .{index});
                const value = if (self.cfg.marks) |map| map.get(key) else null;
                const p = value orelse {
                    failure = .{ .mark_not_found = index };
                    return error.MarkNotFound;
                };
                try sessions.open(self.io, self.a, try sessions.fromPath(self.io, self.a, self.env, p), &self.client, self.cfg);
            },
            .delete => |index| try config.commit(self.io, self.a, self.env, self.cfg, .{ .delete_mark = index }),
            .clear => try config.commit(self.io, self.a, self.env, self.cfg, .clear_marks),
        }
    }

    fn cwd(self: App) ![]const u8 {
        return std.Io.Dir.cwd().realPathFileAlloc(self.io, ".", self.a);
    }
};

fn inferredName(remote: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, remote, "/");
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse {
        failure = .invalid_repository_name;
        return error.InvalidRepositoryName;
    };
    var name = trimmed[slash + 1 ..];
    while (std.mem.endsWith(u8, name, ".git")) name = name[0 .. name.len - 4];
    return name;
}

fn sessionListing(a: A, snapshot: tmux.Snapshot) ![]const u8 {
    const current = if (snapshot.current) |s| s.name else "";
    var text: std.ArrayList(u8) = .empty;
    for (snapshot.sessions) |s| {
        try text.appendSlice(a, s.name);
        if (std.mem.eql(u8, current, s.name)) try text.append(a, '*');
        try text.append(a, ' ');
    }
    if (snapshot.sessions.len == 0 and current.len == 0) try text.append(a, '*');
    try text.appendSlice(a, " \n");
    return text.toOwnedSlice(a);
}

fn unattached(a: A, snapshot: tmux.Snapshot, order: config.Order) ![]const tmux.SessionInfo {
    var result: std.ArrayList(tmux.SessionInfo) = .empty;
    for (snapshot.sessions) |s| if (!s.attached) try result.append(a, s);
    if (order == .last_attached) {
        std.mem.sort(tmux.SessionInfo, result.items, {}, struct {
            fn less(_: void, lhs: tmux.SessionInfo, rhs: tmux.SessionInfo) bool {
                return std.mem.lessThan(u8, rhs.last_attached, lhs.last_attached);
            }
        }.less);
    }
    return result.toOwnedSlice(a);
}

pub fn run(io: Io, command: A, scratch: A, argv: []const []const u8, env: *const Env) anyerror!void {
    failure = null;
    if (try cli.complete(io, command, argv, env)) return;
    const cmd = try cli.parse(command, if (argv.len > 0) argv[1..] else &.{});
    switch (cmd) {
        .help => |path| {
            try std.Io.File.stdout().writeStreamingAll(io, try cli.help(command, path));
            return;
        },
        .version => {
            try std.Io.File.stdout().writeStreamingAll(io, "tmux-sessionizer " ++ @import("build_options").version ++ "\n");
            return;
        },
        else => {},
    }
    var cfg = try config.load(io, command, env);
    const app: App = .{
        .io = io,
        .a = command,
        .scratch = scratch,
        .env = env,
        .cfg = &cfg,
        .client = .{ .socket = env.get("TMS_TMUX_SOCKET") orelse "default", .inside_tmux = std.mem.eql(u8, env.get("TERM_PROGRAM") orelse "", "tmux") },
    };
    switch (cmd) {
        .pick => try app.pick(),
        .start => try app.start(),
        .switch_session => try app.switchSession(),
        .windows => try app.windows(),
        .kill => try app.kill(),
        .sessions => try app.listSessions(),
        .rename => |name| try app.rename(name),
        .refresh => |name| try app.refresh(name),
        .clone_repo => |args| try app.clone(args),
        .init_repo => |name| try app.initRepo(name),
        .bookmark => |args| {
            const p = args.path orelse try app.cwd();
            try config.commit(io, command, env, &cfg, if (args.delete) .{ .delete_bookmark = p } else .{ .add_bookmark = p });
        },
        .marks => |args| try app.marks(args),
        .config => |args| switch (args) {
            .edit => |edit| {
                try config.commit(io, command, env, &cfg, .{ .settings = edit });
                try app.print("Configuration has been stored\n");
            },
            .list => |list| {
                try app.print(try config.exportToml(command, &cfg, list.defaults));
                try app.print("\n");
            },
        },
        .open_session => |key| {
            const catalog = try sessions.discover(io, command, env, &cfg);
            const index = catalog.by_key.get(key) orelse {
                failure = .{ .session_not_found = key };
                return error.SessionNotFound;
            };
            try sessions.open(io, command, catalog.entries[index], &app.client, &cfg);
        },
        .help, .version => unreachable,
    }
}

test "switch and kill sort timestamp text rather than numbers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entries = try unattached(arena.allocator(), .{ .current = null, .sessions = &.{
        .{ .name = "ten", .attached = false, .last_attached = "10" },
        .{ .name = "nine", .attached = false, .last_attached = "9" },
        .{ .name = "current", .attached = true, .last_attached = "99" },
    } }, .last_attached);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("nine", entries[0].name);
}

test "clone inference trims trailing slash and repeated git suffix" {
    try std.testing.expectEqualStrings("project", try inferredName("host/team/project.git.git/"));
    try std.testing.expectError(error.InvalidRepositoryName, inferredName("project"));
}

test "session listing retains asterisk, trailing spaces, and empty server marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("* \n", try sessionListing(a, .{ .current = null, .sessions = &.{} }));
    try std.testing.expectEqualStrings("current* fallback  \n", try sessionListing(a, .{
        .current = .{ .name = "current", .path = "/current" },
        .sessions = &.{
            .{ .name = "current", .attached = true, .last_attached = "1" },
            .{ .name = "fallback", .attached = false, .last_attached = "0" },
        },
    }));
    try std.testing.expectEqualStrings("quo'te,ui*  \n", try sessionListing(a, .{
        .current = .{ .name = "quo'te,ui", .path = "/current" },
        .sessions = &.{.{ .name = "quo'te,ui", .attached = true, .last_attached = "1" }},
    }));
}
fn expectCall(index: usize, args: []const []const u8) !void {
    const actual = process.calls.items[index].request.argv;
    try std.testing.expectEqualStrings("tmux", actual[0]);
    try std.testing.expectEqualStrings("-L", actual[1]);
    try std.testing.expectEqualStrings("tms-app-fixture", actual[2]);
    try std.testing.expectEqual(args.len + 3, actual.len);
    for (args, actual[3..]) |want, got| try std.testing.expectEqualStrings(want, got);
}

fn fixtureApp(a: A, cfg: *config.Config, env: *const Env) App {
    return .{ .io = std.testing.io, .a = a, .scratch = std.testing.allocator, .env = env, .cfg = cfg, .client = .{ .socket = "tms-app-fixture", .inside_tmux = true } };
}

test "fixture startup creates windows, sends command, kills initial window, replaces attach" {
    if (!@hasDecl(process, "reset")) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = Env.init(a);
    var cfg: config.Config = .{ .sessions = &.{.{ .name = "startup", .windows = &.{.{ .name = "editor", .command = "vim" }} }} };
    process.reset(a, &.{});
    try std.testing.expectError(error.Replaced, fixtureApp(a, &cfg, &env).start());
    try expectCall(0, &.{ "new-session", "-d", "-s", "startup" });
    try expectCall(1, &.{ "new-window", "-n", "editor" });
    try expectCall(2, &.{ "send-keys", "vim", "Enter" });
    try expectCall(3, &.{ "kill-window", "-t", ":1" });
    try expectCall(4, &.{"attach-session"});
}

test "fixture absent startup sessions invokes tmux without a command" {
    if (!@hasDecl(process, "reset")) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = Env.init(a);
    var cfg: config.Config = .{};
    process.reset(a, &.{});
    try fixtureApp(a, &cfg, &env).start();
    try expectCall(0, &.{});
}

test "fixture kill chooses configured available fallback before killing current" {
    if (!@hasDecl(process, "reset")) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = Env.init(a);
    var cfg: config.Config = .{ .default_session = "ten", .session_sort_order = .last_attached };
    process.reset(a, &.{
        .{ .stdout = "'current,1,100'\n'nine,0,9'\n'ten,0,10'\n" },
        .{ .stdout = "'current'\n" },
        .{ .stdout = "'/work/current'\n" },
    });
    try fixtureApp(a, &cfg, &env).kill();
    try expectCall(3, &.{ "switch-client", "-t", "ten" });
    try expectCall(4, &.{ "kill-session", "-t", "current" });
}

test "fixture kill missing default uses lexical timestamp fallback" {
    if (!@hasDecl(process, "reset")) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = Env.init(a);
    var cfg: config.Config = .{ .default_session = "absent", .session_sort_order = .last_attached };
    process.reset(a, &.{
        .{ .stdout = "'current,1,100'\n'nine,0,9'\n'ten,0,10'\n" },
        .{ .stdout = "'current'\n" },
        .{ .stdout = "'/work/current'\n" },
    });
    try fixtureApp(a, &cfg, &env).kill();
    try expectCall(3, &.{ "switch-client", "-t", "nine" });
}

test "fixture rename ignores failed move, replaces every path occurrence, sends cd before rename" {
    if (!@hasDecl(process, "reset")) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = Env.init(a);
    var cfg: config.Config = .{};
    process.reset(a, &.{
        .{ .stdout = "'old,1,10'\n" },
        .{ .stdout = "'old'\n" },
        .{ .stdout = "'/work/old/old'\n" },
        .{ .stdout = "'1.0,sleep,/work/old/old'\n'2.0,vim,/work/old/old/sub'\n" },
    });
    try std.testing.expectError(error.Replaced, fixtureApp(a, &cfg, &env).rename("new"));
    try std.testing.expectEqual(.move, process.calls.items[4].kind);
    const moved = process.calls.items[4].request.argv;
    try std.testing.expectEqual(@as(usize, 2), moved.len);
    try std.testing.expectEqualStrings("/work/old/old", moved[0]);
    try std.testing.expectEqualStrings("/work/new/new", moved[1]);
    try expectCall(5, &.{ "send-keys", "-t", "1.0", "cd /work/new/new", "Enter" });
    try expectCall(6, &.{ "send-keys", "-t", "2.0", "cd /work/new/new/sub", "Enter" });
    try expectCall(7, &.{ "rename-session", "new" });
    try expectCall(8, &.{ "attach-session", "-c", "/work/new/new" });
    try std.testing.expectEqual(@as(usize, 9), process.calls.items.len);
}
