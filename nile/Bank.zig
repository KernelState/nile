// SPDX-FileCopyrightText: © 2026 The Nile Developers
// SPDX-License-Identifier: GPL-3.0-only

//! NileBank — nilebank IPC integration for Nile.
//! Socket ID is "compositor" → path "/run/arcos/compositor.sock"
//! Handles compositor protocol requests via `nilebank` library.
//! Read queries are served synchronously (with best-effort main-thread
//! dispatch for mutation ops via Wayland event loop pipe).

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Thread = std.Thread;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const nilebank = @import("nilebank");
const protocols = nilebank.protocols.compositor;

const server = &@import("main.zig").server;
const util = @import("util.zig");
const Window = @import("Window.zig");
const Output = @import("Output.zig");
const Nile = @import("Nile.zig");

const log = std.log.scoped(.bank);

pub const socket_id = "compositor";
pub const socket_path = "/run/arcos/" ++ socket_id ++ ".sock";

// ---------------------------------------------------------------------------
// Helpers: id mapping
// ---------------------------------------------------------------------------

fn windowIdFromRef(ref: Window.Ref) u64 {
    // Pack generation (u32) + index (u32) into u64
    return (@as(u64, ref.key.generation) << 32) | @as(u64, ref.key.index);
}

fn windowFromId(id: u64) ?*Window {
    const gen: u32 = @intCast(id >> 32);
    const idx: u32 = @intCast(id & 0xFFFFFFFF);
    const key: Window.Ref = .{ .key = .{ .generation = gen, .index = idx } };
    return key.get();
}

fn outputId(op: *Output) u64 {
    return @intFromPtr(op);
}

fn outputFromId(id: u64) ?*Output {
    var it = server.om.outputs.iterator(.forward);
    while (it.next()) |o| {
        if (outputId(o) == id) return o;
    }
    return null;
}

fn makeCompositorWindow(win: *Window, alloc: Allocator) !protocols.Window {
    const title_c = win.getTitle();
    const app_id_c = win.getAppId();
    const title = if (title_c) |c| try alloc.dupe(u8, std.mem.sliceTo(c, 0)) else try alloc.dupe(u8, "");
    errdefer if (title.len > 0) alloc.free(title);
    const app_id = if (app_id_c) |c| try alloc.dupe(u8, std.mem.sliceTo(c, 0)) else try alloc.dupe(u8, "");
    errdefer if (app_id.len > 0) alloc.free(app_id);
    // Use ref id for stable mapping
    const id = windowIdFromRef(win.ref);
    // Find output for window if fullscreen else primary
    const out_id: u64 = if (win.wm_requested.fullscreen) |o| outputId(o) else 0;
    // Workspace: we synthesize single workspace 1
    return .{
        .id = id,
        .title = title,
        .app_id = app_id,
        .workspace = 1,
        .output = out_id,
        .pid = @intCast(@max(0, win.unreliablePid())),
        .rect = .{ .x = win.box.x, .y = win.box.y, .width = @intCast(@max(0, win.box.width)), .height = @intCast(@max(0, win.box.height)) },
        .floating = false,
        .fullscreen = win.wm_requested.fullscreen != null,
        .focused = blk: {
            var it = server.input_manager.seats.iterator(.forward);
            while (it.next()) |seat| {
                if (seat.focused == .window and seat.focused.window == win) break :blk true;
            }
            break :blk false;
        },
        .urgent = false,
    };
}

