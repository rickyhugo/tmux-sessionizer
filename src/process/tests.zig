const std = @import("std");
const process = @import("../process.zig");
const t = std.testing;
const io = t.io;
const a = t.allocator;

test "child helper" {
    childHelper() catch |err| {
        std.debug.print("child helper failed: {t}\n", .{err});
        std.process.exit(1);
    };
}

fn childHelper() !void {
    var env = try t.environ.createMap(a);
    defer env.deinit();
    const mode = env.get("TMS_PROCESS_HELPER") orelse return;
    const path = env.get("TMS_PROCESS_CWD").?;
    if (std.mem.eql(u8, mode, "allocation-failure")) try checkOutputAllocationFailures(path, false);
    if (std.mem.eql(u8, mode, "term-oom")) try checkOutputAllocationFailures(path, true);
    if (std.mem.eql(u8, mode, "cancel")) try checkCaptureCancellation(path, .capture, false);
    if (std.mem.eql(u8, mode, "term-cancel")) try checkCaptureCancellation(path, .capture, true);
    if (std.mem.eql(u8, mode, "term-wait")) try checkCaptureCancellation(path, .capture_wait, true);
    if (std.mem.eql(u8, mode, "term-inherit")) try checkCaptureCancellation(path, .inherit, true);
    if (std.mem.startsWith(u8, mode, "quota-")) try checkReplacementSetupFailure(mode);
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
    if (std.mem.startsWith(u8, mode, "failed")) {
        const before = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
        defer a.free(before);
        const closed = std.mem.eql(u8, mode, "failed-closed");
        const flags = std.c.fcntl(0, std.posix.F.GETFD);
        try t.expect(flags >= 0);
        const saved = std.c.fcntl(0, std.posix.F.DUPFD_CLOEXEC, @as(c_int, 3));
        try t.expect(saved >= 0);
        defer _ = std.c.close(saved);
        if (closed) {
            try t.expectEqual(@as(c_int, 0), std.c.close(0));
        } else {
            try t.expectEqual(@as(c_int, 0), std.c.fcntl(0, std.posix.F.SETFD, flags | std.posix.FD_CLOEXEC));
        }
        var missing = request;
        missing.argv = &.{"/does-not-exist/tms-test"};
        missing.stdin = .ignore;
        if (std.mem.eql(u8, mode, "failed-cwd")) missing.cwd = "/does-not-exist/tms-cwd";
        try t.expectError(error.FileNotFound, process.replace(io, missing));
        if (closed) {
            try t.expectEqual(@as(c_int, -1), std.c.fcntl(0, std.posix.F.GETFD));
            try t.expectEqual(std.c.E.BADF, std.c.errno(@as(c_int, -1)));
            try std.Io.Threaded.dup2(saved, 0);
        } else {
            try t.expectEqual(flags | std.posix.FD_CLOEXEC, std.c.fcntl(0, std.posix.F.GETFD));
        }
        try t.expectEqual(@as(c_int, 0), std.c.fcntl(0, std.posix.F.SETFD, flags));
        const after = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
        defer a.free(after);
        try t.expectEqualStrings(before, after);
    }
    if (std.mem.startsWith(u8, mode, "replace")) {
        if (std.mem.eql(u8, mode, "replace-closed-ignore"))
            try t.expectEqual(@as(c_int, 0), std.c.close(0));
        var pid_buffer: [32]u8 = undefined;
        const pid = try std.fmt.bufPrint(&pid_buffer, "{d}\n", .{std.c.getpid()});
        try std.Io.File.stdout().writeStreamingAll(io, pid);
        var replacement = request;
        replacement.argv = &.{
            "/bin/sh", "-c",
            \\: <&0 || exit 91
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
    try checkHelper("allocation-failure", false);
}

test "capture OOM cleanup reaps a child ignoring TERM" {
    try checkHelper("term-oom", false);
}

fn outputFailingAllocator(backing: std.mem.Allocator, index: usize) t.FailingAllocator {
    // Successful remaps do not advance fail_index. Force growth through alloc,
    // otherwise Linux mremap can keep the infinite-output fixture alive.
    return .init(backing, .{ .fail_index = index, .resize_fail_index = 0 });
}

fn checkOutputAllocationFailures(path: []const u8, ignore_term: bool) !void {
    const pid_path = try std.fs.path.join(a, &.{ path, "allocation.pid" });
    defer a.free(pid_path);
    const first: usize = if (ignore_term) 2 else 0;
    for (first..8) |index| {
        std.Io.Dir.cwd().deleteFile(io, pid_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        var failing = outputFailingAllocator(a, index);
        const output = process.capture(io, failing.allocator(), .{
            .argv = &.{
                "/bin/sh", "-c",
                \\if [ "$1" = ignore ]; then trap '' TERM; fi
                \\printf '%s\n' $$ > allocation.pid
                \\while :; do
                \\printf '0123456789012345678901234567890123456789012345678901234567890123456789'
                \\printf '0123456789012345678901234567890123456789012345678901234567890123456789' >&2
                \\done
                ,
                "fixture", if (ignore_term) "ignore" else "default",
            },
            .stdin = .ignore,
            .cwd = path,
        });
        try t.expectError(error.OutOfMemory, output);
        try t.expect(failing.has_induced_failure);
        try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        const pid = readPid(pid_path) catch |err| {
            // Initial buffer allocation can fail before the shell starts.
            if (index < 2 and (err == error.FileNotFound or err == error.InvalidCharacter)) continue;
            return err;
        };
        try expectReaped(pid);
    }
}

test "capture cancellation kills and reaps a child filling both pipes" {
    try checkHelper("cancel", false);
}

test "capture cancellation reaps a child ignoring TERM" {
    try checkHelper("term-cancel", false);
}

test "capture wait cancellation reaps a child ignoring TERM after pipe EOF" {
    try checkHelper("term-wait", false);
}

test "inherit cancellation reaps a child ignoring TERM" {
    try checkHelper("term-inherit", false);
}

const CancellationMode = enum { capture, capture_wait, inherit };

const CaptureCancellation = struct {
    canceled: bool = false,
    mode: CancellationMode,
    ignore_term: bool,

    fn run(self: *CaptureCancellation, path: []const u8) void {
        const request: process.Request = .{
            .argv = &.{
                "/bin/sh",           "-c",
                \\if [ "$1" = ignore ]; then trap '' TERM; fi
                \\printf '%s\n' $$ > capture.pid
                \\if [ "$2" = capture_wait ]; then exec 1>&- 2>&-; fi
                \\if [ "$2" != capture ]; then while :; do :; done; fi
                \\while :; do printf 'stdout'; printf 'stderr' >&2; done
                ,
                "fixture",           if (self.ignore_term) "ignore" else "default",
                @tagName(self.mode),
            },
            .cwd = path,
            .stdin = .ignore,
        };
        if (self.mode == .inherit) {
            _ = process.inherit(io, request) catch |err| {
                self.canceled = err == error.Canceled;
                return;
            };
            return;
        }
        const output = process.capture(io, a, request) catch |err| {
            self.canceled = err == error.Canceled;
            return;
        };
        freeOutput(output);
    }
};

fn checkCaptureCancellation(path: []const u8, mode: CancellationMode, ignore_term: bool) !void {
    const pid_path = try std.fs.path.join(a, &.{ path, "capture.pid" });
    defer a.free(pid_path);
    var state: CaptureCancellation = .{ .mode = mode, .ignore_term = ignore_term };
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, CaptureCancellation.run, .{ &state, path });
    var pid: std.c.pid_t = 0;
    for (0..1000) |_| {
        pid = readPid(pid_path) catch |err| switch (err) {
            error.FileNotFound, error.InvalidCharacter => 0,
            else => return err,
        };
        if (pid != 0) break;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
    try t.expect(pid > 0);
    try std.Io.sleep(io, .fromMilliseconds(20), .awake);
    group.cancel(io);
    try t.expect(state.canceled);
    try expectReaped(pid);
}

fn readPid(path: []const u8) !std.c.pid_t {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(32));
    defer a.free(bytes);
    return std.fmt.parseInt(std.c.pid_t, std.mem.trim(u8, bytes, " \n"), 10);
}

fn expectReaped(pid: std.c.pid_t) !void {
    try t.expectEqual(@as(c_int, -1), std.c.kill(pid, @fromBackingInt(@intCast(0))));
    try t.expectEqual(std.c.E.SRCH, std.c.errno(@as(c_int, -1)));
}

test "output allocation failure cannot be bypassed by successful remaps" {
    var failing = outputFailingAllocator(remapping_allocator, 2);
    const result = process.capture(io, failing.allocator(), .{
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
    const observed: anyerror!void = if (result) |output| blk: {
        failing.allocator().free(output.stdout);
        failing.allocator().free(output.stderr);
        break :blk {};
    } else |err| err;
    try t.expectError(error.OutOfMemory, observed);
    try t.expect(failing.has_induced_failure);
    try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

// Model Linux's moving mremap even when the host allocator cannot grow in place.
const remapping_allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = remapAlloc,
        .resize = std.mem.Allocator.noResize,
        .remap = remapGrowing,
        .free = remapFree,
    },
};

fn remapAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    return a.rawAlloc(len, alignment, ra);
}

fn remapGrowing(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
    const replacement = a.rawAlloc(len, alignment, ra) orelse return null;
    @memcpy(replacement[0..@min(memory.len, len)], memory[0..@min(memory.len, len)]);
    a.rawFree(memory, alignment, ra);
    return replacement;
}

fn remapFree(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
    a.rawFree(memory, alignment, ra);
}

test "capture and inherit preserve stdin cwd and environment" {
    try checkHelper("capture", false);
    try checkHelper("capture-ignore", true);
    try checkHelper("inherit", false);
    try checkHelper("inherit-ignore", true);
}

test "inherit retains successful nonzero and signal termination data" {
    const successful = try process.inherit(io, .{ .argv = &.{ "/bin/sh", "-c", "exit 0" }, .stdin = .ignore });
    try t.expect(successful.success());
    const nonzero = try process.inherit(io, .{ .argv = &.{ "/bin/sh", "-c", "exit 23" }, .stdin = .ignore });
    try t.expect(nonzero == .exited);
    try t.expectEqual(@as(u8, 23), nonzero.exited);
    const signaled = try process.inherit(io, .{ .argv = &.{ "/bin/sh", "-c", "kill -TERM $$" }, .stdin = .ignore });
    try t.expect(signaled == .signal);
    try t.expectEqual(std.posix.SIG.TERM, signaled.signal);
}

test "replace preserves PID streams cwd environment and stdin mode" {
    try checkHelper("replace", false);
    try checkHelper("replace-ignore", true);
    try checkHelper("failed", false);
}

test "replace restores closed stdin after failed exec in an isolated child" {
    try checkHelper("failed-closed", false);
}

test "replace restores stdin descriptor flags and cwd after failed exec" {
    try checkHelper("failed-flags", false);
    try checkHelper("failed-cwd", false);
}

test "replace ignored stdin stays open across exec when initially closed" {
    try checkHelper("replace-closed-ignore", true);
}

test "replace restores stdin after descriptor setup failures in isolated children" {
    try checkHelper("quota-duplicate", false);
    try checkHelper("quota-null-open", false);
    try checkHelper("quota-closed-null-open", false);
    try checkHelper("quota-cwd-open", false);
}

fn checkReplacementSetupFailure(mode: []const u8) !void {
    const before = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    defer a.free(before);
    const flags = std.c.fcntl(0, std.posix.F.GETFD);
    try t.expect(flags >= 0);
    const saved = std.c.fcntl(0, std.posix.F.DUPFD_CLOEXEC, @as(c_int, 3));
    try t.expect(saved >= 0);
    defer _ = std.c.close(saved);
    const closed = std.mem.eql(u8, mode, "quota-closed-null-open") or
        std.mem.eql(u8, mode, "quota-cwd-open");
    if (closed) {
        try t.expectEqual(@as(c_int, 0), std.c.close(0));
    } else {
        try t.expectEqual(@as(c_int, 0), std.c.fcntl(0, std.posix.F.SETFD, flags | std.posix.FD_CLOEXEC));
    }
    const expected = if (std.mem.eql(u8, mode, "quota-duplicate"))
        error.DuplicateStdinFailed
    else
        error.ProcessFdQuotaExceeded;
    try t.expectError(expected, replaceAtFdLimit(mode));
    if (closed) {
        try t.expectEqual(@as(c_int, -1), std.c.fcntl(0, std.posix.F.GETFD));
        try t.expectEqual(std.c.E.BADF, std.c.errno(@as(c_int, -1)));
        try std.Io.Threaded.dup2(saved, 0);
    } else {
        try t.expectEqual(flags | std.posix.FD_CLOEXEC, std.c.fcntl(0, std.posix.F.GETFD));
    }
    try t.expectEqual(@as(c_int, 0), std.c.fcntl(0, std.posix.F.SETFD, flags));
    const after = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    defer a.free(after);
    try t.expectEqualStrings(before, after);
}

fn replaceAtFdLimit(mode: []const u8) !void {
    var limit: std.c.rlimit = undefined;
    try t.expectEqual(@as(c_int, 0), std.c.getrlimit(.NOFILE, &limit));
    defer _ = std.c.setrlimit(.NOFILE, &limit);
    var reduced = limit;
    reduced.cur = if (std.mem.eql(u8, mode, "quota-null-open"))
        @min(limit.cur, 64)
    else if (std.mem.eql(u8, mode, "quota-cwd-open"))
        1
    else
        0;
    try t.expectEqual(@as(c_int, 0), std.c.setrlimit(.NOFILE, &reduced));
    var occupied: [64]c_int = undefined;
    var count: usize = 0;
    defer for (occupied[0..count]) |fd| {
        _ = std.c.close(fd);
    };
    if (std.mem.eql(u8, mode, "quota-null-open")) {
        while (true) {
            const fd = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
            if (fd < 0) {
                try t.expectEqual(std.c.E.MFILE, std.c.errno(fd));
                break;
            }
            occupied[count] = fd;
            count += 1;
        }
        try t.expect(count > 0);
        count -= 1;
        try t.expectEqual(@as(c_int, 0), std.c.close(occupied[count]));
        // Exactly one slot: saving stdin succeeds, then opening /dev/null fails.
    }
    var descriptors: [64]c_int = undefined;
    for (&descriptors, 0..) |*flags, fd|
        flags.* = std.c.fcntl(@as(c_int, @intCast(fd)), std.posix.F.GETFD);
    const failure = process.replace(io, .{
        .argv = &.{"/does-not-exist/tms-test"},
        .cwd = ".",
        .stdin = .ignore,
    }) catch |err| err;
    for (descriptors, 0..) |flags, fd|
        try t.expectEqual(flags, std.c.fcntl(@as(c_int, @intCast(fd)), std.posix.F.GETFD));
    return failure;
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
    var finished = false;
    defer if (!finished) {
        // A failed regression must not leave its TERM-resistant fixture alive.
        for ([_][]const u8{ "allocation.pid", "capture.pid" }) |name| {
            const pid_path = std.fs.path.join(a, &.{ path, name }) catch continue;
            defer a.free(pid_path);
            const pid = readPid(pid_path) catch continue;
            _ = std.c.kill(pid, .KILL);
        }
    };
    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(a, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    const timeout_seconds: i64 = if (std.mem.startsWith(u8, mode, "term-")) 3 else 15;
    try reader.fillRemaining(.{ .duration = .{ .clock = .awake, .raw = .fromSeconds(timeout_seconds) } });
    try reader.checkAnyError();
    const term = try child.wait(io);
    if (!term.success() and !(term == .exited and term.exited == 37))
        std.debug.print("child helper {s}: {t}\n{s}", .{ mode, term, reader.reader(1).buffered() });
    try t.expect(term == .exited);
    try t.expectEqual(@as(u8, 37), term.exited);
    finished = true;
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
    second.createDir(io, unique, .default_dir) catch return error.SkipZigTest;
    const second_path = try a.dupeSentinel(u8, to, 0);
    defer a.free(second_path);
    const root_path = try a.dupeSentinel(u8, root, 0);
    defer a.free(root_path);
    const Metadata = @import("move.zig").Metadata;
    if ((try Metadata.read(root_path)).device == (try Metadata.read(second_path)).device)
        return error.SkipZigTest;
    try second.deleteDir(io, unique);
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

    try temp.dir.deleteFile(io, "target");
    try temp.dir.writeFile(io, .{ .sub_path = "outside", .data = "untouched" });
    try temp.dir.symLink(io, "outside", "target", .{});
    try temp.dir.writeFile(io, .{ .sub_path = "source", .data = "replacement" });
    try move(io, a, from, to);
    try expectFile(temp.dir, "target", "replacement");
    try expectFile(temp.dir, "outside", "untouched");
}

fn expectFile(dir: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    const bytes = try dir.readFileAlloc(io, path, a, .limited(1024));
    defer a.free(bytes);
    try t.expectEqualStrings(expected, bytes);
}
