# worker-cleanup.sh -- sourced by the live tests that run supervise's
# resume.sh on a background session in a scratch folder inside this
# checkout.
#
# worker_cleanup_remove <scripts> <scratch> <id> [<id>...]: stops and removes
# each background session, then releases the first id's marker. resume.sh
# writes the worker's marker in the repo holding the scratch folder, which is
# this checkout, so a test that only removed its session would leave this
# checkout read-only to every attended session. Prints nothing; safe to call
# with sessions already gone and no marker.
#
# worker_cleanup_trap <function>: runs the function when the test exits, and on INT
# and TERM, so an interrupted run cleans up too (#95). bash, which is macOS
# sh, runs an EXIT trap on a fatal signal, but dash and zsh do not, so INT
# and TERM exit through it. A signal that arrives while a foreground command
# runs (a watch.sh wait) is handled once that command returns; Ctrl-C ends
# both at once. The function must be safe to call before the session is
# launched.
worker_cleanup_remove() {
    worker_cleanup_scripts=$1 worker_cleanup_scratch=$2 worker_cleanup_id=$3
    shift 2
    for worker_cleanup_s in "$@"; do
        claude stop "$worker_cleanup_s" </dev/null >/dev/null 2>&1
        claude rm "$worker_cleanup_s" </dev/null >/dev/null 2>&1
    done
    sh "$worker_cleanup_scripts/release.sh" --dir "$worker_cleanup_scratch" --id "$worker_cleanup_id" </dev/null >/dev/null 2>&1
}

worker_cleanup_trap() {
    # shellcheck disable=SC2064
    trap "$1" EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}
