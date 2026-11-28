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
# and $work/labels (a JSON array of names), or, asked for comments, with
# $work/comments (a JSON array of bodies).
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
        case "\$*" in *comments*)
            jq -n --argjson c "\$(command cat "$work/comments")" '{comments: [\$c[] | {body: .}]}'
            exit 0 ;;
        esac
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
    printf '%s' "${3:-[]}" >"$work/comments"
}
hold_comment='["The Distribution push is waiting on the maintainer, so this ticket is held open for them (hitl) until it lands. x holds these commits its upstream lacks:\n\n- abc x"]'

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

reset OPEN '["afk"]'
out=$(close --declined)
check "declined, never held: prints as before" "kept open https://github.com/o/r/issues/7" "$(printf '%s\n' "$out" | grep '^kept open')"

reset OPEN '["hitl"]' '["an unrelated note"]'
out=$(close --declined)
check "declined, already hitl but never held: no reopen, no relabel" "issue view 7 --json state,labels,url
issue view 7 --json comments
issue comment 7 --body-file $(sed -n 's/^issue comment 7 --body-file //p' "$work/gh-log")" "$(command cat "$work/gh-log")"
check "declined, already hitl but never held: lists the commits as before" "The Distribution push was declined, so this ticket stays open and waits on the maintainer (hitl). $dist holds these commits its upstream lacks:

- $code" "$(command cat "$work/gh-body")"

# --- held, before the push is checked or asked (#203) ----------------------
reset OPEN '["afk","bug"]'
out=$(close --held --check)
check "held --check: passes" "exit=0" "$(last "$out")"
check "held --check: lists the unpushed commit" "  $code" "$(printf '%s\n' "$out" | grep '^  ')"
check "held --check: gh not called" "no" "$([ -f "$work/gh-log" ] && echo yes || echo no)"

out=$(close --held)
check "held: exit 0" "exit=0" "$(last "$out")"
check "held: comments, relabels, does not close" "issue view 7 --json state,labels,url
issue comment 7 --body-file $(sed -n 's/^issue comment 7 --body-file //p' "$work/gh-log")
issue edit 7 --remove-label afk --add-label hitl" "$(command cat "$work/gh-log")"
check "held: the comment names the unpushed commit and the wait" "The Distribution push is waiting on the maintainer, so this ticket is held open for them (hitl) until it lands. $dist holds these commits its upstream lacks:

- $code" "$(command cat "$work/gh-body")"
check "held: prints the url" "held open https://github.com/o/r/issues/7" "$(printf '%s\n' "$out" | grep '^held open')"
check "held: nothing recorded as the supervisor's" "no" "$([ -f "$record" ] && echo yes || echo no)"

reset CLOSED '["afk"]'
out=$(close --held)
check "held, closed: reopens first" "issue reopen 7" "$(sed -n 2p "$work/gh-log")"

reset OPEN '["hitl"]' "$hold_comment"
out=$(close --held)
check "held twice: exit 0" "exit=0" "$(last "$out")"
check "held twice: no second comment" "issue view 7 --json state,labels,url
issue view 7 --json comments" "$(command cat "$work/gh-log")"
check "held twice: says so" "held already https://github.com/o/r/issues/7" "$(printf '%s\n' "$out" | grep '^held already')"

reset OPEN '["afk"]'
echo 3d2d302a >"$marker"
out=$(close --held)
check "held: refused while a worker holds the checkout" "exit=2" "$(last "$out")"
check "held, marker: gh not called" "no" "$([ -f "$work/gh-log" ] && echo yes || echo no)"

reset OPEN '["afk"]'
out=$(CLAUDE_CODE_SESSION_ATTENDED=0; export CLAUDE_CODE_SESSION_ATTENDED; close --held)
check "held: refused in a background session" "exit=1" "$(last "$out")"

