;;; run-tests.el --- Batch test runner for bitbucket-devops.el -*- lexical-binding: t; -*-

;;; Code:

(setq load-prefer-newer t)

(let ((test-directory (file-name-directory (or load-file-name buffer-file-name))))
  (dolist (test-file (directory-files test-directory t "-test\\.el\\'"))
    (load test-file nil nil t)))

(when (boundp 'bitbucket-devops-cache-directory)
  (let ((cache-directory (make-temp-file "bitbucket-devops-pipelines-test-cache-" t)))
    (setq bitbucket-devops-cache-directory cache-directory)
    (add-hook 'kill-emacs-hook
              (lambda ()
                (when (file-directory-p cache-directory)
                  (delete-directory cache-directory t))))))

(ert-run-tests-batch-and-exit)

;;; run-tests.el ends here
