// SPDX-FileCopyrightText: © 2026 The Nile Developers
// SPDX-License-Identifier: GPL-3.0-only

//! Compositor — single struct that controls all compositor behavior.
//!
//! The user provides a struct with a single `handle` method:
//!
//! ```zig
//! const MyCompositor = struct {
//!     // any state you want
//!     pub fn handle(self: *MyCompositor, event: Event) void {
//!         switch (event) {
//!             .window_map => |win| {
//!                 const out = Nile.Output.primary() orelse return;
//!                 Nile.Window.setPosition(win, out.current.box().x, out.current.box().y);
//!                 Nile.dirtyWindowing();
//!             },
//!             else => {}, // ignore what you don't care about
//!         }
//!     }
//! };
//! ```
//!
//! Register with `Compositor.set(Compositor.initCompositor(MyCompositor, &instance))`
//! or via `Nile.setCompositor`. After that every state change is delivered as an
//! `Event` union. The compositor controls behavior by calling `Nile.*` functions
//! inside `handle` (or any helper it calls). All events are optional — just ignore
//! variants you don't need.
//!
//! Threading: only called on the main Wayland event loop thread.

const std = @import("std");

const wl = @import("wayland").server.wl;

const Window = @import("Window.zig");
const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const InputDevice = @import("InputDevice.zig");
const XkbBinding = @import("XkbBinding.zig");
// LayerSurface is optional; avoid hard dependency if not needed
// const LayerSurface = @import("LayerSurface.zig");

/// Kind of pointer button hold — distinguishes a normal click from an
/// interactive move or resize initiated via the xdg_toplevel decoration.
pub const PointerButtonKind = enum {
    /// Normal button press with no associated window operation.
    normal,
    /// Button hold that initiates an interactive window move.
    move,
    /// Button hold that initiates an interactive window resize.
    resize,
};

/// All compositor-relevant state changes. Add variants without breaking existing
/// `switch` handling — `else => {}` continues to work.
pub const Event = union(enum) {
    /// A new window has been created and is ready to be configured.
    /// This is the first opportunity to give it dimensions via `Nile.Window.setDimensions`
    /// and position via `setPosition`. The window is in `Window.state == .ready`
    /// and will not advance to `.initialized`/`mapped` until the compositor
    /// provides dimensions. Emitted from `XdgToplevel.handleCommit` on
    /// initial commit.
    window_add: *Window,

    /// Window is mapped and visible (state == .mapped).
    /// Use `Nile.Window.setDimensions` / `setPosition` etc. then `dirtyWindowing`.
    window_map: *Window,

    /// Window is being unmapped (client unmapped surface, not yet destroyed).
    /// Still has a valid `*Window` until `window_destroy`.
    window_unmap: *Window,

    /// Window will be destroyed after this event (after render sequence).
    window_destroy: *Window,

    /// Title changed (via `Window.notifyTitle`).
    window_title_changed: *Window,

    /// App ID / class changed (via `Window.notifyAppId`).
    window_app_id_changed: *Window,

    /// Parent window changed (transient).
    window_parent_changed: *Window,

    /// Client requested fullscreen. `output` may be null (client didn't hint).
    window_fullscreen_request: struct {
        window: *Window,
        output: ?*Output,
    },

    /// Client requested maximize/unmaximize.
    window_maximize_request: struct {
        window: *Window,
        maximize: bool,
    },

    /// Client requested minimize.
    window_minimize_request: *Window,

    /// Pointer moved. Emitted for every relative/absolute motion event
    /// (before internal passthrough/op handling). Use `Nile.Seat.pointerPos`
    /// or the `x`/`y` fields for current cursor position.
    pointer_motion: struct {
        seat: *Seat,
        time_msec: u32,
        x: f64,
        y: f64,
        dx: f64,
        dy: f64,
        unaccel_dx: f64,
        unaccel_dy: f64,
    },

    /// Pointer button pressed or released. `kind` indicates whether this hold
    /// is a normal click or the start/end of an interactive move/resize
    /// (client-initiated via decorations or compositor-initiated via bindings).
    /// For `kind == .resize`, `edges` specifies the requested resize edges;
    /// otherwise `edges` is empty.
    pointer_button: struct {
        seat: *Seat,
        window: ?*Window,
        time_msec: u32,
        button: u32,
        state: wl.Pointer.ButtonState,
        x: f64,
        y: f64,
        kind: PointerButtonKind,
        edges: Window.Edges,
    },

    /// New output appeared (`Output.create`).
    output_add: *Output,

    /// Output is being removed (`Output.handleDestroy`). Pointer is still valid
    /// during this call but will be freed after `WindowManager` finishes.
    output_remove: *Output,

    /// Output state changed (mode, scale, transform, etc. after modeset).
    output_update: *Output,

    /// New seat created (`Seat.create`).
    seat_add: *Seat,

    /// Seat is being destroyed.
    seat_remove: *Seat,

    /// New input device attached (`InputManager.handleNewInput`).
    input_device_add: *InputDevice,

    /// Input device removed.
    input_device_remove: *InputDevice,

    /// A key binding was pressed (via `XkbBinding.pressed`).
    keybind_pressed: *XkbBinding,

    /// Key binding released.
    keybind_released: *XkbBinding,

    /// Frame / idle tick — opportunity to run deferred arrange logic.
    /// Emitted when `WindowManager` goes idle and no other event is pending.
    frame: void,
};

