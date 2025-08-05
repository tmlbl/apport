const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const oci_mod = b.createModule(.{
        .root_source_file = b.path("third-party/oci-spec-zig/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zinatra_mod = b.createModule(.{
        .root_source_file = b.path("third-party/zinatra/src/App.zig"),
        .target = target,
        .optimize = optimize,
    });

    const server_mod = b.createModule(.{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    server_mod.addImport("ocispec", oci_mod);
    server_mod.addImport("zinatra", zinatra_mod);

    const server_exe = b.addExecutable(.{
        .name = "apportd",
        .root_module = server_mod,
    });
    server_exe.linkLibC();

    b.installArtifact(server_exe);

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });

    const cli_exe = b.addExecutable(.{
        .name = "apport",
        .root_module = cli_mod,
    });

    b.installArtifact(cli_exe);

    const exe_unit_tests = b.addTest(.{
        .root_module = server_mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
