#!/bin/bash
# Debian 12 (bookworm) arm64 build environment for the Enigma2 port.
# Phase 1 goal: build OpenPLi enigma2 (scarthgap) natively, generic fbdev path
# (--with-boxtype=none --with-fbdev=/dev/fb0 --with-alsa), NO vendor HAVE_HISILICON.
#
# bookworm gaps:
#   - libdvbsi++ was dropped from Debian -> built from source (tuxbox-neutrino/libdvbsi)
#     into /usr of the container; the runtime .so ships inside the enigma2 tarball.
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
  python3 python3-dev python3-setuptools swig \
  libfreetype-dev libfribidi-dev libglib2.0-dev libpng-dev libxml2-dev \
  libsigc++-3.0-dev libssl-dev fonts-dejavu-core \
  libavahi-client-dev libjpeg-dev libgif-dev libasound2-dev libcrypt-dev \
  > "$WORK/apt.out" 2>&1

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
# The mainline kernel ships DVB API 5.x — replace the macro with a plain header check.
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
cd libtuxtxt
# no autogen.sh in this repo — generate the configure script directly
autoreconf -fi > "$WORK/tuxtxt-autogen.out" 2>&1
./configure --prefix=/usr > "$WORK/tuxtxt-configure.out" 2>&1
make -j"${JOBS:-4}" >> "$WORK/tuxtxt-make.out" 2>&1
make install >> "$WORK/tuxtxt-make.out" 2>&1
ldconfig
pkg-config --modversion tuxbox-tuxtxt

echo "env OK: E2 build deps + libdvbsi++ + libtuxtxt installed"
