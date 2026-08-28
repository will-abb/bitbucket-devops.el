# bitbucket-devops.el Specification

## 1. Purpose

`bitbucket-devops.el` is one Emacs package for Bitbucket Cloud Pipelines and
pull requests. It provides repository-aware pipeline history, details, logs,
status watching, notifications, triggers, reruns, cancellation, and complete
pull request review workflows.

The package targets Bitbucket Cloud at `bitbucket.org`. It does not target
Bitbucket Data Center.

## 2. Scope

### Included

- Resolve the current Bitbucket Cloud repository from an SSH Git remote.
- Show pipeline history for the current repository.
- Filter loaded history by branch, broad status category, commit author,
  displayed pipeline type, and deployment environment.
- Show pipeline details and steps.
- Fetch logs for a completed pipeline step into an Emacs buffer.
- Download all available completed step logs for a pipeline into a configurable
  local directory.
- Watch one or more active pipelines until each reaches a terminal state.
- Show watcher state in the mode line and notify when status changes.
- Trigger a pipeline for the current branch.
- Parse trigger metadata from `bitbucket-pipelines.yml` and choose a configured
  pipeline for the current branch.
- Trigger a custom pipeline selector with optional runtime variables.
- Require explicit confirmation before production-sensitive triggers.
- Continue a pending manual step in a paused or halted pipeline.
- Rerun a pipeline by creating a new run with the same target and optional
  custom selector.
- Stop an active pipeline.
- Refresh status manually.
- Optionally start commit-based watching after a successful Magit branch push.
- Remember non-sensitive trigger defaults between Emacs sessions.
- Show pull requests for the current repository, newest updated first.
- Filter loaded pull requests by state, source or destination branch, and
  author.
- Show pull request details, comments, activity, commits, build statuses,
  tasks, reviewers, changed-file summaries, and raw diffs.
- Open pull request diffs through Bitbucket's patch text, Magit range diffs, or
  per-file Ediff.
- Open or copy Bitbucket browser links exposed by pull requests and build
  statuses.
- Create pull requests with no reviewers, effective default reviewers, or
  explicitly selected reviewers.
- Edit pull request title, description, draft state, reviewers, comments, and
  tasks.
- Approve, remove approval, request changes, remove change requests, merge, and
  decline pull requests.
- Add top-level comments, replies, and inline comments from a diff position or
  an explicit file/side/line location.
- Fetch and switch to a pull request source branch using the configured Git
  remote while preserving Git's normal local-change protection.
- Persist lightweight pipeline, pull request, commit, deployment, and reviewer
  candidate metadata in a file-backed cache by default.

### Explicitly Deferred

- Bitbucket Data Center support.
- Live or incremental log polling while a step is running.
- Remote semantic validation of `bitbucket-pipelines.yml`.
- Local YAML validation and Flymake or Flycheck integration.
- Step-level retry.
- OAuth authentication.
- HTTPS Git remote parsing.
- Forge integration.
- Workspace-wide repository browsing or triggering.
- Repository browsing outside the links already present in pipeline and pull
  request views.
- Environment-specific custom-pipeline wrappers.
- Pushing code or calling repository-write APIs except where Bitbucket requires
  that permission for pull request merge access.

The package may add deferred features only when they have a clear supported
implementation path. In particular, a remote validation feature must not
depend on an undocumented endpoint.

## 3. Supported Environment

- Minimum Emacs version: 29.1.
- Required package dependency: Magit 4.0.0 or newer.
- Required package dependency: `markdown-mode` 2.6 or newer.
- Required direct package dependency: `transient` 0.3.0 or newer.
- Required direct package dependency: GNU ELPA `yaml` 1.2.3 or newer.
- Pipeline features require the target Bitbucket Cloud repository to have
  Pipelines enabled.
- Built-in libraries should be preferred: `auth-source`, `json`,
  `url`, `url-http`, `tabulated-list`, `compile`, `ansi-color`, `diff-mode`,
  `browse-url`, and `ediff`.
- `alert.el` may be used when installed, but it must remain optional. The
  fallback notification mechanism is `message`.
- Forge is not a dependency.

Magit is a required context provider. The package may use Magit functions for
repository root, branch, revision, remote lookup, and opt-in push tracking. It
does not add Magit sections or Magit key bindings.

`markdown-mode` is used for pull request description compose and edit buffers.

## 4. Repository Resolution

Every API request requires a Bitbucket `{workspace}` and `{repo_slug}`. The
package derives them before making a request.

### Resolution Rules

1. Find the Git repository root using Magit.
2. Read the selected Git remote. The default remote is `origin`.
3. Parse one of these Bitbucket Cloud SSH forms:

   ```text
   git@bitbucket.org:{workspace}/{repo_slug}.git
   ssh://git@bitbucket.org/{workspace}/{repo_slug}.git
   ```

   The trailing `.git` is optional.
4. Return a repository context containing at least:

   ```text
   root, remote, workspace, repo-slug, branch, commit
   ```

### Configuration

- `bitbucket-devops-remote` selects the preferred remote and defaults to
  `"origin"`. It must be safe to set as a directory-local variable.
- `bitbucket-devops-repository-overrides` maps repository roots to explicit
  `workspace` and `repo-slug` values. An override takes precedence over remote
  parsing.

### Error Handling

Commands must fail with actionable user errors when:

- the current buffer is not inside a Git repository;
- the selected remote does not exist;
- the selected remote is not an SSH Bitbucket Cloud remote;
- the SSH URL cannot be parsed into a workspace and repository slug; or
- a branch-dependent command is invoked while HEAD is detached.

A detached HEAD still supports commit-based read-only commands where possible.

### Watcher Context

A watcher captures its repository context, commit hash, branch, and pipeline
UUID when it starts. A later branch switch or buffer switch must not change the
pipeline being watched.

## 5. Authentication

The package authenticates with a scoped Bitbucket Cloud token. App Passwords
must not be used.

