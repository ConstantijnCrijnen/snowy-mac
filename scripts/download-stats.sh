#!/bin/bash
set -euo pipefail

if ! command -v gh >/dev/null; then
  printf '%s\n' 'Install GitHub CLI (gh) and run gh auth login first.' >&2
  exit 1
fi

# Fetch all pages before printing totals so an API failure cannot give partial counts.
releases="$(gh api --hostname github.com --paginate 'repos/soloiaros/snowy-mac/releases?per_page=100' --jq '
  .[]
  | select(.draft == false)
  | [.assets[]
      | select(.state == "uploaded")
      | select(.name | test("^Snowy-macOS-(arm64|x86_64|universal)\\.(dmg|zip)$"))
    ] as $files
  | select($files | length > 0)
  | [
      .tag_name,
      ([$files[] | select(.name | endswith(".dmg")) | .download_count] | add // 0),
      ([$files[] | select(.name | endswith(".zip")) | .download_count] | add // 0)
    ]
  | @tsv
')"

printf '%s\n' "$releases" | awk -F '\t' '
  BEGIN { printf "%-16s %10s %10s %10s\n", "Release", "DMG", "ZIP", "Total" }
  NF {
    printf "%-16s %10d %10d %10d\n", $1, $2, $3, $2 + $3
    dmgs += $2
    zips += $3
  }
  END {
    printf "%-16s %10d %10d %10d\n", "All releases", dmgs, zips, dmgs + zips
  }
'

printf '\n%s\n' 'Counts are GitHub asset downloads. ZIPs can include in-app updates.'
