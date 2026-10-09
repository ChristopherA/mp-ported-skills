#!/bin/sh
# capturing-live-check.test.sh -- tests for the capturing skill's
# live-check.sh (#194): the relabel to ready-for-human of a ticket that
# waits on a live check, and the move after its parent's last open
# ready-for-agent child, read over every page of the parent's sub-issues.
#
# Runs live-check.sh against a fake `gh` on PATH that serves fixture JSON
# and logs every write. Touches nothing outside its own mktemp directory.
#
# Usage: sh tests/capturing-live-check.test.sh

set -u
unset CLAUDE_CODE_SESSION_ATTENDED FAKE_GH_PARENT_FAIL 2>/dev/null || true

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script="$root/plugins/mp-ported-skills/skills/capturing/scripts/live-check.sh"
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

# --- fake gh ----------------------------------------------------------------
# Serves repos/{owner}/{repo}/issues/<n>, .../<n>/parent (a 404 when there is
# no parent-<n>.json) and .../<n>/sub_issues, whose second page comes only
# with --paginate, printed as gh prints pages: one array after another.
# `gh issue edit` and a PATCH are logged to $FAKE_GH/log.
mkdir -p "$work/bin" "$work/gh" "$work/proj"
cat >"$work/bin/gh" <<'EOF'
#!/bin/sh
path=
for a in "$@"; do case $a in repos/*) path=$a ;; esac; done
case "$1 $2" in
    "issue edit") shift 2; echo "edit $*" >>"$FAKE_GH/log"; exit 0 ;;
esac
case " $* " in
    *" --method PATCH "*)
        # The real API answers 422 to a priority change missing either id.
        case " $* " in *" sub_issue_id="[0-9]*) ;; *) echo 'gh: Validation Failed (HTTP 422)' >&2; exit 1 ;; esac
        case " $* " in *" after_id="[0-9]*) ;; *) echo 'gh: Validation Failed (HTTP 422)' >&2; exit 1 ;; esac
        echo "$*" >>"$FAKE_GH/log"; exit 0 ;;
esac
[ "$1" = api ] || exit 1
case $path in
    */parent)
        [ -n "${FAKE_GH_PARENT_FAIL:-}" ] && { echo 'gh: Server Error (HTTP 500)' >&2; exit 1; }
        n=${path%/parent}; n=${n##*/}
        [ -f "$FAKE_GH/parent-$n.json" ] || { echo '{"message":"No parent issue found","status":"404"}'; echo 'gh: No parent issue found (HTTP 404)' >&2; exit 1; }
        cat "$FAKE_GH/parent-$n.json" ;;
    */sub_issues*)
        n=${path%/sub_issues*}; n=${n##*/}
        [ -f "$FAKE_GH/sub-$n.fail" ] && { echo 'gh: Server Error (HTTP 500)' >&2; exit 1; }
        cat "$FAKE_GH/sub-$n.json"
        case " $* " in *" --paginate "*)
            if [ -f "$FAKE_GH/sub-$n.page2.json" ]; then cat "$FAKE_GH/sub-$n.page2.json"; fi ;; esac ;;
    repos/*/issues/[0-9]*) n=${path##*/}; cat "$FAKE_GH/issue-$n.json" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$work/bin/gh"
PATH="$work/bin:$PATH"
export FAKE_GH="$work/gh"
[ "$(command -v gh)" = "$work/bin/gh" ] || { echo "FAIL fake gh is not first on PATH"; exit 1; }

