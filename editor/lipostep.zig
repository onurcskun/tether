//! A zig builder step that runs "lipo" on two binaries to create
//! a universal binary.
const LipoStep = @This();

const std = @import("std");
const Step = std.build.Step;
const RunStep = std.build.RunStep;
const FileSource = std.build.FileSource;

pub const Options = struct {
    /// The name of the xcframework to create.
    name: []const u8,

    /// The filename (not the path) of the file to create.
    out_name: []const u8,

    /// Library file (dylib, a) to package.
    input_a: FileSource,
    input_b: FileSource,
};

step: *Step,

/// Resulting binary
output: FileSource,

pub fn create(b: *std.Build, opts: Options) *LipoStep {
    const self = b.allocator.create(LipoStep) catch @panic("OOM");

    const run_step = RunStep.create(b, b.fmt("lipo {s}", .{opts.name}));
    run_step.addArgs(&.{ "lipo", "-create", "-output" });
    const output = run_step.addOutputFileArg(opts.out_name);
    run_step.addFileSourceArg(opts.input_a);
    run_step.addFileSourceArg(opts.input_b);

    self.* = .{
        .step = &run_step.step,
        .output = output,
    };

    return self;
}
