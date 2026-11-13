const std = @import("std");
const sessions = @import("sessions");
const config = @import("config");
const tmux = @import("tmux");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    if (argv.len != 4 or !std.mem.startsWith(u8, argv[1], "tms-port-test-")) return error.UnsafeTestSocket;
    const client: tmux.Client = .{ .socket = argv[1], .inside_tmux = false };
    const entry: sessions.Session = .{ .key = argv[3], .name = argv[3], .source = .{ .bookmark = argv[2] } };
    const cfg: config.Config = .{};
    try sessions.open(init.io, a, entry, &client, &cfg);
}
