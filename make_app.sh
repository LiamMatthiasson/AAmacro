#!/bin/bash
# Builds AAMacro as a signed .app so macOS remembers its permissions across rebuilds.
# Usage: open Terminal, drag this file in, press Return.  (Or: bash ~/Desktop/AAMacro/make_app.sh)
set -e
cd "$(dirname "$0")"

BUNDLE_ID="com.matthiasson.aamacro"
APP="$HOME/Applications/AAMacro.app"

echo "▸ Building (release)…"
swift build -c release

echo "▸ Packaging $APP"
pkill -x AAMacro 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AAMacro "$APP/Contents/MacOS/AAMacro"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>AAMacro</string>
  <key>CFBundleDisplayName</key><string>AA Macro</string>
  <key>CFBundleExecutable</key><string>AAMacro</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# A real signing identity keeps permissions across rebuilds. Ad-hoc does not.
# Prefer a self-made "AAMacro Signing" certificate, else an Apple Development one.
# Sign by the certificate's SHA-1 ID (2nd column) — a self-made cert is "not trusted" for
# distribution, which doesn't matter here, but its name can't be used directly.
LINE=$(security find-identity -p codesigning | grep -m1 '"AAMacro Signing"' || true)
[ -z "$LINE" ] && LINE=$(security find-identity -v -p codesigning | grep -m1 "Apple Development" || true)
IDENTITY=$(echo "$LINE" | awk '{print $2}')
if [ -n "$IDENTITY" ]; then
  echo "▸ Signing with: $(echo "$LINE" | sed -E 's/^[^"]*"([^"]*)".*/\1/')  [$IDENTITY]"
  codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
  echo ""
  echo "⚠️  No signing certificate found — signing ad-hoc."
  echo "   PERMISSIONS WILL RESET ON EVERY REBUILD until you create one (30 seconds):"
  echo "   Keychain Access → menu Keychain Access → Certificate Assistant → Create a Certificate…"
  echo "     Name: AAMacro Signing   Identity Type: Self Signed Root   Certificate Type: Code Signing"
  echo ""
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi

touch "$APP"   # so Finder/Dock pick up the new icon
echo "▸ Launching"
open "$APP"
echo "✓ Done. First run: allow Screen Recording + Accessibility for 'AA Macro', then quit and reopen it."
