#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Install the M1132 print/scan server on 64-bit Raspberry Pi OS (Debian 12):
# - hpcups filter + a CUPS queue per printer found on USB (M1132, P1006),
#   shared on the LAN (AirPrint / IPP Everywhere)
# - hp-fw-upload: sends the P1006 its firmware after every power-on
# - m1132-escl scanner service (eSCL / AirScan), announced via Avahi
# - m1132-oled status display on an I2C SSD1306 OLED (optional hardware)
#
#   sudo ./install.sh [DIR]
#
# DIR holds out/ (hpcups, m1132-escl, PPDs, P1006 firmware) and the service
# files (default: the directory of this script). Override the M1132 with
# URI=usb://... and QUEUE=..., the P1006 with P1006_URI= and P1006_QUEUE=.
set -euo pipefail

SRC=$(cd "${1:-$(dirname "$0")}" && pwd)
OUT=$SRC/out
QUEUE=${QUEUE:-HP_M1132}
PPD_NAME=hp-laserjet_professional_m1132_mfp.ppd
P1006_QUEUE=${P1006_QUEUE:-HP_P1006}
P1006_PPD=hp-laserjet_p1006.ppd
P1006_FW=hp_laserjet_p1006.fw.gz
SVC=m1132-escl

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
[ "$(uname -m)" = aarch64 ] || { echo "this build is for 64-bit Raspberry Pi OS (aarch64) only" >&2; exit 1; }
for f in out/hpcups out/$SVC "out/$PPD_NAME" "out/$P1006_PPD" hp-fw-upload.py hp-fw-upload@.service 61-hp-fw-upload.rules $SVC.service 60-m1132-scanner.rules $SVC.avahi.service rpi-brcmfmac.conf m1132-oled.py m1132-oled.service m1132-wifi-recover.sh m1132-wifi-recover.service m1132-wifi-recover.timer; do
    [ -f "$SRC/$f" ] || { echo "missing $SRC/$f" >&2; exit 1; }
done

export DEBIAN_FRONTEND=noninteractive
apt-get install -y --no-install-recommends \
    cups cups-filters ghostscript avahi-daemon \
    libusb-1.0-0 libmicrohttpd12 libjpeg62-turbo libpng16-16 \
    i2c-tools python3-smbus python3-pil fonts-dejavu-core python3-usb
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

# P1006 firmware: udev starts hp-fw-upload@p1006 whenever the printer appears.
install -o root -g root -m 755 "$SRC/hp-fw-upload.py" /usr/local/bin/hp-fw-upload
install -o root -g root -m 644 "$SRC/hp-fw-upload@.service" /etc/systemd/system/hp-fw-upload@.service
install -o root -g root -m 644 "$SRC/61-hp-fw-upload.rules" /etc/udev/rules.d/61-hp-fw-upload.rules
if [ -f "$OUT/$P1006_FW" ]; then
    install -o root -g root -m 755 -d /usr/local/share/hp-firmware
    install -o root -g root -m 644 "$OUT/$P1006_FW" /usr/local/share/hp-firmware/$P1006_FW
fi
systemctl daemon-reload
udevadm control --reload

# OLED status display (SSD1306 on I2C bus 1, see README). The service waits
# for the display, so installing it without the hardware is harmless.
grep -q '^dtparam=i2c_arm=on' /boot/firmware/config.txt || echo 'dtparam=i2c_arm=on' >> /boot/firmware/config.txt
grep -qx 'i2c-dev' /etc/modules || echo 'i2c-dev' >> /etc/modules
[ -e /dev/i2c-1 ] || { dtparam i2c_arm=on 2>/dev/null; modprobe i2c-dev; } || true
id -u m1132-oled >/dev/null 2>&1 || useradd -r -M -s /usr/sbin/nologin -g i2c m1132-oled
install -o root -g root -m 755 "$SRC/m1132-oled.py" /usr/local/bin/m1132-oled
install -o root -g root -m 644 "$SRC/m1132-oled.service" /etc/systemd/system/m1132-oled.service
systemctl daemon-reload
systemctl enable --now m1132-oled

