# apple-silicon-hp-mf1132

Native Apple Silicon (arm64) printing and scanning for the USB-attached
**HP LaserJet Professional M1132 MFP** on macOS - no Rosetta 2, no HP plugin.

HP's macOS driver for this printer is Intel-only. macOS 27 already warns that
Intel apps running on Rosetta will not open in macOS 28, and lists HP Utility,
hpdot4d and ScanEventHandler among them. This project replaces the print path
with a native build of HPLIP's open-source `hpcups` filter, and the scanner
with a small native eSCL (AirScan) service.

Background article - the problem and how it was solved:
[HP LaserJet Professional M1132 MFP on Apple Silicon](https://meow.kyiv.ua/hp-laserjet-professional-m1132-mfp-apple-silicon-macos-driver/diy/)

## Status

| Feature                      | State                                        |
|------------------------------|----------------------------------------------|
| Printing (text, PDF, images) | Works, tested on the real printer            |
| Manual double-sided printing | Works, tested on the real printer            |
| Scanning (eSCL service)      | Works with NAPS2 (ESCL driver), tested       |

## How it works

```
app -> macOS CUPS (cgpdftoraster) -> hpcups (arm64) -> ZjStream -> usb backend
                                       |
                                       +- src/hpjbig.c -> JBIG-KIT
```

- The M1132 is a host-based printer: it accepts only ZjStream, a page stream of
  JBIG-compressed bitmaps. HPLIP's `hpcups` has an open ZjStream encoder
  (`prnt/hpcups/LJZjStream.cpp`).
- HPLIP gets the JBIG compressor itself from HP's proprietary `lj.so` plugin,
  which exists only for Linux. `src/hpjbig.c` re-implements that one function
  (`hp_encode_bits_to_jbig`) on top of the open JBIG-KIT encoder. It uses the
  same JBIG parameters foo2zjs uses for this printer class.
- The filter is linked statically against libjpeg and JBIG-KIT, so it depends
  only on system libraries in `/usr/lib`.
- Printing goes through macOS's own arm64 `usb` backend.

Scanning:

```
NAPS2 / eSCL app -> http://127.0.0.1:18132/eSCL -> m1132-escl -> USB (IOUSBHost)
```

- `scanner/m1132-escl.swift` drives the scanner over USB with the M1132's
  "Marvell" scan protocol and serves it as an eSCL (AirScan) scanner. It is
  published over Bonjour as `_uscan._tcp` "HP LaserJet M1132 MFP (native)".
- It accepts connections from this Mac only (`--allow-lan` shares it on the
  network). It opens the scanner only while a scan runs, so printing is not
  affected.
- Colour, greyscale and black & white at 150, 300 and 600 dpi; JPEG, PDF or
  PNG; any area of the glass (8.50 x 11.22 in).

## Requirements

- Apple Silicon Mac, Xcode command line tools
- MacPorts `jpeg` (used only at build time, linked statically)
- Source tarballs in `vendor/` (not committed, checked by sha256 in the build):
  - `hplip-3.26.6.tar.gz` - https://sourceforge.net/projects/hplip/files/hplip/3.26.6/
  - `jbigkit-2.1.tar.gz` - https://www.cl.cam.ac.uk/~mgk25/jbigkit/download/

## Build

```
scripts/build.sh
```

Output: `build/out/hpcups`, `build/out/m1132-escl` and
`build/out/hp-laserjet_professional_m1132_mfp.ppd`.

To make a release: test the build on the printer, copy the files to
`release/`, then run

```
scripts/make-pkg.sh
```

It writes `release/HP-M1132-native-arm64-YY.MM-<hash>.pkg`, where `<hash>` is
the short hash of the commit the release files were built from (HEAD). Commit
your changes first; the script refuses to run with uncommitted changes outside
`release/`. Set `VERSION=...` to override. The package is not kept in git;
publish it as a GitHub Release asset:

```
gh release create v<version> release/HP-M1132-native-arm64-<version>.pkg
```

## Install

Easiest: connect and turn on the printer, then download and open the
`.pkg` from the [latest release](https://github.com/tema-mazy/apple-silicon-hp-mf1132/releases/latest).
The package is not signed, so
macOS may block it the first time: right-click it and choose Open, or allow it
in System Settings > Privacy & Security. If the printer was not connected
during install, run `sudo /Library/Printers/apple-silicon-hp-m1132/install.sh`
later.

Or from a terminal, with the printer connected and on:

```
sudo release/install.sh
```

From your own build: `sudo scripts/install-queue.sh` (same installer, using
`build/out`).

This installs the scanner service (a LaunchAgent that starts at login,
log in `/tmp/m1132-escl.log`) and the filter to
`/Library/Printers/apple-silicon-hp-m1132/`, and adds a CUPS queue `HP_M1132_native` ("HP LaserJet M1132 (native arm64)")
on the printer's USB URI, A4 by default. Any existing HP queue is not touched.
The installer finds the M1132 with `lpinfo -v`; set `URI=usb://...` to pick
one explicitly, or `QUEUE=name` for a different queue name.

`release/` holds the binary and PPD built by `scripts/build.sh` and tested on
the printer. The corresponding source is this repository plus the upstream
tarballs listed above.

Test:

```
lp -d HP_M1132_native file.pdf
```

## Scanning with NAPS2

1. In NAPS2, create a profile and choose **ESCL Driver**.
2. Pick "HP LaserJet M1132 MFP (native)" if it is listed. Otherwise choose
   **Manual IP**: host `127.0.0.1`, port `18132`, and leave the HTTPS box
   unticked (the service speaks plain HTTP).
3. Use 150, 300 or 600 dpi (other values are rounded to the nearest one).

Quit Image Capture and HP's own scanner app first: while HP's Intel module
holds the scanner, the service cannot open it.

## Double-sided printing

The M1132 has no duplex unit. Pick "Double-Sided Printing: Long Edge" or
"Short Edge" in the print dialog. The printer prints one side of every
sheet first, then waits for you to put the stack back into the tray and
press OK on the printer.

The printer cannot do this by itself, so the filter builds the job the way
foo2zjs does: odd pages in order, a ZjStream PAUSE chunk, then even pages in
reverse order (rotated 180 degrees for long edge, plus a blank back side when
the page count is odd). The PPD turns this on with `*hpManualDuplex: "1"`.

## Repository layout

| Path                         | Contents                                          |
|------------------------------|---------------------------------------------------|
| `src/hpjbig.c`               | Open JBIG encoder replacing HP's plugin function   |
| `patches/*.patch`            | Patches to HPLIP 3.26.6, applied by `build.sh`    |
| `patches/ppd/*.patch`        | Patches to the M1132 PPD (adds Duplex option)     |
| `scanner/m1132-escl.swift`   | eSCL scanner service (USB scan protocol)          |
| `scripts/build.sh`           | Reproducible build from the tarballs              |
| `scripts/install-queue.sh`   | Installs `build/out` via `release/install.sh`     |
| `scripts/make-pkg.sh`        | Builds the Installer package from `release/`      |
| `release/`                   | Prebuilt `hpcups`, `m1132-escl`, PPD, `install.sh`|

HPLIP patches:

- `0001` - `genJPEGStrips.cpp`: drop the Linux-only `<malloc.h>`.
- `0002` - `Makefile.am` / `Makefile.in`: honor
  `--disable-imageProcessor-build` (upstream still linked HP's closed x86
  `libImageProcessor`).
- `0003` - `ModeJbig.cpp`: with `HPCUPS_BUILTIN_JBIG`, use the built-in
  encoder instead of loading the plugin.
- `0004` - ZjStream manual duplex (`LJZjStream`, `HPCupsFilter`), enabled by
  the `hpManualDuplex` PPD attribute.
- `ppd/m1132-manual-duplex.patch` - adds the Duplex option and
  `hpManualDuplex` to the M1132 PPD.

## Known limits

- NAPS2's ESCL auto-discovery may not list the scanner (it uses its own mDNS
  client); Manual IP always works. Image Capture and NAPS2's Apple driver
  are not tested yet. 1200 dpi is not offered (untested on the device).
  Brightness and contrast settings are ignored.
- CUPS reports PPD printer drivers as deprecated. If a future macOS drops
  them, the same code can be wrapped in a PAPPL printer application.

## License and copyrights

This repository is distributed under the GNU General Public License, version 2
or (at your option) any later version - see `LICENSE`. The GPL applies
because the built filter links JBIG-KIT.

The code built here comes from these projects; all rights belong to their
owners:

- **HPLIP** (hpcups, ZjStream encoder, PPD, `hpjbig_wrapper.h`) -
  Copyright (c) 2001-2015 HP Development Company, L.P.;
  Copyright (c) 1996-2015 HP Co. hpcups sources are under a BSD-style
  license, other parts under the GPL. https://developers.hp.com/hp-linux-imaging-and-printing
- **JBIG-KIT** (JBIG encoder) - Copyright 1995-2014 Markus Kuhn,
  GPL-2.0-or-later. https://www.cl.cam.ac.uk/~mgk25/jbigkit/
- **foo2zjs** - Rick Richardson. Used only as the reference for the ZjStream
  JBIG parameters; no foo2zjs code is included.
- **m1132-scan** - Filip Tarcala, MIT. Its `PROTOCOL.md` (the M1132 USB scan
  protocol, worked out from HP's macOS driver) is the reference for
  `scanner/m1132-escl.swift`; no m1132-scan code is included.
  https://github.com/F1f0mp4/m1132-scan

HP, LaserJet and HPLIP are trademarks of HP Development Company, L.P. This
project is not affiliated with or endorsed by HP. HP's own macOS driver and
its scanner plugin are proprietary and are not part of this repository.
