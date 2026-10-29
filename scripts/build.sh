#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build a native arm64 hpcups CUPS filter for the HP LaserJet Pro M1132 MFP.
# Inputs:  vendor/hplip-3.26.6.tar.gz, vendor/jbigkit-2.1.tar.gz, patches/, src/
# Output:  build/out/hpcups, build/out/m1132-escl,
#          build/out/hp-laserjet_professional_m1132_mfp.ppd
# Needs:   Xcode CLT; MacPorts libjpeg (linked statically).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HPLIP=hplip-3.26.6
JBIGKIT=jbigkit-2.1
HPLIP_SHA256=5fb2235a9cb6ec07cb4786c4066b151359c301324d54aaabf69ae7eef35606b3
JBIGKIT_SHA256=de7106b6bfaf495d6865c7dd7ac6ca1381bd12e0d81405ea81e7f2167263d932
JPEG_PREFIX=${JPEG_PREFIX:-/opt/local}

B=$ROOT/build
SRC=$B/src
DEPS=$B/deps
OUT=$B/out

check_sha() {
    echo "$2  $1" | shasum -a 256 -c - >/dev/null || { echo "checksum mismatch: $1" >&2; exit 1; }
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

# Static deps so the filter links only against system libraries.
J=$SRC/$JBIGKIT/libjbig
clang -O2 -c -I"$J" -I"$SRC/$HPLIP/prnt/hpcups" \
    "$J/jbig.c" "$J/jbig_ar.c" "$ROOT/src/hpjbig.c"
mv jbig.o jbig_ar.o hpjbig.o "$DEPS/"
ar rcs "$DEPS/lib/libhpjbig.a" "$DEPS"/*.o
ln -sf "$JPEG_PREFIX/lib/libjpeg.a" "$DEPS/lib/libjpeg.a"

cd "$SRC/$HPLIP"
./configure --prefix="$B/root" \
    --enable-hpcups-only-build --disable-imageProcessor-build \
    --disable-network-build --disable-scan-build --disable-gui-build \
    --disable-fax-build --disable-dbus-build --disable-doc-build --disable-qt4 \
    --disable-hpps-install --disable-cups-drv-install --enable-cups-ppd-install \
    CPPFLAGS="-I$JPEG_PREFIX/include -DHPCUPS_BUILTIN_JBIG" \
    LDFLAGS="-L$DEPS/lib" LIBS="-lhpjbig" > "$B/configure.log" 2>&1
make -j"$(sysctl -n hw.ncpu)" hpcups > "$B/make.log" 2>&1

cp hpcups "$OUT/"

# Take the PPD as shipped in the tarball: make regenerates ppd/hpcups/*.
PPD=hp-laserjet_professional_m1132_mfp.ppd
tar -xzOf "$ROOT/vendor/$HPLIP.tar.gz" "$HPLIP/ppd/hpcups/$PPD.gz" | gunzip > "$OUT/$PPD"
for p in "$ROOT"/patches/ppd/*.patch; do
    patch -s "$OUT/$PPD" < "$p"
done
# Scanner service (eSCL), Apple frameworks only.
swiftc -O -framework IOUSBHost -o "$OUT/m1132-escl" "$ROOT/scanner/m1132-escl.swift"

file "$OUT/hpcups" "$OUT/m1132-escl"
otool -L "$OUT/hpcups"
