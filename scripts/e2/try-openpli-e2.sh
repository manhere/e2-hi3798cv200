#!/bin/bash
# Trial-run the OpenPLi Enigma2 artifact on a box that ALREADY runs another E2
# (e.g. OpenATV) without replacing it. Run this ON THE BOX as root.
#
#   ./try-openpli-e2.sh prepare [e2-arm64.tar.gz]   # extract to /opt, isolate config, ldd preflight
#   ./try-openpli-e2.sh run --stop-current-e2       # pause the other E2, run OpenPLi in a mount namespace
#   ./try-openpli-e2.sh restore                    # bring the other E2 back
#   ./try-openpli-e2.sh clean                      # remove everything this script created
#
# Why this works (verified against OpenPLi/enigma2 scarthgap source):
#   lib/base/eenv.cpp.in  eEnv::initialize() does setenv(prefix|datadir|sysconfdir|
#                         libdir|..., value, 0) -> externally pre-set variables WIN.
#   main/enigma.cpp:207   PYTHONPATH is set with override=0 as well.
#   Tools/Directories.py  skins, fonts, plugins and config all use
#                         eEnv::resolve("${datadir}/...") / ("${sysconfdir}/...").
# So exporting those variables redirects the whole UI into the extracted tree;
# no chroot and no writes to /usr/share/enigma2 (which on a shared box is a
# symlink into the other image's data!).
#
# The few genuinely hardcoded paths are handled separately:
#   /etc/enigma2/*        (db.cpp, epgcache.cpp, skin.py) -> private bind mount
#                         inside `unshare -m`, seeded with read-only copies of
#                         the other image's transponder XMLs for DVB-C scanning.
#   /usr/lib/enigma.info  (Components/SystemInfo.py:47) -> a single small file,
#                         installed with backup and removed by `clean`.
# Only one E2 can own /dev/fb0 (single DRM master), so the current GUI must be
# paused while testing; `restore` brings it back. Nothing persistent is changed:
# no systemd unit, no autostart, no /etc/enigma2 settings, no /usr overwrite.
set -euo pipefail

ROOT=${E2_TRIAL_ROOT:-/opt/openpli-e2}
P="$ROOT/usr"
PRIVATE_ETC="$ROOT/private-etc/enigma2"
INFO_TARGET=/usr/lib/enigma.info
INFO_BACKUP="$ROOT/enigma.info.host-backup"

setup_env() {
  # eEnv variables (see comment above). All must be set: wordexp(WRDE_UNDEF)
  # fails on an undefined one during eEnv::initialize().
  export prefix="$P" exec_prefix="$P" \
         bindir="$P/bin" sbindir="$P/sbin" libexecdir="$P/libexec" \
         datarootdir="$P/share" datadir="$P/share" \
         sysconfdir="$P/etc" sharedstatedir="$P/com" localstatedir="$P/var" \
         libdir="$P/lib" localedir="$P/share/locale"
  # enigma.cpp uses setenv(..., 0) for PYTHONPATH -> ours wins.
  export PYTHONPATH="$P/lib/enigma2/python"
  # runtime .so shipped by the tarball (libdvbsi++, libtuxtxt, libtuxtxt32bpp)
  export LD_LIBRARY_PATH="$P/lib/aarch64-linux-gnu:$P/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export HOME="$ROOT/home"
  export PYTHONUTF8=1
}

fbcon_unbind() {
  for c in /sys/class/vtconsole/vtcon*; do
    [ -w "$c/bind" ] && echo 0 > "$c/bind" 2>/dev/null || true
  done
}

fbcon_rebind() {
  for c in /sys/class/vtconsole/vtcon*; do
    [ -w "$c/bind" ] && echo 1 > "$c/bind" 2>/dev/null || true
  done
}

