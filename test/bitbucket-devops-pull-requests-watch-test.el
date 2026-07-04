;;; bitbucket-devops-pull-requests-watch-test.el --- Tests for PR comment watchers -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'bitbucket-devops-pull-requests-watch)

(defconst bitbucket-devops-pull-requests-watch-test-context
  '(:workspace "williseed1"
    :repo-slug "test"
    :branch "main")
  "Repository context used by pull request watcher tests.")

(defconst bitbucket-devops-pull-requests-watch-test-pull-request
  '((id . 11)
    (title . "Development"))
  "Pull request used by watcher tests.")

(defmacro bitbucket-devops-pull-requests-watch-test-with-records (&rest body)
  "Run BODY with an isolated pull request comment watcher registry."
  `(let ((bitbucket-devops-pull-requests-watch--records
          (make-hash-table :test #'equal))
         (global-mode-string nil))
     ,@body))

(ert-deftest bitbucket-devops-pull-requests-watch-comments-polls-selected-pr ()
  (bitbucket-devops-pull-requests-watch-test-with-records
   (let (observed)
     (cl-letf (((symbol-function
                 'bitbucket-devops-pull-requests-rest-list-comments)
                (lambda (context pull-request-id _callback &optional next-url)
                  (setq observed (list context pull-request-id next-url))
                  'request-process)))
       (let ((key
              (bitbucket-devops-pull-requests-watch-comments
               bitbucket-devops-pull-requests-watch-test-context
               bitbucket-devops-pull-requests-watch-test-pull-request)))
         (should
          (equal key "williseed1/test:pull-request:11:comments"))
         (should
          (equal
           observed
           (list bitbucket-devops-pull-requests-watch-test-context 11 nil)))
         (should (= (bitbucket-devops-pull-requests-watch-active-count) 1)))))))

(ert-deftest bitbucket-devops-pull-requests-watch-comments-baselines-quietly ()
  (bitbucket-devops-pull-requests-watch-test-with-records
   (let (notifications scheduled)
     (cl-letf (((symbol-function
                 'bitbucket-devops-pull-requests-rest-list-comments)
                (lambda (_context _pull-request-id callback &optional _next-url)
                  (funcall
                   callback
                   '((values
                      . (((id . 101)
                          (user . ((display_name . "Ada Reviewer")))
                          (content . ((raw . "Existing comment")))
                          (created_on . "2026-04-28T14:20:00.000000+00:00")))))
                   nil)))
               ((symbol-function 'run-at-time)
                (lambda (delay &rest _args)
                  (setq scheduled delay)
                  'timer))
               ((symbol-function 'cancel-timer) #'ignore)
               ((symbol-function 'bitbucket-devops-pull-requests-watch--notify)
                (lambda (message) (push message notifications))))
       (let* ((key
               (bitbucket-devops-pull-requests-watch-comments
                bitbucket-devops-pull-requests-watch-test-context
                bitbucket-devops-pull-requests-watch-test-pull-request))
              (record
               (gethash key bitbucket-devops-pull-requests-watch--records)))
         (should (bitbucket-devops-pull-requests-watch--r-initialized record))
         (should
          (gethash
           101
           (bitbucket-devops-pull-requests-watch--r-seen-comment-ids record)))
         (should-not notifications)
         (should (= scheduled bitbucket-devops-pull-requests-comments-poll-interval)))))))

(ert-deftest bitbucket-devops-pull-requests-watch-comments-notifies-new-comments ()
  (bitbucket-devops-pull-requests-watch-test-with-records
   (let (notifications)
     (cl-letf (((symbol-function
                 'bitbucket-devops-pull-requests-rest-list-comments)
                (lambda (&rest _args) 'request-process))
               ((symbol-function 'run-at-time)
                (lambda (&rest _args) 'timer))
               ((symbol-function 'cancel-timer) #'ignore)
               ((symbol-function 'bitbucket-devops-pull-requests-watch--notify)
                (lambda (message) (push message notifications))))
       (let ((key
              (bitbucket-devops-pull-requests-watch-comments
               bitbucket-devops-pull-requests-watch-test-context
               bitbucket-devops-pull-requests-watch-test-pull-request)))
         (bitbucket-devops-pull-requests-watch--receive-comments
          key
          '(((id . 101)
             (user . ((display_name . "Ada Reviewer")))
             (content . ((raw . "Existing comment")))
             (created_on . "2026-04-28T14:20:00.000000+00:00")))
          nil)
         (bitbucket-devops-pull-requests-watch--receive-comments
          key
          '(((id . 101)
             (user . ((display_name . "Ada Reviewer")))
             (content . ((raw . "Existing comment")))
             (created_on . "2026-04-28T14:20:00.000000+00:00"))
            ((id . 102)
             (parent . ((id . 101)))
             (user . ((display_name . "Grace Reviewer")))
             (content . ((raw . "Can you update this branch?\nThanks.")))
             (created_on . "2026-04-28T14:25:00.000000+00:00")))
          nil)
         (should (= (length notifications) 1))
         (should
          (string-match-p
           "williseed1/test#11 Development"
           (car notifications)))
         (should (string-match-p "Grace Reviewer" (car notifications)))
         (should
          (string-match-p
           "Can you update this branch\\? Thanks\\."
           (car notifications))))))))

(ert-deftest bitbucket-devops-pull-requests-watch-comments-skips-deleted-comments ()
  (bitbucket-devops-pull-requests-watch-test-with-records
   (let (notifications)
     (cl-letf (((symbol-function
                 'bitbucket-devops-pull-requests-rest-list-comments)
                (lambda (&rest _args) 'request-process))
               ((symbol-function 'run-at-time)
                (lambda (&rest _args) 'timer))
               ((symbol-function 'cancel-timer) #'ignore)
               ((symbol-function 'bitbucket-devops-pull-requests-watch--notify)
                (lambda (message) (push message notifications))))
       (let ((key
              (bitbucket-devops-pull-requests-watch-comments
               bitbucket-devops-pull-requests-watch-test-context
               bitbucket-devops-pull-requests-watch-test-pull-request)))
         (bitbucket-devops-pull-requests-watch--receive-comments key nil nil)
         (bitbucket-devops-pull-requests-watch--receive-comments
          key
          '(((id . 103)
             (deleted . t)
             (user . ((display_name . "Grace Reviewer")))
             (content . ((raw . "")))
             (created_on . "2026-04-28T14:30:00.000000+00:00")))
          nil)
         (should-not notifications))))))

(ert-deftest bitbucket-devops-pull-requests-watch-comments-network-errors-back-off ()
  (bitbucket-devops-pull-requests-watch-test-with-records
   (let (delays)
     (cl-letf (((symbol-function
                 'bitbucket-devops-pull-requests-rest-list-comments)
                (lambda (&rest _args) 'request-process))
               ((symbol-function 'run-at-time)
                (lambda (delay &rest _args)
                  (push delay delays)
                  'timer))
               ((symbol-function 'cancel-timer) #'ignore))
       (let ((key
              (bitbucket-devops-pull-requests-watch-comments
               bitbucket-devops-pull-requests-watch-test-context
               bitbucket-devops-pull-requests-watch-test-pull-request)))
         (bitbucket-devops-pull-requests-watch--receive-comments
          key
          nil
          '(:type network))
         (bitbucket-devops-pull-requests-watch--receive-comments
          key
          nil
          '(:type network))
         (should (equal (nreverse delays) '(10 20))))))))

(ert-deftest bitbucket-devops-pull-requests-watch-comments-permanent-error-stops ()
  (bitbucket-devops-pull-requests-watch-test-with-records
   (let (notifications canceled)
     (cl-letf (((symbol-function
                 'bitbucket-devops-pull-requests-rest-list-comments)
                (lambda (&rest _args) 'request-process))
               ((symbol-function 'cancel-timer)
                (lambda (timer) (setq canceled timer)))
               ((symbol-function 'bitbucket-devops-pull-requests-watch--notify)
                (lambda (message) (push message notifications))))
       (let* ((key
               (bitbucket-devops-pull-requests-watch-comments
                bitbucket-devops-pull-requests-watch-test-context
                bitbucket-devops-pull-requests-watch-test-pull-request))
              (record
               (gethash key bitbucket-devops-pull-requests-watch--records)))
         (setf (bitbucket-devops-pull-requests-watch--r-timer record) 'timer)
         (bitbucket-devops-pull-requests-watch--receive-comments
          key
          nil
          '(:type http :status 403 :message "Forbidden"))
         (should (eq canceled 'timer))
         (should (= (bitbucket-devops-pull-requests-watch-active-count) 0))
         (should (= (length notifications) 1))
         (should (string-match-p "Forbidden" (car notifications))))))))

(provide 'bitbucket-devops-pull-requests-watch-test)
;;; bitbucket-devops-pull-requests-watch-test.el ends here
