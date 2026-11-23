#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Send the firmware to an HP LaserJet that keeps none of its own (P1005,
# P1006, 1020, ...). These printers enumerate on USB without firmware and
# print nothing until the host sends it, after every power-on. This replaces
# HPLIP's hp-firmware for a single model, on pyusb (python3-usb).
#
#   hp-fw-upload MODEL FIRMWARE.fw.gz
#
# MODEL is matched, ignoring case, against the USB product string (e.g.
# "p1006"). A printer whose IEEE 1284 device ID already carries FWVER has
# its firmware and is left alone. Runs as root from hp-fw-upload@.service (see the udev rule).
import gzip
import sys

import usb.core
import usb.util

HP_VID = 0x03F0
PRINTER_CLASS = 7
CHUNK = 4096
TIMEOUT_MS = 10000


def find_printer(model):
    for dev in usb.core.find(find_all=True, idVendor=HP_VID):
        try:
            product = usb.util.get_string(dev, dev.iProduct) or ""
        except (usb.core.USBError, ValueError):
            continue
        if model.lower() in product.lower():
            return dev, product
    return None, None


def device_id(dev, cfg, intf):
    # USB printer class GET_DEVICE_ID: 2-byte big-endian length, then the ID.
    data = dev.ctrl_transfer(0xA1, 0, cfg.bConfigurationValue - 1,
                             (intf.bInterfaceNumber << 8) | intf.bAlternateSetting,
                             1024, TIMEOUT_MS)
    return bytes(data[2:]).decode("ascii", "replace")


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: hp-fw-upload MODEL FIRMWARE.fw.gz")
    model, path = sys.argv[1], sys.argv[2]

    dev, product = find_printer(model)
    if dev is None:
        sys.exit(f"no HP {model} on USB")

    cfg = dev.get_active_configuration()
    intf = usb.util.find_descriptor(cfg, bInterfaceClass=PRINTER_CLASS)
    ep = intf and usb.util.find_descriptor(intf, custom_match=lambda e:
        usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_OUT
        and usb.util.endpoint_type(e.bmAttributes) == usb.util.ENDPOINT_TYPE_BULK)
    if ep is None:
        sys.exit(f"{product}: no printer interface with a bulk OUT endpoint")

    if "FWVER" in device_id(dev, cfg, intf):
        print(f"{product}: firmware already loaded")
        return

    with gzip.open(path) as f:
        fw = f.read()

    reattach = dev.is_kernel_driver_active(intf.bInterfaceNumber)
    if reattach:
        dev.detach_kernel_driver(intf.bInterfaceNumber)
    usb.util.claim_interface(dev, intf)
    try:
        for i in range(0, len(fw), CHUNK):
            ep.write(fw[i:i + CHUNK], TIMEOUT_MS)
    finally:
        usb.util.release_interface(dev, intf)
        if reattach:
            try:
                dev.attach_kernel_driver(intf.bInterfaceNumber)
            except usb.core.USBError:
                pass
    print(f"{product}: sent {len(fw)} bytes of firmware from {path}")


if __name__ == "__main__":
    main()
