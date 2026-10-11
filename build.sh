#!/bin/zsh
# Builds NotchHide.app (menubar-only, no Dock icon).
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/NotchHide.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/NotchHide "$APP/Contents/MacOS/"
mkdir -p "$APP/Contents/Resources"
cp icons/statusIcon.png icons/statusIcon@2x.png "$APP/Contents/Resources/"

# App icon: build .icns from icons/appicon.png
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz icons/appicon.png --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  sips -z $((sz*2)) $((sz*2)) icons/appicon.png --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.drtaru.notchhide</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>NotchHide</string>
<key>CFBundleExecutable</key><string>NotchHide</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${VERSION:-1.0}</string>
<key>CFBundleVersion</key><string>${VERSION:-1.0}</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
xattr -cr "$APP"
# SIGN_IDENTITY unset or "-": ad-hoc (local use). Otherwise Developer ID with hardened runtime + timestamp, as notarization requires.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
fi
echo "Built $APP"
