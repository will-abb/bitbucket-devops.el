;;; bitbucket-devops-pipelines-live-test.el --- Live Bitbucket API tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Opt-in tests for a dedicated Bitbucket Cloud repository.  These tests use
;; auth-source credentials and perform real network requests.  Mutation tests
;; run only when explicitly enabled.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'seq)
(require 'subr-x)
(require 'bitbucket-devops-pipelines-magit)
(require 'bitbucket-devops-pipelines-mutate)
(require 'bitbucket-devops-rest)
(require 'bitbucket-devops-ui)
(require 'bitbucket-devops-pipelines-watch)

(defconst bitbucket-devops-pipelines-live-test-timeout 30
  "Maximum seconds to wait for one live Bitbucket API request.")

(defconst bitbucket-devops-pipelines-live-test-pipeline-timeout 180
  "Maximum seconds to wait for one live Bitbucket pipeline to complete.")

(defconst bitbucket-devops-pipelines-live-test-workspace "williseed1"
  "Bitbucket workspace used by every live integration test.")

(defconst bitbucket-devops-pipelines-live-test-repository "test"
  "Bitbucket repository used by every live integration test.")

(defconst bitbucket-devops-pipelines-live-test-repository-directory
  "~/repositories/bitbucket/williseed1/test/"
  "Local checkout used by every live integration test.")

(defun bitbucket-devops-pipelines-live-test--context ()
  "Return the dedicated `williseed1/test' live-test repository context."
  (let ((workspace bitbucket-devops-pipelines-live-test-workspace)
        (repo bitbucket-devops-pipelines-live-test-repository)
        (auth-source-host
         (getenv "BITBUCKET_DEVOPS_TEST_AUTH_SOURCE_HOST")))
    (when (and (stringp auth-source-host)
               (not (string-empty-p auth-source-host)))
      (setq bitbucket-devops-auth-rules
            (list
             (list :workspace workspace
                   :repo-slug repo
                   :auth-source-host auth-source-host))))
    (list :workspace workspace :repo-slug repo)))

(defun bitbucket-devops-pipelines-live-test--repository-directory ()
  "Return the local dedicated live-test repository directory."
  (file-name-as-directory
   (expand-file-name
    bitbucket-devops-pipelines-live-test-repository-directory)))

(defun bitbucket-devops-pipelines-live-test--await-response
    (start-request &optional timeout)
  "Run START-REQUEST and return its asynchronous `(VALUE ERROR)' response.

Wait up to TIMEOUT seconds, or `bitbucket-devops-pipelines-live-test-timeout' when
TIMEOUT is nil."
  (let ((deadline (+ (float-time)
                     (or timeout bitbucket-devops-pipelines-live-test-timeout)))
        done
        request-error
        result)
    (funcall
     start-request
     (lambda (value error-value)
       (setq result value)
       (setq request-error error-value)
       (setq done t)))
    (while (and (not done) (< (float-time) deadline))
      (accept-process-output nil 0.1))
    (unless done
      (ert-fail "Timed out waiting for live Bitbucket API response"))
    (list result request-error)))

(defun bitbucket-devops-pipelines-live-test--await (start-request &optional timeout)
  "Run START-REQUEST and return its asynchronous Bitbucket API result."
  (pcase-let
      ((`(,result ,request-error)
        (bitbucket-devops-pipelines-live-test--await-response
         start-request timeout)))
    (when request-error
      (ert-fail
       (format "Live Bitbucket API request failed%s: %s"
               (if-let ((status (plist-get request-error :status)))
                   (format " (HTTP %s)" status)
                 "")
               (plist-get request-error :message))))
    result))

(defun bitbucket-devops-pipelines-live-test--transient-error-p (request-error)
  "Return non-nil when REQUEST-ERROR should be retried by a live poll."
  (memq (plist-get request-error :status) '(429 500 502 503 504)))

(defun bitbucket-devops-pipelines-live-test--wait-until (predicate description
                                                           &optional timeout)
  "Wait until PREDICATE return is non-nil or fail with DESCRIPTION.

Wait up to TIMEOUT seconds, or `bitbucket-devops-pipelines-live-test-timeout' when
TIMEOUT is nil."
  (let ((deadline (+ (float-time)
                     (or timeout bitbucket-devops-pipelines-live-test-timeout))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.1))
    (unless (funcall predicate)
      (ert-fail (format "Timed out waiting for %s" description)))))

(defun bitbucket-devops-pipelines-live-test--await-terminal (context pipeline-uuid)
  "Return terminal PIPELINE-UUID details from CONTEXT before the timeout."
  (let ((deadline (+ (float-time)
                     bitbucket-devops-pipelines-live-test-pipeline-timeout))
        pipeline)
    (while (and (< (float-time) deadline)
                (not
                 (equal
                  (alist-get 'name (alist-get 'state pipeline))
                  "COMPLETED")))
      (pcase-let
          ((`(,value ,request-error)
            (bitbucket-devops-pipelines-live-test--await-response
             (lambda (callback)
               (bitbucket-devops-rest-get-pipeline
                context pipeline-uuid callback)))))
        (cond
         ((null request-error)
          (setq pipeline value))
         ((not
           (bitbucket-devops-pipelines-live-test--transient-error-p
            request-error))
          (ert-fail
           (format "Live Bitbucket pipeline poll failed%s: %s"
                   (if-let ((status (plist-get request-error :status)))
                       (format " (HTTP %s)" status)
                     "")
                   (plist-get request-error :message))))))
      (unless
          (equal (alist-get 'name (alist-get 'state pipeline)) "COMPLETED")
        (accept-process-output nil 1)))
    (unless
        (equal (alist-get 'name (alist-get 'state pipeline)) "COMPLETED")
      (ert-fail "Timed out waiting for live Bitbucket pipeline completion"))
    pipeline))

