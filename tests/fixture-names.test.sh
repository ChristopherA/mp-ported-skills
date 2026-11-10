#!/bin/sh
# fixture-names.test.sh -- checks that no test script holds a literal name a
# public-artifact sweep reads as a private project's.
#
# The maintainer's sweep treats any word ending in -dev, -private or -hub
# (one not preceded by a hyphen, so flags such as --save-dev pass) as a
# possible private project name, and Push on approval fails on a hit. A test
# that needs such a name, as the Distribution repo tests need a folder named
# for the -dev rule, builds it from a suffix variable ("app$dev"), so the
# literal never enters public source. This scans every tests/*.sh and
# tests/live/*.sh for the literal form and names each line that holds one.
# The transcript and pane fixtures are cut from real sessions and are left
# to their own README.
#
# Usage: sh tests/fixture-names.test.sh

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

pass=0 fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}

# The sweep's word rule: a letter-led word, hyphen-joined parts, then one of
# the suffixes, with no word character or hyphen on either side.
pattern='(^|[^-A-Za-z0-9_])[A-Za-z][A-Za-z0-9]*(-[A-Za-z0-9]+)*-(dev|private|hub)([^A-Za-z0-9_]|$)'

# The pattern itself must find the names it is for, or a clean scan proves
# nothing. Each sample is built from its parts, so this file stays clean too.
dev=-dev private=-private hub=-hub Dev=-Dev
for word in "app$dev" "fresh$dev" "my-app$private" "work$hub" "App$Dev"; do
    check "pattern matches $word" "1" "$(printf 'x "%s/y" z\n' "$word" | grep -ciE "$pattern")"
done
for word in "-$dev" "-$private" "a $dev folder" "/-work$hub" "app\$dev" "app${dev}ices"; do
    check "pattern passes $word" "0" "$(printf '%s\n' "$word" | grep -ciE "$pattern")"
done

set -- "$root"/tests/*.sh "$root"/tests/live/*.sh
check "scan: test scripts found" "yes" "$([ -f "$1" ] && echo yes || echo no)"
hits=$(grep -niE "$pattern" "$@" </dev/null | sed "s|^$root/||")
check "no literal -dev, -private or -hub name in a test script" "" "$hits"

echo "fixture-names: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
