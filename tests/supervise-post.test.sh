#!/bin/sh
# supervise-post.test.sh -- tests for the supervise skill's post.sh, and for
# actions.sh's report of a post it made (#144).
#
# Each case builds a scratch Project and a body file, with a fake `gh` first
# on PATH that records its arguments and the body it was given, and prints
# a URL. The sweep is a stub script that records the file it was given and
# exits as the case asks. Touches nothing outside its own mktemp directory.
#
# Usage: sh tests/supervise-post.test.sh

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
# depend on the session running the test.
unset CLAUDE_CODE_SESSION_ATTENDED MP_DENY_SHARED_ACTIONS_IGNORE_GRANTS FAKE_GH_FAIL
export CLAUDE_CONFIG_DIR="$work/config"
mkdir -p "$CLAUDE_CONFIG_DIR"

# --- fake gh ---------------------------------------------------------------
# Records its arguments one a line, and the body file's text, then prints
# the URL a real gh prints for the post.
mkdir -p "$work/bin"
cat >"$work/bin/gh" <<EOF
#!/bin/sh
[ -n "\${FAKE_GH_FAIL:-}" ] && { echo "gh: HTTP 404: Not Found" >&2; exit 1; }
printf '%s\n' "\$@" >"$work/gh-args"
prev=""
for a in "\$@"; do
    [ "\$prev" = --body-file ] && command cp "\$a" "$work/gh-body"
    prev=\$a
done
case "\$1 \$2" in
    "issue comment") echo "https://github.com/o/r/issues/\$3#issuecomment-77" ;;
    "issue create") echo "Creating issue in o/r" >&2; echo "https://github.com/o/r/issues/150" ;;
    *) echo "fake gh: unexpected \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/gh"
PATH="$work/bin:$PATH"
if [ "$(command -v gh)" != "$work/bin/gh" ]; then
    echo "FAIL fake gh is not first on PATH; not running the rest" >&2
    exit 1
fi

# The sweep stub: records its arguments and the file's text, prints a hit
# and exits 1 when $work/sweep-hit exists.
sweep="$work/sweep.sh"
cat >"$sweep" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >"$work/sweep-args"
command cat "\$1" >"$work/sweep-text"
if [ -f "$work/sweep-hit" ]; then echo "\$1:2: private path"; exit 1; fi
echo 'sweep: clean'
EOF
chmod +x "$sweep"

project="$work/project"
git init -q -b main "$project"
git -C "$project" -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -q --allow-empty -m start
start=$(git -C "$project" rev-parse HEAD)
body="$work/body.md"
printf 'Data point from the #108 run.\n\nThe push closed #108; no grant covered the close.\n' >"$body"
record=$(git -C "$project" rev-parse --path-format=absolute --git-path mp-supervise-posted)
marker=$(git -C "$project" rev-parse --path-format=absolute --git-path mp-supervise-worker)

post() { # [args...] -- post.sh for worker 2da1baa1 in $project, its output
    sh "$scripts/post.sh" --dir "$project" --id 2da1baa1 "$@" </dev/null 2>&1
}
reset() { command rm -f "$work/gh-args" "$work/gh-body" "$work/sweep-args" "$work/sweep-text" "$work/sweep-hit" "$record" "$marker"; }

# --- --check on a comment: every check passes, nothing is posted -----------
reset
out=$(post --comment 139 --body-file "$body" --sweep "$sweep" --check)
check "check comment: exits 0" "0" "$?"
check "check comment: the command and body, then the checks" "post issue-comment: gh issue comment 139 --body-file $body
body:
  Data point from the #108 run.

  The push closed #108; no grant covered the close.
ok marker: no worker marker in the checkout
ok body: 3 lines
ok sweep: clean" "$out"
check "check comment: the sweep reads the body" "$(command cat "$body")" "$(command cat "$work/sweep-text")"
check "check comment: nothing posted" "no" "$([ -f "$work/gh-args" ] && echo yes || echo no)"
check "check comment: nothing recorded" "no" "$([ -f "$record" ] && echo yes || echo no)"

# --- a comment ---------------------------------------------------------------
out=$(post --comment 139 --body-file "$body" --sweep "$sweep")
check "comment: exits 0" "0" "$?"
check "comment: the last line names the post" "posted issue-comment https://github.com/o/r/issues/139#issuecomment-77" \
    "$(printf '%s\n' "$out" | tail -n 1)"
