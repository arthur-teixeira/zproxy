const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    const run_zproxy_step = b.step("run", "Run zproxy example");
    const run_zproxy_cmd = b.addRunArtifact(zproxy_exe);
    run_zproxy_step.dependOn(&run_zproxy_cmd.step);
    run_zproxy_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_zproxy_cmd.addArgs(args);
    }

    const up = b.step("mock", "Run ncat mock upstream");
    const run = b.addSystemCommand(&[_][]const u8{
        "sh",
        "-c",
        "ncat -k -l 3030 -c 'cat | tee /dev/tty'",
    });

    up.dependOn(&run.step);
}
