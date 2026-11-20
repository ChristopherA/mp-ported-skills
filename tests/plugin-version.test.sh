#!/bin/sh
# plugin-version.test.sh -- a session running an installed plugin older
# than the one the checkout's default branch carries is told so at start
# (#238): resuming's state.sh prints a `plugin:` line, and supervise's
# step.sh hands it on on stderr, keeping its one stdout line.
#
# Copies the plugin into a folder shaped like the plugin cache
# (<marketplace>/<plugin>/<version>) and runs the scripts from there against
# a scratch repo whose origin/main carries the plugin's plugin.json at a
# chosen version. Touches nothing outside its own mktemp directory.
#
# Usage: sh tests/plugin-version.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
work=$(CDPATH= cd -- "$work" && pwd -P)
trap 'command rm -rf "$work"' EXIT

pass=0 fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}

unset CLAUDE_CODE_SESSION_ATTENDED MP_SESSION_TITLE MP_RESUME_BUDGET

# The plugin as the cache holds it, at <version>.
cached() { # <version> -- prints the copy's root
    d="$work/cache/mkt/mp-ported-skills/$1"
    if [ ! -d "$d" ]; then
        mkdir -p "$d"
        command cp -R "$root/plugins/mp-ported-skills/." "$d/"
    fi
    printf '%s\n' "$d"
}

# A scratch repo whose origin/main holds the plugin's plugin.json at
# <version>, and a local main that may move past it.
git init -q --bare "$work/origin.git"
git init -q -b main "$work/repo"
mkdir -p "$work/repo/plugins/mp-ported-skills/.claude-plugin"
at_version() { # <version> -- writes plugin.json at <version>
    printf '{"name": "mp-ported-skills", "version": "%s"}\n' "$1" \
        >"$work/repo/plugins/mp-ported-skills/.claude-plugin/plugin.json"
}
commit() { git -C "$work/repo" -c commit.gpgsign=false commit -q -am "$1"; }
at_version 0.8.111
git -C "$work/repo" add -A
commit 'Plugin at 0.8.111'
git -C "$work/repo" remote add origin "$work/origin.git"
git -C "$work/repo" push -q -u origin main 2>/dev/null

plugin_line() { # <plugin root> -- state.sh's plugin: line, run from it
    sh "$1/skills/resuming/scripts/state.sh" "$work/repo" </dev/null 2>/dev/null | sed -n 's/^plugin: //p'
}
update="command claude plugin marketplace update mkt && command claude plugin update mp-ported-skills@mkt"
stale="mp-ported-skills 0.8.18 is loaded, older than 0.8.111 on origin/main; run \`$update\` through Bash, then type /reload-plugins"

check "state: an older installed version is named, with the update and the reload" \
    "$stale" \
    "$(plugin_line "$(cached 0.8.18)")"
# Compared by number, not as text: 0.8.111 sorts before 0.8.18 as text.
check "state: a newer installed version prints nothing" "" "$(plugin_line "$(cached 0.8.200)")"
check "state: the same version prints nothing" "" "$(plugin_line "$(cached 0.8.111)")"
check "state: a plugin run from a folder that is no cache version prints nothing" "" \
    "$(plugin_line "$root/plugins/mp-ported-skills")"

# A bump on local main that is not pushed cannot be installed yet: the
# update fetches from the remote, so the line reads origin/main.
at_version 0.8.300
commit 'Plugin at 0.8.300'
check "state: an unpushed bump is not what the line compares with" \
    "$stale" \
    "$(plugin_line "$(cached 0.8.18)")"
# With no origin remote, only the local branch is there, and a version on
# it may not be pushed, so nothing is said.
git clone -q "$work/repo" "$work/clone" 2>/dev/null
git -C "$work/clone" remote remove origin
check "state: no line without an origin ref to compare with" "" \
    "$(sh "$(cached 0.8.18)/skills/resuming/scripts/state.sh" "$work/clone" </dev/null 2>/dev/null | sed -n 's/^plugin: //p')"
git -C "$work/repo" reset -q --hard HEAD~1

# A repo that does not carry the plugin.
git init -q -b main "$work/other"
printf 'x\n' >"$work/other/f"
git -C "$work/other" add -A
git -C "$work/other" -c commit.gpgsign=false commit -q -m x
check "state: a repo without the plugin prints nothing" "" \
    "$(sh "$(cached 0.8.18)/skills/resuming/scripts/state.sh" "$work/other" </dev/null 2>/dev/null | sed -n 's/^plugin: //p')"

# step.sh: its stdout stays the one step line next.sh reads, and the
# plugin: line goes to stderr, where the supervisor sees it.
s=$(cached 0.8.18)/skills/supervise/scripts/step.sh
out=$(sh "$s" "$work/repo" </dev/null 2>"$work/step.err")
check "step: stdout is one line" 1 "$(printf '%s\n' "$out" | grep -c '^')"
check "step: stdout is not the plugin line" "" "$(printf '%s\n' "$out" | grep '^plugin: ')"
check "step: stderr carries the plugin line" \
    "plugin: $stale" \
    "$(command cat "$work/step.err")"
sh "$(cached 0.8.111)/skills/supervise/scripts/step.sh" "$work/repo" </dev/null 2>"$work/step.err" >/dev/null
check "step: no stderr when the loaded version is current" 0 "$(wc -c <"$work/step.err" | tr -d ' ')"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
