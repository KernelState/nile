// SPDX-FileCopyrightText: © 2023 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const XdgPopup = @This();

const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Animation = @import("Animation.zig");
const Output = @import("Output.zig");
const SceneNodeData = @import("SceneNodeData.zig");

const log = std.log.scoped(.xdg_popup);

wlr_popup: *wlr.XdgPopup,
/// Scene tree for the popup contents. Normally owned by wlroots (created with
/// createSceneXdgSurface), but replaced by a compositor-owned snapshot tree
/// while the close animation runs — see snapshotForClose().
tree: *wlr.SceneTree,
/// True if `tree` is the snapshot tree owned by us and must be destroyed on free.
snapshot_owned: bool = false,
capture_tree: ?*wlr.SceneTree = null,

// Animation for popup appear/disappear (fade/scale/scfade). Config via Animation.popup_open/close.
alpha: f32 = 1.0,
animation: struct {
    active: bool = false,
    kind: enum { open, close } = .open,
    start_alpha: f32 = 1.0,
    target_alpha: f32 = 1.0,
    start_scale: f32 = 1.0,
    target_scale: f32 = 1.0,
    start_time_ms: i64 = 0,
    duration_ms: i64 = 150,
    easing: Animation.Easing = .ease_out_cubic,
} = .{},
animation_timer: ?*wl.EventSource = null,
pending_destroy: bool = false,

destroy: wl.Listener(void) = .init(handleDestroy),
commit: wl.Listener(*wlr.Surface) = .init(handleCommit),
new_popup: wl.Listener(*wlr.XdgPopup) = .init(handleNewPopup),
reposition: wl.Listener(void) = .init(handleReposition),

// TODO check if popup is set_reactive and reposition on parent movement.
pub fn create(
    wlr_popup: *wlr.XdgPopup,
    parent: *wlr.SceneTree,
    capture_parent: ?*wlr.SceneTree,
) error{OutOfMemory}!void {
    const xdg_popup = try util.gpa.create(XdgPopup);
    errdefer util.gpa.destroy(xdg_popup);

    xdg_popup.* = .{
        .wlr_popup = wlr_popup,
        .tree = try parent.createSceneXdgSurface(wlr_popup.base),
    };
    if (capture_parent) |p| {
        xdg_popup.capture_tree = try p.createSceneXdgSurface(wlr_popup.base);
    }

    wlr_popup.events.destroy.add(&xdg_popup.destroy);
    wlr_popup.base.surface.events.commit.add(&xdg_popup.commit);
    wlr_popup.base.events.new_popup.add(&xdg_popup.new_popup);
    wlr_popup.events.reposition.add(&xdg_popup.reposition);

    // Popup open animation (fade/scale/scfade). If disabled, shows immediately.
    xdg_popup.startOpenAnimation();
}

fn applyAlpha(popup: *XdgPopup, alpha: f32) void {
    const clamped = @max(0.0, @min(1.0, alpha));
    popup.alpha = clamped;
    const Cb = struct {
        fn cb(buffer: *wlr.SceneBuffer, sx: c_int, sy: c_int, a: *f32) void {
            _ = sx;
            _ = sy;
            buffer.setOpacity(a.*);
        }
    };
    var val: f32 = clamped;
    popup.tree.node.forEachBuffer(*f32, Cb.cb, &val);
    if (popup.capture_tree) |ct| {
        var v2: f32 = clamped;
        ct.node.forEachBuffer(*f32, Cb.cb, &v2);
    }
}

