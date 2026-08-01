;;; bitbucket-devops-pipelines-watch-test.el --- Tests for pipeline watchers -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'bitbucket-devops-pipelines-watch)

(defconst bitbucket-devops-pipelines-watch-test-context
  '(:workspace "williseed1"
    :repo-slug "test"
    :branch "main"
    :commit "0123456789abcdef")
  "Repository context used by watcher tests.")

(defmacro bitbucket-devops-pipelines-watch-test-with-records (&rest body)
  "Run BODY with an isolated watcher registry."
  `(let ((bitbucket-devops-pipelines-watch--records
          (make-hash-table :test #'equal))
         (bitbucket-devops-pull-requests-watch--records
          (make-hash-table :test #'equal))
         (global-mode-string nil))
     (cl-letf (((symbol-function
                 'bitbucket-devops-ui--list-all-paused-pipelines)
                (lambda (_context callback &rest _args)
                  (funcall callback nil nil))))
       ,@body)))

(ert-deftest bitbucket-devops-pipelines-watch-pipeline-terminal-p-detects-completion ()
  (should
   (bitbucket-devops-pipelines-watch--pipeline-terminal-p
    '((state . ((name . "COMPLETED"))))))
  (should-not
   (bitbucket-devops-pipelines-watch--pipeline-terminal-p
    '((state . ((name . "IN_PROGRESS")))))))

(ert-deftest bitbucket-devops-pipelines-watch-normalizes-paused-state ()
  (let ((pipeline
         '((state . ((name . "IN_PROGRESS")
                     (result . ((name . "PAUSED"))))))))
    (should
     (equal (bitbucket-devops-pipelines-watch--pipeline-state pipeline) "PAUSED"))
    (should-not (bitbucket-devops-pipelines-watch--pipeline-result pipeline))
    (should-not (bitbucket-devops-pipelines-watch--pipeline-terminal-p pipeline))))

(ert-deftest bitbucket-devops-pipelines-watch-retry-delay-is-bounded-exponential ()
  (let ((bitbucket-devops-pipelines-backoff-initial-delay 5)
        (bitbucket-devops-pipelines-backoff-maximum-delay 12))
    (should (= (bitbucket-devops-pipelines-watch--retry-delay 1) 5))
    (should (= (bitbucket-devops-pipelines-watch--retry-delay 2) 10))
    (should (= (bitbucket-devops-pipelines-watch--retry-delay 3) 12))))

(ert-deftest bitbucket-devops-pipelines-watch-pipeline-polls-returned-uuid-immediately ()
  (bitbucket-devops-pipelines-watch-test-with-records
   (let (observed)
     (cl-letf (((symbol-function 'bitbucket-devops-rest-get-pipeline)
                (lambda (context pipeline-uuid _callback)
                  (setq observed (list context pipeline-uuid))
                  'request-process)))
       (bitbucket-devops-pipelines-watch-pipeline
        bitbucket-devops-pipelines-watch-test-context
        "{pipeline-12}")
       (should
        (equal
         observed
         (list bitbucket-devops-pipelines-watch-test-context "{pipeline-12}")))
       (should (= (bitbucket-devops-pipelines-watch-active-count) 1))))))

(ert-deftest bitbucket-devops-pipelines-watch-commit-discovers-captured-commit ()
  (bitbucket-devops-pipelines-watch-test-with-records
   (let (observed)
     (cl-letf (((symbol-function
                 'bitbucket-devops-rest-list-pipelines-for-commit)
                (lambda (context commit _callback)
                  (setq observed (list context commit))
                  'request-process)))
       (bitbucket-devops-pipelines-watch-commit bitbucket-devops-pipelines-watch-test-context)
       (should
        (equal
         observed
         (list
          bitbucket-devops-pipelines-watch-test-context
          "0123456789abcdef")))
       (should (= (bitbucket-devops-pipelines-watch-active-count) 1))))))

(ert-deftest bitbucket-devops-pipelines-watch-branch-polls-history-immediately ()
  (bitbucket-devops-pipelines-watch-test-with-records
   (let (observed)
     (cl-letf (((symbol-function 'bitbucket-devops-rest-list-pipelines)
                (lambda (context _callback)
                  (setq observed context)
                  'request-process)))
       (let* ((key
               (bitbucket-devops-pipelines-watch-branch
                bitbucket-devops-pipelines-watch-test-context
                "release"))
              (record (gethash key bitbucket-devops-pipelines-watch--records)))
         (should
          (equal key "williseed1/test:branch:release"))
         (should
          (equal (plist-get observed :branch) "release"))
         (should (eq (bitbucket-devops-pipelines-watch--r-kind record) 'branch))
         (should
          (equal (bitbucket-devops-pipelines-watch--r-state record) "SUBSCRIBED"))
         (should (= (bitbucket-devops-pipelines-watch-active-count) 1)))))))

(ert-deftest bitbucket-devops-pipelines-watch-branch-baselines-old-runs-and-watches-new-runs ()
  (bitbucket-devops-pipelines-watch-test-with-records
   (let (watched)
     (cl-letf (((symbol-function 'bitbucket-devops-rest-list-pipelines)
                (lambda (&rest _args) 'request-process))
               ((symbol-function 'bitbucket-devops-pipelines-watch-pipeline)
                (lambda (_context pipeline-uuid)
                  (push pipeline-uuid watched)))
               ((symbol-function 'run-at-time)
                (lambda (&rest _args) 'timer))
               ((symbol-function 'cancel-timer) #'ignore))
       (let ((key
              (bitbucket-devops-pipelines-watch-branch
               bitbucket-devops-pipelines-watch-test-context
               "main")))
         (bitbucket-devops-pipelines-watch--receive-branch
          key
          '((values
             . (((uuid . "{old-completed}")
                 (target . ((ref_name . "main")))
                 (state . ((name . "COMPLETED"))))
                ((uuid . "{other-branch}")
                 (target . ((ref_name . "release")))
                 (state . ((name . "IN_PROGRESS"))))
                ((uuid . "{active}")
                 (target . ((ref_name . "main")))
                 (state . ((name . "IN_PROGRESS")))))))
          nil)
         (should (equal watched '("{active}")))
         (bitbucket-devops-pipelines-watch--receive-branch
          key
          '((values
             . (((uuid . "{new-completed}")
                 (target . ((ref_name . "main")))
                 (state . ((name . "COMPLETED"))))
                ((uuid . "{active}")
                 (target . ((ref_name . "main")))
                 (state . ((name . "IN_PROGRESS"))))
                ((uuid . "{old-completed}")
                 (target . ((ref_name . "main")))
                 (state . ((name . "COMPLETED")))))))
          nil)
         (should
          (equal watched '("{new-completed}" "{active}")))
         (should (gethash key bitbucket-devops-pipelines-watch--records)))))))

(ert-deftest bitbucket-devops-pipelines-watch-repository-polls-history-immediately ()
  (bitbucket-devops-pipelines-watch-test-with-records
   (let (observed)
     (cl-letf (((symbol-function 'bitbucket-devops-rest-list-pipelines)
                (lambda (context _callback)
                  (setq observed context)
                  'request-process)))
       (let* ((key
               (bitbucket-devops-pipelines-watch-repository
                bitbucket-devops-pipelines-watch-test-context))
              (record (gethash key bitbucket-devops-pipelines-watch--records)))
         (should
          (equal key "williseed1/test:repository"))
         (should
          (equal observed bitbucket-devops-pipelines-watch-test-context))
         (should (eq (bitbucket-devops-pipelines-watch--r-kind record) 'repository))
         (should
         (equal (bitbucket-devops-pipelines-watch--r-state record) "SUBSCRIBED"))
         (should (= (bitbucket-devops-pipelines-watch-active-count) 1)))))))

(ert-deftest bitbucket-devops-pipelines-watch-subscription-merges-paused-pipelines ()
  (bitbucket-devops-pipelines-watch-test-with-records
   (let* ((key "williseed1/test:repository")
          (record
           (bitbucket-devops-pipelines-watch--make-record
            :key key
            :kind 'repository
            :context bitbucket-devops-pipelines-watch-test-context))
          observed)
     (cl-letf (((symbol-function 'bitbucket-devops-rest-list-pipelines)
                (lambda (_context callback)
                  (funcall callback
                           '((values . (((uuid . "{running}")))))
                           nil)))
               ((symbol-function
                 'bitbucket-devops-ui--list-all-paused-pipelines)
                (lambda (_context callback &rest _args)
                  (funcall callback '(((uuid . "{paused}"))) nil)))
               ((symbol-function
                 'bitbucket-devops-pipelines-watch--receive-subscription)
                (lambda (received-key page request-error)
                  (setq observed
                        (list received-key page request-error)))))
       (bitbucket-devops-pipelines-watch--poll-subscription key record)
       (should (equal (car observed) key))
       (should-not (caddr observed))
       (should
        (equal
         (mapcar
          (lambda (pipeline) (alist-get 'uuid pipeline))
          (bitbucket-devops-rest-page-values (cadr observed)))
         '("{running}" "{paused}")))))))

(ert-deftest bitbucket-devops-pipelines-watch-repository-baselines-old-runs-and-watches-new-runs ()
  (bitbucket-devops-pipelines-watch-test-with-records
   (let (watched)
     (cl-letf (((symbol-function 'bitbucket-devops-rest-list-pipelines)
                (lambda (&rest _args) 'request-process))
               ((symbol-function 'bitbucket-devops-pipelines-watch-pipeline)
                (lambda (_context pipeline-uuid)
                  (push pipeline-uuid watched)))
               ((symbol-function 'run-at-time)
                (lambda (&rest _args) 'timer))
               ((symbol-function 'cancel-timer) #'ignore))
       (let ((key
              (bitbucket-devops-pipelines-watch-repository
               bitbucket-devops-pipelines-watch-test-context)))
         (bitbucket-devops-pipelines-watch--receive-subscription
          key
          '((values
             . (((uuid . "{old-completed-main}")
                 (target . ((ref_name . "main")))
                 (state . ((name . "COMPLETED"))))
                ((uuid . "{active-release}")
                 (target . ((ref_name . "release")))
                 (state . ((name . "IN_PROGRESS"))))
                ((uuid . "{active-main}")
                 (target . ((ref_name . "main")))
                 (state . ((name . "IN_PROGRESS")))))))
          nil)
         (should (equal watched '("{active-main}" "{active-release}")))
         (bitbucket-devops-pipelines-watch--receive-subscription
          key
          '((values
             . (((uuid . "{new-completed-release}")
                 (target . ((ref_name . "release")))
                 (state . ((name . "COMPLETED"))))
                ((uuid . "{active-main}")
                 (target . ((ref_name . "main")))
                 (state . ((name . "IN_PROGRESS"))))
                ((uuid . "{old-completed-main}")
                 (target . ((ref_name . "main")))
                 (state . ((name . "COMPLETED")))))))
          nil)
         (should
          (equal watched
                 '("{new-completed-release}"
                   "{active-main}"
                   "{active-release}")))
         (should (gethash key bitbucket-devops-pipelines-watch--records)))))))

(ert-deftest bitbucket-devops-pipelines-watch-discovery-promotes-record-to-uuid-key ()
  (bitbucket-devops-pipelines-watch-test-with-records
   (cl-letf (((symbol-function
               'bitbucket-devops-rest-list-pipelines-for-commit)
              (lambda (&rest _args) 'request-process))
             ((symbol-function 'run-at-time)
              (lambda (&rest _args) 'timer))
             ((symbol-function 'bitbucket-devops-pipelines-watch--notify) #'ignore))
     (let* ((commit-key
             (bitbucket-devops-pipelines-watch-commit
              bitbucket-devops-pipelines-watch-test-context))
            (pipeline-key
             "williseed1/test:pipeline:{pipeline-12}"))
       (bitbucket-devops-pipelines-watch--receive-discovery
        commit-key
        '((values . (((uuid . "{pipeline-12}")
                      (state . ((name . "IN_PROGRESS")))))))
        nil)
       (should-not
        (gethash commit-key bitbucket-devops-pipelines-watch--records))
       (should
        (gethash pipeline-key bitbucket-devops-pipelines-watch--records))))))

(ert-deftest bitbucket-devops-pipelines-watch-receive-terminal-cancels-and-notifies ()
  (bitbucket-devops-pipelines-watch-test-with-records
   (let (notifications canceled)
     (cl-letf (((symbol-function 'bitbucket-devops-rest-get-pipeline)
                (lambda (&rest _args) 'request-process))
               ((symbol-function 'cancel-timer)
                (lambda (timer) (setq canceled timer)))
               ((symbol-function 'bitbucket-devops-pipelines-watch--notify)
                (lambda (message) (push message notifications))))
       (let* ((key
               (bitbucket-devops-pipelines-watch-pipeline
                bitbucket-devops-pipelines-watch-test-context
                "{pipeline-12}"))
              (record (gethash key bitbucket-devops-pipelines-watch--records)))
         (setf (bitbucket-devops-pipelines-watch--r-timer record) 'timer)
         (bitbucket-devops-pipelines-watch--receive-pipeline
          key
          '((uuid . "{pipeline-12}")
            (state . ((name . "COMPLETED")
                      (result . ((name . "SUCCESSFUL"))))))
          nil)
         (should (eq canceled 'timer))
         (should (= (length notifications) 1))
         (should (= (bitbucket-devops-pipelines-watch-active-count) 0)))))))

(ert-deftest bitbucket-devops-pipelines-watch-terminal-auto-download-is-optional ()
  (bitbucket-devops-pipelines-watch-test-with-records
   (let ((bitbucket-devops-pipelines-auto-download-logs t)
         observed)
     (cl-letf (((symbol-function 'bitbucket-devops-rest-get-pipeline)
                (lambda (&rest _args) 'request-process))
               ((symbol-function 'bitbucket-devops-pipelines-watch--notify) #'ignore)
               ((symbol-function
                 'bitbucket-devops-pipelines-watch--download-pipeline-logs)
                (lambda (record pipeline)
                  (setq observed (list record pipeline)))))
       (let* ((key
               (bitbucket-devops-pipelines-watch-pipeline
                bitbucket-devops-pipelines-watch-test-context
                "{pipeline-12}"))
              (pipeline
               '((uuid . "{pipeline-12}")
                 (state . ((name . "COMPLETED")
                           (result . ((name . "SUCCESSFUL"))))))))
         (bitbucket-devops-pipelines-watch--receive-pipeline key pipeline nil)
         (should observed)
         (should (equal (cadr observed) pipeline)))))))

(ert-deftest bitbucket-devops-pipelines-watch-deduplicates-state-notifications ()
  (bitbucket-devops-pipelines-watch-test-with-records
   (let (notifications)
     (cl-letf (((symbol-function 'bitbucket-devops-rest-get-pipeline)
                (lambda (&rest _args) 'request-process))
               ((symbol-function 'run-at-time)
                (lambda (&rest _args) 'timer))
               ((symbol-function 'cancel-timer) #'ignore)
               ((symbol-function 'bitbucket-devops-pipelines-watch--notify)
                (lambda (message) (push message notifications))))
       (let ((key
              (bitbucket-devops-pipelines-watch-pipeline
               bitbucket-devops-pipelines-watch-test-context
               "{pipeline-12}"))
             (pipeline
              '((uuid . "{pipeline-12}")
                (state . ((name . "IN_PROGRESS"))))))
         (bitbucket-devops-pipelines-watch--receive-pipeline key pipeline nil)
         (bitbucket-devops-pipelines-watch--receive-pipeline key pipeline nil)
         (should (= (length notifications) 1)))))))

(ert-deftest bitbucket-devops-pipelines-watch-notifies-paused-and-keeps-polling ()
  (bitbucket-devops-pipelines-watch-test-with-records
   (let (notifications)
     (cl-letf (((symbol-function 'bitbucket-devops-rest-get-pipeline)
                (lambda (&rest _args) 'request-process))
               ((symbol-function 'run-at-time)
                (lambda (&rest _args) 'timer))
               ((symbol-function 'cancel-timer) #'ignore)
               ((symbol-function 'bitbucket-devops-pipelines-watch--notify)
                (lambda (message) (push message notifications))))
       (let* ((key
               (bitbucket-devops-pipelines-watch-pipeline
                bitbucket-devops-pipelines-watch-test-context
                "{pipeline-12}"))
              (pipeline
               '((uuid . "{pipeline-12}")
                 (state . ((name . "IN_PROGRESS")
                           (result . ((name . "PAUSED"))))))))
         (bitbucket-devops-pipelines-watch--receive-pipeline key pipeline nil)
         (should (= (length notifications) 1))
         (should (string-match-p ": PAUSED\\'" (car notifications)))
         (should (gethash key bitbucket-devops-pipelines-watch--records)))))))

(ert-deftest bitbucket-devops-pipelines-watch-network-errors-back-off ()
  (bitbucket-devops-pipelines-watch-test-with-records
   (let (delays)
     (cl-letf (((symbol-function 'bitbucket-devops-rest-get-pipeline)
                (lambda (&rest _args) 'request-process))
               ((symbol-function 'run-at-time)
                (lambda (delay &rest _args)
                  (push delay delays)
                  'timer))
               ((symbol-function 'cancel-timer) #'ignore))
       (let ((key
              (bitbucket-devops-pipelines-watch-pipeline
               bitbucket-devops-pipelines-watch-test-context
               "{pipeline-12}")))
         (bitbucket-devops-pipelines-watch--receive-pipeline
          key nil '(:type network))
         (bitbucket-devops-pipelines-watch--receive-pipeline
          key nil '(:type network))
         (should (equal (nreverse delays) '(5 10))))))))

(ert-deftest bitbucket-devops-pipelines-watch-supports-multiple-repositories ()
  (bitbucket-devops-pipelines-watch-test-with-records
   (cl-letf (((symbol-function 'bitbucket-devops-rest-get-pipeline)
              (lambda (&rest _args) 'request-process)))
     (bitbucket-devops-pipelines-watch-pipeline
      bitbucket-devops-pipelines-watch-test-context
      "{pipeline-12}")
     (bitbucket-devops-pipelines-watch-pipeline
      '(:workspace "Other" :repo-slug "repository" :branch "main")
      "{pipeline-99}")
     (should (= (bitbucket-devops-pipelines-watch-active-count) 2)))))

(ert-deftest bitbucket-devops-pipelines-watch-list-explains-empty-registry ()
  (bitbucket-devops-pipelines-watch-test-with-records
   (let ((buffer
          (get-buffer-create bitbucket-devops-pipelines-watch--list-buffer-name))
         (bitbucket-devops-pipelines-magit-push-watch-mode nil))
     (unwind-protect
         (cl-letf (((symbol-function 'bitbucket-devops-ui--display-buffer)
                    #'ignore))
           (bitbucket-devops-pipelines-list-watchers)
           (with-current-buffer buffer
             (should
              (string-match-p
               "Magit push tracking: DISABLED"
               (buffer-string)))
             (should
              (string-match-p
               "No active Bitbucket watchers"
               (buffer-string)))
             (should
              (string-match-p
               "removed automatically"
             (buffer-string)))))
       (kill-buffer buffer)))))

(ert-deftest bitbucket-devops-pipelines-watch-list-shows-enabled-push-tracking ()
  (bitbucket-devops-pipelines-watch-test-with-records
   (let ((buffer
          (get-buffer-create bitbucket-devops-pipelines-watch--list-buffer-name)))
     (unwind-protect
         (progn
           (setq bitbucket-devops-pipelines-magit-push-watch-mode t)
           (cl-letf (((symbol-function 'bitbucket-devops-ui--display-buffer)
                      #'ignore))
             (bitbucket-devops-pipelines-list-watchers)
             (with-current-buffer buffer
               (should
                (string-match-p
                 "Magit push tracking: ENABLED"
                 (buffer-string))))))
       (setq bitbucket-devops-pipelines-magit-push-watch-mode nil)
       (kill-buffer buffer)))))

(ert-deftest bitbucket-devops-pipelines-watch-list-toggle-push-tracking-refreshes ()
  (bitbucket-devops-pipelines-watch-test-with-records
   (let ((buffer
          (get-buffer-create bitbucket-devops-pipelines-watch--list-buffer-name)))
     (unwind-protect
         (cl-letf (((symbol-function 'bitbucket-devops-pipelines-toggle-magit-push-watch)
                    (lambda ()
                      (set
                       'bitbucket-devops-pipelines-magit-push-watch-mode
                       (not
                        (symbol-value
                         'bitbucket-devops-pipelines-magit-push-watch-mode))))))
           (setq bitbucket-devops-pipelines-magit-push-watch-mode nil)
           (bitbucket-devops-pipelines-watch--render-list-buffer)
           (with-current-buffer buffer
             (should
              (string-match-p
               "Magit push tracking: DISABLED"
               (buffer-string)))
             (bitbucket-devops-pipelines-watch-toggle-push-tracking)
             (should
              (string-match-p
               "Magit push tracking: ENABLED"
               (buffer-string)))))
       (setq bitbucket-devops-pipelines-magit-push-watch-mode nil)
       (kill-buffer buffer)))))

(ert-deftest bitbucket-devops-pipelines-watch-list-uses-ui-back-target ()
  (bitbucket-devops-pipelines-watch-test-with-records
   (let ((source (generate-new-buffer " *bitbucket-devops-pipelines-history*"))
         observed)
     (unwind-protect
         (progn
           (with-current-buffer source
             (bitbucket-devops-pipelines-history-mode)
             (cl-letf (((symbol-function 'bitbucket-devops-ui--display-buffer)
                        (lambda (&rest args) (setq observed args))))
               (bitbucket-devops-pipelines-list-watchers)))
           (should
            (equal
             observed
             (list
              (get-buffer bitbucket-devops-pipelines-watch--list-buffer-name)
              t
              source))))
       (kill-buffer source)
       (when-let ((buffer
                   (get-buffer bitbucket-devops-pipelines-watch--list-buffer-name)))
         (kill-buffer buffer))))))

(ert-deftest bitbucket-devops-pipelines-watch-list-panel-hides-unavailable-back ()
  (let ((buffer (generate-new-buffer " *bitbucket-devops-pipelines-watchers*"))
        (previous (generate-new-buffer " *bitbucket-devops-pipelines-history*")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (bitbucket-devops-pipelines-watch-list-mode)
            (if (fboundp 'bitbucket-devops-dispatch)
                (should
                 (string-match-p
                  "- Back"
                  (bitbucket-devops-ui--command-panel-lines
                   (current-buffer))))
              (should-not
               (string-match-p
                "- Back"
                (bitbucket-devops-ui--command-panel-lines
                 (current-buffer))))))
          (with-current-buffer previous
            (bitbucket-devops-pipelines-history-mode))
          (with-current-buffer buffer
            (setq-local bitbucket-devops-ui--previous-buffer previous)
            (should
             (string-match-p
              "- Back"
              (bitbucket-devops-ui--command-panel-lines
               (current-buffer))))))
      (kill-buffer buffer)
      (kill-buffer previous))))

(ert-deftest bitbucket-devops-pipelines-watch-list-refreshes-through-lifecycle ()
  (bitbucket-devops-pipelines-watch-test-with-records
   (let ((buffer
          (get-buffer-create bitbucket-devops-pipelines-watch--list-buffer-name)))
     (unwind-protect
         (cl-letf (((symbol-function 'bitbucket-devops-rest-get-pipeline)
                    (lambda (&rest _args) 'request-process))
                   ((symbol-function 'run-at-time)
                    (lambda (&rest _args) 'timer))
                   ((symbol-function 'cancel-timer) #'ignore)
                   ((symbol-function 'bitbucket-devops-pipelines-watch--notify)
                    #'ignore)
                   ((symbol-function 'bitbucket-devops-ui--display-buffer)
                    #'ignore))
           (bitbucket-devops-pipelines-list-watchers)
           (let ((key
                  (bitbucket-devops-pipelines-watch-pipeline
                   bitbucket-devops-pipelines-watch-test-context
                   "{pipeline-12}")))
             (bitbucket-devops-pipelines-watch--receive-pipeline
              key
              '((uuid . "{pipeline-12}")
                (state . ((name . "IN_PROGRESS"))))
              nil)
             (with-current-buffer buffer
               (should (string-match-p "{pipeline-12}" (buffer-string)))
               (should (string-match-p "IN_PROGRESS" (buffer-string))))
             (bitbucket-devops-pipelines-watch--receive-pipeline
              key
              '((uuid . "{pipeline-12}")
                (state . ((name . "COMPLETED")
                          (result . ((name . "SUCCESSFUL"))))))
             nil)
             (with-current-buffer buffer
               (should
                (string-match-p
                 "No active Bitbucket watchers"
                 (buffer-string))))))
       (kill-buffer buffer)))))

(ert-deftest bitbucket-devops-pipelines-watch-list-shows-pr-comment-watchers ()
  (bitbucket-devops-pipelines-watch-test-with-records
   (let ((buffer
          (get-buffer-create bitbucket-devops-pipelines-watch--list-buffer-name))
         (bitbucket-devops-pull-requests-comments-watch-max-age 7200))
     (unwind-protect
         (cl-letf (((symbol-function 'float-time) (lambda (&rest _) 1120)))
           (puthash
            "williseed1/test:pull-request:11:comments"
            (bitbucket-devops-pull-requests-watch--make-record
             :key "williseed1/test:pull-request:11:comments"
             :context '(:workspace "williseed1" :repo-slug "test")
             :pull-request-id 11
             :title "Development"
             :state "OPEN"
             :started-at 1000
             :seen-comment-ids (make-hash-table :test #'equal))
            bitbucket-devops-pull-requests-watch--records)
           (bitbucket-devops-pipelines-watch--render-list-buffer)
           (with-current-buffer buffer
             (let ((contents (buffer-string)))
               (should (string-match-p "Active Bitbucket Watchers" contents))
               (should (string-match-p "PR comment watcher" contents))
               (should (string-match-p "#11 Development" contents))
               (should (string-match-p "OPEN" contents))
               (should (string-match-p "2m/2h 0m" contents))
               (should (string-match-p "60s" contents))
               (should (string-match-p "poll comments" contents))
               (should (string-match-p "active" contents)))))
       (kill-buffer buffer)))))

(ert-deftest bitbucket-devops-pipelines-watch-stop-at-point-preserves-list-position ()
  (bitbucket-devops-pipelines-watch-test-with-records
   (let ((buffer
          (get-buffer-create bitbucket-devops-pipelines-watch--list-buffer-name)))
     (unwind-protect
         (progn
           (dolist (key '("a" "b" "c"))
             (puthash
              key
              (bitbucket-devops-pipelines-watch--make-record
               :key key
               :kind 'pipeline
               :context '(:workspace "williseed1" :repo-slug "test")
               :pipeline-uuid key
               :state "IN_PROGRESS")
              bitbucket-devops-pipelines-watch--records))
           (with-current-buffer buffer
             (bitbucket-devops-pipelines-watch-list-mode)
             (bitbucket-devops-pipelines-watch--render-list-buffer)
             (goto-char (point-min))
             (let ((match
                    (text-property-search-forward
                     'bitbucket-devops-pipelines-watcher-key "b" t)))
               (should match)
               (goto-char (prop-match-beginning match)))
             (bitbucket-devops-pipelines-stop-watching-at-point)
             (should
              (equal
               (get-text-property
                (point)
                'bitbucket-devops-pipelines-watcher-key)
               "c"))))
       (kill-buffer buffer)))))

(ert-deftest bitbucket-devops-pipelines-watch-stop-at-point-stops-pr-comment-watcher ()
  (bitbucket-devops-pipelines-watch-test-with-records
   (let ((buffer
          (get-buffer-create bitbucket-devops-pipelines-watch--list-buffer-name))
         (key "williseed1/test:pull-request:11:comments"))
     (unwind-protect
         (progn
           (puthash
            key
            (bitbucket-devops-pull-requests-watch--make-record
             :key key
             :context '(:workspace "williseed1" :repo-slug "test")
             :pull-request-id 11
             :title "Development"
             :state "OPEN"
             :started-at (float-time)
             :seen-comment-ids (make-hash-table :test #'equal))
            bitbucket-devops-pull-requests-watch--records)
           (with-current-buffer buffer
             (bitbucket-devops-pipelines-watch-list-mode)
             (bitbucket-devops-pipelines-watch--render-list-buffer)
             (goto-char (point-min))
             (let ((match
                    (text-property-search-forward
                     'bitbucket-devops-watcher-key key t)))
               (should match)
               (goto-char (prop-match-beginning match)))
             (bitbucket-devops-pipelines-stop-watching-at-point)
             (should (= (bitbucket-devops-pull-requests-watch-active-count) 0))))
       (kill-buffer buffer)))))

(ert-deftest bitbucket-devops-pipelines-watch-notify-uses-custom-function ()
  (let (observed)
    (let ((bitbucket-devops-pipelines-notification-function
           (lambda (message)
             (setq observed message))))
      (bitbucket-devops-pipelines-watch--notify "Pipeline completed")
      (should (equal observed "Pipeline completed")))))

(ert-deftest bitbucket-devops-pipelines-watch-notify-uses-custom-title ()
  (let ((bitbucket-devops-pipelines-notification-title "Custom Bitbucket Title")
        observed)
    (cl-letf (((symbol-function 'alert)
               (lambda (message &rest args)
                 (setq observed (cons message args)))))
      (bitbucket-devops-pipelines-watch--notify "Pipeline completed")
      (should
       (equal observed
              '("Pipeline completed" :title "Custom Bitbucket Title"))))))

(ert-deftest bitbucket-devops-pipelines-watch-mode-line-can-be-disabled ()
  (bitbucket-devops-pipelines-watch-test-with-records
   (let ((bitbucket-devops-pipelines-watch-mode-line-enabled nil))
     (puthash
      "williseed1/test:pipeline:{pipeline-12}"
      (bitbucket-devops-pipelines-watch--make-record
       :key "williseed1/test:pipeline:{pipeline-12}")
      bitbucket-devops-pipelines-watch--records)
     (bitbucket-devops-pipelines-watch--update-mode-line)
     (should-not
      (memq 'bitbucket-devops-pipelines-watch-mode-line global-mode-string)))))

(ert-deftest bitbucket-devops-pipelines-watch-list-uses-custom-column-widths ()
  (bitbucket-devops-pipelines-watch-test-with-records
   (let ((buffer
         (get-buffer-create bitbucket-devops-pipelines-watch--list-buffer-name))
         (bitbucket-devops-pipelines-watch-list-column-widths
          '((type . 10)
            (repository . 20)
            (target . 12)
            (state . 10)
            (age . 8)
            (poll . 6)
            (next . 12)
            (status . 10))))
     (unwind-protect
         (progn
           (puthash
            "williseed1/test:pipeline:{pipeline-12}"
            (bitbucket-devops-pipelines-watch--make-record
             :key "williseed1/test:pipeline:{pipeline-12}"
             :kind 'pipeline
             :context bitbucket-devops-pipelines-watch-test-context
             :pipeline-uuid "{pipeline-12}"
             :branch "main"
             :commit "0123456789abcdef"
             :state "IN_PROGRESS")
            bitbucket-devops-pipelines-watch--records)
           (bitbucket-devops-pipelines-watch--render-list-buffer)
           (with-current-buffer buffer
             (should
              (string-match-p
               (regexp-quote (make-string 95 ?─))
               (buffer-string)))))
       (kill-buffer buffer)))))

(ert-deftest bitbucket-devops-pipelines-watch-install-evil-bindings-uses-simple-actions ()
  (let (bindings)
    (cl-letf (((symbol-function 'evil-define-key*)
               (lambda (_state _keymap &rest args)
                 (setq bindings args))))
      (bitbucket-devops-pipelines-watch--install-evil-bindings)
      (should
       (equal
        bindings
        (list
         (kbd "m") #'bitbucket-devops-pipelines-watch-toggle-push-tracking
         (kbd "x") #'bitbucket-devops-pipelines-stop-watching-at-point
         (kbd "-") #'bitbucket-devops-ui-back
         (kbd "q") #'bitbucket-devops-ui-quit
         (kbd "?") #'bitbucket-devops-ui-show-command-panel))))))

(ert-deftest bitbucket-devops-pipelines-watch-help-binding-shows-panel ()
  (should
   (eq
    (lookup-key bitbucket-devops-pipelines-watch-list-mode-map (kbd "?"))
    #'bitbucket-devops-ui-show-command-panel)))

(provide 'bitbucket-devops-pipelines-watch-test)
;;; bitbucket-devops-pipelines-watch-test.el ends here
