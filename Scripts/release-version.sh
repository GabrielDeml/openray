#!/bin/bash
#
# Prints the version that a release tag stands for: v0.1.0 gives 0.1.0. The release job makes
# this the app's MARKETING_VERSION (docs/DESIGN.md §6.3).
#
# Anything that is not "v" and three numbers fails, so that a tag pushed by mistake (v0.1,
# v0.1.0-beta, 0.1.0) stops the job before it signs anything.
#
#   Scripts/release-version.sh <tag>

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <tag>" >&2
    exit 64
fi

tag=$1

# A number has no leading zero. v0.01.0 would be the same version as v0.1.0 to Sparkle and to
# Homebrew, which compare numbers, and a different one in the name of the zip.
number='(0|[1-9][0-9]*)'
release_tag="^v$number\.$number\.$number\$"

if [[ ! "$tag" =~ $release_tag ]]; then
    echo "'$tag' is not a release tag. A release tag is a v and three numbers, like v0.1.0." >&2
    exit 1
fi

echo "${tag#v}"
