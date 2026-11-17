#!/bin/sh
# capturing-secrets.test.sh -- tests for the capturing skill's secrets.sh
# (#93): which changed files look like they hold a credential, before
# capturing's move 5 offers to commit them.
#
# Builds a scratch repo with changed, staged and untracked files. Every
# key header and token below is built from pieces, so no whole one is
# written in this file: a push holding one would be refused by a host's
# secret scanning, or read as a leak. Touches nothing outside its own
# mktemp directory.
#
# Usage: sh tests/capturing-secrets.test.sh

set -u
unset CLAUDE_CODE_SESSION_ATTENDED

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script="$root/plugins/mp-ported-skills/skills/capturing/scripts/secrets.sh"
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
repo_git() { # <folder> <git args...> -- git there, unsigned, with a test identity
    repo_dir=$1; shift
    git -C "$repo_dir" -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@"
}

dashes=-----
key_header="${dashes}BEGIN OPENSSH PRIV""ATE KEY${dashes}"
gh_token="gh""p_$(printf 'a1B2c3D4e5%.0s' 1 2 3 4)abcd"

repo="$work/repo"
git init -q -b main "$repo"
printf 'echo hi\n' >"$repo/tool.sh"
printf 'old\n' >"$repo/notes.md"
repo_git "$repo" add tool.sh notes.md
repo_git "$repo" commit -q -m start

run() { sh "$script" "$@" </dev/null 2>&1; }

check "secrets: nothing changed, none" "secrets: none" "$(run --dir "$repo")"

# An ordinary source change is not flagged.
printf 'echo hello\n' >"$repo/tool.sh"
check "secrets: an ordinary source file is not flagged" "secrets: none" "$(run --dir "$repo")"

# A changed .env, a private key header and a token, untracked or staged.
printf 'PORT=8080\n' >"$repo/.env"
mkdir -p "$repo/keys"
printf '%s\nb3BlbnNzaA==\n' "$key_header" >"$repo/keys/deploy"
printf 'token: %s\n' "$gh_token" >"$repo/notes.md"
repo_git "$repo" add notes.md
check "secrets: .env, key header and token flagged, source not" \
    "flagged .env: an .env file
flagged keys/deploy: holds a private key header
flagged notes.md: holds a token-shaped string (GitHub token)" "$(run --dir "$repo")"

# Named paths: only those are read.
check "secrets: named paths only" "flagged .env: an .env file" "$(run --dir "$repo" .env tool.sh)"
check "secrets: a named ordinary file, none" "secrets: none" "$(run --dir "$repo" tool.sh)"

# A sample .env is meant to be committed: its name alone does not flag it.
command rm -f "$repo/.env" "$repo/keys/deploy"
repo_git "$repo" reset -q notes.md
printf 'old\n' >"$repo/notes.md"
printf 'PORT=\n' >"$repo/.env.example"
check "secrets: a sample .env is not flagged by its name" "secrets: none" "$(run --dir "$repo")"

# A key file by its name, empty or not.
: >"$repo/id_ed25519"
check "secrets: a private key file name" "flagged id_ed25519: a private key file name" "$(run --dir "$repo" id_ed25519)"
command rm -f "$repo/id_ed25519"

# A deleted file has nothing to commit and is not read.
command rm -f "$repo/tool.sh"
check "secrets: a deleted file is skipped" "secrets: none" "$(run --dir "$repo")"

# Usage errors exit 1.
sh "$script" --dir "$work/nowhere" </dev/null >/dev/null 2>&1
check "secrets: a folder that is no repo exits 1" 1 "$?"
sh "$script" --bogus </dev/null >/dev/null 2>&1
check "secrets: an unknown option exits 1" 1 "$?"

printf 'capturing-secrets: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
