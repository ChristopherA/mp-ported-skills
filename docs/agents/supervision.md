# Supervision

Grants recorded here, once committed on the default branch, let
/supervise perform the action for its worker without stopping for
approval. An absent file, or no matching line under "## Grants", means
every shared action still stops for approval -- an empty file grants nothing.

Grants are read only from the default branch as committed on its remote
(origin/<default>), never the working tree or an uncommitted branch: a
grant has to be pushed before it takes effect, so a worker cannot grant
itself one by editing this file.

## Grants

<!-- One grant per line, as `- <action>` or `- <action>: <note>`.
     <action> is one of:
       push           git push (also git subtree push, git send-pack)
                      in this repo
       distribution-push
                      the same, in the Distribution repo that
                      docs/agents/distribution-repo.md names
       checked-push   the supervisor's own push, after the worker's turn
                      ends, without asking: only when every push.sh
                      --check line is ok, the test suite's included, and
                      no README*, CHANGELOG*, docs/ or .md file changed
                      in either repo. Never a worker's own push. Do not
                      grant it with distribution-push, under which the
                      worker pushes the Distribution repo itself, with
                      none of these checks.
       pr-create      gh pr create
       pr-merge       gh pr merge
       issue-close    gh issue close. Held while the Distribution repo
                      holds commits its upstream lacks: /supervise
                      closes the ticket after that push lands.
       issue-comment  a new comment: gh issue comment, or a gh api POST
                      to repos/<o>/<r>/issues/<n>/comments. Not editing
                      or deleting one (--edit-last, --delete-last, a
                      PATCH or DELETE), which no grant covers.
       issue-create   a new issue: gh issue create, or a gh api POST to
                      repos/<o>/<r>/issues.
       sub-issue      linking an issue under a parent, a gh api POST to
                      repos/<o>/<r>/issues/<n>/sub_issues, or reordering
                      a parent's sub-issues, a gh api PATCH to
                      repos/<o>/<r>/issues/<n>/sub_issues/priority. Not
                      removing one, which no grant covers. The note says
                      which tickets, as
                      `- sub-issue: a capture's tickets, under the work's own parent; the worker's own ticket, to the end of its parent's order`
                      does; the hook checks only the action.
     No grant covers any other gh api write or a GraphQL mutation,
     addComment, createIssue and addSubIssue included.
     Example: `- push: release branches only`
     A push grant covers the commits a worker's capture makes after its
     reviewed work only when its note says so, as
     `- push: to main, after tests pass; its capture's commits included`
     does; without it, the capture waits for approval to push them. -->

- push: to main, after the worker's own tests and /code-review pass; its capture's commits included
- issue-comment: a capture's findings, on this repo's tickets
- issue-close: the worker's own ticket, after its work is pushed
- issue-create: a capture's findings, under the work's own parent, labelled needs-triage
- sub-issue: a capture's tickets, under the work's own parent; the worker's own ticket, to the end of its parent's order
