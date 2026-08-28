<!--
SPDX-FileCopyrightText: © 2020 The River Developers
SPDX-License-Identifier: CC-BY-SA-4.0
-->

<div align="center">
  <img src="logo/logo_text_adaptive_color.svg" width="600em">
</div>

> **Nile fork:** This is [Nile](https://github.com/KernelState/nile) — River reimagined as a **function-first compositor**. Custom Wayland protocols (`river_window_management_v1` etc.) are deprecated in favor of direct Zig functions in `river/Nile.zig`. See [`doc/nile-api.md`](doc/nile-api.md) for the new API. Legacy protocol globals are disabled by default but still generated for one transitional release.

## Overview

River is a Wayland compositor. **Nile** keeps River's high-performance wlroots core (frame-perfect rendering, Xwayland, layer shell, etc.) but replaces the out-of-process window manager protocol with ordinary functions you call from in-process Zig code.

Instead of an external window manager speaking `river-window-management-v1`, you write:

```zig
const Nile = @import("river/Nile.zig");
Nile.Window.setPosition(win, 100, 100);
Nile.Seat.focusWindow(Nile.Seat.default(), win);
Nile.dirtyWindowing();
```

See [`doc/nile-api.md`](doc/nile-api.md) for the full API and migration guide. For the original River protocol design, read [Separating the Wayland Compositor and Window Manager](https://isaacfreund.com/blog/river-window-management/) (historical).

> *If you are looking for the old dynamic tiling version of river, see
[river-classic](https://codeberg.org/river/river-classic).*

## Links

- [Protocol Docs](https://isaacfreund.com/docs/wayland/)
- [tinyrwm](https://codeberg.org/river/tinyrwm) example window manager
- [Wiki](https://codeberg.org/river/wiki)
- IRC: [#river](https://web.libera.chat/?channels=#river) on irc.libera.chat ([logs](https://libera.catirclogs.org/river))
- [Zulip](https://river-compositor.zulipchat.com) (new)
- [Issue Tracker](https://codeberg.org/river/river/issues)
- [Code of Conduct](CODE_OF_CONDUCT.md)

## Features (Nile)

- **Function API** (`river/Nile.zig:1`): `Nile.Window`, `Nile.Output`, `Nile.Seat`, `Nile.Input`, `Nile.Layer` — typed, documented functions instead of Wayland globals.
- Frame perfect rendering, good performance, support for many Wayland protocol extensions, robust Xwayland support.
- Standard protocols unchanged: `xdg_shell`, `wlr_layer_shell`, `ext_session_lock`, `wlr_output_management`, etc.
- Legacy `river_*_v1` protocols still generated but **not advertised** (`river/WindowManager.zig:86`, `river/XkbBindings.zig:23`, etc.). Re-enable via `Nile.enableLegacyProtocols` if you need compatibility.

For River classic features, see historical docs. The `river-window-management-v1` protocol is now deprecated.

## Motivation

Why split the window manager to a separate process?

- Significantly lower the barrier to entry for writing a Wayland window manager.
- Allow implementing Wayland window managers in high-level garbage collected
  languages without impacting compositor performance and latency.
- Allow hot-swapping between window managers without restarting the compositor
  and all Wayland programs.
- Promote diversity and experimentation in window manager design.

## Building

Note: If you are packaging river for distribution, see [PACKAGING.md](PACKAGING.md).

To compile river first ensure that you have the following dependencies
installed. The "development" versions are required if applicable to your
distribution.

- [zig](https://ziglang.org/download/) 0.16
- wayland
- wayland-protocols
- [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) 0.20
- xkbcommon 1.12 or newer
- libevdev
- pixman
- pkg-config
- scdoc (optional, but required for man page generation)

Then run, for example:
```
zig build -Doptimize=ReleaseSafe --prefix ~/.local install
```
To enable Xwayland support pass the `-Dxwayland` option as well.
Run `zig build -h` to see a list of all options.

## Usage

River can either be run nested in an X11/Wayland session or directly
from a tty using KMS/DRM. Simply run the `river` command.

On startup river will run an executable file at `$XDG_CONFIG_HOME/river/init`
if such an executable exists. If `$XDG_CONFIG_HOME` is not set,
`~/.config/river/init` will be used instead.

Usually this executable is a shell script which starts the user's window manager
and any other long-running programs.

For complete documentation see the `river(1)` man page.

## Strict No LLM / No AI Policy

Use of generative AI/LLMs is strictly forbidden for all contributions to river.

This includes bug reports and comments on the issue tracker.

## Hacking

See [ARCHITECTURE.md](ARCHITECTURE.md) for an overview of the code base.

See [CONTRIBUTING.md](CONTRIBUTING.md) for information on submitting patches.

## Donate

If my work on river adds value to your life please consider setting up a
recurring donation through [liberapay]. This is the best way to make river's
development sustainable in the long term.

You can also support me with a one-time or monthly donation on [github sponsors]
or [ko-fi] though I prefer liberapay as it is run by a non-profit.

Thank you for your support!

## Funding

River is funded in part through the [NGI0 Commons Fund](https://nlnet.nl/commonsfund),
a fund established by NLnet with financial support from the European
Commission's [Next Generation Internet](https://ngi.eu/) programme.

Learn more at the [NLnet project page](https://nlnet.nl/project/River-protocol/).

## Licensing

This project follows the [REUSE Specification](https://reuse.software/spec-3.3/),
all files have SPDX copyright and license information.

In overview:

- River's source code is released under the GPL-3.0-only license.
- River's Wayland protocols are released under the MIT license.
- River's logo and documentation are released under the CC-BY-SA-4.0 license.

[river-window-management-v1]: https://isaacfreund.com/docs/wayland/river-window-management-v1
[liberapay]: https://liberapay.com/ifreund
[github sponsors]: https://github.com/sponsors/ifreund
[ko-fi]: https://ko-fi.com/ifreund
