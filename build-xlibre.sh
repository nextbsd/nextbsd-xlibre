#!/usr/bin/env bash
# =============================================================================
# build-xlibre.sh — cross-build driver for nextbsd-xlibre
# =============================================================================
#
# Builds the XLibre X server's stack NextBSD ships in base (E23, plan step 9
# onwards) for ONE architecture, from pinned upstream release tarballs, into
# the /usr/X11 prefix with upstream sonames. So far: the server's support
# libraries (epoll-shim, libepoxy, libxcvt), the XKB keymap data and compiler
# (xkeyboard-config, xkbcomp), the input stack (libudev-devd, libevdev,
# mtdev, libinput) and the XLibre server (libpciaccess, xlibre-xserver with
# modesetting and glamor); the drivers and the tools follow.
#
# For each component, in COMPONENTS order:
#   1. fetch:   download the tarball named in sources.lock, refuse it unless
#               its SHA-256 matches, unpack it under .build/src/;
#   2. patch:   apply patches/<name>/series in order (each patch must state
#               its Origin:);
#   3. build:   upstream meson (cross/meson/<arch>.ini), autotools
#               (cross/autotools/<arch>.site, --host=<triple>) or CMake
#               (cross/cmake/<arch>.cmake), out of tree, installed with
#               DESTDIR into .build/<name>-root-<arch>/;
#   4. stage:   check and tidy that install, then copy it into $SYSROOT (so
#               later components find its headers, .pc files and libraries)
#               and into $DESTDIR (the published artifact).
#
# Upstream build systems are used as they are, with NextBSD's options; nothing
# is rewritten as a hand-made makefile. Nothing here uses FreeBSD packages, the
# ports tree or ports tools, and nothing links against nextbsd-userland: the
# inputs are sources.lock, the NextBSD base (compat) sysroot, and nextbsd-xlibs'
# (the X client libraries, libdrm, pixman, libxkbfile) and nextbsd-mesa's
# (libglvnd, Mesa's GL/EGL/GBM) `continuous` artifacts on top.
#
# EXECUTION CONTEXT (set up by CI before this runs)
#   Inside the nextbsd-kernel-toolchain container (pinned clang/lld 19.1.7 in
#   $CROSS_BINDIR, meson, ninja, cmake, pkgconf, autotools, util-macros,
#   python3, perl, bison), with compat's `continuous` base, then nextbsd-xlibs'
#   and nextbsd-mesa's `continuous` artifacts, extracted into $SYSROOT.
#   $SYSROOT is scratch: this script installs every component into its
#   /usr/X11 as it goes.
#
# USAGE
#   ./build-xlibre.sh              every component, in COMPONENTS order
#   ./build-xlibre.sh libxcvt      named components only (their dependencies
#                                  must already be in $SYSROOT/usr/X11)
# =============================================================================

set -euo pipefail

# ---- required environment ----------------------------------------------------
: "${T:?set T to the target (amd64 / arm64)}"
: "${TA:?set TA to the target_arch (amd64 / aarch64)}"
: "${SYSROOT:?set SYSROOT to the staged NextBSD base}"
: "${CROSS_BINDIR:?set CROSS_BINDIR to the dir holding the cross clang/lld}"
: "${DESTDIR:=/stage}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/.build"
DL="$BUILD/dl"
LOCK="$ROOT/sources.lock"
PATCHES="$ROOT/patches"
XLIBRE_CROSS="$ROOT/cross"

# Install prefix (E23 D4), shared with nextbsd-xlibs. .pc files are gathered in
# $X_PREFIX/lib/pkgconfig whatever the upstream default, so one directory goes
# on pkgconf's path.
X_PREFIX=/usr/X11

case "$T" in
    amd64) CROSS_TRIPLE=x86_64-unknown-freebsd ;;
    arm64) CROSS_TRIPLE=aarch64-unknown-freebsd ;;
    *)     echo "FAIL: unsupported T=$T (amd64 / arm64)" >&2; exit 1 ;;
esac
BUILD_TRIPLE="$(uname -m)-pc-linux-gnu"
JOBS=-j"$(nproc 2>/dev/null || echo 2)"

SYSROOT="$(cd "$SYSROOT" && pwd)"
export SYSROOT DESTDIR CROSS_BINDIR XLIBRE_CROSS

# ---- helpers -----------------------------------------------------------------
comp() { echo; echo "==> [$T/$TA] $*"; }
note() { echo "    - $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# lock_field <name> <version|sha256|url>: a component's pin from sources.lock.
lock_field() {
    local name="$1" field="$2" col
    case "$field" in
        version) col=2 ;;
        sha256)  col=3 ;;
        url)     col=4 ;;
        *)       fail "lock_field: unknown field $field" ;;
    esac
    awk -v n="$name" -v c="$col" '$1 == n && $1 !~ /^#/ { print $c; found=1 } END { exit !found }' "$LOCK" \
        || fail "$name is not pinned in sources.lock"
}

# Assert a staged object links a given library (a cross `readelf -d` check; we
# cannot exec target binaries on the runner).
needed_check() {
    local obj="$1" want="$2"
    "$CROSS_BINDIR/llvm-readelf" -d "$obj" 2>/dev/null | grep -q "NEEDED.*\[$want" \
        || fail "$obj missing DT_NEEDED $want"
    note "DT_NEEDED ok: $(basename "$obj") -> $want"
}

# Assert a staged shared library carries the upstream soname.
soname_check() {
    local lib="$1" want="$2"
    "$CROSS_BINDIR/llvm-readelf" -d "$lib" 2>/dev/null | grep -q "SONAME.*\[$want\]" \
        || fail "$lib does not have SONAME $want"
    note "SONAME ok: $want"
}

