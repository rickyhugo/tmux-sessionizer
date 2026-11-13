const std = @import("std");
const config = @import("config");
const process = @import("process");
const parsers = @import("repos/parsers.zig");
const A = std.mem.Allocator;
const Io = std.Io;

pub const Provider = config.VcsProvider;
pub const RepoRef = struct {
    path: []const u8,
    provider: Provider,
    git_metadata: ?[]const u8 = null,
};
pub const Search = struct {
    roots: []const config.SearchDirectory,
    excluded: ?[]const []const u8,
    providers: []const Provider,
};
pub const Resolved = struct {
    cwd: []const u8,
    metadata: []const u8,
    bare: bool,
    linked: bool,
};
pub const Worktree = struct { name: []const u8, path: []const u8, prunable: bool };
pub const WorkspaceSet = enum { active_other, registered };
pub const Submodule = struct { name: []const u8, ref: RepoRef };

pub fn discover(io: Io, a: A, search: Search) anyerror![]const RepoRef {
    var queue: std.ArrayList(config.SearchDirectory) = .empty;
    defer queue.deinit(a);
    try queue.appendSlice(a, search.roots);
    var found: std.ArrayList(RepoRef) = .empty;
    var next: usize = 0;
    while (next < queue.items.len) : (next += 1) {
        const current = queue.items[next];
        var excluded = false;
        if (search.excluded) |patterns| {
            if (!std.unicode.utf8ValidateSlice(current.path)) return error.NonUtf8Path;
            for (patterns) |pattern| {
                if (std.mem.indexOf(u8, current.path, pattern) != null) {
                    excluded = true;
                    break;
                }
            }
        }
        if (excluded) continue;
        if (try detect(io, current.path, search.providers)) |ref| {
            if (!std.unicode.utf8ValidateSlice(std.fs.path.basename(current.path))) return error.NonUtf8Path;
            try found.append(a, ref);
            continue;
        }
        if (current.depth == 0) continue;
        var dir = Io.Dir.cwd().openDir(io, current.path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.SymLinkLoop => continue,
            error.AccessDenied => {
                if (!std.unicode.utf8ValidateSlice(current.path)) return error.NonUtf8Path;
                var buffer: [1024]u8 = undefined;
                var writer = Io.File.stderr().writer(io, &buffer);
                try writer.interface.print("Warning: insufficient permissions to read '{s}'. Skipping directory...\n", .{current.path});
                try writer.interface.flush();
                continue;
            },
            else => return err,
        };
        defer dir.close(io);
        var entries = dir.iterate();
        while (try entries.next(io)) |entry| {
            const path = try std.fs.path.join(a, &.{ current.path, entry.name });
            try queue.append(a, .{ .path = path, .depth = current.depth - 1 });
        }
    }
    return found.toOwnedSlice(a);
}

pub fn detect(io: Io, path: []const u8, providers: []const Provider) anyerror!?RepoRef {
    for (providers) |provider| {
        var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        switch (provider) {
            .git => {
                var flags: u3 = 0;
                var entries = dir.iterate();
                while (entries.next(io) catch null) |entry| {
                    if (std.mem.eql(u8, entry.name, ".git")) return .{ .path = path, .provider = provider };
                    if (std.mem.eql(u8, entry.name, "HEAD") and entry.kind == .file) flags |= 1;
                    if (std.mem.eql(u8, entry.name, "objects") and entry.kind == .directory) flags |= 2;
                    if (std.mem.eql(u8, entry.name, "refs") and entry.kind == .directory) flags |= 4;
                    if (flags == 7) return .{ .path = path, .provider = provider };
                }
            },
            .jujutsu => {
                dir.access(io, ".jj/repo", .{}) catch continue;
                return .{ .path = path, .provider = provider };
            },
        }
    }
    return null;
}