# issue <n> <labels csv> [state]: id is n*1000, so an id never equals a number.
issue() {
    jq -nc --argjson n "$1" --arg l "$2" --arg s "${3:-open}" \
        '{id: ($n * 1000), number: $n, title: "t\($n)", state: $s,
          labels: ($l | split(",") | map(select(. != "") | {name: .}))}'
}
list() { printf '%s\n' "$@" | jq -sc .; }
reset() { command rm -f "$FAKE_GH"/*; : >"$FAKE_GH/log"; }
run() { (cd "$work/proj" && sh "$script" "$@" </dev/null 2>&1); }
log() { command cat "$FAKE_GH/log"; }
patch="gh api --method PATCH 'repos/{owner}/{repo}/issues/40/sub_issues/priority'"

# --- the #118 case, over two pages ------------------------------------------
# Page 1 holds closed children, #118 and #146; page 2 holds #150, the last
# open ready-for-agent child, and a needs-triage child after it.
reset
issue 118 ready-for-agent >"$FAKE_GH/issue-118.json"
issue 40 ready-for-human,in-motion >"$FAKE_GH/parent-118.json"
list "$(issue 10 ready-for-agent closed)" "$(issue 11 ready-for-agent closed)" \
    "$(issue 118 ready-for-agent)" "$(issue 131 ready-for-human)" "$(issue 146 ready-for-agent)" \
    >"$FAKE_GH/sub-40.json"
list "$(issue 150 ready-for-agent)" "$(issue 160 needs-triage)" "$(issue 12 ready-for-agent closed)" \
    >"$FAKE_GH/sub-40.page2.json"
out=$(run 118)
check "dry run: relabel and reorder after the last ready-for-agent child, read over both pages" \
"relabel: gh issue edit 118 --remove-label ready-for-agent --add-label ready-for-human
parent: #40
reorder: $patch -F sub_issue_id=118000 -F after_id=150000
after: #150, the last open ready-for-agent child of #40" "$out"
check "dry run: writes nothing" "" "$(log)"

out=$(run --apply 118); rc=$?
check "apply: exit 0" 0 "$rc"
check "apply: relabels, then reorders by database id" \
"edit 118 --remove-label ready-for-agent --add-label ready-for-human
api --method PATCH repos/{owner}/{repo}/issues/40/sub_issues/priority -F sub_issue_id=118000 -F after_id=150000" "$(log)"
check "apply: says what it applied" "applied: relabel, reorder" "$(printf '%s\n' "$out" | tail -n 1)"

# --- already ready-for-human: only the move ---------------------------------
reset
issue 118 ready-for-human >"$FAKE_GH/issue-118.json"
issue 40 ready-for-human >"$FAKE_GH/parent-118.json"
list "$(issue 118 ready-for-human)" "$(issue 146 ready-for-agent)" >"$FAKE_GH/sub-40.json"
check "already relabelled: no relabel, still the move" \
"relabel: none, #118 is already ready-for-human
parent: #40
reorder: $patch -F sub_issue_id=118000 -F after_id=146000
after: #146, the last open ready-for-agent child of #40" "$(run 118)"
run --apply 118 >/dev/null
check "already relabelled: apply only reorders" \
"api --method PATCH repos/{owner}/{repo}/issues/40/sub_issues/priority -F sub_issue_id=118000 -F after_id=146000" "$(log)"

# --- nothing to move --------------------------------------------------------
reset
issue 118 ready-for-agent >"$FAKE_GH/issue-118.json"
issue 40 ready-for-human >"$FAKE_GH/parent-118.json"
list "$(issue 146 ready-for-agent)" "$(issue 118 ready-for-agent)" "$(issue 131 ready-for-human)" >"$FAKE_GH/sub-40.json"
check "already after every ready-for-agent child: relabel only" \
"relabel: gh issue edit 118 --remove-label ready-for-agent --add-label ready-for-human
parent: #40
reorder: none, no open ready-for-agent child of #40 follows #118" "$(run 118)"
run --apply 118 >/dev/null
check "already after: apply only relabels" \
"edit 118 --remove-label ready-for-agent --add-label ready-for-human" "$(log)"

reset
issue 118 ready-for-agent >"$FAKE_GH/issue-118.json"
check "no parent: relabel only" \
"relabel: gh issue edit 118 --remove-label ready-for-agent --add-label ready-for-human
parent: none
reorder: none, #118 has no parent" "$(run 118)"

# --- reads that fail change nothing -----------------------------------------
reset
issue 118 ready-for-agent >"$FAKE_GH/issue-118.json"
out=$(FAKE_GH_PARENT_FAIL=1 run --apply 118); rc=$?
check "parent read fails: exit 1" 1 "$rc"
check "parent read fails: names the read" "Error: could not read #118's parent: gh: Server Error (HTTP 500)" "$out"
check "parent read fails: writes nothing" "" "$(log)"

issue 40 ready-for-human >"$FAKE_GH/parent-118.json"
: >"$FAKE_GH/sub-40.fail"
out=$(run --apply 118); rc=$?
check "sub-issues read fails: exit 1" 1 "$rc"
check "sub-issues read fails: names the read" "Error: could not read #40's sub-issues: gh: Server Error (HTTP 500)" "$out"
check "sub-issues read fails: writes nothing" "" "$(log)"

# --- label strings from triage-labels.md ------------------------------------
reset
mkdir -p "$work/proj/docs/agents"
printf '| Role | Label | Meaning |\n|---|---|---|\n| `ready-for-agent` | `afk` | x |\n| `ready-for-human` | `hitl` | y |\n' \
    >"$work/proj/docs/agents/triage-labels.md"
issue 118 afk >"$FAKE_GH/issue-118.json"
issue 40 hitl >"$FAKE_GH/parent-118.json"
list "$(issue 118 afk)" "$(issue 146 afk)" "$(issue 147 hitl)" >"$FAKE_GH/sub-40.json"
check "label strings come from triage-labels.md" \
"relabel: gh issue edit 118 --remove-label afk --add-label hitl
parent: #40
reorder: $patch -F sub_issue_id=118000 -F after_id=146000
after: #146, the last open afk child of #40" "$(run 118)"

# A label string is passed to gh as one argument, never run as shell.
reset
printf '| Role | Label | Meaning |\n|---|---|---|\n| `ready-for-agent` | `afk` | x |\n| `ready-for-human` | `hitl;touch$IFS%s` | y |\n' \
    "$work/pwned" >"$work/proj/docs/agents/triage-labels.md"
issue 118 afk >"$FAKE_GH/issue-118.json"
run --apply 118 >/dev/null
check "label string is not run as shell" "no" "$([ -e "$work/pwned" ] && echo yes || echo no)"
check "label string reaches gh whole" "edit 118 --remove-label afk --add-label hitl;touch\$IFS$work/pwned" "$(log)"
command rm -rf "$work/proj/docs"

# --- usage ------------------------------------------------------------------
check "usage: a ticket number is required" "Error: a ticket number is required" "$(run --apply)"
check "usage: the number must be a number" "Error: not a ticket number: #118" "$(run '#118')"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