inline fn nowMs() i64 {
    const ts = util.timestamp();
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

fn ensureAnimationTimer(popup: *XdgPopup) void {
    if (popup.animation_timer != null) return;
    const loop = server.wl_server.getEventLoop();
    popup.animation_timer = loop.addTimer(*XdgPopup, handleAnimationTick, popup) catch {
        log.err("failed to create popup animation timer", .{});
        return;
    };
    popup.animation_timer.?.timerUpdate(16) catch {};
}

fn handleAnimationTick(popup: *XdgPopup) c_int {
    const now = nowMs();
    if (!tickAnimation(popup, now)) {
        if (popup.animation_timer) |t| {
            t.remove();
            popup.animation_timer = null;
        }
        if (popup.pending_destroy) {
            // Close animation finished — destroy the snapshot tree and free.
            // Listeners were already removed in handleDestroy.
            popup.pending_destroy = false;
            if (popup.snapshot_owned) popup.tree.node.destroy();
            util.gpa.destroy(popup);
        }
    } else {
        popup.animation_timer.?.timerUpdate(16) catch {};
    }
    return 0;
}

fn tickAnimation(popup: *XdgPopup, now_ms: i64) bool {
    if (!popup.animation.active) return false;
    const elapsed = now_ms - popup.animation.start_time_ms;
    if (elapsed >= popup.animation.duration_ms) {
        popup.alpha = popup.animation.target_alpha;
        popup.applyAlpha(popup.alpha);
        popup.animation.active = false;
        return false;
    }
    const t = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(popup.animation.duration_ms));
    const e = popup.animation.easing.apply(@min(1.0, @max(0.0, t)));
    popup.alpha = popup.animation.start_alpha + (popup.animation.target_alpha - popup.animation.start_alpha) * @as(f32, @floatCast(e));
    // Scale would be applied here if wlroots exposed per-node scale; for now we just fade.
    // For scfade, scale is also interpolated but visually the box size is fixed by xdg-popup protocol,
    // so we only fade. Future: apply scale via buffer transform if available.
    popup.applyAlpha(popup.alpha);
    return true;
}

fn startOpenAnimation(popup: *XdgPopup) void {
    const cfg = Animation.get();
    if (!cfg.isPopupOpenEnabled()) {
        popup.alpha = 1.0;
        popup.applyAlpha(1.0);
        return;
    }
    const c = cfg.popup_open;
    switch (c.kind) {
        .none => {
            popup.alpha = 1.0;
            popup.applyAlpha(1.0);
            return;
        },
        .fade, .scale, .scfade => {
            // For popup, scale/scfade currently behave as fade (wlroots has no per-popup scale).
            // We keep scale fields for future when wlr_scene supports it.
            const dur: i64 = @intCast(c.duration_ms);
            popup.animation = .{
                .active = true,
                .kind = .open,
                .start_alpha = 0.0,
                .target_alpha = 1.0,
                .start_scale = if (c.kind == .scale or c.kind == .scfade) c.scale_from else 1.0,
                .target_scale = 1.0,
                .start_time_ms = nowMs(),
                .duration_ms = dur,
                .easing = c.easing,
            };
            popup.alpha = 0.0;
            popup.applyAlpha(0.0);
            popup.ensureAnimationTimer();
        },
    }
}

fn startCloseAnimation(popup: *XdgPopup) bool {
    const cfg = Animation.get();
    if (!cfg.isPopupCloseEnabled()) return false;
    const c = cfg.popup_close;
    if (c.kind == .none) return false;
    const dur: i64 = @intCast(c.duration_ms);
    popup.animation = .{
        .active = true,
        .kind = .close,
        .start_alpha = popup.alpha,
        .target_alpha = 0.0,
        .start_scale = popup.animation.target_scale,
        .target_scale = if (c.kind == .scale or c.kind == .scfade) c.scale_from else 1.0,
        .start_time_ms = nowMs(),
        .duration_ms = dur,
        .easing = c.easing,
    };
    popup.ensureAnimationTimer();
    return true;
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const xdg_popup: *XdgPopup = @fieldParentPtr("destroy", listener);

    // Remove all listeners now — the wlr_popup, its surface, and the
    // wlroots-owned scene tree created with createSceneXdgSurface are all
    // about to be destroyed by wlroots.
    xdg_popup.destroy.link.remove();
    xdg_popup.commit.link.remove();
    xdg_popup.new_popup.link.remove();
    xdg_popup.reposition.link.remove();

    // If the close animation is enabled, snapshot the popup's buffers into a
    // compositor-owned scene tree and defer final cleanup until it finishes.
    if (!xdg_popup.snapshot_owned and xdg_popup.startCloseAnimation()) {
        if (xdg_popup.snapshotForClose()) {
            xdg_popup.pending_destroy = true;
            return;
        }
        // Snapshot failed (OOM) — fall back to immediate cleanup.
    }

    if (xdg_popup.animation_timer) |t| t.remove();
    if (xdg_popup.snapshot_owned) xdg_popup.tree.node.destroy();

    util.gpa.destroy(xdg_popup);
}

