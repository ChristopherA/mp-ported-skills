#!/bin/sh
# record.sh -- print one supervised run's record, for a comment on its ticket.
#
# Prints a Markdown list, one field a line (with --session, see below, the
# fields marked * are left out):
# * worker                   short id and model (the job's --model flag)
# * launched                 the job's createdAt
#   turn ended               the worker transcript's last turn_duration row
#                            with no background agents pending, and how long
#                            after launch
# * reported                 --now (default: now), and how long after the
#                            turn ended: how late the supervisor saw it
#   API calls                distinct requests in the worker's transcript
#                            and its subagents'
#   tokens and cost          by model, from the worker transcript's last
#                            cost-state row, which Claude Code keeps for the
#                            whole session, subagents included
# * supervisor since launch  the supervisor transcript's calls and tokens
#                            after launch, and its cost-state total less the
#                            last one written before launch
#   peak zone                the largest context, input plus cache read and
#                            written, of any worker call, as a percentage of
#                            the smart zone (MP_SMART_ZONE_K, default 150k
#                            tokens, as the status line reads it), and the
#                            first worker call at or past 100%
#   captures and clears      capturing skill calls and prompts, /clear
#                            prompts and compactions in the worker
#   human interventions      the job timeline's blocked entries, each with
#                            its detail (*), and plain prompts typed into the
#                            worker after its first (by `claude attach`)
# * shared actions           actions.sh's lines, or none
#   outcome                  commits in START..HEAD, the job's PRs and
#                            issues (*), and the ticket's state from gh
# then a `note` line for each source it could not read. A field whose source
# was not read says unknown, never none or zero.
#
# With --session, it records a plain interactive session instead, such as
# a hand-run /implement, the baseline a supervised run is measured against:
# the session's id and most-called model, when its transcript starts, and
# the fields above not marked *.
#
# The job's state.json and timeline.jsonl are read under $CLAUDE_CONFIG_DIR,
# and each transcript by session id in any project folder.
#
# Usage:
#   record.sh --id ID --dir DIR --start SHA --ticket N
#             [--supervisor SESSION_ID] [--now ISO-8601 UTC]
#   record.sh --session SESSION_ID --dir DIR --start SHA --ticket N
#
# DIR is the checkout the worker committed in (watch.sh's cwd line), START
# the commit the branch started at. The supervisor's session defaults to
# $CLAUDE_CODE_SESSION_ID, the session running this script.

set -u

ID=""
SESSION=""
DIR=""
START=""
TICKET=""
SUPERVISOR="${CLAUDE_CODE_SESSION_ID:-}"
NOW=""

need_value() { [ $# -ge 2 ] || { printf 'Error: %s needs a value\n' "$1" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --id)         need_value "$@"; ID="$2"; shift 2 ;;
        --session)    need_value "$@"; SESSION="$2"; shift 2 ;;
        --dir)        need_value "$@"; DIR="$2"; shift 2 ;;
        --start)      need_value "$@"; START="$2"; shift 2 ;;
        --ticket)     need_value "$@"; TICKET="${2#\#}"; shift 2 ;;
        --supervisor) need_value "$@"; SUPERVISOR="$2"; shift 2 ;;
        --now)        need_value "$@"; NOW="$2"; shift 2 ;;
        --help)
            printf 'Usage: record.sh --id ID --dir DIR --start SHA --ticket N [--supervisor SESSION_ID] [--now ISO]\n'
            printf '       record.sh --session SESSION_ID --dir DIR --start SHA --ticket N\n'
            printf 'Prints the run record as a Markdown list, then note lines for sources it could not read.\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done
fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }
[ -n "$ID$SESSION" ] || fail "--id or --session is required"
[ -z "$ID" ] || [ -z "$SESSION" ] || fail "--id and --session are exclusive"
[ -n "$DIR" ] || fail "--dir is required"
[ -n "$START" ] || fail "--start is required"
[ -n "$TICKET" ] || fail "--ticket is required"
case $TICKET in *[!0-9]*) fail "--ticket needs an issue number, not '$TICKET'" ;; esac
[ -d "$DIR" ] || fail "not a directory: $DIR"
[ -n "${CLAUDE_CONFIG_DIR:-}" ] || fail "CLAUDE_CONFIG_DIR is not set, so the worker's job is unknown"
git -C "$DIR" rev-parse -q --verify "$START^{commit}" >/dev/null || fail "not a commit in $DIR: $START"
[ -n "$NOW" ] || NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -en --arg t "$NOW" '$t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' >/dev/null 2>&1 ||
    fail "--now needs an ISO 8601 UTC time such as 2026-09-29T06:15:24Z, not '$NOW'"
zone_k=${MP_SMART_ZONE_K:-150}
case $zone_k in '' | *[!0-9]* | 0) zone_k=150 ;; esac
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
errors=$(mktemp)
trap 'command rm -f "$errors"' EXIT

