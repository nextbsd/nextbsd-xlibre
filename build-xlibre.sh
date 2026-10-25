#!/usr/bin/env bash
# =============================================================================
# build-xlibre.sh — cross-build driver for nextbsd-xlibre
# =============================================================================
#
# Builds the XLibre X server's stack NextBSD ships in base (E23, plan step 9
# onwards) for ONE architecture, from pinned upstream release tarballs, into
# the /usr/X11 prefix with upstream sonames. So far: the server's support
# libraries (libepoxy, libxcvt), the XKB keymap compiler (xkbcomp), the
# XLibre server (libpciaccess, xlibre-xserver with modesetting and glamor),
# its input and video drivers, the X.Org tools (xauth, xinit, xset,
# setxkbmap, xinput, xrandr), and the session clients the stock xinitrc
# starts (twm, xclock, xterm).
#
# What both display servers share (libdrm, pixman, expat, freetype,
# fontconfig, libxkbcommon, the XKB data, epoll-shim, libudev, libevdev,
# mtdev, libinput and the <linux/input.h> shim) is not built here: it comes
# from nextbsd-displayserver-support's artifact in /usr (E25, nextbsd-xlibre#12).
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
# ports tree or ports tools, and nothing links against nextbsd-userland (Xorg
# loads liblaunch only at run time, and only with -launchd): the
# inputs are sources.lock, the NextBSD base (compat) sysroot, and
# nextbsd-displayserver-support's (the shared libraries and XKB data, in
# /usr), nextbsd-xlibs' (the X client libraries, libxkbfile) and
# nextbsd-mesa's (libglvnd, Mesa's GL/EGL/GBM) `continuous` artifacts on top.
#
# EXECUTION CONTEXT (set up by CI before this runs)
#   Inside the nextbsd-kernel-toolchain container (pinned clang/lld 19.1.7 in
#   $CROSS_BINDIR, meson, ninja, cmake, pkgconf, autotools, util-macros,
#   python3, perl, bison), with compat's `continuous` base, then
#   nextbsd-displayserver-support's, nextbsd-xlibs' and nextbsd-mesa's
#   `continuous` artifacts, extracted into $SYSROOT. Until nextbsd-xlibs#9,
#   xlibs' own /usr/X11 copies of the libraries that moved to
#   displayserver-support are removed from the sysroot after extraction, so
#   only the /usr ones are there (check_displayserver_support refuses the
#   sysroot otherwise). $SYSROOT is scratch: this script installs every
#   component into its /usr/X11 as it goes.
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

# What this repo installs outside $X_PREFIX: the org.nextbsd.xlibre
# LaunchAgent (launchd/, nextbsd-xlibre#13), next to the userland's agents,
# and the (empty) directory the server writes compiled keymaps to (E25).
LAUNCH_AGENTS_DIR=/System/Library/LaunchAgents
XKM_DIR=/var/db/xkb
LAUNCH_AGENT="$LAUNCH_AGENTS_DIR/org.nextbsd.xlibre.plist"
OUTSIDE_PREFIX="$LAUNCH_AGENT $XKM_DIR"

# nextbsd-displayserver-support (E25 D4) installs into /usr: libraries in
# /usr/lib, .pc files in /usr/libdata/pkgconfig (which pkgconf searches after
# /usr/X11/lib/pkgconfig, with the base's), the XKB data in
# /usr/share/xkeyboard-config-2 with the legacy root /usr/share/X11/xkb
# linking to it. The server, xkbcomp and setxkbmap read the XKB data there.
DSS_PC_DIR=/usr/libdata/pkgconfig
XKB_DIR=/usr/share/X11/xkb
# The modules and sonames that moved there (nextbsd-xlibre#12; libdrm, pixman,
# expat, freetype, fontconfig and libxkbcommon from nextbsd-xlibs, the rest
# from here). Each must resolve from /usr, never from a /usr/X11 copy.
DSS_MODULES="libdrm pixman-1 expat freetype2 fontconfig xkbcommon xkeyboard-config
    epoll-shim libudev linux-input-shim libevdev mtdev libinput"
DSS_SONAMES="libdrm.so.2 libpixman-1.so.0 libexpat.so.1 libfreetype.so.6
    libfontconfig.so.1 libxkbcommon.so.0 libepoll-shim.so.0 libudev.so.0
    libevdev.so.2 libmtdev.so.1 libinput.so.10"

case "$T" in
    amd64) CROSS_TRIPLE=x86_64-unknown-freebsd ;;
    arm64) CROSS_TRIPLE=aarch64-unknown-freebsd ;;
    *)     echo "FAIL: unsupported T=$T (amd64 / arm64)" >&2; exit 1 ;;
esac
BUILD_TRIPLE="$(uname -m)-pc-linux-gnu"
JOBS=-j"$(nproc 2>/dev/null || echo 2)"

SYSROOT="$(cd "$SYSROOT" && pwd)"
export SYSROOT DESTDIR CROSS_BINDIR XLIBRE_CROSS
# pkgconf's search path, as the cross files set it (cross/meson, cross/autotools).
PKG_LIBDIR="$SYSROOT$X_PREFIX/lib/pkgconfig:$SYSROOT$DSS_PC_DIR"

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

