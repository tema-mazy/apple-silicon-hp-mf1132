#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Install the native arm64 driver for the HP LaserJet Professional M1132 MFP:
# - print filter hpcups and a CUPS queue (existing queues are left untouched)
# - scanner service m1132-escl (eSCL/AirScan on this Mac, started at login)
#
#   sudo ./install.sh [DIR]
#
# DIR holds hpcups, m1132-escl and the PPD (default: the directory of this
# script). Override the printer with URI=usb://... and the queue name with QUEUE=...
set -euo pipefail

SRC=$(cd "${1:-$(dirname "$0")}" && pwd)
DEST=/Library/Printers/apple-silicon-hp-m1132
QUEUE=${QUEUE:-HP_M1132_native}
PPD_NAME=hp-laserjet_professional_m1132_mfp.ppd
AGENT_ID=com.github.tema-mazy.m1132-escl
AGENT=/Library/LaunchAgents/$AGENT_ID.plist

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
[ "$(uname -m)" = arm64 ] || { echo "this build is for Apple Silicon (arm64) only" >&2; exit 1; }
for f in hpcups m1132-escl "$PPD_NAME"; do
    [ -f "$SRC/$f" ] || { echo "missing $SRC/$f" >&2; exit 1; }
done

# CUPS only runs filters owned by root and not group/world writable.
# The .pkg installs the files into $DEST already and runs this from there.
if [ "$SRC" != "$DEST" ]; then
    install -d -o root -g wheel -m 755 "$DEST"
    install -o root -g wheel -m 755 "$SRC/hpcups" "$SRC/m1132-escl" "$DEST/"
fi

# Scanner service: one per logged-in user, eSCL on port 18132 for this Mac only.
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$AGENT_ID</string>
    <key>ProgramArguments</key><array><string>$DEST/m1132-escl</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardErrorPath</key><string>/tmp/m1132-escl.log</string>
</dict>
</plist>
PLIST
chown root:wheel "$AGENT"
chmod 644 "$AGENT"
CONSOLE_UID=$(stat -f %u /dev/console)
if [ "$CONSOLE_UID" -gt 0 ]; then
    launchctl bootout "gui/$CONSOLE_UID/$AGENT_ID" 2>/dev/null || true
    launchctl bootstrap "gui/$CONSOLE_UID" "$AGENT"
fi
echo "Scanner: eSCL service on http://127.0.0.1:18132 (log /tmp/m1132-escl.log)"

if [ -z "${URI:-}" ]; then
    URI=$(lpinfo -v | awk '$2 ~ /^usb:\/\/Hewlett-Packard\/HP%20LaserJet%20Professional%20M1132/ {print $2; exit}')
    [ -n "$URI" ] || { echo "M1132 not found on USB - connect and power it on, or set URI=" >&2; exit 1; }
fi
echo "Printer: $URI"

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
