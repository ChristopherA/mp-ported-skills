#!/bin/sh
# protected.sh -- the files a supervised worker may not change, and the
# record and comparison that report a change to one after its run (#190),
# for the supervise scripts and scripts/deny-worker-grant-edits.sh to source.
#
# deny-worker-grant-edits.sh (#58, #173) refuses the writes it can see: an
# Edit tool's target, or a Bash write it can read in the command text. A
# write it cannot see -- a path built at run time, a program that writes on
# its own, sed's w command, find -exec, xargs, rsync, patch, git checkout --
# still lands. So launch.sh, and resume.sh when it holds a released worker
# again, record what the protected files hold before the worker runs, and
# actions.sh compares them when the run is reported, listing each change as
# an action nobody approved.
#
# The protected set:
#   - in the Project: the two files protected_project_list names, the grant
#     file and the Distribution-repo file (the hook's `grant` and `dist`
#     kinds), in the working tree and in any commit made since the record;
#   - in the profile directory: CLAUDE.md, settings*.json, and every file
#     under rules/, hooks/, skills/, agents/, commands/ and plugins/cache/.
# Left out, so the report is not noise: transcripts, job folders, memory
# and caches (none of them is in the list), plugins/cache/temp_git_*, and
# what a plugin update writes beside the cache (plugins/marketplaces/, the
# plugins/*.json catalogs, plugins/data/). Under plugins/cache/ a version
# folder (<marketplace>/<plugin>/<version>/) that appears whole is an
# update adding it and is not reported, nor is one that disappears whole
# while the same plugin gains one (a prune); one that disappears with no
# new version beside it is reported as one line. A file added, changed or
# removed inside a version folder present both times is reported.
# The hook guards the whole profile directory; this record watches only the
# files that govern a session. Known limit: a worker that writes a version
# folder of its own and repoints plugins/installed_plugins.json at it is
# not reported, since the catalogs are left out; and a route the hook
# cannot see could rewrite this record along with a rule.
#
# The record lives at $CLAUDE_CONFIG_DIR/mp-supervise-protected/<id>, inside
# the profile directory the hook refuses the worker's writes to, and outside
# what it records. Its lines: `mp-supervise protected-files 1`, `dir <DIR>`,
# `config <profile>`, `head <sha or none>`, one `<sha256 or absent> <tag>`
# per file (`project/<path>` or `profile/<path>`), then `end`.
#
# Usage:
#   . "$(dirname -- "$0")/protected.sh"
#
# protected_project_list prints `<kind> <path>` for each protected Project
# file, the path relative to the repo's top.
#
# protected_project_kind PATH prints the kind of a path relative to the
# repo's top, and exits 1 when it is not a protected Project file.
#
# protected_record_path CONFIG ID prints the record's path for worker ID.
#
# protected_record DIR CONFIG FILE writes the record of DIR's protected
# files and CONFIG's to FILE, and fails, writing nothing, when a file could
# not be read or FILE could not be written.
#
# protected_compare FILE ID prints one line per change since the record:
#   protected-file <added|changed|removed> ungranted: <path>
#   protected-file committed ungranted: <path> (since <sha>)
# a Project file's changed line ending `, committed since <sha>` when a
# commit since the record also changed it. When the record is missing or
# incomplete, or the files cannot be read now, it prints one
# `note ... not checked` line instead, never nothing. It prints nothing
# when nothing changed.

protected_project_list() {
    printf 'grant docs/agents/supervision.md\n'
    printf 'dist docs/agents/distribution-repo.md\n'
}

protected_project_kind() {
    protected_project_list | awk -v p="$1" '
        substr($0, index($0, " ") + 1) == p { print $1; found = 1; exit }
        END { if (!found) exit 1 }'
}

protected_record_path() {
    printf '%s/mp-supervise-protected/%s\n' "$1" "$2"
}

# protected_sum FILE...: sha256 lines, `<hash>  <file>`.
protected_sum() {
    if shasum -a 256 /dev/null >/dev/null 2>&1; then
        shasum -a 256 "$@"
    else
        sha256sum "$@"
    fi
}

