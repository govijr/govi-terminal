const std = @import("std");
const buildpkg = @import("src/build/main.zig");

comptime {
    buildpkg.requireZig("0.14.0");
}

/// Govi builds the embedded terminal engine and the macOS app only.
/// Keep engine regression tests available without the upstream packaging targets.
pub fn build(b: *std.Build) !void {
    const config = try buildpkg.Config.init(b);
    if (config.target.result.os.tag != .macos or config.app_runtime != .none) {
        std.log.err("Govi supports the native macOS app only", .{});
        return error.UnsupportedGoviTarget;
    }
    const test_filter = b.option([]const u8, "test-filter", "Filter the terminal engine tests.");
    const resources = try buildpkg.GhosttyResources.init(b, &config);
    const deps = try buildpkg.SharedDeps.init(b, &config);
    const xcframework = try buildpkg.GhosttyXCFramework.init(b, &deps, config.xcframework_target);
    const app = try buildpkg.GhosttyXcodebuild.init(b, &config, .{
        .xcframework = &xcframework,
        .resources = &resources,
    });

    if (config.emit_macos_app) {
        // Build in macos/build; govi/build.sh assembles dist/Govi.app.
        // Avoid another copy of the app in zig-out.
        app.installXcframework();
    } else if (config.emit_xcframework) {
        xcframework.install();
        resources.install();
    }
    b.step("run", "Run Govi").dependOn(&app.open.step);

    const test_step = b.step("test", "Run terminal engine tests");
    const test_exe = b.addTest(.{
        .name = "govi-engine-test",
        .filters = if (test_filter) |v| &.{v} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = config.baselineTarget(),
            .optimize = .Debug,
            .strip = false,
            .omit_frame_pointer = false,
            .unwind_tables = .sync,
        }),
    });
    _ = try deps.add(test_exe);
    test_step.dependOn(&b.addRunArtifact(test_exe).step);
    if (test_filter == null) app.addTestStepDependencies(test_step);
}
