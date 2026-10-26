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
# gawk -i inplace, and the same inside `sh -c`, eval, a subshell and a
# process substitution. It also refuses an interpreter, a sourced script,
# an awk program that can write (-f, or >, | or system in it), or a script
# run while the command's working directory, after any cd, cd -, pushd or
# popd, is in the profile directory outside the job folder: the shape a
# worker used to rewrite a profile rule, `cd <profile>/rules && python3
# <job>/tmp/r.py`. A path is resolved against the session cwd and any cd
# before it, with $CLAUDE_CONFIG_DIR, $CLAUDE_JOB_DIR, $HOME and ~ written
# in the command expanded, ${VAR:-default} and ${VAR%suffix} forms
# included, and matched in any case. Reads are never refused, nor is
# `claude plugin update`, which writes the plugin cache through Claude
# Code itself.
#
# Detection is CLAUDE_CODE_SESSION_ATTENDED and permission_mode, the same
# two signals deny-shared-actions.sh uses (docs/adr/0004): both must hold.
#
# Known gap: a write this text scan cannot see gets through -- a path built
# at run time (`d=$CLAUDE_CONFIG_DIR; ... > "$d/x"`), a program that writes
# on its own (`python3 -c` with an absolute path, a script run from
# elsewhere), sed's w command, find -exec, xargs, rsync, patch, git
# checkout. The
# supervisor's after-run comparison reports those (#190).
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
oldIFS=$IFS nl='
'

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

