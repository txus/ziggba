//! Docs root for the build API (`zig build docs`). `src/build/build.zig`
//! can't be the root itself, since it imports `../gba` from outside its
//! own directory.

pub const build = @import("build/build.zig");
