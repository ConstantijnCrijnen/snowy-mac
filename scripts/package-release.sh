#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"
mode="${1:-}"
if [[ $# -gt 1 || ($# -eq 1 && "$mode" != "--skip-build" && "$mode" != "--notarize") ]]; then
  print -u2 "Usage: ./scripts/package-release.sh [--skip-build | --notarize]"
  exit 2
fi
if [[ "$mode" == "--notarize" ]]; then
  : "${SNOWY_CODESIGN_IDENTITY:?Set a Developer ID Application signing identity.}"
  : "${SNOWY_NOTARY_PROFILE:?Set the name of a notarytool Keychain profile.}"
  dmg_sign=(--sign "$SNOWY_CODESIGN_IDENTITY" --timestamp)
  notary_auth=(--keychain-profile "$SNOWY_NOTARY_PROFILE")
  if [[ -n "${SNOWY_CODESIGN_KEYCHAIN:-}" ]]; then
    dmg_sign+=(--keychain "$SNOWY_CODESIGN_KEYCHAIN")
    notary_auth+=(--keychain "$SNOWY_CODESIGN_KEYCHAIN")
  fi
  "$project_root/scripts/build-app.sh" --developer-id
elif [[ "$mode" != "--skip-build" ]]; then
  "$project_root/scripts/build-app.sh"
fi

app_dir="$project_root/build/Snowy.app"
binary="$app_dir/Contents/MacOS/Snowy"
if [[ -L "$project_root/build" || -L "$app_dir" || ! -d "$app_dir" || ! -f "$binary" ]]; then
  print -u2 "Missing build/Snowy.app. Run ./scripts/build-app.sh first."
  exit 1
fi
if [[ "$(plutil -extract CFBundleIdentifier raw "$app_dir/Contents/Info.plist" 2>/dev/null || true)" != "app.snowy.desktop" ]]; then
  print -u2 "Refusing to package a bundle not identified as Snowy."
  exit 1
fi
codesign --verify --deep --strict "$app_dir"
architectures="$(lipo -archs "$binary")"
case "$architectures" in
  arm64) architecture="arm64" ;;
  x86_64) architecture="x86_64" ;;
  "arm64 x86_64"|"x86_64 arm64") architecture="universal" ;;
  *) print -u2 "Unsupported release architecture: $architectures"; exit 1 ;;
esac

release_dir="$project_root/build/releases"
if [[ -L "$project_root/build" || -L "$release_dir" ]]; then
  print -u2 "Refusing a redirected build/releases directory."
  exit 1
fi
mkdir -p "$release_dir"
staging_dir="$(mktemp -d "$release_dir/.Snowy-package.XXXXXX")"
mounted=0
function cleanup() {
  if [[ "$mounted" == 1 ]]; then
    hdiutil detach "$staging_dir/mount" -quiet || return 1
  fi
  rm -rf "$staging_dir"
}
trap cleanup EXIT
archive_name="Snowy-macOS-$architecture.zip"
dmg_name="Snowy-macOS-$architecture.dmg"
for filename in "$archive_name" "$dmg_name" "$archive_name.sha256" "$dmg_name.sha256"; do
  if [[ -L "$release_dir/$filename" || -d "$release_dir/$filename" ]]; then
    print -u2 "Refusing to replace a redirected release file: $filename"
    exit 1
  fi
done

function notarize_and_staple() {
  local submission="$1" target="$2" result="$staging_dir/notary-result.plist"
  if ! xcrun notarytool submit "$submission" "${notary_auth[@]}" \
      --wait --timeout 30m --output-format plist > "$result" \
      || [[ "$(plutil -extract status raw "$result" 2>/dev/null || true)" != "Accepted" ]]; then
    local submission_id
    submission_id="$(plutil -extract id raw "$result" 2>/dev/null || true)"
    print -u2 "Apple did not accept the notarization submission for ${submission:t}."
    if [[ -n "$submission_id" ]]; then
      print -u2 "See notarytool log for submission $submission_id."
    fi
    return 1
  fi
  xcrun stapler staple "$target"
  xcrun stapler validate "$target"
}