- Credentials are loaded with `auth-source`.
- The recommended storage is `.authinfo.gpg`.
- `bitbucket-devops-auth-rules` selects auth-source host aliases by workspace
  and repository. These aliases are local credential names only; REST requests
  still target `api.bitbucket.org`.
- Credential selection fails closed if no rule matches the current repository.
- Support user API tokens and repository, project, or workspace access tokens.
- The token must not appear in buffers, messages, debug output, or error text.
- Local Git operations such as pull request branch checkout may run `git fetch`
  and `git switch`. Those commands use the repository's existing Git
  credentials, not the REST API token.

### User API Tokens

- The login is the user's Atlassian account email.
- The password is the scoped API token.
- Send credentials with HTTP Basic authentication.
- Read-only pipeline features require `read:pipeline:bitbucket`.
- History commit messages and authors require `read:repository:bitbucket`.
- Read-only pull request list and detail buffers require
  `read:pullrequest:bitbucket`. Bitbucket build-status links used by pull
  request detail buffers come from read-only pull request status resources.
- Reviewer completion can use repository users known from loaded pull request
  data. Broader workspace-member completion requires `read:workspace:bitbucket`
  when Bitbucket permits that lookup.
- Pull request approvals, change requests, comment management, task management,
  reviewer management, creation, merge, and decline require
  `write:pullrequest:bitbucket`.
- User API token pull request write scope does not imply
  `write:repository:bitbucket`; prefer this token type when minimizing
  repository-write privilege is more important than limiting the token to one
  repository, project, or workspace.
- Trigger and stop features additionally require `write:pipeline:bitbucket`.

Example:

```text
machine bitbucket-devops-williseed1-test login user@example.com password API_TOKEN
```

### Repository, Project, or Workspace Access Tokens

- The login is the static marker `x-token-auth`.
- The password is the scoped access token.
- Send the token as a Bearer token in the HTTP `Authorization` header.
- Read-only pipeline features require the Pipelines `Read` permission,
  equivalent to the `pipeline` scope.
- History commit messages and authors require the Repositories `Read`
  permission, equivalent to the `repository` scope.
- Pull request list and detail buffers require Pull Requests `Read`. Bitbucket
  automatically selects and locks Repositories `Read` when Pull Requests `Read`
  is selected.
- Pull request approvals, change requests, comment management, task management,
  reviewer management, creation, merge, and decline require Pull Requests
  `Write`. For repository, project, and workspace access tokens, Bitbucket's
  Pull Requests `Write` permission implies repository write capability for merge
  support. This package must not otherwise push code or call repository-write
  APIs.
- Trigger and stop features additionally require the Pipelines `Write`
  permission, equivalent to the `pipeline:write` scope.
- Pipelines `Edit variables` is not required for per-run custom trigger
  variables.

Example:

```text
machine bitbucket-devops-williseed1-test login x-token-auth password ACCESS_TOKEN
```

## 6. REST Client

### Implementation

- Use built-in `url-retrieve` for asynchronous HTTP requests.
- Do not perform synchronous network calls on the Emacs UI thread.
- Use `json-serialize` and `json-parse-buffer` for JSON payloads.
- Use the API base URL:

  ```text
  https://api.bitbucket.org/2.0/repositories/{workspace}/{repo_slug}
  ```

- Select HTTP Basic or Bearer authentication from the `auth-source` login
  marker as described above.
- Centralize request construction, authentication, JSON decoding, error
  normalization, and callback dispatch in one REST client module.
- URL-encode every dynamic path segment independently, including workspace,
  repository slug, pipeline UUID, step UUID, pull request ID, comment ID, and
  task ID values. Pipeline and step UUIDs returned by Bitbucket may contain
  curly braces.
- Treat pagination `next` URLs as opaque API links after verifying that they use
  HTTPS and remain on `api.bitbucket.org`. Do not attach credentials to an
  untrusted host.
- Raw pipeline logs and raw pull request diffs may follow trusted HTTPS
  redirects. Redirects outside `api.bitbucket.org` must be followed only without
  credentials after validating the target as a credential-free HTTPS download.

### Required Pipeline Endpoints

| Operation | Method and path |
| --- | --- |
| List pipelines | `GET /pipelines` |
| List paused pipelines | `GET /pipelines?status=PAUSED,HALTED` |
| List pipelines for commit discovery | `GET /pipelines?target.commit.hash={commit}` |
| Run pipeline | `POST /pipelines` |
| Get pipeline | `GET /pipelines/{pipeline_uuid}` |
| Get commit | `GET /commit/{commit}` |
| List steps | `GET /pipelines/{pipeline_uuid}/steps` |
| List deployments for a pipeline | `GET /deployments?q=deployable.pipeline.uuid="{pipeline_uuid}"` |
| Get step log | `GET /pipelines/{pipeline_uuid}/steps/{step_uuid}/log` |
| Stop pipeline | `POST /pipelines/{pipeline_uuid}/stopPipeline` |
| Continue manual step | `POST /internal/repositories/{workspace}/{repo_slug}/pipelines/{pipeline_uuid}/steps/{step_uuid}/start_step` |

Bitbucket does not currently provide a public 2.0 endpoint for continuing a
paused manual step. The continue operation is isolated behind the REST client
because it uses the internal endpoint exposed by the Bitbucket Cloud web UI.

### Required Pull Request Endpoints

