#!/bin/bash
#
# Records one answer of the Claude API as a test fixture: the raw bytes of the response, as
# OpenRay's provider would receive them (docs/DESIGN.md §5.4).
#
# This sends a real request, which is billed to the key's account. The tests never do; they
# only read what this script wrote.
#
#   OPENRAY_ANTHROPIC_KEY=<key> Scripts/record-claude-fixture.sh <fixture> <request body>
#
#   <fixture>       where to write, below Tests/OpenRayCoreTests/Fixtures/claude:
#                   plain-text.sse for a stream, errors/401.json for a failed response
#   <request body>  a file with the JSON to send, for example
#
#     {"model": "claude-haiku-5-5", "max_tokens": 8192, "stream": true,
#      "output_config": {"effort": "low"},
#      "messages": [{"role": "user", "content": [{"type": "text", "text": "Hello"}]}]}
#
# A failed response is recorded like any other, so the same command makes the error fixtures:
# an unknown model for 404, a made-up key for 401.

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: OPENRAY_ANTHROPIC_KEY=<key> $0 <fixture> <request body>" >&2
    exit 64
fi
if [[ -z "${OPENRAY_ANTHROPIC_KEY:-}" ]]; then
    echo "Set OPENRAY_ANTHROPIC_KEY to the API key to record with." >&2
    exit 64
fi

fixture=$1
request_body=$2

repository=$(cd "$(dirname "$0")/.." && pwd)
output="$repository/Packages/OpenRayCore/Tests/OpenRayCoreTests/Fixtures/claude/$fixture"
mkdir -p "$(dirname "$output")"

# The key reaches curl through a header file that is a pipe. It is in no argument, where `ps`
# would show it, and in no file. Nothing here prints it, and it is not part of what the API
# answers, so it cannot end up in the fixture.
status=$(
    curl --silent --show-error --no-buffer \
        --header @<(printf 'x-api-key: %s\n' "$OPENRAY_ANTHROPIC_KEY") \
        --header "anthropic-version: 2026-10-21" \
        --header "content-type: application/json" \
        --data-binary "@$request_body" \
        --output "$output" \
        --write-out '%{http_code}' \
        https://api.anthropic.com/v1/messages
)

echo "HTTP $status, $(wc -c < "$output" | tr -d ' ') bytes written to $output"
