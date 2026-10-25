# Upstream sources & licences

`nextbsd-xlibre` builds third-party software NextBSD ships in base under
`/usr/X11`, each **under its own upstream licence**. Their sources are not kept
in this repo: `build-xlibre.sh` downloads the release tarballs pinned in
`sources.lock` and checks their SHA-256. The licence files and headers in those
tarballs are authoritative; this table records provenance and does not
relicense anything.

libdrm, pixman, expat, freetype, fontconfig, libxkbcommon, xkeyboard-config,
epoll-shim, libudev-devd, libevdev, mtdev, libinput and the `<linux/input.h>`
shim are not built here: they moved to `nextbsd-displayserver-support` (E25,
nextbsd-xlibre#12), whose `NOTICE.md` records them, and are linked from its
artifact in `/usr`.

NextBSD's changes to upstream code live in `patches/<component>/`. Each patch is
under the licence of the file it changes, and says where it came from in its
`Origin:` line.

The top-level **`LICENSE` (BSD 2-Clause)** covers only what this repo authors:
`build-xlibre.sh`, `sources.lock`, `cross/`, `launchd/`, `.github/workflows/`, this
`NOTICE.md` and `README.md`.

| Component | Upstream | Version | Licence |
|---|---|---|---|
| `libepoxy` | `anholt/libepoxy` | 1.5.10 | MIT (`COPYING`); the bundled Khronos XML registry is Apache-2.0 / MIT, per file |
| `libxcvt` | X.Org, `xorg/lib/libxcvt` | 0.1.3 | MIT/X11 (`COPYING`) |
| `xkbcomp` | X.Org, `xorg/app/xkbcomp` | 1.5.0 | HPND / MIT-style (`COPYING`) |
| `libpciaccess` | X.Org, `xorg/lib/libpciaccess` | 0.19 | MIT/X11-style, per file (`COPYING`) |
| `xlibre-xserver` | X11Libre, `X11Libre/xserver` (tag `xlibre-xserver-25.1.9`) | 25.1.9 | MIT/X11-style, per file (`COPYING`). Patches `0001`–`0004` in `patches/xlibre-xserver/` are from FreeBSD's `x11-servers/xlibre-server` port and `0005`–`0007` are NextBSD's own, all under the licence of the files they change |
| `xauth` | X.Org, `xorg/app/xauth` | 1.1.5 | MIT-open-group (`COPYING`) |
| `xinit` | X.Org, `xorg/app/xinit` | 1.4.4 | MIT-open-group and MIT/X11-style, per file (`COPYING`). NextBSD's patches in `patches/xinit/` are under the licence of the files they change |
| `xset` | X.Org, `xorg/app/xset` | 1.2.6 | MIT-open-group (`COPYING`) |
| `setxkbmap` | X.Org, `xorg/app/setxkbmap` | 1.3.5 | HPND (`COPYING`) |
| `xinput` | X.Org, `xorg/app/xinput` | 1.6.4 | HPND / MIT-style, per file (`COPYING`) |
| `xrandr` | X.Org, `xorg/app/xrandr` | 1.5.4 | HPND-sell-variant (`COPYING`) |
| `twm` | X.Org, `xorg/app/twm` | 1.0.13.1 | MIT/X11-style (`COPYING`) |
| `font-misc-misc` | X.Org, `xorg/font/misc-misc` | 1.1.3 | public domain (`COPYING`) |
| `font-cursor-misc` | X.Org, `xorg/font/cursor-misc` | 1.0.4 | public domain (`COPYING`) |
| `font-alias` | X.Org, `xorg/font/alias` | 1.0.6 | MIT/X11-style (`COPYING`) |
| `xclock` | X.Org, `xorg/app/xclock` | 1.2.1 | MIT/X11-style (`COPYING`) |
| `xterm` | Thomas E. Dickey, invisible-island.net (`archives/xterm`) | 412 | MIT/X11-style (`COPYING`) |
| `xf86-input-libinput` | X11Libre, `X11Libre/xf86-input-libinput` (tag `xlibre-xf86-input-libinput-25.0.1`) | 25.0.1 | MIT/X11-style, per file (`COPYING`) |
| `xf86-input-evdev` | X11Libre, `X11Libre/xf86-input-evdev` (tag `xlibre-xf86-input-evdev-25.0.0`) | 25.0.0 | MIT/X11-style, per file (`COPYING`) |
| `xf86-input-joystick` | X11Libre, `X11Libre/xf86-input-joystick` (tag `xlibre-xf86-input-joystick-25.0.0`) | 25.0.0 | MIT/X11-style (`COPYING`) |
| `xf86-input-keyboard` | X11Libre, `X11Libre/xf86-input-keyboard` (tag `xlibre-xf86-input-keyboard-25.0.0`) | 25.0.0 | MIT/X11-style, per file (`COPYING`). Patches in `patches/xf86-input-keyboard/` are from FreeBSD's `x11-drivers/xlibre-xf86-input-keyboard` port |
| `xf86-input-mouse` | X11Libre, `X11Libre/xf86-input-mouse` (tag `xlibre-xf86-input-mouse-25.0.0`) | 25.0.0 | MIT/X11-style, per file (`COPYING`). Patches in `patches/xf86-input-mouse/` are from FreeBSD's `x11-drivers/xlibre-xf86-input-mouse` port |
| `xf86-input-synaptics` | X11Libre, `X11Libre/xf86-input-synaptics` (tag `xlibre-xf86-input-synaptics-25.0.0`) | 25.0.0 | MIT (`COPYING`). Patches in `patches/xf86-input-synaptics/` are from FreeBSD's `x11-drivers/xlibre-xf86-input-synaptics` port |
| `xf86-input-vmmouse` | X11Libre, `X11Libre/xf86-input-vmmouse` (tag `xlibre-xf86-input-vmmouse-25.0.0`) | 25.0.0 | MIT/X11-style, per file (`COPYING`). amd64 only |
| `xf86-video-scfb` | X11Libre, `X11Libre/xf86-video-scfb` (tag `xlibre-xf86-video-scfb-25.0.0`) | 25.0.0 | BSD-2-Clause (`COPYING`) |
| `xf86-video-vesa` | X11Libre, `X11Libre/xf86-video-vesa` (tag `xlibre-xf86-video-vesa-25.0.0`) | 25.0.0 | MIT/X11-style, per file (`COPYING`). amd64 only |

Build input that is staged into the sysroot only and is not part of the
artifact:

| Component | Upstream | Version | Licence |
|---|---|---|---|
| `khronos-headers` | Khronos Group headers from freedesktop.org's `glvnd/libglvnd` (`include/EGL`, `include/KHR`) | libglvnd 1.7.0 | `EGL/*.h` Apache-2.0, `KHR/khrplatform.h` MIT-style (in each header) |
