# nextbsd-xlibre

The XLibre X server stack that NextBSD ships in base, built from pinned
upstream release tarballs into **`/usr/X11`**. It is the last of the three X
repos in E23
([plan](https://github.com/nextbsd/nextbsd-userland/wiki/E23-Display-Server-Graphics-Stack-Plan),
epic nextbsd/nextbsd#561, step 9 onwards), built by hand in this order:

```
nextbsd-toolchain   clang/lld 19.1.7 (+ the tiny static LLVM for llvmpipe)
        │
nextbsd-xlibs       libdrm + the X client libraries
        │
nextbsd-mesa        Mesa + libglvnd
        │
nextbsd-xlibre      the XLibre server, drivers, input stack, xkb, tools   <- this repo
```

So far it builds the server's support libraries and the XKB keymap data and
compiler (nextbsd/nextbsd-xlibre#1), the input stack: libudev-devd, libevdev,
mtdev and libinput with its quirks (nextbsd/nextbsd-xlibre#2), and the XLibre
server 25.2.2 with modesetting and glamor (nextbsd/nextbsd-xlibre#3). The
input and video drivers and the tools follow. No fonts are built: the server
has built-in fonts.

## Rules

1. **Pinned upstream sources only.** Every component is a release tarball (or
   tag archive) listed in `sources.lock` with its version, URL and SHA-256.
   Not FreeBSD packages, not the ports tree or ports tools, not NetBSD's `xsrc`
   or OpenBSD's `xenocara`. Those, and FreeBSD's port patches, may be read as
   references.
2. **Upstream build systems as they are** (meson, autotools, CMake), driven
   with NextBSD's options and cross files. Never rewritten as hand-made
   makefiles.
3. **NextBSD's changes are patch files** in `patches/<component>/`, never
   edits to an unpacked tree, each with its provenance.
4. **Everything installs under `/usr/X11`** (E23 D4) with **upstream sonames**
   (`libepoxy.so.0`, `libxcvt.so.0`): headers in `/usr/X11/include`, libraries
   in `/usr/X11/lib`, `.pc` files in `/usr/X11/lib/pkgconfig`, programs in
   `/usr/X11/bin`. Nothing goes in `/usr/local`, nothing here ships `/etc`
   (configuration belongs in `nextbsd-overlays`), and nothing may replace a
   file of the base, of `nextbsd-xlibs` or of `nextbsd-mesa`.
5. **Only the NextBSD base sysroot and the earlier X repos are linked
   against** (compat's `continuous` base, then the `continuous` artifacts of
   `nextbsd-xlibs` and `nextbsd-mesa`), never `nextbsd-userland`. Build tools come from the toolchain
   image and never ship.
6. **pkgconf, never freedesktop's GPL pkg-config.** No D-Bus, Avahi, udev or
   Wayland. (`libudev-devd` provides the libudev API on NextBSD's devfs and
   sysctl; it is not udev, and no udev rules ship.)

## Layout

```
build-xlibre.sh              cross-build driver: every component, or some by name
sources.lock                 name, version, SHA-256, URL of every upstream tarball
patches/<name>/series        the patches for <name>, in the order applied
patches/<name>/*.patch       one change each, with an Origin: header
cross/meson/<arch>.ini       meson cross files (host_machine system = 'freebsd')
cross/autotools/<arch>.site  autotools CONFIG_SITE files (cross compiler, pkgconf,
cross/autotools/common.site    cache answers for checks that would run a program)
cross/cmake/<arch>.cmake     CMake toolchain files (CMAKE_SYSTEM_NAME FreeBSD)
.github/workflows/build.yml  CI: build both arches, publish `continuous`
NOTICE.md                    per-component provenance and licence
```

Nothing upstream is committed. `build-xlibre.sh` downloads into `.build/dl/`,
unpacks into `.build/src/` and builds out of tree under `.build/`.

## Build model

`build-xlibre.sh` runs inside the `nextbsd-kernel-toolchain` container (the
pinned clang/lld 19.1.7 in `/usr/lib/llvm-19`, meson, ninja, cmake, pkgconf,
autotools, X.Org util-macros, python3, perl and bison) with compat's
`continuous` base extracted as the sysroot and the `continuous` artifacts of
`nextbsd-xlibs` and then `nextbsd-mesa` extracted on top, the same way `nextbsd-printing-support` stages the
repos it builds against. It needs:

| Variable | Meaning |
|---|---|
| `T` | target: `amd64` or `arm64` |
| `TA` | FreeBSD `TARGET_ARCH`: `amd64` or `aarch64` |
| `SYSROOT` | the staged NextBSD base with `nextbsd-xlibs` and `nextbsd-mesa` in `/usr/X11`; scratch, since each component is installed into its `/usr/X11` |
| `CROSS_BINDIR` | the toolchain's clang, lld and LLVM binutils (set by the container image) |
| `DESTDIR` | where to stage the artifact; default `/stage` |

For each component, in `COMPONENTS` order, it:

1. downloads the tarball named in `sources.lock`, refuses it unless the SHA-256
   matches, and unpacks it;
2. applies `patches/<name>/series`;
3. runs the upstream build out of tree and installs it with `DESTDIR`:
   - **meson** with two cross files: one generated per run with the sysroot and
     LLVM paths, then `cross/meson/<arch>.ini`. It declares
     `system = 'freebsd'` (E23 D12), so upstream's FreeBSD code paths apply
     despite the `nextbsd` OS name. `--prefix=/usr/X11 --libdir=lib`, shared
     libraries, no wrap downloads;
   - **CMake** with `cross/cmake/<arch>.cmake` and Ninja,
     `CMAKE_INSTALL_PREFIX=/usr/X11`, shared libraries;
   - **autotools** in `--host=<triple>` mode with
     `CONFIG_SITE=cross/autotools/<arch>.site`, `--with-sysroot`, shared only
     (for the drivers to come);
4. checks and tidies the install (all of it under `/usr/X11`; nothing that
   would replace a file of the base, of `nextbsd-xlibs` or of `nextbsd-mesa`; no `.la` files or
   docs; `.pc` files moved from `share/pkgconfig` or `libdata/pkgconfig` to
   `lib/pkgconfig`; no `.pc` naming `/usr/local` or a build path, no CMake
   package file naming a build path), then copies it into the sysroot, so
   later components find it, and into `DESTDIR`;
5. checks each library's upstream soname and the libraries it links
   (`llvm-readelf -d`), and that its `.pc` resolves through pkgconf.

pkgconf only searches the sysroot (`/usr/X11/lib/pkgconfig`, then
`/usr/libdata/pkgconfig`) with `PKG_CONFIG_SYSROOT_DIR` set, so nothing from
the Linux host leaks into a build.

```
./build-xlibre.sh               # every component
./build-xlibre.sh libxcvt       # one component; its dependencies must already
                                # be in $SYSROOT/usr/X11
```

## Components

In build order (E23 audit 3, section 2.2). pixman, once planned here, is built
by `nextbsd-xlibs` (E24 Q5) and comes from its artifact, as do libxkbfile and
the X client libraries.

| Component | Version | Build | Installs | Ticket |
|---|---|---|---|---|
| `epoll-shim` | 0.0.20240608 | CMake | `libepoll-shim.so.0`, `libepoll-shim-interpose.so.0`, `include/libepoll-shim/sys/{epoll,signalfd}.h`, `epoll-shim.pc` (the server's meson requires it on FreeBSD). eventfd and timerfd come from NextBSD's libc | nextbsd/nextbsd-xlibre#1 |
| `khronos-headers` | libglvnd 1.7.0 | headers | `EGL/` and `KHR/` headers, **sysroot only** (build input for libepoxy; not in the artifact, see [libepoxy](#libepoxy-and-mesa)) | nextbsd/nextbsd-xlibre#1 |
| `libepoxy` | 1.5.10 | meson | `libepoxy.so.0`, `epoxy/` headers, GLX and EGL dispatch | nextbsd/nextbsd-xlibre#1 |
| `libxcvt` | 0.1.3 | meson | `libxcvt.so.0`, `/usr/X11/bin/cvt` | nextbsd/nextbsd-xlibre#1 |
| `xkeyboard-config` | 2.48 | meson | the XKB database in `/usr/X11/share/xkeyboard-config-2`, with `/usr/X11/share/X11/xkb` linking to it; `xkeyboard-config.pc` (no NLS, no man page) | nextbsd/nextbsd-xlibre#1 |
| `xkbcomp` | 1.5.0 | meson | `/usr/X11/bin/xkbcomp`, `xkbcomp.pc` | nextbsd/nextbsd-xlibre#1 |
| `libudev-devd` | 0.7.0 | meson | `libudev.so.0`, `libudev.h`, `libudev.pc` (unmodified; see [input](#input-stack)) | nextbsd/nextbsd-xlibre#2 |
| `libevdev` | 1.14.0 | meson | `libevdev.so.2`, `include/libevdev-1.0/libevdev/`, the `libevdev-tweak-device`, `mouse-dpi-tool` and `touchpad-edge-detector` tools | nextbsd/nextbsd-xlibre#2 |
| `mtdev` | 1.1.7 | autotools | `libmtdev.so.1`, `mtdev.h`, `mtdev-test` | nextbsd/nextbsd-xlibre#2 |
| `libinput` | 1.32.0 | meson | `libinput.so.10`, `libinput.h`, the `libinput` tool and its helpers in `/usr/X11/libexec/libinput`, the quirks database in `/usr/X11/share/libinput` | nextbsd/nextbsd-xlibre#2 |
| `libpciaccess` | 0.19 | meson | `libpciaccess.so.0`, `pciaccess.h`; `/usr/X11/share/hwdata/pci.ids` links to the base's `/usr/share/misc/pci_vendors` | nextbsd/nextbsd-xlibre#3 |
| `xlibre-xserver` | 25.2.2 | meson | `/usr/X11/bin/Xorg` (and `X`), its modules in `/usr/X11/lib/xorg/modules/xlibre-25` (modesetting, glamoregl, glx, exa, fbdevhw, int10, shadow, shadowfb, vgahw, wfb), the Xorg SDK (`include/xorg`, `xorg-server.pc`) for the drivers, `protocol.txt`, man pages. 4 FreeBSD port patches (see [server](#the-x-server)) | nextbsd/nextbsd-xlibre#3 |

Licences are per component; see `NOTICE.md`. The top-level `LICENSE` (BSD-2)
covers only this repo's harness.

### XKB paths

| What | Path |
|---|---|
| Keymap database | `/usr/X11/share/xkeyboard-config-2` (rules, symbols, keycodes, types, compat, geometry) |
| Legacy XKB root | `/usr/X11/share/X11/xkb`, a link to the above. `nextbsd-xlibs`' libxkbcommon (`-Dxkb-config-root`) and `xkbcomp` (`-Dxkb-config-root`) both use this path, and the server will too |
| Compiler | `/usr/X11/bin/xkbcomp` |

### Input stack

libinput reads the kernel's evdev(4) nodes (`/dev/input/event*`) and finds
them through `libudev-devd`, which implements the libudev API on NextBSD's
devfs, sysctl and devinfo. X uses it through `xf86-input-libinput` (a later
step), and the Mouse settings set libinput's properties.

| What | Choice |
|---|---|
| `libudev-devd` | 0.7.0, unmodified (E23 D10); GPL code off. Devices are enumerated when X starts. Its hotplug monitor listens on devd's socket, and NextBSD has no devd, so a device that appears later is not seen until X restarts. Hotplug through IOKit is later work (nextbsd/nextbsd#482) |
| `libinput` options | mtdev on; libwacom, Lua plugins, `debug-gui`, tests, docs and zsh completion off |
| epoll | `epoll-shim` from this repo (`-Depoll-dir` points into the sysroot) |
| Quirks | `/usr/X11/share/libinput/*.quirks`; the local override file is `/usr/X11/etc/libinput/local-overrides.quirks` (not shipped) |
| udev rules and callouts | removed from the install (as FreeBSD's port does): no udevd runs them |
| `linux/input.h` | not shipped. `libevdev` and `libinput` build with the copies in their tarballs; `mtdev` builds with a one-line build-only header that includes the base's `<dev/evdev/input.h>` |
| `kern.evdev.rcpt_mask` | which kernel drivers deliver to evdev. Set in the image by `nextbsd-overlays` (`/etc/sysctl.conf`, applied by `launchctl` at boot), not here |

### The X server

XLibre's `xlibre-xserver-25.2.2` (E23 D5; 25.1.9, what FreeBSD runs today, is
the fallback), from its GitHub tag archive (XLibre publishes no tarballs).

| What | Choice |
|---|---|
| Servers | `Xorg` only. Xvfb, Xnest, Xephyr, Xfbdev, XWin and XQuartz are off; no Xwayland |
| Graphics (D9) | glamor, GBM, the modesetting driver, GLX with DRI, DRI2 and DRI3 on, against `nextbsd-mesa`'s libGL, libEGL and libgbm and this repo's libepoxy. On amd64 the legacy NVIDIA `ScreenRec` padding is on (as FreeBSD builds it), so NVIDIA's `nvidia_drv.so` loads |
| Devices | the udev config backend and KMS device discovery (the platform bus) through `libudev-devd` (`-Dudev=true -Dudev_kms=true`, as FreeBSD's port); `libinput` is the fallback input driver. PCI through `libpciaccess` |
| Not built | HAL, systemd-logind, systemd notify, seatd/libseat, D-Bus, SELinux, DTrace, libunwind, docs, tests, the `inputtest` driver |
| Privilege | **no suid wrapper** (`Xorg.wrap`). X is started as root by launchd/loginwindow, as today, so `Xorg` is a plain 0755 program in `/usr/X11/bin` (the build checks it is not set-uid). `startx` as a normal user needs root; a seat manager is later work |
| Modules | `/usr/X11/lib/xorg/modules/xlibre-25` (the loader searches it, then `xlibre-25.0` and `/usr/X11/lib/xorg/modules`). Drivers from nextbsd/nextbsd-xlibre#4 install there via `xorg-server.pc`'s `moduledir` |
| XKB | rules from `/usr/X11/share/X11/xkb`, `xkbcomp` from `/usr/X11/bin`; compiled keymaps in `/var/run` (root-only, emptied at boot; the server falls back to `/tmp`) |
| Fonts | default font path `built-ins` only |
| Log | `/var/log/Xorg.N.log` |
| Configuration | read from `/usr/X11/etc/X11` and `/etc/X11` as upstream does; none is shipped here (it belongs in `nextbsd-overlays`). Of upstream's `share/X11/xorg.conf.d` snippets only `10-quirks.conf` ships; its NVIDIA ones (Linux `nvidia-drm`, and Debian copies in `etc/`) are removed, as NVIDIA's configuration belongs with the NVIDIA bundle (D15). FreeBSD's `20-evdev-kbd.conf` is not needed: the default XKB rules are already `evdev` |
| SHA-1 | the base's `libmd` |

`patches/xlibre-xserver/` carries 4 of the 8 server patches in FreeBSD's port
(E23 D11), each with its `Origin:`:

| Patch | What |
|---|---|
| `0001` config/udev | a kbdmux keyboard gets the `device` option only if it can be opened; keyboards and pointers get `kbd`/`mouse` when the kernel has no evdev |
| `0002` bsd_init | the console keyboard goes to `K_RAW` (and its termios is saved and restored) while X owns the VT, so keys don't reach the console tty |
| `0003` os-support | builds `SlowBcopy.c` on the BSDs: `xf86SlowBcopy()` is exported in the SDK but 25.2.2 builds it only for Linux |
| `0004` meson | takes epoll-shim's include path from its dependency (25.2.2 adds the build host's `/usr/X11/include/libepoll-shim`, which breaks cross builds); `os/ospoll.c` uses `poll()` as on FreeBSD |

Not carried: the seatd patch (already in 25.2.2), the two suid-wrapper patches
(no wrapper is built) and `os/utils.c`'s `CLOCK_MONOTONIC_COARSE` → `_FAST`
(NextBSD's headers already define the one as the other). `series` records why.

### libepoxy and Mesa

libepoxy does not need Mesa to build, though CI now stages `nextbsd-mesa`
before it:

- **It never links libGL or libEGL.** It `dlopen()`s `libGLX.so.1` (or
  `libGL.so.1`) and `libEGL.so.1` at run time, so it builds with no Mesa in the
  sysroot; the build checks that `libepoxy.so.0` has no `DT_NEEDED` on any GL
  library. At run time the dynamic linker must find Mesa's libraries in
  `/usr/X11/lib` (its `ldconfig` path).
- **Its dispatch code is generated** from the Khronos XML registry bundled in
  the libepoxy tarball. The only outside headers it needs are
  `EGL/eglplatform.h` and `KHR/khrplatform.h` (and Xlib's, from
  `nextbsd-xlibs`). Those are taken from libglvnd 1.7.0, the release
  `nextbsd-mesa` builds, and staged into the sysroot only (`khronos-headers`):
  `nextbsd-mesa` installs the same headers in `/usr/X11/include`, so this
  artifact doesn't, and the two never clash. With `nextbsd-mesa`'s artifact in
  the sysroot (as in CI), its headers are used and `khronos-headers` does
  nothing.
- With Mesa's `gl.pc` and `egl.pc` in the sysroot, `epoxy.pc` lists them in
  `Requires.private`; libepoxy still links neither.

## CI, artifact, package

The workflow builds both arches on every pull request. On a push to `main`, or
a manual run from `main`, it also publishes `nextbsd-xlibre-<arch>.tar.gz` to
the `continuous` release, rooted at `/`.

The artifact holds the whole `/usr/X11` install of this repo: libraries,
programs, data, man pages, headers, `.pc` files and `.so` links. Splitting
runtime from development files, if wanted, is `nextbsd-pkg`'s job (E23 D13,
`NextBSD-xlibre`).

Nothing is dispatched from here, and nothing dispatches here. This repo is run
by hand after `nextbsd-xlibs` and `nextbsd-mesa`, and `nextbsd-pkg` after it.
There is no boot lane: CI proves the cross build, and hardware checks are
manual.

## Adding a component

1. Pin it in `sources.lock`: name, version, SHA-256, URL of the upstream
   release tarball (check the hash against the release announcement or a
   second mirror).
2. Write `build_<name>()` in `build-xlibre.sh`: `fresh_dirs`, `fetch`,
   `meson_build`, `cmake_build` or `autotools_build` with NextBSD's options,
   `stage`, then checks (`soname_check` or `so_check` for each library's
   upstream soname, `needed_check`, `pc_check`). Append `<name>` to
   `COMPONENTS` in build order.
3. If it needs changes, add `patches/<name>/series` and the `.patch` files.
   Each patch starts with a DEP-3-style header: a `Description:` and an
   `Origin:` (upstream commit or merge request, `nextbsd-ports` commit, the
   FreeBSD port file it was taken from, or `NextBSD`), plus `Forwarded:` if it
   was offered upstream. `build-xlibre.sh` refuses a patch without `Origin:` or
   missing from `series`.
4. Configure checks that must run a target program get their FreeBSD answers
   as cache variables in `cross/autotools/` (or `-D` cache entries for CMake),
   with the reason beside each.
5. A row in `NOTICE.md` and in the table above.
