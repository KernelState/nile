// SPDX-FileCopyrightText: © 2025 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const LayerShellSeat = @This();

const std = @import("std");

const LayerSurface = @import("LayerSurface.zig");

const Focus = union(enum) {
    exclusive: LayerSurface.Ref,
    non_exclusive: LayerSurface.Ref,
    none,
};

scheduled: struct {
    focus: Focus = .none,
} = .{},
sent: struct {
    focus: Focus = .none,
} = .{},
requested: struct {} = .{},

pub fn makeInert(_: *LayerShellSeat) void {}

pub fn manageStart(shell_seat: *LayerShellSeat) void {
    shell_seat.sent.focus = shell_seat.scheduled.focus;
}
