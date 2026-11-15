#!/bin/bash
#
# Writes a release's version and the SHA-256 of its zip into a Homebrew cask. The release job
# runs it on the copy of Casks/openray.rb that it pushes to the tap (docs/DESIGN.md §6.5).
#
# It fails, and leaves the file alone, when the cask does not have exactly one "version" line
# and one "sha256" line to rewrite.
#
#   Scripts/update-cask.sh <version> <sha256> <cask>
#
#   <version>  as Scripts/release-version.sh prints it: 0.1.0
#   <sha256>   of the zip, 64 hexadecimal digits in lower case, as shasum prints them
#   <cask>     the file to rewrite

set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <version> <sha256> <cask>" >&2
    exit 64
fi

version=$1
sha256=$2
cask=$3

# Both values end up inside a sed command below, so neither may be anything but what it claims.
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "'$version' is not a version like 0.1.0." >&2
    exit 1
fi
if [[ ! "$sha256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "'$sha256' is not a SHA-256: 64 hexadecimal digits in lower case." >&2
    exit 1
fi
if [[ ! -f "$cask" ]]; then
    echo "There is no file $cask." >&2
    exit 1
fi

# What the two lines have now. The count below and the rewrite are both built from these, so
# that a line the count accepts is a line the rewrite changes.
old_version='"[^"]*"'
# The repository's copy of the cask says ":no_check", the tap's copy has the hash of a zip.
old_sha256='(:no_check|"[^"]*")'

version_line="^[[:space:]]*version $old_version\$"
sha256_line="^[[:space:]]*sha256 $old_sha256\$"

# grep leaves with an error when it counts no line; the count is what is checked.
version_line_count=$(grep -c -E "$version_line" "$cask" || true)
sha256_line_count=$(grep -c -E "$sha256_line" "$cask" || true)

if [[ "$version_line_count" -ne 1 ]]; then
    echo "$cask has $version_line_count lines of the form: version \"...\". It needs one." >&2
    exit 1
fi
if [[ "$sha256_line_count" -ne 1 ]]; then
    echo "$cask has $sha256_line_count lines of the form: sha256 \"...\" or sha256 :no_check." \
        "It needs one." >&2
    exit 1
fi

rewritten=$(mktemp)
sed -E \
    -e "s/^([[:space:]]*version) $old_version\$/\1 \"$version\"/" \
    -e "s/^([[:space:]]*sha256) $old_sha256\$/\1 \"$sha256\"/" \
    "$cask" > "$rewritten"

# Copied over the cask and not moved there, which would give it the mode of a temporary file.
cat "$rewritten" > "$cask"
rm "$rewritten"
