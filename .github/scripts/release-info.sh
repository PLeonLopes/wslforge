#!/usr/bin/env bash
# Release metadata for CI.
#   release-info.sh          print the version, after checking that install.sh
#                            and install.ps1 agree and that a release version
#                            has its section in CHANGELOG.md
#   release-info.sh --notes  print that CHANGELOG.md section (release notes)
set -euo pipefail
cd "$(dirname "$0")/../.."

sh_version=$(sed -n "s/^WSLFORGE_VERSION='\([^']*\)'.*/\1/p" install.sh)
ps_version=$(sed -n "s/^\$WslforgeVersion = '\([^']*\)'.*/\1/p" install.ps1)

if [[ -z $sh_version || $sh_version != "$ps_version" ]]; then
  echo "ERROR: install.sh ($sh_version) and install.ps1 ($ps_version) must have the same version." >&2
  exit 1
fi

# The section between "## [VERSION]" and the next "## [", without the link
# definitions at the end of the file.
notes() {
  awk -v v="$sh_version" '
    index($0, "## [" v "]") == 1 { on = 1; next }
    on && /^## \[/ { exit }
    on && !/^\[[^]]+\]: / { print }
  ' CHANGELOG.md | sed -e '/./,$!d'
}

if [[ $sh_version != *-dev && -z $(notes | tr -d '[:space:]') ]]; then
  echo "ERROR: CHANGELOG.md has no '## [$sh_version]' section for this release." >&2
  exit 1
fi

if [[ ${1:-} == --notes ]]; then
  notes
else
  echo "$sh_version"
fi
