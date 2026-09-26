#!/bin/sh
# matt-skill-names.test.sh -- checks the Matt skill names our skills use.
#
# Ported skills name mattpocock-skills' skills as literal strings, and
# upstream renames and removes skills between releases. This finds the
# installed mattpocock-skills plugin (the newest version in the plugin cache
# under $CLAUDE_CONFIG_DIR, default ~/.claude) and checks that each name in
# the list below has a SKILL.md there, and that its invocation flag matches
# how our skills present it. It reads the real profile on purpose, unlike
# the other tests, since the installed plugin is what it checks; it writes
# nothing, and without a plugin it exits 2 and reports NOT CHECKED.
#
# Usage: sh tests/matt-skill-names.test.sh

set -u

# Every Matt skill name a ported skill uses, one per line: the name, then
# "user" when our skills tell the user to type it (upstream must set
# disable-model-invocation: true) or "model" when they tell the model to
# call it (upstream must not).
names='
implement user
triage user
wayfinder user
grill-with-docs user
improve-codebase-architecture user
setup-matt-pocock-skills user
to-questionnaire user
handoff user
domain-modeling model
writing-for-agents model
'

config=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
plugin=$(for d in "$config"/plugins/cache/*/mattpocock-skills/*/; do
        [ -d "$d/skills" ] && printf '%s\t%s\n' "$(basename "$d")" "${d%/}"
    done | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 | cut -f2)
if [ -z "$plugin" ]; then
    echo "NOT CHECKED: no mattpocock-skills plugin under $config/plugins/cache" >&2
    exit 2
fi
echo "plugin: $plugin"

pass=0 fail=0
while read -r name kind; do
    [ -n "$name" ] || continue
    set -- "$plugin"/skills/*/"$name"/SKILL.md
    if [ ! -f "$1" ]; then
        fail=$((fail + 1))
        printf 'FAIL %s: no SKILL.md in the plugin\n' "$name"
        continue
    fi
    # The flag counts only inside the frontmatter, between the first two ---.
    if awk '{ sub(/\r$/, "") } /^---$/ { n++; next } n == 1 && /^disable-model-invocation: *"?true"? *$/ { f = 1 } END { exit !f }' "$1"; then
        actual=user
    else
        actual=model
    fi
    if [ "$actual" = "$kind" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s: our skills treat it as %s-invoked, upstream is %s-invoked\n' "$name" "$kind" "$actual"
    fi
done <<EOF
$names
EOF

echo "matt-skill-names: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
