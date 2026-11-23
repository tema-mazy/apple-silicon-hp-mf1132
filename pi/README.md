# HP LaserJet Pro M1132 MFP as an AirPrint + AirScan server on a Raspberry Pi

Everything in this folder turns a Raspberry Pi Zero 2 W with the M1132 on its
USB port into a network printer and scanner. Macs and iPhones print to it
driverless (AirPrint / IPP Everywhere) and scan from Image Capture, Preview
or NAPS2 (eSCL / AirScan). No HP software anywhere, no driver on the clients.

```
Mac / iPhone -> IPP (AirPrint) -> Pi: CUPS (gstoraster) -> hpcups -> ZjStream -> usb backend
Image Capture / NAPS2 -> eSCL -> Pi: m1132-escl (libusb) -> USB scanner
```

- `hpcups` is the same patched HPLIP filter as the macOS build (built-in JBIG
  from `src/hpjbig.c`), compiled for aarch64 Linux.
- `escl/m1132-escl.c` is a C port of `scanner/m1132-escl.swift`: same USB
  protocol and eSCL surface, on libusb-1.0, libjpeg, libpng and
  libmicrohttpd. Avahi announces it from a static service file.

## Requirements

- Raspberry Pi Zero 2 W (any 64-bit Pi works) running 64-bit Raspberry Pi OS
  Lite, bookworm (Debian 12) or trixie (Debian 13, tested with the 2026-10-06
  image). Binaries built on Debian 12 run on both. The hostname is whatever
  Raspberry Pi Imager set; `deploy.sh` takes it via `PI=pi@<host>.local`.
- Micro-USB OTG adapter for the printer; power via the PWR port. A USB hub
  on the OTG port with the printer plus a USB ethernet adapter works too and
  is the better choice where Wi-Fi is weak (see Networking).
- On the Mac: Lima (`port install lima`) to build the aarch64 binaries. The
  Lima VM is arm64 Debian 12, so the output runs on the Pi unchanged.

## Build (Lima VM on the Mac)

```
limactl create --name m1132 pi/lima.yaml
limactl start m1132
limactl shell m1132 -- /Users/mazy/Dev/apple-silicon-hp-mf1132/pi/build.sh
```

`pi/lima.yaml` provisions the build packages. `pi/build.sh` writes
`pi/out/hpcups`, `pi/out/m1132-escl` and the patched PPD; it reuses
`vendor/`, `patches/` and `src/hpjbig.c` from the repo root. Set `B=` to a
guest-local path if the shared mount is slow.

The scanner binary alone also builds on the Pi:

```
sudo apt-get install build-essential pkg-config libusb-1.0-0-dev libmicrohttpd-dev libjpeg62-turbo-dev libpng-dev
make -C pi/escl
```

## Install on the Pi

```
pi/deploy.sh                      # PI=user@host overrides pi@m1132.local
```

This copies `pi/out` and the service files with tar over ssh and runs
`install.sh` with sudo on the Pi. `install.sh`:

1. installs cups, cups-filters, ghostscript, avahi-daemon and the runtime
   libraries (no cups-browsed, no Debian hplip);
2. installs `hpcups` into `/usr/lib/cups/filter/`;
3. installs `m1132-escl` to `/usr/local/bin`, a `scanner` group and udev rule
   for the USB device, the systemd unit and the Avahi service file;
4. runs `cupsctl --share-printers` and adds queue `HP_M1132` (A4, shared,
   default) on the detected `usb://` URI.

Override with `QUEUE=` and `URI=` (both pass through `deploy.sh`).

## Verify

On the Pi:

```
lpstat -p HP_M1132
lp -d HP_M1132 /usr/share/cups/data/testprint
systemctl status m1132-escl
curl -s http://localhost:18132/eSCL/ScannerStatus
```

On the Mac:

```
dns-sd -B _ipp._tcp local.        # queue appears as "HP LaserJet M1132 MFP @ m1132"
                                  # (and "HP LaserJet P1006 @ m1132", see below)
dns-sd -B _uscan._tcp local.      # scanner appears as "HP LaserJet M1132 MFP (m1132)"
```

System Settings > Printers & Scanners > Add Printer lists the queue with the
AirPrint driver. Image Capture and Preview > Import from Scanner list the
scanner under Shared. NAPS2: ESCL driver, auto-discovery or `m1132.local:18132`.
iPhone: Share > Print.

## Differences from the macOS version

- Open on the LAN by default (no `--allow-lan` flag); the Pi is a server.
- Logs go to journald: `journalctl -u m1132-escl -f`.
- Runs as user `m1132-escl` with USB access through the `scanner` group.
- libjpeg is linked dynamically (same Debian on both sides).
- The PDF output is a hand-written single-page PDF wrapping the JPEG.

## HP LaserJet P1006

The same Pi can also serve an HP LaserJet P1006, on its own or next to the
M1132 (a USB hub on the OTG port). `install.sh` adds a queue for each
printer it finds: `HP_M1132` and `HP_P1006` (`P1006_QUEUE=` and `P1006_URI=`
override). Both shared queues show up on the LAN for AirPrint.

- Printing: the same `hpcups` binary. The P1006 speaks ZxStream (XQX), which
  HPLIP encodes with the same JBIG function `src/hpjbig.c` replaces, so it
  needs no extra code. The PPD is the stock HPLIP one.
- Firmware: the P1006 keeps no firmware. It has to be sent again after every
  power-on, and it exists only in HP's proprietary plugin. Download
  `hplip-3.26.6-plugin.run` from https://developers.hp.com/hp-linux-imaging-and-printing/plugins
  into `vendor/` (not committed, checked by sha256). `build.sh` then
  extracts `hp_laserjet_p1006.fw.gz` into `pi/out/` without running the
  plugin's installer.
