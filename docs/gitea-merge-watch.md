# Gitea pull request watch and merge verification

Empirical record for the merge watch and the merge path on Gitea, alongside the existing GitHub, GitLab, and Gerrit ones.
Every live command below was run on 2026-11-08 and is read-only.
The merge request itself was not sent to a live server, and "What was not exercised live" says what stands in for it.

## Versions

```
$ tea --version
Version: 0.16.0	golang: 1.26.10	built with: nixpkgs	go-sdk: 1.2.0

$ jq --version
jq-1.8.2

$ bash --version | head -1
GNU bash, version 5.2.21(1)-release (x86_64-pc-linux-gnu)

$ tea api --login gitea /api/v1/version
{"version":"28.2.0"}
```

## The evidence instance

The live reads ran against a private, self-hosted Gitea 28.2.0 served over plain http on port 3000, the shape the Gitea path exists for.
Its host, owner, repository, and commit identifiers are private, so below they are replaced by `gitea.home.example`, `owner/app`, and `<head>`, and nothing else in any output is changed.
The pull request read is open, not a draft, on an unprotected `main`, with no commit status reported at its head.

## Why the host is the whole origin

A self-hosted Gitea is commonly reached over plain http on a non-default port, so `bin/fm-pr-lib.sh` accepts `http` and a port for the Gitea URL shape `<scheme>://<host>[:<port>]/<owner>/<repo>/pulls/<n>` only.
The GitHub, GitLab, and Gerrit patterns are unchanged and still require https with no port.
Because a scheme or port names a different server, the stored `host` field of a Gitea identity is the whole origin, so two servers that differ only by scheme or port never share an identity:

```
$ bash -c '. bin/fm-pr-lib.sh; fm_pr_url_parse "$0" && printf "%s|%s|%s|%s\n" "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"' http://gitea.home.example:3000/owner/app/pulls/1
gitea|http://gitea.home.example:3000|owner/app|1
```

`tests/fm-pr-check-security.test.sh` pins the accepted and refused URL matrix, including a spelled-out default port, userinfo, uppercase hosts, nested paths, and `.git` or `.wiki` repository names.

## How tea is invoked, and why

tea holds the Gitea token, so firstmate never reads or stores a credential.
Every read and the merge go through the one tea login whose configured URL is exactly the pull request's origin, resolved from `tea logins list --output json` on each call rather than recorded:

```
$ bash -c '. bin/fm-pr-lib.sh; fm_pr_gitea_login http://gitea.home.example:3000; fm_pr_gitea_login http://gitea.home.example:3001 || echo "no login (rc=$?)"'
gitea
no login (rc=1)
```

A URL naming any server with no such login, or with several, therefore reaches nothing, and arming or merging it is refused with the origin named.

`tea api` exits zero on an HTTP error status and prints the error body as if it were the answer:

```
$ tea api --login gitea --include /api/v1/repos/owner/app/pulls/99999; echo "exit=$?"
HTTP/1.1 404 Not Found
Content-Type: application/json;charset=utf-8

{"message":"not found","url":"http://gitea.home.example:3000/api/swagger"}
exit=0
```

So every call passes `--include` and accepts only a 2xx status read from the one HTTP status line it writes to stderr, and every read additionally checks that the body is the pull request with the requested number:

```
$ bash -c '. bin/fm-pr-lib.sh; fm_pr_gitea_read_record "$0" owner/app 1 && echo "$FM_PR_RECORD_STATE $FM_PR_RECORD_MERGED"; fm_pr_gitea_read_pull "$0" owner/app 99999 || echo "unreadable (status $FM_PR_GITEA_STATUS)"' http://gitea.home.example:3000
OPEN false
unreadable (status 404)
```

## End to end: polling a real pull request

The static poll reads Gitea's own `merged` boolean and stays silent for an open pull request:

