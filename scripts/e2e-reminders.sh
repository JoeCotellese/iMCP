#!/usr/bin/env bash
# ABOUTME: End-to-end acceptance tests for ReminderKit-backed reminder tools, run against the installed iMCP.app.
# ABOUTME: Drives imcp-server through the MCP Inspector CLI; writes only to the "iMCP Tests" list and deletes what it creates.

set -euo pipefail

SERVER="${IMCP_SERVER:-/Applications/iMCP.app/Contents/MacOS/imcp-server}"
LIST="iMCP Tests"
FAILURES=0
CREATED=()

# Calls one tool and prints the tool's JSON payload. Exits nonzero when the tool reports an error.
call() {
    local tool="$1"
    shift
    local args=()
    for kv in "$@"; do args+=(--tool-arg "$kv"); done
    local raw
    raw=$(npx -y @modelcontextprotocol/inspector --cli "$SERVER" \
        --method tools/call --tool-name "$tool" "${args[@]}" 2>/dev/null)
    if [ "$(jq -r '.isError // false' <<<"$raw")" = "true" ]; then
        jq -r '.content[0].text' <<<"$raw" >&2
        return 1
    fi
    jq -r '.content[0].text' <<<"$raw"
}

pass() { echo "PASS $1"; }
fail() {
    echo "FAIL $1: $2"
    FAILURES=$((FAILURES + 1))
}

# Assertion helpers take a JSON payload on stdin so --self-test can feed them doctored input.
assert_flagged() { jq -e --argjson want "$1" '.flagged == $want' >/dev/null; }
assert_no_warnings() { jq -e '(.warnings // []) | length == 0' >/dev/null; }
assert_summary_flagged() { jq -e --arg id "$1" --argjson want "$2" 'any(.[]; .identifier == $id and .flagged == $want)' >/dev/null; }

cleanup() {
    for id in "${CREATED[@]:-}"; do
        [ -n "$id" ] && call reminders_delete "identifier=$id" >/dev/null 2>&1 || true
    done
}

require_test_list() {
    if ! call reminders_lists | jq -e --arg l "$LIST" 'any(.[]; .title == $l)' >/dev/null; then
        echo "SETUP missing reminder list \"$LIST\"; create it before running (reminders_create would fall back to the default list)" >&2
        exit 2
    fi
}

create_flagged() {
    local out
    call reminders_create "title=iMCP e2e flag $$" "list=$LIST" "flagged=true"
}

# AC4: create with flagged true returns flagged true and no warnings; a fresh get agrees.
test_flag_create() {
    local out id
    out=$(create_flagged 2>&1) || { fail flag_create "reminders_create rejected: $out"; return; }
    id=$(jq -r '.identifier' <<<"$out")
    CREATED+=("$id")
    assert_flagged true <<<"$out" || { fail flag_create "create response flagged != true"; return; }
    assert_no_warnings <<<"$out" || { fail flag_create "create response has warnings"; return; }
    call reminders_get "identifier=$id" | assert_flagged true || { fail flag_create "get flagged != true"; return; }
    pass flag_create
}

# AC5: update flagged false, then get returns flagged false.
test_flag_update() {
    local out id
    out=$(create_flagged 2>&1) || { fail flag_update "reminders_create rejected: $out"; return; }
    id=$(jq -r '.identifier' <<<"$out")
    CREATED+=("$id")
    call reminders_update "identifier=$id" "flagged=false" >/dev/null 2>&1 || { fail flag_update "reminders_update rejected"; return; }
    call reminders_get "identifier=$id" | assert_flagged false || { fail flag_update "get flagged != false"; return; }
    pass flag_update
}

# AC6: the flagged reminder's summary in reminders_fetch carries flagged true.
test_fetch_flagged_field() {
    local out id
    out=$(create_flagged 2>&1) || { fail fetch_flagged_field "reminders_create rejected: $out"; return; }
    id=$(jq -r '.identifier' <<<"$out")
    CREATED+=("$id")
    call reminders_fetch "lists=[\"$LIST\"]" | assert_summary_flagged "$id" true \
        || { fail fetch_flagged_field "summary for $id lacks flagged true"; return; }
    pass fetch_flagged_field
}

# Proves each assertion can pass on a positive and fail on a negative, without touching Reminders.
self_test() {
    local ok=0
    assert_flagged true <<<'{"flagged":true}' || ok=1
    ! assert_flagged true <<<'{"title":"x"}' || ok=1
    assert_no_warnings <<<'{"flagged":true}' || ok=1
    ! assert_no_warnings <<<'{"warnings":["ReminderKit unavailable"]}' || ok=1
    assert_summary_flagged A true <<<'[{"identifier":"A","flagged":true}]' || ok=1
    ! assert_summary_flagged A true <<<'[{"identifier":"A"}]' || ok=1
    [ "$ok" = 0 ] && echo "PASS self_test" || { echo "FAIL self_test"; exit 1; }
}

if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit 0
fi

trap cleanup EXIT
require_test_list
TESTS=("$@")
[ ${#TESTS[@]} -eq 0 ] && TESTS=(flag_create flag_update fetch_flagged_field)
for t in "${TESTS[@]}"; do "test_$t"; done
[ "$FAILURES" -eq 0 ]
