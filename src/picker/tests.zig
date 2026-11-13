const std = @import("std");
const picker = @import("../picker.zig");
const config = @import("config");
const a = std.testing.allocator;
const bindings = [_]config.Binding{
    .{ .key = .{ .code = .left }, .action = .cursor_left },
    .{ .key = .{ .code = .right }, .action = .cursor_right },
    .{ .key = .{ .code = .up }, .action = .move_up },
    .{ .key = .{ .code = .down }, .action = .move_down },
    .{ .key = .{ .code = .backspace }, .action = .backspace },
    .{ .key = .{ .code = .delete }, .action = .delete },
    .{ .key = .{ .code = .enter }, .action = .confirm },
    .{ .key = .{ .code = .esc }, .action = .cancel },
};
const options: config.PickerOptions = .{ .colors = .{}, .input_position = .bottom, .bindings = &bindings };

fn key(state: *picker.State, code: config.KeyCode) !picker.Transition {
    return picker.reduce(a, state, .{ .key = .{ .code = code } }, options);
}

fn insert(state: *picker.State, value: []const u8) !void {
    var it = (try std.unicode.Utf8View.init(value)).iterator();
    while (it.nextCodepoint()) |scalar| {
        try std.testing.expectEqual(picker.Transition.rematch, try key(state, .{ .char = scalar }));
    }
}

test "editing uses scalar indices and preserves original UTF-8 bytes" {
    var state: picker.State = .{ .size = .{ .width = 80, .height = 24 } };
    defer state.query.deinit(a);
    try insert(&state, "ä🙂c");
    try std.testing.expectEqual(@as(usize, 3), state.scalar_cursor);
    _ = try key(&state, .left);
    _ = try key(&state, .backspace);
    try std.testing.expectEqualStrings("äc", state.query.items);
    try insert(&state, "界");
    try std.testing.expectEqualStrings("ä界c", state.query.items);
    _ = try key(&state, .delete);
    try std.testing.expectEqualStrings("ä界", state.query.items);
    _ = try key(&state, .right);
    try std.testing.expectEqual(@as(usize, 2), state.scalar_cursor);
}

test "selection wraps in both input directions and clamps matches" {
    var state: picker.State = .{ .size = .{ .width = 80, .height = 3 } };
    _ = try picker.reduce(a, &state, .{ .matches = &.{ 4, 1, 2 } }, options);
    _ = try key(&state, .down);
    try std.testing.expectEqual(@as(?usize, 2), state.selection);
    try std.testing.expectEqual(@as(usize, 2), state.scroll);
    _ = try key(&state, .up);
    try std.testing.expectEqual(@as(?usize, 0), state.selection);
    var top = options;
    top.input_position = .top;
    _ = try picker.reduce(a, &state, .{ .key = .{ .code = .down } }, top);
    try std.testing.expectEqual(@as(?usize, 1), state.selection);
    _ = try picker.reduce(a, &state, .{ .matches = &.{4} }, options);
    try std.testing.expectEqual(@as(?usize, 0), state.selection);
    _ = try picker.reduce(a, &state, .{ .matches = &.{} }, options);
    try std.testing.expect(state.selection == null);
    try std.testing.expectEqual(picker.Transition.unchanged, try key(&state, .enter));
    _ = try picker.reduce(a, &state, .{ .matches = &.{2} }, options);
    try std.testing.expectEqual(picker.Transition.confirm, try key(&state, .enter));
    try std.testing.expectEqual(picker.Transition.cancel, try key(&state, .esc));
}

test "all mapped edits consume the key without insertion" {
    const actions = [_]config.PickerAction{
        .noop,               .delete_word,      .delete_to_line_start, .delete_to_line_end,
        .move_to_line_start, .move_to_line_end,
    };
    for (actions) |action| {
        var state: picker.State = .{ .size = .{ .width = 80, .height = 24 } };
        defer state.query.deinit(a);
        try insert(&state, "what's a wörd  ");
        const custom = [_]config.Binding{.{ .key = .{ .code = .{ .char = 'x' } }, .action = action }};
        var opts = options;
        opts.bindings = &custom;
        _ = try picker.reduce(a, &state, .{ .key = .{ .code = .{ .char = 'x' } } }, opts);
        const expected = switch (action) {
            .delete_word => "what's a ",
            .delete_to_line_start => "",
            else => "what's a wörd  ",
        };
        try std.testing.expectEqualStrings(expected, state.query.items);
    }
}

