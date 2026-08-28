// SPDX-FileCopyrightText: © 2025 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const LibinputConfig = @This();

const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;

const LibinputDevice = @import("LibinputDevice.zig");

devices: wl.list.Head(LibinputDevice, .link),

server_destroy: wl.Listener(*wl.Server) = .init(handleServerDestroy),

pub fn init(config: *LibinputConfig) !void {
    config.* = .{
        .devices = undefined,
    };
    config.devices.init();
    server.wl_server.addDestroyListener(&config.server_destroy);
}

fn handleServerDestroy(listener: *wl.Listener(*wl.Server), _: *wl.Server) void {
    const config: *LibinputConfig = @fieldParentPtr("server_destroy", listener);
    _ = config;
}