| Operation | Method and path |
| --- | --- |
| List pull requests | `GET /pullrequests?state=...&sort=-updated_on` |
| Get pull request | `GET /pullrequests/{pull_request_id}` |
| Create pull request | `POST /pullrequests` |
| Update pull request metadata or reviewers | `PUT /pullrequests/{pull_request_id}` |
| List activity | `GET /pullrequests/{pull_request_id}/activity` |
| List comments | `GET /pullrequests/{pull_request_id}/comments` |
| Create comment, reply, or inline comment | `POST /pullrequests/{pull_request_id}/comments` |
| Get comment | `GET /pullrequests/{pull_request_id}/comments/{comment_id}` |
| Update comment | `PUT /pullrequests/{pull_request_id}/comments/{comment_id}` |
| Delete comment | `DELETE /pullrequests/{pull_request_id}/comments/{comment_id}` |
| Resolve comment thread | `POST /pullrequests/{pull_request_id}/comments/{comment_id}/resolve` |
| Reopen comment thread | `DELETE /pullrequests/{pull_request_id}/comments/{comment_id}/resolve` |
| List commits | `GET /pullrequests/{pull_request_id}/commits` |
| List build statuses | `GET /pullrequests/{pull_request_id}/statuses` |
| List tasks | `GET /pullrequests/{pull_request_id}/tasks` |
| Create task | `POST /pullrequests/{pull_request_id}/tasks` |
| Get task | `GET /pullrequests/{pull_request_id}/tasks/{task_id}` |
| Update task | `PUT /pullrequests/{pull_request_id}/tasks/{task_id}` |
| Delete task | `DELETE /pullrequests/{pull_request_id}/tasks/{task_id}` |
| Get raw diff | `GET /pullrequests/{pull_request_id}/diff` |
| List diffstat | `GET /pullrequests/{pull_request_id}/diffstat` |
| Approve | `POST /pullrequests/{pull_request_id}/approve` |
| Remove approval | `DELETE /pullrequests/{pull_request_id}/approve` |
| Request changes | `POST /pullrequests/{pull_request_id}/request-changes` |
| Remove change request | `DELETE /pullrequests/{pull_request_id}/request-changes` |
| Decline | `POST /pullrequests/{pull_request_id}/decline` |
| Merge | `POST /pullrequests/{pull_request_id}/merge?async=false` |
| List effective default reviewers | `GET /effective-default-reviewers` |
| List repository users | `GET /2.0/workspaces/{workspace}/permissions/repositories/{repo_slug}` |
| List workspace members | `GET /2.0/workspaces/{workspace}/members` |

When the pull request state filter is unset, the list request must ask
explicitly for every supported state (`OPEN`, `MERGED`, `DECLINED`, and
`SUPERSEDED`) because Bitbucket otherwise returns only open pull requests.
Every paginated pull request resource follows Bitbucket's trusted `next` links.

### Errors and Backoff

- Convert authentication, authorization, not-found, malformed-response,
  network, and rate-limit failures into concise user-facing errors.
- Preserve enough structured error data for tests and watcher retry decisions.
- Watcher requests retry transient network failures and rate limits with
  bounded exponential backoff.
- Interactive commands report failures immediately.

## 7. Pipeline History

`bitbucket-devops-pipelines-history` opens a `tabulated-list-mode` buffer for the
current repository.

### Columns

- Build number
- State
- Pipeline type (`default` or `custom: selector`)
- Branch or target
- Commit
- Author
- Commit message
- Created time
- Duration
- Deployment environments as a comma-separated summary

Initial history column widths are configurable through
`bitbucket-devops-pipelines-history-column-widths`.

### Filtering and Pagination

- The default view shows recent runs for all branches.
- A branch-filter command selects all branches, the captured current branch, a
  local Git branch, a branch fetched from the configured Git remote, a branch
  name present in loaded history, or an explicitly entered branch name.
- Magit supplies local and configured-remote branch completion candidates.
  Failure to read Git refs does not prevent filtering by loaded-history or
  explicitly entered names.
- Branch filtering applies to loaded pages. Loading additional pages extends the
  locally filtered result set.
- A status filter supports all, successful, failed, and in-progress runs.
- Author, pipeline type, and deployment filters offer values present in loaded
  history. Author and type filters match their displayed column values.
- A deployment filter matches an individual environment name in a pipeline's
  deployment summary, including pipelines with multiple deployment steps.
- The branch, status, author, type, and deployment filters compose with AND
  semantics. Each filter has an all-values choice that clears that filter.
- Loading additional pages extends the available author, type, and deployment
  choices and the locally filtered result set.
- The client follows Bitbucket's `next` pagination links.
- Initial rendering fetches one page.
- A load-more command fetches the next page and appends rows.
- Refresh discards loaded pages and reloads the first page with the active
  filters.
- Paused and halted pipelines are included explicitly, even when they are older
  than the first general history page. Completed logs from earlier steps remain
  available while a later manual or deployment step is paused.
- Pipeline, commit, and deployment metadata is persisted in a lightweight
  file-backed repository cache by default. Opening history renders cached rows
  immediately before refreshing the newest Bitbucket page. Fresh rows are merged
  into the repository cache and retained according to
  `bitbucket-devops-cache-max-pipelines-per-repo`.
- Pipeline history refreshes revalidate cached rows through the pipeline detail
  endpoint with two configurable windows: a newest-row count that is always
  refreshed, and a newest-row count that is refreshed only for records that can
  still change. Pipelines are active unless their top-level API state is
  `COMPLETED`, so pending, running, paused, and manual-waiting pipelines
  continue to be revalidated.
- The metadata cache must not store step log contents.

Selecting a row opens pipeline details, including its steps. Selecting a
completed step fetches and displays its raw log. Step listing follows
Bitbucket's `next` pagination links so pipelines with multiple pages of steps
are complete. Pipeline list responses contain abbreviated commit records, so
the UI fetches and caches each unique commit record needed to display its
author and message. A history-buffer command downloads every available
completed step log for the selected pipeline without first opening details.
History and details buffers can open or copy Bitbucket browser URLs for the
selected or displayed pipeline. The history and details buffers can also open
or copy the repository Pipelines page URL.
The history UI fetches deployment records filtered by pipeline UUID and caches
them for terminal runs. History displays their environment names as a stable
comma-separated summary in execution order. Pipeline details display the
individual deployment environment for each matching step. Ordinary pipelines
and steps leave the deployment column blank.

