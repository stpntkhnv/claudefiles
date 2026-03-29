# Azure DevOps MCP — Tool Reference

Use this skill whenever you need to interact with Azure DevOps via MCP tools. Follow the recipes exactly — parameter formats and call sequences are validated and tested.

---

## Critical parameter rules

These are the most common mistakes. Check every call against these rules.

### Branch ref format

MCP tools expect full ref paths, not bare branch names.

```
DO:    refs/heads/feature/1234-add-auth
DON'T: feature/1234-add-auth
```

Always prefix with `refs/heads/` for branches, `refs/tags/` for tags.

**Exception:** `wit_add_artifact_link` with `branchName` takes bare names (no prefix). The tool constructs the vstfs artifact URI internally. This is the only exception.

### Project and repository identifiers

- Most tools accept both name (string) and ID (GUID)
- Prefer name for readability: `project: "MyProject"`, `repositoryId: "my-repo"`
- If a tool fails with a name, retry with the GUID (get it from `core_list_projects` or `repo_list_repositories`)

### Work item IDs

- Always integers, never strings: `id: 1234` not `id: "1234"`

---

## Response filtering

MCP tool responses are bloated. After each call, extract only what you need and discard the rest. This keeps context clean and avoids hitting token limits.

### wit_get_work_item — extract only:
- `id` — work item number
- `fields["System.Title"]` — title (for PR titles and branch names)
- `fields["System.WorkItemType"]` — type (User Story, Bug, Task, etc.)
- `fields["System.State"]` — current state
- `fields["System.AssignedTo"].displayName` — assigned person
- `fields["System.Description"]` — description (only if needed for PR body)
- `fields["Microsoft.VSTS.Common.AcceptanceCriteria"]` — acceptance criteria (only if needed)

Ignore everything else: revision, url, _links, System.CreatedDate, System.ChangedDate, System.Watermark, System.AreaPath (unless explicitly needed), all System.Board* fields, all WEF_* fields.

### repo_create_pull_request — extract only:
- `pullRequestId` — the PR number
- `repository.webUrl` + `/pullrequest/` + `pullRequestId` — construct the PR URL
- `status` — should be "active"
- `createdBy.displayName` — confirm who created it

### repo_list_pull_requests_by_project — extract only:
- For each PR: `pullRequestId`, `title`, `status`, `sourceRefName`, `targetRefName`, `createdBy.displayName`

### repo_list_pull_request_threads — extract only:
- For each thread: `id`, `status`, `comments[0].content`, `threadContext.filePath` (if file-level), `properties` (check for policy evaluation threads — they have `CodeReviewRequiredReviewerExpressionEvaluations` or similar keys)

### pipelines_get_build_status — extract only:
- `status` — inProgress, completed, cancelling, etc.
- `result` — succeeded, failed, canceled, partiallySucceeded
- `buildNumber`
- `sourceBranch`
- `finishTime` (if completed)

---

## Recipes

### Detect project and repo from git remote

Run this at the start of any ADO session. Do not ask the user for project/repo names if you can extract them.

```
1. Run: git remote -v

2. Parse the remote URL:
   HTTPS: https://dev.azure.com/{org}/{project}/_git/{repo}
   SSH:   git@ssh.dev.azure.com:v3/{org}/{project}/{repo}
   Old:   https://{org}.visualstudio.com/{project}/_git/{repo}

3. Extract: org, project, repo

4. If parsing fails, fall back to:
   Call: core_list_projects
   → pick the right project

   Call: repo_list_repositories
   Params:
     - project: "<project-name>"
   → pick the right repo
```

### Get work item details (for branch naming or PR creation)

```
1. Call: wit_get_work_item
   Params:
     - id: <work-item-number>
     - project: "<project-name>"

2. Extract: id, System.Title, System.WorkItemType

3. Use for:
   - Branch name: sanitize title → feature/<id>-<sanitized-title>
   - PR title: [<id>] <System.Title> (exact, not paraphrased)
```

### Create a pull request

```
1. Determine source and target branches:
   - Source: current branch (git branch --show-current)
   - Target: usually "dev" (check conventions file)

2. Push branch if needed:
   - git push -u origin <branch-name>

3. Call: repo_create_pull_request
   Params (all required):
     - project: "<project-name>"
     - repositoryId: "<repo-name>"
     - sourceRefName: "refs/heads/<source-branch>"
     - targetRefName: "refs/heads/<target-branch>"
     - title: "[<ticket>] <work item title>"
     - description: ""

   Optional but recommended:
     - deleteSourceBranch: true
     - isDraft: false (unless user says "draft PR")

4. Extract: pullRequestId, construct PR URL

5. Link work item:
   Call: wit_link_work_item_to_pull_request
   Params:
     - id: <work-item-number>
     - project: "<project-name>"
     - pullRequestId: <pullRequestId from step 3>
     - repositoryId: "<repo-name>"

6. Add reviewers (if requested):
   First resolve identity:
   Call: core_get_identity
   Params:
     - searchFilter: "<reviewer-name-or-email>"

   Then add:
   Call: repo_manage_pull_request_reviewers
   Params:
     - repositoryId: "<repo-name>"
     - pullRequestId: <pullRequestId>
     - reviewerIds: [<identity-id>]
     - action: "add"

7. Report to user:
   - PR number and URL
   - Linked work item(s)
   - Reviewers added (if any)
```

