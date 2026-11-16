#!/bin/sh
# supervise-view-iterm.test.sh -- tests for view.sh's iTerm2 mode, which
# opens a split pane running `claude attach <id>` for `--watch iterm` (#102).
#
# MP_PANE_DIR points view.sh at fake pane-open.sh, pane-find.sh,
# pane-classify.sh and pane-close.sh, so no pane opens and iTerm2 is never
# driven. The fakes record their arguments; pane-classify.sh prints what the
# test wrote to its state file, and pane-find.sh what it wrote to its find
# file. The last section runs the real iterm-pane scripts on a stubbed
# osascript instead, as the 2026-10-17 run met them (#200). Touches nothing
# outside its own mktemp directory.
#
# Usage: sh tests/supervise-view-iterm.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scripts="$root/plugins/mp-ported-skills/skills/supervise/scripts"

work=$(mktemp -d)
work=$(CDPATH= cd -- "$work" && pwd -P)
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

# Every variable the script reads, set or unset here.
unset TMUX TMUX_PANE ITERM_SESSION_ID CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ATTENDED
export TERM_PROGRAM=iTerm.app LC_TERMINAL=iTerm2
export CLAUDE_CONFIG_DIR="$work/config it's"
mkdir -p "$CLAUDE_CONFIG_DIR"
export MP_VIEW_WAIT=0

fake="$work/fake"
panes="$work/panes"
mkdir -p "$work/bin" "$fake" "$panes"
export MP_PANE_DIR="$panes"
cat >"$panes/pane-open.sh" <<EOF
#!/bin/sh
echo "open \$*" >>"$fake/calls"
if [ -f "$fake/open-fails" ]; then
    echo "Error: could not determine calling TTY" >&2
    exit 1
fi
echo "F1C3A2B4-0D6E 4242 2"
# A pane split, then the command could not be typed into it (#200).
if [ -f "$fake/send-fails" ]; then
    echo "pane-send.sh: no pane with session F1C3A2B4-0D6E in tab 2 of window 4242 (closed, or wrong coordinates)" >&2
    exit 1
fi
EOF
# pane-find.sh: by default the pane is where pane-open.sh said; the find file
# moves it, and find-fails makes iTerm2 unreachable. find-then lists the pane
# once, then turns on the switch it names (find-none, find-fails) for later
# calls, as a pane that closes by itself during the call reads.
cat >"$panes/pane-find.sh" <<EOF
#!/bin/sh
echo "find \$*" >>"$fake/calls"
if [ -f "$fake/find-fails" ]; then
    echo "Error: could not list iTerm2 sessions: execution error: iTerm got an error (-600)" >&2
    exit 1
fi
if [ -f "$fake/find-then" ]; then
    touch "$fake/\$(command cat "$fake/find-then")"
    command rm -f "$fake/find-then"
    echo "F1C3A2B4-0D6E 4242 2"
    exit 0
fi
if [ -f "$fake/find" ]; then
    command cat "$fake/find"
    exit 0
fi
if [ -f "$fake/find-none" ]; then
    echo "Error: no session found matching '\$2'" >&2
    echo "Hint: pass a substring of the session id pane-open.sh printed" >&2
    exit 1
