#!/bin/sh
# fake-clock.sh -- a fake clock for tests that wait on whole seconds, such
# as settle.sh's settle time (#92). Sourced by tests/supervise.test.sh and
# tests/supervise-helpers.test.sh.
#
# fake_clock_install DIR writes a fake `date` and `sleep` into DIR. `date
# +%s` prints the time held in DIR/now, and `sleep N` adds N to it, so
# every read a waiting loop makes lands on a whole second. Either fake
# refuses any other arguments, so a script that needs more than this
# fails, rather than reading the real clock.
#
# on_clock COMMAND... runs the command in a subshell with DIR first on
# PATH and the clock at fake_clock_start. clock_slept prints how many
# seconds the last on_clock run slept.
#
# On the wall clock, `date +%s` read a no-pid row just before one second
# ended and the next read, 1.07s later, just after the second after it, so
# the two read as 2 seconds apart and a 2-second settle time ended a read
# early.

fake_clock_start=1794000000

fake_clock_install() {
    fake_clock_dir=$1
    mkdir -p "$fake_clock_dir"
    cat >"$fake_clock_dir/date" <<EOF
#!/bin/sh
[ "\$*" = +%s ] || { echo "fake date: unexpected \$*" >&2; exit 1; }
cat "$fake_clock_dir/now"
EOF
    cat >"$fake_clock_dir/sleep" <<EOF
#!/bin/sh
case \$1 in *[!0-9]* | '') echo "fake sleep: unexpected \$*" >&2; exit 1 ;; esac
echo \$((\$(cat "$fake_clock_dir/now") + \$1)) >"$fake_clock_dir/now"
EOF
    chmod +x "$fake_clock_dir/date" "$fake_clock_dir/sleep"
}

on_clock() { # <command>...
    (echo "$fake_clock_start" >"$fake_clock_dir/now"; PATH="$fake_clock_dir:$PATH"; "$@")
}

clock_slept() {
    echo $(($(cat "$fake_clock_dir/now") - fake_clock_start))
}
