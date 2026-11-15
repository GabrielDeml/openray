#!/bin/bash
#
# Tests the release scripts that only read and write text: release-version.sh,
# changelog-section.sh and update-cask.sh. CI runs it (docs/DESIGN.md §5.4), because the
# release job that depends on those three runs only when a tag is pushed.
#
# It also checks that every script in this folder parses. notarize.sh gets no more than that:
# running it would send something to Apple.
#
# Everything is written to a temporary directory, which is removed at the end.
#
#   Scripts/test-release-scripts.sh

set -euo pipefail

scripts=$(cd "$(dirname "$0")" && pwd)
repository=$(cd "$scripts/.." && pwd)

work_directory=$(mktemp -d)
trap 'rm -rf "$work_directory"' EXIT

failure_count=0

fail() {
    echo "FAILED: $1" >&2
    failure_count=$((failure_count + 1))
}

# expect_output <what is tested> <expected output> <command...>
# The command must succeed and print exactly the expected text.
expect_output() {
    local description=$1
    local expected=$2
    shift 2

    local actual
    if ! actual=$("$@" 2> "$work_directory/stderr"); then
        fail "$description: the command failed: $(cat "$work_directory/stderr")"
        return
    fi
    if [[ "$actual" != "$expected" ]]; then
        fail "$description: expected '$expected', got '$actual'"
    fi
}

# expect_failure <what is tested> <command...>
# The command must fail and say why on standard error.
expect_failure() {
    local description=$1
    shift

    if "$@" > /dev/null 2> "$work_directory/stderr"; then
        fail "$description: the command succeeded"
        return
    fi
    if [[ ! -s "$work_directory/stderr" ]]; then
        fail "$description: the command failed without a message"
    fi
}


# Every script parses.

