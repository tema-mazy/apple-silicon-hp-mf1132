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
  Lite, bookworm (Debian 12). Hostname `m1132` is assumed below.
- Micro-USB OTG adapter for the printer; power via the PWR port.
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
