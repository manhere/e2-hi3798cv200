#!/bin/bash
# Build OpenPLi enigma2 (scarthgap) natively on Debian 13 (trixie) arm64.
# boxtype=none, /dev/fb0 (histb-vdp generic DRM fbdev emulation), ALSA audio.
# TV playback: HAVE_HISTB software decoder backend (ported from
# manhere/enigma2-hi3798cv200) — demux TS tap -> user-space PES demux ->
# dlopen'ed hivxe-ffmpeg (v4l2request hwaccel: MPEG1/2, H264, HEVC, AVS/AVS+)
# -> DRM_PRIME dmabuf -> histb-vdp DRM overlay plane; audio avcodec -> ALSA.
# The runtime hivxe-ffmpeg libs are NOT shipped in this tarball: they already
# live on the box at /usr/local/lib/hivxe-ffmpeg (avcodec 63.1.101); the
# backend dlopens them and degrades to "no decoder" when absent.
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
# (6) enumerate ALL platform (non-USB) DVB adapters with globally-unique
# frontend slot ids.
# drivers/media/platform/hisilicon/histb-dmx.c registers ONE dvb_adapter per
# enabled TS input (HISTB_DMX_MAX_INPUTS = 6); the DVBIP-1002 DTS wires inputs
# 0..3 to the four MxL214 outputs, so adapters 0..3 are real hardware. Each
# adapter also gets four CA aliases (ca0..ca3, HISTB_DMX_CA_ALIASES = 4) for
# the Tvheadend/OSCam CA mask. Stock OE code instantiates non-USB adapter0 only
# and silently drops built-in adapters >0 ("found 1 adapter").
# Reorder so adapter0 registers first (slot 0 = Tuner A), then instantiate
# platform adapters 1..N as regular eDVBAdapterLinux. Each adapter's
# scanDevices() uses a per-adapter frontend index as the eDVBFrontend *slot id*;
# without an offset every adapter would register its frontend(s) as slot 0 and
# only one tuner would ever be usable. Pass a cumulative fe_base so the global
# slot ids stay 1:1 with the NimManager frontend_device indices (see the
# NimManager /dev/dvb fallback in the next patch block).
p = 'lib/dvb/dvb.cpp'
s = open(p, encoding='utf-8').read()

# (6a) scanDevices() takes a fe_base offset; the per-adapter frontend index is
# shifted by it so slot ids are globally unique across all adapters.
old = 'void eDVBAdapterLinux::scanDevices()\n'
new = 'void eDVBAdapterLinux::scanDevices(int fe_base)\n'
assert s.count(old) == 1, 'dvb.cpp scanDevices() definition not found'
s = s.replace(old, new, 1)

# (6b) both eDVBFrontend constructors receive the slot id; shift it by fe_base.
old = '\t\t\tfe = new eDVBFrontend(name.c_str(), num_fe, ok, true);\n'
new = '\t\t\tfe = new eDVBFrontend(name.c_str(), num_fe + fe_base, ok, true);\n'
assert s.count(old) == 1, 'dvb.cpp simulate frontend ctor not found'
s = s.replace(old, new, 1)
old = '\t\t\tfe = new eDVBFrontend(name.c_str(), num_fe, ok, false, fe);\n'
new = '\t\t\tfe = new eDVBFrontend(name.c_str(), num_fe + fe_base, ok, false, fe);\n'
assert s.count(old) == 1, 'dvb.cpp real frontend ctor not found'
s = s.replace(old, new, 1)

# (6c) adapter enumeration (adapter0 first, then platform adapters 1..N) with
# fe_base threading.
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
    '\tint fe_base = 0;\n'
    '\tif (eDVBAdapterLinux::exist(0))\n'
    '\t{\n'
    '\t\teDVBAdapterLinux *adapter = new eDVBAdapterLinux(0);\n'
    '\t\tadapter->scanDevices(fe_base);\n'
    '\t\taddAdapter(adapter, true);\n'
    '\t\tfe_base += adapter->getNumFrontends();\n'
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
    '\t\t\tadapter->scanDevices(fe_base);\n'
    '\t\t\taddAdapter(adapter);\n'
    '\t\t\tfe_base += adapter->getNumFrontends();\n'
    '\t\t}\n'
    '\t\tnum_adapter++;\n'
    '\t}\n'
)
assert old in s, 'dvb.cpp adapter enumeration block not found'
s = s.replace(old, new, 1)
open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('patched dvb.cpp (enumerate platform adapters 1..N + fe_base slot ids)')

