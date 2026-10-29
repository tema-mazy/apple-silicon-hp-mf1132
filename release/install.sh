#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Install the native arm64 hpcups filter and add a CUPS queue for the
# HP LaserJet Professional M1132 MFP. Existing queues are left untouched.
#
#   sudo ./install.sh [DIR]
#
# DIR holds hpcups and the PPD (default: the directory of this script).
# Override the printer with URI=usb://... and the queue name with QUEUE=...
set -euo pipefail

SRC=$(cd "${1:-$(dirname "$0")}" && pwd)
DEST=/Library/Printers/apple-silicon-hp-m1132
QUEUE=${QUEUE:-HP_M1132_native}
PPD_NAME=hp-laserjet_professional_m1132_mfp.ppd

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
[ "$(uname -m)" = arm64 ] || { echo "this build is for Apple Silicon (arm64) only" >&2; exit 1; }
for f in hpcups "$PPD_NAME"; do
    [ -f "$SRC/$f" ] || { echo "missing $SRC/$f" >&2; exit 1; }
done

if [ -z "${URI:-}" ]; then
    URI=$(lpinfo -v | awk '$2 ~ /^usb:\/\/Hewlett-Packard\/HP%20LaserJet%20Professional%20M1132/ {print $2; exit}')
    [ -n "$URI" ] || { echo "M1132 not found on USB - connect and power it on, or set URI=" >&2; exit 1; }
fi
echo "Printer: $URI"

# CUPS only runs filters owned by root and not group/world writable.
# The .pkg installs the files into $DEST already and runs this from there.
if [ "$SRC" != "$DEST" ]; then
    install -d -o root -g wheel -m 755 "$DEST"
    install -o root -g wheel -m 755 "$SRC/hpcups" "$DEST/hpcups"
fi

PPD=$(mktemp -t m1132ppd)
sed -e "s|^\*cupsFilter: \"application/vnd.cups-raster 0 hpcups\"|*cupsFilter: \"application/vnd.cups-raster 0 $DEST/hpcups\"|" \
    -e 's|^\*NickName: "\(.*\)"|*NickName: "\1 (native arm64)"|' \
    "$SRC/$PPD_NAME" > "$PPD"
grep -q "$DEST/hpcups" "$PPD" || { echo "PPD cupsFilter rewrite failed" >&2; exit 1; }

lpadmin -p "$QUEUE" -E -v "$URI" -P "$PPD" \
    -D "HP LaserJet M1132 (native arm64)" -o PageSize=A4 -o printer-error-policy=abort-job
rm -f "$PPD"

lpstat -p "$QUEUE"
echo "Test with: lp -d $QUEUE <file.pdf>"
