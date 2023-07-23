const std = @import("std");
const LipoStep = @import("build/lipostep.zig");
const XCFrameworkStep = @import("build/xcframeworkstep.zig");
const LibtoolStep = @import("build/libtoolstep.zig");
const MergeStaticLibsStep = @import("build/mergestaticlibstep.zig");
const TreeSitterHighlightStep = @import("build/tree_sitter_highlight_step.zig");

const alloc = std.heap.c_allocator;
const FileSource = std.build.FileSource;

/// From https://mitchellh.com/writing/zig-and-swiftui#merging-all-dependencies
pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigobjc = b.createModule(.{
        .source_file = .{ .path = "lib/zig-objc/src/main.zig" },
    });
    const modules = [_]*std.build.Module{zigobjc};

    build_tests(b, &modules, target, optimize);

    // Make static libraries for aarch64 and x86_64
    var static_lib_aarch64 = try build_static_lib(b, target, optimize, "editor_aarch64", "libeditor-aarch64-bundle.a", .aarch64, &modules);
    var static_lib_x86_64 = try build_static_lib(b, target, optimize, "editor_x86_64", "libeditor-x86_64-bundle.a", .x86_64, &modules);

    // Make a universal static library
    const static_lib_universal = LipoStep.create(b, .{
        .name = "editor",
        .out_name = "libeditor.a",
        .input_a = static_lib_aarch64.out,
        .input_b = static_lib_x86_64.out,
    });
    static_lib_universal.step.dependOn(static_lib_aarch64.step);
    static_lib_universal.step.dependOn(static_lib_x86_64.step);

    // Create XCFramework so the lib can be used from swift
    const xcframework = XCFrameworkStep.create(b, .{
        .name = "EditorKit",
        .out_path = "macos/EditorKit.xcframework",
        .library = static_lib_universal.output,
        .headers = .{ .path = "include" },
    });

    xcframework.step.dependOn(static_lib_universal.step);
    b.default_step.dependOn(xcframework.step);
}

fn build_treesitter(
    b: *std.build.Builder,
    target: std.zig.CrossTarget,
    optimize: std.builtin.Mode,
    cpu_arch: std.Target.Cpu.Arch,
) *std.build.Step.Compile {
    var lib = b.addStaticLibrary(.{
        .name = b.fmt("tree-sitter-{s}", .{@tagName(cpu_arch)}),
        .target = .{
            .cpu_arch = cpu_arch,
            .os_tag = .macos,
            .os_version_min = target.os_version_min,
        },
        .optimize = optimize,
    });

    lib.linkLibC();
    lib.addCSourceFile("lib/tree-sitter/lib/src/lib.c", &.{});
    lib.addIncludePath("lib/tree-sitter/lib/include");
    lib.addIncludePath("lib/tree-sitter/lib/src");

    b.installArtifact(lib);
    return lib;
}

fn build_treesitter_highlight(b: *std.build.Builder) *TreeSitterHighlightStep {
    const step = TreeSitterHighlightStep.create(b, .{ .treesitter_dir = "lib/tree-sitter" });
    b.default_step.dependOn(step.step);
    return step;
}

