// SPDX-FileCopyrightText: © 2024 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const WindowManager = @This();

const std = @import("std");
const assert = std.debug.assert;
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const SlotMap = @import("slotmap").SlotMap;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Output = @import("Output.zig");
const Scene = @import("Scene.zig");
const Seat = @import("Seat.zig");
const ShellSurface = @import("ShellSurface.zig");
const Window = @import("Window.zig");
const WmNode = @import("WmNode.zig");

const log = std.log.scoped(.wm);

/// Legacy Wayland global - disabled by default. Nile uses direct functions.
/// See `Nile.zig` and `doc/nile-api.md`. Set to non-null only if you need
/// compatibility with old external window managers.
global: ?*wl.Global = null,
server_destroy: wl.Listener(*wl.Server) = .init(handleServerDestroy),

state: union(enum) {
    idle,
    /// Waiting on the window manager client to send manage_finish.
    manage,
    /// The number of configures sent that have not yet been acked
    inflight_configures: u32,
    /// Waiting on the window manager client to send render_finish.
    render,
} = .idle,

windows: SlotMap(*Window) = .empty,

/// State to be sent to the wm in the next manage sequence.
scheduled: struct {
    /// State has been modified since the last manage sequence.
    /// Prevents processing further input events until a manage sequence is completed.
    dirty: bool = false,
    /// A manage sequence should be started when idle, but don't prevent processing
    /// further input events.
    dirty_lazy: bool = false,

    output_config: ?*wlr.OutputConfigurationV1 = null,
} = .{},

/// State sent to the wm in the latest update sequence.
sent: struct {
    session_locked: bool = false,

    outputs: wl.list.Head(Output, .link_sent),
    output_config: ?*wlr.OutputConfigurationV1 = null,

    seats: wl.list.Head(Seat, .link_sent),
},

/// Rendering state to be sent to the wm in the next render sequence.
rendering_scheduled: struct {
    /// Rendering state has been modified since the last render sequence.
    dirty: bool = false,
} = .{},

/// The list is in rendering order, the last node in the list is rendered on top.
rendering_requested: struct {
    list: wl.list.Head(WmNode, .link),
    order_hash: u64 = 0,
},

dirty_idle: ?*wl.EventSource = null,

animation_timer: ?*wl.EventSource = null,

timeout: *wl.EventSource,

pub fn init(wm: *WindowManager) !void {
    const event_loop = server.wl_server.getEventLoop();
    const timeout = try event_loop.addTimer(*WindowManager, handleTimeout, wm);
    errdefer timeout.remove();

    wm.* = .{
        .global = null, // Nile: legacy river_window_manager_v1 global disabled
        // To re-enable for compatibility with old WMs, uncomment:
        // .global = try wl.Global.create(server.wl_server, river.WindowManagerV1, 5, *WindowManager, wm, bind),
        .sent = .{
            .outputs = undefined,
            .seats = undefined,
        },
        .rendering_requested = .{
            .list = undefined,
        },
        .timeout = timeout,
    };
    wm.sent.outputs.init();
    wm.sent.seats.init();
    wm.rendering_requested.list.init();

    // Only add legacy init if global is enabled. For Nile, window management
    // is done via direct function calls in `Nile.zig` without a Wayland client.
    // The transaction system (manage/render) still runs, but is driven by
    // `Nile.dirtyWindowing()` / `dirtyRendering()` rather than protocol messages.
    server.wl_server.addDestroyListener(&wm.server_destroy);
}

fn handleServerDestroy(listener: *wl.Listener(*wl.Server), _: *wl.Server) void {
    const wm: *WindowManager = @fieldParentPtr("server_destroy", listener);

    if (wm.global) |g| g.destroy();
    if (wm.animation_timer) |t| t.remove();
    wm.timeout.remove();
}

pub fn ensureAnimationTimer(wm: *WindowManager) void {
    if (wm.animation_timer != null) return;
    const event_loop = server.wl_server.getEventLoop();
    wm.animation_timer = event_loop.addTimer(*WindowManager, handleAnimationTick, wm) catch {
        log.err("failed to create animation timer", .{});
        return;
    };
    // First tick ~16ms (60fps) — batch window so rapid arrange calls coalesce
    wm.animation_timer.?.timerUpdate(16) catch {};
}

