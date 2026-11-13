const std = @import("std");
const config = @import("config");
const repos = @import("repos");
const tmux = @import("tmux");
const A = std.mem.Allocator;
const Io = std.Io;
const Env = std.process.Environ.Map;

pub const Index = usize;
pub const Source = union(enum) { repository: repos.RepoRef, bookmark: []const u8 };
pub const Session = struct { key: []const u8, name: []const u8, source: Source };
pub const Catalog = struct {
    entries: []const Session,
    by_key: std.StringHashMapUnmanaged(Index),
};

pub fn discover(io: Io, a: A, env: *const Env, cfg: *const config.Config) anyerror!Catalog {
    _ = .{ io, a, env, cfg };
    return error.NotImplemented;
}

pub fn orderedIndices(a: A, catalog: Catalog, snapshot: tmux.Snapshot, order: config.Order) anyerror![]const Index {
    _ = .{ a, catalog, snapshot, order };
    return error.NotImplemented;
}

pub fn fromPath(io: Io, a: A, env: *const Env, input_path: []const u8) anyerror!Session {
    _ = .{ io, a, env, input_path };
    return error.NotImplemented;
}

pub fn path(io: Io, a: A, entry: Session) anyerror![]const u8 {
    _ = .{ io, a, entry };
    return error.NotImplemented;
}

pub fn open(io: Io, a: A, entry: Session, client: *const tmux.Client, cfg: *const config.Config) anyerror!void {
    _ = .{ io, a, entry, client, cfg };
    return error.NotImplemented;
}
