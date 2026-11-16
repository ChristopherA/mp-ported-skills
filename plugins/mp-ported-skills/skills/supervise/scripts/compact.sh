# compact.sh -- sourced by zone.sh and next.sh: a session's auto-compact
# point, from the override in force and the context window (#181).
#
# compact_pct: prints CLAUDE_AUTOCOMPACT_PCT_OVERRIDE, the share of the
# window at which Claude Code compacts, or its default, 80, when it is unset
# or not a positive whole number. It reads the caller's environment. The
# profile sets the override in its settings.json `env` block, which reaches
# the supervisor's commands and the worker alike, since launch.sh starts the
# worker under the same profile; an override set only in the supervisor's
# shell does not reach a worker (launch.sh's header). Leading zeros are
# dropped, since $(( )) reads 080 as octal.
compact_pct() {
    compact_p=${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-80}
    case $compact_p in *[!0-9]*) compact_p=80 ;; esac
    while [ "${compact_p#0}" != "$compact_p" ]; do compact_p=${compact_p#0}; done
    [ -n "$compact_p" ] || compact_p=80
    printf '%s\n' "$compact_p"
}

# compact_window_k <model id>: prints the model's context window in
# thousands of tokens, and returns 1 when the window is not known, printing
# the smallest window a worker runs on, 200k, so a caller guesses small. A
# model id ending [1m] asks for the 1M window; claude-opus-5-5 and
# claude-fable-5-1 run on it without asking (status-line records,
# context_window_size 1000000), and so do claude-sonnet-5, claude-sonnet-5-5
# and claude-haiku-5-5 (#226's triage probe, Claude Code 2.1.311:
# `claude -p --model <id> --output-format json` reported
# modelUsage.<id>.contextWindow 1000000 for each, and 200000 for
# claude-haiku-4-5). Each entry also matches its dated `-*` form; for
# claude-sonnet-5 that is `-20*` alone, so an unobserved claude-sonnet-5-6
# is not read as 1M. An alias (opus, sonnet) is not listed: it moves to a
# new model when one ships, so the table holds only ids whose window was
# observed.
compact_window_k() {
    case $1 in
        *'[1m]' | claude-opus-5-5 | claude-opus-5-5-* | claude-fable-5-1 | claude-fable-5-1-* | \
            claude-sonnet-5 | claude-sonnet-5-20* | claude-sonnet-5-5 | claude-sonnet-5-5-* | \
            claude-haiku-5-5 | claude-haiku-5-5-*) echo 1000 ;;
        *) echo 200; return 1 ;;
    esac
}