When Evil is loaded, history and details commands must have equivalent
normal-state bindings, including `RET` for opening the selected pipeline or
step log. A persistent command-panel side window shows context-aware keybinding
help while package UI buffers are displayed. The command panel must not consume
mode-line space or steal focus. History, details, log, pull request, and watcher
list buffers bind `-` to return to the prior package UI screen when one exists,
`?` to toggle the command panel, and `q` to quit the package UI while removing
the persistent command-panel side window. The command panel must not display
`- Back` when no prior package UI screen is available.

`bitbucket-devops-fullscreen-buffers` defaults to nil. When non-nil,
showing package list, detail, diff, commit, activity, or log buffers deletes
other content windows before selecting the package buffer and restoring the
command panel. Back navigation remains available in fullscreen mode when there
is a prior package UI screen.

`bitbucket-devops-command-panel-enabled` defaults to t. Values t and `always`
show the panel automatically, nil and `manual` show it only after pressing `?`,
and `never` disables both automatic and manual display. The command panel side
and height are configurable through `bitbucket-devops-command-panel-side` and
`bitbucket-devops-command-panel-height`.

Initial details column widths are configurable through
`bitbucket-devops-pipelines-details-column-widths`.

## 8. Logs

`bitbucket-devops-pipelines-view-step-log` retrieves the raw log for a completed
pipeline step and renders it in a dedicated read-only buffer. When the step
record includes Bitbucket-reported failure metadata under
`state.result.error`, the displayed buffer prepends its error key and message
above a clearly labeled raw log. Downloaded files remain unmodified raw logs.

- Use `compilation-mode` or a derived mode.
- Apply ANSI color handling.
- Show runner and setup failures reported separately from the raw log so the
  displayed failure reason agrees with the terminal step state.
- Name log buffers predictably using the repository, pipeline build number, and
  step name.
- Requesting a log for a non-terminal step must produce an actionable message
  explaining that logs are available after the step completes.
- Requesting a log for a stopped step must not make a known-to-fail API
  request. It must produce an actionable message explaining that the step was
  stopped. Bundle downloads skip stopped steps and report them as unavailable.
- A stopped multi-step pipeline may still expose logs from earlier successful
  steps. Do not suppress those completed logs merely because a later step was
  stopped.
- The package fetches a completed log as a single user-initiated operation. It does
  not emulate streaming.

`bitbucket-devops-pipelines-download-logs` asynchronously downloads all available
completed step logs for a selected pipeline.

- `bitbucket-devops-pipelines-download-selected-log` downloads only the completed step
  selected in a details buffer.
- In a details buffer, lowercase `d` downloads the selected step log and
  uppercase `D` downloads every available step log for the pipeline.
- `bitbucket-devops-pipelines-log-download-directory` defaults to `~/Downloads`.
- Name files predictably using the workspace, repository slug, pipeline build
  number, step order, and sanitized step name.
- Report the destination directory and any unavailable step logs when the
  operation completes.
- Copy the saved path, or newline-separated saved paths for a bundle download,
  to the kill ring when logs are written successfully.
- `bitbucket-devops-pipelines-auto-download-logs` defaults to nil. When enabled, the
  watcher downloads logs after a watched pipeline reaches a terminal state.
- Viewing a log in Emacs and downloading logs to files are separate commands.

## 9. Watcher

The watcher monitors pipeline state, not logs.

### Configuration

- `bitbucket-devops-pipelines-poll-interval` defaults to 15 seconds.
- `bitbucket-devops-pipelines-branch-poll-interval` defaults to 30 seconds.
- `bitbucket-devops-pipelines-discovery-timeout` defaults to 300 seconds.
- `bitbucket-devops-pipelines-backoff-initial-delay` defaults to 5 seconds.
- `bitbucket-devops-pipelines-backoff-maximum-delay` defaults to 120 seconds.
- `bitbucket-devops-pipelines-backoff-maximum-retries` defaults to 5.
- `bitbucket-devops-pipelines-watch-mode-line-enabled` defaults to t. When nil,
  active pipeline watchers do not add the `BB[n]` mode-line entry.
- `bitbucket-devops-pipelines-watch-list-column-widths` controls the active watcher
  list's type, repository, target, state, age, poll, next-behavior, and status
  column widths.
- `bitbucket-devops-pipelines-notification-function` defaults to nil. When nil, load
  and use optional `alert.el` when it is installed, then try built-in desktop
  notifications in graphical Emacs, and fall back to `message` otherwise.
  Users may set a one-argument function to route notifications through another
  mechanism.
- `bitbucket-devops-pipelines-notification-title` defaults to `Bitbucket Pipelines`
  and is used for built-in desktop and `alert.el` notifications.

### Starting Tracking

- Commands from history or details buffers can track a selected pipeline
  directly.
- `bitbucket-devops-pipelines-watch-branch-current` prompts for a branch and
  persistently tracks newly discovered pipelines on that branch.
- `bitbucket-devops-pipelines-watch-repository-current` persistently tracks newly
  discovered pipelines anywhere in the current repository.
- Branch and repository pipeline watchers establish a quiet baseline for completed
  historical runs on their first poll, attach to active runs immediately, and
  start ordinary run watchers for later unseen matching pipelines.
- A successful `bitbucket-devops-pipelines-run-configured` or
  `bitbucket-devops-pipelines-rerun` command starts tracking the returned
  pipeline UUID immediately.
- Automatic Magit push tracking is optional and separate from manual tracking.
  It performs commit-based discovery for the captured pushed `HEAD`. If the
  pipeline has not appeared yet, discovery polling retries for a configurable
  bounded period.

### Magit Push Tracking

- `bitbucket-devops-pipelines-magit-push-watch-mode` is an opt-in global minor mode.
- When enabled, it observes asynchronous Magit branch pushes without changing
  Magit's key bindings or requiring a repository Git hook.
- Capture repository context and `HEAD` immediately before Magit starts
  `git push`.
- Start commit-based pipeline discovery only after Git exits successfully.
- Do not start discovery after failed pushes, dry runs, tag-only pushes,
  note-only pushes, deletion-style pushes, matching-branch pushes, or pushes
  explicitly sent to a remote other than the resolved repository remote.
