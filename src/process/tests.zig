const std = @import("std");
const process = @import("../process.zig");
const t = std.testing;
const io = t.io;
const a = t.allocator;

test "child helper" {
    var env = try t.environ.createMap(a);
    defer env.deinit();
    const mode = env.get("TMS_PROCESS_HELPER") orelse return;
    const path = env.get("TMS_PROCESS_CWD").?;
    const ignored = std.mem.endsWith(u8, mode, "ignore");
    const request: process.Request = .{
        .argv = &.{
            "/bin/sh", "-c",
            \\IFS= read -r line || line=EOF
            \\printf '%s|%s|%s' "$line" "$TMS_VALUE" "$PWD"
            \\printf 'stderr' >&2
            \\exit 37
        },
        .cwd = path,
        .env = &env,
        .stdin = if (ignored) .ignore else .inherit,
    };
    if (std.mem.eql(u8, mode, "failed")) {
        const before = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
        defer a.free(before);
        var missing = request;
        missing.argv = &.{"/does-not-exist/tms-test"};
        missing.stdin = .ignore;
        try t.expectError(error.FileNotFound, process.replace(io, missing));
        const after = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
        defer a.free(after);
        try t.expectEqualStrings(before, after);
    }
    if (std.mem.startsWith(u8, mode, "replace")) {
        var pid_buffer: [32]u8 = undefined;
        const pid = try std.fmt.bufPrint(&pid_buffer, "{d}\n", .{std.c.getpid()});
        try std.Io.File.stdout().writeStreamingAll(io, pid);
        var replacement = request;
        replacement.argv = &.{
            "/bin/sh", "-c",
            \\printf '%s\n' "$$"
            \\IFS= read -r line || line=EOF
            \\printf '%s|%s|%s' "$line" "$TMS_VALUE" "$PWD"
            \\printf 'stderr' >&2
            \\exit 37
        };
        try process.replace(io, replacement);
    }
    if (std.mem.startsWith(u8, mode, "inherit")) {
        const term = try process.inherit(io, request);
        std.process.exit(term.exited);
    }
    const output = try process.capture(io, a, request);
    try std.Io.File.stdout().writeStreamingAll(io, output.stdout);
    try std.Io.File.stderr().writeStreamingAll(io, output.stderr);
    std.process.exit(output.term.exited);
}

test "capture preserves literal argv and nonzero status" {
    const output = try process.capture(io, a, .{
        .argv = &.{
            "/bin/sh",                                                   "-c",
            "printf '%s\\n' \"$@\"; printf 'error output' >&2; exit 23", "argv0",
            "two words",                                                 "$(touch SHOULD_NOT_EXIST); * | > &",
            "",
        },
        .stdin = .ignore,
    });
    defer freeOutput(output);
    try t.expectEqual(@as(u8, 23), output.term.exited);
    try t.expectEqualStrings("two words\n$(touch SHOULD_NOT_EXIST); * | > &\n\n", output.stdout);
    try t.expectEqualStrings("error output", output.stderr);
}

test "capture drains both channels beyond pipe capacity" {
    const output = try process.capture(io, a, .{
        .argv = &.{
            "/bin/sh", "-c",
            \\i=0
            \\while [ "$i" -lt 10000 ]; do
            \\printf '0123456789abcdef0123456789abcdef'
            \\printf 'fedcba9876543210fedcba9876543210' >&2
            \\i=$((i+1))
            \\done
        },
        .stdin = .ignore,
    });
    defer freeOutput(output);
    try t.expect(output.term.success());
    try t.expectEqual(@as(usize, 320000), output.stdout.len);
    try t.expectEqual(@as(usize, 320000), output.stderr.len);
    for (output.stdout, 0..) |byte, index|
        try t.expectEqual("0123456789abcdef"[index % 16], byte);
    for (output.stderr, 0..) |byte, index|
        try t.expectEqual("fedcba9876543210"[index % 16], byte);
}

test "capture frees allocations on every allocation failure" {
    try t.checkAllAllocationFailures(a, captureAllocated, .{});
}

fn captureAllocated(allocator: std.mem.Allocator) !void {
    const output = try process.capture(io, allocator, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'stdout'; printf 'stderr' >&2" },
        .stdin = .ignore,
    });
    allocator.free(output.stdout);
    allocator.free(output.stderr);
}

test "allocation failure while a child fills both pipes does not hang" {
    for (0..8) |index| {
        var failing: t.FailingAllocator = .init(a, .{ .fail_index = index });
        const output = process.capture(io, failing.allocator(), .{
            .argv = &.{
                "/bin/sh", "-c",
                \\while :; do
                \\printf '0123456789012345678901234567890123456789012345678901234567890123456789'
                \\printf '0123456789012345678901234567890123456789012345678901234567890123456789' >&2
                \\done
            },
            .stdin = .ignore,
        });
        try t.expectError(error.OutOfMemory, output);
    }
}

