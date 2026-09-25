---
name: install-statusline
description: Install a status line that measures context against the ~150k-token smart zone.
disable-model-invocation: true
---

Install a status line into the current Claude Code profile. Line 2 reads `[Opus 5.5|medium] 41% of zone`: the model, its effort level, and tokens in context as a percentage of the **smart zone** (~150k tokens), green through 100%, yellow past it, red from 200%. A percentage of a 1M window stays green long after a session has left the smart zone; this line turns yellow where a **phase boundary** is due, and red where the session is well past anything reported to work. Haiku 4.5's 200K window caps it near 133%, so it compacts before it can turn red. `capturing` reads the same number through `status-line.sh --context`.

The work is `scripts/install.sh`, which is deterministic; this skill runs it, shows its report, and asks.

## 1. Report

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/install.sh" --dry-run </dev/null
```

Show the report as printed. Exit 0 means everything is in sync: say so and stop.

## 2. Ask

Each `!` line needs its own yes, asked one at a time:

- **`! statusLine`**: the profile already runs another status line. Show its command, say this one replaces it, and ask. A yes adds `--replace-statusline`.
- **`! scripts/<file>  installed X is newer than this Y`**: the profile already has a later release, and this run comes from an older plugin copy, as a session started before an update does. Replacing it installs the older release. A yes adds `--force`.
- **`! scripts/<file>  modified`**: an installed copy was edited after it was installed, or came from elsewhere. Replacing it discards that edit. A yes adds `--force`.

With no `!` lines, ask once whether to install.

## 3. Install

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/install.sh" [--replace-statusline] [--force] </dev/null
```

Pass only the flags the user said yes to. Done when it exits 0. Tell the user the status line shows in sessions started from now on, and that `MP_SMART_ZONE_K` in the profile's `env` settings moves the threshold (in thousands of tokens).
