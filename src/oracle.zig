const std = @import("std");
const matcher = @import("matcher");

pub fn main(init: std.process.Init) !void {
    var command = std.heap.ArenaAllocator.init(init.gpa);
    defer command.deinit();
    const a = command.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 3 or !std.mem.eql(u8, args[1], "rank")) {
        try std.Io.File.stderr().writeStreamingAll(init.io, "usage: tms-oracle rank QUERY ITEM...\n");
        std.process.exit(2);
    }
    const items: []const []const u8 = args[3..];
    const ranked = try matcher.rank(a, args[2], items);
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try writeRanked(&stdout.interface, items, ranked);
    try stdout.interface.flush();
}

fn writeRanked(writer: *std.Io.Writer, items: []const []const u8, ranked: []const usize) !void {
    for (ranked) |index| {
        try writer.writeAll(items[index]);
        try writer.writeByte('\n');
    }
}

test "oracle emits original labels in ranked order including duplicates" {
    const items = [_][]const u8{ "same", "é", "same" };
    const ranked = [_]usize{ 2, 1, 0 };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeRanked(&output.writer, &items, &ranked);
    try std.testing.expectEqualStrings("same\né\nsame\n", output.written());
}
