;;; bitbucket-devops-cache.el --- Persistent Bitbucket Cloud metadata cache -*- lexical-binding: t; -*-

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

;; Lightweight file-backed cache for Bitbucket Cloud pipeline and pull request
;; metadata, including pull request reviewer candidates.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defvar read-eval)

(defcustom bitbucket-devops-cache-enabled t
  "Whether Bitbucket DevOps persists metadata between sessions."
  :type 'boolean
  :group 'bitbucket-devops)

(defcustom bitbucket-devops-cache-directory
  (expand-file-name "bitbucket-devops/cache/" user-emacs-directory)
  "Directory used for persistent Bitbucket DevOps cache files."
  :type 'directory
  :group 'bitbucket-devops)

(defcustom bitbucket-devops-cache-max-pipelines-per-repo 500
  "Maximum number of pipeline records retained for one repository cache.

Older records are pruned after each merge.  Set to nil to keep every cached
pipeline record."
  :type '(choice (const :tag "Unlimited" nil)
                 (integer :tag "Maximum pipeline count"))
  :group 'bitbucket-devops)

(defcustom bitbucket-devops-cache-max-pull-requests-per-repo 500
  "Maximum number of pull request records retained per repository.

Older records are pruned after each merge.  Set to nil to keep every cached
pull request record."
  :type '(choice (const :tag "Unlimited" nil)
                 (integer :tag "Maximum pull request count"))
  :group 'bitbucket-devops)

(defconst bitbucket-devops-cache--version 1
  "Current persistent cache data version.")

(defun bitbucket-devops-cache--sanitize-file-component (value)
  "Return VALUE made suitable for a cache file name component."
  (let ((sanitized
         (replace-regexp-in-string
          "[^A-Za-z0-9._-]+"
          "-"
          (or value ""))))
    (if (string-empty-p sanitized)
        "unknown"
      sanitized)))

(defun bitbucket-devops-cache-file (context)
  "Return the persistent cache file path for repository CONTEXT."
  (expand-file-name
   (format "%s--%s.el"
           (bitbucket-devops-cache--sanitize-file-component
            (plist-get context :workspace))
           (bitbucket-devops-cache--sanitize-file-component
            (plist-get context :repo-slug)))
   bitbucket-devops-cache-directory))

(defun bitbucket-devops-cache--empty ()
  "Return a new empty cache value."
  (list :version bitbucket-devops-cache--version
        :updated-at nil
        :pipelines nil
        :pull-requests nil
        :commits nil
        :deployments nil
        :reviewer-users nil
        :reviewer-users-updated-at nil))

(defun bitbucket-devops-cache--valid-p (cache)
  "Return non-nil when CACHE has the supported shape."
  (and (listp cache)
       (= (or (plist-get cache :version) 0)
          bitbucket-devops-cache--version)
       (listp (plist-get cache :pipelines))
       (listp (plist-get cache :pull-requests))
       (listp (plist-get cache :commits))
       (listp (plist-get cache :deployments))
       (listp (plist-get cache :reviewer-users))))

(defun bitbucket-devops-cache-read (context)
  "Read and return the persistent cache for CONTEXT.

Return an empty cache when caching is disabled, the cache file does not exist,
or the file cannot be parsed."
  (if (not bitbucket-devops-cache-enabled)
      (bitbucket-devops-cache--empty)
    (let ((file (bitbucket-devops-cache-file context)))
      (if (not (file-readable-p file))
          (bitbucket-devops-cache--empty)
        (condition-case nil
            (with-temp-buffer
              (insert-file-contents file)
              (let ((read-eval nil)
                    (cache (read (current-buffer))))
                (if (bitbucket-devops-cache--valid-p cache)
                    cache
                  (bitbucket-devops-cache--empty))))
          (error
           (bitbucket-devops-cache--empty)))))))

(defun bitbucket-devops-cache-write (context cache)
  "Persist CACHE for repository CONTEXT when caching is enabled."
  (when bitbucket-devops-cache-enabled
    (let* ((file (bitbucket-devops-cache-file context))
           (directory (file-name-directory file)))
      (make-directory directory t)
      (let ((temp-file
             (make-temp-file
              (expand-file-name ".cache-" directory))))
        (unwind-protect
            (progn
              (with-temp-file temp-file
                (let ((print-length nil)
                      (print-level nil)
                      (print-circle nil))
                  (prin1 cache (current-buffer))
                  (insert "\n")))
              (rename-file temp-file file t))
          (when (file-exists-p temp-file)
            (delete-file temp-file)))))))

(defun bitbucket-devops-cache--alist-set (alist key value)
  "Return ALIST with KEY associated with VALUE."
  (let ((copy (copy-sequence alist)))
    (if-let ((cell (assoc key copy)))
        (setcdr cell value)
      (push (cons key value) copy))
    copy))

(defun bitbucket-devops-cache--pipeline-created-on (pipeline)
  "Return PIPELINE's creation timestamp string, or nil."
  (alist-get 'created_on pipeline))

(defun bitbucket-devops-cache--pipeline-build-number (pipeline)
  "Return PIPELINE's numeric build number, or zero."
  (let ((value (alist-get 'build_number pipeline)))
    (cond
     ((numberp value) value)
     ((stringp value) (string-to-number value))
     (t 0))))

(defun bitbucket-devops-cache--pipeline-newer-p (left right)
  "Return non-nil when LEFT should sort before RIGHT."
  (let ((left-created (bitbucket-devops-cache--pipeline-created-on left))
        (right-created (bitbucket-devops-cache--pipeline-created-on right)))
    (cond
     ((and left-created right-created)
      (string> left-created right-created))
     (left-created t)
     (right-created nil)
     (t
      (> (bitbucket-devops-cache--pipeline-build-number left)
         (bitbucket-devops-cache--pipeline-build-number right))))))

(defun bitbucket-devops-cache--sort-pipelines (pipelines)
  "Return PIPELINES sorted newest first."
  (sort (copy-sequence pipelines)
        #'bitbucket-devops-cache--pipeline-newer-p))

(defun bitbucket-devops-cache--prune-pipeline-alist (pipeline-alist)
  "Return PIPELINE-ALIST pruned according to cache retention settings."
  (let ((sorted
         (mapcar
          (lambda (pipeline)
            (cons (alist-get 'uuid pipeline) pipeline))
          (bitbucket-devops-cache--sort-pipelines
           (mapcar #'cdr pipeline-alist)))))
    (if (and (integerp bitbucket-devops-cache-max-pipelines-per-repo)
             (>= bitbucket-devops-cache-max-pipelines-per-repo 0))
        (seq-take sorted bitbucket-devops-cache-max-pipelines-per-repo)
      sorted)))

(defun bitbucket-devops-cache--touch (cache)
  "Set CACHE's update timestamp and return CACHE."
  (plist-put
   cache
   :updated-at
   (format-time-string "%FT%TZ" nil t)))

(defun bitbucket-devops-cache-merge-pipelines (context pipelines)
  "Merge PIPELINES into CONTEXT's persistent cache.

Return the complete cached pipeline list sorted newest first."
  (let* ((cache (bitbucket-devops-cache-read context))
         (pipeline-alist (plist-get cache :pipelines)))
    (dolist (pipeline pipelines)
      (when-let ((uuid (alist-get 'uuid pipeline)))
        (setq pipeline-alist
              (bitbucket-devops-cache--alist-set
               pipeline-alist
               uuid
               (copy-tree pipeline)))))
    (setq pipeline-alist
          (bitbucket-devops-cache--prune-pipeline-alist pipeline-alist))
    (setq cache (plist-put cache :pipelines pipeline-alist))
    (bitbucket-devops-cache-write
     context
     (bitbucket-devops-cache--touch cache))
    (mapcar #'cdr pipeline-alist)))

(defun bitbucket-devops-cache-pipelines (context)
  "Return cached pipelines for CONTEXT sorted newest first."
  (mapcar #'cdr
          (bitbucket-devops-cache--prune-pipeline-alist
           (plist-get (bitbucket-devops-cache-read context) :pipelines))))

(defun bitbucket-devops-cache--pull-request-newer-p (left right)
  "Return non-nil when pull request LEFT should sort before RIGHT."
  (let ((left-updated (alist-get 'updated_on left))
        (right-updated (alist-get 'updated_on right)))
    (cond
     ((and left-updated right-updated) (string> left-updated right-updated))
     (left-updated t)
     (right-updated nil)
     (t (> (or (alist-get 'id left) 0)
           (or (alist-get 'id right) 0))))))

(defun bitbucket-devops-cache--prune-pull-request-alist
    (pull-request-alist)
  "Return PULL-REQUEST-ALIST sorted and pruned for retention."
  (let ((sorted
         (mapcar
          (lambda (pull-request)
            (cons (alist-get 'id pull-request) pull-request))
          (sort
           (copy-sequence (mapcar #'cdr pull-request-alist))
           #'bitbucket-devops-cache--pull-request-newer-p))))
    (if (and
         (integerp bitbucket-devops-cache-max-pull-requests-per-repo)
         (>= bitbucket-devops-cache-max-pull-requests-per-repo 0))
        (seq-take
         sorted
         bitbucket-devops-cache-max-pull-requests-per-repo)
      sorted)))

(defun bitbucket-devops-cache-merge-pull-requests (context pull-requests)
  "Merge PULL-REQUESTS into CONTEXT's persistent cache.

Return all cached pull requests sorted by most recent update."
  (let* ((cache (bitbucket-devops-cache-read context))
         (pull-request-alist (plist-get cache :pull-requests)))
    (dolist (pull-request pull-requests)
      (when-let ((id (alist-get 'id pull-request)))
        (setq pull-request-alist
              (bitbucket-devops-cache--alist-set
               pull-request-alist
               id
               (copy-tree pull-request)))))
    (setq pull-request-alist
          (bitbucket-devops-cache--prune-pull-request-alist
           pull-request-alist))
    (setq cache (plist-put cache :pull-requests pull-request-alist))
    (bitbucket-devops-cache-write
     context
     (bitbucket-devops-cache--touch cache))
    (mapcar #'cdr pull-request-alist)))

(defun bitbucket-devops-cache-pull-requests (context)
  "Return cached pull requests for CONTEXT, newest-updated first."
  (mapcar
   #'cdr
   (bitbucket-devops-cache--prune-pull-request-alist
    (plist-get
     (bitbucket-devops-cache-read context)
     :pull-requests))))

(defun bitbucket-devops-cache-reviewer-users-cached-p (context)
  "Return non-nil when CONTEXT has a completed reviewer user lookup."
  (and bitbucket-devops-cache-enabled
       (plist-get
        (bitbucket-devops-cache-read context)
        :reviewer-users-updated-at)))

(defun bitbucket-devops-cache-reviewer-users (context)
  "Return cached pull request reviewer users for CONTEXT."
  (when bitbucket-devops-cache-enabled
    (copy-tree
     (plist-get
      (bitbucket-devops-cache-read context)
      :reviewer-users))))

(defun bitbucket-devops-cache-put-reviewer-users (context users)
  "Replace CONTEXT's cached pull request reviewer USERS."
  (when bitbucket-devops-cache-enabled
    (let ((cache (bitbucket-devops-cache-read context)))
      (setq cache (plist-put cache :reviewer-users (copy-tree users)))
      (setq cache
            (plist-put
             cache
             :reviewer-users-updated-at
             (format-time-string "%FT%TZ" nil t)))
      (bitbucket-devops-cache-write
       context
       (bitbucket-devops-cache--touch cache)))))

(defun bitbucket-devops-cache-lookup-commit (context hash)
  "Return cached commit HASH for CONTEXT, or nil."
  (when (and bitbucket-devops-cache-enabled hash)
    (cdr (assoc hash
                (plist-get
                 (bitbucket-devops-cache-read context)
                 :commits)))))

(defun bitbucket-devops-cache-put-commit (context hash commit)
  "Store COMMIT HASH for CONTEXT."
  (when (and bitbucket-devops-cache-enabled hash commit)
    (let* ((cache (bitbucket-devops-cache-read context))
           (commits
            (bitbucket-devops-cache--alist-set
             (plist-get cache :commits)
             hash
             (copy-tree commit))))
      (setq cache (plist-put cache :commits commits))
      (bitbucket-devops-cache-write
       context
       (bitbucket-devops-cache--touch cache)))))

(defun bitbucket-devops-cache-lookup-deployments (context pipeline-uuid)
  "Return cached deployments for PIPELINE-UUID in CONTEXT, or nil."
  (when (and bitbucket-devops-cache-enabled pipeline-uuid)
    (cdr (assoc pipeline-uuid
                (plist-get
                 (bitbucket-devops-cache-read context)
                 :deployments)))))

(defun bitbucket-devops-cache-deployments-cached-p
    (context pipeline-uuid)
  "Return non-nil when CONTEXT has cached PIPELINE-UUID deployments."
  (and bitbucket-devops-cache-enabled
       pipeline-uuid
       (assoc pipeline-uuid
              (plist-get
               (bitbucket-devops-cache-read context)
               :deployments))))

(defun bitbucket-devops-cache-put-deployments
    (context pipeline-uuid deployments)
  "Store DEPLOYMENTS for PIPELINE-UUID in CONTEXT."
  (when (and bitbucket-devops-cache-enabled pipeline-uuid)
    (let* ((cache (bitbucket-devops-cache-read context))
           (deployment-alist
            (bitbucket-devops-cache--alist-set
             (plist-get cache :deployments)
             pipeline-uuid
             (copy-tree deployments))))
      (setq cache (plist-put cache :deployments deployment-alist))
      (bitbucket-devops-cache-write
       context
       (bitbucket-devops-cache--touch cache)))))

(provide 'bitbucket-devops-cache)
;;; bitbucket-devops-cache.el ends here
