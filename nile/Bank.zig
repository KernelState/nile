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

/// Windows in most-recently-focused order (index 0 = currently focused).
/// Main-thread only: mutated from `onCompositorEvent`, read from the
/// request thread in `collectWindows` (same threading as the existing
/// `server.wm.windows` reads there). Holds `Ref`s, so destroyed windows
/// never dangle — stale entries are skipped on read and pruned on write.
var focus_order: std.ArrayList(Window.Ref) = .empty;

fn focusOrderIndexOf(ref: Window.Ref) ?usize {
    for (focus_order.items, 0..) |item, i| {
        if (item.key.index == ref.key.index and item.key.generation == ref.key.generation) return i;
    }
    return null;
}

/// Insert `ref` at the front (index 0). Caller must have removed any
/// existing entry first (or know it is absent).
fn focusOrderInsertFront(ref: Window.Ref) void {
    focus_order.append(bank_alloc, undefined) catch return;
    const items = focus_order.items;
    var i = items.len - 1;
    while (i > 0) {
        items[i] = items[i - 1];
        i -= 1;
    }
    items[0] = ref;
}

/// Move `win` to the front; append to the back first if never seen so no
/// live window is ever missing from the list.
fn focusOrderTrack(win: *Window) void {
    if (focusOrderIndexOf(win.ref)) |idx| _ = focus_order.orderedRemove(idx);
    focusOrderInsertFront(win.ref);
}

/// Ensure `win` is present without changing existing order (new windows go
/// to the back; the later `window_focus_changed` moves them to front).
fn focusOrderEnsure(win: *Window) void {
    if (focusOrderIndexOf(win.ref) == null) focus_order.append(bank_alloc, win.ref) catch {};
}

/// Drop `ref` from the list (window destroyed). Order of the rest is kept.
fn focusOrderRemove(ref: Window.Ref) void {
    if (focusOrderIndexOf(ref)) |idx| _ = focus_order.orderedRemove(idx);
}

// ---------------------------------------------------------------------------
// Window thumbnails — a ~1fps main-thread sweep + instant serve.
//
// Why a cache: client buffers may only be touched on the Wayland main
// thread (a concurrent commit/destroy on another thread would be a
// use-after-free), while `bankCallback` runs on the bank IO thread. So the
// main thread grabs small RGBA thumbs into `thumbs` once a second and
// `capture_window` serves the latest one immediately — the moment the shell
// clicks, it gets a frame at most ~1s old.
//
// Payload budget: nilebank frames cap at 65535 bytes (`Header.length: u16`,
// which would panic on overflow), so thumbs are at most 256px wide and the
// serve path halves them until the deflated payload fits.
// ---------------------------------------------------------------------------

const thumb_max_width: usize = 256;
const thumb_interval_ms: c_int = 1000;
const thumb_max_payload: usize = 60000;

const Thumb = struct {
    width: u32,
    height: u32,
    rgba: []u8, // tightly packed, bank_alloc owned
};

var thumbs: std.AutoHashMap(u64, Thumb) = undefined;
var thumbs_init: bool = false;
var thumbs_mu: Io.Mutex = .init;
var thumb_timer: ?*wl.EventSource = null;

/// `Io` handle for the bank request thread (owns `bank_threaded`, set in
/// `init` before serving starts). Only used for short mutex holds.
fn ioForRequestThread() Io {
    return bank_threaded.?.io();
}

/// `Io` handle for the Wayland main thread (timer sweep, event prune,
/// deinit). Only used for short mutex holds.
fn ioForMainThread() Io {
    return Io.Threaded.global_single_threaded.io();
}

fn drmFourcc(a: u8, b: u8, c: u8, d: u8) u32 {
    return @as(u32, a) | (@as(u32, b) << 8) | (@as(u32, c) << 16) | (@as(u32, d) << 24);
}

const drm_argb8888 = drmFourcc('A', 'R', '2', '4');
const drm_xrgb8888 = drmFourcc('X', 'R', '2', '4');
const drm_abgr8888 = drmFourcc('A', 'B', '2', '4');
const drm_xbgr8888 = drmFourcc('X', 'B', '2', '4');

