#!/bin/sh
# watch.sh -- watch one background session until it needs the supervisor.
#
# Reads `claude agents --json --all` and finds the background session with
# the given short id. Prints its state on the first line:
#   working            still running (the loop keeps polling)
#   moved              still running, but no longer in DIR (with --dir): it
#                      entered a worktree or another folder
#   done               its turn ended; the session is still live
#   hang               still working, but its transcript has not grown in
#                      --stall seconds (#58): report it, leave it running
#   blocked <what>     waiting on a human: `permission prompt`, `input needed`,
#                      or `question` when claude agents names no waitingFor:
#                      the worker asked in plain text (#85)
#   capture-due        still working, and with --zone its context reading
#                      is due for a capture at a safe point (zone.sh --due,
#                      #60): the supervisor captures it and continues the
#                      ticket in a fresh session
#   stopped            stopped, conversation kept
#   gone               not in the list: removed, or never started
#   unknown <state>    a state this script does not know
# then `cwd <path>` (where the session runs), for capture-due `reading <N>%
# of zone` and the due line, and for a blocked session
# `needs <text>`: the action a `Waiting on:` line names (below), or else what
# its job's state.json under $CLAUDE_CONFIG_DIR names, when it names one.
#
# `hang` is a polling-loop state, not something a single classification can
# see: it needs the session's transcript size at an earlier poll to compare
# against. --file classifies one snapshot and never reports it. A long tool
# call can hold the transcript's size steady for a while in its own right
# (the result is appended only once the call returns), so `hang` is a
# "no progress for a while" signal to report, not proof the worker is stuck
# -- hence left running rather than stopped.
#
# With --since, it also compares DIR's repo with a snapshot taken before the
# launch, and prints `worktree <path>` for each worktree added since, and
# `branch <name>` for each branch other than the snapshot's current one that
# was made or moved since, each followed by a `commit <sha> <subject>` line
# for each of its commits that neither the snapshot's HEAD nor that current
# branch holds. Any such line turns working or done into moved. A Project
# with a Distribution repo (#125) has it in the snapshot too; what it gained
# follows a `distribution <path>` line, in the same lines.
# A worker denied EnterWorktree made its worktree with `git worktree add`
# from Bash and kept its cwd in DIR, so its cwd alone does not show it (#83).
# A worktree locked with a reason starting `claude agent bridge-` is a
# session the Claude app started through a remote-control server in DIR
# during the run, not the worker: it is listed as `other <path>` instead,
# its branch is left out of the branch lines, and neither turns the state
# into moved (#84).
#
# The state comes from `state`, not `status`: a session just launched shows
# `status: idle` while its `state` is `working`. But `state` can go on saying
# working for hours after the turn ended (#73), so a working session with
# `status: idle` whose transcript shows the turn ended is reported as done,
# with a last line `note claude agents still said working`. A done session
# whose last text has a line starting `Waiting on:` is reported as `blocked
# input needed`, with a `needs` line naming the action (#88). So is a blocked
# session with no waitingFor whose last text has one; that line wins over
# the job's needs (#97). A blocked session with no waitingFor whose last
# text ends on a statement, not a question, is reported as done, with a last
# line `note claude agents said blocked` (#114): a finished report that
# quotes a decision reads as a question to claude agents.
#
# Usage:
#   watch.sh --id ID [--dir DIR [--since FILE]] [--after EPOCH] [--zone] [--interval SECONDS] [--timeout SECONDS] [--stall SECONDS]
#       poll until a state other than working; on timeout print the last
#       one and exit 124
#   watch.sh --id ID [--dir DIR [--since FILE]] [--after EPOCH] [--zone] --file PATH
#       classify one saved `claude agents --json --all` output
#   watch.sh --dir DIR --snapshot
#       print DIR's repo state for --since: take it before the launch
#
# DIR is the Project folder the worker was launched in. Without it, a working
# session is working wherever it runs. --stall is how long the transcript
# may hold steady before a poll reports hang (default 1800); --file never
# reports it, since it has only one snapshot to look at. --after is the
# `after` line resume.sh prints: a watch that follows a resume passes it, so
# the turn that ended before the resume is not read as the resumed one's end
# (#122). With it, a done needs a turn end in the transcript stamped at or
# after it, whether the transcript or claude agents says done (a done from
# the list with no transcript found stands), a `Waiting on:` line counts
# only in text stamped at or after it (#126), and a blocked question from
# the list needs assistant text stamped at or after it, or reads as working
# (one with no transcript found stands; a block that names its waitingFor is
# not gated) (#127). --zone reads a working worker's zone reading from its
# transcript at each poll, and returns `capture-due` once zone.sh calls it due; a
# worker with no transcript found, or no reading, goes on working.
#
# Exits 1 when the list cannot be read, which is never reported as gone.

