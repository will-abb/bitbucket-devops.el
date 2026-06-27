;;; bitbucket-devops-pipelines-yaml.el --- Parse Bitbucket Pipelines YAML -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Will Bosch-Bello
;; Keywords: tools, vc
;; Package-Requires: ((emacs "29.1") (yaml "1.2.3"))

;;; Commentary:

;; Convert a bitbucket-pipelines.yml file into Bitbucket-specific trigger
;; metadata.  Keep YAML parsing here so the mutation commands only need to
;; reason about API targets and selectors.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'yaml)

(cl-defstruct (bitbucket-devops-pipelines-yaml-variable
               (:constructor bitbucket-devops-pipelines-yaml--make-variable))
  "A runtime variable declared by a custom pipeline."
  name
  default
  allowed-values
  description)

(cl-defstruct (bitbucket-devops-pipelines-yaml-option
               (:constructor bitbucket-devops-pipelines-yaml--make-option))
  "A manually triggerable pipeline option.
KIND is `default', `branch', `pull-request', or `custom'.  BRANCH is set for
`branches' pipeline selectors.  PATTERN is set for pull request and custom
pipeline selectors.  VARIABLES contains runtime variable declarations.
DEPLOYMENTS contains deployment environment names."
  kind
  branch
  pattern
  variables
  deployments)

(cl-defstruct (bitbucket-devops-pipelines-yaml-config
               (:constructor bitbucket-devops-pipelines-yaml--make-config))
  "Trigger-related metadata from a Bitbucket Pipelines configuration."
  default
  default-envs
  branches
  branch-envs
  pull-requests
  pull-request-envs
  tags
  custom
  deployments)

(defun bitbucket-devops-pipelines-yaml--mapping-value (mapping key)
  "Return the value for KEY in YAML MAPPING."
  (cdr (assoc key mapping)))

