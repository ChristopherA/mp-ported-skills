# mp-ported-skills

Skills ported from Matt Pocock's set and adapted to how this user runs Claude Code sessions: across terminal, web and app views, and against a context budget.

## Language

**Profile**:
One Claude Code config home (its settings, memory and installed plugins), named after its directory: `~/.claude` is the default profile, `~/.claude-<name>` is profile `<name>`.
_Avoid_: config, account

**Session title**:
The name a session shows in the terminal, claude.ai/code and the Claude app. The title hook sets it as `<project> · <profile> · <host>`, except in a session a shell wrapper already titled with `-n`, which keeps the wrapper's.
_Avoid_: session name, Remote Control name

**Smart zone**:
The span of context, about 150k tokens by default, within which a session is reported to work well, whatever the model's window size.
_Avoid_: usable context, context budget

**Zone reading**:
The tokens in a session's context expressed as a percentage of the smart zone.
_Avoid_: context percentage, usage

**Zone capture**:
A supervisor's capture of a worker whose zone reading passed its threshold mid-ticket, followed by a fresh worker that continues the same ticket.
_Avoid_: zone stop (the supervisor's own loop stop), compaction

**Glance**:
The zone reading, printed into the conversation on request, for a view that has no status line.
_Avoid_: status, zone check
