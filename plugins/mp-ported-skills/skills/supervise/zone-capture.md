# Zone capture

Part of `/supervise`. `SKILL.md`, beside this file, sends a run here at the step that needs it. `${CLAUDE_SKILL_DIR}` in the commands below is the folder holding this file and `SKILL.md`: Claude Code fills it in only in `SKILL.md`, so write that folder out when you run them.

A worker whose zone reading passes the threshold while it is still building gets the maintainer's own treatment from the status line: capture, then go on in a fresh session (#60). Workers went on building, reviewing and committing past their zone without one: 129%, 174%, and 166% in the #141 run, which crossed 100% at call 34 of 109.

`zone.sh` reads the reading as the status line records it after a call, from the context of the worker's last call on its main chain, and calls it due at or past 80% of zone, and only at a safe point: every tool call has its result and every background command or agent the worker started has reported back, so the stop below cuts no command mid-run. From 88%, a background task still running no longer holds it, and the due line reads `due: background task <id> is cut`: review agents can run for minutes, the stop ends them, and the continuation runs them again; say so in the report. A running tool call holds it at any reading. Both points sit below the auto-compact point of a 200k window, about 106% of zone at the profile's `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` of 80, by more than one tool result can add between polls (`tests/supervise-zone.test.sh` fails otherwise). The worker runs on between the watch's return and `resume.sh`'s stop, so run step 2 at once.

1. Take a fresh snapshot, as Capture's step 1 in `SKILL.md` does, to `<scratchpad>/snapshot-zone.txt`.
2. Send the capture, naming the next phase, so the capture commits the work so far and records what is left on the ticket rather than in a new one:

   ```sh
   sh "${CLAUDE_SKILL_DIR}/scripts/resume.sh" --id ID --dir "<project folder>" --prompt "/mp-ported-skills:capturing next: a fresh worker continues #N from this session's commits; commit the work so far, and record what is left on #N, not in a new ticket" </dev/null
   ```

3. Watch it as Capture's step 3 in `SKILL.md` does, with `--since "<scratchpad>/snapshot-zone.txt"`, `--after`, `--capture` and `--detail`, and no `--zone`, and go on by its first line. The ticket's work has **landed** when the worker pushed it before the reading fired, as a worker under a `push` grant does in its build turn: the capture ended on `live-check.sh`, the ticket is closed (`gh issue view N --json state`), or the capture's report says nothing is left for an agent. In the #133 run the reading fired at 84% after the worker's granted push, and the zone capture found nothing left to build (#197).
   - **`done`**: go on to step 4.
   - **`blocked input needed`** on a `git push`: when the capture's message names `live-check.sh --apply N` as well, the work has landed: take the `live-check.sh` bullet below, since the `needs` line holds only the last `Waiting on:` line. Otherwise, when the work has not landed, go on to step 4 and push nothing: the ticket is not finished, and the continuation reaches its own push. When it has landed, the push that waits is the capture's own commits, and no continuation will reach it: Push on approval, as Capture's step 3 does (read `${CLAUDE_SKILL_DIR}/push-on-approval.md` and follow it), whose last step runs `finish.sh` in place of step 4.
   - **`blocked input needed`** on `live-check.sh --apply N`: the work has landed, and the capture left #N open for a live check that no grant covers. Follow Capture's step 3 in `SKILL.md` for this block; when a `git push` also waits, its Push on approval comes first (read `${CLAUDE_SKILL_DIR}/push-on-approval.md` and follow it). Then step 4, unless Push on approval already ran `finish.sh`.
   - **`blocked input needed`** on a `gh issue comment` or `gh issue create` no grant covers: Post on approval: read `${CLAUDE_SKILL_DIR}/post-on-approval.md` and follow it, then step 4.
   - **Any other state**: `SKILL.md`'s Report step for that state, with no continuation.
4. End the first worker's run with `finish.sh` (Finishing, in `SKILL.md`), with the viewer flag when a viewer is open: it stops the worker, releases its marker, reads its shared actions, takes the glance, and writes and posts its run record, as for any worker. A `stop failed:` line goes to `stop-refused.md` as there, and launches nothing until the stop goes through. When `git -C "<project folder>" status --porcelain` prints anything, the capture left work uncommitted: report it and the worker's id, and launch nothing.
5. When the work has landed (step 3), launch no continuation. When `git -C "<project folder>" status -sb` shows the branch ahead of its upstream, the capture's commits went unpushed with no `Waiting on:` line naming them: report them and the worker's id, and with `--loop` the loop ends there. Otherwise the run is settled, as a `done` run is. Report it with the reading that set off the capture and the ticket's state, and with `--loop` go on to the next ticket (Loop, `loop.md`). Otherwise continue the ticket in a fresh worker: `SKILL.md`'s step 1 snapshot command again, to `<scratchpad>/snapshot.txt`, then Launch with `--continue <start>`, the same `--model` and `--effort`:

   ```sh
   sh "${CLAUDE_SKILL_DIR}/scripts/launch.sh" --dir "<project folder>" --ticket N --continue <start> </dev/null
   ```

   Its prompt tells `/implement` that the commits since `<start>` and the capture's notes on the ticket are the work so far, and its name ends `#N (continued)`. Tell the maintainer the ticket continues, with the new id and the reading that set it off, then Watch and Report it as any worker, keeping the first worker's `<start>` for `actions.sh`, `push.sh` and `record.sh`, so its push and record cover both workers' commits.

A ticket continues once. A continuation that returns `capture-due` itself gets steps 1 to 4, and then the report, with both workers' ids and readings and no third worker; with `--loop`, the loop ends there.
