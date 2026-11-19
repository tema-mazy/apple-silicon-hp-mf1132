#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Run from m1132-wifi-recover.timer. While the fallback hotspot is up, try the
# normal Wi-Fi again; if it still fails NetworkManager re-activates the
# hotspot on its own (it is the lowest-priority autoconnect profile).
# NetworkManager cannot scan while in AP mode, so this periodic probe is the
# only way back. Costs one hotspot drop of ~30 s per attempt.
HOTSPOT=${HOTSPOT:-AirPrint-hotspot}
active=$(nmcli -t -f GENERAL.CONNECTION dev show wlan0 2>/dev/null | cut -d: -f2-)
[ "$active" = "$HOTSPOT" ] || exit 0
# Best other autoconnect Wi-Fi profile, highest priority first.
target=$(nmcli -t -f NAME,TYPE,AUTOCONNECT,AUTOCONNECT-PRIORITY con show \
    | awk -F: -v h="$HOTSPOT" '$2=="802-11-wireless" && $3=="yes" && $1!=h {print $4":"$1}' \
    | sort -t: -k1,1nr | head -1 | cut -d: -f2-)
[ -n "$target" ] || exit 0
echo "hotspot active, trying $target"
if nmcli -w 40 con up "$target" >/dev/null 2>&1; then
    echo "back on $target"
else
    echo "$target still unavailable, staying on $HOTSPOT"
    nmcli con up "$HOTSPOT" >/dev/null 2>&1 || true
fi
