#!/bin/sh
# iterm-pane.test.sh -- fixture tests for the iterm-pane skill's scripts.
#
# Runs each pane script with a fake osascript first on PATH. The fake records
# what it was sent and answers from a canned file, so these tests need no
# iTerm2 and open no pane. The live smoke test is tests/live/iterm-pane.sh.
#
# Usage: sh tests/iterm-pane.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
skill="$root/plugins/mp-ported-skills/skills/iterm-pane"
scripts="$skill/scripts"
work=$(mktemp -d)
trap 'command rm -rf "$work"' EXIT

pass=0 fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}

# The fake osascript: appends its -e arguments and its stdin to $FAKE_OSA_LOG,
# prints $FAKE_OSA_OUT (a file) and exits $FAKE_OSA_RC. A non-zero exit prints
# iTerm2's error for a missing session to stderr, as the real one does.
bin="$work/bin"; mkdir -p "$bin"
command cat > "$bin/osascript" <<'EOF'
#!/bin/sh
for a in "$@"; do [ "$a" = -e ] || printf '%s\n' "$a" >> "$FAKE_OSA_LOG"; done
[ -t 0 ] || command cat >> "$FAKE_OSA_LOG"
if [ "${FAKE_OSA_RC:-0}" -ne 0 ]; then
    printf '%s\n' "execution error: iTerm got an error: Can't get session id \"X\". (-1728)" >&2
    exit "$FAKE_OSA_RC"
fi
[ -n "${FAKE_OSA_OUT:-}" ] && command cat "$FAKE_OSA_OUT"
exit 0
EOF
chmod +x "$bin/osascript"

# The fake ps, for pane-open.sh's walk up to its caller's TTY: every process
# is on $FAKE_PS_TTY ("??" means none) and its parent is init.
command cat > "$bin/ps" <<'EOF'
#!/bin/sh
case "$*" in
    *tty=*)  printf '%s\n' "$FAKE_PS_TTY" ;;
    *ppid=*) printf '1\n' ;;
esac
EOF
chmod +x "$bin/ps"
FAKE_PS_TTY=ttys001; export FAKE_PS_TTY

export FAKE_OSA_LOG="$work/osa.log"
unset FAKE_OSA_OUT FAKE_OSA_RC 2>/dev/null || true
PATH="$bin:$PATH"; export PATH

answer() { printf '%s' "$1" > "$work/answer"; FAKE_OSA_OUT="$work/answer"; export FAKE_OSA_OUT; }
reset() { : > "$FAKE_OSA_LOG"; unset FAKE_OSA_OUT FAKE_OSA_RC 2>/dev/null || true; }
run() { # <script> <args...>: stdout, then stderr, then the exit status
    s=$1; shift
    sh "$scripts/$s" "$@" </dev/null > "$work/out" 2> "$work/err"; rc=$?
}
out() { command cat "$work/out"; }
err() { command cat "$work/err"; }
sent() { command cat "$FAKE_OSA_LOG"; }
pane='--session ABC-123 --window 7 --tab 2'

# --- arguments, for every script that targets one pane ---
for s in pane-read.sh pane-send.sh pane-close.sh; do
    reset; run "$s" --help
    check "$s --help: exit 0" 0 "$rc"
    check "$s --help: usage" "Usage: $s" "$(out | head -1 | cut -d' ' -f1-2)"

    reset; run "$s" --session ABC-123 --window 7
    check "$s, no --tab: exit 1" 1 "$rc"
    check "$s, no --tab: says what is required" \
        'Error: --session, --window, and --tab are required' "$(err)"

    reset; run "$s" --session 'x" to quit' --window 7 --tab 2
    check "$s, quote in --session: refused" 'Error: invalid --session: x" to quit' "$(err)"
    reset; run "$s" --session ABC --window '7 to quit' --tab 2
    check "$s, non-numeric --window: refused" 'Error: invalid --window: 7 to quit' "$(err)"
    reset; run "$s" --session ABC --window 7 --tab 2x
    check "$s, non-numeric --tab: refused" 'Error: invalid --tab: 2x' "$(err)"
    check "$s, bad coordinates: osascript never runs" '' "$(sent)"

    reset; run "$s" $pane --bogus
    check "$s, unknown option: exit 1" 1 "$rc"
    check "$s, unknown option: named" 'Unknown option: --bogus' "$(err)"

    reset; run "$s" $pane --session
    check "$s, flag with no value: exit 1" 1 "$rc"
    check "$s, flag with no value: named" 'Error: --session needs a value' "$(err)"
done

# --- read ---
reset; answer 'line one
line two
line three


'
run pane-read.sh $pane
check "read: trailing blank lines trimmed" 'line one
line two
line three' "$(out)"
check "read: exit 0" 0 "$rc"
check "read: asks the named pane for its contents" \
    'tell application "iTerm2" to tell session id "ABC-123" of tab 2 of window id 7 to get contents' "$(sent)"