(defun bitbucket-devops-pipelines-live-test--clear-watchers ()
  "Cancel live integration watcher timers and remove their records."
  (maphash
   (lambda (_key record)
     (bitbucket-devops-pipelines-watch--cancel-timer record))
   bitbucket-devops-pipelines-watch--records)
  (clrhash bitbucket-devops-pipelines-watch--records)
  (bitbucket-devops-pipelines-watch--update-mode-line))

(defun bitbucket-devops-pipelines-live-test--require-mutations ()
  "Skip the current test unless remote mutations were explicitly enabled."
  (unless (equal (getenv "BITBUCKET_DEVOPS_TEST_MUTATIONS") "1")
    (ert-skip "Set BITBUCKET_DEVOPS_TEST_MUTATIONS=1 to mutate remote state")))

(defun bitbucket-devops-pipelines-live-test--run-public-trigger (invocation)
  "Run public trigger INVOCATION and return its asynchronous pipeline result."
  (let ((original-trigger (symbol-function 'bitbucket-devops-pipelines-mutate-trigger))
        done
        pipeline
        request-error)
    (cl-letf
        (((symbol-function 'bitbucket-devops-pipelines-mutate-trigger)
          (lambda (context body &optional _callback deployments)
            (funcall
             original-trigger
             context
             body
             (lambda (value error-value)
               (setq pipeline value)
               (setq request-error error-value)
               (setq done t))
             deployments))))
      (funcall invocation)
      (bitbucket-devops-pipelines-live-test--wait-until
       (lambda () done)
       "public pipeline trigger callback"))
    (when request-error
      (ert-fail
       (format "Public Bitbucket pipeline trigger failed: %s"
               (plist-get request-error :message))))
    pipeline))

(defun bitbucket-devops-pipelines-live-test--first-terminal-step (context pipeline-uuid)
  "Return the first terminal PIPELINE-UUID step record from CONTEXT."
  (seq-find
   #'bitbucket-devops-pipelines-live-test--terminal-step-p
   (bitbucket-devops-rest-page-values
    (bitbucket-devops-pipelines-live-test--await
     (lambda (callback)
       (bitbucket-devops-rest-list-steps context pipeline-uuid callback))))))

(defun bitbucket-devops-pipelines-live-test--step-log (context pipeline-uuid step)
  "Return STEP log text for PIPELINE-UUID in CONTEXT."
  (bitbucket-devops-pipelines-live-test--await
   (lambda (callback)
     (bitbucket-devops-rest-get-step-log
      context pipeline-uuid (alist-get 'uuid step) callback))))

(defun bitbucket-devops-pipelines-live-test--all-steps (context pipeline-uuid)
  "Return every PIPELINE-UUID step record from CONTEXT."
  (let (done steps request-error)
    (bitbucket-devops-ui--list-all-steps
     context
     pipeline-uuid
     (lambda (value error-value)
       (setq steps value)
       (setq request-error error-value)
       (setq done t)))
    (bitbucket-devops-pipelines-live-test--wait-until
     (lambda () done)
     "complete live pipeline step listing")
    (when request-error
      (ert-fail
       (format "Live Bitbucket pipeline step listing failed: %s"
               (plist-get request-error :message))))
    steps))

(defun bitbucket-devops-pipelines-live-test--download-logs
    (context pipeline steps directory)
  "Download PIPELINE STEPS from CONTEXT into DIRECTORY and return callback data."
  (let (done saved unavailable)
    (bitbucket-devops-ui--download-logs
     context
     pipeline
     steps
     (lambda (saved-value unavailable-value)
       (setq saved saved-value)
       (setq unavailable unavailable-value)
       (setq done t))
     directory)
    (bitbucket-devops-pipelines-live-test--wait-until
     (lambda () done)
     "complete live pipeline log download")
    (list saved unavailable)))

(defun bitbucket-devops-pipelines-live-test--terminal-step-p (step)
  "Return non-nil when STEP has completed and should expose a log."
  (equal (alist-get 'name (alist-get 'state step)) "COMPLETED"))

(ert-deftest bitbucket-devops-pipelines-live-read-contract ()
  (let* ((context (bitbucket-devops-pipelines-live-test--context))
         (page
          (bitbucket-devops-pipelines-live-test--await
           (lambda (callback)
             (bitbucket-devops-rest-list-pipelines context callback))))
         (pipeline
          (seq-find
           (lambda (candidate)
             (equal
              (bitbucket-devops-ui--pipeline-state-label candidate)
              "SUCCESSFUL"))
           (bitbucket-devops-rest-page-values page)))
         (commit-hash
          (bitbucket-devops-ui--nested-get pipeline 'target 'commit 'hash))
         (pipeline-uuid (alist-get 'uuid pipeline)))
    (should pipeline-uuid)
    (should commit-hash)
    (let* ((commit
            (bitbucket-devops-pipelines-live-test--await
             (lambda (callback)
               (bitbucket-devops-rest-get-commit
                context commit-hash callback))))
           (details
            (bitbucket-devops-pipelines-live-test--await
             (lambda (callback)
               (bitbucket-devops-rest-get-pipeline
                context pipeline-uuid callback))))
           (steps-page
            (bitbucket-devops-pipelines-live-test--await
             (lambda (callback)
               (bitbucket-devops-rest-list-steps
                context pipeline-uuid callback))))
           (step
            (seq-find
             #'bitbucket-devops-pipelines-live-test--terminal-step-p
             (bitbucket-devops-rest-page-values steps-page)))
           (step-uuid (alist-get 'uuid step)))
      (should (alist-get 'message commit))
      (should (bitbucket-devops-ui--nested-get commit 'author 'raw))
      (should (equal (alist-get 'uuid details) pipeline-uuid))
      (should step-uuid)
      (let ((log
             (bitbucket-devops-pipelines-live-test--await
              (lambda (callback)
                (bitbucket-devops-rest-get-step-log
                 context pipeline-uuid step-uuid callback)))))
        (should (stringp log))
        (should (not (string-empty-p log)))))))

(ert-deftest bitbucket-devops-pipelines-live-branch-subscription-baselines-history ()
  (let* ((context (bitbucket-devops-pipelines-live-test--context))
         (page
          (bitbucket-devops-pipelines-live-test--await
           (lambda (callback)
             (bitbucket-devops-rest-list-pipelines context callback))))
         (pipeline
          (seq-find
           (lambda (candidate)
             (bitbucket-devops-pipelines-watch--pipeline-branch candidate))
           (bitbucket-devops-rest-page-values page))))
    (unless pipeline
      (ert-skip "Newest live pipeline page does not contain a branch target"))
    (let* ((pipeline-uuid (alist-get 'uuid pipeline))
           (branch (bitbucket-devops-pipelines-watch--pipeline-branch pipeline))
           key)
      (unwind-protect
          (progn
            (setq key (bitbucket-devops-pipelines-watch-branch context branch))
            (bitbucket-devops-pipelines-live-test--wait-until
             (lambda ()
               (when-let ((record
                           (gethash key bitbucket-devops-pipelines-watch--records)))
                 (bitbucket-devops-pipelines-watch--r-initialized record)))
             "persistent branch subscription baseline")
            (let ((record
                   (gethash key bitbucket-devops-pipelines-watch--records)))
              (should (eq (bitbucket-devops-pipelines-watch--r-kind record) 'branch))
              (should
               (gethash
                pipeline-uuid
                (bitbucket-devops-pipelines-watch--r-seen-pipeline-uuids record)))))
        (bitbucket-devops-pipelines-live-test--clear-watchers)))))

(ert-deftest bitbucket-devops-pipelines-live-mutation-trigger-watcher-and-log ()
  (bitbucket-devops-pipelines-live-test--require-mutations)
  (let* ((context (bitbucket-devops-pipelines-live-test--context))
         (message-text
          (format "mutation smoke %s" (format-time-string "%Y%m%d%H%M%S")))
         (body
          (bitbucket-devops-pipelines-mutate-branch-body
           "main"
           "manual-smoke"
           (list (list :key "MESSAGE" :value message-text))))
         pipeline
         pipeline-uuid)
    (unwind-protect
        (let ((bitbucket-devops-pipelines-poll-interval 1)
              (bitbucket-devops-pipelines-production-confirmation-function
               (lambda (&rest _args) t)))
          (bitbucket-devops-pipelines-live-test--clear-watchers)
          (setq pipeline
                (bitbucket-devops-pipelines-live-test--await
                 (lambda (callback)
                   (bitbucket-devops-pipelines-mutate-trigger
                    context body callback))))
          (setq pipeline-uuid (alist-get 'uuid pipeline))
          (should pipeline-uuid)
          (should
           (gethash
            (bitbucket-devops-pipelines-watch--make-key context pipeline-uuid)
            bitbucket-devops-pipelines-watch--records))
          (bitbucket-devops-pipelines-live-test--await-terminal context pipeline-uuid)
          (let* ((steps-page
                  (bitbucket-devops-pipelines-live-test--await
                   (lambda (callback)
                     (bitbucket-devops-rest-list-steps
                      context pipeline-uuid callback))))
                 (step
                  (seq-find
                   #'bitbucket-devops-pipelines-live-test--terminal-step-p
                   (bitbucket-devops-rest-page-values steps-page)))
                 (log
                  (bitbucket-devops-pipelines-live-test--await
                   (lambda (callback)
                     (bitbucket-devops-rest-get-step-log
                      context pipeline-uuid (alist-get 'uuid step) callback)))))
            (should (string-match-p (regexp-quote message-text) log))))
      (bitbucket-devops-pipelines-live-test--clear-watchers))))

(ert-deftest bitbucket-devops-pipelines-live-mutation-stop ()
  (bitbucket-devops-pipelines-live-test--require-mutations)
  (let* ((context (bitbucket-devops-pipelines-live-test--context))
         (pipeline
          (bitbucket-devops-pipelines-live-test--await
           (lambda (callback)
             (bitbucket-devops-rest-run-pipeline
              context
              (bitbucket-devops-pipelines-mutate-branch-body
               "main"
               (or (getenv "BITBUCKET_DEVOPS_TEST_CANCEL_SELECTOR")
                   "cancel-smoke"))
              callback))))
         (pipeline-uuid (alist-get 'uuid pipeline))
         terminal)
    (should pipeline-uuid)
    (unwind-protect
        (progn
          (with-temp-buffer
            (setq-local bitbucket-devops-ui--context context)
            (setq-local bitbucket-devops-ui--details-pipeline pipeline)
            (cl-letf (((symbol-function 'y-or-n-p)
                       (lambda (&rest _args) t)))
              (bitbucket-devops-pipelines-stop)))
          (setq terminal
                (bitbucket-devops-pipelines-live-test--await-terminal
                 context pipeline-uuid))
          (should
           (member
            (alist-get 'name (alist-get 'result (alist-get 'state terminal)))
            '("STOPPED" "ERROR"))))
      (unless
          (equal (alist-get 'name (alist-get 'state terminal)) "COMPLETED")
        (bitbucket-devops-pipelines-live-test--await
         (lambda (callback)
           (bitbucket-devops-rest-stop-pipeline
            context pipeline-uuid callback)))))))

(ert-deftest bitbucket-devops-pipelines-live-mutation-multi-step-and-deployment-logs ()
  (bitbucket-devops-pipelines-live-test--require-mutations)
  (let ((context (bitbucket-devops-pipelines-live-test--context))
        (directory (make-temp-file "bitbucket-devops-pipelines-multi-live-" t)))
    (unwind-protect
        (dolist
            (scenario
             `((,(or (getenv "BITBUCKET_DEVOPS_TEST_MULTI_STEP_SELECTOR")
                     "multi-step-smoke")
                2)
               (,(or (getenv "BITBUCKET_DEVOPS_TEST_DEPLOYMENT_SELECTOR")
                     "deployment-smoke")
                3)))
          (let* ((selector (car scenario))
                 (expected-step-count (cadr scenario))
                 (pipeline
                  (bitbucket-devops-pipelines-live-test--await
                   (lambda (callback)
                     (bitbucket-devops-rest-run-pipeline
                      context
                      (bitbucket-devops-pipelines-mutate-branch-body
                       "main"
                       selector)
                      callback))))
                 (pipeline-uuid (alist-get 'uuid pipeline))
                 terminal
                 steps
                 download-result)
            (should pipeline-uuid)
            (setq terminal
                  (bitbucket-devops-pipelines-live-test--await-terminal
                   context pipeline-uuid))
            (should
             (equal
              (bitbucket-devops-ui--pipeline-state-label terminal)
              "SUCCESSFUL"))
            (setq steps
                  (bitbucket-devops-pipelines-live-test--all-steps
                   context
                   pipeline-uuid))
            (should (= (length steps) expected-step-count))
            (setq download-result
                  (bitbucket-devops-pipelines-live-test--download-logs
                   context
                   terminal
                   steps
                   directory))
            (should (= (length (car download-result)) expected-step-count))
            (should-not (cadr download-result))
            (dolist (file (car download-result))
              (should (file-exists-p file))
              (should (> (file-attribute-size (file-attributes file)) 0)))))
      (delete-directory directory t))))

(ert-deftest bitbucket-devops-pipelines-live-magit-push-watch ()
  (bitbucket-devops-pipelines-live-test--require-mutations)
  (require 'magit)
  (let* ((directory (bitbucket-devops-pipelines-live-test--repository-directory))
         (context (bitbucket-devops-context-resolve directory))
         (original-watch-commit
          (symbol-function 'bitbucket-devops-pipelines-watch-commit))
         (bitbucket-devops-pipelines-poll-interval 1)
         hook-context
         watched-context)
    (unwind-protect
        (cl-letf
            (((symbol-function 'bitbucket-devops-pipelines-watch-commit)
              (lambda (captured-context)
                (setq watched-context captured-context)
                (funcall original-watch-commit captured-context))))
          (let ((hook-function
                 (lambda (captured-context)
                   (setq hook-context captured-context))))
            (unwind-protect
                (progn
                  (add-hook 'bitbucket-devops-pipelines-after-magit-push-hook
                            hook-function
                            t)
                  (bitbucket-devops-pipelines-magit-push-watch-mode 1)
                  (let ((default-directory directory))
                    (let ((process (magit-run-git-async
                                    "push" "-v" "origin" "main")))
                      (bitbucket-devops-pipelines-live-test--wait-until
                       (lambda ()
                         (memq (process-status process) '(exit signal)))
                       "Magit push completion")
                      (should (eq (process-status process) 'exit))
                      (should (zerop (process-exit-status process)))))
                  (bitbucket-devops-pipelines-live-test--wait-until
                   (lambda () hook-context)
                   "Magit post-push hook")
                  (bitbucket-devops-pipelines-live-test--wait-until
                   (lambda () watched-context)
                   "Magit post-push watcher")
                  (should (equal hook-context context))
                  (should (equal watched-context context))
                  (bitbucket-devops-pipelines-live-test--wait-until
                   (lambda ()
                     (zerop (bitbucket-devops-pipelines-watch-active-count)))
                   "Magit push watcher completion"
                   bitbucket-devops-pipelines-live-test-pipeline-timeout))
              (remove-hook 'bitbucket-devops-pipelines-after-magit-push-hook
                           hook-function)
              (bitbucket-devops-pipelines-magit-push-watch-mode -1))))
      (bitbucket-devops-pipelines-live-test--clear-watchers))))

(ert-deftest bitbucket-devops-pipelines-live-workflows ()
  (bitbucket-devops-pipelines-live-test--require-mutations)
  (let* ((directory (bitbucket-devops-pipelines-live-test--repository-directory))
         (context (bitbucket-devops-context-resolve directory))
         (workspace bitbucket-devops-pipelines-live-test-workspace)
         (repo-slug bitbucket-devops-pipelines-live-test-repository)
         (bitbucket-devops-pipelines-poll-interval 1)
         (bitbucket-devops-pipelines-last-variable-metadata nil)
         (bitbucket-devops-pipelines-production-confirmation-function
          (lambda (&rest _args) t))
         (download-directory (make-temp-file "bitbucket-devops-pipelines-live-" t))
         (auto-download-directory
          (make-temp-file "bitbucket-devops-pipelines-auto-live-" t))
         branch-pipeline
         custom-pipeline
         rerun-pipeline)
    (unwind-protect
        (progn
          (should (equal (plist-get context :workspace) workspace))
          (should (equal (plist-get context :repo-slug) repo-slug))
          (should (equal (plist-get context :branch) "main"))
          (should (plist-get context :commit))

          (setq branch-pipeline
                (cl-letf
                    (((symbol-function 'completing-read)
                      (lambda (&rest _args)
                        "default")))
                  (bitbucket-devops-pipelines-live-test--run-public-trigger
                   (lambda ()
                     (bitbucket-devops-pipelines-run-configured directory)))))
          (bitbucket-devops-pipelines-live-test--await-terminal
           context (alist-get 'uuid branch-pipeline))

          (let ((message-text
                 (format "interactive smoke %s"
                         (format-time-string "%Y%m%d%H%M%S"))))
            (setq custom-pipeline
                  (cl-letf
                      (((symbol-function 'completing-read)
                        (lambda (&rest _args) "custom: manual-smoke"))
                       ((symbol-function 'read-string)
                        (lambda (&rest _args) ""))
                       ((symbol-function
                         'bitbucket-devops-pipelines-mutate--read-variable-value)
                        (lambda (&rest _args) message-text)))
                    (bitbucket-devops-pipelines-live-test--run-public-trigger
                     (lambda ()
                       (bitbucket-devops-pipelines-run-configured directory)))))
            (bitbucket-devops-pipelines-live-test--await-terminal
             context (alist-get 'uuid custom-pipeline))
            (should
             (string-match-p
              (regexp-quote message-text)
              (bitbucket-devops-pipelines-live-test--step-log
               context
               (alist-get 'uuid custom-pipeline)
               (bitbucket-devops-pipelines-live-test--first-terminal-step
                context (alist-get 'uuid custom-pipeline))))))

          (setq bitbucket-devops-pipelines-last-variable-metadata nil)
          (with-temp-buffer
            (setq-local bitbucket-devops-ui--context context)
            (setq-local bitbucket-devops-ui--details-pipeline
                        custom-pipeline)
            (cl-letf
                (((symbol-function 'read-string) (lambda (&rest _args) "")))
              (setq rerun-pipeline
                    (bitbucket-devops-pipelines-live-test--run-public-trigger
                     #'bitbucket-devops-pipelines-rerun))))
          (bitbucket-devops-pipelines-live-test--await-terminal
           context (alist-get 'uuid rerun-pipeline))

          (let ((history-buffer (bitbucket-devops-pipelines-history directory)))
            (with-current-buffer history-buffer
              (bitbucket-devops-pipelines-live-test--wait-until
               (lambda () (not bitbucket-devops-ui--history-loading))
               "history buffer loading")
              (should bitbucket-devops-ui--history-pipelines))
            (kill-buffer history-buffer))

          (let* ((pipeline-uuid (alist-get 'uuid custom-pipeline))
                 (details-buffer
                  (bitbucket-devops-pipelines-details context pipeline-uuid)))
            (with-current-buffer details-buffer
              (bitbucket-devops-pipelines-live-test--wait-until
               (lambda () (not bitbucket-devops-ui--details-loading))
               "details buffer loading")
              (should bitbucket-devops-ui--details-steps)
              (let* ((step
                      (seq-find
                       #'bitbucket-devops-ui--step-terminal-p
                       bitbucket-devops-ui--details-steps))
                     (step-uuid (alist-get 'uuid step)))
                (let ((inhibit-read-only t))
                  (erase-buffer)
                  (insert
                   (propertize "step" 'tabulated-list-id step-uuid)))
                (goto-char (point-min))
                (bitbucket-devops-pipelines-view-step-log)
                (bitbucket-devops-pipelines-live-test--wait-until
                 (lambda ()
                   (get-buffer
                    (bitbucket-devops-ui--log-buffer-name
                     context custom-pipeline step)))
                 "completed step log buffer")
                (let ((bitbucket-devops-pipelines-log-download-directory
                       download-directory))
                  (bitbucket-devops-pipelines-download-logs)
                  (bitbucket-devops-pipelines-live-test--wait-until
                   (lambda ()
                     (directory-files download-directory nil "\\.log\\'"))
                   "downloaded step log"))))
            (kill-buffer details-buffer))

          (bitbucket-devops-pipelines-live-test--clear-watchers)
          (bitbucket-devops-pipelines-watch-current directory)
          (bitbucket-devops-pipelines-live-test--wait-until
           (lambda () (zerop (bitbucket-devops-pipelines-watch-active-count)))
           "commit-discovery watcher completion")

          (bitbucket-devops-pipelines-live-test--clear-watchers)
          (let ((bitbucket-devops-pipelines-auto-download-logs t)
                (bitbucket-devops-pipelines-log-download-directory
                 auto-download-directory))
            (with-temp-buffer
              (bitbucket-devops-pipelines-details-mode)
              (setq-local bitbucket-devops-ui--context context)
              (setq-local bitbucket-devops-ui--details-pipeline-uuid
                          (alist-get 'uuid custom-pipeline))
              (bitbucket-devops-pipelines-watch-selected))
            (bitbucket-devops-pipelines-live-test--wait-until
             (lambda ()
               (directory-files auto-download-directory nil "\\.log\\'"))
             "watcher automatic log download")))
      (bitbucket-devops-pipelines-live-test--clear-watchers)
      (delete-directory download-directory t)
      (delete-directory auto-download-directory t))))

(provide 'bitbucket-devops-pipelines-live-test)
;;; bitbucket-devops-pipelines-live-test.el ends here