# so_check <soname>...: each staged $X_PREFIX/lib/<soname> exists and carries
# that soname (the upstream one; libtool and meson name the file after it).
so_check() {
    local s
    for s in "$@"; do
        [ -e "$DESTDIR$X_PREFIX/lib/$s" ] || fail "$X_PREFIX/lib/$s not staged"
        soname_check "$DESTDIR$X_PREFIX/lib/$s" "$s"
    done
}

# lib_needs <soname> <needed>...: a staged library links each <needed>.
lib_needs() {
    local lib="$DESTDIR$X_PREFIX/lib/$1" n
    shift
    for n in "$@"; do needed_check "$lib" "$n"; done
}

# not_needed <file> <pattern>...: a staged object links none of the libraries
# matching <pattern> (an extended regex on the DT_NEEDED name).
not_needed() {
    local obj="$1" p
    shift
    for p in "$@"; do
        if "$CROSS_BINDIR/llvm-readelf" -d "$obj" | grep -E "NEEDED.*\[$p"; then
            fail "$(basename "$obj") links $p"
        fi
    done
    note "DT_NEEDED ok: $(basename "$obj") links none of: $*"
}

# no_build_rpath <file>: a staged object has no RPATH/RUNPATH naming the build
# host (this repo, the sysroot); the run-time linker finds /usr/X11/lib through
# ldconfig, not through paths baked in at build time.
no_build_rpath() {
    local obj="$1"
    if "$CROSS_BINDIR/llvm-readelf" -d "$obj" | grep -E '\((RPATH|RUNPATH)\)' | grep -F -e "$ROOT" -e "$SYSROOT"; then
        fail "$(basename "$obj") has an RPATH/RUNPATH naming a build-host path"
    fi
    note "no build-host RPATH: $(basename "$obj")"
}

# fetch <name>: download (cached in .build/dl), verify and unpack the pinned
# tarball, apply the patch series. Sets SRC_DIR and VERSION.
fetch() {
    local name="$1" url sha file got top
    VERSION=$(lock_field "$name" version)
    url=$(lock_field "$name" url)
    sha=$(lock_field "$name" sha256)
    file="$DL/$(basename "$url")"
    mkdir -p "$DL"
    if [ ! -f "$file" ]; then
        note "fetch $url"
        curl -fsSL --retry 3 -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    got=$(sha256sum "$file" | cut -d' ' -f1)
    [ "$got" = "$sha" ] || { rm -f "$file"; fail "$name: SHA-256 mismatch for $(basename "$file") (got $got, sources.lock has $sha)"; }
    note "$name $VERSION, sha256 ok"
    SRC_DIR="$BUILD/src/$name-$VERSION"
    rm -rf "$SRC_DIR"
    mkdir -p "$SRC_DIR"
    tar -xf "$file" -C "$SRC_DIR" --strip-components=1
    apply_patches "$name"
}

