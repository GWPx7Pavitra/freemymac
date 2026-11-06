#!/bin/zsh
# Builds FreeMyMac.app in this folder. Needs only Apple's Command Line Tools.
#   ./build.sh            build dist/FreeMyMac.app
#   ./build.sh --install  also copy it to ~/Applications
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/FreeMyMac.app"
ICON_TMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TMP"' EXIT

swift build -c release --product FreeMyMac

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/FreeMyMac" "$APP/Contents/MacOS/FreeMyMac"
# Debug symbols record this machine's folder paths, which shouldn't ship.
strip -S -x "$APP/Contents/MacOS/FreeMyMac"

# The icon only needs drawing once per size. retina sizes come from the same script.
SET="$ICON_TMP/FreeMyMac.iconset"
mkdir -p "$SET"
swiftc -O scripts/make-icon.swift -o "$ICON_TMP/make-icon" 2>/dev/null
for pair in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x 256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do
  "$ICON_TMP/make-icon" "${pair%%:*}" "$SET/icon_${pair##*:}.png"
done
iconutil -c icns "$SET" -o "$APP/Contents/Resources/FreeMyMac.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>FreeMyMac</string>
  <key>CFBundleDisplayName</key><string>FreeMyMac</string>
  <key>CFBundleIdentifier</key><string>com.pavitra.freemymac</string>
  <key>CFBundleExecutable</key><string>FreeMyMac</string>
  <key>CFBundleIconFile</key><string>FreeMyMac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $PWD/$APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/FreeMyMac.app"
  cp -R "$APP" "$HOME/Applications/FreeMyMac.app"
  echo "Installed $HOME/Applications/FreeMyMac.app"
fi
