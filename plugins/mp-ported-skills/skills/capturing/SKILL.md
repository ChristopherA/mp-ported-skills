---
name: capturing
description: Capture a session at a phase boundary so nothing decided, learned or promised is lost across /clear or /compact. Use when a phase ends, before /clear or /compact, or when the user wants to wrap up, close, or end the session.
---

A **phase boundary** is where the user picks Continue, `/clear`, `/handoff`, a subagent or `/compact`. Every move but Continue turns this session, the **primary source**, into a lossy secondary one, and the work is only safe if what it produced already landed in its durable home. Capture is that check. The session is the input. Arguments, when any follow here, name the next phase: $ARGUMENTS

**This repo** is the working directory, and its tracker is the one its `docs/agents/issue-tracker.md` names. When that file is absent, this repo has no tracker: say so once and name `/setup-matt-pocock-skills` (you type it; user-invoked). Unfinished work with no ticket then has no home and stays unfiled. A ticket this session filed or touched in another repo belongs to that repo: moves 1 and 4 act on it there, per that repo's `docs/agents/issue-tracker.md`.

## 1. Sweep

Walk the whole session for what was decided, learned or promised and is not yet durable. Route each item to its home now, as you find it:

- **Settled decision or term**: an ADR or `CONTEXT.md`, through `domain-modeling`.
- **Unfinished work**: a ticket, published to this repo's tracker per `docs/agents/issue-tracker.md`, or none when this repo has no tracker. This session originated it, so it lands ready: `ready-for-agent`, or `ready-for-human` when it needs human judgment or access. `needs-triage` is the on-ramp for work arriving from others.
- **A `ready-for-human` ticket this session worked on and left open**: label it `in-motion` and remove that label from every other open ticket, so `resuming` names it first and git's silence cannot hide it. Create the label per `docs/agents/issue-tracker.md` when the tracker lacks it. When the session finished or set aside the ticket that holds the label, remove it.
- **Open decision**: `clarifying`.
- **Something only another person knows**: name it and suggest the user run `/to-questionnaire`.
- **Already durable** (a commit, a ticket, an ADR, a research file, a `prototype/` branch): point at it and move on.

Done when every item has a home or a named reason it has none. If nothing needs capturing, say so plainly.

## 2. Stale claims

For each thing the session changed, search the `CONTEXT.md`, ADRs, docs and open tickets of the repo whose files it changed for statements the change made wrong, and fix them. Include what this session wrote earlier: its author is the reader least likely to reopen it. Done when every change has been searched for once.

## 3. Synthesis

Ask a separate question from the sweep: would anything here change how a *different* piece of work is done? Detection done more carefully finds more instances, never a rule. If something would, write it as one rule, with `writing-for-agents`: in the repo's `CLAUDE.md` or `AGENTS.md`, or in a user-level rule when it reaches beyond this repo. A rule, never a memory: memory is keyed per directory and other repos never see it. If nothing would, say so.

## 4. Waiting on others

Record everything this session sent out (an issue, a PR, a message) on its related ticket: what, to whom, when. The tracker stays the one resume point.

## 5. Commit

Run `git status` and compare it with what this session changed. Show the user anything you don't recognise as this session's work; on their yes, commit it separately, first. Then commit this session's work scoped to its files, per the repo's commit conventions.

## 6. Report

- What was routed where, what stays open, and what has no home.
- **One first next step**, from this repo's tracker only: the `in-motion` ticket when one is labelled, or, when it has open sub-issues, its next child as `resuming` case 1 defines it; otherwise a ticket with the `ready-for-agent` role's label string from `docs/agents/triage-labels.md`, with every blocker closed, lowest number first, and why that one. `resuming`'s cases 1 and 2 define this rule, so an edit to one is made to both. When this repo has no tracker, there is no next ticket; list tickets this session left open in other repos as work for a session started in that repo.
- **Safe to clear**, only when moves 1-5 actually happened. Otherwise say what is missing.

End with this session's context reading, from:

```sh
"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts/status-line.sh" --context "$PWD" "${CLAUDE_SESSION_ID}" </dev/null
```

When it prints nothing, report no number; say once that `/setup-mp-ported-skills` turns one on (you type it; user-invoked). Then walk the five boundary questions in order (continue, `/clear`, `/handoff`, subagent, `/compact`) against the next phase, and recommend one. The reading decides question 1: continue only when the next phase needs this session as a primary source, or will finish inside the smart zone (100%). Between 100% and 200% (yellow), continue only for a phase short enough to finish before 200%, where the status line turns red. The choice is the user's.
