---
name: glance
description: Print this session's zone reading into the conversation, for a view with no status line.
disable-model-invocation: true
---

Print the **glance**: this session's **zone reading**, tokens in context as a percentage of the **smart zone**, into the conversation. claude.ai/code and the Claude app show no status line, so this is how a session driven from them sees the reading.

```sh
sh "${CLAUDE_SKILL_DIR}/scripts/glance.sh" "$PWD" "${CLAUDE_SESSION_ID}" </dev/null
```

Reply with the line it prints, exactly as printed, and nothing else: no branch, model, effort or advice. It prints either the reading (`41% of zone`) or one line saying why there is none.