# existing <normalized absolute path>: sets existing_dir to the deepest
# folder of the path that exists, the path itself included.
existing() {
    existing_dir=$1
    while [ ! -d "$existing_dir" ] && [ "$existing_dir" != / ]; do
        existing_dir=${existing_dir%/*}
        existing_dir=${existing_dir:-/}
    done
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
    existing "$_p"
    _d=$existing_dir _r=${_p#"${existing_dir%/}"}
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

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
cfg_l=$(lower "$cfg")

# protected <absolute path>: sets kind to grant, dist or profile when the
# path is one this hook guards, or to empty. A macOS folder ignores case, so
# a protected path is matched in lower case; the job folder is matched
# exactly, so a differently cased one is not taken for it.
protected() {
    kind=""
    _a=$(physical "$1")
    _l=$(lower "$_a")
    # The grant file, found from the checkout the path lands in (its own
    # folder, walked up to one that exists, since a write may create it).
    # Only a path with one of the two names asks git, which is most of a
    # call's cost.
    case "$_l" in
        */docs/agents/supervision.md | */docs/agents/distribution-repo.md)
            existing "${_a%/*}"
            if _top=$(git -C "$existing_dir" rev-parse --show-toplevel 2>/dev/null); then
                _top=$(lower "$_top")
                [ "$_l" = "$_top/docs/agents/supervision.md" ] && { kind=grant; return; }
                [ "$_l" = "$_top/docs/agents/distribution-repo.md" ] && { kind=dist; return; }
            fi
            ;;
    esac
    [ -n "$cfg" ] || return
    if [ -n "$job" ]; then
        case "$_a" in "$job" | "$job"/*) return ;; esac
    fi
    case "$_l" in "$cfg_l" | "$cfg_l"/*) kind=profile ;; esac
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
# type: `w` a word (quotes removed, a newline inside one written as \037),
# `s` the end of a simple command (`;`, `&`, `|`, parens, backticks, a
# newline), `r` an output redirection (`>`, `>>`, `>|`, `&>`), `d` a
# `>&` duplication, `i` an input redirection, `b` the text of a process
# substitution, newlines written as \037. A heredoc's body is left out:
# it is data for the command, not commands, and a script written into the
# job folder may well name a protected path. A comment is left out too.
tokens() {
    printf '%s' "$1" | awk '
        function flush() {
            if (inw) {
                if (wanth) { gsub(nl, "\n", w); hq[++nh] = w; hdash[nh] = dash; wanth = 0 }
                else print "w" w
            }
            w = ""; inw = 0
        }
        # balanced: the text from i, an opening paren, to its closing one,
        # with i left on the closing one. A paren inside quotes or after a
        # backslash does not count.
        function balanced(   b, depth, bq) {
            b = ""; depth = 0; bq = ""
            for (; i <= n; i++) {
                c = substr(s, i, 1); b = b (c == "\n" ? nl : c)
                if (bq == sq) { if (c == sq) bq = ""; continue }
                if (c == "\\" && i < n && bq != sq) { i++; c = substr(s, i, 1); b = b (c == "\n" ? nl : c); continue }
                if (bq == "\"") { if (c == "\"") bq = ""; continue }
                if (c == sq || c == "\"") { bq = c; continue }
                if (c == "(") depth++
                else if (c == ")" && --depth == 0) break
            }
            return b
        }
        { s = s (NR > 1 ? "\n" : "") $0 }
        END {
            sq = sprintf("%c", 39); nl = sprintf("%c", 31); q = ""; w = ""; inw = 0; nh = 0; n = length(s)
            for (i = 1; i <= n; i++) {
                c = substr(s, i, 1)
                if (q == sq) { if (c == sq) q = ""; else w = w (c == "\n" ? nl : c); continue }
                if (q == "\"") {
                    if (c == "\\" && i < n && index("\"\\$`", substr(s, i + 1, 1))) { w = w substr(s, i + 1, 1); i++; continue }
                    if (c == "\"") q = ""; else w = w (c == "\n" ? nl : c)
                    continue
                }
                if (c == "\\" && i < n) { d = substr(s, i + 1, 1); i++; if (d != "\n") { w = w d; inw = 1 }; continue }
                if (c == sq || c == "\"") { q = c; inw = 1; continue }
                # Arithmetic, $((...)) or ((...)), is one word: its << and >
                # are operators, not a heredoc or a redirection. Only when it
                # closes on )): `((cd x; y) )` is a subshell in a subshell,
                # and the shell runs it as one.
                if ((c == "$" && substr(s, i + 1, 2) == "((") || (c == "(" && !inw && substr(s, i + 1, 1) == "(")) {
                    i0 = i; w0 = w
                    if (c == "$") { w = w c; i++ }
                    b = balanced()
                    if (substr(b, length(b) - 1) == "))") { w = w b; inw = 1; continue }
                    i = i0; w = w0; c = substr(s, i, 1)
                }
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
                # A process substitution, >(...) or <(...), is a command of
                # its own: its text goes out as a body to scan.
                if ((c == ">" || c == "<") && substr(s, i + 1, 1) == "(") {
                    flush(); i++; b = balanced()
                    print "b" substr(b, 2, length(b) - 2); continue
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

# expand <word>: $CLAUDE_CONFIG_DIR, $CLAUDE_JOB_DIR and $HOME (bare,
# braced, braced with a default, or with a prefix or suffix cut by # or %)
# and ~ at the start of a word, as the shell would.
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
            "\${$_v:+"* | "\${$_v+"*) ;;
            # A cut: the pattern is matched, never run, as the shell does.
            "\${$_v%%"*'}'* | "\${$_v%"*'}'* | "\${$_v##"*'}'* | "\${$_v#"*'}'*)
                _r=${_w#"\${$_v"}
                case "$_r" in %%* | '##'*) _op=${_r%"${_r#??}"} ;; *) _op=${_r%"${_r#?}"} ;; esac
                _r=${_r#"$_op"} _pat=${_r%%\}*} _r=${_r#*\}}
                case "$_op" in
                    %%) _w="${_val%%$_pat}$_r" ;;
                    %) _w="${_val%$_pat}$_r" ;;
                    \#\#) _w="${_val##$_pat}$_r" ;;
                    \#) _w="${_val#$_pat}$_r" ;;
                esac
                ;;
            # A default (:-, -, :=, =) or a check (:?, ?) gives the
            # value itself, since the variable is set.
            "\${$_v"[-=?:]*'}'*) _w="$_val${_w#*\}}" ;;
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

# check_args <form> <args...>: check each argument that is not a flag.
check_args() {
    _form=$1
    shift
    for _a in "$@"; do case "$_a" in -*) ;; *) check "$_form" "$_a" ;; esac; done
}

# run_check <program>: refuse an interpreter or a script run while the
# working directory is in the profile directory outside the job folder.
run_check() {
    protected "$base/."
    [ "$kind" = profile ] || return 0
    refuse "A background session in auto mode cannot run '$1' with its working directory in $(what) on its own (#173): a script run there can write the rules, settings and hooks beside it, and a worker that could change them could change what gates it. Run it from the job folder or the checkout, or leave this to the maintainer's own interactive session."
}

# inplace <program> <args...>: true when a flag edits files in place. A
# perl or ruby flag such as -M, -I or -r takes the rest of its cluster as a
# value, so an i after one is not a flag (-MFile::Find). A flag that takes
# no value, or only digits, does not (-0pi, -lpi).
inplace() {
    _p=$1
    shift
    for _a in "$@"; do
        case "$_a" in
            --in-place*) return 0 ;;
            --* | -) ;;
            -*)
                _f=${_a#-}
                case "$_p" in
                    perl) _f=${_f%%[MmIxDCF]*} _f=${_f%%d:*} ;;
                    ruby) _f=${_f%%[IrCEKFx]*} ;;
                esac
                case "$_f" in *i*) return 0 ;; esac
                ;;
        esac
    done
    return 1
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
    case "$name" in
        cd | pushd | popd)
            # The folder stack is followed too: cd - goes back, pushd saves
            # the folder it leaves and popd returns to it. -n keeps the
            # folder where it is.
            _n=""
            while :; do
                case "${1:-}" in -P | -L | -e) shift ;; -n) _n=yes; shift ;; *) break ;; esac
            done
            [ "${1:-}" != -- ] || shift
            _to=""
            case "$name:${1:-}" in
                popd:) [ -n "$_n" ] || [ -z "$dirs" ] || { _to=${dirs%%"$nl"*}; dirs=${dirs#*"$nl"}; } ;;
                cd:) _to=$HOME ;;
                cd:-) _to=$oldbase ;;
                *:-* | *:+* | popd:* | pushd:) ;;
                *)
                    _to=$(norm "$(resolve "$(expand "$1")" "$base")")
                    if [ "$name" = pushd ]; then
                        [ -z "$_n" ] || _to=""
                        [ -n "$_to" ] && dirs="$base$nl$dirs"
                    fi
                    ;;
            esac
            [ -z "$_to" ] || { oldbase=$base; base=$_to; }
            return 0
            ;;
        tee | rm | rmdir | unlink | touch | truncate | mkdir | chmod | mv)
            check_args "$name" "$@"
            ;;
        sed)
            ! inplace sed "$@" || check_args "sed -i" "$@"
            ;;
        perl | ruby)
            ! inplace "$name" "$@" || check_args "$name -i" "$@"
            run_check "$name"
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
        awk | gawk | nawk)
            # A read, unless its program can write: -f, or >, | or system
            # in the program text. gawk's inplace library edits its files.
            for _a in "$@"; do
                case "$_a" in
                    inplace | -iinplace | --include=inplace) check_args "$name -i inplace" "$@"; break ;;
                esac
            done
            _w=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    -F | -v) shift ;;
                    -F* | -v*) ;;
                    -f* | *'>'* | *'|'* | *system*) _w=yes ;;
                esac
                [ $# -eq 0 ] || shift
            done
            [ -z "$_w" ] || run_check "$name"
            ;;
        . | source | python | python[0-9]* | node | deno | bun | php | lua | osascript | swift | fish)
            run_check "$name" ;;
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
            b*) bodies="$bodies$(printf '\n%s' "$t")" ;;
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

base=$cwd oldbase="" dirs="" bodies=""
scan "$cmd"
# A shell's -c text, eval's arguments and a process substitution are
# commands too, run where the command that ran them was; scanned after,
# from the folder the last cd left.
while [ -n "$bodies" ]; do
    b=$bodies bodies=""
    IFS='
'
    for body in $b; do
        IFS=$oldIFS
        [ -z "$body" ] || scan "$(printf '%s' "$body" | tr '\037' '\n')"
        IFS='
'
    done
    IFS=$oldIFS
done

exit 0
