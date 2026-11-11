#!/bin/zsh
# Builds Prisme and creates Prisme.app in the current folder.
set -e
cd "$(dirname "$0")"
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
[ -d "$SDK" ] && export SDKROOT="$SDK"   # SwiftUI macros need full Xcode on newer SDKs
swift build -c release
APP="Prisme.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Prisme "$APP/Contents/MacOS/Prisme"
[ -f Resources/AppIcon.icns ] || swift Resources/make-icon.swift Resources
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Prisme</string>
  <key>CFBundleDisplayName</key><string>Prisme</string>
  <key>CFBundleIdentifier</key><string>local.prisme</string>
  <key>CFBundleExecutable</key><string>Prisme</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.3.0</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Robert Buys — MIT License</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>UTExportedTypeDeclarations</key>
  <array><dict>
    <key>UTTypeIdentifier</key><string>local.prisme.report</string>
    <key>UTTypeDescription</key><string>Rapport Prisme</string>
    <key>UTTypeConformsTo</key><array><string>public.json</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>prisme</string></array></dict>
  </dict></array>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "✅ $APP ready"
