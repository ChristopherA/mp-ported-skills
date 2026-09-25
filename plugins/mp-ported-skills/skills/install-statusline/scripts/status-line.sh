#!/bin/sh
# status-line.sh -- Claude Code status line measured against the smart zone.
#
# Line 1: host · profile » project » branch
# Line 2: [Model] 62k / 150k   (tokens used against the smart zone: green
#                               below two thirds of it, yellow up to it, red
#                               past it)
#
# Wraps status-line-base.sh, an unmodified copy of claude-workstream-kit's
# .claude/scripts/status-line.sh (source below). The base renders line 1 and
# writes <dir>/claude-<session_id>-context.json on every update. This wrapper
# adds the machine and the profile (from CLAUDE_CONFIG_DIR), so an empty or
# missing profile marker shows as the wrong name rather than passing silently,
# and replaces the base's line 2: the base colours by share of the usable
# window, which on a 1M window stays green long after a session has left the
# ~150k-token smart zone.
#
#   status-line.sh --context <project-dir>
#
# prints "context: 62k tokens used of a 150k smart zone, 94% of window
# remaining" from the newest record for that project, or nothing when there is
# none, so a caller says nothing rather than reporting zero.
#
# Environment:
#   MP_SMART_ZONE_K             smart zone in thousands of tokens (default 150)
#   WORKSTREAM_KIT_CONTEXT_DIR  record directory, for both scripts (default /tmp)
#
# Base copied from ChristopherA/claude-workstream-kit 5115068 (v0.11.0),
# 2026-09-05. To update: copy the kit's newer .claude/scripts/status-line.sh
# over status-line-base.sh unmodified, and change this line.

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
base="$here/status-line-base.sh"

zone_k=${MP_SMART_ZONE_K:-150}
case $zone_k in ''|*[!0-9]*|0) zone_k=150 ;; esac

# === --context <project-dir>: the read side ===
# Same record, directory and path normalisation as the base's own --context;
# only the sentence differs, so it reads the record fields directly.
if [ "${1:-}" = "--context" ]; then
    [ -n "${2:-}" ] || { echo "usage: status-line.sh --context <project-dir>" >&2; exit 2; }
    command -v jq >/dev/null 2>&1 || exit 0
    dir=${WORKSTREAM_KIT_CONTEXT_DIR:-/tmp}
    find "${dir%/}/" -maxdepth 1 -name 'claude-*-context.json' -exec jq -rs --arg p "$2" --arg z "$zone_k" \
      'def norm: gsub("/+"; "/") | rtrimstr("/");
       [.[]|select((.project_dir|norm)==($p|norm))]|sort_by(.updated)|last
       |if . then "context: \(.context_window_size * (100 - .remaining_pct) / 100 / 1000 | floor)k tokens used of a \($z)k smart zone, \(.remaining_pct)% of window remaining" else empty end' {} + 2>/dev/null
    exit 0
fi

# === Render ===
input=$(cat)
[ -n "$input" ] || exit 0

host=$(hostname -s 2>/dev/null) || host=""
profile=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")
profile=${profile#.claude-}
[ "$profile" = ".claude" ] && profile=default

out=$(printf '%s' "$input" | sh "$base")
line1=$(printf '%s\n' "$out" | sed -n 1p | sed 's/ » none$//')

if [ -n "$line1" ]; then
    printf '%s · %s » %s\n' "$host" "$profile" "$line1"
else
    printf '%s · %s\n' "$host" "$profile"
fi

# Without jq the base has already said so on its line 2; pass it through.
if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$out" | sed -n '2,$p'
    exit 0
fi

_tsv=$(printf '%s' "$input" | jq -r '[
  .model.display_name // "",
  ((.context_window.used_percentage // 0) * (.context_window.context_window_size // 0) / 100 / 1000 | floor)
] | @tsv' 2>/dev/null) || _tsv=""
model_name=$(printf '%s' "$_tsv" | cut -f1)
used_k=$(printf '%s' "$_tsv" | cut -f2)

# No usage data yet: an empty line 2, as the base does.
case $used_k in ''|*[!0-9]*|0) echo ""; exit 0 ;; esac

model_prefix=""
[ -n "$model_name" ] && model_prefix="[${model_name}] "

if [ "$used_k" -gt "$zone_k" ]; then
    color='\033[0;31m'
elif [ "$used_k" -ge $((zone_k * 2 / 3)) ]; then
    color='\033[0;33m'
else
    color='\033[0;32m'
fi
printf '%s%b%sk / %sk%b\n' "$model_prefix" "$color" "$used_k" "$zone_k" '\033[0m'
