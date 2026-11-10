#!/bin/sh
# signing.sh -- whether a commit signing helper is waiting for a worker,
# read from `ps`, for watch.sh and zone.sh to source (#196, #206).
#
# signing_wait <pid>: `<program> (pid <pid>) has waited <etime>` for a commit
# signing helper among the descendants of the worker's pid, or empty when
# the pid is empty or not a number, ps fails, or no helper is found.
# ssh-sk-helper, which waits at the sensor, is named before the ssh-keygen
# -Y sign that started it. When the key signs through ssh-agent,
# ssh-sk-helper is the agent's child, not the worker's, and the ssh-keygen
# -Y sign that waits on the agent is the one found.
signing_wait() {
    case $1 in '' | *[!0-9]*) return 0 ;; esac
    signing_procs=$(ps -axo pid=,ppid=,etime=,command= </dev/null 2>/dev/null) || return 0
    printf '%s\n' "$signing_procs" | awk -v root="$1" '
        NF >= 4 {
            parent[$1] = $2; etime[$1] = $3
            c = $0; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+[^ \t]+[ \t]+/, "", c)
            n++; order[n] = $1; cmd[$1] = c
        }
        function descends(p,   a, d) {
            for (a = parent[p]; a != "" && a != "0" && d < 64; a = parent[a]) {
                if (a == root) return 1
                d++
            }
            return 0
        }
        END {
            for (i = 1; i <= n; i++) {
                p = order[i]; split(cmd[p], w, " "); prog = w[1]; sub(/.*\//, "", prog)
                if (prog == "ssh-sk-helper" && sk == "" && descends(p)) sk = p
                if (prog == "ssh-keygen" && cmd[p] ~ / -Y sign( |$)/ && kg == "" && descends(p)) kg = p
            }
            if (sk != "") printf "ssh-sk-helper (pid %s) has waited %s\n", sk, etime[sk]
            else if (kg != "") printf "ssh-keygen -Y sign (pid %s) has waited %s\n", kg, etime[kg]
        }'
}