set -u

ID=""
FILE=""
DIR=""
SINCE=""
SNAPSHOT=""
AFTER=""
ZONE=""
INTERVAL=30
TIMEOUT=14400
STALL=1800

need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --id)       need_value "$@"; ID="$2"; shift 2 ;;
        --file)     need_value "$@"; FILE="$2"; shift 2 ;;
        --dir)      need_value "$@"; DIR="$2"; shift 2 ;;
        --since)    need_value "$@"; SINCE="$2"; shift 2 ;;
        --snapshot) SNAPSHOT=1; shift ;;
        --after)    need_value "$@"; AFTER="$2"; shift 2 ;;
        --zone)     ZONE=1; shift ;;
        --interval) need_value "$@"; INTERVAL="$2"; shift 2 ;;
        --timeout)  need_value "$@"; TIMEOUT="$2"; shift 2 ;;
        --stall)    need_value "$@"; STALL="$2"; shift 2 ;;
        --help)
            printf 'Usage: watch.sh --id ID [--dir DIR [--since FILE]] [--after EPOCH] [--zone] [--interval S] [--timeout S] [--stall S] | watch.sh --id ID [--dir DIR [--since FILE]] [--after EPOCH] [--zone] --file PATH | watch.sh --dir DIR --snapshot\n'
            printf 'Prints: working, moved, done, capture-due, hang, blocked <what>, stopped, gone or unknown <state>; then cwd, reading, needs, worktree, branch and commit lines.\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
if [ -n "$DIR" ]; then
    [ -d "$DIR" ] || fail "not a directory: $DIR"
    DIR=$(CDPATH= cd -- "$DIR" && pwd -P)
fi

# snapshot <repo>: its HEAD, current branch, worktrees and branch tips, one
# per line, or exit 1 when it is not in a repo with a commit.
snapshot() {
    head=$(git -C "$1" rev-parse --verify -q HEAD) || return 1
    printf 'head %s\nbranch %s\n' "$head" "$(git -C "$1" branch --show-current)"
    git -C "$1" worktree list --porcelain | sed -n '/^worktree /p'
    git -C "$1" for-each-ref refs/heads --format='ref %(refname:short) %(objectname)'
}

# The Project's Distribution repo (#125), as launch.sh reads it, follows
# DIR's lines in the snapshot: a `distribution <path>` line, then its own
# lines, each starting `dist `. A --since watch reads the path from there,
# so it watches the repo the launch checked for the whole run.
if [ -n "$SNAPSHOT" ]; then
    [ -n "$DIR" ] || fail "--snapshot needs --dir"
    snap=$(snapshot "$DIR") || fail "no commit to snapshot in $DIR"
    dist=$(sh "$(dirname -- "$0")/distribution.sh" --dir "$DIR" </dev/null) ||
        fail "distribution.sh failed, so the Distribution repo is unknown"
    if [ -n "$dist" ]; then
        dist_snap=$(snapshot "$dist") || fail "no commit to snapshot in Distribution repo $dist"
        snap=$(printf '%s\ndistribution %s\n%s' "$snap" "$dist" "$(printf '%s\n' "$dist_snap" | sed 's/^/dist /')")
    fi
    printf '%s\n' "$snap"
    exit 0
