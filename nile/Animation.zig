// SPDX-FileCopyrightText: © 2026 The Nile Developers
// SPDX-License-Identifier: GPL-3.0-only

//! Animation — configurable compositor animations.
//!
//! Nile supports several independent animation families, each with its own
//! kind, duration and easing. All families can be disabled individually
//! (kind = .none) or globally via `Config.disableAll()` / `Config.enabled = false`.
//!
//! Families:
//!   - **window_open / window_close** — when a window maps / unmaps.
//!     Kinds: `none`, `fade`, `scale`, `scfade` (scale + fade, scale starts at 94%).
//!   - **tiling** — when the tiling layout recomputes (window moved/resized by thewm).
//!     Kinds: `none`, `slide` (position+size lerp, current default).
//!   - **popup_open / popup_close** — xdg-popup appear / disappear.
//!     Kinds: `none`, `fade`, `scale`, `scfade`.
//!
//! JSON representation (future-proof):
//! ```json
//! {
//!   "enabled": true,
//!   "window_open":  { "kind": "scfade", "duration_ms": 220, "easing": "ease_out_cubic", "scale_from": 0.94 },
//!   "window_close": { "kind": "fade",   "duration_ms": 180, "easing": "ease_out_cubic" },
//!   "tiling":       { "kind": "slide",  "duration_ms": 200, "easing": "ease_out_cubic" },
//!   "popup_open":   { "kind": "fade",   "duration_ms": 150, "easing": "ease_out_cubic" },
//!   "popup_close":  { "kind": "fade",   "duration_ms": 120, "easing": "ease_out_cubic" }
//! }
//! ```
//! Missing keys fall back to defaults. Set `"enabled": false` or set every
//! `kind` to `"none"` to disable all animations. The file is typically
//! `~/.config/nile/animations.json` or `$XDG_CONFIG_HOME/nile/animations.json`.

const std = @import("std");
const fs = std.fs;
const Io = std.Io;

pub const Easing = enum {
    linear,
    ease_out_cubic,
    ease_in_cubic,
    ease_in_out_cubic,

    pub fn apply(self: Easing, t: f64) f64 {
        return switch (self) {
            .linear => t,
            .ease_out_cubic => 1 - std.math.pow(f64, 1 - t, 3),
            .ease_in_cubic => std.math.pow(f64, t, 3),
            .ease_in_out_cubic => if (t < 0.5) 4 * t * t * t else 1 - std.math.pow(f64, -2 * t + 2, 3) / 2,
        };
    }
};

pub const WindowKind = enum {
    none,
    fade,
    scale,
    scfade,
};

pub const TilingKind = enum {
    none,
    slide,
};

pub const PopupKind = enum {
    none,
    fade,
    scale,
    scfade,
};

pub const WindowOpenConfig = struct {
    kind: WindowKind = .scfade,
    duration_ms: u32 = 220,
    easing: Easing = .ease_out_cubic,
    /// Only used when kind == .scfade or .scale. 0.94 means 94% size at start.
    scale_from: f32 = 0.94,
};

pub const WindowCloseConfig = struct {
    kind: WindowKind = .fade,
    duration_ms: u32 = 180,
    easing: Easing = .ease_out_cubic,
    scale_from: f32 = 0.94,
};

pub const TilingConfig = struct {
    kind: TilingKind = .slide,
    duration_ms: u32 = 200,
    easing: Easing = .ease_out_cubic,
};

pub const PopupOpenConfig = struct {
    kind: PopupKind = .fade,
    duration_ms: u32 = 150,
    easing: Easing = .ease_out_cubic,
    scale_from: f32 = 0.94,
};

pub const PopupCloseConfig = struct {
    kind: PopupKind = .fade,
    duration_ms: u32 = 120,
    easing: Easing = .ease_out_cubic,
    scale_from: f32 = 0.94,
};