# (6d) matching header declaration so the default arg is visible everywhere.
p = 'lib/dvb/dvb.h'
s = open(p, encoding='utf-8').read()
old = '\tvoid scanDevices();\n'
new = '\tvoid scanDevices(int fe_base = 0);\n'
assert s.count(old) == 1, 'dvb.h scanDevices() declaration not found'
s = s.replace(old, new, 1)
open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('patched dvb.h (scanDevices(int fe_base = 0))')
PYEOF

# --- 1b. ported fixes from manhere/enigma2-hi3798cv200 (.ci/patches) -------------------------
# These are OpenATV-tree patches; each is re-anchored to OpenPLi scarthgap and
# only the parts that apply to our tree are taken. Applied: 140 (decode demux),
# 110 (FrontendInfo crash), 080 (NIM enumeration fallback), 210 (lamedb
# frequency-0 guard), 200 (HAVE_HISTB decoder backend, blocks 1c/1d below).
# Skipped (verified against the pinned OpenPLi scarthgap source):
#   * 020-fb-setmode-fallback    -> superseded by our fb.cpp DRM-fbdev rework
#   * 030-avswitch-getmodelist   -> OpenPLi AVSwitch.py has no getModeList()
#   * 040-avcontrol-videomode    -> OpenPLi has no lib/driver/avcontrol.cpp
#   * 050/070 UTF-8 hardening    -> OpenPLi Directories.py already UTF-8 aware
#   * 090/100 opkg screens       -> Information.py absent, SoftwareUpdate has
#                                   no fetchedList path in OpenPLi
#   * 130-dangling-bouquet       -> OpenPLi loadBouquet() is structured
#                                   differently (no operator[] early-return)
#   * 220 maintained patches     -> OpenATV packaging/patches chain, n/a
#   * 300 proc-stb redirect      -> OpenPLi does not use /proc/stb

python3 - <<'PYEOF'
# (7a) lib/dvb/demux.cpp: DMX_SET_SOURCE fallback (live-decode blocker fix).
# histb-dmx does not implement DMX_SET_SOURCE (removed from mainline in 4.14;
# the driver returns ENOTTY). Stock setSourceFrontend() only records source on
# ioctl success, so source stays -1 and allocateDemux()'s sharing test
# (getSource() == frontend DVBID) never matches -> "no free demux found" and
# every live decode-demux allocation fails. On this box each adapter has a
# single frontend+demux, so the hardware routing is a no-op; record source
# regardless so live decode can proceed.
p = 'lib/dvb/demux.cpp'
s = open(p, encoding='utf-8').read()
old = (
    '\tif (res)\n'
    '\t\teDebug("[eDVBDemux] DMX_SET_SOURCE Frontend%d failed: %m", fenum);\n'
    '\telse\n'
    '\t\tsource = fenum;\n'
)
new = (
    '\tif (res)\n'
    '\t\teDebug("[eDVBDemux] DMX_SET_SOURCE Frontend%d failed: %m (recorded anyway)", fenum);\n'
    '\t/* DVBIP-1002: histb-dmx has no DMX_SET_SOURCE (ENOTTY) and each adapter\n'
    '\t * has a single frontend and demux, so hardware source routing is a\n'
    '\t * no-op. Record the source anyway: allocateDemux() sharing\n'
    '\t * (getSource() == frontend DVBID) must succeed for the live decode-demux\n'
    '\t * allocation on the single demux of each adapter. */\n'
    '\tsource = fenum;\n'
)
assert s.count(old) == 1, 'demux.cpp setSourceFrontend anchor not found'
s = s.replace(old, new, 1)
open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('patched demux.cpp (DMX_SET_SOURCE fallback)')

# (7b) Components/Converter/FrontendInfo.py: defuse the LOCK/SLOT_NUMBER assert.
# stock skin_default attaches Pixmap renderers to FrontendInfo>LOCK conversions;
# Pixmap.changed() probes hasattr(source, "text") which evaluates this property
# and raises the assert -> opening Satfinder BSODs. Lock/slot-number have no
# meaningful text form; return "" instead.
p = 'lib/python/Components/Converter/FrontendInfo.py'
s = open(p, encoding='utf-8').read()
old = '\t\tassert self.type not in (self.LOCK, self.SLOT_NUMBER), "the text output of FrontendInfo cannot be used for lock info"\n'
new = (
    '\t\tif self.type in (self.LOCK, self.SLOT_NUMBER):\n'
    '\t\t\t# No meaningful text form for lock/slot-number. The stock\n'
    '\t\t\t# skin_default attaches Pixmap renderers to FrontendInfo>LOCK\n'
    '\t\t\t# conversions; Pixmap.changed() probes hasattr(source, "text")\n'
    '\t\t\t# which evaluates this property - raising here BSODs Satfinder.\n'
    '\t\t\treturn ""\n'
)
assert s.count(old) == 1, 'FrontendInfo.py getText assert anchor not found'
s = s.replace(old, new, 1)
open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('patched FrontendInfo.py (LOCK/SLOT_NUMBER returns "")')
PYEOF

