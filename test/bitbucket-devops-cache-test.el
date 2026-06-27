;;; bitbucket-devops-cache-test.el --- Tests for persistent cache -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Code:

(require 'ert)
(require 'bitbucket-devops-cache)

(defconst bitbucket-devops-cache-test-context
  '(:workspace "williseed1" :repo-slug "test/repo")
  "Repository context used by cache tests.")

(defmacro bitbucket-devops-cache-test-with-temp-cache (&rest body)
  "Run BODY with a temporary Bitbucket Pipelines cache directory."
  `(let ((bitbucket-devops-cache-directory
          (make-temp-file "bitbucket-devops-cache-test-" t))
         (bitbucket-devops-cache-enabled t)
         (bitbucket-devops-cache-max-pipelines-per-repo 500)
         (bitbucket-devops-cache-max-pull-requests-per-repo 500))
     (unwind-protect
         (progn ,@body)
       (delete-directory bitbucket-devops-cache-directory t))))

(ert-deftest bitbucket-devops-cache-merge-persists-pipelines ()
  (bitbucket-devops-cache-test-with-temp-cache
   (let ((old '((uuid . "{old}")
                (build_number . 1)
                (created_on . "2026-05-31T10:00:00Z")))
         (new '((uuid . "{new}")
                (build_number . 2)
                (created_on . "2026-06-01T10:00:00Z"))))
     (bitbucket-devops-cache-merge-pipelines
      bitbucket-devops-cache-test-context
      (list old))
     (should (file-exists-p
              (bitbucket-devops-cache-file
               bitbucket-devops-cache-test-context)))
     (should
      (equal
       (mapcar
        (lambda (pipeline) (alist-get 'uuid pipeline))
        (bitbucket-devops-cache-merge-pipelines
         bitbucket-devops-cache-test-context
         (list new)))
       '("{new}" "{old}")))
     (should
      (equal
       (mapcar
        (lambda (pipeline) (alist-get 'uuid pipeline))
        (bitbucket-devops-cache-pipelines
         bitbucket-devops-cache-test-context))
       '("{new}" "{old}"))))))

(ert-deftest bitbucket-devops-cache-merge-replaces-existing-pipeline ()
  (bitbucket-devops-cache-test-with-temp-cache
   (bitbucket-devops-cache-merge-pipelines
    bitbucket-devops-cache-test-context
    '(((uuid . "{pipeline}") (build_number . 1))))
   (bitbucket-devops-cache-merge-pipelines
    bitbucket-devops-cache-test-context
    '(((uuid . "{pipeline}") (build_number . 2))))
   (should
    (equal
     (mapcar
      (lambda (pipeline) (alist-get 'build_number pipeline))
      (bitbucket-devops-cache-pipelines
       bitbucket-devops-cache-test-context))
     '(2)))))

(ert-deftest bitbucket-devops-cache-prunes-old-pipelines ()
  (bitbucket-devops-cache-test-with-temp-cache
   (let ((bitbucket-devops-cache-max-pipelines-per-repo 2))
     (bitbucket-devops-cache-merge-pipelines
      bitbucket-devops-cache-test-context
      '(((uuid . "{one}") (build_number . 1))
        ((uuid . "{three}") (build_number . 3))
        ((uuid . "{two}") (build_number . 2))))
     (should
      (equal
       (mapcar
        (lambda (pipeline) (alist-get 'uuid pipeline))
        (bitbucket-devops-cache-pipelines
         bitbucket-devops-cache-test-context))
       '("{three}" "{two}"))))))

(ert-deftest bitbucket-devops-cache-stores-commit-records ()
  (bitbucket-devops-cache-test-with-temp-cache
   (let ((commit '((hash . "abc123")
                   (message . "Commit message"))))
     (bitbucket-devops-cache-put-commit
      bitbucket-devops-cache-test-context
      "abc123"
      commit)
     (should
      (equal
       (bitbucket-devops-cache-lookup-commit
        bitbucket-devops-cache-test-context
        "abc123")
       commit)))))

(ert-deftest bitbucket-devops-cache-stores-empty-deployment-records ()
  (bitbucket-devops-cache-test-with-temp-cache
   (bitbucket-devops-cache-put-deployments
    bitbucket-devops-cache-test-context
    "{pipeline}"
    nil)
   (should
    (bitbucket-devops-cache-deployments-cached-p
     bitbucket-devops-cache-test-context
     "{pipeline}"))
   (should-not
    (bitbucket-devops-cache-lookup-deployments
     bitbucket-devops-cache-test-context
     "{pipeline}"))))

(ert-deftest bitbucket-devops-cache-disabled-does-not-write-file ()
  (bitbucket-devops-cache-test-with-temp-cache
   (let ((bitbucket-devops-cache-enabled nil))
     (should
      (equal
       (mapcar
        (lambda (pipeline) (alist-get 'uuid pipeline))
        (bitbucket-devops-cache-merge-pipelines
         bitbucket-devops-cache-test-context
         '(((uuid . "{pipeline}") (build_number . 1)))))
       '("{pipeline}")))
     (should-not
      (file-exists-p
       (bitbucket-devops-cache-file
        bitbucket-devops-cache-test-context))))))

(ert-deftest bitbucket-devops-cache-read-disables-reader-eval ()
  (bitbucket-devops-cache-test-with-temp-cache
   (let ((bitbucket-devops-cache-test--read-eval-triggered nil)
         (file (bitbucket-devops-cache-file bitbucket-devops-cache-test-context)))
     (make-directory (file-name-directory file) t)
     (with-temp-file file
       (insert
        "(:version #.(setq bitbucket-devops-cache-test--read-eval-triggered t)\n"
        " :pipelines nil :pull-requests nil :commits nil\n"
        " :deployments nil :reviewer-users nil)\n"))
     (should-not
      (plist-get
       (bitbucket-devops-cache-read bitbucket-devops-cache-test-context)
       :updated-at))
     (should-not bitbucket-devops-cache-test--read-eval-triggered))))

(ert-deftest bitbucket-devops-cache-merge-persists-pull-requests ()
  (bitbucket-devops-cache-test-with-temp-cache
   (bitbucket-devops-cache-merge-pull-requests
    bitbucket-devops-cache-test-context
    '(((id . 10) (updated_on . "2026-05-01T10:00:00Z"))))
   (should
    (equal
     (mapcar
      (lambda (pull-request) (alist-get 'id pull-request))
      (bitbucket-devops-cache-merge-pull-requests
       bitbucket-devops-cache-test-context
       '(((id . 11) (updated_on . "2026-06-01T10:00:00Z")))))
     '(11 10)))
   (should
    (equal
     (mapcar
      (lambda (pull-request) (alist-get 'id pull-request))
      (bitbucket-devops-cache-pull-requests
       bitbucket-devops-cache-test-context))
     '(11 10)))))

(ert-deftest bitbucket-devops-cache-prunes-and-replaces-pull-requests ()
  (bitbucket-devops-cache-test-with-temp-cache
   (let ((bitbucket-devops-cache-max-pull-requests-per-repo 2))
     (bitbucket-devops-cache-merge-pull-requests
      bitbucket-devops-cache-test-context
      '(((id . 10) (title . "Old") (updated_on . "2026-04-01T10:00:00Z"))
        ((id . 11) (updated_on . "2026-05-01T10:00:00Z"))
        ((id . 12) (updated_on . "2026-06-01T10:00:00Z"))))
     (bitbucket-devops-cache-merge-pull-requests
      bitbucket-devops-cache-test-context
      '(((id . 11) (title . "Updated")
         (updated_on . "2026-06-02T10:00:00Z"))))
     (let ((cached
            (bitbucket-devops-cache-pull-requests
             bitbucket-devops-cache-test-context)))
       (should (equal (mapcar (lambda (pr) (alist-get 'id pr)) cached)
                      '(11 12)))
       (should (equal (alist-get 'title (car cached)) "Updated"))))))

(ert-deftest bitbucket-devops-cache-persists-reviewer-users ()
  (bitbucket-devops-cache-test-with-temp-cache
   (let ((users
          '(((display_name . "Grace Hopper")
             (nickname . "grace")
             (uuid . "{grace}")))))
     (should-not
      (bitbucket-devops-cache-reviewer-users-cached-p
       bitbucket-devops-cache-test-context))
     (bitbucket-devops-cache-put-reviewer-users
      bitbucket-devops-cache-test-context users)
     (should
      (bitbucket-devops-cache-reviewer-users-cached-p
       bitbucket-devops-cache-test-context))
     (should
      (equal
       (bitbucket-devops-cache-reviewer-users
        bitbucket-devops-cache-test-context)
       users)))))

(ert-deftest bitbucket-devops-cache-records-empty-reviewer-user-lookups ()
  (bitbucket-devops-cache-test-with-temp-cache
   (bitbucket-devops-cache-put-reviewer-users
    bitbucket-devops-cache-test-context nil)
   (should
    (bitbucket-devops-cache-reviewer-users-cached-p
     bitbucket-devops-cache-test-context))
   (should-not
    (bitbucket-devops-cache-reviewer-users
     bitbucket-devops-cache-test-context))))

(provide 'bitbucket-devops-cache-test)
;;; bitbucket-devops-cache-test.el ends here
