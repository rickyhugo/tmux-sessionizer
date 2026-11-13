const std = @import("std");

// gix 0.85's fixed templates, rather than Git's ambient template directory.
// Source and license: template/README.md and template/LICENSE.
pub fn write(io: std.Io, metadata: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, metadata, .{});
    defer dir.close(io);
    inline for (.{
        "description",
        "info/exclude",
        "hooks/docs.url",
        "hooks/applypatch-msg.sample",
        "hooks/commit-msg.sample",
        "hooks/fsmonitor-watchman.sample",
        "hooks/post-update.sample",
        "hooks/pre-applypatch.sample",
        "hooks/pre-commit.sample",
        "hooks/pre-merge-commit.sample",
        "hooks/pre-push.sample",
        "hooks/pre-rebase.sample",
        "hooks/prepare-commit-msg.sample",
    }) |path| {
        if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
        try dir.writeFile(io, .{ .sub_path = path, .data = @embedFile("template/" ++ path) });
    }
}
