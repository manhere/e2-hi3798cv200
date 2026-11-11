#!/bin/bash
# Build OpenPLi enigma2 (scarthgap) natively on Debian 13 (trixie) arm64.
# Phase 1: generic fbdev path — boxtype=none, /dev/fb0 (histb-vdp generic DRM
# fbdev emulation), ALSA audio, NO HAVE_HISILICON vendor-kernel code.
# TV playback comes in Phase 2/3.
#
# trixie = python 3.13 / gcc 14; the artifact links libpython3.13.so.1.0 and
# only runs on Debian 13. The DVB UAPI headers come from the *same* upstream
# kernel that runs on the box (HiSilicon-Development/linux-6.12.y @ 6.12.115),
# installed by trixie-env.sh into /usr/local/include/linux/dvb. All patches
# below are derived from that kernel's source.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:?set WORK to the e2 build dir}"
JOBS="${JOBS:-4}"

E2_REPO='https://github.com/OpenPLi/enigma2'
E2_BRANCH='scarthgap'
E2_COMMIT='6a5eb2e2edd414db5b4ded7fbc79b0822324d508'  # scarthgap HEAD 2026-11-07

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

# SYS_DVBC2 is NOT a vendor extension: it is in the mainline UAPI since v6.2
# (include/uapi/linux/dvb/frontend.h of the pinned 6.12.115 kernel, line 696).
# trixie's linux-libc-dev (6.12.115) has it too. The old bookworm build masked
# the getCapabilities() case with #ifdef because bookworm's 6.1 headers lacked
# it; that guard silently made E2 ignore DVB-C2 while the kernel exposes it.
# We build against the pinned upstream UAPI headers, so no guard is needed.
# Fail fast if the env step was skipped.
UAPI=/usr/local/include/linux/dvb
[ -f "$UAPI/frontend.h" ] || { echo "run trixie-env.sh first (upstream DVB UAPI headers missing)"; exit 1; }
grep -q 'SYS_DVBC2' "$UAPI/frontend.h" || { echo "$UAPI/frontend.h has no SYS_DVBC2"; exit 1; }
echo "DVB UAPI: $(grep DVB_API_VERSION_MINOR "$UAPI/version.h")"

# OpenPLi hard-codes -Werror (plus a long OE-tuned -Wno-error exclusion list) in
# configure.ac. On a native trixie toolchain (gcc 14) upstream warnings like
# "ISO C++ forbids converting a string constant to 'char*'" (dvb/volume.cpp,
# ALSA_CARD macro) become fatal, and more will follow. Strip -Werror entirely so
# every diagnostic stays a warning.
sed -i 's/-Werror//g' configure.ac
grep -q -- '-Werror' configure.ac && { echo "-Werror still present"; exit 1; } || true
echo "stripped -Werror (configure.ac)"

# histb-vdp /dev/fb0 is the *generic DRM fbdev emulation*, not vendor hifb:
#   drivers/gpu/drm/hisilicon/histb/histb-vdp-drv.c: drm_fbdev_dma_setup(drm, 32)
#   drivers/gpu/drm/drm_fbdev_dma.c:        fix.smem_len = surface_height * pitches[0]
#   drivers/gpu/drm/drm_fb_helper.c:        drm_fb_helper_fill_fix() ->
#                                           fix.line_length = fb->pitches[0]
#                                           __fill_var() -> yres_virtual = fb->height
#                                           check_var() rejects geometry >
#                                           fb->width/height and never pushes a
#                                           modeset back to KMS.
# Consequences for E2 (old workarounds were based on wrong assumptions):
#  - "double buffering" (yres_virtual = 2*yres) is impossible; ask for one page.
#  - fix.line_length is ALWAYS valid (may be padded); never overwrite it with
#    xres*bpp/8. The historic 0xaaaa/0xffff stride came from E2's own
#    uninitialised stack fb_fix_screeninfo, not from the kernel.
#  - FBIOPUT_VSCREENINFO can still be refused when the requested skin geometry
#    does not fit the allocated framebuffer; re-read the native geometry and
#    derive the page count from it instead of bailing out of SetMode.
#  - FBIO_BLIT / FBIO_SET_MANUAL_BLIT are vendor hifb ioctls, absent here.
python3 - <<'PYEOF'
p = 'lib/gdi/fb.cpp'
s = open(p, encoding='utf-8').read()

