// SPDX-FileCopyrightText: © 2026 The Nile Developers
// SPDX-License-Identifier: GPL-3.0-only

//! NileCompositor — example compositor that shows how to use the struct+Event API.
//!
//! This is the default policy compiled into `nile`. Replace it with your own
//! by writing a struct with `pub fn handle(self: *MyCompositor, event: Event) void`
//! and calling `Nile.setCompositor(Compositor.initCompositor(MyCompositor, &instance))`.
//!
//! The struct owns all policy. Events you don't care about are ignored with `else => {}`.
//! Control is via `Nile.*` calls inside `handle` — e.g. `Nile.Window.setPosition`.

const std = @import("std");
const Nile = @import("Nile.zig");
const Compositor = @import("Compositor.zig");
const Window = @import("Window.zig");
const Output = @import("Output.zig");
const XkbBinding = @import("XkbBinding.zig");

pub const Box = struct {
    w: u32,
    h: u32,
    x: u32,
    y: u32,

    pub fn contains(self: *const Box, other: *const Box) bool {
        return (self.x <= other.x and self.y <= other.y and self.x + self.w >= other.x + other.w and self.y + self.h >= other.y + other.h);
    }
};

const log = std.log.scoped(.wm);

pub const Node = union(enum) {
    leaf: *Window,
    branch: Branch,

    const Orientation = enum { horizontal, vertical };

    pub const Branch = struct {
        first: *Node,
        second: *Node,
        orientation: Orientation,
        /// first item ratio in the split
        /// can be changed via resize
        ratio: f64 = 0.5,
    };

    pub fn getNode(self: *Node, x: u32, y: u32) *Node {
        switch (self.*) {
            .leaf => return self,
            .branch => |b| {
                const n1 = b.first.getNode(x, y);
                const n2 = b.second.getNode(x, y);
                std.debug.assert(n1.* == .leaf);
                std.debug.assert(n2.* == .leaf);
                if (n1.leaf.box.x + n1.leaf.box.width > x and n1.leaf.box.y + n1.leaf.box.height > y and n1.leaf.box.x <= x and n1.leaf.box.y <= y) {
                    return n1;
                } else {
                    return n2;
                }
            },
        }
    }

    pub fn pop(self: *Node, first: bool) void {
        std.debug.assert(self.* == .branch);
        if (first) {
            self.* = self.branch.second.*;
        } else {
            self.* = self.branch.first.*;
        }
    }

    pub fn getBox(self: *const Node) Box {
        var box: Box = .{
            .y = 0,
            .x = 0,
            .w = 0,
            .h = 0,
        };
        switch (self.*) {
            .leaf => |win| {
                box = .{
                    .w = @intCast(win.box.width),
                    .h = @intCast(win.box.height),
                    .x = @intCast(win.box.x),
                    .y = @intCast(win.box.y),
                };
            },
            .branch => |b| {
                const b1 = b.first.getBox();
                box.w += b1.w;
                box.h += b1.h;
                if (b1.x < box.x)
                    box.x = b1.x;
                if (b1.y < box.y)
                    box.y = b1.y;
                const b2 = b.second.getBox();
                box.w += b2.w;
                box.h += b2.h;
                if (b2.x < box.x)
                    box.x = b2.x;
                if (b2.y < box.y)
                    box.y = b2.y;
            },
        }
        return box;
    }

    pub fn parentOf(self: *Node, other: *Node) *Node {
        if (self.* == .leaf)
            return self;

        const b = other.getBox();
        const b1 = self.branch.first.getBox();

        const ret = if (b1.contains(&b))
            self.branch.first.parentOf(other)
        else
            self.branch.second.parentOf(other);

        if (ret.* == .leaf)
            return self;

        return ret;
    }

    /// Remove all windows that don't exist in the tree
    pub fn nullify(self: *Node, wins: []const *Window) bool {
        if (wins.len == 0)
            return true;
        switch (self.*) {
            .branch => |b| {
                const b1 = b.first.nullify(wins);
                const b2 = b.second.nullify(wins);
                if (!b1 and !b2)
                    return true;
                if (!b1) self.pop(true);
                if (!b2) self.pop(false);
            },
            .leaf => |l| {
                for (wins) |w| {
                    if (l == w)
                        return false;
                }
            },
        }
        return true;
    }

    /// add a new leaf to the tree
    pub fn append(self: *Node, alloc: std.mem.Allocator, new: *Window, orientation: ?Orientation) void {
        switch (self.*) {
            .leaf => |l| {
                const b1 = Box{
                    .x = @intCast(l.box.x),
                    .y = @intCast(l.box.y),
                    .w = @intCast(if (orientation == .horizontal) @divFloor(l.box.width, 2) else l.box.width),
                    .h = @intCast(if (orientation == .vertical) @divFloor(l.box.height, 2) else l.box.height),
                };
                const n = alloc.create(Node) catch unreachable;
                n.* = .{ .leaf = new };
                const no = alloc.create(Node) catch unreachable;
                no.* = self.*;
                if (b1.contains(&.{
                    .x = @intCast(new.box.x),
                    .y = @intCast(new.box.y),
                    .w = 0,
                    .h = 0,
                })) {
                    self.* = .{ .branch = .{
                        .first = n,
                        .second = no,
                        .orientation = orientation orelse .horizontal,
                    } };
                } else {
                    self.* = .{ .branch = .{
                        .first = no,
                        .second = n,
                        .orientation = orientation orelse .horizontal,
                    } };
                }
            },
            .branch => |b| {
                const b1 = b.first.getBox();
                if (b1.contains(&.{
                    .x = @intCast(new.box.x),
                    .y = @intCast(new.box.y),
                    .w = 0,
                    .h = 0,
                })) {
                    b.first.append(alloc, new, if (b.orientation == .horizontal) .vertical else .horizontal);
                } else {
                    b.second.append(alloc, new, if (b.orientation == .horizontal) .vertical else .horizontal);
                }
            },
        }
    }
};

