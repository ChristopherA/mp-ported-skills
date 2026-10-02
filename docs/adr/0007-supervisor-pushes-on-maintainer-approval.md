# The supervisor pushes an ungranted push on the maintainer's approval, through a checked script

A `/supervise` worker whose Project grants no push ends its turn on `Waiting on: git push ...` (#88), and the #66 hook and the ADR 0006 wrappers refuse its own push, including after the maintainer types "Push" into it: a message typed into a worker is not a grant. Until now the Report step sent the maintainer to take the push themselves, from a terminal on the Mac or with a `!` command. Neither works from a remote client, where the maintainer usually drives `/supervise` (#81), so every finished ticket stalled until they were back at the Mac (#96).

Now the supervisor makes that push itself, on the maintainer's go-ahead given in the supervisor's own attended session, after checking the work. A new script, `skills/supervise/scripts/push.sh`, is the one place this happens. Given the Project folder, the worker's id, the commit the worker started from and the maintainer's public-artifact sweep command (or `--no-sweep`), it fetches and checks:

- no worker marker left in the checkout, so the worker is stopped and released;
- a clean tree;
- a fast-forward of the folder's branch onto its upstream, with something to push;
- the worker's start already on the upstream, so no earlier unpushed commit goes out unseen;
- every `.claude-plugin/plugin.json` version change a patch bump at most;
- the sweep, run over `<upstream>..HEAD`, exits 0.

It prints each check as `ok` or `fail`, with the commits to go. `--check` stops there. Without it, a full pass pushes only the commit it checked to the branch's upstream (`git push <remote> <sha>:<upstream ref>`). It appends `<worker id> <upstream> <old> <new>` to the checkout's `git rev-parse --git-path mp-supervise-pushed`, so `actions.sh`, and `record.sh` through it, label that branch `pushed by the supervisor on the maintainer's approval` rather than the worker's `ungranted` push. The skill's new Push on approval section runs `--check`, asks the maintainer one question when everything passes, and on an explicit yes runs the push, which repeats every check. A failed check is reported by name and nothing is asked or pushed.

The worker's gate does not change. `push.sh` refuses to push when `CLAUDE_CODE_SESSION_ATTENDED=0`, the background session's marker, and in such a session the git wrapper on its PATH would refuse the push inside it anyway. The hook and the wrappers are untouched.

## What the classifier allowed

Claude Code's auto-mode classifier judges each supervisor push, and it is the one gate no file in this repo controls.

- In the #96 run the supervisor tried the push after the maintainer had only reported the worker's refusal. The classifier refused it as a bypass of the #66 hook.
- In the #97 run the supervisor stopped the worker, released its marker, checked the range by hand (fast-forward, clean tree, patch-only bump, sweep clean, tests passing) and asked one question. After the maintainer chose "Push" in the supervisor session, a plain `git push origin main` from the supervisor was allowed and landed.
- In the #100 run the supervisor ran `push.sh --check`, asked one question, and after the maintainer chose to push, `sh .../push.sh` without `--check` was allowed and landed `0363064..23cbf4e`. No settings rule was needed. The supervisor session was a terminal session.

One thing is still open: whether the script push is allowed when the go-ahead comes from a remote client. It needs a live supervised run driven from the Claude app or a phone; record the result on #100 and here. If the script is refused, the skill says to report the refusal and stop. The next thing to try is a narrow allow rule for the script in the profile's `settings.json` (the same open question as #80).

## Considered Options

- **The maintainer pushes from a terminal or with a `!` command** (the Report step until now). Rejected: neither works from a remote client.
- **The maintainer tells the worker to push.** Rejected: the hook refuses it, and should. A worker that pushes on a message typed into it has a gate that anyone who can reach its session can open.
- **A plain `git push` from the supervisor, with the checks left to the skill text.** This is what landed in #97. It was not chosen as the route because the checks would live only in prose that a model may skip, and a bare push reads to the classifier as a possible bypass. A named script repeats its checks before it pushes, pushes only the commit it checked, and leaves a record that `actions.sh` can read.
- **ADR 0005's rejected option, "the supervisor performs the granted action itself, after the fact".** ADR 0005 rejected the supervisor standing in for a *granted* push the hook could already let through. Its reason still holds for that case: the worker's own granted push goes ahead with nothing from the supervisor. This ADR covers the other case, an *ungranted* push that the hook refuses in the worker and the maintainer approves in person. That approval comes from a human in an attended session, so the supervisor carrying it out is not a substitute for a gate.

## Consequences

- `tests/supervise-push.test.sh` covers `push.sh` in a scratch Project with a bare remote and a stub sweep: a full `--check` pass, a push and its record, nothing left to push, and each failing check by name with nothing pushed (dirty tree, sweep hits with their output, a minor and a major bump, someone else's push upstream, an unpushed commit before the start, a marker still in place, a failed fetch, no upstream, a detached HEAD), and a plugin new or removed in the range, which passes as no bump. It also covers the usage errors, and a background session where `push.sh` refuses and the git wrapper still refuses a plain push. It runs the same way with `worker-bin` first on PATH and `CLAUDE_CODE_SESSION_ATTENDED=0`. The same file checks that `actions.sh` labels a branch `push.sh` pushed for this worker, and still reads `ungranted` for another worker's id.
- The record file holds only pushes `push.sh` made. A push the maintainer makes any other way still reads as the worker's `ungranted` branch line. That is #98's to fix.
- The sweep command is the maintainer's own tool, named in their instructions, not in this public plugin. `push.sh` takes it as an argument and requires either it or an explicit `--no-sweep`, so leaving the sweep out has to be a choice.
