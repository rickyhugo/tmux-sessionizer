const std = @import("std");
const repos = @import("../repos.zig");
const process = @import("process");
const io = std.testing.io;

test "discovery checks depth zero and stops at shallow markers without resolution" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root/.git/nested/.git");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/.git/damaged", .data = "not a repository" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, "root", a);
    for ([_]usize{ 0, 3 }) |depth| {
        const found = try repos.discover(io, a, .{ .roots = &.{.{ .path = root, .depth = depth }}, .excluded = &.{}, .providers = &.{.git} });
        try std.testing.expectEqual(@as(usize, 1), found.len);
        try std.testing.expectEqualStrings(root, found[0].path);
    }
}

test "discovery is breadth first and follows encountered symlink spelling with bounded cycles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root/deeper/second/.git");
    try tmp.dir.createDirPath(io, "root/first/.git");
    try tmp.dir.symLink(io, "first", "root/alias", .{ .is_directory = true });
    try tmp.dir.symLink(io, ".", "root/cycle", .{ .is_directory = true });
    try tmp.dir.symLink(io, "missing", "root/broken", .{ .is_directory = true });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, "root", a);
    const found = try repos.discover(io, a, .{ .roots = &.{.{ .path = root, .depth = 2 }}, .excluded = &.{}, .providers = &.{.git} });
    try std.testing.expectEqual(@as(usize, 5), found.len);
    try std.testing.expect(std.mem.endsWith(u8, found[0].path, "/first") or std.mem.endsWith(u8, found[0].path, "/alias"));
    var alias = false;
    var nested = false;
    for (found) |ref| {
        alias = alias or std.mem.endsWith(u8, ref.path, "/alias");
        nested = nested or std.mem.endsWith(u8, ref.path, "/deeper/second");
    }
    try std.testing.expect(alias and nested);
}

test "exclusions match whole paths literally and case sensitively including empty strings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root/keep/.git");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, "root", a);
    for ([_][]const u8{ "root", "kee", "" }) |pattern| {
        const found = try repos.discover(io, a, .{ .roots = &.{.{ .path = root, .depth = 2 }}, .excluded = &.{pattern}, .providers = &.{.git} });
        try std.testing.expectEqual(@as(usize, 0), found.len);
    }
    const found = try repos.discover(io, a, .{ .roots = &.{.{ .path = root, .depth = 2 }}, .excluded = &.{"KEEP"}, .providers = &.{.git} });
    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "provider order wins shallow detection and empty providers detect nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/.git");
    try tmp.dir.createDirPath(io, "repo/.jj/repo");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const path = try tmp.dir.realPathFileAlloc(io, "repo", arena.allocator());
    try std.testing.expectEqual(repos.Provider.git, (try repos.detect(io, path, &.{ .git, .jujutsu })).?.provider);
    try std.testing.expectEqual(repos.Provider.jujutsu, (try repos.detect(io, path, &.{ .jujutsu, .git })).?.provider);
    try std.testing.expectEqual(null, try repos.detect(io, path, &.{}));
}

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    root: []const u8,

    fn init() !Fixture {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena.deinit();
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", arena.allocator());
        return .{ .arena = arena, .tmp = tmp, .root = root };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn a(self: *Fixture) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn path(self: *Fixture, subpath: []const u8) ![]const u8 {
        return std.fs.path.join(self.a(), &.{ self.root, subpath });
    }

    fn run(self: *Fixture, cwd: []const u8, argv: []const []const u8) !void {
        const output = try process.capture(io, self.a(), .{ .argv = argv, .cwd = cwd, .stdin = .ignore });
        if (output.term != .exited or output.term.exited != 0) {
            std.debug.print("Fixture command failed {s}\n{s}\n", .{ argv[0], output.stderr });
            return error.FixtureCommandFailed;
        }
    }

    fn git(self: *Fixture, cwd: []const u8, args: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(self.a(), &.{
            "git",                     "-c",                         "user.name=tms-test", "-c",                       "user.email=tms-test@example.com",
            "-c",                      "protocol.file.allow=always", "-c",                 "core.hooksPath=/dev/null", "-c",
            "init.defaultBranch=main",
        });
        try argv.appendSlice(self.a(), args);
        try self.run(cwd, argv.items);
    }

    fn jj(self: *Fixture, cwd: []const u8, args: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(self.a(), &.{
            "jj", "--no-pager", "--config", "user.name='tms-test'", "--config", "user.email='tms-test@example.com'",
        });
        try argv.appendSlice(self.a(), args);
        try self.run(cwd, argv.items);
    }

    fn repo(self: *Fixture, subpath: []const u8) !repos.RepoRef {
        const path_ = try self.path(subpath);
        try self.git(self.root, &.{ "init", "--quiet", path_ });
        try self.git(path_, &.{ "commit", "--quiet", "--allow-empty", "-m", "initial" });
        return .{ .path = path_, .provider = .git };
    }
};

