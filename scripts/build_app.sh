#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

VERSION="1.1.0"
BUILD_NUMBER="2"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/TrinityBar.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

echo "Compiling TrinityBar (arm64 release, macOS 26+ Liquid Glass target)..."
swiftc -Osize -whole-module-optimization -parse-as-library \
    -strict-concurrency=complete -warnings-as-errors \
    -Xlinker -dead_strip \
    -target arm64-apple-macosx26.0 \
    -sdk "$SDK_PATH" \
    Sources/TrinityBar/Models/AppSettings.swift \
    Sources/TrinityBar/Monitors/BatteryMonitor.swift \
    Sources/TrinityBar/Monitors/NetworkMonitor.swift \
    Sources/TrinityBar/Monitors/AudioVolumeMonitor.swift \
    Sources/TrinityBar/Monitors/CaffeinateManager.swift \
    Sources/TrinityBar/Monitors/SystemIconsManager.swift \
    Sources/TrinityBar/Views/TrinityEmblemView.swift \
    Sources/TrinityBar/Views/StatusFloatingPanel.swift \
    Sources/TrinityBar/Views/Components/SharedUIComponents.swift \
    Sources/TrinityBar/Views/Components/SummaryMetricSections.swift \
    Sources/TrinityBar/Views/Pages/BatteryDetailsPageView.swift \
    Sources/TrinityBar/Views/Pages/NetworkDetailsPageView.swift \
    Sources/TrinityBar/Views/Pages/SoundDetailsPageView.swift \
    Sources/TrinityBar/Views/PopoverDashboardView.swift \
    Sources/TrinityBar/TrinityBarApp.swift \
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
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocationUsageDescription</key>
    <string>TrinityBar uses Location Services only so macOS allows reading your Wi-Fi network name (SSID) and nearby Wi-Fi list.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>TrinityBar uses Location Services only so macOS allows reading your Wi-Fi network name (SSID) and nearby Wi-Fi list.</string>
</dict>
</plist>
EOF

touch "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "Packaged successfully at: $APP_DIR"

if [[ "${1:-}" == "--release" ]]; then
    ARCHIVE_NAME="TrinityBar-v${VERSION}-macos-arm64.zip"
    ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"
    rm -f "$ARCHIVE_PATH" "$ARCHIVE_PATH.sha256"
    ditto -c -k --keepParent "$APP_DIR" "$ARCHIVE_PATH"
    (cd "$DIST_DIR" && shasum -a 256 "$ARCHIVE_NAME" > "${ARCHIVE_NAME}.sha256")
    echo "Release archive created at: $ARCHIVE_PATH"
fi
