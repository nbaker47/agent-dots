#!/bin/sh
# Build Agent Dots and put it in /Applications:  sh build.sh
set -e
cd "$(dirname "$0")"
swift build -c release 2>&1 | tail -5
APP="build/Agent Dots.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/AgentDots "$APP/Contents/MacOS/AgentDots"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Agent Dots</string>
  <key>CFBundleIdentifier</key><string>com.nbaker.agent-dots</string>
  <key>CFBundleExecutable</key><string>AgentDots</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" 2>/dev/null
pkill -x AgentDots 2>/dev/null || true
rm -rf "/Applications/Agent Dots.app"
cp -R "$APP" /Applications/
echo "installed /Applications/Agent Dots.app"
