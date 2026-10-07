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
       pr-create      gh pr create
       pr-merge       gh pr merge
       issue-close    gh issue close
       issue-comment  a new comment: gh issue comment, or a gh api POST
                      to repos/<o>/<r>/issues/<n>/comments. Not editing
                      or deleting one (--edit-last, --delete-last, a
                      PATCH or DELETE), which no grant covers.
       issue-create   a new issue: gh issue create, or a gh api POST to
                      repos/<o>/<r>/issues.
     No grant covers any other gh api write or a GraphQL mutation,
     addComment and createIssue included.
     Example: `- push: release branches only` -->

- push: to main, after the worker's own tests and /code-review pass
- issue-comment: a capture's findings, on this repo's tickets