check "comment: gh gets the command it showed" "issue
comment
139
--body-file
$body" "$(command cat "$work/gh-args")"
check "comment: gh gets the body unchanged" "$(command cat "$body")" "$(command cat "$work/gh-body")"
check "comment: recorded for actions.sh" "2da1baa1 issue-comment https://github.com/o/r/issues/139#issuecomment-77" \
    "$(awk '{ print $1, $3, $4 }' "$record")"
check "comment: recorded with its time" "yes" \
    "$(awk '{ print $2 }' "$record" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' && echo yes || echo no)"

# actions.sh names the post as the supervisor's, for this worker only.
mkdir -p "$CLAUDE_CONFIG_DIR/jobs/2da1baa1"
echo '{}' >"$CLAUDE_CONFIG_DIR/jobs/2da1baa1/state.json"
out=$(sh "$scripts/actions.sh" --id 2da1baa1 --dir "$project" --start "$start" </dev/null 2>&1)
check "actions: the post is the supervisor's" \
    "issue-comment posted by the supervisor on the maintainer's approval: https://github.com/o/r/issues/139#issuecomment-77" \
    "$(printf '%s\n' "$out" | grep '^issue-')"
mkdir -p "$CLAUDE_CONFIG_DIR/jobs/3d2d302a"
echo '{}' >"$CLAUDE_CONFIG_DIR/jobs/3d2d302a/state.json"
out=$(sh "$scripts/actions.sh" --id 3d2d302a --dir "$project" --start "$start" </dev/null 2>&1)
check "actions: another worker's post is not listed" "" "$(printf '%s\n' "$out" | grep '^issue-')"

# --- a new issue -------------------------------------------------------------
reset
out=$(post --create --title "state.sh: match linked blockers by repo" --label ready-for-agent --label bug \
    --repo o/r --body-file "$body" --sweep "$sweep" --check)
check "check create: exits 0" "0" "$?"
check "check create: the command" \
    "post issue-create: gh issue create --repo o/r --title 'state.sh: match linked blockers by repo' --label ready-for-agent --label bug --body-file $body" \
    "$(printf '%s\n' "$out" | head -n 1)"
check "check create: the sweep reads the title and body" "state.sh: match linked blockers by repo
$(command cat "$body")" "$(command cat "$work/sweep-text")"
out=$(post --create --title "state.sh: match linked blockers by repo" --label ready-for-agent --label bug \
    --repo o/r --body-file "$body" --sweep "$sweep")
check "create: exits 0" "0" "$?"
check "create: the last line names the new issue" "posted issue-create https://github.com/o/r/issues/150" \
    "$(printf '%s\n' "$out" | tail -n 1)"
check "create: gh gets the command it showed" "issue
create
--repo
o/r
--title
state.sh: match linked blockers by repo
--label
ready-for-agent
--label
bug
--body-file
$body" "$(command cat "$work/gh-args")"
check "create: recorded" "2da1baa1 issue-create https://github.com/o/r/issues/150" "$(awk '{ print $1, $3, $4 }' "$record")"

# A title with a quote is shown quoted so it reads back as one word.
out=$(post --create --title "don't drop it" --body-file "$body" --no-sweep --check)
check "check create: a quote in the title" "post issue-create: gh issue create --title 'don'\\''t drop it' --body-file $body" \
    "$(printf '%s\n' "$out" | head -n 1)"
check "no sweep: said" "skip sweep: --no-sweep given, the text was not swept" "$(printf '%s\n' "$out" | tail -n 1)"

# --- each failing check is named, and nothing is posted ----------------------
refused() { # <name> <expected fail lines> [post args...]
    name=$1 expected=$2; shift 2
    command rm -f "$work/gh-args" "$record"
    out=$(post "$@")
    rc=$?
    check "$name: exits 2" "2" "$rc"
    check "$name: says which" "$expected" "$(printf '%s\n' "$out" | grep '^fail')"
    check "$name: nothing posted" "no" "$([ -f "$work/gh-args" ] && echo yes || echo no)"
    check "$name: nothing recorded" "no" "$([ -f "$record" ] && echo yes || echo no)"
}

reset
echo 2da1baa1 >"$marker"
refused "marker" "fail marker: worker 2da1baa1 still holds the checkout; stop it and release its marker first" \
    --comment 139 --body-file "$body" --sweep "$sweep"