/// Nearest-neighbor RGBA downscale. Main-thread or IO-thread safe: pure
/// memcpy math on caller-owned slices.
fn downscaleRgba(alloc: Allocator, src: []const u8, sw: usize, sh: usize, dw: usize, dh: usize) ![]u8 {
    const out = try alloc.alloc(u8, dw * dh * 4);
    errdefer alloc.free(out);
    var y: usize = 0;
    while (y < dh) : (y += 1) {
        const sy = y * sh / dh;
        var x: usize = 0;
        while (x < dw) : (x += 1) {
            const sx = x * sw / dw;
            @memcpy(out[(y * dw + x) * 4 ..][0..4], src[(sy * sw + sx) * 4 ..][0..4]);
        }
    }
    return out;
}

/// Convert 32-bit source pixels to a small owned RGBA thumb (downscaling
/// with nearest-neighbor). Pure CPU math on caller-owned memory.
fn convertToThumb(src: [*]const u8, stride: usize, bw: usize, bh: usize, format: u32) !Thumb {
    const swap_rb = switch (format) {
        drm_argb8888, drm_xrgb8888 => true, // LE bytes are B,G,R,A
        drm_abgr8888, drm_xbgr8888 => false, // LE bytes are R,G,B,A
        else => return error.UnsupportedFormat,
    };
    const has_alpha = (format == drm_argb8888 or format == drm_abgr8888);

    var tw: usize = if (bw > thumb_max_width) thumb_max_width else bw;
    var th: usize = bh * tw / bw;
    if (th == 0) th = 1;
    if (tw == 0) tw = 1;

    const out = try bank_alloc.alloc(u8, tw * th * 4);
    errdefer bank_alloc.free(out);
    const bpp: usize = 4;
    var y: usize = 0;
    while (y < th) : (y += 1) {
        const sy = y * bh / th;
        const srow = src[sy * stride ..][0 .. bw * bpp];
        const drow = out[y * tw * 4 ..][0 .. tw * 4];
        var x: usize = 0;
        while (x < tw) : (x += 1) {
            const sx = x * bw / tw;
            const s = srow[sx * 4 ..][0..4];
            const d = drow[x * 4 ..][0..4];
            d[0] = if (swap_rb) s[2] else s[0];
            d[1] = s[1];
            d[2] = if (swap_rb) s[0] else s[2];
            d[3] = if (has_alpha) s[3] else 255;
        }
    }
    return .{ .width = @intCast(tw), .height = @intCast(th), .rgba = out };
}

/// Grab one window's current client buffer into a small owned RGBA thumb.
/// Main thread only (timer / map hook): no client commit or destroy can
/// interleave, so buffer pointers stay valid throughout.
///
/// Two paths: direct CPU mapping first (free for SHM, cheap for mappable
/// dmabuf), then renderer texture readback (works for any GPU buffer at
/// the cost of a GPU round-trip). Either may fail per window per sweep;
/// the caller keeps the stale frame then.
fn grabWindowThumb(win: *Window) !Thumb {
    const surf = win.rootSurface() orelse return error.NoSurface;
    const cur = &surf.current;
    const src_buf = cur.buffer orelse return error.NoBuffer;
    const bw: usize = @intCast(cur.buffer_width);
    const bh: usize = @intCast(cur.buffer_height);
    if (bw == 0 or bh == 0 or bw > 16384 or bh > 16384) return error.BadDims;

    // Fast path: direct CPU mapping.
    {
        var data: *anyopaque = undefined;
        var format: u32 = 0;
        var stride: usize = 0;
        if (src_buf.beginDataPtrAccess(wlr.Buffer.data_ptr_access_flag.read, &data, &format, &stride)) {
            defer src_buf.endDataPtrAccess();
            if (stride >= bw * 4) {
                const bytes: [*]const u8 = @ptrCast(data);
                const fast = convertToThumb(bytes, stride, bw, bh, format) catch |err| blk: {
                    if (err != error.UnsupportedFormat) return err;
                    // else fall through to texture readback
                    break :blk null;
                };
                if (fast) |thumb| return thumb;
            }
        }
    }

    // Fallback: renderer texture readback (GPU buffers that refuse mapping).
    const tex = wlr.Texture.fromBuffer(server.renderer, src_buf) orelse return error.TextureImportFailed;
    defer tex.destroy();
    const format = tex.preferredReadFormat();
    switch (format) {
        drm_argb8888, drm_xrgb8888, drm_abgr8888, drm_xbgr8888 => {},
        else => return error.UnsupportedFormat,
    }
    const tmp = try bank_alloc.alloc(u8, bw * bh * 4);
    defer bank_alloc.free(tmp);
    const tmp_ptr: *anyopaque = tmp.ptr;
    if (!tex.readPixels(&.{
        .data = tmp_ptr,
        .format = format,
        .stride = @intCast(bw * 4),
        .dst_x = 0,
        .dst_y = 0,
        .src_box = .{ .x = 0, .y = 0, .width = @intCast(bw), .height = @intCast(bh) },
    })) return error.ReadbackFailed;
    return convertToThumb(tmp.ptr, bw * 4, bw, bh, format);
}

