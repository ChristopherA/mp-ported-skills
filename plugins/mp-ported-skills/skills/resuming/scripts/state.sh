#!/bin/sh
# state.sh -- read-only snapshot of where a repo's work stands, and the next step.
#
# Reads git (no fetch: remote refs are as of the last fetch) and, when
# docs/agents/issue-tracker.md names GitHub, the tracker through `gh`. Prints
# state lines, then `next: <case> ...` for the first of the six weighing cases
# that applies and `runner-up: ...` for the second (case 6's suggestions when
# no other applies). Writes nothing.
#
# Usage: sh state.sh [--hook] [dir]
#   default  report everything; an unreached tracker is reported, not hidden.
#   --hook   SessionStart mode: dir defaults to $CLAUDE_PROJECT_DIR; prints
#            nothing unless docs/agents/issue-tracker.md exists and the tracker
#            was reached; always exits 0.
# Env: MP_RESUME_BUDGET  seconds before giving up (default 4 with --hook, else 30)

set -u

hook=0
if [ "${1:-}" = --hook ]; then hook=1; shift; fi
if [ $hook = 1 ]; then dir=${1:-${CLAUDE_PROJECT_DIR:-$PWD}}; else dir=${1:-$PWD}; fi
case ${MP_RESUME_BUDGET:-} in
    '' | *[!0-9]*) if [ $hook = 1 ]; then budget=4; else budget=30; fi ;;
    *) budget=$MP_RESUME_BUDGET ;;
esac

cd "$dir" 2>/dev/null || exit 0
if [ $hook = 1 ]; then
    [ -f docs/agents/issue-tracker.md ] || exit 0
    exec 2>/dev/null
fi