### Update a pull request

```
Call: repo_update_pull_request
Params (required):
  - repositoryId: "<repo-name>"
  - pullRequestId: <number>

Params (include only what you're changing):
  - title: "new title"
  - description: "new description"
  - status: "active" | "abandoned" | "completed"
  - targetRefName: "refs/heads/<branch>"
  - isDraft: true | false
  - autoComplete: true | false
  - deleteSourceBranch: true | false
  - mergeStrategy: "noFastForward" | "squash" | "rebase" | "rebaseMerge"
  - transitionWorkItems: true

DO NOT pass params you're not changing — some tools treat explicit null/empty as "clear this field".
```

### Add a comment to a PR

```
Call: repo_create_pull_request_thread
Params:
  - repositoryId: "<repo-name>"
  - pullRequestId: <number>
  - content: "<comment text>"
  - status: "active"

For file-level comments (code review), add:
  - filePath: "/src/path/to/file.cs" (starts with /)
  - rightFileStartLine: <line-number>
  - rightFileStartOffset: 1
  - rightFileEndLine: <line-number>
  - rightFileEndOffset: 1
```

### Reply to a PR comment

```
Call: repo_reply_to_pull_request_thread
Params:
  - repositoryId: "<repo-name>"
  - pullRequestId: <number>
  - threadId: <thread-id> (get from repo_list_pull_request_threads)
  - content: "<reply text>"
```

### Check PR status and policy blockers

```
1. Call: repo_list_pull_request_threads
   Params:
     - repositoryId: "<repo-name>"
     - pullRequestId: <number>

2. Look for threads where properties contain policy evaluation keys
   (CodeReviewRequiredReviewerExpressionEvaluations, BuildStatusPolicy, etc.)

3. Check thread status:
   - "active" with policy properties = blocker
   - "fixed" = policy satisfied

4. For build policy failures, cross-reference with:
   Call: pipelines_get_build_status
   Params:
     - project: "<project-name>"
   Filter by sourceBranch matching your branch.
```

### List PRs for a project

```
Call: repo_list_pull_requests_by_project
Params:
  - project: "<project-name>"

Returns all active PRs. Filter client-side by repo, author, or status.
```

### Check pipeline status for a branch

```
Call: pipelines_get_build_status
Params:
  - project: "<project-name>"

Filter results by sourceBranch matching your branch (in refs/heads/ format).

Extract only: status, result, buildNumber, sourceBranch, finishTime.
```

### Link artifacts to work items

```
For linking a branch:
Call: wit_add_artifact_link
Params:
  - id: <work-item-number>
  - project: "<project-name>"
  - repositoryId: "<repo-name>"
  - branchName: "<branch-name>"    ← BARE name, no refs/heads/ prefix
  - linkType: "Branch"

For linking a commit:
  - commitId: "<full-sha>"
  - linkType: "Commit"

For linking a build:
  - buildId: <build-id>
  - linkType: "Build"
```

---

## Common pitfalls

### "Branch not found" on PR creation
You passed `feature/1234-fix` instead of `refs/heads/feature/1234-fix`. Always use full ref path for PR source/target.

### "Work item not found" on link
Work item ID must be an integer, not a string. Also verify the project name matches — work items are project-scoped.

### PR created but work item not linked
`repo_create_pull_request` does NOT auto-link work items. You must call `wit_link_work_item_to_pull_request` separately after creating the PR.

### Empty or wrong PR title
Don't compose the title from commit messages. Fetch the work item title and use it exactly: `[<id>] <System.Title>`.

### "TF401398: you cannot complete this pull request"
Usually means branch policies aren't satisfied (missing reviewers, failed build). Use the "Check PR status and policy blockers" recipe above to diagnose.

### Auto-complete not working
Set both `autoComplete: true` AND `mergeStrategy` in the same `repo_update_pull_request` call. If you set auto-complete without a merge strategy, it may be ignored.

### branchName format inconsistency
- `repo_create_pull_request`, `repo_update_pull_request`: need `refs/heads/` prefix
- `wit_add_artifact_link` with branchName: bare name, no prefix
- This is inconsistent by design in the API. Follow the recipe for each tool.

### MCP tool returns error — fallback
If an MCP tool returns an error, show the error to the user. Try `az repos` CLI as fallback only if it's installed (`which az`). Don't silently retry the same call.
