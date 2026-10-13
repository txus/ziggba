//! This module provides helpers for building Zig code as a GBA ROM.

const std = @import("std");

pub const color = @import("color.zig");
pub const font = @import("font.zig");
pub const assets = @import("assets.zig");

pub const LoggerInterface = @import("../gba/debug.zig").LoggerInterface;
pub const CharsetFlags = font.CharsetFlags;

const gba_linker_script_path = "src/gba/gba.ld";
const gba_start_zig_file_path = "src/gba/start.zig";
const gba_lib_file_path = "src/gba/gba.zig";

const RectU16 = @import("../gba/math.zig").RectU16;

const asm_file_paths = [_][]const u8{
    "src/gba/crt0.s",
    "src/gba/isr.s",
    "src/gba/math.s",
    "src/gba/mem.s",
};

pub const GbaBuild = struct {
    pub const CliOptions = struct {
        debug: bool = false,
        safe: bool = false,
        gdb: bool = false,
    };
    
    /// These build options control some aspects of how ZigGBA is compiled.
    pub const BuildOptions = struct {
        /// Choose default logger for use with `gba.debug.print` and
        /// `gba.debug.write`.
        default_logger: LoggerInterface = .mgba,
        /// Options relating to `gba.text`.
        /// Each charset flag, e.g. `charset_latin`, controls whether `gba.text`
        /// will embed font data for a certain subset of Unicode code points
        /// into the compiled ROM.
        text_charsets: CharsetFlags = .{},
    };
    
    /// `std.Target.Query` object for GBA thumb compilation target.
    pub const thumb_target_query = blk: {
        var target = std.Target.Query{
            .cpu_arch = std.Target.Cpu.Arch.thumb,
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.arm7tdmi },
            .os_tag = .freestanding,
        };
        target.cpu_features_add.addFeature(
            @intFromEnum(std.Target.arm.Feature.thumb_mode)
        );
        break :blk target;
    };
    
    b: *std.Build,
    ziggba_dep: ?*std.Build.Dependency,
    thumb_target: std.Build.ResolvedTarget,
    optimize_mode: std.builtin.OptimizeMode,
    gdb: bool,
    /// Compiled lazily by `getAssetsTool`.
    assets_tool: ?*std.Build.Step.Compile = null,
    /// Built lazily by `getFontFile`, indexed like `font.charsets`.
    font_files: [font.charsets.len]?std.Build.LazyPath = @splat(null),
    
    pub fn create(b: *std.Build) *GbaBuild {
        const gba_b = b.allocator.create(GbaBuild) catch @panic("OOM");
        gba_b.* = GbaBuild.init(b);
        return gba_b;
    }
    
    pub fn init(b: *std.Build) GbaBuild {
        const cli_options = GbaBuild.getCliOptions(b);
        var ziggba_dep: ?*std.Build.Dependency = null;
        for(b.available_deps) |dep| {
            if(std.mem.eql(u8, dep[0], "ziggba")) {
                ziggba_dep = b.dependency("ziggba", .{});
                break;
            }
        }
        var optimize_mode: std.builtin.OptimizeMode = .ReleaseFast;
        if(cli_options.debug) {
            optimize_mode = .Debug;
        }
        else if(cli_options.safe) {
            optimize_mode = .ReleaseSafe;
        }
        return .{
            .b = b,
            .ziggba_dep = ziggba_dep,
            .thumb_target = b.resolveTargetQuery(GbaBuild.thumb_target_query),
            .optimize_mode = optimize_mode,
            .gdb = cli_options.gdb,
        };
    }
    
    /// Get the allocator belonging to the underling `std.Build` instance.
    pub fn allocator(self: GbaBuild) std.mem.Allocator {
        return self.b.allocator;
    }
    
    /// Get a path relative to the build directory.
    pub fn path(self: GbaBuild, sub_path: []const u8) std.Build.LazyPath {
        return self.b.path(sub_path);
    }
    
    /// Get a path relative to the ZigGBA build directory.
    pub fn ziggbaPath(self: GbaBuild, sub_path: []const u8) std.Build.LazyPath {
        if(self.ziggba_dep) |dep| {
            return .{
                .dependency = .{
                    .dependency = dep,
                    .sub_path = sub_path,
                },
            };
        }
        else {
            return self.b.path(sub_path);
        }
    }
    
    /// Get options passed via compiler arguments.
    /// - -Ddebug - Do a debug build, instead of an optimized release build.
    /// - -Dgdb - Output an ELF containing debug symbols.
    pub fn getCliOptions(b: *std.Build) CliOptions {
        return .{
            .debug = blk: {
                break :blk b.option(
                    bool,
                    "debug",
                    "Build the GBA ROM in debug mode instead of release mode.",
                ) orelse false;
            },
            .safe = blk: {
                break :blk b.option(
                    bool,
                    "safe",
                    "Build the GBA ROM in ReleaseSafe mode instead of ReleaseFast.",
                ) orelse false;
            },
            .gdb = blk: {
                break :blk b.option(
                    bool,
                    "gdb",
                    "Generate an ELF file with debug symbols alongside the GBA ROM.",
                ) orelse false;
            },
        };
    }
    
    /// Get an `std.Build.Step.Options` object corresponding to some given
    /// `BuildOptions`.
    fn getBuildOptions(
        b: *std.Build,
        build_options: BuildOptions,
    ) *std.Build.Step.Options {
        const b_options = b.addOptions();
        b_options.addOption(LoggerInterface, "default_logger", build_options.default_logger);
        b_options.addOption(CharsetFlags, "text_charsets", build_options.text_charsets);
        return b_options;
    }
    
    /// Add font-related imports to a module.
    /// These files contain glyph data bitmaps used by `gba.text`.
    pub fn addFontImports(
        self: *GbaBuild,
        module: *std.Build.Module,
        build_options: BuildOptions,
    ) void {
        inline for(font.charsets, 0..) |charset, i| {
            if(@field(build_options.text_charsets, charset.name)) {
                module.addAnonymousImport(
                    "ziggba_font_" ++ charset.name ++ ".bin",
                    .{ .root_source_file = self.getFontFile(i) },
                );
            }
        }
    }
    
    /// Add `ziggba_build_options` import to a module.
    pub fn addBuildOptions(
        self: *GbaBuild,
        module: *std.Build.Module,
        build_options: BuildOptions,
    ) void {
        const b_options = GbaBuild.getBuildOptions(self.b, build_options);
        module.addOptions("ziggba_build_options", b_options);
    }
    
    /// Create a module for the GBA target. Modules are private to the
    /// package, since each ROM's modules can differ by `build_options`.
    pub fn addModule(
        self: *GbaBuild,
        root_source_file: std.Build.LazyPath,
        build_options: BuildOptions,
    ) *std.Build.Module {
        const module = self.b.createModule(.{
            .target = self.thumb_target,
            .optimize = self.optimize_mode,
            .root_source_file = root_source_file,
        });
        self.addFontImports(module, build_options);
        self.addBuildOptions(module, build_options);
        return module;
    }
    
    /// Add a build step to compile a static library.
    pub fn addStaticLibrary(
        self: *GbaBuild,
        library_name: []const u8,
        root_module: *std.Build.Module,
        build_options: BuildOptions,
    ) *std.Build.Step.Compile {
        const lib = self.b.addLibrary(.{
            .linkage = .static,
            .name = library_name,
            .root_module = root_module,
        });
        lib.setLinkerScript(self.ziggbaPath(gba_linker_script_path));
        self.addFontImports(lib.root_module, build_options);
        self.addBuildOptions(lib.root_module, build_options);
        return lib;
    }
    
    pub fn addObject(
        self: *GbaBuild,
        object_name: []const u8,
        root_source_file: std.Build.LazyPath,
        build_options: BuildOptions,
    ) *std.Build.Step.Compile {
        const object = self.b.addObject(.{
            .name = object_name,
            .root_module = self.b.createModule(.{
                .target = self.thumb_target,
                .optimize = self.optimize_mode,
                .root_source_file = root_source_file,
            }),
        });
        self.addFontImports(object.root_module, build_options);
        self.addBuildOptions(object.root_module, build_options);
        return object;
    }
    
    pub const ExecutableOptions = struct {
        name: []const u8,
        root_source_file: std.Build.LazyPath,
        build_options: BuildOptions = .{},
    };
    
    /// Add a build step to compile an executable, i.e. a GBA ROM.
    pub fn addExecutable(
        self: *GbaBuild,
        options: ExecutableOptions,
    ) *GbaExecutable {
        const exe_module = self.b.createModule(.{
            .target = self.thumb_target,
            .optimize = self.optimize_mode,
            .root_source_file = options.root_source_file,
        });
        const exe = self.b.addExecutable(.{
            .name = options.name,
            .root_module = exe_module,
        });
        self.addFontImports(exe_module, options.build_options);
        self.addBuildOptions(exe_module, options.build_options);
        self.b.default_step.dependOn(&exe.step);
        // Debug builds otherwise skip section GC and bundle the UBSan runtime,
        // bloating the ROM enormously.
        exe.link_gc_sections = true;
        exe.bundle_ubsan_rt = false;
        // Zig entry point and startup routine
        exe.root_module.addObject(self.addObject(
            "gba_start",
            self.ziggbaPath(gba_start_zig_file_path),
            options.build_options,
        ));
        // ZigGBA as a static library
        const gba_module = self.addModule(
            self.ziggbaPath(gba_lib_file_path),
            options.build_options,
        );
        exe.root_module.linkLibrary(self.addStaticLibrary(
            "ziggba",
            gba_module,
            options.build_options,
        ));
        exe_module.addImport("gba", gba_module);
        // Linker script
        exe.setLinkerScript(self.ziggbaPath(gba_linker_script_path));
        // Assembly modules
        for(asm_file_paths) |asm_path| {
            exe.root_module.addAssemblyFile(self.ziggbaPath(asm_path));
        }
        // Generate GBA ROM
        const objcopy_step = exe.addObjCopy(.{
            .basename = self.b.fmt("{s}.gba", .{ options.name }),
            .format = .binary,
        });
        const install_bin_step = self.b.addInstallBinFile(
            objcopy_step.getOutput(),
            self.b.fmt("{s}.gba", .{ options.name }),
        );
        install_bin_step.step.dependOn(&objcopy_step.step);
        self.b.default_step.dependOn(&install_bin_step.step);
        // Optionally generate ELF file with debug symbols
        if (self.gdb) {
            const install_elf_step = self.b.addInstallArtifact(exe, .{
                // TODO: Why are ELF files still emitting with no extension?
                .dest_sub_path = self.b.fmt("{s}.elf", .{ options.name }),
            });
            self.b.getInstallStep().dependOn(&install_elf_step.step);
        }
        // Fin
        return .create(self, exe, objcopy_step.getOutput());
    }
    
    /// Get the `ziggba_assets` tool, compiling it for the host on first use.
    /// The tool converts images and fonts; see `assets.Job`.
    pub fn getAssetsTool(self: *GbaBuild) *std.Build.Step.Compile {
        if(self.assets_tool) |tool| {
            return tool;
        }
        const ziggba_b = if(self.ziggba_dep) |dep| dep.builder else self.b;
        const zigimg_dep = ziggba_b.dependency("zigimg", .{
            .target = self.b.graph.host,
            .optimize = .ReleaseSafe,
        });
        const tool_module = self.b.createModule(.{
            .root_source_file = self.ziggbaPath("src/ziggba_assets.zig"),
            .target = self.b.graph.host,
            .optimize = .ReleaseSafe,
        });
        tool_module.addImport("zigimg", zigimg_dep.module("zigimg"));
        const tool = self.b.addExecutable(.{
            .name = "ziggba_assets",
            .root_module = tool_module,
        });
        self.assets_tool = tool;
        return tool;
    }
    
    /// Add a step running the `ziggba_assets` tool with a given job.
    /// The caller adds the job's path arguments.
    fn addAssetsJob(self: *GbaBuild, job: assets.Job) *std.Build.Step.Run {
        var job_zon: std.Io.Writer.Allocating = .init(self.b.allocator);
        std.zon.stringify.serialize(job, .{ .whitespace = false }, &job_zon.writer) catch @panic("OOM");
        const run = self.b.addRunArtifact(self.getAssetsTool());
        run.addArg(job_zon.written());
        return run;
    }
    
    /// Get font data for `gba.text` built from the charset at a given index
    /// in `font.charsets`, adding a build step for it on first use.
    pub fn getFontFile(self: *GbaBuild, charset_index: usize) std.Build.LazyPath {
        if(self.font_files[charset_index]) |file| {
            return file;
        }
        const charset = font.charsets[charset_index];
        const run = self.addAssetsJob(.{ .font = .{
            .grid_size = charset.grid_size,
            .image_rect = charset.image_rect,
        } });
        run.setName(self.b.fmt("build font {s}", .{ charset.name }));
        run.addFileArg(self.ziggbaPath(self.b.fmt(
            "assets/font_{s}.png",
            .{ charset.image_name },
        )));
        const file = run.addOutputFileArg(self.b.fmt("font_{s}.bin", .{ charset.name }));
        self.font_files[charset_index] = file;
        return file;
    }
    
    /// One image to convert with `addConvertImages`.
    pub const ConvertImagesInput = struct {
        /// Image file to read. Formats supported by zigimg are accepted.
        path: std.Build.LazyPath,
        format: assets.ImageFormat,
        /// Optionally convert only this sub-rectangle of the image.
        /// Only supported by the bitmap formats.
        rect: ?RectU16 = null,
        /// If not set, then an empty input image will trigger an error.
        allow_empty: bool = false,
    };
    
    pub const ConvertImagesOptions = struct {
        /// Optionally specify a name for the build step.
        name: ?[]const u8 = null,
        /// Shared by all images, in order. Ignored by `.bitmap_16bpp`.
        palettizer: assets.Palettizer = .{ .naive = 256 },
        images: []const ConvertImagesInput,
    };
    
    pub const ConvertedImages = struct {
        /// Converted data for each image, in the same order as the inputs.
        images: []const std.Build.LazyPath,
        /// The palettizer's palette, quantized to 16-bit GBA colors.
        palette: std.Build.LazyPath,
    };
    
    /// Add a build step converting images to GBA tile or bitmap data, in
    /// order, using one shared palettizer. Use this rather than separate
    /// `addConvertImage` calls when images should share a palette that is
    /// discovered from their pixels, i.e. with `.naive`.
    pub fn addConvertImages(
        self: *GbaBuild,
        options: ConvertImagesOptions,
    ) ConvertedImages {
        const job_images = self.b.allocator.alloc(assets.Image, options.images.len) catch @panic("OOM");
        for(options.images, job_images) |input, *job_image| {
            job_image.* = .{
                .format = input.format,
                .rect = input.rect,
                .allow_empty = input.allow_empty,
            };
        }
        const run = self.addAssetsJob(.{ .images = .{
            .palettizer = options.palettizer,
            .images = job_images,
        } });
        if(options.name) |name| {
            run.setName(name);
        }
        else if(options.images.len > 0) {
            run.setName(self.b.fmt("convert images {s}", .{
                options.images[0].path.getDisplayName(),
            }));
        }
        const palette = run.addOutputFileArg("palette.agp");
        const outputs = self.b.allocator.alloc(std.Build.LazyPath, options.images.len) catch @panic("OOM");
        for(options.images, outputs, 0..) |input, *output, i| {
            run.addFileArg(input.path);
            output.* = run.addOutputFileArg(self.b.fmt("image{d}.bin", .{ i }));
        }
        return .{ .images = outputs, .palette = palette };
    }
    
    pub const ConvertImageOptions = struct {
        /// Optionally specify a name for the build step.
        name: ?[]const u8 = null,
        /// Image file to read. Formats supported by zigimg are accepted.
        path: std.Build.LazyPath,
        format: assets.ImageFormat,
        /// Ignored by `.bitmap_16bpp`.
        palettizer: assets.Palettizer = .{ .naive = 256 },
        /// Optionally convert only this sub-rectangle of the image.
        /// Only supported by the bitmap formats.
        rect: ?RectU16 = null,
        /// If not set, then an empty input image will trigger an error.
        allow_empty: bool = false,
    };
    
    pub const ConvertedImage = struct {
        /// Converted tile or bitmap data.
        data: std.Build.LazyPath,
        /// The palettizer's palette, quantized to 16-bit GBA colors.
        palette: std.Build.LazyPath,
    };
    
    /// Add a build step converting an image to GBA tile or bitmap data.
    pub fn addConvertImage(
        self: *GbaBuild,
        options: ConvertImageOptions,
    ) ConvertedImage {
        const converted = self.addConvertImages(.{
            .name = options.name,
            .palettizer = options.palettizer,
            .images = &.{ .{
                .path = options.path,
                .format = options.format,
                .rect = options.rect,
                .allow_empty = options.allow_empty,
            } },
        });
        return .{ .data = converted.images[0], .palette = converted.palette };
    }
    
    /// Write palette data to a file, e.g. for use with `@embedFile`.
    pub fn addPaletteFile(
        self: *GbaBuild,
        palette: []const color.ColorRgb555,
    ) std.Build.LazyPath {
        const files = self.b.addWriteFiles();
        return files.add("palette.agp", std.mem.sliceAsBytes(palette));
    }
};

