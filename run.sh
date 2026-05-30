#!/usr/bin/env bash
# build + launch the Tubeless prototype.
#   ./run.sh          build (release) and launch
#   ./run.sh --debug  build debug (faster compile) and launch
#   ./run.sh --build  build + package only; print the .app path, don't launch
#   ./run.sh --clean  wipe build artifacts first
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

APP_NAME="Tubeless"
BUNDLE_ID="com.tubeless.audio"
CONFIG="release"
BUILD_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG="debug" ;;
    --build) BUILD_ONLY=1 ;;
    --clean) echo "› cleaning"; rm -rf .build "$APP_NAME.app" ;;
    *) echo "unknown arg: $arg"; exit 1 ;;
  esac
done

# --- dependency checks ---------------------------------------------------------
command -v swift >/dev/null || { echo "✗ swift not found (install Xcode Command Line Tools)"; exit 1; }

YTDLP="$(command -v yt-dlp || true)"
if [[ -z "$YTDLP" ]]; then
  echo "✗ yt-dlp not found. Install it:  brew install yt-dlp"
  exit 1
fi
echo "› yt-dlp: $YTDLP"
command -v ffmpeg >/dev/null || echo "  (note: ffmpeg not found — needed only for MP3 downloads)"

# --- app icon (generated once, reused after) -----------------------------------
ICNS="$ROOT/Resources/AppIcon.icns"
if [[ ! -f "$ICNS" ]]; then
  echo "› generating app icon"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  swift "$ROOT/Resources/make-icon.swift" "$ICONSET" >/dev/null
  iconutil -c icns "$ICONSET" -o "$ICNS"
  rm -rf "$ICONSET"
fi

# --- build ---------------------------------------------------------------------
echo "› building ($CONFIG)…"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
[[ -f "$BIN" ]] || { echo "✗ build produced no binary at $BIN"; exit 1; }

# --- assemble .app bundle ------------------------------------------------------
APP="$ROOT/$APP_NAME.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
echo "› packaging $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$BIN" "$MACOS/$APP_NAME"
cp "$ICNS" "$RES/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>0.1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# point the app at the detected yt-dlp unless the user has already chosen one
if ! defaults read "$BUNDLE_ID" ytdlpPath >/dev/null 2>&1; then
  defaults write "$BUNDLE_ID" ytdlpPath "$YTDLP"
fi

# ad-hoc sign so macOS lets the freshly-built bundle make network calls cleanly
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

# --- launch (or just report) ---------------------------------------------------
if [[ "$BUILD_ONLY" -eq 1 ]]; then
  echo "✓ built: $APP"
else
  echo "› launching $APP_NAME"
  open "$APP"
fi
