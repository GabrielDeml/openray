#!/bin/bash
#
# Sends a zip of the signed app to Apple's notary service and waits for the answer
# (docs/DESIGN.md §6.2). The release job runs it; nothing else does.
#
# If Apple does not accept the zip, the script fetches the notary log, which says what was
# wrong with which file, writes it to <log> and fails. The release job uploads that file.
#
#   NOTARY_KEY_P8_BASE64=<key> NOTARY_KEY_ID=<id> [NOTARY_ISSUER_ID=<issuer>] \
#       Scripts/notarize.sh <zip> <log>
#
#   NOTARY_KEY_P8_BASE64  the App Store Connect API key, the .p8 file in Base64
#   NOTARY_KEY_ID         the ID of that key
#   NOTARY_ISSUER_ID      the issuer of a Team key. An Individual key has no issuer: leave the
#                         variable unset or empty, and notarytool is not given one.
#   <zip>                 what to notarise
#   <log>                 where to write the notary log of a zip that was not accepted

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: NOTARY_KEY_P8_BASE64=<key> NOTARY_KEY_ID=<id> [NOTARY_ISSUER_ID=<issuer>]" \
        "$0 <zip> <log>" >&2
    exit 64
fi
if [[ -z "${NOTARY_KEY_P8_BASE64:-}" || -z "${NOTARY_KEY_ID:-}" ]]; then
    echo "Set NOTARY_KEY_P8_BASE64 and NOTARY_KEY_ID to the App Store Connect API key." >&2
    exit 64
fi

zip=$1
log=$2

# notarytool takes the key as a file. It is written where only this user can read it and
# removed when the script ends, however it ends. Nothing here prints the key.
work_directory=$(mktemp -d)
trap 'rm -rf "$work_directory"' EXIT

key_file="$work_directory/notary-key.p8"
printf '%s' "$NOTARY_KEY_P8_BASE64" | base64 --decode > "$key_file"

credentials=(--key "$key_file" --key-id "$NOTARY_KEY_ID")
if [[ -n "${NOTARY_ISSUER_ID:-}" ]]; then
    credentials+=(--issuer "$NOTARY_ISSUER_ID")
fi

# With --output-format json the answer on standard output is one JSON object with the
# submission's "id" and its "status". Progress goes to standard error and into the job's log.
answer="$work_directory/answer.json"
submit_exit_status=0
xcrun notarytool submit "$zip" "${credentials[@]}" --wait --output-format json > "$answer" \
    || submit_exit_status=$?

# What Apple said is read from the answer. The exit status alone does not tell a zip that was
# turned down, which has a log worth fetching, from one that never arrived.
status=$(plutil -extract status raw -o - "$answer" 2> /dev/null || true)
submission=$(plutil -extract id raw -o - "$answer" 2> /dev/null || true)

if [[ -z "$submission" ]]; then
    echo "notarytool could not submit $zip (exit status $submit_exit_status):" >&2
    cat "$answer" >&2
    exit 1
fi
if [[ "$status" != "Accepted" ]]; then
    echo "Apple answered '$status' for submission $submission. The notary log is in $log." >&2
    xcrun notarytool log "$submission" "${credentials[@]}" "$log"
    exit 1
fi

echo "Apple accepted submission $submission."
