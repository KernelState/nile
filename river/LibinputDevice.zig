// SPDX-FileCopyrightText: © 2025 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const LibinputDevice = @This();

const wl = @import("wayland").server.wl;

const c = @import("c");
const server = &@import("main.zig").server;

libinput: *c.libinput_device,

/// LibinputConfig.devices
link: wl.list.Link,

pub fn init(device: *LibinputDevice, handle: *c.libinput_device) void {
    device.* = .{
        .libinput = handle,
        .link = undefined,
    };
    server.libinput_config.devices.append(device);
}

pub fn deinit(device: *LibinputDevice) void {
    device.link.remove();
}