```
$ bin/fm-pr-poll.sh --validated gitea http://gitea.home.example:3000/owner/app/pulls/1 http://gitea.home.example:3000 owner/app 1; echo "exit=$? output=[...]"
exit=0 output=[]
```

`tests/fm-pr-check-security.test.sh` `test_gitea_merge_watch` proves the merged line, silence on an HTTP error, another pull request's body, an absent or ambiguous login, and a doctored sidecar, and that arming refuses a draft, a missing login, and a missing tea.

## Merge-time reads

The merge path reads the base branch's protection summary and every commit status at the live head:

```
$ tea api --login gitea /api/v1/repos/owner/app/branches/main | jq -c "del(.commit)"
{"name":"main","protected":false,"required_approvals":0,"enable_status_check":false,"status_check_contexts":[],"user_can_push":true,"user_can_merge":true,"effective_branch_protection_name":""}

$ bash -c '. bin/fm-pr-lib.sh; fm_pr_gitea_read_statuses "$0" owner/app <head>; echo " rc=$?"' http://gitea.home.example:3000
[]
 rc=0
```

The combined status endpoint keeps only the latest status per context, but it is paginated and its body `total_count` counts only the current page, so pages are read until the `X-Total-Count` header's whole-list count is reached and a short read refuses.

## What the merge relies on from Gitea

These facts are read from the Gitea source at tag `v28.2.0` (commit `1dc1ecdddcdc60ab14ec14e30e7bb4d84242f21f`), the version the evidence instance reports.

- `services/forms/repo_form.go` `MergePullRequestForm`: the body fields are `do`, `head_commit_id`, `force_merge`, `merge_when_checks_succeed`, and `delete_branch_after_merge`, the last a pointer so an explicit `false` overrides the repository default.
- `services/pull/merge_prepare.go` `createTemporaryRepoForMerge`: a non-empty `head_commit_id` that differs from the pull request's current head returns `ErrSHADoesNotMatch` before any merge, which `routers/api/v1/repo/pull.go` `MergePullRequest` answers with 409 `head out of date`.
- `services/pull/check.go` `CheckPullMergeable`: a branch-protection failure, including required status checks and approvals, refuses the merge unless the request sets `force_merge` (and the doer may bypass) or `merge_when_checks_succeed`; firstmate always sends both false.
- `services/pull/commit_status.go` `EffectiveRequiredContexts`: under a protection rule the required set is the rule's own `status_check_contexts` when its status check is enabled, plus every required owner- or instance-level scoped workflow pattern, each a glob.

## Required checks and their limit

Firstmate verifies the required set the API exposes: under a protected base whose status check is enabled, every named context must have reported at the live head, and with none named at least one status must have reported, because Gitea treats an empty status list as pending.
An entry that Gitea would treat as a glob pattern is refused as one this path cannot evaluate exactly.
`services/convert/convert.go` `ToBranch` exposes only the rule's own contexts, and no API endpoint lists scoped required workflows, so a required check added at owner or instance level is not read by firstmate.
That check is enforced only by Gitea's own merge-time protection check, which firstmate never bypasses, and a merge refused that way surfaces as the forge's 405 with its message.
On the evidence instance the base branch is unprotected, so Gitea enforces no required check there and firstmate's reading of the required set is complete.

## What was not exercised live

No live merge request was sent: the only open pull request on the evidence instance is a real deliverable, and merging it from a verification run would have landed it outside its own delivery.
The request body, the 2xx gate, the forge-message relay on a refusal, the read-back of `merged`, and the away and captain-hold gates are pinned instead by the `test_gitea_*` cases in `tests/fm-pr-merge.test.sh`, against a tea fixture (`tests/lib.sh` `fm_fake_tea`) that reproduces the exit-zero-on-error contract shown above.
To refresh this record, rerun the commands above against a reachable instance, and run one attended `bin/fm-pr-merge.sh` on a disposable pull request to observe a 200 merge and a 409 `head out of date` for a stale head.
