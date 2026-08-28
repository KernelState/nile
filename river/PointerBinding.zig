// SPDX-FileCopyrightText: © 2020 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

// Nile: bindings managed via Nile API. Protocol object removed.

const PointerBinding = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Seat = @import("Seat.zig");

seat: *Seat,

button: u32,
modifiers: u32,

wm_scheduled: struct {
    state_change: enum {
        none,
        pressed,
        released,
    } = .none,
} = .{},
wm_requested: struct {
    enabled: bool = false,
} = .{},

sent_pressed: bool = false,

/// Seat.pointer_bindings
link: wl.list.Link,

pub fn create(
    seat: *Seat,
    button: u32,
    modifiers: u32,
) !*PointerBinding {
    const binding = try util.gpa.create(PointerBinding);
    errdefer util.gpa.destroy(binding);
    binding.* = .{
        .seat = seat,
        .button = button,
        .modifiers = modifiers,
        .link = undefined,
    };
    seat.pointer_bindings.append(binding);
    return binding;
}

pub fn destroy(binding: *PointerBinding) void {
    if (binding.seat.cursor.pressed.getPtr(binding.button)) |value_ptr| {
        if (value_ptr.* == binding) {
            value_ptr.* = null;
        }
    }
    binding.link.remove();
    util.gpa.destroy(binding);
}

pub fn pressed(binding: *PointerBinding) void {
    assert(!binding.sent_pressed);
    assert(binding.wm_scheduled.state_change == .none);
    binding.wm_scheduled.state_change = .pressed;
    server.wm.dirtyWindowing();
}

pub fn released(binding: *PointerBinding) void {
    assert(binding.sent_pressed);
    assert(binding.wm_scheduled.state_change == .none);
    binding.wm_scheduled.state_change = .released;
    server.wm.dirtyWindowing();
}

pub fn match(
    binding: *const PointerBinding,
    button: u32,
    modifiers: wlr.Keyboard.ModifierMask,
) bool {
    if (!binding.wm_requested.enabled) return false;

    return button == binding.button and
        @as(u32, @bitCast(modifiers)) == binding.modifiers;
}
