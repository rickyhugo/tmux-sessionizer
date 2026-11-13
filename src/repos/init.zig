const std = @import("std");
const process = @import("process");
const templates = @import("templates.zig");
const A = std.mem.Allocator;
const Io = std.Io;
const Env = std.process.Environ.Map;

pub fn create(io: Io, a: A, target: []const u8, env: *const Env) anyerror!void {
    const metadata = try std.fs.path.join(a, &.{ target, ".git" });
    defer a.free(metadata);
    if (Io.Dir.cwd().statFile(io, metadata, .{ .follow_symlinks = false })) |_| {
        return error.GitError;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return error.GitError,
    }

    var reference_env = try env.clone(a);
    defer reference_env.deinit();
    // gix uses explicit paths and GIT_CONFIG_COUNT, not git-config's file
    // override, Git's shell command parameters, or its test-only branch setting.
    for ([_][]const u8{
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_COMMON_DIR",
        "GIT_OBJECT_DIRECTORY",
        "GIT_CONFIG",
        "GIT_CONFIG_PARAMETERS",
        "GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME",
    }) |key| _ = reference_env.swapRemove(key);

    // gix create::into writes a fixed layout before init_opts opens config.
    // Keep Git initialization, but defer all ambient configuration until that
    // layout and its fallback HEAD exist. In particular, sharedRepository must
    // not change either permissions or the generated configuration.
    var layout_env = try reference_env.clone(a);
    defer layout_env.deinit();
    try layout_env.put("GIT_CONFIG_NOSYSTEM", "1");
    try layout_env.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try layout_env.put("GIT_CONFIG_COUNT", "0");
    _ = layout_env.swapRemove("GIT_DEFAULT_REF_FORMAT");
    const initialized = try process.capture(io, a, .{
        .argv = &.{ "git", "init", "--quiet", "--object-format=sha1", "--template=", "--initial-branch=main", "--shared=umask", target },
        .env = &layout_env,
        .stdin = .ignore,
    });
    if (!success(initialized)) return error.GitError;
    try templates.write(io, metadata);

    // Open the new repository's actual config sources only after creation,
    // matching gix init_opts. NUL termination retains invalid trailing newlines.
    const branch = try process.capture(io, a, .{
        .argv = &.{ "git", "--git-dir", metadata, "--work-tree", target, "config", "--null", "--get", "init.defaultBranch" },
        .env = &reference_env,
        .stdin = .ignore,
    });
    if (branch.term == .exited and branch.term.exited == 1) return;
    if (!success(branch) or !std.mem.endsWith(u8, branch.stdout, "\x00")) return error.GitError;
    const value = branch.stdout[0 .. branch.stdout.len - 1];
    if (std.mem.eql(u8, value, "main")) return;

    // gix Category::LocalBranch does not prefix an already-qualified name.
    // Its branch_name validation rejects HEAD but accepts leading hyphens in
    // the short name; use full-ref validation, not check-ref-format --branch.
    const qualified = if (std.mem.startsWith(u8, value, "refs/heads/"))
        try a.dupe(u8, value)
    else
        try std.fmt.allocPrint(a, "refs/heads/{s}", .{value});
    defer a.free(qualified);
    if (std.mem.eql(u8, qualified, "refs/heads/HEAD") or std.mem.indexOfScalar(u8, qualified, 0) != null)
        return error.GitError;
    const valid = try process.capture(io, a, .{
        .argv = &.{ "git", "check-ref-format", qualified },
        .env = &layout_env,
        .stdin = .ignore,
    });
    if (!success(valid)) return error.GitError;

    // init_opts replaces HEAD only after validation, with reflog writes disabled.
    const head = try std.fs.path.join(a, &.{ metadata, "HEAD" });
    defer a.free(head);
    const contents = try std.fmt.allocPrint(a, "ref: {s}\n", .{qualified});
    defer a.free(contents);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = head, .data = contents });
}

fn success(output: process.Output) bool {
    return output.term == .exited and output.term.exited == 0;
}
