;;; bitbucket-devops-pipelines-magit-test.el --- Tests for Magit push watching -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'bitbucket-devops-pipelines-magit)

(ert-deftest bitbucket-devops-pipelines-magit-watchable-push-args-detects-branch-push ()
  (should
   (bitbucket-devops-pipelines-magit--watchable-push-args-p
    '("push" "-v" "origin" "main:refs/heads/main")))
  (should-not
   (bitbucket-devops-pipelines-magit--watchable-push-args-p
    '("fetch" "origin")))
  (should-not
   (bitbucket-devops-pipelines-magit--watchable-push-args-p
    '("push" "--dry-run" "origin" "main")))
  (should-not
   (bitbucket-devops-pipelines-magit--watchable-push-args-p
    '("push" "-v" "origin" "--tags")))
  (should-not
   (bitbucket-devops-pipelines-magit--watchable-push-args-p
    '("push" "origin" "release-tag")))
  (should-not
   (bitbucket-devops-pipelines-magit--watchable-push-args-p
    '("push" "-v" "origin" ":")))
  (should-not
   (bitbucket-devops-pipelines-magit--watchable-push-args-p
    '("push" "-v" "origin" ":refs/heads/obsolete")))
  (should-not
   (bitbucket-devops-pipelines-magit--watchable-push-args-p
    '("push" "-v" "origin" "main:refs/notes/review"))))

(ert-deftest bitbucket-devops-pipelines-magit-targets-context-remote ()
  (cl-letf (((symbol-function 'magit-list-remotes)
             (lambda () '("origin" "backup"))))
    (should
     (bitbucket-devops-pipelines-magit--targets-context-remote-p
      '("push" "-v" "origin" "main")
      '(:remote "origin")))
    (should-not
     (bitbucket-devops-pipelines-magit--targets-context-remote-p
      '("push" "-v" "backup" "main")
      '(:remote "origin")))
    (should
     (bitbucket-devops-pipelines-magit--targets-context-remote-p
      '("push" "-v")
      '(:remote "origin")))))

(ert-deftest bitbucket-devops-pipelines-magit-wrap-sentinel-runs-hook-once-after-success ()
  (let (hook-context sentinel-called stored-sentinel property)
    (cl-letf (((symbol-function 'process-sentinel)
               (lambda (_process)
                 (lambda (&rest _args) (setq sentinel-called t))))
              ((symbol-function 'set-process-sentinel)
               (lambda (_process sentinel) (setq stored-sentinel sentinel)))
              ((symbol-function 'process-status) (lambda (_process) 'exit))
              ((symbol-function 'process-exit-status) (lambda (_process) 0))
              ((symbol-function 'process-get)
               (lambda (_process _key) property))
              ((symbol-function 'process-put)
               (lambda (_process _key value) (setq property value)))
              ((symbol-function
                'bitbucket-devops-pipelines-magit--run-after-push-hook)
               (lambda (context) (setq hook-context context))))
      (bitbucket-devops-pipelines-magit--wrap-process-sentinel
       'process
       '(:commit "abc"))
      (funcall stored-sentinel 'process "finished\n")
      (funcall stored-sentinel 'process "finished\n")
      (should sentinel-called)
      (should (equal hook-context '(:commit "abc"))))))

(ert-deftest bitbucket-devops-pipelines-magit-wrap-sentinel-ignores-failed-push ()
  (let (hook-context stored-sentinel)
    (cl-letf (((symbol-function 'process-sentinel) (lambda (_process) nil))
              ((symbol-function 'set-process-sentinel)
               (lambda (_process sentinel) (setq stored-sentinel sentinel)))
              ((symbol-function 'process-status) (lambda (_process) 'exit))
              ((symbol-function 'process-exit-status) (lambda (_process) 1))
              ((symbol-function 'process-get) (lambda (&rest _args) nil))
              ((symbol-function
                'bitbucket-devops-pipelines-magit--run-after-push-hook)
               (lambda (context) (setq hook-context context))))
      (bitbucket-devops-pipelines-magit--wrap-process-sentinel
       'process
       '(:commit "abc"))
      (funcall stored-sentinel 'process "failed\n")
      (should-not hook-context))))

(ert-deftest bitbucket-devops-pipelines-magit-advice-captures-context-before-push ()
  (let (observed-context observed-args)
    (cl-letf (((symbol-function 'bitbucket-devops-context-resolve)
               (lambda (directory)
                 (should (equal directory "/repository/"))
                 '(:remote "origin" :commit "abc")))
              ((symbol-function 'magit-list-remotes)
               (lambda () '("origin")))
              ((symbol-function 'processp) (lambda (_process) t))
              ((symbol-function
                'bitbucket-devops-pipelines-magit--wrap-process-sentinel)
               (lambda (_process context) (setq observed-context context))))
      (let ((default-directory "/repository/"))
        (bitbucket-devops-pipelines-magit--around-run-git-async
         (lambda (&rest args)
           (setq observed-args args)
           'process)
         "push"
         "-v"
         "origin"
         "main"))
      (should (equal observed-args '("push" "-v" "origin" "main")))
      (should (equal observed-context '(:remote "origin" :commit "abc"))))))

(ert-deftest bitbucket-devops-pipelines-magit-advice-ignores-other-remote ()
  (let (wrapped)
    (cl-letf (((symbol-function 'bitbucket-devops-context-resolve)
               (lambda (_directory) '(:remote "origin" :commit "abc")))
              ((symbol-function 'magit-list-remotes)
               (lambda () '("origin" "backup")))
              ((symbol-function 'processp) (lambda (_process) t))
              ((symbol-function
                'bitbucket-devops-pipelines-magit--wrap-process-sentinel)
               (lambda (&rest _args) (setq wrapped t))))
      (bitbucket-devops-pipelines-magit--around-run-git-async
       (lambda (&rest _args) 'process)
       "push"
       "-v"
       "backup"
       "main")
      (should-not wrapped))))

(provide 'bitbucket-devops-pipelines-magit-test)
;;; bitbucket-devops-pipelines-magit-test.el ends here
