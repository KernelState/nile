// SPDX-FileCopyrightText: © 2026 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

// Nile: xkb keymaps managed directly; no river_xkb_keymap_v1 protocol objects.

const XkbKeymap = @This();

const xkb = @import("xkbcommon");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

xkb_keymap: *xkb.Keymap,

/// XkbConfig.keymaps
link: wl.list.Link,

pub fn create(xkb_keymap: *xkb.Keymap) !*XkbKeymap {
    const keymap = try util.gpa.create(XkbKeymap);
    errdefer util.gpa.destroy(keymap);
    keymap.* = .{
        .xkb_keymap = xkb_keymap.ref(),
        .link = undefined,
    };
    server.xkb_config.keymaps.append(keymap);
    return keymap;
}

pub fn destroy(keymap: *XkbKeymap) void {
    keymap.xkb_keymap.unref();
    keymap.link.remove();
    util.gpa.destroy(keymap);
}
