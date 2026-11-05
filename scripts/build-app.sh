#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
if [[ $# -gt 1 || ($# -eq 1 && "$1" != "--developer-id") ]]; then
  print -u2 "Usage: ./scripts/build-app.sh [--developer-id]"
  exit 2
fi
if [[ $# -eq 1 ]]; then
  : "${SNOWY_CODESIGN_IDENTITY:?Set a Developer ID Application signing identity.}"
  release_sign=(--force --sign "$SNOWY_CODESIGN_IDENTITY" --options runtime --timestamp)
  if [[ -n "${SNOWY_CODESIGN_KEYCHAIN:-}" ]]; then
    release_sign+=(--keychain "$SNOWY_CODESIGN_KEYCHAIN")
  fi
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  print -u2 "Snowy builds on macOS with Xcode and its Metal toolchain."
  exit 1
fi
if [[ -L "$project_root/build" ]]; then
  print -u2 "Refusing a redirected build directory. Use a real build/ directory in this checkout."
  exit 1
fi
app_dir="$project_root/build/Snowy.app"
if [[ -e "$app_dir" || -L "$app_dir" ]]; then
  if [[ -L "$app_dir" || ! -d "$app_dir" || ! -f "$app_dir/Contents/Info.plist" ]] \
    || [[ "$(plutil -extract CFBundleIdentifier raw "$app_dir/Contents/Info.plist" 2>/dev/null || true)" != "app.snowy.desktop" ]]; then
    print -u2 "Refusing to replace a bundle not identified as Snowy in build/."
    exit 1
  fi
fi
swift build -c release --product Snowy
binary_dir="$(swift build -c release --show-bin-path)"
sparkle_artifact="$project_root/.build/artifacts/sparkle/Sparkle"
sparkle_framework="$sparkle_artifact/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -L "$sparkle_framework/Versions/Current" || ! -x "$sparkle_framework/Sparkle" || ! -f "$sparkle_artifact/LICENSE" ]]; then
  print -u2 "The pinned Sparkle framework is missing or incomplete. Resolve the Swift package dependencies and try again."
  exit 1
fi
mkdir -p "$project_root/build" "$project_root/.build/shaders"
staging_dir="$(mktemp -d "$project_root/build/.Snowy-build.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
staged_app="$staging_dir/Snowy.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources" "$staged_app/Contents/Frameworks"
staged_binary="$staged_app/Contents/MacOS/Snowy"
cp "$binary_dir/Snowy" "$staged_binary"
cp "$project_root/App/Info.plist" "$staged_app/Contents/Info.plist"
# Keep Sparkle's versioned symlinks and its signed updater helpers intact.
ditto "$sparkle_framework" "$staged_app/Contents/Frameworks/Sparkle.framework"
cp "$sparkle_artifact/LICENSE" "$staged_app/Contents/Resources/Sparkle-LICENSE.txt"
# SwiftPM can add developer-toolchain paths for its own build products.
runtime_paths="$(otool -l "$staged_binary" | awk '/cmd LC_RPATH$/ { getline; getline; sub(/^[[:space:]]*path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print }')"
while IFS= read -r runtime_path; do
  case "$runtime_path" in
    ''|/usr/lib/swift|@executable_path/../Frameworks) ;;
    *) install_name_tool -delete_rpath "$runtime_path" "$staged_binary" ;;
  esac
done <<< "$runtime_paths"
xcrun -sdk macosx metal -mmacosx-version-min=14.0 -c \
  "$project_root/Sources/Snowy/Shaders/Snow.metal" -o "$project_root/.build/shaders/Snow.air"
xcrun -sdk macosx metallib "$project_root/.build/shaders/Snow.air" \
  -o "$staged_app/Contents/Resources/Snow.metallib"
mkdir "$staging_dir/Snowy.iconset"
swift "$project_root/scripts/render-install-art.swift" icon "$staging_dir/Snowy.iconset"
iconutil -c icns "$staging_dir/Snowy.iconset" -o "$staged_app/Contents/Resources/Snowy.icns"
if [[ $# -eq 1 ]]; then
  framework="$staged_app/Contents/Frameworks/Sparkle.framework"
  sparkle_version="$framework/Versions/Current"
  # Follow Sparkle's inside-out signing order and preserve Downloader's entitlements.
  codesign "${release_sign[@]}" --preserve-metadata=entitlements "$sparkle_version/XPCServices/Downloader.xpc"
  for component in XPCServices/Installer.xpc Autoupdate Updater.app; do
    codesign "${release_sign[@]}" "$sparkle_version/$component"
  done
  codesign "${release_sign[@]}" "$framework"
  codesign "${release_sign[@]}" "$staged_app"
  codesign --verify --strict -R='anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$staged_app"
else
  codesign --force --sign - "$staged_app"
fi
codesign --verify --deep --strict "$staged_app"
# Replace only the generated bundle, after every build and signing step succeeds.
rm -rf "$app_dir"
mv "$staged_app" "$app_dir"
print "Built $app_dir"
