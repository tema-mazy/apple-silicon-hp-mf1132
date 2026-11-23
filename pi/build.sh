#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build hpcups and the m1132-escl scanner service for 64-bit Raspberry Pi OS
# (Debian 12, aarch64). Run inside the Lima VM (pi/lima.yaml) or on the Pi.
# Inputs:  vendor/hplip-3.26.6.tar.gz, vendor/jbigkit-2.1.tar.gz, patches/,
#          src/hpjbig.c, pi/escl/; optional vendor/hplip-3.26.6-plugin.run
#          (HP's proprietary plugin, for the P1006 firmware only)
# Output:  pi/out/hpcups, pi/out/m1132-escl,
#          pi/out/hp-laserjet_professional_m1132_mfp.ppd,
#          pi/out/hp-laserjet_p1006.ppd, pi/out/hp_laserjet_p1006.fw.gz
# Needs:   build-essential libcups2-dev libcupsimage2-dev libjpeg62-turbo-dev
#          zlib1g-dev libusb-1.0-0-dev libmicrohttpd-dev libpng-dev pkg-config
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HPLIP=hplip-3.26.6
JBIGKIT=jbigkit-2.1
HPLIP_SHA256=5fb2235a9cb6ec07cb4786c4066b151359c301324d54aaabf69ae7eef35606b3
JBIGKIT_SHA256=de7106b6bfaf495d6865c7dd7ac6ca1381bd12e0d81405ea81e7f2167263d932
PLUGIN_SHA256=bb830712bfacc4567e8714522f1359a749df344786256c8513ededf3e9455325

[ "$(uname -s)" = Linux ] || { echo "run this inside the Linux VM (see pi/lima.yaml)" >&2; exit 1; }

# B= moves the work tree to guest-local disk if the shared mount is slow.
B=${B:-$ROOT/build/pi}
SRC=$B/src
DEPS=$B/deps
OUT=$ROOT/pi/out

check_sha() {
    echo "$2  $1" | sha256sum -c - >/dev/null || { echo "checksum mismatch: $1" >&2; exit 1; }
}

check_sha "$ROOT/vendor/$HPLIP.tar.gz" $HPLIP_SHA256
check_sha "$ROOT/vendor/$JBIGKIT.tar.gz" $JBIGKIT_SHA256

rm -rf "$SRC" "$DEPS" "$OUT"
mkdir -p "$SRC" "$DEPS/lib" "$OUT"
tar -xzf "$ROOT/vendor/$HPLIP.tar.gz" -C "$SRC"
tar -xzf "$ROOT/vendor/$JBIGKIT.tar.gz" -C "$SRC"

for p in "$ROOT"/patches/*.patch; do
    patch -d "$SRC/$HPLIP" -p1 -s < "$p"
done

# JBIG-KIT + src/hpjbig.c as a static library (replaces HP's closed lj.so).
J=$SRC/$JBIGKIT/libjbig
(cd "$DEPS" && gcc -O2 -c -I"$J" -I"$SRC/$HPLIP/prnt/hpcups" \
    "$J/jbig.c" "$J/jbig_ar.c" "$ROOT/src/hpjbig.c")
ar rcs "$DEPS/lib/libhpjbig.a" "$DEPS"/*.o

cd "$SRC/$HPLIP"
./configure --prefix="$B/root" \
    --enable-hpcups-only-build --disable-imageProcessor-build \
    --disable-network-build --disable-scan-build --disable-gui-build \
    --disable-fax-build --disable-dbus-build --disable-doc-build --disable-qt4 \
    --disable-hpps-install --disable-cups-drv-install --enable-cups-ppd-install \
    CPPFLAGS="-DHPCUPS_BUILTIN_JBIG" \
    LDFLAGS="-L$DEPS/lib" LIBS="-lhpjbig" > "$B/configure.log" 2>&1
make -j"$(nproc)" hpcups > "$B/make.log" 2>&1

cp hpcups "$OUT/"

# Take the PPD as shipped in the tarball: make regenerates ppd/hpcups/*.
PPD=hp-laserjet_professional_m1132_mfp.ppd
tar -xzOf "$ROOT/vendor/$HPLIP.tar.gz" "$HPLIP/ppd/hpcups/$PPD.gz" | gunzip > "$OUT/$PPD"
for p in "$ROOT"/patches/ppd/*.patch; do
    patch -s "$OUT/$PPD" < "$p"
done

# HP LaserJet P1006: same hpcups binary (ZxStream encoder), stock PPD.
PPD=hp-laserjet_p1006.ppd
tar -xzOf "$ROOT/vendor/$HPLIP.tar.gz" "$HPLIP/ppd/hpcups/$PPD.gz" | gunzip > "$OUT/$PPD"

# The P1006 also needs HP's firmware at every power-on. It ships only in the
# proprietary plugin, a makeself archive; take the tar payload after the shell
# header instead of running the script.
PLUGIN=$ROOT/vendor/$HPLIP-plugin.run
FW=hp_laserjet_p1006.fw.gz
if [ -f "$PLUGIN" ]; then
    check_sha "$PLUGIN" $PLUGIN_SHA256
    n=$(LC_ALL=C sed -n 's/^offset=`head -n \([0-9]*\) .*/\1/p' "$PLUGIN" | head -n 1)
    [ -n "$n" ] || { echo "$PLUGIN: makeself header not recognised" >&2; exit 1; }
    tail -n +$((n + 1)) "$PLUGIN" > "$B/plugin.tar"
    tar -xOf "$B/plugin.tar" --wildcards "*$FW" > "$OUT/$FW"
    gzip -t "$OUT/$FW"
    rm "$B/plugin.tar"
else
    echo "no $PLUGIN: building without the P1006 firmware" >&2
fi

# Scanner service (eSCL) on libusb/libjpeg/libmicrohttpd.
make -C "$ROOT/pi/escl" clean all > "$B/escl.log" 2>&1
cp "$ROOT/pi/escl/m1132-escl" "$OUT/"

strip "$OUT/hpcups" "$OUT/m1132-escl"
file "$OUT/hpcups" "$OUT/m1132-escl"
ldd "$OUT/hpcups"
ldd "$OUT/m1132-escl"