python3 - <<'PYEOF'
# (7c) Components/NimManager.py: /dev/dvb fallback NIM enumeration.
# The only NIM data source upstream is /proc/bus/nim_sockets (dreambox-centric,
# provided by vendor drivers). Mainline histb-dmx + mxl214 expose only standard
# /dev/dvb/adapterN/frontend0 and no proc file -> empty tuner list. When the proc
# file is absent, scan /dev/dvb via FE_GET_INFO and build entries in the same
# format the proc parser produces, then reuse the existing NIM build pipeline.
p = 'lib/python/Components/NimManager.py'
s = open(p, encoding='utf-8').read()

head_old = (
    '\t\ttry:\n'
    '\t\t\tnimfile = open("/proc/bus/nim_sockets")\n'
    '\t\texcept IOError:\n'
    '\t\t\treturn\n'
    '\n'
    '\t\tcurrent_slot = None\n'
    '\n'
    '\t\tentries = {}\n'
    '\t\tfor line in nimfile:\n'
)
head_new = (
    '\t\tentries = self.enumDevDvbFrontends()\n'
    '\t\tif entries is None:\n'
    '\t\t\ttry:\n'
    '\t\t\t\tnimfile = open("/proc/bus/nim_sockets")\n'
    '\t\t\texcept IOError:\n'
    '\t\t\t\treturn\n'
    '\t\t\tcurrent_slot = None\n'
    '\t\t\tentries = {}\n'
    '\t\t\tfor line in nimfile:\n'
)
assert s.count(head_old) == 1, 'NimManager enumerateNIMs head anchor not found'
assert s.count('\t\tnimfile.close()\n') == 1, 'NimManager nimfile.close anchor not unique'
s = s.replace(head_old, head_new, 1)
# Re-indent the proc-parse body by one tab so it nests inside "if entries is None:".
idx = s.index(head_new) + len(head_new)
cid = s.index('\t\tnimfile.close()\n', idx)
body = s[idx:cid].rstrip('\n')
reindented = '\t' + body.replace('\n', '\n\t') + '\n'
s = s[:idx] + reindented + s[cid:]
s = s.replace('\t\tnimfile.close()\n', '\t\t\tnimfile.close()\n', 1)
assert s.count(head_new) == 1 and s.count('\t\t\tnimfile.close()\n') == 1, 'NimManager reindent sanity failed'
open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('patched NimManager.py (dev/dvb fallback NIM enumeration)')

