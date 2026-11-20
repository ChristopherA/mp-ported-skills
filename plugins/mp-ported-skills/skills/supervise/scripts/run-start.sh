#!/bin/sh
# run-start.sh -- sourced by resuming's state.sh: whether the unpushed
# commits on a checkout's branch are a supervised run of one ticket, and
# that run's start (#214).
#
# A supervisor can end between a ticket's zone capture and its continuation,
# or after a continuation that was captured too, leaving the run's commits
# unpushed. Only that supervisor knew the run's start. The run record
# finish.sh posts on the ticket carries it, on its `- outcome: K commits
# after <short sha>` line, so a later session reads it there. A Project with
# a Distribution repo adds ` in the Project repo` after the sha, then that
# repo's count, `, D commits after <short sha> in the Distribution repo`
# (record.sh, #216), and its run can leave commits in either repo (#263).

# run_start <dir> <ticket> <comments json> [<distribution repo>]: the full
# sha of the run's start when the newest run record on the ticket (comments
# json, oldest first, as gh api lists them) is a supervised run of that
# ticket with commits, and the commits on <dir>'s HEAD that no remote holds
# are exactly the K commits after its start. Prints nothing and exits 1
# otherwise: a hand run's record, a `no commits` record, a record of another
# ticket, a start not in the repo, or a commit made after the record or
# outside its range.
#
# With a Distribution repo, prints `<start> <distribution start>`, both full
# shas, and the record must account for the unpushed commits in both repos,
# each by its own range, with commits in at least one: the Project's count
# may be `no commits`. A record that names no Distribution start (one that
# did not count that repo) accounts for it only when it holds no unpushed
# commits, and its start is then the repo's HEAD.
run_start() {
    run_start_out=$(printf '%s' "$3" | jq -r --arg n "$2" '
        [.[] | (.body // "") | select(test("^\\s*## (Supervised|Hand) run of #" + $n + "(\\D|$)"))]
        | last // "" | select(test("^\\s*## Supervised run of #"))
        | [splits("\r?\n") | capture("^- outcome: (?<k>no|[0-9]+) commits? after (?<s>[0-9a-f]{7,40})( in the Project repo(, (?<dk>no|[0-9]+) commits? after (?<ds>[0-9a-f]{7,40}) in the Distribution repo)?)?(,|$)")]
        | first // empty | "\(.k) \(.s) \(.dk // "-") \(.ds // "-")"' 2>/dev/null) || return 1
    [ -n "$run_start_out" ] || return 1
    set -- "$1" "$2" "$3" "${4:-}" $run_start_out
    [ "$5" = no ] && run_start_k=0 || run_start_k=$5
    if [ -z "$4" ]; then
        [ "$run_start_k" -gt 0 ] || return 1
        run_start_sha=$(run_start_exact "$1" "$6" "$run_start_k") || return 1
        printf '%s\n' "$run_start_sha"
        return 0
    fi
    run_start_sha=$(run_start_exact "$1" "$6" "$run_start_k") || return 1
    if [ "$8" = - ]; then
        run_start_dk=0
        run_start_dsha=$(run_start_exact "$4" HEAD 0) || return 1
    else
        [ "$7" = no ] && run_start_dk=0 || run_start_dk=$7
        run_start_dsha=$(run_start_exact "$4" "$8" "$run_start_dk") || return 1
    fi
    [ $((run_start_k + run_start_dk)) -gt 0 ] || return 1
    printf '%s %s\n' "$run_start_sha" "$run_start_dsha"
}

# run_start_exact <dir> <start> <count>: the full sha of <start> in <dir>
# when the commits after it on HEAD are exactly the <count> that no remote
# holds; exits 1 otherwise.
run_start_exact() {
    run_start_full=$(git -C "$1" rev-parse -q --verify "$2^{commit}" 2>/dev/null) || return 1
    run_start_range=$(git -C "$1" rev-list "$run_start_full..HEAD" 2>/dev/null | sort) || return 1
    run_start_unpushed=$(git -C "$1" rev-list HEAD --not --remotes 2>/dev/null | sort) || return 1
    [ "$run_start_range" = "$run_start_unpushed" ] || return 1
    [ "$(printf '%s' "$run_start_range" | grep -c '^')" = "$3" ] || return 1
    printf '%s\n' "$run_start_full"
}
