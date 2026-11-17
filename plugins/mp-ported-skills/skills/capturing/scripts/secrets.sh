#!/bin/sh
# secrets.sh -- the changed files that look like they hold a credential
# (#93). Capturing's move 5 runs it where it shows the changes it is about
# to commit, so a key or a token is pointed out before it is offered for a
# commit, and an unattended capture never commits one.
#
# A file is flagged by its name (an .env file, a private key file, a
# credentials or keychain export) or by its text (a private key header, or
# a string shaped like a known kind of token). A sample .env (.env.example,
# .env.sample, .env.template) is meant to be committed, so its name alone
# does not flag it; its text is still read. Only the changes are read, never
# the whole repo or its history, and a deleted file has nothing to commit.
# The rules are a net for the common shapes, not a scanner: a file not
# flagged is not shown to be clean.
#
# Usage:
#   secrets.sh [--dir DIR] [PATH...]
#
# DIR defaults to the working directory. PATHs, relative to DIR, are the
# files to read; with none, every file git status shows as changed, staged
# or untracked (not ignored) is read.
#
# Prints one line per flagged file, sorted by path:
#   flagged <path>: <why>
# or `secrets: none`. Exits 0 for both, and 1 on a usage error or when DIR
# is no git repo.

set -u

DIR="."
need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --dir) need_value "$@"; DIR="$2"; shift 2 ;;
        --help)
            printf 'Usage: secrets.sh [--dir DIR] [PATH...]\n'
            printf 'Prints the changed files that look like they hold a credential.\n'
            exit 0 ;;
        --) shift; break ;;
        -*) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
        *) break ;;
    esac
done
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || fail "$DIR is no git repo"

# why <path>: prints why the file looks like a credential, or nothing.
why() {
    # A deleted file has nothing to commit.
    [ -e "$DIR/$1" ] || return 0
    base=${1##*/}
    case $base in
        (.env.example | .env.sample | .env.template | *.env.example | *.env.sample | *.env.template) ;;
        (.env | .env.* | *.env) echo "an .env file"; return ;;
        (id_rsa | id_dsa | id_ecdsa | id_ed25519 | id_ecdsa_sk | id_ed25519_sk | *.pem | *.key | *.p12 | *.pfx | *.ppk)
            echo "a private key file name"; return ;;
        (credentials | credentials.json | credentials.csv | .netrc | .pgpass | *.keychain | *.keychain-db | *.kdbx)
            echo "a credentials or keychain export"; return ;;
    esac
    [ -f "$DIR/$1" ] || return 0
    # -I skips a binary file's text.
    if grep -qIE -- '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY( BLOCK)?-----' "$DIR/$1" 2>/dev/null; then
        echo "holds a private key header"; return
    fi
    for rule in \
        'GitHub token|gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,}' \
        'Anthropic key|sk-ant-[A-Za-z0-9_-]{20,}' \
        'OpenAI-style key|sk-(proj-)?[A-Za-z0-9]{32,}' \
        'AWS access key|(AKIA|ASIA)[0-9A-Z]{16}' \
        'Slack token|xox[abposr]-[A-Za-z0-9-]{10,}' \
        'Google API key|AIza[0-9A-Za-z_-]{35}' \
        'Stripe key|[rs]k_live_[0-9A-Za-z]{20,}'
    do
        kind=${rule%%|*}
        if grep -qIE -- "${rule#*|}" "$DIR/$1" 2>/dev/null; then
            echo "holds a token-shaped string ($kind)"; return
        fi
    done
}

if [ $# -gt 0 ]; then
    paths=$(printf '%s\n' "$@")
else
    # Paths relative to the repo's top, made relative to DIR below. A
    # deleted file is left out by --diff-filter=d.
    paths=$({
        git -C "$DIR" -c core.quotePath=false diff --name-only --diff-filter=d --relative
        git -C "$DIR" -c core.quotePath=false diff --cached --name-only --diff-filter=d --relative
        git -C "$DIR" -c core.quotePath=false ls-files --others --exclude-standard
    } | sort -u) || fail "git status could not be read in $DIR"
fi

found=$(printf '%s\n' "$paths" | while IFS= read -r p; do
    [ -n "$p" ] || continue
    w=$(why "$p")
    [ -z "$w" ] || printf 'flagged %s: %s\n' "$p" "$w"
done | sort)
if [ -n "$found" ]; then printf '%s\n' "$found"; else echo "secrets: none"; fi
