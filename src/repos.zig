const std = @import("std");
const config = @import("config");
const A = std.mem.Allocator;
const Io = std.Io;

pub const Provider = config.VcsProvider;
pub const RepoRef = struct { path: []const u8, provider: Provider };
pub const Search = struct {
    roots: []const config.SearchDirectory,
    excluded: []const []const u8,
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
    _ = .{ io, a, search };
    return error.NotImplemented;
}

pub fn detect(io: Io, path: []const u8, providers: []const Provider) anyerror!?RepoRef {
    _ = .{ io, path, providers };
    return error.NotImplemented;
}

pub fn resolve(io: Io, a: A, ref: RepoRef) anyerror!Resolved {
    _ = .{ io, a, ref };
    return error.NotImplemented;
}

pub fn worktrees(io: Io, a: A, ref: RepoRef, set: WorkspaceSet) anyerror![]const Worktree {
    _ = .{ io, a, ref, set };
    return error.NotImplemented;
}

pub fn submodules(io: Io, a: A, ref: RepoRef, recursive: bool) anyerror![]const Submodule {
    _ = .{ io, a, ref, recursive };
    return error.NotImplemented;
}

pub fn cloneRepo(io: Io, a: A, remote: []const u8, target: []const u8) anyerror!void {
    _ = .{ io, a, remote, target };
    return error.NotImplemented;
}

pub fn initRepo(io: Io, a: A, target: []const u8) anyerror!void {
    _ = .{ io, a, target };
    return error.NotImplemented;
}
