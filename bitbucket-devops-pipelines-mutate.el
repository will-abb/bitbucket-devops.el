;;; bitbucket-devops-pipelines-mutate.el --- Mutate Bitbucket Cloud Pipelines -*- lexical-binding: t; -*-

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

;; Trigger, rerun, and stop Bitbucket Cloud pipelines.

;;; Code:

(require 'subr-x)
(require 'seq)
(require 'tabulated-list)
(require 'bitbucket-devops-context)
(require 'bitbucket-devops-rest)
(require 'bitbucket-devops-pipelines-watch)
(require 'bitbucket-devops-pipelines-yaml)
(require 'bitbucket-devops-pull-requests)
(require 'bitbucket-devops-pull-requests-rest)

(defvar bitbucket-devops-ui--context)
(defvar bitbucket-devops-ui--details-pipeline-uuid)
(defvar bitbucket-devops-ui--details-pipeline)
(defvar bitbucket-devops-ui--details-steps)
(defvar savehist-additional-variables)
(declare-function bitbucket-devops-pipelines-details-refresh
                  "bitbucket-devops-ui"
                  ())

(defcustom bitbucket-devops-pipelines-production-branches '("main" "master")
  "Branch names that require confirmation before triggering a pipeline."
  :type '(repeat string)
  :group 'bitbucket-devops-pipelines)

(defcustom bitbucket-devops-pipelines-production-deployment-regexp "prod"
  "Regexp matching deployment names that require trigger confirmation.
Matching is case-insensitive."
  :type 'regexp
  :group 'bitbucket-devops-pipelines)

(defcustom bitbucket-devops-pipelines-production-confirmation-function #'yes-or-no-p
  "Function used to confirm a production-sensitive pipeline trigger.
The function receives one prompt string and must return non-nil to proceed."
  :type 'function
  :group 'bitbucket-devops-pipelines)

(defcustom bitbucket-devops-pipelines-remember-variable-values nil
  "Whether remembered Bitbucket trigger variables include their last values.

When nil, only runtime variable keys are remembered.  When non-nil, runtime
variable values are also stored in
`bitbucket-devops-pipelines-last-variable-metadata' and may be persisted by
`savehist'.  Do not enable this when runtime variables may contain secrets.

Runtime variables are sent to Bitbucket unsecured regardless of this option.
Bitbucket stores their values as plain text on the pipeline run and does not
mask them in its log output, so do not pass tokens, passwords, or keys through
a runtime variable prompt.  Define those as secured repository, deployment, or
workspace variables in Bitbucket instead."
  :type 'boolean
  :group 'bitbucket-devops-pipelines)

(defcustom bitbucket-devops-pipelines-yaml-file-name "bitbucket-pipelines.yml"
  "Name of the local Bitbucket Pipelines YAML file parsed for configured runs."
  :type 'string
  :safe #'stringp
  :group 'bitbucket-devops-pipelines)

(defvar bitbucket-devops-pipelines-last-branch nil
  "Last branch entered for a Bitbucket pipeline trigger.")

(defvar bitbucket-devops-pipelines-last-custom-selector nil
  "Last custom Bitbucket pipeline selector entered by the user.")

(defvar bitbucket-devops-pipelines-last-variable-metadata nil
  "Remembered Bitbucket trigger variable metadata.

This always stores variable keys.  Values are stored only when
`bitbucket-devops-pipelines-remember-variable-values' is non-nil.")

(defun bitbucket-devops-pipelines-mutate--register-savehist-variables ()
  "Register remembered trigger settings with Savehist.

Called when `savehist-mode' is enabled, so the remembered branch, custom
pipeline selector, and variable metadata survive across sessions."
  (dolist (variable
           '(bitbucket-devops-pipelines-last-branch
             bitbucket-devops-pipelines-last-custom-selector
             bitbucket-devops-pipelines-last-variable-metadata))
    (add-to-list 'savehist-additional-variables variable)))

(add-hook 'savehist-mode-hook
          #'bitbucket-devops-pipelines-mutate--register-savehist-variables)

;; `savehist-mode' may already be on by the time this file loads, in which
;; case the hook above will not run on its own.
(when (bound-and-true-p savehist-mode)
  (bitbucket-devops-pipelines-mutate--register-savehist-variables))

(defun bitbucket-devops-pipelines-mutate--pipeline-state-name (pipeline)
  "Return PIPELINE's state name."
  (alist-get 'name (alist-get 'state pipeline)))

(defun bitbucket-devops-pipelines-mutate--pipeline-result-name (pipeline)
  "Return PIPELINE's terminal result name, or nil."
  (alist-get 'name (alist-get 'result (alist-get 'state pipeline))))

(defun bitbucket-devops-pipelines-mutate--nested-get (object &rest keys)
  "Return the value reached by following KEYS through alist OBJECT."
  (dolist (key keys object)
    (setq object (alist-get key object))))

(defun bitbucket-devops-pipelines-mutate--pipeline-paused-p (pipeline)
  "Return non-nil when PIPELINE is paused or halted."
  (let* ((state (alist-get 'state pipeline))
         (labels
          (list
           (alist-get 'name state)
           (bitbucket-devops-pipelines-mutate--nested-get
            state 'stage 'name)
           (bitbucket-devops-pipelines-mutate--nested-get
            state 'result 'name))))
    (seq-some
     (lambda (label)
       (member label '("PAUSED" "HALTED")))
     labels)))

(defun bitbucket-devops-pipelines-mutate--step-state-name (step)
  "Return STEP's state name."
  (alist-get 'name (alist-get 'state step)))

(defun bitbucket-devops-pipelines-mutate--step-pending-p (step)
  "Return non-nil when STEP is waiting to be started."
  (member
   (bitbucket-devops-pipelines-mutate--step-state-name step)
   '("PENDING" "PAUSED" "HALTED")))

(defun bitbucket-devops-pipelines-mutate--pending-steps (steps)
  "Return STEPS that are waiting to be started."
  (seq-filter
   #'bitbucket-devops-pipelines-mutate--step-pending-p
   steps))

(defun bitbucket-devops-pipelines-mutate--pipeline-completed-p (pipeline)
  "Return non-nil when PIPELINE has already completed."
  (equal (bitbucket-devops-pipelines-mutate--pipeline-state-name pipeline) "COMPLETED"))

(defun bitbucket-devops-pipelines-mutate--pipeline-display-name (pipeline)
  "Return a concise user-facing name for PIPELINE."
  (if-let ((build-number (alist-get 'build_number pipeline)))
      (format "#%s" build-number)
    (or (alist-get 'uuid pipeline) "selected pipeline")))

(defun bitbucket-devops-pipelines-mutate--ensure-pipeline-stoppable (pipeline)
  "Signal an actionable error unless PIPELINE can be stopped."
  (when (bitbucket-devops-pipelines-mutate--pipeline-completed-p pipeline)
    (let ((result (bitbucket-devops-pipelines-mutate--pipeline-result-name pipeline)))
      (user-error
       "Bitbucket pipeline %s is already completed%s; only active pipelines can be stopped"
       (bitbucket-devops-pipelines-mutate--pipeline-display-name pipeline)
       (if result (format " (%s)" result) "")))))

(defun bitbucket-devops-pipelines-mutate--step-display-name (step)
  "Return a concise user-facing name for STEP."
  (or (alist-get 'name step)
      (alist-get 'uuid step)
      "selected step"))

(defun bitbucket-devops-pipelines-mutate--ensure-step-startable
    (pipeline step)
  "Signal an actionable error unless STEP can be started in PIPELINE."
  (unless (bitbucket-devops-pipelines-mutate--pipeline-paused-p pipeline)
    (user-error
     "Bitbucket pipeline %s is not paused; only pending manual steps can be continued"
     (bitbucket-devops-pipelines-mutate--pipeline-display-name pipeline)))
  (unless (bitbucket-devops-pipelines-mutate--step-pending-p step)
    (user-error
     "Bitbucket pipeline step %s is not pending"
     (bitbucket-devops-pipelines-mutate--step-display-name step))))

(defun bitbucket-devops-pipelines-mutate--choose-pending-step
    (selected-step steps)
  "Return SELECTED-STEP when pending, otherwise choose a pending step from STEPS."
  (cond
   ((and selected-step
         (bitbucket-devops-pipelines-mutate--step-pending-p selected-step))
    selected-step)
   (t
    (let ((pending-steps
           (bitbucket-devops-pipelines-mutate--pending-steps steps)))
      (pcase (length pending-steps)
        (0
         (if selected-step
             (user-error
              "Bitbucket pipeline step %s is not pending"
              (bitbucket-devops-pipelines-mutate--step-display-name
               selected-step))
           (user-error "This pipeline has no pending manual step")))
        (1
         (car pending-steps))
        (_
         (let* ((choices
                 (mapcar
                  (lambda (step)
                    (cons
                     (format
                      "%s (%s)"
                      (bitbucket-devops-pipelines-mutate--step-display-name
                       step)
                      (alist-get 'uuid step))
                     step))
                  pending-steps))
                (selection
                 (completing-read
                  "Pending manual step: " choices nil t)))
           (cdr (assoc selection choices)))))))))

(defun bitbucket-devops-pipelines-mutate--continue-error-message
    (request-error)
  "Return a user-facing continue failure message for REQUEST-ERROR."
  (let ((message (plist-get request-error :message)))
    (if (and (stringp message)
             (string-match-p
              "not accessible by this authentication mechanism"
              message))
        (concat
         message
         "; Bitbucket rejected this manual-step endpoint for the configured "
         "token type. Try an Atlassian user API token with pipeline write "
         "scope, or continue the step in the Bitbucket web UI.")
      message)))

(defun bitbucket-devops-pipelines-mutate--selector (selector)
  "Return a Bitbucket pipeline selector for SELECTOR, or nil.
SELECTOR may be a custom selector string, or an alist with `type' and optional
`pattern' entries."
  (cond
   ((and (stringp selector) (not (string-empty-p selector)))
    `((type . "custom") (pattern . ,selector)))
   ((and (proper-list-p selector) (alist-get 'type selector))
    selector)))

(defun bitbucket-devops-pipelines-mutate--variable-payload (variable)
  "Return an API payload alist for VARIABLE."
  (let ((key (plist-get variable :key))
        (value (plist-get variable :value)))
    (unless (and (stringp key) (not (string-empty-p key)))
      (user-error "Bitbucket pipeline variable requires a key"))
    (unless (stringp value)
      (user-error "Bitbucket pipeline variable %s requires a value" key))
    `((key . ,key) (value . ,value))))

(defun bitbucket-devops-pipelines-mutate--body (target variables)
  "Return a pipeline trigger body for TARGET and VARIABLES."
  (append
   `((target . ,target))
   (when variables
     `((variables
        . ,(vconcat
            (mapcar #'bitbucket-devops-pipelines-mutate--variable-payload
                    variables)))))))

(defun bitbucket-devops-pipelines-mutate--target-branch (body)
  "Return BODY's target branch name, or nil."
  (let ((target (alist-get 'target body)))
    (cond
     ((equal (alist-get 'ref_type target) "branch")
      (alist-get 'ref_name target))
     ((equal (alist-get 'type target) "pipeline_pullrequest_target")
      (or (alist-get 'source target)
          (alist-get 'destination target))))))

(defun bitbucket-devops-pipelines-mutate--production-branch-p (branch)
  "Return non-nil when BRANCH requires production confirmation."
  (and
   (stringp branch)
   (seq-some
    (lambda (production-branch)
      (string-equal-ignore-case branch production-branch))
    bitbucket-devops-pipelines-production-branches)))

(defun bitbucket-devops-pipelines-mutate--production-deployment-p (deployment)
  "Return non-nil when DEPLOYMENT requires production confirmation."
  (and
   (stringp deployment)
   (let ((case-fold-search t))
     (string-match-p
      bitbucket-devops-pipelines-production-deployment-regexp
      deployment))))

(defun bitbucket-devops-pipelines-mutate--production-reasons (body deployments)
  "Return production confirmation reasons for BODY and DEPLOYMENTS."
  (let ((branch (bitbucket-devops-pipelines-mutate--target-branch body)))
    (append
     (when (bitbucket-devops-pipelines-mutate--production-branch-p branch)
       (list (format "branch %s" branch)))
     (mapcar
      (lambda (deployment)
        (format "deployment %s" deployment))
      (seq-filter
       #'bitbucket-devops-pipelines-mutate--production-deployment-p
       (delete-dups (copy-sequence deployments)))))))

(defun bitbucket-devops-pipelines-mutate--confirm-production-trigger
    (body &optional deployments)
  "Confirm BODY when its branch or DEPLOYMENTS indicate production."
  (when-let ((reasons
              (bitbucket-devops-pipelines-mutate--production-reasons
               body deployments)))
    (unless
        (funcall
         bitbucket-devops-pipelines-production-confirmation-function
         (format
          "Production-sensitive Bitbucket pipeline (%s). Run it? "
          (string-join reasons ", ")))
      (user-error "Canceled production-sensitive Bitbucket pipeline trigger"))))

(defun bitbucket-devops-pipelines-mutate-branch-body
    (branch &optional selector variables)
  "Return a branch trigger body for BRANCH, SELECTOR, and VARIABLES."
  (unless (and (stringp branch) (not (string-empty-p branch)))
    (user-error "Bitbucket pipeline trigger requires a branch"))
  (let ((target
         `((type . "pipeline_ref_target")
           (ref_type . "branch")
           (ref_name . ,branch))))
    (when-let ((selector (bitbucket-devops-pipelines-mutate--selector selector)))
      (setq target (append target `((selector . ,selector)))))
    (bitbucket-devops-pipelines-mutate--body target variables)))

(defun bitbucket-devops-pipelines-mutate--require-string (value description)
  "Return VALUE as a required non-empty string for DESCRIPTION."
  (unless (and (stringp value) (not (string-empty-p value)))
    (user-error "Bitbucket pipeline trigger requires %s" description))
  value)

(defun bitbucket-devops-pipelines-mutate--pull-request-commit-hash
    (pull-request side)
  "Return PULL-REQUEST commit hash from SIDE, either `source' or `destination'."
  (bitbucket-devops-pull-requests--nested-get pull-request side 'commit 'hash))

(defun bitbucket-devops-pipelines-mutate--pull-request-has-commit-hashes-p
    (pull-request)
  "Return non-nil when PULL-REQUEST has source and destination commit hashes."
  (and
   (bitbucket-devops-pipelines-mutate--pull-request-commit-hash
    pull-request 'source)
   (bitbucket-devops-pipelines-mutate--pull-request-commit-hash
    pull-request 'destination)))

(defun bitbucket-devops-pipelines-mutate-pull-request-body
    (pull-request pattern)
  "Return a pull request trigger body for PULL-REQUEST and PATTERN."
  (let* ((id (alist-get 'id pull-request))
         (source
          (bitbucket-devops-pipelines-mutate--require-string
           (bitbucket-devops-pull-requests-source-branch pull-request)
           "a pull request source branch"))
         (destination
          (bitbucket-devops-pipelines-mutate--require-string
           (bitbucket-devops-pull-requests-destination-branch pull-request)
           "a pull request destination branch"))
         (source-hash
          (bitbucket-devops-pipelines-mutate--require-string
           (bitbucket-devops-pipelines-mutate--pull-request-commit-hash
            pull-request 'source)
           "a pull request source commit hash"))
         (destination-hash
          (bitbucket-devops-pipelines-mutate--require-string
           (bitbucket-devops-pipelines-mutate--pull-request-commit-hash
            pull-request 'destination)
           "a pull request destination commit hash"))
         (pattern
          (bitbucket-devops-pipelines-mutate--require-string
           pattern
           "a pull request selector pattern")))
    (unless id
      (user-error "Bitbucket pipeline trigger requires a pull request id"))
    (bitbucket-devops-pipelines-mutate--body
     `((type . "pipeline_pullrequest_target")
       (source . ,source)
       (destination . ,destination)
       (destination_commit . ((hash . ,destination-hash)))
       (commit . ((hash . ,source-hash)))
       (pullrequest . ((id . ,(format "%s" id))))
       (selector . ((type . "pull-requests")
                    (pattern . ,pattern))))
     nil)))

(defun bitbucket-devops-pipelines-mutate-rerun-body
    (pipeline &optional selector variables)
  "Return a fresh trigger body from PIPELINE, SELECTOR, and VARIABLES."
  (let ((target (copy-tree (alist-get 'target pipeline))))
    (unless target
      (user-error "Selected Bitbucket pipeline has no reusable target"))
    (when-let ((selector (bitbucket-devops-pipelines-mutate--selector selector)))
      (setf (alist-get 'selector target) selector))
    (bitbucket-devops-pipelines-mutate--body target variables)))

(defun bitbucket-devops-pipelines-mutate-remember-defaults
    (branch selector variables)
  "Remember trigger defaults from BRANCH, SELECTOR, and VARIABLES."
  (setq bitbucket-devops-pipelines-last-branch branch)
  (setq bitbucket-devops-pipelines-last-custom-selector selector)
  (setq bitbucket-devops-pipelines-last-variable-metadata
        (mapcar
         (lambda (variable)
           (append
            (list :key (plist-get variable :key))
            (when bitbucket-devops-pipelines-remember-variable-values
              (list :value (plist-get variable :value)))))
         variables)))

(defun bitbucket-devops-pipelines-mutate-trigger
    (context body &optional callback deployments)
  "Asynchronously trigger BODY in CONTEXT and invoke CALLBACK.

Start watching the returned pipeline UUID after a successful request.
Require explicit confirmation first when BODY or DEPLOYMENTS indicate
production."
  (bitbucket-devops-pipelines-mutate--confirm-production-trigger body deployments)
  (bitbucket-devops-rest-run-pipeline
   context
   body
   (lambda (pipeline request-error)
     (if request-error
         (progn
           (message "Unable to trigger Bitbucket pipeline: %s"
                    (plist-get request-error :message))
           (when callback
             (funcall callback nil request-error)))
       (let ((pipeline-uuid (alist-get 'uuid pipeline)))
         (unless pipeline-uuid
           (error "Bitbucket pipeline trigger response has no UUID"))
         (bitbucket-devops-pipelines-watch-pipeline context pipeline-uuid)
         (message "Started Bitbucket pipeline #%s"
                  (or (alist-get 'build_number pipeline) "?"))
         (when callback
           (funcall callback pipeline nil)))))))

(defun bitbucket-devops-pipelines-mutate--pipelines-yml (context)
  "Return the path to the configured pipelines YAML file for CONTEXT, or nil."
  (let ((root (plist-get context :root)))
    (when root
      (let ((path
             (expand-file-name bitbucket-devops-pipelines-yaml-file-name root)))
        (when (file-readable-p path) path)))))

(defun bitbucket-devops-pipelines-mutate--parse-custom-selectors (file)
  "Parse custom pipeline selector names from FILE.

Return a list of selector name strings found under `pipelines: custom:'."
  (mapcar
   #'bitbucket-devops-pipelines-yaml-option-pattern
   (bitbucket-devops-pipelines-yaml-config-custom
    (bitbucket-devops-pipelines-yaml-parse-file file))))

(defun bitbucket-devops-pipelines-mutate--parse-custom-variables (file selector)
  "Parse variable metadata for SELECTOR from FILE.

Return variable declarations from the named custom pipeline."
  (when-let ((option
              (bitbucket-devops-pipelines-yaml-custom-option
               (bitbucket-devops-pipelines-yaml-parse-file file)
               selector)))
    (bitbucket-devops-pipelines-yaml-option-variables option)))

(defun bitbucket-devops-pipelines-mutate--configured-deployments (context selector)
  "Return locally configured deployment names for SELECTOR in CONTEXT.
When SELECTOR is nil, return the conservative union for automatic branch
triggers because Bitbucket resolves branch matching server-side."
  (when-let ((yml (bitbucket-devops-pipelines-mutate--pipelines-yml context)))
    (let ((config (bitbucket-devops-pipelines-yaml-parse-file yml)))
      (if selector
          (when-let ((option
                      (bitbucket-devops-pipelines-yaml-custom-option config selector)))
            (bitbucket-devops-pipelines-yaml-option-deployments option))
        (bitbucket-devops-pipelines-yaml-config-deployments config)))))

(defun bitbucket-devops-pipelines-mutate--pipeline-deployments (pipeline)
  "Return deployment environment names already attached to PIPELINE."
  (delq
   nil
   (mapcar
    (lambda (deployment)
      (alist-get 'name (alist-get 'environment deployment)))
    (alist-get 'bitbucket-devops-pipelines-deployments pipeline))))

(defun bitbucket-devops-pipelines-mutate--display-value (value)
  "Return VALUE as prompt text, or nil when VALUE is nil."
  (unless (null value)
    (format "%s" value)))

(defun bitbucket-devops-pipelines-mutate--variable-key (variable)
  "Return the runtime variable key represented by VARIABLE."
  (cond
   ((bitbucket-devops-pipelines-yaml-variable-p variable)
    (bitbucket-devops-pipelines-yaml-variable-name variable))
   ((listp variable)
    (plist-get variable :key))
   (t variable)))

(defun bitbucket-devops-pipelines-mutate--variable-default (variable)
  "Return the YAML default represented by VARIABLE, or nil."
  (cond
   ((bitbucket-devops-pipelines-yaml-variable-p variable)
    (bitbucket-devops-pipelines-yaml-variable-default variable))
   ((listp variable)
    (plist-get variable :default))))

(defun bitbucket-devops-pipelines-mutate--variable-allowed-values (variable)
  "Return the YAML allowed values represented by VARIABLE, or nil."
  (cond
   ((bitbucket-devops-pipelines-yaml-variable-p variable)
    (bitbucket-devops-pipelines-yaml-variable-allowed-values variable))
   ((listp variable)
    (plist-get variable :allowed-values))))

(defun bitbucket-devops-pipelines-mutate--remembered-variable (key)
  "Return remembered runtime variable metadata for KEY, or nil."
  (seq-find
   (lambda (metadata)
     (equal key (plist-get metadata :key)))
   bitbucket-devops-pipelines-last-variable-metadata))

(defun bitbucket-devops-pipelines-mutate--remembered-variable-value (key allowed-values)
  "Return a remembered value for KEY that is valid for ALLOWED-VALUES."
  (when bitbucket-devops-pipelines-remember-variable-values
    (let ((value
           (plist-get
            (bitbucket-devops-pipelines-mutate--remembered-variable key)
            :value)))
      (unless (null value)
        (let ((value (bitbucket-devops-pipelines-mutate--display-value value))
              (allowed-values
               (mapcar #'bitbucket-devops-pipelines-mutate--display-value
                       allowed-values)))
          (when (or (null allowed-values)
                    (member value allowed-values))
            value))))))

(defun bitbucket-devops-pipelines-mutate--read-variable-value
    (key &optional default allowed-values)
  "Read a value for variable KEY.
Offer DEFAULT and ALLOWED-VALUES from the parsed YAML declaration when
available."
  (let ((default (bitbucket-devops-pipelines-mutate--display-value default)))
    (cond
     (allowed-values
      (let ((choices
             (mapcar #'bitbucket-devops-pipelines-mutate--display-value
                     allowed-values)))
        (completing-read
         (format "Value for variable %s: " key)
         (lambda (string predicate action)
           (if (eq action 'metadata)
               '(metadata
                 (category . bitbucket-devops-pipelines-runtime-variable-value))
             (complete-with-action action choices string predicate)))
         nil t nil nil default)))
     (t
      (read-string (format "Value for variable %s: " key) default)))))

(defun bitbucket-devops-pipelines-mutate--read-variable (variable)
  "Read a value for VARIABLE metadata."
  (let* ((key (bitbucket-devops-pipelines-mutate--variable-key variable))
         (allowed-values
          (bitbucket-devops-pipelines-mutate--variable-allowed-values variable))
         (default
          (or (bitbucket-devops-pipelines-mutate--remembered-variable-value
               key
               allowed-values)
              (bitbucket-devops-pipelines-mutate--variable-default variable)))
         (value
          (bitbucket-devops-pipelines-mutate--read-variable-value
           key
           default
           allowed-values)))
    (list :key key :value value)))

(defun bitbucket-devops-pipelines-mutate--read-variables
    (&optional variable-metadata use-remembered-when-empty additional)
  "Read custom variables from VARIABLE-METADATA.

Prompt for each declared VARIABLE-METADATA item.  When
USE-REMEMBERED-WHEN-EMPTY is non-nil, use remembered metadata if
VARIABLE-METADATA is nil.  When ADDITIONAL is non-nil, also read free-form key
and value pairs for variables the configuration does not declare."
  (let ((variable-metadata
         (if use-remembered-when-empty
             (or variable-metadata
                 bitbucket-devops-pipelines-last-variable-metadata)
           variable-metadata))
        variables)
    (dolist (variable variable-metadata)
      (push (bitbucket-devops-pipelines-mutate--read-variable variable) variables))
    (when additional
      (let ((key
             (read-string "Additional runtime variable key (empty for none): ")))
        (while (not (string-empty-p key))
          (push (bitbucket-devops-pipelines-mutate--read-variable key) variables)
          (setq key
                (read-string
                 "Additional runtime variable key (empty for none): ")))))
    (nreverse variables)))

(defun bitbucket-devops-pipelines-mutate--configured-option (config branch)
  "Read a branch-targeted pipeline option from CONFIG for BRANCH."
  (let* ((options (bitbucket-devops-pipelines-yaml-manual-options config branch))
         (choices
          (mapcar
           (lambda (option)
             (cons (bitbucket-devops-pipelines-yaml-option-label option) option))
           options))
         (default
          (if bitbucket-devops-pipelines-last-custom-selector
              (format "custom: %s" bitbucket-devops-pipelines-last-custom-selector)
            (caar choices)))
         (selection
          (progn
            (unless choices
              (user-error "No triggerable Bitbucket pipelines found in YAML"))
            (completing-read
             "Configured pipeline: "
             choices
             nil
             nil
             nil
             nil
             default))))
    (when (string-empty-p selection)
      (user-error "Choose a configured Bitbucket pipeline"))
    (or (cdr (assoc selection choices))
        (bitbucket-devops-pipelines-yaml--make-option
         :kind 'custom
         :pattern (string-remove-prefix "custom: " selection)))))

(defun bitbucket-devops-pipelines-mutate--option-selector (option)
  "Return the branch-target selector represented by configured OPTION."
  (pcase (bitbucket-devops-pipelines-yaml-option-kind option)
    ('default '((type . "default")))
    ('branch
     `((type . "branches")
       (pattern . ,(bitbucket-devops-pipelines-yaml-option-branch option))))
    ('custom
     `((type . "custom")
       (pattern . ,(bitbucket-devops-pipelines-yaml-option-pattern option))))))

(defun bitbucket-devops-pipelines-mutate--collect-open-pull-requests
    (context callback &optional next-url results)
  "Collect open pull requests in CONTEXT and invoke CALLBACK.
CALLBACK receives the collected pull requests and a request error.
NEXT-URL continues a paginated request when non-nil.
RESULTS accumulates pull requests across pages."
  (bitbucket-devops-pull-requests-rest-list
   context
   (lambda (page request-error)
     (if request-error
         (funcall callback nil request-error)
       (let ((combined (append results (alist-get 'values page))))
         (if-let ((next (alist-get 'next page)))
             (bitbucket-devops-pipelines-mutate--collect-open-pull-requests
              context
              callback
              next
              combined)
           (funcall callback combined nil)))))
   next-url
   "OPEN"))

(defun bitbucket-devops-pipelines-mutate--pull-requests-for-branch
    (pull-requests branch)
  "Return PULL-REQUESTS whose source branch is BRANCH."
  (seq-filter
   (lambda (pull-request)
     (equal
      (bitbucket-devops-pull-requests-source-branch pull-request)
      branch))
   pull-requests))

(defun bitbucket-devops-pipelines-mutate--pull-request-choice-label
    (pull-request)
  "Return a completion label for PULL-REQUEST."
  (format
   "#%s -> %s %s"
   (alist-get 'id pull-request)
   (or (bitbucket-devops-pull-requests-destination-branch pull-request) "")
   (or (alist-get 'title pull-request) "")))

(defun bitbucket-devops-pipelines-mutate--choose-pull-request
    (pull-requests branch)
  "Choose one pull request from PULL-REQUESTS for BRANCH."
  (pcase (length pull-requests)
    (0
     (user-error
      "No open Bitbucket pull request found with source branch %s"
      branch))
    (1 (car pull-requests))
    (_
     (let* ((choices
             (mapcar
              (lambda (pull-request)
                (cons
                 (bitbucket-devops-pipelines-mutate--pull-request-choice-label
                  pull-request)
                 pull-request))
              pull-requests))
            (selection
             (completing-read
              (format "Open pull request for %s: " branch)
              choices
              nil
              t)))
       (cdr (assoc selection choices))))))

(defun bitbucket-devops-pipelines-mutate--trigger-pull-request
    (context pull-request pattern callback deployments)
  "Trigger a pull request pipeline in CONTEXT.
PULL-REQUEST is the pull request alist to act on.
PATTERN selects the pipeline definition to run.
CALLBACK receives the decoded response and a request error.
DEPLOYMENTS are the deployment environments to target."
  (let ((body
         (bitbucket-devops-pipelines-mutate-pull-request-body
          pull-request
          pattern)))
    (bitbucket-devops-pipelines-mutate-trigger
     context
     body
     callback
     deployments)))

(defun bitbucket-devops-pipelines-mutate--trigger-pull-request-option
    (context branch option &optional callback)
  "Resolve and trigger pull request OPTION for current BRANCH in CONTEXT."
  (message "Finding open Bitbucket pull request for branch %s..." branch)
  (bitbucket-devops-pipelines-mutate--collect-open-pull-requests
   context
   (lambda (pull-requests request-error)
     (if request-error
         (progn
           (message "Unable to list Bitbucket pull requests: %s"
                    (plist-get request-error :message))
           (when callback
             (funcall callback nil request-error)))
       (let* ((matches
               (bitbucket-devops-pipelines-mutate--pull-requests-for-branch
                pull-requests
                branch))
              (pull-request
               (bitbucket-devops-pipelines-mutate--choose-pull-request
                matches
                branch))
              (pattern
               (bitbucket-devops-pipelines-yaml-option-pattern option))
              (deployments
               (bitbucket-devops-pipelines-yaml-option-deployments option)))
         (if (bitbucket-devops-pipelines-mutate--pull-request-has-commit-hashes-p
              pull-request)
             (bitbucket-devops-pipelines-mutate--trigger-pull-request
              context
              pull-request
              pattern
              callback
              deployments)
           (bitbucket-devops-pull-requests-rest-get
            context
            (alist-get 'id pull-request)
            (lambda (detailed-pull-request detail-error)
              (if detail-error
                  (progn
                    (message "Unable to load Bitbucket pull request details: %s"
                             (plist-get detail-error :message))
                    (when callback
                      (funcall callback nil detail-error)))
                (bitbucket-devops-pipelines-mutate--trigger-pull-request
                 context
                 detailed-pull-request
                 pattern
                 callback
                 deployments))))))))))

;;;###autoload
(defun bitbucket-devops-pipelines-run-configured (&optional directory additional)
  "Prompt for and trigger a configured pipeline in DIRECTORY.
Use the current branch as the API target for `default', `branches', and
`custom' selectors.  Pull request selectors resolve the open pull request whose
source is the current branch.  Named custom pipelines may include runtime
variables.

With a prefix argument, or when ADDITIONAL is non-nil, also prompt for
free-form runtime variables that `bitbucket-pipelines.yml' does not declare."
  (interactive (list nil current-prefix-arg))
  (let* ((context (bitbucket-devops-context-resolve directory))
         (branch (bitbucket-devops-context-require-branch context))
         (yml (bitbucket-devops-pipelines-mutate--pipelines-yml context))
         (_ (unless yml
              (user-error "Repository has no readable bitbucket-pipelines.yml")))
         (config (bitbucket-devops-pipelines-yaml-parse-file yml))
         (option (bitbucket-devops-pipelines-mutate--configured-option config branch))
         (kind (bitbucket-devops-pipelines-yaml-option-kind option))
         (selector (bitbucket-devops-pipelines-mutate--option-selector option))
         (custom-selector
          (when (eq kind 'custom)
            (bitbucket-devops-pipelines-yaml-option-pattern option)))
         (variables
          (when custom-selector
            (bitbucket-devops-pipelines-mutate--read-variables
             (bitbucket-devops-pipelines-yaml-option-variables option)
             nil
             additional))))
    (if (eq kind 'pull-request)
        (progn
          (bitbucket-devops-pipelines-mutate-remember-defaults branch nil nil)
          (bitbucket-devops-pipelines-mutate--trigger-pull-request-option
           context
           branch
           option))
      (unless selector
        (user-error "Unsupported Bitbucket pipeline option: %S" kind))
      (bitbucket-devops-pipelines-mutate-remember-defaults
       branch
       custom-selector
       variables)
      (bitbucket-devops-pipelines-mutate-trigger
       context
       (bitbucket-devops-pipelines-mutate-branch-body
        branch
        selector
        variables)
       nil
       (bitbucket-devops-pipelines-yaml-option-deployments option)))))

(defun bitbucket-devops-pipelines-rerun (&optional additional)
  "Trigger a new run using the current details buffer pipeline target.

With a prefix argument, or when ADDITIONAL is non-nil, also prompt for
free-form runtime variables beyond the keys remembered from the last trigger."
  (interactive "P")
  (unless bitbucket-devops-ui--details-pipeline
    (user-error "This buffer has no loaded Bitbucket pipeline details"))
  (let* ((target (alist-get 'target bitbucket-devops-ui--details-pipeline))
         (branch (alist-get 'ref_name target))
         (prior-selector (alist-get 'pattern (alist-get 'selector target)))
         (selector
          (read-string
           "Custom pipeline selector (empty preserves prior target): "
           prior-selector))
         (variables
          (bitbucket-devops-pipelines-mutate--read-variables nil t additional))
         (effective-selector
          (if (string-empty-p selector) prior-selector selector))
         (deployments
          (delete-dups
           (append
            (bitbucket-devops-pipelines-mutate--pipeline-deployments
             bitbucket-devops-ui--details-pipeline)
            (bitbucket-devops-pipelines-mutate--configured-deployments
             bitbucket-devops-ui--context effective-selector)))))
    (bitbucket-devops-pipelines-mutate-remember-defaults branch selector variables)
    (bitbucket-devops-pipelines-mutate-trigger
     bitbucket-devops-ui--context
     (bitbucket-devops-pipelines-mutate-rerun-body
      bitbucket-devops-ui--details-pipeline
      selector
      variables)
     nil
     deployments)))

(defun bitbucket-devops-pipelines-stop ()
  "Stop the pipeline displayed in the current details buffer."
  (interactive)
  (unless bitbucket-devops-ui--details-pipeline
    (user-error "This buffer has no loaded Bitbucket pipeline details"))
  (bitbucket-devops-pipelines-mutate--ensure-pipeline-stoppable
   bitbucket-devops-ui--details-pipeline)
  (let ((pipeline-uuid (alist-get 'uuid bitbucket-devops-ui--details-pipeline)))
    (unless (y-or-n-p (format "Stop Bitbucket pipeline %s? " pipeline-uuid))
      (user-error "Canceled"))
    (bitbucket-devops-rest-stop-pipeline
     bitbucket-devops-ui--context
     pipeline-uuid
     (lambda (_result request-error)
       (if request-error
           (message "Unable to stop Bitbucket pipeline: %s"
                    (plist-get request-error :message))
         (message "Stopped Bitbucket pipeline %s" pipeline-uuid))))))

(defun bitbucket-devops-pipelines-continue ()
  "Continue the pending manual step selected in the current details buffer."
  (interactive)
  (unless bitbucket-devops-ui--details-pipeline
    (user-error "This buffer has no loaded Bitbucket pipeline details"))
  (let* ((step-uuid (tabulated-list-get-id))
         (selected-step
          (seq-find
           (lambda (candidate)
             (equal (alist-get 'uuid candidate) step-uuid))
           bitbucket-devops-ui--details-steps))
         (pipeline bitbucket-devops-ui--details-pipeline)
         (pipeline-uuid (alist-get 'uuid pipeline))
         (source-buffer (current-buffer))
         (step (progn
                 (unless
                     (bitbucket-devops-pipelines-mutate--pipeline-paused-p
                      pipeline)
                   (user-error
                    "Bitbucket pipeline %s is not paused; only pending manual steps can be continued"
                    (bitbucket-devops-pipelines-mutate--pipeline-display-name
                     pipeline)))
                 (bitbucket-devops-pipelines-mutate--choose-pending-step
                  selected-step
                  bitbucket-devops-ui--details-steps)))
         (step-uuid (alist-get 'uuid step)))
    (unless pipeline-uuid
      (user-error "Selected Bitbucket pipeline has no UUID"))
    (unless step-uuid
      (user-error "Selected Bitbucket pipeline step has no UUID"))
    (bitbucket-devops-pipelines-mutate--ensure-step-startable pipeline step)
    (unless
        (y-or-n-p
         (format
          "Continue Bitbucket pipeline %s at step %s? "
          (bitbucket-devops-pipelines-mutate--pipeline-display-name pipeline)
          (bitbucket-devops-pipelines-mutate--step-display-name step)))
      (user-error "Canceled"))
    (bitbucket-devops-rest-start-step
     bitbucket-devops-ui--context
     pipeline-uuid
     step-uuid
     (lambda (_result request-error)
       (if request-error
           (message "Unable to continue Bitbucket pipeline: %s"
                    (bitbucket-devops-pipelines-mutate--continue-error-message
                     request-error))
         (bitbucket-devops-pipelines-watch-pipeline
          bitbucket-devops-ui--context
          pipeline-uuid)
         (message
          "Continued Bitbucket pipeline %s at step %s"
          (bitbucket-devops-pipelines-mutate--pipeline-display-name pipeline)
          (bitbucket-devops-pipelines-mutate--step-display-name step))
         (when (and (buffer-live-p source-buffer)
                    (fboundp 'bitbucket-devops-pipelines-details-refresh))
           (with-current-buffer source-buffer
             (when (and (derived-mode-p 'bitbucket-devops-pipelines-details-mode)
                        bitbucket-devops-ui--context
                        bitbucket-devops-ui--details-pipeline-uuid)
               (bitbucket-devops-pipelines-details-refresh)))))))))

(provide 'bitbucket-devops-pipelines-mutate)
;;; bitbucket-devops-pipelines-mutate.el ends here