/// Consecutive sweeps with live windows but zero cached frames, and the
/// last grab error seen. Feeds the self-silencing warn below so a broken
/// pipeline is visible on the terminal instead of failing silently.
var thumbs_empty_sweeps: u32 = 0;
var thumbs_last_err: ?anyerror = null;

/// Refresh every live window's thumb; drop thumbs of dead windows.
/// Main thread only (timer callback).
fn sweepThumbs() void {
    if (!thumbs_init) return;
    var it = server.wm.windows.iterator();
    while (it.next()) |win| {
        const id = windowIdFromRef(win.ref);
        const thumb = grabWindowThumb(win) catch |err| {
            thumbs_last_err = err;
            continue; // keep stale frame
        };
        thumbs_mu.lockUncancelable(ioForMainThread());
        if (thumbs.getPtr(id)) |old| {
            bank_alloc.free(old.rgba);
            old.* = thumb;
        } else {
            thumbs.put(id, thumb) catch bank_alloc.free(thumb.rgba);
        }
        thumbs_mu.unlock(ioForMainThread());
    }
    // Prune windows that no longer exist.
    var dead: std.ArrayList(u64) = .empty;
    defer dead.deinit(bank_alloc);
    var kit = thumbs.keyIterator();
    while (kit.next()) |k| {
        if (windowFromId(k.*) == null) dead.append(bank_alloc, k.*) catch {};
    }
    if (dead.items.len > 0) {
        thumbs_mu.lockUncancelable(ioForMainThread());
        defer thumbs_mu.unlock(ioForMainThread());
        for (dead.items) |id| {
            const kv = thumbs.fetchRemove(id);
            if (kv) |e| bank_alloc.free(e.value.rgba);
        }
    }
    // Self-silencing health report: loud only while broken (live windows
    // but nothing cached), quiet once frames flow.
    thumbs_mu.lockUncancelable(ioForMainThread());
    const cached = thumbs.count();
    thumbs_mu.unlock(ioForMainThread());
    var live: usize = 0;
    var wit = server.wm.windows.iterator();
    while (wit.next()) |_| live += 1;
    if (live > 0 and cached == 0) {
        thumbs_empty_sweeps += 1;
        if (thumbs_empty_sweeps == 3 or thumbs_empty_sweeps % 30 == 0) {
            if (thumbs_last_err) |e| {
                log.warn("bank: thumbnails: {d} windows, 0 cached after {d} sweeps (last grab error: {s})", .{ live, thumbs_empty_sweeps, @errorName(e) });
            } else {
                log.warn("bank: thumbnails: {d} windows, 0 cached after {d} sweeps", .{ live, thumbs_empty_sweeps });
            }
        }
    } else {
        if (thumbs_empty_sweeps >= 3 and cached > 0)
            log.info("bank: thumbnails flowing again ({d} cached)", .{cached});
        thumbs_empty_sweeps = 0;
    }
}

fn handleThumbTimer(_: ?*anyopaque) c_int {
    sweepThumbs();
    if (thumb_timer) |t| t.timerUpdate(thumb_interval_ms) catch |err| {
        log.warn("bank: thumbnail timer re-arm failed: {}", .{err});
    };
    return 0;
}

fn pruneThumb(id: u64) void {
    if (!thumbs_init) return;
    thumbs_mu.lockUncancelable(ioForMainThread());
    defer thumbs_mu.unlock(ioForMainThread());
    const kv = thumbs.fetchRemove(id);
    if (kv) |e| bank_alloc.free(e.value.rgba);
}