fi

[ -n "$ID" ] || fail "--id is required"
case $INTERVAL in '' | *[!0-9]*) fail "--interval needs whole seconds, not '$INTERVAL'" ;; esac
case $TIMEOUT in '' | *[!0-9]*) fail "--timeout needs whole seconds, not '$TIMEOUT'" ;; esac
case $STALL in '' | *[!0-9]*) fail "--stall needs whole seconds, not '$STALL'" ;; esac
case $AFTER in *[!0-9]*) fail "--after needs epoch seconds, not '$AFTER'" ;; esac
# claude agents and the job's state.json both follow the config dir, so an
# unset one would read another profile's sessions.
[ -n "${CLAUDE_CONFIG_DIR:-}" ] || fail "CLAUDE_CONFIG_DIR is not set, so the profile being watched is unknown"
if [ -n "$SINCE" ]; then
    [ -n "$DIR" ] || fail "--since needs --dir"
    [ -f "$SINCE" ] || fail "no such snapshot: $SINCE"
fi

# classify <agents json>: the report lines for $ID, or exit 1 when the input
# is not a JSON array.
classify() {
    printf '%s' "$1" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
    printf '%s' "$1" | jq -r --arg id "$ID" '
        [.[] | select(.kind == "background" and .id == $id)] | first
        | if . == null then "gone"
          else (if .state == "working" or .state == "done" or .state == "stopped" then .state
                elif .state == "blocked" then "blocked \(.waitingFor // "question")"
                else "unknown \(.state // "none")" end),
               (.cwd // empty | "cwd \(.)")
          end'
}

# AFTER_JQ: defines the jq filter `not_before`, true for a row stamped at or
# after --after (never for a row with no timestamp jq can read), and for
# every row without --after. turn_ended, stale_since and last_text pass it
# with --arg after "$AFTER".
AFTER_JQ='def not_before: $after == "" or ((.timestamp // "" | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch 0) >= ($after | tonumber));'

# transcript_of <session id>: the path of the session's main transcript, or
# empty when none is found. It is looked for in every project folder, since
# a worker that entered a worktree has its transcript moved to the
# worktree's folder.
transcript_of() {
    [ -n "$1" ] || return 0
    for t in "$CLAUDE_CONFIG_DIR"/projects/*/"$1".jsonl; do
        [ -f "$t" ] || continue
        printf '%s\n' "$t"
        return 0
    done
}

# turn_ended <session id>: whether the session's transcript shows its turn
# ended: its last conversation row is a turn_duration row with no background
# agents pending, since their reports start another turn. With --after, that
# row counts only when it is stamped at or after AFTER: right after a
# resume, the last row is still the turn_duration that ended the previous
# turn (#122).
turn_ended() {
    t=$(transcript_of "$1")
    [ -n "$t" ] || return 1
    jq -e -s "$AFTER_JQ"'[.[] | select(.type == "user" or .type == "assistant" or .type == "system")] | last
        | .type == "system" and .subtype == "turn_duration"
          and (.pendingBackgroundAgentCount // 0) == 0 and not_before' --arg after "$AFTER" "$t" >/dev/null 2>&1
}

# stale_since <session id> <jq row test>: whether what the list says is the
# previous turn's: with --after, the session's transcript is found and has
# no row passing the test stamped at or after AFTER. With no transcript
# found, the list stands. stale_done and stale_question name the tests.
stale_since() {
    t=$(transcript_of "$1")
    [ -n "$t" ] || return 1
    jq -e -s "$AFTER_JQ"'any(.[]; ('"$2"') and not_before) | not' \
        --arg after "$AFTER" "$t" >/dev/null 2>&1
}

# stale_done <session id>: whether a done from claude agents is the previous
# turn's: no turn_duration row at or after AFTER. Time is all it checks, so
# a turn that ended with background agents pending still counts (#126).
stale_done() {
    stale_since "$1" '.type == "system" and .subtype == "turn_duration"'
}

# stale_question <session id>: whether a blocked question from claude
# agents is the previous turn's: no assistant text at or after AFTER (#127).
stale_question() {
    stale_since "$1" '.type == "assistant" and (.isSidechain | not) and any(.message.content[]?; .type == "text")'
}

# last_text <session id>: the session's last text, read from the main
# transcript only, as turn_ended reads it; empty when it has none. With
# --after, only text stamped at or after AFTER is read: the previous turn's
# text is not what a resumed worker ended on (#126).
last_text() {
    t=$(transcript_of "$1")
    [ -n "$t" ] || return 0
    jq -r -s "$AFTER_JQ"'[.[] | select(.type == "assistant" and (.isSidechain | not) and not_before)
               | .message.content[]? | select(.type == "text") | .text // empty]
              | last // empty' --arg after "$AFTER" "$t" 2>/dev/null
    return 0
}

# waiting_on <session id>: the action a worker whose turn ended waits on,
# from a line starting `Waiting on:` in its last text, which launch.sh tells
# it to end on when a shared action has no grant (#88); empty when none. The
# line may be wrapped in backticks or bold.
waiting_on() {
    last_text "$1" | sed -n 's/^[`* ]*Waiting on: *//p' | sed 's/[`* ]*$//' | tail -n 1
}

# QUESTION_JQ: defines the jq filter `asks`, true for a text whose last
# non-blank line, less trailing markdown, ends on a question mark. record.sh
# carries the same definition, and the same `Waiting on:` line test, to count
# only the waits this confirms.
QUESTION_JQ='def asks: [splits("\n") | sub("[\\s`*_\")]+$"; "") | select(. != "")] | last // "" | endswith("?");'

# ends_unasked <session id>: whether its last text is found and ends on a
# statement rather than a question to the maintainer: a finished report that
# quotes a decision, which claude agents can read as a question (#114).
ends_unasked() {
    text=$(last_text "$1")
    [ -n "$text" ] || return 1
    jq -en --arg t "$text" "$QUESTION_JQ"'$t | asks | not' >/dev/null 2>&1
}

# session_id_of <agents json>: the job's sessionId, or empty when the list
# cannot be read or names none. classify() only reads this for an idle
# session (to call turn_ended); the stall check below needs it whatever the
# status is.
session_id_of() {
    printf '%s' "$1" | jq -r --arg id "$ID" '
        [.[] | select(.kind == "background" and .id == $id)] | first
        | .sessionId // empty' 2>/dev/null
}

# transcript_size <session id>: total bytes across its transcript and the
# subagent transcripts in the folder beside it, or empty when it has none
# (never 0 for "no transcript yet", so a session with no transcript at all
# never compares equal across polls and falsely reports no progress).
transcript_size() {
    main=$(transcript_of "$1")
    [ -n "$main" ] || { echo ""; return; }
    total=0
    for t in "$main" "${main%.jsonl}"/subagents/*.jsonl; do
        [ -f "$t" ] || continue
        sz=$(wc -c <"$t" 2>/dev/null) || sz=0
        total=$((total + sz))
    done
    echo "$total"
}

# lock_reason <worktree path>: its "locked" reason in $repo, or empty when
# it is not locked.
lock_reason() {
    git -C "$repo" worktree list --porcelain | awk -v target="$1" '
        /^worktree / { path = substr($0, 10); next }
        path == target && /^locked / { print substr($0, 8); exit }
    '
}

# made_since <repo> <snapshot lines>: the worktree, branch, other and
# commit lines for what the repo gained since its snapshot, or a note when
# the repo was not read.
made_since() {
    repo=$1
    snap=$2
    now=$(snapshot "$repo") || { printf 'note the repo in %s was not read\n' "$repo"; return 0; }
    base=$(printf '%s\n' "$snap" | sed -n 's/^head //p')
    current=$(printf '%s\n' "$snap" | sed -n 's/^branch //p')
    # Commits listed are those neither the snapshot's HEAD nor the folder's
    # branch holds.
    set -- "$base"
    if [ -n "$current" ] && git -C "$repo" rev-parse -q --verify "refs/heads/$current" >/dev/null; then
        set -- "$base" "refs/heads/$current"
    fi
    new_worktrees=$(printf '%s\n' "$now" | sed -n 's/^worktree //p')
    bridge_branches=""
    old_ifs=$IFS
    IFS='
'
    for w in $new_worktrees; do
        IFS=$old_ifs
        printf '%s\n' "$snap" | grep -Fqx "worktree $w" && continue
        reason=$(lock_reason "$w")
        case $reason in
            "claude agent bridge-"*)
                printf 'other %s\n' "$w"
                br=$(git -C "$w" symbolic-ref -q --short HEAD 2>/dev/null)
                [ -z "$br" ] || bridge_branches="$bridge_branches
$br"
                continue ;;
        esac
        printf 'worktree %s\n' "$w"
        # A detached worktree's commits are on no branch, so list them here.
        git -C "$w" symbolic-ref -q HEAD >/dev/null && continue
        commits "$(git -C "$w" rev-parse HEAD)" "$@"
    done
    IFS=$old_ifs
    printf '%s\n' "$now" | sed -n 's/^ref //p' | while read -r name tip; do
        [ "$name" != "$current" ] || continue
        printf '%s\n' "$bridge_branches" | grep -Fqx "$name" && continue
        printf '%s\n' "$snap" | grep -Fqx "ref $name $tip" && continue
        printf 'branch %s\n' "$name"
        commits "$tip" "$@"
    done
}

# commits <tip> <excluded>...: a commit line for each commit on tip and not
# on any excluded one, or a note when git could not list them.
commits() {
    tip=$1; shift
    git -C "$repo" log --format='commit %h %s' "$tip" --not "$@" ||
        printf 'note the commits on %s were not read\n' "$tip"
}

# report <agents json>: classify, adding the job's needs to a blocked state.
# A working session whose cwd is not DIR has moved. A working session with
# status idle whose transcript says its turn ended is done: the state list
# can go on saying working for hours after that. A done session, or a
# blocked one with no waitingFor, whose last text has a `Waiting on:` line
# is `blocked input needed`, with that action as its needs line in place of
# the job's: the service can mark that worker blocked before it is seen
# done, and the job's needs can name a side question from its report (#97).
# A blocked one with no waitingFor and no such line, whose last text ends on
# a statement rather than a question, is done, with a note (#114).
# With --after, a done from the list whose transcript shows no turn end at
# or after it is still working: the list can show the previous turn's done
# for a moment after a resume (#126). So is a blocked question from the list
# whose transcript holds no assistant text at or after it (#127).
# With --zone, a working session whose reading zone.sh calls due is
# capture-due.
# With --since, a worktree or branch made in the repo since the snapshot is
# listed, and makes a working, done or capture-due session moved. So is one made in the
# Distribution repo the snapshot names, after a `distribution <path>` line.
report() {
    out=$(classify "$1") || return 1
    case $out in
        done*)
            if [ -n "$AFTER" ] && stale_done "$(session_id_of "$1")"; then
                out=$(printf 'working%s' "${out#done}")
            fi ;;
        "blocked question"*)
            if [ -n "$AFTER" ] && stale_question "$(session_id_of "$1")"; then
                out=$(printf 'working%s' "${out#blocked question}")
            fi ;;
    esac
    case $out in
        working*)
            cwd=$(printf '%s\n' "$out" | sed -n 's/^cwd //p')
            if [ -n "$DIR" ] && [ -n "$cwd" ] && [ "$cwd" != "$DIR" ]; then
                out=$(printf 'moved\ncwd %s' "$cwd")
            else
                session_id=$(printf '%s' "$1" | jq -r --arg id "$ID" '
                    [.[] | select(.kind == "background" and .id == $id)] | first
                    | select(.status == "idle") | .sessionId // empty')
                if turn_ended "$session_id"; then
                    out=$(printf 'done%s\nnote claude agents still said working' "${out#working}")
                elif [ -n "$ZONE" ] && t=$(transcript_of "$(session_id_of "$1")") && [ -n "$t" ] &&
                    reading=$(sh "$(dirname -- "$0")/zone.sh" --transcript "$t" --due </dev/null 2>/dev/null); then
                    out=$(printf 'capture-due%s\nreading %s\n%s' "${out#working}" \
                        "$(printf '%s\n' "$reading" | head -n 1)" "$(printf '%s\n' "$reading" | sed -n 2p)")
                fi
            fi ;;
    esac
    waits=""
    case $out in
        done* | "blocked question"*) waits=$(waiting_on "$(session_id_of "$1")") ;;
    esac
    if [ -n "$waits" ]; then
        out=$(printf '%s\nneeds %s' "$(printf '%s\n' "$out" | sed '1s/.*/blocked input needed/')" "$waits")
    else
        case $out in
            "blocked question"*)
                if ends_unasked "$(session_id_of "$1")"; then
                    out=$(printf '%s\nnote claude agents said blocked' "$(printf '%s\n' "$out" | sed '1s/.*/done/')")
                fi ;;
        esac
        case $out in
            blocked*)
                job="$CLAUDE_CONFIG_DIR/jobs/$ID/state.json"
                if [ -f "$job" ]; then
                    needs=$(jq -r '.needs // empty' "$job" 2>/dev/null)
                    [ -z "$needs" ] || out=$(printf '%s\nneeds %s' "$out" "$needs")
                fi ;;
        esac
    fi
    if [ -n "$SINCE" ]; then
        made=$(made_since "$DIR" "$(command cat "$SINCE")")
        dist=$(sed -n 's/^distribution //p' "$SINCE")
        if [ -n "$dist" ]; then
            dist_made=$(made_since "$dist" "$(sed -n 's/^dist //p' "$SINCE")")
            [ -z "$dist_made" ] || made=$(printf '%s\n%s' "${made:+$made
}distribution $dist" "$dist_made")
        fi
        if [ -n "$made" ]; then
            if printf '%s\n' "$made" | grep -Eq '^(worktree|branch) '; then
                case $out in
                    working* | done* | capture-due*) out=$(printf '%s\n' "$out" | sed '1s/.*/moved/') ;;
                esac
            fi
            out=$(printf '%s\n%s' "$out" "$made")
        fi
    fi
    printf '%s\n' "$out"
}

