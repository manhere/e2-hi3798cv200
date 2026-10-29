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
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  build-essential pkgconf autoconf automake libtool gettext git \
  python3 python3-dev python3-setuptools swig \
  libfreetype-dev libfribidi-dev libglib2.0-dev libpng-dev libxml2-dev \
  libsigc++-3.0-dev libssl-dev fonts-dejavu-core \
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

echo "env OK: E2 build deps + libdvbsi++ installed"
