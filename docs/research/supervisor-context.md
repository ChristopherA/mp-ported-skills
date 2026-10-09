# A supervisor's context cost per ticket

What a `/supervise` session spends of its own context on each ticket it runs, by step, for #118; the options for spending less, weighed against those numbers; and how many tickets one supervisor session fits.

## Method

Context size is a call's `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`, from the supervisor session's transcript, one reading per distinct `requestId`. Each call's growth over the call before it is charged to what came in between: the earlier call's tool uses (named by the script a Bash call ran) and any prompt or background-task notification. The script that prints this table is at the end. A growth includes the assistant's own text and tool call as well as the tool's output.

`record.sh` reports two of these readings for every run from plugin 0.8.80: the supervisor's context at its last call before the launch and at its last call so far (`supervisor context`).

Sessions measured, all Opus 5.5 at medium, 150k zone:

| Session | Plugin | Tickets |
|---|---|---|
| d45b30de | 0.8.45 to 0.8.46 | #108, then #123 after `/reload-plugins` and a second `/supervise` |
| a90acc86 | 0.8.54 to 0.8.60 | `--loop`: #152, #147, #155, #144, #138 |
| 7b8a9a92 | 0.8.77 to 0.8.78 | `--loop`: #135 and #131, each zone-captured and continued |

## Fixed load

| Reading | Tokens |
|---|---|
| First call after `/clear` (system prompt, tools, profile rules, `CLAUDE.md` files) | 65,754 (0.8.45), 67,069 (0.8.54), 69,265 (0.8.77) |
| `resuming` before the run (`/next`: skill, `state.sh`, a ticket read, a question) | 6,000 to 7,000 |
| `supervise`'s `SKILL.md`, loaded by `/mp-ported-skills:supervise` | 14,284 for 37,680 bytes (0.8.46); 16,690 for 43,583 bytes (0.8.54); 23,939 for 64,231 bytes (0.8.77) |
| A second `/supervise` after `/reload-plugins` in the same session | 20,035 (0.8.46) |

`SKILL.md` costs about 2.6 to 2.7 bytes a token. At 0.8.79 it is 38,053 bytes (about 14k tokens) after #135's split, and a loop also reads `loop.md`, 8,639 bytes (about 3k), so a loop starts near 69k + 17k = 86k, 57% of zone, before its first step. `zone-capture.md`, `push-on-approval.md`, `post-on-approval.md` and the other split-out files add 1k to 2k each when reached.

## By step

Growth per step, from the three sessions:

| Step | Tokens |
|---|---|
| `step.sh` | 360 to 2,500 |
| `launch.sh` | about 300 |
| `view.sh` and `watch.sh` started | about 800 |
| Each worker turn end: the watch's task notification, reading its output, `last-message.sh` | 2,000 to 3,500 |
| `stop.sh` | 440 to 2,100 |
| `actions.sh` | 1,100 to 1,600 |
| Glance | 430 to 1,400 |
| Test suite | about 840 |
| A push or post on approval: the question, then `push.sh` or `post.sh` | 1,500 to 2,800 each |
| A routine answer (`answer.sh`) | about 600 to 1,200 |
| The supervisor's own capture: `capturing`'s `SKILL.md`, `before-clear.sh`, its questions | 8,000 to 15,000 |

A worker's run has two turn ends to watch, its work and its capture, so the watch cycle is the largest per-ticket cost of a clean run.

## By ticket

| Ticket | What it held | Tokens |
|---|---|---|
| #152 | clean, first of the loop | 9,400 |
| #147 | clean | 7,700 |
| #155 | push question and test suite | 9,600 |
| #144 | three post questions and two grant edits | 19,500 |
| #138 | close question, a resume that started a copy | 7,700 |
| #135 | zone capture: two workers | 16,900 |
| #131 | zone capture: two workers, an answer and a question | 22,600 |

A clean ticket costs 7.7k to 9.6k. A ticket that blocks once on a question costs 1k to 3k more; one with a zone capture and continuation costs about twice a clean one.