pub fn construct(alloc: std.mem.Allocator, wins: []const *Window) ?Node {
    if (wins.len == 0)
        return null;
    var n: ?Node = null;
    for (wins) |win| {
        if (n == null) {
            n = .{ .leaf = win };
            continue;
        }
        const ls = n.?.leaf.box.width * n.?.leaf.box.height;
        const cs = win.box.width * win.box.height;
        if (ls < cs)
            n.?.leaf = win;
    }
    var cur = true;
    for (wins) |win| {
        defer cur = !cur;
        if (n.? == .leaf and n.?.leaf == win)
            continue;
        const node = n.?.getNode(@intCast(win.box.x), @intCast(win.box.y));
        const dist_start = @sqrt(@as(f64, @floatFromInt((std.math.pow(
            c_int,
            node.leaf.box.x - win.box.x,
            2,
        ) + std.math.pow(
            c_int,
            node.leaf.box.y - win.box.y,
            2,
        )))));
        const dist_end =
            @sqrt(@as(f64, @floatFromInt(std.math.pow(
                c_int,
                win.box.x - (node.leaf.box.x + node.leaf.box.width),
                2,
            ) + std.math.pow(
                c_int,
                win.box.y - (node.leaf.box.height + node.leaf.box.y),
                2,
            ))));
        const nnode = alloc.create(Node) catch unreachable;
        nnode.* = .{ .leaf = win };
        if (dist_start > dist_end) {
            node.* = .{ .branch = .{
                .first = node,
                .second = nnode,
                .orientation = if (cur) .horizontal else .vertical,
            } };
        } else {
            node.* = .{ .branch = .{
                .first = nnode,
                .second = node,
                .orientation = if (cur) .horizontal else .vertical,
            } };
        }
    }
    return n;
}

