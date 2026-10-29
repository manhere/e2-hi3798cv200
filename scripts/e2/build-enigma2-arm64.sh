#!/bin/bash
# Build OpenPLi enigma2 (scarthgap) natively on Debian 12 (bookworm) arm64.
# Phase 1: generic fbdev path — boxtype=none, /dev/fb0 (histb-vdp fbdev emulation),
# ALSA audio, NO HAVE_HISILICON vendor-kernel code. TV playback comes in Phase 2/3.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:?set WORK to the e2 build dir}"
JOBS="${JOBS:-4}"

E2_REPO='https://github.com/OpenPLi/enigma2'
E2_BRANCH='scarthgap'
E2_COMMIT='21b0fbb801147ebb5ab810bba448e6a19d3dda3c'  # 2026-10-27

mkdir -p "$WORK/src" "$WORK/stage"
cd "$WORK"

# --- 1. source (pinned) --------------------------------------------------------------------
if [ ! -d src/enigma2/.git ]; then
  git clone --no-checkout "$E2_REPO" src/enigma2
fi
cd src/enigma2
git fetch --depth 1 origin "$E2_COMMIT"
git checkout --quiet --detach "$E2_COMMIT"
ACTUAL="$(git rev-parse HEAD)"
[ "$ACTUAL" = "$E2_COMMIT" ] || { echo "commit mismatch: $ACTUAL != $E2_COMMIT"; exit 1; }
echo "enigma2 commit: $ACTUAL"

# mainline kernel UAPI has no SYS_DVBC2 (vendor-kernel extension in fe_delivery_system);
# guard the switch label in getCapabilities() so it compiles against mainline headers.
python3 - <<'PYEOF'
import re
p = 'lib/dvb/frontend.cpp'
s = open(p, encoding='utf-8').read()
s2, n = re.subn(r'([ \t]*)case SYS_DVBC2:([^\n]*break;)',
                '\\1#ifdef SYS_DVBC2\n\\1case SYS_DVBC2:\\2\n\\1#endif', s)
assert n == 1, 'SYS_DVBC2 case not found'
open(p, 'w', encoding='utf-8', newline='\n').write(s2)
print('guarded SYS_DVBC2 (frontend.cpp)')
PYEOF

# --- 2. configure (generic box, fbdev main display, alsa audio) -----------------------------
./autogen.sh > "$WORK/autogen.out" 2>&1
# OpenPLi's ax_python_devel.m4 is OE-cross-patched: with a native multiarch libdir
# (/usr/lib/aarch64-linux-gnu) it mangles PYTHON_CPPFLAGS into
# "-I/aarch64-linux-gnu/usr/include/python3.11" and the dev-env consistency check
# fails ("Could not link test program to Python" -> Giving up).
# The macro only derives flags when PYTHON_CPPFLAGS is empty, so pre-set it.
export PYTHON_CPPFLAGS="-I$(python3 -c 'import sysconfig; print(sysconfig.get_path("include"))')"
# same m4 hack also mangles the site-packages path into /aarch64-linux-gnu/usr/lib/...
# (would misplace E2's python files under DESTDIR staging) -> pre-set it as well.
export PYTHON_SITE_PKG="$(python3 -c 'import sysconfig; print(sysconfig.get_path("purelib"))')"
./configure --prefix=/usr \
  --with-boxtype=none \
  --with-fbdev=/dev/fb0 \
  --with-alsa \
  > "$WORK/configure.out" 2>&1 || { tail -40 "$WORK/configure.out"; exit 1; }
grep -E "boxtype|alsa|fbdev" "$WORK/configure.out" | head -5 || true

# --- 3. build + stage -----------------------------------------------------------------------
make -j"$JOBS" > "$WORK/make.out" 2>&1 || { tail -60 "$WORK/make.out"; exit 1; }
make install DESTDIR="$WORK/stage" >> "$WORK/make.out" 2>&1

# --- 4. ship libdvbsi++ + libtuxtxt runtime .so + fonts inside the tarball -------------------
mkdir -p "$WORK/stage/usr/lib/aarch64-linux-gnu"
cp -a /usr/lib/aarch64-linux-gnu/libdvbsi++.so.* "$WORK/stage/usr/lib/aarch64-linux-gnu/"
cp -a /usr/lib/aarch64-linux-gnu/libtuxtxt.so.* "$WORK/stage/usr/lib/aarch64-linux-gnu/"
mkdir -p "$WORK/stage/usr/share/fonts/ttf"
DJ=/usr/share/fonts/truetype/dejavu
ln -sf "$DJ/DejaVuSans.ttf"         "$WORK/stage/usr/share/fonts/ttf/Regular.ttf"
ln -sf "$DJ/DejaVuSans-Bold.ttf"    "$WORK/stage/usr/share/fonts/ttf/Bold.ttf"
ln -sf "$DJ/DejaVuSans-Oblique.ttf" "$WORK/stage/usr/share/fonts/ttf/Italic.ttf"
ln -sf "$DJ/DejaVuSans-ExtraLight.ttf" "$WORK/stage/usr/share/fonts/ttf/Handwriting.ttf" 2>/dev/null || \
  ln -sf "$DJ/DejaVuSansCondensed.ttf" "$WORK/stage/usr/share/fonts/ttf/Handwriting.ttf"

# --- 5. verify + package --------------------------------------------------------------------
BIN="$WORK/stage/usr/bin/enigma2"
[ -x "$BIN" ] || { echo "enigma2 binary missing"; exit 1; }
echo "== NEEDED -> bookworm packages" | tee "$WORK/runtime-deps.txt"
ldd "$BIN" | tee -a "$WORK/runtime-deps.txt"
ldd "$BIN" | grep 'not found' && { echo "MISSING libs above"; exit 1; } || echo "all libs resolved"
file "$BIN" | tee -a "$WORK/runtime-deps.txt"

OUT="$WORK/e2-arm64.tar.gz"
tar -C "$WORK/stage" --owner=0 --group=0 -czf "$OUT" usr
( cd "$WORK" && sha256sum e2-arm64.tar.gz | tee e2-arm64.tar.gz.sha256 && ls -l e2-arm64.tar.gz )
cp "$HERE/install-enigma2-arm64.sh" "$WORK/"
echo "OK: $OUT"
