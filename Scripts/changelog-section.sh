#!/bin/bash
#
# Prints what CHANGELOG.md says about one version: the lines below its heading, without the
# heading itself. The release job uses them as the notes of the GitHub release and of the
# update that Sparkle offers (docs/DESIGN.md §6.3).
#
# It fails when the version has no section or an empty one, and when a code block in the
# section is never closed. A tag whose notes were forgotten then stops the job before anything
# is signed.
#
#   Scripts/changelog-section.sh <version> [changelog]
#
#   <version>    as in the heading, without the brackets: 0.1.0 finds "## [0.1.0]" and
#                "## [0.1.0] - 2026-11-15"
#   [changelog]  the file to read; CHANGELOG.md of this repository when left out

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: $0 <version> [changelog]" >&2
    exit 64
fi

version=$1
repository=$(cd "$(dirname "$0")/.." && pwd)
changelog=${2:-$repository/CHANGELOG.md}

if [[ ! -f "$changelog" ]]; then
    echo "There is no file $changelog." >&2
    exit 1
fi

# awk leaves with status 3 when it never saw the heading, which tells a missing section from
# an empty one, and with status 4 when the file ended inside a code block.
heading_not_found=3
fence_not_closed=4

status=0
section=$(
    awk -v heading="## [$version]" \
        -v heading_not_found="$heading_not_found" -v fence_not_closed="$fence_not_closed" '
        # Inside a fenced code block a line is text, whatever it looks like.
        in_section && /^[[:space:]]*```/ {
            in_fence = !in_fence
        }

        # The section ends at the next heading of its level, or at the link definitions that
        # Keep a Changelog has at the foot of the file ("[0.1.0]: https://..."). A link
        # definition with any other label belongs to the text of the section.
        in_section && !in_fence && (/^## / || /^\[(Unreleased|[0-9]+\.[0-9]+\.[0-9]+)\]:/) {
            exit
        }

        in_section {
            # A blank line is held back until a line with text follows it. That drops the
            # blank lines at both ends of the section and keeps the ones inside it.
            if ($0 ~ /^[[:space:]]*$/) {
                held_blank_lines++
                next
            }
            if (printed_text) {
                for (i = 0; i < held_blank_lines; i++) print ""
            }
            held_blank_lines = 0
            print
            printed_text = 1
        }

        # The heading is compared as text and not as a pattern, where the dots of 0.1.1 would
        # match any character. It is the whole line, or a space and the date follow it.
        !in_section && ($0 == heading || index($0, heading " ") == 1) {
            in_section = 1
            found_heading = 1
        }

        END {
            if (!found_heading) exit heading_not_found
            # Without its end, the block would have taken the rest of the file with it.
            if (in_fence) exit fence_not_closed
        }
    ' "$changelog"
) || status=$?

if [[ $status -eq $heading_not_found ]]; then
    echo "$changelog has no section '## [$version]'." >&2
    echo "Rename '## [Unreleased]' to '## [$version] - <date>' before you tag the release." >&2
    exit 1
fi
if [[ $status -eq $fence_not_closed ]]; then
    echo "The section '## [$version]' of $changelog has a code block that is never closed." >&2
    exit 1
fi
if [[ $status -ne 0 ]]; then
    echo "$changelog could not be read." >&2
    exit 1
fi
if [[ -z "$section" ]]; then
    echo "The section '## [$version]' of $changelog is empty." >&2
    exit 1
fi

printf '%s\n' "$section"
