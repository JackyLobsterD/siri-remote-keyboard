#!/bin/sh
# Builds bin/siriremoted and wraps it in an ad-hoc signed .app bundle.
# The bundle matters: TCC (Accessibility / Input Monitoring) keys off a stable
# code-signing identity, so a bare binary would re-prompt — and would attach the
# permission to whatever terminal launched it.
set -e
cd "$(dirname "$0")"

mkdir -p bin
swiftc -O src/*.swift -o bin/siriremoted

APP="build/SiriRemoted.app"
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
  <key>NSLocalNetworkUsageDescription</key>
  <string>在同一 Wi-Fi 下的几台 Mac 之间转发遥控器按键。</string>
  <key>NSBonjourServices</key>
  <array><string>_siriremoted._tcp</string></array>
</dict>
</plist>
PLIST

# Prefer a stable signing identity. Ad-hoc signatures are identified by their
# cdhash, which changes on every build, so macOS treats each rebuild as a
# different app and silently drops its Accessibility / Input Monitoring grants.
IDENTITY="SiriRemoted Self-Signed"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1
  echo "signed with: $IDENTITY"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1
  echo "signed ad-hoc (no stable identity; permissions will reset on each rebuild)"
fi
echo "built $APP  (and bin/siriremoted)"

if [ "$1" = "install" ]; then
  pkill -f 'SiriRemoted.app' 2>/dev/null || true
  # Leaving a stale copy behind would keep its own TCC entry around.
  rm -rf /Applications/SiriRemoted.app
  cp -R "$APP" /Applications/
  echo "installed to /Applications/SiriRemoted.app"
fi