# needed_resolve <obj>: every library a staged object links is in the sysroot:
# this repo's, nextbsd-xlibs' or nextbsd-mesa's in /usr/X11/lib, or the base's
# or nextbsd-displayserver-support's in /lib or /usr/lib. The libraries that
# moved to displayserver-support (DSS_SONAMES) must come from /usr/lib. Each
# one's location is logged.
needed_resolve() {
    local obj="$1" lib
    for lib in $("$CROSS_BINDIR/llvm-readelf" -d "$obj" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
        case " $(echo $DSS_SONAMES) " in
            *" $lib "*)
                [ -e "$SYSROOT/usr/lib/$lib" ] && [ ! -e "$SYSROOT$X_PREFIX/lib/$lib" ] \
                    || fail "$(basename "$obj") links $lib, which does not resolve from /usr/lib only"
                note "$(basename "$obj"): $lib in /usr/lib (nextbsd-displayserver-support)"
                ;;
            *)
                if [ -e "$SYSROOT$X_PREFIX/lib/$lib" ]; then
                    note "$(basename "$obj"): $lib in $X_PREFIX/lib"
                elif [ -e "$SYSROOT/lib/$lib" ] || [ -e "$SYSROOT/usr/lib/$lib" ]; then
                    note "$(basename "$obj"): $lib in the base"
                else
                    fail "$(basename "$obj") links $lib, which is neither in $X_PREFIX/lib nor in /lib or /usr/lib"
                fi
                ;;
        esac
    done
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
# Out of tree, configure compiles each source by its absolute path, so
# __FILE__ (in assert()s, for one) would carry the build host's source and
# build directories into the binaries; -fmacro-prefix-map maps both away and
# __FILE__ names the file relative to its package (no_build_paths checks).
# The CONFIG_SITE keeps a CFLAGS from the environment; a component that
# passes CFLAGS= itself must add the maps too.
autotools_build() {
    (
        cd "$COMP_BUILD"
        CFLAGS="${CFLAGS:--O2 -pipe} -fmacro-prefix-map=$SRC_DIR/= -fmacro-prefix-map=$COMP_BUILD/=" \
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

# check_displayserver_support: nextbsd-displayserver-support is staged in the
# sysroot, and every library that moved there resolves from /usr only:
#   - each moved module's .pc is the one in /usr/libdata/pkgconfig (pkgconf
#     --path), with prefix=/usr;
#   - each moved soname is in /usr/lib, and /usr/X11/lib has no copy (until
#     nextbsd-xlibs#9 the workflow removes xlibs' copies from the sysroot);
#   - the XKB data resolves through /usr/share/X11/xkb.
# The log shows where each one came from.
check_displayserver_support() {
    local m path pfx s f
    comp "nextbsd-displayserver-support in the sysroot (/usr)"
    [ -f "$SYSROOT$DSS_PC_DIR/libinput.pc" ] \
        || fail "$SYSROOT has no nextbsd-displayserver-support ($DSS_PC_DIR/libinput.pc); stage its continuous artifact first"
    for m in $DSS_MODULES; do
        path=$(pkgconf_sysroot --path "$m") || fail "pkgconf cannot resolve $m"
        printf '%s\n' "$path" | grep -q -x -F "$SYSROOT$DSS_PC_DIR/$m.pc" \
            && ! printf '%s\n' "$path" | grep -q -x -F "$SYSROOT$X_PREFIX/lib/pkgconfig/$m.pc" \
            || fail "pkgconf resolves $m to $(echo ${path//"$SYSROOT"/}), not $DSS_PC_DIR/$m.pc"
        path="$SYSROOT$DSS_PC_DIR/$m.pc"
        pfx=$(sed -n 's/^prefix=//p' "$path")
        [ -z "$pfx" ] || [ "$pfx" = /usr ] || fail "$m.pc: prefix is $pfx, not /usr"
        note "pkgconf: $m $(pkgconf_sysroot --modversion "$m") from $DSS_PC_DIR/$m.pc"
    done
    for s in $DSS_SONAMES; do
        [ -e "$SYSROOT/usr/lib/$s" ] || fail "$s is not in the sysroot's /usr/lib"
        if [ -e "$SYSROOT$X_PREFIX/lib/$s" ] || [ -L "$SYSROOT$X_PREFIX/lib/$s" ]; then
            fail "$X_PREFIX/lib/$s is in the sysroot too (nextbsd-xlibs' old copy); remove it so /usr/lib's is used"
        fi
        note "$s in /usr/lib only"
    done
    for f in rules/evdev keycodes/evdev symbols/us types/basic compat/basic; do
        test -f "$SYSROOT$XKB_DIR/$f" || fail "$XKB_DIR/$f does not resolve in the sysroot"
    done
    note "XKB data: $XKB_DIR -> $(readlink "$SYSROOT$XKB_DIR")"
}

# The files already in the sysroot before this script installs anything: the
# compat base, nextbsd-displayserver-support's /usr and the /usr/X11 of
# nextbsd-xlibs and nextbsd-mesa. Listed while the sysroot holds none of this
# repo's files (libepoxy's epoxy/gl.h is the marker: libepoxy is the first
# component that ships, since khronos-headers is sysroot-only and skipped
# when nextbsd-mesa is staged), so stage can refuse a component that would
# overwrite any of those files. A later partial run reuses the list.
base_list() {
    BASE_LIST="$BUILD/base-files-$T.list"
    mkdir -p "$BUILD"
    [ -f "$SYSROOT$X_PREFIX/include/X11/Xlib.h" ] \
        || fail "$SYSROOT$X_PREFIX has no nextbsd-xlibs (X11/Xlib.h); stage its continuous artifact first"
    if [ ! -e "$SYSROOT$X_PREFIX/include/epoxy/gl.h" ]; then
        (cd "$SYSROOT" && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort) > "$BASE_LIST"
    elif [ ! -f "$BASE_LIST" ]; then
        fail "$SYSROOT already holds this repo's files but $BASE_LIST is missing; start from a fresh compat base, nextbsd-displayserver-support, nextbsd-xlibs and nextbsd-mesa"
    fi
}

# stage <name> [sysroot-only]: tidy and check $COMP_ROOT, then copy it into
# $SYSROOT (for the components after this one) and $DESTDIR (the artifact).
#   - everything must be under /usr/X11, apart from $OUTSIDE_PREFIX, and
#     nothing may replace a file already in the sysroot (base_list);
#   - libtool .la files and docs are dropped (man pages are kept);
#   - nothing is set-uid or set-gid but $X_PREFIX/bin/Xorg (setid_check),
#     and no file names a build-host path (no_build_paths);
#   - .pc files from share/pkgconfig and libdata/pkgconfig move to
#     lib/pkgconfig;
#   - a .pc file has prefix=/usr/X11 (or, data-only, sets no path outside
#     it); none may name /usr/local or a build-host path, and no CMake
#     package file a build-host path.
# With sysroot-only, the component is build input for later components and is
# left out of the artifact (khronos-headers).
stage() {
    local name="$1" where="${2:-}" x="$COMP_ROOT$X_PREFIX" stray f d clash allowed=""
    [ -d "$x" ] || fail "$name installed nothing under $X_PREFIX"
    for f in $OUTSIDE_PREFIX; do
        allowed="$allowed ! -path .$f"
        d="$f"
        while d=$(dirname "$d") && [ "$d" != / ]; do
            allowed="$allowed ! -path .$d"
        done
    done
    # shellcheck disable=SC2086
    stray=$(cd "$COMP_ROOT" && find . -mindepth 1 ! -path ./usr ! -path ".$X_PREFIX" ! -path ".$X_PREFIX/*" $allowed)
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
        # A data-only .pc has no prefix= line; then every absolute path it
        # sets must be under the prefix.
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
    setid_check "$COMP_ROOT" "$name"
    no_build_paths "$COMP_ROOT" "$name"
    clash=$(cd "$COMP_ROOT" && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort | LC_ALL=C comm -12 - "$BASE_LIST")
    [ -z "$clash" ] || fail "$name would replace files of the NextBSD base, nextbsd-displayserver-support, nextbsd-xlibs or nextbsd-mesa: $clash"
    (cd "$COMP_ROOT" && tar -cf - .) | (cd "$SYSROOT" && tar -xf -)
    if [ "$where" = sysroot-only ]; then
        note "staged $(cd "$COMP_ROOT" && find . ! -type d | wc -l) files (sysroot only, not in the artifact)"
        return 0
    fi
    (cd "$COMP_ROOT" && tar -cf - .) | (cd "$DESTDIR" && tar -xf -)
    note "staged $(cd "$COMP_ROOT" && find . ! -type d | wc -l) files"
}

# The only set-uid or set-gid file this repo ships: the X server, set-uid root
# (nextbsd-xlibre#20; see build_xlibre_xserver).
SETUID_FILES="$X_PREFIX/bin/Xorg"

# setid_check <root> <what>: under <root>, every set-uid or set-gid file is
# one of SETUID_FILES, and that one is set-uid root: mode 4555 or 4755, owned
# by root:wheel (uid and gid 0), not set-gid.
setid_check() {
    local root="$1" what="$2" f m
    for f in $(cd "$root" && find . -type f \( -perm -4000 -o -perm -2000 \) | sed 's#^\.##'); do
        case " $SETUID_FILES " in
            *" $f "*) ;;
            *) fail "$what: $f is set-uid or set-gid; only $SETUID_FILES may be" ;;
        esac
        m=$(stat -c '%a %u %g' "$root$f")
        case "$m" in
            "4555 0 0"|"4755 0 0") note "$what: $f is set-uid root (mode uid gid: $m)" ;;
            *) fail "$what: $f has mode uid gid $m; it must be 4555 or 4755, root:wheel" ;;
        esac
    done
}

# no_build_paths <root> <what>: no file under <root> (programs, modules,
# libraries, scripts, man pages, configuration, .pc files) contains a
# build-host path: this checkout ($ROOT, the CI workspace), the sysroot
# ($SYSROOT) or the build directory ($BUILD). A sysroot path baked in from a
# .pc variable (pkgconf prefixes them with the sysroot) is looked up at run
# time on NextBSD and fails. Each offending file is listed with the paths
# found in it.
no_build_paths() {
    local root="$1" what="$2" pats=() p hits f
    for p in "$ROOT" "$SYSROOT" "$BUILD" "${GITHUB_WORKSPACE:-}"; do
        [ -n "$p" ] && pats+=(-e "$p")
    done
    hits=$(cd "$root" && grep -r -l -a -F "${pats[@]}" . || true)
    if [ -n "$hits" ]; then
        for f in $hits; do
            echo "    $f:" >&2
            grep -a -o "$ROOT[^[:space:][:cntrl:]\"]*" "$root/$f" | sort -u | head -5 | sed 's/^/        /' >&2 || true
        done
        fail "$what: $(echo "$hits" | wc -l) file(s) contain a build-host path ($ROOT, $SYSROOT)"
    fi
    note "$what: no build-host path in any of its $(cd "$root" && find . -type f | wc -l) files ($ROOT, $SYSROOT, $BUILD)"
}