if [[ "$mode" == "--notarize" ]]; then
  # Notarize the app through a temporary ZIP. Only the extracted .app can carry
  # a ticket, so the release ZIP is made from the stapled app below.
  mkdir "$staging_dir/signed"
  ditto "$app_dir" "$staging_dir/signed/Snowy.app"
  app_dir="$staging_dir/signed/Snowy.app"
  ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$staging_dir/notary-upload.zip"
  notarize_and_staple "$staging_dir/notary-upload.zip" "$app_dir"
fi

# The ZIP is the Sparkle update archive and an alternative to the DMG.
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$staging_dir/$archive_name"
mkdir "$staging_dir/verify"
ditto -x -k "$staging_dir/$archive_name" "$staging_dir/verify"
codesign --verify --deep --strict "$staging_dir/verify/Snowy.app"
if [[ "$mode" == "--notarize" ]]; then
  xcrun stapler validate "$staging_dir/verify/Snowy.app"
  syspolicy_check distribution "$staging_dir/verify/Snowy.app"
fi

# Prepare the Finder view directly on an owned writable staging image. This
# captures its real volume/file IDs, without asking Finder to open anything.
python3 -m venv "$staging_dir/tools"
layout_python="$staging_dir/tools/bin/python"
"$layout_python" -m pip install --quiet --disable-pip-version-check \
  --only-binary=:all: --require-hashes -r "$project_root/scripts/dmg-layout-requirements.txt"
mkdir -p "$staging_dir/image/.background" "$staging_dir/art" "$staging_dir/mount"
swift "$project_root/scripts/render-install-art.swift" background "$staging_dir/art"
tiffutil -cathidpicheck "$staging_dir/art/Snowy.png" "$staging_dir/art/Snowy@2x.png" \
  -out "$staging_dir/image/.background/Snowy.tiff"
ditto "$app_dir" "$staging_dir/image/Snowy.app"
ln -s /Applications "$staging_dir/image/Applications"
cp "$app_dir/Contents/Resources/Snowy.icns" "$staging_dir/image/.VolumeIcon.icns"
hdiutil create -quiet -volname Snowy -fs HFS+ -format UDRW \
  -srcfolder "$staging_dir/image" "$staging_dir/writable.dmg"
hdiutil attach -quiet -readwrite -nobrowse -noautoopen -owners off \
  -mountpoint "$staging_dir/mount" "$staging_dir/writable.dmg"
mounted=1
"$layout_python" "$project_root/scripts/dmg-layout.py" write "$staging_dir/mount"
/usr/bin/SetFile -a C "$staging_dir/mount"
hdiutil detach -quiet "$staging_dir/mount"
mounted=0
hdiutil convert -quiet "$staging_dir/writable.dmg" -format UDZO \
  -o "$staging_dir/$dmg_name"
if [[ "$mode" == "--notarize" ]]; then
  codesign "${dmg_sign[@]}" "$staging_dir/$dmg_name"
  notarize_and_staple "$staging_dir/$dmg_name" "$staging_dir/$dmg_name"
  codesign --verify --strict "$staging_dir/$dmg_name"
fi
hdiutil verify -quiet "$staging_dir/$dmg_name"
hdiutil attach -quiet -readonly -nobrowse -noautoopen \
  -mountpoint "$staging_dir/mount" "$staging_dir/$dmg_name"
mounted=1
"$layout_python" "$project_root/scripts/dmg-layout.py" verify "$staging_dir/mount"
codesign --verify --deep --strict "$staging_dir/mount/Snowy.app"
if [[ "$mode" == "--notarize" ]]; then
  xcrun stapler validate "$staging_dir/mount/Snowy.app"
fi
if [[ ! -L "$staging_dir/mount/Applications" || "$(readlink "$staging_dir/mount/Applications")" != /Applications ]]; then
  print -u2 "The disk image is missing its Applications shortcut."
  exit 1
fi
test -f "$staging_dir/mount/.VolumeIcon.icns"
hdiutil detach -quiet "$staging_dir/mount"
mounted=0
(
  cd "$staging_dir"
  shasum -a 256 "$dmg_name" > "$dmg_name.sha256"
  shasum -a 256 "$archive_name" > "$archive_name.sha256"
)
for filename in "$dmg_name" "$archive_name" "$dmg_name.sha256" "$archive_name.sha256"; do
  mv -f "$staging_dir/$filename" "$release_dir/$filename"
  print "Packaged $release_dir/$filename"
done
