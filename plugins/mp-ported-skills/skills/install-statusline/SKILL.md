---
name: install-statusline
description: Install a status line that measures context against the ~150k-token smart zone.
disable-model-invocation: true
---

Install a status line into the current Claude Code profile. Line 2 reads `[Model] 62k / 150k`: tokens used against the **smart zone**, green below two thirds of it, yellow up to it, red past it. A percentage of a 1M window stays green long after a session has left the smart zone; this line turns at the point where a **phase boundary** is due. `capturing` reads the same number through `status-line.sh --context`.

The work is `scripts/install.sh`, which is deterministic; this skill runs it, shows its report, and asks.

## 1. Report

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/install.sh" --dry-run </dev/null
```

Show the report as printed. Exit 0 means everything is in sync: say so and stop.

## 2. Ask

Each `!` line needs its own yes, asked one at a time:

- **`! statusLine`**: the profile already runs another status line. Show its command, say this one replaces it, and ask. A yes adds `--replace-statusline`.
- **`! scripts/<file>`**: an installed copy was edited after it was installed, or came from elsewhere. Replacing it discards that edit. A yes adds `--force`.

With no `!` lines, ask once whether to install.

## 3. Install

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/install.sh" [--replace-statusline] [--force] </dev/null
```

Pass only the flags the user said yes to. Done when it exits 0. Tell the user the status line shows in sessions started from now on, and that `MP_SMART_ZONE_K` in the profile's `env` settings moves the threshold (in thousands of tokens).
