#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build --disable-sandbox
capture_bin="$(swift build --disable-sandbox --show-bin-path)"
capture_root="$(mktemp -d "${TMPDIR:-/tmp}/shipian-launch-capture.XXXXXX")"
trap 'rm -rf "$capture_root"' EXIT
capture_app="$capture_root/LaunchCapture.app"
mkdir -p "$capture_app/Contents/MacOS" "$capture_app/Contents/Resources"
notes_objects=()
if [[ -f "$capture_bin/NotesCore.o" ]]; then
    notes_objects+=("$capture_bin/NotesCore.o")
else
    while IFS= read -r object; do notes_objects+=("$object"); done < <(rg --files .build | rg 'NotesCore.build/.*\.swift.o$')
fi
notes_sources=()
for source in Sources/Tendedero/*.swift; do
    case "$source" in */main.swift|*/LaunchOptions.swift) continue;; esac
    notes_sources+=("$source")
done
swiftc -parse-as-library -module-name Tendedero -I "$capture_bin" -I "$capture_bin/Modules" \
    "${notes_objects[@]}" "${notes_sources[@]}" marketing/source/capture-native.swift \
    -o "$capture_app/Contents/MacOS/LaunchCapture"
cp -R 'build/shipian-release/拾片.app/Contents/Resources/.' "$capture_app/Contents/Resources/"
cat > "$capture_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.shipian.launch-capture</string>
<key>CFBundleExecutable</key><string>LaunchCapture</string>
<key>CFBundleName</key><string>拾片发布素材</string>
<key>CFBundleDisplayName</key><string>拾片发布素材</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
"$capture_app/Contents/MacOS/LaunchCapture" "$PWD/docs/media" "$capture_root/store"
