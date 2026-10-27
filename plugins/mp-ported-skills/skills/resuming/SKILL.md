---
name: resuming
description: Recommend one next step, with its reason and a runner-up, from the tracker and git. Use at session start, after /clear or /compact, or when the user asks what's next.
---

The tracker and git hold where the work stands, so read them and **recommend**: one next step, its reason, and a runner-up. The user asked you precisely because they don't remember; the answer comes from the sources. This skill is read-only: it writes nothing until the user picks a step. Arguments, when any follow here, narrow the question: $ARGUMENTS

## 1. Read

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/state.sh" </dev/null
```

It reads git (no fetch), in a Distribution repo too when one is named, under `distribution repo` lines beside this repo's (one it cannot read, a missing folder, one that is not a git checkout or the Project's own repo, gets a `distribution repo: ... not read:` line instead, and is never taken as clean), and, when `docs/agents/issue-tracker.md` names GitHub, the tracker through `gh`, taking label strings from `docs/agents/triage-labels.md`. Its `next:` line is the first of these cases that applies, and its `runner-up:` line the second, or case 7's suggestions when no other applies. A ticket labelled `parked` is never a step in any case, nor is a `ready-for-agent` ticket whose newest comment opens with a supervised worker's `## Parked` heading, until a later comment answers it (listed on a `parked, awaiting reply:` line):

