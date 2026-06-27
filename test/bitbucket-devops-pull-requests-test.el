;;; bitbucket-devops-pull-requests-test.el --- Tests for Bitbucket PR read models -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Code:

(require 'ert)
(require 'json)
(require 'bitbucket-devops-pull-requests)

(defconst bitbucket-devops-pull-requests-test-fixtures-directory
  (expand-file-name
   "fixtures"
   (file-name-directory (or load-file-name buffer-file-name)))
  "Directory containing sanitized pull request fixtures.")

(defun bitbucket-devops-pull-requests-test-read-json-fixture (name)
  "Return JSON fixture NAME parsed as an alist."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name name bitbucket-devops-pull-requests-test-fixtures-directory))
    (json-parse-buffer
     :object-type 'alist
     :array-type 'list
     :null-object nil
     :false-object nil)))

(ert-deftest bitbucket-devops-pull-requests-nested-get-stops-at-scalar-values ()
  (should
   (equal
    (bitbucket-devops-pull-requests--nested-get
     '((description . ((raw . "Structured"))))
     'description
     'raw)
    "Structured"))
  (should-not
   (bitbucket-devops-pull-requests--nested-get
    '((description . "Plain text"))
    'description
    'raw)))

(ert-deftest bitbucket-devops-pull-requests-summary-renders-list-fields ()
  (let* ((page
          (bitbucket-devops-pull-requests-test-read-json-fixture
           "pull-requests-page-1.json"))
         (pull-request (car (alist-get 'values page))))
    (should
     (equal
      (bitbucket-devops-pull-requests-summary pull-request)
      '(:id 11
        :title "Development"
        :state "MERGED"
        :draft nil
        :author "Will Bosch"
        :source-branch "development"
        :destination-branch "master"
        :created-on "2026-04-28T14:10:00.000000+00:00"
        :updated-on "2026-04-28T15:30:00.000000+00:00"
        :reviewer-count 2
        :approval-count 1
        :reviewers ("Ada Reviewer" "Grace Reviewer")
        :approved-by ("Ada Reviewer"))))))

(ert-deftest bitbucket-devops-pull-requests-summary-detects-draft-prs ()
  (let* ((page
          (bitbucket-devops-pull-requests-test-read-json-fixture
           "pull-requests-page-1.json"))
         (pull-request (cadr (alist-get 'values page)))
         (summary (bitbucket-devops-pull-requests-summary pull-request)))
    (should (equal (plist-get summary :id) 10))
    (should (eq (plist-get summary :draft) t))
    (should (equal (plist-get summary :destination-branch) "main"))
    (should (= (plist-get summary :reviewer-count) 0))
    (should (= (plist-get summary :approval-count) 0))))

(ert-deftest bitbucket-devops-pull-requests-review-summary-counts-approvals ()
  (let* ((page
          (bitbucket-devops-pull-requests-test-read-json-fixture
           "pull-requests-page-1.json"))
         (pull-request (car (alist-get 'values page))))
    (should
     (equal
      (bitbucket-devops-pull-requests-review-summary pull-request)
      '(:reviewer-count 2
        :approval-count 1
        :reviewers ("Ada Reviewer" "Grace Reviewer")
        :approved-by ("Ada Reviewer"))))))

(ert-deftest bitbucket-devops-pull-requests-status-summary-counts-build-states ()
  (let ((page
         (bitbucket-devops-pull-requests-test-read-json-fixture
          "pull-request-statuses.json")))
    (should
     (equal
      (bitbucket-devops-pull-requests-status-summary page)
      '(:total 4
        :passed 2
        :failed 1
        :in-progress 1
        :stopped 0
        :unknown 0)))))

(ert-deftest bitbucket-devops-pull-requests-task-summary-counts-open-work ()
  (let ((page
         (bitbucket-devops-pull-requests-test-read-json-fixture
          "pull-request-tasks.json")))
    (should
     (equal
      (bitbucket-devops-pull-requests-task-summary page)
      '(:total 3 :resolved 1 :unresolved 2)))
    (should
     (equal
      (bitbucket-devops-pull-requests-task-text
       (car (alist-get 'values page)))
      "Update documentation"))))

(ert-deftest bitbucket-devops-pull-requests-comment-summary-counts-comments-and-replies ()
  (let ((page
         (bitbucket-devops-pull-requests-test-read-json-fixture
          "pull-request-comments.json")))
    (should
     (equal
      (bitbucket-devops-pull-requests-comment-summary page)
      '(:total 3 :comments 1 :replies 1 :deleted 1)))))

(ert-deftest bitbucket-devops-pull-requests-comment-helpers-return-author-and-text ()
  (let* ((page
          (bitbucket-devops-pull-requests-test-read-json-fixture
           "pull-request-comments.json"))
         (comments (alist-get 'values page))
         (comment (car comments))
         (reply (cadr comments)))
    (should-not (bitbucket-devops-pull-requests-comment-reply-p comment))
    (should (bitbucket-devops-pull-requests-comment-reply-p reply))
    (should (bitbucket-devops-pull-requests-comment-resolved-p comment))
    (should-not (bitbucket-devops-pull-requests-comment-resolved-p reply))
    (should
     (equal
      (bitbucket-devops-pull-requests-comment-author-name comment)
      "Ada Reviewer"))
    (should
     (equal
      (bitbucket-devops-pull-requests-comment-text reply)
      "Yes, it points the package at the new test repo."))))

(ert-deftest bitbucket-devops-pull-requests-diffstat-summary-counts-files-and-lines ()
  (let ((page
         (bitbucket-devops-pull-requests-test-read-json-fixture
          "pull-request-diffstat.json")))
    (should
     (equal
      (bitbucket-devops-pull-requests-diffstat-summary page)
      '(:files 4
        :added 1
        :removed 1
        :modified 1
        :renamed 1
        :lines-added 72
        :lines-removed 19)))))

(provide 'bitbucket-devops-pull-requests-test)
;;; bitbucket-devops-pull-requests-test.el ends here