fn makeCompositorOutput(out: *Output, alloc: Allocator) !protocols.Output {
    const wlr_out = out.wlr_output;
    const name = if (wlr_out) |w| try alloc.dupe(u8, std.mem.sliceTo(w.name, 0)) else try alloc.dupe(u8, "unknown");
    errdefer if (name.len > 0) alloc.free(name);
    const make = if (wlr_out) |w| if (w.make) |m| try alloc.dupe(u8, std.mem.sliceTo(m, 0)) else try alloc.dupe(u8, "") else try alloc.dupe(u8, "");
    errdefer if (make.len > 0) alloc.free(make);
    const model = if (wlr_out) |w| if (w.model) |m| try alloc.dupe(u8, std.mem.sliceTo(m, 0)) else try alloc.dupe(u8, "") else try alloc.dupe(u8, "");
    errdefer if (model.len > 0) alloc.free(model);
    const box = out.current.box();
    const has_mode = out.current.mode != .none;
    const mode = if (has_mode) blk: {
        const w, const h = out.current.dimensions();
        break :blk protocols.Mode{ .width = w, .height = h, .refresh = 60000 };
    } else protocols.Mode{};

    return .{
        .id = outputId(out),
        .name = name,
        .make = make,
        .model = model,
        .x = box.x,
        .y = box.y,
        .mode = mode,
        .scale = @intFromFloat(out.current.scale * 1000),
        .enabled = out.current.state == .enabled,
    };
}

// ---------------------------------------------------------------------------
// Async mutation dispatch via Wayland pipe
// ---------------------------------------------------------------------------

const AsyncOp = union(enum) {
    focus_window: u64,
    close_window: u64,
    move_window: struct { id: u64, x: i32, y: i32 },
    resize_window: struct { id: u64, width: u32, height: u32 },
};

const DummyMutex = struct {
    fn lock(_: *@This()) void {}
    fn unlock(_: *@This()) void {}
};
var bank_mutex: DummyMutex = .{};
var async_queue: std.ArrayList(AsyncOp) = .empty;
var pipe_fds: [2]posix.fd_t = .{ -1, -1 };
var bank_event_source: ?*wl.EventSource = null;
var bank_alloc: Allocator = undefined;

fn handlePipe(_: c_int, _: wl.EventMask, _: ?*anyopaque) c_int {
    // Drain pipe (single read, pipe is blocking but data is guaranteed)
    var buf: [64]u8 = undefined;
    _ = posix.read(pipe_fds[0], &buf) catch {};
    // Process queue on main (Wayland) thread
    bank_mutex.lock();
    const ops = async_queue.toOwnedSlice(bank_alloc) catch &[_]AsyncOp{};
    async_queue = .empty;
    bank_mutex.unlock();
    defer if (ops.len > 0) bank_alloc.free(ops);
    for (ops) |op| {
        switch (op) {
            .focus_window => |id| {
                if (windowFromId(id)) |win| {
                    const seat = server.input_manager.defaultSeat();
                    seat.wm_requested.focus = .{ .window = win.ref };
                    server.wm.dirtyWindowing();
                    log.info("bank: focus window {d}", .{id});
                }
            },
            .close_window => |id| {
                if (windowFromId(id)) |win| {
                    win.wm_requested.close = true;
                    server.wm.dirtyWindowing();
                    log.info("bank: close window {d}", .{id});
                }
            },
            .move_window => |v| {
                if (windowFromId(v.id)) |win| {
                    win.rendering_requested.x = v.x;
                    win.rendering_requested.y = v.y;
                    win.startPosAnimation(v.x, v.y, true);
                    server.wm.dirtyRendering();
                    log.info("bank: move window {d} to {d},{d}", .{ v.id, v.x, v.y });
                }
            },
            .resize_window => |v| {
                if (windowFromId(v.id)) |win| {
                    win.wm_requested.dimensions = .{ .width = @intCast(v.width), .height = @intCast(v.height) };
                    win.startSizeAnimation(@intCast(v.width), @intCast(v.height), true);
                    server.wm.dirtyWindowing();
                    log.info("bank: resize window {d} to {d}x{d}", .{ v.id, v.width, v.height });
                }
            },
        }
    }
    return 0;
}

fn queueAsync(op: AsyncOp) void {
    bank_mutex.lock();
    defer bank_mutex.unlock();
    async_queue.append(bank_alloc, op) catch {
        log.err("bank: async queue append failed", .{});
        return;
    };
    // Wake main loop
    _ = posix.system.write(pipe_fds[1], &[_]u8{1}, 1);
}

// ---------------------------------------------------------------------------
// Request handler
// ---------------------------------------------------------------------------

var bank_gpa: Allocator = undefined;