test "tiny terminal sizes and empty lists are safe" {
    const render = @import("render.zig");
    for (0..5) |width| for (0..5) |height| {
        var state: picker.State = .{ .size = .{ .width = @intCast(width), .height = @intCast(height) } };
        _ = try picker.reduce(a, &state, .{ .resize = state.size }, options);
        const frame = try render.draw(a, state, &.{}, options, "");
        a.free(frame);
        const preview_frame = try render.draw(a, state, &.{.{ .id = 1, .label = "x", .preview = .{ .directory = "/" } }}, options, "preview");
        a.free(preview_frame);
    };
}

test "every editing action handles a scalar cursor in the middle of a line" {
    const Case = struct {
        action: config.PickerAction,
        before: []const u8 = "äbc",
        cursor: usize = 2,
        after: []const u8,
        after_cursor: usize,
    };
    const cases = [_]Case{
        .{ .action = .noop, .after = "äbc", .after_cursor = 2 },
        .{ .action = .backspace, .after = "äc", .after_cursor = 1 },
        .{ .action = .delete, .after = "äb", .after_cursor = 2 },
        .{ .action = .cursor_left, .after = "äbc", .after_cursor = 1 },
        .{ .action = .cursor_right, .after = "äbc", .after_cursor = 3 },
        .{ .action = .delete_to_line_start, .after = "c", .after_cursor = 0 },
        .{ .action = .delete_to_line_end, .after = "äb", .after_cursor = 2 },
        .{ .action = .move_to_line_start, .after = "äbc", .after_cursor = 0 },
        .{ .action = .move_to_line_end, .after = "äbc", .after_cursor = 3 },
        .{ .action = .delete_word, .before = "one wörd  two", .cursor = 10, .after = "one two", .after_cursor = 4 },
        .{ .action = .delete_word, .before = "one wörd  two", .cursor = 8, .after = "one   two", .after_cursor = 4 },
        .{ .action = .delete_word, .before = "   ", .cursor = 3, .after = "", .after_cursor = 0 },
        .{ .action = .delete_word, .before = "x\u{2003}y", .cursor = 3, .after = "", .after_cursor = 0 },
        .{ .action = .delete_word, .cursor = 0, .after = "äbc", .after_cursor = 0 },
        .{ .action = .backspace, .cursor = 0, .after = "äbc", .after_cursor = 0 },
        .{ .action = .delete, .cursor = 3, .after = "äbc", .after_cursor = 3 },
    };
    for (cases) |case| {
        var state: picker.State = .{ .size = .{ .width = 80, .height = 24 } };
        defer state.query.deinit(a);
        try state.query.appendSlice(a, case.before);
        state.scalar_cursor = case.cursor;
        const binding = [_]config.Binding{.{ .key = .{ .code = .{ .char = 'x' } }, .action = case.action }};
        var opts = options;
        opts.bindings = &binding;
        _ = try picker.reduce(a, &state, .{ .key = binding[0].key }, opts);
        try std.testing.expectEqualStrings(case.after, state.query.items);
        try std.testing.expectEqual(case.after_cursor, state.scalar_cursor);
    }
}

test "display cursor uses cells while edits retain scalar positions" {
    const render = @import("render.zig");
    var state: picker.State = .{ .size = .{ .width = 80, .height = 24 } };
    defer state.query.deinit(a);
    try insert(&state, "界e\u{301}");
    try std.testing.expectEqual(@as(usize, 3), state.scalar_cursor);
    var frame = try render.draw(a, state, &.{}, options, "");
    try std.testing.expect(std.mem.endsWith(u8, frame, "\x1b[24;6H\x1b[?25h"));
    a.free(frame);
    _ = try key(&state, .left);
    _ = try key(&state, .left);
    frame = try render.draw(a, state, &.{}, options, "");
    defer a.free(frame);
    try std.testing.expect(std.mem.endsWith(u8, frame, "\x1b[24;5H\x1b[?25h"));
}

test "mapped modified printable keys do not change the query" {
    var state: picker.State = .{ .size = .{ .width = 80, .height = 24 } };
    defer state.query.deinit(a);
    const mapped: config.Key = .{ .code = .{ .char = 'x' }, .modifiers = .{ .ctrl = true, .alt = true } };
    const binding = [_]config.Binding{.{ .key = mapped, .action = .noop }};
    var opts = options;
    opts.bindings = &binding;
    try std.testing.expectEqual(picker.Transition.unchanged, try picker.reduce(a, &state, .{ .key = mapped }, opts));
    try std.testing.expectEqualStrings("", state.query.items);
    try std.testing.expectEqual(picker.Transition.rematch, try key(&state, .{ .char = 'x' }));
    try std.testing.expectEqualStrings("x", state.query.items);
}
