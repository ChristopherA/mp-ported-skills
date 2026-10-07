---
name: capturing
description: Capture a session at a phase boundary so nothing decided, learned or promised is lost across /clear or /compact. Use when a phase ends, before /clear or /compact, or when the user wants to wrap up, close, or end the session.
---

A **phase boundary** is where the user picks Continue, `/clear`, `/handoff`, a subagent or `/compact`. Every move but Continue turns this session, the **primary source**, into a lossy secondary one, and the work is only safe if what it produced already landed in its durable home. Capture is that check. The session is the input. Arguments, when any follow here, name the next phase: $ARGUMENTS

**This repo** is the working directory, and its tracker is the one its `docs/agents/issue-tracker.md` names. When that file is absent, this repo has no tracker: say so once and name `/setup-matt-pocock-skills` (you type it; user-invoked). Unfinished work with no ticket then has no home and stays unfiled. A ticket this session filed or touched in another repo belongs to that repo: moves 1 and 4 act on it there, per that repo's `docs/agents/issue-tracker.md`.

**User-invoked commands**: `/setup-matt-pocock-skills`, `/to-questionnaire`, `/handoff` and `/setup-mp-ported-skills`, wherever this skill names them, are left out of your skill list and are for the user to type. Tell the user to type the one you name, and give the full command on its own in a fenced code block, so it can be copied from a remote client.

## 1. Sweep

Walk the whole session for what was decided, learned or promised and is not yet durable. Route each item to its home now, as you find it, except findings, below:

- **Settled decision or term**: an ADR or `CONTEXT.md`, through `domain-modeling`.
- **Unfinished work** of this session's own: a ticket, published to this repo's tracker per `docs/agents/issue-tracker.md`, or none when this repo has no tracker. This session originated it, so it lands ready: `ready-for-agent`, or `ready-for-human` when it needs human judgment or access. `needs-triage` is the on-ramp for work arriving from others. When this session's work sits under a parent, link it as a sub-issue of that parent, placed per **A new ticket under a parent** below.
- **A `ready-for-human` ticket this session worked on and left open**: first read its parent's labels, `gh api 'repos/{owner}/{repo}/issues/N/parent' --jq '[.labels[].name]'` (a 404, `No parent issue found`, means it has none). When the read fails any other way, change no label, and report the error with the label move left for the user. When the parent is labelled `in-motion`, change no label, and say why in the report: the parent stays the work in flight and `resuming` names its next child, while moving the label onto this child would hide the parent's other children. Otherwise label it `in-motion` and remove that label from every other open ticket, so `resuming` names it first and git's silence cannot hide it. Create the label per `docs/agents/issue-tracker.md` when the tracker lacks it. When the session finished or set aside the ticket that holds the label, remove it.
- **Open decision**: `clarifying`.
- **Something only another person knows**: name it and suggest the user run `/to-questionnaire` (you type it; user-invoked).
- **Already durable** (a commit, a ticket, an ADR, a research file, a `prototype/` branch): point at it and move on.
- **Finding for an open ticket**: something this session learned that bears on an open ticket other than its own work, such as evidence or a data point for it, or that ticket's scope, narrowed by this session's change. A comment on that ticket, not an edit to its body in move 2: the fact, its evidence (a run, a commit, a transcript line), and what it changes for that ticket.
- **Defect or idea noticed in passing**, outside this session's own work: a new ticket that lands ready, as unfinished work does, linked as a sub-issue of the parent this session's work sits under when there is one, placed per **A new ticket under a parent** below, with a `Blocked by:` line (`Blocked by: none` when nothing blocks it).

**A new ticket under a parent.** The session that files a ticket knows why it exists, what it must follow and what it should precede; a ticket linked with nothing more lands last in the parent's sub-issue order, which `/supervise` follows, with blockers `resuming`'s `state.sh` cannot see. So, for either new-ticket route, with attended and unattended as `before-clear.sh --action other` reads them below (run it first when unfinished work comes before any finding):

