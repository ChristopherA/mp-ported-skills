#!/bin/sh
set -eu

# Send text, keypresses, or control characters to an iTerm2 pane.
#
# Usage:
#   pane-send.sh --session ID --window ID --tab NUM --text "command"
#   pane-send.sh --session ID --window ID --tab NUM --key "s"
#   pane-send.sh --session ID --window ID --tab NUM --control c
#   pane-send.sh --session ID --window ID --tab NUM --escape
#
# --text types the text and a newline. Claude Code can hold pasted text
# without submitting it, so text sent to a session is followed by
# --key return.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/pane-common.sh"

SESSION_ID=""
WINDOW_ID=""
TAB_NUM=""
MODE=""
VALUE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --session) pane_need_value "$@"; SESSION_ID="$2"; shift 2 ;;
        --window)  pane_need_value "$@"; WINDOW_ID="$2"; shift 2 ;;
        --tab)     pane_need_value "$@"; TAB_NUM="$2"; shift 2 ;;
        --text)    pane_need_value "$@"; MODE="text"; VALUE="$2"; shift 2 ;;
        --key)     pane_need_value "$@"; MODE="key"; VALUE="$2"; shift 2 ;;
        --control) pane_need_value "$@"; MODE="control"; VALUE="$2"; shift 2 ;;
        --escape)  MODE="escape"; VALUE=""; shift ;;
        --help)
            printf "Usage: pane-send.sh --session ID --window ID --tab NUM [--text cmd | --key k | --control c | --escape]\n"
            exit 0 ;;
        *) printf "Unknown option: %s\n" "$1" >&2; exit 1 ;;
    esac
done

pane_check_coords

if [ -z "$MODE" ]; then
    printf "Error: specify --text, --key, --control, or --escape\n" >&2
    exit 1
fi

# Sending prints nothing; AppleScript's write text has no result anyway.
exec >/dev/null

TELL="tell application \"iTerm2\" to tell $(pane_target) to"

case "$MODE" in
    text)
        pane_osa "$TELL write text $(pane_quote "$VALUE")"
        ;;
    key)
        case "$VALUE" in
            return|enter) pane_osa "$TELL write text \"\" with newline" ;;
            tab)          pane_osa "$TELL write text (ASCII character 9) without newline" ;;
            *)            pane_osa "$TELL write text $(pane_quote "$VALUE") without newline" ;;
        esac
        ;;
    control)
        case "$VALUE" in
            c) ASCII_CODE=3 ;;
            z) ASCII_CODE=26 ;;
            d) ASCII_CODE=4 ;;
            l) ASCII_CODE=12 ;;
            *) printf "Unknown control character: %s (supported: c, z, d, l)\n" "$VALUE" >&2; exit 1 ;;
        esac
        pane_osa "$TELL write text (ASCII character ${ASCII_CODE})"
        ;;
    escape)
        pane_osa "$TELL write text (ASCII character 27) without newline"
        ;;
esac