# (0) strstr() is needed to recognise the generic DRM fbdev emulation via fix.id.
old = '#include <memory.h>\n'
assert s.count(old) == 1, 'fb.cpp include <memory.h> not found'
s = s.replace(old, old + '#include <string.h>\n', 1)

# (1) skip the double-buffered request on the DRM fbdev emulation
old = (
    '\tif (fbFd < 0) return -1;\n'
    '\tscreeninfo.xres_virtual=screeninfo.xres=nxRes;\n'
    '\tscreeninfo.yres_virtual=(screeninfo.yres=nyRes)*2;\n'
)
new = (
    '\tif (fbFd < 0) return -1;\n'
    '\t/* histb-vdp (6.12.y HiSTB) publishes /dev/fb0 through the generic DRM\n'
    '\t * fbdev emulation (drm_fbdev_dma_setup). It owns exactly one framebuffer\n'
    '\t * object: drm_fb_helper_check_var() rejects yres_virtual > fb->height and\n'
    '\t * __fill_var() rewrites var to the native single-buffer geometry. Asking\n'
    '\t * for double buffering first always fails there, so only legacy fbdev\n'
    '\t * drivers get the two-page request. */\n'
    '\tfb_fix_screeninfo info0;\n'
    '\tmemset(&info0, 0, sizeof(info0));\n'
    '\tbool drmfb = false;\n'
    '\tif (ioctl(fbFd, FBIOGET_FSCREENINFO, &info0) >= 0)\n'
    '\t\tdrmfb = strstr((const char *)info0.id, "drmfb") != 0;\n'
    '\tscreeninfo.xres_virtual=screeninfo.xres=nxRes;\n'
    '\tscreeninfo.yres_virtual=(screeninfo.yres=nyRes)*(drmfb ? 1 : 2);\n'
)
assert s.count(old) == 1, 'fb.cpp SetMode prologue not found'
s = s.replace(old, new, 1)

# (2) tolerate a refused modeset, re-read geometry, derive pages from it
old = (
    '\tif (ioctl(fbFd, FBIOPUT_VSCREENINFO, &screeninfo)<0)\n'
    '\t{\n'
    '\t\t// try single buffering\n'
    '\t\tscreeninfo.yres_virtual=screeninfo.yres=nyRes;\n'
    '\n'
    '\t\tif (ioctl(fbFd, FBIOPUT_VSCREENINFO, &screeninfo)<0)\n'
    '\t\t{\n'
    '\t\t\teDebug("[fb] FBIOPUT_VSCREENINFO: %m");\n'
    '\t\t\treturn -1;\n'
    '\t\t}\n'
    '\t\teDebug("[fb] double buffering not available.");\n'
    '\t} else\n'
    '\t\teDebug("[fb] double buffering available!");\n'
    '\n'
    '\tm_number_of_pages = screeninfo.yres_virtual / nyRes;\n'
    '\n'
    '\tioctl(fbFd, FBIOGET_VSCREENINFO, &screeninfo);\n'
)
new = (
    '\tint modeset = ioctl(fbFd, FBIOPUT_VSCREENINFO, &screeninfo);\n'
    '\tif (modeset < 0 && !drmfb)\n'
    '\t{\n'
    '\t\t// legacy fbdev: retry without the second page\n'
    '\t\tscreeninfo.yres_virtual=screeninfo.yres=nyRes;\n'
    '\t\tmodeset = ioctl(fbFd, FBIOPUT_VSCREENINFO, &screeninfo);\n'
    '\t}\n'
    '\tif (modeset < 0)\n'
    '\t{\n'
    '\t\teDebug("[fb] FBIOPUT_VSCREENINFO: %m");\n'
    '\t\t/* Generic DRM fbdev emulation never changes the KMS mode: check_var()\n'
    '\t\t * refuses geometry that does not fit the allocated framebuffer (the skin\n'
    '\t\t * resolution and the HDMI native mode need not match). Keep the driver\'s\n'
    '\t\t * current mode and re-read the real geometry below instead of bailing out. */\n'
    '\t}\n'
    '\n'
    '\tioctl(fbFd, FBIOGET_VSCREENINFO, &screeninfo);\n'
    '\n'
    '\t/* Derive the page count from the geometry the driver actually reports, not\n'
    '\t * from the requested nyRes: __fill_var() always reports a single buffer for\n'
    '\t * DRM fbdev emulation (yres_virtual == yres). */\n'
    '\tm_number_of_pages = screeninfo.yres ? screeninfo.yres_virtual / screeninfo.yres : 1;\n'
    '\tif (m_number_of_pages < 1)\n'
    '\t\tm_number_of_pages = 1;\n'
)
assert s.count(old) == 1, 'fb.cpp modeset block not found'
s = s.replace(old, new, 1)

