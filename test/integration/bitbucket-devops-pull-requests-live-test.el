;;; bitbucket-devops-pull-requests-live-test.el --- Live PR API tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Opt-in, read-only contract tests for pull requests in the dedicated
;; Bitbucket Cloud integration repository.

;;; Code:

(require 'ert)
(require 'bitbucket-devops-pipelines-live-test)
(require 'bitbucket-devops-pull-requests)
(require 'bitbucket-devops-pull-requests-rest)
(require 'bitbucket-devops-pull-requests-ui)

(defun bitbucket-devops-pull-requests-live-test--collect
    (rest-function context pull-request-id)
  "Return every REST-FUNCTION value for PULL-REQUEST-ID in CONTEXT."
  (condition-case error
      (bitbucket-devops-pipelines-live-test--await
       (lambda (callback)
         (bitbucket-devops-pull-requests-ui--collect-pages
          rest-function context pull-request-id callback)))
    (ert-test-failed
     (ert-fail
      (format "%s failed: %s"
              rest-function
              (error-message-string error))))))

(defun bitbucket-devops-pull-requests-live-test--await-response (start-request)
  "Return `(VALUE ERROR)' from asynchronous START-REQUEST without failing."
  (bitbucket-devops-pipelines-live-test--await-response start-request))

(defun bitbucket-devops-pull-requests-live-test--allow-missing-revision
    (response endpoint)
  "Return RESPONSE value, allowing a revision-backed ENDPOINT to return 404."
  (pcase-let ((`(,value ,error) response))
    (cond
     ((null error) value)
     ((= (or (plist-get error :status) 0) 404) nil)
     (t
      (ert-fail
       (format "%s failed%s: %s"
               endpoint
               (if-let ((status (plist-get error :status)))
                   (format " (HTTP %s)" status)
                 "")
               (plist-get error :message)))))))

(ert-deftest bitbucket-devops-pull-requests-live-read-contract ()
  (let* ((context (bitbucket-devops-pipelines-live-test--context))
         (page
          (bitbucket-devops-pipelines-live-test--await
           (lambda (callback)
             (bitbucket-devops-pull-requests-rest-list
              context callback nil "OPEN"))))
         (pull-request
          (car (bitbucket-devops-rest-page-values page))))
    (unless pull-request
      (ert-skip "Dedicated repository has no pull request to inspect"))
    (let* ((pull-request-id (alist-get 'id pull-request))
           (details
            (bitbucket-devops-pipelines-live-test--await
             (lambda (callback)
               (bitbucket-devops-pull-requests-rest-get
                context pull-request-id callback))))
           (activity
            (bitbucket-devops-pull-requests-live-test--collect
             #'bitbucket-devops-pull-requests-rest-list-activity
             context pull-request-id))
           (comments
            (bitbucket-devops-pull-requests-live-test--collect
             #'bitbucket-devops-pull-requests-rest-list-comments
             context pull-request-id))
           (commits
            (bitbucket-devops-pull-requests-live-test--collect
             #'bitbucket-devops-pull-requests-rest-list-commits
             context pull-request-id))
           (statuses
            (bitbucket-devops-pull-requests-live-test--collect
             #'bitbucket-devops-pull-requests-rest-list-statuses
             context pull-request-id))
           (tasks
            (bitbucket-devops-pull-requests-live-test--collect
             #'bitbucket-devops-pull-requests-rest-list-tasks
             context pull-request-id))
           (diffstat
            (bitbucket-devops-pull-requests-live-test--allow-missing-revision
             (bitbucket-devops-pull-requests-live-test--await-response
              (lambda (callback)
                (bitbucket-devops-pull-requests-ui--collect-pages
                 #'bitbucket-devops-pull-requests-rest-list-diffstat
                 context pull-request-id callback)))
             "pull request diffstat"))
           (diff
            (bitbucket-devops-pull-requests-live-test--allow-missing-revision
             (bitbucket-devops-pull-requests-live-test--await-response
              (lambda (callback)
                (bitbucket-devops-pull-requests-rest-get-diff
                 context pull-request-id callback)))
             "pull request diff")))
      (should (integerp pull-request-id))
      (should (equal (alist-get 'id details) pull-request-id))
      (should (stringp (alist-get 'title details)))
      (should (stringp (bitbucket-devops-pull-requests-source-branch details)))
      (should (stringp (bitbucket-devops-pull-requests-destination-branch details)))
      (should (listp activity))
      (should (listp comments))
      (should (listp commits))
      (should (listp statuses))
      (should (listp tasks))
      (should (listp diffstat))
      (should (or (null diff) (stringp diff))))))

(provide 'bitbucket-devops-pull-requests-live-test)
;;; bitbucket-devops-pull-requests-live-test.el ends here
