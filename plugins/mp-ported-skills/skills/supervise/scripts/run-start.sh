#!/bin/sh
# run-start.sh -- sourced by resuming's state.sh: whether the unpushed
# commits on a checkout's branch are a supervised run of one ticket, and
# that run's start (#214).
#
# A supervisor can end between a ticket's zone capture and its continuation,
# or after a continuation that was captured too, leaving the run's commits
# unpushed. Only that supervisor knew the run's start. The run record
# finish.sh posts on the ticket carries it, on its `- outcome: K commits
# after <short sha>` line, so a later session reads it there.

# run_start <dir> <ticket> <comments json>: the full sha of the run's start
# when the newest run record on the ticket (comments json, oldest first, as
# gh api lists them) is a supervised run of that ticket with commits, and
# the commits on <dir>'s HEAD that no remote holds are exactly the K commits
# after its start. Prints nothing and exits 1 otherwise: a hand run's record,
# a `no commits` record, a record of another ticket, a start not in the
# repo, or a commit made after the record or outside its range.
run_start() {
    run_start_out=$(printf '%s' "$3" | jq -r --arg n "$2" '
        [.[] | (.body // "") | select(test("^\\s*## (Supervised|Hand) run of #" + $n + "(\\D|$)"))]
        | last // "" | select(test("^\\s*## Supervised run of #"))
        | [splits("\r?\n") | capture("^- outcome: (?<k>[0-9]+) commits? after (?<s>[0-9a-f]{7,40})(,|$)")]
        | first // empty | "\(.k) \(.s)"' 2>/dev/null) || return 1
    [ -n "$run_start_out" ] || return 1
    run_start_k=${run_start_out%% *}
    run_start_sha=$(git -C "$1" rev-parse -q --verify "${run_start_out#* }^{commit}" 2>/dev/null) || return 1
    run_start_range=$(git -C "$1" rev-list "$run_start_sha..HEAD" 2>/dev/null | sort) || return 1
    run_start_unpushed=$(git -C "$1" rev-list HEAD --not --remotes 2>/dev/null | sort) || return 1
    [ -n "$run_start_range" ] && [ "$run_start_range" = "$run_start_unpushed" ] || return 1
    [ "$(printf '%s\n' "$run_start_range" | grep -c '^')" = "$run_start_k" ] || return 1
    printf '%s\n' "$run_start_sha"
}
