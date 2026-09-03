// SPDX-FileCopyrightText: © 2026 The Nile Developers
// SPDX-License-Identifier: GPL-3.0-only

//! NileBank — nilebank IPC integration for Nile.
//! Socket ID is "compositor" → path "/run/arcos/compositor.sock"
//! Handles compositor protocol requests via `nilebank` library.
//! Read queries are served synchronously (with best-effort main-thread
//! dispatch for mutation ops via Wayland event loop pipe).

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
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
const Compositor = @import("Compositor.zig");

const log = std.log.scoped(.bank);

pub const socket_id = "compositor";
// NOTE: `nilebank.serve` hardcodes its socket dir to `/tmp/arcos/`, so the
// request/response socket is actually `/tmp/arcos/compositor.sock`
// (not `/run/arcos/`). The event stream below uses the same directory.
pub const socket_path = "/tmp/arcos/" ++ socket_id ++ ".sock";

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

/// True if any seat currently focuses `win`.
fn isWindowFocused(win: *Window) bool {
    var it = server.input_manager.seats.iterator(.forward);
    while (it.next()) |seat| {
        if (seat.focused == .window and seat.focused.window == win) return true;
    }
    return false;
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
    return .{
        .id = id,
        .title = title,
        .app_id = app_id,
        .workspace = win.wm_requested.workspace,
        .output = out_id,
        .pid = @intCast(@max(0, win.unreliablePid())),
        .rect = .{ .x = win.box.x, .y = win.box.y, .width = @intCast(@max(0, win.box.width)), .height = @intCast(@max(0, win.box.height)) },
        .floating = false,
        .fullscreen = win.wm_requested.fullscreen != null,
        .focused = isWindowFocused(win),
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

/// Collect all known windows. Returned slice and every item's strings are
/// owned by the caller: deinit each item, then free the slice.
fn collectWindows(alloc: Allocator) ![]protocols.Window {
    var wins: std.ArrayList(protocols.Window) = .empty;
    errdefer {
        for (wins.items) |w| w.deinit(alloc);
        wins.deinit(alloc);
    }
    var it = server.wm.windows.iterator();
    while (it.next()) |win| {
        try wins.append(alloc, try makeCompositorWindow(win, alloc));
    }
    return wins.toOwnedSlice(alloc);
}

/// Collect all outputs with a backing `wlr_output`. Same ownership as `collectWindows`.
fn collectOutputs(alloc: Allocator) ![]protocols.Output {
    var outs: std.ArrayList(protocols.Output) = .empty;
    errdefer {
        for (outs.items) |o| o.deinit(alloc);
        outs.deinit(alloc);
    }
    var it = server.om.outputs.iterator(.forward);
    while (it.next()) |out| {
        if (out.wlr_output == null) continue;
        try outs.append(alloc, try makeCompositorOutput(out, alloc));
    }
    return outs.toOwnedSlice(alloc);
}

/// Collect all workspaces. Same ownership as `collectWindows`.
fn collectWorkspaces(alloc: Allocator) ![]protocols.Workspace {
    const ws_list = try server.workspace.listWorkspaces(alloc);
    defer {
        for (ws_list) |*ws| ws.deinit(alloc);
        alloc.free(ws_list);
    }
    var items: std.ArrayList(protocols.Workspace) = .empty;
    errdefer {
        for (items.items) |ws| ws.deinit(alloc);
        items.deinit(alloc);
    }
    for (ws_list) |ws| {
        try items.append(alloc, .{
            .id = ws.id,
            .number = @truncate(ws.number),
            .name = if (ws.name.len > 0) try alloc.dupe(u8, ws.name) else "",
            .active = ws.active,
            .current = ws.current,
            .urgent = ws.urgent,
            .output = ws.output,
        });
    }
    return items.toOwnedSlice(alloc);
}

/// Build a full `protocols.Workspace` for one id, or null if unknown.
fn makeCompositorWorkspace(id: u64, alloc: Allocator) !?protocols.Workspace {
    const ws_list = try server.workspace.listWorkspaces(alloc);
    defer {
        for (ws_list) |*ws| ws.deinit(alloc);
        alloc.free(ws_list);
    }
    for (ws_list) |ws| {
        if (ws.id != id) continue;
        return protocols.Workspace{
            .id = ws.id,
            .number = @truncate(ws.number),
            .name = if (ws.name.len > 0) try alloc.dupe(u8, ws.name) else "",
            .active = ws.active,
            .current = ws.current,
            .urgent = ws.urgent,
            .output = ws.output,
        };
    }
    return null;
}

// ---------------------------------------------------------------------------
// Async mutation dispatch via Wayland pipe
// ---------------------------------------------------------------------------

const AsyncOp = union(enum) {
    focus_window: u64,
    close_window: u64,
    move_window: struct { id: u64, x: i32, y: i32 },
    resize_window: struct { id: u64, width: u32, height: u32 },
    switch_workspace: u64,
    // `name` is heap-owned; freed on the main thread after applying.
    set_workspace_name: struct { id: u64, name: []u8 },
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
            .switch_workspace => |id| {
                // Runs on the main thread so the switch (and the events +
                // broadcasts it emits) never races the Wayland event loop.
                _ = server.workspace.switchWorkspace(id) catch |err| {
                    log.warn("bank: switch workspace {d} failed: {}", .{ id, err });
                };
            },
            .set_workspace_name => |v| {
                defer if (v.name.len > 0) bank_alloc.free(v.name);
                server.workspace.setWorkspaceName(bank_alloc, v.id, v.name) catch |err| {
                    log.warn("bank: rename workspace {d} failed: {}", .{ v.id, err });
                };
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
        // The op is dropped — free any heap it owns to avoid leaking.
        if (op == .set_workspace_name and op.set_workspace_name.name.len > 0) {
            bank_alloc.free(op.set_workspace_name.name);
        }
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
            const items = try collectWindows(alloc);
            break :blk .{ .windows = .{ .items = items } };
        },
        .list_workspaces => blk: {
            const items = try collectWorkspaces(alloc);
            break :blk .{ .workspaces = .{ .items = items } };
        },
        .get_workspace => |v| blk: {
            if (server.workspace.getWorkspace(v.id, alloc)) |ws| {
                defer ws.deinit(alloc);
                const items = try alloc.alloc(protocols.Workspace, 1);
                items[0] = .{
                    .id = ws.id,
                    .number = @truncate(ws.number),
                    .name = if (ws.name.len > 0) try alloc.dupe(u8, ws.name) else "",
                    .active = ws.active,
                    .current = ws.current,
                    .urgent = ws.urgent,
                    .output = ws.output,
                };
                break :blk .{ .workspaces = .{ .items = items } };
            } else {
                break :blk .{ .error_msg = .{ .code = 2, .message = try alloc.dupe(u8, "workspace not found") } };
            }
        },
        .list_outputs => blk: {
            const items = try collectOutputs(alloc);
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
            // Applied on the main thread via the async queue (see handlePipe)
            // so the switch can't race the Wayland event loop. The resulting
            // `workspace_activated`/`workspace_deactivated` events are pushed
            // to event-stream subscribers; here we just ack.
            queueAsync(.{ .switch_workspace = v.id });
            break :blk .{ .pong = .{ .nonce = v.id } };
        },
        .set_workspace_name => |v| blk: {
            // Same main-thread routing as switch_workspace. The name is
            // duplicated because `req` (and its strings) is freed when this
            // callback returns, while the queued op runs later.
            const owned = alloc.dupe(u8, v.name) catch break :blk .{
                .error_msg = .{ .code = 1, .message = try alloc.dupe(u8, "out of memory") },
            };
            queueAsync(.{ .set_workspace_name = .{ .id = v.id, .name = owned } });
            break :blk .{ .pong = .{ .nonce = v.id } };
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
// Event stream — push state changes to shell clients
// ---------------------------------------------------------------------------
//
// The request/response socket above can only answer queries. Shells also need
// *push* ("workspace 2 is active now", "window 7 closed") without polling,
// plus the full current state the moment they connect so they can catch up.
// That is what this second socket provides:
//
//   path:    /tmp/arcos/compositor-events.sock
//   framing: [kind: u8][encoding: u8][length: u16 BE][payload] per message
//            (same Header layout as nilebank; decode the payload with
//            `protocols.compositor.Event.decodeAllocWith(alloc, kind, payload, encoding)`)
//   on connect the server immediately sends, in order:
//            windows_snapshot, workspaces_snapshot, outputs_snapshot
//   then one message per state change as it happens (see `onCompositorEvent`).
//
// All stream state lives on the main Wayland thread: the listener is polled
// by the Wayland event loop and `broadcast` is only called from the
// `Compositor.broadcast_hook` (main thread) or the async-queue drain (also
// main thread). Subscriber sockets are nonblocking; a client that cannot keep
// up (short write / EAGAIN) is disconnected and expected to reconnect and
// re-read the snapshots.

pub const event_socket_id = "compositor-events";
pub const event_socket_path = "/tmp/arcos/" ++ event_socket_id ++ ".sock";

var event_listener_fd: posix.fd_t = -1;
var event_listener_source: ?*wl.EventSource = null;
/// Main-thread only. Nonblocking fds, pruned lazily on write failure.
var event_subscribers: std.ArrayList(posix.fd_t) = .empty;

fn writeAllNonblock(fd: posix.fd_t, buf: []const u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.write(fd, buf.ptr + off, buf.len - off);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.Closed;
                off += n;
            },
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .PIPE => return error.Closed,
            else => return error.WriteFailed,
        }
    }
}

fn writeFramed(fd: posix.fd_t, kind: u8, encoding: nilebank.Encoding, payload: []const u8) !void {
    if (payload.len > std.math.maxInt(u16)) return error.TooLarge;
    var hdr: [nilebank.Header.size]u8 = undefined;
    hdr[0] = kind;
    hdr[1] = @intFromEnum(encoding);
    std.mem.writeInt(u16, hdr[2..4], @intCast(payload.len), .big);
    try writeAllNonblock(fd, &hdr);
    try writeAllNonblock(fd, payload);
}

fn encodeEvent(ev: protocols.Event) !nilebank.Message {
    const tag: protocols.EventTag = @as(protocols.EventTag, ev);
    return nilebank.encodeCompositorEvent(bank_alloc, ev, protocols.encodingForEvent(tag));
}

/// Encode `ev` and write it to `fd`. Consumes `ev` (frees its heap on return).
fn sendEventTo(fd: posix.fd_t, ev: protocols.Event) !void {
    var ev_mut = ev;
    defer ev_mut.deinit(bank_alloc);
    const msg = try encodeEvent(ev_mut);
    defer if (msg.data.len > 0) bank_alloc.free(@constCast(msg.data));
    try writeFramed(fd, msg.kind, msg.encoding, msg.data);
}

/// Push `ev` to all event-stream subscribers. Consumes `ev`. Slow or dead
/// clients are disconnected (they re-sync via snapshots on reconnect).
/// No-op when nobody is subscribed.
pub fn broadcast(ev: protocols.Event) void {
    if (event_subscribers.items.len == 0) {
        var drop = ev;
        drop.deinit(bank_alloc);
        return;
    }
    var ev_mut = ev;
    defer ev_mut.deinit(bank_alloc);
    const msg = encodeEvent(ev_mut) catch |err| {
        log.warn("event stream: encode failed: {}", .{err});
        return;
    };
    defer if (msg.data.len > 0) bank_alloc.free(@constCast(msg.data));
    var i = event_subscribers.items.len;
    while (i > 0) {
        i -= 1;
        const fd = event_subscribers.items[i];
        writeFramed(fd, msg.kind, msg.encoding, msg.data) catch {
            _ = posix.system.close(fd);
            _ = event_subscribers.swapRemove(i);
            log.info("event stream: dropped slow subscriber (fd={d})", .{fd});
        };
    }
}

/// Catch-up: full state snapshot for a freshly connected subscriber.
fn sendSnapshotsTo(fd: posix.fd_t) !void {
    {
        const items = try collectWindows(bank_alloc);
        try sendEventTo(fd, .{ .windows_snapshot = .{ .items = items } });
    }
    {
        const items = try collectWorkspaces(bank_alloc);
        try sendEventTo(fd, .{ .workspaces_snapshot = .{ .items = items } });
    }
    {
        const items = try collectOutputs(bank_alloc);
        try sendEventTo(fd, .{ .outputs_snapshot = .{ .items = items } });
    }
}

fn handleEventStream(_: c_int, _: wl.EventMask, _: ?*anyopaque) c_int {
    while (true) {
        const rc = linux.accept4(
            event_listener_fd,
            null,
            null,
            linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC,
        );
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => break,
            .INTR => continue,
            else => |err| {
                log.warn("event stream: accept failed: {}", .{err});
                break;
            },
        }
        const fd: posix.fd_t = @intCast(rc);
        sendSnapshotsTo(fd) catch |err| {
            log.warn("event stream: snapshot send failed: {}", .{err});
            _ = posix.system.close(fd);
            continue;
        };
        event_subscribers.append(bank_alloc, fd) catch {
            _ = posix.system.close(fd);
            continue;
        };
        log.info("event stream: new subscriber (fd={d})", .{fd});
    }
    return 0;
}

