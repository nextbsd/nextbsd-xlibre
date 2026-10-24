# Upstream sources & licences

`nextbsd-xlibre` builds third-party software NextBSD ships in base under
`/usr/X11`, each **under its own upstream licence**. Their sources are not kept
in this repo: `build-xlibre.sh` downloads the release tarballs pinned in
`sources.lock` and checks their SHA-256. The licence files and headers in those
tarballs are authoritative; this table records provenance and does not
relicense anything.

NextBSD's changes to upstream code live in `patches/<component>/`. Each patch is
under the licence of the file it changes, and says where it came from in its
`Origin:` line.

The top-level **`LICENSE` (BSD 2-Clause)** covers only what this repo authors:
`build-xlibre.sh`, `sources.lock`, `cross/`, `launchd/`, `.github/workflows/`, this
`NOTICE.md` and `README.md`.

| Component | Upstream | Version | Licence |
|---|---|---|---|
| `epoll-shim` | Jan Kokemüller, `jiixyj/epoll-shim` | 0.0.20240608 | MIT (`LICENSE`) |
| `libepoxy` | `anholt/libepoxy` | 1.5.10 | MIT (`COPYING`); the bundled Khronos XML registry is Apache-2.0 / MIT, per file |
| `libxcvt` | X.Org, `xorg/lib/libxcvt` | 0.1.3 | MIT/X11 (`COPYING`) |
| `xkeyboard-config` | freedesktop.org, `xkeyboard-config/xkeyboard-config` | 2.48 | MIT/X11-style, per file (`COPYING`) |
| `xkbcomp` | X.Org, `xorg/app/xkbcomp` | 1.5.0 | HPND / MIT-style (`COPYING`) |
| `libudev-devd` | Vladimir Kondratyev, `wulf7/libudev-devd` | 0.7.0 | BSD-2-Clause (in each file; no `COPYING`). The optional GPL code (`utils-gpl.c`) is not built |
| `libevdev` | freedesktop.org, `libevdev/libevdev` | 1.14.0 | MIT (`COPYING`). The Linux UAPI headers it carries in `include/linux/linux` (GPL-2.0 WITH Linux-syscall-note) are build input only and not installed |
| `mtdev` | Henrik Rydberg, bitmath.org | 1.1.7 | MIT (`COPYING`) |
| `libinput` | freedesktop.org, `libinput/libinput` | 1.32.0 | MIT (`COPYING`); the quirks data is under the same licence. The Linux UAPI headers it carries in `include/linux/linux` are build input only and not installed |
| `libpciaccess` | X.Org, `xorg/lib/libpciaccess` | 0.19 | MIT/X11-style, per file (`COPYING`) |
| `xlibre-xserver` | X11Libre, `X11Libre/xserver` (tag `xlibre-xserver-25.2.2`) | 25.2.2 | MIT/X11-style, per file (`COPYING`). Patches `0001`–`0004` in `patches/xlibre-xserver/` are from FreeBSD's `x11-servers/xlibre-server` port and `0005` is NextBSD's own, all under the licence of the files they change |
| `xauth` | X.Org, `xorg/app/xauth` | 1.1.5 | MIT-open-group (`COPYING`) |
| `xinit` | X.Org, `xorg/app/xinit` | 1.4.4 | MIT-open-group and MIT/X11-style, per file (`COPYING`). NextBSD's patches in `patches/xinit/` are under the licence of the files they change |
| `xset` | X.Org, `xorg/app/xset` | 1.2.6 | MIT-open-group (`COPYING`) |
| `setxkbmap` | X.Org, `xorg/app/setxkbmap` | 1.3.5 | HPND (`COPYING`) |
| `xinput` | X.Org, `xorg/app/xinput` | 1.6.4 | HPND / MIT-style, per file (`COPYING`) |
| `xrandr` | X.Org, `xorg/app/xrandr` | 1.5.4 | HPND-sell-variant (`COPYING`) |
| `xf86-input-libinput` | X11Libre, `X11Libre/xf86-input-libinput` (tag `xlibre-xf86-input-libinput-25.0.1`) | 25.0.1 | MIT/X11-style, per file (`COPYING`) |
| `xf86-input-evdev` | X11Libre, `X11Libre/xf86-input-evdev` (tag `xlibre-xf86-input-evdev-25.0.0`) | 25.0.0 | MIT/X11-style, per file (`COPYING`) |
| `xf86-input-joystick` | X11Libre, `X11Libre/xf86-input-joystick` (tag `xlibre-xf86-input-joystick-25.0.0`) | 25.0.0 | MIT/X11-style (`COPYING`) |
| `xf86-input-keyboard` | X11Libre, `X11Libre/xf86-input-keyboard` (tag `xlibre-xf86-input-keyboard-25.0.0`) | 25.0.0 | MIT/X11-style, per file (`COPYING`). Patches in `patches/xf86-input-keyboard/` are from FreeBSD's `x11-drivers/xlibre-xf86-input-keyboard` port |
| `xf86-input-mouse` | X11Libre, `X11Libre/xf86-input-mouse` (tag `xlibre-xf86-input-mouse-25.0.0`) | 25.0.0 | MIT/X11-style, per file (`COPYING`). Patches in `patches/xf86-input-mouse/` are from FreeBSD's `x11-drivers/xlibre-xf86-input-mouse` port |
| `xf86-input-synaptics` | X11Libre, `X11Libre/xf86-input-synaptics` (tag `xlibre-xf86-input-synaptics-25.0.0`) | 25.0.0 | MIT (`COPYING`). Patches in `patches/xf86-input-synaptics/` are from FreeBSD's `x11-drivers/xlibre-xf86-input-synaptics` port |
| `xf86-input-vmmouse` | X11Libre, `X11Libre/xf86-input-vmmouse` (tag `xlibre-xf86-input-vmmouse-25.0.0`) | 25.0.0 | MIT/X11-style, per file (`COPYING`). amd64 only |
| `xf86-video-scfb` | X11Libre, `X11Libre/xf86-video-scfb` (tag `xlibre-xf86-video-scfb-25.0.0`) | 25.0.0 | BSD-2-Clause (`COPYING`) |
| `xf86-video-vesa` | X11Libre, `X11Libre/xf86-video-vesa` (tag `xlibre-xf86-video-vesa-25.0.0`) | 25.0.0 | MIT/X11-style, per file (`COPYING`). amd64 only |
| `linux-input-shim` | NextBSD (written by `build-xlibre.sh`) | n/a | BSD-2-Clause (this repo's `LICENSE`); each header only includes the base's BSD-2-Clause `<dev/evdev/…>` header |

Build input that is staged into the sysroot only and is not part of the
artifact:

| Component | Upstream | Version | Licence |
|---|---|---|---|
| `khronos-headers` | Khronos Group headers from freedesktop.org's `glvnd/libglvnd` (`include/EGL`, `include/KHR`) | libglvnd 1.7.0 | `EGL/*.h` Apache-2.0, `KHR/khrplatform.h` MIT-style (in each header) |
