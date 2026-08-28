// SPDX-FileCopyrightText: © 2020 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

// Nile: bindings managed via Nile.Seat.addXkbBinding. Protocol object removed.
// Keeps keysym/modifiers and matching logic; no wayland object.

const XkbBinding = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Seat = @import("Seat.zig");

seat: *Seat,

keysym: xkb.Keysym,
modifiers: u32,

wm_scheduled: struct {
    state_change: enum {
        none,
        pressed,
        stop_repeat,
        released,
    } = .none,
} = .{},
wm_requested: struct {
    enabled: bool = false,
    layout: ?u32 = null,
} = .{},

sent_pressed: bool = false,

/// Seat.xkb_bindings
link: wl.list.Link,

pub fn create(
    seat: *Seat,
    keysym: xkb.Keysym,
    modifiers: u32,
) !*XkbBinding {
    const binding = try util.gpa.create(XkbBinding);
    errdefer util.gpa.destroy(binding);
    binding.* = .{
        .seat = seat,
        .keysym = keysym,
        .modifiers = modifiers,
        .link = undefined,
    };
    seat.xkb_bindings.append(binding);
    return binding;
}

pub fn destroy(binding: *XkbBinding) void {
    // Clear any pressed refs in keyboard groups
    {
        var it = binding.seat.keyboard_groups.iterator(.forward);
        while (it.next()) |group| {
            for (group.pressed.values()) |*press| {
                if (press.consumer == .binding and press.consumer.binding == binding) {
                    press.consumer.binding = null;
                }
            }
        }
    }
    binding.link.remove();
    util.gpa.destroy(binding);
}

pub fn pressed(binding: *XkbBinding) void {
    assert(!binding.sent_pressed);
    assert(binding.wm_scheduled.state_change == .none);
    binding.wm_scheduled.state_change = .pressed;
    server.wm.dirtyWindowing();
}

pub fn stopRepeat(binding: *XkbBinding) void {
    assert(binding.sent_pressed);
    assert(binding.wm_scheduled.state_change == .none or
        binding.wm_scheduled.state_change == .stop_repeat);
    binding.wm_scheduled.state_change = .stop_repeat;
    server.wm.dirtyWindowing();
}

pub fn released(binding: *XkbBinding) void {
    assert(binding.sent_pressed);
    assert(binding.wm_scheduled.state_change == .stop_repeat);
    binding.wm_scheduled.state_change = .released;
    server.wm.dirtyWindowing();
}

/// Compare binding with given keycode, modifiers and keyboard state
pub fn match(
    binding: *const XkbBinding,
    keycode: xkb.Keycode,
    modifiers: wlr.Keyboard.ModifierMask,
    xkb_state: *xkb.State,
    method: enum { no_translate, translate },
) bool {
    if (!binding.wm_requested.enabled) return false;

    const keymap = xkb_state.getKeymap();
    const layout = binding.wm_requested.layout orelse xkb_state.keyGetLayout(keycode);

    switch (method) {
        .no_translate => {
            const keysyms = keymap.keyGetSymsByLevel(
                keycode,
                layout,
                0,
            );
            if (@as(u32, @bitCast(modifiers)) == binding.modifiers) {
                for (keysyms) |sym| {
                    if (sym == binding.keysym) {
                        return true;
                    }
                }
            }
        },
        .translate => {
            const keysyms_translated = keymap.keyGetSymsByLevel(
                keycode,
                layout,
                xkb_state.keyGetLevel(keycode, layout),
            );
            const consumed = xkb_state.keyGetConsumedMods2(keycode, .xkb);
            const modifiers_translated = @as(u32, @bitCast(modifiers)) & ~consumed;
            if (modifiers_translated == binding.modifiers) {
                for (keysyms_translated) |sym| {
                    if (sym == binding.keysym) {
                        return true;
                    }
                }
            }
        },
    }

    return false;
}