fn handleAnimationTick(wm: *WindowManager) c_int {
    const ts = util.timestamp();
    const now: i64 = @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
    var any_active = false;
    var it = wm.windows.iterator();
    while (it.next()) |window| {
        if (window.tickAnimation(now)) any_active = true;
    }
    if (any_active) {
        wm.animation_timer.?.timerUpdate(16) catch {};
    } else {
        if (wm.animation_timer) |t| {
            t.remove();
            wm.animation_timer = null;
        }
    }
    return 0;
}

pub fn ensureWindowing(wm: *WindowManager) bool {
    switch (wm.state) {
        .manage => return true,
        .idle, .inflight_configures, .render => return false,
    }
}

pub fn ensureRendering(wm: *WindowManager) bool {
    switch (wm.state) {
        .manage, .inflight_configures, .render => return true,
        .idle => return false,
    }
}

pub fn dirtyWindowing(wm: *WindowManager) void {
    wm.scheduled.dirty = true;
    wm.addDirtyIdle();
}

pub fn dirtyWindowingLazy(wm: *WindowManager) void {
    wm.scheduled.dirty_lazy = true;
    wm.addDirtyIdle();
}

pub fn cleanWindowing(wm: *WindowManager) void {
    wm.scheduled.dirty = false;
    wm.removeDirtyIdle();
}

pub fn dirtyRendering(wm: *WindowManager) void {
    wm.rendering_scheduled.dirty = true;
    wm.addDirtyIdle();
}

/// Immediate variant — apply pending rendering_requested directly to the
/// scene graph without waiting for the next idle. Safe to call from
/// `onPointerMotion` for move/drag. Only touches rendering state
/// (position/hidden/border/clip), never `wm_requested` dimensions.
/// Falls back to normal `dirtyRendering` if a manage is in progress
/// where geometry is driven by output state.
pub fn dirtyRenderingImmediate(wm: *WindowManager) void {
    // If idle, we can still handle synchronously to avoid one idle tick.
    // If in-flight, we also handle synchronously — rendering changes
    // do not require client ack and can run concurrent to configure wait.
    wm.applyPendingRenderingImmediate();
    // Clear the scheduled dirty flag since we flushed it synchronously;
    // keep any pending windowing dirty untouched.
    if (wm.rendering_scheduled.dirty) {
        wm.cleanRendering();
    }
}

fn applyPendingRenderingImmediate(wm: *WindowManager) void {
    var it = wm.rendering_requested.list.iterator(.forward);
    while (it.next()) |node| {
        switch (node.get()) {
            .window => |window| window.applyRenderingImmediate(),
            .shell_surface => |shell_surface| shell_surface.renderFinish(),
        }
    }
}

pub fn cleanRendering(wm: *WindowManager) void {
    wm.rendering_scheduled.dirty = false;
    wm.removeDirtyIdle();
}

fn addDirtyIdle(wm: *WindowManager) void {
    assert(wm.scheduled.dirty or wm.scheduled.dirty_lazy or wm.rendering_scheduled.dirty);
    if (wm.dirty_idle == null) {
        const event_loop = server.wl_server.getEventLoop();
        wm.dirty_idle = event_loop.addIdle(*WindowManager, dirtyIdle, wm) catch {
            log.err("out of memory", .{});
            return;
        };
    }
}

fn removeDirtyIdle(wm: *WindowManager) void {
    if (!wm.scheduled.dirty and !wm.scheduled.dirty_lazy and !wm.rendering_scheduled.dirty) {
        if (wm.dirty_idle) |event_source| {
            event_source.remove();
            wm.dirty_idle = null;
        }
    }
}

