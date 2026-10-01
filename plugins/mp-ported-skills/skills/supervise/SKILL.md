---
name: supervise
description: Run a Project's next ready-for-agent ticket through the full /implement in a Claude Code background session, and report done or blocked.
disable-model-invocation: true
---

Run one ticket in a Project, from the Hub or from inside the Project, as the maintainer would by hand: read the next step, start `/implement #N` in a fresh session, watch it, and report. The worker is a Claude Code background session (`claude --bg`), whose first prompt enters through the human's door, so the ticket gets the full `/mattpocock-skills:implement`, its TDD and its own `/code-review` (ADR 0003). One ticket, then stop.

The Project folder, relative to this session's folder or absolute, is the first word here (`.` when this session runs inside the Project); `--model <id>` may follow: $ARGUMENTS

## Policy

The supervisor drives build-loop defaults and nothing else:

- **It may**: take the step `state.sh` names, launch `/implement #N` for a `ready-for-agent` ticket, watch the worker, send it a build-loop follow-up (Follow-ups, below), and stop a worker that finished or failed a launch check.
- **It stops for anything that changes the spec**: any other step, a question the worker asks, a permission prompt, a ticket that needs a decision. It reports these and answers none of them. The human answers in the worker with `claude attach <id>`, or in the approval request the Claude app shows for the worker's permission prompt.
- **Shared actions are gated on standing grants, never on the worker's own say.** A push, PR or issue close that `/implement` reaches is refused by a PreToolUse hook (#66) unless a grant in the Project's `docs/agents/supervision.md` covers it, read only from the default branch as committed on origin -- never the worker's working tree or local commits, which a worker can reach without the maintainer seeing it, and never the worker's to add (#58, docs/adr/0005). With no such file, or no matching grant, the push stops for approval exactly as before; in a background session the `git` and `gh` wrappers below refuse it outright, in any permission mode. `launch.sh` tells the worker, in an `--append-system-prompt`, which shared actions its Project grants, from the same source through `grant.sh`, that a granted one goes ahead without asking, and that any other ends its turn on one line, `Waiting on: <action>`, without trying it (#88): without that, a worker asks before every push and the run stalls at `blocked` with a grant in place. With one, the worker's own attempt goes through, and `actions.sh`'s report (step 4) cites the grant on that line instead of marking it `ungranted`; the report still lists every shared action the worker took, granted or not, in case a form got past the hook or an older worker predates it. A second hook (`deny-worker-grant-edits.sh`) refuses a worker's own Edit, Write or NotebookEdit to that grant file, and to anything under this session's own profile directory, so a worker cannot grant itself one or change what gates it. A push from inside a script, which the hook cannot see, meets the same check in the `git` and `gh` wrappers a SessionStart hook puts first on a background session's PATH (docs/adr/0006).
- **The supervisor stays read-only in the Project while a worker runs**, whether it runs from a parent folder or inside the Project, where the two share one working tree. No file edits, and no git `commit`, `merge`, `rebase`, `checkout`, `switch`, `reset` or `stash` there; reads, `gh` and these scripts still run. `launch.sh` marks the checkout with the worker's id, a PreToolUse hook (#76) refuses those calls in any attended session while the mark is there, the maintainer's own included, and `release.sh` clears it in the Report step. A refusal names the worker and `claude attach <id>`.
- **A worker stays in the Project folder, on its branch, for the whole run**: its commits would otherwise land on a branch nobody pushes. It is launched without the `EnterWorktree` tool and with the background service's worktree guard off (`bgIsolation: none`), so its edits in the folder are not refused. It is stopped at launch if the background service placed it elsewhere, and the moment `watch.sh` sees it leave the folder, or sees a worktree or branch made in the Project's repo since the launch.
- **A worker that stops making progress is reported, not stopped.** `watch.sh --stall` (step 3) reports `hang` when the worker's transcript has not grown in that long, distinct from a permission prompt or a question: the worker is left running, since a long tool call can hold the transcript steady in its own right, so this is a "no progress for a while" signal, not proof of a real hang.

## 1. Step

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/step.sh" "<project folder>" </dev/null
```

It runs `resuming`'s `state.sh` in the folder and reads the `next:` line. `implement #N` means the step is `/implement` of a `ready-for-agent` ticket with nothing else in flight: go on. `stop: ...` means any other step, including work in flight in git: report the line and end here.

Then read the ticket's body and every comment (`gh issue view N --json title,body,comments`, run in the folder), and record where the branch starts, for the report, and the repo's worktrees and branches, for `watch.sh`:

```sh
git -C "<project folder>" rev-parse HEAD
sh "${CLAUDE_SKILL_DIR}/scripts/watch.sh" --dir "<project folder>" --snapshot > "<scratchpad>/snapshot.txt" </dev/null
```

## 2. Launch

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/launch.sh" --dir "<project folder>" --ticket N </dev/null
```

Add `--model <id>` when the user gave one; the default is `claude-sonnet-5`, and a model without auto mode (Haiku) is refused. It sets `CLAUDE_CONFIG_DIR` to this profile for the worker, launches in auto mode with `--disallowedTools EnterWorktree`, `--settings '{"worktree":{"bgIsolation":"none"}}'` and the grants text in `--append-system-prompt`, and reads the job's `state.json` to confirm the worker got this profile, the folder itself rather than a worktree, auto mode, the deny, the setting and the grants text. A grant committed but not on origin is left out, and `grant.sh` names it on stderr as `note: ... ignored`; report that line. Without the setting, Claude Code 2.1.286 refuses a background worker's edits in the folder until it isolates, and a worker denied `EnterWorktree` makes its own worktree with `git worktree add` (#83). First it checks the Project is on its default branch, with a clean tree and no other live background session in it, and refuses otherwise: report the error, since a dirty tree or a branch is the maintainer's to settle. Once the worker passes its checks it writes the worker's id to the checkout's marker (`git rev-parse --git-path mp-supervise-worker`), which holds this session read-only there. It prints the worker's short id. Exit 1: nothing launched, report the error. Exit 2: the worker failed a check and was stopped, report the error with the id.

## 3. Watch

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/watch.sh" --id ID --dir "<project folder>" --since "<scratchpad>/snapshot.txt" </dev/null
```

Run it with the Bash tool's `run_in_background`, since a ticket outlasts a foreground call, and wait for its completion notice. It polls `claude agents --json --all` every 30 seconds while the worker is `working`, and returns at the first other state, with the worker's `cwd` on the next line and, for a blocked worker, a `needs` line naming what it waits for. A working worker whose `cwd` is no longer the Project folder returns at once as `moved`. So does a working or done worker when the Project's repo has gained a worktree, or a branch other than the folder's has been made or moved, since the snapshot: a worker can make a worktree from Bash and keep its `cwd` in the folder. Each one is listed after the state as `worktree <path>`, `branch <name>`, and a `commit <sha> <subject>` line for each of the branch's commits, or a detached worktree's, that the folder's branch lacks. Any state can carry these lines, and a `note` line when the repo was not read. They count every worktree and branch made since the launch, the worker's or not. The one exception is a worktree the Claude app made and locked for its own bridge session in the same Project during the run (`.claude/worktrees/bridge-<session id>`, locked `claude agent bridge-<session id> (pid ...)`): `watch.sh` lists it as `other <path>` instead, leaves its branch out of the branch lines, and does not turn a working or done worker into moved for either. Report an `other` line as another session's worktree, not the worker's, and do not stop the worker for it. `claude agents` can go on saying `working` for hours after the worker's turn ended, so `watch.sh` also reads the worker's transcript and returns `done` when it shows the turn ended with no background agents pending, adding the line `note claude agents still said working`. A working worker whose transcript has not grown in 30 minutes (`--stall` changes this) returns as `hang`, with a `note` line naming how long, rather than waiting out the full timeout (#58): a long tool call can hold the transcript steady in its own right, so this is a signal to report, not proof the worker is stuck. After 4 hours it exits 124 with the last state (`--timeout` changes this).

## 4. Report

One report, by the first line `watch.sh` printed. Whatever the outcome, it lists the shared actions the worker took, with `<cwd>` from `watch.sh` and `<start>` from step 1:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/actions.sh" --id ID --dir "<cwd>" --start <start> </dev/null
```

It prints one line for each PR or issue in the worker's job, each remote branch holding its commits, and each push, PR or issue command in its transcript or a subagent's, with whether it `succeeded`, was `refused`, `failed` or has `no result`. A command counts when the #66 hook would refuse it, when it runs a `gh pr` or `gh issue` subcommand that is not read-only, or when Claude Code recorded a push or PR on its result. It prints `none` only when it found nothing and read every source. A branch or command line is marked `granted (<citation>)` when a standing grant in `docs/agents/supervision.md` covers it, read only from the default branch as committed on origin (#58); otherwise `ungranted`. Report a `granted` line too -- it is what the maintainer's standing grant already approved, not something to re-approve -- and report every `ungranted` line as a shared action the maintainer did not approve, and every `note` line as a source that was not read, never as no actions.

- **`done`**: the ticket and its commits, `git -C <cwd> log --oneline <start>..HEAD`, the shared actions, and whether the ticket is closed (`gh issue view N --json state`). `done` means only that the worker's turn ended: with no commits and the ticket open, read its last output with `claude logs ID`, since it may have ended on a question asked in plain text, and report that as blocked with `claude attach ID`. Otherwise stop the worker, which is still live: `claude stop ID`, then release its marker (below). When `cwd` is not the Project folder, say the commits sit in that checkout, on a branch nobody pushes.
- **`moved`**: stop the worker at once, `claude stop ID`, and release its marker (below). Report where it went: the `cwd` line, with its commits there, `git -C <cwd> log --oneline <start>..HEAD` on `git -C <cwd> branch --show-current`, when `cwd` is not the Project folder; and every `worktree`, `branch` and `commit` line. Say the commits sit on a branch nobody pushes. A worktree inside the Project folder, such as one under `.claude/worktrees/`, also leaves its folder untracked there, so `state.sh` reports work in flight until the maintainer removes the worktree; say so. Moving or salvaging the commits is the maintainer's. An `other` line alongside these is still another session's worktree, not the worker's; report it as such, not as part of why the worker moved.
- **`blocked permission prompt`**, **`blocked input needed`**: what it waits for (the `needs` line), the id, and the command to open it, in a fenced code block of its own:

  ```sh
  claude attach ID
  ```

  `input needed` is a question the worker asked and is waiting on an answer to. Leave the worker running, and its marker in place. Report any `worktree`, `branch` and `commit` lines as for `moved`.
- **`hang`**: the id, the `note` line naming how long its transcript has not grown, and `claude attach ID` to look. Leave the worker running, and its marker in place -- this is a "no progress for a while" signal, not confirmation the worker is actually stuck, since a long tool call can hold the transcript steady on its own. Report any `worktree`, `branch` and `commit` lines as for `moved`.
- **`stopped`**: the id, and that `claude attach ID` reopens it, which starts it again. Release its marker (below).
- **`gone`**: the id; the session was removed and there is nothing to open. Release its marker (below).
- **`unknown ...`**, or exit 124: the state, the id, and `claude logs ID` for its last output. Exit 1: `claude agents` could not be read, so the worker's state is unknown; report that, never that it is gone.

Release the marker whenever the worker was stopped or is gone, so the checkout is writable again and the next launch finds no stale mark (a stale one does not block `launch.sh`, but it keeps the hook refusing):

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/release.sh" --dir "<project folder>" --id ID </dev/null
```

It prints `released ID`, or `no marker in <folder>`. Exit 1: the marker names another worker, or the folder is not a checkout; report it and leave the marker.

Then record the run, whatever the outcome, with the same `<cwd>` and `<start>` and the ticket's number:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/record.sh" --id ID --dir "<cwd>" --start <start> --ticket N > "<scratchpad>/run-record.md" </dev/null
```

It prints the record as a Markdown list: the worker's model, launch and turn-end times, how long after the turn end this report came, API calls, tokens and cost by model, this session's own calls, tokens and cost since the launch, the peak zone reading and the call that first reached 100% of the zone, captures and clears, waits on a human and messages typed into the worker, the shared actions from `actions.sh`, and the outcome. A field whose source was not read says `unknown`, with a `note` line naming the source. The supervisor's own cost reads `unknown` while this session runs, because a running interactive session's transcript holds no cost row yet; its calls and tokens are still counted. Post it on the ticket, run in the Project folder, and include it in the report:

```sh
gh issue comment N --body-file "<scratchpad>/run-record.md"
```

`record.sh --session <session id>` in place of `--id` records a plain interactive session, such as a hand-run `/implement` of a ticket the same size, leaving out the job's fields: that is the baseline a supervised run is compared against.

## Follow-ups

No command sends input to a running background session, so a follow-up to a worker, such as `/mp-ported-skills:capturing` after `done`, goes by stop and resume:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/resume.sh" --id ID --dir "<project folder>" --prompt "<prompt>" </dev/null
```

It stops the worker, waits until `claude agents` shows it `stopped` or has shown no pid for 60 seconds (`--settle`), and resumes the job's original session id with the prompt and no flags. It refuses while another background session is live in the same checkout, naming each. A resume that starts a copy instead of waking the worker loses the launch's EnterWorktree deny, auto mode and model, so the copy is stopped and removed at once, the worker stopped again, and the resume retried, up to 3 times (`--tries`). It prints one line for each copy, then `resumed ID`; name every copy in the report. On a wake it writes the worker's marker again, since the worker is live again, and prints a `note` line first when it could not; report that line. Release the marker again once the follow-up's worker is stopped. The id stays the same, so watch it again with `watch.sh`. Exit 1: nothing resumed, report the error. Exit 2: every try started a copy; each was removed, the worker is left stopped, and the error names them all.

Done when the report names the ticket, the outcome, the shared actions (or `none`), either its commits or the id with `claude attach`, and the run record's comment.
