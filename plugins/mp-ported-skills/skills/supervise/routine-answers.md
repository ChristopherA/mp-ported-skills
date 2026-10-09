# Routine answers

Part of `/supervise`. `SKILL.md`, beside this file, sends a run here at the step that needs it. `${CLAUDE_SKILL_DIR}` in the commands below is the folder holding this file and `SKILL.md`: Claude Code fills it in only in `SKILL.md`, so write that folder out when you run them.

Some questions a worker asks are ones the policy already decides: confirming the ticket it was launched on ("Proceed with #N?"), and asking for a shared action a standing grant covers (#58), which `launch.sh` told it to take without asking. For a `blocked question` or `blocked input needed`, before anything in `SKILL.md`'s Report step, ask:

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/answer.sh" --id ID --dir "<project folder>" --ticket N --state "<watch.sh's first line>" > "<scratchpad>/answer.txt" </dev/null
```

It reads the question from the worker's transcript: a pending AskUserQuestion with one question, a last line `Waiting on: <command>`, or the last sentence of its last message when that ends on the only `?` in it. Only two kinds are routine. A confirmation of ticket N is the whole sentence, naming no other ticket. A shared action (push, PR create or merge, issue close, comment or create) is the question's opening verb, the only action it names, and one `grant.sh` finds granted on origin's default branch. A question that offers a choice (" or "), names another ticket, or is anything else goes to the maintainer, as does a permission prompt and an action no grant covers. A question the supervisor answered once and the worker asks again is not answered twice.

- **Exit 0**: it printed `question <q>`, `rule ticket` or `rule grant <citation>`, and `answer <prompt>`. Send the prompt as a follow-up (Follow-ups, in `SKILL.md`), watch again with `--after` and `--zone`, and go on by the new watch's first line:

  ```sh
  sh "${CLAUDE_SKILL_DIR}/scripts/resume.sh" --id ID --dir "<project folder>" --prompt "$(sed -n 's/^answer //p' "<scratchpad>/answer.txt")" </dev/null
  ```

  The prompt starts `[supervisor answer to "<q>"]`, which `record.sh` lists under `supervisor answers`, apart from human interventions. List each question answered and its answer in the report.
- **Exit 2**: `not routine: <why>`, after `question <q>` when one was read. Report the block by the items of `SKILL.md`'s Report step, as before, with `claude attach ID`, adding the `why` line.
- **Exit 1**: report the error, and the block as before.