# Wi-Fi fallback: an AirPrint hotspot with the lowest autoconnect priority, so
# NetworkManager raises it when no known network is reachable; the
# m1132-wifi-recover timer retries the normal network every 10 minutes.
# HOTSPOT_PSK= sets the key (default PrintMeNow!); HOTSPOT_PSK=none skips it.
if [ "${HOTSPOT_PSK:-PrintMeNow!}" != none ] && ! nmcli -t -g NAME con show | grep -qx AirPrint-hotspot; then
    nmcli con add type wifi ifname wlan0 con-name AirPrint-hotspot ssid AirPrint mode ap \
        802-11-wireless.band bg 802-11-wireless.channel 6 \
        wifi-sec.key-mgmt wpa-psk wifi-sec.proto rsn wifi-sec.pairwise ccmp wifi-sec.group ccmp \
        wifi-sec.pmf disable wifi-sec.psk "${HOTSPOT_PSK:-PrintMeNow!}" \
        ipv4.method shared ipv6.method disabled \
        connection.autoconnect yes connection.autoconnect-priority -10 >/dev/null
fi
install -o root -g root -m 755 "$SRC/m1132-wifi-recover.sh" /usr/local/bin/m1132-wifi-recover
install -o root -g root -m 644 "$SRC/m1132-wifi-recover.service" "$SRC/m1132-wifi-recover.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now m1132-wifi-recover.timer

# Zero 2 W Wi-Fi: mask the broken SAE/FWSUP firmware features (see the conf
# file and README "Networking"). Takes effect on the next boot; the driver
# also lives in the initramfs, so rebuild that too.
if grep -q "Zero 2 W" /proc/device-tree/model 2>/dev/null \
   && ! cmp -s "$SRC/rpi-brcmfmac.conf" /etc/modprobe.d/rpi-brcmfmac.conf; then
    install -o root -g root -m 644 "$SRC/rpi-brcmfmac.conf" /etc/modprobe.d/rpi-brcmfmac.conf
    update-initramfs -u
    echo "brcmfmac feature mask installed; reboot for Wi-Fi to use it"
fi

# CUPS: share queues on the LAN; cups-browsed is not needed for that.
systemctl enable --now cups
cupsctl --share-printers
# cupsctl restarts cupsd; wait until the scheduler answers again.
for _ in $(seq 1 30); do
    lpstat -r 2>/dev/null | grep -q 'is running' && break
    sleep 1
done

# The libusb backend probes on demand; the device may need a moment.
USB=
for _ in 1 2 3 4 5 6; do
    USB=$(lpinfo -v 2>/dev/null | grep '^direct usb:' || true)
    [ -n "$USB" ] && break
    sleep 5
done
# usb_uri MODEL: the first usb:// URI naming MODEL (lower case).
usb_uri() {
    echo "$USB" | awk -v m="$1" 'index(tolower($2), m) {print $2; exit}'
}

# add_queue QUEUE URI PPD DESCRIPTION
add_queue() {
    echo "Printer $1: $2"
    lpadmin -p "$1" -E -v "$2" -P "$3" -D "$4" -L "$(hostname)" \
        -o PageSize=A4 -o printer-error-policy=abort-job -o printer-is-shared=true
    lpstat -p "$1"
    echo "Test with: lp -d $1 /usr/share/cups/data/testprint"
}

URI=${URI:-$(usb_uri m1132)}
P1006_URI=${P1006_URI:-$(usb_uri p1006)}
[ -n "$URI$P1006_URI" ] || { echo "no printer found on USB - connect and power it on (lsusb -d 03f0:), or set URI= / P1006_URI=" >&2; exit 1; }

if [ -n "$P1006_URI" ]; then
    [ -f /usr/local/share/hp-firmware/$P1006_FW ] || { echo "P1006 found but no $OUT/$P1006_FW - put hplip-3.26.6-plugin.run in vendor/ and rebuild" >&2; exit 1; }
    # It may have been powered on before the uploader existed.
    systemctl start hp-fw-upload@p1006 || journalctl -u hp-fw-upload@p1006 -n 5 --no-pager
    add_queue "$P1006_QUEUE" "$P1006_URI" "$OUT/$P1006_PPD" "HP LaserJet P1006"
    lpadmin -d "$P1006_QUEUE"
fi
if [ -n "$URI" ]; then
    add_queue "$QUEUE" "$URI" "$OUT/$PPD_NAME" "HP LaserJet M1132 MFP"
    lpadmin -d "$QUEUE"
fi
echo "Scan test: curl -s http://localhost:18132/eSCL/ScannerStatus"
