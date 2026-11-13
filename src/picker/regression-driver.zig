const std = @import("std");
const picker = @import("picker");
const config = @import("config");

pub fn main(init: std.process.Init) !void {
    const bindings = [_]config.Binding{
        .{ .key = .{ .code = .esc }, .action = .cancel },
        .{ .key = .{ .code = .{ .char = 'c' }, .modifiers = .{ .ctrl = true } }, .action = .cancel },
        .{ .key = .{ .code = .left }, .action = .cursor_left },
        .{ .key = .{ .code = .right }, .action = .cursor_right },
        .{ .key = .{ .code = .backspace }, .action = .backspace },
    };
    const items = [_]picker.Item{.{ .id = 77, .label = "alpha" }};
    _ = try picker.choose(init.io, init.gpa, init.gpa, &items, .{
        .colors = .{},
        .input_position = .bottom,
        .bindings = &bindings,
    });
}