# --- declined on a held ticket ---------------------------------------------
reset OPEN '["hitl","bug"]' "$hold_comment"
out=$(close --declined)
check "declined, held: exit 0" "exit=0" "$(last "$out")"
check "declined, held: comments only, no reopen, no relabel" "issue view 7 --json state,labels,url
issue view 7 --json comments
issue comment 7 --body-file $(sed -n 's/^issue comment 7 --body-file //p' "$work/gh-log")" "$(command cat "$work/gh-log")"
check "declined, held: says declined, no commit list" "The Distribution push was declined, so this ticket stays held for the maintainer (hitl). Its unpushed commits are listed in the comment that held it." \
    "$(command cat "$work/gh-body")"

# --- a failed push.sh --check on a held ticket -----------------------------
printf '%s\n' 'push project main -> origin/main' 'ok marker: no worker marker' 'fail clean: the tree has changes' \
    'ok distribution upstream: x' 'fail distribution sweep: 2 hits' '  README.md:3: hit' >"$work/check-out"
reset OPEN '["hitl"]' "$hold_comment"
out=$(close --failed "$work/check-out")
check "failed, held: exit 0" "exit=0" "$(last "$out")"
check "failed, held: comments only" "issue view 7 --json state,labels,url
issue view 7 --json comments
issue comment 7 --body-file $(sed -n 's/^issue comment 7 --body-file //p' "$work/gh-log")" "$(command cat "$work/gh-log")"
check "failed, held: the comment gives the fail lines" "The Distribution push was not asked: \`push.sh --check\` failed, so this ticket stays held for the maintainer (hitl). The failed checks:

