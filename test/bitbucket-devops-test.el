;;; bitbucket-devops-pipelines-test.el --- Package entry-point tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'bitbucket-devops)

(ert-deftest bitbucket-devops-dispatch-exposes-q-quit-suffix ()
  (should
   (equal
    (transient-get-suffix 'bitbucket-devops-dispatch "q")
    (transient-get-suffix
     'bitbucket-devops-dispatch #'transient-quit-one))))

(ert-deftest bitbucket-devops-dispatch-removes-command-panel-before-setup ()
  (let (observed)
    (cl-letf (((symbol-function 'bitbucket-devops-ui--delete-command-panel)
               (lambda () (push 'delete observed)))
              ((symbol-function 'transient-setup)
               (lambda (prefix &rest _args)
                 (push (list 'setup prefix) observed))))
      (call-interactively #'bitbucket-devops-dispatch))
    (should
     (equal observed
            '((setup bitbucket-devops-dispatch) delete)))))

(ert-deftest bitbucket-devops-dispatch-exposes-only-repository-actions ()
  (dolist (key '("h" "l" "c" "R" "r" "a" "m" "b" "o" "t" "x" "q"))
    (should (transient-get-suffix 'bitbucket-devops-dispatch key)))
  (dolist (key '("p" "P" "u" "v" "w" "W" "d" "s"))
    (should-error
     (transient-get-suffix 'bitbucket-devops-dispatch key))))

(ert-deftest bitbucket-devops-dispatch-run-opens-configured-pipeline-picker ()
  (should
   (equal
    (transient-get-suffix 'bitbucket-devops-dispatch "r")
    (transient-get-suffix
     'bitbucket-devops-dispatch
     #'bitbucket-devops-pipelines-run-configured))))

(ert-deftest bitbucket-devops-pipelines-removes-direct-branch-run-command ()
  (should-not (fboundp 'bitbucket-devops-pipelines-run)))

(ert-deftest bitbucket-devops-dispatch-uses-at-most-three-columns ()
  (should
   (<=
    (length
     (aref
      (car (get 'bitbucket-devops-dispatch 'transient--layout))
      3))
    3)))

(ert-deftest bitbucket-devops-pipelines-toggle-auto-download-logs-toggles-live-value ()
  (let ((bitbucket-devops-pipelines-auto-download-logs nil))
    (bitbucket-devops-pipelines-toggle-auto-download-logs)
    (should bitbucket-devops-pipelines-auto-download-logs)
    (bitbucket-devops-pipelines-toggle-auto-download-logs)
    (should-not bitbucket-devops-pipelines-auto-download-logs)))

(ert-deftest bitbucket-devops-pipelines-toggle-magit-push-watch-toggles-live-mode ()
  (let ((bitbucket-devops-pipelines-magit-push-watch-mode nil))
    (cl-letf (((symbol-function 'bitbucket-devops-pipelines-magit-push-watch-mode)
               (lambda (arg)
                 (setq bitbucket-devops-pipelines-magit-push-watch-mode
                       (> arg 0)))))
      (bitbucket-devops-pipelines-toggle-magit-push-watch)
      (should bitbucket-devops-pipelines-magit-push-watch-mode)
      (bitbucket-devops-pipelines-toggle-magit-push-watch)
      (should-not bitbucket-devops-pipelines-magit-push-watch-mode))))

(provide 'bitbucket-devops-pipelines-test)
;;; bitbucket-devops-pipelines-test.el ends here
