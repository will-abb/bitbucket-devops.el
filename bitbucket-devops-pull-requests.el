;;; bitbucket-devops-pull-requests.el --- Bitbucket Cloud Pull Requests -*- lexical-binding: t; -*-

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

;; Shared read-model helpers for Bitbucket Cloud pull requests.

;;; Code:

(require 'seq)
(require 'subr-x)

(defgroup bitbucket-devops-pull-requests nil
  "Work with Bitbucket Cloud pull requests."
  :group 'bitbucket-devops
  :prefix "bitbucket-devops-pull-requests-")

(defun bitbucket-devops-pull-requests--nested-get (object &rest keys)
  "Return the value reached by following KEYS through alist OBJECT."
  (dolist (key keys object)
    (setq object
          (when (proper-list-p object)
            (alist-get key object)))))

(defun bitbucket-devops-pull-requests--string (value)
  "Return VALUE as a displayable string."
  (cond
   ((stringp value) value)
   ((null value) "")
   (t (format "%s" value))))

(defun bitbucket-devops-pull-requests--user-display-name (user)
  "Return a concise display name for Bitbucket USER."
  (or (alist-get 'display_name user)
      (alist-get 'nickname user)
      (alist-get 'username user)
      (bitbucket-devops-pull-requests--nested-get user 'account_id)
      "Unknown"))

(defun bitbucket-devops-pull-requests--branch-name (branch)
  "Return Bitbucket BRANCH object's name."
  (or (alist-get 'name branch) ""))

(defun bitbucket-devops-pull-requests-source-branch (pull-request)
  "Return PULL-REQUEST's source branch name."
  (bitbucket-devops-pull-requests--branch-name
   (bitbucket-devops-pull-requests--nested-get pull-request 'source 'branch)))

(defun bitbucket-devops-pull-requests-destination-branch (pull-request)
  "Return PULL-REQUEST's destination branch name."
  (bitbucket-devops-pull-requests--branch-name
   (bitbucket-devops-pull-requests--nested-get pull-request 'destination 'branch)))

(defun bitbucket-devops-pull-requests-author-name (pull-request)
  "Return PULL-REQUEST's author display name."
  (bitbucket-devops-pull-requests--user-display-name
   (alist-get 'author pull-request)))

(defun bitbucket-devops-pull-requests-reviewers (pull-request)
  "Return PULL-REQUEST reviewers."
  (or (alist-get 'reviewers pull-request) nil))

(defun bitbucket-devops-pull-requests-participants (pull-request)
  "Return PULL-REQUEST participants."
  (or (alist-get 'participants pull-request) nil))

(defun bitbucket-devops-pull-requests-reviewer-names (pull-request)
  "Return reviewer display names for PULL-REQUEST."
  (mapcar
   #'bitbucket-devops-pull-requests--user-display-name
   (bitbucket-devops-pull-requests-reviewers pull-request)))

(defun bitbucket-devops-pull-requests--participant-approved-p (participant)
  "Return non-nil when PARTICIPANT has approved."
  (eq (alist-get 'approved participant) t))

(defun bitbucket-devops-pull-requests-approved-participants (pull-request)
  "Return approving participants for PULL-REQUEST."
  (seq-filter
   #'bitbucket-devops-pull-requests--participant-approved-p
   (bitbucket-devops-pull-requests-participants pull-request)))

(defun bitbucket-devops-pull-requests-approved-names (pull-request)
  "Return display names for participants who approved PULL-REQUEST."
  (mapcar
   (lambda (participant)
     (bitbucket-devops-pull-requests--user-display-name
      (alist-get 'user participant)))
   (bitbucket-devops-pull-requests-approved-participants pull-request)))

(defun bitbucket-devops-pull-requests-approval-count (pull-request)
  "Return the number of approvals on PULL-REQUEST."
  (length (bitbucket-devops-pull-requests-approved-participants pull-request)))

(defun bitbucket-devops-pull-requests-reviewer-count (pull-request)
  "Return the number of reviewers on PULL-REQUEST."
  (length (bitbucket-devops-pull-requests-reviewers pull-request)))

(defun bitbucket-devops-pull-requests-review-summary (pull-request)
  "Return a review summary plist for PULL-REQUEST."
  (list
   :reviewer-count (bitbucket-devops-pull-requests-reviewer-count pull-request)
   :approval-count (bitbucket-devops-pull-requests-approval-count pull-request)
   :reviewers (bitbucket-devops-pull-requests-reviewer-names pull-request)
   :approved-by (bitbucket-devops-pull-requests-approved-names pull-request)))

(defun bitbucket-devops-pull-requests--page-values (page-or-values)
  "Return values from Bitbucket PAGE-OR-VALUES."
  (if (and (listp page-or-values)
           (assq 'values page-or-values))
      (or (alist-get 'values page-or-values) nil)
    page-or-values))

(defun bitbucket-devops-pull-requests--status-state (status)
  "Return normalized state for Bitbucket build STATUS."
  (upcase
   (bitbucket-devops-pull-requests--string
    (or (alist-get 'state status)
        (alist-get 'name status)))))

(defun bitbucket-devops-pull-requests-status-summary (page-or-statuses)
  "Return a build/status summary plist for PAGE-OR-STATUSES."
  (let ((passed 0)
        (failed 0)
        (in-progress 0)
        (stopped 0)
        (unknown 0))
    (dolist (status (bitbucket-devops-pull-requests--page-values page-or-statuses))
      (pcase (bitbucket-devops-pull-requests--status-state status)
        ((or "SUCCESSFUL" "SUCCESS") (setq passed (1+ passed)))
        ((or "FAILED" "FAILURE" "ERROR") (setq failed (1+ failed)))
        ((or "INPROGRESS" "IN_PROGRESS" "PENDING") (setq in-progress (1+ in-progress)))
        ("STOPPED" (setq stopped (1+ stopped)))
        (_ (setq unknown (1+ unknown)))))
    (list
     :total (+ passed failed in-progress stopped unknown)
     :passed passed
     :failed failed
     :in-progress in-progress
     :stopped stopped
     :unknown unknown)))

(defun bitbucket-devops-pull-requests--task-resolved-p (task)
  "Return non-nil when TASK is resolved."
  (let ((state
         (upcase
          (bitbucket-devops-pull-requests--string
           (or (alist-get 'state task)
               (alist-get 'status task))))))
    (or (eq (alist-get 'resolved task) t)
        (member state '("RESOLVED" "DONE" "COMPLETED" "COMPLETE" "CLOSED")))))

(defun bitbucket-devops-pull-requests-task-text (task)
  "Return TASK's plain-text content."
  (bitbucket-devops-pull-requests--string
   (or (bitbucket-devops-pull-requests--nested-get task 'content 'raw)
       (alist-get 'content task))))

(defun bitbucket-devops-pull-requests-task-summary (page-or-tasks)
  "Return a task summary plist for PAGE-OR-TASKS."
  (let ((resolved 0)
        (unresolved 0))
    (dolist (task (bitbucket-devops-pull-requests--page-values page-or-tasks))
      (if (bitbucket-devops-pull-requests--task-resolved-p task)
          (setq resolved (1+ resolved))
        (setq unresolved (1+ unresolved))))
    (list :total (+ resolved unresolved)
          :resolved resolved
          :unresolved unresolved)))

(defun bitbucket-devops-pull-requests-comment-reply-p (comment)
  "Return non-nil when COMMENT is a reply to another comment."
  (alist-get 'parent comment))

(defun bitbucket-devops-pull-requests-comment-resolved-p (comment)
  "Return non-nil when COMMENT's thread is resolved."
  (alist-get 'resolution comment))

(defun bitbucket-devops-pull-requests-comment-author-name (comment)
  "Return COMMENT author display name."
  (bitbucket-devops-pull-requests--user-display-name
   (alist-get 'user comment)))

(defun bitbucket-devops-pull-requests-comment-text (comment)
  "Return COMMENT text content."
  (or (bitbucket-devops-pull-requests--nested-get comment 'content 'raw)
      (bitbucket-devops-pull-requests--nested-get comment 'content 'html)
      ""))

(defun bitbucket-devops-pull-requests-comment-summary (page-or-comments)
  "Return a comment summary plist for PAGE-OR-COMMENTS."
  (let ((comments 0)
        (replies 0)
        (deleted 0))
    (dolist (comment (bitbucket-devops-pull-requests--page-values page-or-comments))
      (cond
       ((alist-get 'deleted comment) (setq deleted (1+ deleted)))
       ((bitbucket-devops-pull-requests-comment-reply-p comment)
        (setq replies (1+ replies)))
       (t (setq comments (1+ comments)))))
    (list :total (+ comments replies deleted)
          :comments comments
          :replies replies
          :deleted deleted)))

(defun bitbucket-devops-pull-requests-diffstat-summary (page-or-diffstat)
  "Return a changed-file summary plist for PAGE-OR-DIFFSTAT."
  (let ((added 0)
        (removed 0)
        (modified 0)
        (renamed 0)
        (lines-added 0)
        (lines-removed 0))
    (dolist (entry (bitbucket-devops-pull-requests--page-values page-or-diffstat))
      (setq lines-added (+ lines-added (or (alist-get 'lines_added entry) 0)))
      (setq lines-removed (+ lines-removed (or (alist-get 'lines_removed entry) 0)))
      (pcase (alist-get 'status entry)
        ("added" (setq added (1+ added)))
        ("removed" (setq removed (1+ removed)))
        ("renamed" (setq renamed (1+ renamed)))
        (_ (setq modified (1+ modified)))))
    (list :files (+ added removed modified renamed)
          :added added
          :removed removed
          :modified modified
          :renamed renamed
          :lines-added lines-added
          :lines-removed lines-removed)))

(defun bitbucket-devops-pull-requests-summary (pull-request)
  "Return a normalized summary plist for PULL-REQUEST."
  (let ((review-summary
         (bitbucket-devops-pull-requests-review-summary pull-request)))
    (append
     (list
      :id (alist-get 'id pull-request)
      :title (or (alist-get 'title pull-request) "")
      :state (or (alist-get 'state pull-request) "UNKNOWN")
      :draft (eq (alist-get 'draft pull-request) t)
      :author (bitbucket-devops-pull-requests-author-name pull-request)
      :source-branch (bitbucket-devops-pull-requests-source-branch pull-request)
      :destination-branch
      (bitbucket-devops-pull-requests-destination-branch pull-request)
      :created-on (alist-get 'created_on pull-request)
      :updated-on (alist-get 'updated_on pull-request))
     review-summary)))

(provide 'bitbucket-devops-pull-requests)
;;; bitbucket-devops-pull-requests.el ends here
