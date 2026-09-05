<!--
SPDX-FileCopyrightText: © 2026 The Nile Developers
SPDX-License-Identifier: CC-BY-SA-4.0
-->

# Nile API — Direct Function Control for River

Nile replaces River's custom Wayland protocols with ordinary Zig functions. This document describes the function API, migration path, and examples.

> **Status:** Stable. The six legacy River Wayland globals (`river_window_manager_v1`, `river_xkb_bindings_v1`, `river_layer_shell_v1`, `river_input_management_v1`, `river_libinput_config_v1`, `river_xkb_config_v1`) and their XML files (`protocol/river-*.xml`) have been **removed**. All compositor control is via `river/Nile.zig`. The code that previously generated and advertised those globals has been deleted from `build.zig` and `river/*.zig`.

---

## Why?

River's original design split compositor and window manager into separate processes communicating via Wayland. This enabled hot-swapping WMs but imposed a complex transaction model (`manage_start` / `manage_finish` / `render_start` / `render_finish`) and made simple tasks (move a window, focus a seat) require writing a Wayland client.

Nile inverts the relationship: the compositor **is** the library. You import `Nile.zig` and call functions. No `wl_global`, no protocol XML, no async event dance. The compositor still preserves frame-perfect transactions internally, but they are triggered by `Nile.dirtyWindowing()` / `dirtyRendering()` rather than protocol messages.

Benefits:
- **One function = one action.** `Nile.Window.setPosition(win, x, y)` instead of building a Wayland request inside a `manage` sequence.
- **Typed, documented, discoverable.** Zig doc comments, `error` returns, and `zig doc` output.
- **In-process control.** Ideal for niri-style or Hyprland-style configs where the window management policy lives inside the compositor process.
- **Easier bindings.** Language bindings (Python, Lua) can FFI to C-ABI wrappers without implementing Wayland.

---

## Module layout

```
river/Nile.zig          — public façade, re-exports sub-APIs
river/Window.zig        — window state (now driven via Nile.Window)
river/Output.zig        — output state (Nile.Output)
river/Seat.zig          — seat/focus/cursor (Nile.Seat)
river/InputDevice.zig   — input devices (Nile.Input)
river/XkbBinding.zig    — key bindings (Nile.Seat.addXkbBinding)
river/LayerShell*.zig   — layer shell (Nile.Layer)
river/Workspace.zig     — workspace management (Nile.Workspace)
```

Standard Wayland / wlroots protocols (`xdg_shell`, `wlr_layer_shell`, `ext_session_lock`, etc.) are **unchanged**. Only the six `river_*` protocols have been removed.

---

## Core concepts

### Transactions

Internally the compositor still double-buffers state:

1. You mutate `wm_requested` / `rendering_requested` via Nile functions.
2. You call `Nile.dirtyWindowing()` or `Nile.dirtyRendering()`.
3. On the next idle, `WindowManager.manageStart()` / `renderStart()` runs, sends configures to clients, waits for responses, then commits.

From the caller perspective this is synchronous: call functions, optionally call `Nile.commit()` (alias for dirty), and the next frame reflects the change. No need to handle `manage_start` events.

### References are stable

`Window.Ref` (`SlotMap` key) survives across transactions. Store `Ref`s, not raw `*Window` pointers, if you need long-lived handles.

---

## Quick start

```zig
const Nile = @import("river/Nile.zig");

pub fn arrange() void {
    const out = Nile.Output.primary() orelse return;
    const wb = out.currentBox(); // wlr.Box {x,y,width,height}
    var it = Nile.Window.iter();
    var i: u32 = 0;
    while (it.next()) |win| : (i += 1) {
        // Simple vertical stack
        const h = @divTrunc(wb.height, @as(i32, @intCast(Nile.Window.count())));
        Nile.Window.setPosition(win, wb.x, wb.y + @as(i32, @intCast(i)) * h);
        Nile.Window.setDimensions(win, @intCast(wb.width), @intCast(h));
    }
    Nile.dirtyWindowing();
    Nile.dirtyRendering();
}
```

---

## API reference

### `Nile` (top-level)

```zig
pub fn dirtyWindowing() void    // schedule manage sequence
pub fn dirtyWindowingLazy() void
pub fn dirtyRendering() void    // schedule render sequence
pub fn exitSession() void
pub var enableLegacyProtocols: bool // false by default
```

### `Nile.Window` (`WindowApi`)

