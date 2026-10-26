#!/bin/sh
# deny-worker-grant-edits.sh -- PreToolUse hook: refuse a background
# worker's own edit to the grant file or the profile directory (#58), by
# the Edit tools or by a Bash command it can read (#173).
#
# A standing grant is only trustworthy if a worker cannot grant itself one:
# deny-shared-actions.sh reads docs/agents/supervision.md from the default
# branch as committed on origin, never the working tree, which keeps an
# uncommitted or unpushed edit from taking effect, but a worker could still
# edit the committed copy heading into its next commit, or edit the
# profile's own files under $CLAUDE_CONFIG_DIR (rules, settings, hooks, and
# the plugin cache holding these gates) that this session, or a future one,
# reads. This hook refuses an Edit, Write or NotebookEdit whose target is
# docs/agents/supervision.md, or docs/agents/distribution-repo.md, which
# names the Project's Distribution repo (#125), in the checkout the session
# is working in, or any path under $CLAUDE_CONFIG_DIR, in an unattended,
# auto-mode session -- a /supervise worker, or any other background session
# launched the same way. The maintainer's own interactive session, whatever
# its permission mode, is never in scope.
#
# The session's own job folder, $CLAUDE_CONFIG_DIR/jobs/<first 8 of the
# session id> (where Claude Code tells a background session to keep its
# temp files, $CLAUDE_JOB_DIR), is not protected; another job's folder is.
# A path is compared after `..` and symlinks are resolved, so one that only
# looks like it is inside the job folder is not.
#
# For Bash (#173), the hook reads the command text, quotes and heredocs
# included, and refuses a write it can see to a protected path: `>`, `>>`
# and `&>` redirection, tee, sed/perl/ruby -i, cp, ln and install onto one,
# mv, rm, rmdir, unlink, touch, truncate, mkdir and chmod on one, dd of=,
# and the same inside `sh -c` and eval. It also refuses an interpreter or
# a script run while the command's working directory, after any cd, is in
# the profile directory outside the job folder: the shape a worker used to
# rewrite a profile rule, `cd <profile>/rules && python3 <job>/tmp/r.py`.
# A path is resolved against the session cwd and any cd before it, with
# $CLAUDE_CONFIG_DIR, $CLAUDE_JOB_DIR, $HOME and ~ written in the command
# expanded. Reads are never refused, nor is `claude plugin update`, which
# writes the plugin cache through Claude Code itself.
#
# Detection is CLAUDE_CODE_SESSION_ATTENDED and permission_mode, the same
# two signals deny-shared-actions.sh uses (docs/adr/0004): both must hold.
#
# Known gap: a write this text scan cannot see gets through -- a path built
# at run time (`d=$CLAUDE_CONFIG_DIR; ... > "$d/x"`), a program that writes
# on its own (`python3 -c` with an absolute path, a script run from
# elsewhere), find -exec, xargs. The supervisor's after-run comparison
# reports those (#190).
#
# Reads the PreToolUse payload on stdin. Prints a deny decision and exits 0
# when the call is refused; otherwise prints nothing and exits 0. A missing
# jq or an unreadable payload lets the call through.

[ "${CLAUDE_CODE_SESSION_ATTENDED:-1}" = 0 ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)

field() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

mode=$(field .permission_mode)
[ "$mode" = auto ] || exit 0

tool=$(field .tool_name)
case "$tool" in
    Edit | Write | NotebookEdit | Bash) ;;
    *) exit 0 ;;
esac

cwd=$(field .cwd)
[ -n "$cwd" ] || cwd=$(pwd)
set -f
oldIFS=$IFS

# resolve <path> <base>: the path made absolute against the base folder.
resolve() {
    case "$1" in
        /*) printf '%s' "$1" ;;
        '~') printf '%s' "$HOME" ;;
        '~/'*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
        *) printf '%s/%s' "$2" "$1" ;;
    esac
}

# norm <absolute path>: `.`, `..` and repeated slashes removed, lexically.
norm() {
    _n=""
    IFS=/
    for _c in $1; do
        case "$_c" in
            '' | .) ;;
            ..) _n=${_n%/*} ;;
            *) _n="$_n/$_c" ;;
        esac
    done
    IFS=$oldIFS
    printf '%s' "${_n:-/}"
}

# physical <absolute path>: the path with symlinks resolved -- the path
# itself while it is a link, then the deepest folder of it that exists --
# so a link out of the job folder is judged by where it points.
physical() {
    _p=$(norm "$1")
    _i=0
    while [ -L "$_p" ] && [ "$_i" -lt 20 ]; do
        _t=$(readlink -- "$_p") || break
        case "$_t" in /*) ;; *) _t="$(dirname -- "$_p")/$_t" ;; esac
        _p=$(norm "$_t")
        _i=$((_i + 1))
    done
    _d=$_p _r=""
    while [ ! -d "$_d" ] && [ "$_d" != / ]; do
        _r="/${_d##*/}$_r"
        _d=$(dirname -- "$_d")
    done
    _d=$(CDPATH= cd -P -- "$_d" 2>/dev/null && pwd) || _d=$(dirname -- "$_p")
    _d="${_d%/}$_r"
    printf '%s' "${_d:-/}"
}

