#!/usr/bin/env bash
# ABOUTME: End-to-end acceptance tests for ReminderKit-backed reminder tools, run against the installed Pontemac.app.
# ABOUTME: Drives pontemac-server through the MCP Inspector CLI; writes only to the "iMCP Tests" list and deletes what it creates.

set -euo pipefail

SERVER="${IMCP_SERVER:-/Applications/Pontemac.app/Contents/MacOS/pontemac-server}"
LIST="iMCP Tests"
FAILURES=0
CREATED=()
# Tag names carry a per-run suffix so tags left in the account by earlier runs cannot satisfy an assertion.
RUN="${IMCP_E2E_RUN:-$(date +%s)$$}"
TAG_ERRANDS="errands$RUN"
TAG_HOME="Home$RUN"
TAG_URGENT="urgent$RUN"

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
assert_tags() { jq -e --argjson want "$1" '.tags == $want' >/dev/null; }
assert_tag_count() { jq -e --argjson n "$1" '(.tags | length) == $n' >/dev/null; }
assert_warning_contains() { jq -e --arg w "$1" 'any((.warnings // [])[]; contains($w))' >/dev/null; }
assert_tag_listed() { jq -e --arg t "$1" 'index($t) != null' >/dev/null; }
assert_summary_tags() { jq -e --arg id "$1" --argjson want "$2" 'any(.[]; .identifier == $id and .tags == $want)' >/dev/null; }

