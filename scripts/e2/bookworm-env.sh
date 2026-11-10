#!/bin/bash
# Debian 12 (bookworm) arm64 build environment for the Enigma2 port.
# Phase 1 goal: build OpenPLi enigma2 (scarthgap) natively, generic fbdev path
# (--with-boxtype=none --with-fbdev=/dev/fb0 --with-alsa), NO vendor HAVE_HISILICON.
#
# bookworm gaps:
#   - libdvbsi++ was dropped from Debian -> built from source (tuxbox-neutrino/libdvbsi)
#     into /usr of the container; the runtime .so ships inside the enigma2 tarball.
#   - linux-libc-dev is 6.1, while the box runs the HiSTB 6.12.115 kernel:
#     its linux/dvb/frontend.h predates SYS_DVBC2 (mainline since v6.2) and its
#     DVB API minor is older. Install the DVB UAPI headers from the EXACT upstream
#     kernel commit below so E2/tuxtxt see the same API as the running kernel.
set -euo pipefail

WORK="${WORK:?set WORK to the env build dir}"
mkdir -p "$WORK"
cd "$WORK"

export DEBIAN_FRONTEND=noninteractive

# --- 1. build deps (all verified present in bookworm arm64) -------------------------------
# Hard requirements from enigma2 configure.ac: tuxbox-tuxtxt (built below), avahi-client,
# jpeg, gif/ungif, alsa (--with-alsa), crypt, dl/rt (libc).
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  build-essential pkgconf autoconf automake libtool gettext git \
  python3 python3-dev python3-setuptools swig curl ca-certificates \
  libfreetype-dev libfribidi-dev libglib2.0-dev libpng-dev libxml2-dev \
  libsigc++-3.0-dev libssl-dev fonts-dejavu-core \
  libavahi-client-dev libjpeg-dev libgif-dev libasound2-dev libcrypt-dev \
  > "$WORK/apt.out" 2>&1

# --- 1b. DVB UAPI headers from the upstream kernel running on the box -----------------------
# Pin the exact HiSilicon-Development/linux-6.12.y commit (Makefile 6.12.115,
# HEAD 2026-11-09) instead of tracking a moving branch: the binary must be built
# against the same UAPI as the flashed kernel + module tree.
KERNEL_REPO='HiSilicon-Development/linux-6.12.y'
KERNEL_REF='0e14b052c61c4ffa2cc57f299d136fd404f9988f'
KERNEL_UAPI="https://raw.githubusercontent.com/$KERNEL_REPO/$KERNEL_REF/include/uapi/linux/dvb"
UAPI_DIR=/usr/local/include/linux/dvb
mkdir -p "$UAPI_DIR"
for h in audio.h ca.h dmx.h frontend.h net.h osd.h version.h video.h; do
  if ! curl -fsSL --retry 3 --retry-delay 2 "$KERNEL_UAPI/$h" -o "$UAPI_DIR/$h"; then
    # raw.githubusercontent.com can be blocked on some networks; fall back to
    # the GitHub contents API (base64) for the same pinned commit.
    curl -fsSL --retry 3 --retry-delay 2 \
      "https://api.github.com/repos/$KERNEL_REPO/contents/include/uapi/linux/dvb/$h?ref=$KERNEL_REF" \
      -o "$WORK/uapi-$h.json"
    python3 - "$WORK/uapi-$h.json" "$UAPI_DIR/$h" <<'PY'
import base64, json, sys
d = json.load(open(sys.argv[1]))
open(sys.argv[2], 'wb').write(base64.b64decode(d['content']))
PY
  fi
done
# Raw include/uapi headers are KERNEL-side sources, not installed userspace
# headers. `make headers_install` runs scripts/headers_install.sh first: it
# strips __user/__force/__iomem (osd.h/video.h), drops <linux/compiler.h>
# (osd.h) and normalises a few attributes. Reproduce those exact sed rules
# here; without them g++ fails on video.h:133 ("char __user *iFrame").
# __KERNEL__-guarded sections need no unifdef: userspace never defines it, so
# the preprocessor already picks the exported branches.
for h in audio.h ca.h dmx.h frontend.h net.h osd.h version.h video.h; do
  sed -E -i \
    -e 's/([[:space:](])(__user|__force|__iomem)[[:space:]]/\1/g' \
    -e 's/__attribute_const__([[:space:]]|$)/\1/g' \
    -e 's@^#include <linux/compiler(|_types).h>@@' \
    -e 's/(^|[^a-zA-Z0-9])__packed([^a-zA-Z0-9_]|$)/\1__attribute__((packed))\2/g' \
    -e 's/(^|[[:space:](])(inline|asm|volatile)([[:space:](]|$)/\1__\2__\3/g' \
    -e 's@#(ifndef|define|endif[[:space:]]*/[*])[[:space:]]*_UAPI@#\1 @' \
    "$UAPI_DIR/$h"
