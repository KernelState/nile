// SPDX-FileCopyrightText: © 2025 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

// Nile: river_decoration_v1 protocol removed. Keep scene tree logic without protocol objects.

const Decoration = @This();

const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const util = @import("util.zig");

const Scene = @import("Scene.zig");

const role: wlr.Surface.Role = .{
    .name = "river_decoration_v1",
    .client_commit = clientCommit,
    .commit = commit,
    .unmap = null,
    .destroy = null,
};

surface: *wlr.Surface,
tree: *wlr.SceneTree,
surfaces: Scene.SaveableSurfaces,
/// Window.decorations_above/below
link: wl.list.Link,

rendering_requested: struct {
    offset_x: i32 = 0,
    offset_y: i32 = 0,
    sync_next_commit: bool = false,
} = .{},

pub fn create(
    surface: *wlr.Surface,
    parent: *wlr.SceneTree,
) !*Decoration {
    const decoration = try util.gpa.create(Decoration);
    errdefer util.gpa.destroy(decoration);

    const tree = try parent.createSceneTree();
    errdefer tree.node.destroy();

    const surfaces = try Scene.SaveableSurfaces.init(tree);
    _ = try surfaces.tree.createSceneSubsurfaceTree(surface);

    decoration.* = .{
        .surface = surface,
        .tree = tree,
        .surfaces = surfaces,
        .link = undefined,
    };

    if (!surface.setRole(&role, decoration, 0)) {
        tree.node.destroy();
        util.gpa.destroy(decoration);
        return error.AlreadyHasRole;
    }
    surface.setRoleObject(decoration);

    return decoration;
}

pub fn destroy(decoration: *Decoration) void {
    decoration.tree.node.destroy();
    decoration.link.remove();
    util.gpa.destroy(decoration);
}

pub fn makeInert(decoration: *Decoration) void {
    decoration.surfaces.save();
}

fn clientCommit(wlr_surface: *wlr.Surface) callconv(.c) void {
    if (wlr_surface.role != &role) return;
    const resource = wlr_surface.role_resource orelse return;
    const decoration: *Decoration = @ptrCast(@alignCast(resource.getUserData() orelse return));
    if (decoration.rendering_requested.sync_next_commit) {
        decoration.surfaces.save();
    }
}

fn commit(wlr_surface: *wlr.Surface) callconv(.c) void {
    if (wlr_surface.hasBuffer()) {
        wlr_surface.map();
    }
}

pub fn renderFinish(decoration: *Decoration, window_clip: *const wlr.Box) void {
    const rendering_requested = &decoration.rendering_requested;
    if (rendering_requested.sync_next_commit) {
        rendering_requested.sync_next_commit = false;
        if (!decoration.surfaces.saved) {
            // Nile: no protocol object to postError; just proceed
        }
    }

    decoration.surfaces.dropSaved();

    decoration.tree.node.setPosition(rendering_requested.offset_x, rendering_requested.offset_y);

    if (!decoration.surfaces.tree.children.empty()) {
        var clip = window_clip.*;
        clip.x -= rendering_requested.offset_x;
        clip.y -= rendering_requested.offset_y;
        decoration.surfaces.tree.node.subsurfaceTreeSetClip(&clip);
    }
}
