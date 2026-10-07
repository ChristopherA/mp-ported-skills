#!/bin/sh
# state.sh -- read-only snapshot of where a repo's work stands, and the next step.
#
# Reads git (no fetch: remote refs are as of the last fetch) and, when
# docs/agents/issue-tracker.md names GitHub, the tracker through `gh`. Prints
# state lines, then `next: <case> ...` for the first of the seven weighing
# cases that applies and `runner-up: ...` for the second (case 7's suggestions
# when no other applies). A ticket labelled `parked` is never a step. Prints
# what each ready ticket unblocks (`unblocks:`), and what the next step's and
# runner-up's tickets unblock, without changing the step. Writes nothing.
#
# Usage: sh state.sh [dir]
#   dir defaults to the current folder. Reports everything; an unreached
#   tracker is reported, not hidden.
# Env: MP_RESUME_BUDGET  seconds before giving up (default 30)

set -u

dir=${1:-$PWD}
# The folder as the caller named it, for the /supervise command.
shown=${1:-.}
case ${MP_RESUME_BUDGET:-} in
    '' | *[!0-9]*) budget=30 ;;
    *) budget=$MP_RESUME_BUDGET ;;
esac

# supervise's main-checkout.sh, found before the cd below.
main_checkout="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/../../supervise/scripts/main-checkout.sh"

cd "$dir" 2>/dev/null || exit 0

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
you_type_bare="you type it; user-invoked"
you_type="($you_type_bare)"
# Case 7's suggestions, the runner-up when no later case applies.
ideas="/grill-with-docs on a new idea, or /improve-codebase-architecture (you type these; they are user-invoked)"

