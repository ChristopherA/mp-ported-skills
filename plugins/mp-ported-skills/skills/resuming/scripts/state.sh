#!/bin/sh
# state.sh -- read-only snapshot of where a repo's work stands, and the next step.
#
# Reads git (no fetch: remote refs are as of the last fetch) and, when
# docs/agents/issue-tracker.md names GitHub, the tracker through `gh`. Prints
# state lines, then `next: <case> ...` for the first of the seven weighing
# cases that applies and `runner-up: ...` for the second (case 7's suggestions
# when no other applies). A ticket labelled `parked` is never a step, nor is
# one whose newest comment is a worker's park question (#158). Prints
# what each ready ticket unblocks (`unblocks:`), and what the next step's and
# runner-up's tickets unblock, without changing the step. When the working
# tree's docs/agents/distribution-repo.md names a Distribution repo (#142),
# reads that repo's git too, and its work in flight is case 1. When the next
# step is /implement #N, prints the queue a /supervise --loop would run
# (`queue:`), a sub-issue reorder that would lengthen it (`reorder:`), and the
# loop command, offered only for two or more tickets (`supervise:`). Writes
# nothing.
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

# supervise's main-checkout.sh and distribution.sh, found before the cd below.
supervise_scripts="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/../../supervise/scripts"
main_checkout="$supervise_scripts/main-checkout.sh"
distribution="$supervise_scripts/distribution.sh"
# The rules the supervise: offer shares with /supervise (#115): which next:
# step it takes, and which background sessions are live.
. "$supervise_scripts/accept.sh"
. "$supervise_scripts/live.sh"
# The park comment's heading, shared with launch.sh's prompt text (#158).
. "$supervise_scripts/park.sh"
# Whether unpushed commits are a supervised run of a ticket (#214).
. "$supervise_scripts/run-start.sh"

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
# Reads $open_nums, $repo_slug, $body_blockers and the label strings. The
# weigh step reads the child's number back from "; next child #N", so keep
# that wording. Writes the open children to $tmp/kids-<n>.json, which the
# /supervise queue reads.
# Reads every page: gh prints one array per page, merged here into one, and
# the first page can hold only closed children.
next_child() {
    subs=$(gh api "repos/{owner}/{repo}/issues/$1/sub_issues?per_page=100" --paginate 2>/dev/null) &&
        subs=$(printf '%s' "$subs" | jq -cs 'add' 2>/dev/null) &&
        printf '%s' "$subs" | jq -e 'type == "array"' >/dev/null 2>&1 ||
        { printf '; sub-issues not read'; return; }
    kids=$(printf '%s' "$subs" | jq -c --arg repo "$repo_slug" --argjson open "$open_nums" "$body_blockers"'
        [.[] | select(.state == "open")
         | {n: .number, id: .id, t: .title, l: [.labels[].name], c: .comments,
            dep: (.issue_dependencies_summary.blocked_by // 0),
            line: [body_blockers[] | select(. as $b | $open | index($b))]}]')
    kids=$(mark_parked "$kids")
    [ "$(printf '%s' "$kids" | jq length)" = 0 ] && return
    # Kept for the /supervise queue, which replays this pick: this function
    # runs in a command substitution, so a variable would not outlive it.
    printf '%s' "$kids" >"$tmp/kids-$1.json"
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
            if printf '%s' "$kids" | jq -e --argjson k "$k" '.[] | select(.n == $k) | .pk' >/dev/null; then
                blocked="$blocked, #$k parked: awaiting reply"
            else
                blocked="$blocked, #$k parked"
            fi
            continue
        fi
        by=$(printf '%s' "$kids" | jq -r --argjson k "$k" '.[] | select(.n == $k) | .line[]')
        if [ "$(printf '%s' "$kids" | jq --argjson k "$k" '.[] | select(.n == $k) | .dep')" -gt 0 ]; then
            by="$by
$(open_link_blockers "$k" | jq -r '.[]')"
        fi
        # This repo's blockers by number, then any in other repos.
        by=$({ printf '%s\n' "$by" | grep -E '^[0-9]+$' | sort -un | sed 's/^/#/'
               printf '%s\n' "$by" | grep -v -E '^([0-9]+)?$' | sort -u; } | tr '\n' ' ')
        blocked="$blocked, #$k by ${by:-an unread blocker}"
    done
    blocked=$(printf '%s' "$blocked" | sed 's/ ,/,/g; s/ $//')
    printf '; every open child blocked: %s' "${blocked#, }"
}

# awaiting_reply <n>: whether ticket #n's newest comment is a worker's park
# question, a comment opening with park.sh's heading (#158): no step takes
# the ticket until a later comment, from anyone, answers it. A run record
# /supervise posts (park.sh's run_record) is not an answer, and is passed
# over, since finish.sh posts one on the ticket after every park. Reads every
# page, merged as in next_child; a ticket whose comments cannot be read is
# not parked. Each read spends the time budget, so the answer is kept in
# $tmp: next_child runs in a command substitution, and asks again.
awaiting_reply() {
    f="$tmp/park-$1"
    if [ ! -f "$f" ]; then
        gh api "repos/{owner}/{repo}/issues/$1/comments?per_page=100" --paginate 2>/dev/null |
            jq -rs "$park_def$park_record_def"'add | map(.body // "" | select(run_record | not)) | last // "" | parked' >"$f" 2>/dev/null || echo false >"$f"
    fi
    [ "$(cat "$f")" = true ]
}

# mark_parked <rows json>: the rows with each one whose newest comment is a
# park question (awaiting_reply) labelled `parked` for every test below that
# skips one, and flagged `pk` for the reports that name it. Only a row that
# could otherwise be a step is read: open, ready-for-agent, with comments,
# no open blocker and no `parked` label. Reads $open_nums and $t_agent.
mark_parked() {
    pk=
    for n in $(printf '%s' "$1" | jq -r --argjson open "$open_nums" --arg ta "$t_agent" '
        .[] | select((.l | index($ta)) and (.c // 0) > 0 and .dep == 0 and (.l | index("parked") | not)
                     and ([.line[] | select(. as $b | $open | index($b))] | length == 0)) | .n'); do
        awaiting_reply "$n" && pk="$pk $n"
    done
    printf '%s' "$1" | jq -c --arg pk "$pk" '($pk | split(" ") | map(select(. != "") | tonumber)) as $pk
        | map(if (.n as $n | $pk | index($n)) then .l += ["parked"] | .pk = true else . end)'
}

# open_link_blockers <n>: a JSON array of the open tickets GitHub links as
# blocking #n, a number for one in this repo and "owner/repo#N" for one in
# another, so a blocker elsewhere is never read as the local ticket with its
# number; nothing when the list cannot be read. Reads $repo_url and every
# page, merged here as in next_child.
open_link_blockers() {
    gh api "repos/{owner}/{repo}/issues/$1/dependencies/blocked_by?per_page=100" --paginate 2>/dev/null |
        jq -cs --arg repo "$repo_url" '[add[] | select(.state == "open")
            | if (.repository_url // $repo) == $repo then .number
              else "\(.repository_url | sub("^.*/repos/"; ""))#\(.number)" end]' 2>/dev/null
}

# git_state <dir>: <dir>'s branch, default branch, sync with its upstream,
# uncommitted paths and unpushed commits, in r_branch, r_default, r_sync,
# r_dirty and r_unpushed, and the two lines that report them.
git_state() {
    r_branch=$(git -C "$1" symbolic-ref --short -q HEAD || echo "(detached)")
    r_default=$(git -C "$1" symbolic-ref --short -q refs/remotes/origin/HEAD)
    r_default=${r_default#origin/}
    if [ -z "$r_default" ]; then
        for b in main master; do
            git -C "$1" show-ref -q --verify "refs/heads/$b" && { r_default=$b; break; }
        done
    fi
    r_default=${r_default:-main}

    r_dirty=$(git -C "$1" status --porcelain | wc -l | tr -d ' ')
    if git -C "$1" remote | grep -q .; then
        r_unpushed=$(git -C "$1" rev-list --count HEAD --not --remotes 2>/dev/null || echo 0)
    else
        r_unpushed=0
    fi
    if up=$(git -C "$1" rev-parse --abbrev-ref -q '@{u}' 2>/dev/null); then
        counts=$(git -C "$1" rev-list --left-right --count "$up...HEAD")
        behind=${counts%%[!0-9]*} ahead=${counts##*[!0-9]}
        if [ "$behind" = 0 ] && [ "$ahead" = 0 ]; then r_sync="in sync with $up"
        else r_sync="ahead $ahead, behind $behind of $up"; fi
    else
        r_sync="no upstream"
    fi
}

# git_inflight [suffix]: git_state's work in flight, each item ending in
# suffix, as ", item, item".
git_inflight() {
    [ "$r_dirty" -gt 0 ] && printf ', %s uncommitted paths%s' "$r_dirty" "${1:-}"
    [ "$r_unpushed" -gt 0 ] && printf ', %s unpushed commits%s' "$r_unpushed" "${1:-}"
    [ "$r_branch" != "$r_default" ] && printf ', on %s not %s%s' "$r_branch" "$r_default" "${1:-}"
    return 0
}

# implement_of <case line>: the ticket a case 2 line or a case 1 line's
# ready-for-agent next child names for /implement, or nothing.
implement_of() {
    printf '%s\n' "$1" | sed -n \
        -e 's/^2 \/implement #\([0-9][0-9]*\) .*/\1/p' \
        -e 's/^1 work in flight: .*; next child #\([0-9][0-9]*\) ([^,)]*, \/implement #\1, .*/\1/p'
}

gather() {
    command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1 || {
        echo "git: not a repository"
        echo "next: 7 nothing in motion"
        echo "runner-up: $ideas"
        exit 0
    }

    # --- git -------------------------------------------------------------
    git_state .
    branch=$r_branch default=$r_default dirty=$r_dirty unpushed=$r_unpushed
    defref=$default
    git show-ref -q --verify "refs/remotes/origin/$default" && defref=origin/$default
    echo "branch: $branch (default $default), $r_sync, as of last fetch"
    echo "uncommitted paths: $dirty; unpushed commits: $unpushed"
    inflight=$(git_inflight)
    # The same less the unpushed commits, for the /supervise offer (#214).
    r_unpushed=0
    inflight_rest=$(git_inflight)

    # The Distribution repo, from the working tree's copy of
    # docs/agents/distribution-repo.md, as the other docs/agents files are
    # read: this readout only reads, so it needs none of the protection
    # launch.sh gets from origin's copy. One that cannot be read is never
    # clean: its reason goes in dist_unread, which keeps the /supervise
    # offer back.
    dist= dist_inflight= dist_unread=
    if ! dist=$(sh "$distribution" --dir . --working-tree </dev/null 2>"$tmp/dist-err"); then
        dist_unread="not read: $(cat "$tmp/dist-err")"
    elif [ -z "$dist" ]; then
        :
    elif [ ! -d "$dist" ]; then
        dist_unread="$dist not read: no such folder"
    # A plain folder inside a repo is not one: rev-parse would answer for
    # the repo around it, as it would for the Project itself.
    elif [ "$(git -C "$dist" rev-parse --show-toplevel 2>/dev/null)" != "$dist" ]; then
        dist_unread="$dist not read: not a git checkout"
    elif [ "$dist" = "$(git rev-parse --show-toplevel)" ]; then
        dist_unread="$dist not read: the Project's own repo"
    else
        git_state "$dist"
        echo "distribution repo: $dist"
        echo "distribution repo branch: $r_branch (default $r_default), $r_sync, as of last fetch"
        echo "distribution repo uncommitted paths: $r_dirty; unpushed commits: $r_unpushed"
        dist_inflight=$(git_inflight " in distribution repo $dist")
        inflight="$inflight$dist_inflight" inflight_rest="$inflight_rest$dist_inflight"
    fi
    [ -z "$dist_unread" ] || echo "distribution repo: $dist_unread"

    # Issue numbers the default branch's commit messages close.
    close_re='(close[sd]?|fix(e[sd])?|resolve[sd]?):? +#'
    fixed=$(git log "$defref" --format=%B 2>/dev/null |
        grep -oiE "$close_re[0-9]+" |
        grep -oE '[0-9]+' | sort -un | tr '\n' ' ')

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
        # Every page, merged as in next_child.
        elif ! issues=$(gh api 'repos/{owner}/{repo}/issues?state=open&per_page=100' --paginate 2>/dev/null) ||
            ! issues=$(printf '%s' "$issues" | jq -cs 'add' 2>/dev/null) ||
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
        if [ -n "$own" ]; then
            echo "open PRs from this repo: $own"
            inflight="$inflight, open PR $own" inflight_rest="$inflight_rest, open PR $own"
        fi

        # A body's priority line, its first non-blank line (**Priority: High.**),
        # as high, medium or low; null when there is none.
        body_blockers='def priority: [(.body // "") | splits("\r?\n") | select(test("\\S"))][0] // ""
            | (capture("^\\s*\\*\\*Priority: *(?<p>high|medium|low)"; "i") | .p | ascii_downcase) // null;'
        # Issue numbers a body names as blockers: on `Blocked by:` lines, and in
        # bullets under a `Blocked by` heading (any level or case) up to the
        # next heading, the form tickets split from a spec use. Lines in a code
        # fence, closed only by its own marker, are examples, not blockers.
        # A blocker in another repo (other/lib#26) is "other/lib#26", never the
        # local #26; one naming this repo ($repo, any case) is local.
        body_blockers="$body_blockers"'
            def refs: [scan("(?<![\\w./-])(?:([\\w.-]+/[\\w.-]+))?#([0-9]+)(?!\\w)")
                | if .[0] == null or (.[0] | ascii_downcase) == $repo then .[1] | tonumber
                  else "\(.[0])#\(.[1])" end];
            def body_blockers: reduce ((.body // "") | splits("\r?\n")) as $line
            ({fence: null, under: false, nums: []};
             ($line | capture("^\\s*(?<m>```|~~~)").m // null) as $m
             | if .fence then (if $m == .fence then .fence = null else . end)
             elif $m then .fence = $m
             elif ($line | test("^\\s*#+\\s")) then
                 .under = ($line | test("^\\s*#+\\s*blocked by\\s*(:.*)?$"; "i"))
                 | if .under then .nums += ($line | refs) else . end
             elif ($line | test("^\\s*blocked by:"; "i")) or (.under and ($line | test("^\\s*[-*+]\\s")))
             then .nums += ($line | refs)
             else . end) | .nums;'

        # This repo's API URL, which a linked blocker's repository_url matches
        # when the blocker is in this repo, and its owner/repo, lower case.
        repo_url=$(printf '%s' "$issues" | jq -r 'first(.[].repository_url // empty) // ""')
        repo_slug=$(printf '%s' "$repo_url" | sed 's|^.*/repos/||' | tr '[:upper:]' '[:lower:]')

        # Open issues only (the endpoint also lists PRs), with what the cases need.
        rows=$(printf '%s' "$issues" | jq -c --arg repo "$repo_slug" --arg tr "$t_triage" --arg ti "$t_info" \
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
        # Open blockers a body can name: this repo's open tickets, then each
        # other repo's ticket a body names that is open there, read once. One
        # whose state cannot be read counts as open, as an unknown blocker.
        for r in $(printf '%s' "$rows" | jq -r '[.[].line[] | strings] | unique | .[]'); do
            st=$(gh api "repos/${r%%#*}/issues/${r##*#}" 2>/dev/null | jq -r '.state // empty' 2>/dev/null)
            [ "$st" = closed ] ||
                open_nums=$(printf '%s' "$open_nums" | jq -c --arg r "$r" '. + [$r]')
        done
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
        # A ticket awaiting a reply to its park question is parked (#158).
        rows=$(mark_parked "$rows")
        awaiting=$(printf '%s' "$rows" | jq -r 'map(select(.pk) | "#\(.n) \(.t)") | join("; ")')
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
        if [ -n "$in_motion" ]; then
            inflight="$inflight, in motion ${in_motion#; }" inflight_rest="$inflight_rest, in motion ${in_motion#; }"
        fi
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
                last=$(gh api "repos/{owner}/{repo}/issues/$n/comments?per_page=100" --paginate 2>/dev/null |
                    jq -rs 'add | last.user.login // empty')
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
        [ -n "$awaiting" ] && echo "parked, awaiting reply: $awaiting"
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
        if [ -n "$dist_unread" ]; then
            [ -n "$inflight" ] || add_case "undecided: git shows nothing in flight, but the distribution repo was not read; the tracker was not read"
        else
            [ -n "$inflight" ] || add_case "undecided: git shows nothing in flight; the tracker was not read"
        fi
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

    # --- the /supervise offer (#111, #129) ---------------------------------
    # When the next step is /implement #N, whether /supervise --loop would run
    # it and the tickets after it: step.sh takes it only with nothing else in
    # flight (accept.sh's patterns, shared with it), and launch.sh only in
    # the main checkout, not a linked worktree (#79), on the default branch,
    # with a clean tree and no other live background session in the folder
    # (live.sh's rule, shared with it), and the Distribution repo, when there
    # is one, read and clean. A loop is worth running only for two or more
    # tickets, counting a reorder's.
    #
    # Unpushed commits on the default branch may be a supervised run of the
    # next ticket that a supervisor ended before pushing (#214). So the offer
    # reads the step as it would be without them (offer), and when a run
    # record on that ticket accounts for them exactly (run-start.sh), offers
    # the loop and prints `continue: #N from <start>`, which step.sh takes.
    # When they are the only refusal and no run accounts for them, a
    # `push-first:` line names the push and then the loop. Otherwise the
    # lines are as they were: no queue: line, and the unpushed refusal.
    first=$(printf '%s' "$cases" | sed -n 1p)
    offer=$first
    if [ "$unpushed" -gt 0 ]; then
        if [ -n "$inflight_rest" ]; then offer="1 work in flight: ${inflight_rest#, }"
        else offer=$(printf '%s' "$cases" | sed -n 2p); fi
    fi
    impl=$(implement_of "$first")
    [ -n "$impl" ] || [ -n "$(implement_of "$offer")" ] || return 0
    step_n=$(accept_step "$offer")
    # The queue (#129): the tickets a /supervise --loop would run in turn.
    # The loop runs no list: after each ticket step.sh re-reads next:, so the
    # queue replays that pick with each queued ticket counted as closed. Under
    # an in-motion parent it is next_child's pick in the parent's order, and a
    # ready-for-human or unlabelled pick ends the queue as step.sh stops on it;
    # otherwise case 2's, the lowest-numbered ready ticket. A ticket whose
    # links cannot be read counts as blocked. Under a parent, the first
    # ready-for-agent child behind the one ending the queue, unblocked once
    # the queue is closed, is offered as a reorder ahead of it (reorder:).
    qlen=0 qout=
    if [ -n "$step_n" ]; then
        parent=$(printf '%s\n' "$offer" | sed -n 's/^1 work in flight: in motion #\([0-9][0-9]*\) .*/\1/p')
        if [ -n "$parent" ]; then cands=$(cat "$tmp/kids-$parent.json")
        else cands=$(printf '%s' "$rows" | jq -c --argjson open "$open_nums" --argjson fx "$fixed_nums" '
            [.[] | select(.role == "agent" and (.l | index("parked") | not) and (.n as $n | $fx | index($n) | not))
             | .line |= [.[] | select(. as $b | $open | index($b))]]'); fi
        # Links unblocks: already read are reused: each read spends the budget.
        qlinks=$links
        for n in $(printf '%s' "$cands" | jq -r --argjson have "$links" '.[] | select(.dep > 0 and ($have | has("\(.n)") | not)) | .n'); do
            b=$(open_link_blockers "$n")
            qlinks=$(printf '%s' "$qlinks" | jq -c --arg n "$n" --argjson b "${b:-null}" '.[$n] = $b')
        done
        qr=$(printf '%s' "$cands" | jq -c --argjson links "$qlinks" --arg ta "$t_agent" --arg p "$parent" '
            def queued($q): . as $b | $q | index($b);
            def free($q): .by != null and all(.by[]; queued($q));
            def open($q): (.n | queued($q) | not) and (.l | index("parked") | not);
            def replay($c): def go: .q as $q
                | ([$c[] | select(open($q) and free($q))] | first) as $k
                | if $k == null then .
                  elif ($k.l | index($ta)) then .q += [$k.n] | go
                  else .end = $k.n end;
                {q: [], end: null} | go;
            map(.line as $line | .by = (if .dep > 0 then $links["\(.n)"] | if . then . + $line else null end
                                        else $line end))
            | . as $c | replay($c) as $r
            | ($c | map(.n)) as $ns
            | (if $p == "" or $r.end == null then null
               else ($ns | index($r.end)) as $xi
               | ([$c[$xi + 1:][] | select(open($r.q) and (.l | index($ta)) and free($r.q))] | first) as $y
               | if $y == null then null
                 else ($ns | index($y.n)) as $yi
                 | {y: $y.n, yid: $y.id, yi: ($yi + 1), x: $r.end, xid: $c[$xi].id, xi: ($xi + 1),
                    after: replay($c[:$xi] + [$y] + [$c[$xi:][] | select(.n != $y.n)]).q}
                 end
               end) as $m
            | {q: $r.q, m: $m, len: (($m.after // $r.q) | length)}')
        # Empty when the children or the replay could not be read: refused below.
        qlen=$(printf '%s' "$qr" | jq '.len' 2>/dev/null)
        qout=$(echo "queue: $(printf '%s' "$qr" | jq -r '.q | map("#\(.)") | join(" ")')"
        printf '%s' "$qr" | jq -r --arg p "$parent" \
            --arg path "'repos/{owner}/{repo}/issues/$parent/sub_issues/priority'" '.m // empty
            | "reorder: #\(.y) (open child \(.yi) of #\($p)) ahead of #\(.x) (open child \(.xi)): "
              + "gh api --method PATCH \($path)"
              + " -F sub_issue_id=\(.yid) -F before_id=\(.xid); queue after: \(.after | map("#\(.)") | join(" "))"')
    fi
    # The checks in launch.sh's order, the unpushed commits left to the end:
    # those before them (early), the rest of what step.sh and launch.sh
    # refuse (hard), then what only the offer weighs.
    refusal= early= hard=
    if ! linked=$(sh "$main_checkout" . </dev/null 2>&1); then refusal=$linked early=1
    elif [ "$dirty" -gt 0 ]; then refusal="$dirty uncommitted paths; commit or clear them first" early=1
    elif [ "$branch" != "$default" ]; then refusal="on $branch, not the default branch $default" early=1
    elif [ -n "${own:-}" ]; then refusal="open PR $own; settle it first"
    elif [ -n "$dist_inflight" ]; then refusal="work in flight in distribution repo $dist: ${dist_inflight#, }"
    elif [ -n "$dist_unread" ]; then refusal="distribution repo $dist_unread"
    elif [ -z "$step_n" ]; then refusal="other work in flight: ${inflight_rest#, }"
    fi
    hard=$refusal
    if [ -n "$refusal" ]; then :
    elif ! [ "$qlen" -ge 0 ] 2>/dev/null; then refusal="the queue could not be read"
    elif [ "$qlen" -lt 2 ]; then refusal="a queue of one (#$step_n); /supervise is worth running only for two or more tickets"
    else
        here=$(pwd -P)
        # Which sessions are live is live.sh's, shared with launch.sh, which
        # also refuses one in the Distribution repo.
        if ! list=$(claude agents --json --all </dev/null 2>/dev/null); then
            refusal="claude agents --json --all failed, so other sessions in $here are unknown"
        elif ! others=$(live_others "$list" "$here"); then
            refusal="claude agents --json --all printed no list jq could read, so other sessions in $here are unknown"
        elif [ -n "$others" ]; then
            refusal="another live background session in $here: $others"
        elif [ -n "$dist" ] && others=$(live_others "$list" "$dist") && [ -n "$others" ]; then
            refusal="another live background session in distribution repo $dist: $others"
        fi
    fi
    loop="/mp-ported-skills:supervise $shown --loop --model claude-opus-5-5 --effort medium"
    # A read of the run records that fails is told apart from one that finds
    # no run (#222): a read that worked might have continued the ticket, so
    # it gives no push-first advice. Its lines print as a continued run's
    # would, and a refusal that holds whatever the read finds stands.
    start= push_first= records_unread=
    if [ "$unpushed" -gt 0 ] && [ -z "$early" ]; then
        if [ -n "$hard" ]; then :
        elif ! comments=$(gh api "repos/{owner}/{repo}/issues/$step_n/comments?per_page=100" --paginate 2>/dev/null) ||
            ! comments=$(printf '%s' "$comments" | jq -cs 'add // []' 2>/dev/null); then
            records_unread=1
        else
            start=$(run_start . "$step_n" "$comments") || start=
        fi
        if [ -n "$records_unread" ]; then
            [ -n "$refusal" ] || refusal="the run records on #$step_n could not be read"
        elif [ -z "$start" ]; then
            [ -n "$refusal" ] || push_first=1
            refusal="$unpushed unpushed commits; push them first"
        fi
    fi
    if [ "$unpushed" -gt 0 ] && [ -z "$start" ] && [ -z "$push_first" ] && [ -z "$records_unread" ]; then
        [ -n "$impl" ] || return 0
    else
        [ -z "${qout:-}" ] || printf '%s\n' "$qout"
    fi
    if [ -n "$refusal" ]; then echo "supervise: not offered: $refusal"
    else echo "supervise: $loop $you_type"; fi
    [ -z "$start" ] || echo "continue: #$step_n from $start"
    [ -z "$push_first" ] || echo "push-first: git push origin $default; then $loop $you_type"
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
