#!/bin/zsh
# Creates a fake home folder for trying every delete button safely.
#   scripts/make-test-home.sh /some/empty/folder
#   open --env FREEMYMAC_HOME=/some/empty/folder dist/FreeMyMac.app
# With FREEMYMAC_HOME set, FreeMyMac scans and cleans only that folder.
set -euo pipefail
H="${1:?usage: make-test-home.sh <folder>}"
mkdir -p "$H"
mk() { mkdir -p "$H/$(dirname "$1")"; mkfile -n "$2" "$H/$1"; dd if=/dev/zero of="$H/$1" bs=1m count="${2%m}" status=none; }

mk "Library/Caches/com.vendor.editor/blob.bin" 40m
mk "Library/Caches/com.vendor.chat/blob.bin" 25m
mk "Library/Caches/com.apple.Safari/keep.bin" 5m
mk "Library/Caches/Firefox/profile/cache.bin" 30m
mk "Library/Logs/VendorApp/run.log" 3m
mk "Library/Application Support/Chatty/Cache/data.bin" 15m
touch "$H/Library/Application Support/Chatty/Local State"
mk "Library/Application Support/Chatty/IndexedDB/messages.bin" 6m
mk ".npm/_cacache/content.bin" 35m
mk "go/pkg/mod/example.com/lib@v1/file.bin" 12m
chmod 444 "$H/go/pkg/mod/example.com/lib@v1/file.bin"
chmod 555 "$H/go/pkg/mod/example.com/lib@v1" "$H/go/pkg/mod/example.com"
mk ".cache/huggingface/model.bin" 60m

mk "Documents/thesis.bin" 8m
mk "Documents/old-site/node_modules/lib/index.bin" 45m
mk "Documents/old-site/package.json" 1m
touch -t 202401010000 "$H/Documents/old-site/package.json"
mk "Downloads/Setup.dmg" 110m
mk "Downloads/keep-this.pdf" 2m
mk "Movies/holiday.mov" 150m
mk ".Trash/forgotten.zip" 20m
mk "Library/Keychains/login.keychain-db" 1m

mkdir -p "$H/Applications/Sample.app/Contents/MacOS"
mk "Applications/Sample.app/Contents/MacOS/Sample" 18m
cat > "$H/Applications/Sample.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.vendor.sample</string>
<key>CFBundleName</key><string>Sample</string>
</dict></plist>
PLIST
mk "Library/Caches/com.vendor.sample/cache.bin" 4m
mk "Library/Preferences/com.vendor.sample.plist" 1m
echo "Test home ready: $H"
