# nextbsd-xlibre

The XLibre X server stack that NextBSD ships in base, built from pinned
upstream release tarballs into **`/usr/X11`**. It is the last of the three X
repos in E23
([plan](https://github.com/nextbsd/nextbsd-userland/wiki/E23-Display-Server-Graphics-Stack-Plan),
epic nextbsd/nextbsd#561, step 9 onwards), built by hand in this order:

```
nextbsd-toolchain               clang/lld 19.1.7 (+ the tiny static LLVM for llvmpipe)
        │
nextbsd-displayserver-support   libdrm, pixman, fonts, xkb data, input stack (/usr)
        │
nextbsd-xlibs                   the X client libraries
        │
nextbsd-mesa                    Mesa + libglvnd
        │
nextbsd-xlibre                  the XLibre server, drivers, xkbcomp, tools   <- this repo
```

It builds the server's support libraries and the XKB keymap compiler
(nextbsd/nextbsd-xlibre#1), the XLibre server 25.1.9 with modesetting and
glamor (nextbsd/nextbsd-xlibre#3), its input and video drivers
(nextbsd/nextbsd-xlibre#4), and the X.Org tools xauth, xinit (with startx),
xset, setxkbmap, xinput and xrandr (nextbsd/nextbsd-xlibre#5), and twm and
xterm, the clients the stock xinitrc starts, so `startx` gives a usable
session (nextbsd/nextbsd-xlibre#18). No fonts are built: the server has
built-in fonts.

**What both display servers share is not built here.** The XKB data
(xkeyboard-config), epoll-shim, libudev-devd, libevdev, mtdev, libinput and the
`<linux/input.h>` shim (once nextbsd/nextbsd-xlibre#1, #2 and #4), like
libdrm, pixman, the font stack and libxkbcommon (once in `nextbsd-xlibs`),
moved to
[`nextbsd-displayserver-support`](https://github.com/nextbsd/nextbsd-displayserver-support)
(E25, [plan](https://github.com/nextbsd/nextbsd-userland/wiki/E25-Display-Server-Support-Plan),
nextbsd/nextbsd-xlibre#12) at the same versions, and install in **`/usr`**
(E25 D4). The server and drivers link them from `/usr/lib`, and the server,
`xkbcomp` and `setxkbmap` read the XKB data from `/usr/share/X11/xkb` (see
[XKB paths](#xkb-paths)).

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
   (configuration belongs in `nextbsd-overlays`; `/usr/X11/etc` holds only
   xinit's default `xinitrc`, see [tools](#the-tools)), and nothing may replace a
   file of the base, of `nextbsd-displayserver-support`, of `nextbsd-xlibs` or
   of `nextbsd-mesa`. Outside `/usr/X11` there are only the
   `org.nextbsd.xlibre` LaunchAgent in `/System/Library/LaunchAgents` (see
   [on-demand start](#on-demand-start)) and the empty `/var/db/xkb`, where the
   server writes compiled keymaps.
5. **Only the NextBSD base sysroot and the repos before this one are linked
   against** (compat's `continuous` base, then the `continuous` artifacts of
   `nextbsd-displayserver-support`, `nextbsd-xlibs` and `nextbsd-mesa`), never
   `nextbsd-userland` (`Xorg -launchd` loads its liblaunch only at run time).
   Build tools come from the toolchain image and never ship.
6. **pkgconf, never freedesktop's GPL pkg-config.** No D-Bus, Avahi, udev or
   Wayland. (The libudev in `nextbsd-displayserver-support`, libudev-devd,
   provides the libudev API on NextBSD's devfs and sysctl; it is not udev, and
   no udev rules ship.)

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
launchd/*.plist              the launchd job this repo installs (org.nextbsd.xlibre)
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
`nextbsd-displayserver-support`, `nextbsd-xlibs` and then `nextbsd-mesa`
extracted on top, the same way `nextbsd-printing-support` stages the repos it
builds against. Until nextbsd/nextbsd-xlibs#9, `nextbsd-xlibs`' artifact still
carries its old `/usr/X11` copies of libdrm, pixman, expat, freetype,
fontconfig and libxkbcommon (the same versions); the workflow removes from the
sysroot every `/usr/X11` file that `nextbsd-displayserver-support` ships under
`/usr`, so only the `/usr` copies are found. It needs:

| Variable | Meaning |
|---|---|
| `T` | target: `amd64` or `arm64` |
| `TA` | FreeBSD `TARGET_ARCH`: `amd64` or `aarch64` |
| `SYSROOT` | the staged NextBSD base with `nextbsd-displayserver-support` in `/usr` and `nextbsd-xlibs` and `nextbsd-mesa` in `/usr/X11`; scratch, since each component is installed into its `/usr/X11` |
| `CROSS_BINDIR` | the toolchain's clang, lld and LLVM binutils (set by the container image) |
| `DESTDIR` | where to stage the artifact; default `/stage` |

First it checks the sysroot (`check_displayserver_support`): every module that
moved to `nextbsd-displayserver-support` resolves through pkgconf to its `.pc`
in `/usr/libdata/pkgconfig` with `prefix=/usr`, each moved library is in
`/usr/lib` and has no copy in `/usr/X11/lib`, and the XKB data resolves
through `/usr/share/X11/xkb`. The log says where each one came from. Then, for
each component, in `COMPONENTS` order, it:

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
     (the drivers after `autoreconf -fi`, and some tools);
4. checks and tidies the install (all of it under `/usr/X11`; nothing that
   would replace a file already in the sysroot, that is of the base, of
   `nextbsd-displayserver-support`, of `nextbsd-xlibs` or of `nextbsd-mesa`; no `.la` files or
   docs; `.pc` files moved from `share/pkgconfig` or `libdata/pkgconfig` to
   `lib/pkgconfig`; no `.pc` naming `/usr/local` or a build path, no CMake
   package file naming a build path), then copies it into the sysroot, so
   later components find it, and into `DESTDIR`;
5. checks each library's upstream soname and the libraries it links
   (`llvm-readelf -d`), and that its `.pc` resolves through pkgconf. For the
   server, its modules, the drivers and the tools, every library linked must be
   in the sysroot, and the moved ones in `/usr/lib`; the log shows where each
   resolves.

pkgconf only searches the sysroot (`/usr/X11/lib/pkgconfig`, then
`/usr/libdata/pkgconfig`: the base's and `nextbsd-displayserver-support`'s)
with `PKG_CONFIG_SYSROOT_DIR` set, so nothing from the Linux host leaks into a
build.

```
./build-xlibre.sh               # every component
./build-xlibre.sh libxcvt       # one component; its dependencies must already
                                # be in $SYSROOT/usr/X11
```

## Components

In build order (E23 audit 3, section 2.2). libxkbfile and the X client
libraries come from `nextbsd-xlibs`' artifact; libdrm, pixman, the XKB data
and the input stack from `nextbsd-displayserver-support`'s.

| Component | Version | Build | Installs | Ticket |
|---|---|---|---|---|
| `khronos-headers` | libglvnd 1.7.0 | headers | `EGL/` and `KHR/` headers, **sysroot only** (build input for libepoxy; not in the artifact, see [libepoxy](#libepoxy-and-mesa)) | nextbsd/nextbsd-xlibre#1 |
| `libepoxy` | 1.5.10 | meson | `libepoxy.so.0`, `epoxy/` headers, GLX and EGL dispatch | nextbsd/nextbsd-xlibre#1 |
| `libxcvt` | 0.1.3 | meson | `libxcvt.so.0`, `/usr/X11/bin/cvt` | nextbsd/nextbsd-xlibre#1 |
| `xkbcomp` | 1.5.0 | meson | `/usr/X11/bin/xkbcomp`, `xkbcomp.pc` (XKB root `/usr/share/X11/xkb`) | nextbsd/nextbsd-xlibre#1 |
| `libpciaccess` | 0.19 | meson | `libpciaccess.so.0`, `pciaccess.h`; `/usr/X11/share/hwdata/pci.ids` links to the base's `/usr/share/misc/pci_vendors` | nextbsd/nextbsd-xlibre#3 |
| `xlibre-xserver` | 25.1.9 | meson | `/usr/X11/bin/Xorg` (and `X`), its modules in `/usr/X11/lib/xorg/modules/xlibre-25` (modesetting, glamoregl, glx, exa, fbdevhw, int10, shadow, shadowfb, vgahw, wfb), the Xorg SDK (`include/xorg`, `xorg-server.pc`) for the drivers, `protocol.txt`, man pages. 4 FreeBSD port patches (see [server](#the-x-server)) | nextbsd/nextbsd-xlibre#3 |
| `xauth` | 1.1.5 | autotools | `/usr/X11/bin/xauth`, `xauth.1` | nextbsd/nextbsd-xlibre#5 |
| `xinit` | 1.4.4 | autotools | `/usr/X11/bin/xinit` and `startx`, `/usr/X11/etc/X11/xinit/xinitrc`, `xinit.1`, `startx.1`. 2 NextBSD patches (see [tools](#the-tools)) | nextbsd/nextbsd-xlibre#5 |
| `xset` | 1.2.6 | meson | `/usr/X11/bin/xset`, `xset.1` | nextbsd/nextbsd-xlibre#5 |
| `setxkbmap` | 1.3.5 | meson | `/usr/X11/bin/setxkbmap`, `setxkbmap.1` | nextbsd/nextbsd-xlibre#5 |
| `xinput` | 1.6.4 | autotools | `/usr/X11/bin/xinput`, `xinput.1` | nextbsd/nextbsd-xlibre#5 |
| `xrandr` | 1.5.4 | meson | `/usr/X11/bin/xrandr`, `xrandr.1` (not `xkeystone`, a script for the nickle interpreter) | nextbsd/nextbsd-xlibre#5 |
| `twm` | 1.0.13.1 | autotools | `/usr/X11/bin/twm`, `/usr/X11/share/X11/twm/system.twmrc`, `twm.1` | nextbsd/nextbsd-xlibre#18 |
| `xterm` | 412 | autotools | `/usr/X11/bin/xterm`, `resize`, `uxterm`, `koi8rxterm`, their man pages, app-defaults in `/usr/X11/share/X11/app-defaults` (see [session clients](#the-session-clients)) | nextbsd/nextbsd-xlibre#18 |
| `xf86-input-libinput` | 25.0.1 | autotools | `input/libinput_drv.so`, `libinput-properties.h`, `xorg-libinput.pc`, `40-libinput.conf`, `libinput.4x` | nextbsd/nextbsd-xlibre#4 |
| `xf86-input-evdev` | 25.0.0 | autotools | `input/evdev_drv.so`, `evdev-properties.h`, `10-evdev.conf`, `evdev.4x` | nextbsd/nextbsd-xlibre#4 |
| `xf86-input-joystick` | 25.0.0 | autotools | `input/joystick_drv.so` (BSD usbhid and evdev backends), `joystick-properties.h`, `joystick.4x` | nextbsd/nextbsd-xlibre#4 |
| `xf86-input-keyboard` | 25.0.0 | autotools | `input/kbd_drv.so`, `kbd.4x`. 4 FreeBSD port patches | nextbsd/nextbsd-xlibre#4 |
| `xf86-input-mouse` | 25.0.0 | autotools | `input/mouse_drv.so`, `xf86-mouse-properties.h`, `mousedrv.4x`. 4 FreeBSD port patches (about 1,270 lines) | nextbsd/nextbsd-xlibre#4 |
| `xf86-input-synaptics` | 25.0.0 | autotools | `input/synaptics_drv.so` (psmcomm, ps2comm, eventcomm), `synclient`, `syndaemon`, `synaptics-properties.h`, man pages; no `70-synaptics.conf`. 3 FreeBSD port patches | nextbsd/nextbsd-xlibre#4 |
| `xf86-input-vmmouse` | 25.0.0 | autotools | **amd64 only**: `input/vmmouse_drv.so`, `vmmouse_detect`, man pages | nextbsd/nextbsd-xlibre#4 |
| `xf86-video-scfb` | 25.0.0 | autotools | `drivers/scfb_drv.so`, `scfb.4x` | nextbsd/nextbsd-xlibre#4 |
| `xf86-video-vesa` | 25.0.0 | autotools | **amd64 only**: `drivers/vesa_drv.so`, `vesa.4x` | nextbsd/nextbsd-xlibre#4 |

Licences are per component; see `NOTICE.md`. The top-level `LICENSE` (BSD-2)
covers only this repo's harness.

### XKB paths

The XKB data is `nextbsd-displayserver-support`'s xkeyboard-config (E25,
nextbsd/nextbsd-xlibre#12). The server, `xkbcomp` and `setxkbmap` are built
for its paths, and the build checks each names `/usr/share/X11/xkb` and not the
old `/usr/X11/share/X11/xkb`.

| What | Path |
|---|---|
| Keymap database | `/usr/share/xkeyboard-config-2` (rules, symbols, keycodes, types, compat, geometry) |
| XKB root | `/usr/share/X11/xkb`, a link to the above: the server (`-Dxkb_dir`), `xkbcomp` and `setxkbmap` (`-Dxkb-config-root`), and `nextbsd-displayserver-support`'s libxkbcommon |
| Compiler | `/usr/X11/bin/xkbcomp` (the server's `-Dxkb_bin_dir`) |
| Compiled keymaps | `/var/db/xkb` (the server's `-Dxkb_output_dir`), an empty directory this repo ships. The server writes there only if it can, and otherwise in `$XDG_RUNTIME_DIR` or `/tmp` |

### Input

libinput, libevdev, mtdev, libudev (libudev-devd) and `<linux/input.h>` are
`nextbsd-displayserver-support`'s: libraries in `/usr/lib`, `.pc` files in
`/usr/libdata/pkgconfig`, the quirks in `/usr/share/libinput`. X uses libinput
through `xf86-input-libinput`, and the Mouse settings set libinput's
properties. Devices are enumerated when X starts; NextBSD has no devd, so a
device that appears later is not seen until X restarts (hotplug through IOKit
is E25 D7). Which kernel drivers deliver to evdev (`kern.evdev.rcpt_mask`) is
set in the image by `nextbsd-overlays` (`/etc/sysctl.conf`), not here.

### The X server

XLibre's `xlibre-xserver-25.1.9`, from its GitHub tag archive (XLibre
publishes no tarballs). It is the release upstream marks "Latest"; every 25.2.x
is a pre-release (testing), so the pin is E23 D5's fallback, the version
FreeBSD's port builds (maintainer decision, 2026-10-25).

| What | Choice |
|---|---|
| Servers | `Xorg` only. Xvfb, Xnest, Xephyr, Xfbdev, XWin and XQuartz are off; no Xwayland |
| Graphics (D9) | glamor, GBM, the modesetting driver, GLX with DRI, DRI2 and DRI3 on, against `nextbsd-mesa`'s libGL, libEGL and libgbm, `nextbsd-displayserver-support`'s libdrm and pixman (in `/usr/lib`) and this repo's libepoxy. On amd64 the legacy NVIDIA `ScreenRec` padding is on (as FreeBSD builds it), so NVIDIA's `nvidia_drv.so` loads |
| Devices | the udev config backend and KMS device discovery (the platform bus) through `nextbsd-displayserver-support`'s libudev (libudev-devd; `-Dudev=true -Dudev_kms=true`, as FreeBSD's port); `libinput` is the fallback input driver. PCI through `libpciaccess` |
| Not built | HAL, systemd-logind, systemd notify, seatd/libseat, D-Bus, SELinux, DTrace, libunwind, docs, tests, the `inputtest` driver |
| Privilege | `/usr/X11/bin/Xorg` is **set-uid root** (mode 4555), as upstream installs it without a wrapper (nextbsd/nextbsd-xlibre#20): NextBSD has no seat manager, and the server needs root for the console/VT, `/dev/dri` and `/dev/input`. **No suid wrapper** (`Xorg.wrap`) and no console-only restriction: any user may start X, locally or over SSH. The build allows exactly this one set-uid file and refuses any other set-uid or set-gid file. A rootless display server is later E25 work |
| DRI drivers | GLX loads Mesa's DRI drivers from `/usr/X11/lib/dri`, given explicitly (`-Ddri_driver_path`, patch `0006`): upstream takes `dri.pc`'s `dridriverdir`, which pkgconf returns with the build sysroot in front (nextbsd/nextbsd-xlibre#20). The build checks `libglx.so` names only that directory, and that no shipped file names the build sysroot or checkout |
| Modules | `/usr/X11/lib/xorg/modules/xlibre-25` (the loader searches it, then `xlibre-25.0` and `/usr/X11/lib/xorg/modules`). The drivers (nextbsd/nextbsd-xlibre#4) install there, `xorg-server.pc`'s `moduledir` (see [drivers](#drivers)) |
| XKB | rules from `/usr/share/X11/xkb`, `xkbcomp` from `/usr/X11/bin`, compiled keymaps in `/var/db/xkb` (see [XKB paths](#xkb-paths)) |
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
| `0003` os-support | builds `SlowBcopy.c` on the BSDs: `xf86SlowBcopy()` is exported in the SDK but 25.1.9 builds it only for Linux |
| `0004` meson | takes epoll-shim's include path from its dependency (25.1.9 adds the build host's `<epoll-shim prefix>/include/libepoll-shim`, which breaks cross builds); `os/ospoll.c` uses `poll()` as on FreeBSD |

and two of NextBSD's own:

| Patch | What |
|---|---|
| `0005` os | `-launchd <name>`: listen only on the sockets of the launchd job's `Sockets` entry `<name>`, for [on-demand start](#on-demand-start). The socket's directory must belong to the server's real uid (the user who started it; `Xorg` is set-uid root) |
| `0006` meson | `-Ddri_driver_path`: GLX's DRI driver directory set explicitly (`/usr/X11/lib/dri`) instead of `dri.pc`'s `dridriverdir`, which pkgconf prefixes with the build sysroot (nextbsd/nextbsd-xlibre#20) |

Not carried: the seatd patch (it changes only `seatd-libseat.c`, not built with
seatd off), the two suid-wrapper patches
(no wrapper is built) and `os/utils.c`'s `CLOCK_MONOTONIC_COARSE` → `_FAST`
(NextBSD's headers already define the one as the other). `series` records why.

### On-demand start

The XQuartz launch model on NextBSD's launchd-842 (nextbsd/nextbsd-xlibre#13;
E25 plan, "X apps when the WindowServer is primary", option 2): a per-user
LaunchAgent owns the `DISPLAY` socket, and launchd starts the X server when the
first X client connects.

- **The job**, `launchd/org.nextbsd.xlibre.plist`, installed as
  `/System/Library/LaunchAgents/org.nextbsd.xlibre.plist`. Its `Sockets` entry
  `org.nextbsd.xlibre:0` has `SecureSocketWithKey = DISPLAY`: when the agent is
  loaded into a user's session, launchctl makes a private directory
  (`mkdtemp`, mode 0700, owned by the user), binds the socket in it and sets
  `DISPLAY` to its path for the session's jobs. libxcb, and so libX11, takes
  a socket path as `DISPLAY`.
- **The server**, `Xorg -launchd org.nextbsd.xlibre:0 -terminate` (patch
  `0005`). It collects the socket with `launch_activate_socket()` (liblaunch,
  nextbsd/nextbsd-userland#447) and adds it with the server's
  `ListenOnOpenFD()`, as XQuartz does. Because only the user can enter the
  socket's directory, clients need no xauth cookie on it (a launchd socket
  anywhere else keeps X authorization). With `-launchd` the server opens no
  `/tmp/.X11-unix` socket and writes no lock file, so it never clashes with
  an X server started by a login window. liblaunch is `dlopen()`ed only for
  `-launchd`: `Xorg` doesn't link it, and an X server started any other way
  behaves exactly as before.
- **When it runs:** only while it has clients. No `RunAtLoad` or `KeepAlive`;
  `-terminate` makes the server exit after its last client, launchd keeps the
  socket, and the next client starts it again. Its stdout and stderr go to
  `/dev/null`; Xorg writes its own log (for a user,
  `~/.local/share/xorg/Xorg.0.log`).

**Per-user, not a system daemon.** NextBSD's launchd has per-user launchd
instances and LaunchAgents (nextbsd/nextbsd-userland#354; `pam_launchd` puts
console and SSH logins in the per-user `Background` session), and
`SecureSocketWithKey` is a per-session mechanism: the socket and the
`DISPLAY` it exports belong to that user's session. A system LaunchDaemon
can't do this: PID 1 loads `/System/Library/LaunchDaemons` itself and neither
creates `Sockets` nor honours `Disabled` there, and a root-owned socket that
everyone may use would need either X authorization the clients don't have or
none at all.

**Disabled by default.** The agent is `Disabled` and, like XQuartz's, limited
to the `Aqua` session type (launchd-842's default for agents). NextBSD has no
`Aqua` sessions until graphical logins move into them
(nextbsd/nextbsd-userland#372), and today's images start X from the login
window, so the agent does nothing on current images and can't start a second
X server behind the login window's back. Once a user's graphical login runs
in an `Aqua` session, the user turns it on from that session with

```
launchctl load -w -S Aqua /System/Library/LaunchAgents/org.nextbsd.xlibre.plist
```

(`-w` records it in the user's launchd overrides, so it stays on at the next
login; `launchctl unload -w -S Aqua …` turns it off again). Jobs started in the
session then see `DISPLAY`; a shell gets it with `launchctl getenv DISPLAY`.

To try it today in a console login's `Background` session, load a copy with
`LimitLoadToSessionType` set to `Background`:

```
mkdir -p ~/Library/LaunchAgents
sed 's#<string>Aqua</string>#<string>Background</string>#' \
    /System/Library/LaunchAgents/org.nextbsd.xlibre.plist \
    > ~/Library/LaunchAgents/org.nextbsd.xlibre.plist
launchctl load -F -S Background ~/Library/LaunchAgents/org.nextbsd.xlibre.plist
export DISPLAY="$(launchctl getenv DISPLAY)"
xset q        # the first client starts Xorg
```

The server runs set-uid root (see Privilege above), so it can open the DRM,
input and VT devices whichever user loads the agent. The socket handling is not tied to `Xorg`: a rootless XLibre server inside the
WindowServer (nextbsd/nextbsd-xlibre#14), which runs as the user anyway, is
meant to start the same way.

### The tools

The latest X.Org releases of the tools in E23's scope, step 13: xauth and
xinit (the rest of FreeBSD's `xlibre-minimal`), and xset, setxkbmap, xinput
and xrandr, which the desktop runs. `xdotool` is not an X.Org program and is
built by `nextbsd-gershwin-support` (E24). Each tool is in `/usr/X11/bin` with
its man page in `/usr/X11/share/man/man1`, and links only the X client
libraries in `/usr/X11/lib` (`nextbsd-xlibs`) and the base; the build checks
each library it links resolves there and that no build-host RPATH is set.
`setxkbmap` reads the XKB data from `/usr/share/X11/xkb`.

| What | Choice |
|---|---|
| X server | `/usr/X11/bin/X`, the server build's link to `Xorg`. startx is configured with it, and xinit's default server is it too (patch `0002`; upstream runs `X` from `$PATH`) |
| xauth | `/usr/X11/bin/xauth`, the path startx runs. Upstream's startx still ran a bare `xauth` from `$PATH` in two places; patch `0001` makes it use the configured path throughout |
| xinitrc | the system xinitrc is upstream's sample, `/usr/X11/etc/X11/xinit/xinitrc`, under the server's own configuration directory (`/usr/X11/etc/X11`); startx also looks there for `xserverrc` and `xinitrc.d/*.sh`. It starts twm and three xterms and ends with `exec xterm` (twm and xterm are built here, see [session clients](#the-session-clients)); its `xclock &` line fails in the background, since xclock is not shipped. A session of one's own belongs in `~/.xinitrc` (or `$XINITRC`). Installed executable, as upstream does since 1.4.4: startx hands it to xinit as the client program. xinit itself reads only `~/.xinitrc` |
| Cookies | startx makes the MIT-MAGIC-COOKIE with the base's `/usr/bin/openssl rand -hex 16` |
| Privilege | `Xorg` is set-uid root, with no suid wrapper (see [server](#the-x-server)), so `startx` works for any user |
| Not built | xinit's Apple launchd support (XQuartz's `privileged_startx` and LaunchAgents); xset's fontcache and XFree86-Misc extensions (gone from servers; no library in `nextbsd-xlibs`); xrandr's `xkeystone` |
| `/usr/local` | none: the build checks startx, xinitrc, every tool and its man page name neither `/usr/local` nor a build path (patch `0001` also drops `/usr/local/bin` from a comment in startx's Darwin-only branch) |

`patches/xinit/`:

| Patch | What |
|---|---|
| `0001` startx | runs xauth as `"$xauth"` (`/usr/X11/bin/xauth`) everywhere, not a bare `xauth` from `$PATH` for the server's cookie file and the `xauth list` lookup |
| `0002` xinit | the default server is `BINDIR "/X"` (`/usr/X11/bin/X`) instead of `X` from `$PATH` |

### The session clients

twm and xterm (nextbsd/nextbsd-xlibre#18): what the stock xinitrc runs (it
ends with `exec xterm`, and xterm is startx's fallback client). Without them
startx's client exits at once and xinit stops the server. Each is in
`/usr/X11/bin` with its man page, linking only `nextbsd-xlibs`' X client
libraries, `nextbsd-displayserver-support`'s freetype and fontconfig, and the
base; the build checks each library it links resolves there and that no
build-host RPATH is set.

| What | Choice |
|---|---|
| twm | X.Org's 1.0.13.1 release tarball. RandR on. Its default configuration is `/usr/X11/share/X11/twm/system.twmrc` (also compiled in). The tarball carries the generated parser; configure finds the toolchain image's bison and flex |
| xterm | Thomas Dickey's xterm 412 from invisible-island.net (not an X.Org or XLibre project). Menus with Xaw7 (`libXaw.so.7`, nextbsd/nextbsd-xlibs#11; xterm cannot be built without an Athena library), TrueType fonts through Xft, fontconfig and freetype, Xinerama, termcap/terminfo from the base's ncurses |
| xterm app-defaults | `/usr/X11/share/X11/app-defaults` (XTerm, UXTerm, KOI8RXTerm and their `-color` variants), the directory `nextbsd-xlibs`' libXt searches |
| Privilege | xterm and resize are not set-uid or set-gid (`--disable-setuid --disable-setgid`); the pty comes from `openpty(3)`, and no utmpx entry is written |
| Not built | xterm's Xpm icons (`--without-xpm`, no pixmap directory), `.desktop` files, luit (`--disable-luit`; no luit is shipped), utempter, imake, the `-rpath` configure would add for `/usr/X11/lib`; xclock |

### Drivers

X11Libre's driver tags at 25.0.x (E23 D5), from their GitHub tag archives
(the same files, by SHA-256, that FreeBSD's `x11-drivers/xlibre-xf86-*`
ports fetch). The tags ship no `configure`, so each is `autoreconf -fi` with
the staged server's `xorg-server.m4` and the toolchain image's util-macros,
then built against the server SDK in the sysroot. Modules go in
`/usr/X11/lib/xorg/modules/xlibre-25/{input,drivers}`, the SDK headers some
of them install in `/usr/X11/include/xorg`, and `xorg.conf.d` snippets in
`/usr/X11/share/X11/xorg.conf.d`. The module and configuration directories
are given to `configure` explicitly: asked of pkgconf with
`PKG_CONFIG_SYSROOT_DIR` set, they would come back with the sysroot in front.
Driver man pages use the `4x` suffix in `man4`, as FreeBSD installs them, so
`kbd.4x` and `mousedrv.4x` don't shadow the base's `keyboard(4)` and
`mouse(4)`.

| Driver | Role | Notes |
|---|---|---|
| `libinput` | the input driver: every pointer, keyboard, touchpad, touch screen and tablet on `/dev/input/event*` (`40-libinput.conf`), and the server's fallback | links `libinput.so.10`; the Mouse settings use its properties (D10) |
| `evdev` | the older evdev driver, if an `xorg.conf` names it | links `libevdev`, `libmtdev` and `libudev.so.0` itself (FreeBSD's port hides libudev from `configure` and lets the `udev_*` calls resolve against `Xorg`). `10-evdev.conf` sorts before `40-libinput.conf`, so libinput keeps the devices. FreeBSD's `webcamd` dependency isn't needed for kernel evdev devices |
| `joystick` | joysticks as pointers | BSD backend on `/dev/uhid*` (base `libusbhid`) and evdev backend (FreeBSD's port has only the first) |
| `keyboard` (`kbd`) | the console keyboard (syscons/vt(4), kbdmux) when the kernel has no evdev | 4 FreeBSD patches: AT multimedia scancodes, `K_RAW` for a non-console keyboard, no `GIO_KEYMAP` query (it crashes the server on vt(4)), close a non-console keyboard on `DEVICE_OFF` |
| `mouse` | `/dev/sysmouse`, `/dev/psm*`, `/dev/ums*` when the kernel has no evdev | 4 FreeBSD patches, about 1,270 lines, mostly the BSD backend (moused detection, PS/2 models, a USB HID protocol with absolute and touch devices). The patched backend calls `libusbhid` and nothing links it, so it is built with `LIBS=-lusbhid` |
| `synaptics` | the older touchpad driver, with `synclient` and `syndaemon` | psmcomm, ps2comm/alpscomm and eventcomm (`BUILD_EVENTCOMM=yes`, as the port); 3 FreeBSD patches (autoreconf without an `m4/` directory, eventcomm off Linux). **`70-synaptics.conf` is not shipped**: it would take every touchpad from libinput, and the Mouse settings need libinput. Name the driver in an `xorg.conf` to use it |
| `vmmouse` | amd64 only: VMware's (and QEMU's vmport) absolute pointer, through `/dev/io` | HAL callout and fdi, the udev rule and `50-vmmouse.conf` (it matches only the tag that udev rule sets) are not installed; name the driver in an `xorg.conf` |
| `scfb` | the console framebuffer, unaccelerated: the fallback when modesetting has no KMS device | |
| `vesa` | amd64 only: VESA BIOS modes (int10, vgahw), unaccelerated | its `pci_*` calls resolve against `Xorg`'s libpciaccess |

The patches are in `patches/xf86-input-{mouse,keyboard,synaptics}/`, from
FreeBSD's ports at commit `efd79beed9`, each with its `Origin:`; all 11
apply to the 25.0.0 tags unchanged and are carried. The other drivers have no
port patches.

**`linux/input.h`.** The evdev, libinput, synaptics (eventcomm) and joystick
(evdev backend) drivers include `<linux/input.h>`. It is
`nextbsd-displayserver-support`'s `linux-input-shim`: three one-line headers
in `/usr/include/linux-input-shim/linux` that include the base's BSD-licensed
`<dev/evdev/…>` headers (the same structures and ioctls; FreeBSD's ports use
`devel/evdev-proto`, Linux's GPL uapi headers, instead). The drivers get it
through pkgconf, never through a path of this repo: `libevdev.pc` (evdev,
synaptics) requires `linux-input-shim`, and libinput and joystick, which
include `<linux/input.h>` without libevdev, get `pkgconf --cflags
linux-input-shim` in `CPPFLAGS`. The build checks both carry the shim's
directory. There is no `linux/joystick.h` or `linux/version.h`.

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
programs, data, man pages, headers, `.pc` files and `.so` links, plus the
`org.nextbsd.xlibre` LaunchAgent in `/System/Library/LaunchAgents` and the
empty `/var/db/xkb`. Since nextbsd/nextbsd-xlibre#12 it no longer has
epoll-shim, the XKB data, libudev, libevdev, mtdev, libinput or the
`<linux/input.h>` shim: those are in `nextbsd-displayserver-support`'s
artifact. Splitting
runtime from development files, if wanted, is `nextbsd-pkg`'s job (E23 D13,
`NextBSD-xlibre`).

Nothing is dispatched from here, and nothing dispatches here. This repo is run
by hand after `nextbsd-displayserver-support`, `nextbsd-xlibs` and
`nextbsd-mesa`, and `nextbsd-pkg` after it.
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
5. A row in `NOTICE.md` and in the table above. Libraries or data the
   GNUstep WindowServer needs too belong in `nextbsd-displayserver-support`,
   not here (E25 D3).