pub const Config = struct {
    /// Master switch. If false, all animations behave as .none regardless of per-family kind.
    enabled: bool = true,

    window_open: WindowOpenConfig = .{},
    window_close: WindowCloseConfig = .{},
    tiling: TilingConfig = .{},
    popup_open: PopupOpenConfig = .{},
    popup_close: PopupCloseConfig = .{},

    /// Return a config with every animation disabled (all kinds .none).
    pub fn disabled() Config {
        return .{
            .enabled = false,
            .window_open = .{ .kind = .none, .duration_ms = 0 },
            .window_close = .{ .kind = .none, .duration_ms = 0 },
            .tiling = .{ .kind = .none, .duration_ms = 0 },
            .popup_open = .{ .kind = .none, .duration_ms = 0 },
            .popup_close = .{ .kind = .none, .duration_ms = 0 },
        };
    }

    /// Set every family to .none in-place. Keeps durations but they are ignored.
    pub fn setAllNone(self: *Config) void {
        self.window_open.kind = .none;
        self.window_close.kind = .none;
        self.tiling.kind = .none;
        self.popup_open.kind = .none;
        self.popup_close.kind = .none;
    }

    pub fn isTilingEnabled(self: Config) bool {
        return self.enabled and self.tiling.kind != .none;
    }
    pub fn isWindowOpenEnabled(self: Config) bool {
        return self.enabled and self.window_open.kind != .none;
    }
    pub fn isWindowCloseEnabled(self: Config) bool {
        return self.enabled and self.window_close.kind != .none;
    }
    pub fn isPopupOpenEnabled(self: Config) bool {
        return self.enabled and self.popup_open.kind != .none;
    }
    pub fn isPopupCloseEnabled(self: Config) bool {
        return self.enabled and self.popup_close.kind != .none;
    }

    /// Serialize to JSON (allocates). Caller owns returned slice.
    pub fn toJson(self: Config, gpa: std.mem.Allocator) ![]u8 {
        return try std.json.Stringify.valueAlloc(gpa, self, .{ .whitespace = .indent_2 });
    }

    /// Parse from JSON slice. Missing keys use defaults.
    pub fn fromJson(gpa: std.mem.Allocator, slice: []const u8) !Config {
        const parsed = try std.json.parseFromSlice(
            Config,
            gpa,
            slice,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
        );
        defer parsed.deinit();
        return parsed.value;
    }

    /// Load from file path. Returns default config if file does not exist.
    pub fn loadFromFile(gpa: std.mem.Allocator, path: []const u8) !Config {
        const io = Io.Threaded.global_single_threaded.io();
        var file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return Config{},
            else => return err,
        };
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var reader = file.reader(io, &buf);
        const slice = try reader.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(slice);
        return Config.fromJson(gpa, slice);
    }

    /// Save to file path (creates/truncates). Caller ensures parent dir exists.
    pub fn saveToFile(self: Config, gpa: std.mem.Allocator, path: []const u8) !void {
        const io = Io.Threaded.global_single_threaded.io();
        const json = try self.toJson(gpa);
        defer gpa.free(json);
        var file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var writer = file.writer(io, &buf);
        try writer.interface.writeAll(json);
        try writer.interface.flush();
    }
};

// Global config — accessed from Window, XdgPopup, WindowManager (main thread only).
var global: Config = .{};

pub fn get() Config {
    return global;
}

pub fn set(config: Config) void {
    global = config;
}

/// Convenience: disable all animations globally.
pub fn disableAll() void {
    global.setAllNone();
    global.enabled = false;
}

/// Load global config from `path`. If file missing, keeps defaults. Returns loaded config.
pub fn loadGlobalFromFile(gpa: std.mem.Allocator, path: []const u8) !Config {
    const cfg = try Config.loadFromFile(gpa, path);
    set(cfg);
    return cfg;
}

