//! Asset conversion tool run by ZigGBA's build steps.
//! See `build/assets.zig` for the arguments it expects.

const std = @import("std");
const assets = @import("build/assets.zig");
const color = @import("build/color.zig");
const font = @import("build/font.zig");
const image = @import("build/image.zig");
const ColorRgb555 = @import("gba/color.zig").ColorRgb555;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if(args.len < 2) {
        std.log.err("usage: {s} <job.zon> <paths...>", .{ args[0] });
        return error.InvalidArguments;
    }
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const job = std.zon.parse.fromSlice(assets.Job, .{
        .gpa = init.gpa,
        .arena = arena,
        .source = args[1],
        .diagnostics = &diagnostics,
    }) catch |err| {
        if(err == error.ParseZon) diagnostics.log("job");
        return err;
    };
    const paths = args[2..];
    switch(job) {
        .images => |images_job| {
            if(paths.len != 1 + (2 * images_job.images.len)) {
                return error.InvalidArguments;
            }
            try convertImages(arena, io, images_job.palettizer, images_job.images, paths[0], paths[1..]);
        },
        .font => |font_job| {
            if(paths.len != 2) {
                return error.InvalidArguments;
            }
            try font.buildSaveFontPath(
                paths[0],
                paths[1],
                font_job.grid_size,
                font_job.image_rect,
                arena,
                io,
            );
        },
    }
}

fn convertImages(
    allocator: std.mem.Allocator,
    io: std.Io,
    palettizer_options: assets.Palettizer,
    images: []const assets.Image,
    palette_path: []const u8,
    image_paths: []const [:0]const u8,
) !void {
    var nearest: color.PalettizerNearest = undefined;
    var naive: color.PalettizerNaive = undefined;
    const palettizer = switch(palettizer_options) {
        .nearest => |colors| blk: {
            nearest = .init(colors);
            break :blk nearest.pal();
        },
        .naive => |max_colors| blk: {
            naive = try .init(allocator, max_colors);
            break :blk naive.pal();
        },
    };
    const quantizer_linear: color.ColorQuantizerLinear = .init();
    const quantizer = quantizer_linear.quantizer();
    for(images, 0..) |options, i| {
        const input_path = image_paths[2 * i];
        const output_path = image_paths[(2 * i) + 1];
        switch(options.format) {
            .tiles_4bpp, .tiles_8bpp => {
                if(options.rect != null) {
                    return error.TilesRectUnsupported;
                }
            },
            else => {},
        }
        switch(options.format) {
            .tiles_4bpp => try image.convertSaveImageTiles4BppPath(
                allocator,
                io,
                input_path,
                output_path,
                .{ .palettizer = palettizer, .allow_empty = options.allow_empty },
            ),
            .tiles_8bpp => try image.convertSaveImageTiles8BppPath(
                allocator,
                io,
                input_path,
                output_path,
                .{ .palettizer = palettizer, .allow_empty = options.allow_empty },
            ),
            .bitmap_8bpp => try image.convertSaveImageBitmap8BppPath(
                allocator,
                io,
                input_path,
                output_path,
                .{
                    .palettizer = palettizer,
                    .rect = options.rect,
                    .allow_empty = options.allow_empty,
                },
            ),
            .bitmap_16bpp => try image.convertSaveImageBitmap16BppPath(
                allocator,
                io,
                input_path,
                output_path,
                .{
                    .quantizer = quantizer,
                    .rect = options.rect,
                    .allow_empty = options.allow_empty,
                },
            ),
        }
    }
    const palette_colors = palettizer.getPalette();
    const palette = try allocator.alloc(ColorRgb555, palette_colors.len);
    quantizer.quantizeSlice(palette_colors, palette, .{});
    try color.savePalette(io, palette, palette_path);
}