test "capture and inherit preserve stdin cwd and environment" {
    try checkHelper("capture", false);
    try checkHelper("capture-ignore", true);
    try checkHelper("inherit", false);
    try checkHelper("inherit-ignore", true);
}

test "replace preserves PID streams cwd environment and stdin mode" {
    try checkHelper("replace", false);
    try checkHelper("replace-ignore", true);
    try checkHelper("failed", false);
}

test "capture inherits the parent environment and retains signal status" {
    var env = try t.environ.createMap(a);
    defer env.deinit();
    const output = try process.capture(io, a, .{
        .argv = &.{ "/bin/sh", "-c", "printf '%s' \"$HOME\"; kill -TERM $$" },
        .stdin = .ignore,
    });
    defer freeOutput(output);
    try t.expectEqualStrings(env.get("HOME") orelse "", output.stdout);
    try t.expectEqual(std.posix.SIG.TERM, output.term.signal);
}

fn checkHelper(mode: []const u8, ignored: bool) !void {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = "input\n" });
    const input = try temp.dir.openFile(io, "input", .{});
    defer input.close(io);
    const exe = try std.process.executablePathAlloc(io, a);
    defer a.free(exe);
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put("TMS_PROCESS_HELPER", mode);
    try env.put("TMS_PROCESS_CWD", path);
    try env.put("TMS_VALUE", "custom env");
    var child = try std.process.spawn(io, .{
        .argv = &.{exe},
        .environ_map = &env,
        .stdin = .{ .file = input },
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);
    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(a, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    try reader.fillRemaining(.{ .duration = .{ .clock = .awake, .raw = .fromSeconds(15) } });
    try reader.checkAnyError();
    const term = try child.wait(io);
    try t.expectEqual(@as(u8, 37), term.exited);
    var stdout = reader.reader(0).buffered();
    if (std.mem.startsWith(u8, mode, "replace")) {
        const first = std.mem.findScalar(u8, stdout, '\n').?;
        const rest = stdout[first + 1 ..];
        const second = std.mem.findScalar(u8, rest, '\n').?;
        try t.expectEqualStrings(stdout[0..first], rest[0..second]);
        stdout = rest[second + 1 ..];
    }
    const expected = try std.fmt.allocPrint(a, "{s}|custom env|{s}", .{ if (ignored) "EOF" else "input", path });
    defer a.free(expected);
    try t.expectEqualStrings(expected, stdout);
    try t.expect(std.mem.endsWith(u8, reader.reader(1).buffered(), "stderr"));
}

test "empty argv and missing programs are errors" {
    try t.expectError(error.EmptyArgv, process.capture(io, a, .{ .argv = &.{} }));
    try t.expectError(error.EmptyArgv, process.inherit(io, .{ .argv = &.{} }));
    try t.expectError(error.EmptyArgv, process.replace(io, .{ .argv = &.{} }));
    const missing = [_][]const u8{"/does-not-exist/tms-test"};
    try t.expectError(error.FileNotFound, process.capture(io, a, .{ .argv = &missing }));
    try t.expectError(error.FileNotFound, process.inherit(io, .{ .argv = &missing }));
    try t.expectError(error.FileNotFound, process.replace(io, .{ .argv = &missing, .stdin = .ignore }));
}

test "native move overwrites files and moves directories into destinations" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const from = try std.fs.path.join(a, &.{ root, "source space;$" });
    defer a.free(from);
    const to = try std.fs.path.join(a, &.{ root, "destination" });
    defer a.free(to);
    try temp.dir.writeFile(io, .{ .sub_path = "source space;$", .data = "new" });
    try temp.dir.writeFile(io, .{ .sub_path = "destination", .data = "old" });
    try process.movePath(io, a, from, to);
    try expectFile(temp.dir, "destination", "new");
    try t.expectError(error.FileNotFound, temp.dir.statFile(io, "source space;$", .{}));

    try temp.dir.createDirPath(io, "source space;$/nested");
    try temp.dir.writeFile(io, .{ .sub_path = "source space;$/nested/file", .data = "tree" });
    try temp.dir.deleteFile(io, "destination");
    try temp.dir.createDir(io, "destination", .default_dir);
    try process.movePath(io, a, from, to);
    try expectFile(temp.dir, "destination/source space;$/nested/file", "tree");
    try t.expectError(error.FileNotFound, temp.dir.statFile(io, "source space;$", .{}));

    try temp.dir.createDir(io, "source space;$", .default_dir);
    try t.expectError(error.DirNotEmpty, process.movePath(io, a, from, to));
    try t.expectEqual(std.Io.File.Kind.directory, (try temp.dir.statFile(io, "source space;$", .{})).kind);
}

