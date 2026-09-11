#!/bin/bash
# Builds the release binary and assembles Qv2ray-mac.app
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Qv2ray-mac"
BUNDLE_ID="com.qv2ray.mac"
VERSION="3.0.0"

echo "==> Building release binary…"
swift build -c release
BIN=".build/release/Qv2rayMac"

APP="build/${APP_NAME}.app"
rm -rf "build"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

echo "==> Copying binary…"
cp "${BIN}" "${APP}/Contents/MacOS/${APP_NAME}"

echo "==> Generating app icon…"
ICONSET="build/AppIcon.iconset"
mkdir -p "${ICONSET}"
for SIZE in 16 32 128 256 512; do
    "${BIN}" --dump-appicon "${ICONSET}/icon_${SIZE}x${SIZE}.png" "${SIZE}" >/dev/null
    "${BIN}" --dump-appicon "${ICONSET}/icon_${SIZE}x${SIZE}@2x.png" "$((SIZE * 2))" >/dev/null
done
iconutil -c icns -o "${APP}/Contents/Resources/AppIcon.icns" "${ICONSET}"

echo "==> Writing Info.plist…"
cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>       <string>Qv2ray for Mac</string>
    <key>CFBundleIdentifier</key>        <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>           <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleExecutable</key>        <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
    <key>NSUserNotificationAlertStyle</key> <string>alert</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code signing…"
codesign --force --sign - "${APP}"

echo "==> Done: ${APP}"
echo "    Run it with:  open ${APP}"
