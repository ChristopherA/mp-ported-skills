#!/bin/sh
# resuming.test.sh -- tests for the resuming skill's state.sh.
#
# Runs state.sh against a scratch repo with a bare origin and a fake `gh` on
# PATH that serves fixture JSON: no issue-tracker config, `gh` failing (report
# says unreached), a hung `gh` (report says timed out within its budget), each
# of the seven weighing cases, a ticket labelled in-motion or parked, the next
# child of an in-motion parent, the /supervise offer beside /implement (with a
# fake `claude` serving `claude agents`), what each ready ticket unblocks,
# and label strings read from triage-labels.md. Also checks that no plugin
# hook runs state.sh. Touches nothing outside its own mktemp directory.
#
# Usage: sh tests/resuming.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
state="$root/plugins/mp-ported-skills/skills/resuming/scripts/state.sh"
hooks="$root/plugins/mp-ported-skills/hooks/hooks.json"
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
line_of() { printf '%s\n' "$1" | sed -n "s/^$2: //p"; }
ideas="/grill-with-docs on a new idea, or /improve-codebase-architecture (you type these; they are user-invoked)"
case7_later="7 nothing else in motion: $ideas"

# --- fake gh ----------------------------------------------------------------
mkdir -p "$work/bin" "$work/gh"
cat >"$work/bin/gh" <<'EOF'
#!/bin/sh
[ -n "${FAKE_GH_SLEEP:-}" ] && sleep "$FAKE_GH_SLEEP"
[ -n "${FAKE_GH_FAIL:-}" ] && { echo "gh: not logged in" >&2; exit 1; }
case "$1 $2" in
    "api user") echo '{"login":"me"}' ;;
    "api "*/comments*) n=${2%/comments*}; n=${n##*/}; cat "$FAKE_GH/comments-$n.json"
        case " $* " in *" --paginate "*)
            if [ -f "$FAKE_GH/comments-$n.page2.json" ]; then cat "$FAKE_GH/comments-$n.page2.json"; fi ;; esac ;;
    "api "*/sub_issues*) n=${2%/sub_issues*}; n=${n##*/}
        [ -f "$FAKE_GH/sub-$n.fail" ] && exit 1
        if [ -f "$FAKE_GH/sub-$n.json" ]; then cat "$FAKE_GH/sub-$n.json"; else echo '[]'; fi
        # A second page, served only with --paginate, printed as gh prints
        # pages: one array after another.
        case " $* " in *" --paginate "*)
            if [ -f "$FAKE_GH/sub-$n.page2.json" ]; then cat "$FAKE_GH/sub-$n.page2.json"; fi ;; esac ;;
    "api "*/dependencies/blocked_by*) n=${2%/dependencies*}; n=${n##*/}; cat "$FAKE_GH/deps-$n.json"
        case " $* " in *" --paginate "*)
            if [ -f "$FAKE_GH/deps-$n.page2.json" ]; then cat "$FAKE_GH/deps-$n.page2.json"; fi ;; esac ;;
    "api "*/events*) n=${2%/events*}; n=${n##*/}
        [ -f "$FAKE_GH/events-$n.fail" ] && exit 1
        if [ -f "$FAKE_GH/events-$n.json" ]; then cat "$FAKE_GH/events-$n.json"; else echo '[]'; fi ;;
    "api "*/issues*) cat "$FAKE_GH/issues.json"
        case " $* " in *" --paginate "*)
            if [ -f "$FAKE_GH/issues.page2.json" ]; then cat "$FAKE_GH/issues.page2.json"; fi ;; esac ;;
    "pr list") cat "$FAKE_GH/prs.json" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$work/bin/gh"
cat >"$work/bin/claude" <<'EOF'
#!/bin/sh
# Serves `claude agents --json --all` from a fixture; anything else fails.
[ "$*" = "agents --json --all" ] || exit 1
[ -n "${FAKE_CLAUDE_FAIL:-}" ] && { echo "claude: failed" >&2; exit 1; }
cat "$FAKE_GH/agents.json"
EOF
chmod +x "$work/bin/claude"
PATH="$work/bin:$PATH"
export FAKE_GH="$work/gh"
printf '[]' >"$FAKE_GH/agents.json"
# state.sh reads `claude agents`; never let it reach the real one.
[ "$(command -v claude)" = "$work/bin/claude" ] || { echo "FAIL fake claude is not first on PATH"; exit 1; }
unset FAKE_GH_FAIL FAKE_CLAUDE_FAIL FAKE_GH_SLEEP MP_RESUME_BUDGET CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ATTENDED 2>/dev/null || true