# next_child <n>: "; next child ..." for in-motion parent #n, naming the first
# open sub-issue in the parent's order with every blocker closed (the blocker
# test of the frontier rule in docs/agents/issue-tracker.md) and not parked,
# and its command; "; every open child blocked: ..." with the blockers, or
# "parked", when none qualifies; nothing when #n has no open sub-issues.
# Reads $open_nums, $body_blockers and the label strings. The weigh step reads
# the child's number back from "; next child #N", so keep that wording.
# Reads every page: gh prints one array per page, merged here into one, and
# the first page can hold only closed children.
next_child() {
    subs=$(gh api "repos/{owner}/{repo}/issues/$1/sub_issues?per_page=100" --paginate 2>/dev/null) &&
        subs=$(printf '%s' "$subs" | jq -cs 'add' 2>/dev/null) &&
        printf '%s' "$subs" | jq -e 'type == "array"' >/dev/null 2>&1 ||
        { printf '; sub-issues not read'; return; }
    kids=$(printf '%s' "$subs" | jq -c --argjson open "$open_nums" "$body_blockers"'
        [.[] | select(.state == "open")
         | {n: .number, t: .title, l: [.labels[].name],
            dep: (.issue_dependencies_summary.blocked_by // 0),
            line: [body_blockers[] | select(. as $b | $open | index($b))]}]')
    [ "$(printf '%s' "$kids" | jq length)" = 0 ] && return
    step=$(printf '%s' "$kids" | jq -r --arg ta "$t_agent" --arg th "$t_human" --arg you "$you_type_bare" '
        [.[] | select(.dep == 0 and (.line | length == 0) and (.l | index("parked") | not))]
        | first // empty
        | "; next child #\(.n) ("
          + (if (.l | index($ta)) then "\($ta), /implement #\(.n), \($you)"
             elif (.l | index($th)) then "\($th), by hand"
             else "not ready" end)
          + "): \(.t)"')
    if [ -n "$step" ]; then printf '%s' "$step"; return; fi
    blocked=
    for k in $(printf '%s' "$kids" | jq -r '.[].n'); do
        if printf '%s' "$kids" | jq -e --argjson k "$k" '.[] | select(.n == $k) | .l | index("parked")' >/dev/null; then
            blocked="$blocked, #$k parked"; continue
        fi
        by=$(printf '%s' "$kids" | jq -r --argjson k "$k" '.[] | select(.n == $k) | .line[]')
        if [ "$(printf '%s' "$kids" | jq --argjson k "$k" '.[] | select(.n == $k) | .dep')" -gt 0 ]; then
            by="$by
$(open_link_blockers "$k" | jq -r '.[]')"
        fi
        by=$(printf '%s\n' "$by" | grep . | sort -un | sed 's/^/#/' | tr '\n' ' ')
        blocked="$blocked, #$k by ${by:-an unread blocker}"
    done
    blocked=$(printf '%s' "$blocked" | sed 's/ ,/,/g; s/ $//')
    printf '; every open child blocked: %s' "${blocked#, }"
}

# open_link_blockers <n>: a JSON array of the open tickets GitHub links as
# blocking #n; nothing when the list cannot be read.
open_link_blockers() {
    gh api "repos/{owner}/{repo}/issues/$1/dependencies/blocked_by" 2>/dev/null |
        jq -c '[.[] | select(.state == "open") | .number]' 2>/dev/null
}

gather() {
    command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1 || {
        echo "git: not a repository"
        echo "next: 7 nothing in motion"
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
    close_re='(close[sd]?|fix(e[sd])?|resolve[sd]?):? +#'
    fixed=$(git log "$defref" --format=%B 2>/dev/null |
        grep -oiE "$close_re[0-9]+" |
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

    if [ $reached = 1 ]; then
        t_triage=$(label_for needs-triage) t_info=$(label_for needs-info)
        t_agent=$(label_for ready-for-agent) t_human=$(label_for ready-for-human)
        t_wont=$(label_for wontfix)

        own=$(printf '%s' "$prs" | jq -r '[.[] | select(.isCrossRepository | not)]
            | map("#\(.number) \(.title) [\(.headRefName)]") | join("; ")')
        [ -n "$own" ] && echo "open PRs from this repo: $own" && inflight="$inflight, open PR $own"

        # A body's priority line, its first non-blank line (**Priority: High.**),
        # as high, medium or low; null when there is none.
        body_blockers='def priority: [(.body // "") | splits("\r?\n") | select(test("\\S"))][0] // ""
            | (capture("^\\s*\\*\\*Priority: *(?<p>high|medium|low)"; "i") | .p | ascii_downcase) // null;'
        # Issue numbers a body names as blockers: on `Blocked by:` lines, and in
        # bullets under a `Blocked by` heading (any level or case) up to the
        # next heading, the form tickets split from a spec use. Lines in a code
        # fence, closed only by its own marker, are examples, not blockers.
        body_blockers="$body_blockers"'def body_blockers: reduce ((.body // "") | splits("\r?\n")) as $line
            ({fence: null, under: false, nums: []};
             ($line | capture("^\\s*(?<m>```|~~~)").m // null) as $m
             | if .fence then (if $m == .fence then .fence = null else . end)
             elif $m then .fence = $m
             elif ($line | test("^\\s*#+\\s")) then
                 .under = ($line | test("^\\s*#+\\s*blocked by\\s*(:.*)?$"; "i"))
                 | if .under then .nums += [$line | scan("#([0-9]+)") | .[0] | tonumber] else . end
             elif ($line | test("^\\s*blocked by:"; "i")) or (.under and ($line | test("^\\s*[-*+]\\s")))
             then .nums += [$line | scan("#([0-9]+)") | .[0] | tonumber]
             else . end) | .nums;'

        # Open issues only (the endpoint also lists PRs), with what the cases need.
        rows=$(printf '%s' "$issues" | jq -c --arg tr "$t_triage" --arg ti "$t_info" \
            --arg ta "$t_agent" --arg th "$t_human" --arg tw "$t_wont" "$body_blockers"'
            [.[] | select(.pull_request | not)
             | {n: .number, t: .title, c: .comments, l: [.labels[].name],
                dep: (.issue_dependencies_summary.blocked_by // 0),
                line: body_blockers, p: priority}
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
        # -n, not -R on stdin: with no closing commits the input is empty, -R
        # emits nothing, and every --argjson fx below fails.
        fixed_nums=$(jq -nc --arg f "$fixed" '$f | split(" ") | map(select(. != "") | tonumber)')
        # An open ticket reopened on GitHub after its newest closing commit was
        # reopened on purpose (to wait for a live check, say): open work, not
        # fixed. A ticket whose events cannot be read stays fixed. Each read
        # spends the time budget, but only open tickets a commit closes are read.
        for n in $(printf '%s' "$rows" | jq -r --argjson fx "$fixed_nums" '.[] | select(.n as $n | $fx | index($n)) | .n'); do
            at=$(git log "$defref" -1 --format=%ct -i -E \
                --grep="$close_re$n([^0-9]|\$)" 2>/dev/null)
            [ -n "$at" ] || continue
            ev=$(gh api "repos/{owner}/{repo}/issues/$n/events?per_page=100" --paginate 2>/dev/null) || continue
            printf '%s' "$ev" | jq -se --argjson at "$at" \
                'add | any(.[]; .event == "reopened" and (.created_at | fromdateiso8601) > $at)' >/dev/null 2>&1 &&
                fixed_nums=$(printf '%s' "$fixed_nums" | jq -c --argjson n "$n" 'map(select(. != $n))')
        done
        count() { printf '%s' "$rows" | jq --arg r "$1" '[.[] | select(.role == $r)] | length'; }

        # Open tickets the default branch already closes.
        stale=$(printf '%s' "$rows" | jq -r --argjson fx "$fixed_nums" '
            [.[] | select(.n as $n | $fx | index($n))] | map("#\(.n) \(.t)") | join("; ")')

        # Ready-for-agent tickets with every blocker closed, not already fixed.
        ready_rows=$(printf '%s' "$rows" | jq -c --argjson open "$open_nums" --argjson fx "$fixed_nums" '
            [.[] | select(.role == "agent" and .dep == 0 and (.l | index("parked") | not)
                            and ([.line[] | select(. as $b | $open | index($b))] | length == 0)
                            and (.n as $n | $fx | index($n) | not))]')
        ready=$(printf '%s' "$ready_rows" | jq -r 'map("#\(.n) \(.t)") | join("; ")')

        # What closing each ticket unblocks: the open tickets, not parked,
        # wontfix or already fixed, it is the last open blocker of, by GitHub
        # link or body. Only a ticket with one open link (dep, GitHub's open
        # count) has its links read: with two it cannot be unblocked by one
        # close, and each read spends the time budget. A ticket whose links
        # were not read has unknown blockers and is left out.
        targets=$(printf '%s' "$rows" | jq -c --argjson fx "$fixed_nums" '
            [.[] | select(.dep <= 1 and .role != "wontfix" and (.l | index("parked") | not)
                          and (.n as $n | $fx | index($n) | not))]')
        links='{}'
        for n in $(printf '%s' "$targets" | jq -r '.[] | select(.dep == 1) | .n'); do
            b=$(open_link_blockers "$n")
            links=$(printf '%s' "$links" | jq -c --arg n "$n" --argjson b "${b:-null}" '.[$n] = $b')
        done
        # {"<blocker>": "#91 (High), #93", ...}, in ticket order.
        unblocks_map=$(printf '%s' "$targets" | jq -c --argjson open "$open_nums" --argjson links "$links" '
            [.[] | (if .dep > 0 then $links["\(.n)"] else [] end) as $l
             | select($l != null)
             | {n, p, by: ($l + [.line[] | select(. as $b | $open | index($b))] | unique)}
             | select(.by | length == 1)]
            | group_by(.by[0])
            | map({key: "\(.[0].by[0])",
                   value: map("#\(.n)" + (if .p then " (\(.p[:1] | ascii_upcase)\(.p[1:]))" else "" end))
                          | join(", ")})
            | from_entries')
        unblocks=$(printf '%s' "$ready_rows" | jq -r --argjson u "$unblocks_map" '
            map($u["\(.n)"] as $t | select($t) | "#\(.n) unblocks \($t)") | join("; ")')

        # Hand work: ready-for-human tickets not in motion or parked, with every
        # blocker closed and not already fixed, ranked by priority line (high,
        # medium, none, low), then lowest number.
        hand_rows=$(printf '%s' "$rows" | jq -c --argjson open "$open_nums" --argjson fx "$fixed_nums" '
            [.[] | select(.role == "human" and .dep == 0
                            and (.l | index("in-motion") or index("parked") | not)
                            and ([.line[] | select(. as $b | $open | index($b))] | length == 0)
                            and (.n as $n | $fx | index($n) | not))]
            | sort_by([({high: 0, medium: 1, low: 3}[.p // ""] // 2), .n])
            | map(.p |= if . then "\(.[:1] | ascii_upcase)\(.[1:])" else . end)')
        hand=$(printf '%s' "$hand_rows" | jq -r '
            map("#\(.n) \(.t)" + (if .p then " (\(.p))" else "" end)) | join("; ")')
        # The top two, one per line: the second is the runner-up when case 6 wins.
        hand_steps=$(printf '%s' "$hand_rows" | jq -r '
            .[:2][] | "6 by hand" + (if .p then " (\(.p))" else "" end) + ": #\(.n) \(.t)"')

        # Ready-for-human tickets a session left in motion: capturing labels the
        # one it worked on, which git cannot see. Not already fixed.
        moving_rows=$(printf '%s' "$rows" | jq -c --argjson fx "$fixed_nums" '
            [.[] | select(.role == "human" and (.l | index("in-motion"))
                            and (.n as $n | $fx | index($n) | not))]')
        moving=$(printf '%s' "$moving_rows" | jq -r 'map("#\(.n) \(.t)") | join("; ")')
        # A parent's work in flight is its next child, so each carries that step.
        in_motion= children=
        for n in $(printf '%s' "$moving_rows" | jq -r '.[].n'); do
            child=$(next_child "$n")
            children="$children $(printf '%s' "$child" | sed -n 's/^; next child #\([0-9]*\).*/\1/p')"
            in_motion="$in_motion; $(printf '%s' "$moving_rows" |
                jq -r --argjson n "$n" '.[] | select(.n == $n) | "#\(.n) \(.t)"')$child"
        done
        [ -n "$in_motion" ] && inflight="$inflight, in motion ${in_motion#; }"
        # Case 2's ticket: the first ready one case 1 has not already named as
        # a next child, so next: and runner-up: never name the same ticket.
        children_nums=$(jq -nc --arg c "$children" '$c | split(" ") | map(select(. != "") | tonumber)')
        pick=$(printf '%s' "$ready_rows" | jq -r --argjson cn "$children_nums" '
            [.[] | select(.n as $n | $cn | index($n) | not)] | first // empty | "#\(.n) \(.t)"')

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
        echo "unblocks: ${unblocks:-none}"
        echo "by hand, blockers closed: ${hand:-none}"
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
        [ -n "$pick" ] && add_case "2 /implement ${pick%% *} $you_type: $pick"
        if [ "$n_unl" -gt 0 ] || [ "$n_triage" -gt 0 ] || [ -n "$replied" ]; then
            add_case "3 /triage $you_type: $n_unl unlabelled, $n_triage $t_triage, replied $t_info: ${replied:-none}"
        fi
        # The open list can lag a push that closed the ticket by a few seconds.
        [ -n "$stale" ] && add_case "4 tracker and repo disagree: close $stale (as of the last read: confirm with gh issue view first)"
        [ "$n_map" -gt 0 ] && add_case "5 /wayfinder $you_type: $maps"
        [ -n "$hand_steps" ] && add_case "$hand_steps"
        if [ -n "$cases" ]; then add_case "7 nothing else in motion: $ideas"
        else add_case "7 nothing in motion"; add_case "$ideas"; fi
    fi
    printf '%s' "$cases" | sed -n '1s/^/next: /p; 2s/^/runner-up: /p'
    # What the ticket each of those steps names unblocks: case 2's ticket,
    # case 1's first next child or else its first in-motion ticket, or case
    # 6's hand ticket.
    if [ $reached = 1 ]; then
        for i in 1 2; do
            c=$(printf '%s' "$cases" | sed -n "${i}p")
            case $c in
                '2 /implement #'*) t=${c#2 /implement #} ;;
                '1 '*'; next child #'*) t=${c#*; next child #} ;;
                '1 '*'in motion #'*) t=${c#*in motion #} ;;
                '6 by hand'*': #'*) t=${c#*: #} ;;
                *) t= ;;
            esac
            t=${t%%[!0-9]*}
            [ -n "$t" ] || continue
            u=$(printf '%s' "$unblocks_map" | jq -r --arg t "$t" '.[$t] // empty')
            [ -n "$u" ] || continue
            [ $i = 1 ] && echo "next unblocks: $u" || echo "runner-up unblocks: $u"
        done
    fi

    # --- the /supervise offer (#111) ---------------------------------------
    # When the next step is /implement #N, whether /supervise would run it:
    # step.sh takes it only with nothing else in flight (its patterns are
    # copied here), and launch.sh only in the main checkout, not a linked
    # worktree (#79), on the default branch, with a clean tree and no other
    # live background session in the folder.
    first=$(printf '%s' "$cases" | sed -n 1p)
    impl=$(printf '%s\n' "$first" | sed -n \
        -e 's/^2 \/implement #\([0-9][0-9]*\) .*/\1/p' \
        -e 's/^1 work in flight: .*; next child #\([0-9][0-9]*\) ([^,)]*, \/implement #\1, .*/\1/p')
    [ -n "$impl" ] || return 0
    step_n=$(printf '%s\n' "$first" | sed -n \
        -e 's/^2 \/implement #\([0-9][0-9]*\) .*/\1/p' \
        -e 's/^1 work in flight: in motion #[0-9][0-9]* [^;]*; next child #\([0-9][0-9]*\) ([^,)]*, \/implement #\1, .*/\1/p')
    refusal=
    if ! linked=$(sh "$main_checkout" . </dev/null 2>&1); then refusal=$linked
    elif [ "$dirty" -gt 0 ]; then refusal="$dirty uncommitted paths; commit or clear them first"
    elif [ "$branch" != "$default" ]; then refusal="on $branch, not the default branch $default"
    elif [ "$unpushed" -gt 0 ]; then refusal="$unpushed unpushed commits; push them first"
    elif [ -n "${own:-}" ]; then refusal="open PR $own; settle it first"
    elif [ -z "$step_n" ]; then refusal="other work in flight: ${inflight#, }"
    else
        here=$(pwd -P)
        # A row is live unless stopped, or done with no pid, as in launch.sh.
        if ! list=$(claude agents --json --all </dev/null 2>/dev/null); then
            refusal="claude agents --json --all failed, so other sessions in $here are unknown"
        elif ! others=$(printf '%s' "$list" | jq -er --arg d "$here" '
            [.[] | select(.kind == "background" and .cwd == $d and .state != "stopped"
                          and (.state != "done" or .pid != null))
             | "\(.id) (\(.state // "unknown"))"] | join(", ")' 2>/dev/null); then
            refusal="claude agents --json --all printed no list jq could read, so other sessions in $here are unknown"
        elif [ -n "$others" ]; then
            refusal="another live background session in $here: $others"
        fi
    fi
    if [ -n "$refusal" ]; then echo "supervise: not offered: $refusal"
    else echo "supervise: /mp-ported-skills:supervise $shown --model claude-opus-5-5 --effort medium $you_type"; fi
}

# gather runs in the background so the watchdog can stop a hung `gh`. The EXIT
# trap is set after both forks: a subshell that inherits one defers the kill
# until its current command returns. Its stderr goes to a file too, replayed
# after: a hung child the kill leaves behind would otherwise hold the caller's
# stderr open, and a caller capturing it would wait out the hang.
tmp=$(mktemp -d) || exit 0
gather >"$tmp/out" 2>"$tmp/err" &
gpid=$!
(sleep "$budget"; kill "$gpid") >/dev/null 2>&1 &
wpid=$!
trap 'command rm -rf "$tmp"' EXIT
wait "$gpid"
rc=$?
{ kill "$wpid"; wait "$wpid"; } >/dev/null 2>&1

cat "$tmp/err" >&2
cat "$tmp/out"
if [ $rc != 0 ]; then
    if [ $rc -gt 128 ]; then echo "timed out after ${budget}s; the lines above are all that was read"
    else echo "state.sh failed (exit $rc)"; fi
fi
exit 0
