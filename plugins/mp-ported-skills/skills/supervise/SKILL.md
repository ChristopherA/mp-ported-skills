---
name: supervise
description: Run a Project's next ready-for-agent ticket through the full /implement in a Claude Code background session, and report done or blocked.
disable-model-invocation: true
---

Run one ticket in a Project, from the Hub, as the maintainer would by hand: read the next step, start `/implement #N` in a fresh session, watch it, and report. The worker is a Claude Code background session (`claude --bg`), whose first prompt enters through the human's door, so the ticket gets the full `/mattpocock-skills:implement`, its TDD and its own `/code-review` (ADR 0003). One ticket, then stop.

The Project folder, relative to this session's folder or absolute, is the first word here; `--model <id>` may follow: $ARGUMENTS

## Policy

The supervisor drives build-loop defaults and nothing else:

- **It may**: take the step `state.sh` names, launch `/implement #N` for a `ready-for-agent` ticket, watch the worker, and stop a worker that finished or failed a launch check.
- **It stops for anything that changes the spec**: any other step, a question the worker asks, a permission prompt, a ticket that needs a decision. It reports these and answers none of them. The human answers in the worker with `claude attach <id>`, or in the approval request the Claude app shows for the worker's permission prompt.
- **Shared actions are the human's.** This version holds no standing grants: a push, PR or issue close that `/implement` reaches is reported as blocked, and the supervisor performs none itself, apart from one comment on the ticket it ran, holding the run record (step 4). A PreToolUse hook (#66) refuses a worker's own attempt at one in the forms it recognizes, so the report still lists every shared action the worker took, in case a form got past it or an older worker predates the hook.
- **A worker stays in the Project folder for the whole run**: its commits would otherwise land on a branch nobody pushes. It is launched without the `EnterWorktree` tool, stopped at launch if the background service placed it elsewhere, and stopped the moment `watch.sh` sees it leave the folder anyway.

## 1. Step

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/step.sh" "<project folder>" </dev/null
```

It runs `resuming`'s `state.sh` in the folder and reads the `next:` line. `implement #N` means the step is `/implement` of a `ready-for-agent` ticket with nothing else in flight: go on. `stop: ...` means any other step, including work in flight in git: report the line and end here.

Then read the ticket's body and every comment (`gh issue view N --json title,body,comments`, run in the folder), and record where the branch starts, for the report:

```sh
git -C "<project folder>" rev-parse HEAD
```

## 2. Launch

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/launch.sh" --dir "<project folder>" --ticket N </dev/null
```

Add `--model <id>` when the user gave one; the default is `claude-sonnet-5`, and a model without auto mode (Haiku) is refused. It sets `CLAUDE_CONFIG_DIR` to this profile for the worker, launches in auto mode with `--disallowedTools EnterWorktree`, and reads the job's `state.json` to confirm the worker got this profile, the folder itself rather than a worktree, auto mode, and the deny. It prints the worker's short id. Exit 1: nothing launched, report the error. Exit 2: the worker failed a check and was stopped, report the error with the id.

## 3. Watch

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/watch.sh" --id ID --dir "<project folder>" </dev/null
```

Run it with the Bash tool's `run_in_background`, since a ticket outlasts a foreground call, and wait for its completion notice. It polls `claude agents --json --all` every 30 seconds while the worker is `working`, and returns at the first other state, with the worker's `cwd` on the next line and, for a blocked worker, a `needs` line naming what it waits for. A working worker whose `cwd` is no longer the Project folder returns at once as `moved`. `claude agents` can go on saying `working` for hours after the worker's turn ended, so `watch.sh` also reads the worker's transcript and returns `done` when it shows the turn ended with no background agents pending, adding the line `note claude agents still said working`. After 4 hours it exits 124 with the last state (`--timeout` changes this).

## 4. Report

One report, by the first line `watch.sh` printed. Whatever the outcome, it lists the shared actions the worker took, with `<cwd>` from `watch.sh` and `<start>` from step 1:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/actions.sh" --id ID --dir "<cwd>" --start <start> </dev/null
```

It prints one line for each PR or issue in the worker's job, each remote branch holding its commits, and each push, PR or issue command in its transcript or a subagent's, with whether it `succeeded`, was `refused`, `failed` or has `no result`. A command counts when the #66 hook would refuse it, when it runs a `gh pr` or `gh issue` subcommand that is not read-only, or when Claude Code recorded a push or PR on its result. It prints `none` only when it found nothing and read every source. Each action is marked `ungranted`, since this version holds no standing grants. Report every line as a shared action the maintainer did not approve, and report every `note` line as a source that was not read, never as no actions.

- **`done`**: the ticket and its commits, `git -C <cwd> log --oneline <start>..HEAD`, the shared actions, and whether the ticket is closed (`gh issue view N --json state`). `done` means only that the worker's turn ended: with no commits and the ticket open, read its last output with `claude logs ID`, since it may have ended on a question asked in plain text, and report that as blocked with `claude attach ID`. Otherwise stop the worker, which is still live: `claude stop ID`. When `cwd` is not the Project folder, say the commits sit in that checkout, on a branch nobody pushes.
- **`moved`**: stop the worker at once, `claude stop ID`. Report where it went (the `cwd` line), its commits there, `git -C <cwd> log --oneline <start>..HEAD` on `git -C <cwd> branch --show-current`, and that they sit on a branch nobody pushes. A worktree under `.claude/worktrees/` also leaves `.claude/` untracked in the Project folder, so `state.sh` reports work in flight until the maintainer removes the worktree; say so. Moving or salvaging the commits is the maintainer's.
- **`blocked permission prompt`**, **`blocked input needed`**: what it waits for (the `needs` line), the id, and the command to open it, in a fenced code block of its own:

  ```sh
  claude attach ID
  ```

  `input needed` is a question the worker asked, such as the SessionStart recommendation question. Leave the worker running.
- **`stopped`**: the id, and that `claude attach ID` reopens it, which starts it again.
- **`gone`**: the id; the session was removed and there is nothing to open.
- **`unknown ...`**, or exit 124: the state, the id, and `claude logs ID` for its last output. Exit 1: `claude agents` could not be read, so the worker's state is unknown; report that, never that it is gone.

Then record the run, whatever the outcome, with the same `<cwd>` and `<start>` and the ticket's number:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/record.sh" --id ID --dir "<cwd>" --start <start> --ticket N > "<scratchpad>/run-record.md" </dev/null
```

It prints the record as a Markdown list: the worker's model, launch and turn-end times, how long after the turn end this report came, API calls, tokens and cost by model, this session's own calls, tokens and cost since the launch, the peak zone reading and the call that first reached 100% of the zone, captures and clears, waits on a human and messages typed into the worker, the shared actions from `actions.sh`, and the outcome. A field whose source was not read says `unknown`, with a `note` line naming the source. The supervisor's own cost reads `unknown` while this session runs, because a running interactive session's transcript holds no cost row yet; its calls and tokens are still counted. Post it on the ticket, run in the Project folder, and include it in the report:

```sh
gh issue comment N --body-file "<scratchpad>/run-record.md"
```

`record.sh --session <session id>` in place of `--id` records a plain interactive session, such as a hand-run `/implement` of a ticket the same size, leaving out the job's fields: that is the baseline a supervised run is compared against.

Done when the report names the ticket, the outcome, the shared actions (or `none`), either its commits or the id with `claude attach`, and the run record's comment.