/// Serve one `capture_window` from the thumbnail cache. Runs on the bank IO
/// thread: only memcpys under a short mutex hold, never touching client
/// buffers. Returns an already-encoded message; the payload is shrunk until
/// it fits the 64KiB frame budget, else error code 3 (client backs off and
/// retries — a fresh sweep lands within ~1s).
fn serveCaptureWindowMessage(alloc: Allocator, window_id: u64) !nilebank.Message {
    const errEv = struct {
        fn msg(a: Allocator, code: u32, text: []const u8) !nilebank.Message {
            const ev: protocols.Event = .{ .error_msg = .{ .code = code, .message = try a.dupe(u8, text) } };
            defer ev.deinit(a);
            return try nilebank.encodeCompositorEvent(a, ev, protocols.encodingForEvent(.error_msg));
        }
    }.msg;

    if (windowFromId(window_id) == null)
        return errEv(alloc, 2, "window not found");

    thumbs_mu.lockUncancelable(ioForRequestThread());
    const cached = thumbs.get(window_id);
    var rgba: []u8 = if (cached) |c| alloc.dupe(u8, c.rgba) catch &.{} else &.{};
    const cw: u32 = if (cached) |c| c.width else 0;
    const ch: u32 = if (cached) |c| c.height else 0;
    thumbs_mu.unlock(ioForRequestThread());
    if (rgba.len == 0)
        return errEv(alloc, 3, "no frame yet");

    // NOTE: `ev` below borrows `rgba`; it is never passed to `deinit`
    // (which would free `rgba` out from under the retry loop). `rgba` is
    // freed exactly once on every path below.
    var w: usize = cw;
    var h: usize = ch;
    while (true) {
        const ev: protocols.Event = .{ .window_image = .{
            .window_id = window_id,
            .image = .{ .width = @intCast(w), .height = @intCast(h), .stride = @intCast(w * 4), .format = .rgba8, .data = rgba },
        } };
        const out = nilebank.encodeCompositorEvent(alloc, ev, protocols.encodingForEvent(.window_image)) catch {
            alloc.free(rgba);
            return errEv(alloc, 1, "out of memory");
        };
        if (out.data.len <= thumb_max_payload or (w <= 32 or h <= 32)) {
            alloc.free(rgba);
            return out;
        }
        // Too big even deflated: halve and try again.
        alloc.free(@constCast(out.data));
        const nw: usize = @max(32, w / 2);
        const nh: usize = @max(32, h / 2);
        const smaller = downscaleRgba(alloc, rgba, w, h, nw, nh) catch {
            alloc.free(rgba);
            return errEv(alloc, 1, "out of memory");
        };
        alloc.free(rgba);
        rgba = smaller;
        w = nw;
        h = nh;
    }
}

/// Drop refs whose windows no longer exist.
fn focusOrderPrune() void {
    var i = focus_order.items.len;
    while (i > 0) {
        i -= 1;
        if (focus_order.items[i].get() == null) _ = focus_order.orderedRemove(i);
    }
}