(defun bitbucket-devops-pipelines-yaml--mapping-keys (mapping)
  "Return the keys from YAML MAPPING."
  (mapcar #'car mapping))

(defun bitbucket-devops-pipelines-yaml--runtime-variable-value (value)
  "Return VALUE as text suitable for a Bitbucket runtime-variable prompt.
`yaml.el' decodes YAML booleans even when they were quoted.  Runtime-variable
values are sent to Bitbucket as text, so restore their textual representation."
  (cond
   ((eq value t) "true")
   ((eq value :false) "false")
   ((eq value :null) nil)
   ((null value) nil)
   ((stringp value) value)
   (t (format "%s" value))))

(defun bitbucket-devops-pipelines-yaml--deployment-names (node)
  "Return deployment environment names found recursively under YAML NODE."
  (delete-dups
   (cond
    ((not (consp node)) nil)
    ((and (stringp (car node))
          (equal (car node) "deployment")
          (stringp (cdr node)))
     (list (cdr node)))
    (t
     (append
      (bitbucket-devops-pipelines-yaml--deployment-names (car node))
      (bitbucket-devops-pipelines-yaml--deployment-names (cdr node)))))))

(defun bitbucket-devops-pipelines-yaml--variable (mapping)
  "Build a runtime variable from YAML MAPPING."
  (let ((name (bitbucket-devops-pipelines-yaml--mapping-value mapping "name")))
    (when (and (stringp name) (not (string-empty-p name)))
      (bitbucket-devops-pipelines-yaml--make-variable
       :name name
       :default
       (bitbucket-devops-pipelines-yaml--runtime-variable-value
        (bitbucket-devops-pipelines-yaml--mapping-value mapping "default"))
       :allowed-values
       (mapcar
        #'bitbucket-devops-pipelines-yaml--runtime-variable-value
        (bitbucket-devops-pipelines-yaml--mapping-value mapping "allowed-values"))
       :description
       (bitbucket-devops-pipelines-yaml--mapping-value mapping "description")))))

(defun bitbucket-devops-pipelines-yaml--variables (pipeline-items)
  "Return runtime variable declarations from PIPELINE-ITEMS."
  (when-let* ((variables-item
               (seq-find
                (lambda (item)
                  (and (listp item) (assoc "variables" item)))
                pipeline-items))
              (variables
               (bitbucket-devops-pipelines-yaml--mapping-value
                variables-item "variables")))
    (delq nil (mapcar #'bitbucket-devops-pipelines-yaml--variable variables))))

(defun bitbucket-devops-pipelines-yaml--custom-options (mapping)
  "Return custom trigger options from YAML MAPPING."
  (mapcar
   (lambda (entry)
     (bitbucket-devops-pipelines-yaml--make-option
      :kind 'custom
      :pattern (car entry)
      :variables (bitbucket-devops-pipelines-yaml--variables (cdr entry))
      :deployments (bitbucket-devops-pipelines-yaml--deployment-names (cdr entry))))
   mapping))

(defun bitbucket-devops-pipelines-yaml--branch-options (branch-envs)
  "Return branch selector options from BRANCH-ENVS."
  (mapcar
   (lambda (entry)
     (bitbucket-devops-pipelines-yaml--make-option
      :kind 'branch
      :branch (car entry)
      :deployments (cdr entry)))
   branch-envs))

(defun bitbucket-devops-pipelines-yaml--pull-request-options (pull-request-envs)
  "Return pull request selector options from PULL-REQUEST-ENVS."
  (mapcar
   (lambda (entry)
     (bitbucket-devops-pipelines-yaml--make-option
      :kind 'pull-request
      :pattern (car entry)
      :deployments (cdr entry)))
   pull-request-envs))

(defun bitbucket-devops-pipelines-yaml-parse-string (string)
  "Parse Bitbucket Pipelines YAML from STRING."
  (let* ((document
          (yaml-parse-string
           string
           :object-type 'alist
           :object-key-type 'string
           :sequence-type 'list))
         (pipelines
          (bitbucket-devops-pipelines-yaml--mapping-value document "pipelines"))
         (default (assoc "default" pipelines))
         (branches
          (bitbucket-devops-pipelines-yaml--mapping-value pipelines "branches"))
         (pull-requests
          (bitbucket-devops-pipelines-yaml--mapping-value pipelines "pull-requests"))
         (tags (bitbucket-devops-pipelines-yaml--mapping-value pipelines "tags"))
         (custom (bitbucket-devops-pipelines-yaml--mapping-value pipelines "custom")))
    (bitbucket-devops-pipelines-yaml--make-config
     :default (and default t)
     :default-envs
     (bitbucket-devops-pipelines-yaml--deployment-names (cdr default))
     :branches (bitbucket-devops-pipelines-yaml--mapping-keys branches)
     :branch-envs
     (mapcar
      (lambda (entry)
        (cons
         (car entry)
         (bitbucket-devops-pipelines-yaml--deployment-names (cdr entry))))
      branches)
     :pull-requests (bitbucket-devops-pipelines-yaml--mapping-keys pull-requests)
     :pull-request-envs
     (mapcar
      (lambda (entry)
        (cons
         (car entry)
         (bitbucket-devops-pipelines-yaml--deployment-names (cdr entry))))
      pull-requests)
     :tags (bitbucket-devops-pipelines-yaml--mapping-keys tags)
     :custom (bitbucket-devops-pipelines-yaml--custom-options custom)
     :deployments
     (bitbucket-devops-pipelines-yaml--deployment-names
      (list (cdr default) branches)))))

(defun bitbucket-devops-pipelines-yaml--branch-pattern-match-p (pattern branch)
  "Return non-nil when Bitbucket branch PATTERN matches BRANCH."
  (and (stringp pattern)
       (stringp branch)
       (string-match-p (wildcard-to-regexp pattern) branch)))

(defun bitbucket-devops-pipelines-yaml-automatic-deployments (config branch)
  "Return deployments selected by CONFIG's automatic pipeline for BRANCH."
  (let* ((branch-deployments
          (bitbucket-devops-pipelines-yaml-config-branch-envs config))
         (exact (assoc branch branch-deployments))
         (pattern
          (seq-find
           (lambda (entry)
             (bitbucket-devops-pipelines-yaml--branch-pattern-match-p
              (car entry)
              branch))
           branch-deployments)))
    (if-let ((match (or exact pattern)))
        (cdr match)
      (bitbucket-devops-pipelines-yaml-config-default-envs config))))

(defun bitbucket-devops-pipelines-yaml-parse-file (file)
  "Parse a Bitbucket Pipelines YAML configuration from FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (bitbucket-devops-pipelines-yaml-parse-string (buffer-string))))

(defun bitbucket-devops-pipelines-yaml-manual-options (config &optional branch)
  "Return manually triggerable branch-targeted options from CONFIG.
The default option runs the YAML `default' selector against the current branch.
Branch options run named `branches' selectors against the current branch.  Pull
request options run against the open pull request whose source is the current
branch.  Custom options use their named custom selectors."
  (ignore branch)
  (append
   (when (bitbucket-devops-pipelines-yaml-config-default config)
     (list
      (bitbucket-devops-pipelines-yaml--make-option
       :kind 'default
       :deployments (bitbucket-devops-pipelines-yaml-config-default-envs config))))
   (bitbucket-devops-pipelines-yaml--branch-options
    (bitbucket-devops-pipelines-yaml-config-branch-envs config))
   (bitbucket-devops-pipelines-yaml--pull-request-options
    (bitbucket-devops-pipelines-yaml-config-pull-request-envs config))
   (bitbucket-devops-pipelines-yaml-config-custom config)))

(defun bitbucket-devops-pipelines-yaml-option-label (option)
  "Return a completion label for trigger OPTION."
  (pcase (bitbucket-devops-pipelines-yaml-option-kind option)
    ('default "default")
    ('branch
     (format "branches: %s" (bitbucket-devops-pipelines-yaml-option-branch option)))
    ('pull-request
     (format "pull-requests: %s"
             (bitbucket-devops-pipelines-yaml-option-pattern option)))
    ('custom
     (format "custom: %s" (bitbucket-devops-pipelines-yaml-option-pattern option)))
    (_ (error "Unknown Bitbucket pipeline option kind: %S"
              (bitbucket-devops-pipelines-yaml-option-kind option)))))

(defun bitbucket-devops-pipelines-yaml-custom-option (config pattern)
  "Return the custom option matching PATTERN from CONFIG."
  (seq-find
   (lambda (option)
     (equal pattern (bitbucket-devops-pipelines-yaml-option-pattern option)))
   (bitbucket-devops-pipelines-yaml-config-custom config)))

(provide 'bitbucket-devops-pipelines-yaml)
;;; bitbucket-devops-pipelines-yaml.el ends here
