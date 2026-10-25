#!/bin/sh
# park.sh -- sourced by resuming's state.sh, launch.sh, watch.sh and
# record.sh: how a parked ticket and a parked worker are told apart (#158).
#
# An unattended worker that reaches a decision only the maintainer can make
# parks its ticket: it posts the question on the ticket as a comment opening
# with park_heading, and ends its turn on a line starting `Parked:`. Keep one
# copy of both here, for every prompt text and script that writes or reads
# them.

# park_heading: the line a park comment opens with.
park_heading='## Parked'

# park_def: a jq def, `parked`, true for a comment body whose first non-blank
# line is park_heading, alone or followed by more text after a space or a
# colon. A caller puts it first: jq "$park_def ...". park_heading holds no
# regex character, so it goes into the pattern as written.
park_def='def parked: ([splits("\r?\n") | select(test("\\S"))] | first // "")
    | test("^\\s*'"$park_heading"'(\\s|:|$)");'

# park_record_def: a jq def, `run_record`, true for a comment body that is a
# run record /supervise posts after a worker's run (record.sh's heading,
# `## Supervised run of #N` or `## Hand run of #N`). A record is not a reply
# to a park question, and finish.sh posts one after every park.
park_record_def='def run_record: test("^\\s*## (Supervised|Hand) run of #[0-9]+");'

# park_line_sed: a sed program printing the question from each line of a
# text that starts `Parked:`, less markdown wrapping (backticks, bold) at
# either end, as watch.sh reads `Waiting on:`. A caller keeps the last:
# sed -n "$park_line_sed" | tail -n 1.
park_line_sed='/^[`* ]*Parked:/{s/^[`* ]*Parked: *//;s/[`* ]*$//;p;}'

# park_question_def: a jq def, `park_question`, the question from a text's
# last line starting `Parked:`, less markdown wrapping as park_line_sed
# strips it, or null.
park_question_def='def park_question: [splits("\n") | select(test("^[`* ]*Parked:"))] | last
    | if . == null then null else sub("^[`* ]*Parked: *"; "") | sub("[`* ]*$"; "") end;'