/// Try to load from XDG config home: $XDG_CONFIG_HOME/nile/animations.json or ~/.config/nile/animations.json
pub fn loadGlobalFromXdg(gpa: std.mem.Allocator) Config {
    const xdg_opt = std.c.getenv("XDG_CONFIG_HOME");
    const home_opt = std.c.getenv("HOME");
    const path: []const u8 = if (xdg_opt) |xdg| blk: {
        const slice = std.mem.sliceTo(xdg, 0);
        break :blk std.fs.path.join(gpa, &.{ slice, "nile/animations.json" }) catch return get();
    } else if (home_opt) |home| blk: {
        const slice = std.mem.sliceTo(home, 0);
        break :blk std.fs.path.join(gpa, &.{ slice, ".config/nile/animations.json" }) catch return get();
    } else return get();
    defer gpa.free(path);
    const cfg = Config.loadFromFile(gpa, path) catch return get();
    set(cfg);
    return cfg;
}

// Tests — JSON round-trip and none handling.
test "Config json round-trip" {
    const gpa = std.testing.allocator;
    const orig: Config = .{
        .enabled = true,
        .window_open = .{ .kind = .scfade, .duration_ms = 250, .easing = .ease_out_cubic, .scale_from = 0.94 },
        .window_close = .{ .kind = .fade, .duration_ms = 180, .easing = .linear },
        .tiling = .{ .kind = .slide, .duration_ms = 200, .easing = .ease_in_out_cubic },
        .popup_open = .{ .kind = .scale, .duration_ms = 150, .easing = .ease_out_cubic, .scale_from = 0.9 },
        .popup_close = .{ .kind = .fade, .duration_ms = 120, .easing = .ease_out_cubic },
    };
    const json = try orig.toJson(gpa);
    defer gpa.free(json);
    const parsed = try Config.fromJson(gpa, json);
    try std.testing.expectEqual(orig.enabled, parsed.enabled);
    try std.testing.expectEqual(orig.window_open.kind, parsed.window_open.kind);
    try std.testing.expectEqual(orig.window_open.duration_ms, parsed.window_open.duration_ms);
    try std.testing.expectEqual(orig.window_open.easing, parsed.window_open.easing);
    try std.testing.expectApproxEqAbs(orig.window_open.scale_from, parsed.window_open.scale_from, 1e-6);
    try std.testing.expectEqual(orig.tiling.kind, parsed.tiling.kind);
    try std.testing.expectEqual(orig.popup_open.kind, parsed.popup_open.kind);
}

test "Config disabled all none" {
    var cfg = Config{};
    cfg.setAllNone();
    try std.testing.expectEqual(WindowKind.none, cfg.window_open.kind);
    try std.testing.expectEqual(WindowKind.none, cfg.window_close.kind);
    try std.testing.expectEqual(TilingKind.none, cfg.tiling.kind);
    try std.testing.expectEqual(PopupKind.none, cfg.popup_open.kind);
    try std.testing.expectEqual(PopupKind.none, cfg.popup_close.kind);
    try std.testing.expect(!cfg.isTilingEnabled());
    try std.testing.expect(!cfg.isWindowOpenEnabled());
}

test "Config from partial json uses defaults" {
    const gpa = std.testing.allocator;
    const slice =
        \\{ "window_open": { "kind": "fade", "duration_ms": 300 } }
    ;
    const cfg = try Config.fromJson(gpa, slice);
    try std.testing.expectEqual(WindowKind.fade, cfg.window_open.kind);
    try std.testing.expectEqual(@as(u32, 300), cfg.window_open.duration_ms);
    // defaults for missing
    try std.testing.expectEqual(TilingKind.slide, cfg.tiling.kind);
    try std.testing.expectEqual(@as(u32, 200), cfg.tiling.duration_ms);
    try std.testing.expectEqual(true, cfg.enabled);
}

test "Config disabled via enabled false" {
    const gpa = std.testing.allocator;
    const slice =
        \\{ "enabled": false, "tiling": { "kind": "slide", "duration_ms": 200 } }
    ;
    const cfg = try Config.fromJson(gpa, slice);
    try std.testing.expect(!cfg.isTilingEnabled());
    try std.testing.expect(!cfg.isWindowOpenEnabled());
}