# pkgconf_sysroot <pkgconf args...>: pkgconf as the builds see it: only the
# sysroot's .pc directories, -I/-L prefixed with the sysroot.
pkgconf_sysroot() {
    PKG_CONFIG_LIBDIR="$PKG_LIBDIR" PKG_CONFIG_SYSROOT_DIR="$SYSROOT" pkgconf "$@"
}

# pc_check <module> [version]: the staged .pc resolves through pkgconf the way
# later components will see it (and, if given, at that version).
pc_check() {
    local mod="$1" want="${2:-}" got
    got=$(pkgconf_sysroot --modversion "$mod") || fail "pkgconf cannot resolve $mod"
    [ -z "$want" ] || [ "$got" = "$want" ] || fail "$mod.pc is version $got, expected $want"
    note "pkgconf ok: $mod $got"
}


# =============================================================================
# Components, in build order (E23 audit 3, section 2.2): the server's support
# libraries, then the XKB compiler (nextbsd-xlibre#1). epoll-shim and the XKB
# data moved to nextbsd-displayserver-support (E25) and come from its
# artifact in /usr.
# =============================================================================

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
        [ "$(PKG_CONFIG_LIBDIR="$PKG_LIBDIR" pkgconf --variable="$v" epoxy)" = 1 ] \
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

# xkb_path_check <file> <what>: a staged program names the XKB root
# /usr/share/X11/xkb (nextbsd-displayserver-support's xkeyboard-config, the
# path its libxkbcommon uses too) and not the old /usr/X11/share/X11/xkb.
xkb_path_check() {
    local f="$1" what="$2"
    grep -q -a -F "$XKB_DIR" "$f" || fail "$what does not name $XKB_DIR"
    ! grep -q -a -F "$X_PREFIX/share/X11/xkb" "$f" || fail "$what still names $X_PREFIX/share/X11/xkb"
    note "$what XKB config root: $XKB_DIR"
}

# xkbcomp — the XKB keymap compiler the server runs at start-up and on
# keymap changes, in /usr/X11/bin. meson (bison on the build host). Its XKB
# config root is /usr/share/X11/xkb (E25), the same path libxkbcommon uses.
build_xkbcomp() {
    comp "xkbcomp [meson cross]"
    fresh_dirs xkbcomp
    fetch xkbcomp
    meson_build -Dxkb-config-root="$XKB_DIR"
    stage xkbcomp
    local bin="$DESTDIR$X_PREFIX/bin/xkbcomp"
    test -x "$bin" || fail "xkbcomp not staged"
    needed_check "$bin" libxkbfile.so.1
    needed_check "$bin" libX11.so.6
    xkb_path_check "$bin" xkbcomp
    pc_check xkbcomp "$VERSION"
    [ "$(PKG_CONFIG_LIBDIR="$PKG_LIBDIR" pkgconf --variable=xkbconfigdir xkbcomp)" = "$XKB_DIR" ] \
        || fail "xkbcomp.pc: xkbconfigdir is not $XKB_DIR"
    note "xkbcomp.pc: xkbconfigdir=$XKB_DIR"
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

# xlibre-xserver 25.1.9 — the XLibre X server: Xorg, its modules and the SDK
# (headers, xorg-server.pc) the drivers build against. meson. The tag archive
# is pinned (no release tarballs); 25.1.9 is upstream's "Latest" release, every
# 25.2.x being a pre-release (E23 D5's fallback). patches/xlibre-xserver/ holds
# the FreeBSD port's server patches that 25.1.9 still needs (D11; series says
# which and why the others are not carried).
#
# Servers: Xorg only. Xvfb, Xnest, Xephyr, Xfbdev, XWin and XQuartz are off;
# there is no Xwayland in this tree.
#
# Graphics (D9): libdrm and pixman (nextbsd-displayserver-support, /usr),
# GBM, EGL and GL (nextbsd-mesa) and
# libepoxy are all in the sysroot, so glamor, the modesetting driver (meson
# builds it only with GBM), GLX with DRI, DRI2 and DRI3 are on; meson is told
# so explicitly, so a missing dependency fails the build instead of quietly
# dropping them. 25.1.9 has no gbm option (25.2 added -Dgbm): it looks GBM up
# whenever glamor is built and builds glamoregl and modesetting only if it is
# found, so the module checks below are what fail on a missing libgbm. On
# amd64 the legacy NVIDIA ScreenRec padding is on, as in
# FreeBSD's port: NVIDIA's nvidia_drv.so is built for that ABI (E23 D15).
#
# Input and devices: the udev config backend and KMS device discovery
# (platform bus) through libudev (libudev-devd, from nextbsd-displayserver-support;
# -Dudev=true -Dudev_kms=true, as FreeBSD's port builds it); xf86-input-libinput
# is the fallback input driver. No HAL,
# no systemd-logind (it needs D-Bus), no seatd/libseat, no systemd notify, no
# D-Bus at all.
#
# Privilege (nextbsd-xlibre#20): Xorg is installed set-uid root, mode 4555,
# as upstream's autotools build did and as the server expects without a
# wrapper: NextBSD has no seat manager, and the server needs root to open
# the console/VT, /dev/dri and /dev/input (xf86OpenConsole refuses to run
# otherwise). There is no suid wrapper (Xorg.wrap) and so no console-only
# restriction: any user may start X, on the console or over SSH. With
# privileges elevated the server itself refuses the options that would let a
# user read or write files as root (-config, -modulepath, -logfile with
# arbitrary paths). setid_check allows this one set-uid file and no other. A
# rootless display server is later E25 work.
#
# DRI driver directory (nextbsd-xlibre#20): GLX dlopen()s Mesa's DRI drivers
# from DRI_DRIVER_PATH, which upstream takes from dri.pc's dridriverdir; in
# this cross build pkgconf returns it with the sysroot in front, so it is
# given explicitly as /usr/X11/lib/dri (patch 0006 adds -Ddri_driver_path).
#
# Paths: modules under /usr/X11/lib/xorg/modules (25.1.9 installs them in its
# xlibre-25 ABI directory there, which the loader searches first); XKB data
# /usr/share/X11/xkb (nextbsd-displayserver-support's xkeyboard-config, E25),
# xkbcomp from /usr/X11/bin; compiled keymaps in /var/db/xkb, a directory
# this repo ships (the server writes there only if it can, otherwise in
# $XDG_RUNTIME_DIR or /tmp); logs in /var/log (Xorg.N.log); the default font path is
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
        -Dglamor=true -Ddrm=true -Dglx=true -Dglx_dri=true \
        -Ddri2=true -Ddri3=true -Dpciaccess=true \
        -Dudev=true -Dudev_kms=true -Dhal=false -Dsystemd_logind=false \
        -Dsystemd_notify=false -Dseatd_libseat=false -Dsuid_wrapper=false \
        -Dxselinux=false -Ddtrace=false -Dlibunwind=false \
        -Ddocs=false -Ddevel-docs=false -Ddocs-pdf=false -Dtests=false \
        -Dxf86-input-inputtest=false \
        -Dsha1=libmd -Dxcsecurity=true -Dfallback_input_driver=libinput \
        -Dlegacy_nvidia_padding="$nvidia" \
        -Dlog_dir=/var/log -Ddefault_font_path=built-ins \
        -Dxkb_dir="$XKB_DIR" -Dxkb_bin_dir="$X_PREFIX/bin" \
        -Dxkb_output_dir="$XKM_DIR" -Ddri_driver_path="$X_PREFIX/lib/dri"
    # 25.1.9 installs upstream's NVIDIA OutputClass snippets (from
    # config/meson.build): 10-nvidia.conf and 10-nvidia-modules.conf in
    # share/X11/xorg.conf.d (written for Linux 6.12+'s nvidia-drm, with a
    # ModulePath of /usr/X11/lib/nvidia/xorg) and Debian copies in
    # etc/X11/xorg.conf.d. They are removed: FreeBSD's port ships none of them
    # (its post-patch sed drops them), and where NVIDIA's driver and its
    # configuration live is the NVIDIA bundle's business (E23 D15).
    # 10-quirks.conf stays.
    rm -f "$COMP_ROOT$X_PREFIX"/share/X11/xorg.conf.d/10-nvidia*.conf \
          "$COMP_ROOT$X_PREFIX"/etc/X11/xorg.conf.d/10-nvidia*.conf.debian
    # The on-demand LaunchAgent (nextbsd-xlibre#13): launchd starts Xorg
    # -launchd (patch 0005) when the first X client connects. Disabled.
    install -d -m 0755 "$COMP_ROOT$LAUNCH_AGENTS_DIR"
    install -m 0644 "$ROOT/launchd/org.nextbsd.xlibre.plist" "$COMP_ROOT$LAUNCH_AGENTS_DIR/"
    # Compiled keymaps (XKM_OUTPUT_DIR): an empty directory, root's.
    install -d -m 0755 "$COMP_ROOT$XKM_DIR"
    # Set-uid root (see Privilege above). meson installs Xorg 0755 when
    # there is no suid wrapper; the build runs as root in the container, so
    # the owner is root and tar keeps owner and mode into the artifact.
    chown 0:0 "$COMP_ROOT$X_PREFIX/bin/Xorg"
    chmod 4555 "$COMP_ROOT$X_PREFIX/bin/Xorg"
    stage xlibre-xserver
    local x="$DESTDIR$X_PREFIX" mods="$DESTDIR$X_PREFIX/lib/xorg/modules/xlibre-25" xorg m s
    xorg="$x/bin/Xorg"
    test -x "$xorg" || fail "Xorg not staged"
    [ -u "$xorg" ] && [ "$(stat -c '%a %u %g' "$xorg")" = "4555 0 0" ] \
        || fail "Xorg is not set-uid root 4555 root:wheel ($(stat -c '%a %u %g' "$xorg"))"
    note "Xorg: set-uid root, mode 4555, root:wheel"
    [ ! -e "$x/libexec/Xorg.wrap" ] && [ ! -e "$x/libexec/Xorg" ] || fail "the suid wrapper was built"
    [ "$(readlink "$x/bin/X")" = Xorg ] || fail "$X_PREFIX/bin/X does not link to Xorg"
    test -f "$x/share/X11/xorg.conf.d/10-quirks.conf" || fail "10-quirks.conf not staged"
    [ ! -e "$COMP_ROOT$X_PREFIX/etc" ] || fail "$X_PREFIX/etc staged: $(cd "$COMP_ROOT$X_PREFIX/etc" && find . ! -type d)"
    for s in "$x"/share/X11/xorg.conf.d/*; do
        [ "$(basename "$s")" = 10-quirks.conf ] || fail "unexpected $(basename "$s") in $X_PREFIX/share/X11/xorg.conf.d"
    done
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
    needed_resolve "$xorg"
    for m in libglamoregl.so libexa.so libwfb.so drivers/modesetting_drv.so; do
        needed_resolve "$mods/$m"
    done
    not_needed "$xorg" 'libdbus' 'libsystemd' 'libseat' 'libunwind' 'libhal' \
        'libselinux' 'libaudit' 'libbsd' 'liblaunch'
    # -launchd (patch 0005) is built in; liblaunch is dlopen()ed for it only.
    for s in -launchd launch_activate_socket liblaunch.so.1; do
        grep -q -a -F -e "$s" "$xorg" || fail "Xorg has no $s (patch 0005)"
    done
    note "Xorg: -launchd built in, liblaunch loaded only at run time"
    launch_agent_check "$DESTDIR$LAUNCH_AGENT"
    no_build_rpath "$xorg"
    # The paths compiled in.
    for s in /var/log "$X_PREFIX/bin" "$X_PREFIX/lib/xorg/modules" "$XKM_DIR/" built-ins; do
        grep -q -a -F "$s" "$xorg" || fail "Xorg does not name $s"
    done
    xkb_path_check "$xorg" Xorg
    # GLX's DRI driver directory: the one compiled into libglx.so (where
    # glxdricommon.c is built) is /usr/X11/lib/dri, and no module or program
    # names another .../lib/dri.
    grep -q -a -F "$X_PREFIX/lib/dri" "$mods/extensions/libglx.so" \
        || fail "libglx.so does not name $X_PREFIX/lib/dri"
    s=$(grep -a -o -h -E '/[^[:space:][:cntrl:]"]*/lib/dri' "$mods/extensions/libglx.so" | sort -u)
    [ "$s" = "$X_PREFIX/lib/dri" ] || fail "libglx.so names DRI driver directories other than $X_PREFIX/lib/dri: $s"
    note "libglx.so: DRI driver directory $s"
    [ -d "$DESTDIR$XKM_DIR" ] || fail "$XKM_DIR not staged"
    note "Xorg: logs /var/log, XKB $XKB_DIR, xkbcomp in $X_PREFIX/bin, compiled keymaps $XKM_DIR, modules $X_PREFIX/lib/xorg/modules"
    if grep -a -F -e /usr/local -e "$ROOT" -e "$SYSROOT" "$xorg" >/dev/null; then
        fail "Xorg names /usr/local or a build-host path"
    fi
    note "Xorg names neither /usr/local nor a build-host path"
    test -f "$x/include/xorg/xf86.h" || fail "the Xorg SDK (include/xorg) is not staged"
    pc_check xorg-server "$VERSION"
    [ "$(PKG_CONFIG_LIBDIR="$PKG_LIBDIR" pkgconf --variable=moduledir xorg-server)" = "$X_PREFIX/lib/xorg/modules/xlibre-25" ] \
        || fail "xorg-server.pc: moduledir is not $X_PREFIX/lib/xorg/modules/xlibre-25"
    note "xorg-server.pc: moduledir=$X_PREFIX/lib/xorg/modules/xlibre-25"
}

