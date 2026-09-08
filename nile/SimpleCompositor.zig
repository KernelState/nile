// SPDX-FileCopyrightText: © 2026 The Nile Developers
// SPDX-License-Identifier: GPL-3.0-only

//! SimpleCompositor — example compositor that shows how to use the struct+Event API.
//!
//! This is the default policy compiled into `nile`. Replace it with your own
//! by writing a struct with `pub fn handle(self: *MyCompositor, event: Event) void`
//! and calling `Nile.setCompositor(Compositor.initCompositor(MyCompositor, &instance))`.
//!
//! The struct owns all policy. Events you don't care about are ignored with `else => {}`.
//! Control is via `Nile.*` calls inside `handle` — e.g. `Nile.Window.setPosition`.

const std = @import("std");
const server = &@import("main.zig").server;
const Nile = @import("Nile.zig");
const Compositor = @import("Compositor.zig");
const Window = @import("Window.zig");
const Output = @import("Output.zig");
const XkbBinding = @import("XkbBinding.zig");

const log = std.log.scoped(.wm);

const Tree = struct {
    root: ?Node = null,

    pub const Node = union(enum) {
        leaf: *Window,
        branch: Branch,

        pub const Branch = struct {
            first: Node,
            second: Node,
        };

        pub fn getNode(self: *Node, x: u32, y: u32) *Node {
            switch (self) {
                .leaf => return &self,
                .branch => |b| {
                    const n1 = b.first.getNode(x, y);
                    const n2 = b.first.getNode(x, y);
                    std.debug.assert(n1 == .leaf);
                    std.debug.assert(n2 == .leaf);
                    if (n1) {}
                },
            }
        }
    };

    pub fn construct(wins: []const *Window) Tree {
        const n: Tree = .{};
        if (wins.len == 0)
            return n;
        const largest: ?*Window = null;
        for (wins) |win| {
            if (largest == null) {
                largest = win;
                continue;
            }
            const ls = largest.?.box.width * largest.?.box.height;
            const cs = win.box.width * win.box.height;
            if (ls < cs)
                largest = win;
        }
        n.root = .{ .leaf = largest.? };
        for (wins) |win| {
            if (n.root.? == .leaf and n.root.?.leaf == win)
                continue;
        }
    }
};