if [ -n "$FILE" ]; then
    [ -f "$FILE" ] || { printf 'Error: no such file: %s\n' "$FILE" >&2; exit 1; }
    report "$(command cat "$FILE")" || { printf 'Error: not a JSON array: %s\n' "$FILE" >&2; exit 1; }
    exit 0
fi

start=$(date +%s)
stall_size=""
stall_since=$start
while :; do
    if ! list=$(claude agents --json --all </dev/null); then
        printf 'Error: claude agents --json --all failed\n' >&2
        exit 1
    fi
    out=$(report "$list") || { printf 'Error: claude agents --json --all printed no JSON array\n' >&2; exit 1; }
    now=$(date +%s)
    case $out in
        working*)
            size=$(transcript_size "$(session_id_of "$list")")
            if [ -z "$size" ]; then
                stall_size="" stall_since=$now
            elif [ "$size" != "$stall_size" ]; then
                stall_size=$size stall_since=$now
            elif [ $((now - stall_since)) -ge "$STALL" ]; then
                out=$(printf '%s\n' "$out" | sed '1s/.*/hang/')
                out=$(printf '%s\nnote its transcript has not grown in %ss\n' "$out" "$((now - stall_since))")
            fi ;;
    esac
    case $out in
        working*) ;;
        *) printf '%s\n' "$out"; exit 0 ;;
    esac
    if [ $((now - start)) -ge "$TIMEOUT" ]; then
        printf '%s\n' "$out"
        exit 124
    fi
    sleep "$INTERVAL"
done
