// SPDX-FileCopyrightText: © 2026 The Nile Developers
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");

pub const SDL = struct {
    // Constants from SDL3 headers (selected subset)
    pub const INIT_VIDEO: u32 = 0x00000020;
    pub const WINDOW_RESIZABLE: u64 = 0x0000000000000020;
    pub const EVENT_QUIT: u32 = 0x100;

    // Opaque pointer types
    pub const Window = opaque {};
    pub const Renderer = opaque {};
    pub const FRect = extern struct {
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    };
    pub const Event = extern struct {
        type: u32,
        // padding to make the struct exactly 128 bytes as required by SDL3
        _pad: [124]u8,
    };
    comptime {
        if (@sizeOf(Event) != 128) @compileError("SDL_Event size mismatch, expected 128 bytes");
    }

    // SDL functions – declared as extern with the "SDL_" prefix.
    extern fn SDL_Init(flags: u32) bool;
    extern fn SDL_Quit() void;
    extern fn SDL_GetError() [*:0]const u8;
    extern fn SDL_CreateWindow(title: ?[*:0]const u8, w: c_int, h: c_int, flags: u64) ?*Window;
    extern fn SDL_DestroyWindow(window: ?*Window) void;
    extern fn SDL_CreateRenderer(window: ?*Window, name: ?[*:0]const u8) ?*Renderer;
    extern fn SDL_DestroyRenderer(r: ?*Renderer) void;
    extern fn SDL_SetRenderDrawColor(r: ?*Renderer, r_: u8, g: u8, b: u8, a: u8) bool;
    extern fn SDL_RenderClear(r: ?*Renderer) bool;
    extern fn SDL_RenderFillRect(r: ?*Renderer, rect: ?*const FRect) bool;
    extern fn SDL_RenderPresent(r: ?*Renderer) void;
    extern fn SDL_RenderCopy(renderer: ?*Renderer, texture: ?*anyopaque, src: ?*anyopaque, dst: ?*const FRect) bool; // not used
    extern fn SDL_PollEvent(event: ?*Event) bool;
    extern fn SDL_GetWindowSize(window: ?*Window, w: ?*c_int, h: ?*c_int) bool;
    extern fn SDL_SetWindowTitle(window: ?*Window, title: ?[*:0]const u8) bool;
};

pub const Backend = struct {
    gpa: std.mem.Allocator,
    windows: std.AutoHashMapUnmanaged(u64, Canvas) = .empty,

    const Canvas = struct {
        win: *SDL.Window,
        rend: *SDL.Renderer,
        output: OutputState,
        // We keep the output geometry to know where to draw windows.
        pub fn init(gpa: std.mem.Allocator, out: OutputState) !Canvas {
            const title = try std.fmt.allocPrint(gpa, "Nile Output {d}", .{out.id});
            defer gpa.free(title);
            const win = SDL.SDL_CreateWindow(title.ptr, @intCast(out.width), @intCast(out.height), SDL.WINDOW_RESIZABLE) orelse return error.SdlCreateWindow;
            const rend = SDL.SDL_CreateRenderer(win, null) orelse {
                SDL.SDL_DestroyWindow(win);
                return error.SdlCreateRenderer;
            };
            return .{ .win = win, .rend = rend, .output = out };
        }
        pub fn deinit(self: *Canvas) void {
            SDL.SDL_DestroyRenderer(self.rend);
            SDL.SDL_DestroyWindow(self.win);
        }
        pub fn render(self: *Canvas, snap: *const @import("State.zig").Snapshot) void {
            // Clear with black background
            _ = SDL.SDL_SetRenderDrawColor(self.rend, 0, 0, 0, 255);
            _ = SDL.SDL_RenderClear(self.rend);
            // Draw each window that intersects this output
            for (snap.windows) |win| {
                // Simple intersection test
                const ox = @intCast(self.output.x);
                const oy = @intCast(self.output.y);
                const ow = @intCast(self.output.width);
                const oh = @intCast(self.output.height);
                const wx1 = win.x;
                const wy1 = win.y;
                const wx2 = win.x + @intCast(win.width);
                const wy2 = win.y + @intCast(win.height);
                const intersect = !(wx2 <= ox or wx1 >= ox + ow or wy2 <= oy or wy1 >= oy + oh);
                if (!intersect) continue;
                // Convert to float for SDL_FRect
                var fr = SDL.FRect{
                    .x = @floatFromInt(win.x - ox),
                    .y = @floatFromInt(win.y - oy),
                    .w = @floatFromInt(win.width),
                    .h = @floatFromInt(win.height),
                };
                // Fill with a semi‑transparent cyan
                _ = SDL.SDL_SetRenderDrawColor(self.rend, 0, 255, 255, 180);
                _ = SDL.SDL_RenderFillRect(self.rend, &fr);
                // Optional border if enabled
                if (win.border) |b| {
                    // Draw a thin magenta border
                    _ = SDL.SDL_SetRenderDrawColor(self.rend, 255, 0, 255, 255);
                    // top
                    var top = SDL.FRect{ .x = fr.x, .y = fr.y, .w = fr.w, .h = @intToFloat(f32, @intCast(b.width)) };
                    _ = SDL.SDL_RenderFillRect(self.rend, &top);
                    // left
                    var left = SDL.FRect{ .x = fr.x, .y = fr.y, .w = @intToFloat(f32, @intCast(b.width)), .h = fr.h };
                    _ = SDL.SDL_RenderFillRect(self.rend, &left);
                    // right
                    var right = SDL.FRect{ .x = fr.x + fr.w - @intToFloat(f32, @intCast(b.width)), .y = fr.y, .w = @intToFloat(f32, @intCast(b.width)), .h = fr.h };
                    _ = SDL.SDL_RenderFillRect(self.rend, &right);
                    // bottom
                    var bottom = SDL.FRect{ .x = fr.x, .y = fr.y + fr.h - @intToFloat(f32, @intCast(b.width)), .w = fr.w, .h = @intToFloat(f32, @intCast(b.width)) };
                    _ = SDL.SDL_RenderFillRect(self.rend, &bottom);
                }
            }
            SDL.SDL_RenderPresent(self.rend);
        }
    };

    pub fn init(gpa: std.mem.Allocator) Backend {
        // Initialize SDL video subsystem
        if (!SDL.SDL_Init(SDL.INIT_VIDEO)) {
            const err = SDL.SDL_GetError();
            @panic(@ptrCast([*]const u8, err));
        }
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Backend) void {
        // Destroy all canvases
        var it = self.windows.iterator();
        while (it.next()) |pair| {
            pair.value_ptr.deinit();
        }
        self.windows.deinit(self.gpa);
        SDL.SDL_Quit();
    }

    fn ensureCanvas(self: *Backend, out: OutputState) !*Canvas {
        const id = out.id;
        if (self.windows.getPtr(id)) |ptr| return ptr;
        var canvas = try Canvas.init(self.gpa, out);
        try self.windows.put(self.gpa, id, canvas);
        return self.windows.getPtr(id).?;
    }

    pub fn render(self: *Backend, snap: *const @import("State.zig").Snapshot) void {
        // Ensure canvases for each output and render the snapshot.
        for (snap.outputs) |out| {
            const canvas = self.ensureCanvas(out) catch continue;
            canvas.render(snap);
        }
        // Poll and discard events to keep SDL happy.
        var ev: SDL.Event = undefined;
        while (SDL.SDL_PollEvent(&ev)) {
            if (ev.type == SDL.EVENT_QUIT) {
                // ignore – compositor shutdown is managed elsewhere.
            }
        }
    }
};
