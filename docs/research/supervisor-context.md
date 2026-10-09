# A supervisor's context cost per ticket

What a `/supervise` session spends of its own context on each ticket it runs, by step, for #118. The measurements below are done; the options weighed against them and the estimate of tickets per session are left for the rest of #118 (see its latest comment).

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
