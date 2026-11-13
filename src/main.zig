const std = @import("std");
const app = @import("app");

pub fn main(init: std.process.Init) !void {
    var command = std.heap.ArenaAllocator.init(init.gpa);
    defer command.deinit();
    const allocator = command.allocator();
    const argv = try init.minimal.args.toSlice(allocator);
    if (argv.len == 2 and std.mem.eql(u8, argv[1], "--version")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "tmux-sessionizer 0.6.1\n");
        return;
    }
    app.run(init.io, allocator, init.gpa, argv, init.environ_map) catch |err| {
        if (err == error.NotImplemented) {
            try std.Io.File.stderr().writeStreamingAll(init.io, "tms: NotImplemented (Zig port foundation)\n");
            std.process.exit(1);
        }
        return err;
    };
}