test "real git init clone and ignored clone failure" {
    var f = try Fixture.init();
    defer f.deinit();
    const fresh = try f.path("fresh");
    try repos.initRepo(io, f.a(), fresh);
    const ref = (try repos.detect(io, fresh, &.{.git})).?;
    const opened = try repos.resolve(io, f.a(), ref);
    try std.testing.expect(!opened.bare and !opened.linked);
    try std.testing.expectEqualStrings(fresh, opened.cwd);
    try std.testing.expectEqualStrings(try f.path("fresh/.git"), opened.metadata);
    const copied = try f.path("copied");
    try repos.cloneRepo(io, f.a(), fresh, copied);
    try std.testing.expect((try repos.detect(io, copied, &.{.git})) != null);
    const failed = try f.path("failed");
    try repos.cloneRepo(io, f.a(), try f.path("no-such-remote"), failed);
    var dir = try std.Io.Dir.cwd().openDir(io, failed, .{});
    dir.close(io);
    try std.testing.expectEqual(null, try repos.detect(io, failed, &.{.git}));
    try f.tmp.dir.writeFile(io, .{ .sub_path = "blocking-file", .data = "file" });
    try std.testing.expectError(error.GitError, repos.initRepo(io, f.a(), try f.path("blocking-file")));
}

test "real git linked checkouts are discovered separately and names use administrative IDs" {
    var f = try Fixture.init();
    defer f.deinit();
    const main = try f.repo("main");
    const linked = try f.path("different-checkout-name");
    try f.git(main.path, &.{ "worktree", "add", "-b", "topic-branch", linked });
    const ref = (try repos.detect(io, linked, &.{.git})).?;
    const opened = try repos.resolve(io, f.a(), ref);
    try std.testing.expect(opened.linked and !opened.bare);
    try std.testing.expectEqualStrings(linked, opened.cwd);
    const trees = try repos.worktrees(io, f.a(), main, .registered);
    try std.testing.expectEqual(@as(usize, 1), trees.len);
    try std.testing.expectEqualStrings("different-checkout-name", trees[0].name);
    try std.testing.expectEqualStrings(linked, trees[0].path);
    const from_linked = try repos.worktrees(io, f.a(), ref, .active_other);
    try std.testing.expectEqual(@as(usize, 1), from_linked.len);
    try std.testing.expectEqualStrings(linked, from_linked[0].path);
    const found = try repos.discover(io, f.a(), .{
        .roots = &.{.{ .path = f.root, .depth = 2 }},
        .excluded = &.{},
        .providers = &.{.git},
    });
    try std.testing.expectEqual(@as(usize, 2), found.len);
}

