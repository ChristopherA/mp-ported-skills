#!/bin/sh
# supervise-view-iterm.test.sh -- tests for view.sh's iTerm2 mode, which
# opens a split pane running `claude attach <id>` for `--watch iterm` (#102).
#
# MP_PANE_DIR points view.sh at fake pane-open.sh, pane-classify.sh and
# pane-close.sh, so no pane opens and iTerm2 is never driven. The fakes record
# their arguments; pane-classify.sh prints what the test wrote to its state
# file. Touches nothing outside its own mktemp directory.
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
EOF
cat >"$panes/pane-classify.sh" <<EOF
#!/bin/sh
echo "classify \$*" >>"$fake/calls"
command cat "$fake/state" 2>/dev/null || echo working
EOF
cat >"$panes/pane-close.sh" <<EOF
#!/bin/sh
echo "close \$*" >>"$fake/calls"
EOF
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
classify --session F1C3A2B4-0D6E --window 4242 --tab 2" "$(calls)"

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

# --- close -----------------------------------------------------------------
out=$(view --close --pane 'F1C3A2B4-0D6E 4242 2'); rc=$?
check "close: exit 0" 0 "$rc"
check "close: says so" "closed pane F1C3A2B4-0D6E" "$out"
check "close: closes the pane without asking what runs there" "classify --session F1C3A2B4-0D6E --window 4242 --tab 2
close --session F1C3A2B4-0D6E --window 4242 --tab 2 --force" "$(calls)"
echo gone >"$fake/state"
out=$(view --close --pane 'F1C3A2B4-0D6E 4242 2'); rc=$?
check "close, already gone: exit 0" 0 "$rc"
check "close, already gone: says so" "pane F1C3A2B4-0D6E already closed" "$out"
check "close, already gone: closes nothing" 0 "$(calls | grep -c '^close')"
command rm -f "$fake/state"
out=$(view --close --pane 'F1C3A2B4-0D6E 4242'); rc=$?
check "close, bad pane: exit 1" 1 "$rc"
check "close, bad pane: says so" "Error: --pane needs 'SESSION WINDOW TAB', not 'F1C3A2B4-0D6E 4242'" "$out"
out=$(view --close --pane 'F1C3A2B4 4242 2;x'); rc=$?
check "close, bad tab: exit 1" 1 "$rc"
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
check "pane-open fails: names why" "Error: no iTerm2 pane opened (Error: could not determine calling TTY); watch with claude attach $id" "$out"
command rm -f "$fake/open-fails"
calls >/dev/null

out=$(view --iterm --id 'c2a368ee;x' --dir "$project"); rc=$?
check "bad id: exit 1" 1 "$rc"
check "bad id: says so" "Error: --id needs a session id, not 'c2a368ee;x'" "$out"
out=$(view --iterm --id $id --session watch-x --dir "$project"); rc=$?
check "iterm with a tmux session name: exit 1" 1 "$rc"

echo "supervise-view-iterm: $pass passed, $fail failed"
[ "$fail" = 0 ]
