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
    python3 python3-twisted python3-pil libfreetype6 libfribidi0 libpng16-16 libxml2 \
    libsigc++-3.0-0 libssl3 libasound2 libgcc-s1 libstdc++6 \
    fonts-dejavu-core gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav \
    gstreamer1.0-alsa \
    || echo "WARN: adjust package names; run: ldd /usr/bin/enigma2 | grep 'not found'"

  tar -C / -xzf "$T"

  # /proc/stb does not exist on the mainline kernel — E2 logs harmless errors for those
  # writes; a proper shim module is Phase 3.
  cat > /usr/local/bin/e2 <<'WRAP'
#!/bin/sh
# Enigma2 (mainline port) launcher — generic fbdev OSD on /dev/fb0 (histb-vdp),
# ALSA audio, evdev remote. Do not run while Kodi is holding DRM master.
exec /usr/bin/enigma2 "$@"
WRAP
  chmod 755 /usr/local/bin/e2

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
