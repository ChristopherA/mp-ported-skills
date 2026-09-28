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
# $FAKE_OSA_MSG to stderr, by default iTerm2's error for a missing session.
bin="$work/bin"; mkdir -p "$bin"
command cat > "$bin/osascript" <<'EOF'
#!/bin/sh
for a in "$@"; do [ "$a" = -e ] || printf '%s\n' "$a" >> "$FAKE_OSA_LOG"; done
[ -t 0 ] || command cat >> "$FAKE_OSA_LOG"
if [ "${FAKE_OSA_RC:-0}" -ne 0 ]; then
    msg="execution error: iTerm got an error: Can't get session id \"X\". (-1728)"
    printf '%s\n' "${FAKE_OSA_MSG:-$msg}" >&2
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
unset FAKE_OSA_OUT FAKE_OSA_RC FAKE_OSA_MSG 2>/dev/null || true
PATH="$bin:$PATH"; export PATH

answer() { printf '%s' "$1" > "$work/answer"; FAKE_OSA_OUT="$work/answer"; export FAKE_OSA_OUT; }
reset() { : > "$FAKE_OSA_LOG"; unset FAKE_OSA_OUT FAKE_OSA_RC FAKE_OSA_MSG 2>/dev/null || true; }
run() { # <script> <args...>: stdout, then stderr, then the exit status
    s=$1; shift
    sh "$scripts/$s" "$@" </dev/null > "$work/out" 2> "$work/err"; rc=$?
}
out() { command cat "$work/out"; }
err() { command cat "$work/err"; }
sent() { command cat "$FAKE_OSA_LOG"; }
pane='--session ABC-123 --window 7 --tab 2'

# --- arguments, for every script that targets one pane ---
for s in pane-read.sh pane-send.sh pane-close.sh pane-classify.sh pane-wait.sh; do
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

reset; answer 'prompt % echo hi 
hi 
prompt %  
'
run pane-read.sh $pane
check "read: iTerm2's trailing padding stripped from each line" 'prompt % echo hi
hi
prompt %' "$(out)"

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

# --- classify ---
# Every live capture classifies as the state its file name says.
fixtures="$root/tests/fixtures/pane-states"
for f in "$fixtures"/*.txt; do
    name=${f##*/}
    state=${name%.txt}; state=${state%%-*}
    reset; run pane-classify.sh --file "$f"
    check "classify $name" "$state" "$(out)"
    sh "$scripts/pane-classify.sh" --file - < "$f" > "$work/out" 2>/dev/null
    check "classify $name from stdin" "$state" "$(out)"
done
# The captures come from Opus and Fable; none of the rules reads the model.
check "classify: no rule names a model" '' \
    "$(grep -nE 'Opus|Sonnet|Haiku|Fable' "$scripts/pane-classify.sh")"

# A shell whose scrollback still holds a finished session and its model tag.
{ command cat "$fixtures/waiting-after-reply-opus.txt"; printf '%s\n' 'user@workstation project % claude --resume' 'user@workstation project %'; } > "$work/old-session.txt"
reset; run pane-classify.sh --file "$work/old-session.txt"
check "classify: shell below an old session's [Opus tag" shell "$(out)"

# classify_text <text>: classify a capture built here, from stdin.
classify_text() { printf '%s\n' "$1" | sh "$scripts/pane-classify.sh" --file - 2>&1; }
box='───────────────────────── project ─
❯
─────────────────────────
  [Model|medium] 35% of zone'
check "classify: a program running with no prompt last is working, not shell" working \
    "$(classify_text 'user@workstation project % make
building...')"
check "classify: a sudo password prompt is working, not shell" working "$(classify_text 'Password:')"
check "classify: an empty capture is working, not shell" working "$(classify_text '')"
check "classify: a prompt starting with ❯ is a shell" shell "$(classify_text '~/src/project
❯ ls
a b
❯')"
check "classify: a turn interrupted with Esc is waiting" waiting "$(classify_text "❯ Write a story
  ⎿  Interrupted · What should Claude do instead?

$box")"
check "classify: a turn ended by an API error is waiting" waiting "$(classify_text "❯ hi
  ⎿  API Error: 529 Overloaded

$box")"
check "classify: extra footer lines under the box are still the session" waiting \
    "$(classify_text "$(command cat "$fixtures/waiting-opus.txt")
  one
  two
  three
  four
  five")"

# The live path reads the pane through pane-read.sh.
reset; FAKE_OSA_OUT="$fixtures/asking-trust.txt"; export FAKE_OSA_OUT
run pane-classify.sh $pane
check "classify, live pane: read through pane-read" asking "$(out)"
check "classify, live pane: asks the named pane for its contents" \
    'tell application "iTerm2" to tell session id "ABC-123" of tab 2 of window id 7 to get contents' "$(sent)"

reset; FAKE_OSA_RC=1; export FAKE_OSA_RC
run pane-classify.sh $pane
check "classify, pane closed: gone" gone "$(out)"
check "classify, pane closed: exit 0" 0 "$rc"

