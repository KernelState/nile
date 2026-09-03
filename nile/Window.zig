// SPDX-FileCopyrightText: © 2020 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const Window = @This();

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const meta = std.meta;
const posix = std.posix;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const SlotMap = @import("slotmap").SlotMap;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Animation = @import("Animation.zig");
const Decoration = @import("Decoration.zig");
const Output = @import("Output.zig");
const Scene = @import("Scene.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const Seat = @import("Seat.zig");
const WmNode = @import("WmNode.zig");
const XdgToplevel = @import("XdgToplevel.zig");
const XwaylandWindow = @import("XwaylandWindow.zig");

const log = std.log.scoped(.wm);

pub const Edges = packed struct(u32) {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,
    _pad: u28 = 0,
};

pub const Capabilities = packed struct(u32) {
    window_menu: bool = false,
    maximize: bool = false,
    fullscreen: bool = false,
    minimize: bool = false,
    _pad: u28 = 0,
};

pub const DecorationHint = enum {
    no_preference,
    only_supports_csd,
    prefers_ssd,
    prefers_csd,
};

pub const PresentationMode = enum {
    vsync,
    async,
};

pub const Dimensions = struct {
    width: u31,
    height: u31,
};

pub const DimensionsHint = struct {
    min_width: u31 = 0,
    max_width: u31 = 0,
    min_height: u31 = 0,
    max_height: u31 = 0,
};

const Impl = union(enum) {
    toplevel: XdgToplevel,
    xwayland: if (build_options.xwayland) XwaylandWindow else noreturn,
    /// This state is assigned during destruction after the xdg toplevel
    /// has been destroyed but while the transaction system is still rendering
    /// saved surfaces of the window.
    destroying,
};

pub const FullscreenRequest = union(enum) {
    no_request,
    fullscreen: ?*Output,
    exit,
};

pub const Border = struct {
    edges: Edges = .{},
    width: u31 = 0,
    r: u32 = 0,
    b: u32 = 0,
    g: u32 = 0,
    a: u32 = 0,
};

/// Windowing state requested by the wm.
const WmRequested = struct {
    dimensions: ?Dimensions,
    bounds: Dimensions,
    ssd: bool,
    tiled: Edges,
    capabilities: Capabilities,
    resizing: bool,
    maximized: bool,
    fullscreen: ?*Output,
    inform_fullscreen: bool,
    close: bool,
    workspace: u64 = 1,

    pub const init: WmRequested = .{
        .dimensions = null,
        .bounds = .{ .width = 0, .height = 0 },
        .ssd = false,
        .tiled = .{},
        .capabilities = .{
            .window_menu = true,
            .maximize = true,
            .fullscreen = true,
            .minimize = true,
        },
        .resizing = false,
        .maximized = false,
        .fullscreen = null,
        .inform_fullscreen = false,
        .close = false,
        .workspace = 1,
    };
};

pub const Configure = struct {
    width: ?u31,
    height: ?u31,
    bounds: Dimensions,
    /// True if the window has keyboard focus from at least one seat.
    activated: bool,
    ssd: bool,
    tiled: Edges,
    capabilities: Capabilities,
    maximized: bool,
    inform_fullscreen: bool,
    resizing: bool,

    pub const init: Configure = .{
        .width = null,
        .height = null,
        .bounds = .{ .width = 0, .height = 0 },
        .activated = false,
        .ssd = false,
        .tiled = .{},
        .capabilities = .{},
        .maximized = false,
        .inform_fullscreen = false,
        .resizing = false,
    };
};

/// Rendering state requested by the wm.
const RenderingRequested = struct {
    x: i32,
    y: i32,
    hidden: bool,
    border: Border,
    clip: wlr.Box,
    content_clip: wlr.Box,

    pub const init: RenderingRequested = .{
        .x = 0,
        .y = 0,
        .hidden = false,
        .border = .{},
        .clip = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .content_clip = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    };
};

pub const Ref = packed struct {
    key: SlotMap(*Window).Key,

    pub fn get(ref: Ref) ?*Window {
        return server.wm.windows.get(ref.key);
    }
};

ref: Ref,

node: WmNode,

state: enum {
    /// Initial state, also returned to after closed event is sent.
    init,
    /// The window is ready to be configured.
    /// The river_window_v1 will be created in the next manage sequence.
    ready,
    /// The first configure has been sent but the window is not yet mapped.
    initialized,
    /// The window is mapped.
    mapped,
    /// The closed event will be sent in the next manage sequence.
    closing,
} = .init,

/// The implementation of this window
impl: Impl,

/// This is the root scene tree for the window.
/// The trees in the following fields are in rendering order.
tree: *wlr.SceneTree,

/// Opaque black rectangle used as the background while this window is rendered fullscreen.
/// TODO consider using one of these per output rather than one per window to save memory
/// if the complexity tradeoff is worth it.
fullscreen_background: *wlr.SceneRect,

decorations_below: wl.list.Head(Decoration, .link),
decorations_below_tree: *wlr.SceneTree,

surfaces: Scene.SaveableSurfaces,

border: struct {
    left: *wlr.SceneRect,
    right: *wlr.SceneRect,
    top: *wlr.SceneRect,
    bottom: *wlr.SceneRect,
},

decorations_above: wl.list.Head(Decoration, .link),
decorations_above_tree: *wlr.SceneTree,

popup_tree: *wlr.SceneTree,

capture_scene: *wlr.Scene,
capture_source: ?*wlr.ExtImageCaptureSourceV1 = null,

/// State to be sent to the wm in the next manage sequence.
wm_scheduled: struct {
    dimensions_hint: DimensionsHint = .{},
    decoration_hint: DecorationHint = .only_supports_csd,
    show_window_menu_requested: ?struct { x: i32, y: i32 } = null,
    /// Set back to no_request at the end of each update sequence
    fullscreen_requested: FullscreenRequest = .no_request,
    maximize_requested: enum {
        no_request,
        maximize,
        unmaximize,
    } = .no_request,
    minimize_requested: bool = false,
    dirty_app_id: bool = false,
    dirty_title: bool = false,
    pointer_move_requested: ?*Seat = null,
    pointer_resize_requested: ?struct {
        seat: *Seat,
        edges: Edges,
    } = null,
    capture_session_count: u32 = 0,
} = .{},

/// State sent to the wm in the latest manage sequence.
/// This state is only kept around in order to avoid sending redundant events
/// to the wm.
wm_sent: struct {
    dimensions_hint: DimensionsHint = .{},
    decoration_hint: DecorationHint = .only_supports_csd,
    parent: ?Window.Ref = null,
    capture_session_count: u32 = 0,
} = .{},

/// Windowing state requested by the wm.
wm_requested: WmRequested = .init,

/// State to be sent to the window in the next configure.
configure_scheduled: Configure = .init,
/// State sent to the window in the latest configure.
configure_sent: Configure = .init,

/// State to be sent to the wm in the next render sequence.
rendering_scheduled: struct {
    /// Dimensions committed by the window.
    width: u31 = 0,
    height: u31 = 0,
    /// Send dimensions even if they are unchanged.
    resend_dimensions: bool = false,
} = .{},

/// State sent to the wm in the latest render sequence.
rendering_sent: struct {
    width: u31 = 0,
    height: u31 = 0,
    presentation_hint: PresentationMode = .vsync,
} = .{},

/// Rendering state requested by the wm.
rendering_requested: RenderingRequested = .init,

/// The currently rendered position/dimensions of the window in the scene graph
box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

/// Current visual opacity (1.0 opaque, 0.0 transparent) and scale (1.0 normal).
alpha: f32 = 1.0,
scale: f32 = 1.0,

/// Pending open animation — set in map(), runs after tiling has positioned the window.
pending_open: bool = false,

/// Animation state for smooth position/size transitions and open/close effects.
/// When `active`, `box` holds the final target for layout, but the visual
/// scene node is interpolated between `start_box` and `target_box`.
/// `alpha`/`scale` are interpolated for `fade`/`scale`/`scfade` kinds.
/// Grabbed windows (seat.op.window) never animate to avoid input lag.
animation: struct {
    active: bool = false,
    kind: enum { tiling, open, close } = .tiling,
    start_box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    target_box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    start_alpha: f32 = 1.0,
    target_alpha: f32 = 1.0,
    start_scale: f32 = 1.0,
    target_scale: f32 = 1.0,
    start_time_ms: i64 = 0,
    duration_ms: i64 = 200,
    easing: Animation.Easing = .ease_out_cubic,
} = .{},

foreign_toplevel_handle: ?*wlr.ExtForeignToplevelHandleV1 = null,
wlr_toplevel_handle: ?*wlr.ForeignToplevelHandleV1 = null,

pub fn create(impl: Impl) error{OutOfMemory}!*Window {
    assert(impl != .destroying);

    const window = try util.gpa.create(Window);
    errdefer util.gpa.destroy(window);

    const key = try server.wm.windows.put(util.gpa, window);
    errdefer server.wm.windows.remove(key);

    const tree = try server.scene.hidden_tree.createSceneTree();
    errdefer tree.node.destroy();

    const popup_tree = try server.scene.hidden_tree.createSceneTree();
    errdefer popup_tree.node.destroy();

    window.* = .{
        .ref = .{ .key = key },
        .node = undefined,
        .impl = impl,
        .tree = tree,
        .fullscreen_background = try tree.createSceneRect(0, 0, &.{ 0, 0, 0, 1 }),
        .decorations_below = undefined,
        .decorations_below_tree = try tree.createSceneTree(),
        .surfaces = try Scene.SaveableSurfaces.init(tree),
        .border = .{
            .left = try tree.createSceneRect(0, 0, &.{ 0, 0, 0, 0 }),
            .right = try tree.createSceneRect(0, 0, &.{ 0, 0, 0, 0 }),
            .top = try tree.createSceneRect(0, 0, &.{ 0, 0, 0, 0 }),
            .bottom = try tree.createSceneRect(0, 0, &.{ 0, 0, 0, 0 }),
        },
        .decorations_above = undefined,
        .decorations_above_tree = try tree.createSceneTree(),
        .popup_tree = popup_tree,
        .capture_scene = try wlr.Scene.create(),
    };

    window.node.init(.window);

    window.decorations_below.init();
    window.decorations_above.init();

    window.tree.node.setEnabled(false);
    window.popup_tree.node.setEnabled(false);
    window.fullscreen_background.node.setEnabled(false);

    window.capture_scene.restack_xwayland_surfaces = false;

    try SceneNodeData.attach(&window.tree.node, .{ .window = window });
    try SceneNodeData.attach(&window.popup_tree.node, .{ .window = window });

    return window;
}

/// It's safe to destroy the window after we no longer need the saved buffers
/// for frame perfection. We no longer need the saved buffers after the manage
/// sequence in which the closed event was sent is completed and the following
/// render sequence is completed as well.
pub fn destroy(window: *Window) void {
    assert(window.impl == .destroying);

    @import("Compositor.zig").notify(.{ .window_destroy = window });

    switch (window.state) {
        .init => {},
        .closing => {
            server.wm.dirtyWindowing();
            return;
        },
        .ready, .initialized, .mapped => unreachable,
    }

    {
        var it = server.input_manager.seats.iterator(.forward);
        while (it.next()) |seat| {
            assert(seat.focused != .window or seat.focused.window != window);
            if (seat.op) |op| if (op.window) |op_ref| {
                if (op_ref.get()) |op_win| {
                    if (op_win == window) seat.opEnd();
                } else {
                    // Stale ref (window already destroyed) — clear op to avoid confusion
                    seat.opEnd();
                }
            };
        }
    }

    inline for (.{ &window.decorations_above, &window.decorations_below }) |decorations| {
        var it = decorations.safeIterator(.forward);
        while (it.next()) |decoration| decoration.destroy();
    }

    window.tree.node.destroy();
    window.popup_tree.node.destroy();
    window.capture_scene.tree.node.destroy();

    window.node.deinit();

    server.wm.windows.remove(window.ref.key);

    util.gpa.destroy(window);
}

pub fn setDimensionsHint(window: *Window, hint: DimensionsHint) void {
    window.wm_scheduled.dimensions_hint = hint;
    if (!meta.eql(window.wm_sent.dimensions_hint, hint)) {
        server.wm.dirtyWindowing();
    }
}

pub fn setDimensions(window: *Window, width: u31, height: u31) void {
    window.rendering_scheduled.width = width;
    window.rendering_scheduled.height = height;

    if (window.rendering_scheduled.resend_dimensions or
        window.rendering_scheduled.width != window.rendering_sent.width or
        window.rendering_scheduled.height != window.rendering_sent.height)
    {
        server.wm.dirtyRendering();
    }
}

pub fn setDecorationHint(window: *Window, hint: DecorationHint) void {
    window.wm_scheduled.decoration_hint = hint;
    if (hint != window.wm_sent.decoration_hint) {
        server.wm.dirtyWindowing();
    }
}

/// Send dirty state as part of a manage sequence.
pub fn manageStart(window: *Window) void {
    switch (window.state) {
        .init => {},
        .closing => {
            // If close animation is still running, keep window in closing state
            // and defer cleanup until animation finishes (tick will hide and then
            // next manage will clean up).
            if (window.animation.active and window.animation.kind == .close) {
                // Keep in rendering list and don't make inert yet — fade continues.
                // Ensure window stays in list for rendering.
                var in_list = false;
                var it2 = server.wm.rendering_requested.list.iterator(.forward);
                while (it2.next()) |n| if (n == &window.node) {
                    in_list = true;
                    break;
                };
                if (!in_list) {
                    server.wm.rendering_requested.list.append(&window.node);
                }
                return;
            }
            window.state = .init;
            window.wm_sent = .{};
            window.wm_requested = .init;
            window.rendering_sent = .{};
            window.rendering_requested = .init;

            window.node.link.remove();
            window.node.link.init();

            window.makeInert();
        },
        .ready, .initialized, .mapped => {
            // Ensure window is in rendering order list (Nile path, no river_window_v1)
            var in_list = false;
            var it = server.wm.rendering_requested.list.iterator(.forward);
            while (it.next()) |n| if (n == &window.node) {
                in_list = true;
                break;
            };
            if (!in_list) {
                window.node.link.remove();
                server.wm.rendering_requested.list.append(&window.node);
            }

            // Foreign toplevel handles (ext and wlr) - not river protocol
            if (window.foreign_toplevel_handle == null) {
                if (wlr.ExtForeignToplevelHandleV1.create(server.foreign_toplevel_list, &.{
                    .title = window.getTitle(),
                    .app_id = window.getAppId(),
                })) |handle| {
                    window.foreign_toplevel_handle = handle;
                    handle.data = window;
                } else |_| {
                    log.err("failed to create ext foreign toplevel handle", .{});
                }
            }

            if (window.wlr_toplevel_handle == null) {
                if (wlr.ForeignToplevelHandleV1.create(server.wlr_foreign_toplevel_manager)) |handle| {
                    window.wlr_toplevel_handle = handle;
                    if (window.getTitle()) |title| handle.setTitle(title);
                    if (window.getAppId()) |app_id| handle.setAppId(app_id);
                } else |_| {
                    log.err("failed to create wlr foreign toplevel handle", .{});
                }
            }

            const scheduled = &window.wm_scheduled;
            const sent = &window.wm_sent;

            if (!meta.eql(scheduled.dimensions_hint, sent.dimensions_hint)) {
                sent.dimensions_hint = scheduled.dimensions_hint;
            }
            if (scheduled.decoration_hint != sent.decoration_hint) {
                sent.decoration_hint = scheduled.decoration_hint;
            }

            scheduled.show_window_menu_requested = null;
            scheduled.fullscreen_requested = .no_request;
            scheduled.maximize_requested = .no_request;
            scheduled.minimize_requested = false;

            if (window.getParent()) |parent| {
                if (sent.parent == null or sent.parent.?.get() != parent) {
                    sent.parent = parent.ref;
                }
            } else if (sent.parent != null) {
                sent.parent = null;
            }

            if (scheduled.dirty_app_id) scheduled.dirty_app_id = false;
            if (scheduled.dirty_title) scheduled.dirty_title = false;

            scheduled.pointer_move_requested = null;
            scheduled.pointer_resize_requested = null;

            sent.capture_session_count = scheduled.capture_session_count;
        },
    }
}

pub fn makeInert(window: *Window) void {
    window.wm_requested = .init;
    window.rendering_requested = .{
        .x = window.rendering_requested.x,
        .y = window.rendering_requested.y,
        .hidden = false,
        .border = .{},
        .clip = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .content_clip = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    };
    server.wm.dirtyWindowing();
    window.node.makeInert();
    inline for (.{ &window.decorations_above, &window.decorations_below }) |decorations| {
        var it = decorations.iterator(.forward);
        while (it.next()) |decoration| decoration.makeInert();
    }
}

/// Applies window management state from the window manager and sends a configure
/// to the window if necessary.
/// Returns true if the configure should be waited for by the transaction system.
pub fn manageFinish(window: *Window) bool {
    const wm_requested = &window.wm_requested;

    // This can happen if the window is destroyed after being sent to the wm but
    // before being mapped.
    if (window.impl == .destroying) {
        assert(window.state == .closing);
        return false;
    }

    switch (window.state) {
        .init => unreachable,
        .ready => {
            if (wm_requested.dimensions == null and wm_requested.fullscreen == null) {
                return false;
            }
            window.state = .initialized;
        },
        .initialized, .mapped => {},
        .closing => return false,
    }

    if (wm_requested.close) {
        window.close();
        wm_requested.close = false;
    }

    const activated = blk: {
        var it = server.wm.sent.seats.iterator(.forward);
        while (it.next()) |seat| {
            if (seat.focused == .window and seat.focused.window == window) {
                break :blk true;
            }
        }
        break :blk false;
    };

    if (window.wlr_toplevel_handle) |handle| {
        handle.setActivated(activated);
    }

    const width, const height = blk: {
        if (wm_requested.fullscreen) |output| {
            const width, const height = output.sent.dimensions();
            if (window.configure_sent.width != width or
                window.configure_sent.height != height)
            {
                window.configure_scheduled.width = width;
                window.configure_scheduled.height = height;
                window.rendering_scheduled.resend_dimensions = true;
                break :blk .{ width, height };
            }
        } else if (wm_requested.dimensions) |dimensions| {
            window.rendering_scheduled.resend_dimensions = true;
            break :blk .{ dimensions.width, dimensions.height };
        }
        break :blk .{ null, null };
    };
    wm_requested.dimensions = null;

    window.configure_scheduled = .{
        .width = width,
        .height = height,
        .bounds = wm_requested.bounds,
        .activated = activated,
        .ssd = wm_requested.ssd,
        .tiled = wm_requested.tiled,
        .capabilities = wm_requested.capabilities,
        .resizing = wm_requested.resizing,
        .maximized = wm_requested.maximized,
        .inform_fullscreen = wm_requested.inform_fullscreen,
    };

    const track_configure = switch (window.impl) {
        .toplevel => |*toplevel| toplevel.configure(),
        .xwayland => |*xwindow| xwindow.configure(),
        .destroying => unreachable,
    };

    if (track_configure and window.state == .mapped) {
        window.surfaces.save();
        window.sendFrameDone();
    }

    return track_configure;
}

pub fn renderStart(window: *Window) void {
    switch (window.impl) {
        .toplevel => |*toplevel| {
            switch (toplevel.configure_state) {
                .inflight, .acked => {
                    // The transaction has timed out for the xdg toplevel, which means a commit
                    // in response to the configure with the inflight width/height has not yet
                    // been made. It may seem that we should therefore leave the current.box
                    // width/height unchanged. However, this would in fact cause visual glitches.
                    //
                    // We must update the dimensions to the current geometry of the
                    // xdg toplevel here in order to handle the following series of events:
                    //
                    // 0. initial state: client has dimensions X
                    // 1. transaction A sends a configure of size Y
                    // 2. transaction A times out - saved surfaces are dropped
                    // 3. transaction B sends a configure of size Z
                    // 4. client commits buffer of size Y
                    // 5. transaction B times out - saved surfaces are dropped
                    //
                    // If we did not use the current geometry of the toplevel at this point
                    // we would be rendering the SSD border at initial size X but the surface
                    // would be rendered at size Y.
                    switch (toplevel.configure_state) {
                        .inflight => |serial| toplevel.configure_state = .{ .timed_out = serial },
                        .acked => toplevel.configure_state = .timed_out_acked,
                        else => unreachable,
                    }
                },
                .committed => {
                    toplevel.configure_state = .idle;
                },
                // A timed_out or timed_out_acked value is possible in the case of a
                // manage sequence followed by two render sequences for example.
                .idle, .timed_out, .timed_out_acked => {},
            }
            window.rendering_scheduled.width = @intCast(toplevel.geometry.width);
            window.rendering_scheduled.height = @intCast(toplevel.geometry.height);
        },
        .xwayland => |xwindow| {
            window.rendering_scheduled.width = xwindow.xsurface.width;
            window.rendering_scheduled.height = xwindow.xsurface.height;
        },
        .destroying => {},
    }

    const sent = &window.rendering_sent;
    const scheduled = &window.rendering_scheduled;

    // Check if mapped to handle timeout of the first configure sent.
    if (window.state == .mapped and
        (scheduled.resend_dimensions or
            scheduled.width != sent.width or scheduled.height != sent.height))
    {
        window.rendering_scheduled.resend_dimensions = false;
    }
    sent.width = scheduled.width;
    sent.height = scheduled.height;

    const presentation_hint = window.presentationHint();
    if (sent.presentation_hint != presentation_hint) {
        sent.presentation_hint = presentation_hint;
    }
}

fn presentationHint(window: *Window) PresentationMode {
    const root_surface = window.rootSurface() orelse return .vsync;
    return switch (server.tearing_control_manager.hintFromSurface(root_surface)) {
        .async => .async,
        .vsync => .vsync,
        _ => unreachable,
    };
}

/// Apply pending `rendering_requested` directly to the scene graph
/// without waiting for a transaction. Only rendering state is touched
/// (position/hidden/border/clip). Safe to call during `manage` /
/// `inflight_configures` for move/drag. Width/height come from
/// `rendering_sent` (no client configure needed for position).
pub fn applyRenderingImmediate(window: *Window) void {
    if (window.impl == .destroying) return;
    // Grabbed windows are never animated — cancel any active animation
    // so immediate position isn't overwritten by tick.
    if (window.isGrabbed()) window.cancelAnimation();
    // If animating (not grabbed), let animation drive visual; don't snap.
    if (window.animation.active) return;
    const requested = &window.rendering_requested;
    // Width/height are driven by configure; don't change them here.
    // Position, visibility and borders can be applied immediately.
    const enabled = !requested.hidden and (window.state == .mapped or window.state == .closing);
    window.tree.node.setEnabled(enabled);
    window.popup_tree.node.setEnabled(enabled);

    var clip: wlr.Box = requested.clip;
    var content_clip: wlr.Box = requested.content_clip;
    if (window.wm_requested.fullscreen) |output| {
        // Fullscreen position is output-driven; don't override with requested
        // but still ensure decorations/borders reflect immediate state.
        window.box.x = output.sent.x;
        window.box.y = output.sent.y;
        window.fullscreen_background.node.setEnabled(true);
        const width, const height = output.sent.dimensions();
        window.fullscreen_background.setSize(width, height);
        clip = .{ .x = 0, .y = 0, .width = width, .height = height };
        content_clip = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        inline for (.{ "left", "right", "top", "bottom" }) |edge| {
            @field(window.border, edge).node.setEnabled(false);
        }
    } else {
        // Immediate position — no output commit needed, scene damage is automatic
        window.box.x = requested.x;
        window.box.y = requested.y;
        window.fullscreen_background.node.setEnabled(false);
        window.drawBorders();
    }
    window.tree.node.setPosition(window.box.x, window.box.y);
    window.popup_tree.node.setPosition(window.box.x, window.box.y);
    window.applySurfaceClip(&clip, &content_clip);
    inline for (.{ &window.decorations_above, &window.decorations_below }) |decorations| {
        var it = decorations.iterator(.forward);
        while (it.next()) |decoration| {
            decoration.renderFinish(&clip);
        }
    }
}

pub fn renderFinish(window: *Window) void {
    const requested = &window.rendering_requested;

    // If animating, let animation drive visual position/size to avoid snapping.
    // Do not touch box — tick interpolates it. Only keep enabled state current.
    if (window.animation.active) {
        window.tree.node.setEnabled(!requested.hidden and (window.state == .mapped or window.state == .closing));
        window.popup_tree.node.setEnabled(!requested.hidden and (window.state == .mapped or window.state == .closing));
        return;
    }

    // Keep the scene nodes disabled until the render sequence in which the first
    // dimensions event was sent is completed. If we enable the nodes before the
    // window is mapped, there may be an imperfect frame rendered after the window
    // commits its initial buffer and before the render sequence with the first
    // dimensions event is completed.
    // Keeping the nodes enabled while closing is necessary for frame perfection.
    const enabled = !requested.hidden and (window.state == .mapped or window.state == .closing);
    window.tree.node.setEnabled(enabled);
    window.popup_tree.node.setEnabled(enabled);

    window.box.width = window.rendering_sent.width;
    window.box.height = window.rendering_sent.height;

    var clip: wlr.Box = requested.clip;
    var content_clip: wlr.Box = requested.content_clip;
    if (window.wm_requested.fullscreen) |output| {
        window.box.x = output.sent.x;
        window.box.y = output.sent.y;
        window.fullscreen_background.node.setEnabled(true);
        const width, const height = output.sent.dimensions();
        window.fullscreen_background.setSize(width, height);
        clip = .{ .x = 0, .y = 0, .width = width, .height = height };
        content_clip = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        inline for (.{ "left", "right", "top", "bottom" }) |edge| {
            @field(window.border, edge).node.setEnabled(false);
        }
    } else {
        window.box.x = requested.x;
        window.box.y = requested.y;
        window.fullscreen_background.node.setEnabled(false);
        window.drawBorders();
    }
    window.tree.node.setPosition(window.box.x, window.box.y);
    window.popup_tree.node.setPosition(window.box.x, window.box.y);

    switch (window.impl) {
        .xwayland => |*xwindow| _ = xwindow.configure(),
        .toplevel, .destroying => {},
    }

    window.applySurfaceClip(&clip, &content_clip);
    inline for (.{ &window.decorations_above, &window.decorations_below }) |decorations| {
        var it = decorations.iterator(.forward);
        while (it.next()) |decoration| {
            decoration.renderFinish(&clip);
        }
    }
}

fn drawBorders(window: *Window) void {
    const requested = &window.rendering_requested;
    var content: wlr.Box = .{
        .x = 0,
        .y = 0,
        .width = window.box.width,
        .height = window.box.height,
    };
    if (requested.content_clip.empty() or
        content.intersection(&content, &requested.content_clip))
    {
        // f32 cannot represent all u32 values exactly, therefore we must initially use f64
        // (which can) and then cast to f32, potentially losing precision.
        const border = &requested.border;
        const color: [4]f32 = .{
            @floatCast(@as(f64, @floatFromInt(border.r)) / math.maxInt(u32)),
            @floatCast(@as(f64, @floatFromInt(border.g)) / math.maxInt(u32)),
            @floatCast(@as(f64, @floatFromInt(border.b)) / math.maxInt(u32)),
            @floatCast(@as(f64, @floatFromInt(border.a)) / math.maxInt(u32)),
        };
        var left: wlr.Box = .{
            .x = -@as(i32, border.width),
            .y = 0,
            .width = border.width,
            .height = content.height,
        };
        var right: wlr.Box = .{
            .x = content.width,
            .y = 0,
            .width = border.width,
            .height = content.height,
        };
        var top: wlr.Box = .{
            .x = 0,
            .y = -@as(i32, border.width),
            .width = content.width,
            .height = border.width,
        };
        var bottom: wlr.Box = .{
            .x = 0,
            .y = content.height,
            .width = content.width,
            .height = border.width,
        };
        // Use left and right scene rects to draw the corners if needed
        if (border.edges.top) {
            left.y -= border.width;
            left.height += border.width;
            right.y -= border.width;
            right.height += border.width;
        }
        if (border.edges.bottom) {
            left.height += border.width;
            right.height += border.width;
        }
        inline for (.{
            .{ .name = "left", .box = &left },
            .{ .name = "right", .box = &right },
            .{ .name = "top", .box = &top },
            .{ .name = "bottom", .box = &bottom },
        }) |edge| {
            if (!requested.clip.empty()) {
                _ = edge.box.intersection(edge.box, &requested.clip);
            }
            const rect = @field(window.border, edge.name);
            // Workaround a Zig 0.16 LLVM backend miscompilation when passing a boolean member
            // of a packed struct to an extern function:
            // https://codeberg.org/ziglang/zig/issues/35373
            //
            // The only "safe" option in the presence of optimizations appears to be calling
            // the extern function with a constant value that does not depend on the bool we
            // actually want to pass. Luckily, we can use setSize(0,0) as a substitute for
            // disabling the node.
            // TODO(zig) remove workaround when updating to Zig 0.17
            rect.node.setEnabled(true);
            if (@field(border.edges, edge.name)) {
                rect.setSize(edge.box.width, edge.box.height);
            } else {
                rect.setSize(0, 0);
            }
            rect.node.setPosition(edge.box.x, edge.box.y);
            rect.setColor(&color);
        }
    }
}

fn applySurfaceClip(window: *Window, a: *const wlr.Box, b: *const wlr.Box) void {
    var surface_clip: wlr.Box = undefined;
    if (!a.empty() and !b.empty()) {
        if (!surface_clip.intersection(a, b)) {
            // Clip boxes are both non-empty but don't intersect, all window
            // content is clipped away.
            window.surfaces.setEnabled(false);
            return;
        }
    } else if (!a.empty()) {
        surface_clip = a.*;
    } else {
        surface_clip = b.*;
    }
    window.surfaces.setEnabled(true);
    switch (window.impl) {
        .toplevel => |toplevel| {
            surface_clip.x += toplevel.geometry.x;
            surface_clip.y += toplevel.geometry.y;
        },
        .xwayland, .destroying => {},
    }
    // wlroots asserts that a subsurface tree is present.
    if (!window.surfaces.tree.children.empty()) {
        window.surfaces.tree.node.subsurfaceTreeSetClip(&surface_clip);
    }
}

/// Returns null if the window is currently being destroyed and no longer has
/// an associated surface.
/// May also return null for Xwayland windows that are not currently mapped.
pub fn rootSurface(window: Window) ?*wlr.Surface {
    return switch (window.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.base.surface,
        .xwayland => |xwindow| xwindow.xsurface.surface,
        .destroying => null,
    };
}

pub fn sendFrameDone(window: Window) void {
    assert(window.state == .mapped);
    assert(window.impl != .destroying);

    var now = util.timestamp();
    window.rootSurface().?.sendFrameDone(&now);
}

pub fn close(window: Window) void {
    switch (window.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.sendClose(),
        .xwayland => |xwindow| xwindow.xsurface.close(),
        .destroying => {},
    }
}

pub fn destroyPopups(window: Window) void {
    switch (window.impl) {
        .toplevel => |toplevel| toplevel.destroyPopups(),
        .xwayland, .destroying => {},
    }
}

pub fn getParent(window: *Window) ?*Window {
    switch (window.impl) {
        .toplevel => |toplevel| {
            const wlr_parent = toplevel.wlr_toplevel.parent orelse return null;
            const parent: *XdgToplevel = @ptrCast(@alignCast(wlr_parent.base.data));
            return parent.window;
        },
        .xwayland => |xwindow| {
            const parent_xsurface = xwindow.xsurface.parent orelse return null;
            // It seems that the parent may be an Override Redirect window, which
            // have null data.
            const parent_data = parent_xsurface.data orelse return null;
            const parent_xwindow: *XwaylandWindow = @ptrCast(@alignCast(parent_data));
            return parent_xwindow.window;
        },
        .destroying => return null,
    }
}

pub fn unreliablePid(window: *Window) i32 {
    switch (window.impl) {
        .toplevel => |toplevel| {
            const client = toplevel.wlr_toplevel.base.surface.resource.getClient();
            return client.getCredentials().pid;
        },
        .xwayland => |xwindow| return xwindow.xsurface.pid,
        .destroying => unreachable,
    }
}

/// Return the current title of the window if any.
pub fn getTitle(window: Window) ?[*:0]const u8 {
    return switch (window.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.title,
        .xwayland => |xwindow| xwindow.xsurface.title,
        .destroying => unreachable,
    };
}

/// Return the current app_id of the window if any.
pub fn getAppId(window: Window) ?[*:0]const u8 {
    return switch (window.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.app_id,
        // X11 clients don't have an app_id but the class serves a similar role.
        .xwayland => |xwindow| xwindow.xsurface.class,
        .destroying => unreachable,
    };
}

/// Called by the impl when the surface is ready to be displayed
pub fn map(window: *Window) !void {
    log.debug("window '{?s}' mapped", .{window.getTitle()});
    assert(window.impl != .destroying);
    assert(window.state == .initialized);
    window.state = .mapped;
    @import("Compositor.zig").notify(.{ .window_map = window });
    // Start open animation now that window is mapped and has a tiled box.
    // If window_open is disabled or none, this is a no-op (snap).
    // For fade/scfade we start from transparent.
    const cfg = Animation.get();
    if (cfg.isWindowOpenEnabled()) {
        // Ensure box is known (arranged in onWindowAdd). If still zero, defer via pending.
        if (window.box.width != 0 and window.box.height != 0) {
            window.startOpenAnimation(window.box);
        } else {
            window.pending_open = true;
            if (cfg.window_open.kind == .fade or cfg.window_open.kind == .scfade) {
                window.alpha = 0.0;
                window.applyAlpha(0.0);
            }
        }
    }
}

/// Called by the impl when the surface will no longer be displayed
pub fn unmap(window: *Window) void {
    log.debug("window '{?s}' unmapped", .{window.getTitle()});

    window.surfaces.save();

    assert(window.impl != .destroying);
    assert(window.state == .mapped);
    // Start close animation before marking closing — keep visible while fading
    const has_close_anim = window.startCloseAnimation();
    if (has_close_anim) {
        // Keep window in closing but with active close animation; destroy will be delayed
        // until tick completes (see WindowManager.renderFinish).
        window.state = .closing;
    } else {
        window.state = .closing;
    }

    @import("Compositor.zig").notify(.{ .window_unmap = window });

    server.wm.dirtyWindowing();

    if (window.foreign_toplevel_handle) |handle| {
        handle.destroy();
        window.foreign_toplevel_handle = null;
    }

    if (window.wlr_toplevel_handle) |handle| {
        handle.destroy();
        window.wlr_toplevel_handle = null;
    }

    {
        var it = server.input_manager.seats.iterator(.forward);
        while (it.next()) |seat| {
            if (seat.focused == .window and seat.focused.window == window) {
                seat.focus(.none);
            }
        }
    }
}

pub fn notifyTitle(window: *Window) void {
    window.wm_scheduled.dirty_title = true;
    server.wm.dirtyWindowing();

    @import("Compositor.zig").notify(.{ .window_title_changed = window });

    if (window.foreign_toplevel_handle) |handle| {
        handle.updateState(&.{
            .title = window.getTitle(),
            .app_id = window.getAppId(),
        });
    }
    if (window.wlr_toplevel_handle) |handle| {
        if (window.getTitle()) |title| handle.setTitle(title);
    }
}

pub fn notifyAppId(window: *Window) void {
    window.wm_scheduled.dirty_app_id = true;
    server.wm.dirtyWindowing();

    @import("Compositor.zig").notify(.{ .window_app_id_changed = window });

    if (window.foreign_toplevel_handle) |handle| {
        handle.updateState(&.{
            .title = window.getTitle(),
            .app_id = window.getAppId(),
        });
    }
    if (window.wlr_toplevel_handle) |handle| {
        if (window.getAppId()) |app_id| handle.setAppId(app_id);
    }
}

// ---------------------------------------------------------------------------
// Animation — river layer smooth transitions + open/close + popup
// ---------------------------------------------------------------------------

fn isGrabbed(window: *Window) bool {
    var it = server.input_manager.seats.iterator(.forward);
    while (it.next()) |seat| {
        if (seat.op) |op| if (op.window) |ref| if (ref.get()) |w| if (w == window) return true;
    }
    return false;
}

pub fn cancelAnimation(window: *Window) void {
    window.animation.active = false;
    // Reset visual alpha/scale to opaque/normal to avoid leftover translucency
    if (window.alpha != 1.0 or window.scale != 1.0) {
        window.alpha = 1.0;
        window.scale = 1.0;
        window.applyAlpha(1.0);
    }
}

inline fn nowMs() i64 {
    const ts = util.timestamp();
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

fn applyAlpha(window: *Window, alpha: f32) void {
    const clamped = @max(0.0, @min(1.0, alpha));
    window.alpha = clamped;
    // Apply opacity to all scene buffers in the window tree.
    // wlroots scene buffers expose setOpacity; we walk the tree via forEachBuffer.
    const Cb = struct {
        fn cb(buffer: *wlr.SceneBuffer, sx: c_int, sy: c_int, a: *f32) void {
            _ = sx;
            _ = sy;
            buffer.setOpacity(a.*);
        }
    };
    var val: f32 = clamped;
    window.tree.node.forEachBuffer(*f32, Cb.cb, &val);
    // Also apply to popup tree so popups fade with window if needed.
    // Popup fade is handled separately in XdgPopup, but keeping consistent.
}

fn scaledBox(target: wlr.Box, scale_from: f32) wlr.Box {
    // Return a box centered in target with size scaled by scale_from (e.g. 0.94).
    const sw: i32 = @intFromFloat(@floor(@as(f32, @floatFromInt(target.width)) * scale_from));
    const sh: i32 = @intFromFloat(@floor(@as(f32, @floatFromInt(target.height)) * scale_from));
    const sx: i32 = target.x + @divTrunc(target.width - sw, 2);
    const sy: i32 = target.y + @divTrunc(target.height - sh, 2);
    return .{ .x = sx, .y = sy, .width = sw, .height = sh };
}

/// Core tiling/open/close animation starter.
/// Handles `none` kind and grabbed windows as immediate snap.
fn startAnimationInternal(
    window: *Window,
    target: wlr.Box,
    target_alpha: f32,
    target_scale: f32,
    duration_ms: i64,
    easing: Animation.Easing,
    kind: @TypeOf(window.animation.kind),
) void {
    if (window.isGrabbed()) {
        window.cancelAnimation();
        window.box = target;
        window.rendering_requested.x = target.x;
        window.rendering_requested.y = target.y;
        window.tree.node.setPosition(target.x, target.y);
        window.popup_tree.node.setPosition(target.x, target.y);
        window.box.width = target.width;
        window.box.height = target.height;
        window.alpha = target_alpha;
        window.scale = target_scale;
        window.applyAlpha(target_alpha);
        return;
    }
    if (window.state != .mapped and window.state != .closing and kind == .tiling) {
        window.cancelAnimation();
        window.box = target;
        window.alpha = target_alpha;
        window.scale = target_scale;
        window.applyAlpha(target_alpha);
        return;
    }
    const now = nowMs();
    var start_box = window.box;
    var sa: f32 = window.alpha;
    var ss: f32 = window.scale;
    if (window.animation.active) {
        const elapsed = now - window.animation.start_time_ms;
        const raw = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(window.animation.duration_ms));
        const t = @min(1.0, @max(0.0, raw));
        const e = window.animation.easing.apply(t);
        start_box.x = window.animation.start_box.x + @as(i32, @intFromFloat(@as(f64, @floatFromInt(window.animation.target_box.x - window.animation.start_box.x)) * e));
        start_box.y = window.animation.start_box.y + @as(i32, @intFromFloat(@as(f64, @floatFromInt(window.animation.target_box.y - window.animation.start_box.y)) * e));
        start_box.width = window.animation.start_box.width + @as(i32, @intFromFloat(@as(f64, @floatFromInt(window.animation.target_box.width - window.animation.start_box.width)) * e));
        start_box.height = window.animation.start_box.height + @as(i32, @intFromFloat(@as(f64, @floatFromInt(window.animation.target_box.height - window.animation.start_box.height)) * e));
        sa = window.animation.start_alpha + (window.animation.target_alpha - window.animation.start_alpha) * @as(f32, @floatCast(e));
        ss = window.animation.start_scale + (window.animation.target_scale - window.animation.start_scale) * @as(f32, @floatCast(e));
    }
    // No-op check: if box, alpha and scale unchanged, skip
    if (start_box.x == target.x and start_box.y == target.y and
        start_box.width == target.width and start_box.height == target.height and
        @abs(sa - target_alpha) < 0.001 and @abs(ss - target_scale) < 0.001)
    {
        window.cancelAnimation();
        return;
    }
    window.animation = .{
        .active = true,
        .kind = kind,
        .start_box = start_box,
        .target_box = target,
        .start_alpha = sa,
        .target_alpha = target_alpha,
        .start_scale = ss,
        .target_scale = target_scale,
        .start_time_ms = now,
        .duration_ms = duration_ms,
        .easing = easing,
    };
    // For open/close alpha, ensure starting visual reflects start state immediately
    window.alpha = sa;
    window.scale = ss;
    window.applyAlpha(sa);
    server.wm.ensureAnimationTimer();
}

/// Public tiling entry — uses Animation.tiling config.
pub fn startAnimation(window: *Window, target: wlr.Box, duration_ms: i64) void {
    // Legacy path: called with explicit duration (200/180). Now honor tiling config
    // but keep duration param for backwards-compat if config is .slide.
    const cfg = Animation.get();
    if (!cfg.isTilingEnabled()) {
        window.cancelAnimation();
        window.box = target;
        window.rendering_requested.x = target.x;
        window.rendering_requested.y = target.y;
        window.tree.node.setPosition(target.x, target.y);
        window.popup_tree.node.setPosition(target.x, target.y);
        window.box.width = target.width;
        window.box.height = target.height;
        window.applyAlpha(1.0);
        return;
    }
    // Use config duration/easing, but respect passed duration for slide variant
    const dur: i64 = if (duration_ms == 180) @intCast(cfg.tiling.duration_ms - 20) else @intCast(cfg.tiling.duration_ms);
    const ta: f32 = if (window.animation.active) window.animation.target_alpha else window.alpha;
    const ts: f32 = if (window.animation.active) window.animation.target_scale else window.scale;
    startAnimationInternal(window, target, ta, ts, dur, cfg.tiling.easing, .tiling);
}

pub fn startPosAnimation(window: *Window, x: i32, y: i32, animate: bool) void {
    var target = window.box;
    if (window.animation.active) target = window.animation.target_box;
    target.x = x;
    target.y = y;
    if (!animate) {
        window.cancelAnimation();
        window.box.x = x;
        window.box.y = y;
        window.rendering_requested.x = x;
        window.rendering_requested.y = y;
        window.tree.node.setPosition(x, y);
        window.popup_tree.node.setPosition(x, y);
        return;
    }
    const cfg = Animation.get();
    if (!cfg.isTilingEnabled()) {
        window.cancelAnimation();
        window.box.x = x;
        window.box.y = y;
        window.rendering_requested.x = x;
        window.rendering_requested.y = y;
        window.tree.node.setPosition(x, y);
        window.popup_tree.node.setPosition(x, y);
        return;
    }
    window.rendering_requested.x = x;
    window.rendering_requested.y = y;
    const ta: f32 = if (window.animation.active) window.animation.target_alpha else window.alpha;
    const ts: f32 = if (window.animation.active) window.animation.target_scale else window.scale;
    startAnimationInternal(window, target, ta, ts, @intCast(cfg.tiling.duration_ms), cfg.tiling.easing, .tiling);
}

pub fn startSizeAnimation(window: *Window, w: i32, h: i32, animate: bool) void {
    var target = window.box;
    if (window.animation.active) target = window.animation.target_box;
    target.width = w;
    target.height = h;
    if (!animate) {
        window.cancelAnimation();
        window.box.width = w;
        window.box.height = h;
        return;
    }
    const cfg = Animation.get();
    if (!cfg.isTilingEnabled()) {
        window.cancelAnimation();
        window.box.width = w;
        window.box.height = h;
        return;
    }
    const ta: f32 = if (window.animation.active) window.animation.target_alpha else window.alpha;
    const ts: f32 = if (window.animation.active) window.animation.target_scale else window.scale;
    startAnimationInternal(window, target, ta, ts, @intCast(cfg.tiling.duration_ms - 20), cfg.tiling.easing, .tiling);
}

/// Window open animation — called from map().
pub fn startOpenAnimation(window: *Window, target: wlr.Box) void {
    const cfg = Animation.get();
    if (!cfg.isWindowOpenEnabled()) {
        window.cancelAnimation();
        window.box = target;
        window.alpha = 1.0;
        window.scale = 1.0;
        window.applyAlpha(1.0);
        return;
    }
    const c = cfg.window_open;
    switch (c.kind) {
        .none => {
            window.cancelAnimation();
            window.box = target;
            window.applyAlpha(1.0);
            return;
        },
        .fade => {
            startAnimationInternal(window, target, 1.0, 1.0, @intCast(c.duration_ms), c.easing, .open);
            // For fade, start alpha is current (0) -> 1, set by caller (map set alpha 0)
            // Ensure start_alpha is 0 by having window.alpha =0 before call; startAnimationInternal will use current 0
        },
        .scale => {
            const start_box = scaledBox(target, c.scale_from);
            // Directly set scaled -> target without going through startAnimationInternal's current-box interpolation
            // isGrabbed check still applies
            if (window.isGrabbed()) {
                window.cancelAnimation();
                window.box = target;
                window.applyAlpha(1.0);
                return;
            }
            const now = nowMs();
            window.animation = .{
                .active = true,
                .kind = .open,
                .start_box = start_box,
                .target_box = target,
                .start_alpha = 1.0,
                .target_alpha = 1.0,
                .start_scale = c.scale_from,
                .target_scale = 1.0,
                .start_time_ms = now,
                .duration_ms = @intCast(c.duration_ms),
                .easing = c.easing,
            };
            window.alpha = 1.0;
            window.scale = c.scale_from;
            window.box = start_box;
            window.tree.node.setPosition(start_box.x, start_box.y);
            window.popup_tree.node.setPosition(start_box.x, start_box.y);
            server.wm.ensureAnimationTimer();
        },
        .scfade => {
            const start_box = scaledBox(target, c.scale_from);
            if (window.isGrabbed()) {
                window.cancelAnimation();
                window.box = target;
                window.applyAlpha(1.0);
                return;
            }
            const now = nowMs();
            window.animation = .{
                .active = true,
                .kind = .open,
                .start_box = start_box,
                .target_box = target,
                .start_alpha = 0.0,
                .target_alpha = 1.0,
                .start_scale = c.scale_from,
                .target_scale = 1.0,
                .start_time_ms = now,
                .duration_ms = @intCast(c.duration_ms),
                .easing = c.easing,
            };
            window.alpha = 0.0;
            window.scale = c.scale_from;
            window.box = start_box;
            window.tree.node.setPosition(start_box.x, start_box.y);
            window.popup_tree.node.setPosition(start_box.x, start_box.y);
            window.applyAlpha(0.0);
            server.wm.ensureAnimationTimer();
        },
    }
}

/// Window close animation — called from unmap(). Returns true if animation started (caller should delay destroy).
pub fn startCloseAnimation(window: *Window) bool {
    const cfg = Animation.get();
    if (!cfg.isWindowCloseEnabled()) return false;
    const c = cfg.window_close;
    if (c.kind == .none) return false;
    const target = window.box;
    switch (c.kind) {
        .none => return false,
        .fade => {
            startAnimationInternal(window, target, 0.0, 1.0, @intCast(c.duration_ms), c.easing, .close);
            return true;
        },
        .scale => {
            const end_box = scaledBox(target, c.scale_from);
            startAnimationInternal(window, end_box, 1.0, c.scale_from, @intCast(c.duration_ms), c.easing, .close);
            return true;
        },
        .scfade => {
            const end_box = scaledBox(target, c.scale_from);
            startAnimationInternal(window, end_box, 0.0, c.scale_from, @intCast(c.duration_ms), c.easing, .close);
            return true;
        },
    }
}

pub fn tickAnimation(window: *Window, now_ms: i64) bool {
    // Handle deferred open animation (box not known at map time)
    if (window.pending_open) {
        if (window.state != .mapped) {
            window.pending_open = false;
        } else if (window.box.width == 0 or window.box.height == 0) {
            return true; // keep timer alive until box known
        } else {
            window.pending_open = false;
            window.startOpenAnimation(window.box);
            if (!window.animation.active) return false;
        }
    }
    if (!window.animation.active) return false;
    const elapsed = now_ms - window.animation.start_time_ms;
    if (elapsed >= window.animation.duration_ms) {
        window.box = window.animation.target_box;
        window.alpha = window.animation.target_alpha;
        window.scale = window.animation.target_scale;
        window.tree.node.setPosition(window.box.x, window.box.y);
        window.popup_tree.node.setPosition(window.box.x, window.box.y);
        window.applyAlpha(window.alpha);
        window.drawBorders();
        var clip = window.rendering_requested.clip;
        var content_clip = window.rendering_requested.content_clip;
        window.applySurfaceClip(&clip, &content_clip);
        // For close animation, keep enabled until final alpha 0 then hide
        const was_close = window.animation.kind == .close;
        if (was_close and window.alpha <= 0.01) {
            window.tree.node.setEnabled(false);
            window.popup_tree.node.setEnabled(false);
        }
        window.animation.active = false;
        if (was_close) {
            // Schedule final cleanup: next manage will move from closing -> init -> destroy
            server.wm.dirtyWindowing();
        }
        return false;
    }
    const t = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(window.animation.duration_ms));
    const e = window.animation.easing.apply(@min(1.0, @max(0.0, t)));
    const lerpI32 = struct {
        fn f(a: i32, b: i32, ee: f64) i32 {
            return a + @as(i32, @intFromFloat(@as(f64, @floatFromInt(b - a)) * ee));
        }
    }.f;
    window.box.x = lerpI32(window.animation.start_box.x, window.animation.target_box.x, e);
    window.box.y = lerpI32(window.animation.start_box.y, window.animation.target_box.y, e);
    window.box.width = lerpI32(window.animation.start_box.width, window.animation.target_box.width, e);
    window.box.height = lerpI32(window.animation.start_box.height, window.animation.target_box.height, e);
    window.alpha = window.animation.start_alpha + (window.animation.target_alpha - window.animation.start_alpha) * @as(f32, @floatCast(e));
    window.scale = window.animation.start_scale + (window.animation.target_scale - window.animation.start_scale) * @as(f32, @floatCast(e));
    window.tree.node.setPosition(window.box.x, window.box.y);
    window.popup_tree.node.setPosition(window.box.x, window.box.y);
    window.applyAlpha(window.alpha);
    window.drawBorders();
    var clip = window.rendering_requested.clip;
    var content_clip = window.rendering_requested.content_clip;
    window.applySurfaceClip(&clip, &content_clip);
    return true;
}
