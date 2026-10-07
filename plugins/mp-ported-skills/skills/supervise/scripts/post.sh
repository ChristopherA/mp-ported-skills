#!/bin/sh
# post.sh -- post a stopped worker's issue comment or new issue for the
# maintainer, after checking it (#144).
#
# A worker's capture lists a finding it could not post when no standing
# grant covers `gh issue comment` or `gh issue create`, either ending its
# turn on `Waiting on: gh issue comment N` or ending on a statement. The
# maintainer approves the post in the supervisor's attended session, and
# the supervisor runs this: one named, checked action, as push.sh is for a
# push (docs/adr/0007). The command is built from the options, never run
# from the worker's command text, so nothing in that text is evaluated.
#
# Before the checks it prints the command it will run, quoted as a shell
# would read it, and the body file's text, its non-blank lines indented:
#   post <action>: gh issue ...
#   body:
#     <each line>
# Checks, each printed as `ok <check>: ...` or `fail <check>: ...`:
#   marker  no worker marker in the checkout (the worker was stopped and
#           release.sh run)
#   body    the body file holds a line that is not blank
#   sweep   the --sweep command, run in DIR with a file holding the title
#           (for a new issue) and the body appended, exits 0; on a hit its
#           output follows, indented. CMD is shell code: give one command,
#           since the file is appended to its last one
#
# Without --check, when every check passes, it runs the command and prints
# `posted <action> <url>` (`no-url` when gh printed none), and appends
# `ID <time> <action> <url>` to the checkout's
# `git rev-parse --git-path mp-supervise-posted`, which actions.sh reads to
# name the post as the supervisor's, and record.sh to keep the worker's wait
# for it off the waits on a human; a `note` line follows when that write
# fails.
# A post is refused in a background session (CLAUDE_CODE_SESSION_ATTENDED=0),
# as push.sh refuses a push, though --check still runs there: there an issue
# comment or new issue goes only on a standing grant.
#
# Usage:
#   post.sh --dir DIR --id ID (--comment N | --create --title T [--label L]...)
#           [--repo OWNER/REPO] --body-file FILE (--sweep CMD | --no-sweep)
#           [--check]
#
# Exits 0 when every check passed (and, without --check, the post landed);
# 1 on a usage error or in a background session; 2 when a check failed,
# with nothing posted; 3 when gh itself failed.

set -u

DIR=""
ID=""
COMMENT=""
CREATE=0
TITLE=""
LABELS=""
REPO=""
BODY=""
SWEEP=""
NO_SWEEP=0
CHECK=0

need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --dir)       need_value "$@"; DIR="$2"; shift 2 ;;
        --id)        need_value "$@"; ID="$2"; shift 2 ;;
        --comment)   need_value "$@"; COMMENT="${2#\#}"; shift 2 ;;
        --create)    CREATE=1; shift ;;
        --title)     need_value "$@"; TITLE="$2"; shift 2 ;;
        --label)     need_value "$@"; LABELS="$LABELS$2
"; shift 2 ;;
        --repo)      need_value "$@"; REPO="$2"; shift 2 ;;
        --body-file) need_value "$@"; BODY="$2"; shift 2 ;;
        --sweep)     need_value "$@"; SWEEP="$2"; shift 2 ;;
        --no-sweep)  NO_SWEEP=1; shift ;;
        --check)     CHECK=1; shift ;;
        --help)
            printf 'Usage: post.sh --dir DIR --id ID (--comment N | --create --title T [--label L]...) [--repo OWNER/REPO]\n'
            printf '               --body-file FILE (--sweep CMD | --no-sweep) [--check]\n'
            printf 'Checks a stopped worker'\''s issue comment or new issue and, without --check, posts it.\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
[ -n "$DIR" ] || fail "--dir is required"
[ -n "$ID" ] || fail "--id is required"
if [ -n "$COMMENT" ] && [ "$CREATE" = 1 ]; then
    fail "give --comment N or --create, not both"
fi
[ -n "$COMMENT" ] || [ "$CREATE" = 1 ] || fail "--comment N or --create is required"
case $COMMENT in *[!0-9]*) fail "--comment needs an issue number, not '$COMMENT'" ;; esac
if [ "$CREATE" = 1 ]; then
    [ -n "$TITLE" ] || fail "--create needs --title"