# (3) trust fix.line_length, zero the local struct, bound the clear
old = (
    '\tfb_fix_screeninfo fix;\n'
    '\tif (ioctl(fbFd, FBIOGET_FSCREENINFO, &fix)<0)\n'
    '\t{\n'
    '\t\teDebug("[fb] FBIOGET_FSCREENINFO: %m");\n'
    '\t}\n'
    '\n'
    '\tstride=fix.line_length;\n'
    '\tmemset(lfb, 0, stride*yRes);\n'
)
new = (
    '\t/* Zero the local fix struct: on ioctl failure E2 used to read an\n'
    '\t * uninitialised stack value (0xaaaa / 0xffff) as line_length and blit\n'
    '\t * past the mapping. The generic DRM fbdev emulation always reports a valid\n'
    '\t * fix.line_length = fb->pitches[0] and fix.smem_len = pitch * height; keep\n'
    '\t * that stride (it may be padded), only falling back when it cannot fit. */\n'
    '\tfb_fix_screeninfo fix;\n'
    '\tmemset(&fix, 0, sizeof(fix));\n'
    '\tif (ioctl(fbFd, FBIOGET_FSCREENINFO, &fix)<0)\n'
    '\t{\n'
    '\t\teDebug("[fb] FBIOGET_FSCREENINFO: %m");\n'
    '\t}\n'
    '\n'
    '\tstride=fix.line_length;\n'
    '\tunsigned int derived = (unsigned int)screeninfo.xres * ((unsigned int)screeninfo.bits_per_pixel / 8);\n'
    '\tif (!stride || (unsigned long long)stride * yRes > (unsigned long long)m_available_total)\n'
    '\t{\n'
    '\t\tif (derived && (unsigned long long)derived * yRes <= (unsigned long long)m_available_total)\n'
    '\t\t{\n'
    '\t\t\teDebug("[fb] fix.line_length=%u unusable (xres=%u bpp=%u smem_len=%d), using %u",\n'
    '\t\t\t\t(unsigned)fix.line_length, (unsigned)screeninfo.xres,\n'
    '\t\t\t\t(unsigned)screeninfo.bits_per_pixel, m_available_total, derived);\n'
    '\t\t\tstride = derived;\n'
    '\t\t}\n'
    '\t\telse\n'
    '\t\t{\n'
    '\t\t\teDebug("[fb] no usable stride (line_length=%u, xres=%u, yres=%d, smem_len=%d)",\n'
    '\t\t\t\t(unsigned)fix.line_length, (unsigned)screeninfo.xres, yRes, m_available_total);\n'
    '\t\t\treturn -1;\n'
    '\t\t}\n'
    '\t}\n'
    '\tsize_t clear_size = (size_t)stride * yRes;\n'
    '\tif (clear_size > (size_t)m_available_total)\n'
    '\t\tclear_size = m_available_total;\n'
    '\tmemset(lfb, 0, clear_size);\n'
)
assert s.count(old) == 1, 'fb.cpp stride block not found'
s = s.replace(old, new, 1)

# (4) no vendor blit ioctl on generic DRM fbdev emulation
old = '\tif (m_manual_blit == 0) {\n\t\treturn;\n\t}\n'
new = '\tif (m_manual_blit <= 0) {\n\t\treturn;  // no vendor blit ioctl on this driver\n\t}\n'
assert s.count(old) == 1, 'fb.cpp blit() guard not found'
s = s.replace(old, new, 1)

