#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"
if [[ $# -gt 1 || ($# -eq 1 && "$1" != "--skip-build") ]]; then
  print -u2 "Usage: ./scripts/package-release.sh [--skip-build]"
  exit 2
fi
if [[ $# -eq 0 ]]; then
  "$project_root/scripts/build-app.sh"
fi

app_dir="$project_root/build/Snowy.app"
binary="$app_dir/Contents/MacOS/Snowy"
if [[ ! -f "$binary" ]]; then
  print -u2 "Missing build/Snowy.app. Run ./scripts/build-app.sh first."
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
trap 'rm -rf "$staging_dir"' EXIT
filename="Snowy-macOS-$architecture.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$staging_dir/$filename"
mkdir "$staging_dir/verify"
ditto -x -k "$staging_dir/$filename" "$staging_dir/verify"
codesign --verify --deep --strict "$staging_dir/verify/Snowy.app"
(
  cd "$staging_dir"
  shasum -a 256 "$filename" > "$filename.sha256"
)
mv -f "$staging_dir/$filename" "$release_dir/$filename"
mv -f "$staging_dir/$filename.sha256" "$release_dir/$filename.sha256"
print "Packaged $release_dir/$filename"
print "Checksum $release_dir/$filename.sha256"
