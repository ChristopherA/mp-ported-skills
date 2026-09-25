---
name: clarifying
description: Settle a mixed list of open items, or a single decision, one question at a time. Use when a grilling round, spec or triage hands back a list to work through, or the user wants to clarify a decision.
---

Settle what is in front of the user, one decision at a time, then stop. The input is `$ARGUMENTS` when given; otherwise the last message. Usually that is a list another skill handed back, mixing settled decisions, loose details and open questions. A single decision is a list of one.

## 1. Find prior art

Look for what already decides these items: an ADR, `CONTEXT.md`, an earlier summary, a document the user named. Start from it. Done when you have said what you checked and what it settles.

## 2. Sort

Map the items as a **design tree** and sort every item into exactly one bucket:

- **settled**: the list, the conversation or the prior art already answers it.
- **facts**: answerable by looking (code, config, docs, tools). Finding facts is your job: dispatch a sub-agent for each and keep going. A running lookup is an unsettled prerequisite, so only the items downstream of it wait.
- **frontier**: a decision for the user whose prerequisites are all settled.
- **blocked**: a decision waiting on another answer still open.
- **elsewhere**: only someone other than the user can answer it.

Show the sort as one block and ask the user to confirm the settled bucket once, as a whole. Done when every item sits in one bucket and the settled bucket is confirmed.

## 3. Work the frontier

Ask one frontier decision at a time:

1. In prose, set up the stakes, your recommendation and why, and its trade-offs against one or two alternatives.
2. Ask one AskUserQuestion: a single decision, recommended option first and marked `(Recommended)`. When the choice has no clean options, ask in prose instead.
3. Reflect the answer in your own words and name the assumption it rests on. A free-text answer that reframes the question outranks the options: restate your premises and re-ask from the user's frame.
4. Recompute the tree. Settled answers and returned facts move blocked items onto the frontier; decisions they expose join it.

After every third settled decision, ask the question the loop cannot ask itself: does the premise still hold, and should this exist at all? A run of consistent answers is coherence, not validation.

Done when the frontier is empty: every item is settled, blocked on something named, or elsewhere.

## 4. Route elsewhere

Name the elsewhere items and who holds each answer, and suggest the user run `/to-questionnaire` with them. It is user-invoked, so the handoff is theirs to make.

## 5. Summarize and stop

Write the summary:

- **Settled**: each decision in one line, with its reason.
- **Facts**: what the lookups found.
- **Open**: each blocked or elsewhere item, and what it waits on.

End with one completeness word: **full** (nothing open), **partial** (name what is missing), or **minimal** (stopped early).

The summary is the output. Hand it back and wait for the user to ask for action.
