#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
CONFIG="${1:-debug}"
notes_app_name="${LINENOTES_APP_NAME:-LineNotes Dev}"
notes_bundle_id="${LINENOTES_BUNDLE_ID:-local.linenotes.dev}"
APP="build/$notes_app_name.app"
swift build -c "$CONFIG" --disable-sandbox
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Tendedero" "$APP/Contents/MacOS/LineNotes.next"
mv -f "$APP/Contents/MacOS/LineNotes.next" "$APP/Contents/MacOS/LineNotes"
cp Sources/Tendedero/Resources/NoteAtmosphere.png "$APP/Contents/Resources/NoteAtmosphere.png"
mkdir -p "$APP/Contents/Resources/LineControls"
cp Sources/Tendedero/Resources/LineControls/*.png "$APP/Contents/Resources/LineControls/"
for dir in Sources/Tendedero/Resources/*.lproj; do cp -R "$dir" "$APP/Contents/Resources/"; done
cp LICENSE "$APP/Contents/Resources/UPSTREAM-LICENSE.txt"
cp PHOSPHOR-LICENSE.txt "$APP/Contents/Resources/PHOSPHOR-LICENSE.txt"
if [[ "${LINENOTES_BRAND_ICONS:-0}" == "1" ]]; then
    python3 scripts/make-brand-icons.py --source Sources/Tendedero/Resources/Brand --output build/ShipianIcons
    cp build/ShipianIcons/ShipianLight.icns build/ShipianIcons/Assets.car "$APP/Contents/Resources/"
    cp build/ShipianIcons/ShipianIconLight.png build/ShipianIcons/ShipianIconDark.png "$APP/Contents/Resources/"
    rm -f "$APP/Contents/Resources/ShipianDark.icns" "$APP/Contents/Resources/ShipianSystemIconLight.png" "$APP/Contents/Resources/ShipianSystemIconDark.png"
else
    swift scripts/make-dev-icon.swift build/LineNotes.iconset
    iconutil -c icns build/LineNotes.iconset -o "$APP/Contents/Resources/LineNotes.icns"
fi
# Only our independently generated demonstration photos, never upstream artwork.
DEMO_ASSETS="Sources/Tendedero/Resources/Demo"
cp "$DEMO_ASSETS/gallery.png" "$APP/Contents/Resources/DemoGallery.png"
cp "$DEMO_ASSETS/architecture.png" "$APP/Contents/Resources/DemoArchitecture.png"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>LineNotes Dev</string>
<key>CFBundleDisplayName</key><string>LineNotes Dev</string>
<key>CFBundleIdentifier</key><string>local.linenotes.dev</string>
<key>CFBundleExecutable</key><string>LineNotes</string>
<key>CFBundleIconFile</key><string>LineNotes</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSDesktopFolderUsageDescription</key><string>在你启用截图监听后，访问你选择的截图目录。</string>
<key>NSDocumentsFolderUsageDescription</key><string>访问你选择的截图或附件目录。</string>
<key>NSDownloadsFolderUsageDescription</key><string>访问你主动选择的文件。</string>
</dict></plist>
PLIST
plutil -replace CFBundleName -string "$notes_app_name" "$APP/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "$notes_app_name" "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$notes_bundle_id" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "${LINENOTES_VERSION:-0.3.0}" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "${LINENOTES_BUILD:-3}" "$APP/Contents/Info.plist"
if [[ "${LINENOTES_BRAND_ICONS:-0}" == "1" ]]; then
    plutil -replace CFBundleIconFile -string ShipianLight "$APP/Contents/Info.plist"
    plutil -replace CFBundleIconName -string ShipianLight "$APP/Contents/Info.plist"
    python3 scripts/check-brand-icons.py "$APP"
fi
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP (local development, ad hoc signed)"
