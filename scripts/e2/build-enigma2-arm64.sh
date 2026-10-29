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

# OpenPLi hard-codes -Werror (plus a long OE-tuned -Wno-error exclusion list) in
# configure.ac. On a native bookworm toolchain upstream warnings like
# "ISO C++ forbids converting a string constant to 'char*'" (dvb/volume.cpp,
# ALSA_CARD macro) become fatal, and more will follow. Strip -Werror entirely so
# every diagnostic stays a warning.
sed -i 's/-Werror//g' configure.ac
grep -q -- '-Werror' configure.ac && { echo "-Werror still present"; exit 1; } || true
echo "stripped -Werror (configure.ac)"

# histb-vdp fbdev quirks (Hi3798CV200 mainline):
#  1. FBIOPUT_VSCREENINFO always fails (fixed video timing) -> fb.cpp bails out of
#     SetMode with -1 and never refreshes stride/mode info.
#  2. FBIOGET_FSCREENINFO reports a bogus/uninitialised fix.line_length (0xAAAA,
#     0xFFFF, ... varies per boot) -> spinner blits run off the fb mapping -> SIGSEGV
#     in gPixmap::blit from the gRC thread.
#  3. gFBDC then keeps the *requested* surface size (e.g. skin 720x576) while the
#     scanout stays at the native 1280x720.
python3 - <<'PYEOF'
import re
p = 'lib/gdi/fb.cpp'
s = open(p, encoding='utf-8').read()
# (1) tolerate refused mode switch: re-read real geometry below instead of bailing out
s2, n1 = re.subn(
    r'eDebug\("\[fb\] FBIOPUT_VSCREENINFO: %m"\);\n(\t+)return -1;',
    'eDebug("[fb] FBIOPUT_VSCREENINFO: %m");\n'
    '\\1// Mode switch refused (driver with fixed video timing, e.g. histb-vdp).\n'
    '\\1// Keep going with the driver\'s current mode; the real geometry is\n'
    '\\1// re-read below and gFBDC adopts it for the render surface.',
    s, count=1)
assert n1 == 1, 'fb.cpp SetMode failure path not found'
# (2) stride sanity: derive from geometry when fix.line_length is impossible
s2, n2 = re.subn(
    r'stride=fix\.line_length;\n\tmemset\(lfb, 0, stride\*yRes\);',
    'stride=fix.line_length;\n'
    '\t{\n'
    '\t\t// some drivers (histb-vdp) report an uninitialised line_length; blits then\n'
    '\t\t// run off the end of the framebuffer mapping -> SIGSEGV. Fall back to the\n'
    '\t\t// geometry-derived stride when the report cannot be right.\n'
    '\t\tunsigned int want = (unsigned int)screeninfo.xres * ((unsigned int)screeninfo.bits_per_pixel / 8);\n'
    '\t\tif (!want || (unsigned int)stride != want)\n'
    '\t\t{\n'
    '\t\t\teDebug("[fb] fix.line_length=%u bogus (xres=%u bpp=%u), using stride=%u",\n'
    '\t\t\t\t(unsigned)fix.line_length, (unsigned)screeninfo.xres,\n'
    '\t\t\t\t(unsigned)screeninfo.bits_per_pixel, want);\n'
    '\t\t\tstride = want;\n'
    '\t\t}\n'
    '\t}\n'
    '\tmemset(lfb, 0, stride*yRes);',
    s2, count=1)
assert n2 == 1, 'fb.cpp stride assignment not found'
open(p, 'w', encoding='utf-8', newline='\n').write(s2)
print('patched fb.cpp (tolerate refused modeset + stride sanity)')

p = 'lib/gdi/gfbdc.cpp'
s = open(p, encoding='utf-8').read()
# (3) adopt the real framebuffer geometry as render surface size
s2, n3 = re.subn(
    r'(\t)fb->SetMode\(xres, yres, bpp\);\n',
    '\\1fb->SetMode(xres, yres, bpp);\n'
    '\\1// drivers with fixed video timing may refuse the switch — use the real\n'
    '\\1// framebuffer geometry so the render surface matches the scanout.\n'
    '\\1fb->getMode(xres, yres, bpp);\n',
    s, count=1)
assert n3 == 1, 'gfbdc.cpp SetMode call not found'
open(p, 'w', encoding='utf-8', newline='\n').write(s2)
print('patched gfbdc.cpp (adopt real fb geometry)')