open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('patched fb.cpp (DRM fbdev emulation semantics)')

p = 'lib/gdi/gfbdc.cpp'
s = open(p, encoding='utf-8').read()
# (5) adopt the real framebuffer geometry as render surface size
old = '\tfb->SetMode(xres, yres, bpp);\n'
new = (
    '\tfb->SetMode(xres, yres, bpp);\n'
    '\t/* SetMode cannot change the KMS mode through generic DRM fbdev emulation;\n'
    '\t * __fill_var() reports the native scanout geometry instead. Adopt it so\n'
    '\t * the render surface, stride and /dev/fb0 mapping stay in sync. */\n'
    '\tfb->getMode(xres, yres, bpp);\n'
)
assert s.count(old) == 1, 'gfbdc.cpp SetMode call not found'
s = s.replace(old, new, 1)
open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('patched gfbdc.cpp (adopt real fb geometry)')
PYEOF

python3 - <<'PYEOF'
# (6) enumerate ALL platform (non-USB) DVB adapters.
# drivers/media/platform/hisilicon/histb-dmx.c registers ONE dvb_adapter per
# enabled TS input (HISTB_DMX_MAX_INPUTS = 6); the DVBIP-1002 DTS wires inputs
# 0..3 to the four MxL214 outputs, so adapters 0..3 are real hardware. Each
# adapter also gets four CA aliases (ca0..ca3, HISTB_DMX_CA_ALIASES = 4) for
# the Tvheadend/OSCam CA mask. Stock OE code instantiates non-USB adapter0 only
# and silently drops built-in adapters >0 ("found 1 adapter").
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
# "-I/aarch64-linux-gnu/usr/include/python3.13" (trixie) and the dev-env
# consistency check fails ("Could not link test program to Python" -> Giving up).
# The macro only derives flags when PYTHON_CPPFLAGS is empty, so pre-set it.
export PYTHON_CPPFLAGS="-I$(python3 -c 'import sysconfig; print(sysconfig.get_path("include"))')"
# same m4 hack also mangles the site-packages path into /aarch64-linux-gnu/usr/lib/...
# (would misplace E2's python files under DESTDIR staging) -> pre-set it as well.
export PYTHON_SITE_PKG="$(python3 -c 'import sysconfig; print(sysconfig.get_path("purelib"))')"
./configure --prefix=/usr \
  --with-boxtype=none \
  --with-fbdev=/dev/fb0 \
  --with-alsa \
  --with-dvbincludes=/usr/local/include \
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
# skin_default declares Regular/Bold/Italic/Handwriting. Debian's
# fonts-dejavu-core differs per release: trixie ships only DejaVuSans(.ttf),
# DejaVuSans-Bold.ttf plus Mono/Serif variants — NO DejaVuSans-Oblique.ttf or
# DejaVuSans-ExtraLight.ttf. `ln -sf` happily creates a dangling link (so the
# old `|| fallback` never fired). Pick the first EXISTING candidate instead.
mkdir -p "$WORK/stage/usr/share/fonts/ttf"
DJ=/usr/share/fonts/truetype/dejavu
for spec in \
  "Regular.ttf:DejaVuSans.ttf" \
  "Bold.ttf:DejaVuSans-Bold.ttf" \
  "Italic.ttf:DejaVuSans-Oblique.ttf DejaVuSansMono-Oblique.ttf DejaVuSerif.ttf DejaVuSans.ttf" \
  "Handwriting.ttf:DejaVuSans-ExtraLight.ttf DejaVuSansCondensed.ttf DejaVuSerif.ttf DejaVuSans.ttf"