fi
echo "F1C3A2B4-0D6E 4242 2"
EOF
cat >"$panes/pane-classify.sh" <<EOF
#!/bin/sh
echo "classify \$*" >>"$fake/calls"
command cat "$fake/state" 2>/dev/null || echo working
EOF
cat >"$panes/pane-close.sh" <<EOF
#!/bin/sh
echo "close \$*" >>"$fake/calls"
[ ! -f "$fake/close-fails" ] || exit 1
EOF
# pane-tty.sh: the pane's TTY, or nothing when iTerm2 cannot say (tty-none).
cat >"$panes/pane-tty.sh" <<EOF
#!/bin/sh
echo "tty \$*" >>"$fake/calls"
[ -f "$fake/tty-none" ] || printf /dev/ttys042
EOF
# ps -t: the processes on the pane's TTY, from the procs file, or by default
# the login shell exec'd into claude attach for the test's id.
cat >"$work/bin/ps" <<EOF
#!/bin/sh
echo "ps \$*" >>"$fake/calls"
[ "\$1 \$2" = "-t /dev/ttys042" ] || exit 1
if [ -f "$fake/procs" ]; then command cat "$fake/procs"; exit 0; fi
echo "$work/bin/claude attach c2a368ee"
EOF
chmod +x "$work/bin/ps"
cat >"$work/bin/claude" <<'EOF'
#!/bin/sh
echo "fake claude: never run by view.sh" >&2
exit 2
EOF
chmod +x "$work/bin/claude" "$panes"/*.sh
PATH="$work/bin:$PATH"
export PATH
[ "$(command -v claude)" = "$work/bin/claude" ] || { echo "FAIL the fake claude is not first on PATH"; exit 1; }

project="$work/project"
mkdir -p "$project"
view() { sh "$scripts/view.sh" "$@" </dev/null 2>&1; }
calls() { command cat "$fake/calls" 2>/dev/null; command rm -f "$fake/calls"; }
id=c2a368ee

# --- open ------------------------------------------------------------------
out=$(view --iterm --id $id --dir "$project")
rc=$?
check "open: exit 0" 0 "$rc"
check "open: names the pane and how to close it" "viewer iterm pane F1C3A2B4-0D6E 4242 2 runs claude attach $id
close: view.sh --close --pane 'F1C3A2B4-0D6E 4242 2'" "$out"
check "open: splits this session's pane with claude attach under this profile, then checks it" \
    "open --direction vertical --command cd '$project' && exec env CLAUDE_CONFIG_DIR='$work/config it'\\''s' '$work/bin/claude' attach $id
find --session F1C3A2B4-0D6E
classify --session F1C3A2B4-0D6E --window 4242 --tab 2
tty F1C3A2B4-0D6E
ps -t /dev/ttys042 -o args=" "$(calls)"

# pane-open.sh named the wrong window: the pane is reported, and checked,
# where iTerm2 holds it (#200).
echo "F1C3A2B4-0D6E 28142 1" >"$fake/find"
out=$(view --iterm --id $id --dir "$project"); rc=$?
check "open, other window: exit 0" 0 "$rc"
check "open, other window: names the window that holds the pane" "viewer iterm pane F1C3A2B4-0D6E 28142 1 runs claude attach $id
close: view.sh --close --pane 'F1C3A2B4-0D6E 28142 1'" "$out"
check "open, other window: checks the pane there" "classify --session F1C3A2B4-0D6E --window 28142 --tab 1" "$(calls | grep '^classify')"
# A match on part of the id is another pane, not this one.
echo "F1C3A2B4-0D6E-9 28142 1" >"$fake/find"
out=$(view --iterm --id $id --dir "$project"); rc=$?
check "open, only a longer id matches: the pane is gone" "Error: claude attach $id exited at once, so no viewer is open; watch with claude attach $id" "$out"
check "open, only a longer id matches: nothing classified or closed" 0 "$(calls | grep -c '^classify\|^close')"
command rm -f "$fake/find"
# iTerm2 cannot list its panes: the printed coordinates stand.
touch "$fake/find-fails"
out=$(view --iterm --id $id --dir "$project"); rc=$?
check "open, find fails: exit 0" 0 "$rc"
check "open, find fails: keeps pane-open.sh's coordinates" "viewer iterm pane F1C3A2B4-0D6E 4242 2 runs claude attach $id" "$(printf '%s\n' "$out" | head -n 1)"
command rm -f "$fake/find-fails"
calls >/dev/null

# --- a pane split, but claude attach was never typed into it (#200) ----------
touch "$fake/send-fails"
echo "F1C3A2B4-0D6E 28142 1" >"$fake/find"
out=$(view --iterm --id $id --dir "$project"); rc=$?
check "split, send fails: exit 1" 1 "$rc"
check "split, send fails: says so, and that the pane was closed" "Error: claude attach did not start in the pane iTerm2 split (pane-send.sh: no pane with session F1C3A2B4-0D6E in tab 2 of window 4242 (closed, or wrong coordinates)), so the pane was closed; watch with claude attach $id" "$out"
check "split, send fails: finds the pane by its id and closes it where it is" "find --session F1C3A2B4-0D6E
close --session F1C3A2B4-0D6E --window 28142 --tab 1 --force" "$(calls | grep -v '^open')"
touch "$fake/close-fails"
out=$(view --iterm --id $id --dir "$project"); rc=$?
check "split, send and close fail: exit 1" 1 "$rc"
check "split, send and close fail: names the pane's real coordinates" "Error: claude attach did not start in the pane iTerm2 split (pane-send.sh: no pane with session F1C3A2B4-0D6E in tab 2 of window 4242 (closed, or wrong coordinates)), and it could not be closed: view.sh --close --pane 'F1C3A2B4-0D6E 28142 1'; watch with claude attach $id" "$out"
command rm -f "$fake/close-fails" "$fake/find"
calls >/dev/null
touch "$fake/find-none"
out=$(view --iterm --id $id --dir "$project"); rc=$?
check "split, send fails, pane gone: exit 1" 1 "$rc"
check "split, send fails, pane gone: says the pane has closed" "Error: claude attach did not start in the pane iTerm2 split (pane-send.sh: no pane with session F1C3A2B4-0D6E in tab 2 of window 4242 (closed, or wrong coordinates)), and the pane has closed; watch with claude attach $id" "$out"
check "split, send fails, pane gone: closes nothing" 0 "$(calls | grep -c '^close')"
command rm -f "$fake/find-none"
# The pane closes by itself between the lookup and the close (#198).
touch "$fake/close-fails"
echo find-none >"$fake/find-then"
out=$(view --iterm --id $id --dir "$project"); rc=$?
check "split, send fails, pane closes during the close: exit 1" 1 "$rc"
check "split, send fails, pane closes during the close: says the pane has closed" "Error: claude attach did not start in the pane iTerm2 split (pane-send.sh: no pane with session F1C3A2B4-0D6E in tab 2 of window 4242 (closed, or wrong coordinates)), and the pane has closed; watch with claude attach $id" "$out"
check "split, send fails, pane closes during the close: looks again after the failed close" "find --session F1C3A2B4-0D6E
close --session F1C3A2B4-0D6E --window 4242 --tab 2 --force
find --session F1C3A2B4-0D6E" "$(calls | grep -v '^open')"
command rm -f "$fake/close-fails" "$fake/find-none" "$fake/find-then"
touch "$fake/find-fails"
out=$(view --iterm --id $id --dir "$project"); rc=$?
check "split, send and find fail: exit 1" 1 "$rc"
check "split, send and find fail: names the pane and why it was not found" "Error: claude attach did not start in the pane iTerm2 split (pane-send.sh: no pane with session F1C3A2B4-0D6E in tab 2 of window 4242 (closed, or wrong coordinates)), and iTerm2 could not say where pane F1C3A2B4-0D6E is (could not list iTerm2 sessions: execution error: iTerm got an error (-600)), so it may still be open; watch with claude attach $id" "$out"
check "split, send and find fail: closes nothing" 0 "$(calls | grep -c '^close')"
command rm -f "$fake/find-fails" "$fake/send-fails"

# claude attach exits at once: iTerm2 closed the pane, or it fell back to a shell.
echo gone >"$fake/state"
out=$(view --iterm --id $id --dir "$project"); rc=$?
check "attach fails, pane gone: exit 1" 1 "$rc"
check "attach fails, pane gone: says so" "Error: claude attach $id exited at once, so no viewer is open; watch with claude attach $id" "$out"
check "attach fails, pane gone: nothing to close" 0 "$(calls | grep -c '^close')"
echo shell >"$fake/state"
out=$(view --iterm --id $id --dir "$project"); rc=$?
check "attach fails, pane at a shell: exit 1" 1 "$rc"
check "attach fails, pane at a shell: closes the pane" "close --session F1C3A2B4-0D6E --window 4242 --tab 2 --force" "$(calls | grep '^close')"
command rm -f "$fake/state"

# The #123 run: a key typed during the split turned the line into `ocd ...`,
# and zsh stopped at its correction prompt. The screen ends in `[nyae]?`,
# which reads as a program running, so only the pane's TTY tells: no process
# there runs claude attach for this id (#146).
printf '%s\n' '/usr/bin/login -fpl someone /Applications/iTerm.app/Contents/MacOS/ShellLauncher --launch_shell' '-zsh' >"$fake/procs"
out=$(view --iterm --id $id --dir "$project"); rc=$?
check "attach never started, pane at a prompt: exit 1" 1 "$rc"
check "attach never started, pane at a prompt: says so" "Error: claude attach $id is not running in the pane (its shell holds it, at a prompt), so the pane was closed; watch with claude attach $id" "$out"
check "attach never started, pane at a prompt: closes the pane" "close --session F1C3A2B4-0D6E --window 4242 --tab 2 --force" "$(calls | grep '^close')"
touch "$fake/close-fails"
out=$(view --iterm --id $id --dir "$project"); rc=$?
check "attach never started, close fails: exit 1" 1 "$rc"
check "attach never started, close fails: names the pane to close" "Error: claude attach $id is not running in the pane (its shell holds it, at a prompt), and it could not be closed: view.sh --close --pane 'F1C3A2B4-0D6E 4242 2'; watch with claude attach $id" "$out"
command rm -f "$fake/close-fails"
calls >/dev/null
# A viewer for another worker's id is not this one's.
printf '%s\n' '-zsh' "$work/bin/claude attach c2a368ef" >"$fake/procs"
out=$(view --iterm --id $id --dir "$project"); rc=$?
check "attach for another id: exit 1" 1 "$rc"
command rm -f "$fake/procs"
calls >/dev/null
# iTerm2 cannot name the pane's TTY: the screen check stands.
touch "$fake/tty-none"
out=$(view --iterm --id $id --dir "$project"); rc=$?
check "no TTY for the pane: exit 0" 0 "$rc"
check "no TTY for the pane: reports the viewer" "viewer iterm pane F1C3A2B4-0D6E 4242 2 runs claude attach $id" "$(printf '%s\n' "$out" | head -n 1)"
check "no TTY for the pane: no ps read" 0 "$(calls | grep -c '^ps')"
command rm -f "$fake/tty-none"

# --- close -----------------------------------------------------------------
out=$(view --close --pane 'F1C3A2B4-0D6E 4242 2'); rc=$?
check "close: exit 0" 0 "$rc"
check "close: says so" "closed pane F1C3A2B4-0D6E" "$out"
check "close: finds the pane and closes it without asking what runs there" "find --session F1C3A2B4-0D6E
close --session F1C3A2B4-0D6E --window 4242 --tab 2 --force" "$(calls)"
# The coordinates name another window than the one holding the pane (#200).
echo "F1C3A2B4-0D6E 28142 1" >"$fake/find"
out=$(view --close --pane 'F1C3A2B4-0D6E 34630 1'); rc=$?
check "close, other window: exit 0" 0 "$rc"
check "close, other window: says so" "closed pane F1C3A2B4-0D6E" "$out"
check "close, other window: closes the pane where it is" "close --session F1C3A2B4-0D6E --window 28142 --tab 1 --force" "$(calls | grep '^close')"
command rm -f "$fake/find"
touch "$fake/find-none"
out=$(view --close --pane 'F1C3A2B4-0D6E 4242 2'); rc=$?
check "close, already gone: exit 0" 0 "$rc"
check "close, already gone: says so" "pane F1C3A2B4-0D6E already closed" "$out"
check "close, already gone: closes nothing" 0 "$(calls | grep -c '^close')"
command rm -f "$fake/find-none"
echo "F1C3A2B4-0D6E-9 28142 1" >"$fake/find"
out=$(view --close --pane 'F1C3A2B4-0D6E 4242 2'); rc=$?
check "close, only a longer id matches: already closed" "pane F1C3A2B4-0D6E already closed" "$out"
check "close, only a longer id matches: closes nothing" 0 "$(calls | grep -c '^close')"
command rm -f "$fake/find"
touch "$fake/find-fails"
out=$(view --close --pane 'F1C3A2B4-0D6E 4242 2'); rc=$?
check "close, find fails: exit 1" 1 "$rc"
check "close, find fails: does not call the pane closed" "Error: iTerm2 could not say where pane F1C3A2B4-0D6E is (could not list iTerm2 sessions: execution error: iTerm got an error (-600)), so it may still be open" "$out"
check "close, find fails: closes nothing" 0 "$(calls | grep -c '^close')"
command rm -f "$fake/find-fails"
touch "$fake/close-fails"
out=$(view --close --pane 'F1C3A2B4-0D6E 4242 2'); rc=$?
check "close, close fails: exit 1" 1 "$rc"
check "close, close fails: says so" "Error: iTerm2 could not close pane F1C3A2B4-0D6E" "$out"
check "close, close fails: looks for the pane again after the failed close" "find --session F1C3A2B4-0D6E
close --session F1C3A2B4-0D6E --window 4242 --tab 2 --force
find --session F1C3A2B4-0D6E" "$(calls)"
# The pane closes by itself between the lookup and the close (#198).
echo find-none >"$fake/find-then"
out=$(view --close --pane 'F1C3A2B4-0D6E 4242 2'); rc=$?
check "close, pane closes during the call: exit 0" 0 "$rc"
check "close, pane closes during the call: already closed" "pane F1C3A2B4-0D6E already closed" "$out"
check "close, pane closes during the call: looks again after the failed close" "find --session F1C3A2B4-0D6E
close --session F1C3A2B4-0D6E --window 4242 --tab 2 --force
find --session F1C3A2B4-0D6E" "$(calls)"
command rm -f "$fake/find-none" "$fake/find-then"
echo find-fails >"$fake/find-then"
out=$(view --close --pane 'F1C3A2B4-0D6E 4242 2'); rc=$?
check "close, close fails, second lookup fails: exit 1" 1 "$rc"
check "close, close fails, second lookup fails: keeps the error" "Error: iTerm2 could not close pane F1C3A2B4-0D6E" "$out"
command rm -f "$fake/close-fails" "$fake/find-fails" "$fake/find-then"
calls >/dev/null
out=$(view --close --pane 'F1C3A2B4-0D6E 4242'); rc=$?
check "close, bad pane: exit 1" 1 "$rc"
check "close, bad pane: says so" "Error: --pane needs 'SESSION WINDOW TAB', not 'F1C3A2B4-0D6E 4242'" "$out"
out=$(view --close --pane 'F1C3A2B4 4242 2;x'); rc=$?
check "close, bad tab: exit 1" 1 "$rc"
check "close, bad tab: says so" "Error: --pane needs 'SESSION WINDOW TAB', not 'F1C3A2B4 4242 2;x'" "$out"
out=$(view --close --iterm); rc=$?
check "close --iterm without a pane: exit 1" 1 "$rc"
check "close --iterm without a pane: says so" "Error: --close takes --pane, not --iterm, for an iTerm2 pane" "$out"
out=$(view --iterm --id $id --dir "$project" --pane 'F1C3A2B4-0D6E 4242 2'); rc=$?
check "pane without close: exit 1" 1 "$rc"
check "pane without close: says so" "Error: --pane goes with --close" "$out"
check "close, bad: touches no pane" "" "$(calls)"

# --- no pane possible: one line, no viewer ---------------------------------
out=$( (TMUX=/tmp/tmux-501/default,1,0; export TMUX; view --iterm --id $id --dir "$project") ); rc=$?
check "tmux around: exit 1" 1 "$rc"
check "tmux around: says so" "Error: this session runs inside tmux, so no iTerm2 pane can open; watch with claude attach $id" "$out"
out=$( (TERM_PROGRAM=Apple_Terminal LC_TERMINAL=; export TERM_PROGRAM LC_TERMINAL; view --iterm --id $id --dir "$project") ); rc=$?
check "not iTerm2: exit 1" 1 "$rc"
check "not iTerm2: says so" "Error: this session is not in iTerm2, so no pane can open; watch with claude attach $id" "$out"
out=$( (CLAUDE_CODE_ENTRYPOINT=sdk-cli; export CLAUDE_CODE_ENTRYPOINT; view --iterm --id $id --dir "$project") ); rc=$?
check "remote control: exit 1" 1 "$rc"
check "remote control: says so" "Error: this session was started by claude remote-control, so it has no iTerm2 pane to split; watch with claude attach $id" "$out"
check "no pane possible: pane-open is never called" "" "$(calls)"
touch "$fake/open-fails"
out=$(view --iterm --id $id --dir "$project"); rc=$?
check "pane-open fails: exit 1" 1 "$rc"
check "pane-open fails: names why" "Error: no iTerm2 pane opened (could not determine calling TTY); watch with claude attach $id" "$out"
command rm -f "$fake/open-fails"
calls >/dev/null

out=$(view --iterm --id 'c2a368ee;x' --dir "$project"); rc=$?
check "bad id: exit 1" 1 "$rc"
check "bad id: says so" "Error: --id needs a session id, not 'c2a368ee;x'" "$out"
out=$(view --iterm --id $id --session watch-x --dir "$project"); rc=$?
check "iterm with a tmux session name: exit 1" 1 "$rc"
check "iterm with a tmux session name: says so" "Error: --session names a tmux session, not an iTerm2 pane" "$out"
out=$( (MP_PANE_DIR="$work/none"; export MP_PANE_DIR; view --iterm --id $id --dir "$project") ); rc=$?
check "no pane scripts: exit 1" 1 "$rc"
check "no pane scripts: says so" "Error: no iterm-pane scripts in $work/none, so no pane can open; watch with claude attach $id" "$out"

# --- the real iterm-pane scripts, on a stubbed osascript (#200) --------------
# The 2026-10-17 run: the split pane is in window 28142, pane-open.sh named
# window 34630, so typing claude attach into it failed. The stub answers the
# split with the wrong window, refuses any command aimed at window 34630 as
# iTerm2 does (-1728), lists the pane in 28142, and records what it is sent.
# A fake ps gives pane-open.sh a TTY to walk to.
osa="$work/osa"
mkdir -p "$osa/bin"
cat >"$osa/bin/osascript" <<EOF
#!/bin/sh
s=""
for a in "\$@"; do [ "\$a" = -e ] || s="\$s\$a
"; done
[ -t 0 ] || s="\$s\$(command cat)"
printf '%s\n--\n' "\$s" >>"$osa/log"
case \$s in
    *'split vertically'*) echo "D54E62AC-F574 34630 1" ;;
    *'"W:"'*) [ -f "$osa/gone" ] || printf 'W:28142 T:1 S:SUPERVISOR-1 Name:claude\nW:28142 T:1 S:D54E62AC-F574 Name:-zsh\n' ;;
    *'window id 28142'*) ;;
    *) echo "execution error: iTerm got an error: Can't get session id \"D54E62AC-F574\". (-1728)" >&2; exit 1 ;;
esac
EOF
cat >"$osa/bin/ps" <<'EOF'
#!/bin/sh
case "$*" in
    *tty=*)  echo ttys009 ;;
    *ppid=*) echo 1 ;;
esac
EOF
chmod +x "$osa/bin/osascript" "$osa/bin/ps"
real() { (PATH="$osa/bin:$PATH" MP_PANE_DIR="$root/plugins/mp-ported-skills/skills/iterm-pane/scripts" &&
    export PATH MP_PANE_DIR &&
    [ "$(command -v osascript)" = "$osa/bin/osascript" ] && view "$@"); }
sent() { command cat "$osa/log" 2>/dev/null; command rm -f "$osa/log"; }
out=$(real --iterm --id $id --dir "$project"); rc=$?
check "stubbed osascript, wrong window: exit 1" 1 "$rc"
check "stubbed osascript, wrong window: the pane was closed" "Error: claude attach did not start in the pane iTerm2 split (pane-send.sh: no pane with session D54E62AC-F574 in tab 1 of window 34630 (closed, or wrong coordinates)), so the pane was closed; watch with claude attach $id" "$out"
check "stubbed osascript, wrong window: closed in the window that holds it" 1 \
    "$(sent | grep -c 'tell session id "D54E62AC-F574" of tab 1 of window id 28142 to close')"
out=$(real --close --pane 'D54E62AC-F574 34630 1'); rc=$?
check "stubbed osascript, close in the wrong window: exit 0" 0 "$rc"
check "stubbed osascript, close in the wrong window: closes it" "closed pane D54E62AC-F574" "$out"
check "stubbed osascript, close in the wrong window: closed where it is" 1 \
    "$(sent | grep -c 'tell session id "D54E62AC-F574" of tab 1 of window id 28142 to close')"
touch "$osa/gone"
out=$(real --close --pane 'D54E62AC-F574 28142 1'); rc=$?
check "stubbed osascript, no window holds it: already closed" "pane D54E62AC-F574 already closed" "$out"
check "stubbed osascript, no window holds it: closes nothing" 0 "$(sent | grep -c ' to close')"
command rm -f "$osa/gone"

echo "supervise-view-iterm: $pass passed, $fail failed"
[ "$fail" = 0 ]