1. **Work in flight**: uncommitted changes, unpushed commits, a branch other than the default (in this repo, or in the **Distribution repo** the working tree's `docs/agents/distribution-repo.md` names, each item of which ends `in distribution repo <path>`), an open PR from this repo, or a ticket labelled `in-motion`, the `ready-for-human` ticket `capturing` marks as the one a session was working on, which git cannot see. Finish it. When that ticket has open sub-issues, its work is its **next child**: the first open one in the parent's order with every blocker closed, the blocker test of the frontier rule in `docs/agents/issue-tracker.md`, and not `parked`.
2. **A `ready-for-agent` ticket with every blocker closed**: `/implement #N`, lowest number first.
3. **Incoming work**: unlabelled issues, `needs-triage`, or `needs-info` with a reply since the last triage notes. `/triage`.
4. **Tracker and repo disagree**: an open ticket a commit on the default branch already closes, unless GitHub shows it reopened after that commit (reopened on purpose, such as to wait for a live check). Fix the tracker, since every later session starts from it.
5. **An open `wayfinder:map`**: continue `/wayfinder`.
6. **Hand work**: a `ready-for-human` ticket, not `in-motion`, with every blocker closed. Do it by hand. The highest priority line wins (High, Medium, none, Low), then the lowest number. When this case wins, the second such ticket, if any, is the runner-up.
7. **Nothing in motion**: say so plainly. Runner-ups: `/grill-with-docs` on a new idea, or `/improve-codebase-architecture`.

`capturing` runs this script for its report, so what capture leaves, resume finds: capturing's one first next step is the in-motion ticket `state.sh`'s `next:` line names, or that ticket's next child when the line names one; otherwise the ticket on its `2 /implement` line, in `next:` or `runner-up:`. When the line names every open child of that ticket blocked, the step is the blockers it names. An edit to cases 1 or 2 is made to that rule too.

When the next step is `/implement #N` (case 2, or an in-motion parent's next child), a `supervise:` line follows. It holds the `/mp-ported-skills:supervise . --loop` command that would hand the tickets to background workers in turn, when `/supervise` would take them: the main checkout rather than a linked git worktree, a clean tree, the default branch, no unpushed commits or open PR, no work in flight in a Distribution repo and none that could not be read, no other work in flight its `step.sh` would refuse, a queue of two or more tickets, and no other live background session in the folder or its Distribution repo. Otherwise it reads `not offered:` and the first of those that fails. Any other step prints no `supervise:` line.

Unpushed commits on the default branch are weighed last, against the step as it would be without them (#214). When the newest run record on that step's ticket, a `## Supervised run of #N` comment, names a start whose commits after it are exactly the unpushed ones, they are a supervised run that ended before its push: the loop is offered as if they were not there, and a `continue: #N from <sha>` line follows, which `/supervise`'s `step.sh` reads as the step. When no run accounts for them and they are the only check that fails, the line reads `not offered: N unpushed commits; push them first`, and a `push-first: git push origin <default>; then <loop command>` line follows. With any other failing check as well, the line is as above, with no `continue:` or `push-first:` line. When the ticket's comments cannot be read (#222), neither line follows, since a read that worked might have found a run to continue: with no other failing check the line reads `not offered: the run records on #N could not be read`, and otherwise it gives that check's reason.

When `step.sh` would take the step, a `queue:` line names the **queue**, the tickets the loop would run in turn, as `queue: #187 #92`. The loop runs no list: after each ticket it re-reads `next:`, so the queue replays that pick with each queued ticket counted closed. A ticket blocked only by queued ones joins where the loop would reach it. Under an in-motion parent, a `ready-for-human` or unlabelled child ends the queue, as `step.sh` stops on it. When a `ready-for-agent` child, not `parked` and unblocked once the queue is closed, sits behind that child, a `reorder:` line names it, the child it would go ahead of, each one's place among the open children, the `gh api --method PATCH ... sub_issues/priority` command that moves it, and the queue after the move; the `supervise:` line counts that longer queue.

An `unblocks:` line follows the ready list: for each ready ticket, the open tickets it is the last open blocker of (by GitHub link, a `Blocked by:` line or a `Blocked by` heading), each with its priority, as `#90 unblocks #91 (High)`. A ticket with another open blocker, whose links could not be read, or that is `parked`, `wontfix` or already closed by a commit, is left out. After `next:` and `runner-up:`, a `next unblocks:` and a `runner-up unblocks:` line name what that step's ticket unblocks (case 2's ticket, case 1's next child or in-motion ticket, case 6's hand ticket), when it unblocks anything. The lines are evidence, not a reordering: the cases still pick the step, and a parent's sub-issue order stays the maintainer's to set.

## 2. Check what the script cannot

- **Case 1**: name the work: `git status`, `git log --oneline <default>..HEAD`, the PR's title, or `gh issue view N` for an `in-motion` ticket. Finishing means commit, push or merge as the state shows, or picking the ticket up where its last comment left it. For a parent, `state.sh` names the next child, or every open child's blockers when none is free.
- **Case 4**: `gh issue view N` before recommending a close. The open list can lag a push that closed the ticket by a few seconds.
- **Case 6**: `gh issue view N --json body,comments` for the ticket. Pick it up where its last comment left it. When most of its work could be delegated and only a step needs a human, say so and suggest `/triage` to split it.
- **Cases 5 to 7**: search `CONTEXT.md` (or each `CONTEXT.md` that `CONTEXT-MAP.md` lists, with its context's `docs/adr/`), `docs/adr/`, the repo's `README.md` and the open tickets for one thing: ticket numbers closed on the tracker that they still describe as open. A hit is case 4. Read nothing else.
- **Tracker not GitHub**: read it per `docs/agents/issue-tracker.md` and weigh the cases by hand.

Done when the case stands confirmed or you have moved it.

## 3. Recommend

- **Next step**: one command or action, and why this case won. When the step's ticket is the last open blocker of a High ticket, `state.sh`'s `next unblocks:` or `runner-up unblocks:` line names it with `(High)`; say in the reason that the step unblocks it.
- **In-motion parent**: the parent is the work in flight and its next child is the step, with the child's command: `/implement #N` for `ready-for-agent`, done by hand for `ready-for-human`, with its title. When every open child is blocked, the step is the blockers `state.sh` names.
- **Queue**: when the next step is `/implement #N`, or unpushed commits ahead of it (a `continue:` or `push-first:` line, or run records that could not be read), the `queue:`, `reorder:`, `supervise:`, `continue:` and `push-first:` lines pick one of six forms:
  - **A queue of one** (`supervise: not offered: a queue of one`, no `reorder:` line): recommend `/implement #N`, with no `/supervise` form.
  - **A queue of two or more** (the `supervise:` line holds a command, no `reorder:` line): recommend the `--loop` command, without the `(you type it; user-invoked)` note, naming the queued tickets in order, as the way to build them in background workers while this session stays free. `/implement #N` is the alternative, for building only the first ticket in this session.
  - **A reorder** (a `reorder:` line, and the `supervise:` line holds a command): recommend the reorder, naming the ticket, the child it goes ahead of and the queue after, and then the `--loop` command over that queue. Give the PATCH command in a fenced code block; run it only when the user picks that option, and then give the loop command for them to type. `/implement #N` alone is the alternative.
  - **A run to continue** (a `continue: #N from <sha>` line): the unpushed commits are a supervised run of #N that ended before they were pushed. With a `supervise:` command, recommend the loop as above, saying it continues #N from those commits first; with a queue of one, `/implement #N`, which builds on them. Either way, say that a commit on top of them stops `/supervise` from continuing it.
  - **Push first** (a `push-first:` line): unpushed commits are the only thing between the step and the loop. Recommend pushing them, naming them (`git log --oneline origin/<default>..HEAD`) and giving the push in a fenced code block, then the loop command for the user to type. `/implement #N` is the runner-up. Run the push only when the user picks that option.
  - **A failed check** (any other `not offered:` reason): recommend `/implement #N` and give the reason in one line. A `reorder:` line beside it is not offered either: the reorder only serves the loop.

  Never start a worker yourself; only the user starts `/supervise`.
- **Runner-up**: the `runner-up:` line: the next case that applies, the second hand ticket when case 6 wins, or the case 7 suggestions.
- **User-invoked commands**: every command the cases name (`/implement`, `/triage`, `/wayfinder`, `/grill-with-docs`, `/improve-codebase-architecture`, and `/setup-matt-pocock-skills` when no tracker is configured) is user-invoked in `mattpocock-skills`, as is `/mp-ported-skills:supervise` in this plugin, and `state.sh` marks each one. A user-invoked skill is left out of your skill list, so its absence there does not mean it is missing. Tell the user to type it, and give the full command on its own in a fenced code block, so it can be copied from a remote client. Never call it missing, and never offer a model-invocable skill in its place.
- **Sources**: which were reached. State only what a source returned; when a source was not reached, name it instead of filling in its value (no "no open PRs" when `gh` failed). When that source is the tracker (`gh` missing, offline, unauthenticated), also frame the step as git's view only.

**Ask** the recommendation as one self-contained AskUserQuestion: the step and why it won in the question text, the step as the first option marked `(Recommended)`, the runner-up as the second, and in each option's description what picking it does. When the Queue forms recommend the loop or a reorder, that is the first option, `/implement #N` the second and the runner-up the third. Picking hand work, a tracker fix or work in flight starts it in this session. Picking a user-invoked command repeats it for the user to type, in a fenced code block.

On a no, the runner-up becomes the recommendation, in the same shape, with a new runner-up.