pub const SimpleCompositor = struct {
    gpa: std.mem.Allocator = undefined,
    buf: [256]u8 = undefined,
    fba: std.heap.FixedBufferAllocator = undefined,
    // Example state: you can store whatever you need
    // e.g. master ratio, gaps, focused window, layout mode, etc.
    // All fields are owned by the compositor struct itself.
    // Put your compositor logic here — this is the single place that controls
    // window placement, focus, borders, etc. via Nile.* calls.

    /// Called once after registration — use to create keybindings, set up outputs, etc.
    /// Called from main.zig after `setCompositor`. You can also do this lazily on `output_add`.
    pub fn init(self: *SimpleCompositor) void {
        self.fba = .init(&self.buf);
        self.gpa = self.fba.allocator();
    }

    pub fn handle(self: *SimpleCompositor, event: Compositor.Event) void {
        log.info("handling events", .{});
        switch (event) {
            .window_add => |win| self.onWindowAdd(win),
            .window_map => |win| self.onWindowMap(win),
            .window_unmap => |win| self.onWindowUnmap(win),
            .window_destroy => |win| self.onWindowDestroy(win),
            .output_add => |out| self.onOutputAdd(out),
            .output_remove => |out| self.onOutputRemove(out),
            .output_update => |out| self.onOutputUpdate(out),
            .keybind_pressed => |binding| self.onKeybindPressed(binding),
            .window_fullscreen_request => |req| self.onFullscreen(req.window, req.output),
            .pointer_motion => |ev| self.onPointerMotion(ev.seat, ev.x, ev.y, ev.dx, ev.dy, ev.time_msec),
            .pointer_button => |ev| self.onPointerButton(ev.seat, ev.window, ev.button, ev.state, ev.x, ev.y, ev.kind, ev.edges, ev.time_msec),
            .frame => self.onFrame(),
            else => {}, // ignore everything else (title/app_id/parent/minimize/maximize etc.)
        }
    }

    fn onWindowAdd(self: *SimpleCompositor, win: *Window) void {
        log.info("window add (ready): {?s}", .{win.getTitle()});
        self.arrange();
    }

    fn onWindowMap(self: *SimpleCompositor, win: *Window) void {
        log.info("window mapped: {?s}", .{win.getTitle()});
        // Example: focus new window
        Nile.Window.focus(win);
        self.arrange();
    }

    fn onWindowUnmap(self: *SimpleCompositor, win: *Window) void {
        _ = win;
        log.info("window unmapped", .{});
        self.arrange();
    }

    fn onWindowDestroy(self: *SimpleCompositor, win: *Window) void {
        _ = win;
        self.arrange();
    }

    fn onOutputAdd(self: *SimpleCompositor, out: *Output) void {
        if (out.wlr_output) |wlr_out| log.info("output added: {s}", .{wlr_out.name});
        self.arrange();
    }

    fn onOutputRemove(self: *SimpleCompositor, out: *Output) void {
        _ = out;
        log.info("output removed", .{});
        self.arrange();
    }

    fn onOutputUpdate(self: *SimpleCompositor, out: *Output) void {
        if (out.wlr_output) |wlr_out| log.info("output updated: {s}", .{wlr_out.name});
        self.arrange();
    }

    fn onKeybindPressed(self: *SimpleCompositor, binding: *XkbBinding) void {
        _ = self;
        _ = binding;
        // Example: close focused window on Mod+Q (if you bound it)
        // if (binding.keysym == .q) { if (Nile.Seat.default().focused == .window) |w| Nile.Window.close(w); }
    }

    /// Arrange all windows — simple vertical stack, 1 output for now.
    /// Replace with your tiling logic. Call whenever window/output set changes.
    pub fn arrange(self: *SimpleCompositor) void {
        const out = Nile.Output.primary() orelse return;
        const box = Nile.Layer.nonExclusiveArea(out);
        if (box.width == 0 or box.height == 0) return;
        const current_ws = server.workspace.currentWorkspace();
        self.fba.reset();
        var wins = std.ArrayList(*Window).empty;
        var it = Nile.Window.iter();
        while (it.next()) |win| {
            if (win.wm_requested.workspace != current_ws) continue;
            // Don't over allocate for no reason
            if (wins.items.len > 256 / @sizeOf(*Window)) break;
            switch (win.state) {
                .ready, .initialized, .mapped => wins.append(self.fba.allocator(), win) catch {},
                .init, .closing => {},
            }
        }
        if (wins.items.len == 0) return;
        const h = @divTrunc(box.height, @as(i32, @intCast(wins.items.len)));
        var i: usize = 0;
        for (wins.items) |win| {
            const y = box.y + @as(i32, @intCast(i)) * h;
            Nile.Window.setPosition(win, box.x, y, true);
            Nile.Window.setDimensions(win, @intCast(box.width), @intCast(h), true);
            i += 1;
        }
        Nile.dirtyWindowing();
        Nile.dirtyRendering();
    }

    fn onFullscreen(self: *SimpleCompositor, win: *Window, output: ?*Output) void {
        _ = self;
        log.info("fullscreen request {?s}", .{win.getTitle()});
        Nile.Window.setFullscreen(win, output);
    }

    fn onPointerButton(
        self: *SimpleCompositor,
        seat: *@import("Seat.zig"),
        window: ?*Window,
        button: u32,
        state: @import("wayland").server.wl.Pointer.ButtonState,
        x: f64,
        y: f64,
        kind: Compositor.PointerButtonKind,
        edges: Window.Edges,
        time_msec: u32,
    ) void {
        _ = self;
        _ = x;
        _ = y;
        _ = time_msec;
        _ = button;
        switch (state) {
            .pressed => switch (kind) {
                .move => if (window) |win| {
                    Nile.Seat.focusWindow(seat, win);
                    Nile.Window.raiseToTop(win);
                    Nile.Seat.opStartMove(seat, win);
                },
                .resize => if (window) |win| {
                    Nile.Seat.focusWindow(seat, win);
                    Nile.Window.raiseToTop(win);
                    Nile.Window.setResizing(win, true);
                    Nile.Seat.opStartResize(seat, win, edges);
                },
                .normal => if (window) |win| {
                    Nile.Seat.focusWindow(seat, win);
                    Nile.Window.raiseToTop(win);
                },
            },
            .released => switch (kind) {
                .move, .resize => {
                    if (seat.op) |op| if (op.window) |ref| if (ref.get()) |win| if (kind == .resize) Nile.Window.setResizing(win, false);
                    Nile.Seat.opEnd(seat);
                },
                .normal => {},
            },
            else => {},
        }
    }

    fn onPointerMotion(self: *SimpleCompositor, seat: *@import("Seat.zig"), x: f64, y: f64, dx: f64, dy: f64, time_msec: u32) void {
        _ = self;
        _ = dx;
        _ = dy;
        _ = time_msec;
        if (seat.op) |op| if (op.window) |ref| if (ref.get()) |win| {
            switch (op.kind) {
                .move => {
                    const new_x = op.win_x + @as(i32, @intFromFloat(x)) - op.start_x;
                    const new_y = op.win_y + @as(i32, @intFromFloat(y)) - op.start_y;
                    // Grabbed window never animates
                    Nile.Window.setPosition(win, new_x, new_y, false);
                    Nile.dirtyRendering();
                },
                .resize => {
                    var new_w: i32 = @intCast(op.win_width);
                    var new_h: i32 = @intCast(op.win_height);
                    var new_x = op.win_x;
                    var new_y = op.win_y;
                    const delta_x = @as(i32, @intFromFloat(x)) - op.start_x;
                    const delta_y = @as(i32, @intFromFloat(y)) - op.start_y;
                    if (op.edges.right) new_w += delta_x;
                    if (op.edges.left) {
                        new_w -= delta_x;
                        new_x += delta_x;
                    }
                    if (op.edges.bottom) new_h += delta_y;
                    if (op.edges.top) {
                        new_h -= delta_y;
                        new_y += delta_y;
                    }
                    if (new_w < 20) new_w = 20;
                    if (new_h < 20) new_h = 20;
                    Nile.Window.setPosition(win, new_x, new_y, false);
                    Nile.Window.setDimensions(win, @intCast(new_w), @intCast(new_h), false);
                    Nile.dirtyWindowingLazy();
                    Nile.dirtyRendering();
                },
                .normal => {},
            }
        };
    }

    fn onFrame(self: *SimpleCompositor) void {
        _ = self;
        // Periodic tick — use for animations or deferred work. No-op by default.
    }
};

// Re-export for doc convenience — so Nile.SimpleCompositor works
pub const Instance = SimpleCompositor;
