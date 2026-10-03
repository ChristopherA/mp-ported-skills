#!/bin/sh
# worker-bin.test.sh -- tests for the git and gh wrappers a background
# session's Bash commands run through (#66).
#
# Runs the SessionStart command from hooks.json, as Claude Code does, with
# CLAUDE_ENV_FILE pointed at a scratch file, then runs commands the way the
# session's Bash tool would: with that file sourced first. A fake gh stands
# in for the real one; git is the real git, pushing to scratch bare repos.
# Touches nothing outside its own temp folders.
#
# Usage: sh tests/worker-bin.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
hooks="$root/plugins/mp-ported-skills/hooks/hooks.json"
export CLAUDE_PLUGIN_ROOT="$root/plugins/mp-ported-skills"
bin="$CLAUDE_PLUGIN_ROOT/scripts/worker-bin"

pass=0 fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}

# Every variable the scripts read, set or unset here. git reads no global
# or system config, and never signs. Run inside a background session, this
# test inherits that session's wrappers and attended flag; without them the
# setup pushes below would be refused before any check runs.
unset GIT_DIR GIT_WORK_TREE GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT MP_DENY_SHARED_ACTIONS_IGNORE_GRANTS CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ATTENDED
PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '/worker-bin/*$' | paste -sd: -)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

work=$(mktemp -d)
cd "$work" || exit 1

# A fake gh, after the wrappers on PATH, that says what it was asked.
mkdir fake
printf '#!/bin/sh\necho "real gh: $*"\n' >fake/gh
chmod +x fake/gh
export PATH="$work/fake:$PATH"
check "the fake gh is the one on PATH" "$work/fake/gh" "$(command -v gh)"

entry='.hooks.SessionStart[] | select(.hooks[0].command | test("worker-path"))'
hook_cmd=$(jq -r "$entry | .hooks[0].command" "$hooks")
check "SessionStart entry registered" "yes" "$([ -n "$hook_cmd" ] && echo yes)"
check "SessionStart entry runs on every source" "null" "$(jq -r "$entry | .matcher" "$hooks")"
check "SessionStart entry has a timeout" "5" "$(jq -r "$entry | .hooks[0].timeout" "$hooks")"

session_start() { # <attended> <env file>: run the hook as Claude Code does
    printf '{"hook_event_name":"SessionStart","source":"startup"}' |
        (export CLAUDE_ENV_FILE="$2"; CLAUDE_CODE_SESSION_ATTENDED="$1" sh -c "$hook_cmd")
}

# The hook puts the wrappers first on PATH in an unattended session only.
: >env.unattended
session_start 0 env.unattended
check "unattended: PATH starts with the wrappers" "$bin" \
    "$(. ./env.unattended; printf '%s' "${PATH%%:*}")"
session_start 0 env.unattended
check "a second run (resume, compact) adds no second line" "1" \
    "$(grep -c worker-bin env.unattended)"
: >env.attended
session_start 1 env.attended
check "attended: nothing written" "" "$(command cat env.attended)"
: >env.unset
printf '{}' | (export CLAUDE_ENV_FILE="$work/env.unset"; env -u CLAUDE_CODE_SESSION_ATTENDED sh -c "$hook_cmd")
check "attended unset (older Claude Code): nothing written" "" "$(command cat env.unset)"
check "no CLAUDE_ENV_FILE: exits 0" "0" \
    "$(printf '{}' | (CLAUDE_CODE_SESSION_ATTENDED=0 sh -c "$hook_cmd"); echo $?)"

# A command as the session's Bash tool runs it: the env file sourced first.
worker() { # <attended> <dir> <command>: stdout and stderr, then exit=N
    (cd "$2" && CLAUDE_CODE_SESSION_ATTENDED="$1" sh -c ". '$work/env.unattended'; $3" 2>&1; echo "exit=$?")
}
last() { printf '%s\n' "$1" | tail -n 1; }

check "git on PATH is the wrapper" "$bin/git" "$(worker 0 . 'command -v git' | head -n 1)"
check "gh on PATH is the wrapper" "$bin/gh" "$(worker 0 . 'command -v gh' | head -n 1)"

# A checkout with a remote, and no grant.
repo() { # <name>: a checkout pushed to <name>.git
    git init -q --bare "$work/$1.git"
    git init -q -b main "$work/$1"
    git -C "$work/$1" -c commit.gpgsign=false commit -q --allow-empty -m start
    git -C "$work/$1" remote add origin "$work/$1.git"
    git -C "$work/$1" push -q origin main 2>/dev/null
    git -C "$work/$1" remote set-head origin main
}
repo plain
git -C plain -c commit.gpgsign=false commit -q --allow-empty -m more
printf 'git push -q origin main\n' >plain/push.sh
before=$(git -C plain.git rev-parse main)