# apply_patches <name>: patches/<name>/series lists the patches in order, one
# per line (# comments allowed). Every *.patch in the directory must be listed,
# and every patch must say where it came from in an `Origin:` header line
# (DEP-3 style: upstream commit or MR, nextbsd-ports, a FreeBSD port file used
# as a reference, or "NextBSD" for our own).
apply_patches() {
    local name="$1" dir="$PATCHES/$1" p n=0
    [ -d "$dir" ] || return 0
    [ -f "$dir/series" ] || fail "patches/$name has no series file"
    for p in "$dir"/*.patch; do
        [ -e "$p" ] || continue
        grep -qx "$(basename "$p")" "$dir/series" || fail "patches/$name/$(basename "$p") is not listed in series"
    done
    while read -r p; do
        case "$p" in ''|'#'*) continue ;; esac
        [ -f "$dir/$p" ] || fail "patches/$name/series lists missing $p"
        grep -q '^Origin:' "$dir/$p" || fail "patches/$name/$p has no Origin: line"
        patch -d "$SRC_DIR" -p1 --forward --batch --quiet < "$dir/$p" || fail "patches/$name/$p does not apply"
        note "patch $p"
        n=$((n + 1))
    done < "$dir/series"
    note "$n patch(es) applied"
}

# Fresh out-of-tree build and install-root directories for a component.
fresh_dirs() {
    local name="$1"
    COMP_BUILD="$BUILD/$name-$T"
    COMP_ROOT="$BUILD/$name-root-$T"
    rm -rf "$COMP_BUILD" "$COMP_ROOT"
    mkdir -p "$COMP_BUILD" "$COMP_ROOT"
}

# meson_build [meson -D options...]: configure, build and install $SRC_DIR into
# $COMP_ROOT with the arch's cross file. The first cross file is generated here
# and carries the paths of this run; the second is the checked-in one.
meson_build() {
    local paths="$BUILD/cross/paths-$T.ini"
    mkdir -p "$BUILD/cross"
    cat > "$paths" <<EOF
[constants]
sysroot = '$SYSROOT'
llvm_bindir = '$CROSS_BINDIR'
EOF
    meson setup "$COMP_BUILD" "$SRC_DIR" \
        --cross-file "$paths" --cross-file "$XLIBRE_CROSS/meson/$T.ini" \
        --prefix="$X_PREFIX" --libdir=lib --buildtype=release \
        -Ddefault_library=shared --wrap-mode=nodownload \
        "$@"
    meson compile -C "$COMP_BUILD"
    DESTDIR="$COMP_ROOT" meson install -C "$COMP_BUILD" --no-rebuild
}

# autotools_build [configure options...]: upstream configure in --host mode with
# the arch's CONFIG_SITE, out of tree; make; make install into $COMP_ROOT.
autotools_build() {
    (
        cd "$COMP_BUILD"
        CONFIG_SITE="$XLIBRE_CROSS/autotools/$T.site" \
        "$SRC_DIR/configure" \
            --build="$BUILD_TRIPLE" --host="$CROSS_TRIPLE" \
            --with-sysroot="$SYSROOT" \
            --prefix="$X_PREFIX" --libdir="$X_PREFIX/lib" \
            --enable-shared --disable-static \
            --disable-dependency-tracking --disable-silent-rules \
            "$@"
        make $JOBS
        make install DESTDIR="$COMP_ROOT"
    )
}

# cmake_build [cmake -D options...]: configure, build and install $SRC_DIR into
# $COMP_ROOT with the arch's toolchain file (cross/cmake/<arch>.cmake).
cmake_build() {
    cmake -S "$SRC_DIR" -B "$COMP_BUILD" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$XLIBRE_CROSS/cmake/$T.cmake" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$X_PREFIX" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_INSTALL_MANDIR=share/man \
        -DBUILD_SHARED_LIBS=ON \
        "$@"
    cmake --build "$COMP_BUILD" $JOBS
    DESTDIR="$COMP_ROOT" cmake --install "$COMP_BUILD"
}

# The files already in the sysroot before this script installs anything: the
# compat base and the /usr/X11 of nextbsd-xlibs and nextbsd-mesa. Listed while
# the sysroot holds none of this repo's files (epoll-shim's header, the first
# component's, is the marker), so stage can refuse a component that would
# overwrite a base, nextbsd-xlibs or nextbsd-mesa file. A later partial run
# reuses the list.
base_list() {
    BASE_LIST="$BUILD/base-files-$T.list"
    mkdir -p "$BUILD"
    [ -f "$SYSROOT$X_PREFIX/include/X11/Xlib.h" ] \
        || fail "$SYSROOT$X_PREFIX has no nextbsd-xlibs (X11/Xlib.h); stage its continuous artifact first"
    if [ ! -e "$SYSROOT$X_PREFIX/include/libepoll-shim/sys/epoll.h" ]; then
        (cd "$SYSROOT" && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort) > "$BASE_LIST"
    elif [ ! -f "$BASE_LIST" ]; then
        fail "$SYSROOT already holds this repo's files but $BASE_LIST is missing; start from a fresh compat base and nextbsd-xlibs"
    fi
}

# stage <name> [sysroot-only]: tidy and check $COMP_ROOT, then copy it into
# $SYSROOT (for the components after this one) and $DESTDIR (the artifact).
#   - everything must be under /usr/X11, and nothing may replace a base file;
#   - libtool .la files and docs are dropped (man pages are kept);
#   - .pc files from share/pkgconfig and libdata/pkgconfig move to
#     lib/pkgconfig;
#   - a .pc file has prefix=/usr/X11 (or, data-only, sets no path outside
#     it); none may name /usr/local or a build-host path, and no CMake
#     package file a build-host path.
# With sysroot-only, the component is build input for later components and is
# left out of the artifact (khronos-headers).
stage() {
    local name="$1" where="${2:-}" x="$COMP_ROOT$X_PREFIX" stray f d clash
    [ -d "$x" ] || fail "$name installed nothing under $X_PREFIX"
    stray=$(cd "$COMP_ROOT" && find . -mindepth 1 ! -path ./usr ! -path ".$X_PREFIX" ! -path ".$X_PREFIX/*")
    [ -z "$stray" ] || fail "$name installed outside $X_PREFIX: $stray"
    find "$x" -name '*.la' -delete
    rm -rf "$x/share/doc"
    # meson puts a library's .pc in libdata/pkgconfig when host_machine is
    # freebsd (the base layout), arch-independent ones in share/pkgconfig.
    for d in share/pkgconfig libdata/pkgconfig; do
        [ -d "$x/$d" ] || continue
        mkdir -p "$x/lib/pkgconfig"
        mv "$x/$d"/*.pc "$x/lib/pkgconfig/"
        rmdir "$x/$d"
    done
    for f in "$x"/lib/pkgconfig/*.pc; do
        [ -e "$f" ] || continue
        # A data-only .pc (xkeyboard-config's) has no prefix= line; then
        # every absolute path it sets must be under the prefix.
        if grep -q '^prefix=' "$f"; then
            grep -q "^prefix=$X_PREFIX\$" "$f" || fail "$(basename "$f"): prefix is not $X_PREFIX"
        elif grep -E '^[A-Za-z_]+=/' "$f" | grep -v -E "^[A-Za-z_]+=$X_PREFIX(/|\$)"; then
            fail "$(basename "$f"): sets a path outside $X_PREFIX"
        fi
        if grep -n -F -e /usr/local -e "$ROOT" -e "$SYSROOT" "$f"; then
            fail "$(basename "$f") names /usr/local or a build-host path"
        fi
    done
    for f in "$x"/lib/cmake/*/*.cmake; do
        [ -e "$f" ] || continue
        if grep -n -F -e "$ROOT" -e "$SYSROOT" "$f"; then
            fail "$(basename "$f") names a build-host path"
        fi
    done
    find "$x" -type d -empty -delete
    clash=$(cd "$COMP_ROOT" && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort | LC_ALL=C comm -12 - "$BASE_LIST")
    [ -z "$clash" ] || fail "$name would replace files of the NextBSD base, nextbsd-xlibs or nextbsd-mesa: $clash"
    (cd "$COMP_ROOT" && tar -cf - .) | (cd "$SYSROOT" && tar -xf -)
    if [ "$where" = sysroot-only ]; then
        note "staged $(cd "$COMP_ROOT" && find . ! -type d | wc -l) files (sysroot only, not in the artifact)"
        return 0
    fi
    (cd "$COMP_ROOT" && tar -cf - .) | (cd "$DESTDIR" && tar -xf -)
    note "staged $(cd "$COMP_ROOT" && find . ! -type d | wc -l) files"
}

# pc_check <module> [version]: the staged .pc resolves through pkgconf the way
# later components will see it (and, if given, at that version).
pc_check() {
    local mod="$1" want="${2:-}" got
    got=$(PKG_CONFIG_LIBDIR="$SYSROOT$X_PREFIX/lib/pkgconfig:$SYSROOT/usr/libdata/pkgconfig" PKG_CONFIG_SYSROOT_DIR="$SYSROOT" \
          pkgconf --modversion "$mod") || fail "pkgconf cannot resolve $mod"
    [ -z "$want" ] || [ "$got" = "$want" ] || fail "$mod.pc is version $got, expected $want"
    note "pkgconf ok: $mod $got"
}