# (7d) add the enumDevDvbFrontends() helper right before enumerateNIMs().
method = '''\tdef enumDevDvbFrontends(self):
\t\t# Hi3798CV200: mainline DVB drivers (histb-dmx + mxl214) expose only
\t\t# standard /dev/dvb/adapterN/frontend0 and no /proc/bus/nim_sockets
\t\t# (dreambox-centric interface no mainline driver provides). Enumerate
\t\t# frontends via FE_GET_INFO and return entries in the same format the
\t\t# /proc parser produces. Returns None when the proc file exists so it
\t\t# keeps priority; {} when /dev/dvb is absent.
\t\tif os.path.exists("/proc/bus/nim_sockets"):
\t\t\treturn None
\t\tif not os.path.exists("/dev/dvb"):
\t\t\treturn {}
\t\timport ctypes
\t\timport fcntl

\t\tclass FrontendInfo(ctypes.Structure):
\t\t\t_fields_ = [
\t\t\t\t("name", ctypes.c_char * 128),
\t\t\t\t("type", ctypes.c_int),
\t\t\t\t("frequency_min", ctypes.c_uint32),
\t\t\t\t("frequency_max", ctypes.c_uint32),
\t\t\t\t("frequency_stepsize", ctypes.c_uint32),
\t\t\t\t("frequency_tolerance", ctypes.c_uint32),
\t\t\t\t("symbol_rate_min", ctypes.c_uint32),
\t\t\t\t("symbol_rate_max", ctypes.c_uint32),
\t\t\t\t("symbol_rate_tolerance", ctypes.c_uint32),
\t\t\t\t("notifier_delay", ctypes.c_uint32),
\t\t\t\t("caps", ctypes.c_uint32),
\t\t\t]

\t\tFE_GET_INFO = 0x80A86F3D  # _IOR('o', 61, struct dvb_frontend_info)
\t\ttypeMap = {0: "DVB-S", 1: "DVB-C", 2: "DVB-T", 3: "ATSC"}
\t\tentries = {}
\t\tfrontendIndex = 0
\t\tfor adapter in sorted(os.listdir("/dev/dvb")):
\t\t\tif not adapter.startswith("adapter"):
\t\t\t\tcontinue
\t\t\tfePath = os.path.join("/dev/dvb", adapter, "frontend0")
\t\t\tif not os.path.exists(fePath):
\t\t\t\tcontinue
\t\t\ttry:
\t\t\t\tfd = os.open(fePath, os.O_RDONLY)
\t\t\t\ttry:
\t\t\t\t\tinfo = FrontendInfo()
\t\t\t\t\tfcntl.ioctl(fd, FE_GET_INFO, info)
\t\t\t\tfinally:
\t\t\t\t\tos.close(fd)
\t\t\t\tfeType = typeMap.get(info.type)
\t\t\t\tif feType is None:
\t\t\t\t\tprint("[NimManager] %s: unsupported FE type %d, skipped" % (fePath, info.type))
\t\t\t\t\tcontinue
\t\t\t\tfeName = info.name.decode("utf-8", "replace").strip() or fePath
\t\t\t\tentries[frontendIndex] = {
\t\t\t\t\t"type": feType,
\t\t\t\t\t"name": feName,
\t\t\t\t\t"isempty": False,
\t\t\t\t\t"frontend_device": frontendIndex,
\t\t\t\t}
\t\t\t\tprint("[NimManager] fallback NIM scan: slot %d '%s' (%s)" % (frontendIndex, feName, feType))
\t\t\t\tfrontendIndex += 1
\t\t\texcept Exception as err:
\t\t\t\tprint("[NimManager] fallback NIM scan failed on %s: %s" % (fePath, err))
\t\treturn entries

\tdef enumerateNIMs(self):
'''
anchor = '\tdef enumerateNIMs(self):\n'
assert s.count(anchor) == 1, 'NimManager enumerateNIMs method anchor not unique'
s = s.replace(anchor, method, 1)
open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('added NimManager.py enumDevDvbFrontends() helper')
PYEOF

python3 - <<'PYEOF'
# (7e) lib/dvb/db.cpp: reject / skip transponders with frequency 0.
# A flaky frontend can report frequency 0; feeding that feparm back through
# addChannelToList clobbers the good in-memory record and saveServicelist then
# persists "t 0:0:5:..." into lamedb, so every later start tunes to 0 kHz.
# Guard 1 drops feparm updates with frequency 0; guard 2 never persists them.
p = 'lib/dvb/db.cpp'
s = open(p, encoding='utf-8').read()

old1 = (
    'RESULT eDVBDB::addChannelToList(const eDVBChannelID &id, iDVBFrontendParameters *feparm)\n'
    '{\n'
    '\tchannel ch;\n'
    '\tstd::map<eDVBChannelID, channel>::iterator it = m_channels.find(id);\n'
    '\tASSERT(feparm);\n'
    '\tch.m_frontendParameters = feparm;\n'
)
new1 = (
    'RESULT eDVBDB::addChannelToList(const eDVBChannelID &id, iDVBFrontendParameters *feparm)\n'
    '{\n'
    '\tchannel ch;\n'
    '\tstd::map<eDVBChannelID, channel>::iterator it = m_channels.find(id);\n'
    '\tASSERT(feparm);\n'
    '\t/* a broken frontend can report frequency 0; keep the previous record */\n'
    '\t{\n'
    '\t\teDVBFrontendParametersSatellite sat;\n'
    '\t\teDVBFrontendParametersTerrestrial ter;\n'
    '\t\teDVBFrontendParametersCable cab;\n'
    '\t\teDVBFrontendParametersATSC atsc;\n'
    '\t\tunsigned int freqchk;\n'
    '\t\tif (!feparm->getDVBS(sat)) freqchk = sat.frequency;\n'
    '\t\telse if (!feparm->getDVBT(ter)) freqchk = ter.frequency;\n'
    '\t\telse if (!feparm->getDVBC(cab)) freqchk = cab.frequency;\n'
    '\t\telse if (!feparm->getATSC(atsc)) freqchk = atsc.frequency;\n'
    '\t\telse freqchk = 1; /* unknown delivery system: do not judge */\n'
    '\t\tif (freqchk == 0)\n'
    '\t\t{\n'
    '\t\t\teDebug("[eDVBDB] addChannelToList: reject %08x:%04x:%04x, frequency 0 from frontend", id.dvbnamespace.get(), id.transport_stream_id.get(), id.original_network_id.get());\n'
    '\t\t\treturn -1;\n'
    '\t\t}\n'
    '\t}\n'
    '\tch.m_frontendParameters = feparm;\n'
)
assert s.count(old1) == 1, 'db.cpp addChannelToList anchor not found'
s = s.replace(old1, new1, 1)

