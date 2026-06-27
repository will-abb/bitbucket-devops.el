;;; run-tests.el --- Live integration test runner -*- lexical-binding: t; -*-

;;; Code:

(setq load-prefer-newer t)

(require 'package)
(package-initialize)

(when-let ((package-directory
            (getenv "BITBUCKET_DEVOPS_TEST_EMACS_PACKAGE_DIRECTORY")))
  (dolist (entry (directory-files package-directory t "\\`[^.]"))
    (when (file-directory-p entry)
      (add-to-list 'load-path entry))))

(let ((test-directory (file-name-directory (or load-file-name buffer-file-name))))
  (dolist (test-file (directory-files test-directory t "-test\\.el\\'"))
    (load test-file nil nil t)))

(ert-run-tests-batch-and-exit)

;;; run-tests.el ends here
