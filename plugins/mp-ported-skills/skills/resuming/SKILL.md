---
name: resuming
description: Recommend one next step, with its reason and a runner-up, from the tracker and git. Use at session start, after /clear or /compact, or when the user asks what's next.
---

The tracker and git hold where the work stands, so read them and **recommend**: one next step, its reason, and a runner-up. The user asked you precisely because they don't remember; the answer comes from the sources. This skill is read-only: it writes nothing until the user picks a step. Arguments, when any follow here, narrow the question: $ARGUMENTS

## 1. Read

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/state.sh" </dev/null
```

It reads git (no fetch) and, when `docs/agents/issue-tracker.md` names GitHub, the tracker through `gh`, taking label strings from `docs/agents/triage-labels.md`. Its `next:` line is the first of these cases that applies, and its `runner-up:` line the second, or case 7's suggestions when no other applies. A ticket labelled `parked` is never a step in any case:

1. **Work in flight**: uncommitted changes, unpushed commits, a branch other than the default, an open PR from this repo, or a ticket labelled `in-motion`, the `ready-for-human` ticket `capturing` marks as the one a session was working on, which git cannot see. Finish it. When that ticket has open sub-issues, its work is its **next child**: the first open one in the parent's order with every blocker closed, the blocker test of the frontier rule in `docs/agents/issue-tracker.md`, and not `parked`.
2. **A `ready-for-agent` ticket with every blocker closed**: `/implement #N`, lowest number first.
3. **Incoming work**: unlabelled issues, `needs-triage`, or `needs-info` with a reply since the last triage notes. `/triage`.
4. **Tracker and repo disagree**: an open ticket a commit on the default branch already closes. Fix the tracker, since every later session starts from it.
5. **An open `wayfinder:map`**: continue `/wayfinder`.
6. **Hand work**: a `ready-for-human` ticket, not `in-motion`, with every blocker closed. Do it by hand. The highest priority line wins (High, Medium, none, Low), then the lowest number. When this case wins, the second such ticket, if any, is the runner-up.
7. **Nothing in motion**: say so plainly. Runner-ups: `/grill-with-docs` on a new idea, or `/improve-codebase-architecture`.

`capturing` runs this script for its report, so what capture leaves, resume finds: capturing's one first next step is the in-motion ticket `state.sh`'s `next:` line names, or that ticket's next child when the line names one; otherwise the ticket on its `2 /implement` line, in `next:` or `runner-up:`. When the line names every open child of that ticket blocked, the step is the blockers it names. An edit to cases 1 or 2 is made to that rule too.

When the next step is `/implement #N` (case 2, or an in-motion parent's next child), a `supervise:` line follows. It holds the `/mp-ported-skills:supervise` command that would hand the ticket to a background worker instead, when `/supervise` would take it: a clean tree, the default branch, no unpushed commits or open PR, no other work in flight its `step.sh` would refuse, and no other live background session in the folder. Otherwise it reads `not offered:` and the first of those that fails. Any other step prints no `supervise:` line.

## 2. Check what the script cannot

- **Case 1**: name the work: `git status`, `git log --oneline <default>..HEAD`, the PR's title, or `gh issue view N` for an `in-motion` ticket. Finishing means commit, push or merge as the state shows, or picking the ticket up where its last comment left it. For a parent, `state.sh` names the next child, or every open child's blockers when none is free.
- **Case 4**: `gh issue view N` before recommending a close. The open list can lag a push that closed the ticket by a few seconds.
- **Case 6**: `gh issue view N --json body,comments` for the ticket. Pick it up where its last comment left it. When most of its work could be delegated and only a step needs a human, say so and suggest `/triage` to split it.
- **Cases 5 to 7**: search `CONTEXT.md` (or each `CONTEXT.md` that `CONTEXT-MAP.md` lists, with its context's `docs/adr/`), `docs/adr/`, the repo's `README.md` and the open tickets for one thing: ticket numbers closed on the tracker that they still describe as open. A hit is case 4. Read nothing else.
- **Tracker not GitHub**: read it per `docs/agents/issue-tracker.md` and weigh the cases by hand.

Done when the case stands confirmed or you have moved it.

## 3. Recommend

- **Next step**: one command or action, and why this case won.
- **In-motion parent**: the parent is the work in flight and its next child is the step, with the child's command: `/implement #N` for `ready-for-agent`, done by hand for `ready-for-human`, with its title. When every open child is blocked, the step is the blockers `state.sh` names.
- **Supervised form**: when the `supervise:` line holds a command, offer it, without the `(you type it; user-invoked)` note, beside `/implement #N`, as the way to run the same ticket in a background worker while this session stays free. When it reads `not offered:`, offer only `/implement #N` and give that reason in one line. Never start the worker yourself; only the user starts `/supervise`.
- **Runner-up**: the `runner-up:` line: the next case that applies, the second hand ticket when case 6 wins, or the case 7 suggestions.
- **User-invoked commands**: every command the cases name (`/implement`, `/triage`, `/wayfinder`, `/grill-with-docs`, `/improve-codebase-architecture`, and `/setup-matt-pocock-skills` when no tracker is configured) is user-invoked in `mattpocock-skills`, as is `/mp-ported-skills:supervise` in this plugin, and `state.sh` marks each one. A user-invoked skill is left out of your skill list, so its absence there does not mean it is missing. Tell the user to type it, and give the full command on its own in a fenced code block, so it can be copied from a remote client. Never call it missing, and never offer a model-invocable skill in its place.
- **Sources**: which were reached. State only what a source returned; when a source was not reached, name it instead of filling in its value (no "no open PRs" when `gh` failed). When that source is the tracker (`gh` missing, offline, unauthenticated), also frame the step as git's view only.

**Ask** the recommendation as one self-contained AskUserQuestion: the step and why it won in the question text, the step as the first option marked `(Recommended)`, the runner-up as the second, the supervised form, when offered, as the third, and in each option's description what picking it does. Picking hand work, a tracker fix or work in flight starts it in this session. Picking a user-invoked command repeats it for the user to type, in a fenced code block.

On a no, the runner-up becomes the recommendation, in the same shape, with a new runner-up.
