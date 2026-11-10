#!/bin/sh
# supervise-watch-signing.test.sh -- tests for watch.sh naming a worker
# whose turn ended while a commit signing helper waits on a biometric
# approval at the Mac (#196).
#
# Runs watch.sh --file on the recorded `claude agents --json --all` fixture
# done.json (worker pid 85224), with the turn-ended transcript fixture
# installed under the config dir's projects/, and a fake `ps` on PATH that
# prints a stub process list from FAKE_PS. The polling loop runs against a
# fake `claude` that prints FAKE_LIST. Touches nothing outside its own
# mktemp directory.
#
# Usage: sh tests/supervise-watch-signing.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scripts="$root/plugins/mp-ported-skills/skills/supervise/scripts"
fixtures="$root/tests/fixtures/agents-json"
transcripts="$root/tests/fixtures/transcripts"
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

# Every variable the scripts read, set or unset here, so the result does not
# depend on the session running the test.
unset CLAUDE_CODE_SESSION_ATTENDED MP_SMART_ZONE_K CLAUDE_AUTOCOMPACT_PCT_OVERRIDE MP_AGENTS_TIMEOUT FAKE_PS FAKE_LIST
cfg="$work/config"
mkdir -p "$cfg"
export CLAUDE_CONFIG_DIR="$cfg"

# Fake ps and claude, checked on PATH before any call could reach the real
# ones.
bin="$work/bin"
mkdir -p "$bin"
cat >"$bin/ps" <<'EOF'
#!/bin/sh
[ -n "${FAKE_PS:-}" ] && [ -f "$FAKE_PS" ] || { echo "ps: no stub" >&2; exit 1; }
cat "$FAKE_PS"
EOF
cat >"$bin/claude" <<'EOF'
#!/bin/sh
[ "$1 $2 $3" = "agents --json --all" ] || exit 1
cat "$FAKE_LIST"
EOF
chmod +x "$bin/ps" "$bin/claude"
PATH="$bin:$PATH"
export PATH
[ "$(command -v ps)" = "$bin/ps" ] || { echo "FAIL the fake ps is not first on PATH"; exit 1; }
[ "$(command -v claude)" = "$bin/claude" ] || { echo "FAIL the fake claude is not first on PATH"; exit 1; }

sid=9121ff49-5e25-43f0-bf48-307db0776c36
list() { # <state> -- done.json with the worker in that state
    jq --arg s "$1" 'map(if .id == "9121ff49" then .state = $s else . end)' \
        "$fixtures/done.json" >"$work/$1.json"
}
list done
list blocked
transcript() { # <last text> [turn end timestamp] -- the worker's transcript
    dir="$cfg/projects/-work-project"
    command rm -rf "$cfg/projects"; mkdir -p "$dir"
    jq -c --arg t "$1" --arg at "${2:-}" '
        if .type == "assistant" and .message.content == [{"type": "text"}]
        then .message.content[0].text = $t | (if $at != "" then .timestamp = $at else . end)
        elif .type == "system" and .subtype == "turn_duration" and $at != "" then .timestamp = $at
        else . end' "$transcripts/turn-ended.jsonl" >"$dir/$sid.jsonl"
}
# stub ps lines: pid ppid etime command, as `ps -axo pid=,ppid=,etime=,command=`
# prints them. The worker is 85224; its Bash shell 900 runs git 901, which
# runs ssh-keygen 902, which runs ssh-sk-helper 903.
signing="  85224     1    1:02:03 claude --bg
  900 85224      05:20 /bin/zsh -c git commit -S -s -m x
  901   900      05:19 git commit -S -s -m x
  902   901      05:19 ssh-keygen -Y sign -n git -f /var/folders/xx/key /var/folders/xx/buffer
  903   902      05:18 /usr/libexec/ssh-sk-helper
  1     0   9-00:00:00 /sbin/launchd"
other="  85224     1    1:02:03 claude --bg
  700     1      02:00 claude --bg
  701   700      01:59 git commit -S -s -m y
  702   701      01:58 ssh-keygen -Y sign -n git -f /var/folders/yy/key /var/folders/yy/buffer
  1     0   9-00:00:00 /sbin/launchd"
idle="  85224     1    1:02:03 claude --bg
  1     0   9-00:00:00 /sbin/launchd"
stub() { printf '%s\n' "$1" >"$work/ps.txt"; FAKE_PS="$work/ps.txt"; export FAKE_PS; }

