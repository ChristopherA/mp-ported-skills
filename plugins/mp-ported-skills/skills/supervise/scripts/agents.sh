#!/bin/sh
# agents.sh -- read `claude agents --json --all` within a time limit, for
# the supervise scripts and resuming's state.sh to source (#240).
#
# A `claude agents` call can hang and never return. Twice a watch sat
# inside one for hours (3h20m, then 14h40m), so it skipped its own stall
# check and timeout, both read between polls, and the run went unreported
# after the worker finished. The second hung call ignored SIGTERM. So the
# call runs in a process group of its own under a perl parent, which sends
# SIGKILL to the whole group once the limit passes: no handler can catch
# or ignore it. A TERM, INT or HUP to the perl parent, as stopping the
# caller sends, kills the group the same way, since a signal to the
# caller's group no longer reaches the call. The call's stdout and stderr
# go to temporary files rather than the caller's pipe, and are replayed
# after it ends, so a process it leaves behind cannot hold the caller's
# `$( )` open.
#
# The limit is MP_AGENTS_TIMEOUT seconds, a whole number of 1 or more;
# unset or anything else reads as 60. A normal call answers in a second or
# two.
#
# Usage:
#   . "$(dirname -- "$0")/agents.sh"
#   list=$(agents_list); rc=$?
#
# agents_list prints the call's stdout and stderr and returns its exit
# status. A call past the limit prints nothing on stdout and returns 124;
# the caller words the error, naming `agents_limit` seconds.
#
# agents_tries is how many hung calls in a row a polling caller (watch.sh,
# settle.sh) takes before it fails: one hung call is one failed poll, read
# again at the next.

agents_limit() {
    case ${MP_AGENTS_TIMEOUT:-} in
        '' | *[!0-9]* | 0 | 0*) echo 60 ;;
        *) echo "$MP_AGENTS_TIMEOUT" ;;
    esac
}

agents_tries() { echo 3; }

agents_list() {
    agents_out=$(mktemp) || return 1
    agents_err=$(mktemp) || { rm -f "$agents_out"; return 1; }
    # shellcheck disable=SC2016
    perl -e '
        my ($limit, $out, $err, @cmd) = @ARGV;
        my $pid = fork;
        defined $pid or exit 126;
        if ($pid == 0) {
            setpgrp(0, 0);
            open STDOUT, ">", $out or exit 126;
            open STDERR, ">", $err or exit 126;
            exec { $cmd[0] } @cmd;
            exit 127;
        }
        setpgrp($pid, $pid);
        $SIG{ALRM} = sub { kill "KILL", -$pid; kill "KILL", $pid; waitpid $pid, 0; exit 124 };
        for my $sig (qw(TERM INT HUP)) {
            $SIG{$sig} = sub { kill "KILL", -$pid; kill "KILL", $pid; waitpid $pid, 0; exit 128 + ($sig eq "TERM" ? 15 : $sig eq "INT" ? 2 : 1) };
        }
        alarm $limit;
        waitpid $pid, 0;
        my $s = $?;
        alarm 0;
        exit($s & 127 ? 128 + ($s & 127) : $s >> 8);
    ' "$(agents_limit)" "$agents_out" "$agents_err" claude agents --json --all </dev/null
    agents_rc=$?
    # Plain cat and rm, not `command cat`: when a function started as a
    # background job (`f &`, as state.sh's gather is) reads this one through
    # `$( )`, macOS /bin/sh (bash 3.2) runs `command <program>` in place of
    # the substitution's subshell, so nothing after it runs and the call
    # returns that program's status, 0 for a failed read. A subshell started
    # with `( ) &` does not do it. A non-interactive sh expands no aliases,
    # so the plain names reach the programs.
    if [ "$agents_rc" -ne 124 ]; then
        cat "$agents_out"
    fi
    cat "$agents_err" >&2
    rm -f "$agents_out" "$agents_err"
    return "$agents_rc"
}
