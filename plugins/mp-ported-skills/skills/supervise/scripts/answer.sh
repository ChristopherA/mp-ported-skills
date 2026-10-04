#!/bin/sh
# answer.sh -- whether a blocked worker's question is one the supervisor's
# policy already decides, and the answer to send it (#90).
#
# Reads the worker's last message from its transcript, found by the job's
# sessionId in any project folder as last-message.sh finds it. The question
# is, in this order:
#   - a pending AskUserQuestion call in that message, when it asks exactly
#     one question;
#   - a last line `Waiting on: <command>`, as launch.sh tells a worker to end
#     on a shared action it believes no grant covers;
#   - the last sentence of its text, when the text ends on it and holds no
#     other `?`.
# Two kinds are routine:
#   ticket  confirming the ticket it was launched on, "Proceed with #N?"
#           and close forms, naming no other ticket, as the whole sentence;
#   grant   one shared action (push, pr-create, pr-merge, issue-close,
#           issue-comment, issue-create) that grant.sh finds granted on the
#           default branch as committed on origin, asked about anyway.
# Anything else is not: a question that offers a choice (" or "), names
# another ticket or several actions, an action no grant covers, a block that
# is not a question (a permission prompt), and a question already answered
# once in this worker's transcript, so a worker that asks again goes to the
# maintainer rather than round a loop.
#
# The answer is one line starting `[supervisor answer to "<question>"]`.
# record.sh counts prompts of that form as the supervisor's answers, apart
# from human interventions, and a prompt starting `[` is not counted as a
# message typed into the worker.
#
# Usage:
#   answer.sh --id ID --dir DIR --ticket N --state "<watch.sh first line>"
#
# DIR is the Project folder, read for grants. STATE is watch.sh's first line;
# only `blocked question` and `blocked input needed` can be answered.
#
# Exits 0 with three lines: `question <q>`, `rule ticket` or
# `rule grant <citation>`, `answer <the prompt to send>`. Exits 2 when the
# question is not routine: `question <q>` when one was read, then
# `not routine: <why>`. Exits 1 on an error, with nothing on stdout.

set -u

ID=""
DIR=""
TICKET=""
STATE=""

need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --id)     need_value "$@"; ID="$2"; shift 2 ;;
        --dir)    need_value "$@"; DIR="$2"; shift 2 ;;
        --ticket) need_value "$@"; TICKET="${2#\#}"; shift 2 ;;
        --state)  need_value "$@"; STATE="$2"; shift 2 ;;
        --help)
            printf 'Usage: answer.sh --id ID --dir DIR --ticket N --state "<watch.sh first line>"\n'
            printf 'Prints question, rule and answer lines (exit 0), or why the question is not routine (exit 2).\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
[ -n "$ID" ] || fail "--id is required"
[ -n "$DIR" ] || fail "--dir is required"
[ -n "$TICKET" ] || fail "--ticket is required"
[ -n "$STATE" ] || fail "--state is required"
case $TICKET in *[!0-9]*) fail "--ticket needs an issue number, not '$TICKET'" ;; esac
[ -d "$DIR" ] || fail "not a directory: $DIR"
[ -n "${CLAUDE_CONFIG_DIR:-}" ] || fail "CLAUDE_CONFIG_DIR is not set, so the worker's profile is unknown"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

not_routine() { printf 'not routine: %s\n' "$1"; exit 2; }

case $STATE in
    'blocked question' | 'blocked input needed') ;;
    *) not_routine "the worker is $STATE, not waiting on a question" ;;
esac

agents=$(claude agents --json --all </dev/null 2>/dev/null) &&
    printf '%s' "$agents" | jq -e 'type == "array"' >/dev/null 2>&1 ||
    fail "claude agents --json --all could not be read"