test "real git bare worktrees support relative metadata paths prunable records and colliding IDs" {
    var f = try Fixture.init();
    defer f.deinit();
    const bare = try f.path("bare");
    try f.git(f.root, &.{ "init", "--quiet", "--bare", bare });
    const ref: repos.RepoRef = .{ .path = bare, .provider = .git };
    const opened = try repos.resolve(io, f.a(), ref);
    try std.testing.expect(opened.bare and !opened.linked);
    try std.testing.expectEqualStrings(bare, opened.cwd);
    try f.git(bare, &.{ "config", "worktree.useRelativePaths", "true" });
    const one = try f.path("one/checkout");
    const two = try f.path("two/checkout");
    try f.git(bare, &.{ "worktree", "add", "--orphan", "-b", "branch-one", one });
    try f.git(bare, &.{ "worktree", "add", "--orphan", "-b", "branch-two", two });
    const pointer = try f.tmp.dir.readFileAlloc(io, "bare/worktrees/checkout/gitdir", f.a(), .unlimited);
    try std.testing.expect(std.mem.startsWith(u8, pointer, ".."));
    const linked = try repos.resolve(io, f.a(), .{ .path = one, .provider = .git });
    try std.testing.expect(linked.linked and !linked.bare);
    const trees = try repos.worktrees(io, f.a(), ref, .registered);
    try std.testing.expectEqual(@as(usize, 2), trees.len);
    try std.testing.expectEqualStrings("checkout", trees[0].name);
    try std.testing.expectEqualStrings("checkout1", trees[1].name);
    try std.testing.expectEqualStrings(one, trees[0].path);
    try std.testing.expectEqualStrings(two, trees[1].path);
    try f.tmp.dir.deleteTree(io, "one/checkout");
    try f.tmp.dir.createDirPath(io, "bare/worktrees/no-gitdir");
    try f.tmp.dir.createDirPath(io, "bare/worktrees/broken");
    try f.tmp.dir.writeFile(io, .{ .sub_path = "bare/worktrees/broken/gitdir", .data = "\n" });
    const stale = try repos.worktrees(io, f.a(), ref, .active_other);
    try std.testing.expectEqual(@as(usize, 3), stale.len);
    try std.testing.expect(stale[0].prunable);
    try std.testing.expect(stale[1].prunable);
    try std.testing.expect(!stale[2].prunable);
}

test "real git dotgit pointer to dotbare remains bare not linked" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.createDirPath(io, "project");
    const bare = try f.path("project/.bare");
    try f.git(f.root, &.{ "init", "--quiet", "--bare", bare });
    for ([_][]const u8{ "gitdir: .bare\n", try std.fmt.allocPrint(f.a(), "gitdir: {s}\n", .{bare}) }) |pointer| {
        try f.tmp.dir.writeFile(io, .{ .sub_path = "project/.git", .data = pointer });
        const ref = (try repos.detect(io, try f.path("project"), &.{.git})).?;
        const opened = try repos.resolve(io, f.a(), ref);
        try std.testing.expect(opened.bare and !opened.linked);
        try std.testing.expectEqualStrings(bare, opened.cwd);
    }
}

test "real git direct metadata and configured relative worktree resolve their checkout" {
    var f = try Fixture.init();
    defer f.deinit();
    const main = try f.repo("main");
    const metadata = try f.path("main/.git");
    const direct = try repos.resolve(io, f.a(), .{ .path = metadata, .provider = .git });
    try std.testing.expectEqualStrings(main.path, direct.cwd);
    try f.tmp.dir.createDirPath(io, "elsewhere");
    try f.git(main.path, &.{ "config", "core.worktree", "../../elsewhere" });
    const configured = try repos.resolve(io, f.a(), main);
    try std.testing.expectEqualStrings(try f.path("elsewhere"), configured.cwd);
}

