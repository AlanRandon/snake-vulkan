const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const minimp3 = b.dependency("minimp3", .{});

    const exe = b.addExecutable(.{
        .name = "snake",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    exe.linkSystemLibrary("glfw");
    exe.linkSystemLibrary("vulkan");
    exe.linkSystemLibrary("soundio");
    exe.addCSourceFile(.{ .file = b.path("src/lib_wrapper.c") });

    exe.root_module.addImport("minimp3", minimp3.module("minimp3"));

    {
        var assets = std.fs.openDirAbsolute(b.path("./assets").getPath(b), .{ .iterate = true }) catch unreachable;
        defer assets.close();

        var it = assets.iterate();
        while (it.next() catch unreachable) |entry| {
            const name = entry.name;
            exe.root_module.addAnonymousImport(
                std.mem.concat(b.allocator, u8, &[_][]const u8{ "asset:", name }) catch unreachable,
                .{ .root_source_file = b.path(b.pathJoin(&[_][]const u8{ "assets", name })) },
            );
        }
    }

    var shaders = std.fs.openDirAbsolute(b.path("./shaders").getPath(b), .{ .iterate = true }) catch unreachable;
    defer shaders.close();

    var it = shaders.iterate();
    while (it.next() catch unreachable) |entry| {
        const name = entry.name;
        const compile = b.addSystemCommand(&[_][]const u8{ "glslc", "-o", "-" });
        compile.addFileArg(.{ .cwd_relative = b.pathJoin(&[_][]const u8{ "shaders", name }) });
        exe.step.dependOn(&compile.step);

        const output = compile.captureStdOut();
        exe.root_module.addAnonymousImport(
            std.mem.concat(b.allocator, u8, &[_][]const u8{ "spv:", name }) catch unreachable,
            .{ .root_source_file = output },
        );
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