fn dirtyIdle(wm: *WindowManager) void {
    assert(wm.scheduled.dirty or wm.scheduled.dirty_lazy or wm.rendering_scheduled.dirty);
    wm.dirty_idle = null;
    switch (wm.state) {
        .idle => {
            if (wm.rendering_scheduled.dirty) {
                wm.renderStart();
            } else {
                assert(wm.scheduled.dirty or wm.scheduled.dirty_lazy);
                wm.scheduled.dirty = true;
                wm.scheduled.dirty_lazy = false;
                wm.manageStart();
            }
        },
        .manage, .inflight_configures, .render => {},
    }
}

fn manageStart(wm: *WindowManager) void {
    assert(wm.state == .idle);
    assert(wm.scheduled.dirty);
    wm.cleanWindowing();
    wm.state = .manage;

    log.debug("manage sequence start", .{});

    const session_locked = server.lock_manager.state == .locked;
    if (session_locked != wm.sent.session_locked) {
        wm.sent.session_locked = session_locked;
    }

    server.om.autoLayout();
    {
        var it = server.om.outputs.safeIterator(.forward);
        while (it.next()) |output| output.manageStart();
    }

    assert(wm.sent.output_config == null);
    wm.sent.output_config = wm.scheduled.output_config;
    wm.scheduled.output_config = null;

    {
        var it = wm.windows.iterator();
        while (it.next()) |window| window.manageStart();
    }

    {
        var it = server.input_manager.seats.safeIterator(.forward);
        while (it.next()) |seat| seat.manageStart();
    }

    wm.manageFinish();
}

pub fn manageFinish(wm: *WindowManager) void {
    assert(wm.state == .manage);

    log.debug("manage sequence finish", .{});

    {
        // Order is important here, Seat.manageFinish() must be called
        // before Window.manageFinish().
        // NOTE: iterate the live seat list, not wm.sent.seats: nothing ever
        // appends seats to sent.seats (legacy external-WM bookkeeping), so
        // iterating it silently skipped every seat and dropped all
        // seat-mediated requests (window focus, pointer warp, move/resize
        // ops) on the floor. manageStart() above uses the live list too.
        var it = server.input_manager.seats.safeIterator(.forward);
        while (it.next()) |seat| seat.manageFinish();
    }

    wm.state = .{ .inflight_configures = 0 };
    {
        var it = wm.rendering_requested.list.iterator(.forward);
        while (it.next()) |node| {
            switch (node.get()) {
                .window => |window| {
                    if (window.manageFinish()) {
                        wm.state.inflight_configures += 1;
                    }
                },
                .shell_surface => {},
            }
        }
    }

    log.debug("sent {} tracked configure(s)", .{wm.state.inflight_configures});

    if (wm.state.inflight_configures > 0) {
        wm.startTimeoutTimer(100);
    } else {
        wm.renderStart();
    }
}

fn startTimeoutTimer(wm: *WindowManager, ms: u31) void {
    wm.timeout.timerUpdate(ms) catch {
        log.err("failed to start timer", .{});
        _ = wm.handleTimeout();
    };
}

fn cancelTimeoutTimer(wm: *WindowManager) void {
    wm.timeout.timerUpdate(0) catch log.err("error disarming timer", .{});
}

fn handleTimeout(wm: *WindowManager) c_int {
    assert(wm.state.inflight_configures > 0);
    log.err("timeout occurred, some imperfect frames may be shown", .{});
    wm.state.inflight_configures = 0;

    wm.renderStart();

    return 0;
}

pub fn notifyConfigured(wm: *WindowManager) void {
    wm.state.inflight_configures -= 1;
    if (wm.state.inflight_configures == 0) {
        wm.cancelTimeoutTimer();
        wm.renderStart();
    }
}

fn renderStart(wm: *WindowManager) void {
    assert((wm.state == .idle and wm.rendering_scheduled.dirty) or
        wm.state.inflight_configures == 0);
    wm.state = .render;
    wm.cleanRendering();

    log.debug("render sequence start", .{});

    {
        var it = wm.rendering_requested.list.iterator(.forward);
        while (it.next()) |node| {
            switch (node.get()) {
                .window => |window| window.renderStart(),
                .shell_surface => {},
            }
        }
    }

    wm.renderFinish();
}