## Options weighed

From #118's list and its comments, each against the numbers above.

| Option | Verdict | Reason |
|---|---|---|
| Don't load `SKILL.md` again per ticket | Adopted, built by the loop (#59) | A second `/supervise` in one session cost 20k, more than two clean tickets. `--loop` loads it once. |
| A smaller loaded skill | Adopted, built | #135 split the rarer branches into files read when reached (64,231 to 38,053 bytes at 0.8.79, about 24k to 14k tokens). #118 then cut the Watch, Stopping and record-field paragraphs to what the supervisor acts on, pointing at `watch.sh`'s and `record.sh`'s headers for the rest (38,213 bytes at 0.8.80, which added the `supervisor context` field, to 34,140, about 1.5k tokens a load). The Report step's `actions.sh` paragraph stays: the supervisor applies every rule in it at each run. |
| A context reading per ticket in the run record | Adopted, built | `record.sh`'s `supervisor context` field, from 0.8.80. |
| Scripts that return one line | Adopted, as its own ticket under #40 (draft below) | The watch cycle is a clean run's largest per-ticket cost: two turn ends a worker, 2k to 3.5k each, for the task notification, reading the watch's output and `last-message.sh`. The end of a run then takes `stop.sh`, `actions.sh`, the glance and `record.sh` as four calls, the first three 2k to 5.1k together. Folding each group into one call whose output is a short verdict, with the detail in a file read only when the verdict is not clean, is a change to several scripts and to `SKILL.md`'s Report step, so it goes in a ticket of its own (draft below), measured against the By step table. |
| A subagent for the read-only parts | Rejected | The noisy parts it would take are already scripts with short output: the test suite is about 840 tokens, a ticket read and a worker's last message are each under the 2k to 3.5k turn-end cost, which the one-line scripts above cut further. A subagent's brief and report would cost the supervisor a call of their own. Not measured, since no step it could take is large enough to be worth it. |
| A lighter supervisor session | Not built: the maintainer's choice | The fixed load is 65.8k to 69.3k. The worker research (`docs/research/worker-fixed-load.md`) measured the Artifact tool's description at 11,414 tokens and Claude in Chrome's at about 2.5k: together about one and a half clean tickets. The supervisor needs neither, but it is a session the maintainer starts, so dropping them is a flag on that start (`--disallowedTools`), not something the skill can do. Of the profile's rules, the supervisor needs the ones on asking, Remote Control and supervise runs, which #133 counts as interactive-only for workers; little is left to cut there. |
| Hand a worker's findings off the supervisor | Adopted, built | The #113 and #130 runs spent most of their excess on tickets and comments the supervisor wrote from a worker's findings. A worker's capture now posts them itself under the `issue-create` and `issue-comment` grants. |

### Draft ticket: one-line watch and finish

Title: `/supervise: fold the watch cycle and the end of a run into one-line verdicts`

Priority: Medium. Parent: #40, which has room again since #165 (62 sub-issues). Blocked by: none.

