---
name: setup-mp-ported-skills
description: Turn each of this plugin's profile features on or off -- Remote Control at startup, the smart-zone status line, and session titles -- offer to scaffold a Project's docs/agents/supervision.md, and ask whether its code lives in a Distribution repo.
disable-model-invocation: true
---

Turn this plugin's three profile features on or off in the current Claude Code **profile**'s `settings.json`, which a plugin cannot write itself, and offer to write two Project files:

- **Remote Control**: `remoteControlAtStartup`.
- **Status line**: `statusLine`, the profile's copy of the status line, and its install stamp. Line 2 reads `[Opus 5.5|medium] 41% of zone`, tokens in context as a percentage of the **smart zone**. The plugin's SessionStart hook keeps the copy current after this skill makes it.
- **Titles**: `env.MP_SESSION_TITLE=1`. Sessions are titled `<project> · <profile> · <host>`, and status line 1 shows only what is unusual instead of `host · profile » project » branch`.
- **Supervision doc** (#58): `docs/agents/supervision.md` in a **Project**, not the profile -- where `/supervise` reads standing grants for a worker's shared actions. This one has no off: once written, it is the maintainer's file to keep or edit by hand.
- **Distribution repo** (#143): `docs/agents/distribution-repo.md` at the Project repo's top, one path naming the separate repo, cloned beside it, that the Project's code is committed to. `/supervise` reads it to watch and push that repo's work. No file means the code lives in the Project's own repo. Run this in the maintainer's own session: a `/supervise` worker may not edit it.

The work is `scripts/setup.sh`, which is deterministic; this skill runs it, shows its report, and asks. The Project is the directory this session is running in, or one the user names; pass it as `--project-dir DIR` when it is not the current directory.

## 1. Report

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/setup.sh" [--project-dir DIR] report </dev/null
```

Show the report as printed: each feature `on`, `off`, or `modified` (the status line copy has local edits), with detail lines beneath; `supervision-doc` and `distribution-repo` read `present` or `absent`.

## 2. Ask, one feature at a time

For each feature in the report's order, ask one question: turn it on, turn it off, or leave it as it is. Put its current state and the trade-off in the question, and recommend keeping the current state unless the report shows a problem.

- **Remote Control**: on lets the user drive any session from claude.ai/code or the Claude app without typing `/remote-control`; off keeps sessions local unless started by hand.
- **Status line**: on shows the zone reading in the terminal. A `statusLine` that runs another command is replaced, which needs its own yes. A `modified` copy is kept unless the user says to discard the edit; replacing or removing it needs its own yes. So is a copy from a release that cannot be ordered against the plugin's (a pre-release, say): replacing it needs its own yes, and passes `--force`. Off removes `statusLine` (only this plugin's), the copy and its stamp; `/glance` still gives the reading.
- **Titles**: the one setting drives both the session title and status line 1, so say both change.
- **Supervision doc**: when `absent`, offer to write an empty scaffold that shows where grants go and says an empty file grants nothing -- on its own it changes no behavior, since `/supervise` already stops for approval with no file. When `present`, there is nothing to ask; say so and move on.
- **Distribution repo**: ask whether this Project's code is committed to a separate repo cloned beside it. When `absent`, a `suggested:` line beneath it (a `-dev` folder's sibling checkout, or a path a `CLAUDE.md` line names) is the recommended yes, naming that path; with none, recommend no. On no, write nothing, and say that no file means the code lives in this repo. When `present`, its `names` line is the current answer: recommend keeping it, which runs nothing; the other choices are another path or no.

## 3. Apply each yes as it comes

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/setup.sh" [--project-dir DIR] <remote-control|status-line|titles> <on|off> [--replace-statusline] [--force] </dev/null
sh "${CLAUDE_SKILL_DIR}/scripts/setup.sh" [--project-dir DIR] supervision-doc write </dev/null
sh "${CLAUDE_SKILL_DIR}/scripts/setup.sh" [--project-dir DIR] distribution-repo <write PATH|remove> </dev/null
```

For the Distribution repo, `write PATH` takes the path relative to the Project repo's top or absolute, and leaves a file that already names that repo as it is; `remove` is the answer changed to no. A path that is not a git checkout of its own is refused: show the message, and ask for another path or no.

Pass only the flags the user said yes to. Exit 1 means it refused and wrote nothing: its `!` lines name what needs a yes and the flag that gives it. Ask that one question, and on a yes run it again with the flag. Show what it prints.

Done when every feature has been asked about. Say that changes apply to sessions started from now on, and name the earliest `settings.json.pre-setup-mp-ported-skills-<time>` backup it printed, which holds `settings.json` as it was before this run. For a written supervision doc, say it grants nothing until a line is added under "## Grants" and pushed to the Project's default branch. For a written or removed Distribution repo file, say `/supervise` sees the change only once it is committed and pushed to the default branch, which is the maintainer's to do.