pub const GbaExecutable = struct {
    b: *GbaBuild,
    step: *std.Build.Step.Compile,
    /// The `*.gba` ROM file, e.g. to pass to an emulator with `Run.addFileArg`.
    rom: std.Build.LazyPath,
    
    pub fn init(
        b: *GbaBuild,
        step: *std.Build.Step.Compile,
        rom: std.Build.LazyPath,
    ) GbaExecutable {
        return .{ .b = b, .step = step, .rom = rom };
    }
    
    pub fn create(
        b: *GbaBuild,
        step: *std.Build.Step.Compile,
        rom: std.Build.LazyPath,
    ) *GbaExecutable {
        const exe = b.allocator().create(GbaExecutable) catch @panic("OOM");
        exe.* = .init(b, step, rom);
        return exe;
    }
    
    pub fn getOwner(self: GbaExecutable) *std.Build {
        return self.step.step.owner;
    }
    
    pub fn dependOn(self: *GbaExecutable, step: *std.Build.Step) void {
        self.step.step.dependOn(step);
    }
    
    /// Make a file available to the ROM's root module via `@embedFile(name)`,
    /// e.g. data produced by `GbaBuild.addConvertImage`.
    pub fn addAsset(
        self: *GbaExecutable,
        name: []const u8,
        file: std.Build.LazyPath,
    ) void {
        self.step.root_module.addAnonymousImport(name, .{
            .root_source_file = file,
        });
    }
};