# The profile directory as CLAUDE_CONFIG_DIR names it (cfg_shown, for the
# refusal text) and resolved (cfg), so a trailing slash, a relative value or
# a symlinked folder does not defeat the prefix check.
cfg_shown=${CLAUDE_CONFIG_DIR:-} cfg=""
if [ -n "$cfg_shown" ]; then
    cfg_shown=$(resolve "$cfg_shown" "$HOME")
    cfg_shown=${cfg_shown%/}
    cfg=$(physical "$cfg_shown")
fi

# The session's own job folder: Claude Code names it from the first 8
# characters of the session id. CLAUDE_JOB_DIR, when the hook has it, is
# taken only if it is a job folder of this profile.
job="" job_raw=""
if [ -n "$cfg" ]; then
    sid=$(field .session_id)
    sid=${sid%%-*}
    sid=$(printf '%.8s' "$sid")
    case "$sid" in '' | . | .. | */*) ;; *) job_raw="$cfg_shown/jobs/$sid" job="$cfg/jobs/$sid" ;; esac
    if [ -n "${CLAUDE_JOB_DIR:-}" ]; then
        _j=$(physical "$(resolve "$CLAUDE_JOB_DIR" "$HOME")")
        case "$_j" in "$cfg"/jobs/*/*) ;; "$cfg"/jobs/?*) job_raw=$CLAUDE_JOB_DIR job=$_j ;; esac
    fi
fi