else
    [ -z "$TITLE" ] || fail "--title goes with --create, not --comment"
    [ -z "$LABELS" ] || fail "--label goes with --create, not --comment"
fi
[ -n "$BODY" ] || fail "--body-file is required"
[ -f "$BODY" ] || fail "no such body file: $BODY"
if [ -n "$SWEEP" ] && [ "$NO_SWEEP" = 1 ]; then
    fail "give --sweep or --no-sweep, not both"
fi
[ -n "$SWEEP" ] || [ "$NO_SWEEP" = 1 ] ||
    fail "--sweep CMD is required, or --no-sweep to post with the text unswept"
[ -d "$DIR" ] || fail "not a directory: $DIR"
if [ "$CHECK" = 0 ] && [ "${CLAUDE_CODE_SESSION_ATTENDED:-1}" = 0 ]; then
    fail "post.sh posts for the maintainer's attended session; a background session posts only on a standing grant"
fi
DIR=$(CDPATH= cd -- "$DIR" && pwd -P)
git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || fail "not a git checkout: $DIR"

# The command, as positional parameters, built only from the options.
if [ "$CREATE" = 1 ]; then
    action=issue-create
    set -- issue create
    [ -z "$REPO" ] || set -- "$@" --repo "$REPO"
    set -- "$@" --title "$TITLE"
    oldIFS=$IFS
    IFS='
'
    set -f
    for l in $LABELS; do set -- "$@" --label "$l"; done
    set +f
    IFS=$oldIFS
else
    action=issue-comment
    set -- issue comment "$COMMENT"
    [ -z "$REPO" ] || set -- "$@" --repo "$REPO"
fi
set -- "$@" --body-file "$BODY"

# quote <word>: the word as a shell reads it back, single-quoted only when
# it holds anything but plain characters.
quote() {
    case "$1" in
        '' | *[!A-Za-z0-9_./:@%+=,-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
        *) printf '%s' "$1" ;;
    esac
}
shown="gh"
for w in "$@"; do shown="$shown $(quote "$w")"; done

failed=0
ok() { printf 'ok %s\n' "$1"; }
bad() { printf 'fail %s\n' "$1"; failed=1; }

echo "post $action: $shown"
echo "body:"
sed '/./s/^/  /' "$BODY"

marker=$(git -C "$DIR" rev-parse --path-format=absolute --git-path mp-supervise-worker)
if [ -f "$marker" ]; then
    bad "marker: worker $(head -n 1 "$marker") still holds the checkout; stop it and release its marker first"
else
    ok "marker: no worker marker in the checkout"
fi

lines=$(grep -c '' "$BODY")
if ! grep -q '[^[:space:]]' "$BODY"; then
    bad "body: $BODY is empty or blank"
elif [ "$lines" = 1 ]; then
    ok "body: 1 line"
else
    ok "body: $lines lines"
fi

if [ "$NO_SWEEP" = 1 ]; then
    echo "skip sweep: --no-sweep given, the text was not swept"
else
    text=$(mktemp)
    { [ -z "$TITLE" ] || printf '%s\n' "$TITLE"; command cat "$BODY"; } >"$text"
    swept=$(cd "$DIR" && sh -c "$SWEEP"' "$1"' sh "$text" </dev/null 2>&1)
    rc=$?
    command rm -f "$text"
    if [ "$rc" = 0 ]; then
        ok "sweep: clean"
    else
        bad "sweep: exit $rc"
        printf '%s\n' "$swept" | sed 's/^/  /'
    fi
fi

[ "$failed" = 0 ] || exit 2
[ "$CHECK" = 0 ] || exit 0

err=$(mktemp)
if ! out=$(cd "$DIR" && gh "$@" </dev/null 2>"$err"); then
    command cat "$err" >&2
    command rm -f "$err"
    printf 'Error: %s failed\n' "$shown" >&2
    exit 3
fi
command rm -f "$err"
url=$(printf '%s\n' "$out" | grep '^https\{0,1\}://' | tail -n 1)
[ -n "$url" ] || url=no-url
echo "posted $action $url"
record=$(git -C "$DIR" rev-parse --path-format=absolute --git-path mp-supervise-posted)
printf '%s %s %s %s\n' "$ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$action" "$url" >>"$record" ||
    echo "note the post was not recorded in $record, so record.sh will count the worker's wait for it as a human's"
