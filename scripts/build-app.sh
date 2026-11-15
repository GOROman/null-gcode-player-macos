#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
native_bin_dir=$(swift build -c release --show-bin-path)
native_app="$PWD/build/NULL G-Code Player.app"
mkdir -p "$native_app/Contents/MacOS" "$native_app/Contents/Resources"
cp "$native_bin_dir/NullGCodePlayer" "$native_app/Contents/MacOS/NullGCodePlayer"
for native_bundle in "$native_bin_dir"/*.bundle; do
  if [ -d "$native_bundle" ]; then cp -R "$native_bundle" "$native_app/Contents/Resources/"; fi
done
cat > "$native_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>NULL G-Code Player</string>
<key>CFBundleDisplayName</key><string>NULL G-Code Player</string>
<key>CFBundleIdentifier</key><string>com.goroman.null-gcode-player-macos</string>
<key>CFBundleExecutable</key><string>NullGCodePlayer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.10</string>
<key>CFBundleVersion</key><string>10</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>Bambu Studio G-Code</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSItemContentTypes</key><array><string>public.data</string></array><key>CFBundleTypeExtensions</key><array><string>gcode</string><string>gco</string><string>gc</string><string>3mf</string><string>zip</string></array></dict></array>
</dict></plist>
PLIST
codesign --force --deep --sign - "$native_app"
printf '\nBuilt: %s\n' "$native_app"