reset; FAKE_OSA_RC=1; FAKE_OSA_MSG='execution error: iTerm got an error: AppleEvent timed out. (-1712)'; export FAKE_OSA_RC FAKE_OSA_MSG
run pane-classify.sh $pane
check "classify, iTerm2 cannot be asked: exit 1" 1 "$rc"
check "classify, iTerm2 cannot be asked: osascript's reason" \
    'pane-read.sh: execution error: iTerm got an error: AppleEvent timed out. (-1712)' "$(err)"

reset; run pane-classify.sh --file "$work/missing.txt"
check "classify, missing file: exit 1" 1 "$rc"
reset; run pane-classify.sh --file - $pane
check "classify, --file and coordinates: refused" 'Error: give --file or the pane coordinates, not both' "$(err)"

# --- wait ---
reset; FAKE_OSA_OUT="$fixtures/waiting-opus.txt"; export FAKE_OSA_OUT
run pane-wait.sh $pane --state asking,waiting --timeout 5
check "wait, state reached: prints it" waiting "$(out)"
check "wait, state reached: exit 0" 0 "$rc"

reset; FAKE_OSA_OUT="$fixtures/working-streaming-opus.txt"; export FAKE_OSA_OUT
run pane-wait.sh $pane --state waiting --timeout 1 --interval 1
check "wait, timeout: exit 124" 124 "$rc"
check "wait, timeout: prints the last state seen" working "$(out)"
check "wait, timeout: says so" \
    'pane-wait.sh: timed out after 1s waiting for waiting; last state: working' "$(err)"

reset; FAKE_OSA_RC=1; export FAKE_OSA_RC
run pane-wait.sh $pane --state gone --timeout 0
check "wait for gone: reached when the pane closes" gone "$(out)"

reset; FAKE_OSA_RC=1; FAKE_OSA_MSG='execution error: AppleEvent timed out. (-1712)'; export FAKE_OSA_RC FAKE_OSA_MSG
run pane-wait.sh $pane --state waiting --timeout 0
check "wait, pane cannot be read: exit 1" 1 "$rc"
check "wait, pane cannot be read: says so" \
    "pane-wait.sh: could not read the pane's state; last state: none" "$(err | tail -1)"

reset; run pane-wait.sh $pane
check "wait, no --state: named" 'Error: --state is required' "$(err)"
reset; run pane-wait.sh $pane --state idle
check "wait, unknown state: named" 'Error: unknown state: idle (use working, waiting, asking, shell, gone)' "$(err)"
check "wait, bad arguments: osascript never runs" '' "$(sent)"
reset; run pane-wait.sh $pane --state waiting --timeout soon
check "wait, bad --timeout: named" 'Error: invalid --timeout: soon' "$(err)"
reset; run pane-wait.sh $pane --state waiting --interval 0
check "wait, zero --interval: refused" 'Error: invalid --interval: 0' "$(err)"

# --- close ---
for st in working waiting asking; do
    reset; FAKE_OSA_OUT=$(ls "$fixtures/$st"-*.txt | head -1); export FAKE_OSA_OUT
    run pane-close.sh $pane
    check "close without --force, $st: exit 2" 2 "$rc"
    check "close without --force, $st: refused, and why" \
        "REFUSED: a Claude Code session in the pane is $st. End it, or use --force." "$(err)"
    check "close without --force, $st: pane untouched" 0 "$(sent | grep -c 'to close')"
done

reset; FAKE_OSA_OUT="$fixtures/shell-after-exit-opus.txt"; export FAKE_OSA_OUT
run pane-close.sh $pane
check "close without --force, shell: closes the pane" 1 "$(sent | grep -cx "$tell close")"
check "close without --force, shell: exit 0" 0 "$rc"

reset; FAKE_OSA_RC=1; export FAKE_OSA_RC
run pane-close.sh $pane
check "close without --force, gone: exit 0" 0 "$rc"
check "close without --force, gone: says so" 'gone: the pane is already closed' "$(out)"

reset; answer 'user@workstation project % make
building...'
run pane-close.sh $pane
check "close without --force, a program running: exit 2" 2 "$rc"
check "close without --force, a program running: pane untouched" 0 "$(sent | grep -c 'to close')"

reset; FAKE_OSA_RC=1; FAKE_OSA_MSG='execution error: AppleEvent timed out. (-1712)'; export FAKE_OSA_RC FAKE_OSA_MSG
run pane-close.sh $pane
check "close without --force, pane cannot be read: exit 1" 1 "$rc"
check "close without --force, pane cannot be read: says so" \
    "pane-close.sh: could not read the pane's state, so it stays open" "$(err | tail -1)"

reset; run pane-close.sh $pane --force
check "close --force: closes the pane without reading it" "$tell close" "$(sent)"
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

