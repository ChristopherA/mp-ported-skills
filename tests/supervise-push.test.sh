#!/bin/sh
# supervise-push.test.sh -- tests for the supervise skill's push.sh, and for
# actions.sh's report of a push it made (#100).
#
# Each case builds a scratch Project with a bare remote: a start commit on
# origin/main, then the worker's commits on top, one of them a patch bump of
# a plugin.json. The sweep is a stub script that records the range it was
# given and exits as the case asks. Touches nothing outside its own mktemp
# directory.
#
# Usage: sh tests/supervise-push.test.sh

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

# Every variable the scripts read, set or unset here, so the result does not
# depend on the session running the test. A worker runs this file with
# CLAUDE_CODE_SESSION_ATTENDED=0, where the git wrappers would refuse the
# scratch repo's pushes.
unset CLAUDE_CODE_SESSION_ATTENDED MP_DENY_SHARED_ACTIONS_IGNORE_GRANTS
export CLAUDE_CONFIG_DIR="$work/config"
mkdir -p "$CLAUDE_CONFIG_DIR"

repo_git() { # <folder> <git args...> -- git there, unsigned, with a test identity
    repo_dir=$1; shift
    git -C "$repo_dir" -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@"
}

# The sweep stub: records its arguments, and its folder with them in
# sweep-log; exits 2 on an empty range, as the real sweep does; prints a hit
# and exits 1 when $work/sweep-hit exists, empty or naming the folder it runs
# in.
sweep="$work/sweep.sh"
cat >"$sweep" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >"$work/sweep-args"
printf '%s %s\n' "\$(pwd -P)" "\$*" >>"$work/sweep-log"
r=\$2; if [ "\${r%%..*}" = "\${r##*..}" ]; then echo "range \$r contains no commits -- nothing was swept"; exit 2; fi
if [ -f "$work/sweep-hit" ] && { [ ! -s "$work/sweep-hit" ] || [ "\$(command cat "$work/sweep-hit")" = "\$(pwd -P)" ]; }; then echo 'docs/x.md:3: private path'; exit 1; fi
echo 'sweep: clean'
EOF
chmod +x "$sweep"

n=0
# new_project: a fresh Project in $project with a remote in $remote; $start
# is the worker's start, on origin/main; the worker's two commits follow,
# the second bumping the plugin from 0.8.22 to 0.8.23.
new_project() {
    n=$((n + 1))
    remote="$work/remote$n.git"
    project="$work/project$n"
    git init -q --bare "$remote"
    git init -q -b main "$project"
    mkdir -p "$project/plugin/.claude-plugin"
    printf '{"name": "p", "version": "0.8.22"}\n' >"$project/plugin/.claude-plugin/plugin.json"
    repo_git "$project" add -A
    repo_git "$project" commit -q -m start
    repo_git "$project" remote add origin "$remote"
    repo_git "$project" push -q -u origin main 2>/dev/null
    start=$(git -C "$project" rev-parse HEAD)
    echo change >"$project/file.txt"
    repo_git "$project" add file.txt
    repo_git "$project" commit -q -m "Do the work"
    printf '{"name": "p", "version": "0.8.23"}\n' >"$project/plugin/.claude-plugin/plugin.json"
    repo_git "$project" commit -q -am "Bump plugin to 0.8.23"
    head=$(git -C "$project" rev-parse HEAD)
    remote_main=$start
    command rm -f "$work/sweep-hit" "$work/sweep-args" "$work/sweep-log"
}
push() { # [args...] -- push.sh for worker 3fb49286 in $project, its output
    sh "$scripts/push.sh" --dir "$project" --id 3fb49286 --start "$start" "$@" </dev/null 2>&1
}
short() { git -C "$project" rev-parse --short "$1"; }
commits() { # the commit lines for the worker's two commits
    git -C "$project" log --format='commit %h %s' "$start..HEAD"
}

