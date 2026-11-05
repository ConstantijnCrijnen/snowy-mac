#!/bin/zsh
set -euo pipefail

# The base64 Sparkle seed is supplied on stdin from protected local storage or
# a release secret. It must never be passed as a command-line argument.
project_root="${0:A:h:h}"
tag="${1:-}"
if [[ $# -ne 1 || ! "$tag" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 "Usage: create-appcast.sh v<version> < protected-signing-key-file"
  exit 2
fi
release_dir="$project_root/build/releases"
zip_name="Snowy-macOS-arm64.zip"
if [[ -L "$project_root/build" || -L "$release_dir" || ! -f "$release_dir/$zip_name" || -L "$release_dir/$zip_name" ]]; then
  print -u2 "Package the Apple silicon release before generating the appcast."
  exit 1
fi
if [[ -L "$release_dir/appcast.xml" || -d "$release_dir/appcast.xml" ]]; then
  print -u2 "Refusing to replace a redirected appcast."
  exit 1
fi
sparkle_bin="$project_root/.build/artifacts/sparkle/Sparkle/bin"
if [[ ! -x "$sparkle_bin/generate_appcast" ]]; then
  print -u2 "Build Snowy to resolve its pinned Sparkle release tools."
  exit 1
fi
staging_dir="$(mktemp -d "$release_dir/.Snowy-appcast.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
cp "$release_dir/$zip_name" "$staging_dir/$zip_name"
base_url="https://github.com/soloiaros/snowy-mac/releases/download/$tag/"
"$sparkle_bin/generate_appcast" --ed-key-file - --maximum-deltas 0 \
  --download-url-prefix "$base_url" -o "$staging_dir/appcast.xml" "$staging_dir"

python3 - "$staging_dir/appcast.xml" "$staging_dir/$zip_name" "$base_url" "${tag#v}" <<'PY'
import base64
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

feed, archive, base_url, version = sys.argv[1:]
archive = Path(archive)
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
items = ET.parse(feed).findall("./channel/item")
if len(items) != 1:
    raise SystemExit("Expected a single release in the appcast.")
item = items[0]
enclosure = item.find("enclosure")
signature = enclosure.get("{" + ns["sparkle"] + "}edSignature", "")
if (item.findtext("sparkle:shortVersionString", namespaces=ns) != version
        or enclosure.get("url") != base_url + archive.name
        or enclosure.get("length") != str(archive.stat().st_size)
        or len(base64.b64decode(signature, validate=True)) != 64):
    raise SystemExit("Appcast does not match the signed release archive and tag.")
PY
mv -f "$staging_dir/appcast.xml" "$release_dir/appcast.xml"
print "Created signed appcast for $tag."
