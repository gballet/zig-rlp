const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("zig-rlp", Builder.CreateModuleOptions{ .source_file = .{ .path = "src/main.zig" } });

    const lib = b.addStaticLibrary(.{
        .name = "zig-rlp",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    var main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    var deser_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/deserialize.zig" },
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
    test_step.dependOn(&deser_tests.step);
}