pub fn resolve(io: Io, a: A, ref: RepoRef) anyerror!Resolved {
    switch (ref.provider) {
        .git => {
            const metadata = if (ref.git_metadata) |hint|
                try Io.Dir.cwd().realPathFileAlloc(io, hint, a)
            else
                try gitMetadata(io, a, ref.path);
            const common = try gitCommonDirectory(io, a, metadata);
            const common_config = try std.fs.path.join(a, &.{ common, "config" });
            const configured_bare = try process.capture(io, a, .{
                .argv = &.{ "git", "--git-dir", metadata, "--work-tree", metadata, "config", "--file", common_config, "--type=bool", "--get", "core.bare" },
                .cwd = metadata,
                .stdin = .ignore,
            });
            const dotgit = try std.fs.path.join(a, &.{ ref.path, ".git" });
            const bare = if (success(configured_bare.term))
                try parsers.boolean(line(configured_bare.stdout))
            else
                !exists(io, dotgit);
            const linked_metadata = !std.mem.eql(u8, common, metadata);
            var cwd = if (bare and !linked_metadata) metadata else ref.path;
            if (!bare) {
                const configured = try process.capture(io, a, .{
                    .argv = &.{ "git", "--git-dir", metadata, "--work-tree", metadata, "config", "--null", "--show-origin", "--path", "--get-all", "core.worktree" },
                    .cwd = metadata,
                    .stdin = .ignore,
                });
                var override: ?[]const u8 = null;
                if (success(configured.term)) {
                    var records = std.mem.splitScalar(u8, configured.stdout, 0);
                    while (records.next()) |origin| {
                        const value = records.next() orelse break;
                        if (!std.mem.startsWith(u8, origin, "file:")) continue;
                        const source = try std.fs.path.resolve(a, &.{ metadata, origin["file:".len..] });
                        if (!std.mem.startsWith(u8, source, metadata) or
                            source.len <= metadata.len or source[metadata.len] != std.fs.path.sep) continue;
                        override = value;
                    }
                }
                if (override) |value| {
                    cwd = try std.fs.path.resolve(a, &.{ metadata, value });
                } else if (!exists(io, dotgit) and std.mem.eql(u8, std.fs.path.basename(metadata), ".git")) {
                    cwd = std.fs.path.dirname(metadata) orelse return error.GitError;
                }
            }
            return .{
                .cwd = cwd,
                .metadata = metadata,
                .bare = bare,
                .linked = (!bare or linked_metadata) and isFile(io, dotgit),
            };
        },
        .jujutsu => {
            const marker = try std.fs.path.join(a, &.{ ref.path, ".jj/repo" });
            if (!exists(io, marker)) return error.GitError;
            const root = line(try jj(io, a, ref.path, &.{"root"}));
            _ = try jj(io, a, ref.path, &.{ "log", "--no-graph", "--limit", "0", "-r", "@", "-T", "\"\"" });
            const repo_path = try std.fs.path.join(a, &.{ root, ".jj/repo" });
            const linked = isFile(io, repo_path);
            const metadata = if (linked) blk: {
                const pointer = try Io.Dir.cwd().readFileAlloc(io, repo_path, a, .unlimited);
                const relative_to = std.fs.path.dirname(repo_path) orelse return error.GitError;
                break :blk try std.fs.path.resolve(a, &.{ relative_to, line(pointer) });
            } else repo_path;
            const bare = jj(io, a, ref.path, &.{
                "log", "--no-graph", "-r", "@", "-T", "self.empty() ++ \"\\0\" ++ self.parents().map(|parent| parent.root()).join(\"\\0\")",
            }) catch "";
            return .{
                .cwd = root,
                .metadata = metadata,
                .bare = std.mem.eql(u8, bare, "true\x00true"),
                .linked = linked,
            };
        },
    }
}

