#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Back up and remove HP's Intel-only (x86) printer and scanner drivers, which
# stop working without Rosetta 2 (macOS 28). Run after installing the native
# driver.
#
#   sudo ./remove-hp-x86.sh [BACKUP_DIR]
#
# BACKUP_DIR defaults to your home folder. DRY_RUN=1 only lists what would be
# backed up and removed. Restore with:
#   sudo tar -xzf BACKUP_DIR/hp-x86-driver-<date>.tar.gz -C /
set -euo pipefail

[ "${DRY_RUN:-0}" = 1 ] || [ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

OWNER=${SUDO_USER:-$(id -un)}
BACKUP_DIR=$(cd "${1:-$(eval echo "~$OWNER")}" && pwd)
ARCHIVE=$BACKUP_DIR/hp-x86-driver-$(date +%Y%m%d-%H%M%S).tar.gz

uses_hp() { ( set +o pipefail; (gzip -dc "$1" 2>/dev/null || cat "$1") | grep -q '/Library/Printers/hp/' ); }

# Queues whose PPD runs HP's x86 filters.
queues=()
for q in $(lpstat -v 2>/dev/null | awk '{sub(":", "", $3); print $3}'); do
    [ -f "/etc/cups/ppd/$q.ppd" ] && uses_hp "/etc/cups/ppd/$q.ppd" && queues+=("$q")
done

# Files: the HP driver tree, HP's Image Capture modules, and every PPD that
# points into it (system PPD library and leftovers in /etc/cups/ppd).
cd /
paths=()
[ -e Library/Printers/hp ] && paths+=(Library/Printers/hp)
for f in "Library/Image Capture/Devices/"HP*; do              # Intel-only HP modules
    exe=$(ls "$f/Contents/MacOS/"* 2>/dev/null | head -1)
    [ -n "$exe" ] && ! lipo -archs "$exe" 2>/dev/null | grep -qw arm64 && paths+=("$f")
done
for f in etc/cups/ppd/*.ppd etc/cups/ppd/*.ppd.O Library/Printers/PPDs/Contents/Resources/*; do
    [ -f "$f" ] && uses_hp "$f" && paths+=("$f")
done
[ ${#paths[@]} -gt 0 ] || { echo "No HP x86 driver files found."; exit 0; }

echo "Queues to remove: ${queues[*]:-none}"
if [ "${DRY_RUN:-0}" = 1 ]; then
    printf '  %s\n' "${paths[@]}" | grep -v '^  Library/Printers/PPDs/'
    echo "  + $(printf '%s\n' "${paths[@]}" | grep -c '^Library/Printers/PPDs/') PPDs in /Library/Printers/PPDs"
    exit 0
fi
echo "Backing up ${#paths[@]} items to $ARCHIVE"
tar -czf "$ARCHIVE" "${paths[@]}"
tar -tzf "$ARCHIVE" > /dev/null || { echo "backup unreadable - nothing removed" >&2; exit 1; }
chown "$OWNER" "$ARCHIVE"
echo "Backup OK: $(tar -tzf "$ARCHIVE" | wc -l | tr -d ' ') entries, $(du -h "$ARCHIVE" | cut -f1)"

pkill -f /Library/Printers/hp/ 2>/dev/null || true
for q in "${queues[@]}"; do
    lpadmin -x "$q" && echo "Removed queue $q"
done
for p in "${paths[@]}"; do
    rm -rf "/$p"
done
echo "Removed ${#paths[@]} items"
lpstat -v 2>/dev/null || true
