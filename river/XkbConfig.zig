// SPDX-FileCopyrightText: © 2026 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const XkbConfig = @This();

const std = @import("std");
const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");

const server = &@import("main.zig").server;

const XkbKeymap = @import("XkbKeymap.zig");
const XkbKeyboard = @import("XkbKeyboard.zig");

keymaps: wl.list.Head(XkbKeymap, .link),
keyboards: wl.list.Head(XkbKeyboard, .link),

context: *xkb.Context,
default_keymap: *xkb.Keymap,

server_destroy: wl.Listener(*wl.Server) = .init(handleServerDestroy),

pub fn init(config: *XkbConfig) !void {
    const context = xkb.Context.new(.no_flags) orelse return error.XkbContextFailed;
    defer context.unref();

    const default_keymap = xkb.Keymap.newFromNames(context, null, .no_flags) orelse return error.XkbKeymapFailed;
    defer default_keymap.unref();

    config.* = .{
        .context = context.ref(),
        .default_keymap = default_keymap.ref(),
        .keymaps = undefined,
        .keyboards = undefined,
    };
    config.keymaps.init();
    config.keyboards.init();

    server.wl_server.addDestroyListener(&config.server_destroy);
}

fn handleServerDestroy(listener: *wl.Listener(*wl.Server), _: *wl.Server) void {
    const config: *XkbConfig = @fieldParentPtr("server_destroy", listener);
    config.context.unref();
    config.default_keymap.unref();
}

/// Nile helper: create a keymap from an fd (for config scripts that load xkb keymaps).
/// Validates fd, mmaps and parses via libxkbcommon. Returns owned XkbKeymap.
pub fn createKeymapFromFd(fd: i32, format: xkb.Keymap.Format) !*XkbKeymap {
    defer _ = std.c.close(fd);
    const io = std.Io.Threaded.global_single_threaded.io();
    var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    const stat = file.stat(io) catch return error.StatFailed;
    if (stat.size < 1) return error.KeymapTooSmall;
    if (stat.size > 1024 * 1024) return error.KeymapTooLarge;
    const keymap_len: usize = @intCast(stat.size - 1);
    const keymap_ptr = std.c.mmap(null, keymap_len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
    if (keymap_ptr == std.c.MAP_FAILED) return error.MmapFailed;
    defer _ = std.c.munmap(@alignCast(keymap_ptr), keymap_len);
    const keymap = xkb.Keymap.newFromBuffer(
        server.xkb_config.context,
        @ptrCast(keymap_ptr),
        keymap_len,
        format,
        .no_flags,
    ) orelse return error.ParseFailed;
    defer keymap.unref();
    return try XkbKeymap.create(keymap);
}
