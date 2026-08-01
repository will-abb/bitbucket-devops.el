;;; bitbucket-devops-context.el --- Resolve Bitbucket repository context -*- lexical-binding: t; -*-

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

;; Resolve Bitbucket Cloud repository identity from local Git context.

;;; Code:

(require 'subr-x)
(require 'magit nil t)

(declare-function magit-get-current-branch "magit-git" ())
(declare-function magit-git-string "magit-git" (&rest args))
(declare-function magit-rev-parse "magit-git" (&rest args))
(declare-function magit-toplevel "magit" (&optional directory))

(defgroup bitbucket-devops nil
  "Work with Bitbucket Cloud development workflows."
  :group 'tools
  :prefix "bitbucket-devops-")

(defgroup bitbucket-devops-pipelines nil
  "Work with Bitbucket Cloud Pipelines."
  :group 'bitbucket-devops
  :prefix "bitbucket-devops-pipelines-")

(defcustom bitbucket-devops-remote "origin"
  "Git remote used to resolve the current Bitbucket Cloud repository."
  :type 'string
  :safe #'stringp
  :group 'bitbucket-devops)

(defcustom bitbucket-devops-repository-overrides nil
  "Explicit Bitbucket Cloud identity overrides keyed by repository root.

Each value is a plist with `:workspace' and `:repo-slug' keys.  An override
takes precedence over parsing `bitbucket-devops-remote'."
  :type '(alist :key-type directory :value-type sexp)
  :group 'bitbucket-devops)

(defun bitbucket-devops-context--valid-remote-segment-p (segment)
  "Return non-nil when SEGMENT is a valid parsed SSH remote path segment."
  (and (not (string-empty-p segment))
       (not (member segment '("." "..")))
       (not (string-match-p "[/[:space:]?#\\\\]" segment))))

(defun bitbucket-devops-context-parse-ssh-remote (remote)
  "Return the Bitbucket Cloud repository identity parsed from REMOTE.

REMOTE must use a supported Bitbucket Cloud SSH form.  Return a plist with
`:workspace' and `:repo-slug' keys.  Signal `user-error' when REMOTE is not a
supported Bitbucket Cloud SSH URL."
  (let ((path
         (cond
          ((and (stringp remote)
                (string-match "\\`git@bitbucket\\.org:\\(.+\\)\\'" remote))
           (match-string 1 remote))
          ((and (stringp remote)
                (string-match
                 "\\`ssh://git@bitbucket\\.org/\\(.+\\)\\'" remote))
           (match-string 1 remote))
          (t
           (user-error
            "Remote must be an SSH Bitbucket Cloud URL: git@bitbucket.org:workspace/repository.git")))))
    (unless (string-match "\\`\\([^/]+\\)/\\([^/]+\\)\\'" path)
      (user-error "Remote must contain exactly one workspace and repository slug"))
    (let ((workspace (match-string 1 path))
          (repo-slug (string-remove-suffix ".git" (match-string 2 path))))
      (unless (and (bitbucket-devops-context--valid-remote-segment-p workspace)
                   (bitbucket-devops-context--valid-remote-segment-p repo-slug))
        (user-error "Remote contains an invalid workspace or repository slug"))
      (list :workspace workspace :repo-slug repo-slug))))

(defun bitbucket-devops-context--normalize-root (root)
  "Return ROOT as an expanded directory name."
  (file-name-as-directory (expand-file-name root)))

(defun bitbucket-devops-context--repository-override (root)
  "Return the repository identity override for ROOT, or nil."
  (let ((normalized-root (bitbucket-devops-context--normalize-root root))
        result)
    (dolist (entry bitbucket-devops-repository-overrides result)
      (when (and (stringp (car-safe entry))
                 (equal normalized-root
                        (bitbucket-devops-context--normalize-root
                         (car entry))))
        (setq result (cdr entry))))))

(defun bitbucket-devops-context--validate-identity (identity)
  "Return IDENTITY after validating its required Bitbucket Cloud values."
  (let ((workspace (plist-get identity :workspace))
        (repo-slug (plist-get identity :repo-slug)))
    (unless (and (stringp workspace)
                 (bitbucket-devops-context--valid-remote-segment-p workspace)
                 (stringp repo-slug)
                 (bitbucket-devops-context--valid-remote-segment-p repo-slug))
      (user-error
       "Repository override must define a valid :workspace and :repo-slug"))
    (list :workspace workspace :repo-slug repo-slug)))

(defun bitbucket-devops-context-resolve (&optional directory)
  "Return the Bitbucket Cloud repository context for DIRECTORY.

Use `default-directory' when DIRECTORY is nil.  The returned plist contains
`:root', `:remote', `:workspace', `:repo-slug', `:branch', and `:commit'.
`:branch' is nil when HEAD is detached."
  (unless (fboundp 'magit-toplevel)
    (user-error "Magit is required to resolve Bitbucket repository context"))
  (let* ((default-directory
          (bitbucket-devops-context--normalize-root
           (or directory default-directory)))
         (root (magit-toplevel)))
    (unless root
      (user-error "Current buffer is not inside a Git repository"))
    (setq root (bitbucket-devops-context--normalize-root root))
    (let* ((remote bitbucket-devops-remote)
           (override (bitbucket-devops-context--repository-override root))
           (identity
            (if override
                (bitbucket-devops-context--validate-identity override)
              (let ((remote-url
                     (magit-git-string "remote" "get-url" remote)))
                (unless remote-url
                  (user-error "Git remote %S does not exist" remote))
                (bitbucket-devops-context-parse-ssh-remote remote-url))))
           (branch (magit-get-current-branch))
           (commit (magit-rev-parse "HEAD")))
      (unless commit
        (user-error "Unable to resolve HEAD in Git repository %s" root))
      (list :root root
            :remote remote
            :workspace (plist-get identity :workspace)
            :repo-slug (plist-get identity :repo-slug)
            :branch branch
            :commit commit))))

(defun bitbucket-devops-context-require-branch (context)
  "Return the branch from CONTEXT, or signal a detached-HEAD `user-error'."
  (or (plist-get context :branch)
      (user-error "This command requires a branch, but HEAD is detached")))

(provide 'bitbucket-devops-context)
;;; bitbucket-devops-context.el ends here
