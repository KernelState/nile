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
const wlr = @import("wlroots");
const server = &@import("main.zig").server;
const xkb = @import("xkbcommon");
const Nile = @import("Nile.zig");
const Compositor = @import("Compositor.zig");
const Window = @import("Window.zig");
const Output = @import("Output.zig");
const XkbBinding = @import("XkbBinding.zig");
const Bank = @import("Bank.zig");

pub const Box = struct {
    w: i32,
    h: i32,
    x: i32,
    y: i32,

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

        /// Offset ratio by signed pixels delta, positive grows `first`.
        /// Clamped 0.05..0.95 so divider never collapses a child.
        /// Using pixel delta directly (not `delta / parent_dim`) keeps speed
        /// independent of tile size — large tiles no longer feel sluggish — and
        /// caller is responsible for only touching the immediate parent.
        pub fn offsetRatio(self: *Branch, delta_px: i32) void {
            // 0.002 ≈ 1/500; tuned so ~500px drag traverses full ratio range,
            // feels immediate and tracks mouse without the `delta/box` size-dependence.
            // For perfect 1:1 mouse tracking use `delta / parent_dim` instead.
            self.ratio += @as(f64, @floatFromInt(delta_px)) * 0.002;
            self.ratio = @max(0.05, @min(0.95, self.ratio));
        }

        /// Variant that is exactly 1:1 with mouse when parent dim is known.
        pub fn offsetRatioDim(self: *Branch, delta_px: i32, dim: i32) void {
            if (dim == 0) return;
            self.ratio += @as(f64, @floatFromInt(delta_px)) / @as(f64, @floatFromInt(dim));
            self.ratio = @max(0.05, @min(0.95, self.ratio));
        }

        /// Shallow shell: set ratio from absolute cursor vs parent (window-cursor difference).
        /// More accurate than delta accumulation — no drift. Caller provides cursor pos and parent box.
        pub fn setRatioFromCursor(self: *Branch, cursor_pos: f64, parent_pos: i32, parent_dim: i32) void {
            if (parent_dim == 0) return;
            const desired = (cursor_pos - @as(f64, @floatFromInt(parent_pos))) / @as(f64, @floatFromInt(parent_dim));
            self.ratio = @max(0.05, @min(0.95, desired));
        }
    };

    pub fn getNode(self: *Node, x: i32, y: i32) *Node {
        switch (self.*) {
            .leaf => return self,
            .branch => |b| {
                const b1 = b.first.getBox();
                const point = Box{ .x = x, .y = y, .w = 0, .h = 0 };
                if (b1.contains(&point)) {
                    return b.first.getNode(x, y);
                } else {
                    return b.second.getNode(x, y);
                }
            },
        }
    }

    /// Like getNode but uses allocated boxes from ratios/output_box, not stale window.box.
    /// Prevents misselection when windows are mid-animation (visual boxes lag final layout).
    pub fn getNodeAllocated(self: *Node, x: i32, y: i32, root: *const Node, output_box: Box) *Node {
        switch (self.*) {
            .leaf => return self,
            .branch => |b| {
                const first_box = root.allocatedBoxFor(b.first, output_box) orelse b.first.getBox();
                const point = Box{ .x = x, .y = y, .w = 0, .h = 0 };
                if (first_box.contains(&point)) {
                    return b.first.getNodeAllocated(x, y, root, output_box);
                } else {
                    return b.second.getNodeAllocated(x, y, root, output_box);
                }
            },
        }
    }

    /// Find the leaf node that contains `win` by pointer identity.
    /// Returns null if `win` is not in this subtree. No coordinate
    /// comparison — prevents misselection when boxes are stale or overlap.
    pub fn find(self: *Node, win: *Window) ?*Node {
        switch (self.*) {
            .leaf => |l| {
                if (l == win) return self;
                return null;
            },
            .branch => |b| {
                if (b.first.find(win)) |found| return found;
                return b.second.find(win);
            },
        }
    }

    /// Find the parent branch of `target` by pointer identity.
    /// `target` must be a direct node pointer inside this tree.
    pub fn findParent(self: *Node, target: *Node) ?*Node {
        switch (self.*) {
            .leaf => return null,
            .branch => |b| {
                if (b.first == target or b.second == target) return self;
                if (b.first.findParent(target)) |found| return found;
                return b.second.findParent(target);
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
        switch (self.*) {
            .leaf => |win| {
                return .{
                    .w = @intCast(win.box.width),
                    .h = @intCast(win.box.height),
                    .x = @intCast(win.box.x),
                    .y = @intCast(win.box.y),
                };
            },
            .branch => |b| {
                const b1 = b.first.getBox();
                const b2 = b.second.getBox();
                const min_x = @min(b1.x, b2.x);
                const min_y = @min(b1.y, b2.y);
                const max_x = @max(b1.x + b1.w, b2.x + b2.w);
                const max_y = @max(b1.y + b1.h, b2.y + b2.h);
                return .{
                    .x = min_x,
                    .y = min_y,
                    .w = max_x - min_x,
                    .h = max_y - min_y,
                };
            },
        }
    }

    /// Allocated box for `target` as given by current ratios and `rbox`.
    /// Unlike `getBox` (which reads stale `window.box`), this is computed
    /// from the tiling ratios so it has no transaction delay and never
    /// overshoots when the cursor crosses node boundaries.
    pub fn allocatedBoxFor(self: *const Node, target: *const Node, rbox: Box) ?Box {
        if (self == target) return rbox;
        switch (self.*) {
            .leaf => return null,
            .branch => |b| {
                const first_rbox: Box = switch (b.orientation) {
                    .vertical => .{
                        .x = rbox.x,
                        .y = rbox.y,
                        .w = rbox.w,
                        .h = @intFromFloat(@floor(@as(f64, @floatFromInt(rbox.h)) * b.ratio)),
                    },
                    .horizontal => .{
                        .x = rbox.x,
                        .y = rbox.y,
                        .w = @intFromFloat(@floor(@as(f64, @floatFromInt(rbox.w)) * b.ratio)),
                        .h = rbox.h,
                    },
                };
                const second_rbox: Box = switch (b.orientation) {
                    .vertical => .{
                        .x = rbox.x,
                        .y = @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(rbox.y)) + @as(f64, @floatFromInt(rbox.h)) * b.ratio))),
                        .w = rbox.w,
                        .h = @intFromFloat(@floor(@as(f64, @floatFromInt(rbox.h)) * (1.0 - b.ratio))),
                    },
                    .horizontal => .{
                        .x = @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(rbox.x)) + @as(f64, @floatFromInt(rbox.w)) * b.ratio))),
                        .y = rbox.y,
                        .w = @intFromFloat(@floor(@as(f64, @floatFromInt(rbox.w)) * (1.0 - b.ratio))),
                        .h = rbox.h,
                    },
                };
                if (b.first.allocatedBoxFor(target, first_rbox)) |box| return box;
                return b.second.allocatedBoxFor(target, second_rbox);
            },
        }
    }

    pub fn parentOf(self: *Node, other: *Node) *Node {
        if (self.findParent(other)) |p| return p;
        // Fallback for callers that expect a non-null return when
        // `other` is not found (e.g. construct path) — return self
        // so old leaf-check `if (ret.* == .leaf) return self` stays
        // compatible, but log for debugging.
        if (self.* == .leaf) return self;
        return self;
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
    /// drop_x/drop_y is the cursor position where the window was dropped (for tiling placement).
    /// orientation is the split direction for the new branch, or null for horizontal default.
    pub fn append(self: *Node, alloc: std.mem.Allocator, new: *Window, drop_x: i32, drop_y: i32) void {
        switch (self.*) {
            .leaf => |l| {
                const b1 = Box{
                    .x = @intCast(l.box.x),
                    .y = @intCast(l.box.y),
                    .w = @intCast(if (l.box.width > l.box.height) @divFloor(l.box.width, 2) else l.box.width),
                    .h = @intCast(if (l.box.height > l.box.width) @divFloor(l.box.height, 2) else l.box.height),
                };
                const n = alloc.create(Node) catch unreachable;
                n.* = .{ .leaf = new };
                const no = alloc.create(Node) catch unreachable;
                no.* = self.*;
                if (b1.contains(&.{
                    .x = drop_x,
                    .y = drop_y,
                    .w = 0,
                    .h = 0,
                })) {
                    self.* = .{ .branch = .{
                        .first = n,
                        .second = no,
                        .orientation = if (l.box.width > l.box.height) .horizontal else .vertical,
                    } };
                } else {
                    self.* = .{ .branch = .{
                        .first = no,
                        .second = n,
                        .orientation = if (l.box.width > l.box.height) .horizontal else .vertical,
                    } };
                }
            },
            .branch => |b| {
                const b1 = b.first.getBox();
                if (b1.contains(&.{
                    .x = drop_x,
                    .y = drop_y,
                    .w = 0,
                    .h = 0,
                })) {
                    b.first.append(alloc, new, drop_x, drop_y);
                } else {
                    b.second.append(alloc, new, drop_x, drop_y);
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
        const old = alloc.create(Node) catch unreachable;
        old.* = node.*;
        if (dist_start > dist_end) {
            node.* = .{ .branch = .{
                .first = old,
                .second = nnode,
                .orientation = if (cur) .horizontal else .vertical,
            } };
        } else {
            node.* = .{ .branch = .{
                .first = nnode,
                .second = old,
                .orientation = if (cur) .horizontal else .vertical,
            } };
        }
    }
    return n;
}

pub const NileCompositor = struct {
    arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator),
    gpa: std.mem.Allocator = undefined,
    /// One tiling tree per workspace (index `id - 1`). Switching workspaces
    /// only swaps which tree is laid out — trees are never rebuilt, so each
    /// workspace keeps its splits/ratios across switches.
    roots: [ws_count]?Node = [_]?Node{null} ** ws_count,

    const ws_count: usize = @import("Workspace.zig").Manager.fixed_count;

    /// Tree for the currently visible workspace.
    fn cur(self: *NileCompositor) *?Node {
        return self.rootFor(server.workspace.currentWorkspace());
    }

    /// Tree for workspace `id`. Unknown ids fall back to current.
    fn rootFor(self: *NileCompositor, id: u64) *?Node {
        if (id >= 1 and id - 1 < ws_count) return &self.roots[@intCast(id - 1)];
        return &self.roots[curIdx()];
    }

    fn curIdx() usize {
        const id = server.workspace.currentWorkspace();
        if (id < 1 or id - 1 >= ws_count) return 0;
        return @intCast(id - 1);
    }

    pub fn init(self: *NileCompositor) void {
        log.info("initialized window manager", .{});
        self.gpa = self.arena.allocator();
        self.registerWorkspaceBindings();
    }

    pub fn deinit(self: *NileCompositor) void {
        self.arena.deinit();
    }

    /// MOD + 1..9 switches to workspace <num>. MOD+Shift+1..9 moves the
    /// focused window to workspace <num>. MOD is Alt when nested, Super/logo
    /// on DRM/KMS (see `util.modMask`). All 9 workspaces are created at startup
    /// and always exist — no on-demand creation here.
    fn registerWorkspaceBindings(self: *NileCompositor) void {
        _ = self;
        const seat = Nile.Seat.default();
        const mod = @import("util.zig").modMask();
        var shift_mod = mod;
        shift_mod.shift = true;
        const keys = [_]xkb.Keysym{
            xkb.Keysym.@"1",
            xkb.Keysym.@"2",
            xkb.Keysym.@"3",
            xkb.Keysym.@"4",
            xkb.Keysym.@"5",
            xkb.Keysym.@"6",
            xkb.Keysym.@"7",
            xkb.Keysym.@"8",
            xkb.Keysym.@"9",
        };
        for (keys) |sym| {
            const binding = Nile.Seat.addXkbBinding(seat, sym, mod) catch |err| {
                log.warn("failed to register workspace binding: {}", .{err});
                continue;
            };
            _ = binding;
            const move_binding = Nile.Seat.addXkbBinding(seat, sym, shift_mod) catch |err| {
                log.warn("failed to register move-to-workspace binding: {}", .{err});
                continue;
            };
            _ = move_binding;
        }
        // MOD+v: toggle current workspace tiling/floating
        {
            const b = Nile.Seat.addXkbBinding(seat, xkb.Keysym.v, mod) catch |err| {
                log.warn("failed to register workspace mode toggle binding: {}", .{err});
                return;
            };
            _ = b;
        }
        // MOD+f: toggle focused window forced-floating
        {
            const b = Nile.Seat.addXkbBinding(seat, xkb.Keysym.f, mod) catch |err| {
                log.warn("failed to register window floating toggle binding: {}", .{err});
                return;
            };
            _ = b;
        }
    }

    /// Switch to the workspace with human number `num` (1..9).
    /// The fixed set always exists — out-of-range numbers and missing
    /// workspaces are ignored, never created. Layout of the restored tree
    /// happens via the `workspace_switched` event (no rebuild).
    fn switchToWorkspaceNumber(self: *NileCompositor, num: u64) void {
        _ = self;
        if (num < 1 or num > @import("Workspace.zig").Manager.fixed_count) return;
        const id = server.workspace.idForNumber(num) orelse {
            log.warn("workspace {d} does not exist", .{num});
            return;
        };
        _ = server.workspace.switchWorkspace(id) catch |err| {
            log.warn("failed to switch workspace {d}: {}", .{ num, err });
            return;
        };
    }

    /// Move the currently focused window to workspace <num>.
    /// If no window is focused or the target is the current workspace, no-op.
    fn moveFocusedWindowToWorkspace(self: *NileCompositor, num: u64) void {
        _ = self;
        if (num < 1 or num > @import("Workspace.zig").Manager.fixed_count) return;
        const target_id = server.workspace.idForNumber(num) orelse {
            log.warn("workspace {d} does not exist", .{num});
            return;
        };
        const seat = Nile.Seat.default();
        const win: *Window = switch (seat.focused) {
            .window => |w| w,
            else => {
                log.info("move to workspace {d}: no focused window", .{num});
                return;
            },
        };
        if (win.wm_requested.workspace == target_id) return;
        server.workspace.moveWindowToWorkspace(win, target_id) catch |err| {
            log.warn("failed to move window to workspace {d}: {}", .{ num, err });
            return;
        };
        // If we moved the focused window away from the current workspace it
        // becomes hidden. Clear focus and focus the next window on the current
        // workspace so keyboard doesn't stay on a hidden window.
        if (target_id != server.workspace.currentWorkspace()) {
            var it = Nile.Window.iter();
            var next: ?*Window = null;
            const cur_ws = server.workspace.currentWorkspace();
            while (it.next()) |w| {
                if (w == win) continue;
                if (w.wm_requested.workspace != cur_ws) continue;
                if (w.state != .mapped) continue;
                next = w;
                break;
            }
            if (next) |n| {
                Nile.Seat.focusWindow(seat, n);
            } else {
                Nile.Seat.clearFocus(seat);
            }
        }
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
            .window_maximize_request => |req| self.onMaximize(req.window, req.maximize),
            .workspace_switched => |v| self.onWorkspaceSwitched(v.old_id, v.new_id),
            .window_workspace_changed => |v| self.onWindowWorkspaceChanged(v.window, v.old_id, v.new_id),
            .workspace_mode_changed => |v| self.onWorkspaceModeChanged(v.id, v.mode),
            .window_floating_changed => |win| self.onWindowFloatingChanged(win),
            .window_focus_changed => |v| self.onWindowFocusChanged(v.old, v.new),
            .pointer_motion => |ev| self.onPointerMotion(ev.seat, ev.x, ev.y, ev.dx, ev.dy, ev.time_msec),
            .pointer_button => |ev| self.onPointerButton(ev.seat, ev.window, ev.button, ev.state, ev.x, ev.y, ev.kind, ev.edges, ev.time_msec),
            .frame => self.onFrame(),
            else => {}, // ignore everything else (title/app_id/parent/minimize etc.)
        }
    }

    fn onWindowFocusChanged(self: *NileCompositor, old: ?*Window, new: ?*Window) void {
        _ = old;
        if (new) |win| {
            if (win.isEffectivelyFloating()) {
                self.raiseFloatingWindows();
                // Stale focus order race: Bank hasn't yet moved `win` to front when this handler runs
                // (CompositorNotifies global before broadcast_hook). Ensure newly focused is truly top.
                Nile.Window.raiseToTop(win);
                Nile.dirtyRendering();
            }
        }
    }

    fn onWindowAdd(self: *NileCompositor, win: *Window) void {
        log.info("window add (ready): {?s}", .{win.getTitle()});
        // New windows open on the current workspace (they default to id 1).
        const current_ws = server.workspace.currentWorkspace();
        win.wm_requested.workspace = current_ws;
        // If workspace is floating or window is forced-floating, don't tile it
        if (win.isEffectivelyFloating()) {
            log.debug("Window added as floating (workspace mode {s}, forced {any})", .{ @tagName(server.workspace.getEffectiveMode(current_ws)), win.floating });
            self.ensureFloatingPosition(win);
            // Ensure it's on top after layout
            self.layoutCurrent();
            Nile.Window.raiseToTop(win);
            self.raiseFloatingWindows();
            return;
        }
        if (self.cur().*) |*r| {
            const drop_x: i32 = @intCast(@max(0, win.box.x));
            const drop_y: i32 = @intCast(@max(0, win.box.y));
            r.append(self.gpa, win, drop_x, drop_y);
            if (r.find(win)) |node| {
                log.debug("New node: {}", .{@intFromPtr(node)});
            }
            self.layoutTree(r);
        } else {
            log.debug("First window on workspace, creating root", .{});
            self.cur().* = .{ .leaf = win };
            self.layoutCurrent();
        }
        self.raiseFloatingWindows();
    }

    fn onWindowMap(self: *NileCompositor, win: *Window) void {
        const current_ws = server.workspace.currentWorkspace();
        if (win.wm_requested.workspace != current_ws) {
            win.rendering_requested.hidden = true;
            return;
        }
        _ = self;
        Nile.Window.focus(win);
    }

    fn onWindowUnmap(self: *NileCompositor, win: *Window) void {
        _ = self;
        _ = win;
    }

    fn onWindowDestroy(self: *NileCompositor, win: *Window) void {
        // The window knows its workspace; detach it from that tree so the
        // other workspaces' tilings are untouched.
        const root = self.rootFor(win.wm_requested.workspace);
        const ws_id = win.wm_requested.workspace;
        if (root.*) |*r| {
            if (r.* == .leaf) {
                if (r.leaf == win) {
                    root.* = null;
                    log.debug("Root deleted", .{});
                }
                return;
            }
            // Pointer identity: find node that owns `win`, no coordinates.
            const n = r.find(win) orelse return;
            const p = r.findParent(n) orelse return;
            const is_first = p.branch.first == n;
            p.pop(is_first);
            if (root == self.cur()) {
                const mode = server.workspace.getEffectiveMode(ws_id);
                if (mode == .floating) {
                    self.layoutCurrent();
                } else {
                    self.layoutTree(r);
                }
            }
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
        // MOD+v: toggle workspace tiling/floating (no shift)
        if (binding.keysym == xkb.Keysym.v) {
            const mods: @import("wlroots").Keyboard.ModifierMask = @bitCast(binding.modifiers);
            if (!mods.shift) {
                log.info("workspace keybinding: toggle tiling/floating", .{});
                self.toggleCurrentWorkspaceMode();
                return;
            }
        }
        // MOD+f: toggle focused window forced-floating (no shift)
        if (binding.keysym == xkb.Keysym.f) {
            const mods: @import("wlroots").Keyboard.ModifierMask = @bitCast(binding.modifiers);
            if (!mods.shift) {
                log.info("window keybinding: toggle floating", .{});
                self.toggleFocusedWindowFloating();
                return;
            }
        }
        const num: u64 = switch (binding.keysym) {
            xkb.Keysym.@"1" => 1,
            xkb.Keysym.@"2" => 2,
            xkb.Keysym.@"3" => 3,
            xkb.Keysym.@"4" => 4,
            xkb.Keysym.@"5" => 5,
            xkb.Keysym.@"6" => 6,
            xkb.Keysym.@"7" => 7,
            xkb.Keysym.@"8" => 8,
            xkb.Keysym.@"9" => 9,
            // MOD+0 is unbound — Nile has exactly 9 workspaces.
            else => return,
        };
        const mods: @import("wlroots").Keyboard.ModifierMask = @bitCast(binding.modifiers);
        if (mods.shift) {
            log.info("workspace keybinding: move focused window to {d}", .{num});
            self.moveFocusedWindowToWorkspace(num);
        } else {
            log.info("workspace keybinding: switch to {d}", .{num});
            self.switchToWorkspaceNumber(num);
        }
    }

    fn toggleCurrentWorkspaceMode(self: *NileCompositor) void {
        const cur_id = server.workspace.currentWorkspace();
        const new_mode = server.workspace.toggleWorkspaceMode(cur_id) catch |err| {
            log.warn("failed to toggle workspace mode: {}", .{err});
            return;
        };
        log.info("workspace {d} mode -> {s}", .{ cur_id, @tagName(new_mode) });
        // Reconcile tiling tree membership: floating->tiling needs to re-insert
        // windows that were floating only due to workspace mode, tiling->floating
        // leaves positions as-is (no removal needed).
        if (new_mode == .tiling) {
            self.ensureCurrentTree();
        }
        self.layoutCurrent();
        self.raiseFloatingWindows();
        Nile.dirtyWindowing();
        Nile.dirtyRendering();
    }

    fn resolveFloatingTarget(self: *NileCompositor, seat: *@import("Seat.zig")) ?*Window {
        _ = self;
        switch (seat.focused) {
            .window => |w| return w,
            .layer_surface => {
                // Shell has focus via MOD-tap — act on the window that was focused before detour.
                // Defer until MOD release so input is still copied to shell and we float THAT window.
                if (seat.shell_mod.focus_from_mod) {
                    switch (seat.shell_mod.prev) {
                        .window => |ref| if (ref.get()) |prev_win| {
                            // Mark for deferred toggle; Seat.shellModTap will consume on release
                            prev_win.requestToggleFloating();
                            log.info("toggle floating deferred to MOD release for window {?s}", .{prev_win.getTitle()});
                            return null;
                        },
                        else => {},
                    }
                }
                // Fallback: if shell focused without MOD-tap, try prev anyway immediately
                switch (seat.shell_mod.prev) {
                    .window => |ref| if (ref.get()) |prev_win| return prev_win,
                    else => {},
                }
                return null;
            },
            else => {
                if (seat.shell_mod.focus_from_mod) {
                    switch (seat.shell_mod.prev) {
                        .window => |ref| if (ref.get()) |prev_win| {
                            prev_win.requestToggleFloating();
                            log.info("toggle floating deferred to MOD release for window {?s}", .{prev_win.getTitle()});
                            return null;
                        },
                        else => {},
                    }
                }
                return null;
            },
        }
    }

    fn toggleFocusedWindowFloating(self: *NileCompositor) void {
        const seat = Nile.Seat.default();
        const win = self.resolveFloatingTarget(seat) orelse {
            log.info("toggle floating: no target window (deferred or none)", .{});
            return;
        };
        const was_floating = win.floating;
        const now_floating = win.toggleFloating();
        log.info("window {?s} floating {} -> {}", .{ win.getTitle(), was_floating, now_floating });
        if (now_floating) {
            // Capture tiling position before removal for offset placement
            const tiling_box = win.box;
            win.ensureFloatingRestoreBox();
            // Move from tiling tree to floating: remove from tree if present
            const root = self.rootFor(win.wm_requested.workspace);
            if (root.*) |*r| {
                if (r.find(win)) |n| {
                    if (r.* == .leaf) {
                        root.* = null;
                    } else if (r.findParent(n)) |p| {
                        p.pop(p.branch.first == n);
                        if (root == self.cur()) {
                            const m = server.workspace.getEffectiveMode(win.wm_requested.workspace);
                            if (m == .floating) self.layoutCurrent() else self.layoutTree(r);
                        }
                    }
                }
            }
            // Place near previous tiling position with offset so it visibly pops out, using natural size
            {
                var count: i32 = 0;
                var it = Nile.Window.iter();
                while (it.next()) |other| {
                    if (other == win) continue;
                    if (other.wm_requested.workspace != win.wm_requested.workspace) continue;
                    if (!other.isEffectivelyFloating()) continue;
                    if (other.state != .mapped and other.state != .initialized and other.state != .ready) continue;
                    count += 1;
                }
                // Restore tiling box temporarily for placeTiledAsFloating (which uses win.box as base)
                const saved_box = win.box;
                win.box = tiling_box;
                self.placeTiledAsFloating(win, count);
                // If place didn't change (box was zero), fallback to ensure
                if (win.box.x == tiling_box.x and win.box.y == tiling_box.y and tiling_box.width != 0) {
                    _ = saved_box;
                }
            }
            Nile.Window.raiseToTop(win);
        } else {
            // Move from floating to tiling (only if workspace is tiling)
            const ws_mode = server.workspace.getEffectiveMode(win.wm_requested.workspace);
            if (ws_mode == .floating) {
                // Workspace itself is floating: window remains effectively floating; nothing to tile
                Nile.Window.raiseToTop(win);
            } else {
                const root = self.rootFor(win.wm_requested.workspace);
                if (root.*) |*r| {
                    if (r.find(win) == null) {
                        const drop_x: i32 = @intCast(@max(0, win.box.x));
                        const drop_y: i32 = @intCast(@max(0, win.box.y));
                        r.append(self.gpa, win, drop_x, drop_y);
                    }
                } else {
                    root.* = .{ .leaf = win };
                }
                if (root == self.cur()) self.layoutCurrent();
            }
        }
        self.raiseFloatingWindows();
        Nile.dirtyWindowing();
        Nile.dirtyRendering();
    }

    fn ensureFloatingPosition(self: *NileCompositor, win: *Window) void {
        _ = self;
        // If window already has a sane box, keep it. Otherwise center on primary output (with cascade offset so multiple floatings overlap but are visible).
        if (win.box.width != 0 and win.box.height != 0 and win.box.x != 0 and win.box.y != 0) return;
        win.ensureFloatingRestoreBox();
        const out = Nile.Output.primary() orelse return;
        const nea = Nile.Layer.nonExclusiveArea(out);
        if (nea.width == 0 or nea.height == 0) return;
        var w: i32 = if (win.box.width != 0) win.box.width else 0;
        var h: i32 = if (win.box.height != 0) win.box.height else 0;
        if (w == 0 or h == 0) {
            if (win.floating_restore_box) |fb| {
                w = if (w == 0) fb.width else w;
                h = if (h == 0) fb.height else h;
            } else {
                w = if (w == 0) @min(800, @divTrunc(nea.width * 3, 4)) else w;
                h = if (h == 0) @min(600, @divTrunc(nea.height * 3, 4)) else h;
            }
        }
        var x: i32 = nea.x + @divTrunc(nea.width - w, 2);
        var y: i32 = nea.y + @divTrunc(nea.height - h, 2);
        // Cascade offset based on number of other floating windows on same workspace so newcomers don't exactly cover previous
        {
            var count: i32 = 0;
            var it = Nile.Window.iter();
            while (it.next()) |other| {
                if (other == win) continue;
                if (other.wm_requested.workspace != win.wm_requested.workspace) continue;
                if (!other.isEffectivelyFloating()) continue;
                if (other.state != .mapped and other.state != .initialized and other.state != .ready) continue;
                count += 1;
            }
            x += count * 24;
            y += count * 24;
            // Keep within output (wrap if exceeds)
            if (x + w > nea.x + nea.width) x = nea.x + 20;
            if (y + h > nea.y + nea.height) y = nea.y + 20;
        }
        Nile.Window.setPosition(win, x, y, false);
        if (win.box.width == 0 or win.box.height == 0) {
            Nile.Window.setDimensions(win, @intCast(w), @intCast(h), false);
        } else {
            // Ensure position is applied; dimensions already known
            Nile.dirtyWindowing();
            Nile.dirtyRendering();
        }
    }

    /// Place a tiled window that is becoming floating near its tiling position with a small offset
    /// so it visibly pops out of layout. Uses natural size if available.
    fn placeTiledAsFloating(self: *NileCompositor, win: *Window, cascade_idx: i32) void {
        _ = self;
        win.ensureFloatingRestoreBox();
        const out = Nile.Output.primary() orelse return;
        const nea = Nile.Layer.nonExclusiveArea(out);
        if (nea.width == 0 or nea.height == 0) return;
        // Keep tiling position as base but offset to show it's out of layout
        const base_x = win.box.x;
        const base_y = win.box.y;
        var w: i32 = win.box.width;
        var h: i32 = win.box.height;
        if (win.floating_restore_box) |fb| {
            // Use natural size, not stretched tiling size, if we have it and it's reasonable
            if (fb.width != 0 and fb.height != 0 and (fb.width < win.box.width or fb.height < win.box.height or win.box.width == 0)) {
                w = fb.width;
                h = fb.height;
            }
        }
        if (w == 0) w = @min(800, @divTrunc(nea.width * 3, 4));
        if (h == 0) h = @min(600, @divTrunc(nea.height * 3, 4));
        // Clamp size to output exclusive zone (max = output - 40)
        if (nea.width > 40) w = @min(w, @as(i32, @intCast(nea.width - 40)));
        if (nea.height > 40) h = @min(h, @as(i32, @intCast(nea.height - 40)));
        var x: i32 = base_x + 20 + cascade_idx * 16;
        var y: i32 = base_y + 20 + cascade_idx * 16;
        // Clamp to output
        if (x + w > nea.x + nea.width) x = nea.x + nea.width - w - 20;
        if (y + h > nea.y + nea.height) y = nea.y + nea.height - h - 20;
        if (x < nea.x) x = nea.x + 20;
        if (y < nea.y) y = nea.y + 20;
        Nile.Window.setPosition(win, x, y, false);
        if (w != win.box.width or h != win.box.height) {
            Nile.Window.setDimensions(win, @intCast(w), @intCast(h), false);
        } else {
            Nile.dirtyWindowing();
            Nile.dirtyRendering();
        }
        // Update restore box to this new floating geometry for future maximize snap-back
        win.floating_box = .{ .x = x, .y = y, .width = w, .height = h };
        win.updateFloatingRestoreBox();
    }

    fn raiseFloatingWindows(self: *NileCompositor) void {
        _ = self;
        const cur_id = server.workspace.currentWorkspace();
        const focus_refs = Bank.focusOrderSlice();
        // First raise any floating windows that have never been focused (not in focus_order) — they go to bottom
        {
            var it = Nile.Window.iter();
            while (it.next()) |win| {
                if (win.wm_requested.workspace != cur_id) continue;
                if (!win.isEffectivelyFloating()) continue;
                if (win.state != .mapped) continue;
                var in_focus = false;
                for (focus_refs) |ref| {
                    if (ref.key.index == win.ref.key.index and ref.key.generation == win.ref.key.generation) {
                        in_focus = true;
                        break;
                    }
                }
                if (!in_focus) Nile.Window.raiseToTop(win);
            }
        }
        // Now raise in reverse focus order: least recent first, most recent (focused) last -> topmost
        var i = focus_refs.len;
        while (i > 0) {
            i -= 1;
            const ref = focus_refs[i];
            if (ref.get()) |win| {
                if (win.wm_requested.workspace != cur_id) continue;
                if (!win.isEffectivelyFloating()) continue;
                if (win.state != .mapped) continue;
                Nile.Window.raiseToTop(win);
            }
        }
    }

    fn cascadeTiledToFloating(self: *NileCompositor, workspace_id: u64) void {
        const focus_refs = Bank.focusOrderSlice();
        var idx: i32 = 0;
        // MRU first: idx 0 = focused (top), so offset 0 for top, increasing for behind windows
        for (focus_refs) |ref| {
            if (ref.get()) |win| {
                if (win.wm_requested.workspace != workspace_id) continue;
                if (win.floating) continue; // forced floating keeps its own position
                if (win.state != .mapped) continue;
                // Place near tiling position with small offset, using natural size
                self.placeTiledAsFloating(win, idx);
                idx += 1;
            }
        }
        // Windows not in focus order (never focused) — place at end of cascade
        {
            var it = Nile.Window.iter();
            while (it.next()) |win| {
                if (win.wm_requested.workspace != workspace_id) continue;
                if (win.floating) continue;
                if (win.state != .mapped) continue;
                var in_focus = false;
                for (focus_refs) |ref| {
                    if (ref.key.index == win.ref.key.index and ref.key.generation == win.ref.key.generation) {
                        in_focus = true;
                        break;
                    }
                }
                if (in_focus) continue;
                self.placeTiledAsFloating(win, idx);
                idx += 1;
            }
        }
    }

    fn onWorkspaceModeChanged(self: *NileCompositor, id: u64, mode: @import("Workspace.zig").Mode) void {
        // If not current workspace, just update future layout lazily
        if (id != server.workspace.currentWorkspace()) return;
        if (mode == .tiling) {
            self.ensureCurrentTree();
        } else {
            // tiling -> floating: cascade tiled windows so they visually overlap in focus order
            self.cascadeTiledToFloating(id);
        }
        self.layoutCurrent();
        self.raiseFloatingWindows();
        Nile.dirtyWindowing();
        Nile.dirtyRendering();
    }

    fn onWindowFloatingChanged(self: *NileCompositor, win: *Window) void {
        // Decoupled path: the Window.setFloating already toggled the bool,
        // but tiling tree membership must match. Reuse same logic as toggleFocused but for any window.
        // This is called for IPC-driven changes as well.
        const is_floating = win.floating;
        if (is_floating) {
            const tiling_box = win.box;
            win.ensureFloatingRestoreBox();
            const root = self.rootFor(win.wm_requested.workspace);
            if (root.*) |*r| {
                if (r.find(win)) |n| {
                    if (r.* == .leaf) {
                        root.* = null;
                    } else if (r.findParent(n)) |p| {
                        p.pop(p.branch.first == n);
                        if (root == self.cur()) {
                            const m = server.workspace.getEffectiveMode(win.wm_requested.workspace);
                            if (m == .floating) self.layoutCurrent() else self.layoutTree(r);
                        }
                    }
                }
            }
            // If window had a sane tiling box, offset it to show out-of-layout; otherwise fallback to centering
            if (tiling_box.width != 0 and tiling_box.height != 0) {
                var count: i32 = 0;
                var it = Nile.Window.iter();
                while (it.next()) |other| {
                    if (other == win) continue;
                    if (other.wm_requested.workspace != win.wm_requested.workspace) continue;
                    if (!other.isEffectivelyFloating()) continue;
                    if (other.state != .mapped and other.state != .initialized and other.state != .ready) continue;
                    count += 1;
                }
                win.box = tiling_box;
                self.placeTiledAsFloating(win, count);
            } else {
                self.ensureFloatingPosition(win);
            }
            Nile.Window.raiseToTop(win);
        } else {
            const ws_mode = server.workspace.getEffectiveMode(win.wm_requested.workspace);
            if (ws_mode == .tiling) {
                const root = self.rootFor(win.wm_requested.workspace);
                if (root.*) |*r| {
                    if (r.find(win) == null) {
                        const drop_x: i32 = @intCast(@max(0, win.box.x));
                        const drop_y: i32 = @intCast(@max(0, win.box.y));
                        r.append(self.gpa, win, drop_x, drop_y);
                    }
                } else {
                    root.* = .{ .leaf = win };
                }
                if (root == self.cur()) self.layoutCurrent();
            } else {
                Nile.Window.raiseToTop(win);
            }
        }
        self.raiseFloatingWindows();
        Nile.dirtyWindowing();
        Nile.dirtyRendering();
    }

    /// A workspace became visible. Its tree is restored as-is — apply its
    /// saved geometry without rebuilding, so switching never retiles.
    /// If workspace_switch animation is enabled (slide/fade), animate the
    /// transition: outgoing windows slide/fade out, incoming slide/fade in.
    /// Empty workspaces (no windows, root == null) are fully supported — the
    /// outgoing workspace slides/fades out and the incoming stays empty.
    fn onWorkspaceSwitched(self: *NileCompositor, old_id: u64, new_id: u64) void {
        // If switching to a floating workspace that was toggled while not current,
        // its tiled windows are still at tiled positions — cascade them now so they overlap.
        if (server.workspace.getEffectiveMode(new_id) == .floating) {
            self.cascadeTiledToFloating(new_id);
        }
        const Anim = @import("Animation.zig");
        const cfg = Anim.get().workspace_switch;
        if (!Anim.get().isWorkspaceSwitchEnabled()) {
            self.layoutCurrent();
            self.raiseFloatingWindows();
            self.updateFocusForWorkspace(new_id);
            return;
        }
        const out = Nile.Output.primary() orelse {
            self.layoutCurrent();
            self.updateFocusForWorkspace(new_id);
            return;
        };
        const nea = Nile.Layer.nonExclusiveArea(out);
        if (nea.width == 0 or nea.height == 0) {
            self.layoutCurrent();
            self.updateFocusForWorkspace(new_id);
            return;
        }
        const output_box: Box = .{
            .x = @intCast(nea.x),
            .y = @intCast(nea.y),
            .w = @intCast(nea.width),
            .h = @intCast(nea.height),
        };
        const width: i32 = @intCast(nea.width);
        const slide_sign: i32 = if (new_id > old_id) 1 else -1;
        const duration: i64 = @intCast(cfg.duration_ms);
        const easing = cfg.easing;
        switch (cfg.kind) {
            .none => {
                self.layoutCurrent();
                self.updateFocusForWorkspace(new_id);
            },
            .slide => {
                // Outgoing: slide out off-screen (handles empty old workspace gracefully — no windows)
                var it = Nile.Window.iter();
                while (it.next()) |win| {
                    if (win.wm_requested.workspace != old_id) continue;
                    if (win.state != .mapped) continue;
                    var target = win.box;
                    target.x -= slide_sign * width;
                    win.startWorkspaceSlideOut(target, duration, easing);
                }
                // Incoming: slide in from off-screen (empty workspace: no tree, nothing to animate)
                if (self.rootFor(new_id).*) |*r| {
                    self.animateWorkspaceSlideIn(r, output_box, width, slide_sign, duration, easing);
                } else {
                    self.ensureCurrentTree();
                    if (self.cur().*) |*rr| {
                        self.animateWorkspaceSlideIn(rr, output_box, width, slide_sign, duration, easing);
                    } else {
                        // New workspace is empty (or floating with no tiled windows) — handle floating incoming
                    }
                }
                // Incoming floating windows: also slide in (they are not in tiling tree)
                {
                    var it2 = Nile.Window.iter();
                    while (it2.next()) |win| {
                        if (win.wm_requested.workspace != new_id) continue;
                        if (!win.isEffectivelyFloating()) continue;
                        if (win.state != .mapped) continue;
                        self.ensureFloatingPosition(win);
                        const target = win.box;
                        // Ensure target is on-screen (tiling slide recomputes target from rbox; for floating we use current box as target)
                        const start: @import("wlroots").Box = .{ .x = target.x + slide_sign * width, .y = target.y, .width = target.width, .height = target.height };
                        win.box = start;
                        win.tree.node.setPosition(start.x, start.y);
                        win.popup_tree.node.setPosition(start.x, start.y);
                        win.rendering_requested.x = start.x;
                        win.rendering_requested.y = start.y;
                        win.startWorkspaceAnimation(target, 1.0, duration, easing);
                    }
                }
                self.raiseFloatingWindows();
                self.updateFocusForWorkspace(new_id);
                Nile.dirtyWindowing();
                Nile.dirtyRendering();
            },
            .fade => {
                var it = Nile.Window.iter();
                while (it.next()) |win| {
                    if (win.wm_requested.workspace != old_id) continue;
                    if (win.state != .mapped) continue;
                    win.startWorkspaceFadeOut(duration, easing);
                }
                if (self.rootFor(new_id).*) |*r| {
                    self.animateWorkspaceFadeIn(r, output_box, duration, easing);
                } else {
                    self.ensureCurrentTree();
                    if (self.cur().*) |*rr| {
                        self.animateWorkspaceFadeIn(rr, output_box, duration, easing);
                    } else {
                        // Empty incoming workspace — just fade out outgoing (floating handled below)
                    }
                }
                // Incoming floating windows: fade in like tiled incoming
                {
                    var it2 = Nile.Window.iter();
                    while (it2.next()) |win| {
                        if (win.wm_requested.workspace != new_id) continue;
                        if (!win.isEffectivelyFloating()) continue;
                        if (win.state != .mapped) continue;
                        self.ensureFloatingPosition(win);
                        win.alpha = 0.0;
                        win.applyAlpha(0.0);
                        win.startWorkspaceAnimation(win.box, 1.0, duration, easing);
                    }
                }
                self.raiseFloatingWindows();
                self.updateFocusForWorkspace(new_id);
                Nile.dirtyWindowing();
                Nile.dirtyRendering();
            },
        }
    }

    /// Focus the first window on workspace `id`, or clear focus if the workspace is empty.
    /// Called on every workspace switch so that switching to an empty workspace does not leave
    /// keyboard focus on a hidden window from the previous workspace.
    fn updateFocusForWorkspace(self: *NileCompositor, id: u64) void {
        _ = self;
        var it = Nile.Window.iter();
        var first: ?*Window = null;
        while (it.next()) |win| {
            if (win.wm_requested.workspace != id) continue;
            if (win.state != .mapped) continue;
            first = win;
            break;
        }
        const seat = Nile.Seat.default();
        if (first) |w| {
            // Avoid redundant focus if already focused
            switch (seat.focused) {
                .window => |focused| if (focused == w) return,
                else => {},
            }
            Nile.Seat.focusWindow(seat, w);
        } else {
            // Empty workspace — clear focus so input is not stuck on hidden window
            if (seat.focused != .none) Nile.Seat.clearFocus(seat);
        }
    }

    fn animateWorkspaceSlideIn(self: *NileCompositor, r: *Node, output_box: Box, output_width: i32, slide_sign: i32, duration: i64, easing: @import("Animation.zig").Easing) void {
        _ = self;
        workspaceSlideNode(r, output_box, output_width, slide_sign, duration, easing);
    }

    fn animateWorkspaceFadeIn(self: *NileCompositor, r: *Node, output_box: Box, duration: i64, easing: @import("Animation.zig").Easing) void {
        _ = self;
        workspaceFadeNode(r, output_box, duration, easing);
    }

    fn workspaceSlideNode(n: *Node, rbox: Box, output_width: i32, slide_sign: i32, duration: i64, easing: @import("Animation.zig").Easing) void {
        switch (n.*) {
            .leaf => |win| {
                const target: wlr.Box = .{ .x = rbox.x, .y = rbox.y, .width = rbox.w, .height = rbox.h };
                // Ensure client gets correct dimensions (without tiling animation)
                win.wm_requested.dimensions = .{ .width = @intCast(rbox.w), .height = @intCast(rbox.h) };
                const start: wlr.Box = .{ .x = target.x + slide_sign * output_width, .y = target.y, .width = target.width, .height = target.height };
                // Place window at start off-screen immediately
                win.box = start;
                win.tree.node.setPosition(start.x, start.y);
                win.popup_tree.node.setPosition(start.x, start.y);
                win.rendering_requested.x = start.x;
                win.rendering_requested.y = start.y;
                win.alpha = 1.0;
                win.applyAlpha(1.0);
                win.startWorkspaceAnimation(target, 1.0, duration, easing);
            },
            .branch => |b| {
                switch (b.orientation) {
                    .vertical => {
                        const h1: i32 = @intFromFloat(@floor(@as(f64, @floatFromInt(rbox.h)) * b.ratio));
                        const h2: i32 = @intFromFloat(@floor(@as(f64, @floatFromInt(rbox.h)) * (1.0 - b.ratio)));
                        workspaceSlideNode(b.first, .{ .x = rbox.x, .y = rbox.y, .w = rbox.w, .h = h1 }, output_width, slide_sign, duration, easing);
                        workspaceSlideNode(b.second, .{ .x = rbox.x, .y = rbox.y + h1, .w = rbox.w, .h = h2 }, output_width, slide_sign, duration, easing);
                    },
                    .horizontal => {
                        const w1: i32 = @intFromFloat(@floor(@as(f64, @floatFromInt(rbox.w)) * b.ratio));
                        const w2: i32 = @intFromFloat(@floor(@as(f64, @floatFromInt(rbox.w)) * (1.0 - b.ratio)));
                        workspaceSlideNode(b.first, .{ .x = rbox.x, .y = rbox.y, .w = w1, .h = rbox.h }, output_width, slide_sign, duration, easing);
                        workspaceSlideNode(b.second, .{ .x = rbox.x + w1, .y = rbox.y, .w = w2, .h = rbox.h }, output_width, slide_sign, duration, easing);
                    },
                }
            },
        }
    }

    fn workspaceFadeNode(n: *Node, rbox: Box, duration: i64, easing: @import("Animation.zig").Easing) void {
        switch (n.*) {
            .leaf => |win| {
                const target: wlr.Box = .{ .x = rbox.x, .y = rbox.y, .width = rbox.w, .height = rbox.h };
                win.wm_requested.dimensions = .{ .width = @intCast(rbox.w), .height = @intCast(rbox.h) };
                win.box = target;
                win.tree.node.setPosition(target.x, target.y);
                win.popup_tree.node.setPosition(target.x, target.y);
                win.rendering_requested.x = target.x;
                win.rendering_requested.y = target.y;
                win.alpha = 0.0;
                win.applyAlpha(0.0);
                win.startWorkspaceAnimation(target, 1.0, duration, easing);
            },
            .branch => |b| {
                switch (b.orientation) {
                    .vertical => {
                        const h1: i32 = @intFromFloat(@floor(@as(f64, @floatFromInt(rbox.h)) * b.ratio));
                        const h2: i32 = @intFromFloat(@floor(@as(f64, @floatFromInt(rbox.h)) * (1.0 - b.ratio)));
                        workspaceFadeNode(b.first, .{ .x = rbox.x, .y = rbox.y, .w = rbox.w, .h = h1 }, duration, easing);
                        workspaceFadeNode(b.second, .{ .x = rbox.x, .y = rbox.y + h1, .w = rbox.w, .h = h2 }, duration, easing);
                    },
                    .horizontal => {
                        const w1: i32 = @intFromFloat(@floor(@as(f64, @floatFromInt(rbox.w)) * b.ratio));
                        const w2: i32 = @intFromFloat(@floor(@as(f64, @floatFromInt(rbox.w)) * (1.0 - b.ratio)));
                        workspaceFadeNode(b.first, .{ .x = rbox.x, .y = rbox.y, .w = w1, .h = rbox.h }, duration, easing);
                        workspaceFadeNode(b.second, .{ .x = rbox.x + w1, .y = rbox.y, .w = w2, .h = rbox.h }, duration, easing);
                    },
                }
            },
        }
    }

    /// A window moved between workspaces. Detach it from the old tree and
    /// attach it to the new one; both tilings otherwise untouched.
    /// Floating windows are not placed in tiling trees.
    fn onWindowWorkspaceChanged(self: *NileCompositor, win: *Window, old_id: u64, new_id: u64) void {
        const old_root = self.rootFor(old_id);
        if (old_root.*) |*r| {
            if (r.find(win)) |n| {
                if (r.* == .leaf) {
                    old_root.* = null;
                } else if (r.findParent(n)) |p| {
                    p.pop(p.branch.first == n);
                }
            }
            if (old_root == self.cur()) {
                const old_mode = server.workspace.getEffectiveMode(old_id);
                if (old_mode == .floating) {
                    // Floating workspace: keep floating positions, don't retile
                    self.layoutCurrent();
                } else {
                    if (old_root.*) |*rr| self.layoutTree(rr) else self.layoutCurrent();
                }
            }
        }
        // Only insert into tiling tree if window is effectively tiled on new workspace
        if (win.isEffectivelyFloating()) {
            if (self.rootFor(new_id) == self.cur()) {
                self.ensureFloatingPosition(win);
                Nile.Window.raiseToTop(win);
                self.raiseFloatingWindows();
                Nile.dirtyRendering();
            }
            return;
        }
        const new_root = self.rootFor(new_id);
        if (new_root.*) |*r| {
            const drop_x: i32 = @intCast(@max(0, win.box.x));
            const drop_y: i32 = @intCast(@max(0, win.box.y));
            r.append(self.gpa, win, drop_x, drop_y);
            if (new_root == self.cur()) self.layoutTree(r);
        } else {
            new_root.* = .{ .leaf = win };
            if (new_root == self.cur()) self.layoutCurrent();
        }
        self.raiseFloatingWindows();
    }

    /// Arrange all windows. Only builds a tree when the current workspace has
    /// none yet (first show); otherwise lays out the existing tree so manual
    /// splits/ratios survive.
    pub fn arrange(self: *NileCompositor) void {
        self.ensureCurrentTree();
        self.layoutCurrent();
    }

    /// Attach any current-workspace windows missing from its tree (e.g. first
    /// show, or windows assigned while this policy wasn't registered).
    /// Existing splits/ratios are preserved — nothing is ever rebuilt here.
    /// Floating windows (forced or workspace mode floating) are never added to the tiling tree.
    fn ensureCurrentTree(self: *NileCompositor) void {
        const current_ws = server.workspace.currentWorkspace();
        const mode = server.workspace.getEffectiveMode(current_ws);
        if (mode == .floating) return;
        const root = self.cur();
        if (root.* == null) {
            var wins = std.ArrayList(*Window).empty;
            defer wins.deinit(self.gpa);
            var it = Nile.Window.iter();
            while (it.next()) |win| {
                if (win.wm_requested.workspace != current_ws) continue;
                if (win.isEffectivelyFloating()) continue;
                wins.append(self.gpa, win) catch unreachable;
            }
            if (wins.items.len == 0) return;
            root.* = construct(self.gpa, wins.items);
            return;
        }
        // Prune floating windows that are lingering in tree (e.g. toggled while in tree)
        {
            var wins = std.ArrayList(*Window).empty;
            defer wins.deinit(self.gpa);
            // Collect floating windows that are in tree but should be removed
            const r: *Node = &root.*.?;
            // We cannot easily enumerate tree, so iterate all windows and check
            var it = Nile.Window.iter();
            while (it.next()) |win| {
                if (win.wm_requested.workspace != current_ws) continue;
                if (win.isEffectivelyFloating() and r.find(win) != null) {
                    wins.append(self.gpa, win) catch unreachable;
                }
            }
            for (wins.items) |win| {
                if (r.find(win)) |n| {
                    if (r.* == .leaf) {
                        root.* = null;
                        break;
                    } else if (r.findParent(n)) |p| {
                        p.pop(p.branch.first == n);
                    }
                }
            }
            if (root.* == null) return;
        }
        var it = Nile.Window.iter();
        while (it.next()) |win| {
            if (win.wm_requested.workspace != current_ws) continue;
            if (win.isEffectivelyFloating()) continue;
            const r: *Node = &root.*.?;
            if (r.find(win) != null) continue;
            const drop_x: i32 = @intCast(@max(0, win.box.x));
            const drop_y: i32 = @intCast(@max(0, win.box.y));
            r.append(self.gpa, win, drop_x, drop_y);
        }
    }

    /// Apply the current workspace tree's geometry to its windows.
    fn layoutCurrent(self: *NileCompositor) void {
        const cur_id = server.workspace.currentWorkspace();
        const mode = server.workspace.getEffectiveMode(cur_id);
        if (mode == .floating) {
            // Floating workspace: ensure floating windows have positions, raise them
            var it = Nile.Window.iter();
            while (it.next()) |win| {
                if (win.wm_requested.workspace != cur_id) continue;
                if (win.state != .mapped) continue;
                self.ensureFloatingPosition(win);
            }
            self.raiseFloatingWindows();
            Nile.dirtyWindowing();
            Nile.dirtyRendering();
            return;
        }
        if (self.cur().*) |*r| self.layoutTree(r) else {
            // No tiling tree but maybe floating windows need raise
            self.raiseFloatingWindows();
            Nile.dirtyRendering();
        }
    }

    /// Apply one tree's geometry. Pure layout — never mutates the tree.
    fn layoutTree(self: *NileCompositor, r: *Node) void {
        const out = Nile.Output.primary() orelse return;
        const box = Nile.Layer.nonExclusiveArea(out);
        if (box.width == 0 or box.height == 0) return;
        arrangeNode(.{
            .x = @intCast(box.x),
            .y = @intCast(box.y),
            .w = @intCast(box.width),
            .h = @intCast(box.height),
        }, r, true);
        // After tiling, raise any floating windows above tiled ones on this workspace
        self.raiseFloatingWindows();
        Nile.dirtyWindowing();
        Nile.dirtyRendering();
    }

    fn arrangeNode(rbox: Box, n: *const Node, animate: bool) void {
        switch (n.*) {
            .leaf => |win| {
                // Window being dragged never animates — check isGrabbed inside
                // startPosAnimation, but also force animate=false for its own
                // target to guarantee immediate response.
                const is_grabbed = blk: {
                    var it = @import("main.zig").server.input_manager.seats.iterator(.forward);
                    while (it.next()) |seat| if (seat.op) |op| if (op.window) |r| if (r.get()) |w| if (w == win) break :blk true;
                    break :blk false;
                };
                const do_animate = if (is_grabbed) false else animate;
                Nile.Window.setPosition(win, @intCast(rbox.x), @intCast(rbox.y), do_animate);
                Nile.Window.setDimensions(win, @intCast(rbox.w), @intCast(rbox.h), do_animate);
            },
            .branch => |b| {
                switch (b.orientation) {
                    .vertical => {
                        arrangeNode(.{
                            .x = rbox.x,
                            .y = rbox.y,
                            .w = rbox.w,
                            .h = @floor(rbox.h * b.ratio),
                        }, b.first, animate);
                        arrangeNode(.{
                            .x = rbox.x,
                            .y = @as(i32, @intFromFloat(rbox.y + @floor(rbox.h * b.ratio))),
                            .w = rbox.w,
                            .h = @as(i32, @intFromFloat(@floor(rbox.h * (1.0 - b.ratio)))),
                        }, b.second, animate);
                    },
                    .horizontal => {
                        arrangeNode(.{
                            .x = rbox.x,
                            .y = rbox.y,
                            .w = @floor(rbox.w * b.ratio),
                            .h = rbox.h,
                        }, b.first, animate);
                        arrangeNode(.{
                            .x = @as(i32, @intFromFloat(rbox.x + @floor(rbox.w * b.ratio))),
                            .y = rbox.y,
                            .w = @as(i32, @intFromFloat(@floor(rbox.w * (1.0 - b.ratio)))),
                            .h = rbox.h,
                        }, b.second, animate);
                    },
                }
            },
        }
    }

    fn onFullscreen(self: *NileCompositor, win: *Window, output: ?*Output) void {
        _ = self;
        Nile.Window.setFullscreen(win, output);
    }

    fn onMaximize(self: *NileCompositor, win: *Window, maximize: bool) void {
        if (maximize) {
            if (win.wm_requested.maximized) return;
            // Save geometry for restore
            win.maximize_prev_box = win.box;
            const out = Nile.Output.primary() orelse return;
            const nea = Nile.Layer.nonExclusiveArea(out);
            if (nea.width == 0 or nea.height == 0) return;
            // If tiled (in tree), pop it so tiling layout doesn't fight maximize
            if (!win.isEffectivelyFloating()) {
                const root = self.rootFor(win.wm_requested.workspace);
                if (root.*) |*r| {
                    if (r.find(win)) |n| {
                        if (r.* == .leaf) {
                            root.* = null;
                        } else if (r.findParent(n)) |p| {
                            p.pop(p.branch.first == n);
                            if (root == self.cur()) self.layoutTree(r);
                        }
                    }
                }
            }
            win.wm_requested.maximized = true;
            // Maximize to output's non-exclusive area (floating-style)
            Nile.Window.setPosition(win, nea.x, nea.y, false);
            Nile.Window.setDimensions(win, @intCast(nea.width), @intCast(nea.height), false);
            self.raiseFloatingWindows();
            Nile.Window.raiseToTop(win);
            Nile.dirtyWindowing();
            Nile.dirtyRendering();
        } else {
            if (!win.wm_requested.maximized) return;
            win.wm_requested.maximized = false;
            if (win.maximize_prev_box) |prev| {
                win.maximize_prev_box = null;
                Nile.Window.setPosition(win, prev.x, prev.y, false);
                Nile.Window.setDimensions(win, @intCast(prev.width), @intCast(prev.height), false);
                // If it was tiled before maximize, reinsert into tiling tree
                const ws_mode = server.workspace.getEffectiveMode(win.wm_requested.workspace);
                if (ws_mode == .tiling and !win.floating) {
                    const root = self.rootFor(win.wm_requested.workspace);
                    var in_tree = false;
                    if (root.*) |*r| {
                        if (r.find(win) != null) in_tree = true;
                    }
                    if (!in_tree) {
                        if (root.*) |*r| {
                            const drop_x: i32 = @intCast(@max(0, prev.x));
                            const drop_y: i32 = @intCast(@max(0, prev.y));
                            r.append(self.gpa, win, drop_x, drop_y);
                        } else {
                            root.* = .{ .leaf = win };
                        }
                    }
                    if (root == self.cur()) self.layoutCurrent();
                }
                self.raiseFloatingWindows();
                // Keep focused window on top if it was the maximized one
                if (win.isEffectivelyFloating()) Nile.Window.raiseToTop(win);
                Nile.dirtyWindowing();
                Nile.dirtyRendering();
            } else {
                win.wm_requested.maximized = false;
                Nile.dirtyWindowing();
            }
        }
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
        _ = time_msec;
        _ = button;
        switch (state) {
            .pressed => switch (kind) {
                .move => if (window) |win| {
                    log.info("pointer_button move pressed on {?s}", .{win.getTitle()});
                    seat.focus(.{ .window = win });
                    // Maximized windows snap back to stored floating size on drag
                    if (win.wm_requested.maximized) {
                        const restore = win.floating_restore_box orelse win.maximize_prev_box orelse win.box;
                        win.wm_requested.maximized = false;
                        win.maximize_prev_box = null;
                        win.ensureFloatingRestoreBox();
                        const rbox = restore;
                        Nile.Window.setPosition(win, rbox.x, rbox.y, false);
                        if (rbox.width != 0 and rbox.height != 0) {
                            Nile.Window.setDimensions(win, @intCast(rbox.width), @intCast(rbox.height), false);
                        }
                        win.floating_box = rbox;
                        // Treat as floating for this drag
                        Nile.Seat.opStartMove(seat, win);
                        Nile.dirtyWindowing();
                        Nile.dirtyRendering();
                        return;
                    }
                    if (win.isEffectivelyFloating()) {
                        Nile.Seat.opStartMove(seat, win);
                        // Floating windows stay floating: don't touch tiling tree
                        return;
                    }
                    const cur_root = self.cur();
                    if (cur_root.* == null or cur_root.*.? == .leaf)
                        return;
                    Nile.Seat.opStartMove(seat, win);
                    const n = cur_root.*.?.find(win) orelse return;
                    const p = cur_root.*.?.findParent(n) orelse return;
                    p.pop(p.branch.first == n);
                    // Tiling drag: keep the grabbed window very front (behind shell/overlay)
                    Nile.Window.raiseToTop(win);
                    Nile.dirtyRendering();
                },
                .resize => if (window) |win| {
                    log.info("pointer_button resize pressed edges={} on {?s}", .{ edges, win.getTitle() });
                    seat.focus(.{ .window = win });
                    Nile.Window.setResizing(win, true);
                    if (win.wm_requested.maximized) {
                        const restore = win.floating_restore_box orelse win.maximize_prev_box orelse win.box;
                        win.wm_requested.maximized = false;
                        win.maximize_prev_box = null;
                        win.ensureFloatingRestoreBox();
                        const rbox = restore;
                        Nile.Window.setPosition(win, rbox.x, rbox.y, false);
                        if (rbox.width != 0 and rbox.height != 0) {
                            Nile.Window.setDimensions(win, @intCast(rbox.width), @intCast(rbox.height), false);
                        }
                        win.floating_box = rbox;
                        Nile.Seat.opStartResize(seat, win, edges);
                        Nile.dirtyWindowing();
                        Nile.dirtyRendering();
                        return;
                    }
                    if (win.isEffectivelyFloating()) {
                        Nile.Seat.opStartResize(seat, win, edges);
                        return;
                    }
                    Nile.Seat.opStartResize(seat, win, edges);
                },
                .normal => if (window) |win| {
                    // Normal hold — focus clicked window immediately (stacking via focus_changed, not click)
                    seat.focus(.{ .window = win });
                },
            },
            .released => {
                // Use seat.op's kind, or pending wm_requested, not the event kind — Cursor may emit
                // .normal for a binding release, but if an op is active/pending the
                // release should still end it and reinsert the window. This covers
                // the race where release arrives before manageFinish created seat.op.
                const op_info: ?struct { kind: Compositor.PointerButtonKind, window: ?*Window } = if (seat.op) |op|
                    .{ .kind = op.kind, .window = if (op.window) |r| r.get() else null }
                else switch (seat.wm_requested.op) {
                    .start_pointer => |info| .{ .kind = info.kind, .window = if (info.window) |r| r.get() else null },
                    else => null,
                };
                const op_kind = if (op_info) |info| info.kind else kind;
                const op_win = if (op_info) |info| info.window else null;
                if (op_info != null) {
                    log.info(
                        "released {s} (op {s}), where op's nullity is {}",
                        .{ @tagName(kind), @tagName(op_kind), (seat.op == null) },
                    );
                } else {
                    log.info("released {s} (no op) at {d:.0},{d:.0}", .{ @tagName(kind), x, y });
                }
                // End interactive op (pointer release for move/resize)
                if (op_win) |win| {
                    if (op_kind == .resize) Nile.Window.setResizing(win, false);
                    log.info("pointer_button {s} released at {d:.0},{d:.0}", .{ @tagName(op_kind), x, y });
                    // Floating windows don't participate in tiling tree reinsert (stacking via focus, not click)
                    if (win.isEffectivelyFloating()) {
                        // Keep floating position as-is; update stored floating size for maximize snap-back
                        win.updateFloatingRestoreBox();
                    } else {
                        const cur_root = self.cur();
                        log.info("Nullability of root {}", .{(cur_root.* == null)});
                        if (cur_root.*) |*r| {
                            const drop_x: i32 = @as(i32, @intFromFloat(@floor(x)));
                            const drop_y: i32 = @as(i32, @intFromFloat(@floor(y)));
                            const target = if (Nile.Output.primary()) |out| blk: {
                                const nea = Nile.Layer.nonExclusiveArea(out);
                                const output_box: Box = .{ .x = @intCast(nea.x), .y = @intCast(nea.y), .w = @intCast(nea.width), .h = @intCast(nea.height) };
                                break :blk r.getNodeAllocated(drop_x, drop_y, r, output_box);
                            } else r.getNode(drop_x, drop_y);
                            if (op_kind == .move) {
                                target.append(self.gpa, win, drop_x, drop_y);
                            }
                            const win_node = r.find(win) orelse target;
                            log.info("added moving window to the tree at drop {d},{d}\n\twindow is at node {} with parent {}", .{
                                drop_x,
                                drop_y,
                                @intFromPtr(win_node),
                                @intFromPtr(target),
                            });
                        } else {
                            log.info("set moving window as root", .{});
                            cur_root.* = .{ .leaf = win };
                        }
                    }
                }
                if (seat.op != null or op_info != null) Nile.Seat.opEnd(seat);
            },
            else => {},
        }
        // Re-layout only tiling part; floating windows stay in place but need raise
        const cur_id = server.workspace.currentWorkspace();
        const mode = server.workspace.getEffectiveMode(cur_id);
        if (mode == .tiling) {
            if (self.cur().*) |*r| {
                const out = Nile.Output.primary() orelse return;
                const box = Nile.Layer.nonExclusiveArea(out);
                arrangeNode(.{
                    .x = @intCast(box.x),
                    .y = @intCast(box.y),
                    .w = @intCast(box.width),
                    .h = @intCast(box.height),
                }, r, true);
            }
            self.raiseFloatingWindows();
        } else {
            self.raiseFloatingWindows();
            Nile.dirtyRendering();
        }
        // Keep the grabbed tiling window very front (behind shell/overlay) while dragging
        if (state == .pressed and kind == .move) {
            if (seat.op) |op| if (op.window) |ref| if (ref.get()) |win| {
                Nile.Window.raiseToTop(win);
                Nile.dirtyRendering();
            };
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
        _ = time_msec;
        if (seat.op) |op| if (op.window) |ref| if (ref.get()) |win| {
            switch (op.kind) {
                .move => {
                    const new_x = op.win_x + @as(i32, @intFromFloat(x)) - op.start_x;
                    const new_y = op.win_y + @as(i32, @intFromFloat(y)) - op.start_y;
                    // Fast-path: update scene graph synchronously every
                    // wayland motion, bypassing the idle transaction.
                    // Falls back to dirtyRendering if window is not yet mapped.
                    if (win.state == .mapped or win.state == .closing) {
                        Nile.Window.setPositionImmediate(win, new_x, new_y);
                    } else {
                        Nile.Window.setPosition(win, new_x, new_y, false);
                        Nile.dirtyRendering();
                    }
                },
                .resize => {
                    // Floating windows resize directly via dimensions, not tiling ratios
                    if (win.isEffectivelyFloating()) {
                        var new_w: i32 = @intCast(op.win_width);
                        var new_h: i32 = @intCast(op.win_height);
                        var new_x: i32 = op.win_x;
                        var new_y: i32 = op.win_y;
                        const dx: i32 = @as(i32, @intFromFloat(x - @as(f64, @floatFromInt(op.start_x))));
                        const dy: i32 = @as(i32, @intFromFloat(y - @as(f64, @floatFromInt(op.start_y))));
                        if (op.edges.right) new_w = @max(80, @as(i32, @intCast(op.win_width)) + dx);
                        if (op.edges.left) {
                            new_w = @max(80, @as(i32, @intCast(op.win_width)) - dx);
                            new_x = op.win_x + dx;
                        }
                        if (op.edges.bottom) new_h = @max(80, @as(i32, @intCast(op.win_height)) + dy);
                        if (op.edges.top) {
                            new_h = @max(80, @as(i32, @intCast(op.win_height)) - dy);
                            new_y = op.win_y + dy;
                        }
                        if (op.edges.left or op.edges.top) {
                            Nile.Window.setPosition(win, new_x, new_y, false);
                        }
                        win.wm_requested.dimensions = .{ .width = @intCast(new_w), .height = @intCast(new_h) };
                        win.startSizeAnimation(new_w, new_h, false);
                        Nile.dirtyWindowing();
                        Nile.dirtyRenderingImmediate();
                        return;
                    }
                    const rnode: *Node = if (self.cur().*) |*r| r else return;
                    const n = rnode.find(win) orelse return;

                    const out = Nile.Output.primary() orelse return;
                    const nea = Nile.Layer.nonExclusiveArea(out);
                    const output_box: Box = .{
                        .x = @intCast(nea.x),
                        .y = @intCast(nea.y),
                        .w = @intCast(nea.width),
                        .h = @intCast(nea.height),
                    };

                    const has_h = op.edges.left or op.edges.right;
                    const has_v = op.edges.top or op.edges.bottom;
                    if (!has_h and !has_v) return;

                    // Walk ancestors to find the branch(es) whose orientation
                    // matches the dragged edge. This fixes nested cases where
                    // a window's immediate parent orientation doesn't match the
                    // edge (e.g. leaf inside vertical split but dragging right
                    // edge must resize the ancestor horizontal split). Also
                    // handles branch-branch splits (children are branches, not
                    // leaves) — ratio and allocatedBoxFor work for any node.
                    var horiz_branch: ?*Node = null;
                    var vert_branch: ?*Node = null;
                    var horiz_box: ?Box = null;
                    var vert_box: ?Box = null;

                    var anc: ?*Node = n;
                    while (anc) |node| {
                        const parent = rnode.findParent(node) orelse break;
                        const pb = rnode.allocatedBoxFor(parent, output_box) orelse parent.getBox();
                        if (pb.w == 0 or pb.h == 0) {
                            anc = parent;
                            continue;
                        }
                        if (horiz_branch == null and has_h and parent.branch.orientation == .horizontal) {
                            horiz_branch = parent;
                            horiz_box = pb;
                        }
                        if (vert_branch == null and has_v and parent.branch.orientation == .vertical) {
                            vert_branch = parent;
                            vert_box = pb;
                        }
                        if (has_h and !has_v and horiz_branch != null) break;
                        if (!has_h and has_v and vert_branch != null) break;
                        if (has_h and has_v and horiz_branch != null and vert_branch != null) break;
                        anc = parent;
                    }

                    var resized = false;
                    if (has_h) {
                        const b = horiz_branch orelse return;
                        const pb = horiz_box orelse b.getBox();
                        if (pb.w != 0) {
                            b.branch.ratio += delta_x / @as(f64, @floatFromInt(pb.w));
                            b.branch.ratio = @max(0.05, @min(0.95, b.branch.ratio));
                        }
                        resized = true;
                    }
                    if (has_v) {
                        const b = vert_branch orelse {
                            if (!resized) return;
                            // diagonal edge where one axis already resized
                            // but other axis has no matching branch — keep horiz resize
                            arrangeNode(output_box, rnode, false);
                            Nile.dirtyWindowingLazy();
                            Nile.dirtyRenderingImmediate();
                            return;
                        };
                        const pb = vert_box orelse b.getBox();
                        if (pb.h != 0) {
                            b.branch.ratio += delta_y / @as(f64, @floatFromInt(pb.h));
                            b.branch.ratio = @max(0.05, @min(0.95, b.branch.ratio));
                        }
                        resized = true;
                    }
                    if (!resized) return;

                    // Re-arrange whole root immediately with fresh ratios.
                    // During drag, animate=false to avoid lag — batch visual updates
                    // and keep grabbed window immediate. After drop, final arrange
                    // will animate=true.
                    arrangeNode(output_box, rnode, false);
                    // Exception for motion: windowing (dimensions/configure) is still
                    // lazy/idle so it doesn't block motion coalescing, but rendering
                    // (position) is flushed synchronously on every motion for
                    // per-wayland-call latency. The fast-path in Seat.queueEvent
                    // guarantees this handler runs even during inflight_configures.
                    Nile.dirtyWindowingLazy();
                    Nile.dirtyRenderingImmediate();
                },
                .normal => {},
            }
        };
    }

    fn onFrame(self: *NileCompositor) void {
        _ = self;
    }
};

pub const Instance = NileCompositor;
