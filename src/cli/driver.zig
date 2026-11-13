const std = @import("std");
const cli = @import("cli");
const config = @import("config");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    const completed = cli.complete(init.io, a, argv, init.environ_map) catch |err| {
        if (cli.failure) |d| {
            try std.Io.File.stderr().writeStreamingAll(init.io, d.text);
            std.process.exit(d.exit_code);
        }
        return err;
    };
    if (completed) return;
    const parsed = try cli.parseDetailed(a, argv[1..]);
    const command = switch (parsed) {
        .command => |c| c,
        .diagnostic => |d| {
            try std.Io.File.stderr().writeStreamingAll(init.io, d.text);
            std.process.exit(d.exit_code);
        },
    };
    switch (command) {
        .version => {
            try std.Io.File.stdout().writeStreamingAll(init.io, "tmux-sessionizer 0.6.1\n");
            return;
        },
        .help => |path| {
            try std.Io.File.stdout().writeStreamingAll(init.io, try cli.help(a, path));
            return;
        },
        else => {},
    }
    var cfg = switch (try config.loadDetailed(init.io, a, init.environ_map)) {
        .config => |c| c,
        .diagnostic => |d| {
            try std.Io.File.stderr().writeStreamingAll(init.io, d.text);
            std.process.exit(d.exit_code);
        },
    };
    run(init.io, a, init.environ_map, command, &cfg) catch |err| {
        if (config.editDiagnostic(err)) |d| {
            try std.Io.File.stderr().writeStreamingAll(init.io, d.text);
            std.process.exit(d.exit_code);
        }
        return err;
    };
}

fn run(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, command: cli.Command, cfg: *config.Config) !void {
    switch (command) {
        .config => |c| switch (c) {
            .list => |l| {
                try std.Io.File.stdout().writeStreamingAll(io, try config.exportToml(a, cfg, l.defaults));
                try std.Io.File.stdout().writeStreamingAll(io, "\n");
            },
            .edit => |e| {
                try config.commit(io, a, env, cfg, .{ .settings = e });
                try std.Io.File.stdout().writeStreamingAll(io, "Configuration has been stored\n");
            },
        },
        .bookmark => |b| {
            const path = b.path orelse try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
            try config.commit(io, a, env, cfg, if (b.delete) .{ .delete_bookmark = path } else .{ .add_bookmark = path });
        },
        .marks => |m| switch (m) {
            .list => {
                for (try config.validMarks(io, a, env, cfg)) |mark| {
                    try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.allocPrint(a, "{d}: {s} ({s})\n", .{ mark.index, std.fs.path.basename(mark.path), mark.path }));
                }
            },
            .set => |s| try config.commit(io, a, env, cfg, .{ .set_mark = .{ .index = s.index, .path = s.path orelse try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a) } }),
            .delete => |index| try config.commit(io, a, env, cfg, .{ .delete_mark = index }),
            .clear => try config.commit(io, a, env, cfg, .clear_marks),
            .open => return error.DriverDoesNotOpenSessions,
        },
        else => return error.DriverOnlySupportsConfiguration,
    }
}
