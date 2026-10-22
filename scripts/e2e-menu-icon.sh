#!/usr/bin/env bash
# ABOUTME: Acceptance test for the SF Symbol menu bar icon (#46), run against the source tree and the running Pontemac.
# ABOUTME: Runs MenuBarIconTests by name, reads the status item over Accessibility, and checks the old imagesets are gone.

set -euo pipefail

ROOT="${PONTEMAC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
FAILURES=0

pass() { echo "PASS $1"; }
fail() {
    echo "FAIL $1: $2"
    FAILURES=$((FAILURES + 1))
}

# AC1, AC2, AC3, AC5 (proxy): symbol name, enabled and disabled alpha, image label.
check_unit_tests() {
    local log
    log=$(mktemp)
    if xcodebuild test -project "$ROOT/iMCP.xcodeproj" -scheme iMCP \
        -only-testing:iMCPTests/MenuBarIconTests >"$log" 2>&1; then
        pass unit_tests
    else
        fail unit_tests "MenuBarIconTests failed, log at $log"
        return
    fi
    rm -f "$log"
}

# AC5: VoiceOver reads the status item as "Pontemac". Needs Pontemac running (make install, relaunch).
check_status_item_name() {
    local name
    name=$(osascript -e 'tell application "System Events" to get name of menu bar item 1 of menu bar 2 of process "Pontemac"' 2>&1 || true)
    [ "$name" = "Pontemac" ] && pass status_item_name || fail status_item_name "status item name is '$name'"
}

# AC6: the inherited imagesets are deleted.
check_imagesets_removed() {
    local left
    left=$(fd -t d '^MenuIcon-' "$ROOT/App/Assets.xcassets" || true)
    [ -z "$left" ] && pass imagesets_removed || fail imagesets_removed "still present: $(echo $left)"
}

check_unit_tests
check_status_item_name
check_imagesets_removed

[ "$FAILURES" -eq 0 ] && echo "ALL PASS" || { echo "$FAILURES FAILED"; exit 1; }