old2 = (
    '\t\tconst eDVBChannelID &chid = i->first;\n'
    '\t\tconst channel &ch = i->second;\n'
    '\n'
    '\t\tfprintf(f, "%08x:%04x:%04x\\n", chid.dvbnamespace.get(),\n'
)
new2 = (
    '\t\tconst eDVBChannelID &chid = i->first;\n'
    '\t\tconst channel &ch = i->second;\n'
    '\n'
    '\t\t/* never persist transponders with frequency 0 (broken frontend data) */\n'
    '\t\t{\n'
    '\t\t\teDVBFrontendParametersSatellite sat;\n'
    '\t\t\teDVBFrontendParametersTerrestrial ter;\n'
    '\t\t\teDVBFrontendParametersCable cab;\n'
    '\t\t\teDVBFrontendParametersATSC atsc;\n'
    '\t\t\tunsigned int freqchk;\n'
    '\t\t\tif (!ch.m_frontendParameters->getDVBS(sat)) freqchk = sat.frequency;\n'
    '\t\t\telse if (!ch.m_frontendParameters->getDVBT(ter)) freqchk = ter.frequency;\n'
    '\t\t\telse if (!ch.m_frontendParameters->getDVBC(cab)) freqchk = cab.frequency;\n'
    '\t\t\telse if (!ch.m_frontendParameters->getATSC(atsc)) freqchk = atsc.frequency;\n'
    '\t\t\telse freqchk = 1;\n'
    '\t\t\tif (freqchk == 0)\n'
    '\t\t\t{\n'
    '\t\t\t\teDebug("[eDVBDB] saveServicelist: skip %08x:%04x:%04x, frequency 0 (omitted from lamedb output)", chid.dvbnamespace.get(), chid.transport_stream_id.get(), chid.original_network_id.get());\n'
    '\t\t\t\tcontinue;\n'
    '\t\t\t}\n'
    '\t\t}\n'
    '\n'
    '\t\tfprintf(f, "%08x:%04x:%04x\\n", chid.dvbnamespace.get(),\n'
)
assert s.count(old2) == 1, 'db.cpp saveServicelist anchor not found'
s = s.replace(old2, new2, 1)
open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('patched db.cpp (frequency-0 transponder guards)')
PYEOF

python3 - <<'PYEOF'
# --- 1c. lib/dvb/scan.cpp: recognise AVS (0x42) / AVS+ (0x43) video ----------
# Chinese cable/terrestrial PMTs carry AVS/AVS+ elementary streams. Stock
# OpenPLi only recognises 0x01/0x02/0x10/0x1b/0x24/0xEA, so videopid stays
# 0xFFFF and every AVS service is recorded without a video pid ("cannot
# watch" even with a working decoder backend). Map both to
# eDVBVideo::AVS (16): the histb backend decodes AVS and AVS+ through the
# CAVS hwaccel (AV_CODEC_ID_CAVS); eDVBVideo::AVS2 (40) has no CV200 VDH
# engine. scan.cpp does not include decoder.h, hence the literal.
p = 'lib/dvb/scan.cpp'
s = open(p, encoding='utf-8').read()
old = (
    '\t\t\t\tcase 0x24: // H265 HEVC\n'
    '\t\t\t\t\tisvideo = 1;\n'
    '\t\t\t\t\tforced_video = 1;\n'
    '\t\t\t\t\tcurrentVideoType = 7;  // H265_HEVC\n'
    '\t\t\t\t\tbreak;\n'
)
new = old + (
    '\t\t\t\tcase 0x42: // AVS (China)\n'
    '\t\t\t\tcase 0x43: // AVS+ (China, decoded via the CAVS engine)\n'
    '\t\t\t\t\tisvideo = 1;\n'
    '\t\t\t\t\tforced_video = 1;\n'
    '\t\t\t\t\t/* eDVBVideo::AVS == 16 (decoder.h); scan.cpp does not include\n'
    '\t\t\t\t\t * decoder.h, so use the literal. The histb decoder backend\n'
    '\t\t\t\t\t * maps AVS to AV_CODEC_ID_CAVS (v4l2request hwaccel). */\n'
    '\t\t\t\t\tcurrentVideoType = 16;\n'
    '\t\t\t\t\tbreak;\n'
)
assert s.count(old) == 1, 'scan.cpp HEVC case anchor not found'
s = s.replace(old, new, 1)
open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('patched scan.cpp (AVS/AVS+ 0x42/0x43 video recognition)')
PYEOF

