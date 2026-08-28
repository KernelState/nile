// SPDX-FileCopyrightText: © 2026 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

// Nile: protocol-less keyboard state tracking. No river_xkb_keyboard_v1 objects.

const XkbKeyboard = @This();

const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");

const server = &@import("main.zig").server;

sent: struct {
    layout_index: ?u32 = null,
    layout_name: ?[*:0]const u8 = null,
    capslock: ?bool = null,
    numlock: ?bool = null,
} = .{},

/// XkbConfig.keyboards
link: wl.list.Link,

pub fn init(xkb_keyboard: *XkbKeyboard) void {
    xkb_keyboard.* = .{
        .link = undefined,
    };
    server.xkb_config.keyboards.append(xkb_keyboard);
}

pub fn deinit(xkb_keyboard: *XkbKeyboard) void {
    xkb_keyboard.link.remove();
}

pub fn sendState(
    xkb_keyboard: *XkbKeyboard,
    layout_index: xkb.LayoutIndex,
    layout_name: ?[*:0]const u8,
    capslock: bool,
    numlock: bool,
) void {
    const sent = &xkb_keyboard.sent;
    sent.layout_index = layout_index;
    sent.layout_name = layout_name;
    sent.capslock = capslock;
    sent.numlock = numlock;
}
