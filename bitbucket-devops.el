;;; bitbucket-devops.el --- Bitbucket Cloud DevOps workflows -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Will Bosch-Bello

;; Author: Will Bosch-Bello <williamsbosch@gmail.com>
;; Assisted-by: Codex:gpt-5.5-codex
;; Assisted-by: Claude:claude-opus-5
;; Maintainer: Will Bosch-Bello <williamsbosch@gmail.com>
;; Version: 2.0.0
;; Package-Requires: ((emacs "29.1") (magit "4.0.0") (markdown-mode "2.6") (transient "0.3.0") (yaml "1.2.3"))
;; Keywords: tools, vc
;; URL: https://github.com/will-abb/bitbucket-devops.el
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

;; Work with Bitbucket Cloud Pipelines and pull requests from Emacs.
;;
;; For Pipelines, this package provides repository-aware history and detail
;; buffers, completed step logs, background watchers with notifications,
;; manual triggers driven by bitbucket-pipelines.yml, manual-step
;; continuation, reruns, and cancellation.
;;
;; For pull requests, it provides listing and filtering, build summaries,
;; comments and activity, commits, changed-file summaries, raw diff buffers,
;; review actions, reviewer management, inline comments and replies, and
;; pull request creation and decline.
;;
;; Start from the `bitbucket-devops-dispatch' transient menu, or call
;; `bitbucket-devops-pipelines-history' and
;; `bitbucket-devops-pull-requests-list' directly.
;;
;; Repository identity is resolved from an SSH Git remote, and credentials
;; come from auth-source.  Bitbucket Cloud only; Bitbucket Data Center is
;; not supported.  See the README for setup and authentication.

;;; Code:

(require 'transient)
(require 'bitbucket-devops-context)
(require 'bitbucket-devops-cache)
(require 'bitbucket-devops-rest)
(require 'bitbucket-devops-ui)
(require 'bitbucket-devops-pipelines-watch)
(require 'bitbucket-devops-pipelines-magit)
(require 'bitbucket-devops-pipelines-mutate)
(require 'bitbucket-devops-pull-requests-watch)
(require 'bitbucket-devops-pull-requests-ui)

(defun bitbucket-devops-pipelines-toggle-auto-download-logs ()
  "Toggle automatic log downloads for completed tracked pipelines."
  (interactive)
  (setq bitbucket-devops-pipelines-auto-download-logs
        (not bitbucket-devops-pipelines-auto-download-logs))
  (message "Bitbucket pipeline auto-download logs %s"
           (if bitbucket-devops-pipelines-auto-download-logs
               "enabled"
             "disabled")))

(defun bitbucket-devops-pipelines-toggle-magit-push-watch ()
  "Toggle automatic pipeline tracking after successful Magit pushes."
  (interactive)
  (bitbucket-devops-pipelines-magit-push-watch-mode
   (if bitbucket-devops-pipelines-magit-push-watch-mode -1 1))
  (message "Bitbucket pipeline Magit push tracking %s"
           (if bitbucket-devops-pipelines-magit-push-watch-mode
               "enabled"
             "disabled")))

;;;###autoload(autoload 'bitbucket-devops-dispatch "bitbucket-devops" nil t)
(transient-define-prefix bitbucket-devops-dispatch ()
  "Work with Bitbucket Cloud Pipelines and pull requests."
  [["Pipelines"
    ("h" "History" bitbucket-devops-pipelines-history)
    ("r" "Run Pipeline" bitbucket-devops-pipelines-run-configured)
    ("a" "Toggle auto-download logs" bitbucket-devops-pipelines-toggle-auto-download-logs)]
   ["Pull Requests"
    ("l" "List" bitbucket-devops-pull-requests-list)
    ("c" "Create" bitbucket-devops-pull-requests-create)
    ("R" "Refresh reviewer cache"
     bitbucket-devops-pull-requests-refresh-reviewer-cache)]
   ["Watchers"
    ("m" "Toggle Magit push pipeline watching" bitbucket-devops-pipelines-toggle-magit-push-watch)
    ("b" "Watch branch pipelines" bitbucket-devops-pipelines-watch-branch-current)
    ("o" "Watch repository pipelines" bitbucket-devops-pipelines-watch-repository-current)
    ("t" "List watchers" bitbucket-devops-pipelines-list-watchers)
    ("x" "Stop pipeline watcher" bitbucket-devops-pipelines-stop-watching)
    ("q" "Quit" transient-quit-one)]]
  (interactive)
  (bitbucket-devops-ui--delete-command-panel)
  (transient-setup 'bitbucket-devops-dispatch))

(provide 'bitbucket-devops)
;;; bitbucket-devops.el ends here
