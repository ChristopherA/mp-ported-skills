#!/bin/sh
# live-worker-cleanup.test.sh -- tests for tests/live/worker-cleanup.sh, the
# helper the live supervise tests clean up with (#95).
#
# Runs a small script shaped like a live test: it sources the helper, sets
# its cleanup with worker_cleanup_trap, and then ends normally, fails, or is sent INT
# or TERM. A fake `claude` logs each call, and a stub release.sh logs its
# arguments. Checks that every ending stops and removes each session,
# releases the first one's marker and removes the scratch folder, and that
# the script's exit status is kept. Runs the script under sh, and under dash
# too when it is on PATH: bash, which is macOS sh, runs an EXIT trap on a
# fatal signal, but dash and zsh do not, which is why the helper traps INT
# and TERM as well. Runs no real `claude`. Touches nothing
# outside its own mktemp directory.
#
# Usage: sh tests/live-worker-cleanup.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
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

mkdir -p "$work/bin" "$work/scripts"
cat >"$work/bin/claude" <<EOF
#!/bin/sh
printf 'claude %s\n' "\$*" >>"$work/log"
EOF
cat >"$work/scripts/release.sh" <<EOF
#!/bin/sh
printf 'release %s\n' "\$*" >>"$work/log"
EOF
chmod +x "$work/bin/claude" "$work/scripts/release.sh"
PATH="$work/bin:$PATH"
export PATH
[ "$(command -v claude)" = "$work/bin/claude" ] || { echo "FAIL the fake claude is not first on PATH"; exit 1; }

# The live test's shape: no id until the launch, then cleanup on any exit.
# ENDING: ok, fail, INT, TERM or early (exit before the launch).
cat >"$work/live.sh" <<EOF
#!/bin/sh
set -u
. "$root/tests/live/worker-cleanup.sh"
scratch="$work/scratch"
id=""
cleanup() {
    [ -z "\$id" ] || worker_cleanup_remove "$work/scripts" "\$scratch" "\$id" 5b8e1f04
    command rm -rf "\$scratch"
}
worker_cleanup_trap cleanup
mkdir -p "\$scratch"
[ "\$ENDING" = early ] && exit 1
id=c2a368ee
case \$ENDING in
    INT | TERM) kill -s "\$ENDING" \$\$ ;;
esac
echo "past the signal"
[ "\$ENDING" = ok ]
EOF

all="claude stop c2a368ee
claude rm c2a368ee
claude stop 5b8e1f04
claude rm 5b8e1f04
release --dir $work/scratch --id c2a368ee"

shells=sh
command -v dash >/dev/null 2>&1 && shells="sh dash"
for shell in $shells; do
    for ending in ok fail INT TERM; do
        command rm -f "$work/log"
        out=$(ENDING=$ending "$shell" "$work/live.sh" </dev/null 2>&1)
        rc=$?
        case $ending in
            ok) want=0 ;; fail) want=1 ;; INT) want=130 ;; TERM) want=143 ;;
        esac
        check "$shell $ending: exit status kept" "$want" "$rc"
        check "$shell $ending: stops and removes each session, then releases the marker" "$all" \
            "$(command cat "$work/log" 2>/dev/null)"
        check "$shell $ending: the scratch folder is gone" no "$([ -e "$work/scratch" ] && echo yes || echo no)"
        case $ending in
            INT | TERM) check "$shell $ending: nothing runs past the signal" "" "$out" ;;
        esac
    done

    command rm -f "$work/log"
    ENDING=early "$shell" "$work/live.sh" </dev/null >/dev/null 2>&1
    check "$shell before the launch: no session to stop" "" "$(command cat "$work/log" 2>/dev/null)"
    check "$shell before the launch: the scratch folder is gone" no "$([ -e "$work/scratch" ] && echo yes || echo no)"
done

# Both live tests that resume a worker clean up through the helper.
for t in supervise-resume supervise-watch; do
    f="$root/tests/live/$t.sh"
    check "$t: sources the helper" 1 "$(grep -cF '. "$root/tests/live/worker-cleanup.sh"' "$f")"
    check "$t: sets the trap" 1 "$(grep -cx 'worker_cleanup_trap cleanup' "$f")"
    check "$t: unsets CLAUDE_CODE_SESSION_ATTENDED" 1 "$(grep -c '^unset .*CLAUDE_CODE_SESSION_ATTENDED' "$f")"
done

echo "live-worker-cleanup: $pass passed, $fail failed"
[ "$fail" = 0 ]
