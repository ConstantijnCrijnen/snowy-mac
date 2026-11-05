#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
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
mkdir -p "$project_root/build" "$project_root/.build/shaders"
staging_dir="$(mktemp -d "$project_root/build/.Snowy-build.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
staged_app="$staging_dir/Snowy.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$binary_dir/Snowy" "$staged_app/Contents/MacOS/Snowy"
cp "$project_root/App/Info.plist" "$staged_app/Contents/Info.plist"
xcrun -sdk macosx metal -mmacosx-version-min=14.0 -c \
  "$project_root/Sources/Snowy/Shaders/Snow.metal" -o "$project_root/.build/shaders/Snow.air"
xcrun -sdk macosx metallib "$project_root/.build/shaders/Snow.air" \
  -o "$staged_app/Contents/Resources/Snow.metallib"
mkdir "$staging_dir/Snowy.iconset"
swift "$project_root/scripts/render-install-art.swift" icon "$staging_dir/Snowy.iconset"
iconutil -c icns "$staging_dir/Snowy.iconset" -o "$staged_app/Contents/Resources/Snowy.icns"
codesign --force --sign - "$staged_app"
codesign --verify --deep --strict "$staged_app"
# Replace only the generated bundle, after every build and signing step succeeds.
rm -rf "$app_dir"
mv "$staged_app" "$app_dir"
print "Built $app_dir"
