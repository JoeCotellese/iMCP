#!/usr/bin/env bash
# ABOUTME: Acceptance tests for the Pontemac rebrand (#44), run against the installed Pontemac.app and the source tree.
# ABOUTME: Checks bundle layout, Info.plist, About contract, user-visible strings, license, and live serverInfo alongside iMCP.

set -euo pipefail

ROOT="${PONTEMAC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
APP="${PONTEMAC_APP:-/Applications/Pontemac.app}"
UPSTREAM_APP="${UPSTREAM_APP:-/Applications/iMCP.app}"
FAILURES=0

pass() { echo "PASS $1"; }
fail() {
    echo "FAIL $1: $2"
    FAILURES=$((FAILURES + 1))
}

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }

# AC1: the app bundle exists and embeds pontemac-server.
check_bundle_layout() {
    local app="$1"
    [ -d "$app" ] || { fail bundle_layout "$app not found"; return; }
    [ -x "$app/Contents/MacOS/pontemac-server" ] || { fail bundle_layout "Contents/MacOS/pontemac-server missing"; return; }
    pass bundle_layout
}

# AC2: bundle identifier.
check_bundle_id() {
    local got
    got=$(plist "$1" CFBundleIdentifier || true)
    [ "$got" = "com.joecotellese.pontemac" ] && pass bundle_id || fail bundle_id "CFBundleIdentifier is '$got'"
}

# AC3: no Sparkle keys, copyright string.
check_info_plist() {
    local info="$1/Contents/Info.plist" keys copyright
    [ -f "$info" ] || { fail info_plist "$info not found"; return; }
    keys=$(plutil -convert json -o - "$info" | jq -r 'keys[] | select(startswith("SU"))')
    copyright=$(plist "$1" NSHumanReadableCopyright || true)
    if [ -n "$keys" ]; then
        fail info_plist "Sparkle keys present: $(echo $keys)"
    elif [ "$copyright" != "© 2026 Joe Cotellese" ]; then
        fail info_plist "NSHumanReadableCopyright is '$copyright'"
    else
        pass info_plist
    fi
}

# AC4 proxy: the name the menu bar extra, About title, and serverInfo derive from.
check_bundle_name() {
    local got
    got=$(plist "$1" CFBundleName || true)
    [ "$got" = "Pontemac" ] && pass bundle_name || fail bundle_name "CFBundleName is '$got'"
}

# AC6 proxy: the advertised Bonjour type, in the plist and in source.
check_bonjour_type() {
    local app="$1" src="$2" types
    types=$(plutil -convert json -o - "$app/Contents/Info.plist" 2>/dev/null | jq -r '(.NSBonjourServices // []) | join(",")' || true)
    if [ "$types" != "_pontemac._tcp" ]; then
        fail bonjour_type "NSBonjourServices is '$types'"
    elif rg -q '"_mcp\._tcp"' "$src/App" "$src/CLI"; then
        fail bonjour_type "source still declares _mcp._tcp: $(rg -l '"_mcp\._tcp"' "$src/App" "$src/CLI" | tr '\n' ' ')"
    else
        pass bonjour_type
    fi
}

