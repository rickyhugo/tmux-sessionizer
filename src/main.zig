const std = @import("std");
const app = @import("app");
const cli = @import("cli");
const config = @import("config");

pub fn main(init: std.process.Init) !void {
    var command = std.heap.ArenaAllocator.init(init.gpa);
    defer command.deinit();
    const allocator = command.allocator();
    const argv = try init.minimal.args.toSlice(allocator);
    app.run(init.io, allocator, init.gpa, argv, init.environ_map) catch |err| {
        const diagnostic: config.Diagnostic = if (cli.failure) |failure|
            .{ .text = failure.text, .exit_code = failure.exit_code }
        else if (config.failure) |failure|
            failure
        else if (app.failure) |failure|
            switch (failure) {
                .session_not_found => |name| .{ .text = try std.fmt.allocPrint(allocator, "Error: Session {s} not found\n", .{name}) },
                .mark_not_found => |index| .{ .text = try std.fmt.allocPrint(allocator, "Error: Config Error\n╰╴Session with index {d} not found in marks\n", .{index}) },
                .no_search_path => .{ .text = "Error: Config Error\n╰╴No search path configured\n" },
                .invalid_repository_name => .{ .exit_code = 101, .text = "\npanic:\nRepository path contains '/'\nnote: run with `RUST_BACKTRACE=1` environment variable to display a backtrace\n" },
            }
        else
            config.editDiagnostic(err) orelse switch (err) {
                error.NotDir => .{ .text = "Error: IO Error\n╰─▶ Not a directory (os error 20)\n" },
                else => .{ .text = try std.fmt.allocPrint(allocator, "Error: {s}\n", .{@errorName(err)}) },
            };
        try std.Io.File.stderr().writeStreamingAll(init.io, diagnostic.text);
        std.process.exit(diagnostic.exit_code);
    };
}