# --- --check: every check passes, nothing is pushed ------------------------
new_project
out=$(push --check --sweep "$sweep")
check "check: all pass" "push main to origin/main: $(short "$start")..$(short "$head")
$(commits)
ok marker: no worker marker in the checkout
ok tree: clean
ok fast-forward: 2 ahead of origin/main, 0 behind
ok start: $(short "$start") is on origin/main
ok version: plugin/.claude-plugin/plugin.json 0.8.22 -> 0.8.23 (patch)
ok sweep: clean over $(short "$start")..$(short "$head")" "$out"
push --check --sweep "$sweep" >/dev/null
check "check: exits 0" "0" "$?"
check "check: the sweep gets the range" "--range $start..$head" "$(command cat "$work/sweep-args")"
check "check: nothing pushed" "$start" "$(git -C "$remote" rev-parse main)"

# --- a push -----------------------------------------------------------------
out=$(push --sweep "$sweep")
check "push: exits 0" "0" "$?"
check "push: the last line names the push" "pushed origin/main $(short "$start")..$(short "$head")" "$(printf '%s\n' "$out" | tail -n 1)"
check "push: the remote has the worker's commits" "$head" "$(git -C "$remote" rev-parse main)"
check "push: the tracking ref follows" "$head" "$(git -C "$project" rev-parse origin/main)"
recorded=$(command cat "$(git -C "$project" rev-parse --path-format=absolute --git-path mp-supervise-pushed)")
check "push: recorded for actions.sh" "3fb49286 origin/main $start $head" "${recorded% *}"
check "push: recorded with its time, for record.sh" "yes" \
    "$(printf '%s\n' "${recorded##* }" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' && echo yes || echo no)"
out=$(push --sweep "$sweep")
check "push: nothing left to push is refused" "fail fast-forward: nothing to push, 0 ahead of origin/main" \
    "$(printf '%s\n' "$out" | grep '^fail')"

# --- each failing check is named, and nothing is pushed ---------------------
refused() { # <name> <expected fail lines> [push args...]
    name=$1 expected=$2; shift 2
    out=$(push "$@")
    rc=$?
    check "$name: exits 2" "2" "$rc"
    check "$name: says which" "$expected" "$(printf '%s\n' "$out" | grep '^fail')"
    check "$name: nothing pushed" "$remote_main" "$(git -C "$remote" rev-parse main)"
}

new_project
echo dirty >>"$project/file.txt"
refused "dirty tree" "fail tree: 1 uncommitted path" --sweep "$sweep"

new_project
touch "$work/sweep-hit"
refused "sweep hits" "fail sweep: exit 1 over $(short "$start")..$(short "$head")" --sweep "$sweep"
check "sweep hits: its output is shown" "  docs/x.md:3: private path" "$(push --sweep "$sweep" | grep '^  ')"

new_project
printf '{"name": "p", "version": "0.9.0"}\n' >"$project/plugin/.claude-plugin/plugin.json"
repo_git "$project" commit -q --amend -am "Bump plugin to 0.9.0"
refused "minor bump" "fail version: plugin/.claude-plugin/plugin.json 0.8.22 -> 0.9.0 is past a patch bump" --sweep "$sweep"

new_project
printf '{"name": "p", "version": "1.0.0"}\n' >"$project/plugin/.claude-plugin/plugin.json"
repo_git "$project" commit -q --amend -am "Bump plugin to 1.0.0"
refused "major bump" "fail version: plugin/.claude-plugin/plugin.json 0.8.22 -> 1.0.0 is past a patch bump" --sweep "$sweep"

# Someone else pushed to origin/main since the start: not a fast-forward.
new_project
other="$work/other$n"
git clone -q "$remote" "$other"
repo_git "$other" commit -q --allow-empty -m "someone else"
repo_git "$other" push -q origin main 2>/dev/null
moved=$(git -C "$remote" rev-parse main)
out=$(push --sweep "$sweep")
check "not fast-forward: exits 2" "2" "$?"
check "not fast-forward: says which" "fail fast-forward: 2 ahead of origin/main, 1 behind" \
    "$(printf '%s\n' "$out" | grep '^fail')"
check "not fast-forward: nothing pushed" "$moved" "$(git -C "$remote" rev-parse main)"

# A commit before the worker's start that never reached origin would go out
# with the push, unseen.
new_project
repo_git "$project" reset -q --hard "$start"
repo_git "$project" commit -q --allow-empty -m "maintainer's unpushed commit"
start=$(git -C "$project" rev-parse HEAD)
repo_git "$project" commit -q --allow-empty -m "worker's commit"
refused "unpushed before start" "fail start: $(short "$start") is not on origin/main; 1 commit before the worker's start would go too" --sweep "$sweep"

new_project
printf 'x\n' >"$(git -C "$project" rev-parse --path-format=absolute --git-path mp-supervise-worker)"
refused "marker in place" "fail marker: worker x still holds the checkout; stop it and release its marker first" --sweep "$sweep"

new_project
repo_git "$project" remote set-url origin "$work/no-such-remote.git"
out=$(push --sweep "$sweep")
check "fetch fails: exits 2" "2" "$?"
check "fetch fails: says which" "fetch" "$(printf '%s\n' "$out" | sed -n 's/^fail \([a-z-]*\):.*/\1/p')"

# A plugin new in the range, or removed, is not a bump.
new_project
mkdir -p "$project/other/.claude-plugin"
printf '{"name": "o", "version": "2.0.0"}\n' >"$project/other/.claude-plugin/plugin.json"
repo_git "$project" add other
repo_git "$project" commit -q -m "Add another plugin"
check "new manifest: passes, named new" "ok version: other/.claude-plugin/plugin.json new at 2.0.0" \
    "$(push --check --sweep "$sweep" | grep '^ok version: other')"
new_project
repo_git "$project" rm -q plugin/.claude-plugin/plugin.json
repo_git "$project" commit -q -m "Remove the plugin"
check "removed manifest: passes, named removed" "ok version: plugin/.claude-plugin/plugin.json removed, was 0.8.22" \
    "$(push --check --sweep "$sweep" | grep '^ok version')"

new_project
repo_git "$project" checkout -q -b topic
refused "no upstream" "fail branch: topic has no upstream" --sweep "$sweep"

new_project
repo_git "$project" checkout -q --detach
refused "detached" "fail branch: HEAD is detached" --sweep "$sweep"

# --- usage ------------------------------------------------------------------
new_project
push >/dev/null
check "usage: a sweep or --no-sweep is required" "1" "$?"
out=$(push --no-sweep)
check "usage: --no-sweep pushes, and says the range was not swept" "skip sweep: --no-sweep given, the range was not swept" \
    "$(printf '%s\n' "$out" | grep '^skip')"
new_project
sh "$scripts/push.sh" --dir "$project" --start "$start" --no-sweep </dev/null >/dev/null 2>&1
check "usage: --id is required" "1" "$?"
sh "$scripts/push.sh" --dir "$project" --id 3fb49286 --no-sweep </dev/null >/dev/null 2>&1
check "usage: --start is required" "1" "$?"
sh "$scripts/push.sh" --dir "$project" --id 3fb49286 --start nosuchrev --no-sweep </dev/null >/dev/null 2>&1
check "usage: an unknown --start exits 1" "1" "$?"
sh "$scripts/push.sh" --dir "$work/missing" --id 3fb49286 --start "$start" --no-sweep </dev/null >/dev/null 2>&1
check "usage: a missing folder exits 1" "1" "$?"

# --- a background session still cannot push --------------------------------
# push.sh refuses outright, and the git wrapper would refuse it anyway: the
# #66 gate is unchanged.
new_project
out=$( (export CLAUDE_CODE_SESSION_ATTENDED=0; sh "$scripts/push.sh" --dir "$project" --id 3fb49286 --start "$start" --sweep "$sweep" </dev/null 2>&1) )
check "unattended: refused" "1" "$?"
check "unattended: says why" "Error: push.sh pushes for the maintainer's attended session; a background session pushes only on a standing grant" \
    "$(printf '%s\n' "$out" | tail -n 1)"
check "unattended: nothing pushed" "$start" "$(git -C "$remote" rev-parse main)"
out=$( (export CLAUDE_CODE_SESSION_ATTENDED=0 PATH="$root/plugins/mp-ported-skills/scripts/worker-bin:$PATH"
    cd "$project" && git push -q origin main 2>&1) )
check "unattended: the git wrapper still refuses the push" "1" "$?"
out=$( (export CLAUDE_CODE_SESSION_ATTENDED=0; sh "$scripts/push.sh" --dir "$project" --id 3fb49286 --start "$start" --check --sweep "$sweep" </dev/null 2>&1) )
check "unattended: --check still runs" "0" "$?"

# --- actions.sh names the supervisor's push --------------------------------
new_project
push --sweep "$sweep" >/dev/null
mkdir -p "$CLAUDE_CONFIG_DIR/jobs/3fb49286"
printf '{"sessionId": "s1", "children": []}\n' >"$CLAUDE_CONFIG_DIR/jobs/3fb49286/state.json"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/p"
: >"$CLAUDE_CONFIG_DIR/projects/p/s1.jsonl"
check "actions: the supervisor's push, not the worker's" \
    "branch origin/main pushed by the supervisor on the maintainer's approval: holds the worker's commits" \
    "$(sh "$scripts/actions.sh" --id 3fb49286 --dir "$project" --start "$start" </dev/null)"
mkdir -p "$CLAUDE_CONFIG_DIR/jobs/4aa00000"
command cp -f "$CLAUDE_CONFIG_DIR/jobs/3fb49286/state.json" "$CLAUDE_CONFIG_DIR/jobs/4aa00000/state.json"
# Another worker's run is not covered by push.sh's record, and its empty
# transcript holds no push of its own (#98).
check "actions: another worker's run is not covered" \
    "branch origin/main pushed by someone else: holds the worker's commits" \
    "$(sh "$scripts/actions.sh" --id 4aa00000 --dir "$project" --start "$start" </dev/null)"

# --- a Project with a Distribution repo (#141) ------------------------------
# new_dist [project commits]: a Project in $project whose origin names
# $dist in docs/agents/distribution-repo.md, with $start on origin/main and
# <project commits> (0 by default) of the worker's on top; and $dist, with
# its own remote $dist_remote, $dist_start on origin/main and the worker's
# two commits, the second bumping its plugin from 1.2.3 to 1.2.4.
new_dist() {
    new_project
    repo_git "$project" reset -q --hard "$start"
    dist="$work/dist$n"
    dist_remote="$work/dist$n.git"
    mkdir -p "$project/docs/agents"
    printf '%s\n' "$dist" >"$project/docs/agents/distribution-repo.md"
    repo_git "$project" add docs
    repo_git "$project" commit -q -m "Name the Distribution repo"
    repo_git "$project" push -q origin main 2>/dev/null
    git -C "$project" remote set-head origin main
    start=$(git -C "$project" rev-parse HEAD)
    remote_main=$start
    i=0
    while [ "$i" -lt "${1:-0}" ]; do
        i=$((i + 1))
        repo_git "$project" commit -q --allow-empty -m "Capture notes $i"
    done
    head=$(git -C "$project" rev-parse HEAD)
    git init -q --bare "$dist_remote"
    git init -q -b main "$dist"
    mkdir -p "$dist/plugin/.claude-plugin"
    printf '{"name": "d", "version": "1.2.3"}\n' >"$dist/plugin/.claude-plugin/plugin.json"
    repo_git "$dist" add -A
    repo_git "$dist" commit -q -m "dist start"
    repo_git "$dist" remote add origin "$dist_remote"
    repo_git "$dist" push -q -u origin main 2>/dev/null
    dist_start=$(git -C "$dist" rev-parse HEAD)
    echo code >"$dist/code.txt"
    repo_git "$dist" add code.txt
    repo_git "$dist" commit -q -m "Write the code"
    printf '{"name": "d", "version": "1.2.4"}\n' >"$dist/plugin/.claude-plugin/plugin.json"
    repo_git "$dist" commit -q -am "Bump plugin to 1.2.4"
    dist_head=$(git -C "$dist" rev-parse HEAD)
}
dpush() { # [args...] -- push.sh for worker 3fb49286 with both starts
    sh "$scripts/push.sh" --dir "$project" --id 3fb49286 --start "$start" --dist-start "$dist_start" "$@" </dev/null 2>&1
}
dshort() { git -C "$dist" rev-parse --short "$1"; }
nothing_pushed() { # <name>: neither remote moved
    check "$1: the Project's remote did not move" "$remote_main" "$(git -C "$remote" rev-parse main)"
    check "$1: the Distribution repo's remote did not move" "$dist_start" "$(git -C "$dist_remote" rev-parse main)"
}

# Commits in both repos: one check covers both, each line naming its repo.
new_dist 1
out=$(dpush --check --sweep "$sweep")
check "dist check: exits 0" "0" "$?"
check "dist check: both repos, each line naming its repo" "push project main to origin/main: $(short "$start")..$(short "$head")
$(git -C "$project" log --format='commit project %h %s' "$start..HEAD")
ok project marker: no worker marker in the checkout
ok project tree: clean
ok project fast-forward: 1 ahead of origin/main, 0 behind
ok project start: $(short "$start") is on origin/main
ok project version: no plugin version change
ok project sweep: clean over $(short "$start")..$(short "$head")
push distribution main to origin/main: $(dshort "$dist_start")..$(dshort "$dist_head")
$(git -C "$dist" log --format='commit distribution %h %s' "$dist_start..HEAD")
ok distribution marker: no worker marker in the checkout
ok distribution tree: clean
ok distribution fast-forward: 2 ahead of origin/main, 0 behind
ok distribution start: $(dshort "$dist_start") is on origin/main
ok distribution version: plugin/.claude-plugin/plugin.json 1.2.3 -> 1.2.4 (patch)
ok distribution sweep: clean over $(dshort "$dist_start")..$(dshort "$dist_head")" "$out"
check "dist check: each repo is swept over its own range" "$project --range $start..$head
$dist --range $dist_start..$dist_head" "$(command cat "$work/sweep-log")"
nothing_pushed "dist check"

out=$(dpush --sweep "$sweep")
check "dist push: exits 0" "0" "$?"
check "dist push: names both pushes" "pushed origin/main $(short "$start")..$(short "$head")
pushed distribution:origin/main $(dshort "$dist_start")..$(dshort "$dist_head")" "$(printf '%s\n' "$out" | grep '^pushed')"
check "dist push: the Project's remote has its commit" "$head" "$(git -C "$remote" rev-parse main)"
check "dist push: the Distribution repo's remote has its commits" "$dist_head" "$(git -C "$dist_remote" rev-parse main)"
check "dist push: both recorded in the Project, the Distribution repo's by name" "3fb49286 origin/main $start $head
3fb49286 distribution:origin/main $dist_start $dist_head" \
    "$(sed 's/ [^ ]*$//' "$(git -C "$project" rev-parse --path-format=absolute --git-path mp-supervise-pushed)")"
mkdir -p "$CLAUDE_CONFIG_DIR/jobs/3fb49286" "$CLAUDE_CONFIG_DIR/projects/p"
printf '{"sessionId": "s1", "children": []}\n' >"$CLAUDE_CONFIG_DIR/jobs/3fb49286/state.json"
: >"$CLAUDE_CONFIG_DIR/projects/p/s1.jsonl"
check "dist push: actions.sh names the Project's branch as the supervisor's push" \
    "branch origin/main pushed by the supervisor on the maintainer's approval: holds the worker's commits" \
    "$(sh "$scripts/actions.sh" --id 3fb49286 --dir "$project" --start "$start" </dev/null)"

# Only the Distribution repo has commits: the Project is passed over.
new_dist
out=$(dpush --sweep "$sweep")
check "dist only: exits 0" "0" "$?"
check "dist only: the Project has nothing to go" "ok project fast-forward: nothing to push, 0 ahead of origin/main" \
    "$(printf '%s\n' "$out" | grep '^ok project fast-forward')"
check "dist only: only the Distribution repo is pushed" "pushed distribution:origin/main $(dshort "$dist_start")..$(dshort "$dist_head")" \
    "$(printf '%s\n' "$out" | grep '^pushed')"
check "dist only: the Distribution repo's remote has its commits" "$dist_head" "$(git -C "$dist_remote" rev-parse main)"
check "dist only: the Project's empty range is not swept" "ok project sweep: nothing to push" \
    "$(printf '%s\n' "$out" | grep '^ok project sweep')"
check "dist only: only the Distribution repo is swept" "$dist --range $dist_start..$dist_head" "$(command cat "$work/sweep-log")"

# A failing check in either repo pushes neither.
dist_refused() { # <name> <expected fail lines>
    out=$(dpush --sweep "$sweep")
    check "$1: exits 2" "2" "$?"
    check "$1: says which" "$2" "$(printf '%s\n' "$out" | grep '^fail')"
    nothing_pushed "$1"
}
new_dist 1
printf '%s\n' "$dist" >"$work/sweep-hit"
dist_refused "dist sweep hits" "fail distribution sweep: exit 1 over $(dshort "$dist_start")..$(dshort "$dist_head")"
check "dist sweep hits: its output is shown" "  docs/x.md:3: private path" "$(dpush --sweep "$sweep" | grep '^  ')"

new_dist 1
printf '{"name": "d", "version": "1.3.0"}\n' >"$dist/plugin/.claude-plugin/plugin.json"
repo_git "$dist" commit -q --amend -am "Bump plugin to 1.3.0"
dist_refused "dist minor bump" "fail distribution version: plugin/.claude-plugin/plugin.json 1.2.3 -> 1.3.0 is past a patch bump"

new_dist 1
printf 'x\n' >"$(git -C "$dist" rev-parse --path-format=absolute --git-path mp-supervise-worker)"
dist_refused "dist marker in place" "fail distribution marker: worker x still holds the checkout; stop it and release its marker first"

new_dist 1
echo dirty >>"$dist/code.txt"
dist_refused "dist dirty tree" "fail distribution tree: 1 uncommitted path"

new_dist 1
echo dirty >>"$project/file.txt"
dist_refused "project dirty, dist clean" "fail project tree: 1 uncommitted path"

new_dist
repo_git "$dist" reset -q --hard "$dist_start"
dist_refused "nothing in either" "fail fast-forward: nothing to push in the Project or its Distribution repo"

# The second push failing leaves the first in place, and says so.
new_dist 1
printf '#!/bin/sh\nexit 1\n' >"$dist_remote/hooks/pre-receive"
chmod +x "$dist_remote/hooks/pre-receive"
out=$(dpush --sweep "$sweep")
check "dist push refused by its remote: exits 3" "3" "$?"
check "dist push refused by its remote: names what already went" "Error: origin/main was already pushed" \
    "$(printf '%s\n' "$out" | tail -n 1)"

# Usage: --dist-start goes with a Distribution repo, and only with one.
new_dist 1
out=$(push --sweep "$sweep")
check "dist usage: --dist-start is required" "1 Error: --dist-start is required: $project names Distribution repo $dist (give the snapshot's dist head line)" \
    "$? $(printf '%s\n' "$out" | tail -n 1)"
nothing_pushed "dist usage"
new_project
out=$(sh "$scripts/push.sh" --dir "$project" --id 3fb49286 --start "$start" --dist-start "$start" --sweep "$sweep" </dev/null 2>&1)
check "dist usage: --dist-start with no Distribution repo" "1 Error: --dist-start given, but $project names no Distribution repo" "$? $out"

echo "supervise-push: $pass passed, $fail failed"
[ "$fail" = 0 ]
