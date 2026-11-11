#!/bin/bash
# Builds the release binary and assembles Qv2ray-mac.app
#
# By default the Xray core (+ geoip/geosite) and tun2socks are downloaded from their GitHub
# releases (pinned versions, SHA-256 verified, cached in .build/vendor) and embedded in the
# app, so it works without Homebrew. BUNDLE_CORE=0 builds a slim app that relies on a
# system-installed core instead.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Qv2ray-mac"
BUNDLE_ID="com.qv2ray.mac"
VERSION="3.0.0"
BUNDLE_CORE="${BUNDLE_CORE:-1}"

XRAY_VERSION="v26.11.9"
XRAY_SHA256_arm64="233f0c66681cd0726f81a6b2b6ed6a5710869e312047b522e46ed53035bebd26"
XRAY_SHA256_x86_64="488963e676e06f5e48547f9dd38116aaca8de4234959b4272ae8f284e658dfd0"
TUN2SOCKS_VERSION="v2.7.0"
TUN2SOCKS_SHA256_arm64="7c5ebfe2ffb60ecf6e958cc5bbf3e06e74b8b33575ffbb4ba4f6f785a647f1ad"
TUN2SOCKS_SHA256_x86_64="6e654da8bab9ca1645862f0e251a69980e0966680713011feea7b1e5901b2a95"

# Download $1 to $2 (cached) and check its SHA-256 against $3.
fetch() {
    local url="$1" out="$2" sha="$3"
    if [ ! -f "${out}" ] || ! echo "${sha}  ${out}" | shasum -a 256 -c - >/dev/null 2>&1; then
        echo "    ↓ ${url}"
        curl -fsSL --retry 3 -o "${out}.part" "${url}"
        mv "${out}.part" "${out}"
    fi
    if ! echo "${sha}  ${out}" | shasum -a 256 -c - >/dev/null 2>&1; then
        echo "error: checksum mismatch for ${out}" >&2
        rm -f "${out}"
        exit 1
    fi
}

echo "==> Building release binary…"
swift build -c release
BIN=".build/release/Qv2rayMac"

APP="build/${APP_NAME}.app"
rm -rf "build"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

echo "==> Copying binary…"
cp "${BIN}" "${APP}/Contents/MacOS/${APP_NAME}"

if [ "${BUNDLE_CORE}" = "1" ]; then
    # Match the architecture of the app binary that was just built.
    ARCH="$(lipo -archs "${BIN}" | awk '{print $1}')"
    case "${ARCH}" in
        arm64)  XRAY_ASSET="Xray-macos-arm64-v8a.zip"; T2S_ASSET="tun2socks-darwin-arm64"
                XRAY_SHA="${XRAY_SHA256_arm64}"; T2S_SHA="${TUN2SOCKS_SHA256_arm64}" ;;
        x86_64) XRAY_ASSET="Xray-macos-64.zip"; T2S_ASSET="tun2socks-darwin-amd64"
                XRAY_SHA="${XRAY_SHA256_x86_64}"; T2S_SHA="${TUN2SOCKS_SHA256_x86_64}" ;;
        *) echo "error: unsupported architecture ${ARCH}" >&2; exit 1 ;;
    esac

    echo "==> Bundling Xray ${XRAY_VERSION} and tun2socks ${TUN2SOCKS_VERSION} (${ARCH})…"
    VENDOR=".build/vendor/${ARCH}"
    mkdir -p "${VENDOR}"
    fetch "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${XRAY_ASSET}" \
          "${VENDOR}/xray-${XRAY_VERSION}.zip" "${XRAY_SHA}"
    fetch "https://github.com/xjasonlyu/tun2socks/releases/download/${TUN2SOCKS_VERSION}/${T2S_ASSET}.zip" \
          "${VENDOR}/tun2socks-${TUN2SOCKS_VERSION}.zip" "${T2S_SHA}"

    STAGE="$(mktemp -d)"
    trap 'rm -rf "${STAGE}"' EXIT
    unzip -q -o "${VENDOR}/xray-${XRAY_VERSION}.zip" -d "${STAGE}/xray"
    unzip -q -o "${VENDOR}/tun2socks-${TUN2SOCKS_VERSION}.zip" -d "${STAGE}/tun2socks"

    # Executables live next to the app binary (where codesign expects nested code);
    # geodata and licenses go to Resources/core.
    CORE_RES="${APP}/Contents/Resources/core"
    mkdir -p "${CORE_RES}"
    install -m 755 "${STAGE}/xray/xray" "${APP}/Contents/MacOS/xray"
    install -m 755 "${STAGE}/tun2socks/${T2S_ASSET}" "${APP}/Contents/MacOS/tun2socks"
    install -m 644 "${STAGE}/xray/geoip.dat" "${STAGE}/xray/geosite.dat" "${CORE_RES}/"
    install -m 644 "${STAGE}/xray/LICENSE" "${CORE_RES}/LICENSE-Xray"
    curl -fsSL --retry 3 -o "${CORE_RES}/LICENSE-tun2socks" \
        "https://raw.githubusercontent.com/xjasonlyu/tun2socks/${TUN2SOCKS_VERSION}/LICENSE" \
        || echo "    (could not fetch tun2socks LICENSE; it is MIT-licensed)"
    printf 'xray %s\ntun2socks %s\n' "${XRAY_VERSION}" "${TUN2SOCKS_VERSION}" > "${CORE_RES}/VERSIONS"
fi

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
# Nested executables first, then the bundle itself.
for helper in "${APP}/Contents/MacOS/xray" "${APP}/Contents/MacOS/tun2socks"; do
    [ -f "${helper}" ] && codesign --force --sign - "${helper}"
done
codesign --force --sign - "${APP}"

echo "==> Done: ${APP}"
echo "    Run it with:  open ${APP}"