/// Collect all known windows in focus order: currently focused first, then
/// latest focused, down to least recently focused. Windows never focused
/// (or missed by the tracker) are appended at the end in slotmap order, so
/// the result always contains every live window. Returned slice and every
/// item's strings are owned by the caller: deinit each item, then free
/// the slice.
fn collectWindows(alloc: Allocator) ![]protocols.Window {
    var wins: std.ArrayList(protocols.Window) = .empty;
    errdefer {
        for (wins.items) |w| w.deinit(alloc);
        wins.deinit(alloc);
    }
    // MRU first; skip stale refs (destroyed since last prune).
    for (focus_order.items) |ref| {
        if (ref.get()) |win| {
            try wins.append(alloc, try makeCompositorWindow(win, alloc));
        }
    }
    // Leftovers: live windows not in the tracker (never focused yet).
    var it = server.wm.windows.iterator();
    while (it.next()) |win| {
        var seen = false;
        for (focus_order.items) |ref| {
            if (ref.key.index == win.ref.key.index and ref.key.generation == win.ref.key.generation) {
                seen = true;
                break;
            }
        }
        if (!seen) try wins.append(alloc, try makeCompositorWindow(win, alloc));
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
                } else {
                    log.warn("bank: focus window {d}: unknown id", .{id});
                }
            },
            .close_window => |id| {
                if (windowFromId(id)) |win| {
                    win.wm_requested.close = true;
                    server.wm.dirtyWindowing();
                    log.info("bank: close window {d}", .{id});
                } else {
                    log.warn("bank: close window {d}: unknown id", .{id});
                }
            },
            .move_window => |v| {
                if (windowFromId(v.id)) |win| {
                    win.rendering_requested.x = v.x;
                    win.rendering_requested.y = v.y;
                    win.startPosAnimation(v.x, v.y, true);
                    server.wm.dirtyRendering();
                    log.info("bank: move window {d} to {d},{d}", .{ v.id, v.x, v.y });
                } else {
                    log.warn("bank: move window {d}: unknown id", .{v.id});
                }
            },
            .resize_window => |v| {
                if (windowFromId(v.id)) |win| {
                    win.wm_requested.dimensions = .{ .width = @intCast(v.width), .height = @intCast(v.height) };
                    win.startSizeAnimation(@intCast(v.width), @intCast(v.height), true);
                    server.wm.dirtyWindowing();
                    log.info("bank: resize window {d} to {d}x{d}", .{ v.id, v.width, v.height });
                } else {
                    log.warn("bank: resize window {d}: unknown id", .{v.id});
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

fn bankCallback(_: ?*anyopaque, msg: nilebank.Message) anyerror!nilebank.Message {
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

    // Thumbnails are served from the 1fps main-thread cache (see above):
    // return the pre-encoded frame immediately so the shell shows pixels
    // on click instead of waiting.
    if (req == .capture_window) {
        return serveCaptureWindowMessage(alloc, req.capture_window.window_id) catch |err| {
            log.warn("bank: capture serve failed: {}", .{err});
            const ev: protocols.Event = .{ .error_msg = .{ .code = 1, .message = try alloc.dupe(u8, "capture failed") } };
            defer ev.deinit(alloc);
            return try nilebank.encodeCompositorEvent(alloc, ev, protocols.encodingForEvent(.error_msg));
        };
    }

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
        // .capture_window is served above from the thumbnail cache.
        .capture_window => unreachable,
        .capture_full, .capture_output => .{
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
// Event push — live state changes to shell clients (2-way connection)
// ---------------------------------------------------------------------------
//
// The request/response socket doubles as the push channel: nilebank's
// `Server.broadcast` sends unsolicited events (`Header.push_id`) over the
// same connection, and client readers route them to the event listener
// instead of an outstanding `request`. Shells should:
//   1. connect to `/tmp/arcos/compositor.sock`,
//   2. query initial state (`list_windows`, `list_workspaces`, `list_outputs`),
//   3. stay connected to receive pushes (`new_window`, `window_closed`, …).
//      Decode each push with
//      `protocols.compositor.Event.decodeAllocWith(alloc, kind, payload, encoding)`.
//
// Afterwards one message is pushed per state change: `new_window`,
// `window_closed`, `window_focused`, `window_title_changed`,
// `window_app_id_changed`, `window_state_changed`,
// `window_workspace_changed`, `output_added`, `output_removed`,
// `output_changed`, `workspace_created`, `workspace_removed`,
// `workspace_activated`, `workspace_deactivated`, `switch_workspace`
// (plus a full `windows` list re-push on focus change so shells see MRU
// order without re-querying; renames arrive as a full
// `workspaces_snapshot`). Pointer motion/buttons, frame ticks and keybinds
// are intentionally not pushed — re-query (`list_windows`, …) for those.
//
// `broadcast` is only called from the main Wayland thread via the
// `Compositor.broadcast_hook` (or the async-queue drain, also main thread).
// `subscribe`/`unsubscribe` on the request socket are currently acknowledged
// no-ops — staying connected is the subscription mechanism.
// `switch_workspace` and `set_workspace_name` requests are applied
// asynchronously on the main thread (acked with `pong`); the outcome arrives
// as a push.

/// Push `ev` to all connected clients. Consumes `ev`.
/// No-op (besides freeing `ev`) when the server isn't up or nobody is
/// connected.
pub fn broadcast(ev: protocols.Event) void {
    const s = bank_server_obj orelse {
        var drop = ev;
        drop.deinit(bank_alloc);
        return;
    };
    var ev_mut = ev;
    defer ev_mut.deinit(bank_alloc);
    s.broadcastCompositorEventDefault(ev_mut) catch |err| {
        log.warn("bank: broadcast failed: {}", .{err});
    };
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
            focusOrderEnsure(win);
            const title_c = win.getTitle();
            const title = if (title_c) |c| std.mem.sliceTo(c, 0) else "";
            const owned = bank_alloc.dupe(u8, title) catch return;
            broadcast(.{ .new_window = .{ .title = owned, .id = windowIdFromRef(win.ref) } });
        },
        .window_map => |win| {
            focusOrderEnsure(win);
            // Opportunistic thumbnail: don't wait for the next 1s sweep so
            // a freshly opened window has pixels on the first switcher open.
            if (thumbs_init) {
                if (grabWindowThumb(win)) |thumb| {
                    const id = windowIdFromRef(win.ref);
                    thumbs_mu.lockUncancelable(ioForMainThread());
                    if (thumbs.getPtr(id)) |old| {
                        bank_alloc.free(old.rgba);
                        old.* = thumb;
                    } else {
                        thumbs.put(id, thumb) catch bank_alloc.free(thumb.rgba);
                    }
                    thumbs_mu.unlock(ioForMainThread());
                } else |err| {
                    thumbs_last_err = err;
                }
            }
            broadcast(windowStateEvent(win));
        },
        .window_unmap => |win| broadcast(windowStateEvent(win)),
        .window_destroy => |win| {
            focusOrderRemove(win.ref);
            focusOrderPrune();
            pruneThumb(windowIdFromRef(win.ref));
            broadcast(.{ .window_closed = .{ .id = windowIdFromRef(win.ref) } });
        },
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
        .window_focus_changed => |v| {
            // MRU bookkeeping: newly focused window goes to front. On
            // focus-clear (`new == null`) the list is left as-is so it
            // still reads most-recent-first.
            if (v.new) |win| focusOrderTrack(win);
            broadcast(.{ .window_focused = .{
                .id = windowIdOrZero(v.new),
                .old_id = windowIdOrZero(v.old),
            } });
            // Re-push the whole list (in MRU focus order) as a list_windows
            // response so subscribed shells see the new focus order without
            // re-querying. Skipped when nobody is connected to avoid
            // wasted work.
            if (bank_server_obj) |s| {
                if (s.clientCount() != 0) {
                    const items = collectWindows(bank_alloc) catch return;
                    broadcast(.{ .windows = .{ .items = items } });
                }
            }
        },
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

    bank_server_obj = try nilebank.serve(bank_alloc, io, socket_id, bankCallback, null);
    log.info("bank: listening on {s} (id={s})", .{ socket_path, socket_id });

    // 1fps window-thumbnail sweep (main thread; see section above). If the
    // timer can't be created we simply keep answering capture_window with
    // "no frame yet" as before.
    thumbs = std.AutoHashMap(u64, Thumb).init(bank_alloc);
    thumbs_init = true;
    if (server.wl_server.getEventLoop().addTimer(?*anyopaque, handleThumbTimer, null)) |t| {
        thumb_timer = t;
        thumb_timer.?.timerUpdate(thumb_interval_ms) catch |err| {
            log.warn("bank: thumbnail timer arm failed: {}", .{err});
        };
    } else |err| {
        log.warn("bank: thumbnail timer unavailable: {}", .{err});
    }

    Compositor.setBroadcastHook(&onCompositorEvent);
    // Seed MRU order from current state: focused windows first, then the
    // rest in slotmap order. Later focus events keep it up to date.
    {
        var sit = server.input_manager.seats.iterator(.forward);
        while (sit.next()) |seat| {
            if (seat.focused == .window) focusOrderTrack(seat.focused.window);
        }
        var wit = server.wm.windows.iterator();
        while (wit.next()) |win| focusOrderEnsure(win);
    }
}

pub fn deinit() void {
    Compositor.broadcast_hook = null;
    if (thumb_timer) |t| {
        t.remove();
        thumb_timer = null;
    }
    if (bank_server_obj) |s| {
        s.deinit();
        bank_server_obj = null;
    }
    if (bank_threaded) |t| {
        t.deinit();
        bank_alloc.destroy(t);
        bank_threaded = null;
    }
    // After the IO threads are gone: no in-flight capture serve can touch
    // the map anymore, so it is safe to free it here on the main thread.
    if (thumbs_init) {
        thumbs_mu.lockUncancelable(ioForMainThread());
        var it = thumbs.iterator();
        while (it.next()) |kv| bank_alloc.free(kv.value_ptr.rgba);
        thumbs.deinit();
        thumbs_mu.unlock(ioForMainThread());
        thumbs_init = false;
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
    focus_order.deinit(bank_alloc);
    focus_order = .empty;
}
