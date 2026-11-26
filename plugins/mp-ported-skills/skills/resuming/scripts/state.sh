#!/bin/sh
# state.sh -- read-only snapshot of where a repo's work stands, and the next step.
#
# Reads git (no fetch: remote refs are as of the last fetch) and, when
# docs/agents/issue-tracker.md names GitHub, the tracker through `gh`; when
# it is titled `# Issue tracker: Local Markdown`, the ticket files under
# .scratch/ instead, with no `gh` call (#233), building the same rows, so
# the cases run unchanged on string ids (<feature-slug>#<NN>). Prints
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
# loop command, offered only for two or more tickets or a run to continue
# (`supervise:`). When the next step is an in-motion parent's by-hand or
# not-ready child and a ready child behind it could go ahead, prints the same
# lines for that reorder (#207). When the plugin running this script is an
# installed version older than the one the default branch carries, prints
# `plugin:` with the update command and /reload-plugins (#238). Writes nothing.
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
# claude agents within a time limit (#240).
. "$supervise_scripts/agents.sh"
# The Distribution repo's path checks and the repo state read, shared with
# launch.sh and push.sh (#209).
. "$supervise_scripts/own-repo.sh"
. "$supervise_scripts/distribution-repo.sh"
# The park comment's heading, shared with launch.sh's prompt text (#158).
. "$supervise_scripts/park.sh"
# Whether unpushed commits are a supervised run of a ticket (#214).
. "$supervise_scripts/run-start.sh"
# Whether the installed plugin is older than the checkout's (#238).
. "$supervise_scripts/plugin-version.sh"
# Which tracker docs/agents/issue-tracker.md names (#233).
. "$supervise_scripts/tracker.sh"
plugin_root=$(CDPATH= cd -- "$supervise_scripts/../../.." && pwd)

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

# The frontier rule (#208), the one test of whether a ticket is free to start,
# shared by next_child, mark_parked, case 2's ready list and the /supervise
# queue: not parked, and every blocker cleared. Its input is a row whose .line
# holds its open body blockers, .l its labels and .dep its open blocked-by
# count, with .links its open link blockers when they were read (null when
# the read failed, which blocks). With no .links, a count above zero blocks.
# $cleared is the blockers to treat as closed: [] for the pick, the queue so
# far for the replay. open_line($open) keeps only a row's open body blockers.
# tests/resuming.test.sh fails when another jq program tests both.
frontier_def='
    def frontier($cleared):
        def cleared: . as $b | $cleared | index($b);
        (.l | index("parked") | not)
        and all(.line[]; cleared)
        and (if has("links") then .links != null and all(.links[]; cleared) else .dep == 0 end);
    def open_line($open): .line |= [.[] | select(. as $b | $open | index($b))];'

# A ticket's id as the readout writes it: #N for a GitHub number, and a Local
# Markdown id (<feature-slug>#<NN>, a string) as it is (#233). fxkey is the
# key a closing commit names it by: the number, or the id with its NN's
# leading zeros dropped (.k).
ref_def='def ref: if type == "number" then "#\(.)" else . end;
    def fxkey: .k // .n;'

# A row's role from its labels, the same on either tracker.
role_def='def role_of($ta; $th; $ti; $tr; $tw):
    if (.l | index($ta)) then "agent"
    elif (.l | index($th)) then "human"
    elif (.l | index($ti)) then "info"
    elif (.l | index($tr)) then "triage"
    elif (.l | index($tw)) then "wontfix"
    elif (.l | index("wayfinder:map")) then "map"
    elif any(.l[]; startswith("wayfinder:")) then "wayfinder"
    else "unlabelled" end;'

