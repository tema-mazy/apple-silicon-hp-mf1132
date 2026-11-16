#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Install the M1132 print/scan server on 64-bit Raspberry Pi OS (Debian 12):
# - hpcups filter + CUPS queue, shared on the LAN (AirPrint / IPP Everywhere)
# - m1132-escl scanner service (eSCL / AirScan), announced via Avahi
#
#   sudo ./install.sh [DIR]
#
# DIR holds out/ (hpcups, m1132-escl, PPD) and the service files (default: the
# directory of this script). Override the printer with URI=usb://... and the
# queue name with QUEUE=...
set -euo pipefail

SRC=$(cd "${1:-$(dirname "$0")}" && pwd)
OUT=$SRC/out
QUEUE=${QUEUE:-HP_M1132}
PPD_NAME=hp-laserjet_professional_m1132_mfp.ppd
SVC=m1132-escl

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
[ "$(uname -m)" = aarch64 ] || { echo "this build is for 64-bit Raspberry Pi OS (aarch64) only" >&2; exit 1; }
for f in out/hpcups out/$SVC "out/$PPD_NAME" $SVC.service 60-m1132-scanner.rules $SVC.avahi.service; do
    [ -f "$SRC/$f" ] || { echo "missing $SRC/$f" >&2; exit 1; }
done

export DEBIAN_FRONTEND=noninteractive
apt-get install -y --no-install-recommends \
    cups cups-filters ghostscript avahi-daemon \
    libusb-1.0-0 libmicrohttpd12 libjpeg62-turbo libpng16-16
if dpkg -s printer-driver-hpcups >/dev/null 2>&1; then
    echo "printer-driver-hpcups is installed and owns /usr/lib/cups/filter/hpcups; remove it first" >&2
    exit 1
fi
if ldd "$OUT/hpcups" | grep -q "not found"; then
    ldd "$OUT/hpcups" >&2; echo "hpcups: missing shared libraries" >&2; exit 1
fi

# Print filter. CUPS only runs filters owned by root and not group/world writable.
install -o root -g root -m 755 "$OUT/hpcups" /usr/lib/cups/filter/hpcups

# Scanner service: dedicated user, USB access via udev group "scanner".
getent group scanner >/dev/null || groupadd -r scanner
id $SVC >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -d /nonexistent -G scanner $SVC
install -o root -g root -m 755 "$OUT/$SVC" /usr/local/bin/$SVC
install -o root -g root -m 644 "$SRC/60-m1132-scanner.rules" /etc/udev/rules.d/60-m1132-scanner.rules
udevadm control --reload && udevadm trigger --subsystem-match=usb
install -o root -g root -m 644 "$SRC/$SVC.avahi.service" /etc/avahi/services/$SVC.service
install -o root -g root -m 644 "$SRC/$SVC.service" /etc/systemd/system/$SVC.service
systemctl daemon-reload
systemctl enable --now avahi-daemon $SVC
systemctl restart $SVC
echo "Scanner: eSCL service on http://$(hostname).local:18132 (journalctl -u $SVC)"

# CUPS: share queues on the LAN; cups-browsed is not needed for that.
systemctl enable --now cups
cupsctl --share-printers

if [ -z "${URI:-}" ]; then
    # The libusb backend probes on demand; the device may need a moment.
    for _ in 1 2 3 4 5 6; do
        URI=$(lpinfo -v | awk 'tolower($0) ~ /^direct usb:.*m1132/ {print $2; exit}')
        [ -n "$URI" ] && break
        sleep 5
    done
    [ -n "$URI" ] || { echo "M1132 not found on USB - connect and power it on (lsusb -d 03f0:042a), or set URI=" >&2; exit 1; }
fi
echo "Printer: $URI"

lpadmin -p "$QUEUE" -E -v "$URI" -P "$OUT/$PPD_NAME" \
    -D "HP LaserJet M1132 MFP" -L "$(hostname)" \
    -o PageSize=A4 -o printer-error-policy=abort-job -o printer-is-shared=true
lpadmin -d "$QUEUE"

lpstat -p "$QUEUE"
echo "Test with: lp -d $QUEUE /usr/share/cups/data/testprint"
echo "Scan test: curl -s http://localhost:18132/eSCL/ScannerStatus"