notes=""
note() { notes="${notes}- note: $1
"; }

# transcript <session id>: the path of its transcript in any project folder.
transcript() {
    for t in "$CLAUDE_CONFIG_DIR"/projects/*/"$1".jsonl; do
        [ -f "$t" ] && { printf '%s\n' "$t"; return 0; }
    done
    return 1
}

# Shared jq definitions: time, size and money as the record prints them, and
# a transcript's API calls, one per request in the order first written.
defs='
def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
def stamp: sub("\\.[0-9]+Z$"; "Z");
def span: (. / 60 | round) as $m
    | if . < 60 then "under a minute" elif $m < 60 then "\($m) min" else "\($m / 60 | floor) h \($m % 60) min" end;
def size: if . >= 1000000 then "\(. / 100000 | round / 10 | tostring | if test("\\.") then . else . + ".0" end)M"
    elif . >= 1000 then "\(. / 1000 | round)k" else tostring end;
def money: (. * 100 | round) as $c | "$\($c / 100 | floor).\($c % 100 | tostring | if length < 2 then "0" + . else . end)";
def calls: [.[] | select(.type == "assistant" and .message.usage != null)]
    | reduce .[] as $r ({seen: {}, list: []};
        ($r.requestId // $r.message.id // "") as $k
        | if $k != "" and .seen[$k] then . else .seen[$k] = true | .list += [$r] end)
    | .list;
def context: .message.usage | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0);
def tokens: context + (.message.usage.output_tokens // 0);
'

# --- the job ---------------------------------------------------------------
job="$CLAUDE_CONFIG_DIR/jobs/$ID/state.json"
timeline="$CLAUDE_CONFIG_DIR/jobs/$ID/timeline.jsonl"
model="unknown" launched="" sid="$SESSION" children=""
if [ -n "$SESSION" ]; then
    :
elif [ ! -f "$job" ]; then
    note "no job state for $ID under $CLAUDE_CONFIG_DIR/jobs, so the worker's model, launch, session, PRs and waits were not read"
elif ! jobrow=$(jq -r '[(.respawnFlags // [] | . as $f | (index("--model") // null) as $i
        | if $i == null then "" else $f[$i + 1] // "" end),
        (.createdAt // ""), (.sessionId // ""),
        ([.children // [] | .[] | "\(if .kind == "pr" then "PR" else .kind // "item" end) #\(.id)"] | join(", "))]
        | @tsv' "$job" 2>/dev/null); then
    note "job state $job could not be read, so the worker's model, launch, session, PRs and waits were not read"
else
    model=$(printf '%s' "$jobrow" | cut -f1)
    launched=$(printf '%s' "$jobrow" | cut -f2)
    sid=$(printf '%s' "$jobrow" | cut -f3)
    children=$(printf '%s' "$jobrow" | cut -f4)
    [ -n "$model" ] || model="default model"
    [ -n "$launched" ] || note "job state $job names no createdAt, so the launch time was not read"
    [ -n "$sid" ] || note "job state $job names no session, so the worker's transcript was not read"
fi

# --- the worker's transcript -----------------------------------------------
worker='{}'
if [ -n "$sid" ]; then
    if ! wt=$(transcript "$sid"); then
        note "no transcript for session $sid under $CLAUDE_CONFIG_DIR/projects, so its calls, cost, zone, captures and typed messages were not read"
    elif ! worker=$(jq -cs --argjson z "$zone_k" "$defs"'
        def text: .message.content | if type == "string" then .
            elif type == "array" and all(.[]; .type == "text") then map(.text) | join("\n") else null end;
        [.[] | objects] as $rows
        | ($rows | calls) as $calls
        | ($calls | map(context * 100 / ($z * 1000) | floor)) as $pct
        | {calls: ($pct | length),
           peak: ($pct | max),
           crossed: ([range($pct | length) | select($pct[.] >= 100)] | first | if . == null then null else . + 1 end),
           started: ([$rows[] | .timestamp // empty] | first),
           model: ($calls | group_by(.message.model // "unknown") | max_by(length) | if . == null then null else .[0].message.model // "unknown" end),
           turnEnd: ([$rows[] | select(.type == "system" and .subtype == "turn_duration"
                        and (.pendingBackgroundAgentCount // 0) == 0) | .timestamp // empty] | last),
           captures: ([$rows[] | select(.type == "assistant") | .message.content[]? | objects
                        | select(.type == "tool_use" and .name == "Skill"
                                 and (.input.skill // "" | test("(^|:)capturing$")))] | length)
                     + ([$rows[] | select(.type == "user") | text // empty
                        | select(test("<command-name>/([^<]*:)?capturing</command-name>"))] | length),
           clears: ([$rows[] | select(.type == "user") | text // empty
                     | select(test("<command-name>/clear</command-name>"))] | length),
           compacts: ([$rows[] | select(.type == "system" and .subtype == "compact_boundary")] | length),
           # The first prompt is the launch prompt, a slash command or plain text.
           typed: ([$rows[] | select(.type == "user" and (.isMeta // false | not)) | text // empty] | .[1:]
                   | map(select(test("^\\s*[<\\[]") | not)) | length),
           usage: ([$rows[] | select(.type == "cost-state")] | last
                   | if . == null then null
                     else {total: (.totalCostUSD // 0),
                           models: [.modelUsage // {} | to_entries[]
                                    | {model: .key, cost: (.value.costUSD // 0),
                                       tokens: ([.value | .inputTokens, .outputTokens, .cacheReadInputTokens,
                                                 .cacheCreationInputTokens] | map(. // 0) | add)}]} end)}' \
        "$wt" 2>/dev/null); then
        note "transcript $wt could not be read, so its calls, cost, zone, captures and typed messages were not read"
        worker='{}'
    else
        [ "$(printf '%s' "$worker" | jq -r '.usage == null')" = false ] ||
            note "the transcript holds no cost-state row, so its tokens and cost were not read"
        [ "$(printf '%s' "$worker" | jq -r '.turnEnd == null')" = false ] ||
            note "the transcript holds no turn end, so its turn had not ended when this was recorded"
    fi
fi

# Subagents' calls, only when the worker's own transcript was read.
subcalls=""
if [ "$(printf '%s' "$worker" | jq -r '.calls != null')" = true ]; then
    subcalls=0
    for t in "${wt%.jsonl}"/subagents/*.jsonl; do
        [ -f "$t" ] || continue
        if n=$(jq -s "$defs"'[.[] | objects] | calls | length' "$t" 2>/dev/null); then
            subcalls=$((subcalls + n))
        else
            note "subagent transcript $t could not be read, so its calls were not counted"
            subcalls=""
            break
        fi
    done
fi

# --- the supervisor's share ------------------------------------------------
supervisor=""
if [ -n "$SESSION" ]; then
    :
elif [ -z "$SUPERVISOR" ]; then
    note "no supervisor session id (--supervisor or CLAUDE_CODE_SESSION_ID), so its share was not read"
elif [ -z "$launched" ]; then
    note "the launch time is unknown, so the supervisor's share was not read"
elif ! st=$(transcript "$SUPERVISOR"); then
    note "no transcript for supervisor session $SUPERVISOR under $CLAUDE_CONFIG_DIR/projects, so its share was not read"
elif ! supervisor=$(jq -rs --arg l "$launched" "$defs"'
        ($l | epoch) as $launch
        | [.[] | objects] as $rows
        | ($rows | calls | map(select((.timestamp // "") != "" and (.timestamp | epoch) >= $launch))) as $after
        # Each cost-state row is taken as written at the last timestamp before it.
        | (reduce $rows[] as $r ({at: null, before: 0, last: null};
            if $r.timestamp then .at = ($r.timestamp | epoch) else . end
            | if $r.type == "cost-state" then
                .last = ($r.totalCostUSD // 0)
                | if .at == null or .at < $launch then .before = ($r.totalCostUSD // 0) else . end
              else . end)) as $cost
        | "\($after | length) API calls, \($after | map(tokens) | add // 0 | size) tokens"
          + (if $cost.last == null then ", cost unknown" else ", \($cost.last - $cost.before | money)" end)' \
        "$st" 2>/dev/null); then
    note "supervisor transcript $st could not be read, so its share was not read"
    supervisor=""
fi

# --- waits on a human ------------------------------------------------------
waits=""
if [ -n "$SESSION" ]; then
    :
elif [ ! -f "$timeline" ]; then
    [ ! -f "$job" ] || note "no timeline for $ID under $CLAUDE_CONFIG_DIR/jobs, so its waits on a human were not read"
    waits="unknown"
elif ! waits=$(jq -rs '[.[] | objects | select(.state == "blocked") | .detail // ""] as $w
        | if ($w | length) == 0 then ""
          else "\($w | length) wait\(if ($w | length) > 1 then "s" else "" end) on a human"
               + (($w | map(select(. != "")) | join("; ")) as $d | if $d == "" then "" else " (\($d))" end) end' \
        "$timeline" 2>/dev/null); then
    note "timeline $timeline could not be read, so its waits on a human were not read"
    waits="unknown"
fi

# --- shared actions and outcome --------------------------------------------
actions=""
if [ -n "$SESSION" ]; then
    :
elif ! actions=$(sh "$SCRIPT_DIR/actions.sh" --id "$ID" --dir "$DIR" --start "$START" </dev/null 2>"$errors"); then
    note "actions.sh failed, so the shared actions were not read: $(head -n 1 "$errors")"
    actions="unknown"
fi
shared_notes=$(printf '%s\n' "$actions" | sed -n 's/^note //p')
actions=$(printf '%s\n' "$actions" | grep -v '^note ' | grep -v '^$')
if [ -n "$shared_notes" ]; then
    oldIFS=$IFS; IFS='
'
    for n in $shared_notes; do note "$n"; done
    IFS=$oldIFS
fi

short=$(git -C "$DIR" rev-parse --short "$START")
count=$(git -C "$DIR" rev-list --count "$START..HEAD" 2>/dev/null) || {
    note "git rev-list $START..HEAD failed in $DIR, so the commits were not counted"
    count=""
}
if state=$(cd "$DIR" && gh issue view "$TICKET" --json state --jq .state </dev/null 2>/dev/null) && [ -n "$state" ]; then
    ticket="ticket #$TICKET $state"
else
    note "gh issue view $TICKET failed, so the ticket's state was not read"
    ticket="ticket #$TICKET state unknown"
fi

# --- print -----------------------------------------------------------------
jq -rn --arg id "$ID" --arg session "$SESSION" --arg model "$model" --arg launched "$launched" --arg now "$NOW" \
    --argjson w "$worker" --arg sub "$subcalls" --arg sup "$supervisor" --arg waits "$waits" \
    --arg actions "$actions" --arg short "$short" --arg count "$count" --arg children "$children" \
    --arg ticket "$ticket" --arg n "$TICKET" "$defs"'
    def plural($k; $word): "\($k) \($word)\(if $k == 1 then "" else "s" end)";
    ($session != "") as $hand
    | (if $hand then "session" else "worker" end) as $who
    | (if $hand then $w.started // "" else $launched end) as $launched
    | ($launched | if . == "" then null else epoch end) as $l
    | ($w.turnEnd | if . == null then null else epoch end) as $e
    | (if $hand then "## Hand run of #\($n)" else "## Supervised run of #\($n)" end),
      "",
      (if $hand then "- session: \($session), \($w.model // "unknown")",
                     "- started: \(if $launched == "" then "unknown" else $launched | stamp end)"
       else "- worker: \($id), \($model)",
            "- launched: \(if $launched == "" then "unknown" else $launched | stamp end)" end),
      "- turn ended: \(if $e == null then "unknown"
                       else ($w.turnEnd | stamp) + (if $l == null then ""
                            else ", \($e - $l | span) after \(if $hand then "the start" else "launch" end)" end) end)",
      (select($hand | not)
       | "- reported: \($now | stamp)\(if $e == null then "" else ", \(($now | epoch) - $e | span) after the turn ended" end)"),
      "- API calls: \(if $w.calls == null then "unknown"
                     elif $sub == "" then "\($w.calls) by the \($who), its subagents unknown"
                     else "\($w.calls + ($sub | tonumber)), \($w.calls) by the \($who) and \($sub) by its subagents" end)",
      "- tokens and cost: \(if $w.usage == null then "unknown"
                            else ([$w.usage.models | sort_by(.model)[] | "\(.model) \(.tokens | size) tokens \(.cost | money)"]
                                  + ["\($w.usage.total | money) in all"]) | join("; ") end)",
      (select($hand | not) | "- supervisor since launch: \(if $sup == "" then "unknown" else $sup end)"),
      "- peak zone: \(if $w.calls == null then "unknown"
                     elif $w.calls == 0 then "none: no API calls"
                     else "\($w.peak)%" + (if $w.crossed == null then "" else ", past 100% from \($who) call \($w.crossed)" end) end)",
      "- captures and clears: \(if $w.calls == null then "unknown"
                               else [(select($w.captures > 0) | plural($w.captures; "capture")),
                                     (select($w.clears > 0) | plural($w.clears; "clear")),
                                     (select($w.compacts > 0) | plural($w.compacts; "compact"))]
                                    | if length == 0 then "none" else join(", ") end end)",
      "- human interventions: \([(select($waits != "") | if $waits == "unknown" then "unknown waits" else $waits end),
                                 (if $w.calls == null then "unknown typed messages"
                                  elif $w.typed > 0 then "\(plural($w.typed; "message")) typed into the \($who)"
                                  else empty end)]
                                | if length == 0 then "none" else join(", ") end)",
      (select($hand | not)
       | if $actions == "" or $actions == "none" then "- shared actions: none"
         elif $actions == "unknown" then "- shared actions: unknown"
         else "- shared actions:", ($actions | split("\n")[] | "  - \(.)") end),
      "- outcome: \([(if $count == "" then "commits unknown"
                      elif $count == "0" then "no commits after \($short)"
                      else "\(plural($count | tonumber; "commit")) after \($short)" end),
                     (select($children != "") | $children), $ticket] | join(", "))"'
printf '%s' "$notes"