# launch_agent_check <plist>: the org.nextbsd.xlibre LaunchAgent parses as a
# property list (python3's plistlib; there is no plutil on the runner) and
# keeps the shape nextbsd-xlibre#13 needs: an org.nextbsd label, disabled and
# Aqua-only as XQuartz's agent is, nothing started at load, a
# SecureSocketWithKey DISPLAY socket whose name is the one Xorg -launchd
# collects, a server that is staged, and stdout/stderr kept off the console.
launch_agent_check() {
    local p="$1"
    [ -f "$p" ] || fail "$p was not staged"
    python3 - "$p" "$DESTDIR" <<'PY' || fail "$(basename "$p") is not the LaunchAgent nextbsd-xlibre#13 describes"
import os, plistlib, sys
path, destdir = sys.argv[1], sys.argv[2]
with open(path, "rb") as f:
    job = plistlib.load(f)
def need(cond, why):
    if not cond:
        sys.exit(f"FAIL: {os.path.basename(path)}: {why}")
need(job.get("Label") == "org.nextbsd.xlibre", "Label is not org.nextbsd.xlibre")
need(job.get("Disabled") is True, "not Disabled")
need(job.get("LimitLoadToSessionType") == "Aqua", "LimitLoadToSessionType is not Aqua")
for k in ("RunAtLoad", "KeepAlive", "OnDemand", "StartInterval", "WatchPaths", "QueueDirectories"):
    need(k not in job, f"has {k}; X must start only when a client connects")
args = job.get("ProgramArguments", [])
need(len(args) >= 3 and args[1] == "-launchd", "ProgramArguments is not <server> -launchd <name> ...")
need(os.access(destdir + args[0], os.X_OK), f"{args[0]} is not staged")
socks = job.get("Sockets", {})
need(list(socks) == [args[2]], f"Sockets has no single entry named {args[2]}")
need(socks[args[2]].get("SecureSocketWithKey") == "DISPLAY", "the socket is not SecureSocketWithKey DISPLAY")
for k in ("StandardOutPath", "StandardErrorPath"):
    need(job.get(k) == "/dev/null", f"{k} is not /dev/null")
need("com.apple" not in open(path).read(), "names com.apple")
PY
    note "LaunchAgent ok: $LAUNCH_AGENTS_DIR/$(basename "$p") (disabled, Aqua, socket-activated)"
}

