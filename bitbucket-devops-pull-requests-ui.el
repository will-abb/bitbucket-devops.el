;;; bitbucket-devops-pull-requests-ui.el --- Bitbucket Pull Request UI buffers -*- lexical-binding: t; -*-

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

;; Render Bitbucket Cloud pull request list and detail buffers.

;;; Code:

(require 'diff-mode)
(require 'browse-url)
(require 'rx)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'time-date)
(require 'url-parse)
(require 'url-util)
(require 'bitbucket-devops-cache)
(require 'bitbucket-devops-context)
(require 'bitbucket-devops-rest)
(require 'bitbucket-devops-ui)
(require 'bitbucket-devops-pull-requests)
(require 'bitbucket-devops-pull-requests-rest)

(declare-function bitbucket-devops-pipelines-run-configured
                  "bitbucket-devops-pipelines-mutate"
                  (&optional directory additional))
(declare-function bitbucket-devops-pull-requests-watch-comments
                  "bitbucket-devops-pull-requests-watch"
                  (context pull-request))
(declare-function bitbucket-devops-pull-requests-watch-comments-active-p
                  "bitbucket-devops-pull-requests-watch"
                  (context pull-request-id))
(declare-function bitbucket-devops-pull-requests-watch-comments-stop
                  "bitbucket-devops-pull-requests-watch"
                  (context pull-request-id))
(declare-function evil-define-key* "evil-core"
                  (state keymap key def &rest bindings))
(declare-function magit-list-local-branch-names "magit-git" ())
(declare-function magit-list-remote-branch-names "magit-git"
                  (remote &optional local-names))
(declare-function magit-diff-range "magit-diff"
                  (revision-or-range &optional arguments files))
(declare-function magit-show-commit "magit-diff"
                  (revision &optional arguments files module))
(declare-function ediff-buffers "ediff"
                  (buffer-a buffer-b &optional startup-hooks job-name))
(declare-function markdown-mode "markdown-mode" ())
(declare-function emoji--init "emoji" (&optional force inhibit-adjust))
(defvar emoji--all-bases)

(defvar-local bitbucket-devops-pull-requests-ui--context nil
  "Repository context captured by the current pull request buffer.")

(defvar-local bitbucket-devops-pull-requests-ui--pull-requests nil
  "Pull request records loaded into the current list buffer.")

(defvar-local bitbucket-devops-pull-requests-ui--next-url nil
  "Trusted next-page URL for the current pull request list buffer.")

(defvar-local bitbucket-devops-pull-requests-ui--loading nil
  "Non-nil while the current pull request list buffer is loading.")

(defvar-local bitbucket-devops-pull-requests-ui--request-generation 0
  "Generation used to ignore stale pull request list enrichment callbacks.")

(defvar-local bitbucket-devops-pull-requests-ui--state-filter nil
  "Bitbucket pull request state filter for the current list buffer.")

(defvar-local bitbucket-devops-pull-requests-ui--branch-filter nil
  "Source or destination branch filter for the current list buffer.")

(defvar-local bitbucket-devops-pull-requests-ui--author-filter nil
  "Author display-name filter for the current list buffer.")

(defvar-local bitbucket-devops-pull-requests-ui--details-pull-request-id nil
  "Pull request ID displayed by the current detail buffer.")

(defvar-local bitbucket-devops-pull-requests-ui--details-pull-request nil
  "Pull request record displayed by the current detail buffer.")

(defvar-local bitbucket-devops-pull-requests-ui--details-activity nil
  "Activity records displayed by the current detail buffer.")

(defvar-local bitbucket-devops-pull-requests-ui--details-comments nil
  "Comment records displayed by the current detail buffer.")

(defvar-local bitbucket-devops-pull-requests-ui--details-commits nil
  "Commit records displayed by the current detail buffer.")

(defvar-local bitbucket-devops-pull-requests-ui--details-statuses nil
  "Build status records displayed by the current detail buffer.")

(defvar-local bitbucket-devops-pull-requests-ui--details-tasks nil
  "Task records displayed by the current detail buffer.")

(defvar-local bitbucket-devops-pull-requests-ui--details-diffstat nil
  "Diffstat records displayed by the current detail buffer.")

(defvar-local bitbucket-devops-pull-requests-ui--description-source-buffer nil
  "Pull request detail buffer associated with a description editor.")

(defvar-local bitbucket-devops-pull-requests-ui--description-title nil
  "Pull request title to save with the edited description.")

(defvar-local bitbucket-devops-pull-requests-ui--description-saving nil
  "Non-nil while a description editor is saving to Bitbucket.")

(defvar-local bitbucket-devops-pull-requests-ui--create-source-buffer nil
  "Pull request list buffer associated with a creation description editor.")

(defvar-local bitbucket-devops-pull-requests-ui--create-metadata nil
  "Pull request creation metadata stored in a description editor.")

(defvar-local bitbucket-devops-pull-requests-ui--create-reviewer-strategy nil
  "Reviewer strategy stored in a pull request creation editor.")

(defvar-local bitbucket-devops-pull-requests-ui--create-saving nil
  "Non-nil while a pull request creation editor is saving.")

(defvar bitbucket-devops-pull-requests-ui--emoji-shortcodes nil
  "Cached mapping from Markdown emoji shortcodes to Unicode glyphs.")

(defvar ediff-after-quit-hook-internal)

(defface bitbucket-devops-pull-requests-title-face
  '((((class color) (background dark))
     :inherit font-lock-function-name-face :foreground "#c678dd" :weight bold)
    (((class color) (background light))
     :inherit font-lock-function-name-face :foreground "#6f42c1" :weight bold)
    (t :inherit font-lock-function-name-face :weight bold))
  "Face used for pull request titles."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-heading-face
  '((((class color) (background dark))
     :inherit font-lock-function-name-face :foreground "#51afef"
     :weight bold :height 1.3)
    (((class color) (background light))
     :inherit font-lock-function-name-face :foreground "#005cc5"
     :weight bold :height 1.3)
    (t :inherit font-lock-function-name-face :weight bold :height 1.3))
  "Face used for large pull request buffer headings."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-id-face
  '((((class color) (background dark))
     :inherit font-lock-constant-face :foreground "#da8548" :weight bold)
    (((class color) (background light))
     :inherit font-lock-constant-face :foreground "#b05a00" :weight bold)
    (t :inherit font-lock-constant-face :weight bold))
  "Face used for pull request numbers."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-section-face
  '((((class color) (background dark))
     :inherit font-lock-keyword-face :foreground "#51afef"
     :weight bold :overline t)
    (((class color) (background light))
     :inherit font-lock-keyword-face :foreground "#005cc5"
     :weight bold :overline t)
    (t :inherit font-lock-keyword-face :weight bold :overline t))
  "Face used for pull request detail section headings."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-field-label-face
  '((((class color) (background dark))
     :inherit font-lock-variable-name-face :foreground "#46d9ff" :weight bold)
    (((class color) (background light))
     :inherit font-lock-variable-name-face :foreground "#007c91" :weight bold)
    (t :inherit font-lock-variable-name-face :weight bold))
  "Face used for pull request field labels."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-open-face
  '((((class color) (background dark))
     :inherit success :foreground "#98be65" :weight bold
     :box (:line-width -1 :color "#98be65"))
    (((class color) (background light))
     :inherit success :foreground "#2e7d32" :weight bold
     :box (:line-width -1 :color "#2e7d32"))
    (t :inherit success :weight bold :box (:line-width -1)))
  "Face used for open pull requests."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-merged-face
  '((((class color) (background dark))
     :inherit success :foreground "#98be65" :weight bold
     :box (:line-width -1 :color "#98be65"))
    (((class color) (background light))
     :inherit success :foreground "#2e7d32" :weight bold
     :box (:line-width -1 :color "#2e7d32"))
    (t :inherit success :weight bold :box (:line-width -1)))
  "Face used for merged pull requests."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-declined-face
  '((((class color) (background dark))
     :inherit error :foreground "#ff6c6b" :weight bold
     :box (:line-width -1 :color "#ff6c6b"))
    (((class color) (background light))
     :inherit error :foreground "#c62828" :weight bold
     :box (:line-width -1 :color "#c62828"))
    (t :inherit error :weight bold :box (:line-width -1)))
  "Face used for declined pull requests."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-superseded-face
  '((((class color) (background dark))
     :inherit shadow :foreground "#7f849c" :weight bold
     :box (:line-width -1 :color "#7f849c"))
    (((class color) (background light))
     :inherit shadow :foreground "#6a737d" :weight bold
     :box (:line-width -1 :color "#6a737d"))
    (t :inherit shadow :weight bold :box (:line-width -1)))
  "Face used for superseded pull requests."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-draft-face
  '((((class color) (background dark))
     :inherit warning :foreground "#ecbe7b" :weight bold
     :box (:line-width -1 :color "#ecbe7b"))
    (((class color) (background light))
     :inherit warning :foreground "#9a6700" :weight bold
     :box (:line-width -1 :color "#9a6700"))
    (t :inherit warning :weight bold :box (:line-width -1)))
  "Face used for draft pull request metadata."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-source-branch-face
  '((((class color) (background dark))
     :inherit font-lock-keyword-face :foreground "#51afef" :weight semi-bold)
    (((class color) (background light))
     :inherit font-lock-keyword-face :foreground "#005cc5" :weight semi-bold)
    (t :inherit font-lock-keyword-face :weight semi-bold))
  "Face used for pull request source branches."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-destination-branch-face
  '((((class color) (background dark))
     :inherit font-lock-type-face :foreground "#c678dd" :weight semi-bold)
    (((class color) (background light))
     :inherit font-lock-type-face :foreground "#6f42c1" :weight semi-bold)
    (t :inherit font-lock-type-face :weight semi-bold))
  "Face used for pull request destination branches."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-author-face
  '((((class color) (background dark))
     :inherit font-lock-variable-name-face :foreground "#46d9ff")
    (((class color) (background light))
     :inherit font-lock-variable-name-face :foreground "#007c91")
    (t :inherit font-lock-variable-name-face))
  "Face used for pull request authors and commenters."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-count-face
  '((((class color) (background dark))
     :inherit font-lock-constant-face :foreground "#da8548" :weight bold)
    (((class color) (background light))
     :inherit font-lock-constant-face :foreground "#b05a00" :weight bold)
    (t :inherit font-lock-constant-face :weight bold))
  "Face used for pull request counts."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-success-face
  '((((class color) (background dark))
     :inherit success :foreground "#98be65" :weight bold)
    (((class color) (background light))
     :inherit success :foreground "#2e7d32" :weight bold)
    (t :inherit success :weight bold))
  "Face used for successful pull request checks and resolved work."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-warning-face
  '((((class color) (background dark))
     :inherit warning :foreground "#ecbe7b" :weight bold)
    (((class color) (background light))
     :inherit warning :foreground "#9a6700" :weight bold)
    (t :inherit warning :weight bold))
  "Face used for active pull request checks and unresolved work."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-error-face
  '((((class color) (background dark))
     :inherit error :foreground "#ff6c6b" :weight bold)
    (((class color) (background light))
     :inherit error :foreground "#c62828" :weight bold)
    (t :inherit error :weight bold))
  "Face used for failed pull request checks."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-secondary-face
  '((((class color) (background dark))
     :inherit shadow :foreground "#7f849c")
    (((class color) (background light))
     :inherit shadow :foreground "#6a737d")
    (t :inherit shadow))
  "Face used for secondary pull request metadata."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-empty-face
  '((((class color) (background dark))
     :inherit shadow :foreground "#7f849c" :slant italic)
    (((class color) (background light))
     :inherit shadow :foreground "#6a737d" :slant italic)
    (t :inherit shadow :slant italic))
  "Face used for empty pull request sections."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-description-face
  '((((class color) (background dark))
     :inherit font-lock-doc-face :foreground "#cdd6f4")
    (((class color) (background light))
     :inherit font-lock-doc-face :foreground "#24292f")
    (t :inherit font-lock-doc-face))
  "Face used for pull request descriptions and comment text."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-commit-face
  '((((class color) (background dark))
     :inherit font-lock-constant-face :foreground "#da8548" :weight bold)
    (((class color) (background light))
     :inherit font-lock-constant-face :foreground "#b05a00" :weight bold)
    (t :inherit font-lock-constant-face :weight bold))
  "Face used for pull request commit hashes."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-message-face
  '((((class color) (background dark))
     :inherit font-lock-string-face :foreground "#98be65")
    (((class color) (background light))
     :inherit font-lock-string-face :foreground "#2e7d32")
    (t :inherit font-lock-string-face))
  "Face used for pull request commit messages."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-file-face
  '((((class color) (background dark))
     :inherit font-lock-function-name-face :foreground "#51afef")
    (((class color) (background light))
     :inherit font-lock-function-name-face :foreground "#005cc5")
    (t :inherit font-lock-function-name-face))
  "Face used for changed file paths."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-added-face
  '((((class color) (background dark))
     :inherit diff-added :foreground "#98be65" :weight bold)
    (((class color) (background light))
     :inherit diff-added :foreground "#2e7d32" :weight bold)
    (t :inherit diff-added :weight bold))
  "Face used for added files and lines."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-removed-face
  '((((class color) (background dark))
     :inherit diff-removed :foreground "#ff6c6b" :weight bold)
    (((class color) (background light))
     :inherit diff-removed :foreground "#c62828" :weight bold)
    (t :inherit diff-removed :weight bold))
  "Face used for removed files and lines."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-modified-face
  '((((class color) (background dark))
     :inherit diff-changed :foreground "#ecbe7b" :weight bold)
    (((class color) (background light))
     :inherit diff-changed :foreground "#9a6700" :weight bold)
    (t :inherit diff-changed :weight bold))
  "Face used for modified files."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-renamed-face
  '((((class color) (background dark))
     :inherit font-lock-keyword-face :foreground "#c678dd" :weight bold)
    (((class color) (background light))
     :inherit font-lock-keyword-face :foreground "#6f42c1" :weight bold)
    (t :inherit font-lock-keyword-face :weight bold))
  "Face used for renamed files."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-diff-file-face
  '((((class color) (background dark))
     :inherit diff-file-header :foreground "#51afef" :weight bold)
    (((class color) (background light))
     :inherit diff-file-header :foreground "#005cc5" :weight bold)
    (t :inherit diff-file-header :weight bold))
  "Face used for file headers in pull request diffs."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-diff-hunk-face
  '((((class color) (background dark))
     :inherit diff-hunk-header :foreground "#c678dd" :weight bold)
    (((class color) (background light))
     :inherit diff-hunk-header :foreground "#6f42c1" :weight bold)
    (t :inherit diff-hunk-header :weight bold))
  "Face used for hunk headers in pull request diffs."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-header-face
  '((((class color) (background dark))
     :inherit mode-line-emphasis :foreground "#51afef" :weight bold)
    (((class color) (background light))
     :inherit mode-line-emphasis :foreground "#005cc5" :weight bold)
    (t :inherit mode-line-emphasis :weight bold))
  "Face used for repository names in pull request header lines."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-filter-face
  '((((class color) (background dark))
     :inherit font-lock-keyword-face :foreground "#46d9ff" :weight bold
     :box (:line-width -1 :color "#46d9ff"))
    (((class color) (background light))
     :inherit font-lock-keyword-face :foreground "#007c91" :weight bold
     :box (:line-width -1 :color "#007c91"))
    (t :inherit font-lock-keyword-face :weight bold :box (:line-width -1)))
  "Face used for active pull request list filters."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-comment-id-face
  '((((class color) (background dark))
     :inherit font-lock-constant-face :foreground "#da8548" :weight bold)
    (((class color) (background light))
     :inherit font-lock-constant-face :foreground "#b05a00" :weight bold)
    (t :inherit font-lock-constant-face :weight bold))
  "Face used for pull request comment and task identifiers."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-timeline-face
  '((((class color) (background dark))
     :inherit font-lock-keyword-face :foreground "#51afef" :weight bold)
    (((class color) (background light))
     :inherit font-lock-keyword-face :foreground "#005cc5" :weight bold)
    (t :inherit font-lock-keyword-face :weight bold))
  "Face used for pull request activity timeline markers."
  :group 'bitbucket-devops-pull-requests)