```zig
pub fn count() usize
pub fn iter() SlotMap(*Window).Iterator
pub fn get(ref: Window.Ref) ?*Window
pub fn close(window: *Window) void
pub fn setDimensions(window: *Window, width: u31, height: u31) void
pub fn setDimensionsChecked(window: *Window, width: i32, height: i32) !void
pub fn setPosition(window: *Window, x: i32, y: i32) void
pub fn hide(window: *Window) void
pub fn show(window: *Window) void
pub fn isHidden(window: *Window) bool
pub fn setSsd(window: *Window, ssd: bool) void
pub fn setTiled(window: *Window, edges: anytype) void
pub fn setBorders(window: *Window, edges: anytype, width: u31, r:u32,g:u32,b:u32,a:u32) void
pub fn setClipBox(window: *Window, box: wlr.Box) void
pub fn setContentClipBox(window: *Window, box: wlr.Box) void
pub fn setFullscreen(window: *Window, output: ?*Output) void
pub fn toggleFullscreen(window: *Window, output: *Output) void
pub fn setInformFullscreen(window: *Window, fullscreen: bool) void
pub fn setResizing(window: *Window, resizing: bool) void
pub fn setMaximized(window: *Window, maximized: bool) void
pub fn setBounds(window: *Window, max_width: u31, max_height: u31) void
pub fn raiseToTop(window: *Window) void
pub fn focus(window: *Window) void
pub fn title(window: *Window) ?[*:0]const u8
pub fn appId(window: *Window) ?[*:0]const u8
pub fn box(window: *Window) wlr.Box
```

**Example: focus next window**

```zig
fn focusNext() void {
    var it = Nile.Window.iter();
    const cur = Nile.Seat.default().focused;
    // find current and next...
    if (it.next()) |next| Nile.Window.focus(next);
}
```

### `Nile.Output`

```zig
pub fn iter() wl.list.Head(Output).Iterator
pub fn byName(name: []const u8) ?*Output
pub fn primary() ?*Output
pub fn setPosition(output: *Output, x: i32, y: i32) void
pub fn setScale(output: *Output, scale: f32) void
pub fn setTransform(output: *Output, wl.Output.Transform) void
pub fn setEnabled(output: *Output, enabled: bool) void
pub fn setTearing(output: *Output, tearing: bool) void
pub fn autoLayout() void
pub fn currentBox(output: *Output) wlr.Box
```

### `Nile.Seat`

```zig
pub fn iter() wl.list.Head(Seat).Iterator
pub fn byName(name: []const u8) ?*Seat
pub fn default() *Seat
pub fn create(name: [:0]const u8) !void
pub fn destroy(name: []const u8) void
pub fn focusWindow(seat: *Seat, window: *Window) void
pub fn clearFocus(seat: *Seat) void
pub fn warpPointer(seat: *Seat, x: i32, y: i32) void
pub fn opStartPointer(seat: *Seat) void
pub fn opEnd(seat: *Seat) void
pub fn pointerPos(seat: *Seat) struct{ x:f64,y:f64 }
pub fn setXcursorTheme(seat: *Seat, name: ?[*:0]const u8, size: u32) !void
pub fn addXkbBinding(seat: *Seat, keysym: xkb.Keysym, modifiers: anytype) !*XkbBinding // scaffolded
pub fn removeXkbBinding(seat: *Seat, keysym: xkb.Keysym, modifiers: anytype) void
```

**Example: warp and focus**

```zig
Nile.Seat.warpPointer(Nile.Seat.default(), 100, 100);
Nile.Seat.focusWindow(Nile.Seat.default(), win);
```

### `Nile.Input`

```zig
pub fn iter() wl.list.Head(InputDevice).Iterator
pub fn byName(name: []const u8) ?*InputDevice
pub fn assignToSeat(device: *InputDevice, seat_name: []const u8) void
pub fn setRepeat(device: *InputDevice, rate: i32, delay: i32) !void
pub fn setScrollFactor(device: *InputDevice, factor: f64) !void
pub fn mapToOutput(device: *InputDevice, output: ?*wlr.Output) void
pub fn mapToRectangle(device: *InputDevice, rect: ?wlr.Box) !void
```

### `Nile.Layer`

```zig
pub fn setDefaultOutput(output: *Output) void
pub fn nonExclusiveArea(output: *Output) wlr.Box
```

### `Nile.Workspace`

```zig
pub fn currentWorkspace() u64               // returns current workspace id
pub fn switchWorkspace(id: u64) !u64        // switch to workspace, returns new id
pub fn addWorkspace(number: u64, name: []const u8) !u64  // add workspace, returns id
pub fn removeWorkspace(id: u64) !void       // remove workspace by id
pub fn setWorkspaceName(id: u64, name: []const u8) !void // rename workspace
pub fn listWorkspaces(alloc: Allocator) ![]Workspace.Info // list all workspaces
pub fn getWorkspace(id: u64, alloc: Allocator) ?Workspace.Info // get workspace info
```

**Example: switch to workspace 2**

```zig
const Nile = @import("Nile.zig");

pub fn switchToSecond() void {
    // Get workspace with number 2
    var ws_id: u64 = 2;
    _ = Nile.Workspace.switchWorkspace(ws_id);
}
```

### Default keybindings