export E2_PKG_DIR="$HERE/packaging"

python3 - <<'PYEOF'
# --- 1d. HAVE_HISTB decoder backend (re-anchored 200 patch) -------------------
# histb has no /dev/dvb/adapterN/{video,audio}0 nodes; the backend compiled in
# when HAVE_HISTB replaces the classic eDVBAudio/eDVBVideo/eDVBPCR/eDVBTText
# implementations with: demux TSDEMUX_TAP -> user-space TS/PES demux ->
# dlopen("/usr/local/lib/hivxe-ffmpeg/libav*.so") avcodec (v4l2request
# hwaccel) -> DRM_PRIME -> histb-vdp overlay plane; audio avcodec -> ALSA.
# Reference: manhere/enigma2-hi3798cv200 packaging/decoder_histb_impl.h +
# .ci/patches/200-decoder-histb-backend.py, re-anchored to OpenPLi scarthgap:
#   * OpenPLi eDVBAudio pimpl is "int m_fd, m_fd_demux, m_dev, m_is_freezed;"
#     (no m_bypass member like OpenATV)
#   * OpenPLi VIDEO_STREAMTYPE_* defines are not wrapped in #endif, so the
#     relocation cuts to the end of the AVS2 define line instead
#   * the backend references four OpenATV-only members (m_debug x4 statics,
#     m_bypass, m_streamtype, gamma/HDR tracking) which are stripped here
import os
import shutil

pkg = os.environ['E2_PKG_DIR']
os.makedirs('lib/driver/uapi/drm', exist_ok=True)
for name in ('decoder_histb_impl.h', 'histb_video_capture_impl.h',
             'histb_audio_control.h', 'histb_video_entry.h'):
    shutil.copyfile(os.path.join(pkg, name), 'lib/dvb/' + name)
shutil.copyfile(os.path.join(pkg, 'histb_drm.h'), 'lib/driver/histb_drm.h')
shutil.copyfile(os.path.join(pkg, 'uapi', 'drm', 'histb_drm.h'),
                'lib/driver/uapi/drm/histb_drm.h')
print('histb backend headers installed (lib/dvb, lib/driver)')

# (d1) strip OpenATV-only members from the backend implementation
p = 'lib/dvb/decoder_histb_impl.h'
s = open(p, encoding='utf-8').read()
for cls in ('eDVBAudio', 'eDVBVideo', 'eDVBPCR', 'eDVBTText'):
    line = 'int %s::m_debug = -1;\n' % cls
    assert s.count(line) == 1, 'm_debug definition: ' + cls
    s = s.replace(line, '', 1)
old = 'm_is_freezed(0), m_bypass(-1)'
assert s.count(old) == 1, 'eDVBAudio m_bypass initializer'
s = s.replace(old, 'm_is_freezed(0)', 1)
old = ', m_gamma(0), m_streamtype(-1)'
assert s.count(old) == 1, 'eDVBVideo m_streamtype initializer'
s = s.replace(old, ', m_gamma(0)', 1)
for line in (
    '\tm_hdr_detector = nullptr;\n',
    '\tm_hdr_gamma = 0;\n',
    '\tm_driver_gamma = 0;\n',
    '\tm_hdr_gamma_authoritative = false;\n',
    '\tm_gamma_from_driver_event = false;\n',
):
    assert s.count(line) == 1, 'gamma/HDR line: ' + repr(line)
    s = s.replace(line, '', 1)
old = '\tm_streamtype = type;\n'
assert s.count(old) == 1, 'eDVBVideo startPid m_streamtype'
s = s.replace(old, '', 1)
open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('decoder_histb_impl.h adapted for OpenPLi class members')

