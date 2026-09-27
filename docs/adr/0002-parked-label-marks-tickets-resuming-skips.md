# A `parked` label marks tickets that resuming skips

`resuming` recommends an unblocked `ready-for-human` ticket as hand work (case 6), ranked by the body's priority line. This repo also used `ready-for-human` to park work: research set aside for later, and tickets waiting on a trigger such as "when this repo starts using worktrees". To keep those out of the recommendation, a ticket that is not actionable until something outside it happens carries a `parked` label alongside its state label. `resuming` never makes a parked ticket a step, in case 2, case 6 or as an in-motion parent's next child, and `capturing`'s first next step skips it too.

## Considered Options

- **Treat Low priority as parked.** Rejected: Low means "matters less", parked means "cannot act yet". A Low fix that could be done today would vanish from every recommendation, and priority lines exist only on `ready-for-human` work in practice, so a parked `ready-for-agent` ticket would not be covered.
- **Wait for a state in mattpocock-skills.** Its triage docs list "deferred work gated on a future trigger" (mattpocock/skills#297) among the most-requested missing states, and none has shipped. Their documented workaround is a repo-local label alongside the state, which is what this repo already does with `research` and `in-motion`.

## Consequences

- Parking is one explicit edit, and so is unparking: remove the label when the trigger arrives. Nothing unparks a ticket automatically, so the trigger belongs in the ticket body.
- Matt's skills do not know the label. `/triage` and `/implement` will still treat a parked ticket by its state label alone.
- A repo that parks by `ready-for-human` alone, with no `parked` label, now sees those tickets recommended as hand work.