# protected <absolute path>: sets kind to grant, dist or profile when the
# path is one this hook guards, or to empty.
protected() {
    kind=""
    _a=$(physical "$1")
    # The grant file, found from the checkout the path lands in (its own
    # folder, walked up to one that exists, since a write may create it).
    _d=$(dirname -- "$_a")
    while [ ! -d "$_d" ] && [ "$_d" != / ]; do _d=$(dirname -- "$_d"); done
    if _top=$(git -C "$_d" rev-parse --show-toplevel 2>/dev/null); then
        [ "$_a" = "$_top/docs/agents/supervision.md" ] && { kind=grant; return; }
        [ "$_a" = "$_top/docs/agents/distribution-repo.md" ] && { kind=dist; return; }
    fi
    [ -n "$cfg" ] || return
    if [ -n "$job" ]; then
        case "$_a" in "$job" | "$job"/*) return ;; esac
    fi
    case "$_a" in "$cfg" | "$cfg"/*) kind=profile ;; esac
}

# What each kind is, and why a worker may not change it.
what() {
    case "$kind" in
        grant) printf 'docs/agents/supervision.md' ;;
        dist) printf 'docs/agents/distribution-repo.md' ;;
        profile) printf 'its own profile directory (%s)' "$cfg_shown" ;;
    esac
}
why() {
    case "$kind" in
        grant) printf 'a worker that could grant itself a standing grant would make the grant meaningless.' ;;
        dist) printf 'it names the repo /supervise checks and holds read-only for the worker, and a worker that could repoint it could move its work out of that hold.' ;;
        profile) printf "that is where this session's rules, settings and hooks live, and a worker that could change them could change what gates it." ;;
    esac
}
issue() { if [ "$kind" = dist ]; then printf '#125'; else printf '#58'; fi; }

refuse() {
    jq -cn --arg reason "$1" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
    exit 0
}

if [ "$tool" != Bash ]; then
    path=$(field '.tool_input.file_path // .tool_input.notebook_path')
    [ -n "$path" ] || exit 0
    protected "$(resolve "$path" "$cwd")"
    [ -n "$kind" ] &&
        refuse "A background session in auto mode cannot edit $(what) on its own ($(issue)): $(why) Leave this to the maintainer's own interactive session."
    exit 0
fi

cmd=$(field .tool_input.command)
[ -n "$cmd" ] || exit 0

# tokens <text>: the command's words, one per line, each prefixed by its
# type: `w` a word (quotes removed, a newline inside one read as a space),
# `s` the end of a simple command (`;`, `&`, `|`, parens, backticks, a
# newline), `r` an output redirection (`>`, `>>`, `>|`, `&>`), `d` a
# `>&` duplication, `i` an input redirection. A heredoc's body is left out:
# it is data for the command, not commands, and a script written into the
# job folder may well name a protected path. A comment is left out too.
tokens() {
    printf '%s' "$1" | awk '
        function flush() {
            if (inw) {
                if (wanth) { hq[++nh] = w; hdash[nh] = dash; wanth = 0 }
                else print "w" w
            }
            w = ""; inw = 0
        }
        { s = s (NR > 1 ? "\n" : "") $0 }
        END {
            sq = sprintf("%c", 39); q = ""; w = ""; inw = 0; nh = 0; n = length(s)
            for (i = 1; i <= n; i++) {
                c = substr(s, i, 1)
                if (q == sq) { if (c == sq) q = ""; else w = w (c == "\n" ? " " : c); continue }
                if (q == "\"") {
                    if (c == "\\" && i < n && index("\"\\$`", substr(s, i + 1, 1))) { w = w substr(s, i + 1, 1); i++; continue }
                    if (c == "\"") q = ""; else w = w (c == "\n" ? " " : c)
                    continue
                }
                if (c == "\\" && i < n) { d = substr(s, i + 1, 1); i++; if (d != "\n") { w = w d; inw = 1 }; continue }
                if (c == sq || c == "\"") { q = c; inw = 1; continue }
                if (c == "#" && !inw) { while (i < n && substr(s, i + 1, 1) != "\n") i++; continue }
                if (c == " " || c == "\t") { flush(); continue }
                if (c == "\n") {
                    flush(); print "s"
                    for (h = 1; h <= nh; h++) {
                        while (i < n) {
                            j = index(substr(s, i + 1), "\n")
                            line = j ? substr(s, i + 1, j - 1) : substr(s, i + 1)
                            i = j ? i + j : n
                            if (hdash[h]) sub(/^\t+/, "", line)
                            if (line == hq[h]) break
                        }
                    }
                    nh = 0
                    continue
                }
                if (c == "&" && substr(s, i + 1, 1) == ">") {
                    flush(); i++
                    if (substr(s, i + 1, 1) == ">") i++
                    print "r"; continue
                }
                if (c == ">") {
                    if (w ~ /^[0-9]+$/) { w = ""; inw = 0 } else flush()
                    d = substr(s, i + 1, 1)
                    if (d == "&") { i++; print "d"; continue }
                    if (d == ">" || d == "|") i++
                    print "r"; continue
                }
                if (c == "<") {
                    if (w ~ /^[0-9]+$/) { w = ""; inw = 0 } else flush()
                    if (substr(s, i + 1, 2) == "<<") { i += 2; print "i"; continue }
                    if (substr(s, i + 1, 1) == "<") {
                        i++; dash = 0
                        if (substr(s, i + 1, 1) == "-") { i++; dash = 1 }
                        wanth = 1; continue
                    }
                    if (substr(s, i + 1, 1) == "&") i++
                    print "i"; continue
                }
                if (index(";&|()`", c)) {
                    if (c == "(" && w ~ /\$$/) w = substr(w, 1, length(w) - 1)
                    flush(); print "s"; continue
                }
                w = w c; inw = 1
            }
            flush()
        }'
}

# expand <word>: $CLAUDE_CONFIG_DIR, $CLAUDE_JOB_DIR and $HOME (bare or
# braced) and ~ at the start of a word, as the shell would.
expand() {
    _w=$1
    for _v in CLAUDE_CONFIG_DIR CLAUDE_JOB_DIR HOME; do
        case "$_v" in
            CLAUDE_CONFIG_DIR) _val=$cfg_shown ;;
            CLAUDE_JOB_DIR) _val=$job_raw ;;
            HOME) _val=$HOME ;;
        esac
        [ -n "$_val" ] || continue
        case "$_w" in
            "\${$_v}"*) _w="$_val${_w#"\${$_v}"}" ;;
            "\$$_v"/* | "\$$_v") _w="$_val${_w#"\$$_v"}" ;;
        esac
    done
    printf '%s' "$_w"
}

# check <form> <word>: refuse when the word, as a path, is protected.
check() {
    [ -n "$2" ] || return 0
    _abs=$(resolve "$(expand "$2")" "$base")
    protected "$_abs"
    [ -n "$kind" ] || return 0
    refuse "A background session in auto mode cannot write $(what) from Bash on its own ($(issue), #173; '$1' writes $(norm "$_abs")): $(why) Leave this to the maintainer's own interactive session."
}

# run_check <program>: refuse an interpreter or a script run while the
# working directory is in the profile directory outside the job folder.
run_check() {
    protected "$base/."
    [ "$kind" = profile ] || return 0
    refuse "A background session in auto mode cannot run '$1' with its working directory in $(what) on its own (#173): a script run there can write the rules, settings and hooks beside it, and a worker that could change them could change what gates it. Run it from the job folder or the checkout, or leave this to the maintainer's own interactive session."
}

# command_done: judge the simple command whose words are in $words.
command_done() {
    IFS='
'
    # shellcheck disable=SC2086
    set -- $words
    IFS=$oldIFS
    words=""
    # Each word was stored with a `w` in front, so an empty one (`sed -i
    # ''`) keeps its place; take it off.
    for _a in "$@"; do shift; set -- "$@" "${_a#w}"; done
    # Skip words that run what follows them, each past its own flags.
    while [ $# -gt 0 ]; do
        case "$1" in
            [A-Za-z_]*=*) shift; continue ;;
            '{' | '}' | '!' | if | then | else | elif | do | while | until) shift; continue ;;
        esac
        case "${1##*/}" in
            env | command | builtin | exec | time | nohup | nice | timeout | gtimeout | sudo)
                shift
                while [ $# -gt 0 ]; do
                    case "$1" in
                        -u | -C | -P | -n | -s | -k | -a) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
                        -* | [0-9]* | [A-Za-z_]*=*) shift ;;
                        *) break ;;
                    esac
                done
                ;;
            *) break ;;
        esac
    done
    [ $# -gt 0 ] || return 0
    prog=$1
    name=${1##*/}
    shift
    inplace=""
    for _a in "$@"; do
        case "$_a" in --in-place*) inplace=yes ;; --*) ;; -*i*) inplace=yes ;; esac
    done
    case "$name" in
        cd)
            while [ "${1:-}" = -P ] || [ "${1:-}" = -L ] || [ "${1:-}" = -e ]; do shift; done
            [ "${1:-}" != -- ] || shift
            case "${1:-}" in
                '') base=$HOME ;;
                -*) ;;
                *) base=$(norm "$(resolve "$(expand "$1")" "$base")") ;;
            esac
            return 0
            ;;
        tee | rm | rmdir | unlink | touch | truncate | mkdir | chmod | mv)
            for _a in "$@"; do case "$_a" in -*) ;; *) check "$name" "$_a" ;; esac; done
            ;;
        sed)
            if [ -n "$inplace" ]; then
                for _a in "$@"; do case "$_a" in -*) ;; *) check "sed -i" "$_a" ;; esac; done
            fi
            ;;
        cp | ln | install)
            _last="" _t=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    -t) _t=${2:-}; if [ $# -ge 2 ]; then shift 2; else shift; fi; continue ;;
                    --target-directory=*) _t=${1#*=} ;;
                    -*) ;;
                    *) _last=$1 ;;
                esac
                shift
            done
            check "$name" "${_t:-$_last}"
            ;;
        dd)
            for _a in "$@"; do case "$_a" in of=*) check dd "${_a#of=}" ;; esac; done
            ;;
        eval)
            bodies="$bodies$(printf '\n%s' "$*")"
            ;;
        sh | bash | zsh | dash | ksh)
            _c=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --*) shift ;;
                    -*c*) _c=yes; shift; break ;;
                    -*) shift ;;
                    *) break ;;
                esac
            done
            if [ -n "$_c" ]; then
                bodies="$bodies$(printf '\n%s' "${1:-}")"
            else
                run_check "$name"
            fi
            ;;
    esac
    case "$name" in
        perl | ruby)
            if [ -n "$inplace" ]; then
                for _a in "$@"; do case "$_a" in -*) ;; *) check "$name -i" "$_a" ;; esac; done
            fi
            ;;
    esac
    case "$name" in
        python | python[0-9]* | perl | ruby | node | deno | bun | php | lua | osascript | awk | gawk | swift | fish)
            run_check "$name" ;;
        */*) ;;
        *) case "$prog" in */*) run_check "$prog" ;; esac ;;
    esac
}

# scan <text>: judge each command in the text, in order, following cd.
scan() {
    words="" expect=""
    IFS='
'
    for tok in $(tokens "$1"; echo s); do
        IFS=$oldIFS
        t=${tok#?}
        case "$tok" in
            s*) expect=""; [ -z "$words" ] || command_done ;;
            r* | d* | i*) expect=${tok%"$t"} ;;
            w*)
                case "$expect" in
                    r) check '>' "$t" ;;
                    d) case "$t" in '' | - | *[!0-9]*) [ "$t" = - ] || check '>&' "$t" ;; esac ;;
                    i) ;;
                    *) words="$words$(printf '\n%s' "w$t")" ;;
                esac
                expect=""
                ;;
        esac
        IFS='
'
    done
    IFS=$oldIFS
}

base=$cwd bodies=""
scan "$cmd"
# A shell's -c text and eval's arguments are commands too, run where the
# command that ran them was; scanned after, from the folder the last cd left.
while [ -n "$bodies" ]; do
    b=$bodies bodies=""
    IFS='
'
    for body in $b; do IFS=$oldIFS; [ -z "$body" ] || scan "$body"; IFS='
'; done
    IFS=$oldIFS
done

exit 0