# AC5 proxy: the About window carries the identifier, text, and link contract.
# Values are matched with their closing quote, so the /issues/new URL cannot stand in for the repository URL.
check_about_contract() {
    local file="$1/App/Views/AboutWindow.swift" missing=()
    local want=(
        'accessibilityIdentifier("aboutAppNameText")'
        'accessibilityIdentifier("aboutCopyrightText")'
        'accessibilityIdentifier("aboutContactLink")'
        'accessibilityIdentifier("aboutRepositoryLink")'
        'accessibilityIdentifier("aboutBasedOnLink")'
        'accessibilityIdentifier("aboutReportIssueButton")'
        'accessibilityIdentifier("aboutTrademarkText")'
        '"pontemac@cotellese.me"'
        '"mailto:pontemac@cotellese.me"'
        '"Source on GitHub"'
        '"https://github.com/JoeCotellese/pontemac-mcp"'
        '"Based on iMCP by Mattt"'
        '"https://github.com/mattt/iMCP"'
        '"Report an Issue"'
        '"https://github.com/JoeCotellese/pontemac-mcp/issues/new"'
        '"Mac is a trademark of Apple Inc., registered in the U.S. and other countries."'
    )
    for w in "${want[@]}"; do grep -qF "$w" "$file" || missing+=("$w"); done
    if grep -qF 'github.com/mattt/iMCP/issues' "$file"; then missing+=("(still links mattt/iMCP/issues)"); fi
    [ ${#missing[@]} -eq 0 ] && pass about_contract || fail about_contract "missing: ${missing[*]}"
}

# AC10: no user-visible "iMCP" string literal in App/ or CLI/ outside the allowlist.
ALLOWLIST='me\.mattt\.iMCP|Application Support/iMCP|appendingPathComponent\("iMCP"\)|Based on iMCP|github\.com/mattt/iMCP|legacyServerKey = "iMCP"'
check_source_strings() {
    local hits
    hits=$(rg -n --glob '*.swift' --glob '*.plist' '"[^"]*iMCP[^"]*"' "$1/App" "$1/CLI" | rg -v '^\S+:\d+:\s*//' | rg -v "$ALLOWLIST" || true)
    [ -z "$hits" ] && pass source_strings || fail source_strings "$(wc -l <<<"$hits" | tr -d ' ') literal(s), first: $(head -1 <<<"$hits")"
}

# AC11: MIT notice kept, fork notice added.
check_license() {
    local f="$1/LICENSE.md"
    if grep -qF "Copyright 2025 Mattt" "$f" && grep -qF "Copyright 2026 Joe Cotellese" "$f"; then
        pass license
    else
        fail license "LICENSE.md lacks one of the two copyright lines"
    fi
}

# AC12: the reminders e2e script targets Pontemac by default.
check_reminders_default() {
    grep -qF '/Applications/Pontemac.app/Contents/MacOS/pontemac-server' "$1/scripts/e2e-reminders.sh" \
        && pass reminders_default || fail reminders_default "e2e-reminders.sh default SERVER is not Pontemac"
}

# Reads serverInfo.name from an initialize response on stdin.
server_name() { jq -r 'select(.id == 1) | .result.serverInfo.name // empty' 2>/dev/null | head -1; }

# AC7: with upstream iMCP also running, pontemac-server reaches Pontemac.
check_server_info() {
    local app="$1" name
    [ -x "$app/Contents/MacOS/pontemac-server" ] || { fail server_info "pontemac-server not installed"; return; }
    if [ -d "$UPSTREAM_APP" ]; then open -g "$UPSTREAM_APP"; else echo "NOTE upstream $UPSTREAM_APP absent; coexistence not exercised"; fi
    open -g "$app"
    sleep 3
    name=$( (printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e-branding","version":"0"}}}'; sleep 4) \
        | "$app/Contents/MacOS/pontemac-server" 2>/dev/null | server_name || true)
    [ "$name" = "Pontemac" ] && pass server_info || fail server_info "serverInfo.name is '$name'"
}

# Feeds the assertions doctored inputs so a broken assertion shows up without a build.
self_test() {
    local tmp good bad
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    good="$tmp/good/Pontemac.app"
    bad="$tmp/bad/iMCP.app"
    mkdir -p "$good/Contents/MacOS" "$bad/Contents/MacOS"
    printf '#!/bin/sh\n' >"$good/Contents/MacOS/pontemac-server"
    chmod +x "$good/Contents/MacOS/pontemac-server"
    plutil -create xml1 "$good/Contents/Info.plist"
    plutil -insert CFBundleIdentifier -string com.joecotellese.pontemac "$good/Contents/Info.plist"
    plutil -insert CFBundleName -string Pontemac "$good/Contents/Info.plist"
    plutil -insert NSHumanReadableCopyright -string "© 2026 Joe Cotellese" "$good/Contents/Info.plist"
    plutil -insert NSBonjourServices -json '["_pontemac._tcp"]' "$good/Contents/Info.plist"
    plutil -create xml1 "$bad/Contents/Info.plist"
    plutil -insert CFBundleIdentifier -string com.appjawn.iMCP "$bad/Contents/Info.plist"
    plutil -insert CFBundleName -string iMCP "$bad/Contents/Info.plist"
    plutil -insert SUFeedURL -string https://downloads.imcp.app/appcast.xml "$bad/Contents/Info.plist"
    plutil -insert NSHumanReadableCopyright -string "© 2026 Joe Cotellese" "$bad/Contents/Info.plist"
    plutil -insert NSBonjourServices -json '["_mcp._tcp"]' "$bad/Contents/Info.plist"
    mkdir -p "$tmp/src/App/Views" "$tmp/src/CLI" "$tmp/src/scripts"
    cat >"$tmp/src/App/Views/AboutWindow.swift" <<'EOF'
Text("Pontemac").accessibilityIdentifier("aboutAppNameText")
Text(copyright).accessibilityIdentifier("aboutCopyrightText")
Link("pontemac@cotellese.me", destination: URL(string: "mailto:pontemac@cotellese.me")!).accessibilityIdentifier("aboutContactLink")
Link("Source on GitHub", destination: URL(string: "https://github.com/JoeCotellese/pontemac-mcp")!).accessibilityIdentifier("aboutRepositoryLink")
Link("Based on iMCP by Mattt", destination: URL(string: "https://github.com/mattt/iMCP")!).accessibilityIdentifier("aboutBasedOnLink")
Button("Report an Issue") { open(URL(string: "https://github.com/JoeCotellese/pontemac-mcp/issues/new")!) }.accessibilityIdentifier("aboutReportIssueButton")
Text("Mac is a trademark of Apple Inc., registered in the U.S. and other countries.").accessibilityIdentifier("aboutTrademarkText")
EOF
    printf 'let key = "me.mattt.iMCP.messagesDatabaseBookmark"\nlet t = "_pontemac._tcp"\nstatic let legacyServerKey = "iMCP"\n' >"$tmp/src/CLI/main.swift"
    printf 'Copyright 2026 Joe Cotellese\nCopyright 2025 Mattt (https://mat.tt)\n' >"$tmp/src/LICENSE.md"
    printf 'SERVER="${IMCP_SERVER:-/Applications/Pontemac.app/Contents/MacOS/pontemac-server}"\n' >"$tmp/src/scripts/e2e-reminders.sh"

    local out want_pass want_fail
    out=$(check_bundle_layout "$good"; check_bundle_id "$good"; check_info_plist "$good"; check_bundle_name "$good"
        check_bonjour_type "$good" "$tmp/src"; check_about_contract "$tmp/src"; check_source_strings "$tmp/src"
        check_license "$tmp/src"; check_reminders_default "$tmp/src"
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"Pontemac","version":"1.4.0"}}}' | server_name)
    want_pass=$(grep -c '^PASS' <<<"$out" || true)

    # Each About value fails on its own, including the repository URL with /issues/new still present.
    local about="$tmp/src/App/Views/AboutWindow.swift" about_out="" m about_fail
    cp "$about" "$tmp/About.good"
    for m in 's#pontemac-mcp")!)#example.com")!)#' 's#Based on iMCP by Mattt#Based on iMCP#' 's#"Report an Issue"#"Report an Issue..."#'; do
        cp "$tmp/About.good" "$about"
        sed -i '' "$m" "$about"
        about_out="$about_out
$(check_about_contract "$tmp/src")"
    done
    cp "$tmp/About.good" "$about"
    printf 'Link("Report", destination: URL(string: "https://github.com/mattt/iMCP/issues")!)\n' >>"$about"
    about_out="$about_out
$(check_about_contract "$tmp/src")"
    cp "$tmp/About.good" "$about"
    about_fail=$(grep -c '^FAIL about_contract' <<<"$about_out" || true)

    # The legacy-key allowance covers only its own declaration, not other uses of the key.
    local strings_out strings_fail
    cp "$tmp/src/CLI/main.swift" "$tmp/main.good"
    printf 'mcpServers["iMCP"] = value\n' >>"$tmp/src/CLI/main.swift"
    strings_out=$(check_source_strings "$tmp/src")
    cp "$tmp/main.good" "$tmp/src/CLI/main.swift"
    strings_fail=$(grep -c '^FAIL source_strings' <<<"$strings_out" || true)

    printf 'Text("Connected to iMCP")\nlet t = "_mcp._tcp"\n' >>"$tmp/src/CLI/main.swift"
    sed -i '' 's/aboutTrademarkText/x/' "$tmp/src/App/Views/AboutWindow.swift"
    printf 'Copyright 2025 Mattt\n' >"$tmp/src/LICENSE.md"
    printf 'SERVER=/Applications/iMCP.app/Contents/MacOS/imcp-server\n' >"$tmp/src/scripts/e2e-reminders.sh"
    out="$out
$(check_bundle_layout "$bad"; check_bundle_id "$bad"; check_info_plist "$bad"; check_bundle_name "$bad"
        check_bonjour_type "$bad" "$tmp/src"; check_about_contract "$tmp/src"; check_source_strings "$tmp/src"
        check_license "$tmp/src"; check_reminders_default "$tmp/src"
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"iMCP","version":"1.4.0"}}}' | server_name)"
    want_fail=$(grep -c '^FAIL' <<<"$out" || true)

    if [ "$want_pass" -eq 9 ] && [ "$want_fail" -eq 9 ] && [ "$about_fail" -eq 4 ] && [ "$strings_fail" -eq 1 ] && grep -qx Pontemac <<<"$out" && grep -qx iMCP <<<"$out"; then
        echo "SELF-TEST PASS (9 positive, 9 negative, 4 About mutations, legacy key use caught, serverInfo parsed both ways)"
        FAILURES=0
    else
        echo "$out$about_out
$strings_out"
        echo "SELF-TEST FAIL (positive passes: $want_pass/9, negative fails: $want_fail/9, About mutations caught: $about_fail/4, legacy key use caught: $strings_fail/1)"
        FAILURES=1
    fi
}

if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit "$FAILURES"
fi

check_bundle_layout "$APP"
check_bundle_id "$APP"
check_info_plist "$APP"
check_bundle_name "$APP"
check_bonjour_type "$APP" "$ROOT"
check_about_contract "$ROOT"
check_source_strings "$ROOT"
check_license "$ROOT"
check_reminders_default "$ROOT"
check_server_info "$APP"

echo
[ "$FAILURES" -eq 0 ] && echo "ALL PASS" || echo "$FAILURES FAILURE(S)"
exit $((FAILURES > 0))
