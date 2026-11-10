#!/bin/bash
# Install the OpenPLi Enigma2 port on a DEDICATED Debian 13 (trixie) arm64 box
# (mainline 6.12.115-dvbip kernel).
#   sudo ./install-enigma2-arm64.sh install [tarball]   # system-wide install
#   sudo ./install-enigma2-arm64.sh uninstall            # removes what we installed
#
# IMPORTANT: if the box already runs another E2 image (e.g. OpenATV), do NOT use
# this system install. On such boxes /usr/share/enigma2 is commonly a symlink
# into the other image and `tar -C /` would overwrite it; the script refuses in
# that case. Use scripts/e2/try-openpli-e2.sh for an isolated, reversible test.
#
# Phase 1: UI only. DVB frontends exist (MXL214, adapters 0-3, ca0..ca3 per
# adapter); TV playback decode pipeline comes later.
set -euo pipefail

LAUNCHER=/usr/local/bin/openpli-e2
UNIT=/etc/systemd/system/openpli-e2.service

case "${1:-}" in
install)
  T="${2:-e2-arm64.tar.gz}"
  [ -f "$T" ] || { echo "tarball $T not found"; exit 1; }
  if [ -f "$(dirname "$T")/e2-arm64.tar.gz.sha256" ]; then
    (cd "$(dirname "$T")" && sha256sum -c e2-arm64.tar.gz.sha256)
  fi

  # Never overwrite another Enigma2 image's data tree.
  if [ -L /usr/share/enigma2 ]; then
    echo "ERROR: /usr/share/enigma2 is a symlink -> $(readlink /usr/share/enigma2)"
    echo "Another E2 image owns that path. Refusing a system install."
    echo "Use scripts/e2/try-openpli-e2.sh for an isolated test instead."
    exit 1
  fi

  # trixie runtime packages. The 64-bit time_t transition renamed four of them
  # (libpng16-16t64, libssl3t64, libasound2t64, libglib2.0-0t64); the bookworm
  # names no longer exist on Debian 13.
  apt-get install -y --no-install-recommends \
    python3 python3-twisted python3-pil python3-netifaces \
    libfreetype6 libfribidi0 libpng16-16t64 libxml2 libsigc++-3.0-0 \
    libssl3t64 libasound2t64 libgcc-s1 libstdc++6 libcrypt1 libgomp1 libdvbcsa1 \
    libavahi-client3 libjpeg62-turbo libgif7 libglib2.0-0t64 \
    chrony fonts-dejavu-core \
    gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav \
    gstreamer1.0-alsa \
    || echo "WARN: adjust package names; run: ldd /usr/bin/enigma2 | grep 'not found'"

  tar -C / -xzf "$T"

  # E2-DarkOS / PLi-HD skins are separate OE packages, not shipped by enigma2's
  # make install — point the default skin at the in-tree skin_default so startup
  # doesn't attempt a missing E2-DarkOS skin every boot.
  if [ ! -f /usr/etc/enigma2/settings ]; then
    mkdir -p /usr/etc/enigma2
    echo 'config.skin.primary_skin=skin_default/skin.xml' > /usr/etc/enigma2/settings
  fi

  # /proc/stb does not exist on the mainline kernel — E2 logs harmless errors for
  # those writes; a proper shim module is Phase 3.
  cat > "$LAUNCHER" <<'WRAP'
#!/bin/sh
# OpenPLi Enigma2 (mainline port) launcher — generic fbdev OSD on /dev/fb0
# (histb-vdp), ALSA audio, evdev remote. Do not run while another DRM master
# (a second E2 / Kodi) holds the display.
# The 6.12.115 kernel registers the HiSTB IR receiver (IR_HIX5HD2=m +
# INPUT_EVDEV=y), so /dev/input/eventX normally exists; keep the mkdir as a
# guard for boxes booted without the IR module — Components/InputDevice.py
# hard-requires the directory to exist (os.listdir).
mkdir -p /dev/input
# Unbind fbcon (kernel text console) from the framebuffer: otherwise the console
# blank timer / keypress redraws tty text on top of E2's fb0 output.
for c in /sys/class/vtconsole/vtcon*; do
  [ -w "$c/bind" ] && echo 0 > "$c/bind" 2>/dev/null
done
exec /usr/bin/enigma2 "$@"
WRAP
  chmod 755 "$LAUNCHER"
  mkdir -p /dev/input

  # E2 intentionally quits after first-boot steps (e.g. applying a new language)
  # to restart its GUI. Use a UNIQUE unit name: on shared boxes e2.service is
  # normally the other image's (e.g. OpenATV) enabled autostart unit.
  # Not enabled automatically — enabling would replace the box's default GUI.
  cat > "$UNIT" <<'UNIT_TEXT'
[Unit]
Description=OpenPLi Enigma2 (mainline port, hi3798cv200)
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/openpli-e2
# Re-bind fbcon on stop so the text console comes back after E2 exits.
ExecStopPost=/bin/sh -c 'for c in /sys/class/vtconsole/vtcon*; do echo 1 > "$c/bind" 2>/dev/null; done; true'
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT_TEXT
  systemctl daemon-reload
  echo "NOT enabled at boot (an existing E2 may own that role)."
  echo "manual start : systemctl start openpli-e2"
  echo "enable later : systemctl enable openpli-e2   (only on a dedicated box)"

  echo "== verify"
  ldd /usr/bin/enigma2 | grep 'not found' && echo "MISSING libs above" || echo "all libs resolved"
  echo "run: openpli-e2  (from a local console; only one E2 may own /dev/fb0)"
  ;;
uninstall)
  systemctl disable --now openpli-e2.service 2>/dev/null || true
  rm -f "$LAUNCHER" "$UNIT"
  # only the paths this tarball owns; never touch /etc/enigma2 (other images)
  # and never unlink another image's /usr/share/enigma2 symlink.
  if [ -L /usr/share/enigma2 ]; then
    echo "WARN: /usr/share/enigma2 is a symlink, leaving it untouched"
  else
    rm -rf /usr/share/enigma2
  fi
  rm -rf /usr/lib/enigma2 /usr/lib/enigma.info /usr/etc/enigma2 \
         /usr/share/fonts/ttf/Regular.ttf /usr/share/fonts/ttf/Bold.ttf \
         /usr/share/fonts/ttf/Italic.ttf /usr/share/fonts/ttf/Handwriting.ttf \
         /usr/share/fonts/tuxtxt.ttf /usr/bin/enigma2 /usr/bin/enigma2.sh
  systemctl daemon-reload 2>/dev/null || true
  echo "removed (kept /etc/enigma2, /root/.enigma2 and apt packages)"
  ;;
*) echo "usage: $0 install [tarball] | uninstall"; exit 2;;
esac