# next_child <n>: "; next child ..." for in-motion parent #n, naming the first
# open sub-issue in the parent's order with every blocker closed (the blocker
# test of the frontier rule in docs/agents/issue-tracker.md) and not parked,
# and its command; "; every open child blocked: ..." with the blockers, or
# "parked", when none qualifies; nothing when #n has no open sub-issues.
# On Local Markdown the children are the open rows whose `Part of:` names
# #n, in NN order. Reads $open_nums, $unread_refs, $repo_slug,
# $body_blockers, $tracker, $rows and the label strings. The weigh step reads the child's number back from "; next child
# #N", so keep that wording. Writes the open children to
# $tmp/kids-<n>.json, which the /supervise queue reads.
# Reads every page: gh prints one array per page, merged here into one, and
# the first page can hold only closed children.
next_child() {
    if [ "$tracker" = local ]; then
        # Local Markdown (#233): the open tickets whose `Part of:` names
        # #n, in NN order, from the rows already read.
        kids=$(printf '%s' "$rows" | jq -c --arg p "$1" --argjson open "$open_nums" \
            '[.[] | select(.parent == $p) | .line |= [.[] | select(. as $b | $open | index($b))]] | sort_by(.nn)')
    else
        subs=$(gh api "repos/{owner}/{repo}/issues/$1/sub_issues?per_page=100" --paginate 2>/dev/null) &&
            subs=$(printf '%s' "$subs" | jq -cs 'add' 2>/dev/null) &&
            printf '%s' "$subs" | jq -e 'type == "array"' >/dev/null 2>&1 ||
            { printf '; sub-issues not read'; return; }
        kids=$(printf '%s' "$subs" | jq -c --arg repo "$repo_slug" --argjson open "$open_nums" "$body_blockers"'
            [.[] | select(.state == "open")
             | {n: .number, id: .id, t: .title, l: [.labels[].name], c: .comments,
                dep: (.issue_dependencies_summary.blocked_by // 0),
                line: [body_blockers[] | select(. as $b | $open | index($b))]}]')
    fi
    kids=$(mark_parked "$kids")
    [ "$(printf '%s' "$kids" | jq length)" = 0 ] && return
    # Kept for the /supervise queue, which replays this pick: this function
    # runs in a command substitution, so a variable would not outlive it.
    printf '%s' "$kids" >"$tmp/kids-$1.json"
    # On Local Markdown only, a ready-for-human child is passed over when a
    # ready-for-agent child free to start follows it (#233); it stays on the
    # by hand line.
    pass_human=
    [ "$tracker" = local ] && pass_human=1
    step=$(printf '%s' "$kids" | jq -r --arg ta "$t_agent" --arg th "$t_human" --arg you "$you_type_bare" \
        --arg pass "$pass_human" "$frontier_def$ref_def"'
        [.[] | select(frontier([]))] as $f
        | [range($f | length) as $i | $f[$i]
           | select($pass == "" or (.l | index($th) | not)
                    or ([$f[$i + 1:][] | select(.l | index($ta))] | length == 0))]
        | first // empty
        | "; next child \(.n | ref) ("
          + (if (.l | index($ta)) then "\($ta), /implement \(.n | ref), \($you)"
             elif (.l | index($th)) then "\($th), by hand"
             else "not ready" end)
          + "): \(.t)"')
    if [ -n "$step" ]; then printf '%s' "$step"; return; fi
    blocked=
    for k in $(printf '%s' "$kids" | jq -r '.[].n'); do
        case $k in (*'#'*) kr=$k ;; (*) kr="#$k" ;; esac
        if printf '%s' "$kids" | jq -e --arg k "$k" '.[] | select((.n | tostring) == $k) | .l | index("parked")' >/dev/null; then
            if printf '%s' "$kids" | jq -e --arg k "$k" '.[] | select((.n | tostring) == $k) | .pk' >/dev/null; then
                blocked="$blocked, $kr parked: awaiting reply"
            else
                blocked="$blocked, $kr parked"
            fi
            continue
        fi
        by=$(printf '%s' "$kids" | jq -r --arg k "$k" '.[] | select((.n | tostring) == $k) | .line[]')
        linked=
        if [ "$(printf '%s' "$kids" | jq --arg k "$k" '.[] | select((.n | tostring) == $k) | .dep')" -gt 0 ]; then
            linked=$(open_link_blockers "$k" | jq -r '.[]')
            by="$by
$linked"
        fi
        # This repo's blockers by number, then any in other repos, each one
        # whose state could not be read marked "(unread)": a body's ref whose
        # read failed, unless this child's links just read it as open.
        linked=$(printf '%s' "$linked" | tr '\n' ' ')
        by=$({ printf '%s\n' "$by" | grep -E '^[0-9]+$' | sort -un | sed 's/^/#/'
               printf '%s\n' "$by" | grep -v -E '^([0-9]+)?$' | sort -u | while read -r r; do
                   case " $linked " in
                       (*" $r "*) printf '%s\n' "$r" ;;
                       (*) case " $unread_refs " in (*" $r "*) printf '%s (unread)\n' "$r" ;; (*) printf '%s\n' "$r" ;; esac ;;
                   esac
               done; } | tr '\n' ' ')
        blocked="$blocked, $kr by ${by:-an unread blocker}"
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
    # On Local Markdown the comments were read with the files: the row's .lp
    # holds the same answer, from park.sh's local defs (#233).
    if [ "$tracker" = local ]; then
        printf '%s' "$rows" | jq -e --arg n "$1" 'any(.[]; .n == $n and .lp)' >/dev/null
        return
    fi
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
    for n in $(printf '%s' "$1" | jq -r --argjson open "$open_nums" --arg ta "$t_agent" "$frontier_def"'
        .[] | select((.l | index($ta)) and (.c // 0) > 0 and (open_line($open) | frontier([]))) | .n'); do
        awaiting_reply "$n" && pk="$pk $n"
    done
    printf '%s' "$1" | jq -c --arg pk "$pk" '($pk | split(" ") | map(select(. != "") | tonumber? // .)) as $pk
        | map(if (.n as $n | $pk | index($n)) then .l += ["parked"] | .pk = true else . end)'
}

# open_link_blockers <n>: a JSON array of the open tickets GitHub links as
# blocking #n, a number for one in this repo and "owner/repo#N" for one in
# another, owner and repo in lower case as body_blockers names them, so a
# blocker elsewhere is never read as the local ticket with its number;
# nothing when the list cannot be read. Reads $repo_url and every page,
# merged here as in next_child.
open_link_blockers() {
    gh api "repos/{owner}/{repo}/issues/$1/dependencies/blocked_by?per_page=100" --paginate 2>/dev/null |
        jq -cs --arg repo "$repo_url" '[add[] | select(.state == "open")
            | if (.repository_url // $repo | ascii_downcase) == ($repo | ascii_downcase) then .number
              else "\(.repository_url | sub("^.*/repos/"; "") | ascii_downcase)#\(.number)" end]' 2>/dev/null
}

# read_local: every Local Markdown ticket file (#233),
# .scratch/<feature-slug>/issues/<NN>-<slug>.md, as a JSON array of
# {path, text} in $tmp/local.json. No .scratch/ folder is an empty tracker.
# Prints why and returns 1 when a file cannot be read. Calls no gh.
read_local() {
    : >"$tmp/local.jsonl"
    if [ -d .scratch ]; then
        find .scratch -path '.scratch/*/issues/*' -name '[0-9]*-*.md' -type f >"$tmp/local-files" 2>/dev/null ||
            { echo ".scratch/ could not be listed"; return 1; }
        while IFS= read -r f; do
            jq -nc --arg path "$f" --rawfile text "$f" '{path: $path, text: $text}' >>"$tmp/local.jsonl" 2>/dev/null ||
                { printf '%s could not be read\n' "$f"; return 1; }
        done <"$tmp/local-files"
    fi
    jq -sc . "$tmp/local.jsonl" >"$tmp/local.json"
}

# local_rows_def: jq that turns read_local's files into the rows the GitHub
# path builds, with the open ids and the unread items beside them (#233).
# The conventions are docs/agents/issue-tracker.md's for Local Markdown: the
# file opens `# <title>`, then header lines, then the body, whose priority
# line `priority` reads; comments are the `**YYYY-MM-DD.**` blocks under
# `## Comments`. A row's id (.n) is `<feature-slug>#<NN>` as the file names
# it, and .k the same with NN's leading zeros dropped, the key a closing
# commit and a `Blocked by:` or `Part of:` number resolve by, within the
# ticket's own folder. Closed: a `Closed:` line, or `Status: resolved` on a
# wayfinder ticket (one with a `Type:` line). Labels: `Labels:` plus the
# `Status:` role's label string, and `wayfinder:<type>` from `Type:`. A
# Status that is neither a triage role nor, on a wayfinder ticket, claimed
# or resolved is unread, as is a `Blocked by:` number with no file, which
# stays an open blocker, and a `Part of:` naming none. Needs $roles (each
# triage role's label string), $ta $th $ti $tr $tw, and the priority,
# role_of and local_parked defs before it.
local_rows_def='
    def header: first(capture("^(?<k>[A-Z][A-Za-z -]*):(?<v>.*)$") | select(.k != "Priority")) // null;
    def comments_hd: test("^##\\s+Comments\\s*$");
    def file: . as $f
        | (first($f.path | capture("^\\.scratch/(?<slug>[^/]+)/issues/(?<nn>[0-9]+)-[^/]*\\.md$")) // null) as $m
        | select($m != null)
        | ($f.text | split("\n") | map(sub("\r$"; ""))) as $ls
        | (first(range($ls | length) | select($ls[.] | test("^# "))) // -1) as $ti
        | (reduce $ls[($ti + 1):][] as $line ({ph: "pre", h: {}, body: [], com: []};
            ($line | header) as $hd
            | if .ph == "com" then .com += [$line]
              elif ($line | comments_hd) then .ph = "com"
              elif .ph == "body" then .body += [$line]
              elif $hd != null then .ph = "head" | .h[$hd.k] = ($hd.v | sub("^\\s+"; "") | sub("\\s+$"; ""))
              elif .ph == "pre" and ($line | test("^\\s*$")) then .
              else .ph = "body" | .body += [$line] end)) as $p
        | (reduce $p.com[] as $line ([];
            if ($line | test("^\\*\\*[0-9]{4}-[0-9]{2}-[0-9]{2}\\.\\*\\*")) then . + [$line]
            elif length > 0 then .[-1] += "\n" + $line else . end)) as $cs
        | {path: $f.path, slug: $m.slug, nnw: $m.nn, nn: ($m.nn | tonumber),
           t: (if $ti >= 0 then $ls[$ti] | sub("^#\\s+"; "") else "" end),
           h: $p.h, body: ($p.body | join("\n")), cs: $cs};
    def nnum: capture("^0*(?<d>[0-9]+)").d;
    [.[] | file] as $fs
    | ($fs | map({key: "\(.slug)#\(.nn)", value: "\(.slug)#\(.nnw)"}) | from_entries) as $ids
    | [$fs[] | . as $x
       | ($x.h.Status // null) as $s
       | ($x.h.Type // null) as $ty
       | "\($x.slug)#\($x.nnw)" as $id
       | ((($x.h["Blocked by"] // "") | [scan("[0-9]+")])
          | map({w: ., key: "\($x.slug)#\(nnum)"})
          | map(.key as $key | . + {id: ($ids[$key] // "\($x.slug)#\(.w)"), missing: ($ids | has($key) | not)})) as $bl
       | (($x.h["Part of"] // "") | (first(capture("^\\s*0*(?<d>[0-9]+)")) // null)
          | if . == null then null else "\($x.slug)#\(.d)" end) as $pk
       | {id: $id,
          closed: (($x.h | has("Closed")) or ($ty != null and $s == "resolved")),
          bad: (if $s == null then "\($x.path) (no Status: line)"
                elif ($roles | has($s)) or ($ty != null and ($s == "claimed" or $s == "resolved")) then null
                else "\($x.path) (Status: \($s))" end),
          missing: [$bl[] | select(.missing) | "\(.id) (named on the Blocked by: line of \($x.path), no such ticket)"]
                   + (if $pk != null and ($ids | has($pk) | not) then ["\($x.path) (Part of: \($x.h["Part of"]) names no ticket in its folder)"] else [] end),
          missing_ids: [$bl[] | select(.missing) | .id],
          row: ({n: $id, k: "\($x.slug)#\($x.nn)", t: $x.t, c: ($x.cs | length),
                 l: ((($x.h.Labels // "") | split(",") | map(sub("^\\s+"; "") | sub("\\s+$"; "")) | map(select(. != "")))
                     + (if $s != null and ($roles | has($s)) then [$roles[$s]] else [] end)
                     + (if $ty != null then ["wayfinder:\($ty | ascii_downcase)"] else [] end)),
                 dep: 0, line: [$bl[].id], p: ({body: $x.body} | priority),
                 parent: (if $pk != null then $ids[$pk] else null end),
                 slug: $x.slug, nn: $x.nn, path: $x.path,
                 lp: ($x.cs | map(select(local_run_record | not)) | last // "" | local_parked)}
                | .role = role_of($ta; $th; $ti; $tr; $tw))}] as $all
    | ($all | map(select(.closed | not))) as $open
    | {rows: ([$open[] | select(.bad == null) | .row] | sort_by([.slug, .nn])
              | to_entries | map(.value + {o: .key})
              | sort_by([({high: 0, medium: 1, low: 3}[.p // ""] // 2), .o])),
       open: ([$open[].id] + [$open[].missing_ids[]] | unique),
       unread: ([$open[].bad | strings] + [$open[].missing[]] | unique)}'

# git_state <dir>: <dir>'s branch, default branch, sync with its upstream,
# uncommitted paths and unpushed commits, in r_branch, r_default, r_sync,
# r_dirty and r_unpushed. All but the sync are distribution_state's, as
# launch.sh reads them.
git_state() {
    distribution_state "$1"
    r_branch=$distribution_branch r_default=$distribution_default
    r_dirty=$distribution_dirty r_unpushed=$distribution_unpushed
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
    # Only a pushed version can be installed, so no origin ref, no line.
    plugin_ref=
    [ "$defref" = "$default" ] || plugin_ref=$defref
    plugin_behind "$plugin_root" . "$plugin_ref"
    inflight=$(git_inflight)
    # The same less the unpushed commits, for the /supervise offer (#214).
    r_unpushed=0
    inflight_rest=$(git_inflight)

    # The Distribution repo, from the working tree's copy of
    # docs/agents/distribution-repo.md, as the other docs/agents files are
    # read: this readout only reads, so it needs none of the protection
    # launch.sh gets from origin's copy. One that cannot be read is never
    # clean: its reason goes in dist_unread, which keeps the /supervise
    # offer back, and is case 1 work in flight after git's items (#168):
    # the Project's setup is broken, and a ticket built now would fail or
    # land in the Project. It stays out of inflight_rest, so the offer reads
    # the step as it would be without it and names the not-read reason.
    # Its unpushed commits (dist_unpushed) stay out of inflight_rest too, as
    # the Project's do, so a run record can account for them (#263).
    dist= dist_inflight= dist_rest= dist_unread= dist_unpushed=0
    if ! dist=$(sh "$distribution" --dir . --working-tree </dev/null 2>"$tmp/dist-err"); then
        dist_unread="not read: $(cat "$tmp/dist-err")"
    elif [ -z "$dist" ]; then
        :
    # The path's checks are launch.sh's (distribution_check): a path the
    # launch refuses is not read here, so the offer is held back.
    elif ! reason=$(distribution_check "$dist" "$(git rev-parse --show-toplevel)"); then
        case $reason in
            missing) dist_unread="$dist not read: no such folder" ;;
            not-top) dist_unread="$dist not read: not a git checkout" ;;
            linked-worktree) dist_unread="$dist not read: a linked git worktree" ;;
            own-repo) dist_unread="$dist not read: the Project's own repo" ;;
            *) dist_unread="$dist not read: its path check failed ($reason)" ;;
        esac
    else
        git_state "$dist"
        echo "distribution repo: $dist"
        echo "distribution repo branch: $r_branch (default $r_default), $r_sync, as of last fetch"
        echo "distribution repo uncommitted paths: $r_dirty; unpushed commits: $r_unpushed"
        dist_inflight=$(git_inflight " in distribution repo $dist")
        dist_unpushed=$r_unpushed r_unpushed=0
        dist_rest=$(git_inflight " in distribution repo $dist")
        inflight="$inflight$dist_inflight" inflight_rest="$inflight_rest$dist_rest"
    fi
    if [ -n "$dist_unread" ]; then
        echo "distribution repo: $dist_unread"
        inflight="$inflight, distribution repo $dist_unread"
    fi

    # Issue numbers the default branch's commit messages close.
    close_re='(close[sd]?|fix(e[sd])?|resolve[sd]?):? +#'
    fixed=$(git log "$defref" --format=%B 2>/dev/null |
        grep -oiE "$close_re[0-9]+" |
        grep -oE '[0-9]+' | sort -un | tr '\n' ' ')

    # --- tracker ---------------------------------------------------------
    tracker=$(tracker_backend docs/agents/issue-tracker.md)
    reached=0 why=
    if [ $tracker = local ]; then
        if ! command -v jq >/dev/null; then why="jq not installed"
        elif ! why=$(read_local); then :
        else why= reached=1; fi
    elif [ $tracker = github ]; then
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
        local) if [ $reached = 1 ]; then echo "tracker: Local Markdown, read"
            else echo "tracker: Local Markdown, UNREACHED: $why"; fi ;;
    esac

    if [ $reached = 1 ]; then
        t_triage=$(label_for needs-triage) t_info=$(label_for needs-info)
        t_agent=$(label_for ready-for-agent) t_human=$(label_for ready-for-human)
        t_wont=$(label_for wontfix)

        # Local Markdown has no PR surface (#233).
        own=
        [ $tracker = github ] && own=$(printf '%s' "$prs" | jq -r '[.[] | select(.isCrossRepository | not)]
            | map("#\(.number) \(.title) [\(.headRefName)]") | join("; ")')
        if [ -n "$own" ]; then
            echo "open PRs from this repo: $own"
            inflight="$inflight, open PR $own" inflight_rest="$inflight_rest, open PR $own"
        fi

        # A body's priority line, as high, medium or low; null when there is
        # none. The first matching line anywhere in the body, case-insensitive:
        # the bold form with a reason after it (**Priority: High.** Why.), or
        # a line that is only the rating (Priority: Low, bold and a trailing
        # period optional). A line of prose that starts with the word is not
        # one, nor is a line in a code fence, closed only by its own marker.
        body_blockers='def priority: reduce ((.body // "") | splits("\r?\n")) as $line
            ({fence: null, p: null};
             ($line | capture("^\\s*(?<m>```|~~~)").m // null) as $m
             | if .fence then (if $m == .fence then .fence = null else . end)
             elif $m then .fence = $m
             elif .p then .
             else .p = (first($line
                 | capture("^\\s*(?:\\*\\*Priority: *(?<p>high|medium|low)(?!\\w)|(?:\\*\\*)?Priority: *(?<q>high|medium|low)\\.?(?:\\*\\*)?\\.?\\s*$)"; "i")
                 | (.p // .q) | ascii_downcase) // null) end) | .p;'
        # Issue numbers a body names as blockers: on `Blocked by:` lines, and in
        # bullets under a `Blocked by` heading (any level or case) up to the
        # next heading, the form tickets split from a spec use. Lines in a code
        # fence, closed only by its own marker, are examples, not blockers.
        # A blocker in another repo (other/lib#26) is "other/lib#26", never the
        # local #26; one naming this repo ($repo, any case) is local. Owner
        # and repo are lower case, as open_link_blockers names them, so one
        # ticket written in two cases is one blocker.
        body_blockers="$body_blockers"'
            def refs: [scan("(?<![\\w./-])(?:([\\w.-]+/[\\w.-]+))?#([0-9]+)(?!\\w)")
                | if .[0] == null or (.[0] | ascii_downcase) == $repo then .[1] | tonumber
                  else "\(.[0] | ascii_downcase)#\(.[1])" end];
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

        if [ $tracker = local ]; then
        # Local Markdown (#233): the rows, the open ids a blocker can name
        # (a number with no file stays open) and the unread items, from the
        # files read_local read, with no gh call. Its unread blockers are
        # $unread_refs, which next_child marks as GitHub's are.
        local_out=$(jq -c --arg tr "$t_triage" --arg ti "$t_info" --arg ta "$t_agent" --arg th "$t_human" --arg tw "$t_wont" \
            '{"needs-triage": $tr, "needs-info": $ti, "ready-for-agent": $ta, "ready-for-human": $th, "wontfix": $tw} as $roles
            | '"$body_blockers$role_def$park_local_def$local_rows_def" "$tmp/local.json")
        rows=$(printf '%s' "$local_out" | jq -c '.rows')
        open_nums=$(printf '%s' "$local_out" | jq -c '.open')
        unread=$(printf '%s' "$local_out" | jq -r '.unread | join("; ")')
        unread_refs=$(printf '%s' "$rows" | jq -r --argjson open "$open_nums" \
            '([.[].n]) as $have | [$open[] | select(. as $o | $have | index($o) | not)] | join(" ")')
        # A ticket a default-branch commit message closes (Closes
        # <feature-slug>#<NN>), keyed as .k, NN's leading zeros dropped.
        # There is no reopen to read.
        fixed_nums=$(git log "$defref" --format=%B 2>/dev/null |
            grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?):? +[A-Za-z0-9._-]+#[0-9]+' |
            grep -oE '[A-Za-z0-9._-]+#[0-9]+$' | sed 's/#0*\([0-9]\)/#\1/' |
            jq -Rnc '[inputs] | unique')
        else
        # This repo's API URL, which a linked blocker's repository_url matches
        # when the blocker is in this repo, and its owner/repo, lower case.
        repo_url=$(printf '%s' "$issues" | jq -r 'first(.[].repository_url // empty) // ""')
        repo_slug=$(printf '%s' "$repo_url" | sed 's|^.*/repos/||' | tr '[:upper:]' '[:lower:]')

        # Open issues only (the endpoint also lists PRs), with what the cases need.
        rows=$(printf '%s' "$issues" | jq -c --arg repo "$repo_slug" --arg tr "$t_triage" --arg ti "$t_info" \
            --arg ta "$t_agent" --arg th "$t_human" --arg tw "$t_wont" "$body_blockers$role_def"'
            [.[] | select(.pull_request | not)
             | {n: .number, t: .title, c: .comments, l: [.labels[].name],
                dep: (.issue_dependencies_summary.blocked_by // 0),
                line: body_blockers, p: priority}
             | .role = role_of($ta; $th; $ti; $tr; $tw)]
            | sort_by(.n)')
        open_nums=$(printf '%s' "$rows" | jq -c '[.[].n]')
        # Open blockers a body can name: this repo's open tickets, then each
        # other repo's ticket a body names that is open there, read once. One
        # whose state cannot be read counts as open, as an unknown blocker,
        # and is kept in $unread_refs for next_child to name as unread.
        unread_refs=
        for r in $(printf '%s' "$rows" | jq -r '[.[].line[] | strings] | unique | .[]'); do
            st=$(gh api "repos/${r%%#*}/issues/${r##*#}" 2>/dev/null | jq -r '.state // empty' 2>/dev/null)
            [ -n "$st" ] || unread_refs="$unread_refs $r"
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
        fi
        # A ticket awaiting a reply to its park question is parked (#158).
        rows=$(mark_parked "$rows")
        awaiting=$(printf '%s' "$rows" | jq -r "$ref_def"'map(select(.pk) | "\(.n | ref) \(.t)") | join("; ")')
        # count <role> [rows]: the rows (all of them by default) with that role.
        count() { printf '%s' "${2:-$rows}" | jq --arg r "$1" '[.[] | select(.role == $r)] | length'; }
        # Incoming work leaves out a parked ticket, as every other case does:
        # the unlabelled, needs-triage and needs-info counts, the replied
        # needs-info list and so case 3 read only these rows (#145).
        unparked=$(printf '%s' "$rows" | jq -c 'map(select(.l | index("parked") | not))')
        # A parked ticket goes beside ready-for-agent or ready-for-human only;
        # one parked beside any other state, or none, has a label to fix.
        misparked=$(printf '%s' "$rows" | jq -r "$ref_def"'
            map(select((.l | index("parked")) and .role != "agent" and .role != "human") | "\(.n | ref)") | join(", ")')

        # Open tickets the default branch already closes.
        stale=$(printf '%s' "$rows" | jq -r --argjson fx "$fixed_nums" "$ref_def"'
            [.[] | select(fxkey as $n | $fx | index($n))] | map("\(.n | ref) \(.t)") | join("; ")')

        # Ready-for-agent tickets with every blocker closed, not already fixed.
        ready_rows=$(printf '%s' "$rows" | jq -c --argjson open "$open_nums" --argjson fx "$fixed_nums" "$frontier_def$ref_def"'
            [.[] | select(.role == "agent" and (open_line($open) | frontier([]))
                            and (fxkey as $n | $fx | index($n) | not))]')
        ready=$(printf '%s' "$ready_rows" | jq -r "$ref_def"'map("\(.n | ref) \(.t)") | join("; ")')

        # What closing each ticket unblocks: the open tickets, not parked,
        # wontfix or already fixed, it is the last open blocker of, by GitHub
        # link or body. Only a ticket with one open link (dep, GitHub's open
        # count) has its links read: with two it cannot be unblocked by one
        # close, and each read spends the time budget. A ticket whose links
        # were not read has unknown blockers and is left out.
        targets=$(printf '%s' "$rows" | jq -c --argjson fx "$fixed_nums" "$ref_def"'
            [.[] | select(.dep <= 1 and .role != "wontfix" and (.l | index("parked") | not)
                          and (fxkey as $n | $fx | index($n) | not))]')
        links='{}'
        for n in $(printf '%s' "$targets" | jq -r '.[] | select(.dep == 1) | .n'); do
            b=$(open_link_blockers "$n")
            links=$(printf '%s' "$links" | jq -c --arg n "$n" --argjson b "${b:-null}" '.[$n] = $b')
        done
        # {"<blocker>": "#91 (High), #93", ...}, in ticket order.
        unblocks_map=$(printf '%s' "$targets" | jq -c --argjson open "$open_nums" --argjson links "$links" "$ref_def"'
            [.[] | (if .dep > 0 then $links["\(.n)"] else [] end) as $l
             | select($l != null)
             | {n, p, by: ($l + [.line[] | select(. as $b | $open | index($b))] | unique)}
             | select(.by | length == 1)]
            | group_by(.by[0])
            | map({key: "\(.[0].by[0])",
                   value: map("\(.n | ref)" + (if .p then " (\(.p[:1] | ascii_upcase)\(.p[1:]))" else "" end))
                          | join(", ")})
            | from_entries')
        unblocks=$(printf '%s' "$ready_rows" | jq -r --argjson u "$unblocks_map" "$ref_def"'
            map($u["\(.n)"] as $t | select($t) | "\(.n | ref) unblocks \($t)") | join("; ")')

        # Hand work: ready-for-human tickets not in motion or parked, with every
        # blocker closed and not already fixed, ranked by priority line (high,
        # medium, none, low), then lowest number.
        hand_rows=$(printf '%s' "$rows" | jq -c --argjson open "$open_nums" --argjson fx "$fixed_nums" "$ref_def"'
            [.[] | select(.role == "human" and .dep == 0
                            and (.l | index("in-motion") or index("parked") | not)
                            and ([.line[] | select(. as $b | $open | index($b))] | length == 0)
                            and (fxkey as $n | $fx | index($n) | not))]
            | sort_by([({high: 0, medium: 1, low: 3}[.p // ""] // 2), (.o // .n)])
            | map(.p |= if . then "\(.[:1] | ascii_upcase)\(.[1:])" else . end)')
        hand=$(printf '%s' "$hand_rows" | jq -r "$ref_def"'
            map("\(.n | ref) \(.t)" + (if .p then " (\(.p))" else "" end)) | join("; ")')
        # The top two, one per line: the second is the runner-up when case 6 wins.
        hand_steps=$(printf '%s' "$hand_rows" | jq -r "$ref_def"'
            .[:2][] | "6 by hand" + (if .p then " (\(.p))" else "" end) + ": #\(.n) \(.t)"')

        # Ready-for-human tickets a session left in motion: capturing labels the
        # one it worked on, which git cannot see. Not already fixed.
        moving_rows=$(printf '%s' "$rows" | jq -c --argjson fx "$fixed_nums" "$ref_def"'
            [.[] | select(.role == "human" and (.l | index("in-motion"))
                            and (fxkey as $n | $fx | index($n) | not))]')
        moving=$(printf '%s' "$moving_rows" | jq -r "$ref_def"'map("\(.n | ref) \(.t)") | join("; ")')
        # A parent's work in flight is its next child, so each carries that step.
        in_motion= children=
        for n in $(printf '%s' "$moving_rows" | jq -r '.[].n'); do
            child=$(next_child "$n")
            children="$children $(printf '%s' "$child" | sed -n 's/^; next child \([^ ]*\) (.*/\1/p')"
            in_motion="$in_motion; $(printf '%s' "$moving_rows" |
                jq -r --arg n "$n" "$ref_def"'.[] | select((.n | tostring) == $n) | "\(.n | ref) \(.t)"')$child"
        done
        if [ -n "$in_motion" ]; then
            inflight="$inflight, in motion ${in_motion#; }" inflight_rest="$inflight_rest, in motion ${in_motion#; }"
        fi
        # Case 2's ticket: the first ready one case 1 has not already named as
        # a next child, so next: and runner-up: never name the same ticket.
        children_nums=$(jq -nc --arg c "$children" '$c | split(" ") | map(select(. != ""))')
        pick=$(printf '%s' "$ready_rows" | jq -r --argjson cn "$children_nums" "$ref_def"'
            [.[] | select((.n | ref) as $n | $cn | index($n) | not)] | first // empty | "\(.n | ref) \(.t)"')

        # needs-info with a reply: the last comment is not the tracker user's.
        # Local Markdown comments record no author, so no reply is read (#233).
        replied=
        infos=
        [ $tracker = local ] || infos=$(printf '%s' "$unparked" | jq -r '.[] | select(.role == "info" and .c > 0) | .n')
        if [ -n "$infos" ]; then
            me=$(gh api user 2>/dev/null | jq -r '.login // empty')
            for n in $infos; do
                last=$(gh api "repos/{owner}/{repo}/issues/$n/comments?per_page=100" --paginate 2>/dev/null |
                    jq -rs 'add | last.user.login // empty')
                [ -n "$last" ] && [ "$last" != "$me" ] && replied="$replied #$n"
            done
        fi
        replied=${replied# }

        n_triage=$(count triage "$unparked") n_info=$(count info "$unparked") n_unl=$(count unlabelled "$unparked")
        n_agent=$(count agent) n_human=$(count human) n_map=$(count map)
        maps=$(printf '%s' "$rows" | jq -r "$ref_def"'[.[] | select(.role == "map")] | map("\(.n | ref) \(.t)") | join("; ")')
        replied_shown=${replied:-none}
        [ $tracker = local ] && replied_shown="not read"
        echo "issues: $n_unl unlabelled, $n_triage $t_triage, $n_info $t_info (replied: $replied_shown), $n_agent $t_agent, $n_human $t_human, $n_map wayfinder:map"
        [ $tracker = local ] && echo "note: $t_info replies are not read on Local Markdown, since its comments record no author"
        [ -n "${unread:-}" ] && echo "unread: $unread"
        echo "in motion: ${moving:-none}"
        echo "ready, blockers closed: ${ready:-none}"
        [ -n "$awaiting" ] && echo "parked, awaiting reply: $awaiting"
        [ -n "$misparked" ] && echo "parked without a state label: $misparked"
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
        if [ $tracker = local ]; then
            [ -n "$stale" ] && add_case "4 tracker and repo disagree: close $stale (a commit message closes it, and its file has no Closed: line)"
        else
            [ -n "$stale" ] && add_case "4 tracker and repo disagree: close $stale (as of the last read: confirm with gh issue view first)"
        fi
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
                '2 /implement '*) t=${c#2 /implement } ;;
                '1 '*'; next child '*) t=${c#*; next child } ;;
                '1 '*'in motion '*) t=${c#*in motion } ;;
                '6 by hand'*': '*) t=${c#*: } ;;
                *) t= ;;
            esac
            # The id as unblocks_map keys it: the number, or a Local
            # Markdown id as written.
            t=${t%% *} t=${t#\#}
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
    # tickets, counting a reorder's, or for a run to continue.
    #
    # Unpushed commits on the default branch may be a supervised run of the
    # next ticket that a supervisor ended before pushing (#214). So the offer
    # reads the step as it would be without them (offer), and when a run
    # record on that ticket accounts for them exactly (run-start.sh), offers
    # the loop and prints `continue: #N from <start>`, which step.sh takes.
    # When they are the only refusal and no run accounts for them, the loop
    # is offered all the same, and a `push:` line names the push /supervise
    # asks the maintainer for before its first launch (#223), which step.sh
    # hands on. Otherwise the lines are as they were: no queue: line, and the
    # unpushed refusal. A Distribution repo that cannot be read is left out
    # of the offer's step the same way, and refuses it below. Unpushed
    # commits in the Distribution repo are weighed with the Project's (held):
    # a run record that accounts for both continues the run, and its
    # continue: line names the Distribution start too (#263); with none,
    # they refuse as that repo's work in flight, with no push: line.
    first=$(printf '%s' "$cases" | sed -n 1p)
    # /supervise does not run on a Local Markdown tracker yet (#235): an
    # /implement step says so, and nothing else is printed.
    if [ $tracker = local ]; then
        case $first in
            ('2 /implement '* | '1 '*'; next child '*', /implement '*)
                echo "supervise: not offered: /supervise does not run on a Local Markdown tracker yet" ;;
        esac
        return 0
    fi
    offer=$first
    held=$((unpushed + dist_unpushed))
    if [ "$held" -gt 0 ] || [ -n "$dist_unread" ]; then
        if [ -n "$inflight_rest" ]; then offer="1 work in flight: ${inflight_rest#, }"
        else offer=$(printf '%s' "$cases" | sed -n 2p); fi
    fi
    # When the step is an in-motion parent's by-hand or not-ready child, with
    # the parent the only work in flight (hand_child), the offer is the reorder
    # moving a ready child ahead of it, and step_n is that child, set once the
    # replay finds it; with none, nothing is printed, as before (#207). The
    # match is on the step itself, so with git work in flight (unpushed
    # commits included) nothing is printed either.
    impl=$(implement_of "$first") hand_child=
    if [ -z "$impl" ] && [ -z "$(implement_of "$offer")" ]; then
        hand_child=$(hand_step "$first")
        [ -n "$hand_child" ] || return 0
        offer=$first
    fi
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
    if [ -n "$step_n$hand_child" ]; then
        parent=$(printf '%s\n' "$offer" | sed -n 's/^1 work in flight: in motion #\([0-9][0-9]*\) .*/\1/p')
        if [ -n "$parent" ]; then cands=$(cat "$tmp/kids-$parent.json")
        # Parked rows are dropped here, though frontier skips them too, so
        # their links are not read below.
        else cands=$(printf '%s' "$rows" | jq -c --argjson open "$open_nums" --argjson fx "$fixed_nums" "$frontier_def"'
            [.[] | select(.role == "agent" and (.l | index("parked") | not) and (.n as $n | $fx | index($n) | not))
             | open_line($open)]'); fi
        # Links unblocks: already read are reused: each read spends the budget.
        qlinks=$links
        for n in $(printf '%s' "$cands" | jq -r --argjson have "$links" '.[] | select(.dep > 0 and ($have | has("\(.n)") | not)) | .n'); do
            b=$(open_link_blockers "$n")
            qlinks=$(printf '%s' "$qlinks" | jq -c --arg n "$n" --argjson b "${b:-null}" '.[$n] = $b')
        done
        qr=$(printf '%s' "$cands" | jq -c --argjson links "$qlinks" --arg ta "$t_agent" --arg p "$parent" "$frontier_def"'
            def startable($q): (.n as $n | $q | index($n) | not) and frontier($q);
            def replay($c): def go: .q as $q
                | ([$c[] | select(startable($q))] | first) as $k
                | if $k == null then .
                  elif ($k.l | index($ta)) then .q += [$k.n] | go
                  else .end = $k.n end;
                {q: [], end: null} | go;
            map(if .dep > 0 then .links = $links["\(.n)"] else . end)
            | . as $c | replay($c) as $r
            | ($c | map(.n)) as $ns
            | (if $p == "" or $r.end == null then null
               else ($ns | index($r.end)) as $xi
               | ([$c[$xi + 1:][] | select(startable($r.q) and (.l | index($ta)))] | first) as $y
               | if $y == null then null
                 else ($ns | index($y.n)) as $yi
                 | {y: $y.n, yid: $y.id, yi: ($yi + 1), x: $r.end, xid: $c[$xi].id, xi: ($xi + 1),
                    after: replay($c[:$xi] + [$y] + [$c[$xi:][] | select(.n != $y.n)]).q}
                 end
               end) as $m
            | {q: $r.q, m: $m, len: (($m.after // $r.q) | length)}')
        # A by-hand step's queue is empty, since the replay ends at that child:
        # the offer is the reorder's, and with no reorder there is none.
        if [ -n "$hand_child" ]; then
            step_n=$(printf '%s' "$qr" | jq -r '.m.y // empty' 2>/dev/null)
            [ -n "$step_n" ] || return 0
        fi
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
    # Unpushed commits included, though only the rest refuses here: those are
    # weighed with the run records below.
    dist_refusal="work in flight in distribution repo $dist: ${dist_inflight#, }"
    if ! linked=$(sh "$main_checkout" . </dev/null 2>&1); then refusal=$linked early=1
    elif [ "$dirty" -gt 0 ]; then refusal="$dirty uncommitted paths; commit or clear them first" early=1
    elif [ "$branch" != "$default" ]; then refusal="on $branch, not the default branch $default" early=1
    elif [ -n "${own:-}" ]; then refusal="open PR $own; settle it first"
    elif [ -n "$dist_rest" ]; then refusal=$dist_refusal
    elif [ -n "$dist_unread" ]; then refusal="distribution repo $dist_unread"
    elif [ -z "$step_n" ]; then refusal="other work in flight: ${inflight_rest#, }"
    fi
    # A queue of one refuses only when no run is there to continue (#221): a
    # continued ticket is worth a loop on its own, which goes on to whatever
    # is ready after it. With unpushed commits it waits on the run records
    # (lone): one that accounts for them lifts it, and none leaves the
    # unpushed refusal, with no push: line: a lone ticket is /implement's.
    hard=$refusal lone=
    if [ -n "$refusal" ]; then :
    elif ! [ "$qlen" -ge 0 ] 2>/dev/null; then refusal="the queue could not be read"
    elif [ "$qlen" -lt 2 ] && [ "$held" -eq 0 ]; then
        refusal="a queue of one (#$step_n); /supervise is worth running only for two or more tickets"
    else
        [ "$qlen" -ge 2 ] || lone=1
        here=$(pwd -P)
        # Which sessions are live is live.sh's, shared with launch.sh, which
        # also refuses one in the Distribution repo.
        # Within agents.sh's time limit (#240).
        list=$(agents_list 2>/dev/null); list_rc=$?
        if [ "$list_rc" -eq 124 ]; then
            refusal="claude agents --json --all did not answer in $(agents_limit)s, so other sessions in $here are unknown"
        elif [ "$list_rc" -ne 0 ]; then
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
    # it offers no push. Its lines print as a continued run's
    # would, and a refusal set before the read, which holds whatever it
    # finds, stands.
    start= dist_start= push= records_unread=
    if [ "$held" -gt 0 ] && [ -z "$early" ]; then
        if [ -n "$hard" ]; then :
        elif ! comments=$(gh api "repos/{owner}/{repo}/issues/$step_n/comments?per_page=100" --paginate 2>/dev/null) ||
            ! comments=$(printf '%s' "$comments" | jq -cs 'add // []' 2>/dev/null); then
            records_unread=1
        else
            start=$(run_start . "$step_n" "$comments" ${dist:+"$dist"}) || start=
            [ -z "$dist" ] || [ -z "$start" ] || dist_start=${start#* } start=${start%% *}
        fi
        if [ -n "$records_unread" ]; then
            [ -n "$refusal" ] || refusal="the run records on #$step_n could not be read"
        elif [ -n "$start" ]; then :
        elif [ "$unpushed" -gt 0 ]; then
            if [ -n "$refusal$lone" ] || [ "$dist_unpushed" -gt 0 ]; then refusal="$unpushed unpushed commits; push them first"
            else push=1; fi
        else
            [ -n "$hard" ] || refusal=$dist_refusal
        fi
    fi
    if [ "$held" -gt 0 ] && [ -z "$start" ] && [ -z "$push" ] && [ -z "$records_unread" ]; then
        [ -n "$impl" ] || return 0
    else
        [ -z "${qout:-}" ] || printf '%s\n' "$qout"
    fi
    if [ -n "$refusal" ]; then echo "supervise: not offered: $refusal"
    else echo "supervise: $loop $you_type"; fi
    [ -z "$start" ] || echo "continue: #$step_n from $start${dist_start:+, dist start $dist_start}"
    [ -z "$push" ] ||
        echo "push: #$step_n after $unpushed unpushed commits; /supervise asks to push them with git push origin $default before its first launch"
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
