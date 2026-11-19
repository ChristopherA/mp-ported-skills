# Which granted actions the auto-mode classifier lets a worker take

The deny-shared-actions hook lets a supervised worker take an action its Project's standing grants cover: a push, an issue comment, a close. The auto-mode classifier judges the same call on its own and can refuse it anyway. This check records how often it refused each granted action, and whether the command's form made a difference (#225).

## Method

The record comes from the transcripts of real background workers, not a probe. A probe would have to post a real comment or push to a real remote, and it would not run with a worker's launch prompt and grants text, so it would not show what a worker sees.

The transcripts are every session under the maintainer's profile whose transcript holds the grants text `launch.sh` appends ("You are a supervised worker"), from 2026-10-21 to 2026-11-19, in this repo and one other Project. For each Bash call whose command runs `gh issue comment`, `gh issue close` or `git push` (at the start of the command or after `;`, `&&` or `|`, leaving out calls that only search for, print or test that text, such as `rg`, `grep`, `printf` and `sh tests/...`), the call's result was read. A supervisor's own pushes go through `push.sh`, so they do not match; one attended session whose transcript quoted the grants text matched with one push, after its own prompts, and counts in no figure below. A count of every call that names these commands anywhere in a matching transcript, searches included, finds more refusals than these.

- refused: the result starts "Permission for this action was denied by the Claude Code auto mode classifier", and the reason it gives was kept;
- hook: the deny-shared-actions hook refused it;
- ran: neither.

The count of prompts the session had received before the call (the `/implement` prompt, a supervisor's answer, a capture) was kept beside it. Only commands, outcomes and the first words of prompts were read; no transcript text is copied here beyond the command forms.

## Results

### Issue comments

- 98 `gh issue comment` calls in 70 sessions: 91 ran, 5 were refused by the classifier ("[External System Writes]"), one chained with other commands was refused by the hook, and one failed on a missing body file.
- Nearly every call was made in a capture turn, with no supervisor answer before it, and used `gh issue comment N --body-file <file>`, sometimes with `</dev/null`, a `cd` before it or a sweep chained before it.
- The refused calls used the same form as the calls that ran. In three sessions, one comment ran and the next, a second later and in the same form, was refused: #212 ran and #118 was refused; #167 and #227 ran and #166 was refused; #206 ran and #248 was refused. Nothing in the refused bodies (findings of 600 to 3,600 characters, on the worker's own ticket or another) set them apart.
- No worker retried a refused comment, so whether a second try would pass is not recorded.

So `gh issue comment N --body-file <file>` passes most of the time, and no other form passes more often. A refusal is not predictable from the form, and the fallback is to list the comment for Post on approval.

### Pushes

- Before 2026-11-12 17:40 UTC, the first granted push in a worker's `/implement` turn ran in all 38 sessions that made one.
- From then to 2026-11-19, it was refused in all 21 sessions that made one, as "[Destructive or Unwanted Actions]", "[Unsanctioned Communication]" or with no reason given. The forms were `git push origin main`, with and without `2>&1 | tail -N`, `2>&1; echo rc=$?`, `-q`, a `cd` before it, or other git reads chained before it.
- Sending the same push again in the same turn was refused too, in every one of the 5 sessions that did; the refusal's note that it had judged the call without the repo's git status did not change the outcome.
- After the supervisor answered the `Waiting on: git push origin main` line, naming the grant, the push ran in all 17 sessions that waited that way, in the same form or another.
- A push in a later capture turn ran when the session already held such an answer, and was refused in 2 sessions that held none.

So a worker's first granted push is refused whatever its form, and goes through after the supervisor's answer. The form is not what decides it.

### Closes

- 44 granted `gh issue close` calls ran, most of them a worker's first close, in its own call, with no answer before it.
- 2 were refused, as "[External System Writes]", each a worker's first close right after its push (#182 on 2026-11-05, #104 on 2026-11-12). The #182 close went through, unchanged, after the supervisor's answer; the #104 one was then refused by the hook.
- One call that chained a close after a push in a `$( )` was refused before the close ran; the plain push and plain close, each in its own call, then ran.

So a close passes most of the time, and a refused one waits for the supervisor's answer like a push.

## What the grants text says

`launch.sh`'s grants text tells the worker:

- that the classifier can refuse a granted action and a change of form has not got one through (shown for pushes; a refused comment or close was never retried), so it takes each granted action once, in its own Bash call, and on a refusal ends its turn on `Waiting on: <the command>`, as for an action no grant covers;
- with a push grant, to expect that refusal for its first push, which has gone through after the supervisor's answer;
- with an issue-comment grant, to post as `gh issue comment N --body-file <file>`, the form nearly every recorded comment used, and to leave a refused comment's file in place for Post on approval.
