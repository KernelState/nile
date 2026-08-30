// SPDX-FileCopyrightText: © 2025 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

// Nile: legacy river_xkb_bindings_v1 protocol removed. Bindings are managed
// via Nile.Seat.addXkbBinding (see Nile.zig). This is a no-op stub.

const XkbBindings = @This();

const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;

server_destroy: wl.Listener(*wl.Server) = .init(handleServerDestroy),

pub fn init(bindings: *XkbBindings) !void {
    bindings.* = .{};
    server.wl_server.addDestroyListener(&bindings.server_destroy);
}

fn handleServerDestroy(listener: *wl.Listener(*wl.Server), _: *wl.Server) void {
    const bindings: *XkbBindings = @fieldParentPtr("server_destroy", listener);
    _ = bindings;
}