pub const VTable = struct {
    handle: *const fn (ptr: *anyopaque, event: Event) void,
    deinit: ?*const fn (ptr: *anyopaque) void = null,
};

pub const Compositor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub fn handle(self: Compositor, event: Event) void {
        self.vtable.handle(self.ptr, event);
    }

    pub fn deinit(self: Compositor) void {
        if (self.vtable.deinit) |f| f(self.ptr);
    }
};

// Global compositor instance. Null before `set` is called — events are dropped.
var global: ?Compositor = null;

// Queue for window_add events that arrived before a compositor was
// registered. Stores Refs (SlotMap keys) not raw pointers, so destroyed
// windows don't leave dangling pointers. Bounded.
var pending_window_add: [32]Window.Ref = undefined;
var pending_window_add_len: usize = 0;

/// Register the compositor. Call once during `Server.init` or `main` after
/// `server.init`. Replaces any previous compositor (old one's `deinit` is NOT
/// called — call it yourself if needed).
pub fn set(compositor: Compositor) void {
    global = compositor;
    // Replay any window_add that was emitted before registration.
    // This does not change NileCompositor's tiling logic — it just
    // re-delivers the same event at a time when the handler exists.
    for (pending_window_add[0..pending_window_add_len]) |ref| {
        if (ref.get()) |win| {
            // Window may have been destroyed or already promoted; only
            // replay if still in ready (needs dimensions). Xwayland windows
            // that now emit window_add directly will already have been handled,
            // so this is primarily for early XDG windows.
            if (win.state == .ready) {
                compositor.handle(.{ .window_add = win });
            }
        }
    }
    pending_window_add_len = 0;
}

/// Clear the registered compositor. Events will be dropped until `set` again.
pub fn clear() void {
    global = null;
}

pub fn get() ?Compositor {
    return global;
}

/// Deliver an event to the registered compositor if any. Safe to call when
/// no compositor is set — no-op (window_add is queued for replay).
pub fn notify(event: Event) void {
    if (global) |c| {
        c.handle(event);
    } else {
        // Only queue window_add — other events are either idempotent
        // (output_add will fire again on next output) or not needed
        // before compositor exists.
        if (event == .window_add) {
            if (pending_window_add_len < pending_window_add.len) {
                pending_window_add[pending_window_add_len] = event.window_add.ref;
                pending_window_add_len += 1;
            }
        }
    }
}

/// Helper to create a `Compositor` from any struct that has
/// `pub fn handle(self: *T, event: Event) void` (and optionally
/// `pub fn deinit(self: *T) void`).
pub fn initCompositor(comptime T: type, instance: *T) Compositor {
    const Gen = struct {
        fn handle(ptr: *anyopaque, event: Event) void {
            const self: *T = @ptrCast(@alignCast(ptr));
            self.handle(event);
        }
        fn deinit(ptr: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(ptr));
            self.deinit();
        }
        const vtable: VTable = .{
            .handle = handle,
            .deinit = if (@hasDecl(T, "deinit")) deinit else null,
        };
    };
    return .{
        .ptr = instance,
        .vtable = &Gen.vtable,
    };
}

/// Convenience for stateless compositors that only need a function:
/// `Compositor.setFn(myHandleFn)`
pub fn setFn(comptime handleFn: *const fn (Event) void) void {
    const Gen = struct {
        fn handle(_: *anyopaque, event: Event) void {
            handleFn(event);
        }
        const vtable: VTable = .{ .handle = handle };
    };
    var dummy: u8 = 0;
    global = .{ .ptr = &dummy, .vtable = &Gen.vtable };
    // Same replay as set() — ensures early window_add not lost
    for (pending_window_add[0..pending_window_add_len]) |ref| {
        if (ref.get()) |win| if (win.state == .ready) {
            global.?.handle(.{ .window_add = win });
        };
    }
    pending_window_add_len = 0;
}