# protected_scan DIR CONFIG OUT: writes `<hash or absent> <tag>` lines,
# sorted, to OUT; fails, with the reason on stderr, when a file could not
# be read.
protected_scan() {
    : >"$3" || return 1
    for protected_rel in $(protected_project_list | awk '{ print $2 }'); do
        if [ -f "$1/$protected_rel" ]; then
            protected_h=$(protected_sum "$1/$protected_rel") || return 1
            printf '%s project/%s\n' "${protected_h%% *}" "$protected_rel" >>"$3"
        elif [ -e "$1/$protected_rel" ]; then
            printf '%s is not a file\n' "$1/$protected_rel" >&2
            return 1
        else
            printf 'absent project/%s\n' "$protected_rel" >>"$3"
        fi
    done
    (
        set +f
        cd "$2" || exit 1
        set --
        for protected_p in CLAUDE.md settings*.json rules hooks skills agents commands plugins/cache; do
            [ ! -e "$protected_p" ] || set -- "$@" "$protected_p"
        done
        [ $# -eq 0 ] && exit 0
        # -H follows a protected name that is itself a symlink, such as a
        # linked rules/ or CLAUDE.md.
        find -H "$@" -type f ! -path 'plugins/cache/temp_git_*' -exec sh -c '
            if shasum -a 256 /dev/null >/dev/null 2>&1; then shasum -a 256 "$@"; else sha256sum "$@"; fi' sh {} +
    ) >"$3.profile" || { rm -f "$3.profile"; return 1; }
    sed 's/^\([0-9a-f]*\)  /\1 profile\//' "$3.profile" >>"$3"
    rm -f "$3.profile"
    LC_ALL=C sort -k 2 -o "$3" "$3"
}

protected_record() {
    mkdir -p "$(dirname -- "$3")" || return 1
    protected_tmp="$3.tmp.$$"
    if ! protected_scan "$1" "$2" "$protected_tmp.scan"; then
        rm -f "$protected_tmp.scan"
        return 1
    fi
    protected_head=$(git -C "$1" rev-parse -q --verify HEAD 2>/dev/null) || protected_head=none
    {
        printf 'mp-supervise protected-files 1\n'
        printf 'dir %s\nconfig %s\nhead %s\n' "$1" "$2" "$protected_head"
        cat "$protected_tmp.scan"
        printf 'end\n'
    } >"$protected_tmp" && mv -f "$protected_tmp" "$3"
    protected_rc=$?
    rm -f "$protected_tmp.scan" "$protected_tmp"
    return "$protected_rc"
}

protected_compare() {
    if [ ! -f "$1" ]; then
        printf 'note no protected-file record for %s (%s), so changes to protected files were not checked\n' "$2" "$1"
        return 0
    fi
    if [ ! -r "$1" ]; then
        printf 'note the protected-file record for %s (%s) could not be read, so changes to protected files were not checked\n' "$2" "$1"
        return 0
    fi
    protected_dir=$(sed -n 's/^dir //p' "$1" | head -n 1)
    protected_cfg=$(sed -n 's/^config //p' "$1" | head -n 1)
    protected_head=$(sed -n 's/^head //p' "$1" | head -n 1)
    if [ "$(head -n 1 "$1")" != 'mp-supervise protected-files 1' ] || [ "$(tail -n 1 "$1")" != end ] ||
        [ -z "$protected_dir" ] || [ -z "$protected_cfg" ] || [ -z "$protected_head" ]; then
        printf 'note the protected-file record for %s (%s) could not be read, so changes to protected files were not checked\n' "$2" "$1"
        return 0
    fi
    protected_tmp=$(mktemp -d "${TMPDIR:-/tmp}/protected.XXXXXX") || {
        printf 'note no scratch folder for comparing protected files, so changes to them were not checked\n'
        return 0
    }
    if ! protected_scan "$protected_dir" "$protected_cfg" "$protected_tmp/now" 2>"$protected_tmp/err"; then
        printf 'note the protected files could not be read now (%s), so changes to them were not checked\n' \
            "$(head -n 1 "$protected_tmp/err")"
        rm -rf "$protected_tmp"
        return 0
    fi
    if ! sed -e '1,4d' -e '$d' "$1" >"$protected_tmp/then"; then
        printf 'note the protected-file record for %s (%s) could not be read, so changes to protected files were not checked\n' "$2" "$1"
        rm -rf "$protected_tmp"
        return 0
    fi
    # <change> <tag> for each difference. A plugins/cache version folder
    # (profile/plugins/cache/<m>/<p>/<v>) added whole is an update's, and
    # its files are not listed; one removed whole is a prune's when the
    # same plugin gained a version folder in the run, and is otherwise one
    # `removed` line for the folder, since it may hold the running gates.
    if ! awk '
        function tag(line) { return substr(line, index(line, " ") + 1) }
        function unit(t,   a, n) {
            n = split(t, a, "/")
            if (a[1] == "profile" && a[2] == "plugins" && a[3] == "cache" && n >= 7)
                return a[1] "/" a[2] "/" a[3] "/" a[4] "/" a[5] "/" a[6]
            return ""
        }
        function plugin(u) { return substr(u, 1, length(u) - length(ver(u)) - 1) }
        function ver(u,   a, n) { n = split(u, a, "/"); return a[n] }
        FNR == NR { t = tag($0); old[t] = $1; u = unit(t); if (u != "") ou[u] = 1; next }
        { t = tag($0); cur[t] = $1; u = unit(t); if (u != "") nu[u] = 1 }
        END {
            for (u in nu) if (!(u in ou)) grew[plugin(u)] = 1
            for (t in old) {
                if (!(t in cur)) {
                    u = unit(t)
                    if (u == "" || (u in nu)) print "removed " t
                    else if (!(plugin(u) in grew) && !(u in gone)) { gone[u] = 1; print "removed " u }
                } else if (old[t] != cur[t]) {
                    if (old[t] == "absent") print "added " t
                    else if (cur[t] == "absent") print "removed " t
                    else print "changed " t
                }
            }
            for (t in cur) {
                if (t in old) continue
                u = unit(t)
                if (u == "" || (u in ou)) print "added " t
            }
        }' "$protected_tmp/then" "$protected_tmp/now" >"$protected_tmp/unsorted"; then
        printf 'note the protected files could not be compared with the record for %s (%s), so changes to them were not checked\n' "$2" "$1"
        rm -rf "$protected_tmp"
        return 0
    fi
    LC_ALL=C sort -k 2 "$protected_tmp/unsorted" >"$protected_tmp/diff"
    # A commit since the record that changed a Project file.
    : >"$protected_tmp/committed"
    if [ "$protected_head" != none ]; then
        for protected_rel in $(protected_project_list | awk '{ print $2 }'); do
            git -C "$protected_dir" diff --quiet "$protected_head" HEAD -- "$protected_rel" 2>/dev/null
            case $? in
                0) ;;
                1) printf 'project/%s\n' "$protected_rel" >>"$protected_tmp/committed" ;;
                *) printf 'note git could not compare %s with the record'\''s commit %s in %s, so a commit to it was not checked\n' \
                       "$protected_rel" "$protected_head" "$protected_dir" ;;
            esac
        done
    fi
    protected_short=$(printf '%.7s' "$protected_head")
    while read -r protected_change protected_tag; do
        protected_line="protected-file $protected_change ungranted: $(protected_abs "$protected_dir" "$protected_cfg" "$protected_tag")"
        grep -qxF -- "$protected_tag" "$protected_tmp/committed" &&
            protected_line="$protected_line, committed since $protected_short"
        printf '%s\n' "$protected_line"
    done <"$protected_tmp/diff"
    while read -r protected_tag; do
        awk -v t="$protected_tag" 'substr($0, index($0, " ") + 1) == t { found = 1 } END { exit !found }' "$protected_tmp/diff" ||
            printf 'protected-file committed ungranted: %s (since %s)\n' "$(protected_abs "$protected_dir" "$protected_cfg" "$protected_tag")" "$protected_short"
    done <"$protected_tmp/committed"
    rm -rf "$protected_tmp"
}

# protected_abs DIR CONFIG TAG: the tag's absolute path, from the record's
# dir and config.
protected_abs() {
    case "$3" in
        project/*) printf '%s/%s' "$1" "${3#project/}" ;;
        profile/*) printf '%s/%s' "$2" "${3#profile/}" ;;
        *) printf '%s' "$3" ;;
    esac
}
