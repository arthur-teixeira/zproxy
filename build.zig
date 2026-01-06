const std = @import("std");

fn build_zproxy(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const zproxy_exe = b.addExecutable(.{
        .name = "zproxy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });
    b.installArtifact(zproxy_exe);

    const run_zproxy_step = b.step("run", "Run zproxy");
    const run_zproxy_cmd = b.addRunArtifact(zproxy_exe);
    run_zproxy_step.dependOn(&run_zproxy_cmd.step);
    run_zproxy_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_zproxy_cmd.addArgs(args);
    }
}

fn run_mock_upstream(b: *std.Build) void {
    const up = b.step("mock", "Run ncat mock upstream");
    const run = b.addSystemCommand(&[_][]const u8{
        "sh",
        "-c",
        "ncat -k -l 3030 -c 'cat | tee /dev/tty'",
    });
    up.dependOn(&run.step);
}

fn build_echo_tester(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const zproxy_exe = b.addExecutable(.{
        .name = "echo_tester",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/echo_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });
    b.installArtifact(zproxy_exe);

    const run_zproxy_step = b.step("echo_test", "Run zproxy Echo tester");
    const run_zproxy_cmd = b.addRunArtifact(zproxy_exe);
    run_zproxy_step.dependOn(&run_zproxy_cmd.step);
    run_zproxy_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_zproxy_cmd.addArgs(args);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    build_zproxy(b, target, optimize);
    build_echo_tester(b, target, optimize);
    run_mock_upstream(b);
}