fn build_static_lib(
    b: *std.build.Builder,
    target: std.zig.CrossTarget,
    optimize: std.builtin.Mode,
    name: []const u8,
    bundle_name: []const u8,
    cpu_arch: std.Target.Cpu.Arch,
    // Zig modules
    modules: []const *std.build.Module,
) !struct { out: FileSource, step: *std.build.Step } {
    const treesitter = build_treesitter(b, target, optimize, cpu_arch);

    // Make static libraries for aarch64 and x86_64
    var static_lib = b.addStaticLibrary(.{
        .name = name,
        .root_source_file = .{ .path = "src/main_c.zig" },
        .target = .{
            .cpu_arch = cpu_arch,
            .os_tag = .macos,
            .os_version_min = target.os_version_min,
        },
        .optimize = optimize,
    });
    add_libs(static_lib, modules, treesitter);

    const ENABLE_DEBUG_SYMBOLS = true;
    if (comptime ENABLE_DEBUG_SYMBOLS) {
        static_lib.dll_export_fns = true;
        static_lib.strip = false;
        static_lib.export_table = true;
    }

    var lib_list = std.ArrayList(std.build.FileSource).init(alloc);
    try lib_list.append(.{ .generated = &static_lib.output_path_source });
    try lib_list.append(.{ .generated = &treesitter.output_path_source });
    if (cpu_arch == .aarch64) {
        try lib_list.append(.{ .path = "/Users/zackradisic/Code/tether/editor/lib/tree-sitter/libtree-sitter.a" });
    } else {
        // try lib_list.append(.{ .path = "/Users/zackradisic/Code/tether/editor/lib/tree-sitter/libtree-sitter.a" });
    }

    const libtool = LibtoolStep.create(b, .{
        .name = bundle_name,
        .out_name = bundle_name,
        .sources = lib_list.items,
    });
    libtool.step.dependOn(&static_lib.step);

    b.default_step.dependOn(libtool.step);
    b.installArtifact(static_lib);

    return .{ .out = libtool.output, .step = libtool.step };
}

fn add_libs(compile: *std.build.Step.Compile, modules: []const *std.build.Module, treesitter: *std.build.Step.Compile) void {
    compile.addFrameworkPath("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks");
    compile.addSystemIncludePath("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include");
    compile.addLibraryPath("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib");
    compile.linkFramework("CoreText");
    compile.linkFramework("MetalKit");
    compile.linkFramework("Foundation");
    compile.linkFramework("AppKit");
    compile.linkFramework("CoreGraphics");
    compile.linkSystemLibraryName("System");
    compile.linkLibC();

    compile.bundle_compiler_rt = true;
    for (modules) |module| {
        compile.addModule("zig-objc", module);
    }

    // treesitter stuff
    // _ = treesitter;
    compile.addCSourceFile("src/syntax/tree-sitter-zig/src/parser.c", &.{});
    compile.addCSourceFile("src/syntax/tree-sitter-typescript/typescript/src/parser.c", &.{});
    compile.addCSourceFile("src/syntax/tree-sitter-typescript/typescript/src/scanner.c", &.{});
    compile.linkLibrary(treesitter);
    compile.addIncludePath("lib/tree-sitter/lib/include");
    compile.step.dependOn(&treesitter.step);
}

fn build_tests(b: *std.build.Builder, modules: []const *std.build.Module, target: std.zig.CrossTarget, optimize: std.builtin.Mode) void {
    const test_step = b.step("test", "Run tests");
    const treesitter = build_treesitter(b, target, optimize, .aarch64);

    const tests = [_]std.build.TestOptions{
        .{
            .name = "rope_tests",
            .root_source_file = .{ .path = "src/rope.zig" },
            .target = target,
            .optimize = optimize,
        },
        .{
            .name = "vim_tests",
            .root_source_file = .{ .path = "src/vim.zig" },
            .target = target,
            .optimize = optimize,
        },
        .{
            .name = "editor_tests",
            .root_source_file = .{ .path = "src/editor.zig" },
            .target = target,
            .optimize = optimize,
        },
        .{
            .name = "math_tests",
            .root_source_file = .{ .path = "src/math.zig" },
            .target = target,
            .optimize = optimize,
        },
        .{
            .name = "highlight_tests",
            .root_source_file = .{ .path = "src/highlight.zig" },
            .target = target,
            .optimize = optimize,
            // .filter = "backspace line",
        },
    };

    for (tests) |t| {
        build_test(b, test_step, modules, treesitter, t);
    }
}

fn build_test(b: *std.build.Builder, test_step: *std.build.Step, modules: []const *std.build.Module, treesitter: *std.build.Step.Compile, opts: std.build.TestOptions) void {
    const the_test = b.addTest(opts);
    add_libs(the_test, modules, treesitter);
    the_test.linkLibC();
    b.default_step.dependOn(&the_test.step);
    b.default_step.dependOn(&treesitter.step);
    const run: *std.build.Step.Run = b.addRunArtifact(the_test);
    b.installArtifact(the_test);
    test_step.dependOn(&the_test.step);
    test_step.dependOn(&run.step);
}
