// SPDX-FileCopyrightText: © 2025 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

// Nile: libinput accel config is now managed directly via libinput API.
// This is a minimal stub kept so imports still resolve; protocol handling removed.

const LibinputAccelConfig = @This();

const c = @import("c");
const util = @import("util.zig");

libinput: ?*c.libinput_config_accel = null,

pub fn create(profile: c.enum_libinput_config_accel_profile) !*LibinputAccelConfig {
    const accel_config = try util.gpa.create(LibinputAccelConfig);
    accel_config.* = .{
        .libinput = c.libinput_config_accel_create(profile),
    };
    return accel_config;
}

pub fn destroy(accel_config: *LibinputAccelConfig) void {
    if (accel_config.libinput) |libinput| {
        c.libinput_config_accel_destroy(libinput);
    }
    util.gpa.destroy(accel_config);
}