- Run `bitbucket-devops-pipelines-after-magit-push-hook` after a successful tracked
  push. Hook functions receive the captured repository context.
- The default hook function is `bitbucket-devops-pipelines-watch-commit`. Users may
  add hook functions for additional post-push behavior or remove the default
  function when they want to replace automatic tracking.
- `bitbucket-devops-pipelines-auto-download-logs` applies normally to a watcher started
  after a Magit push.

### Lifecycle

- Poll run watchers only while a tracked pipeline is non-terminal or while
  bounded discovery polling is waiting for the pipeline to appear.
- Poll branch and repository subscriptions until the user stops them explicitly
  or retry handling stops them after repeated failures.
- Cancel timers when a tracked run reaches a terminal state.
- Allow the user to stop watching a run, branch, or repository explicitly.
- Deduplicate notifications so the same observed state is announced once.
- Treat Bitbucket's in-progress `PAUSED` or `HALTED` result as a visible state,
  notify when a run enters it, and continue polling until terminal completion.
- Apply bounded exponential backoff after transient network failures and rate
  limits.
- Stop retrying after a configurable maximum and notify the user.

### Multiple Repositories

- Maintain independent watcher records keyed by repository and pipeline UUID, by
  repository and captured commit during discovery, by repository and branch, or
  by repository subscription.
- Support simultaneous active watchers for different repositories.
- Display an aggregate active watcher count in the mode line.
- Provide a command that lists active pipeline watchers and PR comment watchers
  with their type, repository, target, state, age/timeout, poll interval, next
  behavior, and active/error status. The same list shows whether Magit push
  tracking is enabled and lets the user toggle it without returning to the
  dispatch menu.
- Remove terminal run watchers from the active list and display an explanatory
  empty state when no watchers remain.

### Pull Request Comment Watchers

- Pull request comment watchers poll comments only while the pull request is
  `OPEN`.
- Before each comment poll, fetch the current pull request state. Treat
  `MERGED`, `DECLINED`, `SUPERSEDED`, and any other non-`OPEN` state returned by
  Bitbucket as terminal for comment watching.
- When a watched pull request reaches a terminal state, cancel the timer, remove
  the watcher record, update the mode line, and notify that watching stopped.
- The first successful comment poll records existing remote comments and replies
  as a quiet baseline. Later unseen, non-deleted comments notify.
- `bitbucket-devops-pull-requests-comments-watch-max-age` defaults to nil. When
  set to seconds, stop a comment watcher once its lifetime reaches that value.
- Store each comment watcher's start time and show age/timeout in the unified
  watcher list.
- `bitbucket-devops-pull-requests-auto-watch-created` defaults to nil. When
  non-nil, successful pull request creation prompts "Watch comments for pull
  request #N?"; the prompt defaults to yes and starts watching only when the
  user accepts.

## 10. Mutations

### Trigger

`bitbucket-devops-pipelines-run-configured` parses `bitbucket-pipelines.yml` and
prompts for a configured pipeline to run against the current branch. It exposes
the `default` selector, every named `pipelines: branches:` selector, every named
`pipelines: pull-requests:` selector, and every named `pipelines: custom:`
entry. For `default`, `branches`, and `custom` options, the package keeps the
API target on the current branch and sends the selected selector. Pull request
options resolve the open pull request whose source is the current branch, then
send a pull request pipeline target. Custom options may prompt for optional
variables.

The YAML adapter must preserve valid custom names including spaces, dots,
slashes, and quoted keys. It must retain `default`, `branches`,
`pull-requests`, `tags`, `custom`, and custom-variable metadata so future
target-specific commands do not need another parsing implementation. The package
does not offer tag execution from a branch context.

Before sending a trigger request, require a full confirmation when the target
branch is `main` or `master`, or when a deployment environment contains `prod`
anywhere in its name, case-insensitively. Apply the guard in the shared mutation
boundary so direct branch triggers, configured triggers, reruns, and future
mutation commands cannot accidentally bypass it. For pull request targets, use
the source branch as the target branch for branch-name checks, and rely on
parsed deployment metadata for deployment-name checks.

For each custom variable, prompt for its value. Use YAML defaults and allowed
values when declared. Do not include variable values in messages, error text,
or debug output.

Prompt only for declared variables by default. Allow additional free-form key
and value pairs when the command receives a prefix argument, so the common path
ends after the declared prompts and undeclared variables stay reachable without
a separate command. Apply the same prefix argument to reruns, where the
declared set is the variable keys remembered from the last trigger.

Runtime variables are sent unsecured. The trigger request carries only each
variable's key and value, never Bitbucket's `secured` flag, so Bitbucket stores
the values as plain text on the pipeline run and does not mask them in its log
output. The package deliberately does not prompt for a secured flag or read
values with `read-passwd`. Secrets belong in Bitbucket's own secured
repository, deployment, or workspace variables, not in a runtime variable
prompt.

`bitbucket-devops-pipelines-yaml-file-name` defaults to `bitbucket-pipelines.yml` and
controls the local file parsed by configured trigger commands.

### Remembered Defaults

- Remember the last branch and custom selector between Emacs sessions.
- Remember custom-variable keys.
- Prompt for every custom-variable value on every run, using a remembered
  value as the default when available.
- Remember custom-variable values only when
  `bitbucket-devops-pipelines-remember-variable-values` is non-nil. This option is
  intended only for repositories whose runtime variables are not secrets.
- Integrate remembered defaults with `savehist` when it is available.

### Rerun

`bitbucket-devops-pipelines-rerun` creates a new pipeline run using the selected prior
pipeline's target. When applicable, the user may supply a custom selector. With
a prefix argument, it also prompts for free-form runtime variables beyond the
remembered keys.

The package does not promise a server-side retry operation and does not retry an
individual step.

### Stop

`bitbucket-devops-pipelines-stop` prompts for confirmation and stops the selected
active pipeline.

