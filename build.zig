const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const config = module(b, "config", target, optimize);
    const tomlc17 = b.option([]const u8, "tomlc17", "Compile tomlc17.c from this vendored directory") orelse "vendor/tomlc17";
    config.addIncludePath(b.path(tomlc17));
    config.addCSourceFile(.{
        .file = b.path(b.pathJoin(&.{ tomlc17, "tomlc17.c" })),
        .flags = &.{"-std=c17"},
    });
    const process = module(b, "process", target, optimize);
    const repos = module(b, "repos", target, optimize);
    repos.addImport("config", config);
    repos.addImport("process", process);
    const tmux = module(b, "tmux", target, optimize);
    tmux.addImport("process", process);
    const sessions = module(b, "sessions", target, optimize);
    sessions.addImport("config", config);
    sessions.addImport("repos", repos);
    sessions.addImport("tmux", tmux);
    const matcher = module(b, "matcher", target, optimize);
    const picker = module(b, "picker", target, optimize);
    picker.addImport("config", config);
    picker.addImport("matcher", matcher);
    picker.addImport("tmux", tmux);
    const cli = module(b, "cli", target, optimize);
    cli.addImport("config", config);
    cli.addImport("sessions", sessions);
    const app = module(b, "app", target, optimize);
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    app.addOptions("build_options", options);
    const domains = [_]std.Build.Module.Import{
        .{ .name = "config", .module = config },
        .{ .name = "process", .module = process },
        .{ .name = "repos", .module = repos },
        .{ .name = "tmux", .module = tmux },
        .{ .name = "sessions", .module = sessions },
        .{ .name = "matcher", .module = matcher },
        .{ .name = "picker", .module = picker },
        .{ .name = "cli", .module = cli },
    };
    for (domains) |domain| app.addImport(domain.name, domain.module);

    const main = module(b, "main", target, optimize);
    main.addImport("app", app);
    main.addImport("cli", cli);
    main.addImport("config", config);
    const exe = b.addExecutable(.{ .name = "tms", .root_module = main });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run tms").dependOn(&run.step);

    const oracle = module(b, "oracle", target, optimize);
    oracle.addImport("matcher", matcher);
    const oracle_exe = b.addExecutable(.{ .name = "tms-oracle", .root_module = oracle });
    b.installArtifact(oracle_exe);
    b.step("oracle", "Build and install the headless ranking oracle").dependOn(&b.addInstallArtifact(oracle_exe, .{}).step);

    const contracts = module(b, "contracts", target, optimize);
    for (domains) |domain| contracts.addImport(domain.name, domain.module);
    contracts.addImport("app", app);
    const test_step = b.step("test", "Typecheck public contracts and run all module tests");
    for (domains) |domain| {
        const tests = b.addTest(.{ .root_module = domain.module });
        if (target.result.abi.isMusl()) tests.linkage = .static;
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
    for ([_]*std.Build.Module{ app, main, oracle, contracts }) |root| {
        const tests = b.addTest(.{ .root_module = root });
        if (target.result.abi.isMusl()) tests.linkage = .static;
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}

fn module(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.addModule(name, .{
        .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
}
