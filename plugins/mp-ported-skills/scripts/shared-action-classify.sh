# shared-action-classify.sh -- sourced, not run: name the shared action a
# git or gh argument list reaches (#66).
#
# deny-shared-actions.sh calls these on the words it scanned out of a Bash
# command's text; worker-bin/git and worker-bin/gh call them on the real
# argv a process was started with, which reaches inside scripts the hook
# cannot see. One parser for both keeps the refused forms the same.
#
#   classify_git <args after "git">   sets matched to "git push", ...
#   classify_gh <args after "gh">     sets matched to "gh pr create", ...
#
# Both leave matched empty when the arguments reach no shared action. The
# caller sets three variables first: classify_git_cmd, the git that
# resolves an alias from git config (a wrapper passes the real git here, so
# the lookup does not run the wrapper again); classify_base, the directory
# the command runs in; and classify_text, the text a GraphQL mutation is
# looked for in. classify_git also sets classify_dir, the repo the command
# acts on: classify_base, moved by each `-C <dir>` as git moves. A grant is
# looked up there, so a grant in one checkout does not cover a push from
# another. Scratch variables start with _c so they do not clobber the
# caller's.

classify_git() {
    classify_dir=${classify_base:-.}
    while [ $# -gt 0 ]; do
        case "$1" in
        -c)
            # An alias defined inline: `git -c alias.p=push p`.
            case "${2:-}" in alias.*push*) matched="git push (alias)"; return 0 ;; esac
            if [ $# -ge 2 ]; then shift 2; else shift; fi
            ;;
        -C)
            case "${2:-}" in
            /*) classify_dir=$2 ;;
            '') ;;
            *) classify_dir="$classify_dir/$2" ;;
            esac
            if [ $# -ge 2 ]; then shift 2; else shift; fi
            ;;
        -*) shift ;;
        *) break ;;
        esac
    done
    _csub=${1:-}
    if [ "$_csub" = push ] || [ "$_csub" = send-pack ]; then
        matched="git push"
    elif [ "$_csub" = subtree ] && [ "${2:-}" = push ]; then
        matched="git subtree push"
    elif [ -n "$_csub" ]; then
        # An alias from git config, read in the repo the command acts on.
        case "$("${classify_git_cmd:-git}" -C "$classify_dir" config --get "alias.$_csub" 2>/dev/null)" in
        *push*) matched="git push (alias $_csub)" ;;
        esac
    fi
}

# classify_push_where <args after "git">: after classify_git matched a
# plain `git push`, where it sends commits (#94). Sets classify_push_where:
#   local       every URL it pushes to is a path on this machine (a plain
#               path or file://), which nobody else sees
#   shared      a network URL, or a form whose destination this cannot
#               trust: a `-c` or --config-env setting, --git-dir or
#               --work-tree, --receive-pack or --exec (a command run for
#               the push), a submodule push, or a URL an insteadOf or
#               pushInsteadOf rule rewrites
#   unresolved  the destination cannot be read now: classify_dir is not a
#               repo yet, the remote is not configured there, or the word
#               holds text the shell has yet to expand ($, a backtick, a
#               substitution, a glob or ~)
# A remote name is read through `git remote get-url --push --all` in
# classify_dir, which applies insteadOf and pushInsteadOf; a word that is
# not a configured remote is a URL when it holds a slash or a colon. The
# default destination is git's own: branch.<b>.pushRemote,
# remote.pushDefault, branch.<b>.remote, then origin. Uses
# classify_git_cmd, as classify_git does.
classify_push_where() {
    classify_push_where=unresolved
    _cpg=${classify_git_cmd:-git}
    while [ $# -gt 0 ]; do
        case "$1" in
        -c | --config-env | --config-env=* | --git-dir | --git-dir=* | --work-tree | --work-tree=*)
            classify_push_where=shared
            return 0
            ;;
        -C) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
        -*) shift ;;
        *) break ;;
        esac
    done
    [ "${1:-}" = push ] || { classify_push_where=shared; return 0; }
    shift
    _cpd="" _cprepo=""
    while [ $# -gt 0 ]; do
        case "$1" in
        --) shift; _cpd=${1:-}; break ;;
        --repo=*) _cprepo=${1#--repo=} ;;
        --repo) [ $# -lt 2 ] || { _cprepo=$2; shift; } ;;
        --receive-pack* | --exec*) classify_push_where=shared; return 0 ;;
        --recurse-submodules=no | --recurse-submodules=check | --no-recurse-submodules) ;;
        --recurse-submodules*) classify_push_where=shared; return 0 ;;
        --push-option) [ $# -lt 2 ] || shift ;;
        # A redirection, which the hook's scan keeps as words (`2>&1`,
        # `> out`): an operator standing alone takes the next word.
        '>'* | '<'* | '&>'* | [0-9]'>'* | [0-9]'<'*)
            case "$1" in *'>' | *'<' | *'>|' | *'>>') [ $# -lt 2 ] || shift ;; esac
            ;;
        --*) ;;
        # A short cluster ending in o (`-o`, `-fo`) takes the next word as
        # its push option.
        -*o) [ $# -lt 2 ] || shift ;;
        -*) ;;
        *) _cpd=$1; break ;;
        esac
        shift
    done
    [ -n "$_cpd" ] || _cpd=$_cprepo
    "$_cpg" -C "$classify_dir" rev-parse --git-dir >/dev/null 2>&1 || return 0
    if [ -z "$_cpd" ]; then
        _cpb=$("$_cpg" -C "$classify_dir" symbolic-ref --short -q HEAD 2>/dev/null)
        for _cpk in ${_cpb:+"branch.$_cpb.pushRemote"} remote.pushDefault ${_cpb:+"branch.$_cpb.remote"}; do
            _cpd=$("$_cpg" -C "$classify_dir" config --get "$_cpk" 2>/dev/null) && [ -n "$_cpd" ] && break
            _cpd=""
        done
        [ -n "$_cpd" ] || _cpd=origin
    fi
    case "$_cpd" in *'$'* | *'`'* | *"$classify_sub"* | *'*'* | *'?'* | *'['* | '~'*) return 0 ;; esac
    if _cpurls=$("$_cpg" -C "$classify_dir" remote get-url --push --all "$_cpd" 2>/dev/null); then
        :
    else
        case "$_cpd" in
        */* | *:*) ;;
        *) return 0 ;;
        esac
        # git rewrites a URL given on the command line by the same rules.
        _cprules=$("$_cpg" -C "$classify_dir" config --get-regexp '^url\..*\.(push)?insteadof$' 2>/dev/null | sed 's/^[^ ]* //')
        _cpifs=$IFS
        IFS='
