const std = @import("std");
const picker = @import("picker.zig");
const config = @import("config");
const terminal = @import("picker/terminal.zig");
const render = @import("picker/render.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args);
    if (args.len > 1 and std.mem.eql(u8, args[1], "long-query")) return longQuery(init);
    const bindings = [_]config.Binding{
        .{ .key = .{ .code = .esc }, .action = .cancel },
        .{ .key = .{ .code = .{ .char = 'c' }, .modifiers = .{ .ctrl = true } }, .action = .cancel },
        .{ .key = .{ .code = .left }, .action = .cursor_left },
        .{ .key = .{ .code = .right }, .action = .cursor_right },
        .{ .key = .{ .code = .backspace }, .action = .backspace },
        .{ .key = .{ .code = .{ .char = 'x' }, .modifiers = .{ .ctrl = true } }, .action = .cancel },
        .{ .key = .{ .code = .back_tab, .modifiers = .{ .shift = true } }, .action = .cancel },
        .{ .key = .{ .code = .enter }, .action = .cancel },
        .{ .key = .{ .code = .{ .function = 1 } }, .action = .cancel },
    };
    const items = [_]picker.Item{.{ .id = 77, .label = "alpha" }};
    _ = try picker.choose(init.io, init.gpa, init.gpa, &items, .{
        .colors = .{},
        .input_position = .bottom,
        .bindings = &bindings,
    });
}

fn longQuery(init: std.process.Init) !void {
    var state: picker.State = .{ .size = .{ .width = 3, .height = 4 } };
    defer state.query.deinit(init.gpa);
    for (0..32767) |_| try state.query.appendSlice(init.gpa, "\u{2d31}\u{2d7f}");
    state.scalar_cursor = 65534;
    var tty = try terminal.Terminal.init();
    defer tty.deinit();
    try tty.write("RENDERING\n");
    const frame = try render.draw(init.gpa, state, &.{}, .{
        .colors = .{},
        .input_position = .bottom,
        .bindings = &.{},
    }, "");
    defer init.gpa.free(frame);
    try tty.write(frame);
    while (true) {
        _ = try tty.checkSignals();
        if (try tty.wait(100)) {
            var bytes: [128]u8 = undefined;
            _ = try tty.read(&bytes);
            return;
        }
    }
}
