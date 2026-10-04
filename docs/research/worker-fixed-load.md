# A supervised worker's fixed context load

What a `/supervise` worker holds in context at its first API call, by source, and what #130 cut.

## Method

Context size is a call's `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`, from the session's transcript, first distinct `requestId`.

- Worker aea3e16b (`/implement #90`, Opus 5.5 at medium, plugin 0.8.40): **65,310** at its first call, 105,848 about 90 seconds later after reading two tickets, `supervise`'s `SKILL.md`, ADRs, `watch.sh` and `tests/supervise.test.sh`.
- The worker that built #130 (Opus 5.5 at medium, plugin 0.8.41): **65,309**.

Each source was then measured by removing it. Every probe was a `claude --bg` session started the way `launch.sh` starts a worker (`--model claude-opus-5-5`, `--disallowedTools EnterWorktree`, the `bgIsolation: none` setting, `--permission-mode auto`, run in this checkout under this profile), with the prompt "Reply with the single word OK." in place of `/mattpocock-skills:implement #N`. Each probe was stopped and removed once its first call was recorded. Claude Code 2.1.289, 2026-10-04.

The probe with nothing removed read **64,829**, and again 64,831, so a reading is stable to a few tokens. A real worker's extra 481 is `/implement`'s skill text, the grants text and the ticket number. A `claude -p` session is not a stand-in: it read 45,369 with nothing removed, because print mode loads neither the Artifact tool nor Claude in Chrome.

## Breakdown at the first call

| Source | How it was removed | Tokens |
|---|---|---|
| Profile and Project instructions, all of them | `claudeMdExcludes` on every `CLAUDE.md` and rule | 26,804 |
| - the profile's shell-environment rule (18.5 KB) | `claudeMdExcludes` | 6,656 |
| - interactive-only text: the profile's `CLAUDE.md` and its rules on asking the user, Remote Control, editing profile settings and running `/supervise` (15.1 KB) | `claudeMdExcludes` | 5,048 |
| - the Hub's and the Project's `CLAUDE.md` (13.4 KB) | `claudeMdExcludes` | 4,663 |
| - the profile's other 13 rules (rest of the 26,804) | by difference | 10,437 |
| The `Artifact` tool | `--disallowedTools Artifact` | 11,414 |
| Claude in Chrome | `--no-chrome` | 2,528 |
| `Workflow` | `--disallowedTools` | 1,977 |
| `SendFeedback` | `--disallowedTools` | 2,031 |
| `ScheduleWakeup` | `--disallowedTools` | 1,768 |
| `ReadNotifications` and `ListAgents` | `--disallowedTools` | 1,143 |
| `ReportFindings` | `--disallowedTools` | 819 |
| The `cloudflare` plugin (skills and MCP server) | `enabledPlugins` off in `--settings` | 922 |
| System prompt, core tools (Bash, Read, Edit, Agent and the rest), skill and agent listings | the rest | 15,423 |

`--disallowedTools ArtifactComments ArtifactData` saved nothing beyond `Artifact`: both are deferred, so only their names load. `--disable-slash-commands` read 68,210, higher than the base, so the skill listing (14.5 KB of text) could not be measured by removal.

`claudeMdExcludes` given in a session's `--settings` adds to the profile's own list rather than replacing it: the probe that excluded the shell-environment rule loaded every other profile rule and none of the default profile's, which the profile's own list excludes.

## Options weighed

**Adopted: deny the tools a worker never uses, and turn off Claude in Chrome.** `launch.sh` now passes `--disallowedTools EnterWorktree,Artifact,Workflow,ScheduleWakeup,SendFeedback --no-chrome` and confirms both in the job's `respawnFlags`.

- `Artifact`: publishing a page is a shared action no grant covers, and its guidance tells a session to publish finished work, a report like this one included.
- `Workflow` runs only on the user's explicit opt-in, and a worker has no user to opt in.
- Only `/loop` uses `ScheduleWakeup`.
- `SendFeedback` queues a draft for the user to approve in the session that drafted it, and nobody reads a worker's session that way.
- Claude in Chrome drives the user's own browser, and a background worker has nobody to watch it or answer its site prompts.

A probe with all five removed read **45,328**, down 19,501 (30%) from 64,829. The job's `respawnFlags` held the comma-joined list as one value and `--no-chrome`. In a second probe with the same flags, `ToolSearch` for `select:EnterWorktree` returned "No matching deferred tools found", so the comma form still denies it.

**Kept: `ReadNotifications`, `ListAgents`, `ReportFindings` (1,962 together).** `ListAgents` names the subagents a worker continues with `SendMessage`. `ReportFindings` is how the built-in `code-review` reports, should a worker reach it. `ReadNotifications` is small. Each might be used, and the saving is small.

**Filed as its own ticket: a worker rule set.** The interactive-only text is 5,048 tokens, and `claudeMdExcludes` in the worker's `--settings` is shown above to drop it for the worker alone. The public plugin cannot name the profile's private rule files, so the list has to come from the profile (for example a file under `$CLAUDE_CONFIG_DIR` that `launch.sh` merges into its `--settings`), and which rules are interactive-only is the same call #118's lighter-supervisor option makes. The draft is below.

**Rejected: cut the environment rule.** At 6,656 tokens it is the largest single rule, but a worker runs shell commands all through a ticket, and the rule's traps (zsh word-splitting, BSD tools, pathless `rg` hangs, `-i` aliases) are written for exactly that. Shortening it is a change to the maintainer's shared rules, which this profile copies.

**Rejected: a shorter grants text.** The grants text, `/implement`'s skill and the prompt come to 481 tokens together.

**Rejected: large reads in subagents.** aea3e16b grew by 40,538 in its first 90 seconds of reading. Most of those reads are files the ticket changes, and Claude Code's `Edit` needs a `Read` of the file in the same session, so a subagent's summary cannot replace them. Only the read-only context (other tickets, ADRs) could move, and telling a worker how to explore changes how Matt's `/implement` runs, which #130 rules out. Ending a worker that is deep in its zone is #60's job.

**Not adopted in `launch.sh`: turn off a plugin a Project does not use.** The `cloudflare` plugin costs 922 tokens in this Project, and a Cloudflare Project's worker needs it. A Project can turn it off for every session in its own `.claude/settings.json`.

## Draft ticket: a worker rule set

> **/supervise: launch workers without the profile's interactive-only rules**
>
> Parent: #40. Related: #118 (the supervisor's profile text), #130 (`docs/research/worker-fixed-load.md`).
>
> A worker loads every profile rule, including those that only govern an interactive or supervising session. In this profile those are the profile's `CLAUDE.md` and its rules on asking the user, Remote Control, editing profile settings and running `/supervise`: 5,048 tokens at a worker's first call. `claudeMdExcludes` in a session's `--settings` adds to the profile's list (measured in #130), so `launch.sh` can drop them for workers alone.
>
> Build: `launch.sh` reads an optional list of paths or globs from the profile (one per line, relative to `$CLAUDE_CONFIG_DIR`), merges them as `claudeMdExcludes` into the worker's `--settings` with `bgIsolation`, and confirms them in `respawnFlags`. A missing file changes nothing. Settle with #118 which rules count as interactive-only, so the supervisor and worker lists agree.
>
> Acceptance: the list reaches the worker's settings and is confirmed at launch; a worker launched with this profile's list reads lower at its first call by about what #130 measured for that text; the profile's list is written by the maintainer, since it names private files.
>
> Blocked by: none
