#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build the (unsigned) macOS Installer package from release/.
#
#   scripts/make-pkg.sh
#
# Version is YY.MM-<short commit hash> of HEAD, the commit the release files
# were built from. Refuses to run with uncommitted changes outside release/.
# Set VERSION= to override.
# Output: release/HP-M1132-native-arm64-<version>.pkg
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REL=$ROOT/release
ID=com.github.tema-mazy.apple-silicon-hp-m1132
DEST=Library/Printers/apple-silicon-hp-m1132
WORK=$ROOT/build/pkg

if [ -z "${VERSION:-}" ]; then
    if [ -n "$(git -C "$ROOT" status --porcelain -- . ':!release')" ]; then
        echo "uncommitted changes outside release/ - commit first" >&2
        exit 1
    fi
    VERSION=$(date +%y.%m)-$(git -C "$ROOT" rev-parse --short HEAD)
fi
OUT=$REL/HP-M1132-native-arm64-$VERSION.pkg
echo "Version: $VERSION"

for f in hpcups install.sh hp-laserjet_professional_m1132_mfp.ppd; do
    [ -f "$REL/$f" ] || { echo "missing $REL/$f" >&2; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK/root/$DEST" "$WORK/scripts" "$WORK/res"
install -m 755 "$REL/hpcups" "$REL/install.sh" "$WORK/root/$DEST/"
install -m 644 "$REL/hp-laserjet_professional_m1132_mfp.ppd" "$WORK/root/$DEST/"

# Add the CUPS queue. Without a connected printer, keep the files and say how
# to add the queue later instead of failing the whole install.
cat > "$WORK/scripts/postinstall" <<POSTINSTALL
#!/bin/bash
"/$DEST/install.sh" "/$DEST" && exit 0
echo "HP M1132 queue not created. Connect the printer, then run:"
echo "  sudo /$DEST/install.sh"
exit 0
POSTINSTALL
chmod 755 "$WORK/scripts/postinstall"

pkgbuild --root "$WORK/root" --scripts "$WORK/scripts" \
    --identifier "$ID" --version "$VERSION" --install-location / \
    --ownership recommended "$WORK/driver.pkg"

# Installer.app wrapper: title, welcome text, GPL license page, arm64 only.
cp "$ROOT/LICENSE" "$WORK/res/LICENSE.txt"
cat > "$WORK/res/welcome.txt" <<WELCOME
Native Apple Silicon driver for the HP LaserJet Professional M1132 MFP.
Version $VERSION

No Rosetta 2 and no HP plugin are needed. The installer adds the print
filter to /$DEST and creates the printer queue
"HP LaserJet M1132 (native arm64)" for the USB-connected printer.
Existing printer queues are not changed.

Connect the printer and turn it on before you continue.
WELCOME

cat > "$WORK/distribution.xml" <<DIST
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>HP LaserJet M1132 native arm64 driver $VERSION</title>
    <welcome file="welcome.txt"/>
    <license file="LICENSE.txt"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
    <domains enable_localSystem="true"/>
    <choices-outline>
        <line choice="default"/>
    </choices-outline>
    <choice id="default">
        <pkg-ref id="$ID"/>
    </choice>
    <pkg-ref id="$ID" version="$VERSION" onConclusion="none">driver.pkg</pkg-ref>
</installer-gui-script>
DIST

rm -f "$REL"/HP-M1132-native-arm64*.pkg
productbuild --distribution "$WORK/distribution.xml" --resources "$WORK/res" \
    --package-path "$WORK" "$OUT"
pkgutil --payload-files "$WORK/driver.pkg"
