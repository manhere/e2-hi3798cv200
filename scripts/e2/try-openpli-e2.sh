#!/bin/bash
# Trial-run the OpenPLi Enigma2 artifact on a box that ALREADY runs another E2
# (e.g. OpenATV) without replacing it. Run this ON THE BOX as root.
#
#   bash try-openpli-e2.sh prepare [e2-arm64.tar.gz]  # extract to /opt, isolate config, ldd preflight
#   bash try-openpli-e2.sh run --stop-current-e2      # pause the other E2, run OpenPLi in a mount namespace
#   bash try-openpli-e2.sh restore                   # bring the other E2 back
#   bash try-openpli-e2.sh clean                     # remove everything this script created
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
  # enigma.cpp uses setenv(..., 0) for PYTHONPATH -> ours wins. The extra
  # $ROOT/python holds third-party modules installed into the trial tree only.
  export PYTHONPATH="$ROOT/python:$P/lib/enigma2/python"
  # runtime .so shipped by the tarball (libdvbsi++, libtuxtxt, libtuxtxt32bpp)
  export LD_LIBRARY_PATH="$P/lib/aarch64-linux-gnu:$P/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  # in-trial shims (chronyc etc.) must win over the system PATH
  export PATH="$ROOT/bin:$PATH"
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
  # UsageConfig defaults config.ntp.timesync to "auto", whose notifier runs
  # `/etc/init.d/chronyd status` + `update-rc.d chronyd enable 3` on the HOST.
  # Force transponder time so the trial never touches system init config.
  grep -q '^config.ntp.timesync=' "$P/etc/enigma2/settings" || \
    echo 'config.ntp.timesync=dvb' >> "$P/etc/enigma2/settings"

  # Repair dangling font symlinks. Older artifacts link Italic/Handwriting to
  # DejaVuSans-Oblique / DejaVuSans-ExtraLight, which trixie's
  # fonts-dejavu-core does not ship (ln -sf created the link anyway).
  # Rewrite any broken link to the best font actually present on this box.
  DJ=/usr/share/fonts/truetype/dejavu
  for name in Regular Bold Italic Handwriting; do
    link="$P/share/fonts/ttf/$name.ttf"
    [ -L "$link" ] || continue
    [ -e "$link" ] && continue
    case "$name" in
      Regular)     cands="DejaVuSans.ttf" ;;
      Bold)        cands="DejaVuSans-Bold.ttf" ;;
      Italic)      cands="DejaVuSans-Oblique.ttf DejaVuSansMono-Oblique.ttf DejaVuSerif.ttf DejaVuSans.ttf" ;;
      Handwriting) cands="DejaVuSans-ExtraLight.ttf DejaVuSansCondensed.ttf DejaVuSerif.ttf DejaVuSans.ttf" ;;
    esac
    for c in $cands; do
      if [ -f "$DJ/$c" ]; then
        ln -sfn "$DJ/$c" "$link"
        echo "repaired font $name.ttf -> $c"
        break
      fi
    done
  done

  # Components/Network.py imports netifaces, which is not installed system-wide.
  # Extract the Debian module into the trial tree ONLY (apt-get download +
  # dpkg-deb -x): no system package is installed, so the other image is
  # untouched. twisted / PIL / OpenSSL are already provided by the system.
  mkdir -p "$ROOT/python" "$ROOT/deb"
  if ! ls "$ROOT/python"/netifaces* >/dev/null 2>&1; then
    if ! ls "$ROOT/deb"/python3-netifaces*.deb >/dev/null 2>&1; then
      (cd "$ROOT/deb" && apt-get download python3-netifaces >/dev/null 2>&1) || {
        echo "ERROR: cannot fetch python3-netifaces deb (apt-get download failed)"; exit 1; }
    fi
    for deb in "$ROOT/deb"/python3-netifaces*.deb; do
      dpkg-deb -x "$deb" "$ROOT/deb/root" || { echo "ERROR: dpkg-deb -x failed"; exit 1; }
    done
    cp -a "$ROOT/deb/root/usr/lib/python3/dist-packages"/netifaces* "$ROOT/python/" || {
      echo "ERROR: netifaces module not found in deb"; exit 1; }
    echo "installed netifaces into the trial tree"
  fi

  # UsageConfig.NtpTimeSync.isUsable() runs `chronyc tracking` at startup and
  # only catches CalledProcessError; a missing binary raises FileNotFoundError
  # and kills E2 outright. Provide a harmless in-trial shim instead of
  # installing the system chrony package (which would start chronyd and change
  # time sync for the other image). It reports "not usable" so E2 keeps DVB time.
  mkdir -p "$ROOT/bin"
  cat > "$ROOT/bin/chronyc" <<'SHIM'
