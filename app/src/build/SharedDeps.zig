const SharedDeps = @This();

const std = @import("std");
const Config = @import("Config.zig");
const HelpStrings = @import("HelpStrings.zig");
const MetallibStep = @import("MetallibStep.zig");
const UnicodeTables = @import("UnicodeTables.zig");
const GhosttyFrameData = @import("GhosttyFrameData.zig");

config: *const Config,

options: *std.Build.Step.Options,
help_strings: HelpStrings,
metallib: ?*MetallibStep,
unicode_tables: UnicodeTables,
framedata: GhosttyFrameData,

/// Used to keep track of a list of file sources.
pub const LazyPathList = std.ArrayList(std.Build.LazyPath);

pub fn init(b: *std.Build, cfg: *const Config) !SharedDeps {
    var result: SharedDeps = .{
        .config = cfg,
        .help_strings = try .init(b, cfg),
        .unicode_tables = try .init(b),
        .framedata = try .init(b),

        // Setup by retarget
        .options = undefined,
        .metallib = undefined,
    };
    try result.initTarget(b, cfg.target);
    if (cfg.emit_unicode_table_gen) result.unicode_tables.install(b);
    return result;
}

/// Retarget our dependencies for another build target. Modifies in-place.
pub fn retarget(
    self: *const SharedDeps,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) !SharedDeps {
    var result = self.*;
    try result.initTarget(b, target);
    return result;
}

/// Change the exe entrypoint.
pub fn changeEntrypoint(
    self: *const SharedDeps,
    b: *std.Build,
    entrypoint: Config.ExeEntrypoint,
) !SharedDeps {
    // Change our config
    const config = try b.allocator.create(Config);
    config.* = self.config.*;
    config.exe_entrypoint = entrypoint;

    var result = self.*;
    result.config = config;
    result.options = b.addOptions();
    try config.addOptions(result.options);

    return result;
}

fn initTarget(
    self: *SharedDeps,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) !void {
    // Update our metallib
    self.metallib = .create(b, .{
        .name = "Ghostty",
        .target = target,
        .sources = &.{b.path("src/renderer/shaders/shaders.metal")},
    });

    // Change our config
    const config = try b.allocator.create(Config);
    config.* = self.config.*;
    config.target = target;
    self.config = config;

    // Setup our shared build options
    self.options = b.addOptions();
    try self.config.addOptions(self.options);
}

