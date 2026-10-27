# compact.sh -- sourced by zone.sh and next.sh: a session's auto-compact
# point, from the override in force and the context window (#181).
#
# compact_pct: prints CLAUDE_AUTOCOMPACT_PCT_OVERRIDE, the share of the
# window at which Claude Code compacts, or its default, 80, when it is unset
# or not a positive whole number.
compact_pct() {
    compact_p=${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-80}
    case $compact_p in '' | *[!0-9]* | 0) compact_p=80 ;; esac
    printf '%s\n' "$compact_p"
}

# compact_window_k <model id>: prints the model's context window in
# thousands of tokens, and returns 1 when the window is not known, printing
# the smallest window a worker runs on, 200k, so a caller guesses small. A
# model id ending [1m] asks for the 1M window; claude-opus-5-5 and
# claude-fable-5-1 run on it without asking (status-line records,
# context_window_size 1000000).
compact_window_k() {
    case $1 in
        *'[1m]' | claude-opus-5-5 | claude-opus-5-5-* | claude-fable-5-1 | claude-fable-5-1-*) echo 1000 ;;
        *) echo 200; return 1 ;;
    esac
}