/// Copy the popup's scene buffers into a new compositor-owned scene tree so
/// they can be faded out after wlroots destroys the popup.
///
/// createSceneBuffer locks the underlying wlr_buffer, so the textures stay
/// alive even after the client surface is destroyed. The tree is placed under
/// interactive_tree with nodes positioned in layout coordinates, sibling-style
/// like Scene.SaveableSurfaces.
fn snapshotForClose(xdg_popup: *XdgPopup) bool {
    const snapshot_tree = server.scene.interactive_tree.createSceneTree() catch return false;
    errdefer snapshot_tree.node.destroy();

    // forEachBuffer yields coordinates relative to popup.tree, whose origin
    // differs from interactive_tree's. Translate the snapshot tree to the
    // popup tree's layout position so the copy lands pixels-exactly on top of
    // the original. Bail out if the popup is currently hidden (coords false)
    // since its buffers would then be skipped by forEachBuffer anyway.
    var lx: c_int = undefined;
    var ly: c_int = undefined;
    if (!xdg_popup.tree.node.coords(&lx, &ly)) return false;
    snapshot_tree.node.setPosition(lx, ly);

    const Cb = struct {
        fn cb(buffer: *wlr.SceneBuffer, sx: c_int, sy: c_int, dest: *wlr.SceneTree) void {
            const scene_buffer = dest.createSceneBuffer(buffer.buffer) catch {
                log.err("failed to snapshot popup buffer, close animation will be incomplete", .{});
                return;
            };
            scene_buffer.node.setPosition(sx, sy);
            scene_buffer.setDestSize(buffer.dst_width, buffer.dst_height);
            scene_buffer.setSourceBox(&buffer.src_box);
            scene_buffer.setTransform(buffer.transform);
        }
    };
    xdg_popup.tree.node.forEachBuffer(*wlr.SceneTree, Cb.cb, snapshot_tree);

    // Take over the snapshot tree; from now on it owns all rendering and must
    // be destroyed by us. Drop the wlroots-owned trees.
    xdg_popup.tree = snapshot_tree;
    xdg_popup.snapshot_owned = true;
    xdg_popup.capture_tree = null;
    xdg_popup.applyAlpha(xdg_popup.alpha);
    return true;
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const xdg_popup: *XdgPopup = @fieldParentPtr("commit", listener);

    if (xdg_popup.wlr_popup.base.initial_commit) {
        handleReposition(&xdg_popup.reposition);
    }
}

fn handleNewPopup(listener: *wl.Listener(*wlr.XdgPopup), wlr_popup: *wlr.XdgPopup) void {
    const xdg_popup: *XdgPopup = @fieldParentPtr("new_popup", listener);

    XdgPopup.create(
        wlr_popup,
        xdg_popup.tree,
        xdg_popup.capture_tree,
    ) catch {
        wlr_popup.resource.postNoMemory();
        return;
    };
}

fn handleReposition(listener: *wl.Listener(void)) void {
    const xdg_popup: *XdgPopup = @fieldParentPtr("reposition", listener);
    const wlr_popup = xdg_popup.wlr_popup;

    var parent_lx: c_int = undefined;
    var parent_ly: c_int = undefined;
    _ = xdg_popup.tree.node.parent.?.node.coords(&parent_lx, &parent_ly);

    var anchor = wlr_popup.scheduled.rules.anchor_rect;
    anchor.x += parent_lx;
    anchor.y += parent_ly;
    const wlr_output = server.om.maxOverlapOutput(&anchor) orelse return;

    var constraint: wlr.Box = undefined;
    server.om.output_layout.getBox(wlr_output, &constraint);
    constraint.x -= parent_lx;
    constraint.y -= parent_ly;

    wlr_popup.scheduled.rules.unconstrainBox(&constraint, &wlr_popup.scheduled.geometry);
    _ = wlr_popup.base.scheduleConfigure();
}