pub fn worktrees(io: Io, a: A, ref: RepoRef, set: WorkspaceSet) anyerror![]const Worktree {
    if (ref.provider == .jujutsu and set == .registered) {
        // Preserve the captured linked-workspace NotDir failure.
        const index = try std.fs.path.join(a, &.{ ref.path, ".jj/repo/workspace_store/index" });
        const bytes = try Io.Dir.cwd().readFileAlloc(io, index, a, .unlimited);
        return parsers.workspaceStore(a, bytes);
    }
    const repo = try resolve(io, a, ref);
    var result: std.ArrayList(Worktree) = .empty;
    switch (ref.provider) {
        .git => {
            const common = try gitCommonDirectory(io, a, repo.metadata);
            const admin = try std.fs.path.join(a, &.{ common, "worktrees" });
            var dir = Io.Dir.cwd().openDir(io, admin, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound => return &.{},
                else => return err,
            };
            defer dir.close(io);
            var entries = dir.iterate();
            while (try entries.next(io)) |entry| {
                const pointer = try std.fs.path.join(a, &.{ admin, entry.name, "gitdir" });
                if (!isFile(io, pointer)) continue;
                const bytes = Io.Dir.cwd().readFileAlloc(io, pointer, a, .unlimited) catch "";
                const path = parsers.worktreePath(a, pointer, bytes) catch "";
                try result.append(a, .{
                    .name = try a.dupe(u8, entry.name),
                    .path = path,
                    .prunable = path.len == 0 or !exists(io, path),
                });
            }
            std.mem.sort(Worktree, result.items, {}, struct {
                fn less(_: void, lhs: Worktree, rhs: Worktree) bool {
                    return std.mem.lessThan(u8, lhs.name, rhs.name);
                }
            }.less);
        },
        .jujutsu => {
            const current = try jjWorkspaceName(io, a, repo.cwd);
            const names = try jj(io, a, ref.path, &.{ "workspace", "list", "-T", "name.substr(0, name.len()) ++ \"\\0\"" });
            var split = std.mem.splitScalar(u8, names, 0);
            while (split.next()) |name| {
                if (name.len == 0 or std.mem.eql(u8, name, current)) continue;
                const option = try std.fmt.allocPrint(a, "--name={s}", .{name});
                const path = line(jj(io, a, ref.path, &.{ "workspace", "root", option }) catch continue);
                const other: RepoRef = .{ .path = path, .provider = .jujutsu };
                const opened = resolve(io, a, other) catch continue;
                const actual_name = jjWorkspaceName(io, a, opened.cwd) catch continue;
                try result.append(a, .{ .name = actual_name, .path = opened.cwd, .prunable = false });
            }
        },
    }
    return result.toOwnedSlice(a);
}

pub fn submodules(io: Io, a: A, ref: RepoRef, recursive: bool) anyerror![]const Submodule {
    if (ref.provider == .jujutsu) return &.{};
    const repo = try resolve(io, a, ref);
    var result: std.ArrayList(Submodule) = .empty;
    try appendSubmodules(io, a, repo, "", recursive, &result);
    return result.toOwnedSlice(a);
}

pub fn cloneRepo(io: Io, a: A, remote: []const u8, target: []const u8) anyerror!void {
    _ = a;
    try Io.Dir.cwd().createDirPath(io, target);
    _ = try process.inherit(io, .{
        .argv = &.{ "git", "clone", remote, target },
        .cwd = std.fs.path.dirname(target) orelse return error.GitError,
    });
}

pub fn initRepo(io: Io, a: A, target: []const u8, env: *const std.process.Environ.Map) anyerror!void {
    try @import("repos/init.zig").create(io, a, target, env);
}

fn appendSubmodules(io: Io, a: A, repo: Resolved, prefix: []const u8, recursive: bool, result: *std.ArrayList(Submodule)) anyerror!void {
    const modules = try moduleConfig(io, a, repo);
    for (modules) |module| {
        const path = try std.fs.path.resolve(a, &.{ repo.cwd, module.path });
        const dotgit = try std.fs.path.join(a, &.{ path, ".git" });
        const sub: RepoRef = .{
            .path = path,
            .provider = .git,
            .git_metadata = if (exists(io, dotgit)) null else try std.fs.path.join(a, &.{
                try gitCommonDirectory(io, a, repo.metadata), "modules", module.name,
            }),
        };
        const opened = resolve(io, a, sub) catch continue;
        if (opened.bare) continue;
        const basename = std.fs.path.basename(opened.cwd);
        const name = if (prefix.len == 0) basename else try std.fmt.allocPrint(a, "{s}>{s}", .{ prefix, basename });
        if (recursive) appendSubmodules(io, a, opened, name, true, result) catch {};
        try result.append(a, .{ .name = name, .ref = .{ .path = opened.cwd, .provider = .git, .git_metadata = opened.metadata } });
    }
}