do
  name=${spec%%:*}
  candidates=${spec#*:}
  chosen=""
  for c in $candidates; do
    if [ -f "$DJ/$c" ]; then chosen="$DJ/$c"; break; fi
  done
  [ -n "$chosen" ] || { echo "no DejaVu candidate for $name"; exit 1; }
  ln -sfn "$chosen" "$WORK/stage/usr/share/fonts/ttf/$name"
  echo "font $name -> $chosen"
done

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

# --- 4b. external OpenPLi FHD skin + OpenWebif (pinned upstream commits) --------------------
# /dev/fb0 is the native 1920x1080 DRM fbdev framebuffer, but the in-tree
# skin_default declares 720x576. Ship littlesat/skin-PLiHD's PLi-FullHD:
# native 1920x1080, no custom converters/renderers, no absolute paths, and the
# most-starred OpenPLi skin on GitHub. OpenWebif 2.4.1 uses only E2 APIs that
# scarthgap exports (BoxInfo, isPluginInstalled, checkLogin, WHERE_SESSIONSTART)
# and compiles its Cheetah templates at runtime, so no build-time compilation.
SKIN_REPO='https://github.com/littlesat/skin-PLiHD'
SKIN_COMMIT='220a1dca09308037dd11b6d1092e2d54261ee924'  # master 2026-11-10
OWI_REPO='https://github.com/oe-alliance/OpenWebif'
OWI_COMMIT='6c63ba0605dfb0c8f0486685b1947ba1cb4d8f5d'  # main 2026-11-10, 2.4.1

clone_pin() {
  local repo="$1" sha="$2" dir="$3"
  if [ ! -d "$dir/.git" ]; then
    git clone --no-checkout "$repo" "$dir"
  fi
  ( cd "$dir" && git fetch --depth 1 origin "$sha" && git checkout --quiet --detach "$sha" )
}
clone_pin "$SKIN_REPO" "$SKIN_COMMIT" "$WORK/src/skin-plihd"
clone_pin "$OWI_REPO" "$OWI_COMMIT" "$WORK/src/openwebif"

mkdir -p "$WORK/stage/usr/share/enigma2"
rm -rf "$WORK/stage/usr/share/enigma2/PLi-FullHD"
cp -a "$WORK/src/skin-plihd/usr/share/enigma2/PLi-FullHD" "$WORK/stage/usr/share/enigma2/"
[ -f "$WORK/stage/usr/share/enigma2/PLi-FullHD/skin.xml" ] || { echo "PLi-FullHD skin missing"; exit 1; }
grep -q 'yres="1080"' "$WORK/stage/usr/share/enigma2/PLi-FullHD/skin.xml" || \
  { echo "PLi-FullHD is not 1080p"; exit 1; }
echo "shipped PLi-FullHD skin ($(find "$WORK/stage/usr/share/enigma2/PLi-FullHD" -type f | wc -l) files)"

# setup.py build compiles the .po catalogs into plugin/locale (optional).
( cd "$WORK/src/openwebif" && python3 setup.py build > "$WORK/openwebif-build.out" 2>&1 ) || \
  echo "WARN: OpenWebif locale build failed (translations only)"
mkdir -p "$WORK/stage/usr/lib/enigma2/python/Plugins/Extensions"
rm -rf "$WORK/stage/usr/lib/enigma2/python/Plugins/Extensions/OpenWebif"
cp -a "$WORK/src/openwebif/plugin" "$WORK/stage/usr/lib/enigma2/python/Plugins/Extensions/OpenWebif"
[ -f "$WORK/stage/usr/lib/enigma2/python/Plugins/Extensions/OpenWebif/plugin.py" ] || \
  { echo "OpenWebif plugin missing"; exit 1; }
echo "shipped OpenWebif plugin"

# --- 5. verify + package --------------------------------------------------------------------
BIN="$WORK/stage/usr/bin/enigma2"
[ -x "$BIN" ] || { echo "enigma2 binary missing"; exit 1; }
echo "== NEEDED -> trixie packages" | tee "$WORK/runtime-deps.txt"
ldd "$BIN" | tee -a "$WORK/runtime-deps.txt"
ldd "$BIN" | grep 'not found' && { echo "MISSING libs above"; exit 1; } || echo "all libs resolved"
file "$BIN" | tee -a "$WORK/runtime-deps.txt"

OUT="$WORK/e2-arm64.tar.gz"
tar -C "$WORK/stage" --owner=0 --group=0 -czf "$OUT" usr
( cd "$WORK" && sha256sum e2-arm64.tar.gz | tee e2-arm64.tar.gz.sha256 && ls -l e2-arm64.tar.gz )
cp "$HERE/install-enigma2-arm64.sh" "$WORK/"
echo "OK: $OUT"
