//! Jobs for the `ziggba_assets` tool, which ZigGBA's build steps run to
//! convert images and fonts. The build script serializes a `Job` as ZON and
//! passes it as the tool's first argument, so both sides share these types.

const ColorRgba32 = @import("color.zig").ColorRgba32;
const RectU16 = @import("../gba/math.zig").RectU16;
const Vec2U16 = @import("../gba/math.zig").Vec2U16;

/// Determines which palette index is used for each pixel in an image.
pub const Palettizer = union(enum) {
    /// Use `PalettizerNearest` with these colors. Pixels are matched to the
    /// nearest color, and index 0 is reserved for transparency.
    nearest: []const ColorRgba32,
    /// Use `PalettizerNaive`, recording up to this many distinct colors in
    /// order of appearance. Index 0 is reserved for transparency.
    naive: u16,
};

/// Output data formats for image conversion.
pub const ImageFormat = enum {
    /// 4bpp tiles, as produced by `convertImageTiles4Bpp`.
    tiles_4bpp,
    /// 8bpp tiles, as produced by `convertImageTiles8Bpp`.
    tiles_8bpp,
    /// Palettized bitmap, as produced by `convertImageBitmap8Bpp`.
    bitmap_8bpp,
    /// Truecolor bitmap, as produced by `convertImageBitmap16Bpp`.
    bitmap_16bpp,
};

/// Options for converting one image.
pub const Image = struct {
    format: ImageFormat,
    /// Optionally convert only this sub-rectangle of the image.
    /// Only supported by the bitmap formats.
    rect: ?RectU16 = null,
    /// If not set, then an empty input image will trigger an error.
    allow_empty: bool = false,
};

pub const Job = union(enum) {
    /// Convert images in order, sharing one palettizer, then write its
    /// palette quantized to 16-bit GBA colors.
    /// Remaining tool arguments: the palette output path, followed by an
    /// input and output path for each image.
    images: struct {
        palettizer: Palettizer,
        images: []const Image,
    },
    /// Build font data for `gba.text` from a charset image.
    /// Remaining tool arguments: the input image path and output path.
    font: struct {
        grid_size: Vec2U16,
        image_rect: RectU16,
    },
};
