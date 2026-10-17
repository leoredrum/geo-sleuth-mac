#!/bin/zsh
# Builds GeoSleuth.app (SwiftPM binary + bundled geo-sleuth skill + icon).
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$PWD
# The skill itself comes from https://github.com/Oldcircle/geo-sleuth (MIT, (c) Oldcircle).
SKILL_SRC=${SKILL_SRC:-$ROOT/../geo-sleuth/skills/geo-sleuth}
APP=$ROOT/build/GeoSleuth.app

if [[ ! -f $SKILL_SRC/SKILL.md ]]; then
  echo "geo-sleuth skill not found at $SKILL_SRC; cloning…"
  git clone --depth 1 https://github.com/Oldcircle/geo-sleuth.git "$ROOT/../geo-sleuth"
fi

swift build -c release
BIN=$(swift build -c release --show-bin-path)/GeoSleuth

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GeoSleuth"
rsync -a --exclude '__pycache__' --exclude '.geo-cache' "$SKILL_SRC/" "$APP/Contents/Resources/geo-sleuth/"
UPSTREAM_LICENSE="$SKILL_SRC/../../LICENSE"
[[ -f $UPSTREAM_LICENSE ]] && cp "$UPSTREAM_LICENSE" "$APP/Contents/Resources/geo-sleuth-LICENSE"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"

# Icon
ICONSET=$ROOT/build/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
swiftc -O scripts/make_icon.swift -o build/make_icon
build/make_icon "$ROOT/build/icon_1024.png" 1024
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>GeoSleuth</string>
  <key>CFBundleDisplayName</key><string>GeoSleuth</string>
  <key>CFBundleIdentifier</key><string>local.geosleuth.mac</string>
  <key>CFBundleExecutable</key><string>GeoSleuth</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Image</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.image</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $APP"