#!/bin/sh
# Isolated OpenPLi trial shim — no system chrony is installed.
if [ "${1:-}" = "tracking" ]; then
  echo "Leap status     : Not synchronised"
fi
exit 0
SHIM
  chmod 755 "$ROOT/bin/chronyc"

  # UsageConfig.timesyncChanged() calls `/etc/init.d/chronyd status` and then
  # `update-rc.d chronyd enable/disable 3` for EVERY timesync choice. The
  # absolute init script simply fails (chrony is not installed), but
  # update-rc.d would touch /etc/rc*.d on the host. Put a no-op shim earlier
  # in PATH so the trial cannot modify the system init configuration.
  cat > "$ROOT/bin/update-rc.d" <<'SHIM'
#!/bin/sh
# Isolated OpenPLi trial: swallow Enigma2's init-system changes.
exit 0
SHIM
  chmod 755 "$ROOT/bin/update-rc.d"

  # skin.py derives DEFAULT_SKIN from BoxInfo ("E2-DarkOS/skin.xml" or
  # "PLi-HD/skin.xml"); neither ships with enigma2, so it logs "Using emergency
  # skin". Alias both names to the in-tree skin_default (relative symlink, so
  # all relative image/font references still resolve).
  for s in E2-DarkOS PLi-HD; do
    if [ -d "$P/share/enigma2/skin_default" ] && [ ! -e "$P/share/enigma2/$s" ]; then
      ln -sfn skin_default "$P/share/enigma2/$s"
    fi
  done

  # SystemInfo.py hardcodes /usr/lib/enigma.info. Back up a genuine host file;
  # the other image uses /usr/local/lib/enigma.info, so normally there is none.
  # The cmp guard keeps prepare idempotent: on a second run the target is
  # already our own copy and must NOT be recorded as a "host backup".
  if [ -e "$INFO_TARGET" ]; then
    if ! cmp -s "$INFO_TARGET" "$P/lib/enigma.info" && [ ! -e "$INFO_BACKUP" ]; then
      cp -a "$INFO_TARGET" "$INFO_BACKUP"
      echo "backed up existing $INFO_TARGET -> $INFO_BACKUP"
    fi
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
  broken=0
  for link in "$P"/share/fonts/ttf/*.ttf; do
    if [ ! -e "$link" ]; then echo "BROKEN font: $link"; broken=1; fi
  done
  [ "$broken" = 0 ] || { echo "ERROR: skin fonts are dangling"; exit 1; }
  [ -x "$ROOT/bin/chronyc" ] && [ -x "$ROOT/bin/update-rc.d" ] || { echo "ERROR: trial shims missing"; exit 1; }
  if ! PYTHONPATH="$ROOT/python" python3 -c 'import netifaces' >/dev/null 2>&1; then
    echo "ERROR: netifaces module not importable in the trial tree"; exit 1
  fi
  echo "skin fonts OK, shims + netifaces present"
  echo "prepared. Next: $0 run --stop-current-e2"
  ;;

run)
  [ "${2:-}" = "--stop-current-e2" ] || {
    echo "Refusing to pause the running E2 without explicit consent."; echo "usage: $0 run --stop-current-e2"; exit 2; }
  [ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
  [ -x "$P/bin/enigma2" ] || { echo "run '$0 prepare' first"; exit 1; }
  [ -x "$ROOT/bin/chronyc" ] && [ -x "$ROOT/bin/update-rc.d" ] || { echo "run '$0 prepare' first (trial shims missing)"; exit 1; }

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
