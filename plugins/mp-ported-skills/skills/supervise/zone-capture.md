# Zone capture

Part of `/supervise`. `SKILL.md`, beside this file, sends a run here at the step that needs it. `${CLAUDE_SKILL_DIR}` in the commands below is the folder holding this file and `SKILL.md`: Claude Code fills it in only in `SKILL.md`, so write that folder out when you run them.

A worker whose zone reading passes the threshold while it is still building gets the maintainer's own treatment from the status line: capture, then go on in a fresh session (#60). Workers went on building, reviewing and committing past their zone without one: 129%, 174%, and 166% in the #141 run, which crossed 100% at call 34 of 109.

`zone.sh` reads the reading as the status line records it after a call, from the context of the worker's last call on its main chain, and calls it due at or past 80% of zone, and only at a safe point: every tool call has its result and every background command or agent the worker started has reported back, so the stop below cuts no command mid-run. From 88%, a background task still running no longer holds it, and the due line reads `due: background task <id> is cut`: review agents can run for minutes, the stop ends them, and the continuation runs them again; say so in the report. A running tool call holds it at any reading. Both points sit below the auto-compact point of a 200k window, about 106% of zone at the profile's `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` of 80, by more than one tool result can add between polls (`tests/supervise-zone.test.sh` fails otherwise). The worker runs on between the watch's return and `resume.sh`'s stop, so run step 2 at once.

1. Take a fresh snapshot, as Capture's step 1 in `SKILL.md` does, to `<scratchpad>/snapshot-zone.txt`.
2. Send the capture, naming the next phase, so the capture commits the work so far and records what is left on the ticket rather than in a new one:

   ```sh
   sh "${CLAUDE_SKILL_DIR}/scripts/resume.sh" --id ID --dir "<project folder>" --prompt "/mp-ported-skills:capturing next: a fresh worker continues #N from this session's commits; commit the work so far, and record what is left on #N, not in a new ticket" </dev/null
   ```

3. Watch it as Capture's step 3 in `SKILL.md` does, with `--since "<scratchpad>/snapshot-zone.txt"`, `--after` and no `--zone`, and go on by its first line:
   - **`done`**, or **`blocked input needed`** on a `git push`: go on to step 4. Push nothing: the ticket is not finished, and the continuation reaches its own push.
   - **`blocked input needed`** on a `gh issue comment` or `gh issue create` no grant covers: Post on approval: read `${CLAUDE_SKILL_DIR}/post-on-approval.md` and follow it, then step 4.
   - **Any other state**: `SKILL.md`'s Report step for that state, with no continuation.
4. Stop the worker and release its marker with `stop.sh` (Stopping, in `SKILL.md`). Take its shared actions with `actions.sh` and its run record with `record.sh` (Report, in `SKILL.md`), and post the record on the ticket, as for any worker. When `git -C "<project folder>" status --porcelain` prints anything, the capture left work uncommitted: report it and the worker's id, and launch nothing.
5. Continue the ticket in a fresh worker: `SKILL.md`'s step 1 snapshot command again, to `<scratchpad>/snapshot.txt`, then Launch with `--continue <start>`, the same `--model` and `--effort`:

   ```sh
   sh "${CLAUDE_SKILL_DIR}/scripts/launch.sh" --dir "<project folder>" --ticket N --continue <start> </dev/null
   ```

   Its prompt tells `/implement` that the commits since `<start>` and the capture's notes on the ticket are the work so far, and its name ends `#N (continued)`. Tell the maintainer the ticket continues, with the new id and the reading that set it off, then Watch and Report it as any worker, keeping the first worker's `<start>` for `actions.sh`, `push.sh` and `record.sh`, so its push and record cover both workers' commits.

A ticket continues once. A continuation that returns `capture-due` itself gets steps 1 to 4, and then the report, with both workers' ids and readings and no third worker; with `--loop`, the loop ends there.
