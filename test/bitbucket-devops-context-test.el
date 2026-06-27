;;; bitbucket-devops-context-test.el --- Tests for repository context -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'bitbucket-devops-context)

(ert-deftest bitbucket-devops-context-parse-ssh-remote-scp-form ()
  (should
   (equal
    (bitbucket-devops-context-parse-ssh-remote
     "git@bitbucket.org:workspace/repository.git")
    '(:workspace "workspace" :repo-slug "repository"))))

(ert-deftest bitbucket-devops-context-parse-ssh-remote-scp-form-without-suffix ()
  (should
   (equal
    (bitbucket-devops-context-parse-ssh-remote
     "git@bitbucket.org:workspace/repository")
    '(:workspace "workspace" :repo-slug "repository"))))

(ert-deftest bitbucket-devops-context-parse-ssh-remote-url-form ()
  (should
   (equal
    (bitbucket-devops-context-parse-ssh-remote
     "ssh://git@bitbucket.org/workspace/repository.git")
    '(:workspace "workspace" :repo-slug "repository"))))

(ert-deftest bitbucket-devops-context-parse-ssh-remote-url-form-without-suffix ()
  (should
   (equal
    (bitbucket-devops-context-parse-ssh-remote
     "ssh://git@bitbucket.org/workspace/repository")
    '(:workspace "workspace" :repo-slug "repository"))))

(ert-deftest bitbucket-devops-context-parse-ssh-remote-preserves-slug-characters ()
  (should
   (equal
    (bitbucket-devops-context-parse-ssh-remote
     "git@bitbucket.org:team-name/repository_name.with-punctuation.git")
    '(:workspace "team-name"
      :repo-slug "repository_name.with-punctuation"))))

(ert-deftest bitbucket-devops-context-parse-ssh-remote-rejects-unsupported-remotes ()
  (dolist (remote '("https://bitbucket.org/workspace/repository.git"
                    "git@github.com:workspace/repository.git"
                    "git@bitbucket.org:repository.git"
                    "git@bitbucket.org:workspace/"
                    "git@bitbucket.org:workspace/repository/extra"
                    "ssh://user@bitbucket.org/workspace/repository.git"
                    "ssh://git@bitbucket.org/workspace/repository with spaces.git"))
    (should-error
     (bitbucket-devops-context-parse-ssh-remote remote)
     :type 'user-error)))

(ert-deftest bitbucket-devops-context-resolve-uses-selected-remote-fetch-url ()
  (let ((bitbucket-devops-remote "upstream"))
    (cl-letf (((symbol-function 'magit-toplevel)
               (lambda () "/tmp/project/"))
              ((symbol-function 'magit-git-string)
               (lambda (&rest args)
                 (should (equal args '("remote" "get-url" "upstream")))
                 "git@bitbucket.org:workspace/repository.git"))
              ((symbol-function 'magit-get-current-branch)
               (lambda () "development"))
              ((symbol-function 'magit-rev-parse)
               (lambda (revision)
                 (should (equal revision "HEAD"))
                 "0123456789abcdef")))
      (should
       (equal
        (bitbucket-devops-context-resolve)
        '(:root "/tmp/project/"
          :remote "upstream"
          :workspace "workspace"
          :repo-slug "repository"
          :branch "development"
          :commit "0123456789abcdef"))))))

(ert-deftest bitbucket-devops-context-resolve-prefers-repository-override ()
  (let ((bitbucket-devops-repository-overrides
         '(("/tmp/project" . (:workspace "override-workspace"
                             :repo-slug "override-repository")))))
    (cl-letf (((symbol-function 'magit-toplevel)
               (lambda () "/tmp/project/"))
              ((symbol-function 'magit-git-string)
               (lambda (&rest _args)
                 (ert-fail "Remote lookup should not run when an override exists")))
              ((symbol-function 'magit-get-current-branch)
               (lambda () "development"))
              ((symbol-function 'magit-rev-parse)
               (lambda (_revision) "0123456789abcdef")))
      (should
       (equal
        (bitbucket-devops-context-resolve)
        '(:root "/tmp/project/"
          :remote "origin"
          :workspace "override-workspace"
          :repo-slug "override-repository"
          :branch "development"
          :commit "0123456789abcdef"))))))

(ert-deftest bitbucket-devops-context-resolve-preserves-detached-head ()
  (cl-letf (((symbol-function 'magit-toplevel)
             (lambda () "/tmp/project/"))
            ((symbol-function 'magit-git-string)
             (lambda (&rest _args)
               "git@bitbucket.org:workspace/repository.git"))
            ((symbol-function 'magit-get-current-branch)
             (lambda () nil))
            ((symbol-function 'magit-rev-parse)
             (lambda (_revision) "0123456789abcdef")))
    (let ((context (bitbucket-devops-context-resolve)))
      (should-not (plist-get context :branch))
      (should (equal (plist-get context :commit) "0123456789abcdef")))))

(ert-deftest bitbucket-devops-context-resolve-normalizes-explicit-directory ()
  (let (observed-directory)
    (cl-letf (((symbol-function 'magit-toplevel)
               (lambda ()
                 (setq observed-directory default-directory)
                 "/tmp/project/"))
              ((symbol-function 'magit-git-string)
               (lambda (&rest _args)
                 "git@bitbucket.org:workspace/repository.git"))
              ((symbol-function 'magit-get-current-branch)
               (lambda () "development"))
              ((symbol-function 'magit-rev-parse)
               (lambda (_revision) "0123456789abcdef")))
      (bitbucket-devops-context-resolve "/tmp/requested-directory")
      (should (equal observed-directory "/tmp/requested-directory/")))))

(ert-deftest bitbucket-devops-context-resolve-rejects-invalid-override ()
  (let ((bitbucket-devops-repository-overrides
         '(("/tmp/project/" . (:workspace "workspace")))))
    (cl-letf (((symbol-function 'magit-toplevel)
               (lambda () "/tmp/project/")))
      (should-error
       (bitbucket-devops-context-resolve)
       :type 'user-error))))

(ert-deftest bitbucket-devops-context-resolve-rejects-missing-head ()
  (cl-letf (((symbol-function 'magit-toplevel)
             (lambda () "/tmp/project/"))
            ((symbol-function 'magit-git-string)
             (lambda (&rest _args)
               "git@bitbucket.org:workspace/repository.git"))
            ((symbol-function 'magit-get-current-branch)
             (lambda () "development"))
            ((symbol-function 'magit-rev-parse)
             (lambda (_revision) nil)))
    (should-error
     (bitbucket-devops-context-resolve)
     :type 'user-error)))

(ert-deftest bitbucket-devops-context-resolve-rejects-missing-magit ()
  (let ((original (and (fboundp 'magit-toplevel)
                       (symbol-function 'magit-toplevel))))
    (unwind-protect
        (progn
          (fmakunbound 'magit-toplevel)
          (should-error
           (bitbucket-devops-context-resolve)
           :type 'user-error))
      (when original
        (fset 'magit-toplevel original)))))

(ert-deftest bitbucket-devops-context-resolve-rejects-missing-repository ()
  (cl-letf (((symbol-function 'magit-toplevel)
             (lambda () nil)))
    (should-error
     (bitbucket-devops-context-resolve)
     :type 'user-error)))

(ert-deftest bitbucket-devops-context-resolve-rejects-missing-remote ()
  (cl-letf (((symbol-function 'magit-toplevel)
             (lambda () "/tmp/project/"))
            ((symbol-function 'magit-git-string)
             (lambda (&rest _args) nil)))
    (should-error
     (bitbucket-devops-context-resolve)
     :type 'user-error)))

(ert-deftest bitbucket-devops-context-require-branch-rejects-detached-head ()
  (should-error
   (bitbucket-devops-context-require-branch
    '(:root "/tmp/project/" :branch nil :commit "0123456789abcdef"))
   :type 'user-error))

(ert-deftest bitbucket-devops-context-require-branch-returns-current-branch ()
  (should
   (equal
    (bitbucket-devops-context-require-branch
     '(:root "/tmp/project/"
       :branch "development"
       :commit "0123456789abcdef"))
    "development")))

(provide 'bitbucket-devops-context-test)
;;; bitbucket-devops-context-test.el ends here