- **Blockers**: write its `Blocked by:` line from what this session knows, an ordering it reasoned out in prose included: "land #N first" becomes `Blocked by: #N`, never `Blocked by: none`. When the line names a ticket, add one sentence below it saying why.
- **Placement**: read the parent's open sub-issues in order (`gh api --paginate 'repos/{owner}/{repo}/issues/<parent>/sub_issues?per_page=100' --jq '.[] | select(.state=="open") | [.number, .title] | @tsv'`); the first page can hold only closed children, so page through all of them. Propose a place as "before #X", with a one-line reason drawn from the session: what the ticket risks, what it unblocks. Last in the order is a placement too, and needs its reason like any other.
- **Attended**: put the placement in the same AskUserQuestion that confirms the filing (for unfinished work, which is otherwise filed unasked, that question is asked just for this). Each new-ticket option carries its place, so the question stays within four options: `New ticket, before #X` and `New ticket, last`, then comment and skip for a finding, or only the two for unfinished work. After linking, apply the answer with the sub-issue priority API, with the `before_id` of the place the user chose, #X or one they named in free text; last needs no call, since linking puts the ticket there; both ids are database ids (`gh api repos/{owner}/{repo}/issues/<n> --jq .id`), not `#` numbers:

  ```sh
  gh api --method PATCH 'repos/{owner}/{repo}/issues/<parent>/sub_issues/priority' -F sub_issue_id=<new ticket id> -F before_id=<#X id>
  ```

- **Unattended**: file the ticket when the `issue-create` check below grants it, and leave the order alone: no grant covers a sub-issue reorder. List the proposed placement, its reason and the command above, ids filled in, in the report with the other unposted items.

The last two routes in the list above are **findings**. Gather them before writing any, over the whole session, including the results of any worker it supervised, by asking: what did this session learn that bears on an open ticket, or that no ticket holds yet? Unfinished work, a decision, a stale claim (move 2) and a rule (move 3) each have their own route; a finding is none of these, and is lost at `/clear` when nothing catches it. Then find out whether anyone can answer:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/before-clear.sh" --action other </dev/null
```

- `attended`: confirm each finding on its own, one AskUserQuestion per finding, with the fact and its intended target in the question and the options comment, new ticket and skip, the recommended route first and marked `(Recommended)`. Write each as it is confirmed, before asking the next.
- `ungranted` (nobody can answer, such as a `/supervise` worker resumed with `/mp-ported-skills:capturing`): ask nothing. Check each finding by the shared action that posts it, `issue-comment` for a comment on an open ticket and `issue-create` for a new ticket:

  ```sh
  sh "${CLAUDE_SKILL_DIR}/scripts/before-clear.sh" --action <issue-comment|issue-create> </dev/null
  ```

  Post each finding that comes back `granted: <citation>`, with no confirmation, and report that line as what let it post unasked. List each that comes back `ungranted` in the report with its intended target, its text and the command that would post it, and leave it unposted. Exit 1 is a usage error or a `grant.sh` failure: post nothing, and list the finding with its command and the error. The grant read is this repo's, so a finding for a ticket in another repo is listed, never posted.

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

- What was routed where, what stays open, and what has no home. Name each finding with the comment or ticket it became, and the `granted: <citation>` line when it posted unasked; or, when nobody could confirm it and no grant covered it, its intended target, text and command, left unposted; and each finding the user skipped. For each ticket filed under a parent, the place it took in the order, or, unattended, the proposed place, its reason and the reorder command left unrun.
- **One first next step**, from this repo's tracker only, read after move 5 from `resuming`'s script rather than worked out by hand:

  ```sh
  sh "${CLAUDE_SKILL_DIR}/../resuming/scripts/state.sh" </dev/null
  ```

  capturing's one first next step is the in-motion ticket `state.sh`'s `next:` line names, or that ticket's next child when the line names one; otherwise the ticket on its `2 /implement` line, in `next:` or `runner-up:`. When the line names every open child of that ticket blocked, the step is the blockers it names. The line's git items (uncommitted paths, unpushed commits, in this repo or `in distribution repo <path>`) are before-clear jobs, not the step. Give the reason the line gives. When the step's ticket is the last open blocker of a High ticket, `state.sh`'s `next unblocks:` or `runner-up unblocks:` line names it with `(High)`; say in the reason that the step unblocks it. `resuming`'s cases 1 and 2 define this rule, so an edit to one is made to both. When neither line names an `in-motion` ticket or a `2 /implement` one, there is no next ticket, and say so. When this repo has no tracker, or the script's `tracker:` line reads `UNREACHED`, there is no next ticket; list tickets this session left open in other repos as work for a session started in that repo.
- **Safe to clear**, only when moves 1-5 actually happened. Otherwise say what is missing.

Then gather the **before-clear jobs**: small actions that finish this session's work, such as a push, closing a ticket, or a plugin update after a version bump. A push, a ticket close or a PR maps to a shared action `supervise`'s `grant.sh` knows: push, pr-create, pr-merge or issue-close; a push in a Project's Distribution repo (`git -C <repo> push`) maps to distribution-push, never push. A plugin update maps to none.

Find out whether anyone can answer a question here, from the first job:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/before-clear.sh" --action <push|distribution-push|pr-create|pr-merge|issue-close|other> [--dir DIR] </dev/null
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
