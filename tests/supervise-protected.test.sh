#!/bin/sh
# supervise-protected.test.sh -- tests for supervise's protected.sh (#190):
# the record of a worker's protected files taken at launch, and the
# comparison actions.sh reports after the run.
#
# Touches nothing outside its own mktemp directories.
#
# Usage: sh tests/supervise-protected.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scripts="$root/plugins/mp-ported-skills/skills/supervise/scripts"
hooks="$root/plugins/mp-ported-skills/hooks/hooks.json"
export CLAUDE_PLUGIN_ROOT="$root/plugins/mp-ported-skills"
unset CLAUDE_JOB_DIR CLAUDE_CODE_SESSION_ATTENDED GIT_DIR GIT_WORK_TREE

pass=0 fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}

. "$scripts/protected.sh"

work=$(mktemp -d)
work=$(CDPATH= cd -- "$work" && pwd -P)
trap 'chmod -R u+rwx "$work" 2>/dev/null; rm -rf "$work"' EXIT

g() { git -C "$repo" -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@"; }
repo="$work/repo"
git init -q -b main "$repo"
mkdir -p "$repo/docs/agents"
printf -- '- push\n' >"$repo/docs/agents/supervision.md"
g add -A; g commit -q -m one
printf -- '- push\n- issue-close\n' >"$repo/docs/agents/supervision.md"
g commit -q -am two

cfg="$work/profile"
mkdir -p "$cfg/rules" "$cfg/hooks" "$cfg/plugins/cache/m/p/1.0/skills" "$cfg/plugins/marketplaces/m" \
    "$cfg/projects/-x/memory" "$cfg/jobs/abcd1234/tmp"
printf 'claude\n' >"$cfg/CLAUDE.md"
printf '{}\n' >"$cfg/settings.json"
printf 'rule\n' >"$cfg/rules/r.md"
printf 'hook\n' >"$cfg/hooks/h.sh"
printf 'skill\n' >"$cfg/plugins/cache/m/p/1.0/skills/a.md"
printf '{}\n' >"$cfg/plugins/installed_plugins.json"
printf 'clone\n' >"$cfg/plugins/marketplaces/m/f"
printf 't\n' >"$cfg/projects/-x/s.jsonl"
printf 'm\n' >"$cfg/projects/-x/memory/m.md"
src="$work/src"
printf 'other\n' >"$src"

rec=$(protected_record_path "$cfg" w1)
check "record path is in the profile" "$cfg/mp-supervise-protected/w1" "$rec"

# Every case snapshots the profile and repo, takes a record, changes
# something, compares, and puts the snapshot back.
cp -R "$cfg" "$work/cfg.orig"
fresh() {
    rm -rf "$cfg"; cp -R "$work/cfg.orig" "$cfg"
    g reset -q --hard
    g clean -qfdx
    g checkout -q main 2>/dev/null
    protected_record "$repo" "$cfg" "$rec" || echo "record failed"
}
cmp_out() { protected_compare "$rec" w1; }

fresh
check "no change, no line" "" "$(cmp_out)"
check "record ends with end" "end" "$(tail -n 1 "$rec")"
check "record holds the head" "head $(g rev-parse HEAD)" "$(sed -n 4p "$rec")"

# --- the writes the hook cannot see -------------------------------------
entry='.hooks.PreToolUse[] | select(.hooks[0].command | test("deny-worker-grant-edits"))'
hook_cmd=$(jq -r "$entry | .hooks[0].command" "$hooks")
hook_decision() { # <command>
    jq -cn --arg c "$1" --arg cwd "$work" \
        '{hook_event_name:"PreToolUse",session_id:"abcd1234-0000",permission_mode:"auto",
          tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
        CLAUDE_CODE_SESSION_ATTENDED=0 CLAUDE_CONFIG_DIR="$cfg" sh -c "$hook_cmd" >"$work/hook-out"
    if [ -s "$work/hook-out" ]; then jq -r '.hookSpecificOutput.permissionDecision' "$work/hook-out"; else echo allow; fi
}
printf -- '--- a\n+++ b\n@@ -1 +1 @@\n-rule\n+patched\n' >"$work/r.patch"
r="$cfg/rules/r.md"
route() { # <name> <command>
    fresh
    check "hook lets through $1" allow "$(hook_decision "$2")"
    (cd "$work" && CLAUDE_CONFIG_DIR="$cfg" sh -c "$2") >/dev/null 2>&1
    check "report lists a rule changed by $1" "protected-file changed ungranted: $r" "$(cmp_out)"
}
route "a path built at run time" 'd=$CLAUDE_CONFIG_DIR; printf x >>"$d/rules/r.md"'
route "python3 -c with an absolute path" "python3 -c \"open('$r', 'a').write('x')\""
route "sed's w command" "sed -n 'w $r' $src"
route "find -exec" "find $src -exec cp {} $r \\;"
route "xargs" "printf '%s\\n' $r | xargs -I{} cp $src {}"
route "rsync" "rsync $src $r"
route "patch" "patch $r $work/r.patch"

fresh
cmd="git -C $repo checkout HEAD~1 -- docs/agents/supervision.md"
check "hook lets through git checkout" allow "$(hook_decision "$cmd")"
sh -c "$cmd"
check "report lists the grant file git checkout changed" \
    "protected-file changed ungranted: $repo/docs/agents/supervision.md" "$(cmp_out)"

# --- each protected kind ------------------------------------------------
fresh
printf -- '- pr-merge\n' >>"$repo/docs/agents/supervision.md"
g commit -q -am grant
check "a committed grant change names the commit" \
    "protected-file changed ungranted: $repo/docs/agents/supervision.md, committed since $(sed -n 's/^head //p' "$rec" | cut -c1-7)" \
    "$(cmp_out)"

fresh
head=$(g rev-parse HEAD)
printf -- '- pr-merge\n' >>"$repo/docs/agents/supervision.md"
g commit -q -am grant
g show "$head:docs/agents/supervision.md" >"$repo/docs/agents/supervision.md"
check "a grant change committed and undone in the tree is still listed" \
    "protected-file committed ungranted: $repo/docs/agents/supervision.md (since $(printf '%.7s' "$head"))" "$(cmp_out)"

fresh
printf '../dist\n' >"$repo/docs/agents/distribution-repo.md"
check "a new Distribution-repo file is listed" \
    "protected-file added ungranted: $repo/docs/agents/distribution-repo.md" "$(cmp_out)"

fresh
printf '{"x":1}\n' >"$cfg/settings.json"
printf '{}\n' >"$cfg/settings.local.json"
check "a changed and a new settings file are listed" \
    "protected-file changed ungranted: $cfg/settings.json
protected-file added ungranted: $cfg/settings.local.json" "$(cmp_out)"

fresh
printf 'evil\n' >>"$cfg/plugins/cache/m/p/1.0/skills/a.md"
check "a changed plugin cache file is listed" \
    "protected-file changed ungranted: $cfg/plugins/cache/m/p/1.0/skills/a.md" "$(cmp_out)"

fresh
printf 'x\n' >"$cfg/plugins/cache/m/p/1.0/skills/b.md"
rm "$cfg/hooks/h.sh" "$cfg/CLAUDE.md"
check "a file added to an existing version folder, and removed files, are listed" \
    "protected-file removed ungranted: $cfg/CLAUDE.md
protected-file removed ungranted: $cfg/hooks/h.sh
protected-file added ungranted: $cfg/plugins/cache/m/p/1.0/skills/b.md" "$(cmp_out)"

fresh
mkdir -p "$cfg/skills/s"
printf 'x\n' >"$cfg/skills/s/SKILL.md"
check "a new profile skill is listed" "protected-file added ungranted: $cfg/skills/s/SKILL.md" "$(cmp_out)"

# --- what is left out ---------------------------------------------------
fresh
printf 't\n' >"$cfg/projects/-x/new.jsonl"
printf 't\n' >>"$cfg/projects/-x/s.jsonl"
printf 'j\n' >"$cfg/jobs/abcd1234/tmp/f"
mkdir -p "$cfg/jobs/other"; printf 'j\n' >"$cfg/jobs/other/state.json"
printf 'mm\n' >>"$cfg/projects/-x/memory/m.md"
printf 'n\n' >"$cfg/projects/-x/memory/n.md"
mkdir -p "$cfg/plugins/cache/m/p/2.0/skills" "$cfg/plugins/cache/temp_git_1/x"
printf 'new\n' >"$cfg/plugins/cache/m/p/2.0/skills/a.md"
printf 't\n' >"$cfg/plugins/cache/temp_git_1/x/f"
printf '{"v":2}\n' >"$cfg/plugins/installed_plugins.json"
printf 'pulled\n' >"$cfg/plugins/marketplaces/m/f"
mkdir -p "$cfg/cache"; printf 'c\n' >"$cfg/cache/c"
check "no line for transcripts, job folders, memory, caches or a new plugin version folder" "" "$(cmp_out)"

fresh
mkdir -p "$cfg/plugins/cache/m/p/2.0/skills"
printf 'new\n' >"$cfg/plugins/cache/m/p/2.0/skills/a.md"
rm -rf "$cfg/plugins/cache/m/p/1.0"
check "no line for a version folder pruned whole beside a new one" "" "$(cmp_out)"

fresh
rm -rf "$cfg/plugins/cache/m/p/1.0"
check "a version folder removed whole with no new one is one line" \
    "protected-file removed ungranted: $cfg/plugins/cache/m/p/1.0" "$(cmp_out)"

# A protected name that is a symlink is followed.
fresh
mv "$cfg/rules" "$work/linked-rules"
ln -s "$work/linked-rules" "$cfg/rules"
protected_record "$repo" "$cfg" "$rec" || echo "record failed"
printf 'changed\n' >"$work/linked-rules/r.md"
out=$(cmp_out)
rm -rf "$work/linked-rules"
check "a rule changed through a symlinked rules folder is listed" \
    "protected-file changed ungranted: $cfg/rules/r.md" "$out"

# --- a record that cannot be read ---------------------------------------
fresh
rm -f "$rec"
check "a missing record is reported" \
    "note no protected-file record for w1 ($rec), so changes to protected files were not checked" "$(cmp_out)"

fresh
sed '$d' "$rec" >"$rec.cut"; mv "$rec.cut" "$rec"
check "a cut record is reported" \
    "note the protected-file record for w1 ($rec) could not be read, so changes to protected files were not checked" "$(cmp_out)"

fresh
chmod 000 "$rec"
out=$(cmp_out)
chmod 644 "$rec"
case $out in
    'note the protected-file record for w1 '*'could not be read'*) pass=$((pass + 1)) ;;
    *) fail=$((fail + 1)); printf 'FAIL an unreadable record is reported\n  actual: %s\n' "$out" ;;
