;;; bitbucket-devops-pipelines-magit.el --- Watch pipelines after Magit pushes -*- lexical-binding: t; -*-

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

;; Optionally start Bitbucket pipeline discovery after successful Magit pushes.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'bitbucket-devops-context)
(require 'bitbucket-devops-pipelines-watch)

(defcustom bitbucket-devops-pipelines-after-magit-push-hook
  '(bitbucket-devops-pipelines-watch-commit)
  "Functions called after a successful watched Magit push.

Each function receives the repository context captured before the push starts.
The default starts pipeline discovery for the pushed commit."
  :type 'hook
  :options '(bitbucket-devops-pipelines-watch-commit
             bitbucket-devops-pipelines-watch-branch
             bitbucket-devops-pipelines-watch-repository)
  :group 'bitbucket-devops-pipelines)

(defun bitbucket-devops-pipelines-magit--watchable-push-args-p (args)
  "Return non-nil when Magit ARGS describe a commit-affecting push."
  (let ((args (flatten-tree args)))
    (and (equal (car args) "push")
         (member "-v" args)
         (not (member "--dry-run" args))
         (not (member "-n" args))
         (not (member "--delete" args))
         (not (member "-d" args))
         (not (member "--tags" args))
         (not
          (seq-some
           (lambda (arg)
             (and (stringp arg)
                  (or (string-prefix-p ":" arg)
                      (string-match-p
                       "\\(?:\\`\\|:\\)refs/\\(?:tags\\|notes\\)/"
                       arg))))
           args)))))

(defun bitbucket-devops-pipelines-magit--targets-context-remote-p (args context)
  "Return non-nil when ARGS do not explicitly target a remote outside CONTEXT."
  (let* ((args (flatten-tree args))
         (remotes (and (fboundp 'magit-list-remotes)
                       (magit-list-remotes)))
         (explicit-remote
          (seq-find (lambda (arg) (member arg remotes)) args)))
    (or (null explicit-remote)
        (equal explicit-remote (plist-get context :remote)))))

(defun bitbucket-devops-pipelines-magit--run-after-push-hook (context)
  "Run `bitbucket-devops-pipelines-after-magit-push-hook' with CONTEXT."
  (condition-case error-data
      (run-hook-with-args 'bitbucket-devops-pipelines-after-magit-push-hook context)
    (error
     (message "Unable to watch Bitbucket pipeline after Magit push: %s"
              (error-message-string error-data)))))

(defun bitbucket-devops-pipelines-magit--wrap-process-sentinel (process context)
  "Arrange for PROCESS to run the post-push hook with CONTEXT on success."
  (let ((sentinel (process-sentinel process)))
    (set-process-sentinel
     process
     (lambda (process event)
       (when sentinel
         (funcall sentinel process event))
       (when (and (eq (process-status process) 'exit)
                  (zerop (process-exit-status process))
                  (not
                   (process-get
                    process
                    'bitbucket-devops-pipelines-magit-push-hook-ran)))
         (process-put process 'bitbucket-devops-pipelines-magit-push-hook-ran t)
         (bitbucket-devops-pipelines-magit--run-after-push-hook context))))))

(defun bitbucket-devops-pipelines-magit--around-run-git-async (function &rest args)
  "Call Magit FUNCTION with ARGS and watch a successful push when enabled."
  (if (not (bitbucket-devops-pipelines-magit--watchable-push-args-p args))
      (apply function args)
    (let ((context
           (condition-case nil
               (bitbucket-devops-context-resolve default-directory)
             (user-error nil))))
      (let ((process (apply function args)))
        (when (and context
                   (bitbucket-devops-pipelines-magit--targets-context-remote-p
                    args
                    context)
                   (processp process))
          (bitbucket-devops-pipelines-magit--wrap-process-sentinel
           process
           context))
        process))))

(defun bitbucket-devops-pipelines-magit--enable ()
  "Enable automatic pipeline discovery after successful Magit pushes."
  (require 'magit-process)
  (unless
      (advice-member-p
       #'bitbucket-devops-pipelines-magit--around-run-git-async
       'magit-run-git-async)
    (advice-add 'magit-run-git-async
                :around
                #'bitbucket-devops-pipelines-magit--around-run-git-async)))

(defun bitbucket-devops-pipelines-magit--disable ()
  "Disable automatic pipeline discovery after successful Magit pushes."
  (when (fboundp 'magit-run-git-async)
    (advice-remove 'magit-run-git-async
                   #'bitbucket-devops-pipelines-magit--around-run-git-async)))

;;;###autoload
(define-minor-mode bitbucket-devops-pipelines-magit-push-watch-mode
  "Automatically watch Bitbucket pipelines after successful Magit pushes."
  :global t
  :group 'bitbucket-devops-pipelines
  (if bitbucket-devops-pipelines-magit-push-watch-mode
      (bitbucket-devops-pipelines-magit--enable)
    (bitbucket-devops-pipelines-magit--disable)))

;;;###autoload
(defun bitbucket-devops-pipelines-toggle-magit-push-watch ()
  "Toggle automatic pipeline tracking after successful Magit pushes."
  (interactive)
  (bitbucket-devops-pipelines-magit-push-watch-mode
   (if bitbucket-devops-pipelines-magit-push-watch-mode -1 1))
  (message "Bitbucket pipeline Magit push tracking %s"
           (if bitbucket-devops-pipelines-magit-push-watch-mode
               "enabled"
             "disabled")))

;;;###autoload
(defun bitbucket-devops-pipelines-watch-toggle-push-tracking ()
  "Toggle automatic Magit push tracking and refresh the watcher list."
  (interactive)
  (bitbucket-devops-pipelines-toggle-magit-push-watch)
  (bitbucket-devops-pipelines-watch--render-list-buffer))

(provide 'bitbucket-devops-pipelines-magit)
;;; bitbucket-devops-pipelines-magit.el ends here