done
# fail fast on a wrong pin / partial download / unsanitised header
grep -q 'SYS_DVBC2' "$UAPI_DIR/frontend.h" || { echo "upstream frontend.h lacks SYS_DVBC2"; exit 1; }
grep -q '#define DVB_API_VERSION 5' "$UAPI_DIR/version.h" || { echo "unexpected DVB UAPI version"; exit 1; }
if grep -qE '__user|__force|__iomem|<linux/compiler' "$UAPI_DIR"/*.h; then
  echo "kernel-only annotations left in DVB UAPI headers"; exit 1
fi
echo "DVB UAPI from $KERNEL_REPO@$KERNEL_REF: $(grep DVB_API_VERSION_MINOR "$UAPI_DIR/version.h")"

# --- 2. libdvbsi++ (E2 DVB SI parser; not packaged in bookworm) ----------------------------
DVBSI_REPO='https://github.com/tuxbox-neutrino/libdvbsi'
DVBSI_COMMIT='8ed28affe3427640f222cdd96a471c2c817bc55f'  # master 2021-04-17
if [ ! -d libdvbsi/.git ]; then
  git clone --no-checkout "$DVBSI_REPO" libdvbsi
fi
cd libdvbsi
git fetch --depth 1 origin "$DVBSI_COMMIT"
git checkout --quiet --detach "$DVBSI_COMMIT"
echo "libdvbsi commit: $(git rev-parse HEAD)"
./autogen.sh > "$WORK/dvbsi-autogen.out" 2>&1
./configure --prefix=/usr > "$WORK/dvbsi-configure.out" 2>&1
make -j"${JOBS:-4}" >> "$WORK/dvbsi-make.out" 2>&1
make install >> "$WORK/dvbsi-make.out" 2>&1
ldconfig
pkg-config --modversion libdvbsi++

# --- 3. libtuxtxt (provides tuxbox-tuxtxt.pc, a hard requirement of enigma2) ---------------
TUXTXT_REPO='https://github.com/OpenPLi/tuxtxt'
TUXTXT_COMMIT='1402795d660955757d87967b8ff1e3790625f9c1'  # master 2021-06-20
if [ ! -d tuxtxt/.git ]; then
  git clone --no-checkout "$TUXTXT_REPO" tuxtxt
fi
cd tuxtxt
git fetch --depth 1 origin "$TUXTXT_COMMIT"
git checkout --quiet --detach "$TUXTXT_COMMIT"
echo "tuxtxt commit: $(git rev-parse HEAD)"
# TUXBOX_APPS_DVB extracts the DVB API version by preprocessing a conftest inside an
# AC_CHECK_HEADERS action; with autoconf 2.71 conftest is already gone there, so the
# version comes out empty and configure errors with "can't find dvb headers".
# The pinned upstream kernel ships DVB API 5.12 (include/uapi/linux/dvb/version.h);
# tuxtxt only compares the major version, so replace the broken sniffer with a
# plain header check that sets HAVE_DVB_API_VERSION=5.
python3 - <<'PYEOF'
p = 'libtuxtxt/acinclude.m4'
s = open(p, encoding='utf-8').read()
start = s.index('AC_DEFUN([TUXBOX_APPS_DVB]')
end = s.index('AC_DEFUN([TUXBOX_APPS_CAPTURE]')
s = s[:start] + '''AC_DEFUN([TUXBOX_APPS_DVB],[
AC_ARG_WITH(dvbincludes,
\t[  --with-dvbincludes=PATH  path for dvb includes [[NONE]]],
\t[DVBINCLUDES="$withval"],[DVBINCLUDES=""])
if test "$DVBINCLUDES"; then
\tCPPFLAGS="$CPPFLAGS -I$DVBINCLUDES"
fi
AC_CHECK_HEADERS([linux/dvb/version.h linux/dvb/dmx.h],[
\tDVB_API_VERSION=5
\tAC_DEFINE(HAVE_DVB,1,[Define to 1 if you have the dvb includes])
\tAC_DEFINE_UNQUOTED(HAVE_DVB_API_VERSION,$DVB_API_VERSION,[Define to the version of the dvb api])
],[
\tAC_MSG_ERROR([can't find dvb headers])
])
])

''' + s[end:]
open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('patched TUXBOX_APPS_DVB')
PYEOF
# vestigial dbox2-era include: <tuxbox.h> (libtuxbox) is pulled in by tuxtxt_common.h
# but no tuxbox_* symbol is ever used -> drop it instead of porting libtuxbox.
sed -i '/#include <tuxbox.h>/d' libtuxtxt/tuxtxt_common.h
cd libtuxtxt
# no autogen.sh in this repo — generate the configure script directly
autoreconf -fi > "$WORK/tuxtxt-autogen.out" 2>&1
./configure --prefix=/usr --with-dvbincludes=/usr/local/include \
  > "$WORK/tuxtxt-configure.out" 2>&1
make -j"${JOBS:-4}" >> "$WORK/tuxtxt-make.out" 2>&1
make install >> "$WORK/tuxtxt-make.out" 2>&1
ldconfig
pkg-config --modversion tuxbox-tuxtxt
cd ..   # back to tuxtxt repo root (libtuxtxt section ended inside libtuxtxt/)

# --- 3b. libtuxtxt32bpp (tuxtxt/ subdir of the same repo; enigma2 links -ltuxtxt32bpp) ------
# OE builds it as recipe "tuxtxt-enigma2" with --with-boxtype=generic. Same acinclude.m4
# macro problems as libtuxtxt -> apply the identical TUXBOX_APPS_DVB replacement
# (DVB API 5.12 from the pinned upstream UAPI headers installed in step 1b).
python3 - <<'PYEOF'
import re
p = 'tuxtxt/acinclude.m4'
s = open(p, encoding='utf-8').read()
start = s.index('AC_DEFUN([TUXBOX_APPS_DVB]')
nxt = re.search(r'AC_DEFUN\(\[TUXBOX_APPS_(?:CAPTURE|BOXTYPE|HARDWARE)', s[start:])
end = start + nxt.start()
s = s[:start] + '''AC_DEFUN([TUXBOX_APPS_DVB],[
AC_ARG_WITH(dvbincludes,
\t[  --with-dvbincludes=PATH  path for dvb includes [[NONE]]],
\t[DVBINCLUDES="$withval"],[DVBINCLUDES=""])
if test "$DVBINCLUDES"; then
\tCPPFLAGS="$CPPFLAGS -I$DVBINCLUDES"
fi
AC_CHECK_HEADERS([linux/dvb/version.h linux/dvb/dmx.h],[
\tDVB_API_VERSION=5
\tAC_DEFINE(HAVE_DVB,1,[Define to 1 if you have the dvb includes])
\tAC_DEFINE_UNQUOTED(HAVE_DVB_API_VERSION,$DVB_API_VERSION,[Define to the version of the dvb api])
],[
\tAC_MSG_ERROR([can't find dvb headers])
])
])

''' + s[end:]
open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('patched TUXBOX_APPS_DVB (tuxtxt 32bpp)')
PYEOF
sed -i '/#include <tuxbox.h>/d' tuxtxt/tuxtxt_common.h 2>/dev/null || true
cd tuxtxt
autoreconf -fi > "$WORK/tuxtxt32bpp-autogen.out" 2>&1
./configure --prefix=/usr --with-boxtype=generic --with-fbdev=/dev/fb0 \
  --with-dvbincludes=/usr/local/include \
  > "$WORK/tuxtxt32bpp-configure.out" 2>&1
make -j"${JOBS:-4}" >> "$WORK/tuxtxt32bpp-make.out" 2>&1
make install >> "$WORK/tuxtxt32bpp-make.out" 2>&1
ldconfig
ls -l /usr/lib/libtuxtxt32bpp.so.*

echo "env OK: E2 build deps + upstream DVB UAPI + libdvbsi++ + libtuxtxt + libtuxtxt32bpp installed"