# --- launch ---
# typed: the line pane-launch.sh typed into the new pane, unescaped from the
# AppleScript string it was sent in.
typed() {
    sent | sed -n 's/^tell application "iTerm2" to tell session id "NEW-1" of tab 2 of window id 7 to write text "\(.*\)"$/\1/p' |
        sed 's/\\"/"/g; s/\\\\/\\/g'
}
# in_pane: run the typed line as the pane's interactive zsh would, history
# expansion included, with a fake claude that records its directory and each
# argument on its own line.
in_pane() {
    command rm -f "$work/claude.args"
    typed > "$work/line"
    PATH="$work/pane-bin:$PATH" zsh -f -i < "$work/line" >/dev/null 2>&1
    command cat "$work/claude.args" 2>/dev/null
}
mkdir -p "$work/pane-bin" "$work/proj dir"
command cat > "$work/pane-bin/claude" <<EOF
#!/bin/sh
pwd > "$work/claude.args"
for a in "\$@"; do printf '[%s]\n' "\$a" >> "$work/claude.args"; done
EOF
chmod +x "$work/pane-bin/claude"
proj="$work/proj dir"

reset; answer 'NEW-1 7 2'
run pane-launch.sh --dir "$proj"
check "launch: prints the new pane's coordinates only" 'NEW-1 7 2' "$(out)"
check "launch: exit 0" 0 "$rc"
check "launch: splits vertically by default" 1 "$(sent | grep -c 'split vertically with default profile')"
check "launch: starts plain claude in the directory" "$proj" "$(in_pane)"

reset; answer 'NEW-1 7 2'
run pane-launch.sh --dir "$proj" --direction horizontal --permission-mode acceptEdits
check "launch --direction horizontal: split horizontally" 1 "$(sent | grep -c 'split horizontally with default profile')"
check "launch --permission-mode: passed to claude" "$proj
[--permission-mode]
[acceptEdits]" "$(in_pane)"

msg='Say "hi" & it'"'"'s $HOME, `date`, !! and !x done'
reset; answer 'NEW-1 7 2'
run pane-launch.sh --dir "$proj" --message "$msg"
check "launch --message: reaches claude intact" "$proj
[--]
[$msg]" "$(in_pane)"

reset; answer 'NEW-1 7 2'
run pane-launch.sh --message "$msg" --permission-mode plan --dir "$proj"
check "launch, every option: mode then message" "$proj
[--permission-mode]
[plan]
[--]
[$msg]" "$(in_pane)"

reset; answer 'NEW-1 7 2'
run pane-launch.sh --dir "$proj" --message '-p hi'
check "launch --message starting with -: a message, not a flag" "$proj
[--]
[-p hi]" "$(in_pane)"

# A relative --dir resolves against the caller's directory, not CDPATH's.
mkdir -p "$work/elsewhere/proj dir"
reset; answer 'NEW-1 7 2'
(cd "$work" && CDPATH="$work/elsewhere" sh "$scripts/pane-launch.sh" --dir 'proj dir' </dev/null >/dev/null 2>&1)
check "launch, relative --dir with CDPATH set: the caller's directory" "$proj" "$(in_pane)"

reset; run pane-launch.sh
check "launch, no --dir: exit 1" 1 "$rc"
check "launch, no --dir: named" 'Error: --dir is required' "$(err)"
check "launch, no --dir: no pane opens" '' "$(sent)"

reset; run pane-launch.sh --dir "$work/missing"
check "launch, missing --dir: exit 1" 1 "$rc"
check "launch, missing --dir: named" "Error: not a directory: $work/missing" "$(err)"
check "launch, missing --dir: no pane opens" '' "$(sent)"

reset; run pane-launch.sh --dir "$work/answer"
check "launch, --dir is a file: exit 1" 1 "$rc"
check "launch, --dir is a file: no pane opens" '' "$(sent)"

reset; run pane-launch.sh --dir "$proj" --direction diagonal
check "launch, bad direction: exit 1" 1 "$rc"
check "launch, bad direction: no pane opens" '' "$(sent)"

reset; run pane-launch.sh --dir "$proj" --worktree x
check "launch, unknown option: exit 1" 1 "$rc"
check "launch, unknown option: no pane opens" '' "$(sent)"

reset; run pane-launch.sh --dir
check "launch, flag with no value: named" 'Error: --dir needs a value' "$(err)"
reset; run pane-launch.sh --help
check "launch --help: exit 0" 0 "$rc"
check "launch --help: usage" "Usage: pane-launch.sh" "$(out | head -1 | cut -d' ' -f1-2)"

# No state file: a launch leaves the working and temp directories as they were.
before=$(ls -A "$work" "${TMPDIR:-/tmp}" 2>/dev/null)
reset; answer 'NEW-1 7 2'
run pane-launch.sh --dir "$proj" --message hi
check "launch: writes no file outside the pane" "$before" "$(ls -A "$work" "${TMPDIR:-/tmp}" 2>/dev/null)"

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