### Continue Manual Step

`bitbucket-devops-pipelines-continue` prompts for confirmation and starts the
selected pending step in a paused or halted pipeline. It must reject completed
steps and pipelines that are not paused before sending a request.

## 11. Pull Requests

Pull request workflows use the same repository context, authentication, REST
client, pagination, cache, display policy, and command panel as Pipelines.

### List View

`bitbucket-devops-pull-requests-list` opens a `tabulated-list-mode` buffer for
the current repository, sorted newest-updated first.

### Columns

- Pull request number
- State, including draft status
- Title
- Source branch
- Destination branch
- Author
- Reviewer count
- Approval count
- Build summary
- Created time
- Updated time

Initial list column widths are configurable through
`bitbucket-devops-pull-requests-list-column-widths`. Long rows are truncated by
default through `bitbucket-devops-pull-requests-list-truncate-lines`, and users
may allow ordinary Emacs line wrapping by setting it to nil.

### Filtering, Pagination, and Caching

- The default list requests every supported Bitbucket pull request state:
  `OPEN`, `MERGED`, `DECLINED`, and `SUPERSEDED`.
- A state filter refreshes the server page for one selected state or returns to
  the all-state view.
- Branch and author filters apply to loaded pull requests and can be reset to
  all values.
- A load-more command follows Bitbucket's trusted `next` pagination links.
- Pull request metadata is persisted in the file-backed repository cache by
  default. Opening the list renders cached rows immediately before refreshing
  the newest Bitbucket page. Fresh rows are merged into the repository cache and
  retained according to `bitbucket-devops-cache-max-pull-requests-per-repo`.
- Pull request list refreshes revalidate cached rows through the pull request
  detail endpoint with two configurable windows: a newest-row count that is
  always refreshed, and a newest-row count that is refreshed only for records
  that can still change. Pull requests are active while `OPEN` or unknown;
  `MERGED`, `DECLINED`, and `SUPERSEDED` are terminal outside the always-refresh
  window.
- The revalidation windows are controlled by
  `bitbucket-devops-pull-requests-sync-always-count` and
  `bitbucket-devops-pull-requests-sync-active-count`. A nil or zero value
  disables the corresponding window.
- Build summaries are enriched asynchronously from pull request build statuses
  and retained with the cached pull request row.
- Reviewer candidate lookups are cached per repository after a successful load
  and can be replaced through
  `bitbucket-devops-pull-requests-refresh-reviewer-cache`.
- Comments, tasks, diffs, activity, commits, and raw patch text are not cached
  as durable payloads.

### Detail and Subviews

Selecting a row opens a pull request detail buffer. The detail buffer fetches
the pull request record plus comments, activity, commits, build statuses, tasks,
and diffstat. Paginated detail resources are collected through trusted `next`
links. Section-specific API failures are displayed without discarding the
currently loaded detail view.

Detail buffers show repository and pull request context, title, state,
readiness, source and destination branches, author, reviewers, participants,
approvals, checks, tasks, comments, commits, activity, and changed-file
summaries. Description and comments render Markdown-oriented text, and
recognized emoji shortcodes display as Unicode glyphs when
`bitbucket-devops-pull-requests-display-emoji-shortcodes` is non-nil. Editing
comments or descriptions must preserve and send the original Markdown text.
Rendered comment headers include the commenter and local creation timestamp.

The Checks section lists each build status with state, provider, description,
and link. `bitbucket-devops-pull-requests-build-status-action` controls whether
`RET` opens a browser URL or matching local Bitbucket Pipelines details by
default. Local opening applies only to statuses that identify Bitbucket
Pipelines; external provider links such as Terraform Cloud open in the browser.
A prefix argument runs the other action for one invocation when both actions are
available. `S-RET` copies the URL at point instead of opening it.

Diff viewing supports three backends:

- `bitbucket` displays the exact raw patch returned by Bitbucket Cloud.
- `magit` fetches the needed revisions and opens a local three-dot Magit range
  diff.
- `ediff` prompts for a changed file and compares its merge-base and source
  versions.

`bitbucket-devops-pull-requests-diff-viewer` sets the default backend, and
`bitbucket-devops-pull-requests-ui-choose-diff-viewer` chooses a backend for one
view. Raw diff, commits, and activity buffers support refresh and package back
navigation. In a commits buffer, opening a commit fetches the pull request source
branch when the selected commit is not already present locally, then opens the
commit's changed files and patch in Magit.

Inline comments in a raw diff infer the repo-relative path, old or new side, and
line number from point. Added and context lines use Bitbucket's `to` side.
Deleted lines use `from`; renamed files choose `from` or `to` according to the
line. File metadata lines move to the first changed line in the file when one is
available. Detail buffers also provide an explicit file, side, and line prompt
for inline comments.

### Review and Mutation Actions

- Create a pull request from repository branches.
- Use no reviewers, effective default reviewers, or explicitly selected custom
  reviewers during creation.
- Cancel creation before posting when the same source and destination branch
  pair already has an open pull request.
- Compose and edit pull request descriptions in a right-side `markdown-mode`
  buffer. `C-c C-c` and `C-x C-s` post the complete Markdown body, and
  `C-c C-k` cancels.
- Mark a draft ready for review, mark a ready pull request back to draft, or
  toggle readiness while preserving title and description.
- Approve, remove approval, request changes, and remove a change request as the
  current user.
- Add, edit, delete, reply to, resolve, and reopen comments.
- Create, edit, delete, resolve, and reopen tasks. `RET` on a task toggles its
  resolved state when that contextual action is available.
- Add one reviewer, add effective default reviewers that are not already present,
  and remove a loaded reviewer after confirmation.
- Decline a pull request after confirmation.
- Merge an open, non-draft pull request after choosing merge strategy, optional
  merge message, close-source-branch behavior, and confirming.
- Fetch and switch to the pull request source branch. If the local branch
  already exists, preserve it and update only the remote-tracking ref before
  switching. Otherwise, create a local tracking branch. Git must refuse the
  switch when local changes would be overwritten.