test "real git submodules use recursive path basenames and omit uninitialized clones" {
    var f = try Fixture.init();
    defer f.deinit();
    const leaf = try f.repo("leaf-source");
    const middle = try f.repo("middle-source");
    try f.git(middle.path, &.{ "submodule", "add", "--name", "not-the-leaf-name", leaf.path, "nested/leaf.name" });
    try f.git(middle.path, &.{ "commit", "--quiet", "-am", "add leaf" });
    const parent = try f.repo("parent");
    try f.git(parent.path, &.{ "submodule", "add", "--name", "not-the-child-name", middle.path, "vendor/child.name" });
    try f.git(parent.path, &.{ "commit", "--quiet", "-am", "add child" });
    try f.git(parent.path, &.{ "submodule", "update", "--init", "--recursive" });
    const direct = try repos.submodules(io, f.a(), parent, false);
    try std.testing.expectEqual(@as(usize, 1), direct.len);
    try std.testing.expectEqualStrings("child.name", direct[0].name);
    const all = try repos.submodules(io, f.a(), parent, true);
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqualStrings("child.name>leaf.name", all[0].name);
    try std.testing.expectEqualStrings("child.name", all[1].name);
    try std.testing.expectEqualStrings(try f.path("parent/vendor/child.name/nested/leaf.name"), all[0].ref.path);
    const clone = try f.path("uninitialized");
    try repos.cloneRepo(io, f.a(), parent.path, clone);
    try std.testing.expectEqual(@as(usize, 0), (try repos.submodules(io, f.a(), .{ .path = clone, .provider = .git }, true)).len);
    try f.tmp.dir.deleteFile(io, "parent/.gitmodules");
    try std.testing.expectEqual(@as(usize, 1), (try repos.submodules(io, f.a(), parent, false)).len);
    try f.git(parent.path, &.{ "rm", "--cached", ".gitmodules" });
    try std.testing.expectEqual(@as(usize, 1), (try repos.submodules(io, f.a(), parent, false)).len);
    try f.git(parent.path, &.{ "checkout", "HEAD", "--", ".gitmodules" });
    try f.git(parent.path, &.{ "submodule", "deinit", "--force", "--all" });
    const deinitialized = try repos.submodules(io, f.a(), parent, false);
    try std.testing.expectEqual(@as(usize, 1), deinitialized.len);
    const reopened = try repos.resolve(io, f.a(), deinitialized[0].ref);
    try std.testing.expectEqualStrings(try f.path("parent/vendor/child.name"), reopened.cwd);
}

test "real selected broken provider never falls back to a valid colocated provider" {
    var f = try Fixture.init();
    defer f.deinit();
    const main = try f.repo("main");
    try f.tmp.dir.createDirPath(io, "main/.jj/repo");
    const ref = (try repos.detect(io, main.path, &.{ .jujutsu, .git })).?;
    try std.testing.expectEqual(repos.Provider.jujutsu, ref.provider);
    if (repos.resolve(io, f.a(), ref)) |_| return error.TestExpectedError else |_| {}
    _ = try repos.resolve(io, f.a(), main);
}

