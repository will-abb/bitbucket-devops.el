;;; bitbucket-devops-ui.el --- Bitbucket DevOps UI and pipeline buffers -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Will Bosch-Bello <williamsbosch@gmail.com>
;; Keywords: tools, vc

;;; Commentary:

;; Provide shared package navigation and render Bitbucket Cloud pipeline
;; history and related read-only buffers.

;;; Code:

(require 'ansi-color)
(require 'cl-lib)
(require 'compile)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'time-date)
(require 'bitbucket-devops-cache)
(require 'bitbucket-devops-context)
(require 'bitbucket-devops-rest)

(declare-function bitbucket-devops-dispatch "bitbucket-devops" ())
(declare-function bitbucket-devops-pipelines-run-configured
                  "bitbucket-devops-pipelines-mutate"
                  (&optional directory))
(declare-function bitbucket-devops-pipelines-watch-pipeline
                  "bitbucket-devops-pipelines-watch"
                  (context pipeline-uuid))
(declare-function bitbucket-devops-pipelines-rerun "bitbucket-devops-pipelines-mutate" ())
(declare-function bitbucket-devops-pipelines-stop "bitbucket-devops-pipelines-mutate" ())
(declare-function bitbucket-devops-pipelines-continue "bitbucket-devops-pipelines-mutate" ())
(declare-function bitbucket-devops-pull-requests-ui-key-for-command
                  "bitbucket-devops-pull-requests-ui"
                  (command))
(declare-function bitbucket-devops-pull-requests-ui-keys-for-command
                  "bitbucket-devops-pull-requests-ui"
                  (command))
(declare-function evil-define-key* "evil-core" (state keymap key def &rest bindings))
(declare-function magit-list-local-branch-names "magit-git" ())
(declare-function magit-list-remote-branch-names "magit-git"
                  (&optional remote relative))

(defvar-local bitbucket-devops-ui--context nil
  "Repository context captured by the current Bitbucket Pipelines buffer.")

(defvar-local bitbucket-devops-ui--history-pipelines nil
  "Pipelines loaded into the current history buffer.")

(defvar-local bitbucket-devops-ui--history-next-url nil
  "Trusted next-page URL for the current history buffer.")

(defvar-local bitbucket-devops-ui--history-loading nil
  "Non-nil while the current history buffer is loading a page.")

(defvar-local bitbucket-devops-ui--history-request-generation 0
  "Generation used to ignore stale pipeline history sync callbacks.")

(defvar-local bitbucket-devops-ui--history-branch-filter 'all
  "Branch filter used by the current history buffer.

The value is `all' or a branch name string.")

(defvar-local bitbucket-devops-ui--history-status-filter 'all
  "Status filter used by the current history buffer.")

(defvar-local bitbucket-devops-ui--details-pipeline-uuid nil
  "Pipeline UUID displayed by the current details buffer.")

(defvar-local bitbucket-devops-ui--details-pipeline nil
  "Pipeline record displayed by the current details buffer.")

(defvar-local bitbucket-devops-ui--details-steps nil
  "Steps loaded into the current details buffer.")

(defvar-local bitbucket-devops-ui--details-loading nil
  "Non-nil while the current details buffer is loading.")

(defvar-local bitbucket-devops-ui--details-generation 0
  "Generation number of the current asynchronous details refresh.")

(defvar-local bitbucket-devops-ui--previous-buffer nil
  "Prior Bitbucket DevOps UI buffer for local back navigation.")

(defvar bitbucket-devops-ui--commit-cache (make-hash-table :test #'equal)
  "Full Bitbucket commit records keyed by workspace, repository, and hash.")

(defvar bitbucket-devops-ui--deployment-cache (make-hash-table :test #'equal)
  "Deployment records keyed by workspace, repository, and pipeline UUID.")

(defcustom bitbucket-devops-fullscreen-buffers nil
  "Whether Bitbucket DevOps UI buffers occupy the entire frame.

When non-nil, showing history, details, or logs deletes other windows before
selecting the package buffer.  Use `bitbucket-devops-ui-back' to return to
the prior Bitbucket DevOps UI screen."
  :type 'boolean
  :group 'bitbucket-devops)

(defcustom bitbucket-devops-command-panel-height 6
  "Minimum height of the persistent Bitbucket DevOps command panel.

The panel grows beyond this value when necessary to display every command."
  :type 'integer
  :group 'bitbucket-devops)

(defcustom bitbucket-devops-command-panel-enabled t
  "Control automatic display of the Bitbucket DevOps command panel.

The value t or `always' shows the panel whenever a package UI buffer is
displayed.  The value nil or `manual' keeps it hidden until `?' toggles it
on.  The value `never' disables both automatic display and `?' display."
  :type '(choice
          (const :tag "Show automatically" t)
          (const :tag "Show automatically" always)
          (const :tag "Show only after pressing ?" manual)
          (const :tag "Show only after pressing ? (legacy nil)" nil)
          (const :tag "Never show" never))
  :group 'bitbucket-devops)

(defcustom bitbucket-devops-command-panel-side 'bottom
  "Frame side used to display the persistent command panel."
  :type '(choice
          (const :tag "Bottom" bottom)
          (const :tag "Top" top))
  :group 'bitbucket-devops)

(defcustom bitbucket-devops-pipelines-log-download-directory
  (expand-file-name "~/Downloads")
  "Directory used for downloaded Bitbucket pipeline step logs."
  :type 'directory
  :group 'bitbucket-devops-pipelines)

(defcustom bitbucket-devops-pipelines-auto-download-logs nil
  "Whether trackers download completed pipeline logs automatically."
  :type 'boolean
  :group 'bitbucket-devops-pipelines)

(defcustom bitbucket-devops-pipelines-sync-always-count 5
  "Number of newest pipelines to always refetch during history refresh.

Pipeline history opens from cached rows when available, then fetches the newest
Bitbucket page.  This option controls how many newest loaded pipelines are
also refetched through the pipeline detail endpoint even when they are
completed.  Set to nil or 0 to disable unconditional revalidation."
  :type '(choice (const :tag "Disable unconditional pipeline revalidation" nil)
                 (integer :tag "Newest pipelines to always revalidate"))
  :group 'bitbucket-devops-pipelines)

(defcustom bitbucket-devops-pipelines-sync-active-count 20
  "Number of newest active pipelines to refetch during history refresh.

Only pipelines whose top-level API state is not `COMPLETED', or whose state is
unknown, are considered active.  That includes pending, running, paused, and
manual-waiting pipelines.  Completed pipelines are skipped unless they are also
covered by `bitbucket-devops-pipelines-sync-always-count'."
  :type '(choice (const :tag "Disable active pipeline revalidation" nil)
                 (integer :tag "Newest active pipelines to revalidate"))
  :group 'bitbucket-devops-pipelines)

(defcustom bitbucket-devops-pipelines-display-time-zone nil
  "Time zone used to display Bitbucket pipeline timestamps.

Nil means use the local system time zone.  The value t means Universal Time.
A string names a time zone such as \"America/Chicago\"."
  :type '(choice
          (const :tag "Local system time zone" nil)
          (const :tag "Universal Time" t)
          (string :tag "Named time zone"))
  :group 'bitbucket-devops-pipelines)

(defcustom bitbucket-devops-pipelines-display-time-format "%Y-%m-%d %H:%M:%S %Z"
  "Format string used to display Bitbucket pipeline timestamps."
  :type 'string
  :group 'bitbucket-devops-pipelines)

(defcustom bitbucket-devops-pipelines-history-column-widths
  '((build . 7)
    (state . 13)
    (type . 22)
    (deployments . 30)
    (target . 18)
    (commit . 12)
    (author . 24)
    (created . 24)
    (duration . 9)
    (message . 0))
  "Column widths used by Bitbucket pipeline history buffers.

A width of zero gives the column the remaining line width, matching
`tabulated-list-format'."
  :type '(alist :key-type symbol :value-type integer)
  :group 'bitbucket-devops-pipelines)

(defcustom bitbucket-devops-pipelines-details-column-widths
  '((number . 5)
    (step . 36)
    (state . 14)
    (deployment . 18)
    (duration . 10))
  "Column widths used by Bitbucket pipeline details buffers."
  :type '(alist :key-type symbol :value-type integer)
  :group 'bitbucket-devops-pipelines)

(defun bitbucket-devops-ui--column-width (column widths default)
  "Return configured COLUMN width from WIDTHS, falling back to DEFAULT."
  (let ((value (alist-get column widths)))
    (if (and (integerp value) (>= value 0))
        value
      default)))

(defconst bitbucket-devops-ui--command-panel-buffer-name
  "*Bitbucket DevOps Commands*"
  "Name of the persistent Bitbucket DevOps command panel buffer.")

(defvar bitbucket-devops-ui--command-panel-owner nil
  "Bitbucket DevOps UI buffer currently owning the command panel.")

(defface bitbucket-devops-pipelines-success-face
  '((t :inherit success :weight bold))
  "Face used for successful pipeline states."
  :group 'bitbucket-devops-pipelines)

(defface bitbucket-devops-pipelines-error-face
  '((t :inherit error :weight bold))
  "Face used for failed pipeline states."
  :group 'bitbucket-devops-pipelines)

(defface bitbucket-devops-pipelines-stopped-face
  '((t :inherit shadow :weight bold))
  "Face used for stopped pipeline states."
  :group 'bitbucket-devops-pipelines)

(defface bitbucket-devops-pipelines-in-progress-face
  '((t :inherit warning :weight bold))
  "Face used for pipeline states that are not terminal."
  :group 'bitbucket-devops-pipelines)

(defface bitbucket-devops-pipelines-build-face
  '((t :inherit font-lock-constant-face :weight bold))
  "Face used for pipeline build numbers."
  :group 'bitbucket-devops-pipelines)

(defface bitbucket-devops-pipelines-branch-face
  '((t :inherit font-lock-keyword-face))
  "Face used for pipeline branch or target names."
  :group 'bitbucket-devops-pipelines)

(defface bitbucket-devops-pipelines-commit-face
  '((t :inherit font-lock-constant-face))
  "Face used for abbreviated commit hashes."
  :group 'bitbucket-devops-pipelines)

(defface bitbucket-devops-pipelines-author-face
  '((t :inherit font-lock-variable-name-face))
  "Face used for commit authors."
  :group 'bitbucket-devops-pipelines)

(defface bitbucket-devops-pipelines-message-face
  '((t :inherit font-lock-string-face))
  "Face used for commit messages."
  :group 'bitbucket-devops-pipelines)

(defface bitbucket-devops-pipelines-secondary-face
  '((t :inherit shadow))
  "Face used for secondary pipeline metadata."
  :group 'bitbucket-devops-pipelines)

(defface bitbucket-devops-pipelines-deployment-face
  '((t :inherit font-lock-type-face))
  "Face used for Bitbucket deployment environment names."
  :group 'bitbucket-devops-pipelines)

(defface bitbucket-devops-command-panel-heading-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face used for command-panel group headings."
  :group 'bitbucket-devops)

(defface bitbucket-devops-command-panel-key-face
  '((t :inherit font-lock-builtin-face))
  "Face used for command-panel keys."
  :group 'bitbucket-devops)

(defun bitbucket-devops-ui--nested-get (object &rest keys)
  "Return the value reached by following KEYS through alist OBJECT."
  (dolist (key keys object)
    (setq object (alist-get key object))))

(defun bitbucket-devops-ui--pipeline-state-label (pipeline)
  "Return a concise state label for PIPELINE."
  (let ((state (alist-get 'state pipeline)))
    (or (bitbucket-devops-ui--nested-get state 'result 'name)
        (bitbucket-devops-ui--nested-get state 'stage 'name)
        (alist-get 'name state)
        "UNKNOWN")))

(defun bitbucket-devops-ui--step-state-label (step)
  "Return Bitbucket's state or terminal result label for STEP."
  (let ((state (alist-get 'state step)))
    (or (bitbucket-devops-ui--nested-get state 'result 'name)
        (alist-get 'name state)
        "UNKNOWN")))

(defun bitbucket-devops-ui--pipeline-type-label (pipeline)
  "Return a concise selector label for PIPELINE."
  (if-let ((pattern
            (bitbucket-devops-ui--nested-get
             pipeline
             'target
             'selector
             'pattern)))
      (format "custom: %s" pattern)
    "default"))

(defun bitbucket-devops-ui--deployment-environment-name (deployment)
  "Return DEPLOYMENT's environment name."
  (bitbucket-devops-ui--nested-get deployment 'environment 'name))

(defun bitbucket-devops-ui--deployment-pipeline-uuid (deployment)
  "Return the pipeline UUID associated with DEPLOYMENT."
  (bitbucket-devops-ui--nested-get deployment 'deployable 'pipeline 'uuid))

(defun bitbucket-devops-ui--deployment-matches-pipeline-p
    (deployment pipeline-uuid)
  "Return non-nil when DEPLOYMENT belongs to PIPELINE-UUID."
  (equal
   (bitbucket-devops-ui--deployment-pipeline-uuid deployment)
   pipeline-uuid))

(defun bitbucket-devops-ui--deployment-number-less-p (a b)
  "Return non-nil when deployment A ran before deployment B."
  (< (or (alist-get 'number a) 0)
     (or (alist-get 'number b) 0)))

(defun bitbucket-devops-ui--deployment-names (deployments)
  "Return unique environment names from DEPLOYMENTS in execution order."
  (delete-dups
   (delq
    nil
    (mapcar
     #'bitbucket-devops-ui--deployment-environment-name
     (sort (copy-sequence deployments)
           #'bitbucket-devops-ui--deployment-number-less-p)))))

(defun bitbucket-devops-ui--pipeline-deployment-label (pipeline)
  "Return PIPELINE's deployment environments as a CSV label."
  (string-join
   (bitbucket-devops-ui--deployment-names
    (alist-get 'bitbucket-devops-pipelines-deployments pipeline))
   ","))

(defun bitbucket-devops-ui--step-deployment-name (step)
  "Return STEP's deployment environment name, or nil."
  (alist-get 'bitbucket-devops-pipelines-deployment step))

(defun bitbucket-devops-ui--state-face (label)
  "Return the face used to display pipeline state LABEL."
  (pcase label
    ("SUCCESSFUL" 'bitbucket-devops-pipelines-success-face)
    ((or "FAILED" "ERROR") 'bitbucket-devops-pipelines-error-face)
    ("STOPPED" 'bitbucket-devops-pipelines-stopped-face)
    (_ 'bitbucket-devops-pipelines-in-progress-face)))

(defun bitbucket-devops-ui--style (value face)
  "Return VALUE as a string propertized with FACE."
  (propertize (format "%s" (or value "")) 'face face))

(defun bitbucket-devops-ui--format-time (timestamp)
  "Return TIMESTAMP formatted for `bitbucket-devops-pipelines-display-time-zone'."
  (if (or (null timestamp) (string-empty-p timestamp))
      ""
    (if (not
         (string-match-p
          "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T[0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}\\(?:\\.[0-9]+\\)?\\(?:Z\\|[+-][0-9]\\{2\\}:[0-9]\\{2\\}\\)\\'"
          timestamp))
        timestamp
      (condition-case nil
          (format-time-string
           bitbucket-devops-pipelines-display-time-format
           (date-to-time timestamp)
           bitbucket-devops-pipelines-display-time-zone)
        (error timestamp)))))

(defun bitbucket-devops-ui--position-line-column (position)
  "Return the line and column for POSITION in the current buffer."
  (save-excursion
    (goto-char (min (max (point-min) position) (point-max)))
    (cons (line-number-at-pos) (current-column))))

(defun bitbucket-devops-ui--line-column-position (line-column)
  "Return the buffer position represented by LINE-COLUMN."
  (save-excursion
    (goto-char (point-min))
    (forward-line (max 0 (1- (car line-column))))
    (move-to-column (cdr line-column))
    (point)))

(defun bitbucket-devops-ui--visible-window-states (&optional buffer)
  "Return visible window point and scroll states for BUFFER."
  (let ((buffer (or buffer (current-buffer))))
    (mapcar
     (lambda (window)
       (with-current-buffer buffer
         (list window
               (bitbucket-devops-ui--position-line-column
                (window-point window))
               (bitbucket-devops-ui--position-line-column
                (window-start window)))))
     (get-buffer-window-list buffer nil t))))

(defun bitbucket-devops-ui--restore-window-states (buffer states)
  "Restore BUFFER window point and scroll STATES."
  (dolist (state states)
    (let ((window (nth 0 state))
          (point-state (nth 1 state))
          (start-state (nth 2 state)))
      (when (and (window-live-p window)
                 (eq (window-buffer window) buffer))
        (with-current-buffer buffer
          (set-window-point
           window
           (bitbucket-devops-ui--line-column-position point-state))
          (set-window-start
           window
           (bitbucket-devops-ui--line-column-position start-state)))))))

(defun bitbucket-devops-ui--preserve-visible-window-positions (function)
  "Call FUNCTION, preserving visible window scroll positions."
  (let ((buffer (current-buffer))
        (states (bitbucket-devops-ui--visible-window-states)))
    (unwind-protect
        (funcall function)
      (bitbucket-devops-ui--restore-window-states buffer states))))

(defun bitbucket-devops-ui--pipeline-row (pipeline)
  "Return a `tabulated-list-mode' entry for PIPELINE."
  (let* ((target (alist-get 'target pipeline))
         (commit (alist-get 'commit target))
         (hash (or (alist-get 'hash commit) ""))
         (message (or (alist-get 'message commit) ""))
         (duration (alist-get 'duration_in_seconds pipeline))
         (state-label (bitbucket-devops-ui--pipeline-state-label pipeline)))
    (list
     (alist-get 'uuid pipeline)
     (vector
      (bitbucket-devops-ui--style
       (alist-get 'build_number pipeline)
       'bitbucket-devops-pipelines-build-face)
      (bitbucket-devops-ui--style
       state-label
       (bitbucket-devops-ui--state-face state-label))
      (bitbucket-devops-ui--style
       (bitbucket-devops-ui--pipeline-type-label pipeline)
       'bitbucket-devops-pipelines-secondary-face)
      (bitbucket-devops-ui--style
       (bitbucket-devops-ui--pipeline-deployment-label pipeline)
       'bitbucket-devops-pipelines-deployment-face)
      (bitbucket-devops-ui--style
       (alist-get 'ref_name target)
       'bitbucket-devops-pipelines-branch-face)
      (bitbucket-devops-ui--style
       (substring hash 0 (min 12 (length hash)))
       'bitbucket-devops-pipelines-commit-face)
      (bitbucket-devops-ui--style
       (bitbucket-devops-ui--nested-get commit 'author 'raw)
       'bitbucket-devops-pipelines-author-face)
      (bitbucket-devops-ui--style
       (bitbucket-devops-ui--format-time (alist-get 'created_on pipeline))
       'bitbucket-devops-pipelines-secondary-face)
      (bitbucket-devops-ui--style
       (if duration (format "%ss" duration) "")
       'bitbucket-devops-pipelines-secondary-face)
      (bitbucket-devops-ui--style
       (string-trim (car (split-string message "\n")))
       'bitbucket-devops-pipelines-message-face)))))

(defun bitbucket-devops-ui--pipeline-status-category (pipeline)
  "Return the broad status filter category for PIPELINE."
  (pcase (bitbucket-devops-ui--pipeline-state-label pipeline)
    ("SUCCESSFUL" 'successful)
    ((or "FAILED" "ERROR" "STOPPED") 'failed)
    (_ 'in-progress)))

(defun bitbucket-devops-ui--pipeline-build-number-less-p (a b)
  "Return non-nil when pipeline row A has a lower build number than B."
  (< (string-to-number (aref (cadr a) 0))
     (string-to-number (aref (cadr b) 0))))

(defun bitbucket-devops-ui--history-branch-filter-name ()
  "Return the selected history branch name, or nil for all branches."
  (pcase bitbucket-devops-ui--history-branch-filter
    ('all nil)
    ((pred stringp) bitbucket-devops-ui--history-branch-filter)))

(defun bitbucket-devops-ui--history-magit-branch-names ()
  "Return local and configured-remote Git branch names from Magit.

Use the repository root captured by the history buffer.  Return nil when Magit
cannot list refs so loaded pipeline history remains available as a fallback."
  (when (fboundp 'magit-list-local-branch-names)
    (let ((default-directory
           (or (plist-get bitbucket-devops-ui--context :root)
               default-directory))
          (remote (plist-get bitbucket-devops-ui--context :remote)))
      (condition-case nil
          (append
           (magit-list-local-branch-names)
           (when (and (stringp remote)
                      (fboundp 'magit-list-remote-branch-names))
             (magit-list-remote-branch-names remote t)))
        (error nil)))))

(defun bitbucket-devops-ui--history-branch-names ()
  "Return branch names available as history filter completion candidates.

Combine the current branch, names from loaded pipeline history, and local or
configured-remote Git refs reported by Magit."
  (sort
   (delete-dups
    (seq-filter
     (lambda (branch)
       (and (stringp branch)
            (not (string-empty-p branch))
            (not (equal branch "HEAD"))))
     (append
      (list (plist-get bitbucket-devops-ui--context :branch))
      (mapcar
       (lambda (pipeline)
         (bitbucket-devops-ui--nested-get pipeline 'target 'ref_name))
       bitbucket-devops-ui--history-pipelines)
      (bitbucket-devops-ui--history-magit-branch-names))))
   #'string-lessp))

(defun bitbucket-devops-ui--history-filter-pipelines (pipelines)
  "Return PIPELINES matching the current history buffer filters."
  (let ((branch (bitbucket-devops-ui--history-branch-filter-name)))
    (seq-filter
     (lambda (pipeline)
       (and
        (or
         (null branch)
         (equal
          (bitbucket-devops-ui--nested-get pipeline 'target 'ref_name)
          branch))
        (or
         (eq bitbucket-devops-ui--history-status-filter 'all)
         (eq
          (bitbucket-devops-ui--pipeline-status-category pipeline)
          bitbucket-devops-ui--history-status-filter))))
     pipelines)))

(defun bitbucket-devops-ui--step-row (step index)
  "Return a `tabulated-list-mode' entry for STEP at one-based INDEX."
  (list
   (alist-get 'uuid step)
   (vector
    (bitbucket-devops-ui--style index 'bitbucket-devops-pipelines-build-face)
    (or (alist-get 'name step) "")
    (let ((state-label (bitbucket-devops-ui--step-state-label step)))
      (bitbucket-devops-ui--style
       state-label
       (bitbucket-devops-ui--state-face state-label)))
    (bitbucket-devops-ui--style
     (bitbucket-devops-ui--step-deployment-name step)
     'bitbucket-devops-pipelines-deployment-face)
    (let ((duration (alist-get 'duration_in_seconds step)))
      (bitbucket-devops-ui--style
       (if duration (format "%ss" duration) "")
       'bitbucket-devops-pipelines-secondary-face)))))

(defun bitbucket-devops-ui--step-terminal-p (step)
  "Return non-nil when STEP has reached a terminal state."
  (equal (bitbucket-devops-ui--nested-get step 'state 'name)
         "COMPLETED"))

(defun bitbucket-devops-ui--pipeline-terminal-p (pipeline)
  "Return non-nil when PIPELINE has reached a terminal state."
  (equal (bitbucket-devops-ui--nested-get pipeline 'state 'name)
         "COMPLETED"))

(defun bitbucket-devops-ui--pipeline-stopped-p (pipeline)
  "Return non-nil when PIPELINE or step record has a stopped result."
  (equal (bitbucket-devops-ui--step-state-label pipeline)
         "STOPPED"))

(defun bitbucket-devops-ui--step-log-unavailable-reason (pipeline step)
  "Return an actionable reason when STEP log from PIPELINE is unavailable."
  (cond
   ((bitbucket-devops-ui--pipeline-stopped-p step)
    "Step log is unavailable because this Bitbucket pipeline step was stopped")
   ((and (bitbucket-devops-ui--pipeline-stopped-p pipeline)
         (not (equal (bitbucket-devops-ui--step-state-label step)
                     "SUCCESSFUL")))
    "Step log is unavailable because this Bitbucket pipeline was stopped")
   ((not (bitbucket-devops-ui--step-terminal-p step))
    "Step logs are available after the step completes")))

(defun bitbucket-devops-ui--step-log-available-p (pipeline step)
  "Return non-nil when STEP log from PIPELINE can be requested."
  (not (bitbucket-devops-ui--step-log-unavailable-reason pipeline step)))

(defun bitbucket-devops-ui--require-step-log-available (pipeline step)
  "Signal an actionable `user-error' unless STEP log can be requested."
  (when-let ((reason
              (bitbucket-devops-ui--step-log-unavailable-reason
               pipeline
               step)))
    (user-error "%s" reason)))

(defun bitbucket-devops-ui--step-log-request-error-message (request-error)
  "Return a helpful user-facing message for step-log REQUEST-ERROR."
  (if (and (eq (plist-get request-error :type) 'http)
           (equal (plist-get request-error :status) 404))
      (concat
       "Bitbucket did not provide a log for this step; "
       "it may have been stopped before a log was created")
    (or (plist-get request-error :message)
        "Unknown Bitbucket API request failure")))

(defun bitbucket-devops-ui--disable-line-wrapping ()
  "Keep Bitbucket tabulated-list rows on one physical line."
  (setq-local tabulated-list-use-header-line nil)
  (setq-local truncate-lines t)
  (setq-local word-wrap nil)
  (when (boundp 'word-wrap-by-category)
    (setq-local word-wrap-by-category nil))
  (when (bound-and-true-p visual-line-mode)
    (visual-line-mode -1)))

(define-derived-mode bitbucket-devops-pipelines-history-mode tabulated-list-mode
  "Bitbucket-DevOps-Pipelines-History"
  "Major mode for Bitbucket Cloud pipeline history."
  (bitbucket-devops-ui--disable-line-wrapping)
  (setq tabulated-list-format
        `[("Build"
           ,(bitbucket-devops-ui--column-width
             'build bitbucket-devops-pipelines-history-column-widths 7)
           bitbucket-devops-ui--pipeline-build-number-less-p)
          ("State"
           ,(bitbucket-devops-ui--column-width
             'state bitbucket-devops-pipelines-history-column-widths 13)
           t)
          ("Type"
           ,(bitbucket-devops-ui--column-width
             'type bitbucket-devops-pipelines-history-column-widths 22)
           t)
          ("Deployments"
           ,(bitbucket-devops-ui--column-width
             'deployments bitbucket-devops-pipelines-history-column-widths 30)
           t)
          ("Branch or target"
           ,(bitbucket-devops-ui--column-width
             'target bitbucket-devops-pipelines-history-column-widths 18)
           t)
          ("Commit"
           ,(bitbucket-devops-ui--column-width
             'commit bitbucket-devops-pipelines-history-column-widths 12)
           t)
          ("Author"
           ,(bitbucket-devops-ui--column-width
             'author bitbucket-devops-pipelines-history-column-widths 24)
           t)
          ("Created"
           ,(bitbucket-devops-ui--column-width
             'created bitbucket-devops-pipelines-history-column-widths 24)
           t)
          ("Duration"
           ,(bitbucket-devops-ui--column-width
             'duration bitbucket-devops-pipelines-history-column-widths 9)
           t)
          ("Commit message"
           ,(bitbucket-devops-ui--column-width
             'message bitbucket-devops-pipelines-history-column-widths 0)
           t)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key nil)
  (add-hook 'tabulated-list-revert-hook
            #'bitbucket-devops-pipelines-history-refresh
            nil
            t)
  (tabulated-list-init-header))

(define-derived-mode bitbucket-devops-pipelines-details-mode tabulated-list-mode
  "Bitbucket-DevOps-Pipelines-Details"
  "Major mode for Bitbucket Cloud pipeline details."
  (bitbucket-devops-ui--disable-line-wrapping)
  (setq tabulated-list-format
        `[("#"
           ,(bitbucket-devops-ui--column-width
             'number bitbucket-devops-pipelines-details-column-widths 5)
           t)
          ("Step"
           ,(bitbucket-devops-ui--column-width
             'step bitbucket-devops-pipelines-details-column-widths 36)
           t)
          ("State"
           ,(bitbucket-devops-ui--column-width
             'state bitbucket-devops-pipelines-details-column-widths 14)
           t)
          ("Deployment"
           ,(bitbucket-devops-ui--column-width
             'deployment bitbucket-devops-pipelines-details-column-widths 18)
           t)
          ("Duration"
           ,(bitbucket-devops-ui--column-width
             'duration bitbucket-devops-pipelines-details-column-widths 10)
           t)])
  (setq tabulated-list-padding 2)
  (tabulated-list-init-header))

(define-derived-mode bitbucket-devops-pipelines-log-mode compilation-mode
  "Bitbucket-DevOps-Pipelines-Log"
  "Major mode for completed Bitbucket Cloud pipeline step logs.")

(define-derived-mode bitbucket-devops-command-panel-mode special-mode
  "Bitbucket-DevOps-Commands"
  "Major mode for the persistent Bitbucket DevOps command panel."
  (setq-local mode-line-format nil)
  (setq-local cursor-type nil)
  (setq-local truncate-lines t))

(defun bitbucket-devops-ui--command-panel-cell (key description &optional width)
  "Return a styled command-panel cell for KEY and DESCRIPTION.

Pad the returned cell to WIDTH columns when WIDTH is non-nil."
  (let ((cell
         (concat
          (propertize key 'face 'bitbucket-devops-command-panel-key-face)
          " "
          description)))
    (if width
        (format (format "%%-%ds" width) cell)
      cell)))

(defun bitbucket-devops-ui--command-panel-heading (heading &optional width)
  "Return styled command-panel HEADING padded to WIDTH columns."
  (let ((cell
         (propertize
          heading
          'face
          'bitbucket-devops-command-panel-heading-face)))
    (if width
        (format (format "%%-%ds" width) cell)
      cell)))

(defun bitbucket-devops-ui--can-go-back-p (&optional buffer)
  "Return non-nil when BUFFER has a valid previous package UI screen."
  (with-current-buffer (or buffer (current-buffer))
    (or
     (and
      (buffer-live-p bitbucket-devops-ui--previous-buffer)
      (with-current-buffer bitbucket-devops-ui--previous-buffer
        (derived-mode-p
         'bitbucket-devops-pipelines-history-mode
         'bitbucket-devops-pipelines-details-mode
         'bitbucket-devops-pipelines-log-mode
         'bitbucket-devops-pipelines-watch-list-mode
         'bitbucket-devops-pull-requests-list-mode
         'bitbucket-devops-pull-requests-detail-mode
         'bitbucket-devops-pull-requests-diff-mode
         'bitbucket-devops-pull-requests-commits-mode
         'bitbucket-devops-pull-requests-activity-mode)))
     (fboundp 'bitbucket-devops-dispatch))))

(defun bitbucket-devops-ui--command-panel-back-cell (&optional width)
  "Return a Back command cell only when the current buffer can go back.

Pad the returned cell to WIDTH columns when WIDTH is non-nil."
  (if (bitbucket-devops-ui--can-go-back-p)
      (bitbucket-devops-ui--command-panel-cell "-" "Back" width)
    (if width
        (bitbucket-devops-ui--command-panel-cell "" "" width)
      "")))

(defun bitbucket-devops-ui--command-panel-help-cell (&optional width)
  "Return the command-panel help cell.

Pad the returned cell to WIDTH columns when WIDTH is non-nil."
  (bitbucket-devops-ui--command-panel-cell "?" "Help" width))

(defun bitbucket-devops-ui--pull-request-readiness-action ()
  "Return the state-aware pull request draft action label."
  (if (and
       (boundp 'bitbucket-devops-pull-requests-ui--details-pull-request)
       (eq (alist-get
            'draft
            bitbucket-devops-pull-requests-ui--details-pull-request)
           t))
      "Mark ready"
    "Mark draft"))

(defun bitbucket-devops-ui--pull-request-key (command fallback)
  "Return configured pull request key for COMMAND or FALLBACK."
  (or (and (fboundp 'bitbucket-devops-pull-requests-ui-key-for-command)
           (bitbucket-devops-pull-requests-ui-key-for-command command))
      fallback))

(defun bitbucket-devops-ui--pull-request-command-keys (command fallback)
  "Return configured pull request keys for COMMAND as a display label.

Use FALLBACK when no configured key is available."
  (if (fboundp 'bitbucket-devops-pull-requests-ui-keys-for-command)
      (let ((keys (bitbucket-devops-pull-requests-ui-keys-for-command command)))
        (if keys
            (string-join keys "/")
          fallback))
    fallback))

(defun bitbucket-devops-ui--pull-request-keys
    (first second first-fallback second-fallback)
  "Return a display label for two configured pull request commands."
  (format
   "%s/%s"
   (bitbucket-devops-ui--pull-request-key first first-fallback)
   (bitbucket-devops-ui--pull-request-key second second-fallback)))

(defun bitbucket-devops-ui--command-panel-lines (buffer)
  "Return command-panel text for Bitbucket Pipelines UI BUFFER."
  (with-current-buffer buffer
    (cond
     ((derived-mode-p 'bitbucket-devops-pipelines-history-mode)
      (concat
       (bitbucket-devops-ui--command-panel-heading "Navigate" 28)
       (bitbucket-devops-ui--command-panel-heading "Pipeline" 28)
       (bitbucket-devops-ui--command-panel-heading "Filters")
       "\n"
       (bitbucket-devops-ui--command-panel-cell "RET" "Details" 28)
       (bitbucket-devops-ui--command-panel-cell "d" "Download logs" 28)
       (bitbucket-devops-ui--command-panel-cell "f" "Choose branch")
       "\n"
       (bitbucket-devops-ui--command-panel-back-cell 28)
       (bitbucket-devops-ui--command-panel-cell "t" "Track" 28)
       (bitbucket-devops-ui--command-panel-cell "s" "Status")
       "\n"
       (bitbucket-devops-ui--command-panel-cell "r" "Refresh" 28)
       (bitbucket-devops-ui--command-panel-cell "R" "Run pipeline" 28)
       (bitbucket-devops-ui--command-panel-cell "q" "Quit")
       "\n"
       (bitbucket-devops-ui--command-panel-cell "TAB" "Expand column" 28)
       (bitbucket-devops-ui--command-panel-cell "n" "More")
       "\n"
       (bitbucket-devops-ui--command-panel-help-cell)
       "\n"))
     ((derived-mode-p 'bitbucket-devops-pipelines-details-mode)
      (concat
       (bitbucket-devops-ui--command-panel-heading "Navigate" 28)
       (bitbucket-devops-ui--command-panel-heading "Logs" 28)
       (bitbucket-devops-ui--command-panel-heading "Pipeline")
       "\n"
       (bitbucket-devops-ui--command-panel-cell "RET" "View log" 28)
       (bitbucket-devops-ui--command-panel-cell "d" "Download selected" 28)
       (bitbucket-devops-ui--command-panel-cell "t" "Track")
       "\n"
       (bitbucket-devops-ui--command-panel-back-cell 28)
       (bitbucket-devops-ui--command-panel-cell "D" "Download all" 28)
       (bitbucket-devops-ui--command-panel-cell "R" "Rerun")
       "\n"
       (bitbucket-devops-ui--command-panel-cell "r" "Refresh" 28)
       (bitbucket-devops-ui--command-panel-cell "" "" 28)
       (bitbucket-devops-ui--command-panel-cell "s" "Stop")
       "\n"
       (bitbucket-devops-ui--command-panel-cell "q" "Quit")
       (bitbucket-devops-ui--command-panel-cell "" "" 28)
       (bitbucket-devops-ui--command-panel-cell "c" "Continue")
       "\n"
       (bitbucket-devops-ui--command-panel-help-cell)
       "\n"))
     ((derived-mode-p 'bitbucket-devops-pipelines-log-mode)
      (concat
       (bitbucket-devops-ui--command-panel-heading "Navigate")
       "\n"
       (when (bitbucket-devops-ui--can-go-back-p)
         (concat
          (bitbucket-devops-ui--command-panel-cell "-" "Back")
          "\n"))
       (bitbucket-devops-ui--command-panel-cell "q" "Quit")
       "\n"
       (bitbucket-devops-ui--command-panel-help-cell)
       "\n"))
     ((derived-mode-p 'bitbucket-devops-pipelines-watch-list-mode)
      (concat
       (bitbucket-devops-ui--command-panel-heading "Tracking")
       "\n"
       (bitbucket-devops-ui--command-panel-cell "m" "Toggle Magit push tracking")
       "\n"
       (bitbucket-devops-ui--command-panel-cell "x" "Stop selected tracker")
       "\n"
       (when (bitbucket-devops-ui--can-go-back-p)
         (concat
          (bitbucket-devops-ui--command-panel-cell "-" "Back")
          "\n"))
       (bitbucket-devops-ui--command-panel-cell "q" "Quit")
       "\n"
       (bitbucket-devops-ui--command-panel-help-cell)
       "\n"))
     ((derived-mode-p 'bitbucket-devops-pull-requests-list-mode)
      (concat
       (bitbucket-devops-ui--command-panel-heading "Navigate" 28)
       (bitbucket-devops-ui--command-panel-heading "Pull Request" 28)
       (bitbucket-devops-ui--command-panel-heading "Filters")
       "\n"
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-pull-requests-ui-open-at-point "RET")
        "Details" 28)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-pull-requests-ui-create "c")
        "Create" 28)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-pull-requests-ui-set-state-filter "s")
        "State")
       "\n"
       (bitbucket-devops-ui--command-panel-back-cell 28)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-pull-requests-ui-refresh-current "C-c g")
        "Refresh" 28)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-pull-requests-ui-set-branch-filter "f")
        "Branch")
       "\n"
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-ui-quit "q")
        "Quit" 28)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-pull-requests-ui-load-more "n")
        "More" 28)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-pull-requests-ui-set-author-filter "a")
        "Author")
       "\n"
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-pull-requests-ui-copy-browser-url-at-point "S-RET")
        "Copy browser link" 28)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-command-keys
         'bitbucket-devops-pull-requests-ui-run-pipeline "P")
        "Run pipeline" 28)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-pull-requests-ui-browse "o")
        "Browser")
       "\n"
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-pull-requests-ui-checkout-source-branch "C-c b")
        "Checkout branch" 28)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-command-keys
         'bitbucket-devops-pull-requests-ui-toggle-comment-watch "C-c w")
        "Watch comments" 28)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-ui-show-command-panel "?")
        "Help")
       "\n"))
     ((derived-mode-p 'bitbucket-devops-pull-requests-detail-mode)
      (concat
       (bitbucket-devops-ui--command-panel-heading "Navigate" 24)
       (bitbucket-devops-ui--command-panel-heading "Review" 34)
       (bitbucket-devops-ui--command-panel-heading "Discuss")
       "\n"
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-keys
         'bitbucket-devops-pull-requests-ui-open-diff
         'bitbucket-devops-pull-requests-ui-choose-diff-viewer
         "d" "C-c d")
        "Diff / choose" 24)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-keys
         'bitbucket-devops-pull-requests-ui-approve
         'bitbucket-devops-pull-requests-ui-remove-approval "a" "u")
        "Approve / remove" 34)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-keys
         'bitbucket-devops-pull-requests-ui-add-comment
         'bitbucket-devops-pull-requests-ui-reply-to-comment "c" "C")
        "Comment / reply")
       "\n"
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-pull-requests-ui-open-commits "m")
        "Commits" 24)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-keys
         'bitbucket-devops-pull-requests-ui-request-changes
         'bitbucket-devops-pull-requests-ui-remove-request-changes "x" "X")
        "Changes / remove" 34)
       (bitbucket-devops-ui--command-panel-cell
        (format
         "%s/%s/%s"
         (bitbucket-devops-ui--pull-request-key
          'bitbucket-devops-pull-requests-ui-add-reviewer "C-c +")
         (bitbucket-devops-ui--pull-request-key
          'bitbucket-devops-pull-requests-ui-add-default-reviewers "C-c =")
         (bitbucket-devops-ui--pull-request-key
          'bitbucket-devops-pull-requests-ui-remove-reviewer "C-c -"))
        "Reviewer add/default/remove")
       "\n"
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-pull-requests-ui-open-activity "A")
        "Activity" 24)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-keys
         'bitbucket-devops-pull-requests-ui-merge
         'bitbucket-devops-pull-requests-ui-decline "M" "D")
        "Merge / decline" 34)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-keys
         'bitbucket-devops-pull-requests-ui-edit-comment
         'bitbucket-devops-pull-requests-ui-delete-comment "C-c e" "C-c k")
        "Edit / delete comment")
       "\n"
       (bitbucket-devops-ui--command-panel-back-cell 24)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-pull-requests-ui-refresh-current "r")
        "Refresh" 34)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-keys
         'bitbucket-devops-pull-requests-ui-resolve-comment
         'bitbucket-devops-pull-requests-ui-reopen-comment "C-c r" "C-c o")
        "Resolve / reopen")
       "\n"
       (bitbucket-devops-ui--command-panel-cell "q" "Quit" 24)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-pull-requests-ui-edit-metadata "C-c p e")
        "Edit title / Markdown" 34)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-pull-requests-ui-create-task "C-c t c")
        "Task create")
       "\n"
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-command-keys
         'bitbucket-devops-pull-requests-ui-run-pipeline "P")
        "Run pipeline" 24)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-command-keys
         'bitbucket-devops-pull-requests-ui-toggle-draft "R")
        "Toggle ready/draft" 34)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-keys
         'bitbucket-devops-pull-requests-ui-resolve-task
         'bitbucket-devops-pull-requests-ui-reopen-task "C-c t r" "C-c t o")
        "Task resolve / reopen")
       "\n"
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-pull-requests-ui-checkout-source-branch "C-c b")
        "Checkout branch" 24)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-pull-requests-ui-add-inline-comment "C-c i")
        "Inline comment" 34)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-pull-requests-ui-browse "o")
        "Browser")
       "\n"
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-command-keys
         'bitbucket-devops-pull-requests-ui-toggle-comment-watch "C-c w")
        "Watch comments" 24)
       (bitbucket-devops-ui--command-panel-cell "" "" 34)
       "\n"
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-pull-requests-ui-open-detail-at-point "RET")
        "Action at point" 24)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-pull-requests-ui-copy-browser-url-at-point "S-RET")
        "Copy browser link" 34)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-ui-show-command-panel "?")
        "Help")
       "\n"))
     ((derived-mode-p 'bitbucket-devops-pull-requests-diff-mode)
      (concat
       (bitbucket-devops-ui--command-panel-heading "Navigate" 28)
       (bitbucket-devops-ui--command-panel-heading "Discuss")
       "\n"
       (bitbucket-devops-ui--command-panel-back-cell 28)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-pull-requests-ui-add-inline-comment "i")
        "Inline comment")
       "\n"
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-pull-requests-ui-refresh-current "C-c g")
        "Refresh" 28)
       "\n"
       (bitbucket-devops-ui--command-panel-cell "q" "Quit" 28)
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-ui-show-command-panel "?")
        "Help")
       "\n"))
     ((derived-mode-p 'bitbucket-devops-pull-requests-commits-mode)
      (concat
       (bitbucket-devops-ui--command-panel-heading "Navigate")
       "\n"
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-pull-requests-ui-open-commit-at-point "RET")
        "Open commit")
       "\n"
       (bitbucket-devops-ui--command-panel-back-cell)
       "\n"
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-pull-requests-ui-refresh-current "C-c g")
        "Refresh")
       "\n"
       (bitbucket-devops-ui--command-panel-cell "q" "Quit")
       "\n"
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-ui-show-command-panel "?")
        "Help")
       "\n"))
     ((derived-mode-p 'bitbucket-devops-pull-requests-activity-mode)
      (concat
       (bitbucket-devops-ui--command-panel-heading "Navigate")
       "\n"
       (bitbucket-devops-ui--command-panel-back-cell)
       "\n"
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-pull-requests-ui-refresh-current "C-c g")
        "Refresh")
       "\n"
       (bitbucket-devops-ui--command-panel-cell "q" "Quit")
       "\n"
       (bitbucket-devops-ui--command-panel-cell
        (bitbucket-devops-ui--pull-request-key
         'bitbucket-devops-ui-show-command-panel "?")
        "Help")
       "\n"))
     (t ""))))

(defun bitbucket-devops-ui--command-panel-policy ()
  "Return the normalized command-panel display policy."
  (cond
   ((memq bitbucket-devops-command-panel-enabled '(t always)) 'always)
   ((memq bitbucket-devops-command-panel-enabled '(nil manual)) 'manual)
   ((eq bitbucket-devops-command-panel-enabled 'never) 'never)
   (t 'always)))

(defun bitbucket-devops-ui--command-panel-displayed-p (&optional buffer)
  "Return non-nil when BUFFER owns a visible command panel."
  (let ((buffer (or buffer (current-buffer))))
    (and (eq bitbucket-devops-ui--command-panel-owner buffer)
         (get-buffer-window
          bitbucket-devops-ui--command-panel-buffer-name t))))

(defun bitbucket-devops-ui--display-command-panel (buffer &optional force)
  "Show the persistent command panel for Bitbucket Pipelines UI BUFFER.

When FORCE is non-nil, show the panel under the manual display policy."
  (let ((policy (bitbucket-devops-ui--command-panel-policy)))
    (if (or (eq policy 'never)
            (and (not force)
                 (not (eq policy 'always))))
        (progn
          (bitbucket-devops-ui--delete-command-panel)
          nil)
      (setq bitbucket-devops-ui--command-panel-owner buffer)
      (with-current-buffer buffer
        (add-hook 'kill-buffer-hook
                  #'bitbucket-devops-ui--delete-owned-command-panel nil t))
      (let ((panel
             (get-buffer-create
              bitbucket-devops-ui--command-panel-buffer-name)))
        (with-current-buffer panel
          (bitbucket-devops-command-panel-mode)
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (bitbucket-devops-ui--command-panel-lines buffer))
            (goto-char (point-min))))
        (let* ((height
                (with-current-buffer panel
                  (max bitbucket-devops-command-panel-height
                       (count-lines (point-min) (point-max)))))
               (window
                (display-buffer
                 panel
                 `((display-buffer-in-side-window)
                   (side . ,bitbucket-devops-command-panel-side)
                   (slot . 0)
                   (window-height . ,height)))))
          (when (window-live-p window)
            (fit-window-to-buffer window height height)
            (set-window-dedicated-p window t)
            (set-window-parameter window 'no-other-window t))
          (add-hook 'buffer-list-update-hook
                    #'bitbucket-devops-ui--delete-unselected-command-panel)
          window)))))

(defun bitbucket-devops-ui--delete-owned-command-panel ()
  "Delete the command panel when its owning UI buffer is killed."
  (when (eq (current-buffer) bitbucket-devops-ui--command-panel-owner)
    (bitbucket-devops-ui--delete-command-panel)))

(defun bitbucket-devops-ui--command-panel-owner-selected-p ()
  "Return non-nil when the command panel owner is still selected."
  (and
   (buffer-live-p bitbucket-devops-ui--command-panel-owner)
   (or
    (eq (window-buffer (selected-window))
        bitbucket-devops-ui--command-panel-owner)
    (when-let ((minibuffer-window (active-minibuffer-window))
               (source-window (minibuffer-selected-window)))
      (and (eq (selected-window) minibuffer-window)
           (eq (window-buffer source-window)
               bitbucket-devops-ui--command-panel-owner))))))

(defun bitbucket-devops-ui--delete-unselected-command-panel ()
  "Delete the command panel after selecting a buffer other than its owner."
  (when (and bitbucket-devops-ui--command-panel-owner
             (not (bitbucket-devops-ui--command-panel-owner-selected-p)))
    (bitbucket-devops-ui--delete-command-panel)))

(defun bitbucket-devops-ui--delete-command-panel ()
  "Delete the Bitbucket Pipelines command panel buffer and its windows."
  (remove-hook 'buffer-list-update-hook
               #'bitbucket-devops-ui--delete-unselected-command-panel)
  (setq bitbucket-devops-ui--command-panel-owner nil)
  (when-let ((panel
              (get-buffer bitbucket-devops-ui--command-panel-buffer-name)))
    (dolist (window (get-buffer-window-list panel nil t))
      (when (window-live-p window)
        (set-window-dedicated-p window nil)
        (condition-case nil
            (delete-window window)
          (error
           (quit-window nil window)))))
    (when (buffer-live-p panel)
      (kill-buffer panel))))

(defun bitbucket-devops-ui--buffer-p (&optional buffer)
  "Return non-nil when BUFFER is a Bitbucket Pipelines UI buffer."
  (with-current-buffer (or buffer (current-buffer))
    (derived-mode-p
     'bitbucket-devops-pipelines-history-mode
     'bitbucket-devops-pipelines-details-mode
     'bitbucket-devops-pipelines-log-mode
     'bitbucket-devops-pipelines-watch-list-mode
     'bitbucket-devops-pull-requests-list-mode
     'bitbucket-devops-pull-requests-detail-mode
     'bitbucket-devops-pull-requests-diff-mode
     'bitbucket-devops-pull-requests-commits-mode
     'bitbucket-devops-pull-requests-activity-mode)))

(defun bitbucket-devops-ui-show-command-panel ()
  "Toggle the Bitbucket DevOps command panel for the current UI buffer."
  (interactive)
  (unless (bitbucket-devops-ui--buffer-p)
    (user-error "This command requires a Bitbucket DevOps UI buffer"))
  (cond
   ((bitbucket-devops-ui--command-panel-displayed-p)
    (bitbucket-devops-ui--delete-command-panel)
    (message "Hid Bitbucket DevOps keybindings"))
   ((eq (bitbucket-devops-ui--command-panel-policy) 'never)
    (message "Bitbucket DevOps keybindings are disabled"))
   (t
    (bitbucket-devops-ui--display-command-panel (current-buffer) t)
    (message "Displayed Bitbucket DevOps keybindings"))))

(defun bitbucket-devops-ui-quit ()
  "Kill the current Bitbucket DevOps screen and remove its command panel."
  (interactive)
  (bitbucket-devops-ui--delete-command-panel)
  (kill-current-buffer))

(defun bitbucket-devops-ui--display-buffer
    (buffer &optional select previous-buffer)
  "Display BUFFER according to the Bitbucket Pipelines UI preference.

SELECT means select BUFFER under the default display policy.  PREVIOUS-BUFFER
is the package UI screen used by `bitbucket-devops-ui-back'."
  (when (and (buffer-live-p previous-buffer)
             (bitbucket-devops-ui--buffer-p previous-buffer))
    (with-current-buffer buffer
      (setq-local bitbucket-devops-ui--previous-buffer previous-buffer)))
  (if bitbucket-devops-fullscreen-buffers
      (progn
        (delete-other-windows)
        (switch-to-buffer buffer))
    (if select
        (pop-to-buffer buffer)
      (display-buffer buffer)))
  (with-current-buffer buffer
    (when (derived-mode-p
           'bitbucket-devops-pipelines-history-mode
           'bitbucket-devops-pipelines-details-mode)
      (bitbucket-devops-ui--disable-line-wrapping)))
  (bitbucket-devops-ui--display-command-panel buffer)
  buffer)

(defun bitbucket-devops-ui-back ()
  "Return to the prior Bitbucket DevOps UI screen or main dispatch."
  (interactive)
  (cond
   ((and
     (buffer-live-p bitbucket-devops-ui--previous-buffer)
     (bitbucket-devops-ui--buffer-p bitbucket-devops-ui--previous-buffer))
    (bitbucket-devops-ui--display-buffer
     bitbucket-devops-ui--previous-buffer
     t))
   ((fboundp 'bitbucket-devops-dispatch)
    (call-interactively #'bitbucket-devops-dispatch))
   (t
    (setq-local bitbucket-devops-ui--previous-buffer nil)
    (user-error "No previous Bitbucket DevOps screen is available"))))

(defun bitbucket-devops-ui--history-receive-page (page request-error append)
  "Render history PAGE or REQUEST-ERROR in the current buffer.

Append rows to prior pages when APPEND is non-nil."
  (setq bitbucket-devops-ui--history-loading nil)
  (if request-error
      (message "Unable to load Bitbucket pipeline history: %s"
               (plist-get request-error :message))
    (let* ((pipelines (bitbucket-devops-rest-page-values page))
           (display-pipelines
            (if bitbucket-devops-cache-enabled
                (bitbucket-devops-cache-merge-pipelines
                 bitbucket-devops-ui--context
                 pipelines)
              (if append
                  (append bitbucket-devops-ui--history-pipelines pipelines)
                pipelines))))
      (setq bitbucket-devops-ui--history-pipelines
            display-pipelines)
      (setq bitbucket-devops-ui--history-next-url
            (bitbucket-devops-rest-page-next page))
      (bitbucket-devops-ui--history-render))))

(defun bitbucket-devops-ui--merge-pipeline-pages (page additional-pipelines)
  "Return PAGE with unique ADDITIONAL-PIPELINES merged by UUID."
  (let ((merged (copy-tree page))
        (seen (make-hash-table :test #'equal))
        values)
    (dolist (pipeline
             (append
              (bitbucket-devops-rest-page-values page)
              additional-pipelines))
      (let ((uuid (alist-get 'uuid pipeline)))
        (unless (and uuid (gethash uuid seen))
          (when uuid
            (puthash uuid t seen))
          (push pipeline values))))
    (setf (alist-get 'values merged) (nreverse values))
    merged))

(defun bitbucket-devops-ui--list-all-paused-pipelines
    (context callback &optional next-url pipelines)
  "Collect paused pipelines from CONTEXT and invoke CALLBACK.

Follow Bitbucket pagination from NEXT-URL and append records to PIPELINES.
CALLBACK receives the complete list and an error plist."
  (bitbucket-devops-rest-list-paused-pipelines
   context
   (lambda (page request-error)
     (if request-error
         (funcall callback nil request-error)
       (let ((pipelines
              (append pipelines
                      (bitbucket-devops-rest-page-values page))))
         (if-let ((next (bitbucket-devops-rest-page-next page)))
             (bitbucket-devops-ui--list-all-paused-pipelines
              context callback next pipelines)
           (funcall callback pipelines nil)))))
   next-url))

(defun bitbucket-devops-ui--commit-cache-key (context hash)
  "Return the cache key for HASH in repository CONTEXT."
  (list
   (plist-get context :workspace)
   (plist-get context :repo-slug)
   hash))

(defun bitbucket-devops-ui--deployment-cache-key (context pipeline-uuid)
  "Return the deployment cache key for PIPELINE-UUID in repository CONTEXT."
  (list
   (plist-get context :workspace)
   (plist-get context :repo-slug)
   pipeline-uuid))

(defun bitbucket-devops-ui--alist-set (object key value)
  "Destructively set KEY to VALUE in alist OBJECT."
  (if-let ((cell (assq key object)))
      (setcdr cell value)
    (nconc object (list (cons key value)))))

(defun bitbucket-devops-ui--set-pipeline-deployments (pipeline deployments)
  "Attach DEPLOYMENTS to PIPELINE for UI rendering."
  (bitbucket-devops-ui--alist-set
   pipeline
   'bitbucket-devops-pipelines-deployments
   deployments))

(defun bitbucket-devops-ui--annotate-steps-deployments (steps deployments)
  "Attach DEPLOYMENTS environment names to matching STEPS."
  (dolist (step steps)
    (bitbucket-devops-ui--alist-set
     step
     'bitbucket-devops-pipelines-deployment
     nil))
  (dolist (deployment deployments)
    (when-let* ((step-uuid
                 (bitbucket-devops-ui--nested-get deployment 'step 'uuid))
                (step
                 (bitbucket-devops-ui--find-by-uuid step-uuid steps)))
      (bitbucket-devops-ui--alist-set
       step
       'bitbucket-devops-pipelines-deployment
       (bitbucket-devops-ui--deployment-environment-name
        deployment)))))

(defun bitbucket-devops-ui--list-all-deployments
    (context pipeline-uuid callback &optional next-url deployments)
  "Fetch PIPELINE-UUID deployments from CONTEXT and invoke CALLBACK.

Follow Bitbucket pagination from NEXT-URL.  Append records to DEPLOYMENTS while
loading.  CALLBACK receives the complete deployment list and an error plist."
  (bitbucket-devops-rest-list-deployments
   context
   pipeline-uuid
   (lambda (page request-error)
     (if request-error
         (funcall callback nil request-error)
       (let ((all-deployments
              (append deployments
                      (bitbucket-devops-rest-page-values page))))
         (if-let ((next (bitbucket-devops-rest-page-next page)))
           (bitbucket-devops-ui--list-all-deployments
              context
              pipeline-uuid
              callback
              next
              all-deployments)
           (funcall
            callback
            (seq-filter
             (lambda (deployment)
               (bitbucket-devops-ui--deployment-matches-pipeline-p
                deployment
                pipeline-uuid))
             all-deployments)
            nil)))))
   next-url))

(defun bitbucket-devops-ui--ensure-pipeline-deployments
    (context pipeline callback)
  "Attach deployments to PIPELINE from CONTEXT, then invoke CALLBACK.

Use cached records for terminal pipelines.  CALLBACK receives PIPELINE and an
error plist."
  (let* ((pipeline-uuid (alist-get 'uuid pipeline))
         (key
          (bitbucket-devops-ui--deployment-cache-key
           context
           pipeline-uuid))
         (missing (make-symbol "missing"))
         (cached (gethash key bitbucket-devops-ui--deployment-cache missing))
         (persistent-cached-p
          (bitbucket-devops-cache-deployments-cached-p
           context
           pipeline-uuid))
         (persistent-cache
          (when persistent-cached-p
            (bitbucket-devops-cache-lookup-deployments
             context
             pipeline-uuid))))
    (cond
     ((not (eq cached missing))
      (bitbucket-devops-ui--set-pipeline-deployments pipeline cached)
      (funcall callback pipeline nil))
     (persistent-cached-p
      (puthash key persistent-cache bitbucket-devops-ui--deployment-cache)
      (bitbucket-devops-ui--set-pipeline-deployments
       pipeline
       persistent-cache)
      (funcall callback pipeline nil))
     (t
      (bitbucket-devops-ui--list-all-deployments
       context
       pipeline-uuid
       (lambda (deployments request-error)
         (unless request-error
           (when (equal
                  (bitbucket-devops-ui--nested-get pipeline 'state 'name)
                  "COMPLETED")
             (puthash
              key
              deployments
              bitbucket-devops-ui--deployment-cache)
             (bitbucket-devops-cache-put-deployments
              context
              pipeline-uuid
              deployments))
           (bitbucket-devops-ui--set-pipeline-deployments
            pipeline
            deployments))
         (funcall callback pipeline request-error)))))))

(defun bitbucket-devops-ui--history-enrich-deployments
    (context page callback)
  "Attach deployments to pipelines in PAGE for CONTEXT, then invoke CALLBACK."
  (let ((pipelines (bitbucket-devops-rest-page-values page)))
    (if (null pipelines)
        (funcall callback page)
      (let ((remaining (length pipelines))
            errors)
        (dolist (pipeline pipelines)
          (bitbucket-devops-ui--ensure-pipeline-deployments
           context
           pipeline
           (lambda (_enriched-pipeline request-error)
             (when request-error
               (push request-error errors))
             (setq remaining (1- remaining))
             (when (zerop remaining)
               (when errors
                 (message "Unable to load Bitbucket deployment metadata"))
               (funcall callback page)))))))))

(defun bitbucket-devops-ui--pipeline-commit (pipeline)
  "Return PIPELINE's embedded commit record."
  (bitbucket-devops-ui--nested-get pipeline 'target 'commit))

(defun bitbucket-devops-ui--pipeline-needs-commit-details-p (pipeline)
  "Return non-nil when PIPELINE lacks full embedded commit details."
  (let ((commit (bitbucket-devops-ui--pipeline-commit pipeline)))
    (and (alist-get 'hash commit)
         (or (not (alist-get 'message commit))
             (not (bitbucket-devops-ui--nested-get commit 'author 'raw))))))

(defun bitbucket-devops-ui--set-pipeline-commit (pipeline commit)
  "Replace PIPELINE's abbreviated commit record with full COMMIT details."
  (when-let ((cell (assq 'commit (alist-get 'target pipeline))))
    (setcdr cell (copy-tree commit))))

(defun bitbucket-devops-ui--history-apply-cached-commits (context page)
  "Apply cached commit details for CONTEXT to pipelines in PAGE."
  (dolist (pipeline (bitbucket-devops-rest-page-values page))
    (when-let* ((hash
                 (alist-get
                  'hash
                  (bitbucket-devops-ui--pipeline-commit pipeline)))
                (commit
                 (or
                  (gethash
                   (bitbucket-devops-ui--commit-cache-key context hash)
                   bitbucket-devops-ui--commit-cache)
                  (when-let ((persistent-commit
                              (bitbucket-devops-cache-lookup-commit
                               context
                               hash)))
                    (puthash
                     (bitbucket-devops-ui--commit-cache-key context hash)
                     persistent-commit
                     bitbucket-devops-ui--commit-cache)
                    persistent-commit))))
      (bitbucket-devops-ui--set-pipeline-commit pipeline commit))))

(defun bitbucket-devops-ui--history-enrich-page (context page callback)
  "Enrich abbreviated commits in PAGE for CONTEXT, then invoke CALLBACK.

Bitbucket's pipeline list embeds commit hashes and links but omits commit
messages and authors.  Fetch each missing unique commit once and cache it."
  (bitbucket-devops-ui--history-apply-cached-commits context page)
  (let (hashes)
    (dolist (pipeline (bitbucket-devops-rest-page-values page))
      (when (bitbucket-devops-ui--pipeline-needs-commit-details-p pipeline)
        (cl-pushnew
         (alist-get 'hash (bitbucket-devops-ui--pipeline-commit pipeline))
         hashes
         :test #'equal)))
    (if (null hashes)
        (funcall callback page)
      (let ((remaining (length hashes))
            errors)
        (dolist (hash hashes)
          (let ((hash hash))
            (bitbucket-devops-rest-get-commit
             context
             hash
             (lambda (commit request-error)
               (unless request-error
                 (puthash
                  (bitbucket-devops-ui--commit-cache-key context hash)
                  commit
                  bitbucket-devops-ui--commit-cache)
                 (bitbucket-devops-cache-put-commit
                  context
                  hash
                  commit))
               (when request-error
                 (push request-error errors))
               (setq remaining (1- remaining))
               (when (zerop remaining)
                 (bitbucket-devops-ui--history-apply-cached-commits
                  context
                  page)
                 (when errors
                   (message
                    (concat
                     "Unable to load Bitbucket commit metadata; "
                     "grant the token Repositories Read permission")))
                 (funcall callback page))))))))))

(defun bitbucket-devops-ui--history-render ()
  "Render pipelines matching the current history buffer filters."
  (bitbucket-devops-ui--preserve-visible-window-positions
   (lambda ()
     (setq tabulated-list-entries
           (mapcar
            #'bitbucket-devops-ui--pipeline-row
            (bitbucket-devops-ui--history-filter-pipelines
             bitbucket-devops-ui--history-pipelines)))
     (tabulated-list-print t)
     (bitbucket-devops-ui--disable-line-wrapping))))

(defun bitbucket-devops-ui--history-load-cache ()
  "Load cached pipeline history into the current history buffer."
  (when (and bitbucket-devops-cache-enabled
             bitbucket-devops-ui--context)
    (let ((pipelines
           (bitbucket-devops-cache-pipelines
            bitbucket-devops-ui--context)))
      (when pipelines
        (setq bitbucket-devops-ui--history-pipelines pipelines)
        (bitbucket-devops-ui--history-render)))))

(defun bitbucket-devops-ui--sync-count (value)
  "Return VALUE when it is a positive integer, otherwise zero."
  (if (and (integerp value) (> value 0)) value 0))

(defun bitbucket-devops-ui--active-pipeline-p (pipeline)
  "Return non-nil when PIPELINE can still change state."
  (not (bitbucket-devops-ui--pipeline-terminal-p pipeline)))

(defun bitbucket-devops-ui--pipeline-sync-candidates (pipelines)
  "Return pipelines selected for detail revalidation."
  (let* ((sorted (bitbucket-devops-cache--sort-pipelines pipelines))
         (always-count
          (bitbucket-devops-ui--sync-count
           bitbucket-devops-pipelines-sync-always-count))
         (active-count
          (bitbucket-devops-ui--sync-count
           bitbucket-devops-pipelines-sync-active-count))
         (seen (make-hash-table :test #'equal))
         candidates)
    (dolist (pipeline
             (append
              (seq-take sorted always-count)
              (seq-filter
               #'bitbucket-devops-ui--active-pipeline-p
               (seq-take sorted active-count))))
      (when-let ((uuid (alist-get 'uuid pipeline)))
        (unless (gethash uuid seen)
          (puthash uuid t seen)
          (push pipeline candidates))))
    (nreverse candidates)))

(defun bitbucket-devops-ui--preserve-local-pipeline-fields
    (fresh-pipeline cached-pipeline)
  "Return FRESH-PIPELINE with local fields from CACHED-PIPELINE."
  (let ((updated (copy-tree fresh-pipeline)))
    (when-let ((deployments
                (and cached-pipeline
                     (alist-get
                      'bitbucket-devops-pipelines-deployments
                      cached-pipeline))))
      (unless (alist-get 'bitbucket-devops-pipelines-deployments updated)
        (bitbucket-devops-ui--alist-set
         updated
         'bitbucket-devops-pipelines-deployments
         deployments)))
    (let ((fresh-commit (bitbucket-devops-ui--pipeline-commit updated))
          (cached-commit
           (and cached-pipeline
                (bitbucket-devops-ui--pipeline-commit cached-pipeline))))
      (when (and fresh-commit
                 cached-commit
                 (equal (alist-get 'hash fresh-commit)
                        (alist-get 'hash cached-commit))
                 (bitbucket-devops-ui--pipeline-needs-commit-details-p updated)
                 (or (alist-get 'message cached-commit)
                     (bitbucket-devops-ui--nested-get
                      cached-commit
                      'author
                      'raw)))
        (bitbucket-devops-ui--set-pipeline-commit updated cached-commit)))
    updated))

(defun bitbucket-devops-ui--replace-loaded-pipeline (pipeline)
  "Replace or add PIPELINE in the current history buffer by UUID."
  (when-let ((uuid (alist-get 'uuid pipeline)))
    (let* ((existing
            (seq-find
             (lambda (candidate)
               (equal (alist-get 'uuid candidate) uuid))
             bitbucket-devops-ui--history-pipelines))
           (updated
            (bitbucket-devops-ui--preserve-local-pipeline-fields
             pipeline
             existing))
           replaced)
      (setq bitbucket-devops-ui--history-pipelines
            (mapcar
             (lambda (candidate)
               (if (equal (alist-get 'uuid candidate) uuid)
                   (progn
                     (setq replaced t)
                     updated)
                 candidate))
             bitbucket-devops-ui--history-pipelines))
      (unless replaced
        (push updated bitbucket-devops-ui--history-pipelines))
      (setq bitbucket-devops-ui--history-pipelines
            (if (and bitbucket-devops-cache-enabled
                     bitbucket-devops-ui--context)
                (bitbucket-devops-cache-merge-pipelines
                 bitbucket-devops-ui--context
                 (list updated))
              (bitbucket-devops-cache--sort-pipelines
               bitbucket-devops-ui--history-pipelines)))
      (bitbucket-devops-ui--history-render))))

(defun bitbucket-devops-ui--refresh-loaded-pipelines (context generation)
  "Refetch configured loaded pipelines for CONTEXT.

GENERATION is used to ignore callbacks from stale history refreshes."
  (let ((buffer (current-buffer)))
    (dolist (pipeline
             (bitbucket-devops-ui--pipeline-sync-candidates
              bitbucket-devops-ui--history-pipelines))
      (let ((pipeline-uuid (alist-get 'uuid pipeline)))
        (bitbucket-devops-rest-get-pipeline
         context
         pipeline-uuid
         (lambda (fresh-pipeline error)
           (when (and (buffer-live-p buffer)
                      (= generation
                         (buffer-local-value
                          'bitbucket-devops-ui--history-request-generation
                          buffer)))
             (with-current-buffer buffer
               (if error
                   (message
                    "Unable to refresh Bitbucket pipeline %s: %s"
                    pipeline-uuid
                    (or (plist-get error :message) error))
                 (bitbucket-devops-ui--replace-loaded-pipeline
                  fresh-pipeline))))))))))

(defun bitbucket-devops-pipelines-history-column-at-point ()
  "Return the zero-based history column index at point."
  (let ((column (current-column))
        (index 0)
        (start 0)
        match)
    (while (and (< index (length tabulated-list-format)) (not match))
      (let* ((spec (aref tabulated-list-format index))
             (width (cadr spec))
             (end (if (zerop width) most-positive-fixnum (+ start width))))
        (when (and (>= column start) (< column end))
          (setq match index))
        (setq start (+ end tabulated-list-padding))
        (setq index (1+ index))))
    match))

(defun bitbucket-devops-pipelines-history-expand-column-at-point ()
  "Expand the history column at point to fit loaded values."
  (interactive)
  (unless (derived-mode-p 'bitbucket-devops-pipelines-history-mode)
    (user-error "This command is only available in Bitbucket history buffers"))
  (let ((column (bitbucket-devops-pipelines-history-column-at-point)))
    (unless column
      (user-error "No Bitbucket pipeline history column at point"))
    (let* ((spec (aref tabulated-list-format column))
           (name (car spec))
           (current-width (cadr spec))
           (width
            (seq-reduce
             #'max
             (mapcar
              (lambda (entry)
                (string-width
                 (substring-no-properties
                  (format "%s" (aref (cadr entry) column)))))
             tabulated-list-entries)
             (string-width name))))
      (if (zerop current-width)
          (if-let ((entry (tabulated-list-get-entry)))
              (message "%s: %s" name
                       (substring-no-properties
                        (format "%s" (aref entry column))))
            (user-error "No Bitbucket pipeline is selected"))
        (setf (cadr spec) (max current-width width))
        (tabulated-list-init-header)
        (tabulated-list-print t)
        (bitbucket-devops-ui--disable-line-wrapping)
        (message "Expanded Bitbucket history column: %s" name)))))

(defun bitbucket-devops-ui--history-process-page
    (buffer context page request-error append)
  "Enrich and render PAGE or REQUEST-ERROR in BUFFER for CONTEXT."
  (if request-error
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (bitbucket-devops-ui--history-receive-page
           page request-error append)))
    (bitbucket-devops-ui--history-enrich-page
     context
     page
     (lambda (enriched-page)
       (bitbucket-devops-ui--history-enrich-deployments
        context
        enriched-page
        (lambda (fully-enriched-page)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (bitbucket-devops-ui--history-receive-page
               fully-enriched-page nil append)
              (unless append
                (bitbucket-devops-ui--refresh-loaded-pipelines
                 context
                 bitbucket-devops-ui--history-request-generation))))))))))

(defun bitbucket-devops-ui--history-request (next-url append)
  "Request NEXT-URL for the current history buffer.

Request the first page when NEXT-URL is nil.  Append results when APPEND is
non-nil."
  (when bitbucket-devops-ui--history-loading
    (user-error "Bitbucket pipeline history is already loading"))
  (unless bitbucket-devops-ui--context
    (user-error "This buffer has no Bitbucket repository context"))
  (setq bitbucket-devops-ui--history-loading t)
  (unless append
    (setq bitbucket-devops-ui--history-request-generation
          (1+ bitbucket-devops-ui--history-request-generation)))
  (let ((buffer (current-buffer))
        (context bitbucket-devops-ui--context)
        (generation bitbucket-devops-ui--history-request-generation))
    (if next-url
        (bitbucket-devops-rest-list-pipelines
         context
         (lambda (page request-error)
           (when (or append
                     (and (buffer-live-p buffer)
                          (= generation
                             (buffer-local-value
                              'bitbucket-devops-ui--history-request-generation
                              buffer))))
             (bitbucket-devops-ui--history-process-page
              buffer context page request-error append)))
         next-url)
      (let (history-page history-error history-done paused paused-done)
        (cl-labels
            ((finish
              ()
              (when (and history-done paused-done)
                (when (and (buffer-live-p buffer)
                           (= generation
                              (buffer-local-value
                               'bitbucket-devops-ui--history-request-generation
                               buffer)))
                  (bitbucket-devops-ui--history-process-page
                   buffer
                   context
                   (if history-error
                       history-page
                     (bitbucket-devops-ui--merge-pipeline-pages
                      history-page paused))
                   history-error
                   append)))))
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
               (message "Unable to load paused Bitbucket pipelines: %s"
                        (plist-get request-error :message)))
             (setq paused (unless request-error pipelines)
                   paused-done t)
             (finish))))))))

(defun bitbucket-devops-pipelines-history-refresh ()
  "Asynchronously reload the first page of the current history buffer."
  (interactive)
  (bitbucket-devops-ui--history-load-cache)
  (bitbucket-devops-ui--history-request nil nil))

(defun bitbucket-devops-pipelines-history-load-more ()
  "Asynchronously append the next page to the current history buffer."
  (interactive)
  (unless bitbucket-devops-ui--history-next-url
    (user-error "No additional Bitbucket pipeline history pages are available"))
  (bitbucket-devops-ui--history-request
   bitbucket-devops-ui--history-next-url
   t))

(defun bitbucket-devops-pipelines-history-toggle-current-branch ()
  "Toggle between all branches and the captured current branch."
  (interactive)
  (setq bitbucket-devops-ui--history-branch-filter
        (if (eq bitbucket-devops-ui--history-branch-filter 'all)
            (or (plist-get bitbucket-devops-ui--context :branch)
                (user-error "Current repository context has no branch"))
          'all))
  (bitbucket-devops-ui--history-render)
  (message "Bitbucket pipeline branch filter: %s"
           (or (bitbucket-devops-ui--history-branch-filter-name)
               "all branches")))

(defun bitbucket-devops-pipelines-history-set-branch-filter (branch)
  "Set the current history buffer filter to BRANCH or all branches."
  (interactive
   (let* ((all-label "[all branches]")
          (selected
           (completing-read
            "Pipeline branch: "
            (cons all-label
                  (bitbucket-devops-ui--history-branch-names))
            nil
            nil
            nil
            nil
            (or (bitbucket-devops-ui--history-branch-filter-name)
                all-label))))
     (list (if (equal selected all-label) 'all selected))))
  (unless (or (eq branch 'all)
              (and (stringp branch) (not (string-empty-p branch))))
    (user-error "Unsupported Bitbucket pipeline branch filter: %s" branch))
  (setq bitbucket-devops-ui--history-branch-filter branch)
  (bitbucket-devops-ui--history-render)
  (message "Bitbucket pipeline branch filter: %s"
           (or (bitbucket-devops-ui--history-branch-filter-name)
               "all branches")))

(defun bitbucket-devops-pipelines-history-set-status-filter (status)
  "Set the current history buffer STATUS filter."
  (interactive
   (list
    (intern
     (completing-read
      "Pipeline status: "
      '("all" "successful" "failed" "in-progress")
      nil
      t))))
  (unless (memq status '(all successful failed in-progress))
    (user-error "Unsupported Bitbucket pipeline status filter: %s" status))
  (setq bitbucket-devops-ui--history-status-filter status)
  (bitbucket-devops-ui--history-render)
  (message "Bitbucket pipeline status filter: %s" status))

(defun bitbucket-devops-ui--history-buffer-name (context)
  "Return the history buffer name for repository CONTEXT."
  (format "*Bitbucket Pipelines: %s/%s*"
          (plist-get context :workspace)
          (plist-get context :repo-slug)))

(defun bitbucket-devops-ui--details-buffer-name (context pipeline-uuid)
  "Return the details buffer name for CONTEXT and PIPELINE-UUID."
  (format "*Bitbucket Pipeline: %s/%s %s*"
          (plist-get context :workspace)
          (plist-get context :repo-slug)
          pipeline-uuid))

(defun bitbucket-devops-ui--sanitize-name (name)
  "Return NAME made suitable for predictable buffer and file names."
  (string-trim
   (replace-regexp-in-string "[^A-Za-z0-9._-]+" "-" (or name "step"))
   "-"
   "-"))

(defun bitbucket-devops-ui--log-buffer-name (context pipeline step)
  "Return the completed log buffer name for CONTEXT, PIPELINE, and STEP."
  (format "*Bitbucket Log: %s/%s #%s %s*"
          (plist-get context :workspace)
          (plist-get context :repo-slug)
          (or (alist-get 'build_number pipeline) "?")
          (bitbucket-devops-ui--sanitize-name (alist-get 'name step))))

(defun bitbucket-devops-ui--log-download-file-name
    (context pipeline step index)
  "Return a predictable downloaded log filename.

CONTEXT identifies the repository.  PIPELINE and STEP provide display values.
INDEX is the step's one-based position."
  (format "%s-%s-pipeline-%s-%02d-%s.log"
          (bitbucket-devops-ui--sanitize-name
           (plist-get context :workspace))
          (bitbucket-devops-ui--sanitize-name
           (plist-get context :repo-slug))
          (or (alist-get 'build_number pipeline) "unknown")
          index
          (bitbucket-devops-ui--sanitize-name (alist-get 'name step))))

(defun bitbucket-devops-ui--download-logs
    (context pipeline steps callback &optional directory)
  "Download available step logs asynchronously and invoke CALLBACK.

CONTEXT and PIPELINE identify the run.  STEPS contains the step records.
CALLBACK receives saved file paths and unavailable step names.  Store logs in
DIRECTORY or `bitbucket-devops-pipelines-log-download-directory'."
  (let* ((directory
          (file-name-as-directory
           (expand-file-name
            (or directory bitbucket-devops-pipelines-log-download-directory))))
         (pipeline-uuid (alist-get 'uuid pipeline))
         unavailable
         jobs
         saved)
    (make-directory directory t)
    (cl-loop
     for step in steps
     for index from 1
     if (bitbucket-devops-ui--step-log-available-p pipeline step)
     do (push
         (list
          step
          (expand-file-name
           (bitbucket-devops-ui--log-download-file-name
            context
            pipeline
            step
            index)
           directory))
         jobs)
     else do (push (or (alist-get 'name step) "unnamed step") unavailable))
    (setq jobs (nreverse jobs))
    (let ((remaining (length jobs)))
      (if (zerop remaining)
          (funcall callback nil (nreverse unavailable))
        (dolist (job jobs)
          (let ((job job))
            (bitbucket-devops-rest-get-step-log
             context
             pipeline-uuid
             (alist-get 'uuid (car job))
             (lambda (log request-error)
               (if request-error
                   (push (or (alist-get 'name (car job)) "unnamed step")
                         unavailable)
                 (condition-case _error
                     (progn
                       (write-region log nil (cadr job) nil 'silent)
                       (push (cadr job) saved))
                   (file-error
                    (push (or (alist-get 'name (car job)) "unnamed step")
                          unavailable))))
               (setq remaining (1- remaining))
               (when (zerop remaining)
                 (funcall callback
                          (nreverse saved)
                          (nreverse unavailable)))))))))))

(defun bitbucket-devops-ui--copy-log-paths (paths)
  "Copy downloaded log PATHS to the kill ring and return the copied text."
  (when paths
    (let ((text (string-join paths "\n")))
      (kill-new text)
      text)))

(defun bitbucket-devops-ui--download-message-callback
    (directory &optional copy-paths)
  "Return a log-download completion callback reporting DIRECTORY.

When COPY-PATHS is non-nil, copy saved log paths to the kill ring."
  (lambda (saved unavailable)
    (let ((copied (and copy-paths
                       (bitbucket-devops-ui--copy-log-paths saved))))
      (message
       "Downloaded %d Bitbucket pipeline logs to %s%s%s"
       (length saved)
       directory
       (if unavailable
           (format "; unavailable: %s"
                   (string-join unavailable ", "))
         "")
       (if copied
           "; copied path(s)"
         "")))))

(defun bitbucket-devops-ui--list-all-steps
    (context pipeline-uuid callback &optional next-url steps)
  "Fetch every step for PIPELINE-UUID in CONTEXT and invoke CALLBACK.

Follow Bitbucket pagination from NEXT-URL.  Append records to STEPS while
loading.  CALLBACK receives the complete step list and an error plist."
  (bitbucket-devops-rest-list-steps
   context
   pipeline-uuid
   (lambda (page request-error)
     (if request-error
         (funcall callback nil request-error)
       (let ((all-steps
              (append steps (bitbucket-devops-rest-page-values page))))
         (if-let ((page-next (bitbucket-devops-rest-page-next page)))
             (bitbucket-devops-ui--list-all-steps
              context
              pipeline-uuid
              callback
              page-next
              all-steps)
           (funcall callback all-steps nil)))))
   next-url))

(defun bitbucket-devops-ui--render-step-log (context pipeline step log)
  "Render LOG for STEP from PIPELINE and CONTEXT in a read-only buffer."
  (let ((buffer
         (get-buffer-create
          (bitbucket-devops-ui--log-buffer-name context pipeline step))))
    (with-current-buffer buffer
      (bitbucket-devops-pipelines-log-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert log)
        (ansi-color-apply-on-region (point-min) (point-max))
        (goto-char (point-min)))
      (setq buffer-read-only t))
    buffer))

(defun bitbucket-devops-ui--merge-records-by-uuid (records updates)
  "Return RECORDS merged with UPDATES by UUID without duplicates."
  (let ((result (copy-sequence records)))
    (dolist (update updates)
      (let* ((uuid (alist-get 'uuid update))
             (index
              (and uuid
                   (cl-position
                    uuid result
                    :key (lambda (record) (alist-get 'uuid record))
                    :test #'equal))))
        (if index
            (setf (nth index result) update)
          (setq result (append result (list update))))))
    result))

(defun bitbucket-devops-ui--goto-step-id (step-uuid)
  "Move point to STEP-UUID in the current details table."
  (goto-char (point-min))
  (when-let ((match
              (text-property-search-forward
               'tabulated-list-id step-uuid t)))
    (goto-char (prop-match-beginning match))
    t))

(defun bitbucket-devops-ui--details-render-steps ()
  "Render loaded step records into the current details buffer."
  (let ((selected-step (tabulated-list-get-id)))
    (bitbucket-devops-ui--annotate-steps-deployments
     bitbucket-devops-ui--details-steps
     (alist-get
      'bitbucket-devops-pipelines-deployments
      bitbucket-devops-ui--details-pipeline))
    (setq tabulated-list-entries
          (let ((index 0))
            (mapcar
             (lambda (step)
               (setq index (1+ index))
               (bitbucket-devops-ui--step-row step index))
             bitbucket-devops-ui--details-steps)))
    (tabulated-list-print t)
    (bitbucket-devops-ui--disable-line-wrapping)
    (when bitbucket-devops-ui--details-pipeline
      (let ((inhibit-read-only t)
            (pipeline bitbucket-devops-ui--details-pipeline))
        (goto-char (point-min))
        (insert
         (format
          "Pipeline #%s  Type: %s  Target: %s  State: %s  Started: %s\n"
          (or (alist-get 'build_number pipeline) "?")
          (bitbucket-devops-ui--pipeline-type-label pipeline)
          (or (bitbucket-devops-ui--nested-get pipeline 'target 'ref_name)
              "?")
          (bitbucket-devops-ui--pipeline-state-label pipeline)
          (let ((started
                 (bitbucket-devops-ui--format-time
                  (alist-get 'created_on pipeline))))
            (if (string-empty-p started) "?" started))))
        (insert "\n")))
    (or (and selected-step
             (bitbucket-devops-ui--goto-step-id selected-step))
        (when-let ((first-step (caar tabulated-list-entries)))
          (bitbucket-devops-ui--goto-step-id first-step)))))

(defun bitbucket-devops-ui--details-request-steps
    (&optional next-url generation)
  "Request current pipeline step records asynchronously from NEXT-URL."
  (let ((buffer (current-buffer))
        (generation
         (or generation bitbucket-devops-ui--details-generation)))
    (bitbucket-devops-rest-list-steps
     bitbucket-devops-ui--context
     bitbucket-devops-ui--details-pipeline-uuid
     (lambda (page request-error)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (bitbucket-devops-ui--details-receive-steps
            page
            request-error
            generation))))
     next-url)))

(defun bitbucket-devops-ui--details-receive-steps
    (page request-error &optional generation)
  "Render a step PAGE or REQUEST-ERROR in the current details buffer."
  (let ((generation
         (or generation bitbucket-devops-ui--details-generation)))
    (when (= generation bitbucket-devops-ui--details-generation)
      (if request-error
          (progn
            (setq bitbucket-devops-ui--details-loading nil)
            (message "Unable to load Bitbucket pipeline steps: %s"
                     (plist-get request-error :message)))
        (setq bitbucket-devops-ui--details-steps
              (bitbucket-devops-ui--merge-records-by-uuid
               bitbucket-devops-ui--details-steps
               (bitbucket-devops-rest-page-values page)))
        (bitbucket-devops-ui--details-render-steps)
        (if-let ((next-url (bitbucket-devops-rest-page-next page)))
            (bitbucket-devops-ui--details-request-steps
             next-url generation)
          (setq bitbucket-devops-ui--details-loading nil))))))

(defun bitbucket-devops-ui--details-receive-pipeline
    (pipeline request-error generation)
  "Render PIPELINE or REQUEST-ERROR in the current details buffer."
  (when (= generation bitbucket-devops-ui--details-generation)
    (if request-error
        (progn
          (setq bitbucket-devops-ui--details-loading nil)
          (message "Unable to load Bitbucket pipeline details: %s"
                   (plist-get request-error :message)))
      (setq bitbucket-devops-ui--details-pipeline pipeline)
      (bitbucket-devops-cache-merge-pipelines
       bitbucket-devops-ui--context
       (list pipeline))
      (bitbucket-devops-ui--details-render-steps)
      (let ((buffer (current-buffer))
            (context bitbucket-devops-ui--context))
        (bitbucket-devops-ui--details-request-steps nil generation)
        (bitbucket-devops-ui--ensure-pipeline-deployments
         context
         pipeline
         (lambda (_enriched-pipeline deployment-error)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (when (= generation
                        bitbucket-devops-ui--details-generation)
                 (when deployment-error
                   (message "Unable to load Bitbucket deployment metadata"))
                 (bitbucket-devops-ui--details-render-steps))))))))))

(defun bitbucket-devops-pipelines-details-refresh ()
  "Asynchronously reload the current pipeline details buffer."
  (interactive)
  (unless (and bitbucket-devops-ui--context
               bitbucket-devops-ui--details-pipeline-uuid)
    (user-error "This buffer has no Bitbucket pipeline context"))
  (setq bitbucket-devops-ui--details-loading t)
  (setq bitbucket-devops-ui--details-generation
        (1+ bitbucket-devops-ui--details-generation))
  (setq bitbucket-devops-ui--details-steps nil)
  (when bitbucket-devops-ui--details-pipeline
    (bitbucket-devops-ui--details-render-steps))
  (let ((buffer (current-buffer))
        (generation bitbucket-devops-ui--details-generation))
    (bitbucket-devops-rest-get-pipeline
     bitbucket-devops-ui--context
     bitbucket-devops-ui--details-pipeline-uuid
     (lambda (pipeline request-error)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (bitbucket-devops-ui--details-receive-pipeline
            pipeline
            request-error
            generation)))))))

(defun bitbucket-devops-ui--find-by-uuid (uuid records)
  "Return the record identified by UUID from RECORDS."
  (seq-find (lambda (record) (equal (alist-get 'uuid record) uuid))
            records))

(defun bitbucket-devops-pipelines-history-view-details ()
  "Open details for the pipeline at point in a history buffer."
  (interactive)
  (let ((pipeline-uuid (tabulated-list-get-id)))
    (unless pipeline-uuid
      (user-error "No Bitbucket pipeline is selected"))
    (bitbucket-devops-pipelines-details bitbucket-devops-ui--context pipeline-uuid)))

(defun bitbucket-devops-pipelines-history-run-configured ()
  "Prompt for and trigger a configured pipeline from a history buffer."
  (interactive)
  (unless bitbucket-devops-ui--context
    (user-error "This buffer has no Bitbucket pipeline context"))
  (unless (fboundp 'bitbucket-devops-pipelines-run-configured)
    (require 'bitbucket-devops-pipelines-mutate))
  (bitbucket-devops-pipelines-run-configured
   (or (plist-get bitbucket-devops-ui--context :root)
       default-directory)))

(defun bitbucket-devops-pipelines-watch-selected ()
  "Watch the selected pipeline from a history or details buffer."
  (interactive)
  (let ((pipeline-uuid
         (cond
          ((derived-mode-p 'bitbucket-devops-pipelines-details-mode)
           bitbucket-devops-ui--details-pipeline-uuid)
          ((derived-mode-p 'bitbucket-devops-pipelines-history-mode)
           (tabulated-list-get-id)))))
    (unless (and bitbucket-devops-ui--context pipeline-uuid)
      (user-error "No Bitbucket pipeline is selected"))
    (require 'bitbucket-devops-pipelines-watch)
    (bitbucket-devops-pipelines-watch-pipeline
     bitbucket-devops-ui--context
     pipeline-uuid)))

;;;###autoload
(defun bitbucket-devops-pipelines-details (context pipeline-uuid)
  "Open details for PIPELINE-UUID in repository CONTEXT."
  (let ((previous-buffer (current-buffer))
        (buffer
         (get-buffer-create
          (bitbucket-devops-ui--details-buffer-name
           context
           pipeline-uuid))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'bitbucket-devops-pipelines-details-mode)
        (bitbucket-devops-pipelines-details-mode))
      (setq-local bitbucket-devops-ui--context context)
      (setq-local bitbucket-devops-ui--details-pipeline-uuid pipeline-uuid)
      (bitbucket-devops-pipelines-details-refresh))
    (bitbucket-devops-ui--display-buffer buffer t previous-buffer)
    buffer))

(defun bitbucket-devops-pipelines-view-step-log ()
  "Asynchronously open the completed step log selected in a details buffer."
  (interactive)
  (let* ((source-buffer (current-buffer))
         (step-uuid (tabulated-list-get-id))
         (step
          (bitbucket-devops-ui--find-by-uuid
           step-uuid
           bitbucket-devops-ui--details-steps))
         (context bitbucket-devops-ui--context)
         (pipeline bitbucket-devops-ui--details-pipeline))
    (unless step
      (user-error "No Bitbucket pipeline step is selected"))
    (bitbucket-devops-ui--require-step-log-available pipeline step)
    (bitbucket-devops-rest-get-step-log
     context
     (alist-get 'uuid pipeline)
     (alist-get 'uuid step)
     (lambda (log request-error)
       (if request-error
           (message "Unable to load Bitbucket pipeline step log: %s"
                    (bitbucket-devops-ui--step-log-request-error-message
                     request-error))
         (bitbucket-devops-ui--display-buffer
          (bitbucket-devops-ui--render-step-log
           context
           pipeline
           step
           log)
          nil
          source-buffer))))))

(defun bitbucket-devops-pipelines-download-logs ()
  "Asynchronously download available logs for the current pipeline details."
  (interactive)
  (unless bitbucket-devops-ui--details-pipeline
    (user-error "This buffer has no loaded Bitbucket pipeline details"))
  (let ((directory bitbucket-devops-pipelines-log-download-directory))
    (bitbucket-devops-ui--download-logs
     bitbucket-devops-ui--context
     bitbucket-devops-ui--details-pipeline
     bitbucket-devops-ui--details-steps
     (bitbucket-devops-ui--download-message-callback directory t))))

(defun bitbucket-devops-pipelines-history-download-logs ()
  "Download available logs for the pipeline selected in history."
  (interactive)
  (let ((pipeline-uuid (tabulated-list-get-id))
        (context bitbucket-devops-ui--context)
        (directory bitbucket-devops-pipelines-log-download-directory))
    (unless pipeline-uuid
      (user-error "No Bitbucket pipeline is selected"))
    (bitbucket-devops-rest-get-pipeline
     context
     pipeline-uuid
     (lambda (pipeline request-error)
       (if request-error
           (message "Unable to load Bitbucket pipeline details: %s"
                    (plist-get request-error :message))
         (bitbucket-devops-ui--list-all-steps
          context
          pipeline-uuid
          (lambda (steps steps-error)
            (if steps-error
                (message "Unable to load Bitbucket pipeline steps: %s"
                         (plist-get steps-error :message))
              (bitbucket-devops-ui--download-logs
               context
               pipeline
               steps
               (bitbucket-devops-ui--download-message-callback
                directory t))))))))))

(defun bitbucket-devops-pipelines-download-selected-log ()
  "Asynchronously download the completed step log selected in details."
  (interactive)
  (let* ((step-uuid (tabulated-list-get-id))
         (step
          (bitbucket-devops-ui--find-by-uuid
           step-uuid
           bitbucket-devops-ui--details-steps))
         (context bitbucket-devops-ui--context)
         (pipeline bitbucket-devops-ui--details-pipeline)
         (directory
          (file-name-as-directory
           (expand-file-name bitbucket-devops-pipelines-log-download-directory))))
    (unless step
      (user-error "No Bitbucket pipeline step is selected"))
    (bitbucket-devops-ui--require-step-log-available pipeline step)
    (let* ((index
            (1+
             (or (cl-position
                  step
                  bitbucket-devops-ui--details-steps
                  :test #'eq)
                 0)))
           (file
            (expand-file-name
             (bitbucket-devops-ui--log-download-file-name
              context
              pipeline
              step
              index)
             directory)))
      (make-directory directory t)
      (bitbucket-devops-rest-get-step-log
       context
       (alist-get 'uuid pipeline)
       (alist-get 'uuid step)
       (lambda (log request-error)
         (if request-error
             (message "Unable to download Bitbucket pipeline step log: %s"
                      (bitbucket-devops-ui--step-log-request-error-message
                       request-error))
           (condition-case file-error
               (progn
                 (write-region log nil file nil 'silent)
                 (bitbucket-devops-ui--copy-log-paths (list file))
                 (message
                  "Downloaded Bitbucket pipeline step log to %s; copied path"
                  file))
             (file-error
              (message "Unable to save Bitbucket pipeline step log: %s"
                       (error-message-string file-error))))))))))

;;;###autoload
(defun bitbucket-devops-pipelines-history (&optional directory)
  "Open pipeline history for the repository containing DIRECTORY."
  (interactive)
  (let* ((previous-buffer (current-buffer))
         (context (bitbucket-devops-context-resolve directory))
         (buffer
          (get-buffer-create
           (bitbucket-devops-ui--history-buffer-name context))))
    (with-current-buffer buffer
      (bitbucket-devops-pipelines-history-mode)
      (setq-local bitbucket-devops-ui--context context)
      (bitbucket-devops-pipelines-history-refresh))
    (bitbucket-devops-ui--display-buffer buffer t previous-buffer)
    buffer))

(define-key bitbucket-devops-pipelines-history-mode-map (kbd "r")
            #'bitbucket-devops-pipelines-history-refresh)
(define-key bitbucket-devops-pipelines-history-mode-map (kbd "n")
            #'bitbucket-devops-pipelines-history-load-more)
(define-key bitbucket-devops-pipelines-history-mode-map (kbd "f")
            #'bitbucket-devops-pipelines-history-set-branch-filter)
(define-key bitbucket-devops-pipelines-history-mode-map (kbd "s")
            #'bitbucket-devops-pipelines-history-set-status-filter)
(define-key bitbucket-devops-pipelines-history-mode-map (kbd "RET")
            #'bitbucket-devops-pipelines-history-view-details)
(define-key bitbucket-devops-pipelines-history-mode-map (kbd "t")
            #'bitbucket-devops-pipelines-watch-selected)
(define-key bitbucket-devops-pipelines-history-mode-map (kbd "d")
            #'bitbucket-devops-pipelines-history-download-logs)
(define-key bitbucket-devops-pipelines-history-mode-map (kbd "R")
            #'bitbucket-devops-pipelines-history-run-configured)
(define-key bitbucket-devops-pipelines-history-mode-map (kbd "TAB")
            #'bitbucket-devops-pipelines-history-expand-column-at-point)
(define-key bitbucket-devops-pipelines-history-mode-map (kbd "-")
            #'bitbucket-devops-ui-back)
(define-key bitbucket-devops-pipelines-history-mode-map (kbd "q")
            #'bitbucket-devops-ui-quit)
(define-key bitbucket-devops-pipelines-history-mode-map (kbd "?")
            #'bitbucket-devops-ui-show-command-panel)
(define-key bitbucket-devops-pipelines-details-mode-map (kbd "r")
            #'bitbucket-devops-pipelines-details-refresh)
(define-key bitbucket-devops-pipelines-details-mode-map (kbd "RET")
            #'bitbucket-devops-pipelines-view-step-log)
(define-key bitbucket-devops-pipelines-details-mode-map (kbd "d")
            #'bitbucket-devops-pipelines-download-selected-log)
(define-key bitbucket-devops-pipelines-details-mode-map (kbd "D")
            #'bitbucket-devops-pipelines-download-logs)
(define-key bitbucket-devops-pipelines-details-mode-map (kbd "t")
            #'bitbucket-devops-pipelines-watch-selected)
(define-key bitbucket-devops-pipelines-details-mode-map (kbd "R")
            #'bitbucket-devops-pipelines-rerun)
(define-key bitbucket-devops-pipelines-details-mode-map (kbd "c")
            #'bitbucket-devops-pipelines-continue)
(define-key bitbucket-devops-pipelines-details-mode-map (kbd "s")
            #'bitbucket-devops-pipelines-stop)
(define-key bitbucket-devops-pipelines-details-mode-map (kbd "-")
            #'bitbucket-devops-ui-back)
(define-key bitbucket-devops-pipelines-details-mode-map (kbd "q")
            #'bitbucket-devops-ui-quit)
(define-key bitbucket-devops-pipelines-details-mode-map (kbd "?")
            #'bitbucket-devops-ui-show-command-panel)
(define-key bitbucket-devops-pipelines-log-mode-map (kbd "-")
            #'bitbucket-devops-ui-back)
(define-key bitbucket-devops-pipelines-log-mode-map (kbd "q")
            #'bitbucket-devops-ui-quit)
(define-key bitbucket-devops-pipelines-log-mode-map (kbd "?")
            #'bitbucket-devops-ui-show-command-panel)

(defun bitbucket-devops-ui--install-evil-bindings ()
  "Install Evil normal-state bindings for Bitbucket Pipelines buffers."
  (evil-define-key*
   'normal
   bitbucket-devops-pipelines-history-mode-map
   (kbd "r") #'bitbucket-devops-pipelines-history-refresh
   (kbd "n") #'bitbucket-devops-pipelines-history-load-more
   (kbd "f") #'bitbucket-devops-pipelines-history-set-branch-filter
   (kbd "s") #'bitbucket-devops-pipelines-history-set-status-filter
   (kbd "RET") #'bitbucket-devops-pipelines-history-view-details
   (kbd "t") #'bitbucket-devops-pipelines-watch-selected
   (kbd "d") #'bitbucket-devops-pipelines-history-download-logs
   (kbd "R") #'bitbucket-devops-pipelines-history-run-configured
   (kbd "TAB") #'bitbucket-devops-pipelines-history-expand-column-at-point
   (kbd "-") #'bitbucket-devops-ui-back
   (kbd "q") #'bitbucket-devops-ui-quit
   (kbd "?") #'bitbucket-devops-ui-show-command-panel)
  (evil-define-key*
   'normal
   bitbucket-devops-pipelines-details-mode-map
   (kbd "r") #'bitbucket-devops-pipelines-details-refresh
   (kbd "RET") #'bitbucket-devops-pipelines-view-step-log
   (kbd "d") #'bitbucket-devops-pipelines-download-selected-log
   (kbd "D") #'bitbucket-devops-pipelines-download-logs
   (kbd "t") #'bitbucket-devops-pipelines-watch-selected
   (kbd "R") #'bitbucket-devops-pipelines-rerun
   (kbd "c") #'bitbucket-devops-pipelines-continue
   (kbd "s") #'bitbucket-devops-pipelines-stop
   (kbd "-") #'bitbucket-devops-ui-back
   (kbd "q") #'bitbucket-devops-ui-quit
   (kbd "?") #'bitbucket-devops-ui-show-command-panel)
  (evil-define-key*
   'normal
   bitbucket-devops-pipelines-log-mode-map
   (kbd "-") #'bitbucket-devops-ui-back
   (kbd "q") #'bitbucket-devops-ui-quit
   (kbd "?") #'bitbucket-devops-ui-show-command-panel))

(with-eval-after-load 'evil
  (bitbucket-devops-ui--install-evil-bindings))

(provide 'bitbucket-devops-ui)
;;; bitbucket-devops-ui.el ends here
