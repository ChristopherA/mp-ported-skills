# Starting this session

Part of `/supervise`. `SKILL.md`, beside this file, names it for the maintainer: it says how to start a supervisor session, so no step of a running supervisor reads it.

No step of this skill, `capturing` or `resuming` calls `Artifact`, `Workflow`, `ScheduleWakeup`, `SendFeedback` or Claude in Chrome: a supervisor does not publish a page, run a workflow, schedule a `/loop` wakeup, draft feedback or drive a browser. `launch.sh` leaves the same ones out of a worker. A supervisor started from a terminal without them has 20.4k tokens less at its first call, 13.6 points of a 150k zone (`docs/research/supervisor-context.md`):

```sh
claude --disallowedTools Artifact,Workflow,ScheduleWakeup,SendFeedback --no-chrome
```

Then type `/mp-ported-skills:supervise ...` in it, or give the command as `claude`'s first positional prompt, after the flags: an interactive session started that way runs it as the skill, not as plain text (Claude Code 2.1.325, #262). Keep `--disallowedTools` away from the prompt, since a list option reads the next bare word into its list. For a start that takes one word to type, the maintainer can copy this function into their own shell setup (zsh or bash; POSIX `sh` refuses the hyphen):

```sh
claude-supervise() {
    claude --disallowedTools Artifact,Workflow,ScheduleWakeup,SendFeedback --no-chrome \
        "/mp-ported-skills:supervise ${*:-. --loop --model claude-opus-5-5 --effort medium}"
}
```

`claude-supervise` alone runs the loop on the Project in the current folder with an Opus worker at medium effort; any arguments replace that command's, as `claude-supervise ../app --loop 2`. It calls `claude` by name, so a wrapper the maintainer's shell defines for `claude` still runs. The command leaves plugins alone, since which ones a profile holds is the profile's; one the supervisor never uses can be turned off for the session with `--settings '{"enabledPlugins":{"<plugin>@<marketplace>":false}}'`.

From the Claude app, a session gets only what its `claude remote-control` server was started with. Keep a server for supervising, started in the Project folder with a settings file it hands to every session it spawns:

```sh
claude remote-control --spawn same-dir --no-chrome --permission-mode auto --settings <file>
```

with the deny in `<file>`:

```json
{"permissions": {"deny": ["Artifact", "Workflow", "ScheduleWakeup", "SendFeedback"]}}
```

Keep the file outside the Project folder, so the tree stays clean, and somewhere sessions are not meant to write, as the server's help asks; the server reads it once, at start, so restart the server after changing it. Pass `--spawn same-dir`: a supervisor runs from the main checkout (Policy, below), and the server saves its spawn mode for the folder, so one started there once with `--spawn worktree` gives later sessions a worktree each. Pass `--permission-mode auto`: with `--settings`, the server no longer turns on auto mode or auto-compact for its sessions. Auto-compact stays off, so a long supervisor there ends on the loop's zone stop and its capture, not on a compaction. The deny is the one `launch.sh` and the terminal start leave out. The file is ordinary settings, so #230's supervisor exclude list can go in it as `claudeMdExcludes`, as `launch.sh` gives a worker its excludes through `--settings`; whether that list joins the profile's own is #230's to check. The server passed the file, auto mode and `--no-chrome` to the session it spawned (Claude Code 2.1.325, #262), but that session's first call has not been read: a first message can come only from the app.

Until that reading shows the four tools gone, the measured route stays: start the server with `--no-chrome`, and put the deny in the settings of the folder the server runs in, `.claude/settings.local.json`: `"permissions": {"deny": ["Artifact", "Workflow", "ScheduleWakeup", "SendFeedback"]}` (57,752 at the first call, `docs/research/supervisor-context.md`). It holds for every session started in that folder, the maintainer's own included, until removed, which is what the server's `--settings` route avoids. Add the file to `.gitignore` when git does not already ignore it: an untracked file makes the tree dirty, and `launch.sh` refuses a dirty tree.
