#!/bin/sh
# supervise-close.test.sh -- tests for the supervise skill's close.sh, and
# for actions.sh's report of a close it made (#186).
#
# Builds a scratch Project that names a Distribution repo, each with a bare
# remote, and a fake `gh` first on PATH that records every call and answers
# `gh issue view` from a state file. Touches nothing outside its own mktemp
# directory.
#
# Usage: sh tests/supervise-close.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scripts="$root/plugins/mp-ported-skills/skills/supervise/scripts"
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

# Every variable the scripts read, set or unset here, so the result does not
# depend on the session running the test. The git wrappers a background
# session inherits would refuse the scratch pushes; the attended flag is
# set per case below.
unset CLAUDE_CODE_SESSION_ATTENDED MP_DENY_SHARED_ACTIONS_IGNORE_GRANTS FAKE_GH_FAIL
PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '/worker-bin/*$' | paste -sd: -)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export CLAUDE_CONFIG_DIR="$work/config"
mkdir -p "$CLAUDE_CONFIG_DIR"

# --- fake gh ---------------------------------------------------------------
# Logs each call's arguments on one line to gh-log, a comment's body to
# gh-body, and answers `issue view` with $work/state ("OPEN" or "CLOSED")
# and $work/labels (a JSON array of names).
mkdir -p "$work/bin"
cat >"$work/bin/gh" <<EOF
#!/bin/sh
[ -n "\${FAKE_GH_FAIL:-}" ] && { echo "gh: HTTP 404: Not Found" >&2; exit 1; }
echo "\$*" >>"$work/gh-log"
prev=""
for a in "\$@"; do
    [ "\$prev" = --body-file ] && command cp "\$a" "$work/gh-body"
    [ "\$prev" = --comment ] && printf '%s\n' "\$a" >"$work/gh-body"
    prev=\$a
done
case "\$1 \$2" in
    "issue view")
        jq -n --arg s "\$(command cat "$work/state")" --argjson l "\$(command cat "$work/labels")" \
            '{state: \$s, labels: [\$l[] | {name: .}], url: "https://github.com/o/r/issues/7"}' ;;
    "issue close" | "issue reopen" | "issue edit") ;;
    "issue comment") echo "https://github.com/o/r/issues/7#issuecomment-9" ;;
    *) echo "fake gh: unexpected \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/gh"
PATH="$work/bin:$PATH"
if [ "$(command -v gh)" != "$work/bin/gh" ]; then
    echo "FAIL fake gh is not first on PATH; not running the rest" >&2
    exit 1
fi

g() { git -C "$@"; }
for r in proj dist; do
    git init -q --bare "$work/$r.git"
    git init -q -b main "$work/$r"
    g "$work/$r" -c commit.gpgsign=false commit -q --allow-empty -m start
    g "$work/$r" remote add origin "$work/$r.git"
    g "$work/$r" push -q -u origin main 2>/dev/null
    g "$work/$r" remote set-head origin main
done
proj="$work/proj"
dist="$work/dist"
mkdir -p "$proj/docs/agents"
printf '## Grants\n\n- issue-close\n' >"$proj/docs/agents/supervision.md"
printf '../dist\n' >"$proj/docs/agents/distribution-repo.md"
printf '| Role | Label |\n|---|---|\n| `ready-for-agent` | `afk` |\n| `ready-for-human` | `hitl` |\n' >"$proj/docs/agents/triage-labels.md"
g "$proj" add docs
g "$proj" -c commit.gpgsign=false commit -q -m 'grants, dist, labels'
g "$proj" push -q origin main 2>/dev/null
start=$(g "$proj" rev-parse HEAD)
record=$(g "$proj" rev-parse --path-format=absolute --git-path mp-supervise-posted)
marker=$(g "$proj" rev-parse --path-format=absolute --git-path mp-supervise-worker)

close() { # [args...] -- close.sh for worker 2da1baa1, ticket 7, its output then exit=N
    sh "$scripts/close.sh" --dir "$proj" --id 2da1baa1 --ticket 7 "$@" </dev/null 2>&1
    echo "exit=$?"
}
last() { printf '%s\n' "$1" | tail -n 1; }
reset() { # <state> <labels json>
    command rm -f "$work/gh-log" "$work/gh-body" "$record" "$marker"
    printf '%s' "$1" >"$work/state"
    printf '%s' "$2" >"$work/labels"
}

# --- the Distribution repo holds an unpushed commit ------------------------
g "$dist" -c commit.gpgsign=false commit -q --allow-empty -m 'Add the parser'
code=$(g "$dist" log -1 --format='%h %s')

reset OPEN '["afk"]'
out=$(close --pushed)
check "pushed, unpushed commits: refused" "exit=2" "$(last "$out")"
check "pushed, unpushed commits: names the hold" "fail upstream: $dist still holds 1 commit(s) its upstream lacks; push first" \
    "$(printf '%s\n' "$out" | grep '^fail upstream')"
check "pushed, unpushed commits: gh not called" "no" "$([ -f "$work/gh-log" ] && echo yes || echo no)"

# --- declined --------------------------------------------------------------
reset CLOSED '["afk","bug"]'
out=$(close --declined --check)
check "declined --check: passes" "exit=0" "$(last "$out")"
check "declined --check: lists the unpushed commit" "  $code" "$(printf '%s\n' "$out" | grep '^  ')"
check "declined --check: gh not called" "no" "$([ -f "$work/gh-log" ] && echo yes || echo no)"

