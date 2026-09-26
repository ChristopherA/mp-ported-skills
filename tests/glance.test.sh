#!/bin/sh
# glance.test.sh -- tests for the glance skill's glance.sh.
#
# Runs glance.sh against a scratch record directory and scratch profiles:
# a session with a record, a profile with the status line installed but no
# record yet, a profile without it, and a missing session id. Touches no real
# profile and nothing under /tmp outside its own mktemp directory.
#
# Usage: sh tests/glance.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
glance="$root/plugins/mp-ported-skills/skills/glance/scripts/glance.sh"
work=$(mktemp -d)
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

proj="$work/proj"; mkdir -p "$proj"
export WORKSTREAM_KIT_CONTEXT_DIR="$work/ctx"
mkdir -p "$WORKSTREAM_KIT_CONTEXT_DIR"
unset MP_SMART_ZONE_K CLAUDE_CODE_SESSION_ID 2>/dev/null || true
# A profile with the status line installed, and one without.
installed="$work/.claude-installed"; mkdir -p "$installed/scripts"
: > "$installed/scripts/status-line.sh"
bare="$work/.claude-bare"; mkdir -p "$bare"

record() { # <session> <tokens>
    printf '{"session_id":"%s","project_dir":"%s","tokens":%s,"remaining_pct":90,"updated":"2026-01-01T00:00:00Z"}\n' \
        "$1" "$proj" "$2" > "$WORKSTREAM_KIT_CONTEXT_DIR/claude-$1-zone.json"
}
run() { # <profile> <args...>
    p=$1; shift
    CLAUDE_CONFIG_DIR="$p" sh "$glance" "$@" </dev/null
}

record s1 61500
check "reading: printed verbatim" "41% of zone" "$(run "$installed" "$proj" s1)"

check "installed, no record: no reading yet" \
    "No reading yet: the status line writes one after this session's first response in a terminal." \
    "$(run "$installed" "$proj" s2)"

check "not installed: points to setup" \
    "No reading: this profile has no status line. /setup-mp-ported-skills turns one on." \
    "$(run "$bare" "$proj" s2)"

# The skill passes its session-id substitution; when that comes through empty,
# the id Claude Code exports to the shell stands in.
check "no id: falls back to the exported one" "41% of zone" \
    "$(CLAUDE_CODE_SESSION_ID=s1 run "$installed" "$proj" "")"
out=$(run "$installed" "$proj" "" 2>&1); rc=$?
check "no id at all: says so, not 'no reading yet'" \
    "No reading: this session's id is not available." "$out"
check "no id at all: exit 0" "0" "$rc"
check "no project dir: the working directory" "41% of zone" \
    "$(cd "$proj" && CLAUDE_CODE_SESSION_ID=s1 run "$installed")"

# Without jq, --zone prints nothing; that must not read as "no reading yet".
nojq="$work/nojq"; mkdir -p "$nojq"
for t in sh dirname; do ln -s "$(command -v $t)" "$nojq/$t"; done
check "no jq: says so" "No reading: jq is not installed, and the status line needs it." \
    "$(PATH="$nojq" run "$installed" "$proj" s1)"

echo "glance: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
