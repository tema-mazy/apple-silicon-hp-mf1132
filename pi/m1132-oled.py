#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Status display for the M1132 print/scan server on a 128x64 SSD1306 OLED
# (I2C, e.g. the GM009605 module). Shows network, printer and scanner state
# and refreshes every few seconds. Needs python3-smbus, python3-pil and
# fonts-dejavu-core.
#
#   m1132-oled [--png FILE]      render one frame to FILE instead of the OLED
#   I2C_BUS / I2C_ADDR / QUEUE   environment overrides (defaults 1, 0x3c,
#                                the CUPS default destination)
import os
import re
import subprocess
import sys
import time

from PIL import Image, ImageDraw, ImageFont

W, H = 128, 64
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"
PRINTER_USB = ("03f0", "042a")
REFRESH = 5
# OLED burn-in care: low drive current, a slow pixel shift, and blanking the
# panel after OLED_TIMEOUT seconds without a state change (0 = never blank).
CONTRAST = int(os.environ.get("OLED_CONTRAST", "0x40"), 16)
TIMEOUT = int(os.environ.get("OLED_TIMEOUT", "600"))
SHIFT = ((0, 0), (1, 0), (2, 1), (1, 1), (0, 1), (-1, 1), (-2, 0), (-1, 0))


def sh(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


class SSD1306:
    INIT = (0xAE, 0xD5, 0x80, 0xA8, 0x3F, 0xD3, 0x00, 0x40, 0x8D, 0x14, 0x20, 0x00,
            0xA1, 0xC8, 0xDA, 0x12, 0x81, CONTRAST, 0xD9, 0x22, 0xDB, 0x20, 0xA4, 0xA6, 0xAF)

    def __init__(self, bus, addr):
        from smbus import SMBus
        self.bus = SMBus(bus)
        self.addr = addr
        self.on = True
        for c in self.INIT:
            self.cmd(c)

    def cmd(self, c):
        self.bus.write_byte_data(self.addr, 0x00, c)

    def power(self, on):
        if on != self.on:
            self.cmd(0xAF if on else 0xAE)
            self.on = on

    def show(self, img):
        # Horizontal addressing: 8 pages of 128 bytes, LSB is the top row.
        px = img.convert("1").load()
        buf = bytearray(W * H // 8)
        for page in range(H // 8):
            for x in range(W):
                b = 0
                for i in range(8):
                    if px[x, page * 8 + i]:
                        b |= 1 << i
                buf[page * W + x] = b
        for c in (0x21, 0, W - 1, 0x22, 0, H // 8 - 1):
            self.cmd(c)
        for i in range(0, len(buf), 32):
            self.bus.write_i2c_block_data(self.addr, 0x40, list(buf[i:i + 32]))


def iface_ip(name):
    out = sh("ip", "-4", "-o", "addr", "show", name)
    m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", out)
    return m.group(1) if m else ""


def wifi():
    """(ssid, rssi_dbm), or ('', None) when wlan0 is not associated."""
    for line in read("/proc/net/wireless").splitlines():
        if line.strip().startswith("wlan0:"):
            level = int(float(line.split()[3]))
            for row in sh("nmcli", "-t", "-f", "ACTIVE,SSID", "dev", "wifi", "list",
                          "--rescan", "no").splitlines():
                if row.startswith("yes:"):
                    return row[4:], level
            return "?", level
    return "", None


HOTSPOT = os.environ.get("HOTSPOT", "AirPrint-hotspot")
HOTSPOT_SSID = os.environ.get("HOTSPOT_SSID", "AirPrint")


def hotspot_active():
    out = sh("nmcli", "-t", "-f", "GENERAL.CONNECTION", "dev", "show", "wlan0")
    return out.strip().split(":", 1)[-1] == HOTSPOT


def printer(queue):
    """One short word about the queue: idle, printing N, stopped, no USB, no queue."""
    present = any(read(f"/sys/bus/usb/devices/{d}/idVendor") == PRINTER_USB[0]
                  and read(f"/sys/bus/usb/devices/{d}/idProduct") == PRINTER_USB[1]
                  for d in os.listdir("/sys/bus/usb/devices"))
    if not present:
        return "no USB"
    if not queue:
        return "no queue"
    state = sh("lpstat", "-p", queue)
    jobs = len([l for l in sh("lpstat", "-o", queue).splitlines() if l.strip()])
    if "disabled" in state:
        return "stopped"
    if "printing" in state or jobs:
        return f"printing {jobs}" if jobs else "printing"
    if "idle" in state:
        return "idle"
    return "unknown"


def default_queue():
    m = re.search(r"destination: (\S+)", sh("lpstat", "-d"))
    return m.group(1) if m else ""


def uptime():
    s = int(float(read("/proc/uptime", "0 0").split()[0]))
    d, s = divmod(s, 86400)
    h, s = divmod(s, 3600)
    m = s // 60
    return f"{d}d {h:02d}:{m:02d}" if d else f"{h:02d}:{m:02d}"


def frame(fonts, queue):
    """Render the status; returns (image, state) where state changes only when
    something worth waking the display for changes (not uptime/temperature)."""
    img = Image.new("1", (W, H), 0)
    d = ImageDraw.Draw(img)
    big, small = fonts

    ssid, rssi = wifi()
    ip_w, ip_e = iface_ip("wlan0"), iface_ip("eth0")
    ip = ip_w or ip_e or "no network"
    link = ("W" if ip_w else "E") if (ip_w or ip_e) else "-"
    if hotspot_active():
        ssid, rssi, link = "AP " + HOTSPOT_SSID, None, "AP"

    x0 = 2
    d.text((x0, 1), os.uname().nodename, font=big, fill=1)
    temp = read("/sys/class/thermal/thermal_zone0/temp")
    t = f"{uptime()} {int(temp) // 1000}C" if temp else uptime()
    d.text((W - 3 - d.textlength(t, font=small), 3), t, font=small, fill=1)
    d.text((x0, 15), f"{link} {ip}", font=small, fill=1)
    if ssid and rssi is None:
        wl = ssid[:20]
    elif ssid:
        wl = f"{ssid[:14]:<14}{rssi:>5}dB"
    else:
        wl = "wifi: off"
    d.text((x0, 26), wl, font=small, fill=1)
    d.line((x0, 38, W - 3, 38), fill=1)
    pr = printer(queue)
    d.text((x0, 41), f"Print {pr}", font=small, fill=1)
    scan = sh("systemctl", "is-active", "m1132-escl").strip() or "unknown"
    d.text((x0, 52), f"Scan  {scan}", font=small, fill=1)
    # RSSI wobbles all the time; bucket it so it does not keep the panel awake.
    state = (link, ip, ssid, None if rssi is None else rssi // 10, pr, scan)
    return img, state


def main():
    fonts = (ImageFont.truetype(FONT_BOLD, 12), ImageFont.truetype(FONT, 10))
    queue = os.environ.get("QUEUE") or default_queue()

    if len(sys.argv) == 3 and sys.argv[1] == "--png":
        frame(fonts, queue)[0].save(sys.argv[2])
        return

    bus = int(os.environ.get("I2C_BUS", "1"))
    addr = int(os.environ.get("I2C_ADDR", "0x3c"), 16)
    oled = None
    last_state, changed_at, tick = None, time.monotonic(), 0
    while True:
        try:
            if oled is None:
                oled = SSD1306(bus, addr)
                print(f"m1132-oled: SSD1306 at bus {bus} addr 0x{addr:02x}", flush=True)
                last_state, changed_at = None, time.monotonic()
            if not queue:
                queue = default_queue()
            img, state = frame(fonts, queue)
            now = time.monotonic()
            if state != last_state:
                last_state, changed_at = state, now
            awake = TIMEOUT == 0 or now - changed_at < TIMEOUT
            oled.power(awake)
            if awake:
                # Slow pixel shift: one step per minute around a small loop.
                dx, dy = SHIFT[(tick // (60 // REFRESH)) % len(SHIFT)]
                shifted = Image.new("1", (W, H), 0)
                shifted.paste(img, (dx, dy))
                oled.show(shifted)
            tick += 1
        except OSError as e:
            if oled is not None:
                print(f"m1132-oled: display lost ({e}), retrying", flush=True)
            oled = None
            time.sleep(30)
            continue
        time.sleep(REFRESH)


if __name__ == "__main__":
    main()
