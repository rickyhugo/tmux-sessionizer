const std = @import("std");
const config = @import("config");
const tmux = @import("tmux");
const A = std.mem.Allocator;
const Io = std.Io;

pub const Item = struct {
    id: usize,
    label: []const u8,
    active: bool = false,
    preview: Preview = .none,
};
pub const Preview = union(enum) {
    none,
    pane: struct { client: *const tmux.Client, target: []const u8 },
    directory: []const u8,
};
pub const Size = struct { width: u16, height: u16 };
pub const State = struct {
    query: std.ArrayList(u8) = .empty,
    scalar_cursor: usize = 0,
    ranked: []const usize = &.{},
    selection: ?usize = null,
    scroll: usize = 0,
    size: Size,
};
pub const Event = union(enum) {
    key: config.Key,
    resize: Size,
    matches: []const usize,
};
pub const Transition = enum { unchanged, redraw, rematch, confirm, cancel };

pub fn reduce(a: A, state: *State, event: Event, options: config.PickerOptions) anyerror!Transition {
    _ = .{ a, state, event, options };
    return error.NotImplemented;
}

pub fn choose(io: Io, result: A, scratch: A, items: []const Item, options: config.PickerOptions) anyerror!?usize {
    _ = .{ io, result, scratch, items, options };
    return error.NotImplemented;
}
