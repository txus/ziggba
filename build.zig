const std = @import("std");

pub const gba = @import("src/build/build.zig");

/// Build example ROMs.
pub fn build(std_b: *std.Build) void {
    const b = gba.GbaBuild.create(std_b);
    
    // Build examples.
    
    _ = b.addExecutable(.{
        .name = "biosCpuTest",
        .root_source_file = b.path("examples/biosCpuTest/biosCpuTest.zig"),
        .build_options = .{ .text_charsets = .all },
    });
    _ = b.addExecutable(.{
        .name = "charBlock",
        .root_source_file = b.path("examples/charBlock/charBlock.zig"),
    });
    _ = b.addExecutable(.{
        .name = "debugPrint",
        .root_source_file = b.path("examples/debugPrint/debugPrint.zig"),
    });
    _ = b.addExecutable(.{
        .name = "first",
        .root_source_file = b.path("examples/first/first.zig"),
    });
    _ = b.addExecutable(.{
        .name = "helloWorld",
        .root_source_file = b.path("examples/helloWorld/helloWorld.zig"),
        .build_options = .{ .text_charsets = .all },
    });
    _ = b.addExecutable(.{
        .name = "interrupts",
        .root_source_file = b.path("examples/interrupts/interrupts.zig"),
        .build_options = .{ .text_charsets = .all },
    });
    _ = b.addExecutable(.{
        .name = "keydemo",
        .root_source_file = b.path("examples/keydemo/keydemo.zig"),
    });
    _ = b.addExecutable(.{
        .name = "memory",
        .root_source_file = b.path("examples/memory/memory.zig"),
        .build_options = .{ .text_charsets = .all },
    });
    _ = b.addExecutable(.{
        .name = "mode3draw",
        .root_source_file = b.path("examples/mode3draw/mode3draw.zig"),
    });
    _ = b.addExecutable(.{
        .name = "mode4draw",
        .root_source_file = b.path("examples/mode4draw/mode4draw.zig"),
    });
    _ = b.addExecutable(.{
        .name = "objAffine",
        .root_source_file = b.path("examples/objAffine/objAffine.zig"),
    });
    _ = b.addExecutable(.{
        .name = "objDemo",
        .root_source_file = b.path("examples/objDemo/objDemo.zig"),
    });
    _ = b.addExecutable(.{
        .name = "panic",
        .root_source_file = b.path("examples/panic/panic.zig"),
        .build_options = .{ .text_charsets = .all },
    });
    _ = b.addExecutable(.{
        .name = "secondsTimer",
        .root_source_file = b.path("examples/secondsTimer/secondsTimer.zig"),
    });
    _ = b.addExecutable(.{
        .name = "screenBlock",
        .root_source_file = b.path("examples/screenBlock/screenBlock.zig"),
    });
    _ = b.addExecutable(.{
        .name = "surfaces",
        .root_source_file = b.path("examples/surfaces/surfaces.zig"),
        .build_options = .{ .text_charsets = .all },
    });
    _ = b.addExecutable(.{
        .name = "tileDemo",
        .root_source_file = b.path("examples/tileDemo/tileDemo.zig"),
    });
    
    var bgAffine = b.addExecutable(.{
        .name = "bgAffine",
        .root_source_file = b.path("examples/bgAffine/bgAffine.zig"),
        .build_options = .{ .text_charsets = .all },
    });
    const bgAffine_tiles = b.addConvertImage(.{
        .path = b.path("examples/bgAffine/tiles.png"),
        .format = .tiles_8bpp,
        .palettizer = .{ .nearest = &.{
            .transparent,
            .white,
            .red,
            .green,
            .aqua,
        } },
    });
    bgAffine.addAsset("tiles", bgAffine_tiles.data);
    
    var jesuMusic = b.addExecutable(.{
        .name = "jesuMusic",
        .root_source_file = b.path("examples/jesuMusic/jesuMusic.zig"),
    });
    const jesuMusic_charset = b.addConvertImage(.{
        .path = b.path("examples/jesuMusic/charset.png"),
        .format = .tiles_4bpp,
        .palettizer = .{ .nearest = &.{
            .transparent,
            .white,
            .black,
        } },
    });
    jesuMusic.addAsset("charset", jesuMusic_charset.data);

    var mode4flip = b.addExecutable(.{
        .name = "mode4flip",
        .root_source_file = b.path("examples/mode4flip/mode4flip.zig"),
    });
    // Both images share a palette, built from the colors they contain.
    const mode4flip_images = b.addConvertImages(.{
        .palettizer = .{ .naive = 256 },
        .images = &.{
            .{ .path = b.path("examples/mode4flip/front.bmp"), .format = .bitmap_8bpp },
            .{ .path = b.path("examples/mode4flip/back.bmp"), .format = .bitmap_8bpp },
        },
    });
    mode4flip.addAsset("front", mode4flip_images.images[0]);
    mode4flip.addAsset("back", mode4flip_images.images[1]);
    mode4flip.addAsset("palette", mode4flip_images.palette);
    
    // Run tests with `zig build test`.
    
    const test_math = std_b.addRunArtifact(std_b.addTest(.{
        .root_module = std_b.createModule(.{
            .root_source_file = std_b.path("src/gba/math.zig"),
            .target = std_b.graph.host,
        }),
    }));
    const test_format = std_b.addRunArtifact(std_b.addTest(.{
        .root_module = std_b.createModule(.{
            .root_source_file = std_b.path("src/gba/format.zig"),
            .target = std_b.graph.host,
        }),
    }));

    const test_step = std_b.step("test", "Run unit tests");
    test_step.dependOn(&test_math.step);
    test_step.dependOn(&test_format.step);
    
    // Build API docs with `zig build docs`, written to `zig-out/docs/`.
    
    const docs_step = std_b.step("docs", "Build API docs");
    const docs_roots = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "gba", .path = "src/gba/gba.zig" },
        .{ .name = "build", .path = "src/build_docs.zig" },
    };
    for(docs_roots) |root| {
        const docs_obj = std_b.addObject(.{
            .name = root.name,
            .root_module = std_b.createModule(.{
                .root_source_file = std_b.path(root.path),
                .target = std_b.graph.host,
            }),
        });
        const install_docs = std_b.addInstallDirectory(.{
            .source_dir = docs_obj.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = std_b.fmt("docs/{s}", .{ root.name }),
        });
        docs_step.dependOn(&install_docs.step);
    }
}