case "${1:-}" in
prepare)
  T="${2:-e2-arm64.tar.gz}"
  [ -f "$T" ] || { echo "tarball $T not found"; exit 1; }
  if [ -f "$(dirname "$T")/e2-arm64.tar.gz.sha256" ]; then
    (cd "$(dirname "$T")" && sha256sum -c e2-arm64.tar.gz.sha256)
  fi
  [ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

  mkdir -p "$ROOT" "$ROOT/home" "$PRIVATE_ETC" "$P/etc/enigma2"
  echo "extracting $T -> $ROOT (never /)"
  tar -C "$ROOT" -xzf "$T"
  [ -x "$P/bin/enigma2" ] || { echo "enigma2 binary missing in tarball"; exit 1; }

  # Seed the private /etc/enigma2 with read-only transponder data so a DVB-C
  # scan works. Nothing is written back into the other image's config dir.
  for f in cables.xml satellites.xml terrestrial.xml atsc.xml encoding.conf; do
    if [ -f "/etc/enigma2/$f" ] && [ ! -e "$PRIVATE_ETC/$f" ]; then
      cp -a "/etc/enigma2/$f" "$PRIVATE_ETC/$f"
    fi
  done
  # Our own settings live under ${sysconfdir}/enigma2 (not /etc/enigma2).
  if [ ! -f "$P/etc/enigma2/settings" ]; then
    echo 'config.skin.primary_skin=skin_default/skin.xml' > "$P/etc/enigma2/settings"
  fi

  # SystemInfo.py hardcodes /usr/lib/enigma.info. Back up any existing file;
  # the other image uses /usr/local/lib/enigma.info, so there is no conflict.
  if [ -e "$INFO_TARGET" ]; then
    cp -a "$INFO_TARGET" "$INFO_BACKUP"
    echo "backed up existing $INFO_TARGET -> $INFO_BACKUP"
  else
    rm -f "$INFO_BACKUP"
  fi
  cp -a "$P/lib/enigma.info" "$INFO_TARGET"

  # Preflight with the shipped libdvbsi++/libtuxtxt .so already on the search
  # path, otherwise ldd reports those as missing even though the launch has them.
  setup_env
  echo "== preflight: dynamic libraries"
  if ldd "$P/bin/enigma2" | grep -q 'not found'; then
    ldd "$P/bin/enigma2" | grep 'not found'
    echo "ERROR: missing runtime libs. On Debian 13 the artifact must be the"
    echo "       trixie build (libpython3.13.so.1.0), not the bookworm one."
    exit 1
  fi
  echo "all libs resolved"
  echo "prepared. Next: $0 run --stop-current-e2"
  ;;

run)
  [ "${2:-}" = "--stop-current-e2" ] || {
    echo "Refusing to pause the running E2 without explicit consent."; echo "usage: $0 run --stop-current-e2"; exit 2; }
  [ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
  [ -x "$P/bin/enigma2" ] || { echo "run '$0 prepare' first"; exit 1; }

  setup_env
  if ldd "$P/bin/enigma2" | grep -q 'not found'; then
    echo "ERROR: missing runtime libs, run '$0 prepare' to see them"; exit 1
  fi

  # Pause the other image's GUI. This is transient and reversible: `restore`
  # starts e2.service again. No unit files / autostart settings are modified.
  systemctl stop e2.service 2>/dev/null || true
  for pid in $(pgrep -f '^/bin/sh /usr/local/bin/enigma2$' 2>/dev/null || true); do
    kill -TERM "$pid" 2>/dev/null || true   # wrapper traps TERM and reaps enigma2.bin
  done
  sleep 2
  if pgrep -f '/usr/local/bin/enigma2.bin' >/dev/null 2>&1; then
    echo "WARN: another enigma2 is still running; /dev/fb0 may be busy"
  fi

  mkdir -p /dev/input
  fbcon_unbind

  echo "== starting isolated OpenPLi E2 (Ctrl-C / exit returns here)"
  echo "   datadir=$datadir  libdir=$libdir  sysconfdir=$sysconfdir"
  # Private mount namespace: the hardcoded /etc/enigma2 paths in db.cpp /
  # epgcache.cpp / skin.py resolve into our own tree. Nothing leaks to the host.
  unshare -m --propagation private /bin/sh -c '
    mount --bind "$1" /etc/enigma2 || exit 1
    exec "$2"
  ' sh "$PRIVATE_ETC" "$P/bin/enigma2" || true

  fbcon_rebind
  echo "OpenPLi E2 exited. Run '$0 restore' to bring the original GUI back."
  ;;

restore)
  [ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
  fbcon_rebind
  # e2.service is the other image's own (enabled) unit; starting it restores
  # the original GUI under systemd supervision.
  systemctl start e2.service 2>/dev/null || {
    echo "WARN: systemctl start e2.service failed; start the other image's"
    echo "      launcher manually (e.g. /usr/local/bin/enigma2)."
  }
  systemctl status e2.service --no-pager -l 2>/dev/null | head -6 || true
  ;;

clean)
  [ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
  fbcon_rebind
  if [ -f "$INFO_BACKUP" ]; then
    cp -a "$INFO_BACKUP" "$INFO_TARGET"
    echo "restored $INFO_TARGET from backup"
  else
    rm -f "$INFO_TARGET"
    echo "removed $INFO_TARGET"
  fi
  rm -rf "$ROOT"
  echo "removed $ROOT (system unit / autostart / other image untouched)"
  ;;

*)
  echo "usage: $0 prepare [tarball] | run --stop-current-e2 | restore | clean"
  echo "       E2_TRIAL_ROOT=<dir> overrides the isolated root (default /opt/openpli-e2)"
  exit 2
  ;;
esac