'
        for _cpr in $_cprules; do
            case "$_cpd" in "$_cpr"*) IFS=$_cpifs; classify_push_where=shared; return 0 ;; esac
        done
        IFS=$_cpifs
        _cpurls=$_cpd
    fi
    [ -n "$_cpurls" ] || return 0
    _cpifs=$IFS
    IFS='
'
    for _cpu in $_cpurls; do
        classify_url_local "$_cpu" || { IFS=$_cpifs; classify_push_where=shared; return 0; }
    done
    IFS=$_cpifs
    classify_push_where=local
}

# classify_url_local <url>: succeeds when git reads the URL as a path on
# this machine: file://, or no scheme and no colon before the first slash
# (`host:path` is ssh's form, `<transport>::<address>` a helper's).
classify_url_local() {
    case "$1" in
    '') return 1 ;;
    file://*) return 0 ;;
    *://*) return 1 ;;
    esac
    case "${1%%/*}" in *:*) return 1 ;; esac
}

# classify_distribution: after classify_git matched a push, name it as a
# push in a Project's Distribution repo when classify_dir is one (#141).
# Such a push is the Project's to grant, as `distribution-push`, never
# `push`, and never by the Distribution repo's own supervision.md: matched
# gains ` in Distribution repo <path>` and classify_dir becomes the
# Project, where the caller looks the grant up. A repo is a Project's
# Distribution repo when distribution.sh, run on the Project, names it; the
# Project is looked for in the repo's worker marker (`project <path>`, which
# launch.sh writes) and in classify_session, the session's own folder. A
# marker only says where to look: distribution.sh reads the Project's
# origin, so a marker a worker rewrote cannot make another repo one. The
# caller sets classify_distribution_sh to distribution.sh's path and
# classify_session; with no distribution.sh this does nothing.
classify_distribution() {
    [ -f "${classify_distribution_sh:-}" ] || return 0
    case "$matched" in "git push"* | "git subtree push"*) ;; *) return 0 ;; esac
    _ctop=$("${classify_git_cmd:-git}" -C "$classify_dir" rev-parse --show-toplevel 2>/dev/null) || return 0
    _ctop=$(CDPATH= cd -- "$_ctop" 2>/dev/null && pwd -P) || return 0
    _cmarker=$("${classify_git_cmd:-git}" -C "$_ctop" rev-parse --path-format=absolute --git-path mp-supervise-worker 2>/dev/null)
    _cproj=""
    [ ! -f "$_cmarker" ] || _cproj=$(sed -n 's/^project //p' "$_cmarker" | head -n 1)
    for _cp in "$_cproj" "${classify_session:-}"; do
        [ -n "$_cp" ] && [ -d "$_cp" ] || continue
        _cp=$(CDPATH= cd -- "$_cp" && pwd -P) || continue
        _cptop=$("${classify_git_cmd:-git}" -C "$_cp" rev-parse --show-toplevel 2>/dev/null) || continue
        [ "$_cptop" != "$_ctop" ] || continue
        if [ "$(sh "$classify_distribution_sh" --dir "$_cp" </dev/null 2>/dev/null)" = "$_ctop" ]; then
            matched="$matched in Distribution repo $_ctop"
            classify_dir=$_cp
            return 0
        fi
    done
}

