---
name: setup-mp-ported-skills
description: Turn each of this plugin's profile features on or off -- Remote Control at startup, the smart-zone status line, and session titles.
disable-model-invocation: true
---

Turn this plugin's three features on or off in the current Claude Code **profile**'s `settings.json`, which a plugin cannot write itself:

- **Remote Control**: `remoteControlAtStartup`.
- **Status line**: `statusLine`, the profile's copy of the status line, and its install stamp. Line 2 reads `[Opus 5.5|medium] 41% of zone`, tokens in context as a percentage of the **smart zone**. The plugin's SessionStart hook keeps the copy current after this skill makes it.
- **Titles**: `env.MP_SESSION_TITLE=1`. Sessions are titled `<project> · <profile> · <host>`, and status line 1 shows only what is unusual instead of `host · profile » project » branch`.

The work is `scripts/setup.sh`, which is deterministic; this skill runs it, shows its report, and asks.

## 1. Report

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/setup.sh" report </dev/null
```

Show the report as printed: each feature `on`, `off`, or `modified` (the status line copy has local edits), with detail lines beneath.

## 2. Ask, one feature at a time

For each feature in the report's order, ask one question: turn it on, turn it off, or leave it as it is. Put its current state and the trade-off in the question, and recommend keeping the current state unless the report shows a problem.

- **Remote Control**: on lets the user drive any session from claude.ai/code or the Claude app without typing `/remote-control`; off keeps sessions local unless started by hand.
- **Status line**: on shows the zone reading in the terminal. A `statusLine` that runs another command is replaced, which needs its own yes. A `modified` copy is kept unless the user says to discard the edit; replacing or removing it needs its own yes. Off removes `statusLine` (only this plugin's), the copy and its stamp; `/glance` still gives the reading.
- **Titles**: the one setting drives both the session title and status line 1, so say both change.

## 3. Apply each yes as it comes

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/setup.sh" <remote-control|status-line|titles> <on|off> [--replace-statusline] [--force] </dev/null
```

Pass only the flags the user said yes to. Exit 1 means it refused and wrote nothing: its `!` lines name what needs a yes and the flag that gives it. Ask that one question, and on a yes run it again with the flag. Show what it prints.

Done when every feature has been asked about. Say that changes apply to sessions started from now on, and name the earliest `settings.json.pre-setup-mp-ported-skills-<time>` backup it printed, which holds `settings.json` as it was before this run.
