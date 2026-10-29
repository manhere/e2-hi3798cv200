#!/bin/bash
# Install the Enigma2 port on the box (Debian 12 arm64, mainline 6.12 kernel).
#   sudo ./install-enigma2-arm64.sh install          # deps + extract + launcher
#   sudo ./install-enigma2-arm64.sh uninstall        # removes files; keeps /etc/enigma2 + /root/.enigma2
# Phase 1: UI only. DVB frontends exist (MXL214, adapters 0-3); TV playback pipeline comes later.
set -euo pipefail

case "${1:-}" in
install)
  T="${2:-e2-arm64.tar.gz}"
  [ -f "$T" ] || { echo "tarball $T not found"; exit 1; }
  if [ -f "$(dirname "$T")/e2-arm64.tar.gz.sha256" ]; then (cd "$(dirname "$T")" && sha256sum -c e2-arm64.tar.gz.sha256); fi

  # runtime packages (E2 core + generic fbdev/alsa + python + fonts)
  apt-get install -y --no-install-recommends \
    python3 python3-twisted python3-pil python3-netifaces libfreetype6 libfribidi0 libpng16-16 libxml2 \
    libsigc++-3.0-0 libssl3 libasound2 libgcc-s1 libstdc++6 \
    libavahi-client3 libjpeg62-turbo libgif7 libglib2.0-0 \
    chrony \
    fonts-dejavu-core gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
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

  # /proc/stb does not exist on the mainline kernel — E2 logs harmless errors for those
  # writes; a proper shim module is Phase 3.
  cat > /usr/local/bin/e2 <<'WRAP'
#!/bin/sh
# Enigma2 (mainline port) launcher — generic fbdev OSD on /dev/fb0 (histb-vdp),
# ALSA audio, evdev remote. Do not run while Kodi is holding DRM master.
# /dev/input is not auto-populated on this box (no HID devices registered), but
# Components/InputDevice.py hard-requires the directory to exist (os.listdir).
mkdir -p /dev/input
# Unbind fbcon (kernel text console) from the framebuffer: otherwise the console
# blank timer / keypress redraws tty text on top of E2's fb0 output.
for c in /sys/class/vtconsole/vtcon*; do
  [ -w "$c/bind" ] && echo 0 > "$c/bind" 2>/dev/null
done
exec /usr/bin/enigma2 "$@"
WRAP
  chmod 755 /usr/local/bin/e2
  mkdir -p /dev/input

  # E2 intentionally quits after first-boot steps (e.g. applying a new language) to
  # restart its GUI — a real box has an init script that relaunches it. Provide a
  # systemd service with Restart=always so the GUI survives those self-restarts.
  cat > /etc/systemd/system/e2.service <<'UNIT'
[Unit]
Description=Enigma2 (mainline port, hi3798cv200)
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/e2
# Re-bind fbcon on stop so the text console comes back after E2 exits.
ExecStopPost=/bin/sh -c 'for c in /sys/class/vtconsole/vtcon*; do echo 1 > "$c/bind" 2>/dev/null; done; true'
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable e2.service 2>/dev/null || true
  echo "start with: systemctl start e2   (auto-restarts on E2 self-restart/quit)"

  echo "== verify"
  ldd /usr/bin/enigma2 | grep 'not found' && echo "MISSING libs above" || echo "all libs resolved"
  echo "run: e2  (from a local console / console=tty0, NOT needed over ssh since fbdev writes directly)"
  ;;
uninstall)
  # tarball content is /usr — remove what we installed (approximation: enigma2 paths)
  rm -rf /usr/lib/enigma2 /usr/share/enigma2 /usr/share/fonts/ttf/Regular.ttf \
         /usr/share/fonts/ttf/Bold.ttf /usr/share/fonts/ttf/Italic.ttf /usr/share/fonts/ttf/Handwriting.ttf \
         /usr/bin/enigma2 /usr/local/bin/e2
  echo "removed (kept /etc/enigma2 and apt packages)"
  ;;
*) echo "usage: $0 install [tarball] | uninstall"; exit 2;;
esac
