#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

VERSION_FILE="$PROJECT_DIR/version.env"
if [[ ! -f "$VERSION_FILE" ]]; then
    echo "Error: $VERSION_FILE not found" >&2
    exit 1
fi
source "$VERSION_FILE"
if [[ -z "${MARKETING_VERSION:-}" || -z "${BUILD_NUMBER:-}" ]]; then
    echo "Error: MARKETING_VERSION and BUILD_NUMBER must be set in $VERSION_FILE" >&2
    exit 1
fi
VERSION="$MARKETING_VERSION"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/TrinityBar.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SWIFT_FILES=(Sources/TrinityBar/**/*.swift(N))

if (( ${#SWIFT_FILES[@]} == 0 )); then
    echo "Error: No Swift source files found under Sources/TrinityBar" >&2
    exit 1
fi

echo "Compiling TrinityBar v$VERSION (${#SWIFT_FILES[@]} files, arm64 release, macOS 26+ Liquid Glass target)..."
swiftc -Osize -whole-module-optimization -parse-as-library \
    -strict-concurrency=complete -warnings-as-errors \
    -Xlinker -dead_strip \
    -target arm64-apple-macosx26.0 \
    -sdk "$SDK_PATH" \
    "${SWIFT_FILES[@]}" \
    -framework AppKit \
    -framework SwiftUI \
    -framework QuartzCore \
    -framework Network \
    -framework CoreWLAN \
    -framework CoreLocation \
    -framework SystemConfiguration \
    -framework IOKit \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework ServiceManagement \
    -o "$MACOS_DIR/TrinityBar"

chmod +x "$MACOS_DIR/TrinityBar"
strip -x "$MACOS_DIR/TrinityBar"

ICON_SRC="$PROJECT_DIR/Sources/TrinityBar/Resources/AppIcon.icns"
if [[ ! -f "$ICON_SRC" ]]; then
    echo "Generating compact AppIcon.icns..."
    swift "$PROJECT_DIR/scripts/generate_icon.swift"
fi
cp "$ICON_SRC" "$RESOURCES_DIR/AppIcon.icns"

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>TrinityBar</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.zechen.trinitybar</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>TrinityBar</string>
    <key>CFBundleDisplayName</key>
    <string>TrinityBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleGetInfoString</key>
    <string>TrinityBar $VERSION, Copyright © 2026 Zechen Wang.</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Zechen Wang. MIT License.</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>NSLocationUsageDescription</key>
    <string>TrinityBar uses Location Services only so macOS allows reading your Wi-Fi network name (SSID) and nearby Wi-Fi list.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>TrinityBar uses Location Services only so macOS allows reading your Wi-Fi network name (SSID) and nearby Wi-Fi list.</string>
</dict>
</plist>
EOF

touch "$APP_DIR"
plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1
codesign --verify --deep --strict "$APP_DIR"

echo "Packaged successfully at: $APP_DIR (v$VERSION, build $BUILD_NUMBER)"

if [[ "${1:-}" == "--release" ]]; then
    ARCHIVE_NAME="TrinityBar-v${VERSION}-macos-arm64.zip"
    ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"
    rm -f "$DIST_DIR"/TrinityBar-v*-macos-arm64.zip "$DIST_DIR"/TrinityBar-v*-macos-arm64.zip.sha256
    ditto -c -k --keepParent "$APP_DIR" "$ARCHIVE_PATH"
    (cd "$DIST_DIR" && shasum -a 256 "$ARCHIVE_NAME" > "${ARCHIVE_NAME}.sha256")
    (cd "$DIST_DIR" && shasum -a 256 -c "${ARCHIVE_NAME}.sha256" >/dev/null)
    echo "Release archive created at: $ARCHIVE_PATH"
fi
