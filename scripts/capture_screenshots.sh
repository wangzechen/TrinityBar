#!/bin/zsh
# Regenerates the README screenshots in assets/ from a fresh build.
#
# Requires Screen Recording permission for the terminal app running this script
# (System Settings → Privacy & Security → Screen & System Audio Recording).
#
# What it does for each scene (summary, settings):
#   1. Launches dist/TrinityBar.app with TRINITYBAR_SCREENSHOT=<scene>, which replaces SSID / BSSID / IP /
#      router / DNS with neutral demo values and opens the panel on that scene by itself.
#   2. Waits for the app to report panel + menu bar geometry, then captures a region spanning the menu bar
#      slice above the emblem down to the bottom of the panel (cursor excluded).
#   3. Frames it as a rounded card via scripts/frame_screenshot.swift into assets/dashboard-<scene>.png.
# Any running TrinityBar is quit first (native icons are restored) and the installed copy is relaunched after.
#
# Usage: ./scripts/capture_screenshots.sh [--no-build]
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

APP_BIN="$PROJECT_DIR/dist/TrinityBar.app/Contents/MacOS/TrinityBar"
INSTALLED_APP="/Applications/TrinityBar.app"
ASSETS_DIR="$PROJECT_DIR/assets"
WORK_DIR="$(mktemp -d -t trinitybar-shots)"
SCENES=(summary settings)
SIDE_MARGIN=25   # pt left/right of the panel
BOTTOM_MARGIN=28 # pt below the panel
EMBLEM_PAD=4     # pt kept around the TrinityBar emblem when scrubbing the menu bar slice

WAS_RUNNING=0
cleanup() {
    rm -rf "$WORK_DIR"
    # Always hand the user's TrinityBar back, including after a failed scene.
    if (( WAS_RUNNING )) && [[ -d "$INSTALLED_APP" ]] && ! pgrep -x TrinityBar >/dev/null; then
        open "$INSTALLED_APP"
    fi
}
trap cleanup EXIT

# 0. Screen Recording permission probe (screencapture fails or returns a blank file without it)
if ! screencapture -x -R0,0,4,4 "$WORK_DIR/probe.png" 2>/dev/null || [[ ! -s "$WORK_DIR/probe.png" ]]; then
    echo "Error: this terminal lacks Screen Recording permission." >&2
    echo "Grant it in System Settings → Privacy & Security → Screen & System Audio Recording, then re-run." >&2
    exit 1
fi

if [[ "${1:-}" != "--no-build" ]]; then
    ./scripts/build_app.sh
fi

quit_trinitybar() {
    local pids
    pids=($(pgrep -x TrinityBar || true))
    (( ${#pids[@]} == 0 )) && return 0
    kill -TERM "${pids[@]}" 2>/dev/null || true
    for _ in {1..50}; do
        pgrep -x TrinityBar >/dev/null || return 0
        sleep 0.2
    done
    echo "Error: TrinityBar did not exit" >&2
    exit 1
}

json_num() { plutil -extract "$2" raw -o - "$1"; }

pgrep -x TrinityBar >/dev/null && WAS_RUNNING=1
quit_trinitybar
sleep 1 # let ControlCenter settle after restoring native icons

for scene in "${SCENES[@]}"; do
    info="$WORK_DIR/$scene.json"
    raw="$WORK_DIR/$scene-raw.png"
    echo "Capturing scene: $scene"

    TRINITYBAR_SCREENSHOT="$scene" TRINITYBAR_SCREENSHOT_INFO="$info" "$APP_BIN" >/dev/null 2>&1 &

    for _ in {1..150}; do # up to 30 s (app needs ~7 s, plus up to ~10 s of panel-present retries)
        [[ -s "$info" ]] && break
        sleep 0.2
    done
    if [[ ! -s "$info" ]]; then
        quit_trinitybar
        echo "Error: app never reported geometry for scene '$scene'" >&2
        exit 1
    fi

    scale=$(json_num "$info" scale)
    screen_top=$(json_num "$info" screenTop)
    px=$(json_num "$info" panel.x); py=$(json_num "$info" panel.y)
    pw=$(json_num "$info" panel.w); ph=$(json_num "$info" panel.h)
    bx=$(json_num "$info" button.x); bw=$(json_num "$info" button.w)

    # Region in top-left-origin global points: menu bar top -> panel bottom (+ margin), panel width (+ margins)
    x=$(( px - SIDE_MARGIN ))
    y=$(( screen_top ))
    w=$(( pw + 2 * SIDE_MARGIN ))
    h=$(( py + ph - screen_top + BOTTOM_MARGIN ))
    region=$(printf '%.0f,%.0f,%.0f,%.0f' $x $y $w $h)

    screencapture -x -o -R"$region" "$raw"
    quit_trinitybar

    # Keep only the TrinityBar emblem (+ EMBLEM_PAD) in the menu bar slice above the panel; scrub the rest.
    keep_x=$(( bx - EMBLEM_PAD - x ))
    keep_w=$(( bw + 2 * EMBLEM_PAD ))
    strip_h=$(( py - screen_top ))
    swift "$PROJECT_DIR/scripts/frame_screenshot.swift" "$raw" "$ASSETS_DIR/dashboard-$scene.png" "$scale" \
        "$keep_x" "$keep_w" "$strip_h"
    echo "  -> assets/dashboard-$scene.png ($(sips -g pixelWidth -g pixelHeight "$ASSETS_DIR/dashboard-$scene.png" | awk '/pixel/ {printf "%s ", $2}')px)"
    sleep 1
done

echo "Done. Review assets/ before committing: no real SSID/IP should appear (demo values: Home Wi-Fi / 192.168.1.20)."
