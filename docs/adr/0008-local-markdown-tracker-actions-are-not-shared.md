# On a Local Markdown tracker, the shared-action boundary is git push

ADR 0005 gates every tracker write as a shared action: on GitHub Issues a comment, a label, a close or a new issue is visible to others the moment it runs, so a worker takes one only under a standing grant. On a Local Markdown tracker (`docs/agents/issue-tracker.md` opening `# Issue tracker: Local Markdown`, #233) the same write is an edit to a ticket file under `.scratch/`, committed like any other change and seen by nobody until `git push`. A grant there would gate nothing, and an unattended capture would list every comment it writes as waiting on the maintainer (#232, #234).

So on that backend `issue-close`, `issue-comment`, `issue-create`, `label` and `sub-issue` are not shared actions, and `push` and `distribution-push` are the boundary. This narrows ADR 0005's scope: its grants still decide every action on a GitHub tracker, and the two pushes on any tracker.

`grant.sh` answers a tracker action on a `local` backend with exit 3 and the line `local: not a shared action on this tracker`, grant or no grant. Exit 0 stays a grant and exit 1 stays no grant or an error. It reads the backend with `tracker.sh` from `docs/agents/issue-tracker.md` on `origin/<default>`, the ref its grants come from. A worker could otherwise commit a Local Markdown title on a GitHub Project and make its ticket's close free in `close.sh`. With no `origin` remote at all, where there is nowhere to share to, it reads the working tree.

Each caller handles the new status apart from a grant:

- `before-clear.sh` prints the line, exit 0, attended or not, so `capturing` asks nothing about the job and treats it as neither granted nor refused.
- `launch.sh` leaves the action out of the worker's grant list and adds a line saying tracker writes on this backend are commits it makes without asking.
- `answer.sh` reports a worker waiting on such an action as not routine, naming it as not shared on this tracker.
- `close.sh` skips its grant check with a line saying why. It then refuses to run `gh` on a Local Markdown Project, since the close there is a file edit, which #235 builds.
- `actions.sh` keeps a `gh` tracker write `ungranted`, with a note: the command still wrote to GitHub, which is not this Project's tracker, and `finish.sh` raises the line to the maintainer.

None of them shows the line as a citation.

The `deny-shared-actions.sh` hook, the classifier and the worker `gh` wrapper are unchanged. They read any exit other than 0 as no grant. So on a Local Markdown Project a `gh issue` or `gh api` tracker write is refused under every grant, where before a grant let it through. A worker there has no tracker write to make through `gh`.

## Considered Options

- **Read the backend from the working tree, as `resuming`'s `state.sh` does.** Rejected for `grant.sh`. `state.sh` only recommends a step, while `close.sh` acts on `grant.sh`'s answer, and a worker's own commit reaches the working tree.
- **Report a `gh` tracker write on a Local Markdown Project as not shared in `actions.sh`.** Rejected. The command reached GitHub, and a label that calls it unshared would hide it from the maintainer at the run's end.
- **Keep the hook letting a granted `gh` tracker write through on a Local Markdown Project.** Rejected. That needs the hook or the classifier to ask `grant.sh` a different question. The brief keeps both unchanged, and no flow on that backend needs `gh` for a tracker write.

## Consequences

- `tests/grant.test.sh` covers each tracker action on a `local` fixture (exit 3 and the line), `push` still citing its grant, the other actions as on GitHub, a Local Markdown doc only in the working tree or an unpushed commit (ignored while `origin` exists), and a repo with no `origin`.
- `tests/before-clear.test.sh` covers the line attended and unattended, and `push` both granted and not.
- `tests/supervise.test.sh`, `tests/supervise-answer.test.sh` and `tests/supervise-close.test.sh` cover `launch.sh`'s grants text, `actions.sh`'s note, `answer.sh`'s not-routine reason and `close.sh`'s skip and refusal. `tests/deny-shared-actions.test.sh` pins the hook refusing granted `gh` tracker writes on a `local` fixture.
