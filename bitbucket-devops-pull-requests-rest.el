;;; bitbucket-devops-pull-requests-rest.el --- Bitbucket Pull Request REST wrappers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Will Bosch-Bello

;; Author: Will Bosch-Bello <williamsbosch@gmail.com>
;; Assisted-by: Codex:gpt-5.5-codex
;; Assisted-by: Claude:claude-opus-5
;; Maintainer: Will Bosch-Bello <williamsbosch@gmail.com>
;; Keywords: tools, vc
;; SPDX-License-Identifier: GPL-3.0-only

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License version 3 as
;; published by the Free Software Foundation.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Bitbucket Cloud pull request API wrappers built on the shared REST client.

;;; Code:

(require 'subr-x)
(require 'url-util)
(require 'bitbucket-devops-rest)

(defconst bitbucket-devops-pull-requests-rest-sort-query "sort=-updated_on"
  "Query parameter that requests newest-updated pull requests first.")

(defconst bitbucket-devops-pull-requests-rest-workspaces-base-url
  "https://api.bitbucket.org/2.0/workspaces"
  "Bitbucket Cloud workspaces API base URL.")

(defconst bitbucket-devops-pull-requests-rest-states
  '("OPEN" "MERGED" "DECLINED" "SUPERSEDED")
  "Pull request states requested when the UI lists all pull requests.")

(defconst bitbucket-devops-pull-requests-rest-merge-strategies
  '("merge_commit"
    "squash"
    "fast_forward"
    "squash_fast_forward"
    "rebase_fast_forward"
    "rebase_merge")
  "Merge strategies accepted by the Bitbucket Cloud pull request API.")

(defun bitbucket-devops-pull-requests-rest--append-query (url query)
  "Return URL with QUERY appended."
  (concat url
          (if (string-match-p "\\?" url) "&" "?")
          query))

(defun bitbucket-devops-pull-requests-rest--with-sort (url)
  "Return URL with the default pull request sort query."
  (if (string-match-p "\\(?:[?&]\\)sort=" url)
      url
    (bitbucket-devops-pull-requests-rest--append-query
     url
     bitbucket-devops-pull-requests-rest-sort-query)))

(defun bitbucket-devops-pull-requests-rest--with-state (url state)
  "Return URL filtered by pull request STATE.

STATE may be one state string or a list of states.  When STATE is nil, request
all supported states explicitly because Bitbucket otherwise returns only open
pull requests."
  (let ((states
         (cond
          ((and (stringp state) (not (string-empty-p state))) (list state))
          ((null state) bitbucket-devops-pull-requests-rest-states)
          ((listp state) state)
          (t nil))))
    (dolist (value states url)
      (setq url
            (bitbucket-devops-pull-requests-rest--append-query
             url
             (concat "state=" (url-hexify-string value)))))))

(defun bitbucket-devops-pull-requests-rest--pull-request-url
    (context pull-request-id &rest segments)
  "Return a pull request URL for CONTEXT, PULL-REQUEST-ID, and SEGMENTS."
  (apply
   #'bitbucket-devops-rest-repository-url
   context
   "pullrequests"
   (number-to-string pull-request-id)
   segments))

(defun bitbucket-devops-pull-requests-rest--workspace-url (context &rest segments)
  "Return a workspace API URL for CONTEXT and SEGMENTS."
  (concat
   bitbucket-devops-pull-requests-rest-workspaces-base-url
   "/"
   (mapconcat
    #'bitbucket-devops-rest-encode-path-segment
    (cons (plist-get context :workspace) segments)
    "/")))

(defun bitbucket-devops-pull-requests-rest-list-repository-users
    (context callback &optional next-url)
  "List users with effective access to CONTEXT and invoke CALLBACK.

Only repository administrators can access this Bitbucket endpoint.  Request
NEXT-URL instead of the first page when it is non-nil."
  (bitbucket-devops-rest-request
   "GET"
   (if next-url
       (bitbucket-devops-rest-validate-pagination-url next-url)
     (bitbucket-devops-pull-requests-rest--workspace-url
      context
      "permissions"
      "repositories"
      (plist-get context :repo-slug)))
   callback
   nil
   nil
   context))

(defun bitbucket-devops-pull-requests-rest-list-workspace-members
    (context callback &optional next-url)
  "List members of CONTEXT's workspace and invoke CALLBACK.

Request NEXT-URL instead of the first page when it is non-nil."
  (bitbucket-devops-rest-request
   "GET"
   (if next-url
       (bitbucket-devops-rest-validate-pagination-url next-url)
     (bitbucket-devops-pull-requests-rest--workspace-url context "members"))
   callback
   nil
   nil
   context))

(defun bitbucket-devops-pull-requests-rest-list-effective-default-reviewers
    (context callback &optional next-url)
  "List effective default reviewers for CONTEXT and invoke CALLBACK.

The result includes repository defaults and defaults inherited from the
repository's project.  Request NEXT-URL instead of the first page when non-nil."
  (bitbucket-devops-rest-request
   "GET"
   (if next-url
       (bitbucket-devops-rest-validate-pagination-url next-url)
     (bitbucket-devops-rest-repository-url
      context
      "effective-default-reviewers"))
   callback
   nil
   nil
   context))

(defun bitbucket-devops-pull-requests-rest-list
    (context callback &optional next-url state)
  "Asynchronously list pull requests for CONTEXT and invoke CALLBACK.

Request NEXT-URL instead of the first page when it is non-nil.  STATE may be a
Bitbucket pull request state such as \"OPEN\", \"MERGED\", or \"DECLINED\".
When STATE is nil, request every supported state."
  (bitbucket-devops-rest-request
   "GET"
   (if next-url
       (bitbucket-devops-rest-validate-pagination-url next-url)
     (bitbucket-devops-pull-requests-rest--with-sort
      (bitbucket-devops-pull-requests-rest--with-state
       (bitbucket-devops-rest-repository-url context "pullrequests")
       state)))
   callback
   nil
   nil
   context))

(defun bitbucket-devops-pull-requests-rest-get
    (context pull-request-id callback)
  "Asynchronously get PULL-REQUEST-ID for CONTEXT and invoke CALLBACK."
  (bitbucket-devops-rest-request
   "GET"
   (bitbucket-devops-pull-requests-rest--pull-request-url context pull-request-id)
   callback
   nil
   nil
   context))

(defun bitbucket-devops-pull-requests-rest-create
    (context body callback)
  "Asynchronously create a pull request in CONTEXT with BODY.
CALLBACK receives the decoded response and a request error."
  (bitbucket-devops-rest-request
   "POST"
   (bitbucket-devops-rest-repository-url context "pullrequests")
   callback
   body
   nil
   context))

(defun bitbucket-devops-pull-requests-rest--reviewer-object (identifier)
  "Return a Bitbucket reviewer object for IDENTIFIER.

Braced identifiers are treated as Bitbucket UUIDs.  Other identifiers are
treated as Atlassian account IDs."
  (if (string-prefix-p "{" identifier)
      `((uuid . ,identifier))
    `((account_id . ,identifier))))

(defun bitbucket-devops-pull-requests-rest-reviewers-body (reviewer-identifiers)
  "Return an update body for REVIEWER-IDENTIFIERS."
  `((reviewers
     . ,(vconcat
         (mapcar
          #'bitbucket-devops-pull-requests-rest--reviewer-object
          reviewer-identifiers)))))

(defun bitbucket-devops-pull-requests-rest-create-body
    (source destination title &optional description draft reviewer-identifiers)
  "Return a pull request creation body.

SOURCE and DESTINATION are branch names.  TITLE is required.  DESCRIPTION,
DRAFT, and REVIEWER-IDENTIFIERS are optional.  Reviewer identifiers may be
Bitbucket UUIDs or Atlassian account IDs.  When REVIEWER-IDENTIFIERS is nil,
omit the field.  The value `:none' sends an explicit empty reviewer list."
  (setq source (string-trim (or source ""))
        destination (string-trim (or destination ""))
        title (string-trim (or title ""))
        description (string-trim (or description "")))
  (when (string-empty-p source)
    (user-error "Pull request source branch cannot be empty"))
  (when (string-empty-p destination)
    (user-error "Pull request destination branch cannot be empty"))
  (when (string-empty-p title)
    (user-error "Pull request title cannot be empty"))
  (append
   `((title . ,title)
     (source . ((branch . ((name . ,source)))))
     (destination . ((branch . ((name . ,destination))))))
   (unless (string-empty-p description)
     `((description . ,description)))
   (when draft
     '((draft . t)))
   (cond
    ((eq reviewer-identifiers :none)
     (bitbucket-devops-pull-requests-rest-reviewers-body nil))
    (reviewer-identifiers
     (bitbucket-devops-pull-requests-rest-reviewers-body reviewer-identifiers)))))

(defun bitbucket-devops-pull-requests-rest-metadata-body (title description draft)
  "Return an update body for pull request TITLE, DESCRIPTION, and DRAFT.

DESCRIPTION may be an empty string to clear the remote description.  DRAFT is
serialized as an explicit JSON boolean so callers can mark a pull request as
ready for review."
  (setq title (string-trim (or title ""))
        description (or description ""))
  (when (string-empty-p title)
    (user-error "Pull request title cannot be empty"))
  `((title . ,title)
    (description . ,description)
    (draft . ,(if draft t :false))))

(defun bitbucket-devops-pull-requests-rest-update
    (context pull-request-id body callback)
  "Asynchronously update PULL-REQUEST-ID in CONTEXT with BODY."
  (bitbucket-devops-rest-request
   "PUT"
   (bitbucket-devops-pull-requests-rest--pull-request-url context pull-request-id)
   callback
   body
   nil
   context))

(defun bitbucket-devops-pull-requests-rest-list-activity
    (context pull-request-id callback &optional next-url)
  "Asynchronously list activity for PULL-REQUEST-ID and invoke CALLBACK.
CONTEXT identifies the Bitbucket repository."
  (bitbucket-devops-rest-request
   "GET"
   (if next-url
       (bitbucket-devops-rest-validate-pagination-url next-url)
     (bitbucket-devops-pull-requests-rest--pull-request-url
      context
      pull-request-id
      "activity"))
   callback
   nil
   nil
   context))

(defun bitbucket-devops-pull-requests-rest-list-comments
    (context pull-request-id callback &optional next-url)
  "Asynchronously list comments for PULL-REQUEST-ID and invoke CALLBACK.
CONTEXT identifies the Bitbucket repository."
  (bitbucket-devops-rest-request
   "GET"
   (if next-url
       (bitbucket-devops-rest-validate-pagination-url next-url)
     (bitbucket-devops-pull-requests-rest--pull-request-url
      context
      pull-request-id
      "comments"))
   callback
   nil
   nil
   context))

(defun bitbucket-devops-pull-requests-rest--comment-url
    (context pull-request-id comment-id &rest segments)
  "Return a comment URL for CONTEXT, PULL-REQUEST-ID, and COMMENT-ID.
SEGMENTS are extra path components appended to the URL."
  (apply
   #'bitbucket-devops-pull-requests-rest--pull-request-url
   context
   pull-request-id
   "comments"
   (number-to-string comment-id)
   segments))

(defun bitbucket-devops-pull-requests-rest-inline-body (inline-location)
  "Return a Bitbucket inline comment object for INLINE-LOCATION."
  (let ((path (string-trim (or (plist-get inline-location :path) "")))
        (from (plist-get inline-location :from))
        (to (plist-get inline-location :to)))
    (when (string-empty-p path)
      (user-error "Inline comment path cannot be empty"))
    (when (eq (integerp from) (integerp to))
      (user-error "Inline comment needs exactly one from or to line"))
    (when (and (integerp from) (< from 1))
      (user-error "Inline comment from line must be positive"))
    (when (and (integerp to) (< to 1))
      (user-error "Inline comment to line must be positive"))
    (append
     `((path . ,path))
     (when from `((from . ,from)))
     (when to `((to . ,to))))))

