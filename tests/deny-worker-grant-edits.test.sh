#!/bin/sh
# deny-worker-grant-edits.test.sh -- tests for the PreToolUse hook that
# refuses a background worker's own edit to docs/agents/supervision.md,
# docs/agents/distribution-repo.md (#125) or the profile directory (#58).
#
# Runs the command string from hooks.json, as Claude Code does, with a
# PreToolUse payload on stdin and CLAUDE_CODE_SESSION_ATTENDED set the way
# Claude Code sets it in a background session's own process. Touches
# nothing outside its own mktemp directories.
#
# Usage: sh tests/deny-worker-grant-edits.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
hooks="$root/plugins/mp-ported-skills/hooks/hooks.json"
export CLAUDE_PLUGIN_ROOT="$root/plugins/mp-ported-skills"
# The session running the suite sets its own job folder; the hook reads it.
unset CLAUDE_JOB_DIR

pass=0 fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}

entry='.hooks.PreToolUse[] | select(.hooks[0].command | test("deny-worker-grant-edits"))'
hook_cmd=$(jq -r "$entry | .hooks[0].command" "$hooks")

run() { # <attended> <mode> <tool> <path> <cwd> [<config dir>]
    payload=$(jq -cn --arg mode "$2" --arg tool "$3" --arg path "$4" --arg cwd "$5" \
        '{hook_event_name:"PreToolUse",session_id:"s1",permission_mode:$mode,tool_name:$tool,
          tool_input:(if $tool == "NotebookEdit" then {notebook_path:$path} else {file_path:$path} end),
          cwd:$cwd}')
    printf '%s' "$payload" | CLAUDE_CODE_SESSION_ATTENDED="$1" CLAUDE_CONFIG_DIR="${6:-}" sh -c "$hook_cmd"
}
decision() { run "$1" "$2" "$3" "$4" "$5" "${6:-}" | jq -r '.hookSpecificOutput.permissionDecision // empty'; }
reason() { run "$1" "$2" "$3" "$4" "$5" "${6:-}" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty'; }

repo=$(mktemp -d)
repo=$(CDPATH= cd -- "$repo" && pwd -P)
git init -q -b main "$repo"
git -C "$repo" -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -q --allow-empty -m start
mkdir -p "$repo/docs/agents" "$repo/sub"

cfg=$(mktemp -d)

# The grant file, whether it exists yet or not, in an unattended auto-mode
# session: refused.
check "Write to a new supervision.md: deny" "deny" \
    "$(decision 0 auto Write "$repo/docs/agents/supervision.md" "$repo" "$cfg")"
touch "$repo/docs/agents/supervision.md"
check "Edit of an existing supervision.md: deny" "deny" \
    "$(decision 0 auto Edit "$repo/docs/agents/supervision.md" "$repo" "$cfg")"
check "NotebookEdit targeting supervision.md: deny" "deny" \
    "$(decision 0 auto NotebookEdit "$repo/docs/agents/supervision.md" "$repo" "$cfg")"
check "a relative path resolved against cwd: deny" "deny" \
    "$(decision 0 auto Edit docs/agents/supervision.md "$repo" "$cfg")"
check "the same file via a session run inside a subfolder: deny" "deny" \
    "$(decision 0 auto Edit "$repo/docs/agents/supervision.md" "$repo/sub" "$cfg")"

check "refusal names #58 and the maintainer's own session" \
    "A background session in auto mode cannot edit docs/agents/supervision.md on its own (#58): a worker that could grant itself a standing grant would make the grant meaningless. Leave this to the maintainer's own interactive session." \
    "$(reason 0 auto Edit "$repo/docs/agents/supervision.md" "$repo" "$cfg")"

# distribution-repo.md names the Distribution repo /supervise holds for the
# worker (#125), so a worker cannot repoint it either.
check "Write to distribution-repo.md: deny" "deny" \
    "$(decision 0 auto Write "$repo/docs/agents/distribution-repo.md" "$repo" "$cfg")"
check "Edit of distribution-repo.md from a subfolder: deny" "deny" \
    "$(decision 0 auto Edit "$repo/docs/agents/distribution-repo.md" "$repo/sub" "$cfg")"
check "distribution-repo.md: the reason names the file and the hold" \
    "A background session in auto mode cannot edit docs/agents/distribution-repo.md on its own (#125): it names the repo /supervise checks and holds read-only for the worker, and a worker that could repoint it could move its work out of that hold. Leave this to the maintainer's own interactive session." \
    "$(reason 0 auto Edit "$repo/docs/agents/distribution-repo.md" "$repo" "$cfg")"
check "distribution-repo.md in an interactive session is not refused" "" \
    "$(decision 1 auto Edit "$repo/docs/agents/distribution-repo.md" "$repo" "$cfg")"

# A different file in the same folder, or a similarly named file elsewhere,
# is not the grant file.
check "a sibling file in docs/agents is not refused" "" \
    "$(decision 0 auto Edit "$repo/docs/agents/domain.md" "$repo" "$cfg")"
check "supervision.md outside docs/agents is not refused" "" \
    "$(decision 0 auto Edit "$repo/supervision.md" "$repo" "$cfg")"
check "a file outside any checkout is not refused" "" \
    "$(decision 0 auto Edit "$(mktemp -d)/x.md" "$(mktemp -d)" "$cfg")"

# The profile directory: refused, nested or not.
check "a write under the profile directory: deny" "deny" \
    "$(decision 0 auto Write "$cfg/rules/x.md" "$repo" "$cfg")"
check "a write to the profile's settings.json: deny" "deny" \
    "$(decision 0 auto Edit "$cfg/settings.json" "$repo" "$cfg")"
check "refusal names the profile directory" \
    "A background session in auto mode cannot edit its own profile directory ($cfg) on its own (#58): that is where this session's rules, settings and hooks live, and a worker that could change them could change what gates it. Leave this to the maintainer's own interactive session." \
    "$(reason 0 auto Write "$cfg/rules/x.md" "$repo" "$cfg")"
check "a folder that only shares the profile dir's prefix is not refused" "" \
    "$(decision 0 auto Write "${cfg}-other/x.md" "$repo" "$cfg")"
check "no CLAUDE_CONFIG_DIR set: the profile check is skipped, not an error" "" \
    "$(decision 0 auto Write "$repo/elsewhere.md" "$repo" "")"

# The maintainer's own interactive session: attended, whatever the
# permission mode.
check "attended, auto mode: edit allowed" "" \
    "$(decision 1 auto Edit "$repo/docs/agents/supervision.md" "$repo" "$cfg")"
check "attended, default mode: edit allowed" "" \
    "$(decision 1 default Edit "$repo/docs/agents/supervision.md" "$repo" "$cfg")"

# Unattended outside auto mode: out of the way, as deny-shared-actions.sh
# treats it.
check "unattended, default mode: edit allowed" "" \
    "$(decision 0 default Edit "$repo/docs/agents/supervision.md" "$repo" "$cfg")"

# Bash (#173): a command that writes a protected path in a form the hook
# can read is refused. bash_run <attended> <mode> <command> <cwd> [<config
# dir>] sends a Bash payload; the session id s1 makes the session's own job
# folder <config dir>/jobs/s1, as Claude Code names it from the session id.
bash_run() {
    payload=$(jq -cn --arg mode "$2" --arg cmd "$3" --arg cwd "$4" \
        '{hook_event_name:"PreToolUse",session_id:"s1",permission_mode:$mode,tool_name:"Bash",
          tool_input:{command:$cmd},cwd:$cwd}')
    printf '%s' "$payload" | CLAUDE_CODE_SESSION_ATTENDED="$1" CLAUDE_CONFIG_DIR="${5:-}" sh -c "$hook_cmd"
}
bdecision() { bash_run "$1" "$2" "$3" "$4" "${5:-}" | jq -r '.hookSpecificOutput.permissionDecision // empty'; }
breason() { bash_run "$1" "$2" "$3" "$4" "${5:-}" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty'; }

job="$cfg/jobs/s1"
mkdir -p "$cfg/rules" "$job/tmp"
touch "$cfg/rules/supervise-runs-rule.md"

# The #151 shape: a heredoc writes a script into the job folder, then the
# script runs with its working directory in the profile's rules folder.
check "#151: heredoc writing a script into the job folder: allowed" "" \
    "$(bdecision 0 auto "cat > \$CLAUDE_JOB_DIR/tmp/r.py <<'EOF'
import pathlib
p = pathlib.Path('supervise-runs-rule.md')
p.write_text(p.read_text().replace('a', 'b'))
EOF" "$repo" "$cfg")"
check "#151: the same heredoc, the job folder written out: allowed" "" \
    "$(bdecision 0 auto "cat > $job/tmp/r.py <<'EOF'
open('$cfg/rules/supervise-runs-rule.md', 'w').write('x')
EOF" "$repo" "$cfg")"
check "a heredoc body that names a write is data, not a command: allowed" "" \
    "$(bdecision 0 auto "cat <<-EOF > $job/tmp/r.sh
	echo x > $cfg/rules/supervise-runs-rule.md
	EOF
echo done" "$repo" "$cfg")"
check "the command after a heredoc is still read: deny" "deny" \
    "$(bdecision 0 auto "cat > $job/tmp/r.sh <<'EOF'
echo x
EOF
echo x > $cfg/rules/supervise-runs-rule.md" "$repo" "$cfg")"
check "#151: cd into the profile's rules and run the script: deny" "deny" \
    "$(bdecision 0 auto "cd $cfg/rules && python3 $job/tmp/r.py" "$repo" "$cfg")"
check "#151: the refusal names the program, the folder and the maintainer" \
    "A background session in auto mode cannot run 'python3' with its working directory in its own profile directory ($cfg) on its own (#173): a script run there can write the rules, settings and hooks beside it, and a worker that could change them could change what gates it. Run it from the job folder or the checkout, or leave this to the maintainer's own interactive session." \
    "$(breason 0 auto "cd $cfg/rules && python3 $job/tmp/r.py" "$repo" "$cfg")"
check "#151: the cd written with \$CLAUDE_CONFIG_DIR: deny" "deny" \
    "$(bdecision 0 auto "cd \"\$CLAUDE_CONFIG_DIR/rules\"; python3 \"\$CLAUDE_JOB_DIR/tmp/r.py\"" "$repo" "$cfg")"
check "a script run from the job folder: allowed" "" \
    "$(bdecision 0 auto "cd $job/tmp && python3 r.py" "$repo" "$cfg")"
check "a script run from the checkout: allowed" "" \
    "$(bdecision 0 auto "python3 $job/tmp/r.py" "$repo" "$cfg")"

# Each write form the hook reads, with @ standing for the target.
forms='echo x > @
echo x >> @
echo x 2>@
echo x &> @
echo x>@
printf x | tee @
printf x | tee -a @
sed -i '"''"' -e s/a/b/ @
sed -i.bak s/a/b/ @
perl -pi -e s/a/b/ @
perl -i -pe s/a/b/ @
ruby -pi -e 1 @
cp /dev/null @
cp -f /dev/null "@"
mv @ /dev/null
ln -sf /dev/null @
rm -f @
touch @
install -m 644 /dev/null @
dd if=/dev/null of=@
sh -c "echo x > @"
bash -lc '"'"'printf x | tee @'"'"'
eval "rm @"
true && echo x > @
(echo x) > @
echo $(cat /dev/null) > @'
form_checks() { # <label> <expected> <target>
    IFS='
'
    set -f
    for f in $forms; do
        IFS=$oldIFS
        c=$(printf '%s' "$f" | sed "s|@|$3|g")
        check "$1: $f" "$2" "$(bdecision 0 auto "$c" "$repo" "$cfg")"
        IFS='
'
    done
    set +f
    IFS=$oldIFS
}
oldIFS=$IFS
form_checks "grant file" deny "$repo/docs/agents/supervision.md"
form_checks "distribution-repo.md" deny "$repo/docs/agents/distribution-repo.md"
form_checks "profile rule" deny "$cfg/rules/supervise-runs-rule.md"
form_checks "another job's folder" deny "$cfg/jobs/other/tmp/x.py"
form_checks "sibling of the grant file" "" "$repo/docs/agents/domain.md"
form_checks "own job folder" "" "$job/tmp/x.py"

check "a relative target after a cd: deny" "deny" \
    "$(bdecision 0 auto "cd docs/agents && echo x > supervision.md" "$repo" "$cfg")"
check "a relative target from a session in the folder: deny" "deny" \
    "$(bdecision 0 auto "echo x > supervision.md" "$repo/docs/agents" "$cfg")"
check "a redirect into the profile written with \${CLAUDE_CONFIG_DIR}: deny" "deny" \
    "$(bdecision 0 auto 'echo x > "${CLAUDE_CONFIG_DIR}/settings.json"' "$repo" "$cfg")"
check "a write to the job folder written with \$CLAUDE_JOB_DIR: allowed" "" \
    "$(bdecision 0 auto 'echo x > "$CLAUDE_JOB_DIR/tmp/msg.txt"' "$repo" "$cfg")"
check "\$HOME and ~ are expanded: deny" "deny deny" \
    "$( (export HOME="$cfg"; printf '%s %s' "$(bdecision 0 auto 'echo x > $HOME/rules/a.md' "$repo" "$cfg")" \
        "$(bdecision 0 auto 'echo x > ~/rules/a.md' "$repo" "$cfg")") )"
check "a .. out of the job folder: deny" "deny" \
    "$(bdecision 0 auto "echo x > $job/tmp/../../../rules/a.md" "$repo" "$cfg")"
ln -s "$cfg/rules" "$job/tmp/rules-link"
check "a symlink out of the job folder: deny" "deny" \
    "$(bdecision 0 auto "echo x > $job/tmp/rules-link/a.md" "$repo" "$cfg")"
check "the refusal names the form, the target and the maintainer" \
    "A background session in auto mode cannot write docs/agents/supervision.md from Bash on its own (#58, #173; 'sed -i' writes $repo/docs/agents/supervision.md): a worker that could grant itself a standing grant would make the grant meaningless. Leave this to the maintainer's own interactive session." \
    "$(breason 0 auto "sed -i '' s/a/b/ docs/agents/supervision.md" "$repo" "$cfg")"

# The Edit tools follow the same job-folder exception (#112).
check "Write to the session's own job folder: allowed" "" \
    "$(decision 0 auto Write "$job/tmp/edit.py" "$repo" "$cfg")"
check "Write to another job's folder: deny" "deny" \
    "$(decision 0 auto Write "$cfg/jobs/other/tmp/edit.py" "$repo" "$cfg")"
check "Write through .. out of the job folder: deny" "deny" \
    "$(decision 0 auto Write "$job/tmp/../../../settings.json" "$repo" "$cfg")"
check "Write through a symlink out of the job folder: deny" "deny" \
    "$(decision 0 auto Write "$job/tmp/rules-link/a.md" "$repo" "$cfg")"

# Reads of a protected path, and a plugin update, are never refused.
for c in "cat $repo/docs/agents/supervision.md" \
    "rg -n grant $repo/docs/agents/supervision.md $cfg/rules" \
    "git -C $repo show HEAD:docs/agents/supervision.md" \
    "jq . $cfg/settings.json" \
    "jq . $cfg/settings.json > $job/tmp/s.json" \
    "cp $cfg/rules/supervise-runs-rule.md $job/tmp/" \
    "cd $cfg/rules && cat supervise-runs-rule.md 2>&1" \
    "cd $cfg/rules && rg -n zone . >/dev/null" \
    "grep -c x < $cfg/rules/supervise-runs-rule.md" \
    "command claude plugin marketplace update mp-ported-skills && command claude plugin update mp-ported-skills@mp-ported-skills" \
    "git commit -m 'a > $cfg/rules/x'"; do
    check "read: $c" "" "$(bdecision 0 auto "$c" "$repo" "$cfg")"
done

# The maintainer's attended session, and an unattended one outside auto
# mode: Bash writes are not inspected.
check "attended, auto mode: Bash write allowed" "" \
    "$(bdecision 1 auto "echo x > $repo/docs/agents/supervision.md" "$repo" "$cfg")"
check "attended, default mode: Bash write allowed" "" \
    "$(bdecision 1 default "cd $cfg/rules && python3 r.py" "$repo" "$cfg")"
check "unattended, default mode: Bash write allowed" "" \
    "$(bdecision 0 default "echo x > $cfg/rules/a.md" "$repo" "$cfg")"

check "matcher: Edit, Write, NotebookEdit and Bash" "Edit|Write|NotebookEdit|Bash" "$(jq -r "$entry | .matcher" "$hooks")"
check "timeout set" "5" "$(jq -r "$entry | .hooks[0].timeout" "$hooks")"

command rm -rf "$repo" "$cfg"

echo "deny-worker-grant-edits: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
