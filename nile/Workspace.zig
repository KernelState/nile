// SPDX-FileCopyrightText: © 2026 The Nile Developers
// SPDX-License-Identifier: GPL-3.0-only

//! Workspace — workspace management for Nile.
//!
//! Tracks workspaces, the current workspace, and window-to-workspace
//! assignments. Handles workspace switching by updating window
//! visibility and announcing the switch on nilebank.

const std = @import("std");
const Allocator = std.mem.Allocator;

const server = &@import("main.zig").server;
const Window = @import("Window.zig");
const Output = @import("Output.zig");
const Nile = @import("Nile.zig");
const Compositor = @import("Compositor.zig");

const nilebank = @import("nilebank");
const protocols = nilebank.protocols.compositor;

const log = std.log.scoped(.wm);

pub const Mode = enum(u8) {
    tiling = 0,
    floating = 1,

    pub fn fromU8(v: u8) ?Mode {
        return switch (v) {
            0 => .tiling,
            1 => .floating,
            else => null,
        };
    }
};

pub const Info = struct {
    id: u64,
    number: u64,
    name: []const u8,
    active: bool = false,
    current: bool = false,
    urgent: bool = false,
    output: u64 = 0,
    /// Explicit per-workspace layout. `null` means inherit `Manager.default_mode`.
    mode: ?Mode = null,

    pub fn deinit(self: Info, alloc: Allocator) void {
        if (self.name.len > 0) alloc.free(self.name);
    }
};