reset; answer 'a
b
c
'
run pane-read.sh $pane --lines 2
check "read --lines: last N lines" 'b
c' "$(out)"

reset; run pane-read.sh $pane --lines ten
check "read --lines not a number: refused" 'Error: invalid --lines: ten' "$(err)"

reset; FAKE_OSA_RC=1; export FAKE_OSA_RC
run pane-read.sh $pane
check "read, pane gone: exit 1" 1 "$rc"
check "read, pane gone: says so" \
    'pane-read.sh: no pane with session ABC-123 in tab 2 of window 7 (closed, or wrong coordinates)' "$(err)"
check "read, pane gone: nothing on stdout" '' "$(out)"

# --- send ---
tell='tell application "iTerm2" to tell session id "ABC-123" of tab 2 of window id 7 to'
reset; run pane-send.sh $pane --text 'echo "a\b" $HOME !! `id`'
check "send --text: quotes and backslashes escaped, the rest verbatim" \
    "$tell write text \"echo \\\"a\\\\b\\\" \$HOME !! \`id\`\"" "$(sent)"
check "send --text: exit 0" 0 "$rc"

reset; run pane-send.sh $pane --key return
check "send --key return: an empty line" "$tell write text \"\" with newline" "$(sent)"
reset; run pane-send.sh $pane --key tab
check "send --key tab" "$tell write text (ASCII character 9) without newline" "$(sent)"
reset; run pane-send.sh $pane --key y
check "send --key: typed without newline" "$tell write text \"y\" without newline" "$(sent)"
reset; run pane-send.sh $pane --control c
check "send --control c" "$tell write text (ASCII character 3)" "$(sent)"
reset; run pane-send.sh $pane --escape
check "send --escape" "$tell write text (ASCII character 27) without newline" "$(sent)"

reset; run pane-send.sh $pane --control q
check "send --control, unsupported: exit 1" 1 "$rc"
check "send --control, unsupported: named" \
    'Unknown control character: q (supported: c, z, d, l)' "$(err)"
reset; run pane-send.sh $pane
check "send, nothing to send: exit 1" 1 "$rc"
check "send, nothing to send: says so" \
    'Error: specify --text, --key, --control, or --escape' "$(err)"

reset; FAKE_OSA_RC=1; export FAKE_OSA_RC
run pane-send.sh $pane --text hi
check "send, pane gone: says so" \
    'pane-send.sh: no pane with session ABC-123 in tab 2 of window 7 (closed, or wrong coordinates)' "$(err)"

# --- close ---
reset; run pane-close.sh $pane
check "close without --force: exit 2" 2 "$rc"
check "close without --force: refused, and why" \
    'REFUSED: pane-close.sh cannot yet tell whether a session in the pane is busy. Check the pane, then use --force.' "$(err)"
check "close without --force: pane untouched" '' "$(sent)"

reset; run pane-close.sh $pane --force
check "close --force: closes the pane" "$tell close" "$(sent)"
check "close --force: exit 0" 0 "$rc"

reset; FAKE_OSA_RC=1; export FAKE_OSA_RC
run pane-close.sh $pane --force
check "close --force, pane gone: exit 1" 1 "$rc"
check "close --force, pane gone: says so" \
    'pane-close.sh: no pane with session ABC-123 in tab 2 of window 7 (closed, or wrong coordinates)' "$(err)"

# --- find ---
panes='W:7 T:1 S:AAAA-1111 Name:zsh
W:7 T:2 S:BBBB-2222 Name:claude (main)
W:9 T:1 S:BBBB-3333 Name:vim notes.md
'
reset; answer "$panes"
run pane-find.sh --session 1111
check "find, one match: SESSION_ID WINDOW_ID TAB_NUM" 'AAAA-1111 7 1' "$(out)"
check "find, one match: exit 0" 0 "$rc"

reset; answer "$panes"
run pane-find.sh --session BBBB
check "find, two matches: one line each, with the name" 'BBBB-2222 7 2 claude (main)
BBBB-3333 9 1 vim notes.md' "$(out)"
check "find, two matches: says so on stderr" "Multiple sessions match 'BBBB':" "$(err)"

reset; answer 'W:7 T:3 S:DDDD-4444 Name:ssh T:9 S:x
'
run pane-find.sh --session DDDD
check "find: a name holding T: and S: does not skew the fields" 'DDDD-4444 7 3' "$(out)"

reset; answer "$panes"
run pane-find.sh --session 7
check "find: matches the session id only, not the window" 1 "$rc"

reset; answer "$panes"
run pane-find.sh --session CCCC
check "find, no match: exit 1" 1 "$rc"
check "find, no match: says so" "Error: no session found matching 'CCCC'" "$(err | head -1)"

reset; answer ''
run pane-find.sh --session AAAA
check "find, no sessions at all: exit 1" 1 "$rc"
check "find, no sessions at all: says so" 'Error: no iTerm2 sessions found (is iTerm2 running?)' "$(err)"