# (d2) decoder.h: add the histb pimpl pointer to the four leaf classes
p = 'lib/dvb/decoder.h'
s = open(p, encoding='utf-8').read()
old = 'int m_fd, m_fd_demux, m_dev, m_is_freezed;'   # eDVBAudio (no m_bypass here)
assert s.count(old) == 1, 'decoder.h eDVBAudio pimpl anchor'
s = s.replace(old, old + '\n\tvoid *m_histb = nullptr;', 1)
old = 'int m_fd, m_fd_demux, m_dev;'                   # eDVBVideo
assert s.count(old) == 1, 'decoder.h eDVBVideo pimpl anchor'
s = s.replace(old, old + '\n\tvoid *m_histb = nullptr;', 1)
old = 'int m_fd_demux, m_dev;'                         # eDVBPCR + eDVBTText
assert s.count(old) == 2, 'decoder.h eDVBPCR/eDVBTText pimpl anchors'
s = s.replace(old, old + '\n\tvoid *m_histb = nullptr;')
assert s.count('void *m_histb = nullptr;') == 4, 'decoder.h m_histb count'
open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('patched decoder.h (m_histb pimpl members)')

# (d3) decoder.cpp: exclude the classic implementations behind HAVE_HISTB and
# include the backend instead; eTSMPEGDecoder (the orchestrator) stays.
p = 'lib/dvb/decoder.cpp'
s = open(p, encoding='utf-8').read()
old = 'DEFINE_REF(eDVBAudio);'
assert s.count(old) == 1, 'decoder.cpp DEFINE_REF(eDVBAudio) anchor'
s = s.replace(old,
    '#ifdef HAVE_HISTB\n'
    '#include <lib/dvb/decoder_histb_impl.h>\n'
    '#else\n' + old, 1)
old = 'DEFINE_REF(eTSMPEGDecoder);'
assert s.count(old) == 1, 'decoder.cpp DEFINE_REF(eTSMPEGDecoder) anchor'
s = s.replace(old,
    '#endif /* HAVE_HISTB */\n\n' + old, 1)
# The VIDEO_STREAMTYPE_* defines sit inside the now-excluded span but are
# still used by the kept eTSMPEGDecoder code: relocate them above the
# sandwich so both build paths see them. OpenPLi does not wrap them in
# #endif (unlike OpenATV), so cut through the AVS2 define line.
start_anchor = '// not finally values i think.. !!'
assert s.count(start_anchor) == 1, 'streamtype comment anchor'
i0 = s.index(start_anchor)
j = s.index('#define VIDEO_STREAMTYPE_AVS2', i0)
i1 = s.index('\n', j) + 1
block = s[i0:i1]
s = s[:i0] + s[i1:]
sandwich = '#ifdef HAVE_HISTB\n#include <lib/dvb/decoder_histb_impl.h>'
assert s.count(sandwich) == 1, 'histb include anchor'
s = s.replace(sandwich, block + '\n' + sandwich, 1)
# histb backend implements audio via ALSA; the box has no legacy DVB audio
# device node, so m_has_audio stays false and setAudioPID() silently forces
# apid=-1. Force it on.
old = 'm_has_audio = !access(filename, W_OK);'
assert s.count(old) == 1, 'm_has_audio anchor'
s = s.replace(old,
    old + '\n'
    '#ifdef HAVE_HISTB\n'
    '\t\tm_has_audio = true;\n'
    '#endif', 1)
depth = 0
for line in s.split('\n'):
    st = line.strip()
    if st.startswith('#ifdef') or st.startswith('#ifndef') or st.startswith('#if '):
        depth += 1
    elif st.startswith('#endif'):
        depth -= 1
assert depth == 0, 'unbalanced ifdefs depth %d' % depth
open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('patched decoder.cpp (HAVE_HISTB backend sandwich + streamtype relocation)')
PYEOF

# --- 1e. hivxe-ffmpeg compile-time headers -----------------------------------
# The backend dlopens the runtime libs already installed on the box
# (/usr/local/lib/hivxe-ffmpeg, avcodec 63.1.101) but compiles against the
# headers of the same HiSilicon fork. Debian's libavcodec-dev cannot be used:
# it lacks hwcontext_v4l2request.h and has a different ABI generation.
FF_SRC="$WORK/src/ffmpeg-hivxe"
FF_INC="$WORK/ff-include"
if [ ! -f "$FF_SRC/libavcodec/avcodec.h" ]; then
  git clone --depth 1 https://github.com/HiSilicon-Development/FFmpeg "$FF_SRC"