command rm -f "$marker"

reset
touch "$work/sweep-hit"
refused "sweep hits" "fail sweep: exit 1" --comment 139 --body-file "$body" --sweep "$sweep"
check "sweep hits: its output is shown" "yes" \
    "$(post --comment 139 --body-file "$body" --sweep "$sweep" | grep -q '^  .*:2: private path$' && echo yes || echo no)"

reset
: >"$work/empty.md"
refused "empty body" "fail body: $work/empty.md is empty or blank" --comment 139 --body-file "$work/empty.md" --sweep "$sweep"
printf '\n  \n' >"$work/blank.md"
refused "blank body" "fail body: $work/blank.md is empty or blank" --comment 139 --body-file "$work/blank.md" --sweep "$sweep"

# --- gh prints no URL: the record still has four fields ----------------------
reset
mkdir -p "$work/quiet"
printf '#!/bin/sh\nexit 0\n' >"$work/quiet/gh"
chmod +x "$work/quiet/gh"
out=$(PATH="$work/quiet:$PATH"; post --comment 139 --body-file "$body" --sweep "$sweep")
check "no url: said" "posted issue-comment no-url" "$(printf '%s\n' "$out" | tail -n 1)"
check "no url: actions.sh reads it whole" \
    "issue-comment posted by the supervisor on the maintainer's approval: no-url" \
    "$(sh "$scripts/actions.sh" --id 2da1baa1 --dir "$project" --start "$start" </dev/null 2>&1 | grep '^issue-')"

# --- gh fails ----------------------------------------------------------------
reset
out=$(export FAKE_GH_FAIL=1; post --comment 139 --body-file "$body" --sweep "$sweep")
check "gh fails: exits 3" "3" "$(export FAKE_GH_FAIL=1; post --comment 139 --body-file "$body" --sweep "$sweep" >/dev/null; echo $?)"
check "gh fails: its error is shown" "yes" "$(printf '%s\n' "$out" | grep -q 'HTTP 404' && echo yes || echo no)"
check "gh fails: nothing recorded" "no" "$([ -f "$record" ] && echo yes || echo no)"

# --- usage -------------------------------------------------------------------
usage() { # <name> [post args...] -- exits 1, posting nothing
    name=$1; shift
    command rm -f "$work/gh-args"
    post "$@" >/dev/null
    check "$name: exits 1" "1" "$?"
    check "$name: nothing posted" "no" "$([ -f "$work/gh-args" ] && echo yes || echo no)"
}
usage "no action" --body-file "$body" --sweep "$sweep"
usage "both actions" --comment 139 --create --title t --body-file "$body" --sweep "$sweep"
usage "create without a title" --create --body-file "$body" --sweep "$sweep"
usage "a label on a comment" --comment 139 --label bug --body-file "$body" --sweep "$sweep"
usage "a comment on no number" --comment x --body-file "$body" --sweep "$sweep"
usage "no body file" --comment 139 --sweep "$sweep"
usage "a missing body file" --comment 139 --body-file "$work/nope.md" --sweep "$sweep"
usage "no sweep choice" --comment 139 --body-file "$body"
usage "both sweep choices" --comment 139 --body-file "$body" --sweep "$sweep" --no-sweep
sh "$scripts/post.sh" --id 2da1baa1 --comment 139 --body-file "$body" --no-sweep </dev/null >/dev/null 2>&1
check "no dir: exits 1" "1" "$?"
sh "$scripts/post.sh" --dir "$project" --comment 139 --body-file "$body" --no-sweep </dev/null >/dev/null 2>&1
check "no id: exits 1" "1" "$?"

# A background session posts only on a standing grant: post.sh refuses.
reset
out=$( (export CLAUDE_CODE_SESSION_ATTENDED=0; post --comment 139 --body-file "$body" --sweep "$sweep") )
check "background: refused" "Error: post.sh posts for the maintainer's attended session; a background session posts only on a standing grant" "$out"
check "background: nothing posted" "no" "$([ -f "$work/gh-args" ] && echo yes || echo no)"
out=$( (export CLAUDE_CODE_SESSION_ATTENDED=0; post --comment 139 --body-file "$body" --sweep "$sweep" --check) )
check "background: --check still runs" "ok sweep: clean" "$(printf '%s\n' "$out" | tail -n 1)"

echo "supervise-post: $pass passed, $fail failed"
[ "$fail" = 0 ]
