#!/bin/sh
# Builds bin/siriremoted and wraps it in an ad-hoc signed .app bundle.
# The bundle matters: TCC (Accessibility / Input Monitoring) keys off a stable
# code-signing identity, so a bare binary would re-prompt — and would attach the
# permission to whatever terminal launched it.
set -e
cd "$(dirname "$0")"

mkdir -p bin
swiftc -O src/*.swift -o bin/siriremoted

APP="SiriRemoted.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp bin/siriremoted "$APP/Contents/MacOS/siriremoted"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>siriremoted</string>
  <key>CFBundleIdentifier</key><string>com.jacky.siriremoted</string>
  <key>CFBundleName</key><string>SiriRemoted</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1
echo "built $APP  (and bin/siriremoted)"
