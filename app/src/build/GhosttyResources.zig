//! Runtime resources for Govi: terminal capabilities, shell integration, themes.
const GhosttyResources = @This();
const std = @import("std");
const Config = @import("Config.zig");
const terminfo = @import("../terminfo/main.zig");

steps: []*std.Build.Step,

pub fn init(b: *std.Build, cfg: *const Config) !GhosttyResources {
    var steps = std.ArrayList(*std.Build.Step).init(b.allocator);
    errdefer steps.deinit();

    // Keep xterm-ghostty capabilities for full-screen programs and SSH.
    var source = std.ArrayList(u8).init(b.allocator);
    defer source.deinit();
    try terminfo.ghostty.encode(source.writer());
    const wf = b.addWriteFiles();
    const terminfo_source = wf.add("ghostty.terminfo", source.items);
    const tic = b.addSystemCommand(&.{ "tic", "-x", "-o" });
    const compiled = tic.addOutputDirectoryArg("terminfo");
    tic.addFileArg(terminfo_source);
    _ = tic.captureStdErr();
    const capabilities = b.addInstallDirectory(.{
        .source_dir = compiled,
        .install_dir = .{ .custom = "share" },
        .install_subdir = "terminfo",
    });
    try steps.append(&capabilities.step);
    if (cfg.emit_terminfo) try steps.append(&b.addInstallFile(terminfo_source, "share/terminfo/ghostty.terminfo").step);

    const shells = b.addInstallDirectory(.{
        .source_dir = b.path("src/shell-integration"),
        .install_dir = .{ .custom = "share" },
        .install_subdir = "ghostty/shell-integration",
        .exclude_extensions = &.{".md"},
    });
    try steps.append(&shells.step);

    if (cfg.emit_themes) {
        if (b.lazyDependency("iterm2_themes", .{})) |themes| {
            const catalog = b.addInstallDirectory(.{
                .source_dir = themes.path(""),
                .install_dir = .{ .custom = "share" },
                .install_subdir = "ghostty/themes",
                .exclude_extensions = &.{".md"},
            });
            try steps.append(&catalog.step);
        }
    }
    return .{ .steps = try steps.toOwnedSlice() };
}

pub fn install(self: *const GhosttyResources) void {
    self.addStepDependencies(self.steps[0].owner.getInstallStep());
}

pub fn addStepDependencies(self: *const GhosttyResources, step: *std.Build.Step) void {
    for (self.steps) |dependency| step.dependOn(dependency);
}