watch_file() { # <list> [option]... -- watch.sh --file, its epoch digits masked
    l=$1; shift
    sh "$scripts/watch.sh" --id 9121ff49 --file "$work/$l.json" "$@" </dev/null 2>&1 |
        sed 's/^after [0-9][0-9]*$/after EPOCH/'
}
approval="needs biometric approval at the Mac: ssh-sk-helper (pid 903) has waited 05:18"

# --- a done whose commit waits on the signing key ----------------------------
transcript "Committed in the background; the signing may be waiting on a prompt."
stub "$signing"
check "done: a waiting signing helper is named, not done" "blocked signing approval
cwd /work/project
$approval
after EPOCH" "$(watch_file done)"

# The #194 case: claude agents said blocked on a report that ends on a
# statement, which reads as done (#114); the helper wins over that too.
check "blocked on a statement: the helper is named" "blocked signing approval
cwd /work/project
note claude agents said blocked
$approval
after EPOCH" "$(watch_file blocked)"

# A Waiting on: line the worker ended on is kept as a note, for after the
# approval.
transcript 'Committed.

`Waiting on: git push origin main`'
check "waiting on a push: the approval comes first" "blocked signing approval
cwd /work/project
note after the approval it waits on git push origin main
$approval
after EPOCH" "$(watch_file done)"

# Only ssh-keygen waiting, before it has started ssh-sk-helper.
transcript "Committed."
stub "$(printf '%s\n' "$signing" | grep -v ssh-sk-helper)"
check "ssh-keygen -Y sign alone is named" "blocked signing approval
cwd /work/project
needs biometric approval at the Mac: ssh-keygen -Y sign (pid 902) has waited 05:19
after EPOCH" "$(watch_file done)"

# --- what is not a pending approval --------------------------------------------
stub "$other"
check "another session's signing helper is not the worker's" "done
cwd /work/project" "$(watch_file done)"
stub "$idle"
check "no signing helper: done" "done
cwd /work/project" "$(watch_file done)"
stub "  85224     1    1:02:03 claude --bg
  900 85224      05:20 ssh-keygen -l -f /var/folders/xx/key.pub"
check "an ssh-keygen that is not signing: done" "done
cwd /work/project" "$(watch_file done)"
unset FAKE_PS
check "ps fails: done, as before" "done
cwd /work/project" "$(watch_file done)"
jq 'map(if .id == "9121ff49" then del(.pid) else . end)' "$work/done.json" >"$work/nopid.json"
stub "$signing"
check "no pid in the list: done, as before" "done
cwd /work/project" "$(watch_file nopid)"

# --- after the approval, the watch with --after reaches the real turn end ------
# The stub's helper is gone; the transcript still ends on the turn that ended
# before the watch returned, so the list's done is the old one.
stub "$idle"
transcript "Committed in the background." "2026-10-20T10:00:00Z"
after=$(jq -n '"2026-10-20T10:05:00Z" | fromdateiso8601')
check "after the approval: the old turn end is still working" "working
cwd /work/project" "$(watch_file done --after "$after")"
transcript "Committed 3 changes on main." "2026-10-20T10:07:00Z"
check "after the approval: the new turn end is done" "done
cwd /work/project" "$(watch_file done --after "$after")"

# --- the polling loop returns at once, and with --wait-blocked ---------------
stub "$signing"
transcript "Committed in the background."
FAKE_LIST="$work/blocked.json"; export FAKE_LIST
out=$(sh "$scripts/watch.sh" --id 9121ff49 --interval 0 --timeout 5 </dev/null 2>&1 | sed 's/^after [0-9][0-9]*$/after EPOCH/')
check "loop: returns the pending approval" "blocked signing approval
cwd /work/project
note claude agents said blocked
$approval
after EPOCH" "$out"
out=$(sh "$scripts/watch.sh" --id 9121ff49 --wait-blocked --interval 0 --timeout 5 </dev/null 2>&1 | sed 's/^after [0-9][0-9]*$/after EPOCH/' | sed -n 1p)
check "loop with --wait-blocked: returns the pending approval" "blocked signing approval" "$out"
# The after line is the time the watch returned, so a watch with it reads
# only a turn end written later.
before=$(date +%s)
got=$(sh "$scripts/watch.sh" --id 9121ff49 --file "$work/done.json" </dev/null | sed -n 's/^after //p')
afterwards=$(date +%s)
check "after line: the time the watch returned" "yes" \
    "$([ -n "$got" ] && [ "$got" -ge "$before" ] && [ "$got" -le "$afterwards" ] && echo yes || echo "no: $got")"

# With --detail, every line prints, and no message: what waits is named.
check "detail: the lines, no message" "blocked signing approval
cwd /work/project
$approval
after EPOCH
detail $work/detail.txt" "$(watch_file done --detail "$work/detail.txt")"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
