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
# colon. A caller puts it first: jq "$park_def ...".
park_def='def parked: ([splits("\r?\n") | select(test("\\S"))] | first // "")
    | test("^\\s*## Parked(\\s|:|$)");'

# park_line_sed: a sed program printing the question from each line of a
# text that starts `Parked:`, less markdown wrapping (backticks, bold), as
# watch.sh reads `Waiting on:`. A caller keeps the last: sed -n "$park_line_sed" | tail -n 1.
park_line_sed='s/^[`* ]*Parked: *//p'

# park_question_def: a jq def, `park_question`, the question from a text's
# last line starting `Parked:`, less markdown wrapping as watch.sh strips
# it, or null.
park_question_def='def park_question: [splits("\n") | select(test("^[`* ]*Parked:"))] | last
    | if . == null then null else sub("^[`* ]*Parked: *"; "") | sub("[`* ]*$"; "") end;'
