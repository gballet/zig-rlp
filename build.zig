const std = @import("std");
const Build = std.Build;

const rlptest_json = "ethereum-tests/RLPTests/rlptest.json";
const invalid_rlptest_json = "ethereum-tests/RLPTests/invalidRLPTest.json";

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("zig-rlp", Build.Module.CreateOptions{
        .root_source_file = b.path("src/rlp.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "zig-rlp",
        .root_module = b.createModule(.{ 
            .root_source_file = b.path("src/serialize.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    b.installArtifact(lib);

    var main_tests = b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{ 
            .root_source_file = b.path("src/serialize.zig"),
            .target = target, 
            .optimize = optimize 
        }),
    }));
    var deser_tests = b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{ 
            .root_source_file = b.path("src/deserialize.zig"),
            .target = target, 
            .optimize = optimize 
        }),
    }));

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
    test_step.dependOn(&deser_tests.step);
    const have_vectors = blk: {
        const io = b.graph.io;
        const root = b.build_root.handle;
        root.access(io, rlptest_json, .{}) catch break :blk false;
        root.access(io, invalid_rlptest_json, .{}) catch break :blk false;
        break :blk true;
    };

    if (have_vectors) {
        const vectors_module = b.createModule(.{
            .root_source_file = b.path("src/vectors.zig"),
            .target = target,
            .optimize = optimize,
        });
        vectors_module.addAnonymousImport("rlptest.json", .{
            .root_source_file = b.path(rlptest_json),
        });
        vectors_module.addAnonymousImport("invalidRLPTest.json", .{
            .root_source_file = b.path(invalid_rlptest_json),
        });

        const vector_tests = b.addRunArtifact(b.addTest(.{ .root_module = vectors_module }));
        test_step.dependOn(&vector_tests.step);
    }
}
