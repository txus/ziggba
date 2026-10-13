const std = @import("std");

const ColorRgb555 = @import("../gba/color.zig").ColorRgb555;

/// Save palette data as a binary file at a given file path.
pub fn savePalette(
    io: std.Io,
    palette: []const ColorRgb555,
    output_path: []const u8,
) !void {
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = output_path,
        .data = std.mem.sliceAsBytes(palette),
    });
}