issues() { printf '%s' "$1" >"$FAKE_GH/issues.json"; }
prs() { printf '%s' "$1" >"$FAKE_GH/prs.json"; }
# issue <n> <labels csv> [blocked_by] [body]; every issue is in me/proj, and a
# blocker fixture names other/lib for a ticket in another repo.
issue() {
    jq -nc --argjson n "$1" --arg l "$2" --argjson d "${3:-0}" --arg b "${4:-}" \
        '{number: $n, title: "t\($n)", body: $b, comments: 0, state: "open",
          repository_url: "https://api.github.com/repos/me/proj",
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

# --- no session-start hook --------------------------------------------------
check "no hook runs state.sh" "0" \
    "$(jq '[.hooks[][].hooks[].command | select(test("state\\.sh"))] | length' "$hooks")"

# --- no tracker, unreached, timed out --------------------------------------
issues '[]'
prs '[]'
bare="$work/bare"
git init -q "$bare"
has "no config: report names setup" "no docs/agents/issue-tracker.md; run /setup-matt-pocock-skills (you type it; user-invoked)" "$(sh "$state" "$bare" </dev/null 2>&1)"

out=$(FAKE_GH_FAIL=1 run)
has "gh failing: report says unreached" "tracker: GitHub, UNREACHED" "$out"
has "gh failing: no confident case" "undecided" "$(next "$out")"
check "gh failing: no runner-up known" "none known: the tracker was not read" "$(runner "$out")"

start=$(date +%s)
out=$(FAKE_GH_SLEEP=5 MP_RESUME_BUDGET=1 run)
took=$(($(date +%s) - start))
has "gh hung: report says timed out" "timed out after 1s; the lines above are all that was read" "$out"
[ "$took" -lt 4 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL gh hung: took ${took}s"; }

# --- the seven cases --------------------------------------------------------
out=$(run)
check "case 7: nothing in motion" "7 nothing in motion" "$(next "$out")"
check "case 7: runner-up names the suggestions" "$ideas" "$(runner "$out")"
# With no dir, state.sh reads the folder it runs in.
check "case 7: dir defaults to the current folder" "7 nothing in motion" \
    "$(next "$(cd "$proj" && sh "$state" </dev/null 2>&1)")"

issues "$(list "$(issue 20 wayfinder:map)" "$(issue 21 wayfinder:task)")"
out=$(run)
check "case 5: wayfinder map" "5 /wayfinder (you type it; user-invoked): #20 t20" "$(next "$out")"
check "case 5: runner-up falls to case 7" "$case7_later" "$(runner "$out")"

# No commit on main closes a ticket yet, so the closed-by-commit list is empty.
issues "$(list "$(issue 31 ready-for-agent)")"
out=$(run)
has "no closing commits: ready ticket still found" "ready, blockers closed: #31 t31" "$out"
check "no closing commits: no jq error" "" "$(printf '%s\n' "$out" | grep jq)"
# Past 100 open issues, a ticket only on the second page is still read.
list "$(issue 32 ready-for-agent)" >"$FAKE_GH/issues.page2.json"
check "open issues: a ready ticket on the second page" "#31 t31; #32 t32" "$(line_of "$(run)" "ready, blockers closed")"
command rm -f "$FAKE_GH/issues.page2.json"
issues 'not json'
has "open issues unreadable: report says unreached" "tracker: GitHub, UNREACHED: gh api failed (offline, unauthenticated, or no GitHub remote)" "$(run)"
issues "$(list "$(issue 31 ready-for-agent)")"

g commit -q --allow-empty -m 'Fix the thing' -m 'Closes #30'
g push -q
issues "$(list "$(issue 20 wayfinder:map)" "$(issue 30 ready-for-agent)")"
out=$(run)
check "case 4: open but closed on main" "4 tracker and repo disagree: close #30 t30 (as of the last read: confirm with gh issue view first)" "$(next "$out")"
check "case 4: runner-up is case 5" "5 /wayfinder (you type it; user-invoked): #20 t20" "$(runner "$out")"
has "case 4: not offered as ready" "ready, blockers closed: none" "$out"

# A ticket reopened after its closing commit was reopened on purpose (to wait
# for a live check): not a disagreement, and it counts as open work again.
printf '[{"event":"closed","created_at":"2999-01-01T00:00:00Z"},{"event":"reopened","created_at":"2999-01-01T00:05:00Z"}]' >"$FAKE_GH/events-30.json"
out=$(run)
check "case 4: reopened after the commit not listed" "none" "$(line_of "$out" "open but closed by a commit on main")"
check "case 4: reopened ticket is a step again" "2 /implement #30 (you type it; user-invoked): #30 t30" "$(next "$out")"
check "case 4: reopened ticket is ready again" "#30 t30" "$(line_of "$out" "ready, blockers closed")"
# Reopened as ready-for-human to wait for a live check: hand work again.
issues "$(list "$(issue 30 ready-for-human)")"
check "case 4: reopened hand ticket is case 6" "6 by hand: #30 t30" "$(next "$(run)")"
issues "$(list "$(issue 20 wayfinder:map)" "$(issue 30 ready-for-agent)")"
# Reopened before the closing commit: that commit's close never reached GitHub.
printf '[{"event":"closed","created_at":"2000-01-01T00:00:00Z"},{"event":"reopened","created_at":"2000-01-01T00:05:00Z"}]' >"$FAKE_GH/events-30.json"
check "case 4: reopened before the commit still listed" "#30 t30" "$(line_of "$(run)" "open but closed by a commit on main")"
# Events unread: kept in the list, which already says to confirm first.
command rm -f "$FAKE_GH/events-30.json"; : >"$FAKE_GH/events-30.fail"
check "case 4: events unread still listed" "#30 t30" "$(line_of "$(run)" "open but closed by a commit on main")"
command rm -f "$FAKE_GH/events-30.fail"

issues "$(list "$(issue 30 enhancement)" "$(issue 31 needs-triage)")"
out=$(run)
check "case 3: needs-triage" "3 /triage (you type it; user-invoked): 1 unlabelled, 1 needs-triage, replied needs-info: none" "$(next "$out")"
check "case 3: runner-up is case 4" "4 tracker and repo disagree: close #30 t30 (as of the last read: confirm with gh issue view first)" "$(runner "$out")"

printf '[{"user":{"login":"me"}},{"user":{"login":"reporter"}}]' >"$FAKE_GH/comments-40.json"
printf '[{"user":{"login":"reporter"}},{"user":{"login":"me"}}]' >"$FAKE_GH/comments-41.json"
issues "$(list "$(issue 40 needs-info | jq -c '.comments = 2')" "$(issue 41 needs-info | jq -c '.comments = 2')")"
check "case 3: needs-info replied" "3 /triage (you type it; user-invoked): 0 unlabelled, 0 needs-triage, replied needs-info: #40" "$(next "$(run)")"
issues "$(list "$(issue 41 needs-info | jq -c '.comments = 2')")"
check "case 7: needs-info awaiting reporter" "7 nothing in motion" "$(next "$(run)")"
# Past 100 comments, the newest is the second page's last.
printf '[{"user":{"login":"me"}},{"user":{"login":"reporter"}}]' >"$FAKE_GH/comments-41.page2.json"
check "case 3: needs-info replied on the second page" "3 /triage (you type it; user-invoked): 0 unlabelled, 0 needs-triage, replied needs-info: #41" "$(next "$(run)")"
command rm -f "$FAKE_GH/comments-41.page2.json"
printf 'not json' >"$FAKE_GH/comments-41.json"
check "case 7: comments unreadable, not replied" "7 nothing in motion" "$(next "$(run)")"
printf '[{"user":{"login":"reporter"}},{"user":{"login":"me"}}]' >"$FAKE_GH/comments-41.json"

# Hand work: unblocked, unparked ready-for-human tickets, by the body's
# priority line (High, Medium, none, Low), lowest number first within one.
issues "$(list "$(issue 80 ready-for-human 0 'No priority line here.' | jq -c '.title = "t80 (x)"')" \
    "$(issue 81 ready-for-human 0 '**Priority: Low.** Later.')" \
    "$(issue 82 ready-for-human 0 '**Priority: Medium.** Soon.')" \
    "$(issue 83 ready-for-human,parked 0 '**Priority: High.** Waits on a trigger.')" \
    "$(issue 84 ready-for-human 1 '**Priority: High.** Blocked natively.')" \
    "$(issue 85 ready-for-human 0 '**Priority: High.** Blocked in the body.
Blocked by: #80')")"
out=$(run)
check "case 6: highest-priority hand ticket" "6 by hand (Medium): #82 t82" "$(next "$out")"
has "case 6: ranked, parked and blocked left out" "by hand, blockers closed: #82 t82 (Medium); #80 t80 (x); #81 t81 (Low)" "$out"
check "case 6: runner-up is the second hand ticket" "6 by hand: #80 t80 (x)" "$(runner "$out")"
issues "$(list "$(issue 80 ready-for-human 0 'No priority line here.' | jq -c '.title = "t80 (x)"')")"
out=$(run)
check "case 6: no priority, title in parentheses" "6 by hand: #80 t80 (x)" "$(next "$out")"
check "case 6: one hand ticket, runner-up falls to case 7" "$case7_later" "$(runner "$out")"
issues "$(list "$(issue 81 ready-for-human 0 '**Priority: Low.** Later.')" "$(issue 87 ready-for-agent)")"
out=$(run)
check "case 6: runner-up to case 2" "6 by hand (Low): #81 t81" "$(runner "$out")"
issues "$(list "$(issue 81 ready-for-human 0 '**Priority: Low.** Later.')" "$(issue 87 ready-for-agent,parked)")"
out=$(run)
check "case 2: skips a parked ticket" "6 by hand (Low): #81 t81" "$(next "$out")"
has "case 2: parked is not ready" "ready, blockers closed: none" "$out"

# Blockers as bullets under a Blocked by heading, any level or case, up to the
# next heading.
issues "$(list "$(issue 31 needs-triage)" \
    "$(issue 54 ready-for-agent 0 '## Blocked by

- #31')" \
    "$(issue 55 ready-for-agent 0 '### blocked BY
* #31')" \
    "$(issue 56 ready-for-agent 0 '## Blocked by

- #9

## Notes

- #31 is related')" \
    "$(issue 57 ready-for-agent 0 '## Blocked by

None - can start immediately')" \
    "$(issue 58 ready-for-agent 0 'Quotes the forms in a code block:

```
## Blocked by

- #31
Blocked by: #31
```')" \
    "$(issue 59 ready-for-agent 0 '```
~~~
```

## Blocked by

- #31')" \
    "$(issue 60 ready-for-agent 0 '## Blocked by: #31')")"
check "heading blockers: bullets under the heading block, up to the next heading, outside code blocks" "#56 t56; #57 t57; #58 t58" "$(run | sed -n 's/^ready, blockers closed: //p')"

issues "$(list "$(issue 31 needs-triage)" "$(issue 50 ready-for-agent 1)" \
    "$(issue 51 ready-for-agent 0 'Blocked by: #31')" "$(issue 52 ready-for-agent 0 'Blocked by: #9')" \
    "$(issue 53 ready-for-agent)")"
out=$(run)
check "case 2: first unblocked ready" "2 /implement #52 (you type it; user-invoked): #52 t52" "$(next "$out")"
has "case 2: skips native and body blockers" "ready, blockers closed: #52 t52; #53 t53" "$out"
check "case 2: runner-up is case 3" "3 /triage (you type it; user-invoked): 0 unlabelled, 1 needs-triage, replied needs-info: none" "$(runner "$out")"

# A ready-for-human ticket a session left in motion, in a clean repo.
saved_issues=$(cat "$FAKE_GH/issues.json")
issues "$(list "$(issue 24 ready-for-human,in-motion)" "$(issue 25 ready-for-human)" "$(issue 52 ready-for-agent)")"
out=$(run)
check "case 1: ticket in motion" "1 work in flight: in motion #24 t24" "$(next "$out")"
check "case 1: in motion, runner-up is case 2" "2 /implement #52 (you type it; user-invoked): #52 t52" "$(runner "$out")"
has "in motion: its own line" "in motion: #24 t24" "$out"
issues "$(list "$(issue 25 ready-for-human)" "$(issue 52 ready-for-agent)")"
check "unmarked ready-for-human is not in motion" "2 /implement #52 (you type it; user-invoked): #52 t52" "$(next "$(run)")"
issues "$(list "$(issue 30 ready-for-human,in-motion)" "$(issue 52 ready-for-agent)")"
has "in motion: skips a ticket main already closes" "in motion: none" "$(run)"
issues "$(list "$(issue 26 ready-for-agent,in-motion)" "$(issue 52 ready-for-agent)")"
check "in motion: only on a ready-for-human ticket" "2 /implement #26 (you type it; user-invoked): #26 t26" "$(next "$(run)")"

# An in-motion parent with sub-issues: its next child is the step.
issues "$(list "$(issue 24 ready-for-human,in-motion)" "$(issue 52 ready-for-agent)")"
closed() { issue "$@" | jq -c '.state = "closed"'; }
list "$(closed 26 ready-for-human)" "$(issue 27 ready-for-agent 1)" \
    "$(issue 28 ready-for-agent 0 'Blocked by: #9')" "$(issue 29 ready-for-human)" >"$FAKE_GH/sub-24.json"
out=$(run)
check "in-motion parent: next child ready-for-agent" "1 work in flight: in motion #24 t24; next child #28 (ready-for-agent, /implement #28, you type it; user-invoked): t28" "$(next "$out")"
check "in-motion parent: runner-up unchanged" "2 /implement #52 (you type it; user-invoked): #52 t52" "$(runner "$out")"
list "$(issue 26 ready-for-human)" "$(issue 28 ready-for-agent)" >"$FAKE_GH/sub-24.json"
check "in-motion parent: next child ready-for-human" "1 work in flight: in motion #24 t24; next child #26 (ready-for-human, by hand): t26" "$(next "$(run)")"
list "$(issue 26 ready-for-human,parked)" "$(issue 28 ready-for-agent)" >"$FAKE_GH/sub-24.json"
check "in-motion parent: skips a parked child" "1 work in flight: in motion #24 t24; next child #28 (ready-for-agent, /implement #28, you type it; user-invoked): t28" "$(next "$(run)")"
list "$(issue 26 ready-for-human,parked)" >"$FAKE_GH/sub-24.json"
check "in-motion parent: only a parked child" "1 work in flight: in motion #24 t24; every open child blocked: #26 parked" "$(next "$(run)")"
list "$(closed 26 ready-for-human)" "$(closed 28 ready-for-agent)" >"$FAKE_GH/sub-24.json"
check "in-motion parent: children all closed" "1 work in flight: in motion #24 t24" "$(next "$(run)")"
command rm -f "$FAKE_GH/sub-24.json"
check "in-motion ticket: no sub-issues" "1 work in flight: in motion #24 t24" "$(next "$(run)")"
list "$(issue 27 ready-for-agent 1)" "$(issue 28 ready-for-agent 0 'Blocked by: #52')" >"$FAKE_GH/sub-24.json"
printf '[{"number":26,"state":"open"},{"number":9,"state":"closed"}]' >"$FAKE_GH/deps-27.json"
check "in-motion parent: open children all blocked" "1 work in flight: in motion #24 t24; every open child blocked: #27 by #26, #28 by #52" "$(next "$(run)")"
# A linked blocker in another repo is named with its repo, never as the
# local ticket with the same number (#147).
printf '[{"number":26,"state":"open","repository_url":"https://api.github.com/repos/other/lib"},{"number":52,"state":"open","repository_url":"https://api.github.com/repos/me/proj"}]' >"$FAKE_GH/deps-27.json"
check "in-motion parent: a blocker in another repo" "1 work in flight: in motion #24 t24; every open child blocked: #27 by #52 other/lib#26, #28 by #52" "$(next "$(run)")"
printf '[{"number":9,"state":"closed"}]' >"$FAKE_GH/deps-27.json"
printf '[{"number":26,"state":"open"}]' >"$FAKE_GH/deps-27.page2.json"
check "in-motion parent: a blocker on the second page" "1 work in flight: in motion #24 t24; every open child blocked: #27 by #26, #28 by #52" "$(next "$(run)")"
command rm -f "$FAKE_GH/deps-27.page2.json"
printf 'not json' >"$FAKE_GH/deps-27.json"
check "in-motion parent: blocker list unread" "1 work in flight: in motion #24 t24; every open child blocked: #27 by an unread blocker, #28 by #52" "$(next "$(run)")"
list "$(issue 28 ready-for-agent 0 '## Blocked by

- #52')" "$(issue 29 ready-for-human)" >"$FAKE_GH/sub-24.json"
check "in-motion parent: skips a child blocked under a heading" "1 work in flight: in motion #24 t24; next child #29 (ready-for-human, by hand): t29" "$(next "$(run)")"
list "$(issue 27 enhancement)" >"$FAKE_GH/sub-24.json"
check "in-motion parent: next child not ready" "1 work in flight: in motion #24 t24; next child #27 (not ready): t27" "$(next "$(run)")"
list "$(closed 26 ready-for-human)" "$(issue 27 ready-for-agent 1)" >"$FAKE_GH/sub-24.json"
list "$(issue 28 ready-for-agent)" >"$FAKE_GH/sub-24.page2.json"
check "in-motion parent: next child on the second page" "1 work in flight: in motion #24 t24; next child #28 (ready-for-agent, /implement #28, you type it; user-invoked): t28" "$(next "$(run)")"
command rm -f "$FAKE_GH/sub-24.page2.json"
touch "$FAKE_GH/sub-24.fail"
check "in-motion parent: sub-issues unread" "1 work in flight: in motion #24 t24; sub-issues not read" "$(next "$(run)")"
command rm -f "$FAKE_GH/sub-24.fail" "$FAKE_GH/sub-24.json" "$FAKE_GH/deps-27.json"

# The next child is also the lowest ready ticket: case 2 names the next one.
issues "$(list "$(issue 24 ready-for-human,in-motion)" "$(issue 52 ready-for-agent)" "$(issue 53 ready-for-agent)")"
list "$(issue 52 ready-for-agent)" >"$FAKE_GH/sub-24.json"
out=$(run)
check "next child also ready: next is the child" "1 work in flight: in motion #24 t24; next child #52 (ready-for-agent, /implement #52, you type it; user-invoked): t52" "$(next "$out")"
check "next child also ready: runner-up is the next ready ticket" "2 /implement #53 (you type it; user-invoked): #53 t53" "$(runner "$out")"
has "next child also ready: still listed as ready" "ready, blockers closed: #52 t52; #53 t53" "$out"
issues "$(list "$(issue 24 ready-for-human,in-motion)" "$(issue 52 ready-for-agent)")"
out=$(run)
check "next child the only ready ticket: runner-up falls to case 7" "$case7_later" "$(runner "$out")"
command rm -f "$FAKE_GH/sub-24.json"
issues "$saved_issues"

# --- what each ready ticket unblocks (#123) ---------------------------------
# A ticket is unblocked by #90 when #90 is its last open blocker, whether the
# blocker is a GitHub link, a Blocked by: line or a bullet under a heading.
# Parked, wontfix and already-fixed tickets are never listed, and a ticket
# with two open links has them left unread (#99's fixture would list it).
# #87's one open link is #90 of another repo, not this one's (#147).
issues "$(list "$(issue 30 needs-info 0 'Blocked by: #90')" "$(issue 88 wontfix 0 'Blocked by: #90')" \
    "$(issue 89 needs-info,parked 0 'Blocked by: #90')" "$(issue 99 ready-for-agent 2)" \
    "$(issue 87 ready-for-agent 1)" \
    "$(issue 90 ready-for-agent)" \
    "$(issue 91 ready-for-human 1 '**Priority: High.** Linked.')" \
    "$(issue 92 needs-triage 0 '**Priority: Medium.** On a line.

Blocked by: #90')" \
    "$(issue 93 ready-for-agent 0 '## Blocked by

- #90')" \
    "$(issue 94 ready-for-agent 0 '**Priority: High.** Two open.

Blocked by: #90, #92')" \
    "$(issue 95 ready-for-agent 1 '**Priority: High.** Linked and in the body.

Blocked by: #92')" \
    "$(issue 96 ready-for-agent 1 '**Priority: Low.** A closed link too.')" \
    "$(issue 97 ready-for-agent 1 'Unread links.

Blocked by: #90')" \
    "$(issue 98 ready-for-agent 0 'Quotes the form:

```
Blocked by: #90
```')")"
printf '[{"number":90,"state":"open","repository_url":"https://api.github.com/repos/other/lib"}]' >"$FAKE_GH/deps-87.json"
printf '[{"number":90,"state":"open"}]' >"$FAKE_GH/deps-91.json"
printf '[{"number":90,"state":"open"}]' >"$FAKE_GH/deps-95.json"
printf '[{"number":90,"state":"open"},{"number":9,"state":"closed"}]' >"$FAKE_GH/deps-96.json"
printf 'not json' >"$FAKE_GH/deps-97.json"
printf '[{"number":90,"state":"open"}]' >"$FAKE_GH/deps-99.json"
out=$(run)
check "unblocks: last open blocker, every form, other open blockers and fences left out" \
    "#90 unblocks #91 (High), #92 (Medium), #93, #96 (Low)" "$(line_of "$out" unblocks)"
check "unblocks: next line unchanged" "2 /implement #90 (you type it; user-invoked): #90 t90" "$(next "$out")"
check "unblocks: runner-up line unchanged" "3 /triage (you type it; user-invoked): 0 unlabelled, 1 needs-triage, replied needs-info: none" "$(runner "$out")"
check "unblocks: for the next ticket" "#91 (High), #92 (Medium), #93, #96 (Low)" "$(line_of "$out" 'next unblocks')"
check "unblocks: none for a runner-up that names no ticket" "" "$(line_of "$out" 'runner-up unblocks')"
command rm -f "$FAKE_GH"/deps-9[1-9].json "$FAKE_GH/deps-87.json"

# The next child and the runner-up each carry what they unblock.
issues "$(list "$(issue 24 ready-for-human,in-motion)" "$(issue 52 ready-for-agent)" "$(issue 53 ready-for-agent)" \
    "$(issue 54 needs-info 0 '**Priority: High.**

Blocked by: #53')" "$(issue 55 needs-info 0 'Blocked by: #52')")"
list "$(issue 52 ready-for-agent)" >"$FAKE_GH/sub-24.json"
out=$(run)
check "unblocks: next child" "#55" "$(line_of "$out" 'next unblocks')"
check "unblocks: runner-up" "#54 (High)" "$(line_of "$out" 'runner-up unblocks')"
check "unblocks: the ready list" "#52 unblocks #55; #53 unblocks #54 (High)" "$(line_of "$out" unblocks)"
command rm -f "$FAKE_GH/sub-24.json"
issues "$(list "$(issue 80 ready-for-human 0 '**Priority: Medium.**')" "$(issue 81 needs-info 0 'Blocked by: #80')")"
out=$(run)
check "unblocks: a by-hand next step" "#81" "$(line_of "$out" 'next unblocks')"
check "unblocks: none in the ready list" "none" "$(line_of "$out" unblocks)"
issues "$(list "$(issue 24 ready-for-human,in-motion)" "$(issue 56 needs-info 0 'Blocked by: #24')")"
check "unblocks: an in-motion ticket with no sub-issues" "#56" "$(line_of "$(run)" 'next unblocks')"
issues "$saved_issues"

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
# The state a capture ends in (#108): unpushed work, an in-motion parent whose
# ready-for-human child waits on a live check behind a ready-for-agent child,
# and a lower-numbered ready ticket outside the parent. Capturing's first next
# step reads these lines, so the parent's next child must lead, not #67.
issues "$(list "$(issue 40 ready-for-human,in-motion)" "$(issue 67 ready-for-agent)" \
    "$(issue 98 ready-for-agent)" "$(issue 102 ready-for-human)")"
list "$(issue 98 ready-for-agent)" "$(issue 102 ready-for-human)" >"$FAKE_GH/sub-40.json"
out=$(run)
check "capture state: next is the parent's next child" "1 work in flight: 1 unpushed commits, in motion #40 t40; next child #98 (ready-for-agent, /implement #98, you type it; user-invoked): t98" "$(next "$out")"
check "capture state: runner-up is the lowest ready ticket" "2 /implement #67 (you type it; user-invoked): #67 t67" "$(runner "$out")"
command rm -f "$FAKE_GH/sub-40.json"
issues "$saved_issues"
g push -q
g checkout -q -b feature
check "case 1: off the default branch" "1 work in flight: on feature not main" "$(next "$(run)")"
g checkout -q main

# --- the /supervise offer ---------------------------------------------------
# When the next step is /implement #N, state.sh says whether /supervise would
# take it: launch.sh's entry checks (default branch, clean tree, no other live
# background session) and step.sh's (nothing else in flight).
sup() { printf '%s\n' "$1" | sed -n 's/^supervise: //p'; }
real=$(cd "$proj" && pwd -P)
offer="/mp-ported-skills:supervise $proj --model claude-opus-5-5 --effort medium (you type it; user-invoked)"
agents() { printf '%s' "$1" >"$FAKE_GH/agents.json"; }
row() { # <id> <state> <pid or null> [cwd] [kind]
    jq -nc --arg id "$1" --arg s "$2" --argjson pid "$3" --arg cwd "${4:-$real}" --arg k "${5:-background}" \
        '{id: $id, kind: $k, cwd: $cwd, state: $s, pid: $pid}'
}

issues "$(list "$(issue 52 ready-for-agent)")"
out=$(run)
check "supervise: offered for case 2 on a clean default branch" "$offer" "$(sup "$out")"
check "supervise: next line unchanged" "2 /implement #52 (you type it; user-invoked): #52 t52" "$(next "$out")"
check "supervise: the folder as given, . by default" \
    "/mp-ported-skills:supervise . --model claude-opus-5-5 --effort medium (you type it; user-invoked)" \
    "$(sup "$(cd "$proj" && sh "$state" </dev/null 2>&1)")"
agents "$(list "$(row aa11 stopped null)" "$(row bb22 done null)" "$(row cc33 working 12 /elsewhere)" \
    "$(row dd44 working 13 "$real" interactive)")"
check "supervise: stopped, finished, elsewhere and interactive sessions do not count" "$offer" "$(sup "$(run)")"
agents "$(list "$(row aa11 stopped null)" "$(row ee55 working 14)" "$(row ff66 done 15)")"
check "supervise: not offered beside a live background session" \
    "not offered: another live background session in $real: ee55 (working), ff66 (done)" "$(sup "$(run)")"
agents '[]'
check "supervise: not offered when claude agents fails" \
    "not offered: claude agents --json --all failed, so other sessions in $real are unknown" \
    "$(sup "$(FAKE_CLAUDE_FAIL=1 run)")"
agents 'not json'
check "supervise: not offered when claude agents prints no list" \
    "not offered: claude agents --json --all printed no list jq could read, so other sessions in $real are unknown" \
    "$(sup "$(run)")"
agents '[]'

# An in-motion parent whose next child is ready-for-agent is also /implement.
issues "$(list "$(issue 24 ready-for-human,in-motion)" "$(issue 52 ready-for-agent)")"
list "$(issue 52 ready-for-agent)" >"$FAKE_GH/sub-24.json"
check "supervise: offered for an in-motion parent's next child" "$offer" "$(sup "$(run)")"
echo x >"$proj/scratch"
out=$(run)
check "supervise: dirty tree, next is still the child" "1 work in flight: 1 uncommitted paths, in motion #24 t24; next child #52 (ready-for-agent, /implement #52, you type it; user-invoked): t52" "$(next "$out")"
check "supervise: not offered on a dirty tree" "not offered: 1 uncommitted paths; commit or clear them first" "$(sup "$out")"
command rm -f "$proj/scratch"
g checkout -q -b side
check "supervise: not offered off the default branch" "not offered: on side, not the default branch main" "$(sup "$(run)")"
# A linked worktree holding the default branch passes every other check, but
# launch.sh refuses it (#79), so it is not offered.
g worktree add -q "$real-wt" main
check "supervise: not offered in a linked worktree on the default branch" \
    "not offered: $real-wt is a linked git worktree on branch main, not the main checkout $real; a worker there would commit to a branch nobody pushes, so run /supervise from $real" \
    "$(sup "$(sh "$state" "$real-wt" </dev/null 2>&1)")"
g worktree remove --force "$real-wt"
g checkout -q main
g commit -q --allow-empty -m wip2
check "supervise: not offered with unpushed commits" "not offered: 1 unpushed commits; push them first" "$(sup "$(run)")"
g push -q
prs '[{"number":61,"title":"own pr","headRefName":"y","isCrossRepository":false}]'
check "supervise: not offered with an open PR" "not offered: open PR #61 own pr [y]; settle it first" "$(sup "$(run)")"
prs '[]'

# step.sh takes only the first in-motion ticket's child.
issues "$(list "$(issue 23 ready-for-human,in-motion)" "$(issue 24 ready-for-human,in-motion)" "$(issue 52 ready-for-agent)")"
check "supervise: not offered for a second in-motion ticket's child" \
    "not offered: other work in flight: in motion #23 t23; #24 t24; next child #52 (ready-for-agent, /implement #52, you type it; user-invoked): t52" \
    "$(sup "$(run)")"
issues "$(list "$(issue 24 ready-for-human,in-motion)" "$(issue 52 ready-for-agent)")"

# Any other step: no offer at all.
list "$(issue 26 ready-for-human)" >"$FAKE_GH/sub-24.json"
check "supervise: no offer when the next child is by hand" "" "$(sup "$(run)")"
command rm -f "$FAKE_GH/sub-24.json"
check "supervise: no offer for an in-motion ticket" "" "$(sup "$(run)")"
issues "$(list "$(issue 31 needs-triage)" "$(issue 52 ready-for-agent)")"
out=$(run)
check "supervise: still offered when the runner-up is not /implement" "$offer" "$(sup "$out")"
issues "$(list "$(issue 81 ready-for-human)" "$(issue 31 needs-triage)")"
check "supervise: no offer for triage" "" "$(sup "$(run)")"
issues '[]'
check "supervise: no offer when nothing is in motion" "" "$(sup "$(run)")"
check "supervise: no offer when the tracker is unreached" "" "$(sup "$(FAKE_GH_FAIL=1 run)")"
issues "$saved_issues"

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
