// SPDX-FileCopyrightText: © 2026 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

// Nile: river_xkb_bindings_seat_v1 removed. Keep scheduling state for
// modifiers tracking and ensure_next_key_eaten used by KeyboardGroup/Seat.

const XkbBindingsSeat = @This();

const server = &@import("main.zig").server;

scheduled: struct {
    ate_unbound_key: bool = false,
    mods_update: ?struct {
        old: u32,
        new: u32,
    } = null,
} = .{},
requested: struct {
    next_key_change: enum {
        none,
        ensure_eaten,
        cancel_ensure_eaten,
    } = .none,
    mods_watched: u32 = 0,

    const init: @This() = .{
        .next_key_change = .none,
        .mods_watched = 0,
    };
} = .init,

ensure_next_key_eaten: bool = false,

pub fn makeInert(bindings_seat: *XkbBindingsSeat) void {
    bindings_seat.* = .{};
}

pub fn manageStart(bindings_seat: *XkbBindingsSeat) void {
    // Nile: previously sent ate_unbound_key / modifiers_update over protocol.
    // Now just clear scheduled state; no client to notify. Keep consumption for
    // future Nile notifications if needed.
    if (bindings_seat.scheduled.ate_unbound_key) {
        bindings_seat.scheduled.ate_unbound_key = false;
    }
    if (bindings_seat.scheduled.mods_update) |_| {
        bindings_seat.scheduled.mods_update = null;
    }
}

pub fn manageFinish(bindings_seat: *XkbBindingsSeat) void {
    switch (bindings_seat.requested.next_key_change) {
        .none => {},
        .ensure_eaten => bindings_seat.ensure_next_key_eaten = true,
        .cancel_ensure_eaten => bindings_seat.ensure_next_key_eaten = false,
    }
    bindings_seat.requested.next_key_change = .none;
}
