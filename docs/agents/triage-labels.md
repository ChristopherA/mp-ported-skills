# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles to the actual label strings used in this repo's issue tracker.

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `ready-for-human`    | Requires human implementation            |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding label string from this table.

Edit the right-hand column to match whatever vocabulary you actually use.

## Other labels

`setup-matt-pocock-skills` writes the table above but not this section, so keep this section when re-running that skill. It never uses the pipe character, because `resuming` reads label strings from any pipe-delimited line in this file.

- **`research`**: the issue evaluates an outside skill, repo or idea for adoption; it is not committed work. It sits alongside a triage label, so a research issue starts at `needs-triage` like any other. A research issue parked for later moves to `ready-for-human` with `parked`, which takes it out of the `/triage` queue and out of every `resuming` case. Distinct from `wayfinder:research`, which marks a research ticket on a wayfinder map.
- **`in-motion`**: the one `ready-for-human` ticket a session was working on and left open. `capturing` sets it and moves it; `resuming` reads it as work in flight, since that work often leaves git clean. It sits alongside `ready-for-human`.
- **`parked`**: the ticket is not actionable until something outside it happens, such as a trigger its body names. It sits alongside the state label, `ready-for-agent` or `ready-for-human`, and `resuming` never makes it a step. Remove it when the trigger arrives. Low priority is not parking: a Low ticket that can be done now stays unparked and ranks last.
- **Priority line**: this repo has no priority labels. Priority goes in the issue body as its first line: a bold rating of High, Medium or Low, then the reason, as in `**Priority: Medium.** No ported skill wraps one yet ...`. The reason stays next to the rating, so triage can revise both.
