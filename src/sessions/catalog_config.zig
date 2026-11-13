const std = @import("std");
const config = @import("config_types");

pub const Config = config.Config;
pub const SearchDirectory = config.SearchDirectory;
pub const VcsProvider = config.VcsProvider;
pub const Order = config.Order;

pub fn searchRoots(_: std.Io, _: std.mem.Allocator, _: *const std.process.Environ.Map, cfg: *const Config) ![]const SearchDirectory {
    return cfg.search_dirs orelse &.{};
}

pub fn bookmarkPaths(_: std.Io, _: std.mem.Allocator, _: *const std.process.Environ.Map, cfg: *const Config) ![]const []const u8 {
    return cfg.bookmarks orelse &.{};
}