/// Finish the update sequence and drop stashed buffers. This means that
/// the next frame drawn will be the post-transaction state.
fn renderFinish(wm: *WindowManager) void {
    assert(wm.state == .render);
    wm.state = .idle;

    log.debug("render sequence finish", .{});

    {
        var it = wm.windows.iterator();
        while (it.next()) |window| {
            const close_anim_active = window.animation.active and window.animation.kind == .close;
            // If a window is unmapped during a render sequence, we need to retain the saved
            // buffers until after the next manage sequence (in which the closed event will
            // be sent) for frame perfection. Keep saved while close anim is running.
            if (window.state != .closing and !close_anim_active) {
                window.surfaces.dropSaved();
            }
            // Ensure windows that are closed but not yet destroyed don't have
            // their borders/decorations rendered. Don't hide while close anim is fading.
            if (window.state == .init and !close_anim_active) {
                window.tree.node.reparent(server.scene.hidden_tree);
            }
            if (window.impl == .destroying and !close_anim_active) {
                window.destroy();
            } else if (window.impl == .destroying and close_anim_active) {
                // Keep close animation alive — ensure timer is running
                wm.ensureAnimationTimer();
            }
        }
    }

    // This is a hack to avoid excessive modification of the wlroots scene graph.
    // There is currently no way to atomically apply multiple changes to the
    // scene graph, which means that damage and visibility are re-calculated
    // every API call, resulting in redundant events being sent to clients.
    //
    // TODO(wlroots) provide a way to batch changes to the scene graph.
    const new_order_hash = blk: {
        var hash = std.crypto.hash.Blake3.init(.{});
        var it = wm.rendering_requested.list.iterator(.forward);
        while (it.next()) |node| {
            switch (node.get()) {
                .window => |window| {
                    hash.update(@ptrCast(&window.ref));
                    hash.update(&.{@intFromBool(renderedFullscreen(window))});
                },
                .shell_surface => |shell_surface| {
                    hash.update(@ptrCast(&shell_surface));
                },
            }
        }
        var final: u64 = undefined;
        hash.final(@ptrCast(&final));
        break :blk final;
    };

    {
        const reorder = wm.rendering_requested.order_hash != new_order_hash;
        wm.rendering_requested.order_hash = new_order_hash;

        var found_fullscreen: bool = false;
        var it = wm.rendering_requested.list.iterator(.forward);
        while (it.next()) |node| {
            switch (node.get()) {
                .window => |window| {
                    window.renderFinish();
                    if (!reorder) continue;
                    window.popup_tree.node.reparent(server.scene.layers.popups);
                    if (renderedFullscreen(window)) {
                        window.tree.node.reparent(server.scene.layers.fullscreen);
                        window.tree.node.raiseToTop();
                        found_fullscreen = true;
                    } else {
                        window.tree.node.reparent(server.scene.layers.wm);
                        window.tree.node.raiseToTop();
                    }
                },
                .shell_surface => |shell_surface| {
                    shell_surface.renderFinish();
                    if (!reorder) continue;
                    shell_surface.popup_tree.node.reparent(server.scene.layers.popups);
                    if (found_fullscreen) {
                        shell_surface.tree.node.reparent(server.scene.layers.fullscreen);
                    } else {
                        shell_surface.tree.node.reparent(server.scene.layers.wm);
                    }
                    shell_surface.tree.node.raiseToTop();
                },
            }
        }
    }

    server.om.commitOutputState();

    {
        var it = server.input_manager.seats.iterator(.forward);
        while (it.next()) |seat| seat.cursor.updateState();
    }

    server.idle_inhibit_manager.checkActive();

    log.debug("finished committing transaction", .{});

    // Notify compositor that a frame tick completed — good place for deferred arrange
    @import("Compositor.zig").notify(.frame);

    if (wm.scheduled.dirty or wm.scheduled.dirty_lazy or wm.rendering_scheduled.dirty) {
        wm.addDirtyIdle();
    }

    server.input_manager.processEvents();
}

fn renderedFullscreen(window: *Window) bool {
    return window.wm_requested.fullscreen != null and !window.rendering_requested.hidden;
}
