# e2-hi3798cv200

Enigma2 (OpenPLi scarthgap) port for **Hi3798CV200** (HiMedia Q10 Pro class boxes,
DVBIP-1002) running the mainline **6.12.115-dvbip** kernel
([HiSilicon-Development/linux-6.12.y](https://github.com/HiSilicon-Development/linux-6.12.y))
on **Debian 12 (bookworm) arm64**. Everything is built by GitHub Actions
(`ubuntu-24.04-arm` runner inside a `debian:bookworm` container) — nothing is built locally.

## Upstream kernel baseline

All kernel facts below come from the pinned upstream commit, not from vendor BSP code:

| Item | Value |
|---|---|
| Source | `HiSilicon-Development/linux-6.12.y` |
| Pinned commit | `0e14b052c61c4ffa2cc57f299d136fd404f9988f` (HEAD 2026-11-09) |
| Version | `Makefile`: 6.12.115 |
| Board defconfig | `arch/arm64/configs/hi3798cv200_defconfig` (+ `dvbip_1002_defconfig` fragment) |
| Board DTS | `arch/arm64/boot/dts/hisilicon/hi3798cv200-dvbip-1002-arm64.dts` |

`scripts/e2/bookworm-env.sh` installs the **DVB UAPI headers of that exact commit**
(`include/uapi/linux/dvb/*.h`, DVB API 5.12) into `/usr/local/include/linux/dvb`,
applying the same sanitisation as the kernel's `scripts/headers_install.sh`
(`__user`/`__force`/`__iomem`, `<linux/compiler.h>`, …) — raw in-tree UAPI headers
are kernel-side sources and do not compile in userspace as-is.
Debian bookworm's `linux-libc-dev` is 6.1 and predates `SYS_DVBC2` (mainline since
v6.2), which is why the old build masked that switch case with `#ifdef`. The port now
compiles against the same UAPI as the running kernel, so no masking is needed. Keep
the pin in `bookworm-env.sh` in sync when the box kernel is updated.

## Hardware/kernel facts (verified against the source above)

| Block | Status on upstream 6.12.115 |
|---|---|
| Display | `histb-vdp` atomic KMS driver (`DRM_HISI_HISTB=m`): graphics G0/G1/G3 + video V0/V1, HDR10/HLG, HDCP 1.4/2.2, CEC. `/dev/fb0` is the **generic DRM fbdev emulation** — `drm_fbdev_dma_setup(drm, 32)` with `CONFIG_DRM_FBDEV_EMULATION=y`, XRGB8888, 32bpp |
| fbdev semantics | `drm_fb_helper_fill_fix()` sets `fix.line_length = fb->pitches[0]`; `fix.smem_len = surface_height * pitch`; `__fill_var()` reports `yres_virtual = fb->height` (single buffer only). `drm_fb_helper_check_var()` rejects geometry larger than the allocated framebuffer and never pushes a modeset back to KMS. No vendor `FBIO_BLIT` / `FBIO_SET_MANUAL_BLIT` / `FBIO_WAITFORVSYNC` |
| DVB-C tuner | 4x MaxLinear MxL214 DVB-C frontends. `histb-dmx` registers **one `dvb_adapter` per TS input** (`HISTB_DMX_MAX_INPUTS = 6`); the 1002 DTS wires inputs 0..3 → adapters 0..3, standard `/dev/dvb`. Each adapter exposes **four CA aliases `ca0..ca3`** (`HISTB_DMX_CA_ALIASES = 4`, for the Tvheadend/OSCam CA mask) |
| Video decode | `histb-vdec` V4L2 stateful m2m (HiVXE), H.264 request controls validated; **no** DVB video0/audio0 device |
| GPU | Mali-T720 (`arm,mali-t720`) with `CONFIG_DRM_PANFROST=m` — usable by Mesa/GBM clients, but E2's fbdev OSD still blits on the CPU |
| Audio | AIAO/Tianlai + simple-audio-card (`DVBIP-1002`), analog and HDMI as separate PCM devices |
| Input | HiSTB IR receiver (`CONFIG_IR_HIX5HD2=m`) with `CONFIG_INPUT_EVDEV=y` → `/dev/input/eventX` for the remote |

## Port strategy

Phase 1 (this repo, CI green = artifact `e2-arm64-bookworm`):
- OpenPLi/enigma2 `scarthgap` pinned `6a5eb2e2` (HEAD 2026-11-07), built with `--with-boxtype=none
  --with-fbdev=/dev/fb0 --with-alsa` — the **generic fbdev path**, no vendor
  `HAVE_HISILICON` code (that assumes vendor-kernel hifb/proc-stb/DVB-video0).
- Source patches are derived from the kernel implementation, not from symptoms:
  - `fb.cpp`: no double-buffer request on generic DRM fbdev emulation, tolerate a
    refused `FBIOPUT_VSCREENINFO`, re-read native geometry, derive page count from
    the geometry actually reported, keep the authoritative (possibly padded)
    `fix.line_length`, zero the local `fb_fix_screeninfo`, bound the clear to
    `smem_len`, and skip the non-existent vendor blit ioctl.
  - `gfbdc.cpp`: adopt the real framebuffer geometry as the render surface.
  - `dvb.cpp`: enumerate platform (non-USB) adapters 1..N, not just adapter0.
- bookworm gap: libdvbsi++ not packaged → built from `tuxbox-neutrino/libdvbsi`
  (pinned `8ed28aff`), runtime `.so` shipped inside the tarball.
- Deliverable: `e2-arm64.tar.gz` (`usr/` layout) + `install-enigma2-arm64.sh` → UI boots on HDMI.

Phase 2: TV pipeline — DVB-C scanning works against the standard frontend API;
playback decode needs a bridge (gst/ffmpeg with HiVXE v4l2m2m, or soft decode MVP).
The upstream kernel also exposes the VDP video planes and PRIME import paths for a
future zero-copy route.

Phase 3: `/proc/stb` shim kernel module, hw decode integration, OSCam/CA
(`ca0..ca3` on every adapter already exist).

## Usage (on the box)

```bash
bash install-enigma2-arm64.sh install      # installs deps, extracts to /, creates `e2` launcher
e2                                          # run from the local console (tty0)
```

Note: the UI renders via the KMS fbdev emulation at software-blit speed; do not run
while another DRM master (e.g. a GBM media player) holds the display. The launcher
unbinds fbcon while E2 runs so the text console does not redraw over the OSD.
