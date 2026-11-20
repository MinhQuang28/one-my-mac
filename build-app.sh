#!/bin/bash
# Build OneMac and assemble build/OneMac.app (signed with the stable local identity).
#   ./build-app.sh            build + bundle
#   ./build-app.sh --install  also replace /Applications/OneMac.app and relaunch it
set -euo pipefail
cd "$(dirname "$0")"

if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
SWIFT="$(xcrun --find swift 2>/dev/null || which swift)"

APP_NAME="OneMac"
BUNDLE_ID="com.onemac.app"
VERSION="$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' Sources/OneMac/PanelView.swift)"
[ -n "$VERSION" ] || { echo "Error: could not read AppInfo.version"; exit 1; }
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || date +%Y%m%d%H%M)"
OUT="build/${APP_NAME}.app"

echo "==> swift build -c release"
"$SWIFT" build -c release --product OneMac
"$SWIFT" build -c release --product onemac-fan
BIN_DIR="$("$SWIFT" build -c release --show-bin-path)"

echo "==> assembling ${OUT}"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN_DIR/OneMac" "$OUT/Contents/MacOS/OneMac"
cp "$BIN_DIR/onemac-fan" "$OUT/Contents/MacOS/onemac-fan"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}.${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSDownloadsFolderUsageDescription</key><string>OneMac saves HiDPI recovery packages and diagnostics reports to the Downloads folder.</string>
    <key>NSAppleEventsUsageDescription</key><string>OneMac asks System Events to restart the Mac to apply a HiDPI configuration, and runs the fan helper installer with administrator rights.</string>
    <key>NSHumanReadableCopyright</key><string>OneMac · PolyForm Noncommercial 1.0.0</string>
</dict>
</plist>
PLIST

# The permission prompts in Vietnamese for a Vietnamese system; Info.plist carries the English ones.
mkdir -p "$OUT/Contents/Resources/en.lproj" "$OUT/Contents/Resources/vi.lproj"
: > "$OUT/Contents/Resources/en.lproj/InfoPlist.strings"
cat > "$OUT/Contents/Resources/vi.lproj/InfoPlist.strings" <<'STRINGS'
"NSDownloadsFolderUsageDescription" = "OneMac lưu gói khôi phục HiDPI và báo cáo chẩn đoán vào thư mục Tải về.";
"NSAppleEventsUsageDescription" = "OneMac nhờ System Events khởi động lại máy để áp dụng cấu hình HiDPI, và chạy lệnh cài helper quạt với quyền quản trị.";
STRINGS

ENTITLEMENTS="build/${APP_NAME}.entitlements"
cat > "$ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key><true/>
</dict>
</plist>
PLIST

# A stable identity keeps Accessibility permission across rebuilds (run tools/setup-signing-cert.sh once).
# "HiDisplay Local Signing" first: its key already allows codesign without a Keychain prompt.
SIGN_NAME="${ONEMAC_SIGN_IDENTITY:-}"
if [ -z "$SIGN_NAME" ]; then
    for candidate in "HiDisplay Local Signing" "OneMac Local Signing"; do
        if security find-identity -p codesigning 2>/dev/null | grep -q "\"$candidate\""; then
            SIGN_NAME="$candidate"; break
        fi
    done
fi
SIGN_HASH=""
[ -n "$SIGN_NAME" ] && SIGN_HASH="$(security find-identity -p codesigning 2>/dev/null \
    | awk -v n="\"$SIGN_NAME\"" 'index($0, n) {print $2; exit}' || true)"
echo "==> signing identity: ${SIGN_NAME:-ad-hoc}"
SIGN="${SIGN_HASH:--}"
[ "$SIGN" = "-" ] && echo "==> WARNING: ad-hoc signing; Accessibility must be re-granted after every build"
codesign --force --sign "$SIGN" --options runtime --timestamp=none "$OUT/Contents/MacOS/onemac-fan"
codesign --force --sign "$SIGN" --options runtime --timestamp=none --entitlements "$ENTITLEMENTS" "$OUT"
codesign --verify --strict "$OUT"
echo "==> built $(pwd)/${OUT}"

if [ "${1:-}" = "--install" ]; then
    echo "==> installing to /Applications"
    # Quit normally so fans return to System and dimming is cleared before the binary is replaced.
    osascript -e 'tell application id "com.onemac.app" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do pgrep -xq OneMac || break; sleep 0.25; done
    pkill -x OneMac 2>/dev/null || true
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$OUT" "/Applications/${APP_NAME}.app"
    open "/Applications/${APP_NAME}.app"
    echo "==> launched /Applications/${APP_NAME}.app"
fi