Each worker turn end costs the supervisor 2k to 3.5k (the watch's task notification, reading its output, `last-message.sh`), twice a worker, and the end of a run takes `stop.sh`, `actions.sh`, the glance and `record.sh` as four calls, the first three costing 2k to 5.1k together (`docs/research/supervisor-context.md`, By step). Together that is most of a clean ticket's 7.7k to 9.6k.

Build:
- `watch.sh` writes its full result and the worker's last message to a file, and prints only the state line and, when the state is not `done` or `capture-due`, the lines the report needs, so a clean turn end is one short notification and no second read.
- One script for a settled run's end that stops the worker, reads its shared actions, takes the glance and writes the run record, and prints one line per result that needs the maintainer (an `ungranted` action, a `note`, a refused stop), or one `clean` line.

Acceptance: a clean ticket's cost to the supervisor, measured as in `docs/research/supervisor-context.md`, falls below the 7.7k to 9.6k it costs now; every case `SKILL.md`'s Report step reports today is still reported.

## Tickets per session

From the numbers above, at plugin 0.8.81:

- A loop starts at about 85k, 57% of zone: 69.3k fixed, about 12.9k for `SKILL.md` (34,140 bytes) and about 3.3k for `loop.md` (8,639 bytes).
- `next.sh` stops the loop at 90% of zone, 135k, checked between tickets, so a ticket started just under it runs on past it.
- At 7.7k to 9.6k a clean ticket, the reading after k tickets is 85k plus k times that. The loop starts its seventh clean ticket at 7.7k a ticket (131k after six) and stops after six at 9.6k (143k, 95%). So **6 to 7 clean tickets** in one session.
- A ticket that blocks once on a question costs 1k to 3k more, which takes a ticket off only at the high end (at 9.6k a ticket, 5 tickets and 3k reach 136k, past the stop). One with a zone capture costs about twice a clean one and takes one ticket off: **5 to 6**, or 6 to 7 for a single cheap block.
- The wrap-up after the zone stop, a loop summary and the supervisor's own capture (8k to 15k), starts at 90% to 96% of zone, so it ends past 100%. A zone stop that left room for the capture would start no ticket past about 135k less one ticket and the capture, near 75% of zone, and the loop would run one ticket fewer.

The zone stop (#78) reads this session's zone through the glance, from the status line's record of its context window, while `supervisor context` reads the transcript's per-call usage: the same size from two sources. The next loop's records and glance lines, side by side, show whether they agree.

The live loop at 0.8.54 to 0.8.60 ran five tickets from 44% to 93% of zone with the 43.6 KB `SKILL.md` loaded; the #135/#131 loop at 0.8.77 ran two zone-captured tickets from 69% to 94% with the 64 KB one. The next loop at 0.8.81 or later confirms the estimate, from each run record's `supervisor context` field.

## Script

```python
# Per-call context growth in a supervisor transcript.
# Usage: python3 -I steps.py <session id prefix>
import json, sys, re, os, glob
f = glob.glob(os.environ['CLAUDE_CONFIG_DIR'] + '/projects/*/' + sys.argv[1] + '*.jsonl')[0]
rows = [json.loads(l) for l in open(f) if l.strip()]
seen, events, pending = set(), [], []
def label(b):
    n, i = b.get('name'), b.get('input', {})
    if n == 'Bash':
        c = i.get('command', '')
        m = re.search(r'/(\w[\w-]*)\.sh', c)
        return m.group(1) + '.sh' if m else 'bash:' + (c.split() or [''])[0][:20]
    if n == 'Skill':
        return 'Skill ' + i.get('skill', '')
    return n
for r in rows:
    if r.get('type') == 'user' and not r.get('isMeta'):
        c = r.get('message', {}).get('content')
        if isinstance(c, str):
            m = re.search(r'<command-name>([^<]*)', c)
            pending.append('prompt ' + (m.group(1) if m else c[:40].replace('\n', ' ')))
    if r.get('type') == 'assistant' and r.get('message', {}).get('usage'):
        k = r.get('requestId') or r['message'].get('id')
        u = r['message']['usage']
        ctx = u.get('input_tokens', 0) + u.get('cache_read_input_tokens', 0) + u.get('cache_creation_input_tokens', 0)
        tools = [label(b) for b in r['message'].get('content') or [] if isinstance(b, dict) and b.get('type') == 'tool_use']
        if k in seen:
            events[-1]['tools'] += tools
            continue
        seen.add(k)
        events.append({'at': r['timestamp'], 'ctx': ctx, 'tools': tools, 'before': pending})
        pending = []
prev = None
for e in events:
    d = e['ctx'] - prev['ctx'] if prev else e['ctx']
    why = e['before'] + (prev['tools'] if prev else [])
    print(f"{e['at'][11:19]} {e['ctx']:>7} {d:>+7}  {'; '.join(why)[:110]}")
    prev = e
```
