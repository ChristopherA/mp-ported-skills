#!/bin/sh
# accept.sh -- sourced by step.sh and resuming's state.sh: which next: step
# /supervise takes (#115). One copy of the patterns, so state.sh's
# supervise: offer and step.sh cannot disagree on it.

# accept_step <line>: the ticket number when state.sh's next: line (without
# `next: `) is /implement of a ready-for-agent ticket with nothing else in
# flight, or nothing. Case 2 names the ticket first. In case 1, an in-motion
# ticket must be the only work in flight (git's items come before it), and
# the next child's parentheses name /implement only for the ready-for-agent
# label.
accept_step() {
    printf '%s\n' "$1" | sed -n \
        -e 's/^2 \/implement #\([0-9][0-9]*\) .*/\1/p' \
        -e 's/^1 work in flight: in motion #[0-9][0-9]* [^;]*; next child #\([0-9][0-9]*\) ([^,)]*, \/implement #\1, .*/\1/p'
}

# hand_step <line>: the next child's number when the line is case 1 with an
# in-motion ticket the only work in flight, as accept_step reads it, and its
# next child by hand or not ready; or nothing. state.sh offers a reorder past
# such a child (#207). step.sh stops on it, so accept_step does not take it.
hand_step() {
    printf '%s\n' "$1" | sed -n \
        -e 's/^1 work in flight: in motion #[0-9][0-9]* [^;]*; next child #\([0-9][0-9]*\) ([^,)]*, by hand): .*/\1/p' \
        -e 's/^1 work in flight: in motion #[0-9][0-9]* [^;]*; next child #\([0-9][0-9]*\) (not ready): .*/\1/p'
}
