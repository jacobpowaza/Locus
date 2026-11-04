#!/usr/bin/env bash
# macOS only. Builds an UNSIGNED Release IPA for physical iPhones. Sideloaders
# (SideStore, AltStore, Sideloadly, Feather, LiveContainer) re-sign it with
# your own Apple ID, so no developer certificate is needed here.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${OUT:-outputs}"
DERIVED="${DERIVED:-build/DerivedData-device}"
mkdir -p "$OUT"
[ -d Locus.xcodeproj ] || xcodegen generate

xcodebuild -project Locus.xcodeproj -scheme Locus -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build > "$OUT/xcodebuild-device.log" 2>&1 || { tail -80 "$OUT/xcodebuild-device.log"; exit 1; }

STAGE=$(mktemp -d)
mkdir -p "$STAGE/Payload"
cp -R "$DERIVED/Build/Products/Release-iphoneos/Locus.app" "$STAGE/Payload/"
(cd "$STAGE" && zip -qry Locus-unsigned.ipa Payload)
mv "$STAGE/Locus-unsigned.ipa" "$OUT/"
rm -rf "$STAGE"
echo "Wrote $OUT/Locus-unsigned.ipa"