# =============================================================================
# Components, in build order (E23 audit 3, section 2.2): the server's support
# libraries, then the XKB data and compiler (nextbsd-xlibre#1). pixman moved
# to nextbsd-xlibs (E24 Q5) and comes from its artifact.
# =============================================================================

# epoll-shim — epoll(7), signalfd(2) on kqueue, which the XLibre server's
# meson requires on FreeBSD (os/ostimer and the input thread). CMake.
#
# NextBSD's libc has eventfd(2) and timerfd_create(2), so epoll-shim builds and
# installs neither (as the FreeBSD port does on 15): its sys/eventfd.h and
# sys/timerfd.h would shadow the base headers. Two configure checks run a
# target program and are answered here for cross builds:
#   ALLOWS_ONESHOT_TIMERS_WITH_TIMEOUT_ZERO  FreeBSD's EVFILT_TIMER accepts a
#       zero timeout with EV_ONESHOT (filt_timerattach only bumps 0 to 1 for
#       periodic timers), so the quirk stays off;
#   the POLLRDHUP probe  its value is read from the sysroot's sys/poll.h. The
#       probe program calls printf without <stdio.h>, which clang 19 refuses,
#       so the build falls back to upstream's 0x2000 as it does natively; the
#       answer only matters if that ever compiles.
# The tests (and microatf, the test framework they need) are off.
build_epoll_shim() {
    comp "epoll-shim [cmake cross]"
    fresh_dirs epoll-shim
    fetch epoll-shim
    local rdhup
    rdhup=$(awk '$1 == "#define" && $2 == "POLLRDHUP" { print $3 }' "$SYSROOT/usr/include/sys/poll.h")
    [ -n "$rdhup" ] || fail "POLLRDHUP not found in the sysroot's sys/poll.h"
    cmake_build -DBUILD_TESTING=OFF \
        -DALLOWS_ONESHOT_TIMERS_WITH_TIMEOUT_ZERO=1 \
        -DHAVE_POLLRDHUP_RUN_RESULT=0 \
        -DHAVE_POLLRDHUP_RUN_RESULT__TRYRUN_OUTPUT="$rdhup"
    stage epoll-shim
    local x="$DESTDIR$X_PREFIX/include/libepoll-shim"
    test -f "$x/sys/epoll.h" || fail "libepoll-shim/sys/epoll.h not staged"
    test -f "$x/sys/signalfd.h" || fail "libepoll-shim/sys/signalfd.h not staged"
    for h in eventfd timerfd; do
        [ ! -e "$x/sys/$h.h" ] || fail "libepoll-shim/sys/$h.h staged; the base's sys/$h.h must be used"
    done
    note "EPOLLRDHUP is $(awk '$2 == "EPOLLRDHUP" { print $3 }' "$x/sys/epoll.h")"
    so_check libepoll-shim.so.0 libepoll-shim-interpose.so.0
    lib_needs libepoll-shim-interpose.so.0 libepoll-shim.so.0
    pc_check epoll-shim
    pc_check epoll-shim-interpose
}

# khronos-headers — the Khronos EGL/ and KHR/ headers (egl.h, eglext.h,
# eglplatform.h, khrplatform.h), build input for libepoxy's EGL dispatch:
# epoxy/egl_generated.h includes EGL/eglplatform.h. They are copied from
# libglvnd 1.7.0's include/, the release nextbsd-mesa builds (the Khronos
# EGL-Registry has no tags), into the sysroot only: nextbsd-mesa's libglvnd
# installs the same headers in /usr/X11/include, so they are not in this
# artifact. If the sysroot already has them (nextbsd-mesa staged in), those
# are used and nothing is copied.
build_khronos_headers() {
    comp "khronos-headers [headers, build input only]"
    if [ -f "$SYSROOT$X_PREFIX/include/EGL/eglplatform.h" ]; then
        note "EGL/eglplatform.h already in the sysroot (nextbsd-mesa, or an earlier run); nothing to do"
        return 0
    fi
    fresh_dirs khronos-headers
    fetch khronos-headers
    local inc="$COMP_ROOT$X_PREFIX/include" h
    install -d "$inc/EGL" "$inc/KHR"
    for h in EGL/egl.h EGL/eglext.h EGL/eglplatform.h KHR/khrplatform.h; do
        install -m 0644 "$SRC_DIR/include/$h" "$inc/$h"
    done
    stage khronos-headers sysroot-only
}

# libepoxy — the GL/GLES/EGL/GLX function-pointer dispatch library glamor and
# the modesetting driver use. meson; GLX and EGL dispatch on, X11 on, no tests
# or docs.
#
# libepoxy never links libGL or libEGL: it dlopen()s libGLX.so.1/libGL.so.1 and
# libEGL.so.1 at run time, so Mesa (nextbsd-mesa) is not needed to build it.
# The dispatch tables are generated from the Khronos XML registry it bundles;
# the only outside headers are EGL/eglplatform.h and KHR/khrplatform.h
# (nextbsd-mesa's, or khronos-headers above) and Xlib's (nextbsd-xlibs). CI
# stages nextbsd-mesa first, so its gl.pc and egl.pc are found and epoxy.pc
# lists them in Requires.private; without them it lists none.
build_libepoxy() {
    comp "libepoxy [meson cross]"
    fresh_dirs libepoxy
    fetch libepoxy
    meson_build -Dglx=yes -Degl=yes -Dx11=true -Dtests=false -Ddocs=false
    stage libepoxy
    local x="$DESTDIR$X_PREFIX" v
    for h in gl glx egl gl_generated glx_generated egl_generated; do
        test -f "$x/include/epoxy/$h.h" || fail "epoxy/$h.h not staged"
    done
    so_check libepoxy.so.0
    not_needed "$x/lib/libepoxy.so.0" 'libGL' 'libEGL' 'libGLES' 'libOpenGL'
    pc_check epoxy "$VERSION"
    for v in epoxy_has_glx epoxy_has_egl; do
        [ "$(PKG_CONFIG_LIBDIR="$SYSROOT$X_PREFIX/lib/pkgconfig" pkgconf --variable="$v" epoxy)" = 1 ] \
            || fail "epoxy.pc: $v is not 1"
        note "epoxy.pc: $v=1"
    done
}