esac

fresh
chmod 000 "$cfg/rules/r.md"
out=$(cmp_out)
chmod 644 "$cfg/rules/r.md"
case $out in
    'note the protected files could not be read now ('*'), so changes to them were not checked') pass=$((pass + 1)) ;;
    *) fail=$((fail + 1)); printf 'FAIL a protected file unreadable now is reported\n  actual: %s\n' "$out" ;;
esac

chmod 000 "$cfg/rules/r.md"
protected_record "$repo" "$cfg" "$work/never" 2>/dev/null
check "a record that cannot read a file fails" "1 absent" "$? $([ -e "$work/never" ] && echo present || echo absent)"
chmod 644 "$cfg/rules/r.md"

# --- the shared definition ----------------------------------------------
check "grant kind" grant "$(protected_project_kind docs/agents/supervision.md)"
check "dist kind" dist "$(protected_project_kind docs/agents/distribution-repo.md)"
protected_project_kind docs/agents/other.md >/dev/null
check "another file has no kind" 1 "$?"

# --- actions.sh lists the comparison ------------------------------------
fresh
start=$(g rev-parse HEAD)
printf 'x\n' >>"$cfg/rules/r.md"
out=$(CLAUDE_CONFIG_DIR="$cfg" sh "$scripts/actions.sh" --id w1 --dir "$repo" --start "$start" </dev/null 2>&1)
case $out in
    *"protected-file changed ungranted: $cfg/rules/r.md"*) pass=$((pass + 1)) ;;
    *) fail=$((fail + 1)); printf 'FAIL actions.sh lists a protected-file change\n  actual: %s\n' "$out" ;;
esac
rm -f "$rec"
out=$(CLAUDE_CONFIG_DIR="$cfg" sh "$scripts/actions.sh" --id w1 --dir "$repo" --start "$start" </dev/null 2>&1)
case $out in
    *"note no protected-file record for w1 "*) pass=$((pass + 1)) ;;
    *) fail=$((fail + 1)); printf 'FAIL actions.sh notes a missing record\n  actual: %s\n' "$out" ;;
esac

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