test "native move preserves symlinks" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const from = try std.fs.path.join(a, &.{ root, "link" });
    defer a.free(from);
    const to = try std.fs.path.join(a, &.{ root, "moved" });
    defer a.free(to);
    try temp.dir.symLink(io, "missing target", "link", .{});
    try process.movePath(io, a, from, to);
    var buffer: [128]u8 = undefined;
    const len = try temp.dir.readLink(io, "moved", &buffer);
    try t.expectEqualStrings("missing target", buffer[0..len]);
}

test "native move crosses devices when a writable second filesystem is available" {
    var env = try t.environ.createMap(a);
    defer env.deinit();
    const second_root = env.get("TMS_TEST_CROSS_DEVICE_DIR") orelse
        if (@import("builtin").os.tag == .linux) "/dev/shm" else return error.SkipZigTest;
    var second = std.Io.Dir.openDirAbsolute(io, second_root, .{}) catch return error.SkipZigTest;
    defer second.close(io);
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const from = try std.fs.path.join(a, &.{ root, "source" });
    defer a.free(from);
    const unique = try std.fmt.allocPrint(a, "tms-process-{s}", .{temp.sub_path});
    defer a.free(unique);
    const to = try std.fs.path.join(a, &.{ second_root, unique });
    defer a.free(to);
    defer second.deleteTree(io, unique) catch {};
    try temp.dir.createDir(io, "source", .default_dir);
    try temp.dir.writeFile(io, .{ .sub_path = "source/file", .data = "cross device" });
    try temp.dir.symLink(io, "file", "source/link", .{});
    try t.expectError(error.CrossDevice, std.Io.Dir.cwd().rename(from, .cwd(), to, io));
    try process.movePath(io, a, from, to);
    try t.expectError(error.FileNotFound, temp.dir.statFile(io, "source", .{}));
    const moved_file = try std.fs.path.join(a, &.{ unique, "file" });
    defer a.free(moved_file);
    try expectFile(second, moved_file, "cross device");
    const moved_link = try std.fs.path.join(a, &.{ unique, "link" });
    defer a.free(moved_link);
    var buffer: [128]u8 = undefined;
    const len = try second.readLink(io, moved_link, &buffer);
    try t.expectEqualStrings("file", buffer[0..len]);
}

fn freeOutput(output: process.Output) void {
    a.free(output.stdout);
    a.free(output.stderr);
}

pub fn checkCopyFallback(move: anytype) !void {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const from = try std.fs.path.join(a, &.{ root, "source" });
    defer a.free(from);
    const to = try std.fs.path.join(a, &.{ root, "target" });
    defer a.free(to);
    try temp.dir.writeFile(io, .{ .sub_path = "source", .data = "new" });
    try temp.dir.writeFile(io, .{ .sub_path = "target", .data = "old" });
    try move(io, a, from, to);
    try expectFile(temp.dir, "target", "new");
    try t.expectError(error.FileNotFound, temp.dir.statFile(io, "source", .{}));
    try temp.dir.deleteFile(io, "target");
    try temp.dir.createDirPath(io, "source/nested");
    try temp.dir.writeFile(io, .{ .sub_path = "source/nested/file", .data = "tree" });
    try temp.dir.symLink(io, "nested/file", "source/link", .{});
    const nested = try std.fs.path.join(a, &.{ from, "nested", "invalid" });
    defer a.free(nested);
    try t.expectError(error.InvalidDestination, move(io, a, from, nested));
    try temp.dir.createDir(io, "target", .default_dir);
    try move(io, a, from, to);
    try expectFile(temp.dir, "target/nested/file", "tree");
    var link_buffer: [128]u8 = undefined;
    const len = try temp.dir.readLink(io, "target/link", &link_buffer);
    try t.expectEqualStrings("nested/file", link_buffer[0..len]);
    try t.expectError(error.FileNotFound, temp.dir.statFile(io, "source", .{}));

    try temp.dir.createDir(io, "source", .default_dir);
    try temp.dir.writeFile(io, .{ .sub_path = "source/keep", .data = "keep" });
    try t.expectError(error.DirNotEmpty, move(io, a, from, to));
    try expectFile(temp.dir, "source/keep", "keep");
    try temp.dir.deleteTree(io, "target");
    try temp.dir.writeFile(io, .{ .sub_path = "target", .data = "keep file" });
    try t.expectError(error.NotDir, move(io, a, from, to));
    try expectFile(temp.dir, "source/keep", "keep");
    try expectFile(temp.dir, "target", "keep file");

    try temp.dir.deleteTree(io, "source");
    try temp.dir.symLink(io, "missing target", "source", .{});
    try move(io, a, from, to);
    const moved_len = try temp.dir.readLink(io, "target", &link_buffer);
    try t.expectEqualStrings("missing target", link_buffer[0..moved_len]);
}

fn expectFile(dir: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    const bytes = try dir.readFileAlloc(io, path, a, .limited(1024));
    defer a.free(bytes);
    try t.expectEqualStrings(expected, bytes);
}