# classify_close_held <dir>: the issue-close grant covers the worker's
# ticket only after its work is pushed (#186). Sets classify_held to why a
# close in <dir> waits, or empty: a Distribution repo of the Project holds
# commits its upstream lacks, or has no upstream to compare with; and
# classify_held_repo to that repo's path. A path that is not a repo of its
# own (a plain folder inside another repo) is passed over. The
# Project is <dir>'s repo, or the one its worker marker names (`project
# <path>`, from a session in the Distribution repo); its Distribution repos
# are the one distribution.sh reads from origin and the one the Project's
# marker records (`distribution <path>`). A marker can only add a repo to
# check, never remove the committed one. The caller sets
# classify_distribution_sh; with no distribution.sh nothing is held.
classify_close_held() {
    classify_held=""
    classify_held_repo=""
    [ -f "${classify_distribution_sh:-}" ] || return 0
    _cg=${classify_git_cmd:-git}
    _ctop=$("$_cg" -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 0
    _cmarker=$("$_cg" -C "$_ctop" rev-parse --path-format=absolute --git-path mp-supervise-worker 2>/dev/null)
    _cprojects=$_ctop
    [ ! -f "$_cmarker" ] || _cprojects="$_cprojects
$(sed -n 's/^project //p' "$_cmarker" | head -n 1)"
    _cdists=""
    _cifs=$IFS
    IFS='
'
    for _cp in $_cprojects; do
        [ -d "$_cp" ] || continue
        _cdists="$_cdists
$(sh "$classify_distribution_sh" --dir "$_cp" </dev/null 2>/dev/null)"
        _cpm=$("$_cg" -C "$_cp" rev-parse --path-format=absolute --git-path mp-supervise-worker 2>/dev/null)
        [ ! -f "$_cpm" ] || _cdists="$_cdists
$(sed -n 's/^distribution //p' "$_cpm" | head -n 1)"
    done
    for _cd in $_cdists; do
        [ -d "$_cd" ] || continue
        _cd=$(CDPATH= cd -- "$_cd" && pwd -P) || continue
        [ "$("$_cg" -C "$_cd" rev-parse --show-toplevel 2>/dev/null)" = "$_cd" ] || continue
        if ! _cn=$("$_cg" -C "$_cd" rev-list --count '@{upstream}..HEAD' 2>/dev/null); then
            classify_held="Distribution repo $_cd has no upstream to compare with"
            classify_held_repo=$_cd
            break
        fi
        if [ "$_cn" != 0 ]; then
            _cs=s
            [ "$_cn" != 1 ] || _cs=""
            classify_held="Distribution repo $_cd holds $_cn commit$_cs its upstream lacks"
            classify_held_repo=$_cd
            break
        fi
    done
    IFS=$_cifs
}

# classify_close_held_reason <held> <repo>: the refusal the hook and the
# wrappers give for a held close, from classify_close_held's
# classify_held and classify_held_repo.
classify_close_held_reason() {
    printf '%s' "A background session in auto mode cannot run 'gh issue close' yet (#186): $1, and the issue-close grant covers the ticket only after its work is pushed. When the ticket's work is done, list the close with the push, as \`Waiting on: git -C $2 push origin <branch>; gh issue close <N>\`, and /supervise closes the ticket after the push lands; when work is left on it, list the push alone (#217)."
}

# command_parts <command>: the command split at the separators outside
# quotes, one part per line, for a scan that must not read a quoted
# separator as the end of a command (`--add-label "a;b" --title t`; #184,
# #202). With a quote left open the split cannot be trusted, so the whole
# command is one part. A newline inside quotes or after a backslash joins
# its part, as a space. The hook and actions.sh both split with it.
command_parts() {
    printf '%s' "$1" | awk '
        { s = s (NR > 1 ? "\n" : "") $0 }
        END {
            sq = sprintf("%c", 39); q = ""; part = ""; n = length(s)
            for (i = 1; i <= n; i++) {
                c = substr(s, i, 1)
                if (q != "" && c == "\n") c = " "
                if (q == sq) { if (c == sq) q = ""; part = part c; continue }
                if (c == "\\" && i < n) { d = substr(s, i + 1, 1); part = part c (d == "\n" ? " " : d); i++; continue }
                if (q == "\"") { if (c == "\"") q = ""; part = part c; continue }
                if (c == sq || c == "\"") { q = c; part = part c; continue }
                if (index(";&|()`\n", c)) { print part; part = ""; continue }
                part = part c
            }
            if (q != "") { gsub("\n", " ", s); print s } else print part
        }'
}

# command_segments <command>: the simple commands the shell would run from
# the command's text, for a scan that must read a command only where it
# runs, never inside quoted text or a heredoc's body (#104). The first line
# says whether a `cd` in the text may be followed: `follow` when the text
# is only plain sequences (`;`, `&&`, `||`, newlines), `nofollow` when a
# subshell, a pipe, a background job or a substitution stands anywhere in
# it, since the split cannot say where a cd in one of those ends. Each line
# after it is one simple command, its words joined by $classify_rs, a
# newline inside a word written as \037, and $classify_sub standing where a
# substitution's output goes into a word, so a caller can tell a word whose
# text no scan can know (`sh -c "$(cat f)"`). Quotes and backslashes are
# removed as the shell removes them. A `$(...)`, a backtick or a process
# substitution, outside quotes or inside double quotes, and one in an
# unquoted heredoc's body, is a command of its own, printed as its own
# lines; a heredoc's body is otherwise left out, as is a comment. `<<<` is
# a word of its own, the here-string after it the next word. `>&`, `<&`,
# `&>` and `>|` are redirections, kept in their words, not separators.
# Arithmetic, `$((...))` or `((...))`, is one word when its inner paren
# closes right before the last one, so `1<<2` is not read as a heredoc.
# An unclosed quote or backtick, an empty heredoc delimiter, or arithmetic
# that holds a substitution falls back to the quote-blind split: each
# separator, paren or backtick ends a command, quotes and backslashes are
# dropped, and the follow line is read from the whole text, so the scan
# then refuses more, never less.
classify_rs=$(printf '\036')
classify_sub=$(printf '\035')
command_segments() {
    _cs_out=$(printf '%s' "$1" | awk '
        function endw() {
            if (inw) { seg = seg (nseg ? rs : "") w; nseg++ }
            w = ""; inw = 0
        }
        function ends() {
            endw()
            if (nseg) out = out seg "\n"
            seg = ""; nseg = 0
        }
        # sublex: lex a substitution body as commands of its own, keeping
        # the word and command being built around it.
        function sublex(t, d,   sw, sinw, sseg, snseg) {
            sw = w; sinw = inw; sseg = seg; snseg = nseg
            w = ""; inw = 0; seg = ""; nseg = 0
            lex(t, d)
            w = sw; inw = sinw; seg = sseg; nseg = snseg
            nofollow = 1
        }
        # balanced: the text of t from j, an opening paren, to its closing
        # one, quotes and backslashes respected; bend is where it ended and
        # bclosed whether it closed.
        function balanced(t, j,   b, depth, bq, c, m) {
            m = length(t); b = ""; depth = 0; bq = ""; bclosed = 0
            for (; j <= m; j++) {
                c = substr(t, j, 1); b = b c
                if (bq == sq) { if (c == sq) bq = ""; continue }
                if (c == "\\" && j < m) { j++; b = b substr(t, j, 1); continue }
                if (bq == "\"") { if (c == "\"") bq = ""; continue }
                if (c == sq || c == "\"") { bq = c; continue }
                if (c == "(") depth++
                else if (c == ")" && --depth == 0) { bclosed = 1; break }
            }
            bend = (j > m ? m : j)
            return b
        }
        # arith: whether t at j, a "((", is arithmetic; atext is its text
        # and aend where it ended. Arithmetic holding a substitution sets
        # fallback.
        function arith(t, j,   b, inner, e) {
            b = balanced(t, j)
            if (!bclosed) return 0
            e = bend
            inner = balanced(t, j + 1)
            if (!bclosed || bend != e - 1) return 0
            if (index(b, "$(") || index(b, "`")) fallback = 1
            atext = b; aend = e
            return 1
        }
        # subst: t at j is "$(": lex a command substitution, or take
        # arithmetic as text. Returns where it ended; sets sarith.
        function subst(t, j, d,   b) {
            sarith = 0
            if (substr(t, j + 2, 1) == "(" && arith(t, j + 1)) { sarith = 1; return aend }
            b = balanced(t, j + 1)
            sublex(substr(b, 2, length(b) - (bclosed ? 2 : 1)), d + 1)
            return bend
        }
        # btick: t at j is a backtick: lex up to the next unescaped one.
        function btick(t, j, d,   k, m, b, c) {
            m = length(t); b = ""
            for (k = j + 1; k <= m; k++) {
                c = substr(t, k, 1)
                if (c == "\\" && k < m) { k++; c = substr(t, k, 1); b = b (c == "`" || c == "\\" || c == "$" ? "" : "\\") c; continue }
                if (c == "`") break
                b = b c
            }
            if (k > m) { fallback = 1; k = m }
            sublex(b, d + 1)
            return k
        }
        # bodysubs: the substitutions in an unquoted heredoc body.
        function bodysubs(b, d,   j, m, c) {
            m = length(b)
            for (j = 1; j <= m; j++) {
                c = substr(b, j, 1)
                if (c == "\\") { j++; continue }
                if (c == "$" && substr(b, j + 1, 1) == "(") { j = subst(b, j, d); continue }
                if (c == "`") j = btick(b, j, d)
            }
        }
        function lex(t, d,   i, n, c, q, x, dl, quo, dash, h, line, body, k) {
            n = length(t); q = ""; nh[d] = 0
            for (i = 1; i <= n; i++) {
                c = substr(t, i, 1)
                if (q == sq) { if (c == sq) q = ""; else w = w (c == "\n" ? nl : c); continue }
                if (q == "ansi") {
                    if (c == "\\" && i < n) { i++; w = w substr(t, i, 1); continue }
                    if (c == sq) q = ""; else w = w (c == "\n" ? nl : c)
                    continue
                }
                if (q == "\"") {
                    if (c == "\\" && i < n && index("\"\\$`\n", substr(t, i + 1, 1))) { i++; c = substr(t, i, 1); if (c != "\n") w = w c; continue }
                    if (c == "\"") { q = ""; continue }
                    if (c == "$" && substr(t, i + 1, 1) == "(") {
                        i = subst(t, i, d)
                        if (sarith) { x = "$" atext; gsub("\n", nl, x); w = w x } else w = w mk
                        continue
                    }
                    if (c == "`") { i = btick(t, i, d); w = w mk; continue }
                    w = w (c == "\n" ? nl : c); continue
                }
                if (c == "\\") {
                    if (i < n) { i++; c = substr(t, i, 1); if (c != "\n") { w = w c; inw = 1 } }
                    continue
                }
                if (c == sq || c == "\"") { q = c; inw = 1; continue }
                if (c == "$" && substr(t, i + 1, 1) == sq) { q = "ansi"; inw = 1; i++; continue }
                if (c == "$" && substr(t, i + 1, 1) == "(") {
                    i = subst(t, i, d)
                    if (sarith) { x = "$" atext; gsub("\n", nl, x); w = w x } else w = w mk
                    inw = 1; continue
                }
                if (c == "(" && !inw && substr(t, i + 1, 1) == "(" && arith(t, i)) {
                    x = atext; gsub("\n", nl, x); w = w x; inw = 1; i = aend; continue
                }
                if (c == "`") { i = btick(t, i, d); w = w mk; inw = 1; continue }
                # A process substitution, >(...) or <(...).
                if (c == "(" && w ~ /[<>]$/) {
                    x = balanced(t, i)
                    sublex(substr(x, 2, length(x) - (bclosed ? 2 : 1)), d + 1)
                    i = bend; w = w mk; continue
                }
                if (c == "#" && !inw) { while (i < n && substr(t, i + 1, 1) != "\n") i++; continue }
                if (c == " " || c == "\t") { endw(); continue }
                if (c == "<" && substr(t, i + 1, 2) == "<<") { endw(); w = "<<<"; inw = 1; endw(); i += 2; continue }
                if (c == "<" && substr(t, i + 1, 1) == "<") {
                    # A heredoc: its delimiter, and whether any of it was
                    # quoted, which makes the body pure data.
                    if (w ~ /^[0-9]+$/) { w = ""; inw = 0 }
                    endw(); i++; dash = 0
                    if (substr(t, i + 1, 1) == "-") { i++; dash = 1 }
                    while (i < n && index(" \t", substr(t, i + 1, 1))) i++
                    dl = ""; quo = 0
                    while (i < n) {
                        x = substr(t, i + 1, 1)
                        if (index(" \t\n;&|()<>", x)) break
                        i++
                        if (x == sq || x == "\"") {
                            quo = 1
                            while (i < n && substr(t, i + 1, 1) != x) { i++; dl = dl substr(t, i, 1) }
                            if (i >= n) fallback = 1
                            i++; continue
                        }
                        if (x == "\\") { quo = 1; if (i < n) { i++; dl = dl substr(t, i, 1) }; continue }
                        dl = dl x
                    }
                    if (dl == "") fallback = 1
                    k = ++nh[d]; hq[d, k] = dl; hdash[d, k] = dash; hquo[d, k] = quo
                    continue
                }
                if (c == "&") {
                    if (substr(t, i + 1, 1) == "&") { ends(); i++; continue }
                    if (substr(t, i + 1, 1) == ">") { w = w "&>"; i++; inw = 1; continue }
                    if (w ~ /[<>]$/) { w = w c; continue }
                    ends(); nofollow = 1; continue
                }
                if (c == "|") {
                    if (substr(t, i + 1, 1) == "|") { ends(); i++; continue }
                    if (w ~ />$/) { w = w c; continue }
                    ends(); nofollow = 1; continue
                }
                if (c == ";") { ends(); continue }
                if (c == "(" || c == ")") { ends(); nofollow = 1; continue }
                if (c == "\n") {
                    ends()
                    for (h = 1; h <= nh[d]; h++) {
                        body = ""
                        while (i < n) {
                            k = index(substr(t, i + 1), "\n")
                            line = k ? substr(t, i + 1, k - 1) : substr(t, i + 1)
                            i = k ? i + k : n
                            if (hdash[d, h]) sub(/^\t+/, "", line)
                            if (line == hq[d, h]) break
                            body = body line "\n"
                        }
                        if (!hquo[d, h]) bodysubs(body, d)
                    }
                    nh[d] = 0
                    continue
                }
                w = w c; inw = 1
            }
            if (q != "") fallback = 1
            ends()
        }
        { s = s (NR > 1 ? "\n" : "") $0 }
        END {
            sq = sprintf("%c", 39); nl = sprintf("%c", 31); rs = sprintf("%c", 30); mk = sprintf("%c", 29)
            out = ""; w = ""; inw = 0; seg = ""; nseg = 0; nofollow = 0; fallback = 0
            lex(s, 0)
            if (fallback) print "fallback"
            else printf "%s\n%s", (nofollow ? "nofollow" : "follow"), out
        }')
    if [ "$_cs_out" != fallback ]; then
        printf '%s\n' "$_cs_out"
        return 0
    fi
    case "$(printf '%s' "$1" | sed -E 's/&&|\|\|//g')" in
    *[\(\)\|\&\`]*) echo nofollow ;;
    *) echo follow ;;
    esac
    printf '%s\n' "$1" | sed -E 's/(&&|\|\||[;&|()`])/\n/g' | tr -d "\"'\\\\" |
        awk -v rs="$classify_rs" '{ o = ""; for (k = 1; k <= NF; k++) o = o (k > 1 ? rs : "") $k; if (NF) print o }'
}

# gh_words <args after "gh">: sets gh_sub and gh_act to the subcommand and
# its action, passing over a repo flag (-R <repo>, -R=<repo>, -R<repo>,
# --repo <repo>, --repo=<repo>) wherever gh takes one: before the
# subcommand, between it and its action, or after the action (#119).
# gh_pre is the count of words before the subcommand. actions.sh reads gh
# commands with it too.
gh_words() {
    gh_sub="" gh_act="" gh_pre=0
    while [ $# -gt 0 ] && [ -z "$gh_act" ]; do
        case "$1" in
        -R | --repo)
            [ -n "$gh_sub" ] || gh_pre=$((gh_pre + ($# >= 2 ? 2 : 1)))
            if [ $# -ge 2 ]; then shift 2; else shift; fi
            continue
            ;;
        --repo=* | -R?*) [ -n "$gh_sub" ] || gh_pre=$((gh_pre + 1)); shift; continue ;;
        esac
        if [ -z "$gh_sub" ]; then gh_sub=$1; else gh_act=$1; fi
        shift
    done
}

classify_gh() {
    gh_words "$@"
    case "$gh_sub/$gh_act" in
    pr/create | pr/new) matched="gh pr create" ;;
    pr/merge) matched="gh pr merge" ;;
    issue/close) matched="gh issue close" ;;
    issue/comment)
        # The comment grant posts a new comment only (#113). Editing or
        # deleting the last one is named apart, so no grant covers it. Any
        # word that is the flag counts, even one gh would read as a body;
        # the first one found names the form, and both are refused. Every
        # word is looked at, the ones before the action included, since a
        # repo flag may stand between the subcommand and its action.
        matched="gh issue comment"
        for _carg in "$@"; do
            case "$_carg" in
            --edit-last | --edit-last=*) matched="gh issue comment (edit)"; break ;;
            --delete-last | --delete-last=*) matched="gh issue comment (delete)"; break ;;
            esac
        done
        ;;
    issue/create | issue/new)
        # A create's link flags are named apart (#218): --blocked-by or
        # --blocking as a blocked-by link, which no grant covers, and
        # --parent as a sub-issue link, which needs issue-create and
        # sub-issue together. Any word that is the flag counts, even one gh
        # would read as another flag's value; every other word is ignored.
        _cparent="" _cblocked=""
        for _carg in "$@"; do
            case "$_carg" in
            --blocked-by | --blocked-by=* | --blocking | --blocking=*) _cblocked=yes ;;
            --parent | --parent=*) _cparent=yes ;;
            esac
        done
        if [ -n "$_cblocked" ]; then
            matched="gh issue create (blocked-by link)"
        elif [ -n "$_cparent" ]; then
            matched="gh issue create (sub-issue link)"
        else
            matched="gh issue create"
        fi
        ;;
    issue/delete | issue/transfer | issue/reopen | issue/pin | issue/unpin | issue/lock | issue/unlock | issue/develop)
        # Writes no grant covers (#218). A help flag prints help and runs
        # nothing when no other flag stands beside it (beside one it may be
        # that flag's value: `reopen 23 -c --help`), and develop's --list
        # or -l is a read on the same terms.
        _chelp="" _clist="" _cother=""
        for _carg in "$@"; do
            case "$_carg" in
            -R | --repo | --repo=* | -R?*) ;;
            --help | -h) _chelp=yes ;;
            --list | -l) _clist=yes ;;
            -*) _cother=yes ;;
            esac
        done
        [ "$gh_act" = develop ] || { [ -z "$_clist" ] || _cother=yes; }
        if [ -z "$_cother" ] && { [ -n "$_chelp" ] || [ -n "$_clist" ]; }; then
            :
        else
            matched="gh issue $gh_act"
        fi
        ;;
    issue/edit)
        # Every field a gh issue edit sets is named, by the families of its
        # flags: label (--add-label, --remove-label) for the label grant
        # (#184), link (--parent, --add-sub-issue) for the sub-issue grant,
        # unlink (--remove-parent, --remove-sub-issue), and other, any other
        # flag (#202). Every word is looked at, the ones before the action
        # included; a repo flag is passed over, and words that are not flags
        # (issue numbers, label values) are ignored, so a flag value that
        # starts with - counts as other and refuses. A help flag alone
        # prints help and sets nothing; beside a field it may be that
        # field's value, so it counts as other there. An edit with no field
        # flag is left unmatched.
        _clabel="" _clink="" _cunlink="" _cother="" _chelp=""
        for _carg in "$@"; do
            case "$_carg" in
            --add-label | --remove-label | --add-label=* | --remove-label=*) _clabel=yes ;;
            --parent | --add-sub-issue | --parent=* | --add-sub-issue=*) _clink=yes ;;
            --remove-parent | --remove-sub-issue | --remove-parent=* | --remove-sub-issue=*) _cunlink=yes ;;
            -R | --repo | --repo=* | -R?*) ;;
            --help | -h) _chelp=yes ;;
            -*) _cother=yes ;;
            esac
        done
        # Each family set adds one "yes", so "$_cfams" = yes means exactly
        # one family is present.
        _cfams=$_clabel$_clink$_cunlink$_cother
        [ -z "$_chelp" ] || [ -z "$_cfams" ] || { _cother=yes; _cfams=${_cfams}yes; }
        if [ -n "$_clabel" ] && [ "$_cfams" = yes ]; then
            matched="gh issue edit (label)"
        elif [ -n "$_clabel" ]; then
            matched="gh issue edit (label and other fields)"
        elif [ -n "$_clink" ] && [ "$_cfams" = yes ]; then
            matched="gh issue edit (sub-issue link)"
        elif [ -n "$_cunlink" ] && [ "$_cfams" = yes ]; then
            matched="gh issue edit (sub-issue unlink)"
        elif [ -n "$_cfams" ]; then
            matched="gh issue edit (other fields)"
        fi
        ;;
    api/*)
        # A write through the REST or GraphQL API reaches the same
        # actions: a POST, PUT, PATCH or DELETE on pulls, issues, merges,
        # contents or the git data API, or a GraphQL mutation. gh sends POST
        # by default once a field or input is given. A POST to an issue's
        # comments, or to a repo's issues, is named as the issue comment or
        # new issue it makes, so the grant for that action covers it (#110),
        # and so are a POST to an issue's sub_issues (linking a child) and a
        # PATCH to its sub_issues/priority (a reorder), for the sub-issue
        # grant (#162): only when that path, matched whole, is the one word
        # not taken by a method or field flag. Any other word -- a second
        # path, a header's value -- leaves it a plain gh api write, never
        # granted, as is a PATCH or DELETE of a comment (#113) or of a
        # sub-issue. A GraphQL mutation is never granted either, addComment,
        # createIssue and addSubIssue included; ADR 0005 says why. The words
        # after `api` are the request.
        shift $((gh_pre + 1))
        _cmethod="" _cfields="" _ctarget="" _cgraphql="" _cissue="" _cwords=0
        while [ $# -gt 0 ]; do
            case "$1" in
            -X | --method) _cmethod=${2:-}; if [ $# -ge 2 ]; then shift 2; else shift; fi; continue ;;
            -X* ) _cmethod=${1#-X}; shift; continue ;;
            --method=*) _cmethod=${1#--method=}; shift; continue ;;
            -f | -F | --field | --raw-field | --input) _cfields=yes; if [ $# -ge 2 ]; then shift 2; else shift; fi; continue ;;
            -f* | -F* | --field=* | --raw-field=* | --input=*) _cfields=yes; shift; continue ;;
            -*) shift; continue ;;
            esac
            _cwords=$((_cwords + 1))
            case "$1" in
            graphql) _cgraphql=yes ;;
            *pulls* | *issues* | *merges* | *contents* | */git/*)
                _ctarget=yes
                # Owner and repo are GitHub's name characters, or gh's
                # {owner} and {repo}: a ? or # there would hide another
                # endpoint behind a granted form, and a . or .. segment could
                # step out of it.
                if printf '%s\n' "$1" | grep -Eq '(^|/)\.\.?(/|$)'; then
                    :
                elif printf '%s\n' "$1" | grep -Eqx '/?repos/[A-Za-z0-9._{}-]+/[A-Za-z0-9._{}-]+/issues/[0-9]+/comments/?'; then
                    _cissue=comment
                elif printf '%s\n' "$1" | grep -Eqx '/?repos/[A-Za-z0-9._{}-]+/[A-Za-z0-9._{}-]+/issues/?'; then
                    _cissue=create
                elif printf '%s\n' "$1" | grep -Eqx '/?repos/[A-Za-z0-9._{}-]+/[A-Za-z0-9._{}-]+/issues/[0-9]+/sub_issues/?'; then
                    _cissue=sub-link
                elif printf '%s\n' "$1" | grep -Eqx '/?repos/[A-Za-z0-9._{}-]+/[A-Za-z0-9._{}-]+/issues/[0-9]+/sub_issues/priority/?'; then
                    _cissue=sub-reorder
                fi
                ;;
            esac
            shift
        done
        [ "$_cwords" -eq 1 ] || _cissue=""
        _cmethod=$(printf '%s' "$_cmethod" | tr '[:lower:]' '[:upper:]')
        [ -n "$_cmethod" ] || { [ -n "$_cfields" ] && _cmethod=POST; } || _cmethod=GET
        if [ -n "$_cgraphql" ]; then
            case "${classify_text:-}" in *mutation*) matched="gh api graphql mutation" ;; esac
        elif [ -n "$_ctarget" ] && [ "$_cmethod" = POST ] && { [ "$_cissue" = comment ] || [ "$_cissue" = create ]; }; then
            matched="gh api POST (issue $_cissue)"
        elif [ -n "$_ctarget" ] && [ "$_cmethod" = POST ] && [ "$_cissue" = sub-link ]; then
            matched="gh api POST (sub-issue link)"
        elif [ -n "$_ctarget" ] && [ "$_cmethod" = PATCH ] && [ "$_cissue" = sub-reorder ]; then
            matched="gh api PATCH (sub-issue reorder)"
        elif [ -n "$_ctarget" ] && [ "$_cmethod" != GET ]; then
            matched="gh api $_cmethod"
        fi
        ;;
    esac
}

# The action a grant names for a matched form, or nothing for a form no
# grant covers: the piped-into-a-shell fallback and the other gh api forms,
# which do not say which action they reach, and an issue comment's edit or
# delete (#113), a gh issue edit that changes more than labels (#184), and
# a gh issue edit that unlinks a sub-issue or sets any field but labels or
# a link (#202). The two gh api POSTs above that name an issue comment or a
# new issue map to that action (#110), the sub-issue link and reorder map to
# sub-issue (#162), as does a gh issue edit that only links (--parent,
# --add-sub-issue; #202), and a label-only gh issue edit maps to label
# (#184). A gh issue create with --parent needs two actions, issue-create
# and sub-issue (#218), printed space-separated: a caller lets it through
# only when every action printed is granted. No grant covers a create with
# --blocked-by or --blocking, nor gh issue delete, transfer, reopen, pin,
# unpin, lock, unlock or develop (#218). No form maps
# to checked-push (#188): it covers only the supervisor's own push.sh push,
# so a worker's push under it alone is refused as with no grant.
grant_action() { # <matched>
    case "$1" in
    "git push (piped"* | "gh (piped"*) ;;
    *" in Distribution repo "*) echo distribution-push ;;
    "git push"* | "git subtree push"* | "git send-pack"*) echo push ;;
    "gh pr create"*) echo pr-create ;;
    "gh pr merge"*) echo pr-merge ;;
    "gh issue close"*) echo issue-close ;;
    "gh issue comment" | "gh api POST (issue comment)") echo issue-comment ;;
    "gh issue create" | "gh api POST (issue create)") echo issue-create ;;
    "gh issue create (sub-issue link)") echo issue-create sub-issue ;;
    "gh api POST (sub-issue link)" | "gh api PATCH (sub-issue reorder)" | "gh issue edit (sub-issue link)") echo sub-issue ;;
    "gh issue edit (label)") echo label ;;
    esac
}

# classify_granted <grant.sh> <dir> <action>...: succeeds only when grant.sh
# finds a standing grant in <dir> for every action given, as grant_action
# prints them (#218). With no action, or no grant.sh, it fails.
classify_granted() {
    _cgsh=$1 _cgdir=$2
    shift 2
    [ $# -gt 0 ] && [ -f "$_cgsh" ] || return 1
    for _cga in "$@"; do
        sh "$_cgsh" --dir "$_cgdir" --action "$_cga" >/dev/null 2>&1 </dev/null || return 1
    done
}