# libxcvt — VESA CVT mode lines (the server's RandR and modesetting), and the
# cvt tool. meson.
build_libxcvt() {
    comp "libxcvt [meson cross]"
    fresh_dirs libxcvt
    fetch libxcvt
    meson_build
    stage libxcvt
    test -x "$DESTDIR$X_PREFIX/bin/cvt" || fail "cvt not staged"
    test -f "$DESTDIR$X_PREFIX/include/libxcvt/libxcvt.h" || fail "libxcvt/libxcvt.h not staged"
    so_check libxcvt.so.0
    pc_check libxcvt "$VERSION"
}

# xkeyboard-config — the XKB keymap database. meson (python3 generates the
# rules files, perl the .lst files on the build host). The data goes in
# /usr/X11/share/xkeyboard-config-2, with upstream's /usr/X11/share/X11/xkb
# link to it: that is where nextbsd-xlibs' libxkbcommon, xkbcomp below and the
# server look. Compatibility rules on (upstream default), no "xorg" rules links
# (the server's default rules are evdev), no NLS (translated descriptions in
# the registry XML only; msgfmt is not in the toolchain image). The man page
# needs xsltproc, which the image does not have, so it is not built.
build_xkeyboard_config() {
    comp "xkeyboard-config [meson cross]"
    fresh_dirs xkeyboard-config
    fetch xkeyboard-config
    meson_build -Dnls=false -Dcompat-rules=true -Dxorg-rules-symlinks=false \
        -Dnon-latin-layouts-list=false
    stage xkeyboard-config
    local x="$DESTDIR$X_PREFIX" d="$DESTDIR$X_PREFIX/share/xkeyboard-config-2" f link
    for f in rules/evdev rules/base rules/evdev.xml rules/evdev.lst rules/base.lst \
             keycodes/evdev symbols/us symbols/pc types/basic compat/basic; do
        test -f "$d/$f" || fail "xkeyboard-config-2/$f not staged"
    done
    link=$(readlink "$x/share/X11/xkb") || fail "$X_PREFIX/share/X11/xkb not staged"
    [ "$link" = "$X_PREFIX/share/xkeyboard-config-2" ] \
        || fail "$X_PREFIX/share/X11/xkb points to $link, not $X_PREFIX/share/xkeyboard-config-2"
    note "$X_PREFIX/share/X11/xkb -> $link"
    pc_check xkeyboard-config "$VERSION"
    [ "$(PKG_CONFIG_LIBDIR="$SYSROOT$X_PREFIX/lib/pkgconfig" pkgconf --variable=xkb_base xkeyboard-config)" = "$X_PREFIX/share/X11/xkb" ] \
        || fail "xkeyboard-config.pc: xkb_base is not $X_PREFIX/share/X11/xkb"
    note "xkeyboard-config.pc: xkb_base=$X_PREFIX/share/X11/xkb"
}

# xkbcomp — the XKB keymap compiler the server runs at start-up and on
# keymap changes, in /usr/X11/bin. meson (bison on the build host). Its XKB
# config root is /usr/X11/share/X11/xkb, the same path libxkbcommon uses.
build_xkbcomp() {
    comp "xkbcomp [meson cross]"
    fresh_dirs xkbcomp
    fetch xkbcomp
    meson_build -Dxkb-config-root="$X_PREFIX/share/X11/xkb"
    stage xkbcomp
    local bin="$DESTDIR$X_PREFIX/bin/xkbcomp"
    test -x "$bin" || fail "xkbcomp not staged"
    needed_check "$bin" libxkbfile.so.1
    needed_check "$bin" libX11.so.6
    grep -q -a -F "$X_PREFIX/share/X11/xkb" "$bin" || fail "xkbcomp does not name $X_PREFIX/share/X11/xkb"
    note "xkbcomp XKB config root: $X_PREFIX/share/X11/xkb"
    pc_check xkbcomp "$VERSION"
}

# =============================================================================
# The input stack (nextbsd-xlibre#2, E23 D10): libinput, which the server's
# xf86-input-libinput driver uses and whose properties the Mouse settings set,
# and what it needs: a libudev (libudev-devd), libevdev and mtdev.
#
# The kernel's evdev(4) nodes (/dev/input/event*) carry the events. Which
# drivers deliver to them is the kern.evdev.rcpt_mask policy, set in the image
# by nextbsd-overlays (/etc/sysctl.conf), not here.
# =============================================================================

# libudev-devd 0.7.0 — the libudev API on NextBSD's devfs, sysctl and devinfo:
# libinput enumerates input devices through it. Unmodified (E23 D10). meson.
#
# It finds /dev/input/event*, /dev/kbdmux*, /dev/sysmouse and the rest once,
# when the caller enumerates (X start-up). Its udev_monitor (hotplug) listens
# on devd's socket, and NextBSD has no devd, so devices that appear later are
# not seen: hotplug through IOKit is later work (nextbsd/nextbsd#482). The GPL
# code (enable-gpl) stays off. Upstream's default is werror=true; clang 19
# adds warnings 0.7.0 predates, so -Werror is off (as FreeBSD's port does).
# Links the base's libdevinfo and libprocstat.
build_libudev_devd() {
    comp "libudev-devd [meson cross]"
    fresh_dirs libudev-devd
    fetch libudev-devd
    meson_build -Dwerror=false -Denable-gpl=false
    stage libudev-devd
    test -f "$DESTDIR$X_PREFIX/include/libudev.h" || fail "libudev.h not staged"
    so_check libudev.so.0
    lib_needs libudev.so.0 libdevinfo.so libprocstat.so
    no_build_rpath "$DESTDIR$X_PREFIX/lib/libudev.so.0"
    # libudev-devd's .pc claims udev 243's API level; libinput asks for none.
    pc_check libudev 243
}

