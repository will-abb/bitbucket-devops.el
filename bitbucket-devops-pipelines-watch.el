;;; bitbucket-devops-pipelines-watch.el --- Watch Bitbucket Cloud Pipelines -*- lexical-binding: t; -*-

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

;; Poll Bitbucket Cloud pipeline state without blocking Emacs.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'bitbucket-devops-cache)
(require 'bitbucket-devops-context)
(require 'bitbucket-devops-rest)
(require 'bitbucket-devops-ui)
(require 'bitbucket-devops-pull-requests-watch)

(declare-function alert "ext:alert" (message &rest args))
(declare-function notifications-notify "notifications" (&rest params))
(declare-function evil-define-key* "ext:evil-core"
                  (state keymap key def &rest bindings))
(declare-function bitbucket-devops-pipelines-toggle-magit-push-watch "bitbucket-devops")
(defvar bitbucket-devops-pipelines-magit-push-watch-mode)

(defcustom bitbucket-devops-pipelines-poll-interval 15
  "Seconds between successful Bitbucket pipeline watcher polls."
  :type 'number
  :group 'bitbucket-devops-pipelines)

(defcustom bitbucket-devops-pipelines-branch-poll-interval 30
  "Seconds between successful persistent branch subscription polls."
  :type 'number
  :group 'bitbucket-devops-pipelines)

(defcustom bitbucket-devops-pipelines-discovery-timeout 300
  "Maximum seconds to wait for a pushed commit pipeline to appear."
  :type 'number
  :group 'bitbucket-devops-pipelines)

(defcustom bitbucket-devops-pipelines-backoff-initial-delay 5
  "Initial watcher retry delay after a transient Bitbucket failure."
  :type 'number
  :group 'bitbucket-devops-pipelines)

(defcustom bitbucket-devops-pipelines-backoff-maximum-delay 120
  "Maximum watcher retry delay after transient Bitbucket failures."
  :type 'number
  :group 'bitbucket-devops-pipelines)

(defcustom bitbucket-devops-pipelines-backoff-maximum-retries 5
  "Maximum watcher retries after transient Bitbucket failures."
  :type 'integer
  :group 'bitbucket-devops-pipelines)

(defcustom bitbucket-devops-pipelines-notification-function nil
  "Optional function used to display watcher notification messages.

The function receives one string argument.  When nil, use `alert.el' when it
is installed, then try built-in desktop notifications in graphical Emacs, and
fall back to `message' otherwise."
  :type '(choice
          (const :tag "Use alert.el when available, otherwise message" nil)
          (function :tag "Notification function"))
  :group 'bitbucket-devops-pipelines)

(defcustom bitbucket-devops-pipelines-notification-title "Bitbucket Pipelines"
  "Title used for built-in watcher notifications."
  :type 'string
  :group 'bitbucket-devops-pipelines)

(defcustom bitbucket-devops-pipelines-watch-mode-line-enabled t
  "Whether active Bitbucket pipeline watchers appear in the mode line."
  :type 'boolean
  :group 'bitbucket-devops-pipelines)

(defcustom bitbucket-devops-pipelines-watch-list-column-widths
  '((repository . 52)
    (branch . 16)
    (commit . 12)
    (state . 14)
    (result . 10))
  "Column widths used by the active Bitbucket watcher list buffer."
  :type '(alist :key-type symbol :value-type integer)
  :group 'bitbucket-devops-pipelines)

;; `:noinline' keeps `cl-defstruct' from generating a compiler macro per
;; accessor.  Those carry an auto-built docstring that exceeds 80 columns
;; whenever the accessor name is long, and it cannot be shortened from here.
(cl-defstruct
    (bitbucket-devops-pipelines-watch--record
     (:constructor bitbucket-devops-pipelines-watch--make-record)
     (:conc-name bitbucket-devops-pipelines-watch--r-)
     (:noinline t))
  key
  kind
  context
  pipeline-uuid
  commit
  branch
  state
  result
  timer
  (failures 0)
  discovery-started-at
  last-notification
  seen-pipeline-uuids
  initialized)

(defvar bitbucket-devops-pipelines-watch--records
  (make-hash-table :test #'equal)
  "Active Bitbucket pipeline watcher records keyed by captured identity.")

(defconst bitbucket-devops-pipelines-watch--list-buffer-name
  "*Bitbucket Watchers*"
  "Buffer name used to display active Bitbucket watchers.")

(defvar bitbucket-devops-pipelines-watch-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "m") #'bitbucket-devops-pipelines-watch-toggle-push-tracking)
    (define-key map (kbd "x") #'bitbucket-devops-pipelines-stop-watching-at-point)
    (define-key map (kbd "-") #'bitbucket-devops-ui-back)
    (define-key map (kbd "q") #'bitbucket-devops-ui-quit)
    (define-key map (kbd "?") #'bitbucket-devops-ui-show-command-panel)
    map)
  "Keymap used by `bitbucket-devops-pipelines-watch-list-mode'.")

(defun bitbucket-devops-pipelines-watch--install-evil-bindings ()
  "Install Evil normal-state bindings for the watcher list."
  (evil-define-key*
   'normal
   bitbucket-devops-pipelines-watch-list-mode-map
   (kbd "m") #'bitbucket-devops-pipelines-watch-toggle-push-tracking
   (kbd "x") #'bitbucket-devops-pipelines-stop-watching-at-point
   (kbd "-") #'bitbucket-devops-ui-back
   (kbd "q") #'bitbucket-devops-ui-quit
   (kbd "?") #'bitbucket-devops-ui-show-command-panel))

(defvar bitbucket-devops-pipelines-watch--evil-bindings-installed nil
  "Non-nil once Evil bindings for the watcher list have been installed.")

(defun bitbucket-devops-pipelines-watch-install-evil-bindings ()
  "Install Evil bindings for the watcher list when Evil is loaded.

Does nothing when Evil is absent, and installs at most once.  The watcher
mode invokes this function when it starts, so Evil only has to be loaded by
the time the list is first opened."
  (when (and (featurep 'evil)
             (not bitbucket-devops-pipelines-watch--evil-bindings-installed))
    (setq bitbucket-devops-pipelines-watch--evil-bindings-installed t)
    (bitbucket-devops-pipelines-watch--install-evil-bindings)))

(define-derived-mode bitbucket-devops-pipelines-watch-list-mode special-mode
  "Bitbucket-Watchers"
  "Major mode used to display active Bitbucket watchers."
  (bitbucket-devops-pipelines-watch-install-evil-bindings))

(defvar bitbucket-devops-pipelines-watch-mode-line
  '(:eval (bitbucket-devops-pipelines-watch-mode-line-string))
  "Mode-line entry displayed while Bitbucket pipeline watchers are active.")

(defvar bitbucket-devops-pipelines-watch-mode-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1]
                #'bitbucket-devops-pipelines-list-watchers)
    map)
  "Keymap for the Bitbucket pipeline watcher mode-line entry.")

(defun bitbucket-devops-pipelines-watch-active-count ()
  "Return the number of active Bitbucket pipeline watchers."
  (hash-table-count bitbucket-devops-pipelines-watch--records))

(defun bitbucket-devops-pipelines-watch-mode-line-string ()
  "Return the aggregate watcher mode-line text."
  (let ((count (bitbucket-devops-pipelines-watch-active-count)))
    (when (> count 0)
      (propertize
       (format " BB[%d]" count)
       'help-echo "mouse-1: list active Bitbucket watchers"
       'local-map bitbucket-devops-pipelines-watch-mode-line-map
       'mouse-face 'mode-line-highlight))))

(defun bitbucket-devops-pipelines-watch--column-width (column default)
  "Return configured watcher-list COLUMN width, falling back to DEFAULT."
  (let ((value
         (alist-get column bitbucket-devops-pipelines-watch-list-column-widths)))
    (if (and (integerp value) (>= value 0))
        value
      default)))

(defun bitbucket-devops-pipelines-watch--short-commit (commit)
  "Return a concise display value for COMMIT."
  (if (and commit (> (length commit) 12))
      (substring commit 0 12)
    (or commit "")))

(defun bitbucket-devops-pipelines-watch--sorted-records ()
  "Return active watcher records sorted by repository identity."
  (let (records)
    (maphash
     (lambda (_key record)
       (push record records))
     bitbucket-devops-pipelines-watch--records)
    (sort records
          (lambda (left right)
            (string-lessp
             (bitbucket-devops-pipelines-watch--r-key left)
             (bitbucket-devops-pipelines-watch--r-key right))))))

(defun bitbucket-devops-pipelines-watch--push-tracking-enabled-p ()
  "Return non-nil when automatic Magit push tracking is enabled."
  (bound-and-true-p bitbucket-devops-pipelines-magit-push-watch-mode))

(defun bitbucket-devops-pipelines-watch--push-tracking-label ()
  "Return a display label for automatic Magit push tracking."
  (if (bitbucket-devops-pipelines-watch--push-tracking-enabled-p)
      "ENABLED"
    "DISABLED"))

(defun bitbucket-devops-pipelines-watch--fit (value width)
  "Return VALUE truncated to WIDTH display columns."
  (truncate-string-to-width (or value "") width nil nil "..."))

(defun bitbucket-devops-pipelines-watch--format-duration (seconds)
  "Return a compact duration label for SECONDS."
  (setq seconds (max 0 (floor (or seconds 0))))
  (cond
   ((< seconds 60)
    (format "%ds" seconds))
   ((< seconds 3600)
    (format "%dm" (/ seconds 60)))
   ((< seconds 86400)
    (format "%dh %dm" (/ seconds 3600) (/ (% seconds 3600) 60)))
   (t
    (format "%dd %dh" (/ seconds 86400) (/ (% seconds 86400) 3600)))))

(defun bitbucket-devops-pipelines-watch--repository-label (context)
  "Return a workspace/repository label for CONTEXT."
  (format "%s/%s"
          (plist-get context :workspace)
          (plist-get context :repo-slug)))

(defun bitbucket-devops-pipelines-watch--pipeline-type-label (record)
  "Return a clear watcher type label for pipeline RECORD."
  (pcase (bitbucket-devops-pipelines-watch--r-kind record)
    ('branch "branch pipeline subscription")
    ('repository "repository pipeline subscription")
    ('commit "pipeline run discovery")
    (_ "pipeline run")))

(defun bitbucket-devops-pipelines-watch--pipeline-target-label (record)
  "Return the target label for pipeline RECORD."
  (pcase (bitbucket-devops-pipelines-watch--r-kind record)
    ('branch
     (format "branch:%s"
             (or (bitbucket-devops-pipelines-watch--r-branch record) "")))
    ('repository "all branches")
    ('commit
     (if-let ((pipeline-uuid
               (bitbucket-devops-pipelines-watch--r-pipeline-uuid record)))
         pipeline-uuid
       (format "commit:%s"
               (bitbucket-devops-pipelines-watch--short-commit
                (bitbucket-devops-pipelines-watch--r-commit record)))))
    (_
     (or (bitbucket-devops-pipelines-watch--r-pipeline-uuid record) ""))))

(defun bitbucket-devops-pipelines-watch--pipeline-poll-label (record)
  "Return a poll interval label for pipeline RECORD."
  (format
   "%ss"
   (if (memq (bitbucket-devops-pipelines-watch--r-kind record)
             '(branch repository))
       bitbucket-devops-pipelines-branch-poll-interval
     bitbucket-devops-pipelines-poll-interval)))

(defun bitbucket-devops-pipelines-watch--pipeline-next-label (record)
  "Return the next behavior label for pipeline RECORD."
  (pcase (bitbucket-devops-pipelines-watch--r-kind record)
    ('branch "watch branch")
    ('repository "watch repository")
    ('commit
     (if (bitbucket-devops-pipelines-watch--r-pipeline-uuid record)
         "poll until terminal"
       "discover run"))
    (_ "poll until terminal")))

(defun bitbucket-devops-pipelines-watch--pipeline-age-label (record)
  "Return an age label for pipeline RECORD when applicable."
  (if-let ((started
            (bitbucket-devops-pipelines-watch--r-discovery-started-at record)))
      (bitbucket-devops-pipelines-watch--format-duration
       (- (float-time) started))
    ""))

(defun bitbucket-devops-pipelines-watch--pipeline-status-label (record)
  "Return an active/error status label for pipeline RECORD."
  (let ((failures (bitbucket-devops-pipelines-watch--r-failures record)))
    (if (> failures 0)
        (format "error retry %d" failures)
      "active")))

(defun bitbucket-devops-pipelines-watch--pr-target-label (record)
  "Return the target label for pull request comment watcher RECORD."
  (format
   "#%s%s"
   (bitbucket-devops-pull-requests-watch--r-pull-request-id record)
   (if-let ((title
             (bitbucket-devops-pull-requests-watch--r-title record)))
       (format " %s" title)
     "")))

(defun bitbucket-devops-pipelines-watch--pr-age-timeout-label (record)
  "Return an age and timeout label for pull request watcher RECORD."
  (let ((age
         (bitbucket-devops-pipelines-watch--format-duration
          (bitbucket-devops-pull-requests-watch--record-age record))))
    (if-let ((max-age
              (bitbucket-devops-pull-requests-watch--active-max-age)))
        (format "%s/%s"
                age
                (bitbucket-devops-pipelines-watch--format-duration max-age))
      age)))

(defun bitbucket-devops-pipelines-watch--pr-status-label (record)
  "Return an active/error status label for pull request watcher RECORD."
  (if-let ((error
            (bitbucket-devops-pull-requests-watch--r-last-error record)))
      (format
       "error retry %d: %s"
       (bitbucket-devops-pull-requests-watch--r-failures record)
       error)
    "active"))

(defun bitbucket-devops-pipelines-watch-toggle-push-tracking ()
  "Toggle automatic Magit push tracking and refresh the watcher list."
  (interactive)
  (unless (fboundp 'bitbucket-devops-pipelines-toggle-magit-push-watch)
    (user-error "Bitbucket Pipelines dispatch is not loaded"))
  (bitbucket-devops-pipelines-toggle-magit-push-watch)
  (bitbucket-devops-pipelines-watch--render-list-buffer))

(defun bitbucket-devops-pipelines-watch--render-list-buffer ()
  "Refresh the watcher list buffer when it exists."
  (when-let ((buffer
              (get-buffer bitbucket-devops-pipelines-watch--list-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'bitbucket-devops-pipelines-watch-list-mode)
        (bitbucket-devops-pipelines-watch-list-mode))
      (let ((old-point (point))
            (selected-key
             (get-text-property
              (point)
              'bitbucket-devops-watcher-key))
            (inhibit-read-only t)
            (pipeline-records
             (bitbucket-devops-pipelines-watch--sorted-records))
            (pr-records
             (bitbucket-devops-pull-requests-watch--sorted-records)))
        (erase-buffer)
        (insert
         (propertize "Automatic Tracking"
                     'face 'bitbucket-devops-command-panel-heading-face)
         "\n"
         "Magit push tracking: "
         (propertize
          (bitbucket-devops-pipelines-watch--push-tracking-label)
          'face (if (bitbucket-devops-pipelines-watch--push-tracking-enabled-p)
                    'bitbucket-devops-pipelines-success-face
                  'bitbucket-devops-pipelines-secondary-face))
         "\n"
         "When enabled, successful Magit branch pushes start pipeline watching for the pushed commit.\n\n"
         (propertize "Active Bitbucket Watchers"
                     'face 'bitbucket-devops-command-panel-heading-face)
         (propertize
          (format
           "  [%d]\n\n"
           (+ (length pipeline-records) (length pr-records)))
          'face 'bitbucket-devops-pipelines-secondary-face))
        (if (or pipeline-records pr-records)
            (let* ((type-width
                    (bitbucket-devops-pipelines-watch--column-width 'type 32))
                   (repository-width
                    (bitbucket-devops-pipelines-watch--column-width
                     'repository
                     32))
                   (target-width
                    (bitbucket-devops-pipelines-watch--column-width 'target 34))
                   (state-width
                    (bitbucket-devops-pipelines-watch--column-width 'state 14))
                   (age-width
                    (bitbucket-devops-pipelines-watch--column-width 'age 14))
                   (poll-width
                    (bitbucket-devops-pipelines-watch--column-width 'poll 8))
                   (next-width
                    (bitbucket-devops-pipelines-watch--column-width 'next 20))
                   (status-width
                    (bitbucket-devops-pipelines-watch--column-width 'status 18))
                   (format-string
                    (format "%%-%ds %%-%ds %%-%ds %%-%ds %%-%ds %%-%ds %%-%ds %%-%ds\n"
                            type-width
                            repository-width
                            target-width
                            state-width
                            age-width
                            poll-width
                            next-width
                            status-width))
                   (divider-width
                    (+ type-width repository-width target-width state-width
                       age-width poll-width next-width status-width 7)))
              (insert
               (propertize
                (format
                 format-string
                 "Type"
                 "Repository"
                 "Target"
                 "State"
                 "Age/Timeout"
                 "Poll"
                 "Next"
                 "Status")
                'face 'bold))
              (insert
               (propertize (make-string divider-width ?─) 'face 'shadow)
               "\n")
              (dolist (record pipeline-records)
                (let* ((state (or (bitbucket-devops-pipelines-watch--r-state record)
                                  "DISCOVERING"))
                       (result (or (bitbucket-devops-pipelines-watch--r-result record)
                                   ""))
                       (state-label
                        (if (string-empty-p result)
                            state
                          (format "%s/%s" state result)))
                       (state-face
                        (bitbucket-devops-ui--state-face
                         (if (string= state "DISCOVERING") result state)))
                       (key (bitbucket-devops-pipelines-watch--r-key record))
                       (line-start (point)))
                  (insert
                   (format
                    format-string
                    (bitbucket-devops-pipelines-watch--fit
                     (bitbucket-devops-pipelines-watch--pipeline-type-label record)
                     type-width)
                    (bitbucket-devops-pipelines-watch--fit
                     (bitbucket-devops-pipelines-watch--repository-label
                      (bitbucket-devops-pipelines-watch--r-context record))
                     repository-width)
                    (bitbucket-devops-pipelines-watch--fit
                     (bitbucket-devops-pipelines-watch--pipeline-target-label record)
                     target-width)
                    (bitbucket-devops-pipelines-watch--fit state-label state-width)
                    (bitbucket-devops-pipelines-watch--fit
                     (bitbucket-devops-pipelines-watch--pipeline-age-label record)
                     age-width)
                    (bitbucket-devops-pipelines-watch--fit
                     (bitbucket-devops-pipelines-watch--pipeline-poll-label record)
                     poll-width)
                    (bitbucket-devops-pipelines-watch--fit
                     (bitbucket-devops-pipelines-watch--pipeline-next-label record)
                     next-width)
                    (bitbucket-devops-pipelines-watch--fit
                     (bitbucket-devops-pipelines-watch--pipeline-status-label record)
                     status-width)))
                  (put-text-property line-start (point) 'face state-face)
                  (put-text-property
                   line-start (point) 'bitbucket-devops-watcher-key key)
                  (put-text-property
                   line-start (point) 'bitbucket-devops-watcher-type 'pipeline)
                  (put-text-property
                   line-start (point)
                   'bitbucket-devops-pipelines-watcher-key
                   key)))
              (dolist (record pr-records)
                (let* ((key
                        (bitbucket-devops-pull-requests-watch--r-key record))
                       (state
                        (or (bitbucket-devops-pull-requests-watch--r-state record)
                            "UNKNOWN"))
                       (line-start (point)))
                  (insert
                   (format
                    format-string
                    (bitbucket-devops-pipelines-watch--fit
                     "PR comment watcher"
                     type-width)
                    (bitbucket-devops-pipelines-watch--fit
                     (bitbucket-devops-pipelines-watch--repository-label
                      (bitbucket-devops-pull-requests-watch--r-context record))
                     repository-width)
                    (bitbucket-devops-pipelines-watch--fit
                     (bitbucket-devops-pipelines-watch--pr-target-label record)
                     target-width)
                    (bitbucket-devops-pipelines-watch--fit state state-width)
                    (bitbucket-devops-pipelines-watch--fit
                     (bitbucket-devops-pipelines-watch--pr-age-timeout-label record)
                     age-width)
                    (bitbucket-devops-pipelines-watch--fit
                     (format
                      "%ss"
                      bitbucket-devops-pull-requests-comments-poll-interval)
                     poll-width)
                    (bitbucket-devops-pipelines-watch--fit
                     "poll comments"
                     next-width)
                    (bitbucket-devops-pipelines-watch--fit
                     (bitbucket-devops-pipelines-watch--pr-status-label record)
                     status-width)))
                  (put-text-property
                   line-start (point) 'bitbucket-devops-watcher-key key)
                  (put-text-property
                   line-start (point)
                   'bitbucket-devops-watcher-type
                   'pull-request-comments)
                  (put-text-property
                   line-start (point)
                   'bitbucket-devops-pull-request-comments-watcher-key
                   key))))
          (insert
           (propertize "No active Bitbucket watchers.\n\n" 'face 'shadow)
           "Pipeline run watchers are removed automatically when their pipeline reaches a terminal state.\n"
           "Branch and repository pipeline subscriptions keep watching until stopped.\n"
           "PR comment watchers baseline existing comments on their first poll, then stop when the PR leaves OPEN or expires.\n"))
        (insert "\n"
                (propertize "m" 'face 'bitbucket-devops-command-panel-key-face)
                " toggle Magit push pipeline watching  "
                (propertize "x" 'face 'bitbucket-devops-command-panel-key-face)
                " stop selected watcher  "
                (propertize "q" 'face 'bitbucket-devops-command-panel-key-face)
                " quit\n")
        (goto-char (point-min))
        (if-let ((match
                  (and selected-key
                       (text-property-search-forward
                        'bitbucket-devops-watcher-key
                        selected-key
                        t))))
            (goto-char (prop-match-beginning match))
          (goto-char (min old-point (point-max))))))))

(defun bitbucket-devops-pipelines-watch--update-mode-line ()
  "Add or remove the aggregate watcher mode-line entry."
  (if (and bitbucket-devops-pipelines-watch-mode-line-enabled
           (> (bitbucket-devops-pipelines-watch-active-count) 0))
      (unless (memq 'bitbucket-devops-pipelines-watch-mode-line global-mode-string)
        (setq global-mode-string
              (append global-mode-string
                      '(bitbucket-devops-pipelines-watch-mode-line))))
    (setq global-mode-string
          (delq 'bitbucket-devops-pipelines-watch-mode-line global-mode-string)))
  (bitbucket-devops-pipelines-watch--render-list-buffer)
  (force-mode-line-update t))

(defun bitbucket-devops-pipelines-watch--make-key (context &optional pipeline-uuid commit)
  "Return a watcher key for CONTEXT and PIPELINE-UUID or COMMIT."
  (format "%s/%s:%s"
          (plist-get context :workspace)
          (plist-get context :repo-slug)
          (if pipeline-uuid
              (concat "pipeline:" pipeline-uuid)
            (concat "commit:" commit))))

(defun bitbucket-devops-pipelines-watch--make-branch-key (context branch)
  "Return a persistent branch subscription key for CONTEXT and BRANCH."
  (format "%s/%s:branch:%s"
          (plist-get context :workspace)
          (plist-get context :repo-slug)
          branch))

(defun bitbucket-devops-pipelines-watch--make-repository-key (context)
  "Return a persistent repository subscription key for CONTEXT."
  (format "%s/%s:repository"
          (plist-get context :workspace)
          (plist-get context :repo-slug)))

(defun bitbucket-devops-pipelines-watch--pipeline-state (pipeline)
  "Return PIPELINE's user-facing state name."
  (let* ((state (alist-get 'state pipeline))
         (name (alist-get 'name state))
         (result (alist-get 'name (alist-get 'result state)))
         (stage (alist-get 'name (alist-get 'stage state))))
    (cond
     ((member result '("PAUSED" "HALTED")) result)
     ((member stage '("PAUSED" "HALTED")) stage)
     (t name))))

(defun bitbucket-devops-pipelines-watch--pipeline-result (pipeline)
  "Return PIPELINE's terminal result name, or nil."
  (let ((state (alist-get 'state pipeline)))
    (when (equal (alist-get 'name state) "COMPLETED")
      (alist-get 'name (alist-get 'result state)))))

(defun bitbucket-devops-pipelines-watch--pipeline-terminal-p (pipeline)
  "Return non-nil when PIPELINE has reached a terminal state."
  (equal
   (alist-get 'name (alist-get 'state pipeline))
   "COMPLETED"))

(defun bitbucket-devops-pipelines-watch--retry-delay (failures)
  "Return bounded exponential retry delay for FAILURES."
  (min bitbucket-devops-pipelines-backoff-maximum-delay
       (* bitbucket-devops-pipelines-backoff-initial-delay
          (expt 2 (max 0 (1- failures))))))

(defun bitbucket-devops-pipelines-watch--cancel-timer (record)
  "Cancel RECORD's timer when present."
  (when-let ((timer (bitbucket-devops-pipelines-watch--r-timer record)))
    (cancel-timer timer)
    (setf (bitbucket-devops-pipelines-watch--r-timer record) nil)))

(defun bitbucket-devops-pipelines-watch--remove (key)
  "Stop and remove the watcher identified by KEY."
  (when-let ((record (gethash key bitbucket-devops-pipelines-watch--records)))
    (bitbucket-devops-pipelines-watch--cancel-timer record)
    (remhash key bitbucket-devops-pipelines-watch--records)
    (bitbucket-devops-pipelines-watch--update-mode-line)))

(defun bitbucket-devops-pipelines-watch--schedule (record delay)
  "Schedule RECORD to poll after DELAY seconds."
  (bitbucket-devops-pipelines-watch--cancel-timer record)
  (setf
   (bitbucket-devops-pipelines-watch--r-timer record)
   (run-at-time
    delay
    nil
    (lambda (key)
      (when-let ((current
                  (gethash key bitbucket-devops-pipelines-watch--records)))
        (setf (bitbucket-devops-pipelines-watch--r-timer current) nil)
        (bitbucket-devops-pipelines-watch--poll key)))
    (bitbucket-devops-pipelines-watch--r-key record))))

(defun bitbucket-devops-pipelines-watch--notify (message)
  "Notify the user with MESSAGE."
  (cond
   ((functionp bitbucket-devops-pipelines-notification-function)
    (funcall bitbucket-devops-pipelines-notification-function message))
   ((or (fboundp 'alert)
        (require 'alert nil t))
    (alert message :title bitbucket-devops-pipelines-notification-title))
   ((and (display-graphic-p)
         (or (fboundp 'notifications-notify)
             (require 'notifications nil t)))
    (condition-case nil
        (progn
          (notifications-notify
           :title bitbucket-devops-pipelines-notification-title
           :body message)
          (message "%s" message))
      (error
       (message "%s" message))))
   (t
    (message "%s" message))))

(defun bitbucket-devops-pipelines-watch--describe-record (record)
  "Return a concise repository and pipeline description for RECORD."
  (let ((context (bitbucket-devops-pipelines-watch--r-context record)))
    (format "%s/%s%s"
            (plist-get context :workspace)
            (plist-get context :repo-slug)
            (if-let ((pipeline-uuid
                      (bitbucket-devops-pipelines-watch--r-pipeline-uuid record)))
                (format " %s" pipeline-uuid)
              (pcase (bitbucket-devops-pipelines-watch--r-kind record)
                ('branch
                 (format " branch:%s"
                         (bitbucket-devops-pipelines-watch--r-branch record)))
                ('repository " repository")
                (_ ""))))))

(defun bitbucket-devops-pipelines-watch--notify-state-change (record)
  "Notify once after a change to RECORD's observed state or result."
  (let* ((state (bitbucket-devops-pipelines-watch--r-state record))
         (result (bitbucket-devops-pipelines-watch--r-result record))
         (notification (cons state result)))
    (unless (equal notification
                   (bitbucket-devops-pipelines-watch--r-last-notification record))
      (setf (bitbucket-devops-pipelines-watch--r-last-notification record)
            notification)
      (bitbucket-devops-pipelines-watch--notify
       (format "Bitbucket pipeline %s: %s%s"
               (bitbucket-devops-pipelines-watch--describe-record record)
               (or state "UNKNOWN")
               (if result (format "/%s" result) ""))))))

(defun bitbucket-devops-pipelines-watch--transient-error-p (request-error)
  "Return non-nil when REQUEST-ERROR should be retried."
  (let ((type (plist-get request-error :type))
        (status (plist-get request-error :status)))
    (or (eq type 'network)
        (eq type 'rate-limit)
        (and (eq type 'http)
             (integerp status)
             (or (= status 429)
                 (<= 500 status 599))))))

(defun bitbucket-devops-pipelines-watch--handle-error (key request-error)
  "Handle REQUEST-ERROR for watcher KEY."
  (when-let ((record (gethash key bitbucket-devops-pipelines-watch--records)))
    (if (bitbucket-devops-pipelines-watch--transient-error-p request-error)
        (let ((failures
               (1+ (bitbucket-devops-pipelines-watch--r-failures record))))
          (setf (bitbucket-devops-pipelines-watch--r-failures record) failures)
          (if (> failures bitbucket-devops-pipelines-backoff-maximum-retries)
              (progn
                (bitbucket-devops-pipelines-watch--notify
                 (format "Bitbucket pipeline watcher %s stopped after repeated failures; refresh manually"
                         (bitbucket-devops-pipelines-watch--describe-record record)))
                (bitbucket-devops-pipelines-watch--remove key))
            (bitbucket-devops-pipelines-watch--schedule
             record
             (bitbucket-devops-pipelines-watch--retry-delay failures))))
      (bitbucket-devops-pipelines-watch--notify
       (format "Bitbucket pipeline watcher %s stopped: %s"
               (bitbucket-devops-pipelines-watch--describe-record record)
               (or (plist-get request-error :message) "request failed")))
      (bitbucket-devops-pipelines-watch--remove key))))

(defun bitbucket-devops-pipelines-watch--collect-steps
    (context pipeline-uuid callback &optional next-url steps)
  "Collect PIPELINE-UUID step records asynchronously and invoke CALLBACK.

CONTEXT identifies the repository.  Follow NEXT-URL when present and accumulate
STEPS across pages.  CALLBACK receives the collected steps and an error plist."
  (bitbucket-devops-rest-list-steps
   context
   pipeline-uuid
   (lambda (page request-error)
     (if request-error
         (funcall callback nil request-error)
       (let ((steps
              (append steps (bitbucket-devops-rest-page-values page))))
         (if-let ((next-page (bitbucket-devops-rest-page-next page)))
             (bitbucket-devops-pipelines-watch--collect-steps
              context
              pipeline-uuid
              callback
              next-page
              steps)
           (funcall callback steps nil)))))
   next-url))

(defun bitbucket-devops-pipelines-watch--download-pipeline-logs (record pipeline)
  "Asynchronously download available terminal PIPELINE logs for RECORD."
  (let ((context (bitbucket-devops-pipelines-watch--r-context record))
        (pipeline-uuid (alist-get 'uuid pipeline)))
    (bitbucket-devops-pipelines-watch--collect-steps
     context
     pipeline-uuid
     (lambda (steps request-error)
       (if request-error
           (bitbucket-devops-pipelines-watch--notify
            (format "Unable to collect completed Bitbucket pipeline logs for %s"
                    (bitbucket-devops-pipelines-watch--describe-record record)))
         (bitbucket-devops-ui--download-logs
          context
          pipeline
          steps
          (lambda (saved unavailable)
            (bitbucket-devops-pipelines-watch--notify
             (format "Downloaded %d Bitbucket pipeline logs for %s%s"
                     (length saved)
                     (bitbucket-devops-pipelines-watch--describe-record record)
                     (if unavailable
                         (format "; unavailable: %s"
                                 (string-join unavailable ", "))
                       ""))))))))))

(defun bitbucket-devops-pipelines-watch--receive-pipeline
    (key pipeline request-error)
  "Handle PIPELINE or REQUEST-ERROR for watcher KEY."
  (if request-error
      (bitbucket-devops-pipelines-watch--handle-error key request-error)
    (when-let ((record (gethash key bitbucket-devops-pipelines-watch--records)))
      (bitbucket-devops-cache-merge-pipelines
       (bitbucket-devops-pipelines-watch--r-context record)
       (list pipeline))
      (setf (bitbucket-devops-pipelines-watch--r-failures record) 0)
      (setf (bitbucket-devops-pipelines-watch--r-state record)
            (bitbucket-devops-pipelines-watch--pipeline-state pipeline))
      (setf (bitbucket-devops-pipelines-watch--r-result record)
            (bitbucket-devops-pipelines-watch--pipeline-result pipeline))
      (bitbucket-devops-pipelines-watch--notify-state-change record)
      (bitbucket-devops-pipelines-watch--render-list-buffer)
      (if (bitbucket-devops-pipelines-watch--pipeline-terminal-p pipeline)
          (progn
            (when bitbucket-devops-pipelines-auto-download-logs
              (bitbucket-devops-pipelines-watch--download-pipeline-logs
               record
               pipeline))
            (bitbucket-devops-pipelines-watch--remove key))
        (bitbucket-devops-pipelines-watch--schedule
         record
         bitbucket-devops-pipelines-poll-interval)))))

(defun bitbucket-devops-pipelines-watch--receive-discovery
    (key page request-error)
  "Handle discovery PAGE or REQUEST-ERROR for watcher KEY."
  (if request-error
      (bitbucket-devops-pipelines-watch--handle-error key request-error)
    (when-let ((record (gethash key bitbucket-devops-pipelines-watch--records)))
      (bitbucket-devops-cache-merge-pipelines
       (bitbucket-devops-pipelines-watch--r-context record)
       (bitbucket-devops-rest-page-values page))
      (setf (bitbucket-devops-pipelines-watch--r-failures record) 0)
      (if-let ((pipeline (car (bitbucket-devops-rest-page-values page))))
          (let* ((pipeline-uuid (alist-get 'uuid pipeline))
                 (pipeline-key
                  (bitbucket-devops-pipelines-watch--make-key
                   (bitbucket-devops-pipelines-watch--r-context record)
                   pipeline-uuid)))
            (unless (equal key pipeline-key)
              (when (gethash pipeline-key bitbucket-devops-pipelines-watch--records)
                (bitbucket-devops-pipelines-watch--remove pipeline-key))
              (remhash key bitbucket-devops-pipelines-watch--records)
              (setf (bitbucket-devops-pipelines-watch--r-key record) pipeline-key)
              (puthash pipeline-key record bitbucket-devops-pipelines-watch--records))
            (setf (bitbucket-devops-pipelines-watch--r-pipeline-uuid record)
                  pipeline-uuid)
            (bitbucket-devops-pipelines-watch--receive-pipeline
             pipeline-key
             pipeline
             nil))
        (if (>= (- (float-time)
                   (bitbucket-devops-pipelines-watch--r-discovery-started-at
                    record))
                bitbucket-devops-pipelines-discovery-timeout)
            (progn
              (bitbucket-devops-pipelines-watch--notify
               (format "No Bitbucket pipeline appeared for %s"
                       (bitbucket-devops-pipelines-watch--describe-record record)))
              (bitbucket-devops-pipelines-watch--remove key))
          (bitbucket-devops-pipelines-watch--schedule
           record
           bitbucket-devops-pipelines-poll-interval))))))

(defun bitbucket-devops-pipelines-watch--pipeline-branch (pipeline)
  "Return PIPELINE's target branch name, or nil."
  (alist-get 'ref_name (alist-get 'target pipeline)))

(defun bitbucket-devops-pipelines-watch--receive-subscription
    (key page request-error)
  "Handle persistent subscription PAGE or REQUEST-ERROR for watcher KEY."
  (if request-error
      (bitbucket-devops-pipelines-watch--handle-error key request-error)
    (when-let ((record (gethash key bitbucket-devops-pipelines-watch--records)))
      (bitbucket-devops-cache-merge-pipelines
       (bitbucket-devops-pipelines-watch--r-context record)
       (bitbucket-devops-rest-page-values page))
      (setf (bitbucket-devops-pipelines-watch--r-failures record) 0)
      (let ((initialized (bitbucket-devops-pipelines-watch--r-initialized record))
            (branch (bitbucket-devops-pipelines-watch--r-branch record))
            (seen (bitbucket-devops-pipelines-watch--r-seen-pipeline-uuids record)))
        (dolist (pipeline (bitbucket-devops-rest-page-values page))
         (let ((pipeline-uuid (alist-get 'uuid pipeline)))
            (when (and pipeline-uuid
                       (or (null branch)
                           (equal branch
                                  (bitbucket-devops-pipelines-watch--pipeline-branch
                                   pipeline)))
                       (not (gethash pipeline-uuid seen)))
              (puthash pipeline-uuid t seen)
              ;; Establish a quiet baseline for completed historical runs while
              ;; still attaching to any active run already in scope.
              (when (or initialized
                        (not
                         (bitbucket-devops-pipelines-watch--pipeline-terminal-p
                          pipeline)))
                (let ((context (copy-tree
                                (bitbucket-devops-pipelines-watch--r-context record))))
                  (when-let ((pipeline-branch
                              (bitbucket-devops-pipelines-watch--pipeline-branch
                               pipeline)))
                    (setq context
                          (plist-put context :branch pipeline-branch)))
                  (bitbucket-devops-pipelines-watch-pipeline
                   context
                   pipeline-uuid))))))
        (setf (bitbucket-devops-pipelines-watch--r-initialized record) t)
        (bitbucket-devops-pipelines-watch--render-list-buffer)
        (bitbucket-devops-pipelines-watch--schedule
         record
         bitbucket-devops-pipelines-branch-poll-interval)))))

(defun bitbucket-devops-pipelines-watch--receive-branch
    (key page request-error)
  "Handle persistent branch discovery PAGE or REQUEST-ERROR for watcher KEY."
  (bitbucket-devops-pipelines-watch--receive-subscription key page request-error))

(defun bitbucket-devops-pipelines-watch--poll-subscription (key record)
  "Poll the branch or repository subscription in RECORD identified by KEY."
  (let ((context (bitbucket-devops-pipelines-watch--r-context record))
        history-page history-error history-done paused paused-done)
    (cl-labels
        ((finish
          ()
          (when (and history-done paused-done)
            (bitbucket-devops-pipelines-watch--receive-subscription
             key
             (if history-error
                 history-page
               (bitbucket-devops-ui--merge-pipeline-pages
                history-page paused))
             history-error))))
      (bitbucket-devops-rest-list-pipelines
       context
       (lambda (page request-error)
         (setq history-page page
               history-error request-error
               history-done t)
         (finish)))
      (bitbucket-devops-ui--list-all-paused-pipelines
       context
       (lambda (pipelines request-error)
         (when request-error
           (message "Unable to discover paused Bitbucket pipelines: %s"
                    (plist-get request-error :message)))
         (setq paused (unless request-error pipelines)
               paused-done t)
         (finish))))))

(defun bitbucket-devops-pipelines-watch--poll (key)
  "Poll the watcher identified by KEY immediately."
  (when-let ((record (gethash key bitbucket-devops-pipelines-watch--records)))
    (pcase (bitbucket-devops-pipelines-watch--r-kind record)
      ((or 'branch 'repository)
       (bitbucket-devops-pipelines-watch--poll-subscription key record))
      (_
       (if-let ((pipeline-uuid
                 (bitbucket-devops-pipelines-watch--r-pipeline-uuid record)))
           (bitbucket-devops-rest-get-pipeline
            (bitbucket-devops-pipelines-watch--r-context record)
            pipeline-uuid
            (lambda (pipeline request-error)
              (bitbucket-devops-pipelines-watch--receive-pipeline
               key
               pipeline
               request-error)))
         (bitbucket-devops-rest-list-pipelines-for-commit
          (bitbucket-devops-pipelines-watch--r-context record)
          (bitbucket-devops-pipelines-watch--r-commit record)
          (lambda (page request-error)
            (bitbucket-devops-pipelines-watch--receive-discovery
             key
             page
             request-error))))))))

(defun bitbucket-devops-pipelines-watch-pipeline (context pipeline-uuid)
  "Start watching PIPELINE-UUID using captured repository CONTEXT.

Return the active watcher key."
  (let* ((context (copy-tree context))
         (key
          (bitbucket-devops-pipelines-watch--make-key context pipeline-uuid))
         (record
          (bitbucket-devops-pipelines-watch--make-record
           :key key
           :kind 'pipeline
           :context context
           :pipeline-uuid pipeline-uuid
           :commit (plist-get context :commit)
           :branch (plist-get context :branch))))
    (when (gethash key bitbucket-devops-pipelines-watch--records)
      (bitbucket-devops-pipelines-watch--remove key))
    (puthash key record bitbucket-devops-pipelines-watch--records)
    (bitbucket-devops-pipelines-watch--update-mode-line)
    (bitbucket-devops-pipelines-watch--poll key)
    key))

(defun bitbucket-devops-pipelines-watch-commit (context)
  "Discover and watch the pipeline for the captured commit in CONTEXT.

Return the active watcher key."
  (let ((commit (plist-get context :commit)))
    (unless commit
      (user-error "Unable to watch a Bitbucket pipeline without a commit"))
    (let* ((context (copy-tree context))
           (key (bitbucket-devops-pipelines-watch--make-key context nil commit))
           (record
            (bitbucket-devops-pipelines-watch--make-record
             :key key
             :kind 'commit
             :context context
             :commit commit
             :branch (plist-get context :branch)
             :discovery-started-at (float-time))))
      (when (gethash key bitbucket-devops-pipelines-watch--records)
        (bitbucket-devops-pipelines-watch--remove key))
      (puthash key record bitbucket-devops-pipelines-watch--records)
      (bitbucket-devops-pipelines-watch--update-mode-line)
      (bitbucket-devops-pipelines-watch--poll key)
      key)))

;;;###autoload
(defun bitbucket-devops-pipelines-watch-branch (context branch)
  "Persistently watch newly discovered pipelines on BRANCH using CONTEXT.

The first poll establishes a historical baseline without notifying for completed
runs.  Active runs and pipelines discovered by later polls use ordinary
per-pipeline watchers.  Return the persistent branch subscription key."
  (unless (and (stringp branch) (not (string-empty-p branch)))
    (user-error "Unable to watch a Bitbucket branch without a branch name"))
  (let* ((context (plist-put (copy-tree context) :branch branch))
         (key (bitbucket-devops-pipelines-watch--make-branch-key context branch))
         (record
          (bitbucket-devops-pipelines-watch--make-record
           :key key
           :kind 'branch
           :context context
           :branch branch
           :state "SUBSCRIBED"
           :seen-pipeline-uuids (make-hash-table :test #'equal))))
    (when (gethash key bitbucket-devops-pipelines-watch--records)
      (bitbucket-devops-pipelines-watch--remove key))
    (puthash key record bitbucket-devops-pipelines-watch--records)
    (bitbucket-devops-pipelines-watch--update-mode-line)
    (bitbucket-devops-pipelines-watch--poll key)
    key))

;;;###autoload
(defun bitbucket-devops-pipelines-watch-repository (context)
  "Persistently watch newly discovered pipelines in CONTEXT's repository.

The first poll establishes a historical baseline without notifying for completed
runs.  Active runs and pipelines discovered by later polls use ordinary
per-pipeline watchers.  Return the persistent repository subscription key."
  (let* ((context (copy-tree context))
         (key (bitbucket-devops-pipelines-watch--make-repository-key context))
         (record
          (bitbucket-devops-pipelines-watch--make-record
           :key key
           :kind 'repository
           :context context
           :state "SUBSCRIBED"
           :seen-pipeline-uuids (make-hash-table :test #'equal))))
    (when (gethash key bitbucket-devops-pipelines-watch--records)
      (bitbucket-devops-pipelines-watch--remove key))
    (puthash key record bitbucket-devops-pipelines-watch--records)
    (bitbucket-devops-pipelines-watch--update-mode-line)
    (bitbucket-devops-pipelines-watch--poll key)
    key))

;;;###autoload
(defun bitbucket-devops-pipelines-watch-current (&optional directory)
  "Discover and watch the current commit pipeline for DIRECTORY."
  (interactive)
  (bitbucket-devops-pipelines-watch-commit
   (bitbucket-devops-context-resolve directory)))

;;;###autoload
(defun bitbucket-devops-pipelines-watch-branch-current (&optional directory)
  "Prompt for and persistently watch a branch in DIRECTORY's repository."
  (interactive)
  (let* ((context (bitbucket-devops-context-resolve directory))
         (branch
          (read-string
           "Watch Bitbucket branch: "
           (or (plist-get context :branch) ""))))
    (bitbucket-devops-pipelines-watch-branch context branch)
    (message "Watching new Bitbucket pipelines on branch %s" branch)))

;;;###autoload
(defun bitbucket-devops-pipelines-watch-repository-current (&optional directory)
  "Persistently watch newly discovered pipelines in DIRECTORY's repository."
  (interactive)
  (let ((context (bitbucket-devops-context-resolve directory)))
    (bitbucket-devops-pipelines-watch-repository context)
    (message "Watching new Bitbucket pipelines in %s/%s"
             (plist-get context :workspace)
             (plist-get context :repo-slug))))

(defun bitbucket-devops-pipelines-refresh ()
  "Immediately refresh every active Bitbucket pipeline watcher."
  (interactive)
  (maphash
   (lambda (key record)
     (bitbucket-devops-pipelines-watch--cancel-timer record)
     (bitbucket-devops-pipelines-watch--poll key))
   bitbucket-devops-pipelines-watch--records))

(defun bitbucket-devops-pipelines-stop-watching (key)
  "Stop the active Bitbucket pipeline watcher identified by KEY."
  (interactive
   (list
    (completing-read
     "Stop pipeline watcher: "
     (hash-table-keys bitbucket-devops-pipelines-watch--records)
     nil
     t)))
  (unless (gethash key bitbucket-devops-pipelines-watch--records)
    (user-error "No active Bitbucket pipeline watcher: %s" key))
  (bitbucket-devops-pipelines-watch--remove key)
  (message "Stopped Bitbucket pipeline watcher %s" key))

(defun bitbucket-devops-pipelines-stop-watching-at-point ()
  "Stop the watcher on the current line in the watcher list buffer."
  (interactive)
  (let ((key (or (get-text-property (point) 'bitbucket-devops-watcher-key)
                 (get-text-property
                  (point)
                  'bitbucket-devops-pipelines-watcher-key)))
        (type (get-text-property (point) 'bitbucket-devops-watcher-type)))
    (pcase type
      ('pipeline
       (bitbucket-devops-pipelines-watch--remove key)
       (message "Stopped Bitbucket pipeline watcher %s" key))
      ('pull-request-comments
       (bitbucket-devops-pull-requests-watch-comments-stop-by-key key)
       (message "Stopped Bitbucket PR comment watcher %s" key))
      (_
       (if key
           (progn
             (bitbucket-devops-pipelines-watch--remove key)
             (message "Stopped Bitbucket pipeline watcher %s" key))
         (user-error "No watcher on this line"))))))

(defun bitbucket-devops-pipelines-list-watchers ()
  "Display active Bitbucket pipeline and PR comment watchers."
  (interactive)
  (let ((previous-buffer (current-buffer))
        (buffer
         (get-buffer-create bitbucket-devops-pipelines-watch--list-buffer-name)))
    (bitbucket-devops-pipelines-watch--render-list-buffer)
    (bitbucket-devops-ui--display-buffer buffer t previous-buffer)
    buffer))

(provide 'bitbucket-devops-pipelines-watch)
;;; bitbucket-devops-pipelines-watch.el ends here