fn bankCallback(msg: nilebank.Message) anyerror!nilebank.Message {
    const alloc = bank_gpa;
    // Decode request
    const req = nilebank.decodeCompositorRequest(alloc, msg) catch |err| {
        log.warn("bank: decode request failed: {}", .{err});
        const ev: protocols.Event = .{ .error_msg = .{ .code = 1, .message = try alloc.dupe(u8, "invalid request") } };
        defer ev.deinit(alloc);
        const enc = protocols.encodingForEvent(.error_msg);
        return try nilebank.encodeCompositorEvent(alloc, ev, enc);
    };
    defer req.deinit(alloc);

    // Dispatch based on request tag
    const ev: protocols.Event = switch (req) {
        .ping => .{ .pong = .{ .nonce = 0x4E494C45 } }, // "NILE"
        .pong => .{ .pong = .{ .nonce = 0 } },
        .list_windows => blk: {
            var wins: std.ArrayList(protocols.Window) = .empty;
            defer wins.deinit(alloc);
            var it = server.wm.windows.iterator();
            while (it.next()) |win| {
                const cw = try makeCompositorWindow(win, alloc);
                try wins.append(alloc, cw);
            }
            const items = try wins.toOwnedSlice(alloc);
            break :blk .{ .windows = .{ .items = items } };
        },
        .list_workspaces => blk: {
            // Single synthetic workspace
            const ws = try alloc.alloc(protocols.Workspace, 1);
            ws[0] = .{
                .id = 1,
                .number = 1,
                .name = try alloc.dupe(u8, "main"),
                .active = true,
                .current = true,
                .urgent = false,
                .output = if (server.om.outputs.first()) |o| outputId(o) else 0,
            };
            break :blk .{ .workspaces = .{ .items = ws } };
        },
        .list_outputs => blk: {
            var outs: std.ArrayList(protocols.Output) = .empty;
            defer outs.deinit(alloc);
            var it = server.om.outputs.iterator(.forward);
            while (it.next()) |out| {
                if (out.wlr_output == null) continue;
                const co = try makeCompositorOutput(out, alloc);
                try outs.append(alloc, co);
            }
            const items = try outs.toOwnedSlice(alloc);
            break :blk .{ .outputs = .{ .items = items } };
        },
        .get_window => |v| blk: {
            if (windowFromId(v.id)) |win| {
                const cw = try makeCompositorWindow(win, alloc);
                const arr = try alloc.alloc(protocols.Window, 1);
                arr[0] = cw;
                break :blk .{ .windows = .{ .items = arr } };
            } else {
                break :blk .{ .error_msg = .{ .code = 2, .message = try alloc.dupe(u8, "window not found") } };
            }
        },
        .get_output => |v| blk: {
            if (outputFromId(v.id)) |out| {
                const co = try makeCompositorOutput(out, alloc);
                const arr = try alloc.alloc(protocols.Output, 1);
                arr[0] = co;
                break :blk .{ .outputs = .{ .items = arr } };
            } else {
                break :blk .{ .error_msg = .{ .code = 2, .message = try alloc.dupe(u8, "output not found") } };
            }
        },
        .get_workspace => |v| blk: {
            if (v.id == 1) {
                const ws = try alloc.alloc(protocols.Workspace, 1);
                ws[0] = .{
                    .id = 1,
                    .number = 1,
                    .name = try alloc.dupe(u8, "main"),
                    .active = true,
                    .current = true,
                    .urgent = false,
                    .output = if (server.om.outputs.first()) |o| outputId(o) else 0,
                };
                break :blk .{ .workspaces = .{ .items = ws } };
            } else {
                break :blk .{ .error_msg = .{ .code = 2, .message = try alloc.dupe(u8, "workspace not found") } };
            }
        },
        .subscribe => .{ .pong = .{ .nonce = 0 } },
        .unsubscribe => .{ .pong = .{ .nonce = 0 } },
        .capture_full, .capture_output, .capture_window => .{
            .error_msg = .{ .code = 3, .message = try alloc.dupe(u8, "capture not implemented") },
        },
        .focus_window => |v| blk: {
            queueAsync(.{ .focus_window = v.id });
            break :blk .{ .pong = .{ .nonce = v.id } };
        },
        .close_window => |v| blk: {
            queueAsync(.{ .close_window = v.id });
            break :blk .{ .pong = .{ .nonce = v.id } };
        },
        .move_window => |v| blk: {
            queueAsync(.{ .move_window = .{ .id = v.id, .x = v.x, .y = v.y } });
            break :blk .{ .pong = .{ .nonce = v.id } };
        },
        .resize_window => |v| blk: {
            queueAsync(.{ .resize_window = .{ .id = v.id, .width = v.width, .height = v.height } });
            break :blk .{ .pong = .{ .nonce = v.id } };
        },
        .switch_workspace => |v| blk: {
            _ = v;
            break :blk .{ .error_msg = .{ .code = 4, .message = try alloc.dupe(u8, "workspaces not implemented") } };
        },
        .set_workspace_name => |v| blk: {
            // v.name is owned by req, will be freed after. For now just ack.
            _ = v;
            break :blk .{ .error_msg = .{ .code = 4, .message = try alloc.dupe(u8, "workspaces not implemented") } };
        },
        .full_image, .window_image => .{
            .error_msg = .{ .code = 3, .message = try alloc.dupe(u8, "legacy image not implemented, use capture_*") },
        },
    };

    // Choose encoding per kind default
    const tag: protocols.EventTag = @as(protocols.EventTag, ev);
    const enc = protocols.encodingForEvent(tag);
    // Encode: need to handle heap ownership
    var ev_mut = ev;
    defer ev_mut.deinit(alloc);
    const msg_out = try nilebank.encodeCompositorEvent(alloc, ev_mut, enc);
    return msg_out;
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

var bank_threaded: ?*Io.Threaded = null;
var bank_server_obj: ?*nilebank.Server = null;

pub fn init() !void {
    bank_alloc = util.gpa;
    bank_gpa = util.gpa;

    // Ensure socket directory exists: /run/arcos
    const dir_path = "/run/arcos";
    {
        const io = Io.Threaded.global_single_threaded.io();
        Io.Dir.createDirAbsolute(io, dir_path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => log.warn("bank: failed to create {s}: {}", .{ dir_path, err }),
        };
    }

    // Also ensure /tmp fallback for tests/headless where /run/arcos not writable
    // Try to create socket dir via mkdir -p logic: if /run/arcos fails, use /tmp/arcos
    // But nilebank serve uses fixed path "/run/arcos/compositor.sock" – we must ensure it exists.

    // Create pipe for async dispatch
    {
        var fds: [2]c_int = undefined;
        if (posix.system.pipe(&fds) != 0) return error.PipeFailed;
        pipe_fds = fds;
    }

    bank_event_source = try server.wl_server.getEventLoop().addFd(
        ?*anyopaque,
        pipe_fds[0],
        .{ .readable = true },
        handlePipe,
        null,
    );

    // Start nilebank server on threaded Io
    const threaded = try bank_alloc.create(Io.Threaded);
    threaded.* = Io.Threaded.init(bank_alloc, .{});
    bank_threaded = threaded;
    const io = threaded.io();

    // Remove stale socket if any
    Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    bank_server_obj = try nilebank.serve(bank_alloc, io, socket_id, bankCallback);
    log.info("bank: listening on {s} (id={s})", .{ socket_path, socket_id });
}

pub fn deinit() void {
    if (bank_server_obj) |s| {
        s.deinit();
        bank_server_obj = null;
    }
    if (bank_threaded) |t| {
        t.deinit();
        bank_alloc.destroy(t);
        bank_threaded = null;
    }
    if (bank_event_source) |es| {
        es.remove();
        bank_event_source = null;
    }
    if (pipe_fds[0] != -1) {
        _ = posix.system.close(pipe_fds[0]);
        pipe_fds[0] = -1;
    }
    if (pipe_fds[1] != -1) {
        _ = posix.system.close(pipe_fds[1]);
        pipe_fds[1] = -1;
    }
    bank_mutex.lock();
    async_queue.deinit(bank_alloc);
    async_queue = .empty;
    bank_mutex.unlock();
}