fn gitMetadata(io: Io, a: A, path: []const u8) ![]const u8 {
    const dotgit = try std.fs.path.join(a, &.{ path, ".git" });
    const metadata = if (isFile(io, dotgit)) blk: {
        const pointer = try Io.Dir.cwd().readFileAlloc(io, dotgit, a, .unlimited);
        break :blk try parsers.gitdir(a, path, pointer);
    } else if (exists(io, dotgit)) dotgit else blk: {
        const head = try std.fs.path.join(a, &.{ path, "HEAD" });
        if (isFile(io, head)) break :blk path;
        return error.GitError;
    };
    return Io.Dir.cwd().realPathFileAlloc(io, metadata, a);
}

fn moduleConfig(io: Io, a: A, repo: Resolved) ![]const parsers.Module {
    const file = try std.fs.path.join(a, &.{ repo.cwd, ".gitmodules" });
    var source = [2][]const u8{ "--file", file };
    const stat = Io.Dir.cwd().statFile(io, file, .{ .follow_symlinks = false }) catch null;
    if (repo.bare or stat == null or stat.?.kind == .sym_link) {
        var blob: ?[]const u8 = null;
        for ([_][]const u8{ ":.gitmodules", "HEAD:.gitmodules" }) |candidate| {
            const probe = try process.capture(io, a, .{
                .argv = &.{ "git", "--git-dir", repo.metadata, "--work-tree", repo.metadata, "rev-parse", "--verify", candidate },
                .cwd = repo.metadata,
                .stdin = .ignore,
            });
            if (success(probe.term)) {
                blob = candidate;
                break;
            }
        }
        source = .{ "--blob", blob orelse return &.{} };
    }
    const output = try process.capture(io, a, .{
        .argv = &.{
            "git",          "--git-dir",               repo.metadata, "--work-tree", repo.metadata, "config", "--null", source[0], source[1],
            "--get-regexp", "^submodule\\..*\\.path$",
        },
        .cwd = repo.metadata,
        .stdin = .ignore,
    });
    if (!success(output.term)) {
        if (output.term == .exited and output.term.exited == 1) return &.{};
        return error.GitError;
    }
    return parsers.submoduleEntries(a, output.stdout);
}

fn gitCommonDirectory(io: Io, a: A, metadata: []const u8) ![]const u8 {
    const common = line(try checked(io, a, &.{
        "git", "--git-dir", metadata, "--work-tree", metadata, "rev-parse", "--path-format=absolute", "--git-common-dir",
    }, metadata));
    return Io.Dir.cwd().realPathFileAlloc(io, common, a);
}

fn jj(io: Io, a: A, cwd: []const u8, args: []const []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.appendSlice(a, &.{ "jj", "--ignore-working-copy", "--no-pager", "--color=never" });
    try argv.appendSlice(a, args);
    return checked(io, a, argv.items, cwd);
}

fn jjWorkspaceName(io: Io, a: A, cwd: []const u8) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ cwd, ".jj/working_copy/checkout" });
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    return parsers.checkoutName(bytes);
}

fn checked(io: Io, a: A, argv: []const []const u8, cwd: ?[]const u8) ![]const u8 {
    const output = try process.capture(io, a, .{ .argv = argv, .cwd = cwd, .stdin = .ignore });
    if (!success(output.term)) return error.GitError;
    return output.stdout;
}

fn success(term: std.process.Child.Term) bool {
    return term == .exited and term.exited == 0;
}

fn line(bytes: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, bytes, "\n")) bytes[0 .. bytes.len - 1] else bytes;
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn isFile(io: Io, path: []const u8) bool {
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

test {
    _ = parsers;
    _ = @import("repos/tests.zig");
}
