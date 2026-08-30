// SPDX-FileCopyrightText: © 2022 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const InputDevice = @This();

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const c = @import("c");
const server = &@import("main.zig").server;
const util = @import("util.zig");

const Keyboard = @import("Keyboard.zig");
const LibinputDevice = @import("LibinputDevice.zig");
const Seat = @import("Seat.zig");
const Tablet = @import("Tablet.zig");
const XkbKeyboard = @import("XkbKeyboard.zig");

const log = std.log.scoped(.input);

seat: *Seat,
wlr_device: *wlr.InputDevice,
virtual: bool,

libinput: LibinputDevice,
xkb_keyboard: XkbKeyboard,

remove: wl.Listener(*wlr.InputDevice) = .init(handleRemove),

config: struct {
    scroll_factor: f64 = 1.0,
    map_to_output: ?*wlr.Output = null,
    map_to_rectangle: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
} = .{},

/// InputManager.devices
link: wl.list.Link,

pub fn init(
    device: *InputDevice,
    seat: *Seat,
    wlr_device: *wlr.InputDevice,
    virtual: bool,
) !void {
    device.* = .{
        .seat = seat,
        .wlr_device = wlr_device,
        .virtual = virtual,
        .libinput = undefined,
        .xkb_keyboard = undefined,
        .link = undefined,
    };
    server.input_manager.devices.append(device);
    @import("Compositor.zig").notify(.{ .input_device_add = device });

    wlr_device.data = device;
    wlr_device.events.destroy.add(&device.remove);

    log.debug("new {s}input device: {s}-{s}", .{
        if (virtual) "virtual " else "",
        @tagName(wlr_device.type),
        wlr_device.name orelse "unknown",
    });

    if (!virtual) {
        if (wlr_device.getLibinputDevice()) |handle| {
            device.libinput.init(@ptrCast(handle));
        }
        if (wlr_device.type == .keyboard) {
            device.xkb_keyboard.init();
        }
    }

    // The wlroots Wayland and X11 backends support multiple outputs
    // exposed as multiple windows in the host session. However, this
    // requires mapping pointer/touch devices to the outputs suggested
    // by the backend to make input work as expected.
    if (switch (wlr_device.type) {
        .pointer => wlr_device.toPointer().output_name,
        .touch => wlr_device.toTouch().output_name,
        else => null,
    }) |output_name| {
        var it = server.om.outputs.iterator(.forward);
        while (it.next()) |output| {
            const wlr_output = output.wlr_output orelse continue;
            if (mem.orderZ(u8, output_name, wlr_output.name) == .eq) {
                device.config.map_to_output = wlr_output;
                break;
            }
        }
    }
}

pub fn deinit(device: *InputDevice) void {
    if (!device.virtual) {
        if (device.wlr_device.getLibinputDevice() != null) {
            device.libinput.deinit();
        }
        if (device.wlr_device.type == .keyboard) {
            device.xkb_keyboard.deinit();
        }
    }

    device.remove.link.remove();
    device.link.remove();
    device.seat.updateCapabilities();

    device.wlr_device.data = null;

    device.* = undefined;
}

pub fn assignToSeat(device: *InputDevice, new: *Seat) void {
    const old = device.seat;
    if (new == old) return;
    old.detachDevice(device);
    new.attachDevice(device);
    old.updateCapabilities();
    new.updateCapabilities();
}

/// Retuns the curretly active mapping for the device, or an empty box if
/// the movement of the device is unrestricted.
pub fn activeMapping(device: *const InputDevice) wlr.Box {
    var mapping = device.config.map_to_rectangle;
    if (!mapping.empty()) {
        return mapping;
    }
    if (device.config.map_to_output) |output| {
        server.om.output_layout.getBox(output, &mapping);
    }
    return mapping;
}

fn handleRemove(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
    const device: *InputDevice = @fieldParentPtr("remove", listener);

    @import("Compositor.zig").notify(.{ .input_device_remove = device });

    log.debug("removed input device: {s}-{s}", .{
        @tagName(device.wlr_device.type),
        device.wlr_device.name orelse "unknown",
    });

    switch (device.wlr_device.type) {
        .keyboard => {
            const keyboard: *Keyboard = @fieldParentPtr("device", device);
            keyboard.deviceDestroy();
        },
        .pointer, .touch => {
            device.deinit();
            util.gpa.destroy(device);
        },
        .tablet => {
            const tablet: *Tablet = @fieldParentPtr("device", device);
            tablet.destroy();
        },
        .@"switch", .tablet_pad => unreachable,
    }
}


