#!/bin/sh
# transcript.sh -- sourced by watch.sh, actions.sh, answer.sh,
# last-message.sh, record.sh and zone.sh: where a session's transcripts are
# (#172). Keep the one lookup here, so a change to how a transcript is found
# is one edit.
#
# A session's main transcript is $CLAUDE_CONFIG_DIR/projects/<folder>/<id>.jsonl.
# The folder is not always the one its cwd maps to: a session that entered a
# worktree has its whole transcript moved to the worktree's folder, so the
# lookup tries every project folder. Its subagents' transcripts sit beside
# it, in <folder>/<id>/subagents/, wherever the main one moved to.
#
# Usage, from a script beside this one:
#   . "$(dirname -- "$0")/transcript.sh"

# transcript_of <session id>: prints the path of the session's main
# transcript; prints nothing and returns 1 when none is found, or when the
# id is empty. Reads CLAUDE_CONFIG_DIR.
transcript_of() {
    [ -n "$1" ] || return 1
    for transcript_path in "$CLAUDE_CONFIG_DIR"/projects/*/"$1".jsonl; do
        [ -f "$transcript_path" ] || continue
        printf '%s\n' "$transcript_path"
        return 0
    done
    return 1
}

# transcript_subagents_dir <main transcript>: prints the folder that holds
# that session's subagent transcripts (*.jsonl), beside the main one. The
# folder may not exist, for a session that ran no subagent.
transcript_subagents_dir() {
    printf '%s\n' "${1%.jsonl}/subagents"
}