pub const NileCompositor = struct {
    arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator),
    gpa: std.mem.Allocator = undefined,
    root: ?Node = null,

    pub fn init(self: *NileCompositor) void {
        log.info("initialized window manager", .{});
        self.gpa = self.arena.allocator();
    }

    pub fn deinit(self: *NileCompositor) void {
        self.arena.deinit();
    }

    pub fn handle(self: *NileCompositor, event: Compositor.Event) void {
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

    fn onWindowAdd(self: *NileCompositor, win: *Window) void {
        log.info("window add (ready): {?s}", .{win.getTitle()});
        const out = Nile.Output.primary() orelse return;
        const box = Nile.Output.effectiveBox(out);
        if (self.root) |*r| {
            r.append(self.gpa, win, null);
            log.debug("New node: {}", .{@intFromPtr(r.getNode(
                @intCast(win.box.x),
                @intCast(win.box.y),
            ))});
            arrangeNode(.{
                .x = 0,
                .y = 0,
                .w = @intCast(box.width),
                .h = @intCast(box.height),
            }, &self.root.?);
        } else {
            log.debug("Rebuilding root", .{});
            self.arrange();
        }
    }

    fn onWindowMap(self: *NileCompositor, win: *Window) void {
        _ = self;
        Nile.Window.focus(win);
    }

    fn onWindowUnmap(self: *NileCompositor, win: *Window) void {
        _ = self;
        _ = win;
    }

    fn onWindowDestroy(self: *NileCompositor, win: *Window) void {
        if (self.root.? == .leaf)
            self.root = null;
        if (self.root) |*r| {
            const p = r.parentOf(
                r.getNode(@intCast(win.box.x), @intCast(win.box.y)),
            );
            p.pop(p.branch.first.* == .leaf and p.branch.first.leaf == win);
        }
    }

    fn onOutputAdd(self: *NileCompositor, out: *Output) void {
        if (out.wlr_output) |wlr_out| log.info("output added: {s}", .{wlr_out.name});
        self.arrange();
    }

    fn onOutputRemove(self: *NileCompositor, out: *Output) void {
        _ = self;
        _ = out;
        log.info("output removed", .{});
    }

    fn onOutputUpdate(self: *NileCompositor, out: *Output) void {
        if (out.wlr_output) |wlr_out| log.info("output updated: {s}", .{wlr_out.name});
        self.arrange();
    }

    fn onKeybindPressed(self: *NileCompositor, binding: *XkbBinding) void {
        _ = self;
        _ = binding;
        // Example: close focused window on Mod+Q (if you bound it)
        // if (binding.keysym == .q) { if (Nile.Seat.default().focused == .window) |w| Nile.Window.close(w); }
    }

    /// Arrange all windows. Replaces the current root.
    pub fn arrange(self: *NileCompositor) void {
        const out = Nile.Output.primary() orelse return;
        const box = Nile.Output.effectiveBox(out);
        if (box.width == 0 or box.height == 0) return;
        var wins = std.ArrayList(*Window).empty;
        var it = Nile.Window.iter();
        while (it.next()) |win| {
            wins.append(self.gpa, win) catch unreachable;
        }
        if (wins.items.len == 0) return;
        self.root = construct(self.gpa, wins.items);
        if (self.root) |r| {
            arrangeNode(.{
                .x = 0,
                .y = 0,
                .w = @intCast(box.width),
                .h = @intCast(box.height),
            }, &r);
        }
        Nile.dirtyWindowing();
        Nile.dirtyRendering();
    }

    fn arrangeNode(rbox: Box, n: *const Node) void {
        switch (n.*) {
            .leaf => |win| {
                Nile.Window.setPosition(win, @intCast(rbox.x), @intCast(rbox.y));
                Nile.Window.setDimensions(win, @intCast(rbox.w), @intCast(rbox.h));
            },
            .branch => |b| {
                switch (b.orientation) {
                    .vertical => {
                        arrangeNode(.{
                            .x = rbox.x,
                            .y = rbox.y,
                            .w = rbox.w,
                            .h = @floor(rbox.h * b.ratio),
                        }, b.first);
                        arrangeNode(.{
                            .x = rbox.x,
                            .y = @as(u32, @intFromFloat(rbox.y + @floor(rbox.h * b.ratio))),
                            .w = rbox.w,
                            .h = @as(u32, @intFromFloat(@floor(rbox.h * (1.0 - b.ratio)))),
                        }, b.second);
                    },
                    .horizontal => {
                        arrangeNode(.{
                            .x = rbox.x,
                            .y = rbox.y,
                            .w = @floor(rbox.w * b.ratio),
                            .h = rbox.h,
                        }, b.first);
                        arrangeNode(.{
                            .x = @as(u32, @intFromFloat(rbox.x + @floor(rbox.w * b.ratio))),
                            .y = rbox.y,
                            .w = @as(u32, @intFromFloat(@floor(rbox.w * (1.0 - b.ratio)))),
                            .h = rbox.h,
                        }, b.second);
                    },
                }
            },
        }
    }

    fn onFullscreen(self: *NileCompositor, win: *Window, output: ?*Output) void {
        _ = self;
        Nile.Window.setFullscreen(win, output);
    }

    fn onPointerButton(
        self: *NileCompositor,
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
        _ = x;
        _ = y;
        _ = time_msec;
        _ = button;
        switch (state) {
            .pressed => switch (kind) {
                .move => if (window) |win| {
                    log.info("pointer_button move pressed on {?s}", .{win.getTitle()});
                    Nile.Seat.focusWindow(seat, win);
                    Nile.Window.raiseToTop(win);
                    if (self.root == null or self.root.? == .leaf)
                        return;
                    Nile.Seat.opStartMove(seat, win);
                    const n = self.root.?.getNode(@intCast(win.box.x), @intCast(win.box.y));
                    const p = self.root.?.parentOf(n);
                    log.debug("parent: {}, node: {}", .{ @intFromPtr(p), @intFromPtr(n) });
                    p.pop(p.branch.first == n);
                },
                .resize => if (window) |win| {
                    log.info("pointer_button resize pressed edges={} on {?s}", .{ edges, win.getTitle() });
                    Nile.Seat.focusWindow(seat, win);
                    Nile.Window.raiseToTop(win);
                    Nile.Window.setResizing(win, true);
                    Nile.Seat.opStartResize(seat, win, edges);
                },
                .normal => if (window) |win| {
                    // Normal hold — focus clicked window
                    Nile.Seat.focusWindow(seat, win);
                    Nile.Window.raiseToTop(win);
                },
            },
            .released => switch (kind) {
                .move, .resize => {
                    // End interactive op (pointer release for move/resize)
                    if (seat.op) |op| if (op.window) |win| {
                        if (kind == .resize) Nile.Window.setResizing(win, false);
                        log.info("pointer_button {s} released", .{@tagName(kind)});
                        if (self.root) |*r| {
                            const n = r.getNode(@intCast(win.box.x), @intCast(win.box.y));
                            if (kind == .move) {
                                const rbox = Box{
                                    .w = @intCast(n.leaf.box.width),
                                    .h = @intCast(n.leaf.box.height),
                                    .x = @intCast(n.leaf.box.x),
                                    .y = @intCast(n.leaf.box.y),
                                };
                                n.* = construct(self.gpa, &.{ n.leaf, win }).?;
                                arrangeNode(rbox, n);
                            } else {}
                        } else {
                            self.root = .{ .leaf = win };
                        }
                    };
                    Nile.Seat.opEnd(seat);
                },
                .normal => {},
            },
            else => {},
        }
    }

    fn onPointerMotion(
        self: *NileCompositor,
        seat: *@import("Seat.zig"),
        x: f64,
        y: f64,
        delta_x: f64,
        delta_y: f64,
        time_msec: u32,
    ) void {
        _ = delta_y;
        _ = time_msec;
        if (seat.op) |op| if (op.window) |win| {
            switch (op.kind) {
                .move => {
                    const new_x = op.win_x + @as(i32, @intFromFloat(x)) - op.start_x;
                    const new_y = op.win_y + @as(i32, @intFromFloat(y)) - op.start_y;
                    Nile.Window.setPosition(win, new_x, new_y);
                    Nile.dirtyRendering();
                },
                .resize => {
                    const n = self.root.?.getNode(@intCast(win.box.x), @intCast(win.box.y));
                    const dx = @as(i32, @intFromFloat(x)) - op.start_x;
                    const dy = @as(i32, @intFromFloat(y)) - op.start_y;
                    if (dx == 0 and dy == 0)
                        return;
                    var parents = std.ArrayList(*Node).empty;
                    defer parents.deinit(self.gpa);
                    parents.append(self.gpa, n) catch unreachable;
                    while (parents.items.len != 0 and parents.items[parents.items.len - 1] != &self.root.?) {
                        parents.append(self.gpa, self.root.?.parentOf(&parents.items[parents.items.len - 1].*)) catch unreachable;
                    }
                    var iter = std.mem.reverseIterator(parents.items);
                    var i = parents.items.len - 1;
                    while (iter.next()) |p| : (i -= 1) {
                        if (i == 0) break;
                        var mul: i32 = -1;
                        if (p.branch.first == parents.items[i - 1]) {
                            mul = 1;
                        }
                        const box = p.getBox();
                        switch (p.branch.orientation) {
                            .horizontal => p.branch.ratio += @as(f64, @floatFromInt(dx)) / @as(f64, @floatFromInt(box.w)) * mul,
                            .vertical => p.branch.ratio += (@as(f64, @floatFromInt(dy)) / @as(f64, @floatFromInt(box.h))) * mul,
                        }
                    }
                    const out = Nile.Output.primary() orelse return;
                    arrangeNode(.{
                        .x = 0,
                        .y = 0,
                        .w = @intCast(out.current.box().width),
                        .h = @intCast(out.current.box().height),
                    }, &self.root.?);
                    Nile.dirtyWindowing();
                    Nile.dirtyRendering();
                },
                .normal => {},
            }
        } else {
            _ = delta_x;
        };
    }

    fn onFrame(self: *NileCompositor) void {
        _ = self;
    }
};

pub const Instance = NileCompositor;
