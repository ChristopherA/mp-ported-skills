---
name: capturing
description: Capture a session at a phase boundary so nothing decided, learned or promised is lost across /clear or /compact. Use when a phase ends, before /clear or /compact, or when the user wants to wrap up, close, or end the session.
---

A **phase boundary** is where the user picks Continue, `/clear`, `/handoff`, a subagent or `/compact`. Every move but Continue turns this session, the **primary source**, into a lossy secondary one, and the work is only safe if what it produced already landed in its durable home. Capture is that check. The session is the input. Arguments, when any follow here, name the next phase: $ARGUMENTS

**This repo** is the working directory, and its tracker is the one its `docs/agents/issue-tracker.md` names. When that file is absent, this repo has no tracker: say so once and name `/setup-matt-pocock-skills` (you type it; user-invoked). Unfinished work with no ticket then has no home and stays unfiled. A ticket this session filed or touched in another repo belongs to that repo: moves 1 and 4 act on it there, per that repo's `docs/agents/issue-tracker.md`.

**User-invoked commands**: `/setup-matt-pocock-skills`, `/to-questionnaire`, `/handoff` and `/setup-mp-ported-skills`, wherever this skill names them, are left out of your skill list and are for the user to type. Tell the user to type the one you name, and give the full command on its own in a fenced code block, so it can be copied from a remote client.

## 1. Sweep

Walk the whole session for what was decided, learned or promised and is not yet durable. Route each item to its home now, as you find it:

- **Settled decision or term**: an ADR or `CONTEXT.md`, through `domain-modeling`.
- **Unfinished work**: a ticket, published to this repo's tracker per `docs/agents/issue-tracker.md`, or none when this repo has no tracker. This session originated it, so it lands ready: `ready-for-agent`, or `ready-for-human` when it needs human judgment or access. `needs-triage` is the on-ramp for work arriving from others.
- **A `ready-for-human` ticket this session worked on and left open**: label it `in-motion` and remove that label from every other open ticket, so `resuming` names it first and git's silence cannot hide it. Create the label per `docs/agents/issue-tracker.md` when the tracker lacks it. When the session finished or set aside the ticket that holds the label, remove it.
- **Open decision**: `clarifying`.
- **Something only another person knows**: name it and suggest the user run `/to-questionnaire` (you type it; user-invoked).
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
- **One first next step**, from this repo's tracker only: the `in-motion` ticket when one is labelled, or, when it has open sub-issues, its next child as `resuming` case 1 defines it; otherwise a ticket with the `ready-for-agent` role's label string from `docs/agents/triage-labels.md`, with every blocker closed and not labelled `parked`, lowest number first, and why that one. `resuming`'s cases 1 and 2 define this rule, so an edit to one is made to both. When this repo has no tracker, there is no next ticket; list tickets this session left open in other repos as work for a session started in that repo.
- **Safe to clear**, only when moves 1-5 actually happened. Otherwise say what is missing.

Then gather the **before-clear jobs**: small actions that finish this session's work, such as a push, closing a ticket, or a plugin update after a version bump. A push, a ticket close or a PR maps to one of the four shared actions `supervise`'s `grant.sh` knows (push, pr-create, pr-merge, issue-close); a plugin update maps to none of them.

Find out whether anyone can answer a question here, from the first job:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/before-clear.sh" --action <push|pr-create|pr-merge|issue-close|other> [--dir DIR] </dev/null
```

DIR defaults to the working directory. It prints `attended` when someone can: ask every job below as before, this session's own answer deciding all of them, and read no further job through the script. It prints `granted: <citation>` or `ungranted` when nobody can, such as a `/supervise` worker resumed with `/mp-ported-skills:capturing`, where the question would block at `input needed` the way resuming's SessionStart question once did (#69, #89): ask nothing. Call the script again for each remaining job, by the shared action it maps to (`other` for one that maps to none, a plugin update among them). Run every job that comes back `granted: <citation>`, with no confirmation, and report that line as what let it run unasked, the same as `/supervise`'s own report cites a grant (#88). List every job that comes back `ungranted` in the report with its command, and leave it undone. Exit 1 is a usage error or a `grant.sh` failure (its stderr starts `Error:`), never a silent ungranted: do not run the job, but do not block on it either -- list it in the report with its command and the error, the same as an `ungranted` job, since nothing here can act on the error and the capture still has to reach `done`.

**Attended.** Ask the before-clear jobs as one self-contained multi-select AskUserQuestion, each job an option whose description says what it does and whom it reaches. Run the ones ticked. More than four jobs take a second question. With no jobs, skip the question. With one job, the choice is yes or no, so ask it single-select: the job first, marked `(Recommended)`, and leaving it undone last. A multi-select makes the user tick, move to Submit and confirm, and a "don't" option among checkboxes contradicts the job beside it.

A plugin update runs through Bash, which works from any client, so it is one option with the full command in its description: `claude plugin marketplace update <marketplace> && claude plugin update <plugin>@<marketplace>`. On a permission denial, say so and stop. Do not offer it as a `!` command or copy it to the clipboard: `!` commands and `/plugin` run only in the local terminal, and a remote client cannot reach this machine's clipboard. After the update, tell the user to type `/reload-plugins` to load it in this session. A session the `claude remote-control` server started refuses `/reload-plugins`, so there tell the user that a new session loads it.

**Unattended.** A plugin update is always `ungranted`, since `supervision.md` has nothing for it to match: list its command in the report and leave it for the maintainer, the same as any other ungranted job.

End with this session's context reading, from:

```sh
"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts/status-line.sh" --context "$PWD" "${CLAUDE_SESSION_ID}" </dev/null
```

When it prints nothing, report no number; say once that `/setup-mp-ported-skills` turns one on (you type it; user-invoked). Then walk the five boundary questions in order (continue, `/clear`, `/handoff`, subagent, `/compact`) against the next phase, and recommend one. The reading decides question 1: continue only when the next phase needs this session as a primary source, or will finish inside the smart zone (100%). Between 100% and 200% (yellow), continue only for a phase short enough to finish before 200%, where the status line turns red. The choice is the user's.