python3 - <<'PYEOF'
# (4) enumerate ALL platform (non-USB) DVB adapters: hi3798cv200 has 4 built-in
# MXL214 DVB-C adapters (adapter0-3); stock OE code instantiates non-USB
# adapter0 only and silently drops built-in adapters >0 ("found 1 adapter").
# Reorder so adapter0 registers first (slot 0 = Tuner A), then instantiate
# platform adapters 1..N as regular eDVBAdapterLinux.
p = 'lib/dvb/dvb.cpp'
s = open(p, encoding='utf-8').read()
old = (
    '\tint num_adapter = 1;\n'
    '\twhile (eDVBAdapterLinux::exist(num_adapter))\n'
    '\t{\n'
    '\t\tif (eDVBAdapterLinux::isusb(num_adapter))\n'
    '\t\t{\n'
    '\t\t\teDVBAdapterLinux *adapter = new eDVBUsbAdapter(num_adapter);\n'
    '\t\t\taddAdapter(adapter);\n'
    '\t\t}\n'
    '\t\tnum_adapter++;\n'
    '\t}\n'
    '\n'
    '\tif (eDVBAdapterLinux::exist(0))\n'
    '\t{\n'
    '\t\teDVBAdapterLinux *adapter = new eDVBAdapterLinux(0);\n'
    '\t\tadapter->scanDevices();\n'
    '\t\taddAdapter(adapter, true);\n'
    '\t}\n'
)
new = (
    '\tif (eDVBAdapterLinux::exist(0))\n'
    '\t{\n'
    '\t\teDVBAdapterLinux *adapter = new eDVBAdapterLinux(0);\n'
    '\t\tadapter->scanDevices();\n'
    '\t\taddAdapter(adapter, true);\n'
    '\t}\n'
    '\n'
    '\tint num_adapter = 1;\n'
    '\twhile (eDVBAdapterLinux::exist(num_adapter))\n'
    '\t{\n'
    '\t\tif (eDVBAdapterLinux::isusb(num_adapter))\n'
    '\t\t{\n'
    '\t\t\teDVBAdapterLinux *adapter = new eDVBUsbAdapter(num_adapter);\n'
    '\t\t\taddAdapter(adapter);\n'
    '\t\t}\n'
    '\t\telse\n'
    '\t\t{\n'
    '\t\t\t// platform (non-USB) adapters >0 are real hardware here\n'
    '\t\t\teDVBAdapterLinux *adapter = new eDVBAdapterLinux(num_adapter);\n'
    '\t\t\tadapter->scanDevices();\n'
    '\t\t\taddAdapter(adapter);\n'
    '\t\t}\n'
    '\t\tnum_adapter++;\n'
    '\t}\n'
)
assert old in s, 'dvb.cpp adapter enumeration block not found'
open(p, 'w', encoding='utf-8', newline='\n').write(s.replace(old, new, 1))
print('patched dvb.cpp (enumerate platform adapters 1..N)')
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
# autotools deps installed with --prefix=/usr land in /usr/lib (no multiarch), so probe
# both /usr/lib/aarch64-linux-gnu and /usr/lib.
mkdir -p "$WORK/stage/usr/lib/aarch64-linux-gnu"
STAGE_LIB="$WORK/stage/usr/lib/aarch64-linux-gnu"
for lib in libdvbsi++ libtuxtxt libtuxtxt32bpp; do
  srcs=$(ls /usr/lib/aarch64-linux-gnu/${lib}.so.* /usr/lib/${lib}.so.* 2>/dev/null || true)
  [ -n "$srcs" ] || { echo "runtime lib $lib not found in /usr/lib*"; exit 1; }
  cp -a $srcs "$STAGE_LIB/"
done
mkdir -p "$WORK/stage/usr/share/fonts/ttf"
DJ=/usr/share/fonts/truetype/dejavu
ln -sf "$DJ/DejaVuSans.ttf"         "$WORK/stage/usr/share/fonts/ttf/Regular.ttf"
ln -sf "$DJ/DejaVuSans-Bold.ttf"    "$WORK/stage/usr/share/fonts/ttf/Bold.ttf"
ln -sf "$DJ/DejaVuSans-Oblique.ttf" "$WORK/stage/usr/share/fonts/ttf/Italic.ttf"
ln -sf "$DJ/DejaVuSans-ExtraLight.ttf" "$WORK/stage/usr/share/fonts/ttf/Handwriting.ttf" 2>/dev/null || \
  ln -sf "$DJ/DejaVuSansCondensed.ttf" "$WORK/stage/usr/share/fonts/ttf/Handwriting.ttf"

# enigma.info — BoxInfo bootstrap file (Components/SystemInfo.py parses it at import).
# Without it BoxInfo.getItem("architecture") is None and StartEnigma.py dies with
# "AttributeError: 'NoneType' object has no attribute 'startswith'".
# Format: key=value per line; values go through literal_eval (plain strings stay strings);
# no checksum= line -> content check skipped (only a notice is printed).
mkdir -p "$WORK/stage/usr/lib"
cat > "$WORK/stage/usr/lib/enigma.info" <<'EOF'
brand=HiMedia
machinebuild=hi3798cv200
machine=himedia-q10-pro
model=himedia-q10-pro
architecture=arm
EOF
# append a valid checksum so BoxInfo reports "data loaded" instead of "checksum failed"
# (an invalid checksum triggers the IncorrectBoxInfoWizard on every first boot).
CS=$(md5sum "$WORK/stage/usr/lib/enigma.info" | cut -d' ' -f1)
echo "checksum=$CS" >> "$WORK/stage/usr/lib/enigma.info"

# skin_default/skin.xml declares font 'tuxtxt.ttf' (from the tuxtxt/ subdir font install);
# without it the whole skin fails to parse and E2 falls back to the bare emergency style.
found_tuxtxt_font=""
for f in /usr/share/fonts/tuxtxt.ttf /usr/share/fonts/ttf/tuxtxt.ttf; do
  if [ -f "$f" ]; then cp -a "$f" "$WORK/stage/usr/share/fonts/"; found_tuxtxt_font="$f"; break; fi
done
[ -n "$found_tuxtxt_font" ] || { echo "tuxtxt.ttf not found in /usr/share/fonts*"; exit 1; }
echo "shipped tuxtxt font: $found_tuxtxt_font"

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