pub fn add(
    self: *const SharedDeps,
    step: *std.Build.Step.Compile,
) !LazyPathList {
    const b = step.step.owner;

    // We could use our config.target/optimize fields here but its more
    // correct to always match our step.
    const target = step.root_module.resolved_target.?;
    const optimize = step.root_module.optimize.?;

    // We maintain a list of our static libraries and return it so that
    // we can build a single fat static library for the final app.
    var static_libs = LazyPathList.init(b.allocator);
    errdefer static_libs.deinit();

    // Every exe gets build options populated
    step.root_module.addOptions("build_options", self.options);

    // Freetype
    _ = b.systemIntegrationOption("freetype", .{}); // Shows it in help
    if (self.config.font_backend.hasFreetype()) {
        if (b.lazyDependency("freetype", .{
            .target = target,
            .optimize = optimize,
            .@"enable-libpng" = true,
        })) |freetype_dep| {
            step.root_module.addImport(
                "freetype",
                freetype_dep.module("freetype"),
            );

            if (b.systemIntegrationOption("freetype", .{})) {
                step.linkSystemLibrary2("bzip2", dynamic_link_opts);
                step.linkSystemLibrary2("freetype2", dynamic_link_opts);
            } else {
                step.linkLibrary(freetype_dep.artifact("freetype"));
                try static_libs.append(
                    freetype_dep.artifact("freetype").getEmittedBin(),
                );
            }
        }
    }

    // Harfbuzz
    _ = b.systemIntegrationOption("harfbuzz", .{}); // Shows it in help
    if (self.config.font_backend.hasHarfbuzz()) {
        if (b.lazyDependency("harfbuzz", .{
            .target = target,
            .optimize = optimize,
            .@"enable-freetype" = self.config.font_backend.hasFreetype(),
            .@"enable-coretext" = self.config.font_backend.hasCoretext(),
        })) |harfbuzz_dep| {
            step.root_module.addImport(
                "harfbuzz",
                harfbuzz_dep.module("harfbuzz"),
            );
            if (b.systemIntegrationOption("harfbuzz", .{})) {
                step.linkSystemLibrary2("harfbuzz", dynamic_link_opts);
            } else {
                step.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
                try static_libs.append(
                    harfbuzz_dep.artifact("harfbuzz").getEmittedBin(),
                );
            }
        }
    }

    // Fontconfig
    _ = b.systemIntegrationOption("fontconfig", .{}); // Shows it in help
    if (self.config.font_backend.hasFontconfig()) {
        if (b.lazyDependency("fontconfig", .{
            .target = target,
            .optimize = optimize,
        })) |fontconfig_dep| {
            step.root_module.addImport(
                "fontconfig",
                fontconfig_dep.module("fontconfig"),
            );

            if (b.systemIntegrationOption("fontconfig", .{})) {
                step.linkSystemLibrary2("fontconfig", dynamic_link_opts);
            } else {
                step.linkLibrary(fontconfig_dep.artifact("fontconfig"));
                try static_libs.append(
                    fontconfig_dep.artifact("fontconfig").getEmittedBin(),
                );
            }
        }
    }

    // Libpng - Ghostty doesn't actually use this directly, its only used
    // through dependencies, so we only need to add it to our static
    // libs list if we're not using system integration. The dependencies
    // will handle linking it.
    if (!b.systemIntegrationOption("libpng", .{})) {
        if (b.lazyDependency("libpng", .{
            .target = target,
            .optimize = optimize,
        })) |libpng_dep| {
            step.linkLibrary(libpng_dep.artifact("png"));
            try static_libs.append(
                libpng_dep.artifact("png").getEmittedBin(),
            );
        }
    }

    // Zlib - same as libpng, only used through dependencies.
    if (!b.systemIntegrationOption("zlib", .{})) {
        if (b.lazyDependency("zlib", .{
            .target = target,
            .optimize = optimize,
        })) |zlib_dep| {
            step.linkLibrary(zlib_dep.artifact("z"));
            try static_libs.append(
                zlib_dep.artifact("z").getEmittedBin(),
            );
        }
    }

    // Oniguruma
    if (b.lazyDependency("oniguruma", .{
        .target = target,
        .optimize = optimize,
    })) |oniguruma_dep| {
        step.root_module.addImport(
            "oniguruma",
            oniguruma_dep.module("oniguruma"),
        );
        if (b.systemIntegrationOption("oniguruma", .{})) {
            step.linkSystemLibrary2("oniguruma", dynamic_link_opts);
        } else {
            step.linkLibrary(oniguruma_dep.artifact("oniguruma"));
            try static_libs.append(
                oniguruma_dep.artifact("oniguruma").getEmittedBin(),
            );
        }
    }

    // Glslang
    if (b.lazyDependency("glslang", .{
        .target = target,
        .optimize = optimize,
    })) |glslang_dep| {
        step.root_module.addImport("glslang", glslang_dep.module("glslang"));
        if (b.systemIntegrationOption("glslang", .{})) {
            step.linkSystemLibrary2("glslang", dynamic_link_opts);
            step.linkSystemLibrary2(
                "glslang-default-resource-limits",
                dynamic_link_opts,
            );
        } else {
            step.linkLibrary(glslang_dep.artifact("glslang"));
            try static_libs.append(
                glslang_dep.artifact("glslang").getEmittedBin(),
            );
        }
    }

    // Spirv-cross
    if (b.lazyDependency("spirv_cross", .{
        .target = target,
        .optimize = optimize,
    })) |spirv_cross_dep| {
        step.root_module.addImport(
            "spirv_cross",
            spirv_cross_dep.module("spirv_cross"),
        );
        if (b.systemIntegrationOption("spirv-cross", .{})) {
            step.linkSystemLibrary2("spirv-cross", dynamic_link_opts);
        } else {
            step.linkLibrary(spirv_cross_dep.artifact("spirv_cross"));
            try static_libs.append(
                spirv_cross_dep.artifact("spirv_cross").getEmittedBin(),
            );
        }
    }

    // Simdutf
    if (b.systemIntegrationOption("simdutf", .{})) {
        step.linkSystemLibrary2("simdutf", dynamic_link_opts);
    } else {
        if (b.lazyDependency("simdutf", .{
            .target = target,
            .optimize = optimize,
        })) |simdutf_dep| {
            step.linkLibrary(simdutf_dep.artifact("simdutf"));
            try static_libs.append(
                simdutf_dep.artifact("simdutf").getEmittedBin(),
            );
        }
    }

    // Wasm we do manually since it is such a different build.
    if (step.rootModuleTarget().cpu.arch == .wasm32) {
        if (b.lazyDependency("zig_js", .{
            .target = target,
            .optimize = optimize,
        })) |js_dep| {
            step.root_module.addImport(
                "zig-js",
                js_dep.module("zig-js"),
            );
        }

        return static_libs;
    }

    // On Linux, we need to add a couple common library paths that aren't
    // on the standard search list. i.e. GTK is often in /usr/lib/x86_64-linux-gnu
    // on x86_64.
    if (step.rootModuleTarget().os.tag == .linux) {
        const triple = try step.rootModuleTarget().linuxTriple(b.allocator);
        const path = b.fmt("/usr/lib/{s}", .{triple});
        if (std.fs.accessAbsolute(path, .{})) {
            step.addLibraryPath(.{ .cwd_relative = path });
        } else |_| {}
    }

    // C files
    step.linkLibC();
    step.addIncludePath(b.path("src/stb"));
    step.addCSourceFiles(.{ .files = &.{"src/stb/stb.c"} });

    // C++ files
    step.linkLibCpp();
    step.addIncludePath(b.path("src"));
    {
        // From hwy/detect_targets.h
        const HWY_AVX3_SPR: c_int = 1 << 4;
        const HWY_AVX3_ZEN4: c_int = 1 << 6;
        const HWY_AVX3_DL: c_int = 1 << 7;
        const HWY_AVX3: c_int = 1 << 8;

        // Zig 0.13 bug: https://github.com/ziglang/zig/issues/20414
        // To workaround this we just disable AVX512 support completely.
        // The performance difference between AVX2 and AVX512 is not
        // significant for our use case and AVX512 is very rare on consumer
        // hardware anyways.
        const HWY_DISABLED_TARGETS: c_int = HWY_AVX3_SPR | HWY_AVX3_ZEN4 | HWY_AVX3_DL | HWY_AVX3;

        step.addCSourceFiles(.{
            .files = &.{
                "src/simd/base64.cpp",
                "src/simd/codepoint_width.cpp",
                "src/simd/index_of.cpp",
                "src/simd/vt.cpp",
            },
            .flags = if (step.rootModuleTarget().cpu.arch == .x86_64) &.{
                b.fmt("-DHWY_DISABLED_TARGETS={}", .{HWY_DISABLED_TARGETS}),
            } else &.{},
        });
    }

    // We always require the system SDK so that our system headers are available.
    // This makes things like `os/log.h` available for cross-compiling.
    if (step.rootModuleTarget().os.tag.isDarwin()) {
        try @import("apple_sdk").addPaths(b, step);

        const metallib = self.metallib.?;
        metallib.output.addStepDependencies(&step.step);
        step.root_module.addAnonymousImport("ghostty_metallib", .{
            .root_source_file = metallib.output,
        });
    }

    // Other dependencies, mostly pure Zig
    if (b.lazyDependency("opengl", .{})) |dep| {
        step.root_module.addImport("opengl", dep.module("opengl"));
    }
    if (b.lazyDependency("vaxis", .{})) |dep| {
        step.root_module.addImport("vaxis", dep.module("vaxis"));
    }
    if (b.lazyDependency("wuffs", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        step.root_module.addImport("wuffs", dep.module("wuffs"));
    }
    if (b.lazyDependency("libxev", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        step.root_module.addImport("xev", dep.module("xev"));
    }
    if (b.lazyDependency("z2d", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        step.root_module.addImport("z2d", dep.module("z2d"));
    }
    if (b.lazyDependency("ziglyph", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        step.root_module.addImport("ziglyph", dep.module("ziglyph"));
    }
    if (b.lazyDependency("zf", .{
        .target = target,
        .optimize = optimize,
        .with_tui = false,
    })) |dep| {
        step.root_module.addImport("zf", dep.module("zf"));
    }

    // Mac Stuff
    if (step.rootModuleTarget().os.tag.isDarwin()) {
        if (b.lazyDependency("zig_objc", .{
            .target = target,
            .optimize = optimize,
        })) |objc_dep| {
            step.root_module.addImport(
                "objc",
                objc_dep.module("objc"),
            );
        }

        if (b.lazyDependency("macos", .{
            .target = target,
            .optimize = optimize,
        })) |macos_dep| {
            step.root_module.addImport(
                "macos",
                macos_dep.module("macos"),
            );
            step.linkLibrary(
                macos_dep.artifact("macos"),
            );
            try static_libs.append(
                macos_dep.artifact("macos").getEmittedBin(),
            );
        }

        if (self.config.renderer == .opengl) {
            step.linkFramework("OpenGL");
        }
    }

    // cimgui
    if (b.lazyDependency("cimgui", .{
        .target = target,
        .optimize = optimize,
    })) |cimgui_dep| {
        step.root_module.addImport("cimgui", cimgui_dep.module("cimgui"));
        step.linkLibrary(cimgui_dep.artifact("cimgui"));
        try static_libs.append(cimgui_dep.artifact("cimgui").getEmittedBin());
    }

    // Highway
    if (b.lazyDependency("highway", .{
        .target = target,
        .optimize = optimize,
    })) |highway_dep| {
        step.linkLibrary(highway_dep.artifact("highway"));
        try static_libs.append(highway_dep.artifact("highway").getEmittedBin());
    }

    // utfcpp - This is used as a dependency on our hand-written C++ code
    if (b.lazyDependency("utfcpp", .{
        .target = target,
        .optimize = optimize,
    })) |utfcpp_dep| {
        step.linkLibrary(utfcpp_dep.artifact("utfcpp"));
        try static_libs.append(utfcpp_dep.artifact("utfcpp").getEmittedBin());
    }

    // Fonts
    {
        // JetBrains Mono
        const jb_mono = b.dependency("jetbrains_mono", .{});
        step.root_module.addAnonymousImport(
            "jetbrains_mono_regular",
            .{ .root_source_file = jb_mono.path("fonts/ttf/JetBrainsMono-Regular.ttf") },
        );
        step.root_module.addAnonymousImport(
            "jetbrains_mono_bold",
            .{ .root_source_file = jb_mono.path("fonts/ttf/JetBrainsMono-Bold.ttf") },
        );
        step.root_module.addAnonymousImport(
            "jetbrains_mono_italic",
            .{ .root_source_file = jb_mono.path("fonts/ttf/JetBrainsMono-Italic.ttf") },
        );
        step.root_module.addAnonymousImport(
            "jetbrains_mono_bold_italic",
            .{ .root_source_file = jb_mono.path("fonts/ttf/JetBrainsMono-BoldItalic.ttf") },
        );
        step.root_module.addAnonymousImport(
            "jetbrains_mono_variable",
            .{ .root_source_file = jb_mono.path("fonts/variable/JetBrainsMono[wght].ttf") },
        );
        step.root_module.addAnonymousImport(
            "jetbrains_mono_variable_italic",
            .{ .root_source_file = jb_mono.path("fonts/variable/JetBrainsMono-Italic[wght].ttf") },
        );

        // Symbols-only nerd font
        const nf_symbols = b.dependency("nerd_fonts_symbols_only", .{});
        step.root_module.addAnonymousImport(
            "nerd_fonts_symbols_only",
            .{ .root_source_file = nf_symbols.path("SymbolsNerdFont-Regular.ttf") },
        );
    }

    // If we're building an exe then we have additional dependencies.
    if (step.kind != .lib) {
        // We always statically compile glad
        step.addIncludePath(b.path("vendor/glad/include/"));
        step.addCSourceFile(.{
            .file = b.path("vendor/glad/src/gl.c"),
            .flags = &.{},
        });
    }

    self.help_strings.addImport(step);
    self.unicode_tables.addImport(step);
    self.framedata.addImport(step);

    return static_libs;
}

// For dynamic linking, we prefer dynamic linking and to search by
// mode first. Mode first will search all paths for a dynamic library
// before falling back to static.
const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
    .preferred_link_mode = .dynamic,
    .search_strategy = .mode_first,
};