\`\`\`
fail clean: the tree has changes
fail distribution sweep: 2 hits
\`\`\`" "$(command cat "$work/gh-body")"
check "failed, held: prints the url" "kept open https://github.com/o/r/issues/7" "$(printf '%s\n' "$out" | grep '^kept open')"

reset OPEN '["afk"]'
out=$(close --failed "$work/check-out")
check "failed, never held: relabels too" "issue edit 7 --remove-label afk --add-label hitl" "$(sed -n 3p "$work/gh-log")"

printf 'ok marker: fine\n' >"$work/check-ok"
reset OPEN '["hitl"]'
out=$(close --failed "$work/check-ok")
check "failed, no fail lines: usage error" "exit=1" "$(last "$out")"
check "failed, no fail lines: gh not called" "no" "$([ -f "$work/gh-log" ] && echo yes || echo no)"
out=$(close --failed "$work/missing")
check "failed, no such file: usage error" "exit=1" "$(last "$out")"

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
out=$(close --held)
check "held after the push: refused, nothing is unpushed" "exit=2" "$(last "$out")"
check "held after the push: gh not called" "no" "$([ -f "$work/gh-log" ] && echo yes || echo no)"

reset OPEN '["hitl","bug"]' "$hold_comment"
out=$(close --pushed)
check "pushed, held: closes, then removes hitl" "issue view 7 --json state,labels,url
issue close 7 --comment Closed after the Distribution push landed: $dist is even with its upstream at $code.
issue edit 7 --remove-label hitl" \
    "$(command cat "$work/gh-log")"
check "pushed, held: recorded for actions.sh" "2da1baa1 issue-close https://github.com/o/r/issues/7" \
    "$(awk '{ print $1, $3, $4 }' "$record")"

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
check "pushed, already closed: not recorded as the supervisor's" "no" "$([ -f "$record" ] && echo yes || echo no)"

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

# A Distribution path that is a plain folder inside the Project's repo is
# no repo of its own: its upstream count would be the Project's.
mkdir -p "$proj/plain"
printf 'plain\n' >"$proj/docs/agents/distribution-repo.md"
g "$proj" -c commit.gpgsign=false commit -q -am 'dist is a plain folder'
g "$proj" push -q origin main 2>/dev/null
reset OPEN '["afk"]'
out=$(close --pushed --approved)
check "plain-folder Distribution path: refused" "exit=2" "$(last "$out")"
check "plain-folder Distribution path: gh not called" "no" "$([ -f "$work/gh-log" ] && echo yes || echo no)"

# A Project that names no Distribution repo (#261): nothing is held there,
# since the worker closes its own ticket, but a close the worker named
# beside a push the supervisor made is settled by --pushed, once the
# Project's own branch is even with its upstream.
printf '## Grants\n\n- push\n- issue-close\n' >"$proj/docs/agents/supervision.md"
g "$proj" rm -q docs/agents/distribution-repo.md
g "$proj" -c commit.gpgsign=false commit -q -am 'no dist'
# distribution.sh reads the Project's origin, so the removal is pushed; the
# worker's commit is not.
g "$proj" push -q origin main 2>/dev/null
g "$proj" -c commit.gpgsign=false commit -q --allow-empty -m 'Add the feature'
for o in --held --declined; do
    reset OPEN '["afk"]'
    out=$(close $o)
    check "no Distribution repo, $o: refused" "exit=2" "$(last "$out")"
    check "no Distribution repo, $o: says nothing is held" \
        "fail distribution: $proj names no Distribution repo, so its ticket is not held; only --pushed runs there" \
        "$(printf '%s\n' "$out" | grep '^fail distribution')"
    check "no Distribution repo, $o: gh not called" "no" "$([ -f "$work/gh-log" ] && echo yes || echo no)"
done
reset OPEN '["afk"]'
out=$(close --failed "$work/check-out")
check "no Distribution repo, --failed: refused" "exit=2" "$(last "$out")"

reset OPEN '["afk"]'
out=$(close --pushed)
check "no Distribution repo, unpushed: refused" "exit=2" "$(last "$out")"
check "no Distribution repo, unpushed: names the Project's branch" \
    "fail upstream: $proj still holds 1 commit(s) its upstream lacks; push first" \
    "$(printf '%s\n' "$out" | grep '^fail upstream')"
check "no Distribution repo, unpushed: gh not called" "no" "$([ -f "$work/gh-log" ] && echo yes || echo no)"

g "$proj" push -q origin main 2>/dev/null
head=$(g "$proj" log -1 --format='%h %s')
reset OPEN '["afk"]'
out=$(close --pushed --check)
check "no Distribution repo, --check: passes" "exit=0" "$(last "$out")"
check "no Distribution repo, --check: says the Project is checked" \
    "ok distribution: none named, so $proj's own branch is checked" \
    "$(printf '%s\n' "$out" | grep '^ok distribution')"
check "no Distribution repo, --check: gh not called" "no" "$([ -f "$work/gh-log" ] && echo yes || echo no)"

out=$(close --pushed)
check "no Distribution repo, pushed: exit 0" "exit=0" "$(last "$out")"
check "no Distribution repo, pushed: cites the grant" "ok grant: issue-close" "$(printf '%s\n' "$out" | grep '^ok grant')"
check "no Distribution repo, pushed: closes with a comment" "issue view 7 --json state,labels,url
issue close 7 --comment Closed after the push landed: $proj is even with its upstream at $head." \
    "$(command cat "$work/gh-log")"
check "no Distribution repo, pushed: prints the url" "closed https://github.com/o/r/issues/7" \
    "$(printf '%s\n' "$out" | grep '^closed ')"
check "no Distribution repo, pushed: recorded as the Project's push" \
    "2da1baa1 issue-close https://github.com/o/r/issues/7 project" \
    "$(awk '{ print $1, $3, $4, $5 }' "$record")"
out=$(sh "$scripts/actions.sh" --id 2da1baa1 --dir "$proj" --start "$start" </dev/null 2>&1)
check "no Distribution repo, actions: the close is the supervisor's, after the push" \
    "issue-close by the supervisor after the push landed: https://github.com/o/r/issues/7" \
    "$(printf '%s\n' "$out" | grep '^issue-')"

reset CLOSED '["afk"]'
out=$(close --pushed)
check "no Distribution repo, already closed: no second close" "issue view 7 --json state,labels,url" "$(command cat "$work/gh-log")"
check "no Distribution repo, already closed: not recorded" "no" "$([ -f "$record" ] && echo yes || echo no)"

printf '## Grants\n\n- push\n' >"$proj/docs/agents/supervision.md"
g "$proj" -c commit.gpgsign=false commit -q -am 'no issue-close, no dist'
g "$proj" push -q origin main 2>/dev/null
reset OPEN '["afk"]'
out=$(close --pushed)
check "no Distribution repo, no grant: refused" "exit=2" "$(last "$out")"
check "no Distribution repo, no grant: says to ask" "fail grant: the Project grants no issue-close; ask the maintainer, then run with --approved" \
    "$(printf '%s\n' "$out" | grep '^fail grant')"
check "no Distribution repo, no grant: gh not called" "no" "$([ -f "$work/gh-log" ] && echo yes || echo no)"
out=$(close --pushed --approved)
check "no Distribution repo, --approved: closes" "exit=0" "$(last "$out")"
check "no Distribution repo, --approved: closed" "closed https://github.com/o/r/issues/7" \
    "$(printf '%s\n' "$out" | grep '^closed ')"

# On a Local Markdown tracker (#234) the close is no shared action: every
# outcome is refused before gh runs, since the close there is an edit to
# the ticket file, and grant.sh's line is never cited.
printf '# Issue tracker: Local Markdown\n' >"$proj/docs/agents/issue-tracker.md"
g "$proj" add docs/agents/issue-tracker.md
g "$proj" -c commit.gpgsign=false commit -q -m 'a local tracker'
g "$proj" push -q origin main 2>/dev/null
for a in "" --approved; do
    reset OPEN '["afk"]'
    # shellcheck disable=SC2086
    out=$(close --pushed $a)
    check "local $a: refused" "exit=2" "$(last "$out")"
    [ -n "$a" ] || check "local: no grant line, and grant.sh's line is never cited" "" \
        "$(printf '%s\n' "$out" | grep -e 'grant' -e 'not a shared action on this tracker')"
    check "local $a: says the close is a file edit" \
        "fail tracker: $proj's tracker is Local Markdown, where the close is an edit to the ticket file, not a shared action, and close.sh closes only GitHub issues; edit the ticket file and commit it" \
        "$(printf '%s\n' "$out" | grep '^fail tracker')"
    check "local $a: gh not called" "no" "$([ -f "$work/gh-log" ] && echo yes || echo no)"
done
printf '# Issue tracker: GitHub\n' >"$proj/docs/agents/issue-tracker.md"
g "$proj" -c commit.gpgsign=false commit -q -am 'back to GitHub'
g "$proj" push -q origin main 2>/dev/null

# A Project branch with no upstream holds the close.
g "$proj" branch -q --unset-upstream
reset OPEN '["afk"]'
out=$(close --pushed --approved)
check "no Distribution repo, no upstream: refused" "exit=2" "$(last "$out")"
check "no Distribution repo, no upstream: says so" "fail upstream: $proj has no upstream to compare with" \
    "$(printf '%s\n' "$out" | grep '^fail upstream')"

# Usage errors.
check "usage: both outcomes" "exit=1" "$(last "$(close --pushed --declined)")"
check "usage: no outcome" "exit=1" "$(last "$(close)")"
check "usage: --approved with --declined" "exit=1" "$(last "$(close --declined --approved)")"
check "usage: --approved with --held" "exit=1" "$(last "$(close --held --approved)")"
check "usage: --held with --declined" "exit=1" "$(last "$(close --held --declined)")"
check "usage: --failed with no file" "exit=1" "$(last "$(close --failed)")"
out=$(sh "$scripts/close.sh" --dir "$proj" --id 2da1baa1 --ticket x7 --pushed </dev/null 2>&1; echo "exit=$?")
check "usage: a ticket that is not a number" "exit=1" "$(last "$out")"

echo "supervise-close: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
