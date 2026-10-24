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
`build-xlibre.sh`, `sources.lock`, `cross/`, `.github/workflows/`, this
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
| `xlibre-xserver` | X11Libre, `X11Libre/xserver` (tag `xlibre-xserver-25.2.2`) | 25.2.2 | MIT/X11-style, per file (`COPYING`). Patches in `patches/xlibre-xserver/` are from FreeBSD's `x11-servers/xlibre-server` port, under the licence of the files they change |

Build input that is staged into the sysroot only and is not part of the
artifact:

| Component | Upstream | Version | Licence |
|---|---|---|---|
| `khronos-headers` | Khronos Group headers from freedesktop.org's `glvnd/libglvnd` (`include/EGL`, `include/KHR`) | libglvnd 1.7.0 | `EGL/*.h` Apache-2.0, `KHR/khrplatform.h` MIT-style (in each header) |