pub const Manager = struct {
    const Self = @This();

    /// Nile always has exactly this many workspaces, numbered 1..COUNT.
    /// Created at startup; never auto-created or auto-removed afterwards.
    pub const fixed_count: u64 = 9;

    workspaces: std.ArrayList(Info) = .empty,
    current: u64 = 1,
    /// Global fallback when `Info.mode == null`. Lives in the compositor
    /// conceptually but stored here so `Window.isEffectivelyFloating` can resolve
    /// it without depending on `NileCompositor` (avoiding a cycle).
    default_mode: Mode = .tiling,

    pub fn init(self: *Manager, alloc: Allocator) !void {
        self.* = .{
            .workspaces = try std.ArrayList(Info).initCapacity(alloc, fixed_count),
            .current = 1,
            .default_mode = .tiling,
        };
        var i: u64 = 1;
        while (i <= fixed_count) : (i += 1) {
            var name_buf: [16]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "{d}", .{i}) catch "ws";
            try self.workspaces.append(alloc, .{
                .id = i,
                .number = i,
                .name = try alloc.dupe(u8, name),
                .current = (i == self.current),
                .mode = null,
            });
        }
    }

    pub fn deinit(self: *Manager, alloc: Allocator) void {
        for (self.workspaces.items) |*ws| ws.deinit(alloc);
        self.workspaces.deinit(alloc);
    }

    pub fn currentWorkspace(self: *const Manager) u64 {
        return self.current;
    }

    pub fn listWorkspaces(self: *const Manager, alloc: Allocator) ![]Info {
        const items = try alloc.alloc(Info, self.workspaces.items.len);
        for (self.workspaces.items, 0..) |ws, i| {
            items[i] = ws;
            items[i].current = ws.id == self.current;
            if (ws.name.len > 0) {
                items[i].name = try alloc.dupe(u8, ws.name);
            }
        }
        return items;
    }

    pub fn getWorkspace(self: *const Manager, id: u64, alloc: Allocator) ?Info {
        for (self.workspaces.items) |ws| {
            if (ws.id == id) {
                var copy = ws;
                copy.current = ws.id == self.current;
                if (ws.name.len > 0) {
                    copy.name = alloc.dupe(u8, ws.name) catch return null;
                }
                return copy;
            }
        }
        return null;
    }

    pub fn addWorkspace(self: *Manager, alloc: Allocator, number: u64, name: []const u8) !Info {
        // Fixed set 1..fixed_count already exists — return the existing one
        // so on-demand creation never duplicates workspaces.
        for (self.workspaces.items) |ws| {
            if (ws.number == number) return ws;
        }
        const id = self.nextId();
        const ws = Info{ .id = id, .number = number, .name = try alloc.dupe(u8, name), .current = (id == self.current), .mode = null };
        try self.workspaces.append(alloc, ws);
        Compositor.notify(.{ .workspace_created = id });
        return ws;
    }

    pub fn removeWorkspace(self: *Manager, alloc: Allocator, id: u64) !void {
        // The fixed set 1..fixed_count can never be removed — Nile always
        // has exactly `fixed_count` workspaces.
        for (self.workspaces.items) |ws| {
            if (ws.id == id and ws.number >= 1 and ws.number <= fixed_count) {
                return error.WorkspaceFixed;
            }
        }
        const idx = blk: {
            for (self.workspaces.items, 0..) |ws, i| {
                if (ws.id == id) break :blk i;
            }
            return error.WorkspaceNotFound;
        };
        const ws = self.workspaces.items[idx];
        ws.deinit(alloc);
        _ = self.workspaces.orderedRemove(idx);
        if (self.current == id) {
            if (self.workspaces.items.len > 0) {
                self.current = self.workspaces.items[0].id;
            } else {
                self.current = 0;
            }
        }
        Compositor.notify(.{ .workspace_removed = id });
    }

    /// Get a workspace's number by id.
    pub fn getWorkspaceNumber(self: *const Manager, id: u64) u64 {
        for (self.workspaces.items) |ws| {
            if (ws.id == id) return ws.number;
        }
        return 0;
    }

    /// Get a workspace's id by its human number (1..fixed_count).
    /// Returns null if no workspace has that number (should not happen
    /// for the fixed set — all are created at startup).
    pub fn idForNumber(self: *const Manager, number: u64) ?u64 {
        for (self.workspaces.items) |ws| {
            if (ws.number == number) return ws.id;
        }
        return null;
    }

    /// Set a workspace's name. The name is duplicated; the caller retains
    /// ownership of the passed slice.
    pub fn setWorkspaceName(self: *Manager, alloc: Allocator, id: u64, name: []const u8) !void {
        for (self.workspaces.items) |*ws| {
            if (ws.id == id) {
                const owned = try alloc.dupe(u8, name);
                // free old name but keep other fields
                if (ws.name.len > 0) alloc.free(ws.name);
                ws.name = owned;
                Compositor.notify(.{ .workspace_renamed = id });
                return;
            }
        }
        return error.WorkspaceNotFound;
    }

    /// Get explicit per-workspace mode. `null` means inherit `default_mode`
    /// or workspace not found (caller can distinguish via `getWorkspace` if needed).
    pub fn getWorkspaceMode(self: *const Manager, id: u64) ?Mode {
        for (self.workspaces.items) |ws| {
            if (ws.id == id) return ws.mode;
        }
        return null;
    }

    /// Effective layout for `id` — explicit if set, otherwise `default_mode`.
    /// Unknown ids also fall back to `default_mode` (sensible default, never null).
    pub fn getEffectiveMode(self: *const Manager, id: u64) Mode {
        for (self.workspaces.items) |ws| {
            if (ws.id == id) return ws.mode orelse self.default_mode;
        }
        return self.default_mode;
    }

    /// Global fallback. Used when `Info.mode == null`.
    pub fn getGlobalMode(self: *const Manager) Mode {
        return self.default_mode;
    }
    pub fn setGlobalMode(self: *Manager, mode: Mode) void {
        if (self.default_mode == mode) return;
        self.default_mode = mode;
        // Notify per-workspace where mode is inherited so shells re-evaluate effective state
        for (self.workspaces.items) |ws| {
            if (ws.mode == null) {
                Compositor.notify(.{ .workspace_mode_changed = .{ .id = ws.id, .mode = mode } });
            }
        }
        log.info("global workspace mode -> {s}", .{@tagName(mode)});
        server.wm.dirtyWindowing();
        server.wm.dirtyRendering();
    }

    /// Clear explicit mode so workspace inherits global.
    pub fn clearWorkspaceMode(self: *Manager, id: u64) !void {
        for (self.workspaces.items) |*ws| {
            if (ws.id == id) {
                if (ws.mode == null) return;
                ws.mode = null;
                const eff = self.default_mode;
                Compositor.notify(.{ .workspace_mode_changed = .{ .id = id, .mode = eff } });
                log.info("workspace {} mode cleared -> inherits {s}", .{ id, @tagName(eff) });
                server.wm.dirtyWindowing();
                server.wm.dirtyRendering();
                return;
            }
        }
        return error.WorkspaceNotFound;
    }

    /// Set a workspace layout mode (explicit).
    pub fn setWorkspaceMode(self: *Manager, id: u64, mode: Mode) !void {
        for (self.workspaces.items) |*ws| {
            if (ws.id == id) {
                if (ws.mode != null and ws.mode.? == mode) return;
                ws.mode = mode;
                Compositor.notify(.{ .workspace_mode_changed = .{ .id = id, .mode = mode } });
                log.info("workspace {} mode -> {s}", .{ id, @tagName(mode) });
                server.wm.dirtyWindowing();
                server.wm.dirtyRendering();
                return;
            }
        }
        return error.WorkspaceNotFound;
    }

    /// Toggle a workspace mode tiling <-> floating (operates on effective mode, writes explicit).
    pub fn toggleWorkspaceMode(self: *Manager, id: u64) !Mode {
        for (self.workspaces.items) |*ws| {
            if (ws.id == id) {
                const cur = ws.mode orelse self.default_mode;
                const new_mode: Mode = if (cur == .tiling) .floating else .tiling;
                ws.mode = new_mode;
                Compositor.notify(.{ .workspace_mode_changed = .{ .id = id, .mode = new_mode } });
                log.info("workspace {} mode toggled -> {s}", .{ id, @tagName(new_mode) });
                server.wm.dirtyWindowing();
                server.wm.dirtyRendering();
                return new_mode;
            }
        }
        return error.WorkspaceNotFound;
    }

    /// Switch to workspace `id`. Returns the activated workspace id,
    /// or error.WorkspaceNotFound if it does not exist.
    pub fn switchWorkspace(self: *Manager, id: u64) !u64 {
        if (self.current == id) return id;
        const old_id = self.current;

        var found = false;
        for (self.workspaces.items) |ws| {
            if (ws.id == id) {
                found = true;
                break;
            }
        }
        if (!found) return error.WorkspaceNotFound;

        // Update visibility for all windows
        {
            var it = server.wm.windows.iterator();
            while (it.next()) |win| {
                if (win.wm_requested.workspace == old_id) {
                    win.rendering_requested.hidden = true;
                } else if (win.wm_requested.workspace == id) {
                    win.rendering_requested.hidden = false;
                }
            }
        }

        self.current = id;
        server.wm.dirtyWindowing();
        server.wm.dirtyRendering();
        log.info("workspace switched {} -> {}", .{ old_id, id });
        Compositor.notify(.{ .workspace_switched = .{ .old_id = old_id, .new_id = id } });
        return id;
    }

    /// Move a window to a different workspace.
    pub fn moveWindowToWorkspace(self: *Manager, win: *Window, id: u64) !void {
        const old_id = win.wm_requested.workspace;
        if (old_id == id) return;
        win.wm_requested.workspace = id;
        if (self.current != id) {
            win.rendering_requested.hidden = true;
        } else {
            win.rendering_requested.hidden = false;
        }
        server.wm.dirtyWindowing();
        server.wm.dirtyRendering();
        log.info("moved window to workspace {}", .{id});
        Compositor.notify(.{ .window_workspace_changed = .{ .window = win, .old_id = old_id, .new_id = id } });
    }

    fn nextId(self: *Manager) u64 {
        var max_id: u64 = 0;
        for (self.workspaces.items) |ws| {
            if (ws.id > max_id) max_id = ws.id;
        }
        return max_id + 1;
    }
};
