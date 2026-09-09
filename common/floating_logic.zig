// SPDX-FileCopyrightText: © 2026 The Nile Developers
// SPDX-License-Identifier: GPL-3.0-only

//! Pure helpers for floating/workspace logic — extracted so they can be unit-tested
//! without pulling the whole compositor (wlroots, server global, etc.).
//! The real code in `nile/Window.zig` / `nile/NileCompositor.zig` mirrors these.

const std = @import("std");

pub const Mode = enum(u8) {
    tiling = 0,
    floating = 1,
};

/// Effective workspace mode: explicit if set, otherwise global fallback.
pub fn effectiveMode(explicit: ?Mode, global: Mode) Mode {
    return explicit orelse global;
}

/// Clamped floating placement near tiling position with offset.
/// - base_x/base_y: tiling position
/// - w/h: natural size (if 0, caller should fallback)
/// - idx: cascade index (0 = first)
/// - out_x/out_y/out_w/out_h: output exclusive area
pub fn floatingPlacement(
    base_x: i32,
    base_y: i32,
    w: i32,
    h: i32,
    idx: i32,
    out_x: i32,
    out_y: i32,
    out_w: i32,
    out_h: i32,
) struct { x: i32, y: i32 } {
    var x: i32 = base_x + 20 + idx * 16;
    var y: i32 = base_y + 20 + idx * 16;
    if (x + w > out_x + out_w) x = out_x + out_w - w - 20;
    if (y + h > out_y + out_h) y = out_y + out_h - h - 20;
    if (x < out_x) x = out_x + 20;
    if (y < out_y) y = out_y + 20;
    return .{ .x = x, .y = y };
}

test "effectiveMode fallback" {
    try std.testing.expectEqual(Mode.tiling, effectiveMode(null, .tiling));
    try std.testing.expectEqual(Mode.floating, effectiveMode(null, .floating));
    try std.testing.expectEqual(Mode.floating, effectiveMode(.floating, .tiling));
    try std.testing.expectEqual(Mode.tiling, effectiveMode(.tiling, .floating));
}

test "floatingPlacement offset and clamp" {
    // Simple offset without clamp
    {
        const p = floatingPlacement(100, 100, 800, 600, 0, 0, 0, 1920, 1080);
        try std.testing.expectEqual(120, p.x);
        try std.testing.expectEqual(120, p.y);
    }
    // Cascade idx 2
    {
        const p = floatingPlacement(100, 100, 800, 600, 2, 0, 0, 1920, 1080);
        try std.testing.expectEqual(152, p.x);
        try std.testing.expectEqual(152, p.y);
    }
    // Clamp to output right/bottom
    {
        const p = floatingPlacement(1800, 900, 400, 300, 0, 0, 0, 1920, 1080);
        // x would be 1820, clamp to 1920-400-20=1500
        try std.testing.expectEqual(1500, p.x);
        try std.testing.expectEqual(760, p.y);
    }
    // Clamp to output left/top (negative base)
    {
        const p = floatingPlacement(-50, -50, 400, 300, 0, 0, 0, 1920, 1080);
        // x = -30 -> clamp to 20
        try std.testing.expectEqual(20, p.x);
        try std.testing.expectEqual(20, p.y);
    }
}

test "floating restore size preference" {
    // When natural size exists, it should be used even if tiling stretched.
    // Pure check: if natural w < tiling w, prefer natural.
    const tiling_w: i32 = 960;
    const natural_w: i32 = 800;
    const chosen = if (natural_w != 0 and natural_w < tiling_w) natural_w else tiling_w;
    try std.testing.expectEqual(800, chosen);
    // If tiling is smaller (e.g. split), keep tiling?
    const tiling_small: i32 = 400;
    const natural_large: i32 = 800;
    const chosen2 = if (natural_large != 0 and natural_large < tiling_small) natural_large else tiling_small;
    try std.testing.expectEqual(400, chosen2);
}