fn eventStreamInit() !void {
    const fd_rc = linux.socket(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
        0,
    );
    if (linux.errno(fd_rc) != .SUCCESS) return error.SocketFailed;
    const fd: posix.fd_t = @intCast(fd_rc);
    errdefer _ = posix.system.close(fd);

    {
        const io = Io.Threaded.global_single_threaded.io();
        Io.Dir.deleteFileAbsolute(io, event_socket_path) catch {};
    }

    const SockAddrUn = extern struct {
        family: u16,
        path: [108]u8,
    };
    var addr = std.mem.zeroes(SockAddrUn);
    addr.family = posix.AF.UNIX;
    if (event_socket_path.len + 1 > addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..event_socket_path.len], event_socket_path);
    const addr_len: posix.socklen_t = @intCast(@sizeOf(u16) + event_socket_path.len + 1);
    if (linux.errno(linux.bind(fd, @ptrCast(&addr), addr_len)) != .SUCCESS) return error.BindFailed;
    if (linux.errno(linux.listen(fd, 16)) != .SUCCESS) return error.ListenFailed;

    event_listener_source = try server.wl_server.getEventLoop().addFd(
        ?*anyopaque,
        fd,
        .{ .readable = true },
        handleEventStream,
        null,
    );
    event_listener_fd = fd;
    log.info("bank: event stream listening on {s}", .{event_socket_path});
}