out=$(close --declined)
check "declined: exit 0" "exit=0" "$(last "$out")"
check "declined: reopens the closed ticket, comments, relabels" "issue view 7 --json state,labels,url
issue reopen 7
issue comment 7 --body-file $(sed -n 's/^issue comment 7 --body-file //p' "$work/gh-log")
issue edit 7 --remove-label afk --add-label hitl" "$(command cat "$work/gh-log")"
check "declined: the comment names the unpushed commit" "The Distribution push was declined, so this ticket stays open and waits on the maintainer (hitl). $dist holds these commits its upstream lacks:

- $code" "$(command cat "$work/gh-body")"
check "declined: nothing recorded as the supervisor's" "no" "$([ -f "$record" ] && echo yes || echo no)"

reset OPEN '["hitl"]'
out=$(close --declined)
check "declined, open and already hitl: no reopen, no relabel" "issue view 7 --json state,labels,url
issue comment 7 --body-file $(sed -n 's/^issue comment 7 --body-file //p' "$work/gh-log")" "$(command cat "$work/gh-log")"

reset OPEN '["afk"]'
out=$(CLAUDE_CODE_SESSION_ATTENDED=0; export CLAUDE_CODE_SESSION_ATTENDED; close --declined)
check "declined: refused in a background session" "exit=1" "$(last "$out")"
check "background: gh not called" "no" "$([ -f "$work/gh-log" ] && echo yes || echo no)"

reset OPEN '["afk"]'
echo 3d2d302a >"$marker"
out=$(close --declined)
check "declined: refused while a worker holds the checkout" "exit=2" "$(last "$out")"
check "marker: names the worker" "fail marker: worker 3d2d302a still holds the checkout; stop it and release its marker first" \
    "$(printf '%s\n' "$out" | grep '^fail marker')"

# --- pushed ----------------------------------------------------------------
g "$dist" push -q origin main 2>/dev/null

reset OPEN '["afk"]'
out=$(close --declined)
check "declined after the push: refused, nothing is unpushed" "exit=2" "$(last "$out")"

reset OPEN '["afk"]'
out=$(close --pushed)
check "pushed: exit 0" "exit=0" "$(last "$out")"
check "pushed: cites the grant" "ok grant: issue-close" "$(printf '%s\n' "$out" | grep '^ok grant')"
check "pushed: closes with a comment" "issue view 7 --json state,labels,url
issue close 7 --comment Closed after the Distribution push landed: $dist is even with its upstream at $code." \
    "$(command cat "$work/gh-log")"
check "pushed: prints the url" "closed https://github.com/o/r/issues/7" "$(printf '%s\n' "$out" | grep '^closed ')"
check "pushed: recorded for actions.sh" "2da1baa1 issue-close https://github.com/o/r/issues/7" \
    "$(awk '{ print $1, $3, $4 }' "$record")"

mkdir -p "$CLAUDE_CONFIG_DIR/jobs/2da1baa1"
echo '{}' >"$CLAUDE_CONFIG_DIR/jobs/2da1baa1/state.json"
out=$(sh "$scripts/actions.sh" --id 2da1baa1 --dir "$proj" --start "$start" </dev/null 2>&1)
check "actions: the close is the supervisor's, after the push" \
    "issue-close by the supervisor after the Distribution push landed: https://github.com/o/r/issues/7" \
    "$(printf '%s\n' "$out" | grep '^issue-')"

reset CLOSED '["afk"]'
out=$(close --pushed)
check "pushed, already closed: no second close" "issue view 7 --json state,labels,url" "$(command cat "$work/gh-log")"

reset OPEN '["afk"]'
out=$(FAKE_GH_FAIL=1; export FAKE_GH_FAIL; close --pushed)
check "pushed: gh failure exits 3" "exit=3" "$(last "$out")"
check "pushed: gh failure records nothing" "no" "$([ -f "$record" ] && echo yes || echo no)"

# Without the issue-close grant, the close needs the maintainer's approval.
printf '## Grants\n\n- push\n' >"$proj/docs/agents/supervision.md"
g "$proj" -c commit.gpgsign=false commit -q -am 'no issue-close'
g "$proj" push -q origin main 2>/dev/null
reset OPEN '["afk"]'
out=$(close --pushed)
check "pushed, no grant: refused" "exit=2" "$(last "$out")"
check "pushed, no grant: says to ask" "fail grant: the Project grants no issue-close; ask the maintainer, then run with --approved" \
    "$(printf '%s\n' "$out" | grep '^fail grant')"
out=$(close --pushed --approved)
check "pushed --approved: closes" "exit=0" "$(last "$out")"

# A Project that names no Distribution repo has nothing to settle here.
g "$proj" rm -q docs/agents/distribution-repo.md
g "$proj" -c commit.gpgsign=false commit -q -m 'no dist'
g "$proj" push -q origin main 2>/dev/null
reset OPEN '["afk"]'
out=$(close --pushed --approved)
check "no Distribution repo: refused" "exit=2" "$(last "$out")"

# Usage errors.
check "usage: both outcomes" "exit=1" "$(last "$(close --pushed --declined)")"
check "usage: no outcome" "exit=1" "$(last "$(close)")"
check "usage: --approved with --declined" "exit=1" "$(last "$(close --declined --approved)")"
out=$(sh "$scripts/close.sh" --dir "$proj" --id 2da1baa1 --ticket x7 --pushed </dev/null 2>&1; echo "exit=$?")
check "usage: a ticket that is not a number" "exit=1" "$(last "$out")"

echo "supervise-close: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