The default compositor (`NileCompositor`) registers `MOD + 1..9` on the
default seat to switch between the 9 fixed workspaces (created at startup,
always present). MOD is Alt when nested (Wayland/X11 backend, so the outer
compositor keeps Super) and Super/Logo on DRM/KMS. The same rule applies to
mod-drag (move/resize). New windows open on the current workspace, and
switching re-tiles for the newly visible set.

### Shell event push (`/tmp/arcos/compositor.sock`, 2-way connection)

The request/response socket (`/tmp/arcos/compositor.sock`) doubles as the
push channel: the server broadcasts unsolicited events (`Header.push_id`) over
the same connection, and client readers route them to the event listener
instead of an outstanding `request`. Shells that need live state should:

1. connect with an event listener (`Connection.initPath(alloc, io, path, listener, ctx)`),
2. query initial state (`list_windows`, `list_workspaces`, `list_outputs`),
3. stay connected to receive pushes, decoding each with
   `protocols.compositor.Event.decodeAllocWith(alloc, kind, payload, encoding)`.

One message is pushed per state change: `new_window`, `window_closed`,
`window_focused`, `window_title_changed`, `window_app_id_changed`,
`window_state_changed`, `window_workspace_changed`, `output_added`,
`output_removed`, `output_changed`, `workspace_created`, `workspace_removed`,
`workspace_activated`, `workspace_deactivated`, `switch_workspace`
(a full `windows` list is re-pushed on focus change so shells see MRU focus
order without re-querying; renames arrive as a full `workspaces_snapshot`).
Pointer motion/buttons, frame ticks and keybinds are intentionally not pushed —
re-query (`list_windows`, …) for those.
`subscribe`/`unsubscribe` on the request socket are currently acknowledged
no-ops — staying connected is the subscription mechanism.
`switch_workspace` and `set_workspace_name` requests are applied
asynchronously on the main thread (acked with `pong`); the outcome arrives
as a push.

---

## Migration from protocols

| Protocol request/event | Nile equivalent |
|---|---|
| `river_window_manager_v1.manage_dirty` | `Nile.dirtyWindowing()` |
| `river_window_v1.propose_dimensions` | `Nile.Window.setDimensions(win, w, h)` |
| `river_window_v1.hide/show` | `Nile.Window.hide/show` |
| `river_window_v1.set_borders` | `Nile.Window.setBorders(...)` |
| `river_window_v1.fullscreen/exit_fullscreen` | `Nile.Window.setFullscreen(win, out)` |
| `river_seat_v1.focus_window` | `Nile.Seat.focusWindow(seat, win)` |
| `river_seat_v1.pointer_warp` | `Nile.Seat.warpPointer(seat, x, y)` |
| `river_xkb_bindings_v1.get_xkb_binding` | `Nile.Seat.addXkbBinding(seat, keysym, mods)` |
| `river_input_manager_v1.create_seat` | `Nile.Seat.create("name")` |
| `river_input_device_v1.assign_to_seat` | `Nile.Input.assignToSeat(dev, "name")` |
| `river_layer_shell_output_v1.set_default` | `Nile.Layer.setDefaultOutput(out)` |
| Workspace management (no protocol) | `Nile.Workspace.switchWorkspace(id)` |

**Before (Wayland client):**

```zig
wm.sendManageDirty();
 // wait for manage_start
win.proposeDimensions(800, 600);
seat.focusWindow(win);
wm.sendManageFinish();
```

**After (Nile):**

```zig
Nile.Window.setDimensions(win, 800, 600);
Nile.Seat.focusWindow(seat, win);
Nile.dirtyWindowing();
```

No `manage_start` handler, no `render_finish`, no error for wrong sequence — the transaction system handles ordering internally.

---

## Writing a window manager with Nile

Create a Zig module that imports `Nile` and hooks into events. The simplest integration is to call `Nile` from within the compositor process (e.g. from `main.zig` init or a plugin). A future `nile` binary will load a user `init.zig` that exports `onMap`, `onFocus`, etc.

Example `init.zig` (planned):

```zig
const Nile = @import("river/Nile.zig");

export fn onWindowMap(win: *Nile.Window) void {
    // Master-stack layout: first window is master (60% width)
    arrange();
}
```

---

## Legacy protocols removed

The old external window manager protocol has been deleted. External WMs like `tinyrwm` that spoke `river_window_management_v1` will no longer connect. The `enableLegacyProtocols` flag in `Nile.zig` is retained as a no-op for source compatibility but has no effect — the globals and `wl.Global.create` calls have been removed from `WindowManager.zig`, `XkbBindings.zig`, etc. To restore legacy support, re-add the six XML files and `scanner.addCustomProtocol`/`scanner.generate` lines in `build.zig` from git history.

---

## Docs generation

```bash
zig build docs  # (future) generates `docs/nile-api.html` via `zig doc`
```

Inline `///` comments in `river/Nile.zig` are the source of truth; this markdown is an overview.

---

## License

GPL-3.0-only for code, CC-BY-SA-4.0 for docs. Protocol XML remains MIT.