All successful review, reviewer, metadata, comment, task, merge, and decline
actions refresh the current view asynchronously. API failures are reported
without exposing credentials and without discarding the current buffer state.

### Keybinding Customization

Pull request keybindings are shared by ordinary Emacs maps and Evil normal
state. Users may customize:

- `bitbucket-devops-pull-requests-list-keybindings`
- `bitbucket-devops-pull-requests-detail-keybindings`
- `bitbucket-devops-pull-requests-diff-keybindings`
- `bitbucket-devops-pull-requests-subview-keybindings`
- `bitbucket-devops-pull-requests-commits-keybindings`
- `bitbucket-devops-pull-requests-task-keybindings`
- `bitbucket-devops-pull-requests-metadata-keybindings`
- `bitbucket-devops-pull-requests-task-prefix-key`
- `bitbucket-devops-pull-requests-metadata-prefix-key`
- `bitbucket-devops-pull-requests-evil-universal-argument-keybindings`

After changing keybinding options, users can run
`bitbucket-devops-pull-requests-ui-apply-keybindings` to refresh loaded maps.

## 12. User Interface

Provide a transient prefix command, `bitbucket-devops`, with the
repository-scoped actions:

```text
h  Show pipeline history
r  Run Pipeline (configured pipeline chooser)
a  Toggle automatic log downloads for completed tracked pipelines
l  List pull requests
c  Create a pull request
R  Refresh cached custom reviewer candidates
m  Toggle automatic pipeline watching after successful Magit pushes
b  Watch new pipelines on a branch
o  Watch new pipelines in the current repository
t  List active watchers
x  Stop an active pipeline watcher
q  Quit dispatch
```

The top-level dispatch must use at most three columns so it remains usable in a
narrow split. Commands that require a selected pipeline, step, pull request,
comment, task, reviewer, build status, or diff position must not appear in the
repository-scoped dispatch. Contextual commands appear in the corresponding
package buffer. The automatic log-download and Magit push-watch toggles are
runtime session switches. They must not write to the user's init file or package
configuration.

```text
Pipeline History:
r    Refresh history
n    Load next history page
f    Filter loaded history by branch
s    Filter loaded history by status
a    Filter loaded history by commit author
T    Filter loaded history by displayed pipeline type
D    Filter loaded history by deployment environment
RET  Open pipeline details
S-RET Copy browser URL
o    Open selected pipeline in browser
O    Open repository Pipelines page in browser
t    Track selected pipeline
d    Download selected pipeline logs
R    Run configured pipeline
TAB  Expand current column to fit loaded values
?    Toggle command panel
-    Back
q    Quit package UI

Pipeline Details:
r    Refresh displayed pipeline
RET  View selected completed step log
S-RET Copy browser URL
o    Open displayed pipeline in browser
O    Open repository Pipelines page in browser
d    Download selected completed step log
D    Download displayed pipeline logs
t    Track displayed pipeline
R    Rerun displayed pipeline
c    Continue selected pending manual step
s    Stop displayed pipeline
?    Toggle command panel
-    Back
q    Quit package UI

Pull Request List:
r / C-c g  Refresh first page
n         Load next page
s         Filter by pull request state
f         Filter loaded pull requests by branch
a         Filter loaded pull requests by author
RET       Open pull request details
S-RET     Copy browser URL
C-c b     Checkout source branch
t         Watch comments on selected pull request
C-c w     Watch comments on selected pull request
C-c C-w   Watch comments on selected pull request
o         Open browser URL
c         Create a pull request
?         Toggle command panel
-         Back
q         Quit package UI

Pull Request Details:
RET       Run contextual action at point
S-RET     Copy browser URL at point
r / C-c g Refresh details
d         Open diff
C-c d     Choose one-time diff viewer
m         Open complete loaded commit list
A         Open complete loaded activity list
b         Checkout source branch
o         Open browser URL
I / R     Toggle ready/draft state
a         Approve
u         Remove approval
x         Request changes
X         Remove change request
c         Add comment
C         Reply to loaded comment
C-c e     Edit loaded comment
C-c i     Add inline comment from explicit location
C-c k     Delete loaded comment
C-c r     Resolve loaded comment thread
C-c o     Reopen loaded comment thread
C-c +     Add reviewer
C-c =     Add missing effective default reviewers
C-c -     Remove loaded reviewer
C-c p e   Edit title and description
C-c p d   Toggle draft state
C-c t c   Create task
C-c t e   Edit loaded task
C-c t d   Delete loaded task
C-c t r   Resolve loaded task
C-c t o   Reopen loaded task
M         Merge
D         Decline
?         Toggle command panel
-         Back
q         Quit package UI

Pull Request Diff:
r / C-c g  Refresh diff
i / C-c i  Add inline comment inferred from point
?          Toggle command panel
-          Back
q          Quit package UI

Pull Request Commits and Activity:
r / C-c g  Refresh subview
RET        Open selected commit in Magit (commit buffer only)
?          Toggle command panel
-          Back
q          Quit package UI
```

The package adds an optional mode-line indicator while any pipeline watcher is
active. The indicator shows the active watcher count and opens the watcher list
when clicked. Users may disable the indicator with
`bitbucket-devops-pipelines-watch-mode-line-enabled`.

Pipeline history and details buffers use status-aware faces for successful,
failed, stopped, and active states. Pull request buffers use semantic faces for
state, draft, branch, build, approval, task, comment, activity, diff, and
secondary metadata. History timestamps default to the local system time zone.
Users may configure a fixed named time zone, such as `"America/Chicago"`, or
Universal Time. Users may also customize the timestamp format.

## 13. Testing Strategy

Development follows test-driven development.

- Use ERT for automated tests.
- Unit-test SSH remote parsing, repository overrides, detached HEAD behavior,
  auth-source lookup, request construction, JSON decoding, state
  classification, path-segment encoding, pagination-host validation, redirect
  handling, and cache persistence with reader evaluation disabled.