(defun bitbucket-devops-pull-requests-rest-comment-body
    (text &optional parent-id inline-location)
  "Return a Bitbucket comment body.

TEXT is required.  PARENT-ID creates a reply.  INLINE-LOCATION is a plist with
`:path' and exactly one of `:from' or `:to'."
  (unless (and (stringp text) (not (string-empty-p text)))
    (user-error "Pull request comment text cannot be empty"))
  (when (and parent-id inline-location)
    (user-error "A pull request comment cannot be both a reply and inline"))
  (append
   `((content . ((raw . ,text))))
   (when parent-id
     `((parent . ((id . ,parent-id)))))
   (when inline-location
     `((inline . ,(bitbucket-devops-pull-requests-rest-inline-body inline-location))))))

(defun bitbucket-devops-pull-requests-rest-create-comment
    (context pull-request-id text callback &optional parent-id inline-location)
  "Create a comment on PULL-REQUEST-ID with TEXT.

When PARENT-ID is non-nil, create a reply using Bitbucket's `parent.id'
relationship.  When INLINE-LOCATION is non-nil, create an inline diff comment.
CONTEXT identifies the Bitbucket repository."
  (bitbucket-devops-rest-request
   "POST"
   (bitbucket-devops-pull-requests-rest--pull-request-url
    context
    pull-request-id
    "comments")
   callback
   (bitbucket-devops-pull-requests-rest-comment-body text parent-id inline-location)
   nil
   context))

(defun bitbucket-devops-pull-requests-rest-get-comment
    (context pull-request-id comment-id callback)
  "Get COMMENT-ID from PULL-REQUEST-ID and invoke CALLBACK.
CONTEXT identifies the Bitbucket repository."
  (bitbucket-devops-rest-request
   "GET"
   (bitbucket-devops-pull-requests-rest--comment-url
    context pull-request-id comment-id)
   callback
   nil
   nil
   context))

(defun bitbucket-devops-pull-requests-rest-update-comment
    (context pull-request-id comment-id text callback)
  "Update COMMENT-ID on PULL-REQUEST-ID with TEXT.
CONTEXT identifies the Bitbucket repository."
  (bitbucket-devops-rest-request
   "PUT"
   (bitbucket-devops-pull-requests-rest--comment-url
    context pull-request-id comment-id)
   callback
   (bitbucket-devops-pull-requests-rest-comment-body text)
   nil
   context))

(defun bitbucket-devops-pull-requests-rest-delete-comment
    (context pull-request-id comment-id callback)
  "Delete COMMENT-ID from PULL-REQUEST-ID.
CONTEXT identifies the Bitbucket repository."
  (bitbucket-devops-rest-request
   "DELETE"
   (bitbucket-devops-pull-requests-rest--comment-url
    context pull-request-id comment-id)
   callback
   nil
   nil
   context))

(defun bitbucket-devops-pull-requests-rest-resolve-comment
    (context pull-request-id comment-id callback)
  "Resolve the thread rooted at COMMENT-ID on PULL-REQUEST-ID.
CONTEXT identifies the Bitbucket repository."
  (bitbucket-devops-rest-request
   "POST"
   (bitbucket-devops-pull-requests-rest--comment-url
    context pull-request-id comment-id "resolve")
   callback
   nil
   nil
   context))

(defun bitbucket-devops-pull-requests-rest-reopen-comment
    (context pull-request-id comment-id callback)
  "Reopen the thread rooted at COMMENT-ID on PULL-REQUEST-ID.
CONTEXT identifies the Bitbucket repository."
  (bitbucket-devops-rest-request
   "DELETE"
   (bitbucket-devops-pull-requests-rest--comment-url
    context pull-request-id comment-id "resolve")
   callback
   nil
   nil
   context))

(defun bitbucket-devops-pull-requests-rest-list-commits
    (context pull-request-id callback &optional next-url)
  "Asynchronously list commits for PULL-REQUEST-ID and invoke CALLBACK.
CONTEXT identifies the Bitbucket repository."
  (bitbucket-devops-rest-request
   "GET"
   (if next-url
       (bitbucket-devops-rest-validate-pagination-url next-url)
     (bitbucket-devops-pull-requests-rest--pull-request-url
      context
      pull-request-id
      "commits"))
   callback
   nil
   nil
   context))

(defun bitbucket-devops-pull-requests-rest-list-statuses
    (context pull-request-id callback &optional next-url)
  "Asynchronously list build statuses for PULL-REQUEST-ID and invoke CALLBACK.
CONTEXT identifies the Bitbucket repository."
  (bitbucket-devops-rest-request
   "GET"
   (if next-url
       (bitbucket-devops-rest-validate-pagination-url next-url)
     (bitbucket-devops-pull-requests-rest--pull-request-url
      context
      pull-request-id
      "statuses"))
   callback
   nil
   nil
   context))

(defun bitbucket-devops-pull-requests-rest-list-tasks
    (context pull-request-id callback &optional next-url)
  "Asynchronously list tasks for PULL-REQUEST-ID and invoke CALLBACK.
CONTEXT identifies the Bitbucket repository."
  (bitbucket-devops-rest-request
   "GET"
   (if next-url
       (bitbucket-devops-rest-validate-pagination-url next-url)
     (bitbucket-devops-pull-requests-rest--pull-request-url
      context
      pull-request-id
      "tasks"))
   callback
   nil
   nil
   context))

(defun bitbucket-devops-pull-requests-rest--task-url
    (context pull-request-id &optional task-id)
  "Return the task collection or TASK-ID URL for PULL-REQUEST-ID.
CONTEXT identifies the Bitbucket repository."
  (apply
   #'bitbucket-devops-pull-requests-rest--pull-request-url
   context
   pull-request-id
   "tasks"
   (when task-id (list (number-to-string task-id)))))

(defun bitbucket-devops-pull-requests-rest-task-body (&optional text state)
  "Return a Bitbucket task body containing optional TEXT and STATE."
  (when (and text
             (or (not (stringp text))
                 (string-empty-p (string-trim text))))
    (user-error "Pull request task text cannot be empty"))
  (when (and state (not (member state '("UNRESOLVED" "RESOLVED"))))
    (user-error "Unsupported pull request task state: %s" state))
  (unless (or text state)
    (user-error "A task update requires text or state"))
  (append
   (when text `((content . ((raw . ,(string-trim text))))))
   (when state `((state . ,state)))))

(defun bitbucket-devops-pull-requests-rest-create-task
    (context pull-request-id text callback)
  "Create a task with TEXT on PULL-REQUEST-ID.
CONTEXT identifies the Bitbucket repository."
  (bitbucket-devops-rest-request
   "POST"
   (bitbucket-devops-pull-requests-rest--task-url context pull-request-id)
   callback
   (bitbucket-devops-pull-requests-rest-task-body text)
   nil
   context))

(defun bitbucket-devops-pull-requests-rest-get-task
    (context pull-request-id task-id callback)
  "Get TASK-ID from PULL-REQUEST-ID and invoke CALLBACK.
CONTEXT identifies the Bitbucket repository."
  (bitbucket-devops-rest-request
   "GET"
   (bitbucket-devops-pull-requests-rest--task-url context pull-request-id task-id)
   callback
   nil
   nil
   context))

(defun bitbucket-devops-pull-requests-rest-update-task
    (context pull-request-id task-id callback &optional text state)
  "Update TASK-ID on PULL-REQUEST-ID with optional TEXT and STATE.
CONTEXT identifies the Bitbucket repository."
  (bitbucket-devops-rest-request
   "PUT"
   (bitbucket-devops-pull-requests-rest--task-url context pull-request-id task-id)
   callback
   (bitbucket-devops-pull-requests-rest-task-body text state)
   nil
   context))

(defun bitbucket-devops-pull-requests-rest-delete-task
    (context pull-request-id task-id callback)
  "Delete TASK-ID from PULL-REQUEST-ID.
CONTEXT identifies the Bitbucket repository."
  (bitbucket-devops-rest-request
   "DELETE"
   (bitbucket-devops-pull-requests-rest--task-url context pull-request-id task-id)
   callback
   nil
   nil
   context))

(defun bitbucket-devops-pull-requests-rest-get-diff
    (context pull-request-id callback)
  "Asynchronously get the raw diff for PULL-REQUEST-ID and invoke CALLBACK.
CONTEXT identifies the Bitbucket repository."
  (bitbucket-devops-rest-request
   "GET"
   (bitbucket-devops-pull-requests-rest--pull-request-url
    context
    pull-request-id
    "diff")
   callback
   nil
   t
   context))

(defun bitbucket-devops-pull-requests-rest-list-diffstat
    (context pull-request-id callback &optional next-url)
  "Asynchronously list diffstat for PULL-REQUEST-ID and invoke CALLBACK.
CONTEXT identifies the Bitbucket repository."
  (bitbucket-devops-rest-request
   "GET"
   (if next-url
       (bitbucket-devops-rest-validate-pagination-url next-url)
     (bitbucket-devops-pull-requests-rest--pull-request-url
      context
      pull-request-id
      "diffstat"))
   callback
   nil
   nil
   context))

(defun bitbucket-devops-pull-requests-rest-approve
    (context pull-request-id callback)
  "Approve PULL-REQUEST-ID as the current user.
CONTEXT identifies the Bitbucket repository."
  (bitbucket-devops-rest-request
   "POST"
   (bitbucket-devops-pull-requests-rest--pull-request-url
    context
    pull-request-id
    "approve")
   callback
   nil
   nil
   context))

(defun bitbucket-devops-pull-requests-rest-remove-approval
    (context pull-request-id callback)
  "Remove the current user's approval from PULL-REQUEST-ID.
CONTEXT identifies the Bitbucket repository."
  (bitbucket-devops-rest-request
   "DELETE"
   (bitbucket-devops-pull-requests-rest--pull-request-url
    context
    pull-request-id
    "approve")
   callback
   nil
   nil
   context))

(defun bitbucket-devops-pull-requests-rest-request-changes
    (context pull-request-id callback)
  "Request changes on PULL-REQUEST-ID as the current user.
CONTEXT identifies the Bitbucket repository."
  (bitbucket-devops-rest-request
   "POST"
   (bitbucket-devops-pull-requests-rest--pull-request-url
    context
    pull-request-id
    "request-changes")
   callback
   nil
   nil
   context))

(defun bitbucket-devops-pull-requests-rest-remove-request-changes
    (context pull-request-id callback)
  "Remove the current user's request-changes state from PULL-REQUEST-ID.
CONTEXT identifies the Bitbucket repository."
  (bitbucket-devops-rest-request
   "DELETE"
   (bitbucket-devops-pull-requests-rest--pull-request-url
    context
    pull-request-id
    "request-changes")
   callback
   nil
   nil
   context))

(defun bitbucket-devops-pull-requests-rest-decline
    (context pull-request-id callback)
  "Decline PULL-REQUEST-ID.
CONTEXT identifies the Bitbucket repository."
  (bitbucket-devops-rest-request
   "POST"
   (bitbucket-devops-pull-requests-rest--pull-request-url
    context
    pull-request-id
    "decline")
   callback
   nil
   nil
   context))

(defun bitbucket-devops-pull-requests-rest-merge-body
    (strategy message close-source-branch)
  "Return a merge body using STRATEGY, MESSAGE, and CLOSE-SOURCE-BRANCH."
  (unless (member strategy bitbucket-devops-pull-requests-rest-merge-strategies)
    (user-error "Unsupported Bitbucket pull request merge strategy: %s"
                strategy))
  (setq message (string-trim (or message "")))
  (append
   `((type . "pullrequest")
     (merge_strategy . ,strategy)
     (close_source_branch . ,(if close-source-branch t :false)))
   (unless (string-empty-p message)
     `((message . ,message)))))

(defun bitbucket-devops-pull-requests-rest-merge
    (context pull-request-id body callback)
  "Merge PULL-REQUEST-ID in CONTEXT using BODY and invoke CALLBACK."
  (bitbucket-devops-rest-request
   "POST"
   (bitbucket-devops-pull-requests-rest--append-query
    (bitbucket-devops-pull-requests-rest--pull-request-url
     context
     pull-request-id
     "merge")
    "async=false")
   callback
   body
   nil
   context))

(provide 'bitbucket-devops-pull-requests-rest)
;;; bitbucket-devops-pull-requests-rest.el ends here