- On the Pi, `61-hp-fw-upload.rules` starts `hp-fw-upload@p1006.service`
  whenever the printer appears on USB. The service runs `hp-fw-upload`,
  which sends the firmware over libusb (python3-usb). It skips a printer
  whose IEEE 1284 device ID already reports `FWVER`. Check with
  `journalctl -u hp-fw-upload@p1006`.
- A job queued while the printer is off may reach it before the firmware
  does when it powers on. Cancel and resend it if the first page fails.

## OLED status display

Optional: a 128x64 SSD1306 OLED on I2C (the common 0.96 inch GM009605
module) shows host name, time, temperature, IP and Wi-Fi signal, printer
state (idle / printing N / stopped / no USB) and the scanner service.
`install.sh` enables I2C, installs `m1132-oled` and its service; the
service retries every 30 s until a display answers, so it can be wired
later. Wiring to the 40-pin header (follow the labels on the module, the
pin order differs between boards):

```
VCC -> pin 1 (3.3V)    GND -> pin 6    SCL -> pin 5 (GPIO3)    SDA -> pin 3 (GPIO2)
```

`i2cdetect -y 1` must show `3c`; for a `3d` module add
`Environment=I2C_ADDR=0x3d` to the service. Burn-in care is built in: low
contrast (`OLED_CONTRAST`, default 0x40), a slow pixel shift, and the panel
blanks after `OLED_TIMEOUT` seconds (default 600) without a state change and
wakes on the next one; clock and temperature ticks do not count. `m1132-oled --png out.png`
renders one frame to a file for layout work without the hardware.

## Wi-Fi fallback hotspot

If no known network is reachable, NetworkManager raises the profile
`AirPrint-hotspot` (SSID `AirPrint`, WPA2, 10.42.0.1/24, lowest autoconnect
priority) so the Pi can still be reached; `install.sh` creates it with the
key from `HOTSPOT_PSK=` (default `PrintMeNow!`, `none` to skip). While it is
up the OLED shows `AP AirPrint`, and the `m1132-wifi-recover` timer retries
the normal network every 10 minutes, since the radio cannot scan in AP mode.

## Networking on the Zero 2 W

- The radio is 2.4 GHz only and the PCB antenna is weak, but the usual
  failure is not signal: against a WPA2/WPA3 mixed-mode AP every join ends
  in `Authentication with <bssid> timed out` and the AP never logs the
  client, even at -60 dBm. The firmware advertises WPA3 SAE and a
  firmware-side 4-way handshake, NetworkManager therefore selects SAE, and
  the BCM43430 completes neither. Raspberry Pi OS already
  masks some of this in `/usr/lib/modprobe.d/rpi-brcmfmac.conf`
  (`feature_disable=0x282000`) but leaves SAE_EXT on. `install.sh` installs
  `rpi-brcmfmac.conf` into `/etc/modprobe.d/`, which overrides the system
  file by name and adds bit 25 (`feature_disable=0x02282000`), then rebuilds
  the initramfs; after a reboot the Pi joins as plain WPA2-PSK. To confirm, run
  `wpa_cli -i wlan0 log_level DEBUG` and look for `using KEY_MGMT WPA-PSK`
  instead of `SAE`; `cat /sys/kernel/debug/ieee80211/phy0/features` must
  not list `SAE_EXT`.
- Imager writes `cfg80211.ieee80211_regdom=US` into cmdline.txt. US hides
  channels 12 and 13; set your country (`raspi-config nonint do_wifi_country
  PL`, and fix cmdline.txt) or the SSID is invisible.
- Imager's cloud-init profile may store no Wi-Fi key ("secrets are
  required"); set it with `nmcli con modify <profile> wifi-sec.psk '<key>'`.
- NetworkManager leaves USB gadget interfaces (`usb0`) unmanaged; a
  `/etc/NetworkManager/conf.d/usb0.conf` with `[device-usb0]
  match-device=interface-name:usb0 managed=1` fixes that if you want an
  ethernet-over-USB link to a Mac for setup (`dtoverlay=dwc2` plus
  `modules-load=dwc2,g_cdc`; macOS then also needs a route for the Pi's
  address on the gadget interface).
- Serial console on GPIO 14/15 needs `enable_uart=1`. With Bluetooth on, the
  pins carry the mini UART whose baud follows the core clock (readable at
  230400 early in boot, garbage later); add `dtoverlay=disable-bt` to get the
  PL011 at a stable 115200. The last `console=` entry in cmdline.txt owns the
  login prompt, so keep `console=serial0,115200` last.
- Never put a blocking `systemctl start` in cloud-init `bootcmd`; it runs
  before basic.target and deadlocks the boot. `cloud-init=disabled` on the
  kernel command line gets you past such a hang.

## Troubleshooting

- Printer not found: `lsusb -d 03f0:042a`. If the Zero's USB port stays in
  gadget mode, add `dtoverlay=dwc2,dr_mode=host` under `[pi02]` in
  `/boot/firmware/config.txt`.
- Print jobs: `sudo cupsctl LogLevel=debug`, then
  `tail -f /var/log/cups/error_log`. Image-heavy PDFs take tens of seconds on
  the Zero 2 W (ghostscript); `CONF_SWAPSIZE=512` in `/etc/dphys-swapfile`
  helps if memory runs out.
- Scanner "not found" while printing works: check the udev rule took effect
  (`ls -l /dev/bus/usb/*/*` shows group `scanner` for the device) and that
  the service user is in that group.
- A scan takes a while; `NextDocument` blocks until the page is done.