# Label string for a triage role, from docs/agents/triage-labels.md; the role
# name itself when the file or row is missing.
label_for() {
    l=
    if [ -f docs/agents/triage-labels.md ]; then
        l=$(awk -F'|' -v role="$1" '
            { r = $2; s = $3; gsub(/[ `]/, "", r); gsub(/[ `]/, "", s) }
            r == role && s != "" { print s; exit }' docs/agents/triage-labels.md)
    fi
    printf '%s' "${l:-$1}"
}

# Every command this script names is user-invoked in mattpocock-skills
# (disable-model-invocation: true), so it is missing from the model's skill
# list; the marker keeps the reply from calling it absent or substituting one.
you_type="(you type it; user-invoked)"
# Case 6's suggestions, the runner-up when no later case applies.
ideas="/grill-with-docs on a new idea, or /improve-codebase-architecture (you type these; they are user-invoked)"

gather() {
    command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1 || {
        echo "git: not a repository"
        [ $hook = 1 ] && exit 3
        echo "next: 6 nothing in motion"
        echo "runner-up: $ideas"
        exit 0
    }

    # --- git -------------------------------------------------------------
    branch=$(git symbolic-ref --short -q HEAD || echo "(detached)")
    default=$(git symbolic-ref --short -q refs/remotes/origin/HEAD)
    default=${default#origin/}
    if [ -z "$default" ]; then
        for b in main master; do
            git show-ref -q --verify "refs/heads/$b" && { default=$b; break; }
        done
    fi
    default=${default:-main}
    defref=$default
    git show-ref -q --verify "refs/remotes/origin/$default" && defref=origin/$default

    dirty=$(git status --porcelain | wc -l | tr -d ' ')
    if git remote | grep -q .; then
        unpushed=$(git rev-list --count HEAD --not --remotes 2>/dev/null || echo 0)
    else
        unpushed=0
    fi
    sync=
    if up=$(git rev-parse --abbrev-ref -q '@{u}' 2>/dev/null); then
        set -- $(git rev-list --left-right --count "$up...HEAD")
        if [ "$1" = 0 ] && [ "$2" = 0 ]; then sync="in sync with $up"
        else sync="ahead $2, behind $1 of $up"; fi
    else
        sync="no upstream"
    fi
    echo "branch: $branch (default $default), $sync, as of last fetch"
    echo "uncommitted paths: $dirty; unpushed commits: $unpushed"

    # Issue numbers the default branch's commit messages close.
    fixed=$(git log "$defref" --format=%B 2>/dev/null |
        grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?):? +#[0-9]+' |
        grep -oE '[0-9]+' | sort -un | tr '\n' ' ')

    inflight=
    [ "$dirty" -gt 0 ] && inflight="$inflight, $dirty uncommitted paths"
    [ "$unpushed" -gt 0 ] && inflight="$inflight, $unpushed unpushed commits"
    [ "$branch" != "$default" ] && inflight="$inflight, on $branch not $default"

    # --- tracker ---------------------------------------------------------
    tracker=none
    if [ -f docs/agents/issue-tracker.md ]; then
        if head -n 5 docs/agents/issue-tracker.md | grep -qi github; then tracker=github
        else tracker=other; fi
    fi
    reached=0 why=
    if [ $tracker = github ]; then
        if ! command -v jq >/dev/null; then why="jq not installed"
        elif ! command -v gh >/dev/null; then why="gh not installed"
        elif ! issues=$(gh api 'repos/{owner}/{repo}/issues?state=open&per_page=100' 2>/dev/null) ||
            ! printf '%s' "$issues" | jq -e 'type == "array"' >/dev/null 2>&1; then
            why="gh api failed (offline, unauthenticated, or no GitHub remote)"
        elif ! prs=$(gh pr list --state open --json number,title,headRefName,isCrossRepository 2>/dev/null) ||
            ! printf '%s' "$prs" | jq -e 'type == "array"' >/dev/null 2>&1; then
            why="gh pr list failed"
        else reached=1; fi
    fi

    case $tracker in
        none) echo "tracker: no docs/agents/issue-tracker.md; run /setup-matt-pocock-skills $you_type" ;;
        other) echo "tracker: not GitHub; read it per docs/agents/issue-tracker.md" ;;
        github) if [ $reached = 1 ]; then echo "tracker: GitHub, reached"
            else echo "tracker: GitHub, UNREACHED: $why"; fi ;;
    esac
    if [ $tracker = github ] && [ $reached = 0 ] && [ $hook = 1 ]; then exit 3; fi

    if [ $reached = 1 ]; then
        t_triage=$(label_for needs-triage) t_info=$(label_for needs-info)
        t_agent=$(label_for ready-for-agent) t_human=$(label_for ready-for-human)
        t_wont=$(label_for wontfix)

        own=$(printf '%s' "$prs" | jq -r '[.[] | select(.isCrossRepository | not)]
            | map("#\(.number) \(.title) [\(.headRefName)]") | join("; ")')
        [ -n "$own" ] && echo "open PRs from this repo: $own" && inflight="$inflight, open PR $own"

        # Open issues only (the endpoint also lists PRs), with what the cases need.
        rows=$(printf '%s' "$issues" | jq -c --arg tr "$t_triage" --arg ti "$t_info" \
            --arg ta "$t_agent" --arg th "$t_human" --arg tw "$t_wont" '
            [.[] | select(.pull_request | not)
             | {n: .number, t: .title, c: .comments, l: [.labels[].name],
                dep: (.issue_dependencies_summary.blocked_by // 0),
                line: ([(.body // "") | splits("\r?\n")
                        | select(test("^\\s*blocked by:"; "i"))
                        | scan("#([0-9]+)") | .[0] | tonumber])}
             | .role = (if (.l | index($ta)) then "agent"
                        elif (.l | index($th)) then "human"
                        elif (.l | index($ti)) then "info"
                        elif (.l | index($tr)) then "triage"
                        elif (.l | index($tw)) then "wontfix"
                        elif (.l | index("wayfinder:map")) then "map"
                        elif any(.l[]; startswith("wayfinder:")) then "wayfinder"
                        else "unlabelled" end)]
            | sort_by(.n)')
        open_nums=$(printf '%s' "$rows" | jq -c '[.[].n]')
        fixed_nums=$(printf '%s' "$fixed" | jq -Rc 'split(" ") | map(select(. != "") | tonumber)')
        count() { printf '%s' "$rows" | jq --arg r "$1" '[.[] | select(.role == $r)] | length'; }

        # Open tickets the default branch already closes.
        stale=$(printf '%s' "$rows" | jq -r --argjson fx "$fixed_nums" '
            [.[] | select(.n as $n | $fx | index($n))] | map("#\(.n) \(.t)") | join("; ")')

        # Ready-for-agent tickets with every blocker closed, not already fixed.
        ready=$(printf '%s' "$rows" | jq -r --argjson open "$open_nums" --argjson fx "$fixed_nums" '
            [.[] | select(.role == "agent" and .dep == 0
                            and ([.line[] | select(. as $b | $open | index($b))] | length == 0)
                            and (.n as $n | $fx | index($n) | not))]
            | map("#\(.n) \(.t)") | join("; ")')

        # Ready-for-human tickets a session left in motion: capturing labels the
        # one it worked on, which git cannot see. Not already fixed.
        moving=$(printf '%s' "$rows" | jq -r --argjson fx "$fixed_nums" '
            [.[] | select(.role == "human" and (.l | index("in-motion"))
                            and (.n as $n | $fx | index($n) | not))]
            | map("#\(.n) \(.t)") | join("; ")')
        [ -n "$moving" ] && inflight="$inflight, in motion $moving"

        # needs-info with a reply: the last comment is not the tracker user's.
        replied=
        infos=$(printf '%s' "$rows" | jq -r '.[] | select(.role == "info" and .c > 0) | .n')
        if [ -n "$infos" ]; then
            me=$(gh api user 2>/dev/null | jq -r '.login // empty')
            for n in $infos; do
                last=$(gh api "repos/{owner}/{repo}/issues/$n/comments?per_page=100" 2>/dev/null |
                    jq -r 'last.user.login // empty')
                [ -n "$last" ] && [ "$last" != "$me" ] && replied="$replied #$n"
            done
        fi
        replied=${replied# }

        n_triage=$(count triage) n_info=$(count info) n_unl=$(count unlabelled)
        n_agent=$(count agent) n_human=$(count human) n_map=$(count map)
        maps=$(printf '%s' "$rows" | jq -r '[.[] | select(.role == "map")] | map("#\(.n) \(.t)") | join("; ")')
        echo "issues: $n_unl unlabelled, $n_triage $t_triage, $n_info $t_info (replied: ${replied:-none}), $n_agent $t_agent, $n_human $t_human, $n_map wayfinder:map"
        echo "in motion: ${moving:-none}"
        echo "ready, blockers closed: ${ready:-none}"
        echo "open but closed by a commit on $default: ${stale:-none}"
        [ -n "$maps" ] && echo "wayfinder maps: $maps"
    fi

    # --- weigh: the first case that applies, and the next one ------------
    # Every applicable case in order; the first is next, the second runner-up.
    cases=
    add_case() { cases="$cases$1
"; }
    [ -n "$inflight" ] && add_case "1 work in flight: ${inflight#, }"
    if [ $reached = 0 ]; then
        [ -n "$inflight" ] || add_case "undecided: git shows nothing in flight; the tracker was not read"
        add_case "none known: the tracker was not read"
    else
        [ -n "$ready" ] && add_case "2 /implement ${ready%% *} $you_type: ${ready%%;*}"
        if [ "$n_unl" -gt 0 ] || [ "$n_triage" -gt 0 ] || [ -n "$replied" ]; then
            add_case "3 /triage $you_type: $n_unl unlabelled, $n_triage $t_triage, replied $t_info: ${replied:-none}"
        fi
        # The open list can lag a push that closed the ticket by a few seconds.
        [ -n "$stale" ] && add_case "4 tracker and repo disagree: close $stale (as of the last read: confirm with gh issue view first)"
        [ "$n_map" -gt 0 ] && add_case "5 /wayfinder $you_type: $maps"
        if [ -n "$cases" ]; then add_case "6 nothing else in motion: $ideas"
        else add_case "6 nothing in motion"; add_case "$ideas"; fi
    fi
    printf '%s' "$cases" | sed -n '1s/^/next: /p; 2s/^/runner-up: /p'
}

# gather runs in the background so the watchdog can stop a hung `gh`. The EXIT
# trap is set after both forks: a subshell that inherits one defers the kill
# until its current command returns.
tmp=$(mktemp -d) || exit 0
gather >"$tmp/out" &
gpid=$!
(sleep "$budget"; kill "$gpid") >/dev/null 2>&1 &
wpid=$!
trap 'command rm -rf "$tmp"' EXIT
wait "$gpid"
rc=$?
{ kill "$wpid"; wait "$wpid"; } >/dev/null 2>&1

if [ $rc = 0 ]; then
    cat "$tmp/out"
    if [ $hook = 1 ]; then
        echo "On your first reply, whatever the user wrote, recommend one next step from this state in the resuming skill's shape (the step, its reason, and the runner-up line as the runner-up), then answer anything else they asked. Do not ask what they are working on. Commands marked user-invoked are installed but hidden from your skill list: tell the user to type them, and never call them missing or swap in a model-invocable skill."
    fi
elif [ $hook = 0 ]; then
    cat "$tmp/out"
    if [ $rc -gt 128 ]; then echo "timed out after ${budget}s; the lines above are all that was read"
    else echo "state.sh failed (exit $rc)"; fi
fi
exit 0