fn eventStreamDeinit() void {
    if (event_listener_source) |es| {
        es.remove();
        event_listener_source = null;
    }
    if (event_listener_fd != -1) {
        _ = posix.system.close(event_listener_fd);
        event_listener_fd = -1;
        const io = Io.Threaded.global_single_threaded.io();
        Io.Dir.deleteFileAbsolute(io, event_socket_path) catch {};
    }
    for (event_subscribers.items) |fd| _ = posix.system.close(fd);
    event_subscribers.deinit(bank_alloc);
    event_subscribers = .empty;
}

fn windowIdOrZero(win: ?*Window) u64 {
    return if (win) |w| windowIdFromRef(w.ref) else 0;
}

fn windowStateEvent(win: *Window) protocols.Event {
    return .{ .window_state_changed = .{
        .id = windowIdFromRef(win.ref),
        .floating = false,
        .fullscreen = win.wm_requested.fullscreen != null,
        .urgent = false,
        .focused = isWindowFocused(win),
    } };
}

/// Translate compositor policy events into shell protocol events and push
/// them to event-stream subscribers. Runs on the main Wayland thread via the
/// `Compositor.broadcast_hook`. High-frequency noise (pointer motion/buttons,
/// frame ticks, keybinds) is deliberately skipped — shells re-query on demand.
fn onCompositorEvent(event: Compositor.Event) void {
    switch (event) {
        .window_add => |win| {
            const title_c = win.getTitle();
            const title = if (title_c) |c| std.mem.sliceTo(c, 0) else "";
            const owned = bank_alloc.dupe(u8, title) catch return;
            broadcast(.{ .new_window = .{ .title = owned, .id = windowIdFromRef(win.ref) } });
        },
        .window_map => |win| broadcast(windowStateEvent(win)),
        .window_unmap => |win| broadcast(windowStateEvent(win)),
        .window_destroy => |win| broadcast(.{ .window_closed = .{ .id = windowIdFromRef(win.ref) } }),
        .window_title_changed => |win| {
            const title_c = win.getTitle();
            const title = if (title_c) |c| std.mem.sliceTo(c, 0) else "";
            const owned = bank_alloc.dupe(u8, title) catch return;
            broadcast(.{ .window_title_changed = .{ .id = windowIdFromRef(win.ref), .title = owned } });
        },
        .window_app_id_changed => |win| {
            const app_c = win.getAppId();
            const app_id = if (app_c) |c| std.mem.sliceTo(c, 0) else "";
            const owned = bank_alloc.dupe(u8, app_id) catch return;
            broadcast(.{ .window_app_id_changed = .{ .id = windowIdFromRef(win.ref), .app_id = owned } });
        },
        .window_fullscreen_request => |req| broadcast(windowStateEvent(req.window)),
        .window_maximize_request => |req| broadcast(windowStateEvent(req.window)),
        .window_minimize_request => |win| broadcast(windowStateEvent(win)),
        .window_parent_changed => {},
        .pointer_motion => {},
        .pointer_button => {},
        .output_add => |out| {
            const full = makeCompositorOutput(out, bank_alloc) catch return;
            broadcast(.{ .output_added = full });
        },
        .output_remove => |out| broadcast(.{ .output_removed = .{ .id = outputId(out) } }),
        .output_update => |out| {
            const full = makeCompositorOutput(out, bank_alloc) catch return;
            broadcast(.{ .output_changed = full });
        },
        .seat_add => {},
        .seat_remove => {},
        .input_device_add => {},
        .input_device_remove => {},
        .keybind_pressed => {},
        .keybind_released => {},
        .frame => {},
        .window_focus_changed => |v| broadcast(.{ .window_focused = .{
            .id = windowIdOrZero(v.new),
            .old_id = windowIdOrZero(v.old),
        } }),
        .window_workspace_changed => |v| broadcast(.{ .window_workspace_changed = .{
            .id = windowIdFromRef(v.window.ref),
            .old_workspace = v.old_id,
            .new_workspace = v.new_id,
        } }),
        .workspace_switched => |v| {
            broadcast(.{ .workspace_deactivated = .{ .id = v.old_id } });
            broadcast(.{ .workspace_activated = .{ .id = v.new_id } });
            broadcast(.{ .switch_workspace = .{ .index = @truncate(server.workspace.getWorkspaceNumber(v.new_id)) } });
        },
        .workspace_created => |id| {
            const full = makeCompositorWorkspace(id, bank_alloc) catch return;
            if (full) |ws| broadcast(.{ .workspace_created = ws });
        },
        .workspace_removed => |id| broadcast(.{ .workspace_removed = .{ .id = id } }),
        .workspace_renamed => {
            // No dedicated rename event in the protocol; push a full snapshot instead.
            const items = collectWorkspaces(bank_alloc) catch return;
            broadcast(.{ .workspaces_snapshot = .{ .items = items } });
        },
    }
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

var bank_threaded: ?*Io.Threaded = null;
var bank_server_obj: ?*nilebank.Server = null;

pub fn init() !void {
    bank_alloc = util.gpa;
    bank_gpa = util.gpa;

    // Ensure socket directory exists. Note `nilebank.serve` hardcodes its
    // socket dir to `/tmp/arcos/` (see `socket_path` above); /run/arcos is
    // kept as a best-effort legacy path.
    const dir_path = "/run/arcos";
    {
        const io = Io.Threaded.global_single_threaded.io();
        Io.Dir.createDirAbsolute(io, dir_path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => log.warn("bank: failed to create {s}: {}", .{ dir_path, err }),
        };
    }

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

    // Push channel for shells. Best-effort: queries keep working if it fails.
    eventStreamInit() catch |err| {
        log.warn("bank: event stream unavailable: {}", .{err});
    };
    Compositor.setBroadcastHook(&onCompositorEvent);
}

pub fn deinit() void {
    Compositor.broadcast_hook = null;
    eventStreamDeinit();
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