reset; FAKE_OSA_RC=1; export FAKE_OSA_RC
run pane-find.sh --session AAAA
check "find, iTerm2 cannot be asked: exit 1" 1 "$rc"
check "find, iTerm2 cannot be asked: says so, with osascript's reason" \
    'Error: could not list iTerm2 sessions: execution error: iTerm got an error: Can'"'"'t get session id "X". (-1728)' "$(err)"

reset; run pane-find.sh
check "find, no --session: exit 1" 1 "$rc"
reset; run pane-find.sh --session
check "find, --session with no value: named" 'Error: --session needs a value' "$(err)"
reset; run pane-find.sh --help
check "find --help: exit 0" 0 "$rc"

# --- tty ---
reset; answer '/dev/ttys042'
run pane-tty.sh ABC-123
check "tty: prints the pane's TTY" '/dev/ttys042' "$(out)"
check "tty: looks up the session by the id the other scripts use" 1 "$(sent | grep -c 'if id of s is "ABC-123" then')"

reset; answer ''
run pane-tty.sh ABC-123
check "tty, no such session: empty output" '' "$(out)"
check "tty, no such session: exit 0" 0 "$rc"

reset; run pane-tty.sh --help
check "tty --help: exit 0" 0 "$rc"
check "tty --help: usage" 'Usage: pane-tty.sh SESSION_ID' "$(out | head -1)"
check "tty --help: osascript never runs" '' "$(sent)"

reset; run pane-tty.sh
check "tty, no id: exit 1" 1 "$rc"
check "tty, no id: usage" 'Usage: pane-tty.sh SESSION_ID' "$(err)"
reset; run pane-tty.sh 'x" then'
check "tty, quote in id: refused" 'Error: invalid session id: x" then' "$(err)"
check "tty, quote in id: osascript never runs" '' "$(sent)"

# --- open ---
reset; answer 'NEW-1 7 2'
run pane-open.sh
check "open: prints the new pane's coordinates" 'NEW-1 7 2' "$(out)"
check "open: exit 0" 0 "$rc"
check "open: finds the caller's pane by its TTY" 1 "$(sent | grep -c 'set targetTTY to "/dev/ttys001"')"
check "open: splits vertically by default" 1 "$(sent | grep -c 'split vertically with default profile')"

reset; answer 'NEW-1 7 2'
run pane-open.sh --direction horizontal
check "open --direction horizontal: split horizontally (new pane below)" 1 \
    "$(sent | grep -c 'split horizontally with default profile')"

reset; answer 'NEW-1 7 2'
run pane-open.sh --profile 'Hot "Dog"'
check "open --profile: quotes escaped" 1 "$(sent | grep -c 'split vertically with profile "Hot \\"Dog\\""')"

reset; run pane-open.sh --direction diagonal
check "open, bad direction: exit 1" 1 "$rc"
check "open, bad direction: named" 'Invalid direction: diagonal (use vertical or horizontal)' "$(err)"
check "open, bad direction: osascript never runs" '' "$(sent)"

reset; answer 'NEW-1 7 2'
run pane-open.sh --command 'ls -la'
check "open --command: prints the coordinates" 'NEW-1 7 2' "$(out)"
check "open --command: typed into the new pane" 1 \
    "$(sent | grep -c 'tell session id "NEW-1" of tab 2 of window id 7 to write text "ls -la"')"

reset; FAKE_OSA_RC=1; export FAKE_OSA_RC
run pane-open.sh
check "open, iTerm2 fails: exit 1" 1 "$rc"
check "open, iTerm2 fails: says so, with osascript's reason" \
    'Error: could not open a pane: execution error: iTerm got an error: Can'"'"'t get session id "X". (-1728)' "$(err)"

reset; FAKE_PS_TTY='??'
run pane-open.sh
check "open, no TTY above the caller: exit 1" 1 "$rc"
check "open, no TTY above the caller: says so" 'Error: could not determine calling TTY' "$(err)"
FAKE_PS_TTY=ttys001

reset; run pane-open.sh --direction
check "open, flag with no value: named" 'Error: --direction needs a value' "$(err)"
reset; run pane-open.sh --help
check "open --help: exit 0" 0 "$rc"

# --- the skill's content ---
for f in "$scripts"/*.sh; do
    sh -n "$f" 2>/dev/null; rc=$?
    check "sh -n ${f##*/}" 0 "$rc"
done
# A default-profile path, a named agent role, a private host or a pane-state
# file: the upstream skill's setup, which this port leaves behind.
leaks=$(grep -rnE '~/\.claude|HOME/\.claude|/Users/|\.local\b|--agent|pane-launch-agent|pane-verify|\.state/|pane-state' "$skill")
check "no default-profile paths, agent roles, private hosts or state files" '' "$leaks"

echo "iterm-pane: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