- Unit-test pipeline and step pagination, paused-pipeline inclusion, deployment
  summaries, commit enrichment, notification deduplication, retry backoff, timer
  cancellation, remembered trigger metadata, prevention of variable-value
  persistence, log-download filenames, and stopped-step log handling.
- Unit-test pull request summaries, build status summaries, task and comment
  summaries, diffstat summaries, list/detail rendering, filters, pagination,
  cached refresh windows, build enrichment, reviewer candidate caching, branch
  checkout, browser and copy-link behavior, diff backends, inline comment
  inference, review actions, comments, tasks, metadata edits, reviewer
  management, creation preflight, draft handling, decline, merge, keybindings,
  command panels, and Evil bindings.
- Replace `url-retrieve` and Bitbucket REST functions with deterministic test
  doubles in offline tests.
- Feed recorded JSON and diff fixtures through REST, UI, cache, history,
  watcher, and pull request code.
- Do not require live Bitbucket credentials or network access for the automated
  test suite.
- Provide a separate opt-in read-only integration suite for the dedicated
  `williseed1/test` Bitbucket Cloud repository. It must authenticate through
  `auth-source`, list pipelines, fetch pipeline details and steps, retrieve a
  completed step log, list pull requests, and verify pull request detail
  resources through the real API.
- Keep live integration tests outside the default ERT target and never print
  token values.
- Keep mutating live tests separate from the read-only integration suite.
  Triggering, stopping, merging, declining, or otherwise mutating remote state
  requires an explicit invocation because it changes remote state and may
  consume billable pipeline minutes.
- Provide an explicit mutating integration target for a dedicated test
  repository. It must resolve repository context through Magit, drive public
  branch and custom pipeline triggers, cover per-run variables, rerun a prior
  pipeline, verify watcher polling and commit discovery, exercise history and
  details buffers, retrieve and download logs, verify automatic log downloads,
  perform an up-to-date Magit branch push with post-push discovery, stop a
  separate long-running pipeline, and verify pipeline-wide log downloads for
  multi-step and deployment pipelines.
- Run load testing, offline ERT, byte compilation, and package linting in CI.

## 14. Acceptance Criteria

The package contract is satisfied when all of the following are true:

1. From a repository with an `origin` SSH remote such as
   `git@bitbucket.org:workspace/repository.git`, the package resolves the
   workspace and repository slug.
2. Repository overrides work when the selected remote is missing or unsuitable.
3. A user with a configured Bitbucket Cloud token in `.authinfo.gpg` can list
   pipeline history and pull requests without blocking the Emacs UI.
4. Pipeline history supports first-page loading, load-more pagination, refresh,
   paused-pipeline inclusion, and composable branch, status, commit-author,
   displayed-type, and deployment-environment filtering.
5. A user can open a pipeline, select a completed step, and view its
   ANSI-colored log.
6. A user can asynchronously download one completed step log or all available
   completed step logs for a pipeline into a configurable directory with
   predictable filenames, and the saved paths are copied to the kill ring.
7. Push tracking continues to track the captured run after the user changes
   branches.
8. Watcher timers stop for terminal runs, repeated states do not produce
   duplicate notifications, paused runs keep polling, and transient failures
   back off.
9. Multiple repositories can be watched at the same time.
10. A user can parse configured pipeline choices, trigger the automatic
    current-branch pipeline, trigger any named custom pipeline with optional
    runtime variables, trigger a pull request selector for the current branch,
    rerun by creating a new pipeline with a prior target, continue a pending
    manual step, and stop an active pipeline.
11. Triggering or rerunning a production-sensitive pipeline requires explicit
    confirmation before the REST request is sent.
12. Successfully triggering or rerunning a pipeline starts an asynchronous
    watcher for the returned pipeline UUID.
13. Remembered trigger defaults persist branch, selector, and variable keys.
    Variable values are remembered only when explicitly enabled.
14. Pull request lists support newest-updated ordering, pagination, state
    refresh filters, local branch and author filters, cached first render,
    build summary enrichment, and configurable cached-row revalidation windows.
15. A user can open a pull request detail buffer and view metadata, reviewers,
    approvals, checks, tasks, comments, commits, activity, and changed-file
    summaries.
16. A user can open Bitbucket patch diffs, Magit range diffs, and per-file Ediff
    views for a pull request.
17. A user can open or copy pull request and build-status browser links, and can
    make build-status `RET` open either the browser URL or matching local
    Bitbucket Pipelines details according to configuration. External provider
    status links remain browser-only.
18. A user can create a pull request, compose or edit Markdown descriptions,
    manage draft state, add or remove reviewers, apply effective default
    reviewers, approve, request changes, comment, reply, comment inline, manage
    tasks, decline, and merge with confirmation.
19. Pull request creation cancels before posting when an open pull request
    already exists for the same source and destination branch pair.
20. Pull request source branch checkout fetches the configured remote and lets
    Git protect local changes.
21. History, details, log, pull request, diff, commit, activity, and watcher
    buffers support package navigation, command-panel display, Evil normal-state
    bindings when Evil is loaded, and fullscreen display when configured.
22. Tests run without network access and cover repository resolution, REST
    behavior, trusted-host pagination, redirects, cache behavior, pipeline logs,
    watcher lifecycle, pipeline mutations, and pull request workflows.
23. An opt-in read-only integration suite verifies authentication and the live
    Bitbucket Cloud API contract against the dedicated test repository.
24. An explicit mutating integration suite verifies repository-aware public
    pipeline workflows, branch and custom triggers, runtime variables, reruns,
    watcher polling and discovery, logs, downloads, and pipeline cancellation
    against the dedicated test repository.
25. Enabling `bitbucket-devops-pipelines-magit-push-watch-mode` starts
    commit-based discovery after a successful Magit branch push, does not start
    it after a failed or excluded push, and allows user hook functions to run
    with the captured pre-push context.
