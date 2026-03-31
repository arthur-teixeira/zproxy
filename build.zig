const std = @import("std");

const BuildOptions = struct {
    testing: bool,

    fn create(self: BuildOptions, b: *std.Build) *std.Build.Step.Options {
        const opts: *std.Build.Step.Options = .create(b);
        opts.addOption(bool, "testing", self.testing);

        return opts;
    }

    fn set(self: BuildOptions, b: *std.Build, exe: *std.Build.Step.Compile) void {
        const opts = self.create(b);
        exe.root_module.addOptions("build_options", opts);
    }
};

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

    const opts: BuildOptions = .{
        .testing = false,
    };
    opts.set(b, zproxy_exe);

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

fn build_tests(b: *std.Build, target: std.Build.ResolvedTarget) void {
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
        }),
    });

    const opts: BuildOptions = .{
        .testing = true,
    };
    opts.set(b, unit_tests);

    const test_step = b.step("test", "Run zproxy tests");
    const run_tests_cmd = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_tests_cmd.step);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    build_zproxy(b, target, optimize);
    build_tests(b, target);
    run_mock_upstream(b);
}