test "real jj registered store retains current stale records and the baseline linked-store failure" {
    var f = try Fixture.init();
    defer f.deinit();
    const main = try f.path("main");
    const linked = try f.path("linked");
    const stale = try f.path("stale");
    try f.jj(f.root, &.{ "git", "init", "--no-colocate", main });
    try f.jj(main, &.{ "workspace", "add", "--name", "topic", linked });
    try f.jj(main, &.{ "workspace", "add", "--name", "stale", stale });
    const ref: repos.RepoRef = .{ .path = main, .provider = .jujutsu };
    const opened = try repos.resolve(io, f.a(), ref);
    try std.testing.expect(opened.bare and !opened.linked);
    const linked_ref: repos.RepoRef = .{ .path = linked, .provider = .jujutsu };
    const linked_opened = try repos.resolve(io, f.a(), linked_ref);
    try std.testing.expect(linked_opened.bare and linked_opened.linked);
    try std.testing.expectEqualStrings(opened.metadata, linked_opened.metadata);
    try std.testing.expectError(error.NotDir, repos.worktrees(io, f.a(), linked_ref, .registered));
    try f.tmp.dir.writeFile(io, .{ .sub_path = "linked/.jj/repo", .data = "../../main/.jj/repo" });
    const relative = try repos.resolve(io, f.a(), linked_ref);
    try std.testing.expectEqualStrings(opened.metadata, relative.metadata);
    try f.tmp.dir.deleteTree(io, "stale");
    const registered = try repos.worktrees(io, f.a(), ref, .registered);
    try std.testing.expectEqual(@as(usize, 3), registered.len);
    try std.testing.expectEqualStrings("default", registered[0].name);
    try std.testing.expectEqualStrings("stale", registered[2].name);
    try std.testing.expect(!registered[2].prunable);
    const active = try repos.worktrees(io, f.a(), ref, .active_other);
    try std.testing.expectEqual(@as(usize, 1), active.len);
    try std.testing.expectEqualStrings("topic", active[0].name);
    try std.testing.expectEqualStrings(linked, active[0].path);
    const from_linked = try repos.worktrees(io, f.a(), linked_ref, .active_other);
    try std.testing.expectEqual(@as(usize, 1), from_linked.len);
    try std.testing.expectEqualStrings("default", from_linked[0].name);
    try f.jj(main, &.{ "workspace", "forget", "stale" });
    const forgotten = try repos.worktrees(io, f.a(), ref, .registered);
    try std.testing.expectEqual(@as(usize, 2), forgotten.len);
}

test "real jj active list rejects damaged nested workspaces instead of opening their ancestor" {
    var f = try Fixture.init();
    defer f.deinit();
    const main = try f.path("main");
    const nested = try f.path("main/nested");
    try f.jj(f.root, &.{ "git", "init", "--no-colocate", main });
    try f.jj(main, &.{ "workspace", "add", "--name", "nested", nested });
    try f.tmp.dir.deleteTree(io, "main/nested/.jj");
    const ref: repos.RepoRef = .{ .path = main, .provider = .jujutsu };
    try std.testing.expectEqual(@as(usize, 0), (try repos.worktrees(io, f.a(), ref, .active_other)).len);
    try std.testing.expectEqual(@as(usize, 2), (try repos.worktrees(io, f.a(), ref, .registered)).len);
}

test "real jj active workspace names retain spaces Unicode and exclude the current workspace" {
    var f = try Fixture.init();
    defer f.deinit();
    const main = try f.path("main");
    const linked = try f.path("linked");
    const name = "with space レポ";
    try f.jj(f.root, &.{ "git", "init", "--no-colocate", main });
    try f.jj(main, &.{ "workspace", "add", "--name", name, linked });
    const ref: repos.RepoRef = .{ .path = main, .provider = .jujutsu };
    const other = try repos.worktrees(io, f.a(), ref, .active_other);
    try std.testing.expectEqual(@as(usize, 1), other.len);
    try std.testing.expectEqualStrings(name, other[0].name);
    const from_linked = try repos.worktrees(io, f.a(), .{ .path = linked, .provider = .jujutsu }, .active_other);
    try std.testing.expectEqual(@as(usize, 1), from_linked.len);
    try std.testing.expectEqualStrings("default", from_linked[0].name);
}

test "real jj bare classification reads recorded empty root child without snapshotting files" {
    var f = try Fixture.init();
    defer f.deinit();
    const main = try f.path("main");
    try f.jj(f.root, &.{ "git", "init", "--no-colocate", main });
    const ref: repos.RepoRef = .{ .path = main, .provider = .jujutsu };
    try f.tmp.dir.writeFile(io, .{ .sub_path = "main/unrecorded", .data = "unrecorded" });
    try std.testing.expect((try repos.resolve(io, f.a(), ref)).bare);
    try f.jj(main, &.{"status"});
    try std.testing.expect(!(try repos.resolve(io, f.a(), ref)).bare);
    try f.jj(main, &.{"new"});
    try std.testing.expect(!(try repos.resolve(io, f.a(), ref)).bare);
    try std.testing.expectEqual(@as(usize, 0), (try repos.submodules(io, f.a(), ref, true)).len);
}
