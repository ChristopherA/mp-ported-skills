# Report: the other states

Part of `/supervise`. `SKILL.md`, beside this file, sends a run here at the step that needs it.

- **`moved`**: stop the worker at once, and release its marker, with `stop.sh` (Stopping, in `SKILL.md`). Report where it went: the `cwd` line, with its commits there, `git -C <cwd> log --oneline <start>..HEAD` on `git -C <cwd> branch --show-current`, when `cwd` is not the Project folder; and every `worktree`, `branch` and `commit` line. Say the commits sit on a branch nobody pushes. A worktree inside the Project folder, such as one under `.claude/worktrees/`, also leaves its folder untracked there, so `state.sh` reports work in flight until the maintainer removes the worktree; say so. Moving or salvaging the commits is the maintainer's. An `other` line alongside these is still another session's worktree, not the worker's; report it as such, not as part of why the worker moved.
- **`blocked permission prompt`**, **`blocked input needed`**, **`blocked question`**: what it waits for (the `needs` line), the id, and the command to open it, in a fenced code block of its own:

  ```sh
  claude attach ID
  ```

  `input needed` is a question the worker asked and is waiting on an answer to, or a shared action no grant covers other than a push or a capture's issue comment or new issue, which the `needs` line names: the maintainer takes it in their own session. `question` is a worker that ended its turn on a question asked in plain text, which `claude agents` shows as blocked with nothing named as waited for; the `needs` line holds the question when the job names one, and with none, report its last output (Stopping, in `SKILL.md`) instead (#85). Leave the worker running, and its marker in place. Report any `worktree`, `branch` and `commit` lines as for `moved`.
- **`hang`**: the id, the `note` line naming how long its transcript has not grown, and `claude attach ID` to look. Leave the worker running, and its marker in place -- this is a "no progress for a while" signal, not confirmation the worker is actually stuck, since a long tool call can hold the transcript steady on its own. Report any `worktree`, `branch` and `commit` lines as for `moved`.
- **`stopped`**: the id, and that `claude attach ID` reopens it, which starts it again. Release its marker (Stopping, in `SKILL.md`).
- **`gone`**: the id; the session was removed and there is nothing to open. Release its marker (Stopping, in `SKILL.md`).
- **`unknown ...`**, or exit 124: the state, the id, and its last output (Stopping, in `SKILL.md`). Exit 1: `claude agents` could not be read, so the worker's state is unknown; report that, never that it is gone.