out=$(worker 0 plain 'sh push.sh')
check "a script that pushes is refused" "exit=1" "$(last "$out")"
check "the refusal names the grant file and the supervisor" "1" \
    "$(printf '%s\n' "$out" | grep -c "cannot run 'git push' on its own (#66).*docs/agents/supervision.md.*supervisor")"
check "the remote did not move" "$before" "$(git -C plain.git rev-parse main)"
check "a push through a variable is refused" "exit=1" "$(last "$(worker 0 plain 'g=git; $g push -q origin main')")"
# find exits 0 whatever -exec's command returns, so look for the refusal.
check "a push through find -exec is refused" "1" \
    "$(worker 0 plain 'find . -maxdepth 0 -exec git push -q origin main \;' | grep -c "cannot run 'git push'")"
check "a push through an alias is refused" "exit=1" \
    "$(last "$(worker 0 plain 'git -c alias.ship=push ship -q origin main')")"
check "the remote still did not move" "$before" "$(git -C plain.git rev-parse main)"

# Ordinary git goes through, exit status and all.
check "git status goes through" "exit=0" "$(last "$(worker 0 plain 'git status --short')")"
check "git log output passes through" "more" "$(worker 0 plain 'git log -1 --format=%s' | head -n 1)"
check "a failing git keeps its exit status" "exit=128" \
    "$(last "$(worker 0 plain 'git cat-file -t 0000000000000000000000000000000000000000')")"

# gh: refused forms never reach the real gh; others do.
out=$(worker 0 plain 'sh -c "gh pr create --fill"')
check "gh pr create from a script is refused" "exit=1" "$(last "$out")"
check "the real gh was not run" "0" "$(printf '%s\n' "$out" | grep -c 'real gh')"
check "gh pr view goes to the real gh" "real gh: pr view 5" "$(worker 0 plain 'gh pr view 5' | head -n 1)"
check "gh api write is refused" "exit=1" "$(last "$(worker 0 plain 'gh api -X PUT repos/o/r/pulls/5/merge')")"
check "gh api read goes through" "real gh: api repos/o/r/pulls/5" "$(worker 0 plain 'gh api repos/o/r/pulls/5' | head -n 1)"
check "gh issue comment from a script is refused" "exit=1" "$(last "$(worker 0 plain 'sh -c "gh issue comment 104 --body x"')")"
check "gh issue create is refused" "exit=1" "$(last "$(worker 0 plain 'gh issue create --title x --body y')")"
check "gh api issue comment is refused" "exit=1" "$(last "$(worker 0 plain 'gh api repos/o/r/issues/104/comments -f body=x')")"

# A standing grant on the committed default branch lets the matching
# action through; gh api stays refused alongside it (#58).
repo granted
mkdir -p granted/docs/agents
printf '## Grants\n\n- push\n- issue-close\n- issue-comment\n- issue-create\n' >granted/docs/agents/supervision.md
git -C granted add docs/agents/supervision.md
git -C granted -c commit.gpgsign=false commit -q -m grants
git -C granted push -q origin main 2>/dev/null
git -C granted -c commit.gpgsign=false commit -q --allow-empty -m work
printf 'git push -q origin main\n' >granted/push.sh

check "a granted push from a script goes through" "exit=0" "$(last "$(worker 0 granted 'sh push.sh')")"
check "the remote moved" "$(git -C granted rev-parse main)" "$(git -C granted.git rev-parse main)"
check "a granted issue close reaches the real gh" "real gh: issue close 4" \
    "$(worker 0 granted 'gh issue close 4' | head -n 1)"
# The grant is read from the repo the push acts on, not the one the
# command runs in.
git -C plain -c commit.gpgsign=false commit -q --allow-empty -m elsewhere
before=$(git -C plain.git rev-parse main)
check "git -C into an ungranted repo is refused from a granted one" "exit=1" \
    "$(last "$(worker 0 granted 'git -C ../plain push -q origin main')")"
check "the ungranted remote did not move" "$before" "$(git -C plain.git rev-parse main)"
git -C granted -c commit.gpgsign=false commit -q --allow-empty -m from-outside
check "git -C into a granted repo goes through from an ungranted one" "exit=0" \
    "$(last "$(worker 0 plain 'git -C ../granted push -q origin main')")"
check "a granted issue comment from a script reaches the real gh" "real gh: issue comment 104 --body x" \
    "$(worker 0 granted 'sh -c "gh issue comment 104 --body x"' | head -n 1)"
check "a granted issue create reaches the real gh" "real gh: issue create --title x --body y" \
    "$(worker 0 granted 'gh issue create --title x --body y' | head -n 1)"
check "a granted issue comment through gh api reaches the real gh" "real gh: api repos/o/r/issues/104/comments -f body=x" \
    "$(worker 0 granted 'gh api repos/o/r/issues/104/comments -f body=x' | head -n 1)"
check "an ungranted action beside a grant is refused" "exit=1" \
    "$(last "$(worker 0 granted 'gh pr merge 5')")"
check "gh api is never granted" "exit=1" \
    "$(last "$(worker 0 granted 'gh api -X PUT repos/o/r/pulls/5/merge')")"

# The maintainer's own session: if the env file reached it, the wrappers
# still let everything through.
git -C plain -c commit.gpgsign=false commit -q --allow-empty -m attended
check "attended: a push goes through" "exit=0" "$(last "$(worker 1 plain 'sh push.sh')")"
check "attended: the remote moved" "$(git -C plain rev-parse main)" "$(git -C plain.git rev-parse main)"
check "attended: gh pr create reaches the real gh" "real gh: pr create --fill" \
    "$(worker 1 plain 'gh pr create --fill' | head -n 1)"

# Installs copy the plugin by git, so the wrappers must be committed
# executable for PATH lookup to find them.
for p in git gh; do
    check "worker-bin/$p is executable" "yes" "$([ -x "$bin/$p" ] && echo yes)"
    check "worker-bin/$p is committed executable" "100755" \
        "$(git -C "$root" ls-files -s "plugins/mp-ported-skills/scripts/worker-bin/$p" | cut -c1-6)"
done

cd / && command rm -rf "$work"

echo "worker-bin: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