# libevdev — the evdev device wrapper libinput (and later xf86-input-evdev)
# uses. meson; python3 generates the event-name tables on the build host. The
# kernel interface comes from the copy of NextBSD's dev/evdev/input.h the
# tarball carries (include/linux/freebsd/, picked by host_machine.system()).
# The tools (libevdev-tweak-device, mouse-dpi-tool, touchpad-edge-detector)
# are built; the tests (they need check) and the doxygen docs are not.
build_libevdev() {
    comp "libevdev [meson cross]"
    fresh_dirs libevdev
    fetch libevdev
    meson_build -Dtests=disabled -Ddocumentation=disabled -Dtools=enabled
    stage libevdev
    local x="$DESTDIR$X_PREFIX" t
    for h in libevdev libevdev-uinput; do
        test -f "$x/include/libevdev-1.0/libevdev/$h.h" || fail "libevdev/$h.h not staged"
    done
    for t in libevdev-tweak-device mouse-dpi-tool touchpad-edge-detector; do
        test -x "$x/bin/$t" || fail "$t not staged"
    done
    so_check libevdev.so.2
    no_build_rpath "$x/lib/libevdev.so.2"
    pc_check libevdev "$VERSION"
}

# mtdev — turns multitouch protocol A devices into protocol B slots for
# libinput. autotools.
#
# mtdev.h includes <linux/input.h>, which NextBSD's base doesn't have (FreeBSD
# gets it from the devel/evdev-proto port, which is not used here). For the
# library's own build, a one-line linux/input.h that includes the base's
# <dev/evdev/input.h> (the same kernel ABI) goes on the include path. It lives
# in the build directory only; nothing ships it, and mtdev.h is installed
# unchanged. libinput brings its own linux/input.h for its include of mtdev.h.
build_mtdev() {
    comp "mtdev [autotools cross]"
    fresh_dirs mtdev
    fetch mtdev
    local compat="$BUILD/evdev-compat-$T"
    rm -rf "$compat"
    mkdir -p "$compat/linux"
    printf '%s\n' '/* NextBSD build-only shim: the base kernel evdev ABI. */' \
        '#include <dev/evdev/input.h>' > "$compat/linux/input.h"
    autotools_build CPPFLAGS="-I$compat"
    stage mtdev
    test -f "$DESTDIR$X_PREFIX/include/mtdev.h" || fail "mtdev.h not staged"
    test -x "$DESTDIR$X_PREFIX/bin/mtdev-test" || fail "mtdev-test not staged"
    so_check libmtdev.so.1
    no_build_rpath "$DESTDIR$X_PREFIX/lib/libmtdev.so.1"
    pc_check mtdev "$VERSION"
}

