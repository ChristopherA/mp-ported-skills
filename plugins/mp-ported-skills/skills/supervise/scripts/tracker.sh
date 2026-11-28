#!/bin/sh
# tracker.sh -- sourced by resuming's state.sh and supervise's grant.sh:
# which tracker backend a Project's docs/agents/issue-tracker.md names
# (#233). One copy of the rule, for every script that branches on the
# tracker.

# tracker_backend <doc path>: prints `none` when the file does not exist,
# else what tracker_backend_read prints for its text.
tracker_backend() {
    [ -f "$1" ] || { echo none; return 0; }
    tracker_backend_read <"$1"
}

# tracker_backend_read: the backend the doc on stdin names, as grant.sh
# reads it from a committed ref (#234). Its first line decides:
# `# Issue tracker: GitHub` gives `github`, `# Issue tracker: Local
# Markdown` gives `local` (any case, trailing blanks ignored), and any other
# `# Issue tracker:` title gives `other`. A doc with no such title keeps the
# older rule, so a repo set up before the title existed reads as it did:
# GitHub named anywhere in its first five lines gives `github`, else
# `other`.
tracker_backend_read() {
    tracker_head=$(head -n 5)
    tracker_title=$(printf '%s\n' "$tracker_head" | sed -n '1{s/[[:space:]]*$//;p;q;}' | tr '[:upper:]' '[:lower:]')
    case $tracker_title in
        ('# issue tracker: github') echo github ;;
        ('# issue tracker: local markdown') echo local ;;
        ('# issue tracker:'*) echo other ;;
        (*) if printf '%s\n' "$tracker_head" | grep -qi github; then echo github; else echo other; fi ;;
    esac
}
