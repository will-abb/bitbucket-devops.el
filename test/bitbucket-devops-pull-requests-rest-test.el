;;; bitbucket-devops-pull-requests-rest-test.el --- Tests for PR REST wrappers -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'bitbucket-devops-pull-requests-rest)

(defconst bitbucket-devops-pull-requests-rest-test-context
  '(:workspace "team name" :repo-slug "repo/name")
  "Repository context used by PR REST tests.")

(defun bitbucket-devops-pull-requests-rest-test-capture (thunk)
  "Run THUNK and return captured REST request arguments."
  (let (observed)
    (cl-letf (((symbol-function 'bitbucket-devops-rest-request)
               (lambda (method url callback &optional body raw context)
                 (setq observed
                       (list :method method
                             :url url
                             :callback callback
                             :body body
                             :raw raw
                             :context context))
                 'request-process)))
      (should (eq (funcall thunk) 'request-process))
      observed)))

(ert-deftest bitbucket-devops-pull-requests-rest-list-requests-newest-updated-first ()
  (should
   (equal
    (bitbucket-devops-pull-requests-rest-test-capture
     (lambda ()
       (bitbucket-devops-pull-requests-rest-list
        bitbucket-devops-pull-requests-rest-test-context
        #'ignore)))
    '(:method "GET"
      :url "https://api.bitbucket.org/2.0/repositories/team%20name/repo%2Fname/pullrequests?state=OPEN&state=MERGED&state=DECLINED&state=SUPERSEDED&sort=-updated_on"
      :callback ignore
      :body nil
      :raw nil
      :context (:workspace "team name" :repo-slug "repo/name")))))

(ert-deftest bitbucket-devops-pull-requests-rest-list-applies-state-filter ()
  (should
   (equal
    (plist-get
     (bitbucket-devops-pull-requests-rest-test-capture
      (lambda ()
        (bitbucket-devops-pull-requests-rest-list
         bitbucket-devops-pull-requests-rest-test-context
         #'ignore
         nil
         "OPEN")))
     :url)
    "https://api.bitbucket.org/2.0/repositories/team%20name/repo%2Fname/pullrequests?state=OPEN&sort=-updated_on")))

(ert-deftest bitbucket-devops-pull-requests-rest-list-uses-next-page-url ()
  (let ((next-url
         "https://api.bitbucket.org/2.0/repositories/team%20name/repo%2Fname/pullrequests?page=2"))
    (should
     (equal
      (plist-get
       (bitbucket-devops-pull-requests-rest-test-capture
        (lambda ()
          (bitbucket-devops-pull-requests-rest-list
           bitbucket-devops-pull-requests-rest-test-context
           #'ignore
           next-url
           "OPEN")))
       :url)
      next-url))))

(ert-deftest bitbucket-devops-pull-requests-rest-lists-reviewer-user-sources ()
  (should
   (equal
    (bitbucket-devops-pull-requests-rest-test-capture
     (lambda ()
       (bitbucket-devops-pull-requests-rest-list-repository-users
        bitbucket-devops-pull-requests-rest-test-context
        #'ignore)))
    '(:method "GET"
      :url "https://api.bitbucket.org/2.0/workspaces/team%20name/permissions/repositories/repo%2Fname"
      :callback ignore
      :body nil
      :raw nil
      :context (:workspace "team name" :repo-slug "repo/name"))))
  (should
   (equal
    (bitbucket-devops-pull-requests-rest-test-capture
     (lambda ()
       (bitbucket-devops-pull-requests-rest-list-workspace-members
        bitbucket-devops-pull-requests-rest-test-context
        #'ignore)))
    '(:method "GET"
      :url "https://api.bitbucket.org/2.0/workspaces/team%20name/members"
      :callback ignore
      :body nil
      :raw nil
      :context (:workspace "team name" :repo-slug "repo/name")))))

(ert-deftest bitbucket-devops-pull-requests-rest-lists-effective-default-reviewers ()
  (should
   (equal
    (bitbucket-devops-pull-requests-rest-test-capture
     (lambda ()
       (bitbucket-devops-pull-requests-rest-list-effective-default-reviewers
        bitbucket-devops-pull-requests-rest-test-context
        #'ignore)))
    '(:method "GET"
      :url "https://api.bitbucket.org/2.0/repositories/team%20name/repo%2Fname/effective-default-reviewers"
      :callback ignore
      :body nil
      :raw nil
      :context (:workspace "team name" :repo-slug "repo/name")))))

(ert-deftest bitbucket-devops-pull-requests-rest-reviewer-user-sources-use-next-page ()
  (dolist
      (function
       '(bitbucket-devops-pull-requests-rest-list-repository-users
         bitbucket-devops-pull-requests-rest-list-workspace-members
         bitbucket-devops-pull-requests-rest-list-effective-default-reviewers))
    (let ((next-url
           "https://api.bitbucket.org/2.0/workspaces/team/members?page=2"))
      (should
       (equal
        (plist-get
         (bitbucket-devops-pull-requests-rest-test-capture
          (lambda ()
            (funcall
             function
             bitbucket-devops-pull-requests-rest-test-context
             #'ignore
             next-url)))
         :url)
        next-url)))))

(ert-deftest bitbucket-devops-pull-requests-rest-get-encodes-pr-id-path ()
  (should
   (equal
    (plist-get
     (bitbucket-devops-pull-requests-rest-test-capture
      (lambda ()
        (bitbucket-devops-pull-requests-rest-get
         bitbucket-devops-pull-requests-rest-test-context
         11
         #'ignore)))
     :url)
    "https://api.bitbucket.org/2.0/repositories/team%20name/repo%2Fname/pullrequests/11")))

(ert-deftest bitbucket-devops-pull-requests-rest-list-detail-resources ()
  (dolist (case '((bitbucket-devops-pull-requests-rest-list-activity . "activity")
                  (bitbucket-devops-pull-requests-rest-list-comments . "comments")
                  (bitbucket-devops-pull-requests-rest-list-commits . "commits")
                  (bitbucket-devops-pull-requests-rest-list-statuses . "statuses")
                  (bitbucket-devops-pull-requests-rest-list-tasks . "tasks")
                  (bitbucket-devops-pull-requests-rest-list-diffstat . "diffstat")))
    (should
     (equal
      (plist-get
       (bitbucket-devops-pull-requests-rest-test-capture
        (lambda ()
          (funcall
           (car case)
           bitbucket-devops-pull-requests-rest-test-context
           11
           #'ignore)))
       :url)
      (format
       "https://api.bitbucket.org/2.0/repositories/team%%20name/repo%%2Fname/pullrequests/11/%s"
       (cdr case))))))

(ert-deftest bitbucket-devops-pull-requests-rest-get-diff-requests-raw-response ()
  (should
   (equal
    (bitbucket-devops-pull-requests-rest-test-capture
     (lambda ()
       (bitbucket-devops-pull-requests-rest-get-diff
        bitbucket-devops-pull-requests-rest-test-context
        11
        #'ignore)))
    '(:method "GET"
      :url "https://api.bitbucket.org/2.0/repositories/team%20name/repo%2Fname/pullrequests/11/diff"
      :callback ignore
      :body nil
      :raw t
      :context (:workspace "team name" :repo-slug "repo/name")))))

(ert-deftest bitbucket-devops-pull-requests-rest-create-posts-body ()
  (let ((body '((title . "PR")
                (source . ((branch . ((name . "feature")))))
                (destination . ((branch . ((name . "main"))))))))
    (should
     (equal
      (bitbucket-devops-pull-requests-rest-test-capture
       (lambda ()
         (bitbucket-devops-pull-requests-rest-create
          bitbucket-devops-pull-requests-rest-test-context
          body
          #'ignore)))
      `(:method "POST"
        :url "https://api.bitbucket.org/2.0/repositories/team%20name/repo%2Fname/pullrequests"
        :callback ignore
        :body ,body
        :raw nil
        :context (:workspace "team name" :repo-slug "repo/name"))))))

(ert-deftest bitbucket-devops-pull-requests-rest-create-body-builds-fields ()
  (should
   (equal
    (bitbucket-devops-pull-requests-rest-create-body
     " feature/example "
     "main"
     " Add feature "
     " Description "
     t
     '("{reviewer-uuid}" "account-id"))
    '((title . "Add feature")
      (source . ((branch . ((name . "feature/example")))))
      (destination . ((branch . ((name . "main")))))
      (description . "Description")
      (draft . t)
      (reviewers
       . [((uuid . "{reviewer-uuid}"))
          ((account_id . "account-id"))])))))

(ert-deftest bitbucket-devops-pull-requests-rest-create-body-omits-empty-options ()
  (should
   (equal
    (bitbucket-devops-pull-requests-rest-create-body
     "feature/example" "main" "Add feature" "" nil nil)
    '((title . "Add feature")
      (source . ((branch . ((name . "feature/example")))))
      (destination . ((branch . ((name . "main")))))))))

(ert-deftest bitbucket-devops-pull-requests-rest-create-body-can-clear-reviewers ()
  (should
   (equal
    (bitbucket-devops-pull-requests-rest-create-body
     "feature/example" "main" "Add feature" "" nil :none)
    '((title . "Add feature")
      (source . ((branch . ((name . "feature/example")))))
      (destination . ((branch . ((name . "main")))))
      (reviewers . [])))))

(ert-deftest bitbucket-devops-pull-requests-rest-create-body-validates-required-fields ()
  (dolist (arguments '(("" "main" "Title")
                       ("feature" "" "Title")
                       ("feature" "main" "")))
    (should-error
     (apply #'bitbucket-devops-pull-requests-rest-create-body arguments)
     :type 'user-error)))

(ert-deftest bitbucket-devops-pull-requests-rest-metadata-body-builds-fields ()
  (should
   (equal
    (bitbucket-devops-pull-requests-rest-metadata-body
     " Updated title "
     "Updated description"
     t)
    '((title . "Updated title")
      (description . "Updated description")
      (draft . t))))
  (should
   (equal
    (bitbucket-devops-pull-requests-rest-metadata-body "Ready" "" nil)
    '((title . "Ready")
      (description . "")
      (draft . :false)))))

(ert-deftest bitbucket-devops-pull-requests-rest-metadata-body-rejects-empty-title ()
  (should-error
   (bitbucket-devops-pull-requests-rest-metadata-body "" "Description" nil)
   :type 'user-error))

(ert-deftest bitbucket-devops-pull-requests-rest-merge-body-builds-options ()
  (should
   (equal
    (bitbucket-devops-pull-requests-rest-merge-body
     "squash" " Merge feature " nil)
    '((type . "pullrequest")
      (merge_strategy . "squash")
      (close_source_branch . :false)
      (message . "Merge feature"))))
  (should
   (equal
    (bitbucket-devops-pull-requests-rest-merge-body
     "merge_commit" "" t)
    '((type . "pullrequest")
      (merge_strategy . "merge_commit")
      (close_source_branch . t))))
  (should-error
   (bitbucket-devops-pull-requests-rest-merge-body "unknown" "" nil)
   :type 'user-error))

(ert-deftest bitbucket-devops-pull-requests-rest-merge-posts-synchronously ()
  (let ((body '((type . "pullrequest")
                (merge_strategy . "merge_commit"))))
    (should
     (equal
      (bitbucket-devops-pull-requests-rest-test-capture
       (lambda ()
         (bitbucket-devops-pull-requests-rest-merge
          bitbucket-devops-pull-requests-rest-test-context
          11
          body
          #'ignore)))
      `(:method "POST"
        :url ,(concat
               "https://api.bitbucket.org/2.0/repositories/"
               "team%20name/repo%2Fname/pullrequests/11/merge?async=false")
        :callback ignore
        :body ,body
        :raw nil
        :context (:workspace "team name" :repo-slug "repo/name"))))))

(ert-deftest bitbucket-devops-pull-requests-rest-reviewers-body-supports-empty-list ()
  (should
   (equal
    (bitbucket-devops-pull-requests-rest-reviewers-body nil)
    '((reviewers . [])))))

(ert-deftest bitbucket-devops-pull-requests-rest-reviewers-body-serializes-json-array ()
  (should
   (equal
    (json-serialize
     (bitbucket-devops-pull-requests-rest-reviewers-body
      '("{eb2296a6-8478-44c1-8ac0-d63ca81c829c}" "account-id")))
    (concat
     "{\"reviewers\":["
     "{\"uuid\":\"{eb2296a6-8478-44c1-8ac0-d63ca81c829c}\"},"
     "{\"account_id\":\"account-id\"}]}"))))

(ert-deftest bitbucket-devops-pull-requests-rest-comment-body-rejects-empty-text ()
  (should-error
   (bitbucket-devops-pull-requests-rest-comment-body "")
   :type 'user-error))

(ert-deftest bitbucket-devops-pull-requests-rest-comment-body-builds-inline-location ()
  (should
   (equal
    (bitbucket-devops-pull-requests-rest-comment-body
     "Inline note"
     nil
     '(:path "lib/example.el" :to 42))
    '((content . ((raw . "Inline note")))
      (inline . ((path . "lib/example.el") (to . 42))))))
  (should
   (equal
    (bitbucket-devops-pull-requests-rest-comment-body
     "Old line"
     nil
     '(:path "lib/example.el" :from 7))
    '((content . ((raw . "Old line")))
      (inline . ((path . "lib/example.el") (from . 7)))))))

(ert-deftest bitbucket-devops-pull-requests-rest-comment-body-validates-inline-location ()
  (should-error
   (bitbucket-devops-pull-requests-rest-comment-body
    "Inline note" nil '(:path "" :to 1))
   :type 'user-error)
  (should-error
   (bitbucket-devops-pull-requests-rest-comment-body
    "Inline note" nil '(:path "a.el" :from 1 :to 1))
   :type 'user-error)
  (should-error
   (bitbucket-devops-pull-requests-rest-comment-body
    "Inline note" 100 '(:path "a.el" :to 1))
   :type 'user-error))

(ert-deftest bitbucket-devops-pull-requests-rest-create-comment-posts-text ()
  (should
   (equal
    (bitbucket-devops-pull-requests-rest-test-capture
     (lambda ()
       (bitbucket-devops-pull-requests-rest-create-comment
        bitbucket-devops-pull-requests-rest-test-context
        11
        "Looks good"
        #'ignore)))
    '(:method "POST"
      :url "https://api.bitbucket.org/2.0/repositories/team%20name/repo%2Fname/pullrequests/11/comments"
      :callback ignore
      :body ((content . ((raw . "Looks good"))))
      :raw nil
      :context (:workspace "team name" :repo-slug "repo/name")))))

(ert-deftest bitbucket-devops-pull-requests-rest-create-comment-posts-inline-location ()
  (should
   (equal
    (bitbucket-devops-pull-requests-rest-test-capture
     (lambda ()
       (bitbucket-devops-pull-requests-rest-create-comment
        bitbucket-devops-pull-requests-rest-test-context
        11
        "Inline note"
        #'ignore
        nil
        '(:path "lib/example.el" :to 42))))
    '(:method "POST"
      :url "https://api.bitbucket.org/2.0/repositories/team%20name/repo%2Fname/pullrequests/11/comments"
      :callback ignore
      :body ((content . ((raw . "Inline note")))
             (inline . ((path . "lib/example.el") (to . 42))))
      :raw nil
      :context (:workspace "team name" :repo-slug "repo/name")))))

(ert-deftest bitbucket-devops-pull-requests-rest-create-comment-can-send-parent ()
  (should
   (equal
    (plist-get
     (bitbucket-devops-pull-requests-rest-test-capture
      (lambda ()
        (bitbucket-devops-pull-requests-rest-create-comment
         bitbucket-devops-pull-requests-rest-test-context
         11
         "Reply"
         #'ignore
         101)))
     :body)
    '((content . ((raw . "Reply")))
      (parent . ((id . 101)))))))

(ert-deftest bitbucket-devops-pull-requests-rest-comment-lifecycle-uses-comment-url ()
  (let ((base-url
         (concat
          "https://api.bitbucket.org/2.0/repositories/"
          "team%20name/repo%2Fname/pullrequests/11/comments/101")))
    (dolist
        (case
         '((bitbucket-devops-pull-requests-rest-get-comment "GET" "" nil)
           (bitbucket-devops-pull-requests-rest-delete-comment "DELETE" "" nil)
           (bitbucket-devops-pull-requests-rest-resolve-comment "POST" "/resolve" nil)
           (bitbucket-devops-pull-requests-rest-reopen-comment
            "DELETE" "/resolve" nil)))
      (let ((observed
             (bitbucket-devops-pull-requests-rest-test-capture
              (lambda ()
                (funcall
                 (nth 0 case)
                 bitbucket-devops-pull-requests-rest-test-context
                 11
                 101
                 #'ignore)))))
        (should (equal (plist-get observed :method) (nth 1 case)))
        (should (equal (plist-get observed :url)
                       (concat base-url (nth 2 case))))
        (should-not (plist-get observed :body))))
    (let ((observed
           (bitbucket-devops-pull-requests-rest-test-capture
            (lambda ()
              (bitbucket-devops-pull-requests-rest-update-comment
               bitbucket-devops-pull-requests-rest-test-context
               11
               101
               "Updated text"
               #'ignore)))))
      (should (equal (plist-get observed :method) "PUT"))
      (should (equal (plist-get observed :url) base-url))
      (should
       (equal (plist-get observed :body)
              '((content . ((raw . "Updated text")))))))))

(ert-deftest bitbucket-devops-pull-requests-rest-task-lifecycle-uses-task-url ()
  (let ((collection-url
         (concat
          "https://api.bitbucket.org/2.0/repositories/"
          "team%20name/repo%2Fname/pullrequests/11/tasks"))
        (task-url
         (concat
          "https://api.bitbucket.org/2.0/repositories/"
          "team%20name/repo%2Fname/pullrequests/11/tasks/201")))
    (should
     (equal
      (bitbucket-devops-pull-requests-rest-test-capture
       (lambda ()
         (bitbucket-devops-pull-requests-rest-create-task
          bitbucket-devops-pull-requests-rest-test-context
          11 "Fix lint" #'ignore)))
      `(:method "POST" :url ,collection-url :callback ignore
        :body ((content . ((raw . "Fix lint")))) :raw nil
        :context (:workspace "team name" :repo-slug "repo/name"))))
    (dolist (case
             '((bitbucket-devops-pull-requests-rest-get-task "GET")
               (bitbucket-devops-pull-requests-rest-delete-task "DELETE")))
      (let ((request
             (bitbucket-devops-pull-requests-rest-test-capture
              (lambda ()
                (funcall
                 (car case)
                 bitbucket-devops-pull-requests-rest-test-context
                 11 201 #'ignore)))))
        (should (equal (plist-get request :method) (cadr case)))
        (should (equal (plist-get request :url) task-url))))
    (should
     (equal
      (bitbucket-devops-pull-requests-rest-test-capture
       (lambda ()
         (bitbucket-devops-pull-requests-rest-update-task
          bitbucket-devops-pull-requests-rest-test-context
          11 201 #'ignore "Updated task" "RESOLVED")))
      `(:method "PUT" :url ,task-url :callback ignore
        :body ((content . ((raw . "Updated task")))
               (state . "RESOLVED"))
        :raw nil :context (:workspace "team name" :repo-slug "repo/name"))))
    (should
     (equal
      (bitbucket-devops-pull-requests-rest-test-capture
       (lambda ()
         (bitbucket-devops-pull-requests-rest-update-task
          bitbucket-devops-pull-requests-rest-test-context
          11 201 #'ignore nil "UNRESOLVED")))
      `(:method "PUT" :url ,task-url :callback ignore
        :body ((state . "UNRESOLVED"))
        :raw nil :context (:workspace "team name" :repo-slug "repo/name")))))
  (should-error (bitbucket-devops-pull-requests-rest-task-body "") :type 'user-error)
  (should-error
   (bitbucket-devops-pull-requests-rest-task-body nil "UNKNOWN")
   :type 'user-error))

(ert-deftest bitbucket-devops-pull-requests-rest-review-actions-use-expected-methods ()
  (dolist (case '((bitbucket-devops-pull-requests-rest-approve "POST" "approve")
                  (bitbucket-devops-pull-requests-rest-remove-approval "DELETE" "approve")
                  (bitbucket-devops-pull-requests-rest-request-changes "POST" "request-changes")
                  (bitbucket-devops-pull-requests-rest-remove-request-changes "DELETE" "request-changes")
                  (bitbucket-devops-pull-requests-rest-decline "POST" "decline")))
    (let ((observed
           (bitbucket-devops-pull-requests-rest-test-capture
            (lambda ()
              (funcall
               (nth 0 case)
               bitbucket-devops-pull-requests-rest-test-context
               11
               #'ignore)))))
      (should (equal (plist-get observed :method) (nth 1 case)))
      (should
       (equal
        (plist-get observed :url)
        (format
         "https://api.bitbucket.org/2.0/repositories/team%%20name/repo%%2Fname/pullrequests/11/%s"
         (nth 2 case)))))))

(provide 'bitbucket-devops-pull-requests-rest-test)
;;; bitbucket-devops-pull-requests-rest-test.el ends here