# =============================================================================
# The input and video drivers (nextbsd-xlibre#4, E23 step 12): input libinput,
# evdev, joystick, keyboard, mouse, synaptics and vmmouse (amd64); video scfb
# and vesa (amd64), the unaccelerated fallbacks next to modesetting (D9). Each
# is X11Libre's 25.0.x tag, built with autotools against the server SDK staged
# above, with FreeBSD's port patches where it has them (D11).
# =============================================================================

# Where drivers go: the server's ABI module directory (xorg-server.pc's
# moduledir) and its xorg.conf.d. Given to configure explicitly: the drivers
# ask pkgconf for them, and with PKG_CONFIG_SYSROOT_DIR set pkgconf answers
# with the sysroot in front.
XORG_MODULE_DIR="$X_PREFIX/lib/xorg/modules/xlibre-25"
XORG_CONF_DIR="$X_PREFIX/share/X11/xorg.conf.d"

# xdriver_build [configure options...]: an X11Libre driver from its tag
# archive. The tags ship no configure, so autoreconf runs first, with the
# server's xorg-server.m4 from the sysroot (util-macros' xorg-macros.m4 is
# in the toolchain image's aclocal). Then autotools_build with the module
# directory and driver man pages in man4 with the 4x suffix, as FreeBSD
# installs them: kbd.4x and mousedrv.4x never shadow the base's own
# keyboard(4) and mouse(4) pages.
xdriver_build() {
    local aclocal="$SYSROOT$X_PREFIX/share/aclocal"
    [ -f "$aclocal/xorg-server.m4" ] || fail "no xorg-server.m4 in the sysroot; build xlibre-xserver first"
    (cd "$SRC_DIR" && autoreconf -fi -I "$aclocal")
    autotools_build --with-xorg-module-dir="$XORG_MODULE_DIR" \
        DRIVER_MAN_SUFFIX=4x DRIVER_MAN_DIR='$(mandir)/man4' \
        "$@"
}

# <linux/input.h> for the evdev, libinput, synaptics (eventcomm) and joystick
# (evdev backend) drivers is nextbsd-displayserver-support's linux-input-shim
# (/usr/include/linux-input-shim/linux, the base's <dev/evdev/...> headers),
# found through pkgconf. evdev and synaptics get it from libevdev.pc, which
# requires linux-input-shim; libinput and joystick include <linux/input.h>
# without libevdev, so they are given its cflags.
#
# shim_cflags <module>: pkgconf --cflags <module>, checked to carry the
# shim's include directory.
shim_cflags() {
    local got
    got=$(pkgconf_sysroot --cflags "$1") || fail "pkgconf cannot resolve $1"
    case " $got " in
        *" -I$SYSROOT/usr/include/linux-input-shim "*) ;;
        *) fail "pkgconf --cflags $1 has no -I/usr/include/linux-input-shim: $got" ;;
    esac
    note "pkgconf --cflags $1: the input shim (/usr/include/linux-input-shim)" >&2
    echo "$got"
}

