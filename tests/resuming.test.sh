#!/bin/sh
# resuming.test.sh -- tests for the resuming skill's state.sh and the hook.
#
# Runs state.sh against a scratch repo with a bare origin and a fake `gh` on
# PATH that serves fixture JSON: no issue-tracker config (hook silent), `gh`
# failing (hook silent, report says unreached), a hung `gh` (hook silent
# within its budget), each of the six weighing cases, and label strings read
# from triage-labels.md. Touches nothing outside its own mktemp directory.
#
# Usage: sh tests/resuming.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
state="$root/plugins/mp-ported-skills/skills/resuming/scripts/state.sh"
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
has() { # <name> <needle> <haystack>
    case $3 in *"$2"*) pass=$((pass + 1)) ;; *) fail=$((fail + 1)); printf 'FAIL %s\n  missing: %s\n  in: %s\n' "$1" "$2" "$3" ;; esac
}
next() { printf '%s\n' "$1" | sed -n 's/^next: //p'; }
runner() { printf '%s\n' "$1" | sed -n 's/^runner-up: //p'; }
ideas="/grill-with-docs on a new idea, or /improve-codebase-architecture (you type these; they are user-invoked)"
case6_later="6 nothing else in motion: $ideas"

# --- fake gh ----------------------------------------------------------------
mkdir -p "$work/bin" "$work/gh"
cat >"$work/bin/gh" <<'EOF'
#!/bin/sh
[ -n "${FAKE_GH_SLEEP:-}" ] && sleep "$FAKE_GH_SLEEP"
[ -n "${FAKE_GH_FAIL:-}" ] && { echo "gh: not logged in" >&2; exit 1; }
case "$1 $2" in
    "api user") echo '{"login":"me"}' ;;
    "api "*/comments*) n=${2%/comments*}; n=${n##*/}; cat "$FAKE_GH/comments-$n.json" ;;
    "api "*/issues*) cat "$FAKE_GH/issues.json" ;;
    "pr list") cat "$FAKE_GH/prs.json" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$work/bin/gh"
PATH="$work/bin:$PATH"
export FAKE_GH="$work/gh"
unset FAKE_GH_FAIL FAKE_GH_SLEEP MP_RESUME_BUDGET 2>/dev/null || true

issues() { printf '%s' "$1" >"$FAKE_GH/issues.json"; }
prs() { printf '%s' "$1" >"$FAKE_GH/prs.json"; }
# issue <n> <labels csv> [blocked_by] [body]
issue() {
    jq -nc --argjson n "$1" --arg l "$2" --argjson d "${3:-0}" --arg b "${4:-}" \
        '{number: $n, title: "t\($n)", body: $b, comments: 0,
          labels: ($l | split(",") | map(select(. != "") | {name: .})),
          issue_dependencies_summary: {blocked_by: $d}}'
}
list() { printf '%s\n' "$@" | jq -sc .; }