# libinput — the input library behind xf86-input-libinput. meson.
#
# Options: mtdev on; libwacom off (no libwacom in base, E23 D10); Lua plugins
# off, and so no plugin autoloading; no debug-gui (GTK), tests or docs; no zsh
# completion (it would go in /usr/X11/share/zsh, outside zsh's fpath).
#
# epoll comes from epoll-shim (built above). libinput's meson looks for it
# under -Depoll-dir (default: its own prefix, i.e. the build host's
# /usr/X11), so that points into the sysroot.
#
# Installed: libinput.so.10 and libinput.h; the libinput tool in bin and its
# helpers in libexec/libinput (the Python ones need a python3 at run time, as
# upstream); the quirks database in /usr/X11/share/libinput (the local
# override file is /usr/X11/etc/libinput/local-overrides.quirks, not shipped).
# The udev rules and callouts in /usr/X11/lib/udev are removed, as FreeBSD's
# port does: NextBSD has no udevd to run them.
build_libinput() {
    comp "libinput [meson cross]"
    fresh_dirs libinput
    fetch libinput
    meson_build -Dlibwacom=false -Dmtdev=true -Dlua-plugins=disabled \
        -Dautoload-plugins=false -Ddebug-gui=false -Dtests=false \
        -Dinstall-tests=false -Ddocumentation=false -Dzshcompletiondir=no \
        -Depoll-dir="$SYSROOT$X_PREFIX"
    rm -rf "$COMP_ROOT$X_PREFIX/lib/udev"
    stage libinput
    local x="$DESTDIR$X_PREFIX" q n t
    test -f "$x/include/libinput.h" || fail "libinput.h not staged"
    so_check libinput.so.10
    lib_needs libinput.so.10 libudev.so.0 libevdev.so.2 libmtdev.so.1 libepoll-shim.so.0
    not_needed "$x/lib/libinput.so.10" 'libwacom' 'liblua' 'libgtk' 'libglib'
    no_build_rpath "$x/lib/libinput.so.10"
    test -x "$x/bin/libinput" || fail "the libinput tool is not staged"
    no_build_rpath "$x/bin/libinput"
    for t in libinput-list-devices libinput-debug-events libinput-quirks libinput-record; do
        test -x "$x/libexec/libinput/$t" || fail "libexec/libinput/$t not staged"
        no_build_rpath "$x/libexec/libinput/$t"
    done
    # Every quirks file in the tarball is installed, and libinput was built
    # to read them from there.
    n=0
    for q in "$SRC_DIR"/quirks/*.quirks; do
        test -f "$x/share/libinput/$(basename "$q")" || fail "quirks $(basename "$q") not staged"
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] || fail "no quirks files in the libinput tarball"
    note "$n quirks files in $X_PREFIX/share/libinput"
    grep -q -a -F "$X_PREFIX/share/libinput" "$x/lib/libinput.so.10" \
        || fail "libinput.so.10 does not name $X_PREFIX/share/libinput"
    [ ! -e "$x/lib/udev" ] || fail "$X_PREFIX/lib/udev staged"
    pc_check libinput "$VERSION"
}

# =============================================================================
# The X server (nextbsd-xlibre#3, E23 step 11): libpciaccess, then the XLibre
# server with modesetting and glamor (D9) and FreeBSD's server patches (D11).
# Mesa (libGL, libEGL, libgbm, dri.pc) comes from nextbsd-mesa's artifact,
# staged into the sysroot by CI.
# =============================================================================

# libpciaccess 0.19 — PCI bus access for the server (and, later, the vesa
# driver). meson. FreeBSD's backend (/dev/pci) is picked by host_machine.
#
# Device and vendor names come from a pci.ids file in -Dpci-ids, by default
# /usr/X11/share/hwdata. NextBSD's base already has the PCI ID Project's
# database as /usr/share/misc/pci_vendors (the same file format), so rather
# than ship a second copy, /usr/X11/share/hwdata/pci.ids is a link to it.
# Names only show up in logs and scanpci; nothing breaks without them. No
# zlib (the database is not compressed); scanpci is not installed.
build_libpciaccess() {
    comp "libpciaccess [meson cross]"
    fresh_dirs libpciaccess
    fetch libpciaccess
    meson_build -Dpci-ids=hwdata -Dzlib=disabled -Dinstall-scanpci=false \
        -Dlinux-rom-fallback=false
    install -d "$COMP_ROOT$X_PREFIX/share/hwdata"
    ln -s /usr/share/misc/pci_vendors "$COMP_ROOT$X_PREFIX/share/hwdata/pci.ids"
    stage libpciaccess
    local x="$DESTDIR$X_PREFIX"
    test -f "$x/include/pciaccess.h" || fail "pciaccess.h not staged"
    so_check libpciaccess.so.0
    no_build_rpath "$x/lib/libpciaccess.so.0"
    grep -q -a -F "$X_PREFIX/share/hwdata" "$x/lib/libpciaccess.so.0" \
        || fail "libpciaccess.so.0 does not name $X_PREFIX/share/hwdata"
    [ "$(readlink "$x/share/hwdata/pci.ids")" = /usr/share/misc/pci_vendors ] \
        || fail "$X_PREFIX/share/hwdata/pci.ids does not link to /usr/share/misc/pci_vendors"
    test -f "$SYSROOT/usr/share/misc/pci_vendors" \
        || note "the sysroot has no /usr/share/misc/pci_vendors (the runtime base does)"
    note "$X_PREFIX/share/hwdata/pci.ids -> /usr/share/misc/pci_vendors"
    pc_check pciaccess "$VERSION"
}

# xlibre-xserver 25.2.2 — the XLibre X server: Xorg, its modules and the SDK
# (headers, xorg-server.pc) the drivers build against. meson. The tag archive
# is pinned (no release tarballs); patches/xlibre-xserver/ holds the FreeBSD
# port's server patches that 25.2.2 still needs (D11; series says which and
# why the others are not carried).
#
# Servers: Xorg only. Xvfb, Xnest, Xephyr, Xfbdev, XWin and XQuartz are off;
# there is no Xwayland in this tree.
#
# Graphics (D9): libdrm (nextbsd-xlibs), GBM, EGL and GL (nextbsd-mesa) and
# libepoxy are all in the sysroot, so glamor, the modesetting driver (meson
# builds it only with GBM), GLX with DRI, DRI2 and DRI3 are on; meson is told
# so explicitly, so a missing dependency fails the build instead of quietly
# dropping them. On amd64 the legacy NVIDIA ScreenRec padding is on, as in
# FreeBSD's port: NVIDIA's nvidia_drv.so is built for that ABI (E23 D15).
#
# Input and devices: the udev config backend and KMS device discovery
# (platform bus) through libudev-devd (-Dudev=true -Dudev_kms=true, as FreeBSD's
# port builds it); xf86-input-libinput is the fallback input driver. No HAL,
# no systemd-logind (it needs D-Bus), no seatd/libseat, no systemd notify, no
# D-Bus at all.
#
# Privilege: no suid wrapper (Xorg.wrap). X is started as root by launchd /
# loginwindow, as it is today (E23 audit 3), so Xorg is installed as a plain
# 0755 program in /usr/X11/bin; the build checks it is not set-uid. A user
# running startx needs root, as with any X without a wrapper; a seat manager
# would be later work.
#
# Paths: modules under /usr/X11/lib/xorg/modules (25.2.2 installs them in its
# xlibre-25 ABI directory there, which the loader searches first); XKB data
# /usr/X11/share/X11/xkb, xkbcomp from /usr/X11/bin; compiled keymaps in
# /var/run (root-only, emptied at boot; the server falls back to /tmp if it
# can't write there); logs in /var/log (Xorg.N.log); the default font path is
# the built-in fonts only (NextBSD ships no X core fonts). Configuration is
# read from /usr/X11/etc/X11 and /etc/X11 as upstream does; none is shipped
# here (it belongs in nextbsd-overlays). SHA-1 from the base's libmd; no
# libunwind, DTrace, SELinux, docs or tests; the inputtest driver is off.
build_xlibre_xserver() {
    comp "xlibre-xserver [meson cross]"
    local h
    for h in gbm.h EGL/egl.h GL/gl.h; do
        [ -f "$SYSROOT$X_PREFIX/include/$h" ] \
            || fail "$SYSROOT$X_PREFIX has no nextbsd-mesa ($h); stage its continuous artifact first"
    done
    fresh_dirs xlibre-xserver
    fetch xlibre-xserver
    local nvidia=false
    [ "$T" = amd64 ] && nvidia=true
    meson_build \
        -Dxorg=true -Dxvfb=false -Dxnest=false -Dxephyr=false -Dxfbdev=false \
        -Dxwin=false -Dxquartz=false \
        -Dglamor=true -Dgbm=true -Ddrm=true -Dglx=true -Dglx_dri=true \
        -Ddri2=true -Ddri3=true -Dpciaccess=true \
        -Dudev=true -Dudev_kms=true -Dhal=false -Dsystemd_logind=false \
        -Dsystemd_notify=false -Dseatd_libseat=false -Dsuid_wrapper=false \
        -Dxselinux=false -Ddtrace=false -Dlibunwind=false \
        -Ddocs=false -Ddevel-docs=false -Ddocs-pdf=false -Dtests=false \
        -Dxf86-input-inputtest=false \
        -Dsha1=libmd -Dxcsecurity=true -Dfallback_input_driver=libinput \
        -Dlegacy_nvidia_padding="$nvidia" \
        -Dlog_dir=/var/log -Ddefault_font_path=built-ins \
        -Dxkb_dir="$X_PREFIX/share/X11/xkb" -Dxkb_bin_dir="$X_PREFIX/bin" \
        -Dxkb_output_dir=/var/run
    stage xlibre-xserver
    local x="$DESTDIR$X_PREFIX" mods="$DESTDIR$X_PREFIX/lib/xorg/modules/xlibre-25" xorg m s
    xorg="$x/bin/Xorg"
    test -x "$xorg" || fail "Xorg not staged"
    [ ! -u "$xorg" ] || fail "Xorg is set-uid"
    [ ! -e "$x/libexec/Xorg.wrap" ] && [ ! -e "$x/libexec/Xorg" ] || fail "the suid wrapper was built"
    [ "$(readlink "$x/bin/X")" = Xorg ] || fail "$X_PREFIX/bin/X does not link to Xorg"
    for s in Xvfb Xnest Xephyr Xfbdev Xwayland; do
        [ ! -e "$x/bin/$s" ] || fail "$s staged; only Xorg is built"
    done
    for m in drivers/modesetting_drv.so libglamoregl.so extensions/libglx.so \
             libwfb.so libshadow.so libshadowfb.so libexa.so \
             libfbdevhw.so libint10.so libvgahw.so; do
        test -f "$mods/$m" || fail "module $m not staged in lib/xorg/modules/xlibre-25"
        no_build_rpath "$mods/$m"
    done
    needed_check "$mods/libglamoregl.so" libepoxy.so.0
    needed_check "$mods/libglamoregl.so" libgbm.so.1
    needed_check "$mods/extensions/libglx.so" libGL.so.1
    needed_check "$mods/drivers/modesetting_drv.so" libgbm.so.1
    for s in libudev.so.0 libpciaccess.so.0 libdrm.so.2 libpixman-1.so.0 \
             libXfont2.so.2 libxcvt.so.0 libXau.so.6 libXdmcp.so.6 \
             libxshmfence.so.1 libmd.so; do
        needed_check "$xorg" "$s"
    done
    not_needed "$xorg" 'libdbus' 'libsystemd' 'libseat' 'libunwind' 'libhal' \
        'libselinux' 'libaudit' 'libbsd'
    no_build_rpath "$xorg"
    # The paths compiled in.
    for s in /var/log "$X_PREFIX/share/X11/xkb" "$X_PREFIX/bin" \
             "$X_PREFIX/lib/xorg/modules" /var/run/ built-ins; do
        grep -q -a -F "$s" "$xorg" || fail "Xorg does not name $s"
    done
    note "Xorg: logs /var/log, XKB $X_PREFIX/share/X11/xkb, xkbcomp in $X_PREFIX/bin, modules $X_PREFIX/lib/xorg/modules"
    if grep -a -F -e /usr/local -e "$ROOT" -e "$SYSROOT" "$xorg" >/dev/null; then
        fail "Xorg names /usr/local or a build-host path"
    fi
    note "Xorg names neither /usr/local nor a build-host path"
    test -f "$x/include/xorg/xf86.h" || fail "the Xorg SDK (include/xorg) is not staged"
    pc_check xorg-server "$VERSION"
    [ "$(PKG_CONFIG_LIBDIR="$SYSROOT$X_PREFIX/lib/pkgconfig" pkgconf --variable=moduledir xorg-server)" = "$X_PREFIX/lib/xorg/modules/xlibre-25" ] \
        || fail "xorg-server.pc: moduledir is not $X_PREFIX/lib/xorg/modules/xlibre-25"
    note "xorg-server.pc: moduledir=$X_PREFIX/lib/xorg/modules/xlibre-25"
}

# =============================================================================
# driver
# =============================================================================
# Add a component: pin it in sources.lock, write build_<name>() above (hyphens
# in the name become underscores in the function), put its patches, if any, in
# patches/<name>/ with a series file, and add <name> here, one per line, in
# build order.
COMPONENTS="
    epoll-shim
    khronos-headers
    libepoxy
    libxcvt
    xkeyboard-config
    xkbcomp
    libudev-devd
    libevdev
    mtdev
    libinput
    libpciaccess
    xlibre-xserver
"

if [ $# -gt 0 ]; then
    for c in "$@"; do
        case " $(echo $COMPONENTS) " in
            *" $c "*) ;;
            *) fail "unknown component '$c' (known: $(echo $COMPONENTS))" ;;
        esac
    done
    COMPONENTS="$*"
fi

echo "nextbsd-xlibre: building [$(echo $COMPONENTS)] for $T/$TA into $DESTDIR$X_PREFIX"
mkdir -p "$DESTDIR"
base_list
for c in $COMPONENTS; do
    "build_$(printf '%s' "$c" | tr - _)"
done

echo
echo "==> staged into $DESTDIR:"
( cd "$DESTDIR" && find . ! -type d | sort | sed 's#^\.##' )
