;;; bitbucket-devops-pull-requests-watch.el --- Watch Bitbucket PR comments -*- lexical-binding: t; -*-

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

;; Poll Bitbucket Cloud pull request comments without blocking Emacs.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'bitbucket-devops-rest)
(require 'bitbucket-devops-pull-requests)
(require 'bitbucket-devops-pull-requests-rest)

(declare-function alert "ext:alert" (message &rest args))
(declare-function notifications-notify "notifications" (&rest params))
(declare-function bitbucket-devops-pipelines-watch--render-list-buffer
                  "bitbucket-devops-pipelines-watch")

(defcustom bitbucket-devops-pull-requests-comments-poll-interval 60
  "Seconds between successful Bitbucket pull request comment watcher polls."
  :type 'number
  :group 'bitbucket-devops-pull-requests)

(defcustom bitbucket-devops-pull-requests-comments-backoff-initial-delay 10
  "Initial retry delay after a transient pull request comment watcher failure."
  :type 'number
  :group 'bitbucket-devops-pull-requests)

(defcustom bitbucket-devops-pull-requests-comments-backoff-maximum-delay 300
  "Maximum retry delay after transient pull request comment watcher failures."
  :type 'number
  :group 'bitbucket-devops-pull-requests)

(defcustom bitbucket-devops-pull-requests-comments-backoff-maximum-retries 5
  "Maximum transient retries before stopping a pull request comment watcher."
  :type 'integer
  :group 'bitbucket-devops-pull-requests)

(defcustom bitbucket-devops-pull-requests-comments-notification-function nil
  "Optional function used to display pull request comment notifications.

The function receives one string argument.  When nil, use `alert.el' when it
is installed, then try built-in desktop notifications in graphical Emacs, and
fall back to `message' otherwise."
  :type '(choice
          (const :tag "Use alert.el when available, otherwise message" nil)
          (function :tag "Notification function"))
  :group 'bitbucket-devops-pull-requests)

(defcustom bitbucket-devops-pull-requests-comments-notification-title
  "Bitbucket Pull Requests"
  "Title used for pull request comment watcher notifications."
  :type 'string
  :group 'bitbucket-devops-pull-requests)

(defcustom bitbucket-devops-pull-requests-comments-notification-max-width 180
  "Maximum display width of pull request comment text in notifications."
  :type 'integer
  :group 'bitbucket-devops-pull-requests)

(defcustom bitbucket-devops-pull-requests-comments-watch-mode-line-enabled t
  "Whether active pull request comment watchers appear in the mode line."
  :type 'boolean
  :group 'bitbucket-devops-pull-requests)

(defcustom bitbucket-devops-pull-requests-comments-watch-max-age nil
  "Maximum lifetime in seconds for a pull request comment watcher.

When nil, comment watchers run until the pull request reaches a terminal state,
the user stops them, or retry handling removes them after repeated failures."
  :type '(choice
          (const :tag "No maximum lifetime" nil)
          (number :tag "Seconds"))
  :group 'bitbucket-devops-pull-requests)

;; `:noinline' keeps `cl-defstruct' from generating a compiler macro per
;; accessor.  Those carry an auto-built docstring that exceeds 80 columns
;; whenever the accessor name is long, and it cannot be shortened from here.
(cl-defstruct
    (bitbucket-devops-pull-requests-watch--record
     (:constructor bitbucket-devops-pull-requests-watch--make-record)
     (:conc-name bitbucket-devops-pull-requests-watch--r-)
     (:noinline t))
  key
  context
  pull-request-id
  title
  state
  started-at
  timer
  (failures 0)
  last-error
  seen-comment-ids
  initialized)

(defvar bitbucket-devops-pull-requests-watch--records
  (make-hash-table :test #'equal)
  "Active Bitbucket pull request comment watcher records keyed by PR identity.")

(defvar bitbucket-devops-pull-requests-comments-watch-mode-line
  '(:eval (bitbucket-devops-pull-requests-watch-mode-line-string))
  "Mode-line entry displayed while pull request comment watchers are active.")

(defun bitbucket-devops-pull-requests-watch--make-key
    (context pull-request-id)
  "Return a watcher key for CONTEXT and PULL-REQUEST-ID."
  (format "%s/%s:pull-request:%s:comments"
          (plist-get context :workspace)
          (plist-get context :repo-slug)
          pull-request-id))

(defun bitbucket-devops-pull-requests-watch-active-count ()
  "Return the number of active pull request comment watchers."
  (hash-table-count bitbucket-devops-pull-requests-watch--records))

(defun bitbucket-devops-pull-requests-watch--sorted-records ()
  "Return active pull request comment watcher records sorted by key."
  (let (records)
    (maphash
     (lambda (_key record)
       (push record records))
     bitbucket-devops-pull-requests-watch--records)
    (sort
     records
     (lambda (left right)
       (string-lessp
        (bitbucket-devops-pull-requests-watch--r-key left)
        (bitbucket-devops-pull-requests-watch--r-key right))))))

(defun bitbucket-devops-pull-requests-watch-mode-line-string ()
  "Return the aggregate pull request comment watcher mode-line text."
  (let ((count (bitbucket-devops-pull-requests-watch-active-count)))
    (when (> count 0)
      (format " PRC[%d]" count))))

(defun bitbucket-devops-pull-requests-watch--update-mode-line ()
  "Add or remove the aggregate pull request comment watcher mode-line entry."
  (if (and bitbucket-devops-pull-requests-comments-watch-mode-line-enabled
           (> (bitbucket-devops-pull-requests-watch-active-count) 0))
      (unless
          (memq
           'bitbucket-devops-pull-requests-comments-watch-mode-line
           global-mode-string)
        (setq global-mode-string
              (append
               global-mode-string
               '(bitbucket-devops-pull-requests-comments-watch-mode-line))))
    (setq global-mode-string
          (delq
           'bitbucket-devops-pull-requests-comments-watch-mode-line
           global-mode-string)))
  (when (fboundp 'bitbucket-devops-pipelines-watch--render-list-buffer)
    (bitbucket-devops-pipelines-watch--render-list-buffer))
  (force-mode-line-update t))

(defun bitbucket-devops-pull-requests-watch--normalize-state (state)
  "Return a normalized pull request STATE string, or nil."
  (when state
    (let ((value
           (string-trim
            (upcase
             (if (stringp state)
                 state
               (format "%s" state))))))
      (unless (string-empty-p value)
        value))))

(defun bitbucket-devops-pull-requests-watch--pull-request-state
    (pull-request)
  "Return PULL-REQUEST's normalized state, or nil."
  (bitbucket-devops-pull-requests-watch--normalize-state
   (alist-get 'state pull-request)))

(defun bitbucket-devops-pull-requests-watch--terminal-state-p (state)
  "Return non-nil when pull request STATE should stop comment watching."
  (let ((state (bitbucket-devops-pull-requests-watch--normalize-state state)))
    (and state (not (equal state "OPEN")))))

(defun bitbucket-devops-pull-requests-watch--active-max-age ()
  "Return the configured watcher maximum age, or nil."
  (when (and (numberp bitbucket-devops-pull-requests-comments-watch-max-age)
             (>= bitbucket-devops-pull-requests-comments-watch-max-age 0))
    bitbucket-devops-pull-requests-comments-watch-max-age))

(defun bitbucket-devops-pull-requests-watch--record-age (record)
  "Return RECORD's lifetime in seconds."
  (max 0 (- (float-time)
            (or (bitbucket-devops-pull-requests-watch--r-started-at record)
                (float-time)))))

(defun bitbucket-devops-pull-requests-watch--expired-p (record)
  "Return non-nil when RECORD has exceeded its configured lifetime."
  (when-let ((max-age
              (bitbucket-devops-pull-requests-watch--active-max-age)))
    (>= (bitbucket-devops-pull-requests-watch--record-age record)
        max-age)))

(defun bitbucket-devops-pull-requests-watch--effective-delay (record delay)
  "Return polling DELAY bounded by RECORD's remaining lifetime."
  (if-let ((max-age
            (bitbucket-devops-pull-requests-watch--active-max-age)))
      (max
       0
       (min delay
            (- max-age
               (bitbucket-devops-pull-requests-watch--record-age record))))
    delay))

(defun bitbucket-devops-pull-requests-watch--stop-expired (key record)
  "Stop RECORD identified by KEY when it has exceeded its lifetime."
  (when (bitbucket-devops-pull-requests-watch--expired-p record)
    (bitbucket-devops-pull-requests-watch--notify
     (format
      "Stopped watching PR #%s comments: watcher expired."
      (bitbucket-devops-pull-requests-watch--r-pull-request-id record)))
    (bitbucket-devops-pull-requests-watch--remove key)
    t))

(defun bitbucket-devops-pull-requests-watch--cancel-timer (record)
  "Cancel RECORD's timer when present."
  (when-let ((timer (bitbucket-devops-pull-requests-watch--r-timer record)))
    (cancel-timer timer)
    (setf (bitbucket-devops-pull-requests-watch--r-timer record) nil)))

(defun bitbucket-devops-pull-requests-watch--remove (key)
  "Stop and remove the watcher identified by KEY."
  (when-let ((record (gethash key bitbucket-devops-pull-requests-watch--records)))
    (bitbucket-devops-pull-requests-watch--cancel-timer record)
    (remhash key bitbucket-devops-pull-requests-watch--records)
    (bitbucket-devops-pull-requests-watch--update-mode-line)))

(defun bitbucket-devops-pull-requests-watch--schedule (record delay)
  "Schedule RECORD to poll after DELAY seconds."
  (bitbucket-devops-pull-requests-watch--cancel-timer record)
  (setf
   (bitbucket-devops-pull-requests-watch--r-timer record)
   (run-at-time
    (bitbucket-devops-pull-requests-watch--effective-delay record delay)
    nil
    (lambda (key)
      (when-let ((current
                  (gethash
                   key
                   bitbucket-devops-pull-requests-watch--records)))
        (setf (bitbucket-devops-pull-requests-watch--r-timer current) nil)
        (bitbucket-devops-pull-requests-watch--poll key)))
    (bitbucket-devops-pull-requests-watch--r-key record))))

(defun bitbucket-devops-pull-requests-watch--notify (message)
  "Notify the user with MESSAGE."
  (cond
   ((functionp bitbucket-devops-pull-requests-comments-notification-function)
    (funcall bitbucket-devops-pull-requests-comments-notification-function message))
   ((or (fboundp 'alert)
        (require 'alert nil t))
    (alert
     message
     :title bitbucket-devops-pull-requests-comments-notification-title))
   ((and (display-graphic-p)
         (or (fboundp 'notifications-notify)
             (require 'notifications nil t)))
    (condition-case nil
        (progn
          (notifications-notify
           :title bitbucket-devops-pull-requests-comments-notification-title
           :body message)
          (message "%s" message))
      (error
       (message "%s" message))))
   (t
    (message "%s" message))))

(defun bitbucket-devops-pull-requests-watch--describe-record (record)
  "Return a concise user-facing description for RECORD."
  (format
   "%s/%s#%s%s"
   (plist-get
    (bitbucket-devops-pull-requests-watch--r-context record)
    :workspace)
   (plist-get
    (bitbucket-devops-pull-requests-watch--r-context record)
    :repo-slug)
   (bitbucket-devops-pull-requests-watch--r-pull-request-id record)
   (if-let ((title (bitbucket-devops-pull-requests-watch--r-title record)))
       (format " %s" title)
     "")))

(defun bitbucket-devops-pull-requests-watch--comment-created-on (comment)
  "Return COMMENT creation timestamp as a string."
  (or (alist-get 'created_on comment) ""))

(defun bitbucket-devops-pull-requests-watch--comment-older-p
    (left right)
  "Return non-nil when LEFT should be notified before RIGHT."
  (string-lessp
   (bitbucket-devops-pull-requests-watch--comment-created-on left)
   (bitbucket-devops-pull-requests-watch--comment-created-on right)))

(defun bitbucket-devops-pull-requests-watch--sorted-comments (comments)
  "Return COMMENTS sorted oldest first."
  (sort
   (copy-sequence comments)
   #'bitbucket-devops-pull-requests-watch--comment-older-p))

(defun bitbucket-devops-pull-requests-watch--comment-preview (comment)
  "Return a concise one-line preview for COMMENT."
  (let ((text
         (string-trim
          (replace-regexp-in-string
           "[[:space:]\n\r]+"
           " "
           (bitbucket-devops-pull-requests-comment-text comment)))))
    (if (string-empty-p text)
        "(no text)"
      (truncate-string-to-width
       text
       bitbucket-devops-pull-requests-comments-notification-max-width
       nil
       nil
       "..."))))

(defun bitbucket-devops-pull-requests-watch--notify-comment
    (record comment)
  "Notify that COMMENT appeared on the pull request represented by RECORD."
  (bitbucket-devops-pull-requests-watch--notify
   (format
    "Bitbucket PR %s: %s commented: %s"
    (bitbucket-devops-pull-requests-watch--describe-record record)
    (bitbucket-devops-pull-requests-comment-author-name comment)
    (bitbucket-devops-pull-requests-watch--comment-preview comment))))

(defun bitbucket-devops-pull-requests-watch--transient-error-p
    (request-error)
  "Return non-nil when REQUEST-ERROR should be retried."
  (let ((type (plist-get request-error :type))
        (status (plist-get request-error :status)))
    (or (eq type 'network)
        (eq type 'rate-limit)
        (and (eq type 'http)
             (integerp status)
             (or (= status 429)
                 (<= 500 status 599))))))

(defun bitbucket-devops-pull-requests-watch--retry-delay (failures)
  "Return bounded exponential retry delay for FAILURES."
  (min bitbucket-devops-pull-requests-comments-backoff-maximum-delay
       (* bitbucket-devops-pull-requests-comments-backoff-initial-delay
          (expt 2 (max 0 (1- failures))))))

(defun bitbucket-devops-pull-requests-watch--handle-error
    (key request-error)
  "Handle REQUEST-ERROR for watcher KEY."
  (when-let ((record (gethash key bitbucket-devops-pull-requests-watch--records)))
    (setf (bitbucket-devops-pull-requests-watch--r-last-error record)
          (or (plist-get request-error :message) "request failed"))
    (if (bitbucket-devops-pull-requests-watch--transient-error-p request-error)
        (let ((failures
               (1+ (bitbucket-devops-pull-requests-watch--r-failures record))))
          (setf (bitbucket-devops-pull-requests-watch--r-failures record)
                failures)
          (bitbucket-devops-pull-requests-watch--update-mode-line)
          (cond
           ((bitbucket-devops-pull-requests-watch--stop-expired key record)
            nil)
           ((> failures
               bitbucket-devops-pull-requests-comments-backoff-maximum-retries)
            (bitbucket-devops-pull-requests-watch--notify
             (format
              "Bitbucket PR comment watcher %s stopped after repeated failures; refresh manually"
              (bitbucket-devops-pull-requests-watch--describe-record record)))
            (bitbucket-devops-pull-requests-watch--remove key))
           (t
            (bitbucket-devops-pull-requests-watch--schedule
             record
             (bitbucket-devops-pull-requests-watch--retry-delay failures)))))
      (bitbucket-devops-pull-requests-watch--notify
       (format
        "Bitbucket PR comment watcher %s stopped: %s"
        (bitbucket-devops-pull-requests-watch--describe-record record)
        (or (plist-get request-error :message) "request failed")))
      (bitbucket-devops-pull-requests-watch--remove key))))

(defun bitbucket-devops-pull-requests-watch--receive-pull-request
    (key pull-request request-error)
  "Handle PULL-REQUEST details or REQUEST-ERROR for watcher KEY."
  (if request-error
      (bitbucket-devops-pull-requests-watch--handle-error key request-error)
    (when-let ((record (gethash key bitbucket-devops-pull-requests-watch--records)))
      (when-let ((state
                  (bitbucket-devops-pull-requests-watch--pull-request-state
                   pull-request)))
        (setf (bitbucket-devops-pull-requests-watch--r-state record) state))
      (when-let ((title (alist-get 'title pull-request)))
        (setf (bitbucket-devops-pull-requests-watch--r-title record) title))
      (bitbucket-devops-pull-requests-watch--update-mode-line)
      (let ((state (bitbucket-devops-pull-requests-watch--r-state record)))
        (cond
         ((bitbucket-devops-pull-requests-watch--terminal-state-p state)
          (progn
            (bitbucket-devops-pull-requests-watch--notify
             (format
              "Stopped watching PR #%s comments: PR is %s."
              (bitbucket-devops-pull-requests-watch--r-pull-request-id record)
              state))
            (bitbucket-devops-pull-requests-watch--remove key)))
         ((bitbucket-devops-pull-requests-watch--stop-expired key record)
          nil)
         (t
          (bitbucket-devops-pull-requests-watch--collect-record-comments
           key
           record)))))))

(defun bitbucket-devops-pull-requests-watch--collect-comments
    (context pull-request-id callback &optional next-url comments)
  "Collect all comments for PULL-REQUEST-ID and invoke CALLBACK.

CONTEXT identifies the repository.  Follow NEXT-URL when present and
accumulate COMMENTS across pages.  CALLBACK receives the comments and an error
plist."
  (bitbucket-devops-pull-requests-rest-list-comments
   context
   pull-request-id
   (lambda (page request-error)
     (if request-error
         (funcall callback nil request-error)
       (let ((comments
              (append
               comments
               (bitbucket-devops-pull-requests--page-values page))))
         (if-let ((next-page (bitbucket-devops-rest-page-next page)))
             (bitbucket-devops-pull-requests-watch--collect-comments
              context
              pull-request-id
              callback
              next-page
              comments)
           (funcall callback comments nil)))))
   next-url))

(defun bitbucket-devops-pull-requests-watch--track-comment
    (record comment)
  "Mark COMMENT as seen for RECORD and return non-nil when it is new."
  (let ((comment-id (alist-get 'id comment))
        (seen (bitbucket-devops-pull-requests-watch--r-seen-comment-ids record)))
    (when comment-id
      (prog1 (not (gethash comment-id seen))
        (puthash comment-id t seen)))))

(defun bitbucket-devops-pull-requests-watch--receive-comments
    (key comments request-error)
  "Handle COMMENTS or REQUEST-ERROR for watcher KEY."
  (if request-error
      (bitbucket-devops-pull-requests-watch--handle-error key request-error)
    (when-let ((record (gethash key bitbucket-devops-pull-requests-watch--records)))
      (setf (bitbucket-devops-pull-requests-watch--r-failures record) 0)
      (setf (bitbucket-devops-pull-requests-watch--r-last-error record) nil)
      (bitbucket-devops-pull-requests-watch--update-mode-line)
      (let ((initialized
             (bitbucket-devops-pull-requests-watch--r-initialized record)))
        (dolist
            (comment
             (bitbucket-devops-pull-requests-watch--sorted-comments comments))
          (when (and
                 (not (alist-get 'deleted comment))
                 (bitbucket-devops-pull-requests-watch--track-comment
                  record
                  comment)
                 initialized)
            (bitbucket-devops-pull-requests-watch--notify-comment
             record
             comment)))
        (setf (bitbucket-devops-pull-requests-watch--r-initialized record) t)
        (unless (bitbucket-devops-pull-requests-watch--stop-expired key record)
          (bitbucket-devops-pull-requests-watch--schedule
           record
           bitbucket-devops-pull-requests-comments-poll-interval))))))

(defun bitbucket-devops-pull-requests-watch--poll (key)
  "Poll the pull request comment watcher identified by KEY immediately."
  (when-let ((record (gethash key bitbucket-devops-pull-requests-watch--records)))
    (unless (bitbucket-devops-pull-requests-watch--stop-expired key record)
      (bitbucket-devops-pull-requests-rest-get
       (bitbucket-devops-pull-requests-watch--r-context record)
       (bitbucket-devops-pull-requests-watch--r-pull-request-id record)
       (lambda (pull-request request-error)
         (bitbucket-devops-pull-requests-watch--receive-pull-request
          key
          pull-request
          request-error))))))

(defun bitbucket-devops-pull-requests-watch--collect-record-comments
    (key record)
  "Collect comments for RECORD identified by KEY."
  (bitbucket-devops-pull-requests-watch--collect-comments
   (bitbucket-devops-pull-requests-watch--r-context record)
   (bitbucket-devops-pull-requests-watch--r-pull-request-id record)
   (lambda (comments request-error)
     (bitbucket-devops-pull-requests-watch--receive-comments
      key
      comments
      request-error))))

;;;###autoload
(defun bitbucket-devops-pull-requests-watch-comments
    (context pull-request)
  "Start watching comments on PULL-REQUEST using repository CONTEXT.

The first poll establishes a quiet historical baseline.  Later polls notify
for newly seen non-deleted comments and replies.  Return the active watcher
key."
  (let* ((context (copy-tree context))
         (pull-request-id (alist-get 'id pull-request))
         (title (alist-get 'title pull-request))
         (key
          (bitbucket-devops-pull-requests-watch--make-key
           context
           pull-request-id))
         (record
          (bitbucket-devops-pull-requests-watch--make-record
           :key key
           :context context
           :pull-request-id pull-request-id
           :title title
           :state (bitbucket-devops-pull-requests-watch--pull-request-state
                   pull-request)
           :started-at (float-time)
           :seen-comment-ids (make-hash-table :test #'equal))))
    (unless pull-request-id
      (user-error "Unable to watch Bitbucket pull request comments without a pull request id"))
    (when (gethash key bitbucket-devops-pull-requests-watch--records)
      (bitbucket-devops-pull-requests-watch--remove key))
    (puthash key record bitbucket-devops-pull-requests-watch--records)
    (bitbucket-devops-pull-requests-watch--update-mode-line)
    (bitbucket-devops-pull-requests-watch--poll key)
    key))

(defun bitbucket-devops-pull-requests-watch-comments-active-p
    (context pull-request-id)
  "Return non-nil when comments are being watched for PULL-REQUEST-ID.
CONTEXT identifies the Bitbucket repository."
  (not
   (null
    (gethash
     (bitbucket-devops-pull-requests-watch--make-key context pull-request-id)
     bitbucket-devops-pull-requests-watch--records))))

;;;###autoload
(defun bitbucket-devops-pull-requests-watch-comments-stop
    (context pull-request-id)
  "Stop watching comments for PULL-REQUEST-ID in CONTEXT."
  (bitbucket-devops-pull-requests-watch--remove
   (bitbucket-devops-pull-requests-watch--make-key context pull-request-id)))

;;;###autoload
(defun bitbucket-devops-pull-requests-watch-comments-stop-by-key (key)
  "Stop the pull request comment watcher identified by KEY."
  (bitbucket-devops-pull-requests-watch--remove key))

;;;###autoload
(defun bitbucket-devops-pull-requests-watch-stop-all ()
  "Stop every active pull request comment watcher."
  (interactive)
  (maphash
   (lambda (key _record)
     (bitbucket-devops-pull-requests-watch--remove key))
   (copy-hash-table bitbucket-devops-pull-requests-watch--records))
  (message "Stopped Bitbucket pull request comment watchers"))

(provide 'bitbucket-devops-pull-requests-watch)
;;; bitbucket-devops-pull-requests-watch.el ends here