for script in "$scripts"/*.sh; do
    if ! bash -n "$script"; then
        fail "$(basename "$script") does not parse"
    fi
done


# release-version.sh

version_of="$scripts/release-version.sh"

expect_output "a first release" "0.1.0" "$version_of" v0.1.0
expect_output "numbers of more than one digit" "12.34.56" "$version_of" v12.34.56
expect_output "a major version" "1.0.0" "$version_of" v1.0.0

expect_failure "a tag without the v" "$version_of" 0.1.0
expect_failure "a tag of two numbers" "$version_of" v0.1
expect_failure "a tag of four numbers" "$version_of" v0.1.0.1
expect_failure "a tag with a suffix" "$version_of" v0.1.0-beta
expect_failure "a tag with a leading zero" "$version_of" v0.01.0
expect_failure "a tag with a capital V" "$version_of" V0.1.0
expect_failure "a tag with text before it" "$version_of" release-v0.1.0
expect_failure "an empty tag" "$version_of" ""
expect_failure "no tag at all" "$version_of"


# changelog-section.sh

section_of="$scripts/changelog-section.sh"
changelog="$work_directory/CHANGELOG.md"

cat > "$changelog" << 'END'
# Changelog

What changed in each release.

## [Unreleased]

## [0.1.10] - 2026-12-24

### Fixed

- The tenth fix.

## [0.1.1]


### Added

- A heading without a date.

### Fixed

- Two blank lines above, one below.

## [0.1.0] - 2026-11-15

- The first release.
- With a [link](https://example.com) and a ## in the middle of a line.

[Unreleased]: https://example.com/compare/v0.1.10...HEAD
[0.1.10]: https://example.com/compare/v0.1.1...v0.1.10
END

expect_output "a section in the middle, heading without a date" \
    "### Added

- A heading without a date.

### Fixed

- Two blank lines above, one below." \
    "$section_of" 0.1.1 "$changelog"

expect_output "the first section with text, heading with a date" \
    "### Fixed

- The tenth fix." \
    "$section_of" 0.1.10 "$changelog"

expect_output "the last section, which ends at the link definitions" \
    "- The first release.
- With a [link](https://example.com) and a ## in the middle of a line." \
    "$section_of" 0.1.0 "$changelog"

expect_failure "a version that has no section" "$section_of" 0.2.0 "$changelog"
# This is what the release job prints when the heading was not renamed before the tag.
if ! grep -q "Rename '## \[Unreleased\]'" "$work_directory/stderr"; then
    fail "a version that has no section: the message does not say what to rename"
fi
expect_failure "a version that is the start of another" "$section_of" 0.1 "$changelog"
expect_failure "a version that is the end of another" "$section_of" 1.10 "$changelog"
# As a pattern, 0.1..0 would match the heading of 0.1.10.
expect_failure "a version whose dots would match as a pattern" "$section_of" 0.1..0 "$changelog"
expect_failure "a section without text" "$section_of" Unreleased "$changelog"
expect_failure "a changelog that does not exist" "$section_of" 0.1.0 "$work_directory/missing.md"
expect_failure "no version at all" "$section_of"

# What looks like the end of a section inside a code block is text of the notes, and so is a
# link definition that is not one of the versions.
fenced_changelog="$work_directory/fenced.md"

cat > "$fenced_changelog" << 'END'
## [0.2.0] - 2026-12-31

- Scripts can print Markdown:

```
## not a heading
[0.1.0]: not a link definition
```

- See [the guide] for more.

[the guide]: https://example.com/guide

- A line after the link definition.

## [0.1.0]

- The first release.
END

expect_output "a section with a code block and a link definition of its own" \
    '- Scripts can print Markdown:

```
## not a heading
[0.1.0]: not a link definition
```

- See [the guide] for more.

[the guide]: https://example.com/guide

- A line after the link definition.' \
    "$section_of" 0.2.0 "$fenced_changelog"

expect_output "the section after one with a code block" \
    "- The first release." \
    "$section_of" 0.1.0 "$fenced_changelog"

# Without its end, a code block would take every later section into the notes.
cat > "$work_directory/unclosed.md" << 'END'
## [0.2.1]

- A code block that is never closed:

```
swift test

## [0.2.0]

- The release before.
END

expect_failure "a section whose code block is never closed" \
    "$section_of" 0.2.1 "$work_directory/unclosed.md"
if ! grep -q "never closed" "$work_directory/stderr"; then
    fail "a section whose code block is never closed: the message does not say so"
fi

# The repository's own changelog: every released version has notes that the release job could
# extract. "Unreleased" is left out, because right after a release it is empty.
if [[ ! -f "$repository/CHANGELOG.md" ]]; then
    fail "the repository has no CHANGELOG.md"
else
    # grep leaves with an error when every heading is "Unreleased", which is no failure.
    released_versions=$(
        sed -n -E 's/^## \[([^]]+)\].*$/\1/p' "$repository/CHANGELOG.md" \
            | grep -v -x Unreleased || true
    )
    for version in $released_versions; do
        if ! "$section_of" "$version" > /dev/null 2> "$work_directory/stderr"; then
            fail "CHANGELOG.md, version $version: $(cat "$work_directory/stderr")"
        fi
    done
fi


# update-cask.sh, on a copy of the cask that the release job copies to the tap.

update_cask="$scripts/update-cask.sh"
cask="$work_directory/openray.rb"
sha256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
other_sha256=fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210

cp "$repository/Casks/openray.rb" "$cask"
expect_output "the repository's cask" "" "$update_cask" 1.2.3 "$sha256" "$cask"
expect_output "the version line" '  version "1.2.3"' grep -E '^ *version ' "$cask"
expect_output "the sha256 line" "  sha256 \"$sha256\"" grep -E '^ *sha256 ' "$cask"

# Apart from those two lines the cask is as it was.
changed_line_count=$(diff "$repository/Casks/openray.rb" "$cask" | grep -c '^>' || true)
if [[ "$changed_line_count" -ne 2 ]]; then
    fail "the rewrite changed $changed_line_count lines of the cask, not 2"
fi

# The next release rewrites a cask that already has a hash.
expect_output "a cask that has a hash" "" "$update_cask" 1.2.4 "$other_sha256" "$cask"
expect_output "the version line, rewritten again" '  version "1.2.4"' grep -E '^ *version ' "$cask"
expect_output "the sha256 line, rewritten again" "  sha256 \"$other_sha256\"" \
    grep -E '^ *sha256 ' "$cask"

before_refused_rewrites=$(cat "$cask")
expect_failure "a hash that is too short" "$update_cask" 1.2.5 abc123 "$cask"
expect_failure "a hash in capitals" "$update_cask" 1.2.5 "$(echo "$sha256" | tr a-f A-F)" "$cask"
expect_failure "a hash with another character" "$update_cask" 1.2.5 "${sha256%f}g" "$cask"
expect_failure "a version with a v" "$update_cask" v1.2.5 "$sha256" "$cask"
expect_failure "a cask that does not exist" "$update_cask" 1.2.5 "$sha256" "$work_directory/no.rb"
if [[ "$(cat "$cask")" != "$before_refused_rewrites" ]]; then
    fail "a refused rewrite changed the cask"
fi

grep -v -E '^ *version ' "$cask" > "$work_directory/no-version.rb"
expect_failure "a cask without a version line" \
    "$update_cask" 1.2.5 "$sha256" "$work_directory/no-version.rb"

grep -v -E '^ *sha256 ' "$cask" > "$work_directory/no-sha256.rb"
expect_failure "a cask without a sha256 line" \
    "$update_cask" 1.2.5 "$sha256" "$work_directory/no-sha256.rb"


if [[ $failure_count -gt 0 ]]; then
    echo "$failure_count checks failed." >&2
    exit 1
fi
echo "The release scripts pass their tests."
