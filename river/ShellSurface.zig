// SPDX-FileCopyrightText: © 2024 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

// Nile: river_shell_surface_v1 protocol removed. Keep scene tree logic without protocol objects.

const ShellSurface = @This();

const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Scene = @import("Scene.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const WmNode = @import("WmNode.zig");

const role: wlr.Surface.Role = .{
    .name = "river_shell_surface_v1",
    .client_commit = clientCommit,
    .commit = commit,
    .unmap = null,
    .destroy = roleDestroy,
};

surface: *wlr.Surface,
tree: *wlr.SceneTree,
surfaces: Scene.SaveableSurfaces,
popup_tree: *wlr.SceneTree,
node: WmNode,

rendering_requested: struct {
    x: i32 = 0,
    y: i32 = 0,
    sync_next_commit: bool = false,
} = .{},

pub fn create(
    surface: *wlr.Surface,
) !void {
    const shell_surface = try util.gpa.create(ShellSurface);
    errdefer util.gpa.destroy(shell_surface);

    const tree = try server.scene.hidden_tree.createSceneTree();
    errdefer tree.node.destroy();

    const popup_tree = try server.scene.hidden_tree.createSceneTree();
    errdefer popup_tree.node.destroy();

    const surfaces = try Scene.SaveableSurfaces.init(tree);
    _ = try surfaces.tree.createSceneSubsurfaceTree(surface);

    try SceneNodeData.attach(&tree.node, .{ .shell_surface = shell_surface });
    try SceneNodeData.attach(&popup_tree.node, .{ .shell_surface = shell_surface });

    shell_surface.* = .{
        .surface = surface,
        .tree = tree,
        .surfaces = surfaces,
        .popup_tree = popup_tree,
        .node = undefined,
    };
    if (!surface.setRole(&role, shell_surface, 0)) {
        tree.node.destroy();
        popup_tree.node.destroy();
        util.gpa.destroy(shell_surface);
        return;
    }
    surface.setRoleObject(shell_surface);
    shell_surface.node.init(.shell_surface);
    server.wm.rendering_requested.list.append(&shell_surface.node);
}

fn roleDestroy(wlr_surface: *wlr.Surface) callconv(.c) void {
    const shell_surface = fromWlrSurface(wlr_surface) orelse return;

    shell_surface.surface.unmap();

    shell_surface.node.makeInert();
    shell_surface.node.deinit();

    shell_surface.tree.node.destroy();
    shell_surface.popup_tree.node.destroy();

    util.gpa.destroy(shell_surface);
}

fn fromWlrSurface(wlr_surface: *wlr.Surface) ?*ShellSurface {
    if (wlr_surface.role != &role) return null;
    const resource = wlr_surface.role_resource orelse return null;
    return @ptrCast(@alignCast(resource.getUserData()));
}

fn clientCommit(wlr_surface: *wlr.Surface) callconv(.c) void {
    const shell_surface = fromWlrSurface(wlr_surface) orelse return;
    if (shell_surface.rendering_requested.sync_next_commit) {
        shell_surface.surfaces.save();
    }
}

fn commit(wlr_surface: *wlr.Surface) callconv(.c) void {
    if (wlr_surface.hasBuffer()) {
        wlr_surface.map();
    }
}

pub fn renderFinish(shell_surface: *ShellSurface) void {
    const rendering_requested = &shell_surface.rendering_requested;
    if (rendering_requested.sync_next_commit) {
        rendering_requested.sync_next_commit = false;
        if (!shell_surface.surfaces.saved) {
            // Nile: no protocol object to postError
        }
    }

    shell_surface.surfaces.dropSaved();

    shell_surface.tree.node.setPosition(rendering_requested.x, rendering_requested.y);
    shell_surface.popup_tree.node.setPosition(rendering_requested.x, rendering_requested.y);
}