cleanup() {
    local run_tags="[\"$TAG_ERRANDS\",\"$TAG_HOME\",\"$TAG_URGENT\"]"
    for id in "${CREATED[@]:-}"; do
        [ -n "$id" ] || continue
        # Strip this run's tags first so a deleted reminder does not leave labels behind in the sidebar.
        call reminders_update "identifier=$id" "removeTags=$run_tags" >/dev/null 2>&1 || true
        call reminders_delete "identifier=$id" >/dev/null 2>&1 || true
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

# Creates a reminder in the test list tagged errands and Home and prints the create payload.
# Callers run it in $(...), a subshell, so each caller adds the identifier to CREATED itself.
create_tagged() {
    call reminders_create "title=iMCP e2e tags $$" "list=$LIST" "tags=[\"$TAG_ERRANDS\",\"$TAG_HOME\"]"
}

# #37 AC1: create with tags returns them sorted; a fresh get agrees.
test_tag_create() {
    local out id want="[\"$TAG_HOME\",\"$TAG_ERRANDS\"]"
    out=$(create_tagged 2>&1) || { fail tag_create "reminders_create rejected: $out"; return; }
    id=$(jq -r '.identifier' <<<"$out")
    CREATED+=("$id")
    assert_tags "$want" <<<"$out" || { fail tag_create "create response tags != $want"; return; }
    call reminders_get "identifier=$id" | assert_tags "$want" || { fail tag_create "get tags != $want"; return; }
    pass tag_create
}

# #37 AC2: addTags adds one tag and keeps the others.
test_tag_add() {
    local out id want="[\"$TAG_HOME\",\"$TAG_ERRANDS\",\"$TAG_URGENT\"]"
    out=$(create_tagged 2>&1) || { fail tag_add "reminders_create rejected: $out"; return; }
    id=$(jq -r '.identifier' <<<"$out")
    CREATED+=("$id")
    call reminders_update "identifier=$id" "addTags=[\"$TAG_URGENT\"]" >/dev/null 2>&1 || { fail tag_add "reminders_update rejected"; return; }
    call reminders_get "identifier=$id" | assert_tags "$want" || { fail tag_add "get tags != $want"; return; }
    pass tag_add
}

# #37 AC3: removeTags removes one tag and keeps the others.
test_tag_remove() {
    local out id want="[\"$TAG_HOME\",\"$TAG_URGENT\"]"
    out=$(create_tagged 2>&1) || { fail tag_remove "reminders_create rejected: $out"; return; }
    id=$(jq -r '.identifier' <<<"$out")
    CREATED+=("$id")
    call reminders_update "identifier=$id" "addTags=[\"$TAG_URGENT\"]" >/dev/null 2>&1 || { fail tag_remove "reminders_update addTags rejected"; return; }
    call reminders_update "identifier=$id" "removeTags=[\"$TAG_ERRANDS\"]" >/dev/null 2>&1 || { fail tag_remove "reminders_update removeTags rejected"; return; }
    call reminders_get "identifier=$id" | assert_tags "$want" || { fail tag_remove "get tags != $want"; return; }
    pass tag_remove
}

# #37 AC4: a leading # and a case-only variant collapse to one stored tag.
test_tag_dedupe() {
    local out id upper="Errands$RUN"
    out=$(call reminders_create "title=iMCP e2e tag dedupe $$" "list=$LIST" "tags=[\"#$TAG_ERRANDS\",\"$upper\"]" 2>&1) \
        || { fail tag_dedupe "reminders_create rejected: $out"; return; }
    id=$(jq -r '.identifier' <<<"$out")
    CREATED+=("$id")
    call reminders_get "identifier=$id" | assert_tag_count 1 || { fail tag_dedupe "get returned other than one tag"; return; }
    pass tag_dedupe
}

# #37 AC5: removing a tag the reminder lacks succeeds, leaves tags alone, and warns.
test_tag_remove_missing() {
    local out id upd want="[\"$TAG_HOME\",\"$TAG_ERRANDS\"]"
    out=$(create_tagged 2>&1) || { fail tag_remove_missing "reminders_create rejected: $out"; return; }
    id=$(jq -r '.identifier' <<<"$out")
    CREATED+=("$id")
    upd=$(call reminders_update "identifier=$id" 'removeTags=["missing"]' 2>&1) || { fail tag_remove_missing "reminders_update rejected: $upd"; return; }
    assert_warning_contains "tag 'missing' not on reminder" <<<"$upd" || { fail tag_remove_missing "warnings lack \"tag 'missing' not on reminder\""; return; }
    call reminders_get "identifier=$id" | assert_tags "$want" || { fail tag_remove_missing "get tags != $want"; return; }
    pass tag_remove_missing
}

# #37 AC6: reminders_tags lists tags added by create and by update.
test_tags_list() {
    local out id tags
    out=$(create_tagged 2>&1) || { fail tags_list "reminders_create rejected: $out"; return; }
    id=$(jq -r '.identifier' <<<"$out")
    CREATED+=("$id")
    call reminders_update "identifier=$id" "addTags=[\"$TAG_URGENT\"]" >/dev/null 2>&1 || { fail tags_list "reminders_update rejected"; return; }
    tags=$(call reminders_tags 2>&1) || { fail tags_list "reminders_tags rejected: $tags"; return; }
    assert_tag_listed "$TAG_ERRANDS" <<<"$tags" || { fail tags_list "reminders_tags lacks $TAG_ERRANDS"; return; }
    assert_tag_listed "$TAG_URGENT" <<<"$tags" || { fail tags_list "reminders_tags lacks $TAG_URGENT"; return; }
    pass tags_list
}

# #37 AC7: the tagged reminder's summary in reminders_fetch carries its tags.
test_fetch_tags_field() {
    local out id want="[\"$TAG_HOME\",\"$TAG_ERRANDS\"]"
    out=$(create_tagged 2>&1) || { fail fetch_tags_field "reminders_create rejected: $out"; return; }
    id=$(jq -r '.identifier' <<<"$out")
    CREATED+=("$id")
    call reminders_fetch "lists=[\"$LIST\"]" | assert_summary_tags "$id" "$want" \
        || { fail fetch_tags_field "summary for $id lacks tags $want"; return; }
    pass fetch_tags_field
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
    assert_tags '["Home","errands"]' <<<'{"tags":["Home","errands"]}' || ok=1
    ! assert_tags '["Home","errands"]' <<<'{"tags":["errands","Home"]}' || ok=1
    ! assert_tags '["Home","errands"]' <<<'{"title":"x"}' || ok=1
    assert_tag_count 1 <<<'{"tags":["errands"]}' || ok=1
    ! assert_tag_count 1 <<<'{"tags":["errands","Errands"]}' || ok=1
    ! assert_tag_count 1 <<<'{"title":"x"}' || ok=1
    assert_warning_contains "tag 'missing' not on reminder" <<<'{"warnings":["tag '"'"'missing'"'"' not on reminder"]}' || ok=1
    ! assert_warning_contains "tag 'missing' not on reminder" <<<'{"tags":[]}' || ok=1
    assert_tag_listed errands1 <<<'["Home1","errands1"]' || ok=1
    ! assert_tag_listed errands1 <<<'["Home1","errands"]' || ok=1
    assert_summary_tags A '["Home"]' <<<'[{"identifier":"A","tags":["Home"]}]' || ok=1
    ! assert_summary_tags A '["Home"]' <<<'[{"identifier":"A"},{"identifier":"B","tags":["Home"]}]' || ok=1
    [ "$ok" = 0 ] && echo "PASS self_test" || { echo "FAIL self_test"; exit 1; }
}

if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit 0
fi

trap cleanup EXIT
require_test_list
TESTS=("$@")
[ ${#TESTS[@]} -eq 0 ] && TESTS=(flag_create flag_update fetch_flagged_field \
    tag_create tag_add tag_remove tag_dedupe tag_remove_missing tags_list fetch_tags_field)
for t in "${TESTS[@]}"; do "test_$t"; done
[ "$FAILURES" -eq 0 ]
