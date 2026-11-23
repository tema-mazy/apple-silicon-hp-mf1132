#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copy pi/out and the service files to the Pi and run install.sh there.
#
#   pi/deploy.sh            (PI=user@host overrides the target)
#
# Uses tar over ssh, so the Pi needs nothing but sshd. The ssh key may prompt
# for biometrics twice (copy, then install).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PI=${PI:-pi@m1132.local}

for f in out/hpcups out/m1132-escl out/hp-laserjet_professional_m1132_mfp.ppd out/hp-laserjet_p1006.ppd; do
    [ -f "$HERE/$f" ] || { echo "missing $HERE/$f - run pi/build.sh in the Lima VM first" >&2; exit 1; }
done

echo "Copying to $PI:~/m1132"
tar -C "$HERE" -cf - out install.sh m1132-escl.service 60-m1132-scanner.rules m1132-escl.avahi.service rpi-brcmfmac.conf m1132-oled.py m1132-oled.service m1132-wifi-recover.sh m1132-wifi-recover.service m1132-wifi-recover.timer hp-fw-upload.py hp-fw-upload@.service 61-hp-fw-upload.rules \
    | ssh "$PI" 'rm -rf ~/m1132 && mkdir ~/m1132 && tar -C ~/m1132 -xf -'

echo "Installing on $PI"
ssh -t "$PI" "sudo QUEUE=${QUEUE:-HP_M1132} URI=${URI:-} P1006_QUEUE=${P1006_QUEUE:-HP_P1006} P1006_URI=${P1006_URI:-} ~/m1132/install.sh ~/m1132"