sid=$(printf '%s' "$agents" | jq -r --arg id "$ID" '
    [.[] | select(.kind == "background" and .id == $id)] | first | .sessionId // empty')
[ -n "$sid" ] || fail "claude agents lists no background session $ID"
transcript=""
for t in "$CLAUDE_CONFIG_DIR"/projects/*/"$sid".jsonl; do
    [ -f "$t" ] && { transcript=$t; break; }
done
[ -n "$transcript" ] || fail "no transcript for worker $ID (session $sid) under $CLAUDE_CONFIG_DIR/projects"

# One JSON value: the question, the kind it reads as, the action for a grant
# question, or why it is not routine.
read_out=$(jq -s --arg n "$TICKET" '
    def norm: gsub("[*`_]"; "") | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
    def action_of_command:
        if test("^git (-c [^ ]+ )*push\\b") then "push"
        elif test("^gh pr (create|new)\\b") then "pr-create"
        elif test("^gh pr merge\\b") then "pr-merge"
        elif test("^gh issue close\\b") then "issue-close"
        elif test("^gh issue comment\\b") then "issue-comment"
        elif test("^gh issue (create|new)\\b") then "issue-create"
        else null end;
    # The words a go-ahead question may open with, before its verb.
    def lead: "^(ok(ay)?,? )?((shall|should|can|may) i |do you want me to |want me to |ready to |ok(ay)? to )?(go ahead and )?";
    # Every shared action the question mentions anywhere.
    def actions_in:
        [(select(test("\\bpush")) | "push"),
         (select(test("\\b(open|create|raise)\\b.*\\b(pr|pull request)\\b")) | "pr-create"),
         (select(test("\\bmerge")) | "pr-merge"),
         (select(test("\\bclose\\b")) | "issue-close"),
         (select(test("\\b(comment|post)\\b")) | "issue-comment"),
         (select(test("\\b(file|open|create)\\b.*\\bissue\\b")) | "issue-create")];
    # The shared action the question asks to take: its verb right after the lead.
    def action_asked:
        if test(lead + "push\\b") then "push"
        elif test(lead + "(open|create|raise) (a |the )?(pr|pull request)\\b") then "pr-create"
        elif test(lead + "merge\\b") then "pr-merge"
        elif test(lead + "close\\b") then "issue-close"
        elif test(lead + "(comment|post)\\b") then "issue-comment"
        elif test(lead + "(file|open|create) (a |an |the )?(new )?issue\\b") then "issue-create"
        else null end;
    [.[] | objects | select(.isSidechain | not)] as $rows
    # Prompts already sent as a supervisor answer, by question.
    | [$rows[] | select(.type == "user") | .message.content
       | if type == "string" then . elif type == "array" then [.[] | select(.type == "text") | .text] | join("\n") else "" end
       | capture("^\\[supervisor answer to \"(?<q>.*)\"\\]") | .q] as $answered
    # The last message: assistant rows sharing its message id.
    | [$rows | to_entries[] | select(.value.type == "assistant")] as $said
    | ($said | last | .value.message.id // null) as $mid
    | [$said[] | select(if $mid == null then . == ($said | last) else .value.message.id == $mid end)
       | .value.message.content[]? | objects] as $blocks
    | ([$blocks[] | select(.type == "tool_use" and .name == "AskUserQuestion") | .input.questions // []] | last) as $ask
    | ([$blocks[] | select(.type == "text") | .text // empty] | join("\n\n") | sub("[\\s*_]+$"; "")) as $text
    | ([$text | split("\n")[] | select(test("\\S"))] | last // "") as $lastline
    | if $ask != null then
        if ($ask | length) != 1 then {why: "it asks \($ask | length) questions at once"}
        else {q: ($ask[0].question // "" | norm)} end
      elif ($lastline | test("^\\s*Waiting on:")) then
        ($lastline | sub("^\\s*Waiting on:\\s*"; "") | norm) as $cmd
        | {q: "Waiting on: \($cmd)", waiting: true, action: ($cmd | gsub("`"; "") | action_of_command)}
      elif $text == "" then {why: "its last message holds no text and no question"}
      elif ($text | test("\\?$") | not) then {why: "its last message does not end on a question"}
      elif ([$text | match("\\?"; "g")] | length) > 1 then {why: "its last message asks more than one question"}
      else {q: ($text | capture("(?<s>[^.!?\\n]*\\?)$").s | norm)} end
    | if .q == "" then {why: "the question could not be read"} else . end
    | . as $r
    | if $r.q == null then $r
      elif ($answered | index($r.q | gsub("\""; "'"'"'") | .[0:200])) != null then $r + {why: "it was answered once already and the worker asked again"}
      elif $r.waiting then
        if $r.action == null then $r + {why: "it waits on an action no grant can cover"} else $r + {kind: "grant"} end
      else ($r.q | ascii_downcase) as $q
        | ([$q | match("#([0-9]+)"; "g") | .captures[0].string] | unique) as $nums
        | if ($q | test("\\bor\\b")) then $r + {why: "it offers a choice"}
          elif ($nums - [$n] | length) > 0 then $r + {why: "it names a ticket other than #\($n)"}
          elif ($q | test(lead + "(proceed|start|begin|continue|implement|build|work)( (with|on|implementing|building|working on))?( (the )?(ticket|issue))? #" + $n + "( (now|then|as (specified|described|written)))?\\?$"))
            then $r + {kind: "ticket"}
          elif ($q | actions_in | length) > 1 then $r + {why: "it asks about more than one shared action"}
          elif ($q | action_asked) != null then $r + {kind: "grant", action: ($q | action_asked)}
          else $r + {why: "it is not one the policy decides: only confirming #\($n) or a granted shared action is"} end end
    ' "$transcript" 2>/dev/null) || fail "the transcript $transcript could not be read"

question=$(printf '%s' "$read_out" | jq -r '.q // empty')
why=$(printf '%s' "$read_out" | jq -r '.why // empty')
kind=$(printf '%s' "$read_out" | jq -r '.kind // empty')
action=$(printf '%s' "$read_out" | jq -r '.action // empty')

[ -z "$question" ] || printf 'question %s\n' "$question"
[ -z "$why" ] || not_routine "$why"

# The question as the answer quotes it: one line, no double quotes, so
# record.sh can read it back.
quoted=$(printf '%s' "$question" | tr '"' "'" | cut -c1-200)
case $kind in
    ticket)
        printf 'rule ticket\n'
        printf 'answer [supervisor answer to "%s"] Yes, proceed with #%s as the ticket and its latest Agent Brief describe. This is /supervise'\''s routine answer: it confirms the launched ticket and approves nothing beyond it, so if your plan departs from the ticket, stop and say so.\n' \
            "$quoted" "$TICKET" ;;
    grant)
        citation=$(sh "$SCRIPT_DIR/grant.sh" --dir "$DIR" --action "$action" </dev/null) ||
            not_routine "no standing grant covers $action"
        printf 'rule grant %s\n' "$citation"
        printf 'answer [supervisor answer to "%s"] Yes, go ahead with the %s. The Project'\''s standing grant covers it ("%s"), so take it as the grant allows, without asking again.\n' \
            "$quoted" "$action" "$citation" ;;
    *) fail "the question's kind could not be read" ;;
esac