# drv_check <path under the module dir> [needed...]: a staged driver module
# links each <needed> library, each library it links resolves in the sysroot
# (needed_resolve; libinput, libevdev, mtdev and libudev from /usr/lib), has
# no SONAME other than its own file name
# (libtool's -module -avoid-version), no build-host RPATH, and doesn't link
# the server.
drv_check() {
    local m="$DESTDIR$XORG_MODULE_DIR/$1" n so
    shift
    test -f "$m" || fail "module $(basename "$m") not staged in $XORG_MODULE_DIR"
    for n in "$@"; do needed_check "$m" "$n"; done
    needed_resolve "$m"
    so=$("$CROSS_BINDIR/llvm-readelf" -d "$m" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
    [ -z "$so" ] || [ "$so" = "$(basename "$m")" ] || fail "$(basename "$m") has SONAME $so"
    not_needed "$m" 'Xorg' 'libdbus' 'libsystemd' 'libhal'
    no_build_rpath "$m"
}

# config_has <define>...: the driver's configure turned each on (config.h).
config_has() {
    local d
    for d in "$@"; do
        grep -q "^#define $d 1" "$COMP_BUILD/config.h" || fail "configure did not define $d"
        note "config.h: $d"
    done
}

# xf86-input-libinput 25.0.1 — the input driver X uses for everything on
# /dev/input/event* (the server's fallback input driver, and what the Mouse
# settings' libinput properties talk to, D10). Installs libinput_drv.so,
# libinput-properties.h and xorg-libinput.pc in the SDK, and
# 40-libinput.conf, which gives libinput every pointer, keyboard, touchpad,
# touch screen and tablet on an event node.
build_xf86_input_libinput() {
    comp "xf86-input-libinput [autotools cross]"
    fresh_dirs xf86-input-libinput
    fetch xf86-input-libinput
    local shim
    shim=$(shim_cflags linux-input-shim)
    xdriver_build --with-sdkdir="$X_PREFIX/include/xorg" --with-xorg-conf-dir="$XORG_CONF_DIR" \
        CPPFLAGS="$shim"
    stage xf86-input-libinput
    local x="$DESTDIR$X_PREFIX"
    drv_check input/libinput_drv.so libinput.so.10
    test -f "$x/include/xorg/libinput-properties.h" || fail "libinput-properties.h not staged"
    test -f "$x/share/X11/xorg.conf.d/40-libinput.conf" || fail "40-libinput.conf not staged"
    test -f "$x/share/man/man4/libinput.4x" || fail "libinput.4x not staged"
    pc_check xorg-libinput "$VERSION"
}

# xf86-input-evdev 25.0.0 — the older evdev(4) driver, for an xorg.conf that
# names it. libevdev, mtdev and libudev (libudev-devd), all from
# nextbsd-displayserver-support; <linux/input.h> comes with libevdev.pc's
# cflags (shim_cflags). FreeBSD's port hides
# libudev from configure and leaves the udev_* calls to resolve against
# Xorg's; here the module links libudev.so.0 itself. 10-evdev.conf ships, as
# in FreeBSD: it sorts before 40-libinput.conf, so libinput still gets the
# devices. FreeBSD's webcamd dependency is not needed for kernel evdev
# devices. No patches.
build_xf86_input_evdev() {
    comp "xf86-input-evdev [autotools cross]"
    fresh_dirs xf86-input-evdev
    fetch xf86-input-evdev
    shim_cflags libevdev >/dev/null
    xdriver_build --with-sdkdir="$X_PREFIX/include/xorg" --with-xorg-conf-dir="$XORG_CONF_DIR"
    stage xf86-input-evdev
    local x="$DESTDIR$X_PREFIX"
    config_has HAVE_LIBUDEV
    drv_check input/evdev_drv.so libevdev.so.2 libmtdev.so.1 libudev.so.0
    test -f "$x/include/xorg/evdev-properties.h" || fail "evdev-properties.h not staged"
    test -f "$x/share/X11/xorg.conf.d/10-evdev.conf" || fail "10-evdev.conf not staged"
    test -f "$x/share/man/man4/evdev.4x" || fail "evdev.4x not staged"
}

# xf86-input-joystick 25.0.0 — joysticks as pointers. Two backends: the BSD
# one on /dev/uhid* through the base's libusbhid, and evdev on
# /dev/input/event* (enabled by linux-input-shim; FreeBSD's port builds only
# the first). There is no linux/joystick.h, so no Linux joystick backend. No
# patches.
build_xf86_input_joystick() {
    comp "xf86-input-joystick [autotools cross]"
    fresh_dirs xf86-input-joystick
    fetch xf86-input-joystick
    local shim
    shim=$(shim_cflags linux-input-shim)
    xdriver_build --with-sdkdir="$X_PREFIX/include/xorg" CPPFLAGS="$shim"
    stage xf86-input-joystick
    local x="$DESTDIR$X_PREFIX"
    config_has BSD_BACKEND EVDEV_BACKEND
    ! grep -q '^#define LINUX_BACKEND 1' "$COMP_BUILD/config.h" || fail "the Linux joystick backend was built"
    drv_check input/joystick_drv.so libusbhid.so
    test -f "$x/include/xorg/joystick-properties.h" || fail "joystick-properties.h not staged"
    test -f "$x/share/man/man4/joystick.4x" || fail "joystick.4x not staged"
}

# xf86-input-keyboard 25.0.0 — kbd_drv.so, the console keyboard driver
# (syscons/vt(4) and kbdmux), what the server picks when the kernel has no
# evdev. FreeBSD's 4 patches (patches/xf86-input-keyboard): without them the
# driver reads the console keymap and crashes the server on vt(4).
build_xf86_input_keyboard() {
    comp "xf86-input-keyboard [autotools cross]"
    fresh_dirs xf86-input-keyboard
    fetch xf86-input-keyboard
    xdriver_build
    stage xf86-input-keyboard
    drv_check input/kbd_drv.so
    test -f "$DESTDIR$X_PREFIX/share/man/man4/kbd.4x" || fail "kbd.4x not staged"
}

# xf86-input-mouse 25.0.0 — mouse_drv.so on /dev/sysmouse, /dev/psm* and
# /dev/ums*, the fallback when the kernel has no evdev. FreeBSD's 4 patches
# (about 1,270 lines, patches/xf86-input-mouse). The patched backend calls
# libusbhid for USB HID devices, and nothing in the build links it (the
# module would fail on an unresolved hid_* call), so -lusbhid is added.
build_xf86_input_mouse() {
    comp "xf86-input-mouse [autotools cross]"
    fresh_dirs xf86-input-mouse
    fetch xf86-input-mouse
    xdriver_build --with-sdkdir="$X_PREFIX/include/xorg" LIBS=-lusbhid
    stage xf86-input-mouse
    local x="$DESTDIR$X_PREFIX"
    drv_check input/mouse_drv.so libusbhid.so
    test -f "$x/include/xorg/xf86-mouse-properties.h" || fail "xf86-mouse-properties.h not staged"
    test -f "$x/share/man/man4/mousedrv.4x" || fail "mousedrv.4x not staged"
}

# xf86-input-synaptics 25.0.0 — the older touchpad driver, with synclient
# and syndaemon (libXi, libXtst). Backends: psmcomm (/dev/psm* with
# hw.psm.synaptics_support), ps2comm/alpscomm, and eventcomm on
# /dev/input/event* through libevdev, turned on with BUILD_EVENTCOMM=yes as
# FreeBSD's port does (its EVDEV option, default on). FreeBSD's 3 patches
# (patches/xf86-input-synaptics).
#
# 70-synaptics.conf is not shipped: it gives every touchpad to synaptics,
# ahead of 40-libinput.conf, and the Mouse settings need libinput on
# touchpads (D10). FreeBSD installs synaptics only on request; here it is
# always present, so it is used only when an xorg.conf names it.
build_xf86_input_synaptics() {
    comp "xf86-input-synaptics [autotools cross]"
    fresh_dirs xf86-input-synaptics
    fetch xf86-input-synaptics
    shim_cflags libevdev >/dev/null
    xdriver_build --with-sdkdir="$X_PREFIX/include/xorg" --with-xorg-conf-dir="$XORG_CONF_DIR" \
        BUILD_EVENTCOMM=yes
    rm -f "$COMP_ROOT$XORG_CONF_DIR/70-synaptics.conf"
    stage xf86-input-synaptics
    local x="$DESTDIR$X_PREFIX" t
    config_has BUILD_EVENTCOMM BUILD_PSMCOMM BUILD_PS2COMM
    drv_check input/synaptics_drv.so libevdev.so.2
    for t in synclient syndaemon; do
        test -x "$x/bin/$t" || fail "$t not staged"
        no_build_rpath "$x/bin/$t"
    done
    needed_check "$x/bin/synclient" libXi.so.6
    needed_check "$x/bin/syndaemon" libXtst.so.6
    test -f "$x/include/xorg/synaptics-properties.h" || fail "synaptics-properties.h not staged"
    [ ! -e "$x/share/X11/xorg.conf.d/70-synaptics.conf" ] || fail "70-synaptics.conf staged"
    [ ! -e "$x/share/hal" ] || fail "HAL files staged"
}

# xf86-input-vmmouse 25.0.0 (amd64 only) — absolute pointer for VMware and
# QEMU's vmport, through the VMware backdoor I/O port (/dev/io, so X runs as
# root, as it does). vmmouse_drv.so and vmmouse_detect. HAL's callout and
# fdi file and the udev rule are not installed, and nor is 50-vmmouse.conf:
# it matches only the "vmmouse" tag that udev rule sets, so without udev it
# never applies; an xorg.conf names the driver instead. No patches.
build_xf86_input_vmmouse() {
    comp "xf86-input-vmmouse [autotools cross]"
    if [ "$T" != amd64 ]; then
        note "amd64 only (E23 D9); nothing to build for $T"
        return 0
    fi
    fresh_dirs xf86-input-vmmouse
    fetch xf86-input-vmmouse
    xdriver_build --with-xorg-conf-dir="$XORG_CONF_DIR" --with-udev-rules-dir=no
    rm -rf "$COMP_ROOT$X_PREFIX/lib/hal" "$COMP_ROOT$X_PREFIX/share/hal" \
        "$COMP_ROOT$XORG_CONF_DIR/50-vmmouse.conf"
    stage xf86-input-vmmouse
    local x="$DESTDIR$X_PREFIX"
    config_has VMMOUSE_OS_BSD USE_DEV_IO
    drv_check input/vmmouse_drv.so
    test -x "$x/bin/vmmouse_detect" || fail "vmmouse_detect not staged"
    no_build_rpath "$x/bin/vmmouse_detect"
    [ ! -e "$x/lib/hal" ] && [ ! -e "$x/share/hal" ] && [ ! -e "$x/lib/udev" ] || fail "HAL or udev files staged"
}

# xf86-video-scfb 25.0.0 — the dumb framebuffer driver on the console's
# framebuffer (vt(4)'s efifb/vbefb, or a boot-time framebuffer on arm64):
# no acceleration, the fallback when modesetting has no KMS device. No
# patches.
build_xf86_video_scfb() {
    comp "xf86-video-scfb [autotools cross]"
    fresh_dirs xf86-video-scfb
    fetch xf86-video-scfb
    xdriver_build
    stage xf86-video-scfb
    drv_check drivers/scfb_drv.so
    test -f "$DESTDIR$X_PREFIX/share/man/man4/scfb.4x" || fail "scfb.4x not staged"
}

# xf86-video-vesa 25.0.0 (amd64 only) — the VESA BIOS driver (int10, vgahw),
# unaccelerated, for legacy-BIOS machines without KMS. Its pci_* calls resolve
# against Xorg's libpciaccess, so the module itself links nothing. No
# patches.
build_xf86_video_vesa() {
    comp "xf86-video-vesa [autotools cross]"
    if [ "$T" != amd64 ]; then
        note "amd64 only (E23 D9); nothing to build for $T"
        return 0
    fi
    fresh_dirs xf86-video-vesa
    fetch xf86-video-vesa
    xdriver_build
    stage xf86-video-vesa
    drv_check drivers/vesa_drv.so
    test -f "$DESTDIR$X_PREFIX/share/man/man4/vesa.4x" || fail "vesa.4x not staged"
}

# =============================================================================
# The X.Org tools (nextbsd-xlibre#5, E23 step 13): xauth and xinit (the rest
# of xlibre-minimal), then xset, setxkbmap, xinput and xrandr, the tools the
# desktop runs. Each is a program in /usr/X11/bin with its man page in
# /usr/X11/share/man/man1, linking only the X client libraries from
# nextbsd-xlibs' /usr/X11/lib and the base.
# =============================================================================

# tool_check <prog> <needed>...: /usr/X11/bin/<prog> and its man page are
# staged; it links each <needed>; every library it links resolves in the
# sysroot (needed_resolve); it has no build-host RPATH; and neither it nor its
# man page names /usr/local or a build-host path.
tool_check() {
    local prog="$1" bin="$DESTDIR$X_PREFIX/bin/$1" man="$DESTDIR$X_PREFIX/share/man/man1/$1.1" n
    shift
    test -x "$bin" || fail "$prog not staged in $X_PREFIX/bin"
    test -f "$man" || fail "$prog.1 not staged in $X_PREFIX/share/man/man1"
    for n in "$@"; do needed_check "$bin" "$n"; done
    needed_resolve "$bin"
    no_build_rpath "$bin"
    if grep -l -a -F -e /usr/local -e "$ROOT" -e "$SYSROOT" "$bin" "$man"; then
        fail "$prog or its man page names /usr/local or a build-host path"
    fi
}

# xauth 1.1.5 — the X authority file utility: startx writes the server's and
# the user's cookies with it, and loginwindow can too. autotools.
build_xauth() {
    comp "xauth [autotools cross]"
    fresh_dirs xauth
    fetch xauth
    autotools_build
    stage xauth
    tool_check xauth libX11.so.6 libXau.so.6 libXext.so.6 libXmuu.so.1
}

# xinit 1.4.4 — xinit, startx and the default xinitrc. autotools.
#
# Paths: the server is $X_PREFIX/bin/X (the server's Xorg link), xauth and
# xinit are called by their $X_PREFIX/bin paths, and the system xinitrc (and
# an optional xserverrc) live in $X_PREFIX/etc/X11/xinit, under the server's
# own sysconfdir ($X_PREFIX/etc/X11). twm, xclock, xterm, xrdb and xmodmap,
# which upstream's sample xinitrc starts, are left as bare names, found on
# $PATH: twm, xclock and xterm are built below (nextbsd-xlibre#18, #22); xrdb
# and xmodmap are not part of NextBSD. A user's ~/.xinitrc (or $XINITRC) is their
# own session.
#
# Privilege: Xorg is set-uid root and no suid wrapper is built (see
# xlibre-xserver), so startx works for any user. Apple-launchd support (XQuartz's privileged_startx and LaunchAgents) is
# off. The cookie maker is the base's /usr/bin/openssl (configure would
# otherwise pick up the build host's mcookie). The xinitrc is made executable,
# as upstream does since xinit commit e914dae9: startx passes it to xinit as
# the client program. patches/xinit/ makes startx run xauth from its path
# everywhere and xinit's default server $X_PREFIX/bin/X rather than X from
# $PATH. xinit itself reads only ~/.xinitrc; the system xinitrc is startx's.
build_xinit() {
    comp "xinit [autotools cross]"
    [ -x "$SYSROOT$X_PREFIX/bin/xauth" ] || fail "$SYSROOT$X_PREFIX/bin/xauth missing; build xauth first"
    [ "$(readlink "$SYSROOT$X_PREFIX/bin/X")" = Xorg ] || fail "$SYSROOT$X_PREFIX/bin/X does not link to Xorg; build xlibre-xserver first"
    fresh_dirs xinit
    fetch xinit
    local xinitdir="$X_PREFIX/etc/X11/xinit"
    autotools_build --without-launchd \
        --with-xserver="$X_PREFIX/bin/X" --with-xauth="$X_PREFIX/bin/xauth" \
        --with-xinit="$X_PREFIX/bin/xinit" --with-xinitdir="$xinitdir" \
        MCOOKIE="/usr/bin/openssl rand -hex 16"
    chmod 0755 "$COMP_ROOT$xinitdir/xinitrc"
    stage xinit
    local x="$DESTDIR$X_PREFIX" startx="$DESTDIR$X_PREFIX/bin/startx" rc="$DESTDIR$xinitdir/xinitrc" s
    tool_check xinit libX11.so.6
    test -x "$startx" || fail "startx not staged"
    test -f "$x/share/man/man1/startx.1" || fail "startx.1 not staged"
    test -x "$rc" || fail "$xinitdir/xinitrc not staged executable"
    for s in "xserver=\"$X_PREFIX/bin/X\"" "xauth=\"$X_PREFIX/bin/xauth\"" \
             "xinit=\"$X_PREFIX/bin/xinit\"" "xinitdir=\"$xinitdir\"" \
             'mk_cookie="/usr/bin/openssl rand -hex 16"' 'has_cookie_maker="true"'; do
        grep -q -x -F "$s" "$startx" || fail "startx does not set $s"
    done
    note "startx: server $X_PREFIX/bin/X, xauth $X_PREFIX/bin/xauth, xinitrc in $xinitdir"
    if grep -n -E '(^|[^"$/])xauth (-q|list|add|remove)' "$startx"; then
        fail "startx runs a bare xauth"
    fi
    if grep -n -F -e /usr/local -e "$ROOT" -e "$SYSROOT" "$startx" "$rc" "$x/share/man/man1/startx.1"; then
        fail "startx, xinitrc or startx.1 names /usr/local or a build-host path"
    fi
    if grep -n -E '@[A-Za-z_]+@' "$startx" "$rc"; then
        fail "startx or xinitrc has an unsubstituted @VAR@"
    fi
    grep -q -a -F "$X_PREFIX/bin/X" "$x/bin/xinit" || fail "xinit's default server is not $X_PREFIX/bin/X"
    [ ! -e "$x/libexec/privileged_startx" ] || fail "Apple-launchd support was built"
    note "xinit: default server $X_PREFIX/bin/X, xinitrc $xinitdir/xinitrc"
}

# xset 1.2.6 — user preferences (DPMS, keyboard repeat, bell, screen saver).
# meson. The fontcache and XFree86-Misc extensions are long gone from servers,
# and nextbsd-xlibs has neither library, so both are off.
build_xset() {
    comp "xset [meson cross]"
    fresh_dirs xset
    fetch xset
    meson_build -Dfontcache=disabled -Dxf86misc=disabled
    stage xset
    tool_check xset libX11.so.6 libXmuu.so.1 libXext.so.6
}

# setxkbmap 1.3.5 — sets the XKB keymap (the Keyboard settings use it). meson.
# Its XKB config root is /usr/share/X11/xkb, as for xkbcomp and the server.
build_setxkbmap() {
    comp "setxkbmap [meson cross]"
    fresh_dirs setxkbmap
    fetch setxkbmap
    meson_build -Dxkb-config-root="$XKB_DIR"
    stage setxkbmap
    tool_check setxkbmap libX11.so.6 libxkbfile.so.1 libXrandr.so.2
    xkb_path_check "$DESTDIR$X_PREFIX/bin/setxkbmap" setxkbmap
}

# xinput 1.6.4 — lists input devices and sets their properties (the Mouse
# settings set libinput's through it). autotools; XI 2.2 support.
build_xinput() {
    comp "xinput [autotools cross]"
    fresh_dirs xinput
    fetch xinput
    autotools_build
    stage xinput
    tool_check xinput libX11.so.6 libXi.so.6 libXrandr.so.2 libXinerama.so.1
}

# xrandr 1.5.4 — output, mode and rotation control (E24's Display settings).
# meson. Upstream also installs xkeystone, a script for the nickle
# interpreter, which NextBSD does not ship; it is removed.
build_xrandr() {
    comp "xrandr [meson cross]"
    fresh_dirs xrandr
    fetch xrandr
    meson_build
    rm -f "$COMP_ROOT$X_PREFIX/bin/xkeystone"
    stage xrandr
    # libXrender is a build dependency only: meson links --as-needed and
    # xrandr calls none of its functions, so it is not in DT_NEEDED.
    tool_check xrandr libX11.so.6 libXrandr.so.2
    [ ! -e "$DESTDIR$X_PREFIX/bin/xkeystone" ] || fail "xkeystone staged"
}

# =============================================================================
# The session clients (nextbsd-xlibre#18, #22): twm, xclock and xterm, what
# the stock xinitrc runs (it ends with `exec xterm`, and xterm is startx's
# fallback client), so `startx` gives a usable session. Each is a program in
# /usr/X11/bin with its man page, linking only nextbsd-xlibs' X client
# libraries (libXaw and libXpm since nextbsd-xlibs#11),
# nextbsd-displayserver-support's freetype and fontconfig, and the base.
# =============================================================================

# twm 1.0.13.1 — the X.Org window manager. autotools. The tarball carries
# the generated parser and lexer (src/gram.c, src/lex.c); configure still
# looks for yacc and lex, and finds the toolchain image's bison and flex.
# RandR support is on (libXrandr). The default configuration is
# /usr/X11/share/X11/twm/system.twmrc, and is also compiled in.
build_twm() {
    comp "twm [autotools cross]"
    fresh_dirs twm
    fetch twm
    autotools_build
    stage twm
    local x="$DESTDIR$X_PREFIX"
    config_has HAVE_XRANDR
    tool_check twm libX11.so.6 libXext.so.6 libXt.so.6 libXmu.so.6 libICE.so.6 libSM.so.6 libXrandr.so.2
    test -f "$x/share/X11/twm/system.twmrc" || fail "$X_PREFIX/share/X11/twm/system.twmrc not staged"
    grep -q -a -F "$X_PREFIX/share/X11/twm" "$x/bin/twm" || fail "twm does not name $X_PREFIX/share/X11/twm"
    note "twm: system.twmrc in $X_PREFIX/share/X11/twm"
}

# xclock 1.2.1 — the analog/digital clock the stock xinitrc starts
# (nextbsd-xlibre#22). meson. Xaw7 widgets, Xft and Xrender for anti-aliased
# drawing, XKB bells (libxkbfile), iconv from the base's libc. The
# app-defaults directory is given explicitly: otherwise meson reads xt.pc's
# appdefaultdir, which pkgconf returns with the build sysroot in front
# (the leak nextbsd-xlibre#20 fixed for the DRI path).
build_xclock() {
    comp "xclock [meson cross]"
    fresh_dirs xclock
    fetch xclock
    local appdefaults="$X_PREFIX/share/X11/app-defaults" s
    meson_build -Dappdefaultdir="$appdefaults" -Dxft=enabled -Dxkb=enabled
    stage xclock
    tool_check xclock libXaw.so.7 libXmu.so.6 libXt.so.6 libX11.so.6 libXft.so.2 libXrender.so.1 libxkbfile.so.1
    for s in XClock XClock-color XClock-ampm XClock-grandfather; do
        test -f "$DESTDIR$appdefaults/$s" || fail "app-defaults/$s not staged in $appdefaults"
    done
    grep -q -F "$appdefaults" "$DESTDIR$X_PREFIX/share/man/man1/xclock.1" \
        || fail "xclock.1 does not name $appdefaults"
    note "xclock: app-defaults in $appdefaults"
}

# xterm 412 — the terminal emulator. autotools (Thomas Dickey's configure).
#
# Toolkit: Xaw7 for the menus (nextbsd-xlibs' libXaw.so.7; xterm cannot be
# built without an Athena library), Xft with fontconfig and freetype for
# TrueType fonts (the default faceName comes from the user; NextBSD ships no
# core fonts, so the server's built-in "fixed" is the bitmap fallback),
# Xinerama, and the base's ncurses (libtinfow) for termcap/terminfo, found by
# configure's tgetent check.
#
# Not built: libXpm icons (--without-xpm, and no pixmap directory, since
# its icons need Xpm), the .desktop files (--disable-desktop), luit
# (--disable-luit: no luit is shipped, and configure would otherwise look
# one up on the build host), utempter (not given --with-utempter), imake.
# --disable-rpath-hack: configure would add an -rpath for /usr/X11/lib;
# ldconfig finds it at run time, as for the other tools. xterm keeps its
# assert()s; autotools_build maps the build host's directories out of their
# __FILE__.
#
# Privilege: no set-uid or set-gid (--disable-setuid --disable-setgid).
# xterm opens its pty with openpty(3) from the base's libutil, and without
# privilege it records no utmpx entry.
#
# app-defaults go to /usr/X11/share/X11/app-defaults, the directory
# nextbsd-xlibs' libXt searches (xt.pc's appdefaultdir); configure's default
# is EPREFIX/lib/X11/app-defaults. Installs xterm, resize, uxterm and
# koi8rxterm (shell wrappers that set a locale and run xterm), with man
# pages.
build_xterm() {
    comp "xterm [autotools cross]"
    fresh_dirs xterm
    fetch xterm
    local appdefaults="$X_PREFIX/share/X11/app-defaults"
    autotools_build --with-app-defaults="$appdefaults" \
        --disable-setuid --disable-setgid --without-utempter \
        --disable-luit --without-xpm --without-pixmapdir --disable-desktop \
        --disable-imake --disable-rpath-hack
    stage xterm
    local x="$DESTDIR$X_PREFIX" s
    for s in HAVE_LIB_XAW OPT_WIDE_CHARS XRENDERFONT; do
        grep -q -E "^#define $s 1([[:space:]]|\$)" "$COMP_BUILD/xtermcfg.h" || fail "xtermcfg.h does not define $s"
        note "xtermcfg.h: $s"
    done
    for s in OPT_LUIT_PROG HAVE_LIBXPM USE_UTEMPTER; do
        ! grep -q -E "^#define $s([[:space:]]|\$)" "$COMP_BUILD/xtermcfg.h" || fail "xtermcfg.h defines $s"
    done
    note "xtermcfg.h: no luit, Xpm or utempter"
    tool_check xterm libXaw.so.7 libXft.so.2 libfontconfig.so.1 libXt.so.6 libX11.so.6
    not_needed "$x/bin/xterm" 'libXpm' 'libutempter'
    for s in xterm resize; do
        [ ! -u "$x/bin/$s" ] && [ ! -g "$x/bin/$s" ] || fail "$s is set-uid or set-gid"
    done
    note "xterm and resize: not set-uid or set-gid"
    tool_check resize
    for s in uxterm koi8rxterm; do
        test -x "$x/bin/$s" || fail "$s not staged"
        test -f "$x/share/man/man1/$s.1" || fail "$s.1 not staged"
    done
    for s in XTerm XTerm-color UXTerm UXTerm-color KOI8RXTerm KOI8RXTerm-color; do
        test -f "$DESTDIR$appdefaults/$s" || fail "app-defaults/$s not staged in $appdefaults"
    done
    note "app-defaults in $appdefaults"
    [ ! -e "$x/share/pixmaps" ] && [ ! -e "$x/share/icons" ] && [ ! -e "$x/share/applications" ] \
        || fail "xterm icons or desktop files staged"
    if grep -l -a -F -e /usr/local -e "$ROOT" -e "$SYSROOT" "$x"/bin/uxterm "$x"/bin/koi8rxterm "$DESTDIR$appdefaults"/*; then
        fail "an xterm script or app-defaults file names /usr/local or a build-host path"
    fi
}

# =============================================================================
# driver
# =============================================================================
# Add a component: pin it in sources.lock, write build_<name>() above (hyphens
# in the name become underscores in the function), put its patches, if any, in
# patches/<name>/ with a series file, and add <name> here, one per line, in
# build order.
COMPONENTS="
    khronos-headers
    libepoxy
    libxcvt
    xkbcomp
    libpciaccess
    xlibre-xserver
    xf86-input-libinput
    xf86-input-evdev
    xf86-input-joystick
    xf86-input-keyboard
    xf86-input-mouse
    xf86-input-synaptics
    xf86-input-vmmouse
    xf86-video-scfb
    xf86-video-vesa
    xauth
    xinit
    xset
    setxkbmap
    xinput
    xrandr
    twm
    xclock
    xterm
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
check_displayserver_support
base_list
for c in $COMPONENTS; do
    "build_$(printf '%s' "$c" | tr - _)"
done

# The whole artifact once more: exactly one set-uid file (Xorg) and no
# build-host path in any file (stage checks each component as it goes).
comp "artifact: set-uid files and build-host paths"
setid_check "$DESTDIR" artifact
no_build_paths "$DESTDIR" artifact

echo
echo "==> staged into $DESTDIR:"
( cd "$DESTDIR" && find . ! -type d | sort | sed 's#^\.##' )