fi
mkdir -p "$FF_INC/libavcodec" "$FF_INC/libavutil" "$FF_INC/libswresample" "$FF_INC/libswscale"
cp "$FF_SRC"/libavcodec/*.h "$FF_INC/libavcodec/"
cp "$FF_SRC"/libavutil/*.h "$FF_INC/libavutil/"
cp "$FF_SRC"/libswresample/*.h "$FF_INC/libswresample/"
cp "$FF_SRC"/libswscale/*.h "$FF_INC/libswscale/"
# configure-generated headers: fixed arm64 little-endian template
cat > "$FF_INC/libavutil/avconfig.h" <<'EOF'
#ifndef AVUTIL_AVCONFIG_H
#define AVUTIL_AVCONFIG_H
#define AV_HAVE_BIGENDIAN 0
#define AV_HAVE_FAST_UNALIGNED 1
#endif
EOF
cat > "$FF_INC/libavutil/ffversion.h" <<'EOF'
#ifndef AVUTIL_FFVERSION_H
#define AVUTIL_FFVERSION_H
#define FFMPEG_VERSION "hivxe-63.1.101"
#endif
EOF
[ -f "$FF_INC/libavutil/hwcontext_v4l2request.h" ] || \
  { echo "hivxe-ffmpeg headers incomplete (no hwcontext_v4l2request.h)"; exit 1; }
[ -f "$FF_INC/libavcodec/avcodec.h" ] || \
  { echo "hivxe-ffmpeg headers incomplete (no avcodec.h)"; exit 1; }
echo "hivxe-ffmpeg compile headers ready at $FF_INC"

# libdrm is linked directly by the backend (xf86drmMode for the overlay plane)
pkg-config --exists libdrm 2>/dev/null || \
  { apt-get update -qq && apt-get install -y --no-install-recommends libdrm-dev; }
{ [ -e /usr/include/libdrm/xf86drm.h ] || [ -e /usr/include/xf86drm.h ]; } || \
  { echo "libdrm headers missing (libdrm-dev)"; exit 1; }
echo "libdrm OK"

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
# HAVE_HISTB: histb decoder backend (dlopen hivxe-ffmpeg, no hard link).
# -I$FF_INC: HiSilicon FFmpeg fork headers (Debian libavcodec-dev lacks
#   hwcontext_v4l2request.h and has a different ABI generation).
# -I/usr/include/libdrm: xf86drm.h internally #include <drm.h>; Debian's
#   libdrm-dev installs kernel DRM headers under /usr/include/libdrm/
#   (not /usr/include/drm/).
CPPFLAGS="-DHAVE_HISTB -I$FF_INC -I/usr/include/libdrm" \
LIBS="-lasound -ldrm -ldl" \
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

# DVB text fallback: this cable network carries raw GBK/GB2312 channel names
# without DVB encoding descriptors, so OpenPLi's default "* ISO8859-1"
# fallback garbles them into double-encoded mojibake. GB18030 (superset of
# GB2312/GBK/CP936, natively supported by lib/base/encoding.cpp) is the
# proven fix on this exact box: OpenATV ships /etc/enigma2/encoding.conf
# containing exactly "* GB18030". Rewrite the shipped fallback.
ENC="$WORK/stage/usr/share/enigma2/encoding.conf"
if [ -f "$ENC" ]; then
  sed -i 's/^\*[[:space:]]*ISO8859-1[[:space:]]*/*   GB18030/' "$ENC"
  grep -q '^\*.*GB18030' "$ENC" || { echo "encoding.conf fallback rewrite failed"; exit 1; }
else
  printf '*   GB18030\n' > "$ENC"
fi
echo "encoding.conf: global DVB text fallback set to GB18030"

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

# OpenWebif 2.4.1 imports Tools.CopyFiles at module scope in
# controllers/models/movies.py. That module is OpenATV-specific and absent
# from OpenPLi scarthgap, which otherwise aborts the whole httpserver import
# chain. Provide the two functions it actually uses (its other optional
# OpenATV imports are already inside try/except or local functions).
cat > "$WORK/stage/usr/lib/enigma2/python/Tools/CopyFiles.py" <<'PY'
# Compatibility shim: OpenWebif expects OpenATV's Tools.CopyFiles, which
# OpenPLi scarthgap does not ship. Only copyFiles/moveFiles are used.
import os
import shutil


def _run(items, func):
	for src, dst in items:
		parent = os.path.dirname(dst)
		if parent:
			os.makedirs(parent, exist_ok=True)
		func(src, dst)


def copyFiles(items, name=None):
	_run(items, shutil.copy2)


def moveFiles(items, name=None):
	_run(items, shutil.move)
PY
echo "shipped Tools.CopyFiles compatibility shim"

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
