// SPDX-FileCopyrightText: © 2024 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const WmNode = @This();

const wl = @import("wayland").server.wl;

const Window = @import("Window.zig");
const ShellSurface = @import("ShellSurface.zig");

const Type = union(enum) {
    window: *Window,
    shell_surface: *ShellSurface,
};
const Tag = @typeInfo(Type).@"union".tag_type.?;

tag: Tag,

/// WindowManager.rendering_requested.list
link: wl.list.Link,

pub fn init(node: *WmNode, tag: Tag) void {
    node.* = .{
        .tag = tag,
        .link = undefined,
    };
    node.link.init();
}

pub fn deinit(node: *WmNode) void {
    node.link.remove();
}

pub fn get(node: *WmNode) Type {
    return switch (node.tag) {
        .window => .{ .window = @fieldParentPtr("node", node) },
        .shell_surface => .{ .shell_surface = @fieldParentPtr("node", node) },
    };
}

pub fn makeInert(_: *WmNode) void {}