# --- scratch repo -----------------------------------------------------------
git init -q --bare "$work/origin.git"
proj="$work/proj"
git init -q -b main "$proj"
mkdir -p "$proj/docs/agents"
cp "$root/docs/agents/issue-tracker.md" "$root/docs/agents/triage-labels.md" "$proj/docs/agents/"
g() { git -C "$proj" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
g add -A
g commit -qm init
g remote add origin "$work/origin.git"
g push -qu origin main
g remote set-head origin main
run() { sh "$state" "$@" "$proj" </dev/null 2>&1; }
hook() { CLAUDE_PROJECT_DIR=$proj sh "$state" --hook </dev/null 2>&1; }

# --- silence ----------------------------------------------------------------
issues '[]'
prs '[]'
bare="$work/bare"
git init -q "$bare"
check "no config: hook silent" "" "$(CLAUDE_PROJECT_DIR=$bare sh "$state" --hook </dev/null 2>&1)"
has "no config: report names setup" "no docs/agents/issue-tracker.md; run /setup-matt-pocock-skills (you type it; user-invoked)" "$(sh "$state" "$bare" </dev/null 2>&1)"

check "gh failing: hook silent" "" "$(FAKE_GH_FAIL=1 hook)"
out=$(FAKE_GH_FAIL=1 run)
has "gh failing: report says unreached" "tracker: GitHub, UNREACHED" "$out"
has "gh failing: no confident case" "undecided" "$(next "$out")"
check "gh failing: no runner-up known" "none known: the tracker was not read" "$(runner "$out")"

start=$(date +%s)
out=$(FAKE_GH_SLEEP=5 MP_RESUME_BUDGET=1 hook)
took=$(($(date +%s) - start))
check "gh hung: hook silent" "" "$out"
[ "$took" -lt 4 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL gh hung: took ${took}s"; }

# --- the six cases ----------------------------------------------------------
out=$(run)
check "case 6: nothing in motion" "6 nothing in motion" "$(next "$out")"
check "case 6: runner-up names the suggestions" "$ideas" "$(runner "$out")"
out=$(hook)
has "case 6: hook states it" "next: 6 nothing in motion" "$out"
has "case 6: hook carries the runner-up" "runner-up: $ideas" "$out"
has "hook: instruction line" "Do not ask what they are working on." "$out"
has "hook: user-invoked commands are for the user to type" "never call them missing or swap in a model-invocable skill" "$out"

issues "$(list "$(issue 20 wayfinder:map)" "$(issue 21 wayfinder:task)")"
out=$(run)
check "case 5: wayfinder map" "5 /wayfinder (you type it; user-invoked): #20 t20" "$(next "$out")"
check "case 5: runner-up falls to case 6" "$case6_later" "$(runner "$out")"

g commit -q --allow-empty -m 'Fix the thing' -m 'Closes #30'
g push -q
issues "$(list "$(issue 20 wayfinder:map)" "$(issue 30 ready-for-agent)")"
out=$(run)
check "case 4: open but closed on main" "4 tracker and repo disagree: close #30 t30 (as of the last read: confirm with gh issue view first)" "$(next "$out")"
check "case 4: runner-up is case 5" "5 /wayfinder (you type it; user-invoked): #20 t20" "$(runner "$out")"
has "case 4: not offered as ready" "ready, blockers closed: none" "$out"

issues "$(list "$(issue 30 enhancement)" "$(issue 31 needs-triage)")"
out=$(run)
check "case 3: needs-triage" "3 /triage (you type it; user-invoked): 1 unlabelled, 1 needs-triage, replied needs-info: none" "$(next "$out")"
check "case 3: runner-up is case 4" "4 tracker and repo disagree: close #30 t30 (as of the last read: confirm with gh issue view first)" "$(runner "$out")"

printf '[{"user":{"login":"me"}},{"user":{"login":"reporter"}}]' >"$FAKE_GH/comments-40.json"
printf '[{"user":{"login":"reporter"}},{"user":{"login":"me"}}]' >"$FAKE_GH/comments-41.json"
issues "$(list "$(issue 40 needs-info | jq -c '.comments = 2')" "$(issue 41 needs-info | jq -c '.comments = 2')")"
check "case 3: needs-info replied" "3 /triage (you type it; user-invoked): 0 unlabelled, 0 needs-triage, replied needs-info: #40" "$(next "$(run)")"
issues "$(list "$(issue 41 needs-info | jq -c '.comments = 2')")"
check "case 6: needs-info awaiting reporter" "6 nothing in motion" "$(next "$(run)")"

issues "$(list "$(issue 31 needs-triage)" "$(issue 50 ready-for-agent 1)" \
    "$(issue 51 ready-for-agent 0 'Blocked by: #31')" "$(issue 52 ready-for-agent 0 'Blocked by: #9')" \
    "$(issue 53 ready-for-agent)")"
out=$(run)
check "case 2: first unblocked ready" "2 /implement #52 (you type it; user-invoked): #52 t52" "$(next "$out")"
has "case 2: skips native and body blockers" "ready, blockers closed: #52 t52; #53 t53" "$out"
check "case 2: runner-up is case 3" "3 /triage (you type it; user-invoked): 0 unlabelled, 1 needs-triage, replied needs-info: none" "$(runner "$out")"

prs '[{"number":60,"title":"fork pr","headRefName":"x","isCrossRepository":true}]'
check "fork PR is not work in flight" "2 /implement #52 (you type it; user-invoked): #52 t52" "$(next "$(run)")"
prs '[{"number":61,"title":"own pr","headRefName":"y","isCrossRepository":false}]'
out=$(run)
has "case 1: own open PR" "1 work in flight: open PR #61 own pr [y]" "$(next "$out")"
check "case 1: runner-up is case 2" "2 /implement #52 (you type it; user-invoked): #52 t52" "$(runner "$out")"
prs '[]'

echo x >"$proj/scratch"
check "case 1: uncommitted" "1 work in flight: 1 uncommitted paths" "$(next "$(run)")"
check "case 1: git-only runner-up when gh fails" "none known: the tracker was not read" "$(runner "$(FAKE_GH_FAIL=1 run)")"
command rm -f "$proj/scratch"
g commit -q --allow-empty -m wip
check "case 1: unpushed" "1 work in flight: 1 unpushed commits" "$(next "$(run)")"
g push -q
g checkout -q -b feature
check "case 1: off the default branch" "1 work in flight: on feature not main" "$(next "$(run)")"
g checkout -q main

# --- label strings from triage-labels.md ------------------------------------
sed 's/^\(| `ready-for-agent` *| \)`ready-for-agent`/\1`AFK`/' "$root/docs/agents/triage-labels.md" >"$proj/docs/agents/triage-labels.md"
g commit -qam 'Map ready-for-agent to AFK'
g push -q
issues "$(list "$(issue 70 AFK)" "$(issue 71 ready-for-agent)")"
out=$(run)
check "mapped label: ready by its string" "2 /implement #70 (you type it; user-invoked): #70 t70" "$(next "$out")"
has "mapped label: counted under its string" "1 AFK" "$out"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
