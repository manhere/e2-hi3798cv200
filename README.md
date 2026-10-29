# e2-hi3798cv200

Enigma2 (OpenPLi scarthgap) port for **Hi3798CV200** (HiMedia Q10 Pro class boxes)
running the mainline **6.12.112-dvbip** kernel ([HiSilicon-Development/linux-6.12.y](https://github.com/HiSilicon-Development/linux-6.12.y))
on **Debian 12 (bookworm) arm64**. Everything is built by GitHub Actions
(`ubuntu-24.04-arm` runner inside a `debian:bookworm` container) — nothing is built locally.

## Hardware/kernel facts (verified)

| Block | Status on mainline 6.12 |
|---|---|
| DVB-C tuner | 4x MaxLinear MxL214 DVB-C frontends via `histb-dmx` (adapters 0-3, standard `/dev/dvb`, plus `ca0-3`) |
| Display | `histb-vdp` atomic KMS driver with fbdev emulation (`/dev/fb0`, 32bpp) |
| Video decode | `histb-vdec` V4L2 stateful m2m (HiVXE), **no** DVB video0/audio0 device |
| GPU | none usable (Mesa has no DRI driver for histb-vdp) — UI renders on CPU |
| Audio | ALSA simple-audio-card (`DVBIP-1002`) |

## Port strategy

Phase 1 (this repo, CI green = artifact `e2-arm64-bookworm`):
- OpenPLi/enigma2 `scarthgap` pinned `21b0fbb8`, built with `--with-boxtype=none
  --with-fbdev=/dev/fb0 --with-alsa` — the **generic fbdev path**, no vendor
  `HAVE_HISILICON` code (that assumes vendor-kernel hifb/proc-stb/DVB-video0).
- bookworm gap: libdvbsi++ not packaged → built from `tuxbox-neutrino/libdvbsi`
  (pinned `8ed28aff`), runtime `.so` shipped inside the tarball.
- Deliverable: `e2-arm64.tar.gz` (`usr/` layout) + `install-enigma2-arm64.sh` → UI boots on HDMI.

Phase 2: TV pipeline — DVB-C scanning works against the standard frontend API;
playback decode needs a bridge (gst/ffmpeg with HiVXE v4l2m2m, or soft decode MVP).

Phase 3: `/proc/stb` shim kernel module, hw decode integration, OSCam/CA (`ca0-3` devices exist).

## Usage (on the box)

```bash
bash install-enigma2-arm64.sh install      # installs deps, extracts to /, creates `e2` launcher
e2                                          # run from the local console (tty0)
```

Note: the UI renders via the KMS fbdev emulation at software-blit speed; do not run
while another DRM master (e.g. a GBM media player) holds the display.