(defface bitbucket-devops-pull-requests-resolved-text-face
  '((t :inherit shadow :strike-through t))
  "Face used for completed pull request task text."
  :group 'bitbucket-devops-pull-requests)

(defun bitbucket-devops-pull-requests-ui--set-keybinding-option (symbol value)
  "Set keybinding option SYMBOL to VALUE and refresh maps when available."
  (set-default symbol value)
  (when (and (fboundp 'bitbucket-devops-pull-requests-ui-apply-keybindings)
             (boundp 'bitbucket-devops-pull-requests-ui--applied-keybindings))
    (bitbucket-devops-pull-requests-ui-apply-keybindings)))

(defcustom bitbucket-devops-pull-requests-list-keybindings
  '(("r" . bitbucket-devops-pull-requests-ui-refresh-current)
    ("C-c g" . bitbucket-devops-pull-requests-ui-refresh-current)
    ("RET" . bitbucket-devops-pull-requests-ui-open-at-point)
    ("S-RET" . bitbucket-devops-pull-requests-ui-copy-browser-url-at-point)
    ("S-<return>" . bitbucket-devops-pull-requests-ui-copy-browser-url-at-point)
    ("n" . bitbucket-devops-pull-requests-ui-load-more)
    ("s" . bitbucket-devops-pull-requests-ui-set-state-filter)
    ("f" . bitbucket-devops-pull-requests-ui-set-branch-filter)
    ("a" . bitbucket-devops-pull-requests-ui-set-author-filter)
    ("P" . bitbucket-devops-pull-requests-ui-run-pipeline)
    ("C-c P" . bitbucket-devops-pull-requests-ui-run-pipeline)
    ("C-c b" . bitbucket-devops-pull-requests-ui-checkout-source-branch)
    ("t" . bitbucket-devops-pull-requests-ui-toggle-comment-watch)
    ("C-c w" . bitbucket-devops-pull-requests-ui-toggle-comment-watch)
    ("C-c C-w" . bitbucket-devops-pull-requests-ui-toggle-comment-watch)
    ("o" . bitbucket-devops-pull-requests-ui-browse)
    ("c" . bitbucket-devops-pull-requests-ui-create)
    ("-" . bitbucket-devops-ui-back)
    ("q" . bitbucket-devops-ui-quit)
    ("?" . bitbucket-devops-ui-show-command-panel))
  "Keybindings shared by non-Evil and Evil pull request list buffers."
  :type '(alist :key-type string :value-type function)
  :set #'bitbucket-devops-pull-requests-ui--set-keybinding-option
  :group 'bitbucket-devops-pull-requests)

(defcustom bitbucket-devops-pull-requests-display-emoji-shortcodes t
  "When non-nil, display recognized comment emoji shortcodes as glyphs.

This changes only rendered pull request comments.  The original Markdown text
is retained for editing and requests sent to Bitbucket."
  :type 'boolean
  :group 'bitbucket-devops-pull-requests)

(defcustom bitbucket-devops-pull-requests-auto-watch-created nil
  "When non-nil, prompt to watch comments after creating a pull request.

The prompt defaults to yes.  A watcher starts only when the user accepts."
  :type 'boolean
  :group 'bitbucket-devops-pull-requests)

(defcustom bitbucket-devops-pull-requests-build-status-action 'browser
  "Default action for RET on a pull request build status row.

`browser' opens the build status URL with `browse-url'.  `local' opens the
matching Bitbucket Pipelines details buffer when the status can be mapped to a
pipeline.  Use a prefix argument, such as \\[universal-argument] before RET,
to run the other action for one invocation."
  :type '(choice
          (const :tag "Open build status URL in browser" browser)
          (const :tag "Open matching pipeline details buffer locally" local))
  :group 'bitbucket-devops-pull-requests)

(defcustom bitbucket-devops-pull-requests-detail-keybindings
  '(("r" . bitbucket-devops-pull-requests-ui-refresh-current)
    ("C-c g" . bitbucket-devops-pull-requests-ui-refresh-current)
    ("RET" . bitbucket-devops-pull-requests-ui-open-detail-at-point)
    ("S-RET" . bitbucket-devops-pull-requests-ui-copy-browser-url-at-point)
    ("S-<return>" . bitbucket-devops-pull-requests-ui-copy-browser-url-at-point)
    ("<mouse-1>" . bitbucket-devops-pull-requests-ui-open-detail-at-mouse)
    ("d" . bitbucket-devops-pull-requests-ui-open-diff)
    ("C-c d" . bitbucket-devops-pull-requests-ui-choose-diff-viewer)
    ("m" . bitbucket-devops-pull-requests-ui-open-commits)
    ("A" . bitbucket-devops-pull-requests-ui-open-activity)
    ("P" . bitbucket-devops-pull-requests-ui-run-pipeline)
    ("C-c P" . bitbucket-devops-pull-requests-ui-run-pipeline)
    ("C-c b" . bitbucket-devops-pull-requests-ui-checkout-source-branch)
    ("C-c w" . bitbucket-devops-pull-requests-ui-toggle-comment-watch)
    ("C-c C-w" . bitbucket-devops-pull-requests-ui-toggle-comment-watch)
    ("o" . bitbucket-devops-pull-requests-ui-browse)
    ("R" . bitbucket-devops-pull-requests-ui-toggle-draft)
    ("a" . bitbucket-devops-pull-requests-ui-approve)
    ("u" . bitbucket-devops-pull-requests-ui-remove-approval)
    ("x" . bitbucket-devops-pull-requests-ui-request-changes)
    ("X" . bitbucket-devops-pull-requests-ui-remove-request-changes)
    ("c" . bitbucket-devops-pull-requests-ui-add-comment)
    ("C" . bitbucket-devops-pull-requests-ui-reply-to-comment)
    ("C-c e" . bitbucket-devops-pull-requests-ui-edit-comment)
    ("C-c k" . bitbucket-devops-pull-requests-ui-delete-comment)
    ("C-c i" . bitbucket-devops-pull-requests-ui-add-inline-comment)
    ("C-c r" . bitbucket-devops-pull-requests-ui-resolve-comment)
    ("C-c o" . bitbucket-devops-pull-requests-ui-reopen-comment)
    ("C-c +" . bitbucket-devops-pull-requests-ui-add-reviewer)
    ("C-c =" . bitbucket-devops-pull-requests-ui-add-default-reviewers)
    ("C-c -" . bitbucket-devops-pull-requests-ui-remove-reviewer)
    ("M" . bitbucket-devops-pull-requests-ui-merge)
    ("D" . bitbucket-devops-pull-requests-ui-decline)
    ("-" . bitbucket-devops-ui-back)
    ("q" . bitbucket-devops-ui-quit)
    ("?" . bitbucket-devops-ui-show-command-panel))
  "Keybindings shared by non-Evil and Evil pull request detail buffers."
  :type '(alist :key-type string :value-type function)
  :set #'bitbucket-devops-pull-requests-ui--set-keybinding-option
  :group 'bitbucket-devops-pull-requests)

(defcustom bitbucket-devops-pull-requests-evil-universal-argument-keybindings
  '("C-u" "SPC u")
  "Evil normal-state keys that start `universal-argument' in PR buffers.

These keys make prefix-sensitive commands behave the same for Evil users as
ordinary Emacs users.  For example, either default key followed by RET inverts
the configured pull request build-status action."
  :type '(repeat string)
  :set #'bitbucket-devops-pull-requests-ui--set-keybinding-option
  :group 'bitbucket-devops-pull-requests)

(defcustom bitbucket-devops-pull-requests-diff-viewer 'bitbucket
  "Viewer used by `bitbucket-devops-pull-requests-ui-open-diff'.

`bitbucket' displays the exact patch returned by Bitbucket Cloud.
`magit' fetches the pull request revisions and displays their three-dot range
in Magit.  `ediff' prompts for a changed file and compares its merge-base and
source versions.  Use
`bitbucket-devops-pull-requests-ui-choose-diff-viewer' to select a viewer for
one invocation without changing this option."
  :type '(choice
          (const :tag "Bitbucket patch buffer" bitbucket)
          (const :tag "Magit range diff" magit)
          (const :tag "Ediff changed file" ediff))
  :group 'bitbucket-devops-pull-requests)

(defcustom bitbucket-devops-pull-requests-diff-keybindings
  '(("r" . bitbucket-devops-pull-requests-ui-refresh-current)
    ("C-c g" . bitbucket-devops-pull-requests-ui-refresh-current)
    ("i" . bitbucket-devops-pull-requests-ui-add-inline-comment)
    ("C-c i" . bitbucket-devops-pull-requests-ui-add-inline-comment)
    ("-" . bitbucket-devops-ui-back)
    ("q" . bitbucket-devops-ui-quit)
    ("?" . bitbucket-devops-ui-show-command-panel))
  "Keybindings shared by non-Evil and Evil pull request diff buffers."
  :type '(alist :key-type string :value-type function)
  :set #'bitbucket-devops-pull-requests-ui--set-keybinding-option
  :group 'bitbucket-devops-pull-requests)

(defcustom bitbucket-devops-pull-requests-subview-keybindings
  '(("r" . bitbucket-devops-pull-requests-ui-refresh-current)
    ("C-c g" . bitbucket-devops-pull-requests-ui-refresh-current)
    ("-" . bitbucket-devops-ui-back)
    ("q" . bitbucket-devops-ui-quit)
    ("?" . bitbucket-devops-ui-show-command-panel))
  "Keybindings shared by pull request commit and activity buffers."
  :type '(alist :key-type string :value-type function)
  :set #'bitbucket-devops-pull-requests-ui--set-keybinding-option
  :group 'bitbucket-devops-pull-requests)

(defcustom bitbucket-devops-pull-requests-commits-keybindings
  '(("RET" . bitbucket-devops-pull-requests-ui-open-commit-at-point)
    ("<mouse-1>" . bitbucket-devops-pull-requests-ui-open-commit-at-mouse))
  "Additional bindings for pull request commit buffers.

These bindings are installed for both ordinary Emacs use and Evil normal
state.  Refresh, back, and quit bindings come from
`bitbucket-devops-pull-requests-subview-keybindings'."
  :type '(alist :key-type string :value-type function)
  :set #'bitbucket-devops-pull-requests-ui--set-keybinding-option
  :group 'bitbucket-devops-pull-requests)

(defcustom bitbucket-devops-pull-requests-task-keybindings
  '(("c" . bitbucket-devops-pull-requests-ui-create-task)
    ("e" . bitbucket-devops-pull-requests-ui-edit-task)
    ("d" . bitbucket-devops-pull-requests-ui-delete-task)
    ("r" . bitbucket-devops-pull-requests-ui-resolve-task)
    ("o" . bitbucket-devops-pull-requests-ui-reopen-task))
  "Bindings below the pull request task prefix."
  :type '(alist :key-type string :value-type function)
  :set #'bitbucket-devops-pull-requests-ui--set-keybinding-option
  :group 'bitbucket-devops-pull-requests)

(defcustom bitbucket-devops-pull-requests-metadata-keybindings
  '(("e" . bitbucket-devops-pull-requests-ui-edit-metadata)
    ("d" . bitbucket-devops-pull-requests-ui-toggle-draft))
  "Bindings below the pull request metadata prefix."
  :type '(alist :key-type string :value-type function)
  :set #'bitbucket-devops-pull-requests-ui--set-keybinding-option
  :group 'bitbucket-devops-pull-requests)

(defcustom bitbucket-devops-pull-requests-task-prefix-key "C-c t"
  "Prefix key for pull request task actions."
  :type 'string
  :set #'bitbucket-devops-pull-requests-ui--set-keybinding-option
  :group 'bitbucket-devops-pull-requests)

(defcustom bitbucket-devops-pull-requests-metadata-prefix-key "C-c p"
  "Prefix key for pull request metadata actions."
  :type 'string
  :set #'bitbucket-devops-pull-requests-ui--set-keybinding-option
  :group 'bitbucket-devops-pull-requests)

(defcustom bitbucket-devops-pull-requests-sync-always-count 5
  "Number of newest pull requests to always refetch during list refresh.

The pull request list opens from cached rows when available, then fetches the
newest list page from Bitbucket.  This option controls how many newest loaded
pull requests are also refetched through the detail endpoint even when their
state is terminal.  Set to nil or 0 to disable unconditional revalidation."
  :type '(choice (const :tag "Disable unconditional pull request revalidation" nil)
                 (integer :tag "Newest pull requests to always revalidate"))
  :group 'bitbucket-devops-pull-requests)

(defcustom bitbucket-devops-pull-requests-sync-active-count 20
  "Number of newest active pull requests to refetch during list refresh.

Only pull requests whose state is `OPEN', or whose state is unknown, are
considered active.  Terminal states such as `MERGED', `DECLINED', and
`SUPERSEDED' are skipped unless they are also covered by
`bitbucket-devops-pull-requests-sync-always-count'."
  :type '(choice (const :tag "Disable active pull request revalidation" nil)
                 (integer :tag "Newest active pull requests to revalidate"))
  :group 'bitbucket-devops-pull-requests)

(defun bitbucket-devops-pull-requests-ui--key-for-command (bindings command)
  "Return the key in BINDINGS assigned to COMMAND."
  (car (rassq command bindings)))

(defun bitbucket-devops-pull-requests-ui--keys-for-command (bindings command)
  "Return all keys in BINDINGS assigned to COMMAND."
  (delq
   nil
   (mapcar
    (lambda (binding)
      (when (eq (cdr binding) command)
        (car binding)))
    bindings)))

(defun bitbucket-devops-pull-requests-ui-keys-for-command (command)
  "Return configured keys for COMMAND in the current PR buffer."
  (cond
   ((derived-mode-p 'bitbucket-devops-pull-requests-list-mode)
    (bitbucket-devops-pull-requests-ui--keys-for-command
     bitbucket-devops-pull-requests-list-keybindings command))
   ((derived-mode-p 'bitbucket-devops-pull-requests-detail-mode)
    (bitbucket-devops-pull-requests-ui--keys-for-command
     bitbucket-devops-pull-requests-detail-keybindings command))
   ((derived-mode-p 'bitbucket-devops-pull-requests-diff-mode)
    (bitbucket-devops-pull-requests-ui--keys-for-command
     bitbucket-devops-pull-requests-diff-keybindings command))
   ((derived-mode-p 'bitbucket-devops-pull-requests-commits-mode)
    (append
     (bitbucket-devops-pull-requests-ui--keys-for-command
      bitbucket-devops-pull-requests-commits-keybindings command)
     (bitbucket-devops-pull-requests-ui--keys-for-command
      bitbucket-devops-pull-requests-subview-keybindings command)))
   ((derived-mode-p 'bitbucket-devops-pull-requests-activity-mode)
    (bitbucket-devops-pull-requests-ui--keys-for-command
     bitbucket-devops-pull-requests-subview-keybindings command))))

(defun bitbucket-devops-pull-requests-ui-key-for-command (command)
  "Return the configured key for COMMAND in the current PR buffer."
  (or
   (cond
    ((derived-mode-p 'bitbucket-devops-pull-requests-list-mode)
     (bitbucket-devops-pull-requests-ui--key-for-command
      bitbucket-devops-pull-requests-list-keybindings command))
    ((derived-mode-p 'bitbucket-devops-pull-requests-detail-mode)
     (bitbucket-devops-pull-requests-ui--key-for-command
      bitbucket-devops-pull-requests-detail-keybindings command))
    ((derived-mode-p 'bitbucket-devops-pull-requests-diff-mode)
     (bitbucket-devops-pull-requests-ui--key-for-command
      bitbucket-devops-pull-requests-diff-keybindings command))
    ((derived-mode-p 'bitbucket-devops-pull-requests-commits-mode)
     (or (bitbucket-devops-pull-requests-ui--key-for-command
          bitbucket-devops-pull-requests-commits-keybindings command)
         (bitbucket-devops-pull-requests-ui--key-for-command
          bitbucket-devops-pull-requests-subview-keybindings command)))
    ((derived-mode-p 'bitbucket-devops-pull-requests-activity-mode)
     (bitbucket-devops-pull-requests-ui--key-for-command
      bitbucket-devops-pull-requests-subview-keybindings command)))
   (when (derived-mode-p 'bitbucket-devops-pull-requests-detail-mode)
     (when-let ((key
                 (bitbucket-devops-pull-requests-ui--key-for-command
                  bitbucket-devops-pull-requests-task-keybindings command)))
       (concat bitbucket-devops-pull-requests-task-prefix-key " " key)))
   (when (derived-mode-p 'bitbucket-devops-pull-requests-detail-mode)
     (when-let ((key
                 (bitbucket-devops-pull-requests-ui--key-for-command
                  bitbucket-devops-pull-requests-metadata-keybindings command)))
       (concat bitbucket-devops-pull-requests-metadata-prefix-key " " key)))))

(defcustom bitbucket-devops-pull-requests-list-column-widths
  '((number . 8)
    (state . 12)
    (title . 34)
    (source . 18)
    (destination . 18)
    (author . 22)
    (reviewers . 10)
    (approvals . 10)
    (builds . 10)
    (created . 16)
    (updated . 16))
  "Column widths used by Bitbucket pull request list buffers."
  :type '(alist :key-type symbol :value-type integer)
  :group 'bitbucket-devops-pull-requests)

(defcustom bitbucket-devops-pull-requests-list-truncate-lines t
  "Whether pull request list buffers keep each row on one visual line.

When non-nil, pull request list buffers disable visual line wrapping and
truncate long rows horizontally.  When nil, list buffers allow Emacs to wrap
long rows according to the buffer and window's normal wrapping settings."
  :type 'boolean
  :group 'bitbucket-devops-pull-requests)

(defun bitbucket-devops-pull-requests-ui--column-width (column default)
  "Return configured COLUMN width, falling back to DEFAULT."
  (let ((value (alist-get column bitbucket-devops-pull-requests-list-column-widths)))
    (if (and (integerp value) (>= value 0))
        value
      default)))

(defun bitbucket-devops-pull-requests-ui--apply-list-line-wrapping ()
  "Apply configured line wrapping behavior to the current pull request list."
  (setq-local tabulated-list-use-header-line nil)
  (if bitbucket-devops-pull-requests-list-truncate-lines
      (bitbucket-devops-ui--disable-line-wrapping)
    (setq-local truncate-lines nil)))

(defun bitbucket-devops-pull-requests-ui--format-time (timestamp)
  "Return TIMESTAMP as a concise local date/time string."
  (if (or (null timestamp) (string-empty-p timestamp))
      ""
    (condition-case nil
        (format-time-string "%Y-%m-%d %H:%M" (date-to-time timestamp))
      (error timestamp))))

(defun bitbucket-devops-pull-requests-ui--values (page-or-values)
  "Return Bitbucket values from PAGE-OR-VALUES."
  (if (and (listp page-or-values)
           (assq 'values page-or-values))
      (or (alist-get 'values page-or-values) nil)
    page-or-values))

(defun bitbucket-devops-pull-requests-ui--state-label (summary)
  "Return a display state for normalized PR SUMMARY."
  (let ((state (plist-get summary :state)))
    (if (plist-get summary :draft)
        (concat state " DRAFT")
      state)))

(defun bitbucket-devops-pull-requests-ui--build-label (pull-request)
  "Return the build summary label stored on PULL-REQUEST."
  (or (alist-get 'bitbucket-devops-pull-requests-build-label pull-request)
      ""))

(defun bitbucket-devops-pull-requests-ui--build-summary-label (statuses)
  "Return a concise list-column label for STATUSES."
  (let* ((summary (bitbucket-devops-pull-requests-status-summary statuses))
         (total (plist-get summary :total))
         (passed (plist-get summary :passed))
         (failed (plist-get summary :failed))
         (in-progress (plist-get summary :in-progress))
         (stopped (plist-get summary :stopped)))
    (cond
     ((zerop total) "No builds")
     ((> failed 0) (format "%s failed" failed))
     ((> in-progress 0) (format "%s running" in-progress))
     ((= passed total) (format "%s passed" passed))
     ((> stopped 0) (format "%s stopped" stopped))
     (t (format "%s/%s passed" passed total)))))

(defun bitbucket-devops-pull-requests-ui--style (value face)
  "Return VALUE as a string propertized with FACE."
  (propertize (format "%s" (or value "")) 'face face))

(defun bitbucket-devops-pull-requests-ui--add-action
    (start end command help)
  "Mark text from START to END as an interactive detail COMMAND.

HELP is used as the hover text for mouse users."
  (add-text-properties
   start
   end
   (list 'bitbucket-devops-pull-requests-action command
         'mouse-face 'highlight
         'help-echo help
         'follow-link t)))

(defun bitbucket-devops-pull-requests-ui--property-at-point-or-line (property)
  "Return PROPERTY at point or from the current line."
  (or (get-text-property (point) property)
      (and (> (point) (point-min))
           (get-text-property
            (1- (point))
            property))
      (save-excursion
        (let ((line-end (line-end-position)))
          (goto-char (line-beginning-position))
          (catch 'value
            (while (< (point) line-end)
              (when-let ((value
                          (get-text-property
                           (point)
                           property)))
                (throw 'value value))
              (let ((next
                     (next-single-property-change
                      (point)
                      property
                      nil
                      line-end)))
                (goto-char
                 (if (and next (> next (point)))
                     next
                   (1+ (point))))))
            nil)))))

(defun bitbucket-devops-pull-requests-ui--action-at-point ()
  "Return the detail action at point or on the current line."
  (bitbucket-devops-pull-requests-ui--property-at-point-or-line
   'bitbucket-devops-pull-requests-action))

(defun bitbucket-devops-pull-requests-ui--browser-url-segment (value)
  "Return VALUE encoded for a Bitbucket browser URL path segment."
  (url-hexify-string (format "%s" (or value ""))))

(defun bitbucket-devops-pull-requests-ui--pull-requests-url (context)
  "Return the Bitbucket browser URL for CONTEXT's pull request list."
  (format
   "https://bitbucket.org/%s/%s/pull-requests/"
   (bitbucket-devops-pull-requests-ui--browser-url-segment
    (plist-get context :workspace))
   (bitbucket-devops-pull-requests-ui--browser-url-segment
    (plist-get context :repo-slug))))

(defun bitbucket-devops-pull-requests-ui--pull-request-url
    (context pull-request &optional pull-request-id)
  "Return the Bitbucket browser URL for PULL-REQUEST in CONTEXT.

Prefer Bitbucket's API-provided HTML link and fall back to CONTEXT plus
PULL-REQUEST-ID when the loaded record does not include links."
  (or (bitbucket-devops-pull-requests--nested-get pull-request 'links 'html 'href)
      (format
       "%s%s"
       (bitbucket-devops-pull-requests-ui--pull-requests-url context)
       (or pull-request-id (alist-get 'id pull-request)))))

(defun bitbucket-devops-pull-requests-ui--state-face (state)
  "Return the semantic face for pull request STATE."
  (pcase (upcase (or state "UNKNOWN"))
    ("OPEN" 'bitbucket-devops-pull-requests-open-face)
    ("MERGED" 'bitbucket-devops-pull-requests-merged-face)
    ("DECLINED" 'bitbucket-devops-pull-requests-declined-face)
    ("SUPERSEDED" 'bitbucket-devops-pull-requests-superseded-face)
    (_ 'bitbucket-devops-pull-requests-secondary-face)))

(defun bitbucket-devops-pull-requests-ui--state-label-styled (summary)
  "Return SUMMARY's state and draft labels with semantic faces."
  (let ((state (plist-get summary :state)))
    (concat
     (bitbucket-devops-pull-requests-ui--style
      state
      (bitbucket-devops-pull-requests-ui--state-face state))
     (if (plist-get summary :draft)
         (concat
          " "
          (bitbucket-devops-pull-requests-ui--style
           "DRAFT"
           'bitbucket-devops-pull-requests-draft-face))
       ""))))

(defun bitbucket-devops-pull-requests-ui--state-action-candidates
    (pull-request)
  "Return state action candidates for PULL-REQUEST."
  (let ((state (upcase (or (alist-get 'state pull-request) "")))
        (draft (eq (alist-get 'draft pull-request) t)))
    (when (equal state "OPEN")
      (append
       (list
        (if draft
            (cons
             "Mark ready for review"
             #'bitbucket-devops-pull-requests-ui-mark-ready)
          (cons
           "Mark draft"
           #'bitbucket-devops-pull-requests-ui-mark-draft)))
       (unless draft
         (list
          (cons "Merge" #'bitbucket-devops-pull-requests-ui-merge)))
       (list
        (cons "Decline" #'bitbucket-devops-pull-requests-ui-decline))))))

(defun bitbucket-devops-pull-requests-ui-change-state ()
  "Choose and run a valid state transition for the current pull request."
  (interactive)
  (bitbucket-devops-pull-requests-ui--require-details-context)
  (unless bitbucket-devops-pull-requests-ui--details-pull-request
    (user-error "Pull request details are not loaded yet"))
  (let* ((pull-request bitbucket-devops-pull-requests-ui--details-pull-request)
         (state (upcase (or (alist-get 'state pull-request) "UNKNOWN")))
         (candidates
          (bitbucket-devops-pull-requests-ui--state-action-candidates
           pull-request)))
    (unless candidates
      (user-error "No state transitions are available for %s pull requests"
                  state))
    (let* ((selection
            (completing-read
             "Pull request state action: "
             (mapcar #'car candidates)
             nil
             t))
           (command (cdr (assoc selection candidates))))
      (unless command
        (user-error "Unknown pull request state action: %s" selection))
      (call-interactively command))))

(defun bitbucket-devops-pull-requests-ui--build-face (label)
  "Return the semantic face for build summary LABEL."
  (cond
   ((string-match-p "failed" label) 'bitbucket-devops-pull-requests-error-face)
   ((string-match-p "running" label) 'bitbucket-devops-pull-requests-warning-face)
   ((string-match-p "passed" label) 'bitbucket-devops-pull-requests-success-face)
   ((string-match-p "stopped" label) 'bitbucket-devops-pull-requests-secondary-face)
   (t 'bitbucket-devops-pull-requests-secondary-face)))

(defun bitbucket-devops-pull-requests-ui--file-status-face (status)
  "Return the semantic face for changed file STATUS."
  (pcase (downcase (or status "modified"))
    ("added" 'bitbucket-devops-pull-requests-added-face)
    ("removed" 'bitbucket-devops-pull-requests-removed-face)
    ("renamed" 'bitbucket-devops-pull-requests-renamed-face)
    (_ 'bitbucket-devops-pull-requests-modified-face)))

(defun bitbucket-devops-pull-requests-ui--branch-flow (source destination)
  "Return a styled SOURCE to DESTINATION branch flow."
  (concat
   (bitbucket-devops-pull-requests-ui--style
    source 'bitbucket-devops-pull-requests-source-branch-face)
   (bitbucket-devops-pull-requests-ui--style
    " -> " 'bitbucket-devops-pull-requests-secondary-face)
   (bitbucket-devops-pull-requests-ui--style
    destination 'bitbucket-devops-pull-requests-destination-branch-face)))

(defun bitbucket-devops-pull-requests-ui--header-separator ()
  "Return the standard pull request header separator."
  (bitbucket-devops-pull-requests-ui--style
   "  |  " 'bitbucket-devops-pull-requests-secondary-face))

(defun bitbucket-devops-pull-requests-ui--repository-label ()
  "Return the current pull request repository label."
  (format
   "%s/%s"
   (or (plist-get bitbucket-devops-pull-requests-ui--context :workspace) "")
   (or (plist-get bitbucket-devops-pull-requests-ui--context :repo-slug) "")))

(defun bitbucket-devops-pull-requests-ui--filter-badge (label value)
  "Return a styled active filter badge using LABEL and VALUE."
  (bitbucket-devops-pull-requests-ui--style
   (format " %s: %s " label value)
   'bitbucket-devops-pull-requests-filter-face))

(defun bitbucket-devops-pull-requests-ui--list-header-line ()
  "Return a dynamic header line for the current pull request list."
  (let* ((visible (length (bitbucket-devops-pull-requests-ui--filtered-pull-requests)))
         (loaded (length bitbucket-devops-pull-requests-ui--pull-requests))
         (filters
          (delq
           nil
           (list
            (when bitbucket-devops-pull-requests-ui--state-filter
              (bitbucket-devops-pull-requests-ui--filter-badge
               "State" bitbucket-devops-pull-requests-ui--state-filter))
            (when bitbucket-devops-pull-requests-ui--branch-filter
              (bitbucket-devops-pull-requests-ui--filter-badge
               "Branch" bitbucket-devops-pull-requests-ui--branch-filter))
            (when bitbucket-devops-pull-requests-ui--author-filter
              (bitbucket-devops-pull-requests-ui--filter-badge
               "Author" bitbucket-devops-pull-requests-ui--author-filter))))))
    (append
     (list
      " "
      (bitbucket-devops-pull-requests-ui--style
       (bitbucket-devops-pull-requests-ui--repository-label)
       'bitbucket-devops-pull-requests-header-face)
      (bitbucket-devops-pull-requests-ui--header-separator)
      (bitbucket-devops-pull-requests-ui--style
       (format "%s visible / %s loaded" visible loaded)
       'bitbucket-devops-pull-requests-count-face))
     (when bitbucket-devops-pull-requests-ui--loading
       (list
        (bitbucket-devops-pull-requests-ui--header-separator)
        (bitbucket-devops-pull-requests-ui--style
         "Refreshing..." 'bitbucket-devops-pull-requests-warning-face)))
     (when bitbucket-devops-pull-requests-ui--next-url
       (list
        (bitbucket-devops-pull-requests-ui--header-separator)
        (bitbucket-devops-pull-requests-ui--style
         "More available" 'bitbucket-devops-pull-requests-secondary-face)))
     (when filters
       (append
        (list (bitbucket-devops-pull-requests-ui--header-separator))
        (cl-loop for filter in filters
                 append (list filter " ")))))))

(defun bitbucket-devops-pull-requests-ui--detail-header-line ()
  "Return a dynamic header line for a pull request detail buffer."
  (let* ((pull-request bitbucket-devops-pull-requests-ui--details-pull-request)
         (summary (and pull-request
                       (bitbucket-devops-pull-requests-summary pull-request))))
    (append
     (list
      " "
      (bitbucket-devops-pull-requests-ui--style
       (bitbucket-devops-pull-requests-ui--repository-label)
       'bitbucket-devops-pull-requests-header-face))
     (when summary
       (list
        (bitbucket-devops-pull-requests-ui--header-separator)
        (bitbucket-devops-pull-requests-ui--style
         (format "PR #%s" (plist-get summary :id))
         'bitbucket-devops-pull-requests-id-face)
        (bitbucket-devops-pull-requests-ui--header-separator)
        (bitbucket-devops-pull-requests-ui--state-label-styled summary)
        (bitbucket-devops-pull-requests-ui--header-separator)
        (bitbucket-devops-pull-requests-ui--branch-flow
         (plist-get summary :source-branch)
         (plist-get summary :destination-branch)))))))

(defun bitbucket-devops-pull-requests-ui--subview-header-line (kind &optional count)
  "Return a header line for pull request subview KIND with optional COUNT."
  (append
   (list
    " "
    (bitbucket-devops-pull-requests-ui--style
     (bitbucket-devops-pull-requests-ui--repository-label)
     'bitbucket-devops-pull-requests-header-face)
    (bitbucket-devops-pull-requests-ui--header-separator)
    (bitbucket-devops-pull-requests-ui--style
     (format "PR #%s" bitbucket-devops-pull-requests-ui--details-pull-request-id)
     'bitbucket-devops-pull-requests-id-face)
    (bitbucket-devops-pull-requests-ui--header-separator)
    (bitbucket-devops-pull-requests-ui--style
     kind 'bitbucket-devops-pull-requests-title-face))
   (when count
     (list
      (bitbucket-devops-pull-requests-ui--header-separator)
      (bitbucket-devops-pull-requests-ui--style
       (format "%s %s" count (if (= count 1) "item" "items"))
       'bitbucket-devops-pull-requests-count-face)))))

(defun bitbucket-devops-pull-requests-ui--row (pull-request)
  "Return a `tabulated-list-mode' entry for PULL-REQUEST."
  (let* ((summary (bitbucket-devops-pull-requests-summary pull-request))
         (build-label (bitbucket-devops-pull-requests-ui--build-label pull-request)))
    (list
     (number-to-string (or (plist-get summary :id) 0))
     (vector
      (bitbucket-devops-pull-requests-ui--style
       (or (plist-get summary :id) 0)
       'bitbucket-devops-pull-requests-id-face)
      (bitbucket-devops-pull-requests-ui--state-label-styled summary)
      (bitbucket-devops-pull-requests-ui--style
       (plist-get summary :title)
       'bitbucket-devops-pull-requests-title-face)
      (bitbucket-devops-pull-requests-ui--style
       (plist-get summary :source-branch)
       'bitbucket-devops-pull-requests-source-branch-face)
      (bitbucket-devops-pull-requests-ui--style
       (plist-get summary :destination-branch)
       'bitbucket-devops-pull-requests-destination-branch-face)
      (bitbucket-devops-pull-requests-ui--style
       (plist-get summary :author)
       'bitbucket-devops-pull-requests-author-face)
      (bitbucket-devops-pull-requests-ui--style
       (or (plist-get summary :reviewer-count) 0)
       'bitbucket-devops-pull-requests-count-face)
      (bitbucket-devops-pull-requests-ui--style
       (or (plist-get summary :approval-count) 0)
       (if (> (or (plist-get summary :approval-count) 0) 0)
           'bitbucket-devops-pull-requests-success-face
         'bitbucket-devops-pull-requests-secondary-face))
      (bitbucket-devops-pull-requests-ui--style
       build-label
       (bitbucket-devops-pull-requests-ui--build-face build-label))
      (bitbucket-devops-pull-requests-ui--style
       (bitbucket-devops-pull-requests-ui--format-time
        (plist-get summary :created-on))
       'bitbucket-devops-pull-requests-secondary-face)
      (bitbucket-devops-pull-requests-ui--style
       (bitbucket-devops-pull-requests-ui--format-time
        (plist-get summary :updated-on))
       'bitbucket-devops-pull-requests-secondary-face)))))

(defun bitbucket-devops-pull-requests-ui--find-loaded (id)
  "Return the loaded pull request with numeric ID."
  (seq-find
   (lambda (pull-request)
     (= (or (alist-get 'id pull-request) -1) id))
   bitbucket-devops-pull-requests-ui--pull-requests))

(defun bitbucket-devops-pull-requests-ui--id-at-point-or-next ()
  "Return the pull request ID at point or on the next table row."
  (or (tabulated-list-get-id)
      (save-excursion
        (catch 'id
          (while (< (point) (point-max))
            (forward-line 1)
            (when-let ((id (tabulated-list-get-id)))
              (throw 'id id)))
          nil))))

(defun bitbucket-devops-pull-requests-ui--sync-count (value)
  "Return VALUE when it is a positive integer, otherwise zero."
  (if (and (integerp value) (> value 0)) value 0))

(defun bitbucket-devops-pull-requests-ui--active-p (pull-request)
  "Return non-nil when PULL-REQUEST can still change list metadata."
  (let ((state (upcase (or (alist-get 'state pull-request) ""))))
    (or (string-empty-p state)
        (equal state "OPEN"))))

(defun bitbucket-devops-pull-requests-ui--sync-candidates
    (pull-requests)
  "Return pull requests selected for detail revalidation.
PULL-REQUESTS is the list of pull requests to select from."
  (let* ((sorted
          (bitbucket-devops-pull-requests-ui--sort-pull-requests
           pull-requests))
         (always-count
          (bitbucket-devops-pull-requests-ui--sync-count
           bitbucket-devops-pull-requests-sync-always-count))
         (active-count
          (bitbucket-devops-pull-requests-ui--sync-count
           bitbucket-devops-pull-requests-sync-active-count))
         (seen (make-hash-table :test #'equal))
         candidates)
    (dolist (pull-request
             (append
              (seq-take sorted always-count)
              (seq-filter
               #'bitbucket-devops-pull-requests-ui--active-p
               (seq-take sorted active-count))))
      (when-let ((id (alist-get 'id pull-request)))
        (unless (gethash id seen)
          (puthash id t seen)
          (push pull-request candidates))))
    (nreverse candidates)))

(defun bitbucket-devops-pull-requests-ui--preserve-local-fields
    (fresh-pull-request cached-pull-request)
  "Return FRESH-PULL-REQUEST with local fields from CACHED-PULL-REQUEST.

Local fields are values derived from extra API calls or UI state rather than
the pull request object itself."
  (let ((updated (copy-tree fresh-pull-request)))
    (when-let ((build-label
                (and cached-pull-request
                     (alist-get
                      'bitbucket-devops-pull-requests-build-label
                      cached-pull-request))))
      (unless (alist-get 'bitbucket-devops-pull-requests-build-label updated)
        (push
         (cons 'bitbucket-devops-pull-requests-build-label build-label)
         updated)))
    updated))

(defun bitbucket-devops-pull-requests-ui--sort-pull-requests (pull-requests)
  "Return PULL-REQUESTS sorted by most recent update."
  (sort (copy-sequence pull-requests)
        #'bitbucket-devops-cache--pull-request-newer-p))

(defun bitbucket-devops-pull-requests-ui--replace-loaded-pull-request
    (pull-request)
  "Replace or add PULL-REQUEST in the current list buffer by numeric ID."
  (when-let ((id (alist-get 'id pull-request)))
    (let* ((existing (bitbucket-devops-pull-requests-ui--find-loaded id))
           (updated
            (bitbucket-devops-pull-requests-ui--preserve-local-fields
             pull-request existing))
           replaced)
      (setq bitbucket-devops-pull-requests-ui--pull-requests
            (mapcar
             (lambda (candidate)
               (if (= (or (alist-get 'id candidate) -1) id)
                   (progn
                     (setq replaced t)
                     updated)
                 candidate))
             bitbucket-devops-pull-requests-ui--pull-requests))
      (unless replaced
        (push updated bitbucket-devops-pull-requests-ui--pull-requests))
      (setq bitbucket-devops-pull-requests-ui--pull-requests
            (if (and bitbucket-devops-cache-enabled
                     bitbucket-devops-pull-requests-ui--context)
                (bitbucket-devops-cache-merge-pull-requests
                 bitbucket-devops-pull-requests-ui--context
                 (list updated))
              (bitbucket-devops-pull-requests-ui--sort-pull-requests
               bitbucket-devops-pull-requests-ui--pull-requests)))
      (bitbucket-devops-pull-requests-ui--render))))

(defun bitbucket-devops-pull-requests-ui--refresh-newest-loaded-details
    (context generation)
  "Refetch configured loaded pull request details for CONTEXT.

GENERATION is used to ignore callbacks from stale list refreshes."
  (let ((buffer (current-buffer)))
    (dolist (pull-request
             (bitbucket-devops-pull-requests-ui--sync-candidates
              bitbucket-devops-pull-requests-ui--pull-requests))
      (let ((pull-request-id (alist-get 'id pull-request)))
        (bitbucket-devops-pull-requests-rest-get
         context
         pull-request-id
         (lambda (pull-request error)
           (when (and (buffer-live-p buffer)
                      (= generation
                         (buffer-local-value
                          'bitbucket-devops-pull-requests-ui--request-generation
                          buffer)))
             (with-current-buffer buffer
               (if error
                   (message
                    "Unable to refresh Bitbucket pull request #%s: %s"
                    pull-request-id
                    (or (plist-get error :message) error))
                 (bitbucket-devops-pull-requests-ui--replace-loaded-pull-request
                  pull-request))))))))))

(defun bitbucket-devops-pull-requests-ui--rule-width ()
  "Return the display width used for pull request detail rules."
  (max 72
       (or
        (when-let ((window (get-buffer-window (current-buffer) t)))
          (max 1 (1- (window-body-width window))))
        88)))

(defun bitbucket-devops-pull-requests-ui--rule (&optional indent)
  "Return a pull request detail divider rule with optional INDENT."
  (let* ((indent (or indent ""))
         (width
          (max 8
               (- (bitbucket-devops-pull-requests-ui--rule-width)
                  (string-width indent)))))
    (concat indent (make-string width ?-))))

(defun bitbucket-devops-pull-requests-ui--insert-section
    (title &optional action help)
  "Insert a detail section TITLE.

When ACTION is non-nil, make the section heading invoke ACTION.  HELP is used
as hover text."
  (let (start)
    (insert "\n")
    (setq start (point))
    (let ((rule (bitbucket-devops-pull-requests-ui--rule)))
      (insert
       (bitbucket-devops-pull-requests-ui--style
        rule 'bitbucket-devops-pull-requests-secondary-face)
       "\n"
       (bitbucket-devops-pull-requests-ui--style
        title 'bitbucket-devops-pull-requests-section-face)
       "\n"
       (bitbucket-devops-pull-requests-ui--style
        rule 'bitbucket-devops-pull-requests-secondary-face)))
    (when action
      (bitbucket-devops-pull-requests-ui--add-action
       start
       (point)
       action
       (or help "Open section")))
    (insert "\n")))

(defun bitbucket-devops-pull-requests-ui--insert-comment-divider
    (&optional reply)
  "Insert a divider before a pull request comment.

When REPLY is non-nil, indent the divider to match the reply text."
  (insert
   "\n"
   (bitbucket-devops-pull-requests-ui--style
    (bitbucket-devops-pull-requests-ui--rule (when reply "    "))
    'bitbucket-devops-pull-requests-secondary-face)
   "\n"))

(defun bitbucket-devops-pull-requests-ui--insert-field
    (label value &optional face action help)
  "Insert a detail field LABEL and VALUE, optionally styled with FACE.

When ACTION is non-nil, make the complete field line invoke ACTION.  HELP is
used as hover text."
  (let ((start (point)))
    (insert
     (bitbucket-devops-pull-requests-ui--style
      (format "%-14s" (concat label ":"))
      'bitbucket-devops-pull-requests-field-label-face)
     " "
     (if face
         (bitbucket-devops-pull-requests-ui--style value face)
       (format "%s" (or value ""))))
    (when action
      (bitbucket-devops-pull-requests-ui--add-action
       start
       (point)
       action
       (or help (format "Run action for %s" label))))
    (insert "\n")))

(defun bitbucket-devops-pull-requests-ui--join-or-none (values &optional face)
  "Return VALUES joined by comma, or a styled none label.

When FACE is non-nil, apply it to every value."
  (if values
      (string-join
       (if face
           (mapcar
            (lambda (value)
              (bitbucket-devops-pull-requests-ui--style value face))
            values)
         values)
       (bitbucket-devops-pull-requests-ui--style
        ", " 'bitbucket-devops-pull-requests-secondary-face))
    (bitbucket-devops-pull-requests-ui--style
     "None" 'bitbucket-devops-pull-requests-empty-face)))

(defun bitbucket-devops-pull-requests-ui--insert-empty (text)
  "Insert empty-state TEXT followed by a newline."
  (insert
   (bitbucket-devops-pull-requests-ui--style
    text 'bitbucket-devops-pull-requests-empty-face)
   "\n"))

(defun bitbucket-devops-pull-requests-ui--fontify-markdown (markdown)
  "Return MARKDOWN with display faces applied when `markdown-mode' is available."
  (let ((rendered
         (if (not (require 'markdown-mode nil t))
             markdown
           (with-temp-buffer
             (insert markdown)
             (markdown-mode)
             (font-lock-ensure)
             (buffer-string)))))
    (add-face-text-property
     0
     (length rendered)
     'bitbucket-devops-pull-requests-description-face
     t
     rendered)
    rendered))

(defun bitbucket-devops-pull-requests-ui--status-summary-label (statuses)
  "Return a concise build status label for STATUSES."
  (let ((summary (bitbucket-devops-pull-requests-status-summary statuses)))
    (concat
     (bitbucket-devops-pull-requests-ui--style
      (format "%s total" (plist-get summary :total))
      'bitbucket-devops-pull-requests-count-face)
     ", "
     (bitbucket-devops-pull-requests-ui--style
      (format "%s passed" (plist-get summary :passed))
      'bitbucket-devops-pull-requests-success-face)
     ", "
     (bitbucket-devops-pull-requests-ui--style
      (format "%s failed" (plist-get summary :failed))
      (if (> (plist-get summary :failed) 0)
          'bitbucket-devops-pull-requests-error-face
        'bitbucket-devops-pull-requests-secondary-face))
     ", "
     (bitbucket-devops-pull-requests-ui--style
      (format "%s in progress" (plist-get summary :in-progress))
      (if (> (plist-get summary :in-progress) 0)
          'bitbucket-devops-pull-requests-warning-face
          'bitbucket-devops-pull-requests-secondary-face)))))

(defun bitbucket-devops-pull-requests-ui--status-face (status)
  "Return the semantic face for build STATUS."
  (pcase (bitbucket-devops-pull-requests--status-state status)
    ((or "SUCCESSFUL" "SUCCESS") 'bitbucket-devops-pull-requests-success-face)
    ((or "FAILED" "FAILURE" "ERROR") 'bitbucket-devops-pull-requests-error-face)
    ((or "INPROGRESS" "IN_PROGRESS" "PENDING")
     'bitbucket-devops-pull-requests-warning-face)
    (_ 'bitbucket-devops-pull-requests-secondary-face)))

(defun bitbucket-devops-pull-requests-ui--status-url (status)
  "Return STATUS's safe browser URL, or nil when it has none."
  (when-let ((url (alist-get 'url status)))
    (when (and (stringp url)
               (string-match-p "\\`https?://" url))
      url)))

(defun bitbucket-devops-pull-requests-ui--bitbucket-url-p (url)
  "Return non-nil when URL points to Bitbucket Cloud."
  (when-let ((host
              (ignore-errors
                (url-host (url-generic-parse-url url)))))
    (member (downcase host)
            '("bitbucket.org" "www.bitbucket.org" "api.bitbucket.org"))))

(defun bitbucket-devops-pull-requests-ui--bitbucket-pipeline-url-p (url)
  "Return non-nil when URL points to a Bitbucket Pipelines result."
  (when (and (stringp url)
             (bitbucket-devops-pull-requests-ui--bitbucket-url-p url))
    (let ((decoded (url-unhex-string url)))
      (or
       (string-match-p
        (rx "/pipelines/results/" (+ digit))
        decoded)
       (string-match-p
        (rx "/addon/pipelines/home" (* anything) "/results/" (+ digit))
        decoded)
       (string-match-p
        (rx "/pipelines/" "{" (+ (not (any "/?"))) "}")
        decoded)))))

(defun bitbucket-devops-pull-requests-ui--status-explicit-pipeline-uuid
    (status)
  "Return a pipeline UUID explicitly advertised by STATUS, or nil."
  (or (bitbucket-devops-pull-requests--nested-get status 'pipeline 'uuid)
      (alist-get 'pipeline_uuid status)))

(defun bitbucket-devops-pull-requests-ui--status-local-pipeline-p (status)
  "Return non-nil when STATUS can be opened as a local Bitbucket pipeline."
  (or
   (bitbucket-devops-pull-requests-ui--status-explicit-pipeline-uuid status)
   (when-let ((url (bitbucket-devops-pull-requests-ui--status-url status)))
     (bitbucket-devops-pull-requests-ui--bitbucket-pipeline-url-p url))))

(defun bitbucket-devops-pull-requests-ui--insert-statuses (statuses)
  "Insert individual build STATUSES with provider links."
  (dolist (status statuses)
    (let* ((start (point))
           (state (bitbucket-devops-pull-requests--status-state status))
           (name (or (alist-get 'name status)
                     (alist-get 'key status)
                     "Unknown build"))
           (description (string-trim (or (alist-get 'description status) "")))
           (url (bitbucket-devops-pull-requests-ui--status-url status)))
      (insert
       "  "
       (bitbucket-devops-pull-requests-ui--style
        (format "[%s]" state)
        (bitbucket-devops-pull-requests-ui--status-face status))
       " "
       (bitbucket-devops-pull-requests-ui--style
        name
        (if url 'link 'bitbucket-devops-pull-requests-description-face)))
      (unless (string-empty-p description)
        (insert
         (bitbucket-devops-pull-requests-ui--style
          (concat " - " description)
          'bitbucket-devops-pull-requests-secondary-face)))
      (when url
        (add-text-properties
         start
         (point)
         (list 'bitbucket-devops-pull-requests-status-url url
               'bitbucket-devops-pull-requests-status status))
        (bitbucket-devops-pull-requests-ui--add-action
         start
         (point)
         #'bitbucket-devops-pull-requests-ui-open-status
         (format "Open %s build results" name)))
      (insert "\n"))))

(defun bitbucket-devops-pull-requests-ui--task-summary-label (tasks)
  "Return a concise task label for TASKS."
  (let ((summary (bitbucket-devops-pull-requests-task-summary tasks)))
    (concat
     (bitbucket-devops-pull-requests-ui--style
      (format "%s total" (plist-get summary :total))
      'bitbucket-devops-pull-requests-count-face)
     ", "
     (bitbucket-devops-pull-requests-ui--style
      (format "%s resolved" (plist-get summary :resolved))
      'bitbucket-devops-pull-requests-success-face)
     ", "
     (bitbucket-devops-pull-requests-ui--style
      (format "%s unresolved" (plist-get summary :unresolved))
      (if (> (plist-get summary :unresolved) 0)
          'bitbucket-devops-pull-requests-warning-face
        'bitbucket-devops-pull-requests-secondary-face)))))

(defun bitbucket-devops-pull-requests-ui--comment-summary-label (comments)
  "Return a concise comment label for COMMENTS."
  (let ((summary (bitbucket-devops-pull-requests-comment-summary comments)))
    (concat
     (bitbucket-devops-pull-requests-ui--style
      (format "%s comments" (plist-get summary :comments))
      'bitbucket-devops-pull-requests-count-face)
     ", "
     (bitbucket-devops-pull-requests-ui--style
      (format "%s replies" (plist-get summary :replies))
      'bitbucket-devops-pull-requests-author-face)
     ", "
     (bitbucket-devops-pull-requests-ui--style
      (format "%s deleted" (plist-get summary :deleted))
      'bitbucket-devops-pull-requests-secondary-face))))

(defun bitbucket-devops-pull-requests-ui--emoji-shortcode-key (name)
  "Return a normalized emoji shortcode key for NAME."
  (replace-regexp-in-string
   "\\`_+\\|_+\\'" ""
   (replace-regexp-in-string
    "[^[:alnum:]+-]+" "_" (downcase name))))

(defun bitbucket-devops-pull-requests-ui--emoji-shortcodes ()
  "Return the cached mapping of Markdown emoji shortcodes to glyphs."
  (or bitbucket-devops-pull-requests-ui--emoji-shortcodes
      (setq
       bitbucket-devops-pull-requests-ui--emoji-shortcodes
       (let ((shortcodes (make-hash-table :test #'equal)))
         (when (require 'emoji nil t)
           (emoji--init)
           (maphash
            (lambda (name glyph)
              (puthash
               (bitbucket-devops-pull-requests-ui--emoji-shortcode-key name)
               glyph
               shortcodes))
            emoji--all-bases)
           (dolist
               (alias
                '(("white_check_mark" . "check_mark_button")
                  ("computer" . "laptop")
                  ("heavy_check_mark" . "check_mark")
                  ("x" . "cross_mark")
                  ("lock" . "locked")
                  ("unlock" . "unlocked")
                  ("+1" . "thumbs_up")
                  ("-1" . "thumbs_down")
                  ("tada" . "party_popper")
                  ("boom" . "collision")))
             (when-let ((glyph (gethash (cdr alias) shortcodes)))
               (puthash (car alias) glyph shortcodes))))
         shortcodes))))

(defun bitbucket-devops-pull-requests-ui--display-comment-text (text)
  "Return TEXT with recognized Markdown emoji shortcodes displayed as glyphs."
  (if (not bitbucket-devops-pull-requests-display-emoji-shortcodes)
      text
    (let ((shortcodes
           (bitbucket-devops-pull-requests-ui--emoji-shortcodes)))
      (replace-regexp-in-string
       ":[[:alnum:]_+-]+:"
       (lambda (shortcode)
         (or
          (gethash
           (bitbucket-devops-pull-requests-ui--emoji-shortcode-key
            (substring shortcode 1 -1))
           shortcodes)
          shortcode))
       text t t))))

(defun bitbucket-devops-pull-requests-ui--comment-location (comment)
  "Return a concise inline location for COMMENT, or nil."
  (when-let* ((inline (alist-get 'inline comment))
              (path (alist-get 'path inline)))
    (let ((line (or (alist-get 'to inline) (alist-get 'from inline))))
      (if line
          (format "%s:%s" path line)
        path))))

(defun bitbucket-devops-pull-requests-ui--comment-time (comment)
  "Return COMMENT's creation time, or nil when unavailable."
  (when-let ((created (alist-get 'created_on comment)))
    (ignore-errors (date-to-time created))))

(defun bitbucket-devops-pull-requests-ui--comment-newer-p (left right)
  "Return non-nil when LEFT should be displayed before RIGHT."
  (let ((left-time (bitbucket-devops-pull-requests-ui--comment-time left))
        (right-time (bitbucket-devops-pull-requests-ui--comment-time right)))
    (cond
     ((and left-time right-time) (time-less-p right-time left-time))
     (left-time t)
     (right-time nil)
     (t nil))))

(defun bitbucket-devops-pull-requests-ui--comments-newest-first (comments)
  "Return a copy of COMMENTS ordered newest first."
  (sort (copy-sequence comments)
        #'bitbucket-devops-pull-requests-ui--comment-newer-p))

(defun bitbucket-devops-pull-requests-ui--diffstat-path (entry)
  "Return the best path label for diffstat ENTRY."
  (or (bitbucket-devops-pull-requests--nested-get entry 'new 'path)
      (bitbucket-devops-pull-requests--nested-get entry 'old 'path)
      "unknown"))

(defun bitbucket-devops-pull-requests-ui--diffstat-summary-label (diffstat)
  "Return a concise diffstat label for DIFFSTAT."
  (let ((summary (bitbucket-devops-pull-requests-diffstat-summary diffstat)))
    (format
     "%s files, +%s -%s"
     (plist-get summary :files)
     (plist-get summary :lines-added)
     (plist-get summary :lines-removed))))

(defun bitbucket-devops-pull-requests-ui--activity-line (activity)
  "Return a display line for ACTIVITY."
  (cond
   ((alist-get 'update activity)
    (let ((update (alist-get 'update activity)))
      (concat
       (bitbucket-devops-pull-requests-ui--style
        (bitbucket-devops-pull-requests--user-display-name
         (alist-get 'author update))
        'bitbucket-devops-pull-requests-author-face)
       (bitbucket-devops-pull-requests-ui--style
        " changed state to " 'bitbucket-devops-pull-requests-secondary-face)
       (bitbucket-devops-pull-requests-ui--style
        (or (alist-get 'state update) "UNKNOWN")
        (bitbucket-devops-pull-requests-ui--state-face
         (alist-get 'state update)))
       (if-let ((date (alist-get 'date update)))
           (concat
            (bitbucket-devops-pull-requests-ui--style
             " at " 'bitbucket-devops-pull-requests-secondary-face)
            (bitbucket-devops-pull-requests-ui--style
             (bitbucket-devops-pull-requests-ui--format-time date)
             'bitbucket-devops-pull-requests-secondary-face))
         ""))))
   ((alist-get 'comment activity)
    (let ((comment (alist-get 'comment activity)))
      (concat
       (bitbucket-devops-pull-requests-ui--style
        (bitbucket-devops-pull-requests-comment-author-name comment)
        'bitbucket-devops-pull-requests-author-face)
       (bitbucket-devops-pull-requests-ui--style
        " commented: " 'bitbucket-devops-pull-requests-secondary-face)
       (bitbucket-devops-pull-requests-ui--style
        (bitbucket-devops-pull-requests-ui--display-comment-text
         (bitbucket-devops-pull-requests-comment-text comment))
        'bitbucket-devops-pull-requests-description-face))))
   (t
    (bitbucket-devops-pull-requests-ui--style
     "Unknown activity" 'bitbucket-devops-pull-requests-empty-face))))

(defun bitbucket-devops-pull-requests-ui--render-details ()
  "Render the current pull request detail buffer."
  (let ((inhibit-read-only t)
        (original-point (point))
        (original-column (current-column))
        (task-id
         (bitbucket-devops-pull-requests-ui--property-at-point-or-line
          'bitbucket-devops-pull-requests-task-id))
        (comment-id
         (bitbucket-devops-pull-requests-ui--property-at-point-or-line
          'bitbucket-devops-pull-requests-comment-id))
        (task-column (current-column)))
    (erase-buffer)
    (if (not bitbucket-devops-pull-requests-ui--details-pull-request)
        (bitbucket-devops-pull-requests-ui--insert-empty
         "Loading Bitbucket pull request...")
      (let* ((pull-request bitbucket-devops-pull-requests-ui--details-pull-request)
             (summary (bitbucket-devops-pull-requests-summary pull-request))
             (description
              (or (bitbucket-devops-pull-requests--nested-get pull-request 'description 'raw)
                  (alist-get 'description pull-request)
                  "")))
        (let ((heading-start (point)))
          (insert
           (bitbucket-devops-pull-requests-ui--style
            (format "#%s" (plist-get summary :id))
            'bitbucket-devops-pull-requests-id-face))
          (bitbucket-devops-pull-requests-ui--add-action
           heading-start
           (point)
           #'bitbucket-devops-pull-requests-ui-browse
           "Open this pull request in Bitbucket")
          (insert " ")
          (setq heading-start (point))
          (insert
           (bitbucket-devops-pull-requests-ui--style
            (plist-get summary :title)
            'bitbucket-devops-pull-requests-heading-face))
          (bitbucket-devops-pull-requests-ui--add-action
           heading-start
           (point)
           #'bitbucket-devops-pull-requests-ui-edit-title
           "Edit pull request title")
          (insert "\n"))
        (let ((state-start (point)))
          (insert
           (bitbucket-devops-pull-requests-ui--state-label-styled summary))
          (bitbucket-devops-pull-requests-ui--add-action
           state-start
           (point)
           #'bitbucket-devops-pull-requests-ui-change-state
           "Change pull request state")
          (insert
           (bitbucket-devops-pull-requests-ui--style
            "  |  " 'bitbucket-devops-pull-requests-secondary-face)
           (bitbucket-devops-pull-requests-ui--branch-flow
            (plist-get summary :source-branch)
            (plist-get summary :destination-branch))
           "\n\n"))
        (bitbucket-devops-pull-requests-ui--insert-field
         "State"
         (bitbucket-devops-pull-requests-ui--state-label-styled summary)
         nil
         #'bitbucket-devops-pull-requests-ui-change-state
         "Change pull request state")
        (bitbucket-devops-pull-requests-ui--insert-field
         "Readiness"
         (if (plist-get summary :draft) "Draft" "Ready for review")
         (if (plist-get summary :draft)
             'bitbucket-devops-pull-requests-draft-face
           'bitbucket-devops-pull-requests-success-face)
         #'bitbucket-devops-pull-requests-ui-toggle-draft
         "Toggle draft readiness")
        (bitbucket-devops-pull-requests-ui--insert-field
         "Author"
         (plist-get summary :author)
         'bitbucket-devops-pull-requests-author-face)
        (bitbucket-devops-pull-requests-ui--insert-field
         "Branches"
         (bitbucket-devops-pull-requests-ui--branch-flow
          (plist-get summary :source-branch)
          (plist-get summary :destination-branch))
         nil
         #'bitbucket-devops-pull-requests-ui-checkout-source-branch
         "Check out the source branch")
        (bitbucket-devops-pull-requests-ui--insert-field
         "Created"
         (bitbucket-devops-pull-requests-ui--format-time
          (plist-get summary :created-on))
         'bitbucket-devops-pull-requests-secondary-face)
        (bitbucket-devops-pull-requests-ui--insert-field
         "Updated"
         (bitbucket-devops-pull-requests-ui--format-time
          (plist-get summary :updated-on))
         'bitbucket-devops-pull-requests-secondary-face)

        (bitbucket-devops-pull-requests-ui--insert-section
         "Description"
         #'bitbucket-devops-pull-requests-ui-edit-description
         "Edit pull request description as Markdown")
        (let ((description-start (point)))
          (if (string-empty-p description)
              (insert
               (bitbucket-devops-pull-requests-ui--style
                "No description." 'bitbucket-devops-pull-requests-empty-face))
            (insert
             (bitbucket-devops-pull-requests-ui--fontify-markdown
              description)))
          (bitbucket-devops-pull-requests-ui--add-action
           description-start
           (point)
           #'bitbucket-devops-pull-requests-ui-edit-description
           "Edit pull request description as Markdown")
          (insert "\n"))

        (bitbucket-devops-pull-requests-ui--insert-section
         "Reviewers"
         #'bitbucket-devops-pull-requests-ui-add-reviewer
         "Add a reviewer")
        (bitbucket-devops-pull-requests-ui--insert-field
         "Approvals"
         (concat
          (bitbucket-devops-pull-requests-ui--style
           (or (plist-get summary :approval-count) 0)
           (if (> (or (plist-get summary :approval-count) 0) 0)
               'bitbucket-devops-pull-requests-success-face
             'bitbucket-devops-pull-requests-secondary-face))
          (bitbucket-devops-pull-requests-ui--style
           " / " 'bitbucket-devops-pull-requests-secondary-face)
          (bitbucket-devops-pull-requests-ui--style
           (or (plist-get summary :reviewer-count) 0)
           'bitbucket-devops-pull-requests-count-face)))
        (bitbucket-devops-pull-requests-ui--insert-field
         "Reviewers"
         (bitbucket-devops-pull-requests-ui--join-or-none
          (plist-get summary :reviewers)
          'bitbucket-devops-pull-requests-author-face)
         nil
         #'bitbucket-devops-pull-requests-ui-add-reviewer
         "Add a reviewer")
        (bitbucket-devops-pull-requests-ui--insert-field
         "Approved by"
         (bitbucket-devops-pull-requests-ui--join-or-none
          (plist-get summary :approved-by)
          'bitbucket-devops-pull-requests-success-face))

        (bitbucket-devops-pull-requests-ui--insert-section "Checks")
        (bitbucket-devops-pull-requests-ui--insert-field
         "Builds"
         (bitbucket-devops-pull-requests-ui--status-summary-label
          bitbucket-devops-pull-requests-ui--details-statuses))
        (bitbucket-devops-pull-requests-ui--insert-statuses
         bitbucket-devops-pull-requests-ui--details-statuses)
        (bitbucket-devops-pull-requests-ui--insert-field
         "Tasks"
         (bitbucket-devops-pull-requests-ui--task-summary-label
          bitbucket-devops-pull-requests-ui--details-tasks))

        (bitbucket-devops-pull-requests-ui--insert-section "Tasks")
        (if bitbucket-devops-pull-requests-ui--details-tasks
            (dolist (task bitbucket-devops-pull-requests-ui--details-tasks)
              (let ((line-start (point))
                    (resolved
                     (bitbucket-devops-pull-requests--task-resolved-p task)))
                (insert
                 (bitbucket-devops-pull-requests-ui--style
                  "- " 'bitbucket-devops-pull-requests-secondary-face)
                 (bitbucket-devops-pull-requests-ui--style
                  (if resolved "[resolved]" "[open]")
                  (if resolved
                      'bitbucket-devops-pull-requests-success-face
                    'bitbucket-devops-pull-requests-warning-face))
                 " "
                 (bitbucket-devops-pull-requests-ui--style
                  (bitbucket-devops-pull-requests-task-text task)
                  (if resolved
                      'bitbucket-devops-pull-requests-resolved-text-face
                    'bitbucket-devops-pull-requests-description-face))
                 (bitbucket-devops-pull-requests-ui--style
                  (format "  [task #%s]" (or (alist-get 'id task) "?"))
                  'bitbucket-devops-pull-requests-comment-id-face))
                (add-text-properties
                 line-start
                 (point)
                 (list 'bitbucket-devops-pull-requests-task-id
                       (alist-get 'id task)))
                (bitbucket-devops-pull-requests-ui--add-action
                 line-start
                 (point)
                 #'bitbucket-devops-pull-requests-ui-toggle-task-at-point
                 (if resolved "Reopen this task" "Resolve this task"))
                (insert "\n")))
          (bitbucket-devops-pull-requests-ui--insert-empty "No tasks."))

        (bitbucket-devops-pull-requests-ui--insert-section "Comments")
        (insert
         (bitbucket-devops-pull-requests-ui--comment-summary-label
          bitbucket-devops-pull-requests-ui--details-comments)
         "\n")
        (if bitbucket-devops-pull-requests-ui--details-comments
            (dolist
                (comment
                 (bitbucket-devops-pull-requests-ui--comments-newest-first
                  bitbucket-devops-pull-requests-ui--details-comments))
              (unless (alist-get 'deleted comment)
                (let ((reply (bitbucket-devops-pull-requests-comment-reply-p comment))
                      (created
                       (bitbucket-devops-pull-requests-ui--format-time
                        (alist-get 'created_on comment)))
                      (location
                       (bitbucket-devops-pull-requests-ui--comment-location comment)))
                  (bitbucket-devops-pull-requests-ui--insert-comment-divider
                   reply)
                  (let ((line-start (point)))
                    (insert
                     (bitbucket-devops-pull-requests-ui--style
                      (if reply "    |-- " "o ")
                      'bitbucket-devops-pull-requests-timeline-face)
                     (bitbucket-devops-pull-requests-ui--style
                      (format "#%s" (or (alist-get 'id comment) "?"))
                      'bitbucket-devops-pull-requests-comment-id-face)
                     " "
                     (bitbucket-devops-pull-requests-ui--style
                      (bitbucket-devops-pull-requests-comment-author-name comment)
                      'bitbucket-devops-pull-requests-author-face)
                     (if (string-empty-p created)
                         ""
                       (concat
                        " "
                        (bitbucket-devops-pull-requests-ui--style
                         (format "[%s]" created)
                         'bitbucket-devops-pull-requests-secondary-face)))
                     (if (bitbucket-devops-pull-requests-comment-resolved-p
                          comment)
                         (concat
                          " "
                          (bitbucket-devops-pull-requests-ui--style
                           "[resolved]"
                           'bitbucket-devops-pull-requests-success-face))
                       "")
                     (or
                      (when location
                        (concat
                         " "
                         (bitbucket-devops-pull-requests-ui--style
                          (format "[%s]" location)
                          'bitbucket-devops-pull-requests-file-face)))
                      "")
                     (bitbucket-devops-pull-requests-ui--style
                      ": " 'bitbucket-devops-pull-requests-secondary-face)
                     (bitbucket-devops-pull-requests-ui--style
                      (bitbucket-devops-pull-requests-ui--display-comment-text
                       (bitbucket-devops-pull-requests-comment-text comment))
                      'bitbucket-devops-pull-requests-description-face))
                    (add-text-properties
                     line-start
                     (point)
                     (list 'bitbucket-devops-pull-requests-comment-id
                           (alist-get 'id comment)))
                    (bitbucket-devops-pull-requests-ui--add-action
                     line-start
                     (point)
                     #'bitbucket-devops-pull-requests-ui-edit-comment-at-point
                     "Edit this comment")
                    (insert "\n")))))
          (bitbucket-devops-pull-requests-ui--insert-empty "No comments."))

        (let ((section-start (point)))
          (bitbucket-devops-pull-requests-ui--insert-section "Activity")
          (if bitbucket-devops-pull-requests-ui--details-activity
              (dolist (activity bitbucket-devops-pull-requests-ui--details-activity)
                (insert
                 (bitbucket-devops-pull-requests-ui--style
                  "o " 'bitbucket-devops-pull-requests-timeline-face)
                 (bitbucket-devops-pull-requests-ui--activity-line activity)
                 "\n"))
            (bitbucket-devops-pull-requests-ui--insert-empty "No activity loaded."))
          (bitbucket-devops-pull-requests-ui--add-action
           section-start
           (point)
           #'bitbucket-devops-pull-requests-ui-open-activity
           "Open activity buffer"))

        (let ((section-start (point)))
          (bitbucket-devops-pull-requests-ui--insert-section "Commits")
          (if bitbucket-devops-pull-requests-ui--details-commits
              (dolist (commit bitbucket-devops-pull-requests-ui--details-commits)
                (insert
                 (bitbucket-devops-pull-requests-ui--style
                  "- " 'bitbucket-devops-pull-requests-secondary-face)
                 (bitbucket-devops-pull-requests-ui--style
                  (substring (or (alist-get 'hash commit) "")
                             0
                             (min 12 (length (or (alist-get 'hash commit) ""))))
                  'bitbucket-devops-pull-requests-commit-face)
                 " "
                 (bitbucket-devops-pull-requests-ui--style
                  (string-trim
                   (car
                    (split-string
                     (or (alist-get 'message commit) "") "\n")))
                  'bitbucket-devops-pull-requests-message-face)
                 "\n"))
            (bitbucket-devops-pull-requests-ui--insert-empty "No commits loaded."))
          (bitbucket-devops-pull-requests-ui--add-action
           section-start
           (point)
           #'bitbucket-devops-pull-requests-ui-open-commits
           "Open commits buffer"))

        (let ((section-start (point)))
          (bitbucket-devops-pull-requests-ui--insert-section "Changed Files")
          (insert
           (bitbucket-devops-pull-requests-ui--style
            (bitbucket-devops-pull-requests-ui--diffstat-summary-label
             bitbucket-devops-pull-requests-ui--details-diffstat)
            (if bitbucket-devops-pull-requests-ui--details-diffstat
                'bitbucket-devops-pull-requests-count-face
              'bitbucket-devops-pull-requests-secondary-face))
           "\n")
          (if bitbucket-devops-pull-requests-ui--details-diffstat
              (dolist (entry bitbucket-devops-pull-requests-ui--details-diffstat)
                (let ((status (or (alist-get 'status entry) "modified")))
                  (insert
                   (bitbucket-devops-pull-requests-ui--style
                    "- " 'bitbucket-devops-pull-requests-secondary-face)
                   (bitbucket-devops-pull-requests-ui--style
                    (bitbucket-devops-pull-requests-ui--diffstat-path entry)
                    'bitbucket-devops-pull-requests-file-face)
                   " "
                   (bitbucket-devops-pull-requests-ui--style
                    status
                    (bitbucket-devops-pull-requests-ui--file-status-face status))
                   " "
                   (bitbucket-devops-pull-requests-ui--style
                    (format "+%s" (or (alist-get 'lines_added entry) 0))
                    'bitbucket-devops-pull-requests-added-face)
                   " "
                   (bitbucket-devops-pull-requests-ui--style
                    (format "-%s" (or (alist-get 'lines_removed entry) 0))
                    'bitbucket-devops-pull-requests-removed-face)
                   "\n")))
            (bitbucket-devops-pull-requests-ui--insert-empty "No changed files."))
          (bitbucket-devops-pull-requests-ui--add-action
           section-start
           (point)
           #'bitbucket-devops-pull-requests-ui-open-diff
           "Open diff buffer"))))
    (let (restored)
      (cond
       (task-id
        (when-let ((position
                    (text-property-any
                     (point-min)
                     (point-max)
                     'bitbucket-devops-pull-requests-task-id
                     task-id)))
          (goto-char position)
          (move-to-column task-column)
          (setq restored t)))
       (comment-id
        (when-let ((position
                    (text-property-any
                     (point-min)
                     (point-max)
                     'bitbucket-devops-pull-requests-comment-id
                     comment-id)))
          (goto-char position)
          (move-to-column original-column)
          (setq restored t))))
      (unless restored
        (goto-char (min (point-max) original-point))
        (move-to-column original-column)))))

(defun bitbucket-devops-pull-requests-ui--render ()
  "Render loaded pull requests in the current list buffer."
  (bitbucket-devops-ui--preserve-visible-window-positions
   (lambda ()
     (setq tabulated-list-entries
           (mapcar #'bitbucket-devops-pull-requests-ui--row
                   (bitbucket-devops-pull-requests-ui--filtered-pull-requests)))
     (tabulated-list-print t)
     (save-excursion
       (let ((inhibit-read-only t))
         (goto-char (point-min))
         (insert
          (apply #'concat (bitbucket-devops-pull-requests-ui--list-header-line))
          "\n")))
     (bitbucket-devops-pull-requests-ui--apply-list-line-wrapping)
     (force-mode-line-update))))

(defun bitbucket-devops-pull-requests-ui--filtered-pull-requests ()
  "Return loaded pull requests matching active list filters."
  (seq-filter
   (lambda (pull-request)
     (and
      (or
       (null bitbucket-devops-pull-requests-ui--state-filter)
       (equal
        (upcase (or (alist-get 'state pull-request) ""))
        bitbucket-devops-pull-requests-ui--state-filter))
      (or
       (null bitbucket-devops-pull-requests-ui--branch-filter)
       (equal
        bitbucket-devops-pull-requests-ui--branch-filter
        (bitbucket-devops-pull-requests-source-branch pull-request))
       (equal
        bitbucket-devops-pull-requests-ui--branch-filter
        (bitbucket-devops-pull-requests-destination-branch pull-request)))
      (or
       (null bitbucket-devops-pull-requests-ui--author-filter)
       (string-equal-ignore-case
        bitbucket-devops-pull-requests-ui--author-filter
        (bitbucket-devops-pull-requests-author-name pull-request)))))
   bitbucket-devops-pull-requests-ui--pull-requests))

(defun bitbucket-devops-pull-requests-ui--receive-page (page error replace)
  "Handle pull request PAGE or ERROR.

When REPLACE is non-nil, replace the loaded rows.  Otherwise append them."
  (setq bitbucket-devops-pull-requests-ui--loading nil)
  (force-mode-line-update)
  (if error
      (message "Unable to load Bitbucket pull requests: %s"
               (or (plist-get error :message) error))
    (let ((values (or (bitbucket-devops-rest-page-values page) nil)))
      (setq bitbucket-devops-pull-requests-ui--pull-requests
            (if (and bitbucket-devops-pull-requests-ui--context
                     bitbucket-devops-cache-enabled)
                (bitbucket-devops-cache-merge-pull-requests
                 bitbucket-devops-pull-requests-ui--context
                 values)
              (if replace
                  values
                (append bitbucket-devops-pull-requests-ui--pull-requests values))))
      (setq bitbucket-devops-pull-requests-ui--next-url
            (bitbucket-devops-rest-page-next page))
      (bitbucket-devops-pull-requests-ui--render))))

(defun bitbucket-devops-pull-requests-ui--collect-pages
    (rest-function context pull-request-id callback
                   &optional next-url collected-values)
  "Collect all REST-FUNCTION pages for PULL-REQUEST-ID, then invoke CALLBACK.

CALLBACK receives the complete value list and an error value.
CONTEXT identifies the Bitbucket repository."
  (funcall
   rest-function
   context
   pull-request-id
   (lambda (page error)
     (if error
         (funcall callback nil error)
       (let ((collected
              (append collected-values
                      (bitbucket-devops-rest-page-values page)))
             (next (bitbucket-devops-rest-page-next page)))
         (if next
             (bitbucket-devops-pull-requests-ui--collect-pages
              rest-function context pull-request-id callback next collected)
           (funcall callback collected nil)))))
   next-url))

(defun bitbucket-devops-pull-requests-ui--collect-statuses
    (context pull-request-id callback &optional next-url statuses)
  "Collect all build statuses for PULL-REQUEST-ID, then invoke CALLBACK.
CONTEXT identifies the Bitbucket repository."
  (bitbucket-devops-pull-requests-ui--collect-pages
   #'bitbucket-devops-pull-requests-rest-list-statuses
   context pull-request-id callback next-url statuses))

(defun bitbucket-devops-pull-requests-ui--store-build-label
    (pull-request label)
  "Store LABEL on the loaded copy of PULL-REQUEST and refresh the list."
  (when-let* ((id (alist-get 'id pull-request))
              (loaded (bitbucket-devops-pull-requests-ui--find-loaded id)))
    (let ((updated
           (cons
            (cons 'bitbucket-devops-pull-requests-build-label label)
            (assq-delete-all
             'bitbucket-devops-pull-requests-build-label
             (copy-tree loaded)))))
      (setq bitbucket-devops-pull-requests-ui--pull-requests
            (mapcar
             (lambda (candidate)
               (if (= (or (alist-get 'id candidate) -1) id)
                   updated
                 candidate))
             bitbucket-devops-pull-requests-ui--pull-requests))
    (when (and bitbucket-devops-cache-enabled
               bitbucket-devops-pull-requests-ui--context)
      (setq bitbucket-devops-pull-requests-ui--pull-requests
            (bitbucket-devops-cache-merge-pull-requests
             bitbucket-devops-pull-requests-ui--context
             (list updated)))))
    (bitbucket-devops-pull-requests-ui--render)))

(defun bitbucket-devops-pull-requests-ui--enrich-builds
    (context pull-requests generation)
  "Sequentially enrich PULL-REQUESTS with build labels for CONTEXT.

Ignore callbacks that do not match the current request GENERATION."
  (when-let ((pull-request (car pull-requests)))
    (let ((buffer (current-buffer))
          (remaining (cdr pull-requests))
          (pull-request-id (alist-get 'id pull-request)))
      (bitbucket-devops-pull-requests-ui--collect-statuses
       context
       pull-request-id
       (lambda (statuses error)
         (when (and (buffer-live-p buffer)
                    (= generation
                       (buffer-local-value
                        'bitbucket-devops-pull-requests-ui--request-generation
                        buffer)))
           (with-current-buffer buffer
             (bitbucket-devops-pull-requests-ui--store-build-label
              pull-request
              (if error
                  "N/A"
                (bitbucket-devops-pull-requests-ui--build-summary-label statuses)))
             (bitbucket-devops-pull-requests-ui--enrich-builds
              context remaining generation))))))))

(defvar bitbucket-devops-pull-requests-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    map)
  "Keymap for `bitbucket-devops-pull-requests-list-mode'.")

(defvar bitbucket-devops-pull-requests-task-prefix-map
  (make-sparse-keymap)
  "Prefix keymap for pull request task actions.")

(defvar bitbucket-devops-pull-requests-metadata-prefix-map
  (make-sparse-keymap)
  "Prefix keymap for pull request metadata actions.")

(defvar bitbucket-devops-pull-requests-detail-mode-map
  (make-sparse-keymap)
  "Keymap for `bitbucket-devops-pull-requests-detail-mode'.")

(defun bitbucket-devops-pull-requests-ui-refresh ()
  "Reload the first pull request page for the current buffer."
  (interactive)
  (unless bitbucket-devops-pull-requests-ui--context
    (user-error "This buffer is not associated with a Bitbucket repository"))
  (let ((buffer (current-buffer))
        (context bitbucket-devops-pull-requests-ui--context)
        (state bitbucket-devops-pull-requests-ui--state-filter))
    (setq bitbucket-devops-pull-requests-ui--request-generation
          (1+ bitbucket-devops-pull-requests-ui--request-generation))
    (setq bitbucket-devops-pull-requests-ui--loading t)
    (force-mode-line-update)
    (let ((generation bitbucket-devops-pull-requests-ui--request-generation))
      (bitbucket-devops-pull-requests-rest-list
       context
       (lambda (page error)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (= generation
                      bitbucket-devops-pull-requests-ui--request-generation)
               (bitbucket-devops-pull-requests-ui--receive-page page error t)
               (unless error
                 (bitbucket-devops-pull-requests-ui--refresh-newest-loaded-details
                  context generation)
                 (bitbucket-devops-pull-requests-ui--enrich-builds
                  context
                  (bitbucket-devops-rest-page-values page)
                  generation))))))
       nil
       state))))

(defun bitbucket-devops-pull-requests-ui-load-more ()
  "Load the next pull request page for the current buffer."
  (interactive)
  (unless bitbucket-devops-pull-requests-ui--next-url
    (user-error "No older Bitbucket pull requests are available"))
  (let ((buffer (current-buffer))
        (context bitbucket-devops-pull-requests-ui--context)
        (next-url bitbucket-devops-pull-requests-ui--next-url)
        (state bitbucket-devops-pull-requests-ui--state-filter)
        (generation bitbucket-devops-pull-requests-ui--request-generation))
    (setq bitbucket-devops-pull-requests-ui--loading t)
    (force-mode-line-update)
    (bitbucket-devops-pull-requests-rest-list
     context
     (lambda (page error)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (when (= generation
                    bitbucket-devops-pull-requests-ui--request-generation)
             (bitbucket-devops-pull-requests-ui--receive-page page error nil)
             (unless error
               (bitbucket-devops-pull-requests-ui--enrich-builds
                context
                (bitbucket-devops-rest-page-values page)
                generation))))))
     next-url
     state)))

(defun bitbucket-devops-pull-requests-ui-set-state-filter (state)
  "Filter the list by pull request STATE, or show all."
  (interactive
   (list
    (completing-read
     "Pull request state: "
     '("ALL" "OPEN" "MERGED" "DECLINED" "SUPERSEDED")
     nil
     t
     nil
     nil
     (or bitbucket-devops-pull-requests-ui--state-filter "ALL"))))
  (setq bitbucket-devops-pull-requests-ui--state-filter
        (unless (equal state "ALL") (upcase state)))
  (bitbucket-devops-pull-requests-ui--render)
  (bitbucket-devops-pull-requests-ui-refresh))

(defun bitbucket-devops-pull-requests-ui--loaded-branch-names ()
  "Return branch names from loaded pull requests and Git refs."
  (sort
   (delete-dups
    (seq-filter
     (lambda (branch)
       (and (stringp branch) (not (string-empty-p branch))))
     (append
      (list (plist-get bitbucket-devops-pull-requests-ui--context :branch))
      (mapcar
       #'bitbucket-devops-pull-requests-source-branch
       bitbucket-devops-pull-requests-ui--pull-requests)
      (mapcar
       #'bitbucket-devops-pull-requests-destination-branch
       bitbucket-devops-pull-requests-ui--pull-requests)
      (bitbucket-devops-pull-requests-ui--branch-names))))
   #'string-lessp))

(defun bitbucket-devops-pull-requests-ui-set-branch-filter (branch)
  "Filter loaded pull requests by source or destination BRANCH, or show all."
  (interactive
   (list
    (completing-read
     "Pull request branch: "
     (cons "ALL" (bitbucket-devops-pull-requests-ui--loaded-branch-names))
     nil
     nil
     nil
     nil
     (or bitbucket-devops-pull-requests-ui--branch-filter "ALL"))))
  (setq branch (string-trim branch))
  (setq bitbucket-devops-pull-requests-ui--branch-filter
        (unless (or (string-empty-p branch)
                    (string-equal-ignore-case branch "ALL"))
          branch))
  (bitbucket-devops-pull-requests-ui--render))

(defun bitbucket-devops-pull-requests-ui--loaded-author-names ()
  "Return sorted author names from loaded pull requests."
  (sort
   (delete-dups
    (seq-filter
     (lambda (author)
       (and (stringp author) (not (string-empty-p author))))
     (mapcar
      #'bitbucket-devops-pull-requests-author-name
      bitbucket-devops-pull-requests-ui--pull-requests)))
   #'string-lessp))

(defun bitbucket-devops-pull-requests-ui-set-author-filter (author)
  "Filter loaded pull requests by AUTHOR display name, or show all."
  (interactive
   (list
    (completing-read
     "Pull request author: "
     (cons "ALL" (bitbucket-devops-pull-requests-ui--loaded-author-names))
     nil
     nil
     nil
     nil
     (or bitbucket-devops-pull-requests-ui--author-filter "ALL"))))
  (setq author (string-trim author))
  (setq bitbucket-devops-pull-requests-ui--author-filter
        (unless (or (string-empty-p author)
                    (string-equal-ignore-case author "ALL"))
          author))
  (bitbucket-devops-pull-requests-ui--render))

(defun bitbucket-devops-pull-requests-ui--branch-names ()
  "Return Git branch names for pull request completion."
  (let ((context bitbucket-devops-pull-requests-ui--context))
    (sort
     (delete-dups
      (seq-filter
       (lambda (branch)
         (and (stringp branch)
              (not (string-empty-p branch))
              (not (equal branch "HEAD"))))
       (condition-case nil
           (let ((default-directory
                  (or (plist-get context :root) default-directory))
                 (remote (plist-get context :remote)))
             (append
              (list (plist-get context :branch))
              (when (fboundp 'magit-list-local-branch-names)
                (magit-list-local-branch-names))
              (when (and (stringp remote)
                         (fboundp 'magit-list-remote-branch-names))
                (magit-list-remote-branch-names remote t))))
         (error (list (plist-get context :branch))))))
     #'string-lessp)))

(defun bitbucket-devops-pull-requests-ui--default-destination (branches source)
  "Return a sensible destination from BRANCHES, excluding SOURCE."
  (or (seq-find
       (lambda (branch)
         (and (member branch '("main" "master" "development" "develop"))
              (not (equal branch source))))
       branches)
      (seq-find (lambda (branch) (not (equal branch source))) branches)
      ""))

(defun bitbucket-devops-pull-requests-ui--parse-reviewers (input)
  "Return reviewer identifiers parsed from comma-separated INPUT."
  (delete-dups
   (seq-filter
    (lambda (identifier) (not (string-empty-p identifier)))
    (mapcar #'string-trim (split-string (or input "") ",")))))

(defun bitbucket-devops-pull-requests-ui--read-draft-p ()
  "Return non-nil when the user chooses to create a draft.

An empty answer defaults to yes."
  (let (answer)
    (while
        (progn
          (setq answer
                (downcase
                 (string-trim
                  (read-string "Create as draft? [Y/n]: "))))
          (unless (member answer '("" "y" "yes" "n" "no"))
            (message "Please answer y or n"))
          (not (member answer '("" "y" "yes" "n" "no")))))
    (not (null (member answer '("" "y" "yes"))))))

(defun bitbucket-devops-pull-requests-ui--collect-open-pull-requests
    (context callback &optional next-url collected)
  "Collect every open pull request for CONTEXT and invoke CALLBACK.

NEXT-URL and COLLECTED are used internally while following pagination."
  (bitbucket-devops-pull-requests-rest-list
   context
   (lambda (page error)
     (if error
         (funcall callback nil error)
       (let ((pull-requests
              (append
               collected
               (or (bitbucket-devops-rest-page-values page) nil)))
             (next (bitbucket-devops-rest-page-next page)))
         (if next
             (bitbucket-devops-pull-requests-ui--collect-open-pull-requests
              context callback next pull-requests)
           (funcall callback pull-requests nil)))))
   next-url
   "OPEN"))

(defun bitbucket-devops-pull-requests-ui--find-open-pull-request
    (pull-requests source destination)
  "Find an open PR in PULL-REQUESTS from SOURCE to DESTINATION."
  (seq-find
   (lambda (pull-request)
     (and
      (equal source (bitbucket-devops-pull-requests-source-branch pull-request))
      (equal
       destination
       (bitbucket-devops-pull-requests-destination-branch pull-request))))
   pull-requests))

(defun bitbucket-devops-pull-requests-ui--read-create-arguments ()
  "Read the non-reviewer arguments for pull request creation."
  (unless bitbucket-devops-pull-requests-ui--context
    (user-error "This buffer is not associated with a Bitbucket repository"))
  (let* ((branches (bitbucket-devops-pull-requests-ui--branch-names))
         (source-default
          (or (plist-get bitbucket-devops-pull-requests-ui--context :branch) ""))
         (source
          (completing-read
           "Source branch: " branches nil nil nil nil source-default))
         (destination-default
          (bitbucket-devops-pull-requests-ui--default-destination branches source))
         (destination
          (completing-read
           "Destination branch: " branches nil nil nil nil destination-default))
         (title (read-string "Pull request title: " source))
         (description (read-string "Description (optional): "))
         (draft (bitbucket-devops-pull-requests-ui--read-draft-p)))
    (list source destination title description draft)))

(defun bitbucket-devops-pull-requests-ui--read-create-metadata ()
  "Read creation fields that fit naturally in the minibuffer."
  (unless bitbucket-devops-pull-requests-ui--context
    (user-error "This buffer is not associated with a Bitbucket repository"))
  (let* ((branches (bitbucket-devops-pull-requests-ui--branch-names))
         (source-default
          (or (plist-get bitbucket-devops-pull-requests-ui--context :branch) ""))
         (source
          (completing-read
           "Source branch: " branches nil nil nil nil source-default))
         (destination-default
          (bitbucket-devops-pull-requests-ui--default-destination branches source))
         (destination
          (completing-read
           "Destination branch: " branches nil nil nil nil destination-default))
         (title (read-string "Pull request title: " source))
         (draft (bitbucket-devops-pull-requests-ui--read-draft-p)))
    (list :source source
          :destination destination
          :title title
          :draft draft)))

(defconst bitbucket-devops-pull-requests-ui--reviewer-strategies
  '(("No reviewers" . none)
    ("Default reviewers" . defaults)
    ("Custom reviewers" . custom))
  "Reviewer strategies offered when creating a pull request.")

(defun bitbucket-devops-pull-requests-ui--read-reviewer-strategy ()
  "Read and return the reviewer strategy for a new pull request."
  (let* ((default "Default reviewers")
         (selection
          (completing-read
           "Reviewers: "
           bitbucket-devops-pull-requests-ui--reviewer-strategies
           nil t nil nil default)))
    (cdr
     (assoc
      (if (string-empty-p selection) default selection)
      bitbucket-devops-pull-requests-ui--reviewer-strategies))))

(defun bitbucket-devops-pull-requests-ui--prompt-create-reviewers
    (buffer create-arguments users error)
  "Prompt in BUFFER for custom USERS, then create using CREATE-ARGUMENTS."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((candidates
             (bitbucket-devops-pull-requests-ui--reviewer-user-candidates users)))
        (when error
          (message
           (concat
            "Using users known from this repository; broader reviewer lookup "
            "requires optional read:workspace:bitbucket access")))
        (if (null candidates)
            (message
             "No custom reviewer candidates are available; refresh the reviewer cache and try again")
          (let* ((selections
                  (completing-read-multiple
                   "Custom reviewers: " candidates nil t))
                 (reviewer-identifiers
                  (delq
                   nil
                   (mapcar
                    (lambda (selection) (cdr (assoc selection candidates)))
                    selections))))
            (if reviewer-identifiers
                (apply
                 #'bitbucket-devops-pull-requests-ui-create
                 (append create-arguments (list reviewer-identifiers)))
              (message "No custom reviewers selected; pull request not created"))))))))

(defun bitbucket-devops-pull-requests-ui--collect-effective-default-reviewers
    (context callback &optional next-url collected)
  "Collect effective default reviewers for CONTEXT and invoke CALLBACK.

NEXT-URL and COLLECTED are used internally while following pagination."
  (bitbucket-devops-pull-requests-rest-list-effective-default-reviewers
   context
   (lambda (page error)
     (if error
         (funcall callback nil error)
       (let ((reviewers
              (append
               collected
               (or (bitbucket-devops-rest-page-values page) nil)))
             (next (bitbucket-devops-rest-page-next page)))
         (if next
             (bitbucket-devops-pull-requests-ui--collect-effective-default-reviewers
              context callback next reviewers)
           (funcall
            callback
            (bitbucket-devops-pull-requests-ui--unique-users reviewers)
            nil)))))
   next-url))

(defun bitbucket-devops-pull-requests-ui--create-with-default-reviewers
    (buffer create-arguments reviewers error)
  "Create from BUFFER and CREATE-ARGUMENTS using effective REVIEWERS.
ERROR is a request error from the preceding lookup, or nil."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if error
          (message
           "Unable to load Bitbucket default reviewers: %s"
           (or (plist-get error :message) error))
        (let ((identifiers
               (delq
                nil
                (mapcar
                 #'bitbucket-devops-pull-requests-ui--reviewer-identifier
                 reviewers))))
          (apply
           #'bitbucket-devops-pull-requests-ui-create
           (append create-arguments (list nil identifiers))))))))

(defun bitbucket-devops-pull-requests-ui--create-with-reviewer-strategy
    (buffer create-arguments strategy)
  "Create from BUFFER and CREATE-ARGUMENTS using reviewer STRATEGY."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (pcase strategy
        ('none
         (apply
          #'bitbucket-devops-pull-requests-ui-create
          (append create-arguments (list :none))))
        ('defaults
         (message "Loading Bitbucket default reviewers...")
         (bitbucket-devops-pull-requests-ui--collect-effective-default-reviewers
          bitbucket-devops-pull-requests-ui--context
          (lambda (reviewers error)
            (run-at-time
             0 nil
             #'bitbucket-devops-pull-requests-ui--create-with-default-reviewers
             buffer create-arguments reviewers error))))
        ('custom
         (message "Loading Bitbucket reviewer candidates...")
         (bitbucket-devops-pull-requests-ui--load-reviewer-users
          (lambda (users error)
            (run-at-time
             0 nil
             #'bitbucket-devops-pull-requests-ui--prompt-create-reviewers
             buffer create-arguments users error))))
        (_ (user-error "Unknown pull request reviewer strategy"))))))

(defun bitbucket-devops-pull-requests-ui--create-description-buffer-name ()
  "Return the description editor buffer name for a new pull request."
  (format
   "*Bitbucket Pull Request Description: %s/%s new*"
   (plist-get bitbucket-devops-pull-requests-ui--context :workspace)
   (plist-get bitbucket-devops-pull-requests-ui--context :repo-slug)))

(defun bitbucket-devops-pull-requests-ui--open-create-description-editor
    (metadata reviewer-strategy)
  "Open a Markdown editor for a new pull request description.
METADATA supplies the pull request fields collected so far.
REVIEWER-STRATEGY selects how reviewers are resolved."
  (let* ((source-buffer (current-buffer))
         (buffer
          (get-buffer-create
           (bitbucket-devops-pull-requests-ui--create-description-buffer-name))))
    (with-current-buffer buffer
      (unless (and (eq bitbucket-devops-pull-requests-ui--create-source-buffer
                       source-buffer)
                   (buffer-modified-p))
        (if (require 'markdown-mode nil t)
            (markdown-mode)
          (text-mode))
        (erase-buffer)
        (goto-char (point-min))
        (set-buffer-modified-p nil))
      (setq-local bitbucket-devops-pull-requests-ui--create-source-buffer
                  source-buffer)
      (setq-local bitbucket-devops-pull-requests-ui--create-metadata metadata)
      (setq-local bitbucket-devops-pull-requests-ui--create-reviewer-strategy
                  reviewer-strategy)
      (setq-local bitbucket-devops-pull-requests-ui--create-saving nil)
      (bitbucket-devops-pull-requests-create-description-mode 1)
      (setq-local header-line-format
                  " New pull request Markdown  C-c C-c/C-x C-s create  C-c C-k cancel "))
    (let ((window
           (display-buffer
            buffer
            '((display-buffer-in-side-window)
              (side . right)
              (slot . 1)
              (window-width . 0.45)))))
      (when (window-live-p window)
        (select-window window)))
    buffer))

(defun bitbucket-devops-pull-requests-ui--create-interactively ()
  "Read pull request fields and apply the selected reviewer strategy."
  (let* ((buffer (current-buffer))
         (strategy
          (bitbucket-devops-pull-requests-ui--read-reviewer-strategy))
         (metadata
          (bitbucket-devops-pull-requests-ui--read-create-metadata)))
    (with-current-buffer buffer
      (bitbucket-devops-pull-requests-ui--open-create-description-editor
       metadata strategy))))

(defun bitbucket-devops-pull-requests-ui--read-watch-created-p
    (pull-request-id)
  "Return non-nil when the user wants to watch created PULL-REQUEST-ID."
  (let (answer)
    (while
        (progn
          (setq answer
                (downcase
                 (string-trim
                  (read-string
                   (format
                    "Watch comments for pull request #%s? [Y/n]: "
                    pull-request-id)))))
          (unless (member answer '("" "y" "yes" "n" "no"))
            (message "Please answer y or n"))
          (not (member answer '("" "y" "yes" "n" "no")))))
    (not (null (member answer '("" "y" "yes"))))))

(defun bitbucket-devops-pull-requests-ui--maybe-watch-created
    (context pull-request)
  "Prompt to watch comments for created PULL-REQUEST in CONTEXT."
  (when bitbucket-devops-pull-requests-auto-watch-created
    (let ((pull-request-id (alist-get 'id pull-request)))
      (when (and pull-request-id
                 (bitbucket-devops-pull-requests-ui--read-watch-created-p
                  pull-request-id))
        (require 'bitbucket-devops-pull-requests-watch)
        (bitbucket-devops-pull-requests-watch-comments context pull-request)
        (message "Watching Bitbucket pull request #%s comments"
                 pull-request-id)))))

(defun bitbucket-devops-pull-requests-ui--finish-create
    (buffer context pull-request &optional reviewer-error)
  "Finish creating PULL-REQUEST from BUFFER in CONTEXT.

When REVIEWER-ERROR is non-nil, report that creation succeeded but applying
default reviewers failed."
  (if reviewer-error
      (message
       "Created Bitbucket pull request #%s, but unable to apply default reviewers: %s"
       (alist-get 'id pull-request)
       (or (plist-get reviewer-error :message) reviewer-error))
    (message "Created Bitbucket pull request #%s"
             (alist-get 'id pull-request)))
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (bitbucket-devops-pull-requests-ui-refresh)))
  (bitbucket-devops-pull-requests-ui--maybe-watch-created context pull-request)
  (bitbucket-devops-pull-requests-ui-show-details context pull-request))

(defun bitbucket-devops-pull-requests-ui--apply-default-reviewers
    (buffer context pull-request reviewer-identifiers)
  "Apply REVIEWER-IDENTIFIERS to PULL-REQUEST, excluding its author.
BUFFER is the buffer to act on.
CONTEXT identifies the Bitbucket repository."
  (let* ((author (alist-get 'author pull-request))
         (author-identifier
          (bitbucket-devops-pull-requests-ui--reviewer-identifier author))
         (identifiers
          (delete author-identifier (copy-sequence reviewer-identifiers))))
    (if (null identifiers)
        (bitbucket-devops-pull-requests-ui--finish-create
         buffer context pull-request)
      (bitbucket-devops-pull-requests-rest-update
       context
       (alist-get 'id pull-request)
       (bitbucket-devops-pull-requests-rest-reviewers-body identifiers)
       (lambda (updated-pull-request error)
         (bitbucket-devops-pull-requests-ui--finish-create
          buffer
          context
          (or updated-pull-request pull-request)
          error))))))

(defun bitbucket-devops-pull-requests-ui-create
    (&optional source destination title description draft reviewer-identifiers
               default-reviewer-identifiers)
  "Create a pull request from SOURCE to DESTINATION.

TITLE, DESCRIPTION, DRAFT, and REVIEWER-IDENTIFIERS form the remaining
Bitbucket pull request fields.  When DEFAULT-REVIEWER-IDENTIFIERS is non-nil,
create the pull request first, exclude its author, and then apply those default
reviewers."
  (interactive)
  (unless bitbucket-devops-pull-requests-ui--context
    (user-error "This buffer is not associated with a Bitbucket repository"))
  (if (called-interactively-p 'interactive)
      (bitbucket-devops-pull-requests-ui--create-interactively)
    (setq source (string-trim (or source ""))
          destination (string-trim (or destination "")))
    (let ((buffer (current-buffer))
          (context bitbucket-devops-pull-requests-ui--context)
          (body
           (bitbucket-devops-pull-requests-rest-create-body
            source destination title description draft reviewer-identifiers)))
      (bitbucket-devops-pull-requests-ui--collect-open-pull-requests
       context
       (lambda (open-pull-requests error)
         (if error
             (message "Unable to check existing Bitbucket pull requests: %s"
                      (or (plist-get error :message) error))
           (if-let ((existing
                     (bitbucket-devops-pull-requests-ui--find-open-pull-request
                      open-pull-requests source destination)))
               (message
                (concat "Open Bitbucket pull request #%s already exists for "
                        "%s -> %s; creation cancelled")
                (alist-get 'id existing)
                source
                destination)
             (bitbucket-devops-pull-requests-rest-create
              context
              body
              (lambda (pull-request create-error)
                (if create-error
                    (message "Unable to create Bitbucket pull request: %s"
                             (or (plist-get create-error :message)
                                 create-error))
                  (if default-reviewer-identifiers
                      (bitbucket-devops-pull-requests-ui--apply-default-reviewers
                       buffer
                       context
                       pull-request
                       default-reviewer-identifiers)
                    (bitbucket-devops-pull-requests-ui--finish-create
                     buffer context pull-request))))))))))))

(define-derived-mode bitbucket-devops-pull-requests-detail-mode special-mode
  "Bitbucket-PR"
  "Major mode for a Bitbucket Cloud pull request detail buffer."
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local line-spacing 0.12)
  (setq-local header-line-format
              '(:eval (bitbucket-devops-pull-requests-ui--detail-header-line))))

(defvar bitbucket-devops-pull-requests-description-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c")
                #'bitbucket-devops-pull-requests-ui-save-description)
    (define-key map (kbd "C-x C-s")
                #'bitbucket-devops-pull-requests-ui-save-description)
    (define-key map (kbd "C-c C-k")
                #'bitbucket-devops-pull-requests-ui-cancel-description-edit)
    map)
  "Keymap for Bitbucket pull request description editing.")

(define-minor-mode bitbucket-devops-pull-requests-description-edit-mode
  "Minor mode for editing a Bitbucket pull request description."
  :lighter " PR-Description"
  :keymap bitbucket-devops-pull-requests-description-edit-mode-map)

(defvar bitbucket-devops-pull-requests-create-description-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c")
                #'bitbucket-devops-pull-requests-ui-save-create-description)
    (define-key map (kbd "C-x C-s")
                #'bitbucket-devops-pull-requests-ui-save-create-description)
    (define-key map (kbd "C-c C-k")
                #'bitbucket-devops-pull-requests-ui-cancel-create-description)
    map)
  "Keymap for new Bitbucket pull request description editing.")

(define-minor-mode bitbucket-devops-pull-requests-create-description-mode
  "Minor mode for composing a new Bitbucket pull request description."
  :lighter " PR-Create"
  :keymap bitbucket-devops-pull-requests-create-description-mode-map)

(defun bitbucket-devops-pull-requests-ui--details-buffer-name
    (context pull-request-id)
  "Return the detail buffer name for CONTEXT and PULL-REQUEST-ID."
  (format
   "*Bitbucket Pull Request: %s/%s#%s*"
   (plist-get context :workspace)
   (plist-get context :repo-slug)
   pull-request-id))

(defun bitbucket-devops-pull-requests-ui--detail-values (page)
  "Return PAGE values, or nil for an empty response."
  (or (bitbucket-devops-pull-requests-ui--values page) nil))

(defun bitbucket-devops-pull-requests-ui--details-receive
    (buffer variable value error section &optional page-values)
  "Store VALUE in BUFFER-local VARIABLE and render.

SECTION identifies the request in errors.  When PAGE-VALUES is non-nil, store
the paginated `values' array from VALUE.
BUFFER is the buffer to act on."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if error
          (message "Unable to load Bitbucket pull request %s: %s"
                   section
                   (or (plist-get error :message) error))
        (set variable
             (if page-values
                 (bitbucket-devops-pull-requests-ui--detail-values value)
               value))
        (bitbucket-devops-pull-requests-ui--render-details)))))

(defun bitbucket-devops-pull-requests-ui--enrich-comment-resolutions
    (context pull-request-id comments callback)
  "Fetch complete top-level COMMENTS and invoke CALLBACK with the result.

Bitbucket's list-comments response can omit the `resolution' field even when a
thread is resolved.  Individual comment responses include that field.
CONTEXT identifies the Bitbucket repository.
PULL-REQUEST-ID identifies the pull request."
  (let* ((result (copy-tree comments))
         (top-level
          (seq-filter
           (lambda (comment)
             (and (alist-get 'id comment)
                  (not (alist-get 'parent comment))
                  (not (alist-get 'deleted comment))))
           result))
         (remaining (length top-level)))
    (if (zerop remaining)
        (funcall callback result nil)
      (dolist (comment top-level)
        (let ((comment-id (alist-get 'id comment)))
          (bitbucket-devops-pull-requests-rest-get-comment
           context
           pull-request-id
           comment-id
           (lambda (complete error)
             (unless error
               (when-let ((position
                           (cl-position
                            comment-id
                            result
                            :key (lambda (candidate)
                                   (alist-get 'id candidate))
                            :test #'equal)))
                 (setcar (nthcdr position result) complete)))
             (setq remaining (1- remaining))
             (when (zerop remaining)
               (funcall callback result nil)))))))))

(defun bitbucket-devops-pull-requests-ui-refresh-details ()
  "Refresh the current pull request detail buffer."
  (interactive)
  (unless (and bitbucket-devops-pull-requests-ui--context
               bitbucket-devops-pull-requests-ui--details-pull-request-id)
    (user-error "This buffer is not associated with a Bitbucket pull request"))
  (let ((buffer (current-buffer))
        (context bitbucket-devops-pull-requests-ui--context)
        (pull-request-id bitbucket-devops-pull-requests-ui--details-pull-request-id))
    (bitbucket-devops-pull-requests-rest-get
     context
     pull-request-id
     (lambda (pull-request error)
       (bitbucket-devops-pull-requests-ui--details-receive
        buffer
        'bitbucket-devops-pull-requests-ui--details-pull-request
        pull-request
        error
        "summary")))
    (bitbucket-devops-pull-requests-ui--collect-pages
     #'bitbucket-devops-pull-requests-rest-list-activity
     context
     pull-request-id
     (lambda (activity error)
       (bitbucket-devops-pull-requests-ui--details-receive
        buffer
        'bitbucket-devops-pull-requests-ui--details-activity
        activity
        error
        "activity")))
    (bitbucket-devops-pull-requests-ui--collect-pages
     #'bitbucket-devops-pull-requests-rest-list-comments
     context
     pull-request-id
     (lambda (comments error)
       (if error
           (bitbucket-devops-pull-requests-ui--details-receive
            buffer
            'bitbucket-devops-pull-requests-ui--details-comments
            comments
            error
            "comments")
         (bitbucket-devops-pull-requests-ui--enrich-comment-resolutions
          context
          pull-request-id
          comments
          (lambda (enriched enrich-error)
            (bitbucket-devops-pull-requests-ui--details-receive
             buffer
             'bitbucket-devops-pull-requests-ui--details-comments
             enriched
             enrich-error
             "comments"))))))
    (bitbucket-devops-pull-requests-ui--collect-pages
     #'bitbucket-devops-pull-requests-rest-list-commits
     context
     pull-request-id
     (lambda (commits error)
       (bitbucket-devops-pull-requests-ui--details-receive
        buffer
        'bitbucket-devops-pull-requests-ui--details-commits
        commits
        error
        "commits")))
    (bitbucket-devops-pull-requests-ui--collect-statuses
     context
     pull-request-id
     (lambda (statuses error)
       (bitbucket-devops-pull-requests-ui--details-receive
        buffer
        'bitbucket-devops-pull-requests-ui--details-statuses
        statuses
        error
        "build statuses")))
    (bitbucket-devops-pull-requests-ui--collect-pages
     #'bitbucket-devops-pull-requests-rest-list-tasks
     context
     pull-request-id
     (lambda (tasks error)
       (bitbucket-devops-pull-requests-ui--details-receive
        buffer
        'bitbucket-devops-pull-requests-ui--details-tasks
        tasks
        error
        "tasks")))
    (bitbucket-devops-pull-requests-ui--collect-pages
     #'bitbucket-devops-pull-requests-rest-list-diffstat
     context
     pull-request-id
     (lambda (diffstat error)
       (bitbucket-devops-pull-requests-ui--details-receive
        buffer
        'bitbucket-devops-pull-requests-ui--details-diffstat
        diffstat
        error
        "changed files")))))

(defun bitbucket-devops-pull-requests-ui-show-details (context pull-request)
  "Show PULL-REQUEST details for CONTEXT."
  (let* ((pull-request-id (alist-get 'id pull-request))
         (buffer
          (get-buffer-create
           (bitbucket-devops-pull-requests-ui--details-buffer-name
            context
            pull-request-id))))
    (with-current-buffer buffer
      (bitbucket-devops-pull-requests-detail-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id
                  pull-request-id)
      (setq-local bitbucket-devops-pull-requests-ui--details-pull-request
                  pull-request)
      (setq-local bitbucket-devops-pull-requests-ui--details-activity nil)
      (setq-local bitbucket-devops-pull-requests-ui--details-comments nil)
      (setq-local bitbucket-devops-pull-requests-ui--details-commits nil)
      (setq-local bitbucket-devops-pull-requests-ui--details-statuses nil)
      (setq-local bitbucket-devops-pull-requests-ui--details-tasks nil)
      (setq-local bitbucket-devops-pull-requests-ui--details-diffstat nil)
      (bitbucket-devops-pull-requests-ui--render-details))
    (bitbucket-devops-ui--display-buffer
     buffer
     t
     (current-buffer))
    (bitbucket-devops-pull-requests-ui-refresh-details)))

(defun bitbucket-devops-pull-requests-ui-open-at-point ()
  "Open the pull request at point."
  (interactive)
  (unless bitbucket-devops-pull-requests-ui--context
    (user-error "This buffer is not associated with a Bitbucket repository"))
  (let* ((id (string-to-number
              (or (bitbucket-devops-pull-requests-ui--id-at-point-or-next) "")))
         (pull-request (bitbucket-devops-pull-requests-ui--find-loaded id)))
    (unless pull-request
      (user-error "No Bitbucket pull request at point"))
    (bitbucket-devops-pull-requests-ui-show-details
     bitbucket-devops-pull-requests-ui--context
     pull-request)))

(defun bitbucket-devops-pull-requests-ui--current-pull-request ()
  "Return the pull request selected by the current list or detail buffer."
  (cond
   ((derived-mode-p 'bitbucket-devops-pull-requests-list-mode)
    (let ((id (string-to-number
               (or (bitbucket-devops-pull-requests-ui--id-at-point-or-next) ""))))
      (or (bitbucket-devops-pull-requests-ui--find-loaded id)
          (user-error "No Bitbucket pull request at point"))))
   ((derived-mode-p 'bitbucket-devops-pull-requests-detail-mode)
    (or bitbucket-devops-pull-requests-ui--details-pull-request
        (user-error "No Bitbucket pull request is loaded")))
   (t
    (user-error "This command requires a pull request list or detail buffer"))))

(defun bitbucket-devops-pull-requests-ui-run-pipeline (&optional additional)
  "Run a configured pipeline from the current pull request buffer's repository.

With a prefix argument, or when ADDITIONAL is non-nil, also prompt for
free-form runtime variables that `bitbucket-pipelines.yml' does not declare."
  (interactive "P")
  (unless bitbucket-devops-pull-requests-ui--context
    (user-error "This buffer is not associated with a Bitbucket repository"))
  (require 'bitbucket-devops-pipelines-mutate)
  (bitbucket-devops-pipelines-run-configured
   (or (plist-get bitbucket-devops-pull-requests-ui--context :root)
       default-directory)
   additional))

(defun bitbucket-devops-pull-requests-ui-toggle-comment-watch ()
  "Toggle comment notifications for the selected pull request."
  (interactive)
  (unless bitbucket-devops-pull-requests-ui--context
    (user-error "This buffer is not associated with a Bitbucket repository"))
  (require 'bitbucket-devops-pull-requests-watch)
  (let* ((context bitbucket-devops-pull-requests-ui--context)
         (pull-request (bitbucket-devops-pull-requests-ui--current-pull-request))
         (pull-request-id (alist-get 'id pull-request)))
    (unless pull-request-id
      (user-error "Unable to watch comments without a pull request id"))
    (if (bitbucket-devops-pull-requests-watch-comments-active-p
         context
         pull-request-id)
        (progn
          (bitbucket-devops-pull-requests-watch-comments-stop
           context
           pull-request-id)
          (message "Stopped watching Bitbucket pull request #%s comments"
                   pull-request-id))
      (bitbucket-devops-pull-requests-watch-comments context pull-request)
      (message "Watching Bitbucket pull request #%s comments"
               pull-request-id))))

(defun bitbucket-devops-pull-requests-ui--pull-request-at-point ()
  "Return the pull request on the current list row, or nil."
  (when (derived-mode-p 'bitbucket-devops-pull-requests-list-mode)
    (when-let ((id (tabulated-list-get-id)))
      (bitbucket-devops-pull-requests-ui--find-loaded (string-to-number id)))))

(defun bitbucket-devops-pull-requests-ui--browser-url-at-point ()
  "Return the browser URL represented by point in a pull request buffer."
  (unless bitbucket-devops-pull-requests-ui--context
    (user-error "This buffer is not associated with a Bitbucket repository"))
  (cond
   ((derived-mode-p 'bitbucket-devops-pull-requests-list-mode)
    (if-let ((pull-request
              (bitbucket-devops-pull-requests-ui--pull-request-at-point)))
        (bitbucket-devops-pull-requests-ui--pull-request-url
         bitbucket-devops-pull-requests-ui--context
         pull-request)
      (bitbucket-devops-pull-requests-ui--pull-requests-url
       bitbucket-devops-pull-requests-ui--context)))
   ((derived-mode-p 'bitbucket-devops-pull-requests-detail-mode)
    (or
     (bitbucket-devops-pull-requests-ui--property-at-point-or-line
      'bitbucket-devops-pull-requests-status-url)
     (and
      (eq (bitbucket-devops-pull-requests-ui--action-at-point)
          #'bitbucket-devops-pull-requests-ui-browse)
      (bitbucket-devops-pull-requests-ui--pull-request-url
       bitbucket-devops-pull-requests-ui--context
       bitbucket-devops-pull-requests-ui--details-pull-request
       bitbucket-devops-pull-requests-ui--details-pull-request-id))
     (user-error "No Bitbucket browser link at point")))
   (t
    (user-error
     "This command requires a pull request list or detail buffer"))))

(defun bitbucket-devops-pull-requests-ui--browse-url (url)
  "Open URL in the configured browser."
  (browse-url url))

(defun bitbucket-devops-pull-requests-ui-browse (&optional copy)
  "Open the current pull request or pull request list in a browser.

In a pull request list buffer, open the row at point when point is on a row.
When point is on the list header or empty space, open the repository pull
request list.  In a detail buffer, open the displayed pull request.
With a prefix argument, COPY the URL to the kill ring instead."
  (interactive "P")
  (unless bitbucket-devops-pull-requests-ui--context
    (user-error "This buffer is not associated with a Bitbucket repository"))
  (let ((url
         (if (derived-mode-p 'bitbucket-devops-pull-requests-detail-mode)
             (bitbucket-devops-pull-requests-ui--pull-request-url
              bitbucket-devops-pull-requests-ui--context
              bitbucket-devops-pull-requests-ui--details-pull-request
              bitbucket-devops-pull-requests-ui--details-pull-request-id)
           (bitbucket-devops-pull-requests-ui--browser-url-at-point))))
    (if copy
        (progn
          (kill-new url)
          (message "Copied Bitbucket URL: %s" url))
      (bitbucket-devops-pull-requests-ui--browse-url url))))

(defun bitbucket-devops-pull-requests-ui-browse-status (&optional pipeline)
  "Open the build status URL at point in a browser.
With a prefix argument, PIPELINE opens the pipeline instead."
  (interactive "P")
  (if pipeline
      (bitbucket-devops-pull-requests-ui-open-status-pipeline)
    (if-let ((url
              (bitbucket-devops-pull-requests-ui--property-at-point-or-line
               'bitbucket-devops-pull-requests-status-url)))
        (bitbucket-devops-pull-requests-ui--browse-url url)
      (user-error "No Bitbucket build status link at point"))))

(defun bitbucket-devops-pull-requests-ui--status-at-point ()
  "Return the build status represented by point, or nil."
  (bitbucket-devops-pull-requests-ui--property-at-point-or-line
   'bitbucket-devops-pull-requests-status))

(defun bitbucket-devops-pull-requests-ui--status-pipeline-uuid (status)
  "Return a pipeline UUID advertised by STATUS, or nil."
  (or (bitbucket-devops-pull-requests-ui--status-explicit-pipeline-uuid
       status)
      (when-let ((url (bitbucket-devops-pull-requests-ui--status-url status)))
        (when (bitbucket-devops-pull-requests-ui--bitbucket-pipeline-url-p
               url)
          (let ((decoded (url-unhex-string url)))
            (when (string-match
                   (rx "/pipelines/" (group "{" (+ (not (any "/?"))) "}"))
                   decoded)
              (match-string 1 decoded)))))))

(defun bitbucket-devops-pull-requests-ui--status-build-number (status)
  "Return the pipeline build number advertised by STATUS, or nil."
  (when (bitbucket-devops-pull-requests-ui--status-local-pipeline-p status)
    (let ((build-number (alist-get 'build_number status)))
      (or
       (cond
        ((integerp build-number) build-number)
        ((stringp build-number) (string-to-number build-number)))
       (when-let ((url (bitbucket-devops-pull-requests-ui--status-url status)))
         (let ((decoded (url-unhex-string url)))
           (when (string-match
                  (rx "/pipelines/results/" (group (+ digit)))
                  decoded)
             (string-to-number (match-string 1 decoded)))))))))

(defun bitbucket-devops-pull-requests-ui--pipeline-build-number (pipeline)
  "Return PIPELINE's numeric build number, or nil."
  (let ((value (alist-get 'build_number pipeline)))
    (cond
     ((integerp value) value)
     ((stringp value) (string-to-number value)))))

(defun bitbucket-devops-pull-requests-ui--pipeline-with-build-number
    (pipelines build-number)
  "Return pipeline from PIPELINES with BUILD-NUMBER."
  (seq-find
   (lambda (pipeline)
     (= (or (bitbucket-devops-pull-requests-ui--pipeline-build-number pipeline)
            -1)
        build-number))
   pipelines))

(defun bitbucket-devops-pull-requests-ui--find-pipeline-by-build-number
    (context build-number callback &optional next-url)
  "Find BUILD-NUMBER in CONTEXT pipeline history and invoke CALLBACK."
  (bitbucket-devops-rest-list-pipelines
   context
   (lambda (page error)
     (if error
         (funcall callback nil error)
       (if-let ((pipeline
                 (bitbucket-devops-pull-requests-ui--pipeline-with-build-number
                  (bitbucket-devops-rest-page-values page)
                  build-number)))
           (funcall callback pipeline nil)
         (if-let ((next (bitbucket-devops-rest-page-next page)))
             (bitbucket-devops-pull-requests-ui--find-pipeline-by-build-number
              context build-number callback next)
           (funcall callback nil nil)))))
   next-url))

(defun bitbucket-devops-pull-requests-ui-open-status-pipeline ()
  "Open the matching Bitbucket Pipelines details buffer for status at point."
  (interactive)
  (unless bitbucket-devops-pull-requests-ui--context
    (user-error "This buffer is not associated with a Bitbucket repository"))
  (let* ((context bitbucket-devops-pull-requests-ui--context)
         (status
          (or (bitbucket-devops-pull-requests-ui--status-at-point)
              (user-error "No Bitbucket build status at point")))
         (pipeline-uuid
          (bitbucket-devops-pull-requests-ui--status-pipeline-uuid status))
         (build-number
          (bitbucket-devops-pull-requests-ui--status-build-number status)))
    (cond
     (pipeline-uuid
      (bitbucket-devops-pipelines-details context pipeline-uuid))
     (build-number
      (if-let ((pipeline
                (bitbucket-devops-pull-requests-ui--pipeline-with-build-number
                 (bitbucket-devops-cache-pipelines context)
                 build-number)))
          (bitbucket-devops-pipelines-details
           context
           (alist-get 'uuid pipeline))
        (message "Finding Bitbucket pipeline #%s..." build-number)
        (bitbucket-devops-pull-requests-ui--find-pipeline-by-build-number
         context
         build-number
         (lambda (pipeline error)
           (if error
               (message "Unable to find Bitbucket pipeline #%s: %s"
                        build-number
                        (or (plist-get error :message) error))
             (if pipeline
                 (bitbucket-devops-pipelines-details
                  context
                  (alist-get 'uuid pipeline))
               (message "No Bitbucket pipeline #%s found" build-number)))))))
     (t
      (user-error
       "This build status does not identify a Bitbucket pipeline")))))

(defun bitbucket-devops-pull-requests-ui-open-status (&optional alternate)
  "Run the configured build status action at point.

With ALTERNATE, run the action not selected by
`bitbucket-devops-pull-requests-build-status-action'."
  (interactive "P")
  (let ((action bitbucket-devops-pull-requests-build-status-action))
    (when alternate
      (setq action (if (eq action 'browser) 'local 'browser)))
    (pcase action
      ('browser (bitbucket-devops-pull-requests-ui-browse-status))
      ('local
       (let ((status
              (or (bitbucket-devops-pull-requests-ui--status-at-point)
                  (user-error "No Bitbucket build status at point"))))
         (if (bitbucket-devops-pull-requests-ui--status-local-pipeline-p
              status)
             (bitbucket-devops-pull-requests-ui-open-status-pipeline)
           (bitbucket-devops-pull-requests-ui-browse-status))))
      (_
       (user-error
        "Invalid `bitbucket-devops-pull-requests-build-status-action': %s"
        action)))))

(defun bitbucket-devops-pull-requests-ui-copy-browser-url-at-point
    (&optional browse)
  "Copy the browser URL represented by point to the kill ring.

With BROWSE, open the URL instead."
  (interactive "P")
  (let ((url (bitbucket-devops-pull-requests-ui--browser-url-at-point)))
    (if browse
        (bitbucket-devops-pull-requests-ui--browse-url url)
      (kill-new url)
      (message "Copied Bitbucket URL: %s" url))))

(defun bitbucket-devops-pull-requests-ui-open-detail-at-point
    (&optional alternate)
  "Run the pull request detail action at point.

With ALTERNATE, commands that support a paired action run the other action."
  (interactive "P")
  (unless (derived-mode-p 'bitbucket-devops-pull-requests-detail-mode)
    (user-error "This command requires a Bitbucket pull request detail buffer"))
  (if-let ((action (bitbucket-devops-pull-requests-ui--action-at-point)))
      (let ((current-prefix-arg alternate))
        (call-interactively action))
    (user-error "No Bitbucket pull request action at point")))

(defun bitbucket-devops-pull-requests-ui-open-detail-at-mouse (event)
  "Run the pull request detail action clicked in mouse EVENT."
  (interactive "e")
  (mouse-set-point event)
  (bitbucket-devops-pull-requests-ui-open-detail-at-point))

(defun bitbucket-devops-pull-requests-ui--git-call (context &rest arguments)
  "Run Git ARGUMENTS in CONTEXT and return trimmed output.

Signal a `user-error' containing Git's output when the command fails."
  (let ((default-directory (plist-get context :root)))
    (unless (and (stringp default-directory)
                 (file-directory-p default-directory))
      (user-error "Unable to find the local Git repository"))
    (unless (executable-find "git")
      (user-error "Git is not available"))
    (with-temp-buffer
      (let ((status
             (apply #'process-file
                    "git" nil (list (current-buffer) t) nil arguments)))
        (let ((output (string-trim (buffer-string))))
          (unless (zerop status)
            (user-error
             "Git %s failed%s"
             (or (car arguments) "command")
             (if (string-empty-p output)
                 ""
               (format ": %s" output))))
          output)))))

(defun bitbucket-devops-pull-requests-ui--git-call-raw (context &rest arguments)
  "Run Git ARGUMENTS in CONTEXT and return output without trimming it."
  (let ((default-directory (plist-get context :root)))
    (unless (and (stringp default-directory)
                 (file-directory-p default-directory))
      (user-error "Unable to find the local Git repository"))
    (unless (executable-find "git")
      (user-error "Git is not available"))
    (with-temp-buffer
      (let ((status
             (apply #'process-file
                    "git" nil (list (current-buffer) t) nil arguments))
            (output nil))
        (setq output (buffer-string))
        (unless (zerop status)
          (user-error
           "Git %s failed%s"
           (or (car arguments) "command")
           (if (string-empty-p (string-trim output))
               ""
             (format ": %s" (string-trim output)))))
        output))))

(defun bitbucket-devops-pull-requests-ui--git-ref-exists-p (context ref)
  "Return non-nil when Git REF exists in repository CONTEXT."
  (let ((default-directory (plist-get context :root)))
    (and (stringp default-directory)
         (file-directory-p default-directory)
         (zerop
          (process-file
           "git" nil nil nil
           "show-ref" "--verify" "--quiet" ref)))))

(defun bitbucket-devops-pull-requests-ui--git-commit-exists-p (context hash)
  "Return non-nil when HASH names a commit in repository CONTEXT."
  (let ((default-directory (plist-get context :root)))
    (and (stringp default-directory)
         (file-directory-p default-directory)
         (stringp hash)
         (string-match-p "\\`[[:xdigit:]]+\\'" hash)
         (zerop
          (process-file
           "git" nil nil nil "cat-file" "-e" (concat hash "^{commit}"))))))

(defun bitbucket-devops-pull-requests-ui--validate-checkout-target
    (context remote branch)
  "Validate REMOTE and BRANCH before fetching in repository CONTEXT."
  (unless (and (stringp remote)
               (not (string-empty-p remote))
               (not (string-prefix-p "-" remote)))
    (user-error "The configured Git remote is invalid"))
  (bitbucket-devops-pull-requests-ui--git-call
   context "check-ref-format" "--branch" branch)
  (bitbucket-devops-pull-requests-ui--git-call
   context "check-ref-format"
   (format "refs/remotes/%s/%s" remote branch)))

(defun bitbucket-devops-pull-requests-ui--pull-request-side-value
    (pull-request side &rest keys)
  "Return the value under SIDE and KEYS in PULL-REQUEST."
  (apply
   #'bitbucket-devops-pull-requests--nested-get
   pull-request
   side
   keys))

(defun bitbucket-devops-pull-requests-ui--pull-request-side-hash
    (pull-request side)
  "Return the commit hash for SIDE of PULL-REQUEST."
  (bitbucket-devops-pull-requests-ui--pull-request-side-value
   pull-request side 'commit 'hash))

(defun bitbucket-devops-pull-requests-ui--pull-request-side-branch
    (pull-request side)
  "Return the branch name for SIDE of PULL-REQUEST."
  (bitbucket-devops-pull-requests-ui--pull-request-side-value
   pull-request side 'branch 'name))

(defun bitbucket-devops-pull-requests-ui--pull-request-side-repository
    (pull-request side)
  "Return the full repository name for SIDE of PULL-REQUEST."
  (bitbucket-devops-pull-requests-ui--pull-request-side-value
   pull-request side 'repository 'full_name))

(defun bitbucket-devops-pull-requests-ui--context-repository-name (context)
  "Return CONTEXT's workspace/repository name."
  (format "%s/%s"
          (plist-get context :workspace)
          (plist-get context :repo-slug)))

(defun bitbucket-devops-pull-requests-ui--validate-repository-name (repository)
  "Return REPOSITORY when it is a safe Bitbucket workspace/repository name."
  (unless (and
           (stringp repository)
           (string-match-p
            "\\`[[:alnum:]_.-]+/[[:alnum:]_.-]+\\'"
            repository))
    (user-error "The pull request source repository is invalid"))
  repository)

(defun bitbucket-devops-pull-requests-ui--fetch-pull-request-side
    (context pull-request side)
  "Fetch SIDE of PULL-REQUEST into the local repository for CONTEXT."
  (let* ((hash
          (bitbucket-devops-pull-requests-ui--pull-request-side-hash
           pull-request side))
         (branch
          (bitbucket-devops-pull-requests-ui--pull-request-side-branch
           pull-request side))
         (repository
          (or
           (bitbucket-devops-pull-requests-ui--pull-request-side-repository
            pull-request side)
           (bitbucket-devops-pull-requests-ui--context-repository-name context)))
         (remote
          (if (equal
               (downcase repository)
               (downcase
                (bitbucket-devops-pull-requests-ui--context-repository-name context)))
              (plist-get context :remote)
            (format
             "git@bitbucket.org:%s.git"
             (bitbucket-devops-pull-requests-ui--validate-repository-name
              repository))))
         (pull-request-id (alist-get 'id pull-request))
         (target
          (format "refs/bitbucket-devops-pull-requests/%s/%s"
                  pull-request-id side)))
    (unless (and (stringp hash)
                 (string-match-p "\\`[[:xdigit:]]+\\'" hash))
      (user-error "The pull request %s commit hash is unavailable" side))
    (unless (and (stringp branch) (not (string-empty-p branch)))
      (user-error "The pull request %s branch is unavailable" side))
    (bitbucket-devops-pull-requests-ui--git-call
     context "check-ref-format" "--branch" branch)
    (bitbucket-devops-pull-requests-ui--git-call
     context "check-ref-format" target)
    (message "Fetching pull request %s branch %s..." side branch)
    (bitbucket-devops-pull-requests-ui--git-call
     context
     "fetch"
     "--no-tags"
     remote
     (format "+refs/heads/%s:%s" branch target))
    (unless (bitbucket-devops-pull-requests-ui--git-commit-exists-p context hash)
      (user-error
       "Commit %s was not found after fetching %s from %s"
       hash branch repository))
    hash))

(defun bitbucket-devops-pull-requests-ui--ensure-pull-request-revisions
    (context pull-request)
  "Ensure both revisions for PULL-REQUEST are available in CONTEXT.

Return a list containing destination and source commit hashes."
  (let ((destination
         (bitbucket-devops-pull-requests-ui--pull-request-side-hash
          pull-request 'destination))
        (source
         (bitbucket-devops-pull-requests-ui--pull-request-side-hash
          pull-request 'source)))
    (unless (bitbucket-devops-pull-requests-ui--git-commit-exists-p
             context destination)
      (setq destination
            (bitbucket-devops-pull-requests-ui--fetch-pull-request-side
             context pull-request 'destination)))
    (unless (bitbucket-devops-pull-requests-ui--git-commit-exists-p context source)
      (setq source
            (bitbucket-devops-pull-requests-ui--fetch-pull-request-side
             context pull-request 'source)))
    (list destination source)))

(defun bitbucket-devops-pull-requests-ui-checkout-source-branch ()
  "Fetch and switch to the selected pull request's source branch.

Use the configured repository remote.  Switch to an existing local branch
without resetting it, or create a tracking branch when it does not exist."
  (interactive)
  (unless bitbucket-devops-pull-requests-ui--context
    (user-error "This buffer is not associated with a Bitbucket repository"))
  (let* ((context bitbucket-devops-pull-requests-ui--context)
         (pull-request (bitbucket-devops-pull-requests-ui--current-pull-request))
         (branch (bitbucket-devops-pull-requests-source-branch pull-request))
         (remote (plist-get context :remote))
         (local-ref (format "refs/heads/%s" branch))
         (remote-ref (format "refs/remotes/%s/%s" remote branch))
         (refspec
          (format "+refs/heads/%s:%s" branch remote-ref)))
    (unless (and (stringp branch) (not (string-empty-p branch)))
      (user-error "The pull request does not have a source branch"))
    (bitbucket-devops-pull-requests-ui--validate-checkout-target
     context remote branch)
    (bitbucket-devops-pull-requests-ui--git-call
     context "fetch" "--no-tags" remote refspec)
    (if (bitbucket-devops-pull-requests-ui--git-ref-exists-p context local-ref)
        (bitbucket-devops-pull-requests-ui--git-call
         context "switch" "--" branch)
      (bitbucket-devops-pull-requests-ui--git-call
       context "switch" "--track" "-c" branch remote-ref))
    (setq bitbucket-devops-pull-requests-ui--context
          (plist-put (copy-sequence context) :branch branch))
    (message "Switched to pull request branch %s" branch)))

(defun bitbucket-devops-pull-requests-ui--diff-buffer-name
    (context pull-request-id)
  "Return the diff buffer name for CONTEXT and PULL-REQUEST-ID."
  (format
   "*Bitbucket Pull Request Diff: %s/%s#%s*"
   (plist-get context :workspace)
   (plist-get context :repo-slug)
   pull-request-id))

(defun bitbucket-devops-pull-requests-ui--diff-header-line
    (context pull-request-id &optional file-count)
  "Return a styled diff header for CONTEXT and PULL-REQUEST-ID.
Optional FILE-COUNT is shown in the header when non-nil."
  (append
   (list
    " "
    (bitbucket-devops-pull-requests-ui--style
     (format "%s/%s"
             (plist-get context :workspace)
             (plist-get context :repo-slug))
     'bitbucket-devops-pull-requests-header-face)
    (bitbucket-devops-pull-requests-ui--header-separator)
    (bitbucket-devops-pull-requests-ui--style
     (format "PR #%s" pull-request-id)
     'bitbucket-devops-pull-requests-id-face)
    (bitbucket-devops-pull-requests-ui--header-separator)
    (bitbucket-devops-pull-requests-ui--style
     "Changed files" 'bitbucket-devops-pull-requests-title-face))
   (when file-count
     (list
      (bitbucket-devops-pull-requests-ui--header-separator)
      (bitbucket-devops-pull-requests-ui--style
       (format "%s %s" file-count (if (= file-count 1) "file" "files"))
       'bitbucket-devops-pull-requests-count-face)))
   (list
    (bitbucket-devops-pull-requests-ui--header-separator)
    (bitbucket-devops-pull-requests-ui--style
     "i comment  r refresh  - back"
     'bitbucket-devops-pull-requests-secondary-face))))

(define-derived-mode bitbucket-devops-pull-requests-diff-mode diff-mode
  "Bitbucket-PR-Diff"
  "Major mode for a Bitbucket Cloud pull request diff."
  (setq-local line-spacing 0.05)
  (font-lock-add-keywords
   nil
   '(("^diff --git .*$" 0 'bitbucket-devops-pull-requests-diff-file-face t)
     ("^@@ .*$" 0 'bitbucket-devops-pull-requests-diff-hunk-face t)
     ("^new file mode .*$" 0 'bitbucket-devops-pull-requests-added-face t)
     ("^deleted file mode .*$" 0 'bitbucket-devops-pull-requests-removed-face t)
     ("^rename \\(?:from\\|to\\) .*$" 0 'bitbucket-devops-pull-requests-renamed-face t)
     ("^similarity index .*$" 0 'bitbucket-devops-pull-requests-success-face t)
     ("^index .*$" 0 'bitbucket-devops-pull-requests-secondary-face t)
     ("^--- .*$" 0 'bitbucket-devops-pull-requests-removed-face t)
     ("^\\+\\+\\+ .*$" 0 'bitbucket-devops-pull-requests-added-face t))
   'append))

(define-derived-mode bitbucket-devops-pull-requests-commits-mode special-mode
  "Bitbucket-PR-Commits"
  "Major mode for Bitbucket Cloud pull request commits."
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local line-spacing 0.1)
  (when (fboundp 'hl-line-mode)
    (hl-line-mode 1)))

(define-derived-mode bitbucket-devops-pull-requests-activity-mode special-mode
  "Bitbucket-PR-Activity"
  "Major mode for Bitbucket Cloud pull request activity."
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local line-spacing 0.1)
  (when (fboundp 'hl-line-mode)
    (hl-line-mode 1)))

(defvar bitbucket-devops-pull-requests-ui--applied-keybindings nil
  "Configured keys currently installed in pull request maps.")

(defvar bitbucket-devops-pull-requests-ui--applied-evil-keybindings nil
  "Configured keys currently installed in Evil pull request maps.")

(defun bitbucket-devops-pull-requests-ui--detail-bindings ()
  "Return configured detail bindings including action prefixes."
  (append
   bitbucket-devops-pull-requests-detail-keybindings
   (list
    (cons bitbucket-devops-pull-requests-task-prefix-key
          bitbucket-devops-pull-requests-task-prefix-map)
    (cons bitbucket-devops-pull-requests-metadata-prefix-key
          bitbucket-devops-pull-requests-metadata-prefix-map))))

(defun bitbucket-devops-pull-requests-ui--apply-map-bindings
    (name map bindings)
  "Replace configured BINDINGS for MAP tracked under NAME."
  (dolist (key (alist-get name bitbucket-devops-pull-requests-ui--applied-keybindings))
    (define-key map (kbd key) nil))
  (dolist (binding bindings)
    (define-key map (kbd (car binding)) (cdr binding)))
  (setf (alist-get name bitbucket-devops-pull-requests-ui--applied-keybindings)
        (mapcar #'car bindings)))

(defun bitbucket-devops-pull-requests-ui--clear-unconfigured-map-bindings
    (map bindings keys)
  "Clear stale KEYS from MAP when absent from configured BINDINGS."
  (dolist (key keys)
    (unless (assoc key bindings)
      (define-key map (kbd key) nil))))

(defun bitbucket-devops-pull-requests-ui--evil-bindings (bindings)
  "Return flattened Evil arguments for BINDINGS."
  (apply
   #'append
   (mapcar
    (lambda (binding) (list (kbd (car binding)) (cdr binding)))
    bindings)))

(defun bitbucket-devops-pull-requests-ui--evil-universal-argument-bindings ()
  "Return Evil bindings that emulate regular Emacs prefix arguments."
  (mapcar
   (lambda (key) (cons key #'universal-argument))
   bitbucket-devops-pull-requests-evil-universal-argument-keybindings))

(defun bitbucket-devops-pull-requests-ui--install-evil-map-bindings
    (name map bindings)
  "Replace Evil normal-state BINDINGS in MAP tracked under NAME."
  (setq bindings
        (append
         (bitbucket-devops-pull-requests-ui--evil-universal-argument-bindings)
         bindings))
  (dolist
      (key (alist-get name bitbucket-devops-pull-requests-ui--applied-evil-keybindings))
    (evil-define-key* 'normal map (kbd key) nil))
  (apply
   #'evil-define-key*
   (append
    (list 'normal map)
    (bitbucket-devops-pull-requests-ui--evil-bindings bindings)))
  (setf (alist-get name bitbucket-devops-pull-requests-ui--applied-evil-keybindings)
        (mapcar #'car bindings)))

(defun bitbucket-devops-pull-requests-ui--clear-unconfigured-evil-bindings
    (map bindings keys)
  "Clear stale Evil normal-state KEYS from MAP when absent from BINDINGS."
  (dolist (key keys)
    (unless (assoc key bindings)
      (evil-define-key* 'normal map (kbd key) nil))))

(defun bitbucket-devops-pull-requests-ui-apply-keybindings ()
  "Apply configured pull request bindings to non-Evil and Evil maps."
  (interactive)
  (bitbucket-devops-pull-requests-ui--apply-map-bindings
   'list bitbucket-devops-pull-requests-list-mode-map
   bitbucket-devops-pull-requests-list-keybindings)
  (bitbucket-devops-pull-requests-ui--clear-unconfigured-map-bindings
   bitbucket-devops-pull-requests-list-mode-map
   bitbucket-devops-pull-requests-list-keybindings
   '("b" "B" "t" "w" "W"))
  (bitbucket-devops-pull-requests-ui--apply-map-bindings
   'detail bitbucket-devops-pull-requests-detail-mode-map
   (bitbucket-devops-pull-requests-ui--detail-bindings))
  (bitbucket-devops-pull-requests-ui--clear-unconfigured-map-bindings
   bitbucket-devops-pull-requests-detail-mode-map
   bitbucket-devops-pull-requests-detail-keybindings
   '("b" "B" "I" "K"))
  (bitbucket-devops-pull-requests-ui--apply-map-bindings
   'diff bitbucket-devops-pull-requests-diff-mode-map
   bitbucket-devops-pull-requests-diff-keybindings)
  (bitbucket-devops-pull-requests-ui--apply-map-bindings
   'commits bitbucket-devops-pull-requests-commits-mode-map
   (append bitbucket-devops-pull-requests-commits-keybindings
           bitbucket-devops-pull-requests-subview-keybindings))
  (bitbucket-devops-pull-requests-ui--apply-map-bindings
   'activity bitbucket-devops-pull-requests-activity-mode-map
   bitbucket-devops-pull-requests-subview-keybindings)
  (bitbucket-devops-pull-requests-ui--apply-map-bindings
   'tasks bitbucket-devops-pull-requests-task-prefix-map
   bitbucket-devops-pull-requests-task-keybindings)
  (bitbucket-devops-pull-requests-ui--apply-map-bindings
   'metadata bitbucket-devops-pull-requests-metadata-prefix-map
   bitbucket-devops-pull-requests-metadata-keybindings)
  (when (and (featurep 'evil)
             (fboundp 'bitbucket-devops-pull-requests-ui--install-evil-bindings))
    (bitbucket-devops-pull-requests-ui--install-evil-bindings)))

(bitbucket-devops-pull-requests-ui-apply-keybindings)

(defun bitbucket-devops-pull-requests-ui--subview-buffer-name
    (kind context pull-request-id)
  "Return a KIND buffer name for PULL-REQUEST-ID in CONTEXT."
  (format
   "*Bitbucket Pull Request %s: %s/%s#%s*"
   kind
   (plist-get context :workspace)
   (plist-get context :repo-slug)
   pull-request-id))

(defun bitbucket-devops-pull-requests-ui--insert-subview-heading (kind)
  "Insert a styled KIND heading for the current pull request subview."
  (insert
   (bitbucket-devops-pull-requests-ui--style
    (format "#%s" bitbucket-devops-pull-requests-ui--details-pull-request-id)
    'bitbucket-devops-pull-requests-id-face)
   "  "
   (bitbucket-devops-pull-requests-ui--style
    kind 'bitbucket-devops-pull-requests-heading-face)
   "\n"
   (bitbucket-devops-pull-requests-ui--style
    (format
     "%s/%s"
     (or (plist-get bitbucket-devops-pull-requests-ui--context :workspace) "")
     (or (plist-get bitbucket-devops-pull-requests-ui--context :repo-slug) ""))
    'bitbucket-devops-pull-requests-secondary-face)
   "\n\n"))

(defun bitbucket-devops-pull-requests-ui--render-commits (commits &optional preserve-point)
  "Render COMMITS in the current pull request commits buffer.
When PRESERVE-POINT is non-nil, restore point afterwards."
  (let ((position (and preserve-point (point)))
        (inhibit-read-only t))
    (setq-local header-line-format
                (bitbucket-devops-pull-requests-ui--subview-header-line
                 "Commits" (length commits)))
    (erase-buffer)
    (bitbucket-devops-pull-requests-ui--insert-subview-heading "Commits")
    (if commits
        (cl-loop
         for commit in commits
         for index from 1
         do
         (let* ((row-start (point))
                (hash (or (alist-get 'hash commit) "Unknown hash"))
                (author
                 (or (bitbucket-devops-pull-requests--nested-get
                      commit 'author 'raw)
                     "Unknown"))
                (date
                 (bitbucket-devops-pull-requests-ui--format-time
                  (alist-get 'date commit))))
           (insert
            (bitbucket-devops-pull-requests-ui--style
             (format "%2d" index) 'bitbucket-devops-pull-requests-count-face)
            (bitbucket-devops-pull-requests-ui--style
             "  o  " 'bitbucket-devops-pull-requests-timeline-face)
            (bitbucket-devops-pull-requests-ui--style
             hash 'bitbucket-devops-pull-requests-commit-face)
            "  "
            (bitbucket-devops-pull-requests-ui--style
             (string-trim
              (car
               (split-string
                (or (alist-get 'message commit) "No message") "\n")))
             'bitbucket-devops-pull-requests-message-face)
            "\n"
            (bitbucket-devops-pull-requests-ui--style
             "    Author: " 'bitbucket-devops-pull-requests-field-label-face)
            (bitbucket-devops-pull-requests-ui--style
             author 'bitbucket-devops-pull-requests-author-face)
            (bitbucket-devops-pull-requests-ui--style
             "    Date: " 'bitbucket-devops-pull-requests-field-label-face)
            (bitbucket-devops-pull-requests-ui--style
             date 'bitbucket-devops-pull-requests-secondary-face)
            "\n"
            (bitbucket-devops-pull-requests-ui--style
             (make-string 72 ?-)
             'bitbucket-devops-pull-requests-secondary-face)
            "\n")
           (add-text-properties
            row-start
            (point)
            (list 'bitbucket-devops-pull-requests-commit commit
                  'bitbucket-devops-pull-requests-commit-hash hash
                  'mouse-face 'highlight
                  'help-echo "Open this commit"
                  'follow-link t))))
      (bitbucket-devops-pull-requests-ui--insert-empty "No commits loaded."))
    (goto-char (if position (min position (point-max)) (point-min)))))

(defun bitbucket-devops-pull-requests-ui--commit-property-at-point (property)
  "Return commit PROPERTY at point or immediately before point."
  (or (get-text-property (point) property)
      (and (> (point) (point-min))
           (get-text-property (1- (point)) property))))

(defun bitbucket-devops-pull-requests-ui--ensure-commit-available (context hash)
  "Ensure HASH is available in the local Git repository for CONTEXT."
  (unless (bitbucket-devops-pull-requests-ui--git-commit-exists-p context hash)
    (let* ((pull-request bitbucket-devops-pull-requests-ui--details-pull-request)
           (branch (and pull-request
                        (bitbucket-devops-pull-requests-source-branch pull-request)))
           (remote (plist-get context :remote)))
      (unless (and (stringp branch) (not (string-empty-p branch)))
        (user-error
         "Commit %s is not local and the pull request source branch is unknown"
         hash))
      (bitbucket-devops-pull-requests-ui--validate-checkout-target
       context remote branch)
      (message "Fetching pull request branch %s..." branch)
      (bitbucket-devops-pull-requests-ui--git-call
       context
       "fetch"
       "--no-tags"
       remote
       (format "+refs/heads/%s:refs/remotes/%s/%s"
               branch remote branch))
      (unless (bitbucket-devops-pull-requests-ui--git-commit-exists-p context hash)
        (user-error "Commit %s was not found after fetching %s" hash branch)))))

(defun bitbucket-devops-pull-requests-ui-open-commit-at-point ()
  "Open the pull request commit at point in a Magit revision buffer."
  (interactive)
  (unless (derived-mode-p 'bitbucket-devops-pull-requests-commits-mode)
    (user-error "This command requires a Bitbucket pull request commits buffer"))
  (let ((hash
         (bitbucket-devops-pull-requests-ui--commit-property-at-point
          'bitbucket-devops-pull-requests-commit-hash))
        (context bitbucket-devops-pull-requests-ui--context))
    (unless hash
      (user-error "No Bitbucket pull request commit at point"))
    (unless context
      (user-error "This buffer is not associated with a Bitbucket repository"))
    (bitbucket-devops-pull-requests-ui--ensure-commit-available context hash)
    (unless (or (fboundp 'magit-show-commit)
                (require 'magit-diff nil t))
      (user-error "Magit is required to display commit changes"))
    (let ((default-directory (plist-get context :root)))
      (magit-show-commit hash)
      (bitbucket-devops-ui--delete-command-panel))))

(defun bitbucket-devops-pull-requests-ui-open-commit-at-mouse (event)
  "Open the pull request commit clicked in mouse EVENT."
  (interactive "e")
  (mouse-set-point event)
  (bitbucket-devops-pull-requests-ui-open-commit-at-point))

(defun bitbucket-devops-pull-requests-ui-open-commits ()
  "Open the loaded commits for the current pull request."
  (interactive)
  (pcase-let ((`(,context ,pull-request-id)
               (bitbucket-devops-pull-requests-ui--require-details-context)))
    (let ((previous (current-buffer))
          (commits bitbucket-devops-pull-requests-ui--details-commits)
          (pull-request bitbucket-devops-pull-requests-ui--details-pull-request)
          (buffer
           (get-buffer-create
            (bitbucket-devops-pull-requests-ui--subview-buffer-name
             "Commits" context pull-request-id))))
      (with-current-buffer buffer
        (bitbucket-devops-pull-requests-commits-mode)
        (setq-local bitbucket-devops-pull-requests-ui--context context)
        (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id
                    pull-request-id)
        (setq-local bitbucket-devops-pull-requests-ui--details-pull-request
                    pull-request)
        (bitbucket-devops-pull-requests-ui--render-commits commits))
      (bitbucket-devops-ui--display-buffer buffer t previous))))

(defun bitbucket-devops-pull-requests-ui-refresh-commits ()
  "Reload commits for the current pull request commits buffer."
  (interactive)
  (pcase-let ((`(,context ,pull-request-id)
               (bitbucket-devops-pull-requests-ui--require-details-context)))
    (let ((buffer (current-buffer)))
      (bitbucket-devops-pull-requests-ui--collect-pages
       #'bitbucket-devops-pull-requests-rest-list-commits
       context
       pull-request-id
       (lambda (commits error)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (if error
                 (message "Unable to refresh Bitbucket pull request commits: %s"
                          (or (plist-get error :message) error))
               (bitbucket-devops-pull-requests-ui--render-commits commits t)
               (message "Refreshed Bitbucket pull request commits")))))))))

(defun bitbucket-devops-pull-requests-ui--render-activity
    (activities &optional preserve-point)
  "Render ACTIVITIES in the current pull request activity buffer.
When PRESERVE-POINT is non-nil, restore point afterwards."
  (let ((position (and preserve-point (point)))
        (inhibit-read-only t))
    (setq-local header-line-format
                (bitbucket-devops-pull-requests-ui--subview-header-line
                 "Activity" (length activities)))
    (erase-buffer)
    (bitbucket-devops-pull-requests-ui--insert-subview-heading "Activity")
    (if activities
        (cl-loop
         for activity in activities
         for index from 1
         do
         (insert
          (bitbucket-devops-pull-requests-ui--style
           (format "%2d" index) 'bitbucket-devops-pull-requests-count-face)
          (bitbucket-devops-pull-requests-ui--style
           "  o  " 'bitbucket-devops-pull-requests-timeline-face)
          (bitbucket-devops-pull-requests-ui--activity-line activity)
          "\n"))
      (bitbucket-devops-pull-requests-ui--insert-empty "No activity loaded."))
    (goto-char (if position (min position (point-max)) (point-min)))))

(defun bitbucket-devops-pull-requests-ui-open-activity ()
  "Open the loaded activity for the current pull request."
  (interactive)
  (pcase-let ((`(,context ,pull-request-id)
               (bitbucket-devops-pull-requests-ui--require-details-context)))
    (let ((previous (current-buffer))
          (activities bitbucket-devops-pull-requests-ui--details-activity)
          (buffer
           (get-buffer-create
            (bitbucket-devops-pull-requests-ui--subview-buffer-name
             "Activity" context pull-request-id))))
      (with-current-buffer buffer
        (bitbucket-devops-pull-requests-activity-mode)
        (setq-local bitbucket-devops-pull-requests-ui--context context)
        (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id
                    pull-request-id)
        (bitbucket-devops-pull-requests-ui--render-activity activities))
      (bitbucket-devops-ui--display-buffer buffer t previous))))

(defun bitbucket-devops-pull-requests-ui-refresh-activity ()
  "Reload activity for the current pull request activity buffer."
  (interactive)
  (pcase-let ((`(,context ,pull-request-id)
               (bitbucket-devops-pull-requests-ui--require-details-context)))
    (let ((buffer (current-buffer)))
      (bitbucket-devops-pull-requests-ui--collect-pages
       #'bitbucket-devops-pull-requests-rest-list-activity
       context
       pull-request-id
       (lambda (activities error)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (if error
                 (message "Unable to refresh Bitbucket pull request activity: %s"
                          (or (plist-get error :message) error))
               (bitbucket-devops-pull-requests-ui--render-activity activities t)
               (message "Refreshed Bitbucket pull request activity")))))))))

(defun bitbucket-devops-pull-requests-ui--replace-diff (diff-text &optional preserve-point)
  "Replace the current diff with DIFF-TEXT.
When PRESERVE-POINT is non-nil, restore point afterwards."
  (let ((position (and preserve-point (point)))
        (inhibit-read-only t))
    (erase-buffer)
    (insert (or diff-text ""))
    (setq-local
     header-line-format
     (bitbucket-devops-pull-requests-ui--diff-header-line
      bitbucket-devops-pull-requests-ui--context
      bitbucket-devops-pull-requests-ui--details-pull-request-id
      (save-excursion
        (goto-char (point-min))
        (how-many "^diff --git "))))
    (goto-char (if position (min position (point-max)) (point-min)))
    (font-lock-flush)))

(defun bitbucket-devops-pull-requests-ui--show-diff
    (context pull-request-id diff-text previous-buffer)
  "Show DIFF-TEXT for PULL-REQUEST-ID in CONTEXT.

PREVIOUS-BUFFER is the pull request detail buffer used by the back command."
  (let ((buffer
         (get-buffer-create
          (bitbucket-devops-pull-requests-ui--diff-buffer-name
           context
           pull-request-id))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (bitbucket-devops-pull-requests-diff-mode)
        (setq-local bitbucket-devops-pull-requests-ui--context context)
        (setq-local bitbucket-devops-pull-requests-ui--details-pull-request-id
                    pull-request-id)
        (setq-local header-line-format
                    (bitbucket-devops-pull-requests-ui--diff-header-line
                     context pull-request-id))
        (setq-local buffer-read-only t)
        (bitbucket-devops-pull-requests-ui--replace-diff diff-text)))
    (bitbucket-devops-ui--display-buffer
     buffer
     t
     previous-buffer)))

(defun bitbucket-devops-pull-requests-ui--require-diff-pull-request ()
  "Return context, ID, and loaded pull request for a diff command."
  (unless (and bitbucket-devops-pull-requests-ui--context
               bitbucket-devops-pull-requests-ui--details-pull-request-id
               bitbucket-devops-pull-requests-ui--details-pull-request)
    (user-error "This buffer is not associated with a Bitbucket pull request"))
  (list bitbucket-devops-pull-requests-ui--context
        bitbucket-devops-pull-requests-ui--details-pull-request-id
        bitbucket-devops-pull-requests-ui--details-pull-request))

(defun bitbucket-devops-pull-requests-ui--open-bitbucket-diff ()
  "Open Bitbucket's raw patch for the current pull request."
  (pcase-let ((`(,context ,pull-request-id ,_pull-request)
               (bitbucket-devops-pull-requests-ui--require-diff-pull-request)))
    (let ((details-buffer (current-buffer)))
      (bitbucket-devops-pull-requests-rest-get-diff
       context
       pull-request-id
       (lambda (diff-text error)
         (if error
             (message "Unable to load Bitbucket pull request diff: %s"
                      (or (plist-get error :message) error))
           (bitbucket-devops-pull-requests-ui--show-diff
            context
            pull-request-id
            diff-text
            details-buffer)))))))

(defun bitbucket-devops-pull-requests-ui--open-magit-diff ()
  "Open the current pull request as a Magit three-dot range."
  (pcase-let* ((`(,context ,_pull-request-id ,pull-request)
                (bitbucket-devops-pull-requests-ui--require-diff-pull-request))
               (`(,destination ,source)
                (bitbucket-devops-pull-requests-ui--ensure-pull-request-revisions
                 context pull-request)))
    (unless (or (fboundp 'magit-diff-range)
                (require 'magit-diff nil t))
      (user-error "Magit is required to display a Magit pull request diff"))
    (let ((default-directory (plist-get context :root)))
      (magit-diff-range (format "%s...%s" destination source)))))

(defun bitbucket-devops-pull-requests-ui--diffstat-entry-label (entry index)
  "Return a completion label for diffstat ENTRY at INDEX."
  (let ((status (or (alist-get 'status entry) "modified"))
        (old-path (bitbucket-devops-pull-requests--nested-get entry 'old 'path))
        (new-path (bitbucket-devops-pull-requests--nested-get entry 'new 'path)))
    (format
     "%d. %-8s %s"
     index
     status
     (if (and old-path new-path (not (equal old-path new-path)))
         (format "%s -> %s" old-path new-path)
       (or new-path old-path "unknown")))))

(defun bitbucket-devops-pull-requests-ui--read-ediff-entry (diffstat)
  "Read and return one changed-file entry from DIFFSTAT."
  (unless diffstat
    (user-error "No changed files are loaded for this pull request"))
  (let* ((choices
          (cl-loop
           for entry in diffstat
           for index from 1
           collect
           (cons
            (bitbucket-devops-pull-requests-ui--diffstat-entry-label entry index)
            entry)))
         (selected
          (completing-read
           "Ediff changed file: "
           choices
           nil
           t)))
    (cdr (assoc selected choices))))

(defun bitbucket-devops-pull-requests-ui--git-file-content
    (context revision path)
  "Return PATH contents at Git REVISION in repository CONTEXT.

Return an empty string when PATH is nil, as for an added or deleted side."
  (if path
      (bitbucket-devops-pull-requests-ui--git-call-raw
       context "show" (format "%s:%s" revision path))
    ""))

(defun bitbucket-devops-pull-requests-ui--ediff-buffer
    (context pull-request-id side path content)
  "Create an Ediff buffer for SIDE PATH and CONTENT in CONTEXT.
PULL-REQUEST-ID identifies the pull request."
  (let ((buffer
         (generate-new-buffer
          (format
           "*Bitbucket PR #%s %s: %s*"
           pull-request-id side (or path "(empty)")))))
    (with-current-buffer buffer
      (insert content)
      (when path
        (setq-local
         buffer-file-name
         (expand-file-name path (plist-get context :root)))
        (set-auto-mode)
        (setq-local buffer-file-name nil))
      (setq-local buffer-read-only t)
      (set-buffer-modified-p nil))
    buffer))

(defun bitbucket-devops-pull-requests-ui--open-ediff ()
  "Compare one changed pull request file using Ediff."
  (pcase-let* ((`(,context ,pull-request-id ,pull-request)
                (bitbucket-devops-pull-requests-ui--require-diff-pull-request))
               (`(,destination ,source)
                (bitbucket-devops-pull-requests-ui--ensure-pull-request-revisions
                 context pull-request))
               (merge-base
                (bitbucket-devops-pull-requests-ui--git-call
                 context "merge-base" destination source))
               (entry
                (bitbucket-devops-pull-requests-ui--read-ediff-entry
                 bitbucket-devops-pull-requests-ui--details-diffstat))
               (old-path
                (bitbucket-devops-pull-requests--nested-get entry 'old 'path))
               (new-path
                (bitbucket-devops-pull-requests--nested-get entry 'new 'path))
               (before
                (bitbucket-devops-pull-requests-ui--ediff-buffer
                 context
                 pull-request-id
                 "base"
                 old-path
                 (bitbucket-devops-pull-requests-ui--git-file-content
                  context merge-base old-path)))
               (after
                (bitbucket-devops-pull-requests-ui--ediff-buffer
                 context
                 pull-request-id
                 "source"
                 new-path
                 (bitbucket-devops-pull-requests-ui--git-file-content
                  context source new-path)))
               (buffers (list before after)))
    (unless (or (fboundp 'ediff-buffers)
                (require 'ediff nil t))
      (mapc #'kill-buffer buffers)
      (user-error "Ediff is unavailable"))
    (ediff-buffers
     before
     after
     (list
      (lambda ()
        (let ((temporary-buffers buffers))
          (add-hook
           'ediff-after-quit-hook-internal
           (lambda ()
             (dolist (buffer temporary-buffers)
               (when (buffer-live-p buffer)
                 (kill-buffer buffer))))
           nil
           t)))))))

(defun bitbucket-devops-pull-requests-ui-open-diff (&optional viewer)
  "Open the current pull request using VIEWER.

When VIEWER is nil, use `bitbucket-devops-pull-requests-diff-viewer'."
  (interactive)
  (pcase (or viewer bitbucket-devops-pull-requests-diff-viewer)
    ('bitbucket (bitbucket-devops-pull-requests-ui--open-bitbucket-diff))
    ('magit (bitbucket-devops-pull-requests-ui--open-magit-diff))
    ('ediff (bitbucket-devops-pull-requests-ui--open-ediff))
    (other (user-error "Unsupported pull request diff viewer: %s" other))))

(defun bitbucket-devops-pull-requests-ui-choose-diff-viewer ()
  "Prompt for a viewer and open the current pull request diff."
  (interactive)
  (let* ((choices
          '(("Bitbucket patch" . bitbucket)
            ("Magit range diff" . magit)
            ("Ediff changed file" . ediff)))
         (choice
          (completing-read "Pull request diff viewer: " choices nil t)))
    (bitbucket-devops-pull-requests-ui-open-diff (cdr (assoc choice choices)))))

(defun bitbucket-devops-pull-requests-ui-refresh-diff ()
  "Reload the current pull request diff in place."
  (interactive)
  (pcase-let ((`(,context ,pull-request-id)
               (bitbucket-devops-pull-requests-ui--require-details-context)))
    (let ((buffer (current-buffer)))
      (bitbucket-devops-pull-requests-rest-get-diff
       context
       pull-request-id
       (lambda (diff-text error)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (if error
                 (message "Unable to refresh Bitbucket pull request diff: %s"
                          (or (plist-get error :message) error))
               (bitbucket-devops-pull-requests-ui--replace-diff diff-text t)
               (message "Refreshed Bitbucket pull request diff")))))))))

(defun bitbucket-devops-pull-requests-ui-refresh-current ()
  "Refresh the current pull request UI buffer from Bitbucket."
  (interactive)
  (cond
   ((derived-mode-p 'bitbucket-devops-pull-requests-list-mode)
    (bitbucket-devops-pull-requests-ui-refresh))
   ((derived-mode-p 'bitbucket-devops-pull-requests-detail-mode)
    (bitbucket-devops-pull-requests-ui-refresh-details))
   ((derived-mode-p 'bitbucket-devops-pull-requests-diff-mode)
    (bitbucket-devops-pull-requests-ui-refresh-diff))
   ((derived-mode-p 'bitbucket-devops-pull-requests-commits-mode)
    (bitbucket-devops-pull-requests-ui-refresh-commits))
   ((derived-mode-p 'bitbucket-devops-pull-requests-activity-mode)
    (bitbucket-devops-pull-requests-ui-refresh-activity))
   (t
    (user-error "This is not a refreshable Bitbucket pull request buffer"))))

(defun bitbucket-devops-pull-requests-ui--require-details-context ()
  "Return the current detail buffer context and pull request ID.

Signal a `user-error' outside a Bitbucket pull request detail buffer."
  (unless (and bitbucket-devops-pull-requests-ui--context
               bitbucket-devops-pull-requests-ui--details-pull-request-id)
    (user-error "This buffer is not associated with a Bitbucket pull request"))
  (list bitbucket-devops-pull-requests-ui--context
        bitbucket-devops-pull-requests-ui--details-pull-request-id))

(defun bitbucket-devops-pull-requests-ui--action-callback (buffer success-message)
  "Return a mutation callback for BUFFER and SUCCESS-MESSAGE."
  (lambda (_result error)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (if error
            (message "Bitbucket pull request action failed: %s"
                     (or (plist-get error :message) error))
          (message "%s" success-message)
          (bitbucket-devops-pull-requests-ui-refresh-details))))))

(defun bitbucket-devops-pull-requests-ui--run-action (rest-function success-message)
  "Call REST-FUNCTION for the current PR and report SUCCESS-MESSAGE."
  (pcase-let ((`(,context ,pull-request-id)
               (bitbucket-devops-pull-requests-ui--require-details-context)))
    (funcall
     rest-function
     context
     pull-request-id
     (bitbucket-devops-pull-requests-ui--action-callback
      (current-buffer)
      success-message))))

(defun bitbucket-devops-pull-requests-ui-approve ()
  "Approve the current pull request."
  (interactive)
  (bitbucket-devops-pull-requests-ui--run-action
   #'bitbucket-devops-pull-requests-rest-approve
   "Approved Bitbucket pull request"))

(defun bitbucket-devops-pull-requests-ui-remove-approval ()
  "Remove the current user's approval from the current pull request."
  (interactive)
  (bitbucket-devops-pull-requests-ui--run-action
   #'bitbucket-devops-pull-requests-rest-remove-approval
   "Removed Bitbucket pull request approval"))

(defun bitbucket-devops-pull-requests-ui-request-changes ()
  "Request changes on the current pull request."
  (interactive)
  (bitbucket-devops-pull-requests-ui--run-action
   #'bitbucket-devops-pull-requests-rest-request-changes
   "Requested changes on Bitbucket pull request"))

(defun bitbucket-devops-pull-requests-ui-remove-request-changes ()
  "Remove the current user's request-changes state."
  (interactive)
  (bitbucket-devops-pull-requests-ui--run-action
   #'bitbucket-devops-pull-requests-rest-remove-request-changes
   "Removed Bitbucket pull request change request"))

(defun bitbucket-devops-pull-requests-ui--create-comment (text &optional parent-id)
  "Create a current-PR comment with TEXT and optional PARENT-ID."
  (pcase-let ((`(,context ,pull-request-id)
               (bitbucket-devops-pull-requests-ui--require-details-context)))
    (bitbucket-devops-pull-requests-rest-create-comment
     context
     pull-request-id
     text
     (bitbucket-devops-pull-requests-ui--action-callback
      (current-buffer)
      (if parent-id
          "Replied to Bitbucket pull request comment"
        "Added Bitbucket pull request comment"))
     parent-id)))

(defun bitbucket-devops-pull-requests-ui-add-comment (text)
  "Add TEXT as a comment on the current pull request."
  (interactive (list (read-string "Pull request comment: ")))
  (bitbucket-devops-pull-requests-ui--create-comment text))

(defun bitbucket-devops-pull-requests-ui--normalize-diff-path (path)
  "Return Bitbucket PATH from a unified diff file header."
  (let ((path (string-trim (or path ""))))
    (unless (or (string-empty-p path) (equal path "/dev/null"))
      (replace-regexp-in-string "\\`[ab]/" "" path))))

(defun bitbucket-devops-pull-requests-ui--diff-header-paths ()
  "Return old and new file paths for the current unified diff hunk."
  (let ((file-start
         (save-excursion
           (when (re-search-backward
                  (rx line-start "diff --git ")
                  nil
                  t)
             (line-beginning-position))))
        old-path
        new-path)
    (save-excursion
      (when (re-search-backward
             (rx line-start "+++ " (group (+ nonl)) line-end)
             file-start
             t)
        (setq new-path
              (bitbucket-devops-pull-requests-ui--normalize-diff-path
               (match-string 1))))
      (when (re-search-backward
             (rx line-start "--- " (group (+ nonl)) line-end)
             file-start
             t)
        (setq old-path
              (bitbucket-devops-pull-requests-ui--normalize-diff-path
               (match-string 1)))))
    (list old-path new-path)))

(defun bitbucket-devops-pull-requests-ui--diff-position-at-point ()
  "Return an inline comment plist for the unified diff line at point."
  (when (derived-mode-p 'bitbucket-devops-pull-requests-diff-mode 'diff-mode)
    (save-excursion
      (let ((target-line-start (line-beginning-position))
            old-line
            new-line
            hunk-end
            old-path
            new-path)
        (when
            (re-search-backward
             (rx line-start
                 "@@ -"
                 (group (+ digit))
                 (? "," (+ digit))
                 " +"
                 (group (+ digit))
                 (? "," (+ digit))
                 " @@")
             nil
             t)
          (setq old-line (string-to-number (match-string 1))
                new-line (string-to-number (match-string 2))
                hunk-end (line-end-position))
          (pcase-let ((`(,old ,new)
                       (bitbucket-devops-pull-requests-ui--diff-header-paths)))
            (setq old-path old
                  new-path new))
          (goto-char (1+ hunk-end))
          (while (< (point) target-line-start)
            (pcase (char-after)
              (?+ (setq new-line (1+ new-line)))
              (?- (setq old-line (1+ old-line)))
              (?\s (setq old-line (1+ old-line)
                         new-line (1+ new-line))))
            (forward-line 1))
          (pcase (char-after target-line-start)
            (?+
             (when new-path
               (list :path new-path :to new-line)))
            (?-
             (when old-path
               (list :path old-path :from old-line)))
            (?\s
             (when (or new-path old-path)
               (list :path (or new-path old-path) :to new-line)))))))))

(defun bitbucket-devops-pull-requests-ui--diff-file-bounds-at-point ()
  "Return the current unified diff file section as (START . END)."
  (when (derived-mode-p 'bitbucket-devops-pull-requests-diff-mode 'diff-mode)
    (save-excursion
      (end-of-line)
      (when (re-search-backward (rx line-start "diff --git ") nil t)
        (let ((start (line-beginning-position)))
          (forward-line 1)
          (cons
           start
           (if (re-search-forward (rx line-start "diff --git ") nil t)
               (match-beginning 0)
             (point-max))))))))

(defun bitbucket-devops-pull-requests-ui--diff-first-position-in-current-file ()
  "Return the first inline-commentable location in the current file section."
  (when-let ((bounds
              (bitbucket-devops-pull-requests-ui--diff-file-bounds-at-point)))
    (save-excursion
      (save-restriction
        (narrow-to-region (car bounds) (cdr bounds))
        (goto-char (point-min))
        (let (in-hunk location)
          (while (and (not location) (not (eobp)))
            (cond
             ((looking-at-p (rx "@@ -"))
              (setq in-hunk t))
             ((and in-hunk
                   (memq (char-after) '(?+ ?- ?\s))
                   (not (looking-at-p (rx (or "+++ " "--- ")))))
              (setq location
                    (bitbucket-devops-pull-requests-ui--diff-position-at-point))))
            (forward-line 1))
          location)))))

(defun bitbucket-devops-pull-requests-ui--diffstat-path-candidates ()
  "Return repo-relative changed-file paths loaded for the current PR."
  (delq
   nil
   (mapcar
    (lambda (entry)
      (let ((path (bitbucket-devops-pull-requests-ui--diffstat-path entry)))
        (unless (or (string-empty-p path) (equal path "unknown"))
          path)))
    bitbucket-devops-pull-requests-ui--details-diffstat)))

(defun bitbucket-devops-pull-requests-ui--read-inline-path (default-path)
  "Read an inline comment file path, preferring DEFAULT-PATH."
  (let ((candidates
         (delete-dups
          (copy-sequence
           (append
            (when default-path (list default-path))
            (bitbucket-devops-pull-requests-ui--diffstat-path-candidates))))))
    (if candidates
        (completing-read
         "Inline file path, relative to repo root: "
         candidates
         nil
         nil
         nil
         nil
         default-path)
      (read-string
       "Inline file path, relative to repo root: "
       nil
       nil
       default-path))))

(defun bitbucket-devops-pull-requests-ui--read-inline-comment-arguments ()
  "Read arguments for creating an inline pull request comment."
  (bitbucket-devops-pull-requests-ui--require-details-context)
  (let* ((diff-buffer-p
          (derived-mode-p 'bitbucket-devops-pull-requests-diff-mode))
         (inferred
          (or (bitbucket-devops-pull-requests-ui--diff-position-at-point)
              (and diff-buffer-p
                   (bitbucket-devops-pull-requests-ui--diff-first-position-in-current-file))))
         (default-path (plist-get inferred :path))
         (default-side (if (plist-member inferred :from) "from" "to"))
         (default-line
          (or (plist-get inferred :from)
              (plist-get inferred :to)
              1)))
    (if diff-buffer-p
        (if (and inferred default-path)
            (list (read-string "Inline comment: ") inferred)
          (user-error
           (concat
            "This file has no inline-commentable line; pure renames and "
            "empty added/deleted files require a normal pull request comment")))
      (let* ((path (bitbucket-devops-pull-requests-ui--read-inline-path default-path))
             (side
              (completing-read
               "Inline side (to=new/destination, from=old/source): "
               '("to" "from")
               nil
               t
               nil
               nil
               default-side))
             (line
              (read-number
               "Inline line number on selected side: "
               default-line))
             (text (read-string "Inline comment: ")))
        (list
         text
         (if (equal side "from")
             (list :path path :from line)
           (list :path path :to line)))))))

(defun bitbucket-devops-pull-requests-ui--inline-comment-callback
    (buffer success-message)
  "Return a callback for inline comment creation in BUFFER.
SUCCESS-MESSAGE is reported when the request succeeds."
  (lambda (_result error)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (if error
            (message "Bitbucket pull request action failed: %s"
                     (or (plist-get error :message) error))
          (message "%s" success-message)
          (when (derived-mode-p 'bitbucket-devops-pull-requests-detail-mode)
            (bitbucket-devops-pull-requests-ui-refresh-details)))))))

(defun bitbucket-devops-pull-requests-ui-add-inline-comment (text inline-location)
  "Add TEXT as an inline comment at INLINE-LOCATION."
  (interactive (bitbucket-devops-pull-requests-ui--read-inline-comment-arguments))
  (pcase-let ((`(,context ,pull-request-id)
               (bitbucket-devops-pull-requests-ui--require-details-context)))
    (bitbucket-devops-pull-requests-rest-create-comment
     context
     pull-request-id
     text
     (bitbucket-devops-pull-requests-ui--inline-comment-callback
      (current-buffer)
      "Added Bitbucket pull request inline comment")
     nil
     inline-location)))

(defun bitbucket-devops-pull-requests-ui--comment-candidates (&optional predicate)
  "Return completion candidates for loaded comments matching PREDICATE."
  (mapcar
   (lambda (comment)
     (let* ((id (alist-get 'id comment))
            (author (bitbucket-devops-pull-requests-comment-author-name comment))
            (text (replace-regexp-in-string
                   "[\n\r]+"
                   " "
                   (bitbucket-devops-pull-requests-comment-text comment)))
            (preview (truncate-string-to-width text 70 nil nil t)))
       (cons
        (format
         "#%s%s %s: %s"
         id
         (if (bitbucket-devops-pull-requests-comment-resolved-p comment)
             " [resolved]"
           "")
         author
         preview)
        id)))
   (seq-filter
    (lambda (comment)
      (and (alist-get 'id comment)
           (not (alist-get 'deleted comment))
           (or (null predicate) (funcall predicate comment))))
    bitbucket-devops-pull-requests-ui--details-comments)))

(defun bitbucket-devops-pull-requests-ui--comment-for-selection
    (selection &optional predicate)
  "Return the loaded comment represented by SELECTION and PREDICATE."
  (when-let ((comment-id
              (cdr (assoc selection
                          (bitbucket-devops-pull-requests-ui--comment-candidates
                           predicate)))))
    (seq-find
     (lambda (comment) (equal (alist-get 'id comment) comment-id))
     bitbucket-devops-pull-requests-ui--details-comments)))

(defun bitbucket-devops-pull-requests-ui--comment-at-point ()
  "Return the loaded comment on the current detail line, or nil."
  (when-let ((comment-id
              (bitbucket-devops-pull-requests-ui--property-at-point-or-line
               'bitbucket-devops-pull-requests-comment-id)))
    (seq-find
     (lambda (comment) (equal (alist-get 'id comment) comment-id))
     bitbucket-devops-pull-requests-ui--details-comments)))

(defun bitbucket-devops-pull-requests-ui-reply-to-comment (selection text)
  "Reply with TEXT to comment SELECTION on the current pull request."
  (interactive
   (let* ((candidates (bitbucket-devops-pull-requests-ui--comment-candidates)))
     (unless candidates
       (user-error "No loaded Bitbucket pull request comments to reply to"))
     (let ((selection
            (completing-read "Reply to comment: " candidates nil t)))
       (list selection (read-string "Reply: ")))))
  (let ((parent-id
         (cdr (assoc selection
                     (bitbucket-devops-pull-requests-ui--comment-candidates)))))
    (unless parent-id
      (user-error "Unknown Bitbucket pull request comment"))
    (bitbucket-devops-pull-requests-ui--create-comment text parent-id)))

(defun bitbucket-devops-pull-requests-ui--run-comment-action
    (rest-function comment-id success-message)
  "Run REST-FUNCTION for COMMENT-ID and report SUCCESS-MESSAGE."
  (pcase-let ((`(,context ,pull-request-id)
               (bitbucket-devops-pull-requests-ui--require-details-context)))
    (funcall
     rest-function
     context
     pull-request-id
     comment-id
     (bitbucket-devops-pull-requests-ui--action-callback
      (current-buffer)
      success-message))))

(defun bitbucket-devops-pull-requests-ui--edit-comment (comment text)
  "Replace loaded COMMENT with TEXT."
  (pcase-let ((`(,context ,pull-request-id)
               (bitbucket-devops-pull-requests-ui--require-details-context)))
    (bitbucket-devops-pull-requests-rest-update-comment
     context
     pull-request-id
     (alist-get 'id comment)
     text
     (bitbucket-devops-pull-requests-ui--action-callback
      (current-buffer)
      "Updated Bitbucket pull request comment"))))

(defun bitbucket-devops-pull-requests-ui-edit-comment (selection text)
  "Replace comment SELECTION with TEXT."
  (interactive
   (let* ((candidates (bitbucket-devops-pull-requests-ui--comment-candidates)))
     (unless candidates
       (user-error "No loaded Bitbucket pull request comments to edit"))
     (let* ((selection
             (completing-read "Edit comment: " candidates nil t))
            (comment
             (bitbucket-devops-pull-requests-ui--comment-for-selection selection)))
       (list
        selection
        (read-string
         "Updated comment: "
         (bitbucket-devops-pull-requests-comment-text comment))))))
  (let ((comment
         (bitbucket-devops-pull-requests-ui--comment-for-selection selection)))
    (unless comment
      (user-error "Unknown Bitbucket pull request comment"))
    (bitbucket-devops-pull-requests-ui--edit-comment comment text)))

(defun bitbucket-devops-pull-requests-ui-edit-comment-at-point ()
  "Edit the pull request comment on the current detail line."
  (interactive)
  (unless (derived-mode-p 'bitbucket-devops-pull-requests-detail-mode)
    (user-error "This command requires a Bitbucket pull request detail buffer"))
  (let ((comment (bitbucket-devops-pull-requests-ui--comment-at-point)))
    (unless comment
      (user-error "No Bitbucket pull request comment at point"))
    (bitbucket-devops-pull-requests-ui--edit-comment
     comment
     (read-string
      "Updated comment: "
      (bitbucket-devops-pull-requests-comment-text comment)))))

(defun bitbucket-devops-pull-requests-ui-delete-comment (selection)
  "Delete comment SELECTION after confirmation."
  (interactive
   (let ((candidates (bitbucket-devops-pull-requests-ui--comment-candidates)))
     (unless candidates
       (user-error "No loaded Bitbucket pull request comments to delete"))
     (list (completing-read "Delete comment: " candidates nil t))))
  (let ((comment
         (bitbucket-devops-pull-requests-ui--comment-for-selection selection)))
    (unless comment
      (user-error "Unknown Bitbucket pull request comment"))
    (when (yes-or-no-p (format "Delete %s? " selection))
      (bitbucket-devops-pull-requests-ui--run-comment-action
       #'bitbucket-devops-pull-requests-rest-delete-comment
       (alist-get 'id comment)
       "Deleted Bitbucket pull request comment"))))

(defun bitbucket-devops-pull-requests-ui--unresolved-thread-p (comment)
  "Return non-nil when COMMENT is an unresolved top-level thread."
  (and (not (bitbucket-devops-pull-requests-comment-reply-p comment))
       (not (bitbucket-devops-pull-requests-comment-resolved-p comment))))

(defun bitbucket-devops-pull-requests-ui--resolved-thread-p (comment)
  "Return non-nil when COMMENT is a resolved top-level thread."
  (and (not (bitbucket-devops-pull-requests-comment-reply-p comment))
       (bitbucket-devops-pull-requests-comment-resolved-p comment)))

(defun bitbucket-devops-pull-requests-ui-resolve-comment (selection)
  "Resolve the comment thread represented by SELECTION."
  (interactive
   (let ((candidates
          (bitbucket-devops-pull-requests-ui--comment-candidates
           #'bitbucket-devops-pull-requests-ui--unresolved-thread-p)))
     (unless candidates
       (user-error "No unresolved Bitbucket pull request comment threads"))
     (list (completing-read "Resolve comment thread: " candidates nil t))))
  (let ((comment
         (bitbucket-devops-pull-requests-ui--comment-for-selection
          selection
          #'bitbucket-devops-pull-requests-ui--unresolved-thread-p)))
    (unless comment
      (user-error "Unknown unresolved Bitbucket pull request comment thread"))
    (bitbucket-devops-pull-requests-ui--run-comment-action
     #'bitbucket-devops-pull-requests-rest-resolve-comment
     (alist-get 'id comment)
     "Resolved Bitbucket pull request comment thread")))

(defun bitbucket-devops-pull-requests-ui-reopen-comment (selection)
  "Reopen the resolved comment thread represented by SELECTION."
  (interactive
   (let ((candidates
          (bitbucket-devops-pull-requests-ui--comment-candidates
           #'bitbucket-devops-pull-requests-ui--resolved-thread-p)))
     (unless candidates
       (user-error "No resolved Bitbucket pull request comment threads"))
     (list (completing-read "Reopen comment thread: " candidates nil t))))
  (let ((comment
         (bitbucket-devops-pull-requests-ui--comment-for-selection
          selection
          #'bitbucket-devops-pull-requests-ui--resolved-thread-p)))
    (unless comment
      (user-error "Unknown resolved Bitbucket pull request comment thread"))
    (bitbucket-devops-pull-requests-ui--run-comment-action
     #'bitbucket-devops-pull-requests-rest-reopen-comment
     (alist-get 'id comment)
     "Reopened Bitbucket pull request comment thread")))

(defun bitbucket-devops-pull-requests-ui--task-candidates (&optional predicate)
  "Return completion candidates for loaded tasks matching PREDICATE."
  (mapcar
   (lambda (task)
     (let* ((id (alist-get 'id task))
            (state
             (if (bitbucket-devops-pull-requests--task-resolved-p task)
                 "resolved"
               "open"))
            (text
             (truncate-string-to-width
              (replace-regexp-in-string
               "[\n\r]+" " " (bitbucket-devops-pull-requests-task-text task))
              70 nil nil t)))
       (cons (format "#%s [%s] %s" id state text) id)))
   (if predicate
       (seq-filter predicate bitbucket-devops-pull-requests-ui--details-tasks)
     bitbucket-devops-pull-requests-ui--details-tasks)))

(defun bitbucket-devops-pull-requests-ui--task-for-selection (selection)
  "Return the loaded task selected by completion label SELECTION."
  (when-let ((task-id
              (cdr (assoc selection
                          (bitbucket-devops-pull-requests-ui--task-candidates)))))
    (seq-find
     (lambda (task) (= (or (alist-get 'id task) -1) task-id))
     bitbucket-devops-pull-requests-ui--details-tasks)))

(defun bitbucket-devops-pull-requests-ui-create-task (text)
  "Create a task with TEXT on the current pull request."
  (interactive (list (read-string "Pull request task: ")))
  (pcase-let ((`(,context ,pull-request-id)
               (bitbucket-devops-pull-requests-ui--require-details-context)))
    (bitbucket-devops-pull-requests-rest-create-task
     context pull-request-id text
     (bitbucket-devops-pull-requests-ui--action-callback
      (current-buffer) "Created Bitbucket pull request task"))))

(defun bitbucket-devops-pull-requests-ui-edit-task (selection text)
  "Edit loaded task SELECTION, replacing its content with TEXT."
  (interactive
   (let* ((candidates (bitbucket-devops-pull-requests-ui--task-candidates))
          (_ (unless candidates (user-error "No loaded tasks are available")))
          (selection (completing-read "Edit task: " candidates nil t))
          (task (bitbucket-devops-pull-requests-ui--task-for-selection selection)))
     (list selection
           (read-string "Task text: "
                        (bitbucket-devops-pull-requests-task-text task)))))
  (let ((task (bitbucket-devops-pull-requests-ui--task-for-selection selection)))
    (unless task (user-error "The selected task is no longer loaded"))
    (pcase-let ((`(,context ,pull-request-id)
                 (bitbucket-devops-pull-requests-ui--require-details-context)))
      (bitbucket-devops-pull-requests-rest-update-task
       context pull-request-id (alist-get 'id task)
       (bitbucket-devops-pull-requests-ui--action-callback
        (current-buffer) "Updated Bitbucket pull request task")
       text))))

(defun bitbucket-devops-pull-requests-ui-delete-task (selection)
  "Delete loaded task SELECTION after confirmation."
  (interactive
   (let ((candidates (bitbucket-devops-pull-requests-ui--task-candidates)))
     (unless candidates (user-error "No loaded tasks are available"))
     (list (completing-read "Delete task: " candidates nil t))))
  (let ((task (bitbucket-devops-pull-requests-ui--task-for-selection selection)))
    (unless task (user-error "The selected task is no longer loaded"))
    (pcase-let ((`(,context ,pull-request-id)
                 (bitbucket-devops-pull-requests-ui--require-details-context)))
      (when
          (yes-or-no-p
           (format "Delete task #%s from %s/%s pull request #%s? "
                   (alist-get 'id task)
                   (plist-get context :workspace)
                   (plist-get context :repo-slug)
                   pull-request-id))
        (bitbucket-devops-pull-requests-rest-delete-task
         context pull-request-id (alist-get 'id task)
         (bitbucket-devops-pull-requests-ui--action-callback
          (current-buffer) "Deleted Bitbucket pull request task"))))))

(defun bitbucket-devops-pull-requests-ui--open-task-p (task)
  "Return non-nil when TASK is unresolved."
  (not (bitbucket-devops-pull-requests--task-resolved-p task)))

(defun bitbucket-devops-pull-requests-ui--resolved-task-p (task)
  "Return non-nil when TASK is resolved."
  (bitbucket-devops-pull-requests--task-resolved-p task))

(defun bitbucket-devops-pull-requests-ui--task-at-point ()
  "Return the loaded task on the current detail line, or nil."
  (when-let ((task-id
              (bitbucket-devops-pull-requests-ui--property-at-point-or-line
               'bitbucket-devops-pull-requests-task-id)))
    (seq-find
     (lambda (task) (equal (alist-get 'id task) task-id))
     bitbucket-devops-pull-requests-ui--details-tasks)))

(defun bitbucket-devops-pull-requests-ui--set-task-state-for-task
    (task state success-message)
  "Set loaded TASK to STATE and report SUCCESS-MESSAGE."
  (pcase-let ((`(,context ,pull-request-id)
               (bitbucket-devops-pull-requests-ui--require-details-context)))
    (bitbucket-devops-pull-requests-rest-update-task
     context pull-request-id (alist-get 'id task)
     (bitbucket-devops-pull-requests-ui--action-callback
      (current-buffer) success-message)
     nil state)))

(defun bitbucket-devops-pull-requests-ui--set-task-state
    (selection state success-message)
  "Set loaded task SELECTION to STATE and report SUCCESS-MESSAGE."
  (let ((task (bitbucket-devops-pull-requests-ui--task-for-selection selection)))
    (unless task (user-error "The selected task is no longer loaded"))
    (bitbucket-devops-pull-requests-ui--set-task-state-for-task
     task state success-message)))

(defun bitbucket-devops-pull-requests-ui-toggle-task-at-point ()
  "Resolve or reopen the pull request task on the current line."
  (interactive)
  (unless (derived-mode-p 'bitbucket-devops-pull-requests-detail-mode)
    (user-error "This command requires a Bitbucket pull request detail buffer"))
  (let ((task (bitbucket-devops-pull-requests-ui--task-at-point)))
    (unless task
      (user-error "No Bitbucket pull request task at point"))
    (if (bitbucket-devops-pull-requests--task-resolved-p task)
        (bitbucket-devops-pull-requests-ui--set-task-state-for-task
         task "UNRESOLVED" "Reopened Bitbucket pull request task")
      (bitbucket-devops-pull-requests-ui--set-task-state-for-task
       task "RESOLVED" "Resolved Bitbucket pull request task"))))

(defun bitbucket-devops-pull-requests-ui-resolve-task (selection)
  "Resolve loaded open task SELECTION."
  (interactive
   (let ((candidates
          (bitbucket-devops-pull-requests-ui--task-candidates
           #'bitbucket-devops-pull-requests-ui--open-task-p)))
     (unless candidates (user-error "No loaded open tasks are available"))
     (list (completing-read "Resolve task: " candidates nil t))))
  (bitbucket-devops-pull-requests-ui--set-task-state
   selection "RESOLVED" "Resolved Bitbucket pull request task"))

(defun bitbucket-devops-pull-requests-ui-reopen-task (selection)
  "Reopen loaded resolved task SELECTION."
  (interactive
   (let ((candidates
          (bitbucket-devops-pull-requests-ui--task-candidates
           #'bitbucket-devops-pull-requests-ui--resolved-task-p)))
     (unless candidates (user-error "No loaded resolved tasks are available"))
     (list (completing-read "Reopen task: " candidates nil t))))
  (bitbucket-devops-pull-requests-ui--set-task-state
   selection "UNRESOLVED" "Reopened Bitbucket pull request task"))

(defun bitbucket-devops-pull-requests-ui-save-create-description ()
  "Create a pull request using the current Markdown description."
  (interactive)
  (unless bitbucket-devops-pull-requests-create-description-mode
    (user-error "This is not a Bitbucket pull request creation editor"))
  (when bitbucket-devops-pull-requests-ui--create-saving
    (user-error "The pull request is already being created"))
  (unless (buffer-live-p
           bitbucket-devops-pull-requests-ui--create-source-buffer)
    (user-error "The pull request list buffer is no longer available"))
  (let* ((editor-buffer (current-buffer))
         (source-buffer bitbucket-devops-pull-requests-ui--create-source-buffer)
         (metadata bitbucket-devops-pull-requests-ui--create-metadata)
         (description (buffer-substring-no-properties (point-min) (point-max)))
         (create-arguments
          (list
           (plist-get metadata :source)
           (plist-get metadata :destination)
           (plist-get metadata :title)
           description
           (plist-get metadata :draft)))
         (strategy bitbucket-devops-pull-requests-ui--create-reviewer-strategy))
    (setq bitbucket-devops-pull-requests-ui--create-saving t)
    (with-current-buffer source-buffer
      (bitbucket-devops-pull-requests-ui--create-with-reviewer-strategy
       source-buffer
       create-arguments
       strategy))
    (with-current-buffer editor-buffer
      (setq bitbucket-devops-pull-requests-ui--create-saving nil)
      (set-buffer-modified-p nil))
    (if-let ((window (get-buffer-window editor-buffer t)))
        (quit-window t window)
      (kill-buffer editor-buffer))))

(defun bitbucket-devops-pull-requests-ui-cancel-create-description ()
  "Cancel the current pull request creation edit."
  (interactive)
  (unless bitbucket-devops-pull-requests-create-description-mode
    (user-error "This is not a Bitbucket pull request creation editor"))
  (when bitbucket-devops-pull-requests-ui--create-saving
    (user-error "Wait for the pull request creation to finish"))
  (when (or (not (buffer-modified-p))
            (yes-or-no-p "Discard new pull request description? "))
    (let ((buffer (current-buffer)))
      (set-buffer-modified-p nil)
      (if-let ((window (get-buffer-window buffer t)))
          (quit-window t window)
        (kill-buffer buffer)))))

(defun bitbucket-devops-pull-requests-ui--current-description ()
  "Return the loaded pull request description as editable plain text."
  (or (bitbucket-devops-pull-requests--nested-get
       bitbucket-devops-pull-requests-ui--details-pull-request
       'description
       'raw)
      (alist-get 'description
                 bitbucket-devops-pull-requests-ui--details-pull-request)
      ""))

(defun bitbucket-devops-pull-requests-ui--current-title ()
  "Return the loaded pull request title."
  (or (alist-get 'title bitbucket-devops-pull-requests-ui--details-pull-request) ""))

(defun bitbucket-devops-pull-requests-ui--current-draft-p ()
  "Return non-nil when the loaded pull request is a draft."
  (eq (alist-get 'draft bitbucket-devops-pull-requests-ui--details-pull-request) t))

(defun bitbucket-devops-pull-requests-ui--description-buffer-name ()
  "Return the description editor buffer name for the current pull request."
  (format
   "*Bitbucket Pull Request Description: %s/%s#%s*"
   (plist-get bitbucket-devops-pull-requests-ui--context :workspace)
   (plist-get bitbucket-devops-pull-requests-ui--context :repo-slug)
   bitbucket-devops-pull-requests-ui--details-pull-request-id))

(defun bitbucket-devops-pull-requests-ui--close-description-editor (buffer)
  "Close and kill description editor BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (set-buffer-modified-p nil))
    (if-let ((window (get-buffer-window buffer t)))
        (quit-window t window)
      (kill-buffer buffer))))

(defun bitbucket-devops-pull-requests-ui--description-save-callback
    (editor-buffer source-buffer)
  "Return a save callback for EDITOR-BUFFER and SOURCE-BUFFER."
  (lambda (_result error)
    (when (buffer-live-p editor-buffer)
      (with-current-buffer editor-buffer
        (setq bitbucket-devops-pull-requests-ui--description-saving nil)))
    (if error
        (when (buffer-live-p editor-buffer)
          (with-current-buffer editor-buffer
            (message "Unable to update Bitbucket pull request description: %s"
                     (or (plist-get error :message) error))))
      (when (buffer-live-p source-buffer)
        (with-current-buffer source-buffer
          (message "Updated Bitbucket pull request metadata")
          (bitbucket-devops-pull-requests-ui-refresh-details)))
      (bitbucket-devops-pull-requests-ui--close-description-editor
       editor-buffer))))

(defun bitbucket-devops-pull-requests-ui-save-description ()
  "Save the current Markdown description to Bitbucket."
  (interactive)
  (unless bitbucket-devops-pull-requests-description-edit-mode
    (user-error "This is not a Bitbucket pull request description editor"))
  (when bitbucket-devops-pull-requests-ui--description-saving
    (user-error "The pull request description is already being saved"))
  (unless (buffer-live-p
           bitbucket-devops-pull-requests-ui--description-source-buffer)
    (user-error "The pull request detail buffer is no longer available"))
  (let ((editor-buffer (current-buffer))
        (source-buffer
         bitbucket-devops-pull-requests-ui--description-source-buffer)
        (title bitbucket-devops-pull-requests-ui--description-title)
        (description (buffer-substring-no-properties (point-min) (point-max))))
    (setq bitbucket-devops-pull-requests-ui--description-saving t)
    (condition-case error
        (with-current-buffer source-buffer
          (pcase-let ((`(,context ,pull-request-id)
                       (bitbucket-devops-pull-requests-ui--require-details-context)))
            (bitbucket-devops-pull-requests-rest-update
             context
             pull-request-id
             (bitbucket-devops-pull-requests-rest-metadata-body
              title
              description
              (bitbucket-devops-pull-requests-ui--current-draft-p))
             (bitbucket-devops-pull-requests-ui--description-save-callback
              editor-buffer source-buffer))))
      (error
       (setq bitbucket-devops-pull-requests-ui--description-saving nil)
       (signal (car error) (cdr error))))))

(defun bitbucket-devops-pull-requests-ui-cancel-description-edit ()
  "Cancel the current pull request description edit."
  (interactive)
  (unless bitbucket-devops-pull-requests-description-edit-mode
    (user-error "This is not a Bitbucket pull request description editor"))
  (when bitbucket-devops-pull-requests-ui--description-saving
    (user-error "Wait for the pull request description save to finish"))
  (when (or (not (buffer-modified-p))
            (yes-or-no-p "Discard pull request description edits? "))
    (bitbucket-devops-pull-requests-ui--close-description-editor
     (current-buffer))))

(defun bitbucket-devops-pull-requests-ui--open-description-editor (title)
  "Open a Markdown editor for the current description using TITLE."
  (bitbucket-devops-pull-requests-ui--require-details-context)
  (unless bitbucket-devops-pull-requests-ui--details-pull-request
    (user-error "Pull request details are not loaded yet"))
  (let* ((source-buffer (current-buffer))
         (description (bitbucket-devops-pull-requests-ui--current-description))
         (buffer (get-buffer-create
                  (bitbucket-devops-pull-requests-ui--description-buffer-name))))
    (with-current-buffer buffer
      (let ((preserve-edits
             (and (eq bitbucket-devops-pull-requests-ui--description-source-buffer
                      source-buffer)
                  (buffer-modified-p))))
        (unless preserve-edits
          (if (require 'markdown-mode nil t)
              (markdown-mode)
            (text-mode))
          (erase-buffer)
          (insert description)
          (goto-char (point-min))
          (set-buffer-modified-p nil))
        (setq-local bitbucket-devops-pull-requests-ui--description-source-buffer
                    source-buffer)
        (setq-local bitbucket-devops-pull-requests-ui--description-title title)
        (setq-local bitbucket-devops-pull-requests-ui--description-saving nil)
        (bitbucket-devops-pull-requests-description-edit-mode 1)
        (setq-local header-line-format
                    " Edit Markdown  C-c C-c/C-x C-s save  C-c C-k cancel ")))
    (let ((window
           (display-buffer
            buffer
            '((display-buffer-in-side-window)
              (side . right)
              (slot . 1)
              (window-width . 0.45)))))
      (when (window-live-p window)
        (select-window window)))
    buffer))

(defun bitbucket-devops-pull-requests-ui-edit-description ()
  "Edit the current pull request description in a Markdown side buffer."
  (interactive)
  (bitbucket-devops-pull-requests-ui--open-description-editor
   (bitbucket-devops-pull-requests-ui--current-title)))

(defun bitbucket-devops-pull-requests-ui-edit-title (title)
  "Edit the current pull request TITLE."
  (interactive
   (list
    (read-string "Pull request title: "
                 (bitbucket-devops-pull-requests-ui--current-title))))
  (bitbucket-devops-pull-requests-ui--update-metadata
   title
   (bitbucket-devops-pull-requests-ui--current-description)
   (bitbucket-devops-pull-requests-ui--current-draft-p)
   "Updated Bitbucket pull request title"))

(defun bitbucket-devops-pull-requests-ui--update-metadata
    (title description draft success-message)
  "Update the current pull request metadata and report SUCCESS-MESSAGE.
TITLE is the pull request title to store.
DESCRIPTION is the pull request description to store.
DRAFT sets the pull request draft state."
  (pcase-let ((`(,context ,pull-request-id)
               (bitbucket-devops-pull-requests-ui--require-details-context)))
    (bitbucket-devops-pull-requests-rest-update
     context
     pull-request-id
     (bitbucket-devops-pull-requests-rest-metadata-body title description draft)
     (bitbucket-devops-pull-requests-ui--action-callback
      (current-buffer)
      success-message))))

(defun bitbucket-devops-pull-requests-ui--set-draft-state
    (draft success-message already-message)
  "Set the current pull request draft state to DRAFT.

Report SUCCESS-MESSAGE after a remote update.  Report ALREADY-MESSAGE without
calling Bitbucket when the pull request already has the requested state."
  (bitbucket-devops-pull-requests-ui--require-details-context)
  (unless bitbucket-devops-pull-requests-ui--details-pull-request
    (user-error "Pull request details are not loaded yet"))
  (if (eq (not (not draft))
          (bitbucket-devops-pull-requests-ui--current-draft-p))
      (message "%s" already-message)
    (bitbucket-devops-pull-requests-ui--update-metadata
     (bitbucket-devops-pull-requests-ui--current-title)
     (bitbucket-devops-pull-requests-ui--current-description)
     draft
     success-message)))

(defun bitbucket-devops-pull-requests-ui-edit-metadata
    (&optional title description interactive)
  "Edit the current pull request TITLE and DESCRIPTION.

Interactive use reads the one-line title, then opens DESCRIPTION in a Markdown
side buffer.  Non-interactive callers update both values immediately.
When INTERACTIVE is non-nil, prompt for both values."
  (interactive (list nil nil t))
  (if interactive
      (bitbucket-devops-pull-requests-ui--open-description-editor
       (read-string "Pull request title: "
                    (bitbucket-devops-pull-requests-ui--current-title)))
    (bitbucket-devops-pull-requests-ui--update-metadata
     title
     description
     (bitbucket-devops-pull-requests-ui--current-draft-p)
     "Updated Bitbucket pull request metadata")))

(defun bitbucket-devops-pull-requests-ui-mark-ready ()
  "Mark the current draft pull request ready for review."
  (interactive)
  (bitbucket-devops-pull-requests-ui--set-draft-state
   nil
   "Marked Bitbucket pull request as ready for review"
   "Bitbucket pull request is already ready for review"))

(defun bitbucket-devops-pull-requests-ui-mark-draft ()
  "Mark the current ready pull request as a draft."
  (interactive)
  (bitbucket-devops-pull-requests-ui--set-draft-state
   t
   "Marked Bitbucket pull request as draft"
   "Bitbucket pull request is already a draft"))

(defun bitbucket-devops-pull-requests-ui-toggle-draft ()
  "Toggle the current pull request between draft and ready for review."
  (interactive)
  (bitbucket-devops-pull-requests-ui--require-details-context)
  (unless bitbucket-devops-pull-requests-ui--details-pull-request
    (user-error "Pull request details are not loaded yet"))
  (let* ((draft (not (bitbucket-devops-pull-requests-ui--current-draft-p)))
         (message
          (if draft
              "Marked Bitbucket pull request as draft"
            "Marked Bitbucket pull request as ready for review")))
    (bitbucket-devops-pull-requests-ui--update-metadata
     (bitbucket-devops-pull-requests-ui--current-title)
     (bitbucket-devops-pull-requests-ui--current-description)
     draft
     message)))

(defun bitbucket-devops-pull-requests-ui--reviewer-identifier (reviewer)
  "Return REVIEWER's UUID or account ID."
  (or (alist-get 'uuid reviewer)
      (alist-get 'account_id reviewer)))

(defun bitbucket-devops-pull-requests-ui--alist-object-p (value)
  "Return non-nil when VALUE is a symbol-keyed alist object."
  (and (proper-list-p value)
       (seq-every-p
        (lambda (entry)
          (and (consp entry) (symbolp (car entry))))
        value)))

(defun bitbucket-devops-pull-requests-ui--user-object (value)
  "Return the Bitbucket user represented by VALUE, or nil."
  (when (bitbucket-devops-pull-requests-ui--alist-object-p value)
    (let ((user (or (alist-get 'user value) value)))
      (when (and (bitbucket-devops-pull-requests-ui--alist-object-p user)
               (bitbucket-devops-pull-requests-ui--reviewer-identifier user)
               (or (alist-get 'display_name user)
                   (alist-get 'nickname user)
                   (alist-get 'email user)))
        user))))

(defun bitbucket-devops-pull-requests-ui--collect-user-objects (value)
  "Return identifiable Bitbucket user objects nested in VALUE."
  (cond
   ((not (consp value)) nil)
   ((and (proper-list-p value)
         (bitbucket-devops-pull-requests-ui--user-object value))
    (list (bitbucket-devops-pull-requests-ui--user-object value)))
   ((bitbucket-devops-pull-requests-ui--alist-object-p value)
    (apply
     #'append
     (mapcar
      (lambda (entry)
        (bitbucket-devops-pull-requests-ui--collect-user-objects (cdr entry)))
      value)))
   ((proper-list-p value)
    (apply
     #'append
     (mapcar #'bitbucket-devops-pull-requests-ui--collect-user-objects value)))
   (t
    (bitbucket-devops-pull-requests-ui--collect-user-objects (cdr value)))))

(defun bitbucket-devops-pull-requests-ui--known-reviewer-users (&optional context)
  "Return users already known by pull request UI buffers for CONTEXT."
  (let (values)
    (when (or (null context)
              (equal context bitbucket-devops-pull-requests-ui--context))
      (setq values
            (list bitbucket-devops-pull-requests-ui--pull-requests
                  bitbucket-devops-pull-requests-ui--details-pull-request
                  bitbucket-devops-pull-requests-ui--details-comments
                  bitbucket-devops-pull-requests-ui--details-activity)))
    (when (buffer-live-p bitbucket-devops-ui--previous-buffer)
      (with-current-buffer bitbucket-devops-ui--previous-buffer
        (when (and
               (boundp 'bitbucket-devops-pull-requests-ui--pull-requests)
               (or
                (null context)
                (equal context bitbucket-devops-pull-requests-ui--context)))
          (push bitbucket-devops-pull-requests-ui--pull-requests values))))
    (apply #'append
           (mapcar #'bitbucket-devops-pull-requests-ui--collect-user-objects values))))

(defun bitbucket-devops-pull-requests-ui--unique-users (users)
  "Return USERS deduplicated by Bitbucket identifier."
  (let ((seen (make-hash-table :test #'equal))
        result)
    (dolist (value users (nreverse result))
      (when-let* ((user (bitbucket-devops-pull-requests-ui--user-object value))
                  (identifier
                   (bitbucket-devops-pull-requests-ui--reviewer-identifier user)))
        (unless (gethash identifier seen)
          (puthash identifier t seen)
          (push user result))))))

(defun bitbucket-devops-pull-requests-ui--short-user-id (identifier)
  "Return a short display form of Bitbucket IDENTIFIER."
  (let* ((trimmed (string-trim identifier "[{}]" "[{}]"))
         (length (length trimmed)))
    (substring trimmed 0 (min 8 length))))

(defun bitbucket-devops-pull-requests-ui--reviewer-user-label (user)
  "Return an unambiguous completion label for Bitbucket USER."
  (let* ((display-name (bitbucket-devops-pull-requests--user-display-name user))
         (nickname (alist-get 'nickname user))
         (email (alist-get 'email user))
         (identifier (bitbucket-devops-pull-requests-ui--reviewer-identifier user)))
    (format
     "%s%s%s [%s]"
     display-name
     (if (and (stringp nickname)
              (not (string-empty-p nickname))
              (not (equal nickname display-name)))
         (format " (@%s)" nickname)
       "")
     (if (and (stringp email) (not (string-empty-p email)))
         (format " <%s>" email)
       "")
     (bitbucket-devops-pull-requests-ui--short-user-id identifier))))

(defun bitbucket-devops-pull-requests-ui--reviewer-user-candidates (users)
  "Return completion candidates for Bitbucket USERS."
  (sort
   (mapcar
    (lambda (user)
      (cons
       (bitbucket-devops-pull-requests-ui--reviewer-user-label user)
       (bitbucket-devops-pull-requests-ui--reviewer-identifier user)))
    (bitbucket-devops-pull-requests-ui--unique-users users))
   (lambda (left right) (string-lessp (car left) (car right)))))

(defun bitbucket-devops-pull-requests-ui--collect-user-pages
    (rest-function context callback &optional next-url collected)
  "Collect user pages from REST-FUNCTION for CONTEXT, then call CALLBACK.
NEXT-URL continues a paginated request when non-nil.
COLLECTED accumulates users across pages."
  (funcall
   rest-function
   context
   (lambda (page error)
     (if error
         (funcall callback nil error)
       (let ((values
              (append collected
                      (or (bitbucket-devops-rest-page-values page) nil)))
             (next (bitbucket-devops-rest-page-next page)))
         (if next
             (bitbucket-devops-pull-requests-ui--collect-user-pages
              rest-function context callback next values)
           (funcall callback values nil)))))
   next-url))

(defun bitbucket-devops-pull-requests-ui--finish-reviewer-user-load
    (context known users error callback)
  "Finish loading reviewer USERS for CONTEXT and invoke CALLBACK.

KNOWN users are merged into the result.  Successful remote results replace
the persistent reviewer cache; ERROR leaves the previous cache untouched."
  (let ((merged
         (bitbucket-devops-pull-requests-ui--unique-users
          (append users known))))
    (unless error
      (bitbucket-devops-cache-put-reviewer-users context merged))
    (funcall callback merged error)))

(defun bitbucket-devops-pull-requests-ui--load-reviewer-users
    (callback &optional force-refresh context)
  "Load reviewer candidates and invoke CALLBACK with USERS and lookup ERROR.

Use CONTEXT when supplied instead of the current buffer's repository.  Cached
users are returned without a network request unless FORCE-REFRESH is non-nil."
  (setq context (or context bitbucket-devops-pull-requests-ui--context))
  (unless context
    (user-error "This buffer is not associated with a Bitbucket repository"))
  (let ((known
         (bitbucket-devops-pull-requests-ui--known-reviewer-users context)))
    (if (and (not force-refresh)
             (bitbucket-devops-cache-reviewer-users-cached-p context))
        (funcall
         callback
         (bitbucket-devops-pull-requests-ui--unique-users
          (append
           (bitbucket-devops-cache-reviewer-users context)
           known))
         nil)
      (bitbucket-devops-pull-requests-ui--collect-user-pages
       #'bitbucket-devops-pull-requests-rest-list-repository-users
       context
       (lambda (repository-users repository-error)
         (if (and (not repository-error) repository-users)
             (bitbucket-devops-pull-requests-ui--finish-reviewer-user-load
              context known repository-users nil callback)
           (bitbucket-devops-pull-requests-ui--collect-user-pages
            #'bitbucket-devops-pull-requests-rest-list-workspace-members
            context
            (lambda (workspace-members workspace-error)
              (bitbucket-devops-pull-requests-ui--finish-reviewer-user-load
               context
               known
               workspace-members
               (and workspace-error
                    (or workspace-error repository-error))
               callback)))))))))

;;;###autoload
(defun bitbucket-devops-pull-requests-refresh-reviewer-cache ()
  "Refresh custom reviewer candidates for the current repository."
  (interactive)
  (let ((context
         (or bitbucket-devops-pull-requests-ui--context
             (bitbucket-devops-context-resolve))))
    (message "Refreshing Bitbucket reviewer cache...")
    (bitbucket-devops-pull-requests-ui--load-reviewer-users
     (lambda (users error)
       (if error
           (message
            "Unable to refresh Bitbucket reviewer cache: %s"
            (or (plist-get error :message) error))
         (message
          "Cached %s Bitbucket reviewer candidate%s"
          (length users)
          (if (= (length users) 1) "" "s"))))
     t
     context)))

(defun bitbucket-devops-pull-requests-ui--reviewer-identifiers ()
  "Return identifiable reviewers from the current pull request."
  (let* ((reviewers
          (bitbucket-devops-pull-requests-reviewers
           bitbucket-devops-pull-requests-ui--details-pull-request))
         (identifiers
          (mapcar
           #'bitbucket-devops-pull-requests-ui--reviewer-identifier
           reviewers)))
    (when (memq nil identifiers)
      (user-error
       "Cannot update reviewers because loaded reviewer data lacks identifiers; refresh and try again"))
    identifiers))

(defun bitbucket-devops-pull-requests-ui--update-reviewers
    (reviewer-identifiers success-message)
  "Replace current reviewers and report SUCCESS-MESSAGE.
REVIEWER-IDENTIFIERS name the reviewers to set."
  (pcase-let ((`(,context ,pull-request-id)
               (bitbucket-devops-pull-requests-ui--require-details-context)))
    (bitbucket-devops-pull-requests-rest-update
     context
     pull-request-id
     (bitbucket-devops-pull-requests-rest-reviewers-body reviewer-identifiers)
     (bitbucket-devops-pull-requests-ui--action-callback
      (current-buffer)
      success-message))))

(defun bitbucket-devops-pull-requests-ui--add-reviewer-identifier (identifier)
  "Add the reviewer identified by Bitbucket IDENTIFIER."
  (setq identifier (string-trim identifier))
  (when (string-empty-p identifier)
    (user-error "Reviewer identifier cannot be empty"))
  (let ((reviewers (bitbucket-devops-pull-requests-ui--reviewer-identifiers)))
    (when (member identifier reviewers)
      (user-error "That user is already a reviewer"))
    (bitbucket-devops-pull-requests-ui--update-reviewers
     (append reviewers (list identifier))
     "Added Bitbucket pull request reviewer")))

(defun bitbucket-devops-pull-requests-ui--unavailable-reviewer-identifiers ()
  "Return identifiers that cannot be added to the current pull request."
  (delete-dups
   (delq
    nil
    (cons
     (bitbucket-devops-pull-requests-ui--reviewer-identifier
      (alist-get 'author bitbucket-devops-pull-requests-ui--details-pull-request))
     (bitbucket-devops-pull-requests-ui--reviewer-identifiers)))))

(defun bitbucket-devops-pull-requests-ui--prompt-add-reviewer (buffer users error)
  "Prompt in BUFFER to add one of USERS, noting lookup ERROR when present."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((unavailable
              (bitbucket-devops-pull-requests-ui--unavailable-reviewer-identifiers))
             (candidates
              (seq-remove
               (lambda (candidate)
                 (member (cdr candidate) unavailable))
               (bitbucket-devops-pull-requests-ui--reviewer-user-candidates users))))
        (if (null candidates)
            (message
             (if error
                 (concat
                  "No reviewer users are available; grant optional "
                  "read:workspace:bitbucket access or load PRs containing the user")
               "No additional Bitbucket reviewers are available"))
          (when error
            (message
             (concat
              "Using users known from this repository; broader lookup "
              "requires optional read:workspace:bitbucket access")))
          (let* ((selection
                  (completing-read "Add reviewer: " candidates nil t))
                 (selected-identifier
                  (cdr (assoc selection candidates))))
            (when selected-identifier
              (bitbucket-devops-pull-requests-ui--add-reviewer-identifier
               selected-identifier))))))))

(defun bitbucket-devops-pull-requests-ui-add-reviewer (&optional identifier)
  "Select and add a reviewer, or add Bitbucket IDENTIFIER directly.

Interactive use loads repository or workspace users and presents completion by
display name, nickname, and email when Bitbucket exposes it.  The selected
user's UUID is sent to Bitbucket."
  (interactive)
  (cond
   ((and (called-interactively-p 'interactive) current-prefix-arg)
    (bitbucket-devops-pull-requests-ui-add-default-reviewers))
   (identifier
    (bitbucket-devops-pull-requests-ui--add-reviewer-identifier identifier))
   (t
    (bitbucket-devops-pull-requests-ui--require-details-context)
    (let ((buffer (current-buffer)))
      (message "Loading Bitbucket reviewer candidates...")
      (bitbucket-devops-pull-requests-ui--load-reviewer-users
       (lambda (users error)
         (run-at-time
          0 nil
          #'bitbucket-devops-pull-requests-ui--prompt-add-reviewer
          buffer users error)))))))

(defun bitbucket-devops-pull-requests-ui--add-default-reviewers
    (buffer reviewers error)
  "Add effective default REVIEWERS in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if error
          (message "Unable to load Bitbucket default reviewers: %s"
                   (or (plist-get error :message) error))
        (let* ((existing (bitbucket-devops-pull-requests-ui--reviewer-identifiers))
               (author-identifier
                (bitbucket-devops-pull-requests-ui--reviewer-identifier
                 (alist-get
                  'author
                  bitbucket-devops-pull-requests-ui--details-pull-request)))
               (identifiers
                (delete-dups
                 (append
                  existing
                  (delq
                   nil
                   (mapcar
                    #'bitbucket-devops-pull-requests-ui--reviewer-identifier
                    reviewers)))))
               (identifiers
                (delete author-identifier identifiers)))
          (if (equal identifiers existing)
              (message "No additional Bitbucket default reviewers to add")
            (bitbucket-devops-pull-requests-ui--update-reviewers
             identifiers
             "Added Bitbucket default pull request reviewers")))))))

(defun bitbucket-devops-pull-requests-ui-add-default-reviewers ()
  "Add effective default reviewers to the current pull request."
  (interactive)
  (pcase-let ((`(,context ,_pull-request-id)
               (bitbucket-devops-pull-requests-ui--require-details-context)))
    (let ((buffer (current-buffer)))
      (message "Loading Bitbucket default reviewers...")
      (bitbucket-devops-pull-requests-ui--collect-effective-default-reviewers
       context
       (lambda (reviewers error)
         (run-at-time
          0 nil
          #'bitbucket-devops-pull-requests-ui--add-default-reviewers
          buffer reviewers error))))))

(defun bitbucket-devops-pull-requests-ui--reviewer-candidates ()
  "Return completion candidates for removable reviewers."
  (delq
   nil
   (mapcar
    (lambda (reviewer)
      (when-let ((identifier
                  (bitbucket-devops-pull-requests-ui--reviewer-identifier reviewer)))
        (cons
         (format "%s [%s]"
                 (bitbucket-devops-pull-requests--user-display-name reviewer)
                 identifier)
         identifier)))
    (bitbucket-devops-pull-requests-reviewers
     bitbucket-devops-pull-requests-ui--details-pull-request))))

(defun bitbucket-devops-pull-requests-ui-remove-reviewer (selection)
  "Remove reviewer SELECTION from the current pull request."
  (interactive
   (let ((candidates (bitbucket-devops-pull-requests-ui--reviewer-candidates)))
     (unless candidates
       (user-error "No identifiable Bitbucket pull request reviewers"))
     (list (completing-read "Remove reviewer: " candidates nil t))))
  (let* ((candidates (bitbucket-devops-pull-requests-ui--reviewer-candidates))
         (identifier (cdr (assoc selection candidates))))
    (unless identifier
      (user-error "Unknown Bitbucket pull request reviewer"))
    (when (yes-or-no-p (format "Remove reviewer %s? " selection))
      (bitbucket-devops-pull-requests-ui--update-reviewers
       (delete identifier (bitbucket-devops-pull-requests-ui--reviewer-identifiers))
       "Removed Bitbucket pull request reviewer"))))

(defun bitbucket-devops-pull-requests-ui-decline ()
  "Decline the current pull request after confirmation."
  (interactive)
  (pcase-let* ((`(,context ,pull-request-id)
                (bitbucket-devops-pull-requests-ui--require-details-context))
               (title
                (or (alist-get
                     'title
                     bitbucket-devops-pull-requests-ui--details-pull-request)
                    "")))
    (when
        (yes-or-no-p
         (format
          "Decline %s/%s pull request #%s %s? "
          (plist-get context :workspace)
          (plist-get context :repo-slug)
          pull-request-id
          title))
      (bitbucket-devops-pull-requests-ui--run-action
       #'bitbucket-devops-pull-requests-rest-decline
       "Declined Bitbucket pull request"))))

(defun bitbucket-devops-pull-requests-ui--merge-strategies ()
  "Return merge strategies advertised by the current pull request."
  (let* ((pull-request bitbucket-devops-pull-requests-ui--details-pull-request)
         (destination
          (bitbucket-devops-pull-requests--nested-get
           pull-request 'destination 'branch))
         (advertised (alist-get 'merge_strategies destination)))
    (or
     (seq-filter
      (lambda (strategy)
        (member strategy bitbucket-devops-pull-requests-rest-merge-strategies))
      advertised)
     bitbucket-devops-pull-requests-rest-merge-strategies)))

(defun bitbucket-devops-pull-requests-ui--default-merge-strategy ()
  "Return the current pull request's default merge strategy."
  (let ((default
         (bitbucket-devops-pull-requests--nested-get
          bitbucket-devops-pull-requests-ui--details-pull-request
          'destination
          'branch
          'default_merge_strategy)))
    (if (member default (bitbucket-devops-pull-requests-ui--merge-strategies))
        default
      (car (bitbucket-devops-pull-requests-ui--merge-strategies)))))

(defun bitbucket-devops-pull-requests-ui--read-merge-arguments ()
  "Read merge strategy, commit message, and source-branch behavior."
  (let* ((strategies (bitbucket-devops-pull-requests-ui--merge-strategies))
         (strategy
          (completing-read
           "Merge strategy: "
           strategies
           nil
           t
           nil
           nil
           (bitbucket-devops-pull-requests-ui--default-merge-strategy)))
         (message (read-string "Merge commit message (optional): "))
         (close-source-branch
          (y-or-n-p "Close source branch after merging? ")))
    (list strategy message close-source-branch)))

(defun bitbucket-devops-pull-requests-ui-merge
    (strategy message close-source-branch)
  "Merge the current pull request using STRATEGY and MESSAGE.

When CLOSE-SOURCE-BRANCH is non-nil, delete the source branch after merging."
  (interactive (bitbucket-devops-pull-requests-ui--read-merge-arguments))
  (pcase-let* ((`(,context ,pull-request-id)
                (bitbucket-devops-pull-requests-ui--require-details-context))
               (pull-request
                bitbucket-devops-pull-requests-ui--details-pull-request)
               (state (upcase (or (alist-get 'state pull-request) "")))
               (title (or (alist-get 'title pull-request) ""))
               (source (bitbucket-devops-pull-requests-source-branch pull-request))
               (destination
                (bitbucket-devops-pull-requests-destination-branch pull-request)))
    (unless (equal state "OPEN")
      (user-error "Only open Bitbucket pull requests can be merged"))
    (when (eq (alist-get 'draft pull-request) t)
      (user-error "A draft Bitbucket pull request cannot be merged"))
    (when
        (yes-or-no-p
         (format
          (concat "Merge %s/%s pull request #%s %s (%s -> %s) "
                  "using %s? ")
          (plist-get context :workspace)
          (plist-get context :repo-slug)
          pull-request-id
          title
          source
          destination
          strategy))
      (bitbucket-devops-pull-requests-rest-merge
       context
       pull-request-id
       (bitbucket-devops-pull-requests-rest-merge-body
        strategy message close-source-branch)
       (bitbucket-devops-pull-requests-ui--action-callback
        (current-buffer)
        "Merged Bitbucket pull request")))))

(define-derived-mode bitbucket-devops-pull-requests-list-mode tabulated-list-mode
  "Bitbucket-PRs"
  "Major mode for Bitbucket Cloud pull request lists."
  (setq-local tabulated-list-format
              (vector
               (list "#" (bitbucket-devops-pull-requests-ui--column-width 'number 8) t)
               (list "State" (bitbucket-devops-pull-requests-ui--column-width 'state 12) t)
               (list "Title" (bitbucket-devops-pull-requests-ui--column-width 'title 34) t)
               (list "Source" (bitbucket-devops-pull-requests-ui--column-width 'source 18) t)
               (list "Destination"
                     (bitbucket-devops-pull-requests-ui--column-width 'destination 18)
                     t)
               (list "Author" (bitbucket-devops-pull-requests-ui--column-width 'author 22) t)
               (list "Reviewers"
                     (bitbucket-devops-pull-requests-ui--column-width 'reviewers 10)
                     t)
               (list "Approvals"
                     (bitbucket-devops-pull-requests-ui--column-width 'approvals 10)
                     t)
               (list "Builds" (bitbucket-devops-pull-requests-ui--column-width 'builds 10) t)
               (list "Created"
                     (bitbucket-devops-pull-requests-ui--column-width 'created 16)
                     t)
               (list "Updated" (bitbucket-devops-pull-requests-ui--column-width 'updated 16) t)))
  (setq-local tabulated-list-padding 2)
  (setq-local tabulated-list-sort-key nil)
  (bitbucket-devops-pull-requests-ui--apply-list-line-wrapping)
  (setq-local line-spacing 0.05)
  (when (fboundp 'hl-line-mode)
    (hl-line-mode 1))
  (tabulated-list-init-header))

(defun bitbucket-devops-pull-requests-ui--install-evil-bindings ()
  "Install Evil normal-state bindings for pull request buffers."
  (bitbucket-devops-pull-requests-ui--install-evil-map-bindings
   'list bitbucket-devops-pull-requests-list-mode-map
   bitbucket-devops-pull-requests-list-keybindings)
  (bitbucket-devops-pull-requests-ui--clear-unconfigured-evil-bindings
   bitbucket-devops-pull-requests-list-mode-map
   bitbucket-devops-pull-requests-list-keybindings
   '("b" "B" "t" "w" "W"))
  (bitbucket-devops-pull-requests-ui--install-evil-map-bindings
   'detail bitbucket-devops-pull-requests-detail-mode-map
   (bitbucket-devops-pull-requests-ui--detail-bindings))
  (bitbucket-devops-pull-requests-ui--clear-unconfigured-evil-bindings
   bitbucket-devops-pull-requests-detail-mode-map
   bitbucket-devops-pull-requests-detail-keybindings
   '("b" "B" "I" "K"))
  (bitbucket-devops-pull-requests-ui--install-evil-map-bindings
   'diff bitbucket-devops-pull-requests-diff-mode-map
   bitbucket-devops-pull-requests-diff-keybindings)
  (bitbucket-devops-pull-requests-ui--install-evil-map-bindings
   'commits bitbucket-devops-pull-requests-commits-mode-map
   (append bitbucket-devops-pull-requests-commits-keybindings
           bitbucket-devops-pull-requests-subview-keybindings))
  (bitbucket-devops-pull-requests-ui--install-evil-map-bindings
   'activity bitbucket-devops-pull-requests-activity-mode-map
   bitbucket-devops-pull-requests-subview-keybindings))

(defvar bitbucket-devops-pull-requests-ui--evil-bindings-installed nil
  "Non-nil once Evil bindings for pull request buffers have been installed.")

(defun bitbucket-devops-pull-requests-ui-install-evil-bindings ()
  "Install Evil bindings for pull request buffers when Evil is loaded.

Does nothing when Evil is absent, and installs at most once.  This runs
from the pull request major modes rather than at load time, so Evil only
has to be loaded by the time the first pull request buffer is opened."
  (when (and (featurep 'evil)
             (not bitbucket-devops-pull-requests-ui--evil-bindings-installed))
    (setq bitbucket-devops-pull-requests-ui--evil-bindings-installed t)
    (bitbucket-devops-pull-requests-ui--install-evil-bindings)))

(dolist (hook '(bitbucket-devops-pull-requests-list-mode-hook
                bitbucket-devops-pull-requests-detail-mode-hook
                bitbucket-devops-pull-requests-diff-mode-hook
                bitbucket-devops-pull-requests-commits-mode-hook
                bitbucket-devops-pull-requests-activity-mode-hook))
  (add-hook hook #'bitbucket-devops-pull-requests-ui-install-evil-bindings))

;;;###autoload
(defun bitbucket-devops-pull-requests-list ()
  "List Bitbucket Cloud pull requests for the current repository."
  (interactive)
  (let* ((context (bitbucket-devops-context-resolve))
         (buffer
         (get-buffer-create
           (format
            "*Bitbucket Pull Requests: %s/%s*"
            (plist-get context :workspace)
            (plist-get context :repo-slug)))))
    (with-current-buffer buffer
      (bitbucket-devops-pull-requests-list-mode)
      (setq-local bitbucket-devops-pull-requests-ui--context context)
      (setq-local bitbucket-devops-pull-requests-ui--state-filter nil)
      (setq-local bitbucket-devops-pull-requests-ui--branch-filter nil)
      (setq-local bitbucket-devops-pull-requests-ui--author-filter nil)
      (setq-local
       bitbucket-devops-pull-requests-ui--pull-requests
      (bitbucket-devops-cache-pull-requests context))
      (bitbucket-devops-pull-requests-ui--render))
    (bitbucket-devops-ui--display-buffer buffer t)
    (with-current-buffer buffer
      (bitbucket-devops-pull-requests-ui--apply-list-line-wrapping))
    (bitbucket-devops-pull-requests-ui-refresh)))

;;;###autoload
(defun bitbucket-devops-pull-requests-create ()
  "Open the current repository's PR list and create a pull request."
  (interactive)
  (bitbucket-devops-pull-requests-list)
  (call-interactively #'bitbucket-devops-pull-requests-ui-create))

(provide 'bitbucket-devops-pull-requests-ui)
;;; bitbucket-devops-pull-requests-ui.el ends here
