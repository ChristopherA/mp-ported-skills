---
name: resuming
description: Recommend one next step, with its reason and a runner-up, from the tracker and git. Use at session start, after /clear or /compact, or when the user asks what's next.
---

The tracker and git hold where the work stands, so read them and **recommend**: one next step, its reason, and a runner-up. The user asked you precisely because they don't remember; the answer comes from the sources. This skill is read-only: it writes nothing. Arguments, when any follow here, narrow the question: $ARGUMENTS

## 1. Read

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/state.sh" </dev/null
```

It reads git (no fetch) and, when `docs/agents/issue-tracker.md` names GitHub, the tracker through `gh`, taking label strings from `docs/agents/triage-labels.md`. Its `next:` line is the first of these cases that applies, and its `runner-up:` line the second, or case 6's suggestions when no other applies:

1. **Work in flight**: uncommitted changes, unpushed commits, a branch other than the default, or an open PR from this repo. Finish it.
2. **A ready ticket with every blocker closed**: `/implement #N`, lowest number first. This is `capturing`'s one first next step, so what capture leaves, resume finds.
3. **Incoming work**: unlabelled issues, `needs-triage`, or `needs-info` with a reply since the last triage notes. `/triage`.
4. **Tracker and repo disagree**: an open ticket a commit on the default branch already closes. Fix the tracker, since every later session starts from it.
5. **An open `wayfinder:map`**: continue `/wayfinder`.
6. **Nothing in motion**: say so plainly. Runner-ups: `/grill-with-docs` on a new idea, or `/improve-codebase-architecture`.

When the SessionStart hook already put this state in context, use it; run the script only when it is absent or the user asks again later.

## 2. Check what the script cannot

- **Case 1**: name the work: `git status`, `git log --oneline <default>..HEAD`, the PR's title. Finishing means commit, push or merge as the state shows.
- **Case 4**: `gh issue view N` before recommending a close. The open list can lag a push that closed the ticket by a few seconds.
- **Cases 5 and 6**: search `CONTEXT.md`, ADRs and docs for recently closed ticket numbers still described as open; a hit is case 4.
- **Tracker not GitHub**: read it per `docs/agents/issue-tracker.md` and weigh the cases by hand.

Done when the case stands confirmed or you have moved it.

## 3. Recommend

- **Next step**: one command or action, and why this case won.
- **Runner-up**: the `runner-up:` line: the next case that applies, or the case 6 suggestions.
- **User-invoked commands**: every command the cases name (`/implement`, `/triage`, `/wayfinder`, `/grill-with-docs`, `/improve-codebase-architecture`, and `/setup-matt-pocock-skills` when no tracker is configured) is user-invoked in `mattpocock-skills`, and `state.sh` marks each one. A user-invoked skill is left out of your skill list, so its absence there does not mean it is missing. Tell the user to type it. Never call it missing, and never offer a model-invocable skill in its place.
- **Sources**: which were reached. When the tracker was unreached (`gh` missing, offline, unauthenticated), say so, and frame the step as git's view only.

On a no, the runner-up becomes the recommendation, in the same shape, with a new runner-up.
