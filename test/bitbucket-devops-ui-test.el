;;; bitbucket-devops-ui-test.el --- Tests for pipeline UI buffers -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'bitbucket-devops-ui)

(defconst bitbucket-devops-ui-test-fixtures-directory
  (expand-file-name
   "fixtures"
   (file-name-directory (or load-file-name buffer-file-name)))
  "Directory containing sanitized REST response fixtures.")

(defun bitbucket-devops-ui-test-read-json-fixture (name)
  "Return JSON fixture NAME parsed as an alist."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name name bitbucket-devops-ui-test-fixtures-directory))
    (json-parse-buffer
     :object-type 'alist
     :array-type 'list
     :null-object nil
     :false-object nil)))

(defun bitbucket-devops-ui-test-strip-row-properties (row)
  "Return ROW with text properties removed from each displayed column."
  (list
   (car row)
   (vconcat
    (mapcar #'substring-no-properties (append (cadr row) nil)))))

(ert-deftest bitbucket-devops-ui-pipeline-row-renders-recorded-pipeline ()
  (let* ((page
          (bitbucket-devops-ui-test-read-json-fixture
           "pipelines-page-1.json"))
         (pipeline (car (alist-get 'values page))))
    (should
     (equal
      (bitbucket-devops-ui-test-strip-row-properties
       (let ((bitbucket-devops-pipelines-display-time-zone t))
         (bitbucket-devops-ui--pipeline-row pipeline)))
      '("{pipeline-12}"
        ["12"
         "SUCCESSFUL"
         "default"
         ""
         "main"
         "0123456789ab"
         "Test User <test@example.com>"
         "2026-05-31 17:16:00 GMT"
         "8s"
         "Add smoke pipeline"])))))

(ert-deftest bitbucket-devops-ui-pipeline-row-styles-columns ()
  (let* ((page
          (bitbucket-devops-ui-test-read-json-fixture
           "pipelines-page-1.json"))
         (pipeline (car (alist-get 'values page)))
         (_
          (setf (alist-get 'bitbucket-devops-pipelines-deployments pipeline)
                '(((number . 1)
                   (environment . ((name . "development")))))))
         (columns (cadr (bitbucket-devops-ui--pipeline-row pipeline))))
    (should (eq (get-text-property 0 'face (aref columns 0))
                'bitbucket-devops-pipelines-build-face))
    (should (eq (get-text-property 0 'face (aref columns 1))
                'bitbucket-devops-pipelines-success-face))
    (should (eq (get-text-property 0 'face (aref columns 2))
                'bitbucket-devops-pipelines-secondary-face))
    (should (eq (get-text-property 0 'face (aref columns 3))
                'bitbucket-devops-pipelines-deployment-face))
    (should (eq (get-text-property 0 'face (aref columns 4))
                'bitbucket-devops-pipelines-branch-face))
    (should (eq (get-text-property 0 'face (aref columns 5))
                'bitbucket-devops-pipelines-commit-face))
    (should (eq (get-text-property 0 'face (aref columns 6))
                'bitbucket-devops-pipelines-author-face))
    (should (eq (get-text-property 0 'face (aref columns 7))
                'bitbucket-devops-pipelines-secondary-face))
    (should (eq (get-text-property 0 'face (aref columns 8))
                'bitbucket-devops-pipelines-secondary-face))
    (should (eq (get-text-property 0 'face (aref columns 9))
                'bitbucket-devops-pipelines-message-face))))

(ert-deftest bitbucket-devops-ui-pipeline-type-label-distinguishes-custom-runs ()
  (should
   (equal
    (bitbucket-devops-ui--pipeline-type-label
     '((target . ((selector . ((pattern . "manual-smoke")))))))
    "custom: manual-smoke"))
  (should
   (equal
    (bitbucket-devops-ui--pipeline-type-label '((target . nil)))
    "default")))

(ert-deftest bitbucket-devops-ui-pipeline-state-label-shows-paused-result ()
  (should
   (equal
    (bitbucket-devops-ui--pipeline-state-label
     '((state . ((name . "IN_PROGRESS")
                 (result . ((name . "PAUSED")))))))
    "PAUSED")))

(ert-deftest bitbucket-devops-ui-pipeline-state-label-shows-paused-stage ()
  (should
   (equal
    (bitbucket-devops-ui--pipeline-state-label
     '((state . ((name . "IN_PROGRESS")
                 (stage . ((name . "PAUSED")))))))
    "PAUSED")))

(ert-deftest bitbucket-devops-ui-step-state-label-keeps-api-pending-name ()
  (should
   (equal
    (bitbucket-devops-ui--step-state-label
     '((state . ((name . "PENDING")
                 (stage . ((name . "PAUSED")))))))
    "PENDING")))

(ert-deftest bitbucket-devops-ui-deployment-names-use-execution-order ()
  (should
   (equal
    (bitbucket-devops-ui--deployment-names
     '(((number . 2) (environment . ((name . "uat"))))
       ((number . 1) (environment . ((name . "development"))))
       ((number . 3) (environment . ((name . "production"))))))
    '("development" "uat" "production"))))

(ert-deftest bitbucket-devops-ui-pipeline-row-renders-deployments-as-csv ()
  (let ((pipeline
         '((uuid . "{pipeline-42}")
           (state . ((name . "COMPLETED")
                     (result . ((name . "SUCCESSFUL")))))
           (target . ((ref_name . "main") (commit . ((hash . "abc")))))
           (bitbucket-devops-pipelines-deployments
            . (((number . 2) (environment . ((name . "uat"))))
               ((number . 1) (environment . ((name . "development"))))
               ((number . 3) (environment . ((name . "production")))))))))
    (should
     (equal
      (substring-no-properties
       (aref (cadr (bitbucket-devops-ui--pipeline-row pipeline)) 3))
      "development,uat,production"))))

(ert-deftest bitbucket-devops-ui-history-enrich-page-fetches-unique-commits ()
  (let* ((context '(:workspace "williseed1" :repo-slug "test"))
         (pipeline
          '((uuid . "{pipeline-12}")
            (target . ((commit . ((hash . "abc123")))))))
         (page `((values . (,pipeline ,(copy-tree pipeline)))))
         observed
         callback-page)
    (clrhash bitbucket-devops-ui--commit-cache)
    (cl-letf (((symbol-function 'bitbucket-devops-rest-get-commit)
               (lambda (request-context hash callback)
                 (push (list request-context hash) observed)
                 (funcall
                  callback
                  '((hash . "abc123")
                    (author . ((raw . "Test User <test@example.com>")))
                    (message . "Commit message"))
                  nil))))
      (bitbucket-devops-ui--history-enrich-page
       context
       page
       (lambda (value) (setq callback-page value)))
      (should (= (length observed) 1))
      (should (eq callback-page page))
      (dolist (value (alist-get 'values page))
        (should
         (equal
          (alist-get 'message (bitbucket-devops-ui--pipeline-commit value))
          "Commit message"))))))

(ert-deftest bitbucket-devops-ui-history-enrich-deployments-caches-pipeline ()
  (let* ((context '(:workspace "williseed1" :repo-slug "test"))
         (pipeline '((uuid . "{pipeline-42}")
                     (state . ((name . "COMPLETED")))))
         (page `((values . (,pipeline))))
         observed
         callback-page)
    (clrhash bitbucket-devops-ui--deployment-cache)
    (cl-letf (((symbol-function
                'bitbucket-devops-ui--list-all-deployments)
               (lambda (request-context pipeline-uuid callback &rest _args)
                 (setq observed (list request-context pipeline-uuid))
                 (funcall
                  callback
                  '(((number . 1)
                     (environment . ((name . "development")))))
                  nil))))
      (bitbucket-devops-ui--history-enrich-deployments
       context
       page
       (lambda (value) (setq callback-page value)))
      (should
       (equal
        observed
        '((:workspace "williseed1" :repo-slug "test") "{pipeline-42}")))
      (should (eq callback-page page))
      (should
       (equal
        (bitbucket-devops-ui--pipeline-deployment-label pipeline)
        "development")))))

(ert-deftest bitbucket-devops-ui-history-load-cache-renders-pipelines ()
  (let ((bitbucket-devops-cache-directory
         (make-temp-file "bitbucket-devops-ui-cache-" t)))
    (unwind-protect
        (let ((context '(:workspace "williseed1" :repo-slug "test"))
              (bitbucket-devops-cache-enabled t)
              (cached-pipeline
               '((uuid . "{cached}")
                 (build_number . 4)
                 (created_on . "2026-06-01T10:00:00Z")
                 (state . ((name . "COMPLETED")
                           (result . ((name . "SUCCESSFUL")))))
                 (target . ((ref_name . "main")
                            (commit . ((hash . "abc123"))))))))
          (bitbucket-devops-cache-merge-pipelines
           context
           (list cached-pipeline))
          (with-temp-buffer
            (bitbucket-devops-pipelines-history-mode)
            (setq-local bitbucket-devops-ui--context context)
            (bitbucket-devops-ui--history-load-cache)
            (should
             (equal
              (mapcar
               (lambda (pipeline) (alist-get 'uuid pipeline))
               bitbucket-devops-ui--history-pipelines)
              '("{cached}")))
            (should (equal (caar tabulated-list-entries) "{cached}"))))
      (delete-directory bitbucket-devops-cache-directory t))))

(ert-deftest bitbucket-devops-ui-history-receive-page-merges-cache ()
  (let ((bitbucket-devops-cache-directory
         (make-temp-file "bitbucket-devops-ui-cache-" t)))
    (unwind-protect
        (let ((context '(:workspace "williseed1" :repo-slug "test"))
              (bitbucket-devops-cache-enabled t)
              (old-pipeline
               '((uuid . "{old}")
                 (build_number . 1)
                 (created_on . "2026-05-31T10:00:00Z")
                 (target . ((commit . ((hash . "old"))))))))
          (bitbucket-devops-cache-merge-pipelines
           context
           (list old-pipeline))
          (with-temp-buffer
            (bitbucket-devops-pipelines-history-mode)
            (setq-local bitbucket-devops-ui--context context)
            (bitbucket-devops-ui--history-receive-page
             '((values . (((uuid . "{new}")
                           (build_number . 2)
                           (created_on . "2026-06-01T10:00:00Z")
                           (target . ((commit . ((hash . "new")))))))))
             nil
             nil)
            (should
             (equal
              (mapcar
               (lambda (pipeline) (alist-get 'uuid pipeline))
               bitbucket-devops-ui--history-pipelines)
              '("{new}" "{old}")))))
      (delete-directory bitbucket-devops-cache-directory t))))

(ert-deftest bitbucket-devops-ui-list-all-deployments-filters-server-results ()
  (let (callback-args)
    (cl-letf (((symbol-function 'bitbucket-devops-rest-list-deployments)
               (lambda (_context _pipeline-uuid callback &optional _next-url)
                 (funcall
                  callback
                  '((values
                     . (((uuid . "{deployment-42}")
                         (deployable
                          . ((pipeline . ((uuid . "{pipeline-42}")))))
                         (environment . ((name . "production"))))
                        ((uuid . "{deployment-other}")
                         (deployable
                          . ((pipeline . ((uuid . "{pipeline-other}")))))
                         (environment . ((name . "development")))))))
                  nil))))
      (bitbucket-devops-ui--list-all-deployments
       '(:workspace "williseed1" :repo-slug "test")
       "{pipeline-42}"
       (lambda (&rest args) (setq callback-args args)))
      (should-not (cadr callback-args))
      (should
       (equal
        (mapcar
         (lambda (deployment) (alist-get 'uuid deployment))
         (car callback-args))
        '("{deployment-42}"))))))

(ert-deftest bitbucket-devops-ui-state-face-distinguishes-outcomes ()
  (should
   (eq (bitbucket-devops-ui--state-face "SUCCESSFUL")
       'bitbucket-devops-pipelines-success-face))
  (should
   (eq (bitbucket-devops-ui--state-face "ERROR")
       'bitbucket-devops-pipelines-error-face))
  (should
   (eq (bitbucket-devops-ui--state-face "FAILED")
       'bitbucket-devops-pipelines-error-face))
  (should
   (eq (bitbucket-devops-ui--state-face "STOPPED")
       'bitbucket-devops-pipelines-stopped-face))
  (should
   (eq (bitbucket-devops-ui--state-face "IN_PROGRESS")
       'bitbucket-devops-pipelines-in-progress-face)))

(ert-deftest bitbucket-devops-ui-stopped-step-log-is-unavailable ()
  (let ((pipeline
         '((state . ((name . "COMPLETED")
                     (result . ((name . "STOPPED")))))))
        (step
         '((state . ((name . "COMPLETED")
                     (result . ((name . "STOPPED"))))))))
    (should-not
     (bitbucket-devops-ui--step-log-available-p pipeline step))
    (should
     (string-match-p
      "stopped"
      (bitbucket-devops-ui--step-log-unavailable-reason
       pipeline
       step)))))

(ert-deftest bitbucket-devops-ui-stopped-pipeline-keeps-successful-step-log ()
  (should
   (bitbucket-devops-ui--step-log-available-p
    '((state . ((name . "COMPLETED")
                (result . ((name . "STOPPED"))))))
    '((state . ((name . "COMPLETED")
                (result . ((name . "SUCCESSFUL")))))))))

(ert-deftest bitbucket-devops-ui-paused-pipeline-keeps-completed-step-log ()
  (should
   (bitbucket-devops-ui--step-log-available-p
    '((state . ((name . "IN_PROGRESS")
                (result . ((name . "PAUSED"))))))
    '((state . ((name . "COMPLETED")
                (result . ((name . "SUCCESSFUL")))))))))

(ert-deftest bitbucket-devops-ui-step-log-404-message-explains-missing-log ()
  (should
   (equal
    (bitbucket-devops-ui--step-log-request-error-message
     '(:type http :status 404 :message "Bitbucket API request failed"))
    (concat
     "Bitbucket did not provide a log for this step; "
     "it may have been stopped before a log was created"))))

(ert-deftest bitbucket-devops-ui-format-time-supports-configurable-zone ()
  (let ((timestamp "2026-06-01T02:30:48.993045954Z")
        (bitbucket-devops-pipelines-display-time-format "%Y-%m-%d %H:%M:%S %Z"))
    (let ((bitbucket-devops-pipelines-display-time-zone t))
      (should
       (equal (bitbucket-devops-ui--format-time timestamp)
              "2026-06-01 02:30:48 GMT")))
    (let ((bitbucket-devops-pipelines-display-time-zone "America/Chicago"))
      (should
       (equal (bitbucket-devops-ui--format-time timestamp)
              "2026-05-31 21:30:48 CDT")))
    (should
     (equal (bitbucket-devops-ui--format-time "not-a-timestamp")
            "not-a-timestamp"))))

(ert-deftest bitbucket-devops-ui-history-receive-page-replaces-rows ()
  (let ((page
         (bitbucket-devops-ui-test-read-json-fixture
          "pipelines-page-1.json"))
        (bitbucket-devops-cache-enabled nil))
    (with-temp-buffer
      (bitbucket-devops-pipelines-history-mode)
      (setq-local bitbucket-devops-ui--history-loading t)
      (bitbucket-devops-ui--history-receive-page page nil nil)
      (should (= (length bitbucket-devops-ui--history-pipelines) 1))
      (should (= (length tabulated-list-entries) 1))
      (should
       (equal
        bitbucket-devops-ui--history-next-url
        "https://api.bitbucket.org/2.0/repositories/williseed1/test/pipelines?page=2"))
      (should-not bitbucket-devops-ui--history-loading))))

(ert-deftest bitbucket-devops-ui-history-mode-preserves-server-order ()
  (with-temp-buffer
    (bitbucket-devops-pipelines-history-mode)
    (should-not tabulated-list-sort-key)))

(ert-deftest bitbucket-devops-ui-tabulated-modes-truncate-expanded-lines ()
  (with-temp-buffer
    (visual-line-mode 1)
    (bitbucket-devops-pipelines-history-mode)
    (should-not tabulated-list-use-header-line)
    (should truncate-lines)
    (should-not word-wrap)
    (should-not visual-line-mode))
  (with-temp-buffer
    (visual-line-mode 1)
    (bitbucket-devops-pipelines-details-mode)
    (should-not tabulated-list-use-header-line)
    (should truncate-lines)
    (should-not word-wrap)
    (should-not visual-line-mode)))

(ert-deftest bitbucket-devops-ui-build-number-sort-is-numeric ()
  (should
   (bitbucket-devops-ui--pipeline-build-number-less-p
    '("{pipeline-9}" ["9"])
    '("{pipeline-10}" ["10"])))
  (should-not
   (bitbucket-devops-ui--pipeline-build-number-less-p
    '("{pipeline-10}" ["10"])
    '("{pipeline-9}" ["9"]))))

(ert-deftest bitbucket-devops-ui-history-receive-page-appends-rows ()
  (let ((first-page
         (bitbucket-devops-ui-test-read-json-fixture
          "pipelines-page-1.json"))
        (second-page
         (bitbucket-devops-ui-test-read-json-fixture
          "pipelines-page-2.json")))
    (with-temp-buffer
      (bitbucket-devops-pipelines-history-mode)
      (bitbucket-devops-ui--history-receive-page first-page nil nil)
      (bitbucket-devops-ui--history-receive-page second-page nil t)
      (should
       (equal
        (mapcar
         (lambda (pipeline) (alist-get 'build_number pipeline))
         bitbucket-devops-ui--history-pipelines)
        '(12 11)))
      (should (= (length tabulated-list-entries) 2))
      (should-not bitbucket-devops-ui--history-next-url))))

(ert-deftest bitbucket-devops-pipelines-history-refresh-requests-first-page ()
  (let (observed)
    (with-temp-buffer
      (bitbucket-devops-pipelines-history-mode)
      (setq-local bitbucket-devops-ui--context
                  '(:workspace "williseed1" :repo-slug "test"))
      (setq-local bitbucket-devops-ui--history-next-url "stale-next-url")
      (cl-letf (((symbol-function 'bitbucket-devops-rest-list-pipelines)
                 (lambda (context callback &optional next-url)
                   (setq observed (list context callback next-url))
                   'request-process))
                ((symbol-function
                  'bitbucket-devops-ui--list-all-paused-pipelines)
                 (lambda (&rest _args) 'request-process)))
        (should (eq (bitbucket-devops-pipelines-history-refresh) 'request-process))
        (should bitbucket-devops-ui--history-loading)
        (should
         (equal
          (list (car observed) (caddr observed))
          '((:workspace "williseed1" :repo-slug "test") nil)))))))

(ert-deftest bitbucket-devops-pipelines-history-load-more-requests-next-page ()
  (let ((next
         "https://api.bitbucket.org/2.0/repositories/williseed1/test/pipelines?page=2")
        observed)
    (with-temp-buffer
      (bitbucket-devops-pipelines-history-mode)
      (setq-local bitbucket-devops-ui--context
                  '(:workspace "williseed1" :repo-slug "test"))
      (setq-local bitbucket-devops-ui--history-next-url next)
      (cl-letf (((symbol-function 'bitbucket-devops-rest-list-pipelines)
                 (lambda (context callback &optional next-url)
                   (setq observed (list context callback next-url))
                   'request-process)))
        (should (eq (bitbucket-devops-pipelines-history-load-more) 'request-process))
        (should bitbucket-devops-ui--history-loading)
        (should
         (equal
          (list (car observed) (caddr observed))
          (list '(:workspace "williseed1" :repo-slug "test") next)))))))

(ert-deftest bitbucket-devops-ui-history-render-preserves-visible-scroll ()
  (let ((buffer
         (generate-new-buffer
          " *bitbucket-devops-history-scroll-test*")))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (bitbucket-devops-pipelines-history-mode)
          (setq-local
           bitbucket-devops-ui--history-pipelines
           (cl-loop
            for index from 1 to 40
            collect
            `((uuid . ,(format "{pipeline-%02d}" index))
              (build_number . ,index)
              (created_on . "2026-06-07T12:00:00Z")
              (state . ((name . "COMPLETED")
                        (result . ((name . "SUCCESSFUL")))))
              (target . ((ref_name . "main")
                         (commit . ((hash . "0123456789abcdef")))))))))
          (bitbucket-devops-ui--history-render)
          (goto-char (point-min))
          (forward-line 12)
          (set-window-point (selected-window) (point))
          (set-window-start (selected-window) (point))
          (let ((start-line (line-number-at-pos (window-start))))
            (bitbucket-devops-ui--history-render)
            (should (= (line-number-at-pos (window-start)) start-line)))
      (kill-buffer buffer))))

(ert-deftest bitbucket-devops-pipelines-history-selects-history-buffer ()
  (let ((buffer (generate-new-buffer " *bitbucket-devops-pipelines-history-test*"))
        selected)
    (unwind-protect
        (cl-letf (((symbol-function 'bitbucket-devops-context-resolve)
                   (lambda (_directory)
                     '(:workspace "williseed1" :repo-slug "test")))
                  ((symbol-function 'get-buffer-create)
                   (lambda (_name) buffer))
                  ((symbol-function 'bitbucket-devops-pipelines-history-refresh)
                   #'ignore)
                  ((symbol-function 'pop-to-buffer)
                   (lambda (target &rest _args)
                     (setq selected target))))
          (should (eq (bitbucket-devops-pipelines-history) buffer))
          (should (eq selected buffer)))
      (kill-buffer buffer))))

(ert-deftest bitbucket-devops-pipelines-watch-selected-uses-history-row ()
  (let (observed)
    (with-temp-buffer
      (bitbucket-devops-pipelines-history-mode)
      (setq-local bitbucket-devops-ui--context
                  '(:workspace "williseed1" :repo-slug "test"))
      (let ((inhibit-read-only t))
        (insert (propertize "pipeline row" 'tabulated-list-id "{pipeline-12}")))
      (goto-char (point-min))
      (cl-letf (((symbol-function 'bitbucket-devops-pipelines-watch-pipeline)
                 (lambda (context pipeline-uuid)
                   (setq observed (list context pipeline-uuid)))))
        (bitbucket-devops-pipelines-watch-selected)
        (should
         (equal
          observed
          '((:workspace "williseed1" :repo-slug "test")
            "{pipeline-12}")))))))

(ert-deftest bitbucket-devops-pipelines-watch-selected-uses-details-pipeline ()
  (let (observed)
    (with-temp-buffer
      (bitbucket-devops-pipelines-details-mode)
      (setq-local bitbucket-devops-ui--context
                  '(:workspace "williseed1" :repo-slug "test"))
      (setq-local bitbucket-devops-ui--details-pipeline-uuid "{pipeline-12}")
      (cl-letf (((symbol-function 'bitbucket-devops-pipelines-watch-pipeline)
                 (lambda (context pipeline-uuid)
                   (setq observed (list context pipeline-uuid)))))
        (bitbucket-devops-pipelines-watch-selected)
        (should
         (equal
          observed
          '((:workspace "williseed1" :repo-slug "test")
            "{pipeline-12}")))))))

(ert-deftest bitbucket-devops-ui-step-row-renders-recorded-step ()
  (let* ((page
          (bitbucket-devops-ui-test-read-json-fixture
           "steps-page-1.json"))
         (step (car (alist-get 'values page))))
    (should
     (equal
      (bitbucket-devops-ui-test-strip-row-properties
       (bitbucket-devops-ui--step-row step 1))
      '("{step-1}" ["1" "Build" "SUCCESSFUL" "" "5s"])))))

(ert-deftest bitbucket-devops-ui-step-row-renders-deployment ()
  (let ((step
         '((uuid . "{step-1}")
           (name . "Deploy UAT")
           (state . ((name . "COMPLETED")
                     (result . ((name . "SUCCESSFUL")))))
           (bitbucket-devops-pipelines-deployment . "uat")
           (duration_in_seconds . 5))))
    (should
     (equal
      (bitbucket-devops-ui-test-strip-row-properties
       (bitbucket-devops-ui--step-row step 1))
      '("{step-1}" ["1" "Deploy UAT" "SUCCESSFUL" "uat" "5s"])))))

(ert-deftest bitbucket-devops-ui-annotate-steps-deployments-matches-uuid ()
  (let ((steps '(((uuid . "{step-1}")) ((uuid . "{step-2}")))))
    (bitbucket-devops-ui--annotate-steps-deployments
     steps
     '(((step . ((uuid . "{step-2}")))
        (environment . ((name . "production"))))))
    (should-not
     (bitbucket-devops-ui--step-deployment-name (car steps)))
    (should
     (equal
      (bitbucket-devops-ui--step-deployment-name (cadr steps))
      "production"))))

(ert-deftest bitbucket-devops-ui-details-receive-steps-loads-next-page ()
  (let ((page
         (bitbucket-devops-ui-test-read-json-fixture
          "steps-page-1.json"))
        observed)
    (with-temp-buffer
      (bitbucket-devops-pipelines-details-mode)
      (setq-local bitbucket-devops-ui--context
                  '(:workspace "williseed1" :repo-slug "test"))
      (setq-local bitbucket-devops-ui--details-pipeline-uuid "{pipeline-12}")
      (setq-local bitbucket-devops-ui--details-loading t)
      (cl-letf (((symbol-function 'bitbucket-devops-rest-list-steps)
                 (lambda (context pipeline-uuid callback &optional next-url)
                   (setq observed
                         (list context pipeline-uuid callback next-url))
                   'request-process)))
        (should
         (eq
          (bitbucket-devops-ui--details-receive-steps page nil)
          'request-process))
        (should bitbucket-devops-ui--details-loading)
        (should (= (length bitbucket-devops-ui--details-steps) 1))
        (should
         (equal
          (list (car observed) (cadr observed) (cadddr observed))
          '((:workspace "williseed1" :repo-slug "test")
            "{pipeline-12}"
            "https://api.bitbucket.org/2.0/repositories/williseed1/test/pipelines/%7Bpipeline-12%7D/steps?page=2")))))))

(ert-deftest bitbucket-devops-ui-details-receive-steps-finishes-final-page ()
  (let ((page
         (bitbucket-devops-ui-test-read-json-fixture
          "steps-page-2.json")))
    (with-temp-buffer
      (bitbucket-devops-pipelines-details-mode)
      (setq-local bitbucket-devops-ui--details-loading t)
      (setq-local bitbucket-devops-ui--details-steps
                  (list '((uuid . "{step-1}"))))
      (bitbucket-devops-ui--details-receive-steps page nil)
      (should-not bitbucket-devops-ui--details-loading)
      (should (= (length bitbucket-devops-ui--details-steps) 2))
      (should (= (length tabulated-list-entries) 2)))))

(ert-deftest bitbucket-devops-ui-details-receive-steps-deduplicates-uuids ()
  (with-temp-buffer
    (bitbucket-devops-pipelines-details-mode)
    (setq-local bitbucket-devops-ui--details-loading t)
    (setq-local bitbucket-devops-ui--details-steps
                '(((uuid . "{step-1}") (name . "Old name"))))
    (bitbucket-devops-ui--details-receive-steps
     '((values . (((uuid . "{step-1}") (name . "New name"))
                  ((uuid . "{step-2}") (name . "Approve")))))
     nil)
    (should-not bitbucket-devops-ui--details-loading)
    (should
     (equal
      (mapcar (lambda (step) (alist-get 'uuid step))
              bitbucket-devops-ui--details-steps)
      '("{step-1}" "{step-2}")))
    (should
     (equal (alist-get 'name (car bitbucket-devops-ui--details-steps))
            "New name"))))

(ert-deftest bitbucket-devops-ui-details-ignores-stale-step-response ()
  (with-temp-buffer
    (bitbucket-devops-pipelines-details-mode)
    (setq-local bitbucket-devops-ui--details-generation 2)
    (setq-local bitbucket-devops-ui--details-loading t)
    (setq-local bitbucket-devops-ui--details-steps
                '(((uuid . "{current-step}"))))
    (bitbucket-devops-ui--details-receive-steps
     '((values . (((uuid . "{stale-step}")))))
     nil
     1)
    (should bitbucket-devops-ui--details-loading)
    (should
     (equal
      (mapcar (lambda (step) (alist-get 'uuid step))
              bitbucket-devops-ui--details-steps)
      '("{current-step}")))))

(ert-deftest bitbucket-devops-ui-details-render-selects-and-preserves-step ()
  (with-temp-buffer
    (bitbucket-devops-pipelines-details-mode)
    (setq-local bitbucket-devops-ui--details-pipeline
                '((uuid . "{pipeline-12}") (build_number . 12)))
    (setq-local bitbucket-devops-ui--details-steps
                '(((uuid . "{step-1}") (name . "Build"))
                  ((uuid . "{step-2}") (name . "Approve"))))
    (bitbucket-devops-ui--details-render-steps)
    (should (equal (tabulated-list-get-id) "{step-1}"))
    (should (bitbucket-devops-ui--goto-step-id "{step-2}"))
    (bitbucket-devops-ui--details-render-steps)
    (should (equal (tabulated-list-get-id) "{step-2}"))))

(ert-deftest bitbucket-devops-ui-details-render-shows-started-time ()
  (let ((bitbucket-devops-pipelines-display-time-zone t))
    (with-temp-buffer
      (bitbucket-devops-pipelines-details-mode)
      (setq-local bitbucket-devops-ui--details-pipeline
                  '((uuid . "{pipeline-12}")
                    (build_number . 12)
                    (created_on . "2026-05-31T17:16:00.000000+00:00")
                    (state . ((name . "COMPLETED")
                              (result . ((name . "SUCCESSFUL")))))
                    (target . ((ref_name . "main")))))
      (setq-local bitbucket-devops-ui--details-steps
                  '(((uuid . "{step-1}") (name . "Build"))))
      (bitbucket-devops-ui--details-render-steps)
      (should
       (string-match-p
        "Started: 2026-05-31 17:16:00 GMT"
        (buffer-string))))))

(ert-deftest bitbucket-devops-ui-merge-pipeline-pages-adds-paused-runs ()
  (let* ((page
          '((values . (((uuid . "{running}"))
                       ((uuid . "{paused}"))))
            (next . "https://api.bitbucket.org/2.0/repositories/x/y/pipelines?page=2")))
         (merged
          (bitbucket-devops-ui--merge-pipeline-pages
           page
           '(((uuid . "{paused}"))
             ((uuid . "{older-paused}"))))))
    (should
     (equal
      (mapcar
       (lambda (pipeline) (alist-get 'uuid pipeline))
       (bitbucket-devops-rest-page-values merged))
      '("{running}" "{paused}" "{older-paused}")))
    (should (equal (alist-get 'next merged) (alist-get 'next page)))))

(ert-deftest bitbucket-devops-ui-pipeline-sync-candidates-use-active-window ()
  (let ((bitbucket-devops-pipelines-sync-always-count 1)
        (bitbucket-devops-pipelines-sync-active-count 4))
    (should
     (equal
      (mapcar
       (lambda (pipeline) (alist-get 'uuid pipeline))
       (bitbucket-devops-ui--pipeline-sync-candidates
        '(((uuid . "{completed-newest}")
           (created_on . "2026-06-07T12:00:00Z")
           (state . ((name . "COMPLETED"))))
          ((uuid . "{running}")
           (created_on . "2026-06-07T11:00:00Z")
           (state . ((name . "IN_PROGRESS"))))
          ((uuid . "{completed-middle}")
           (created_on . "2026-06-07T10:00:00Z")
           (state . ((name . "COMPLETED"))))
          ((uuid . "{paused}")
           (created_on . "2026-06-07T09:00:00Z")
           (state . ((name . "IN_PROGRESS")
                     (stage . ((name . "PAUSED"))))))
          ((uuid . "{old-running}")
           (created_on . "2026-06-07T08:00:00Z")
           (state . ((name . "IN_PROGRESS")))))))
      '("{completed-newest}" "{running}" "{paused}")))))

(ert-deftest bitbucket-devops-ui-refresh-loaded-pipelines-preserves-local-fields ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        (bitbucket-devops-cache-enabled nil)
        (bitbucket-devops-pipelines-sync-always-count 1)
        (bitbucket-devops-pipelines-sync-active-count 1)
        requested)
    (with-temp-buffer
      (bitbucket-devops-pipelines-history-mode)
      (setq-local bitbucket-devops-ui--context context)
      (setq-local bitbucket-devops-ui--history-request-generation 4)
      (setq-local
       bitbucket-devops-ui--history-pipelines
       '(((uuid . "{pipeline}")
          (build_number . 7)
          (created_on . "2026-06-07T12:00:00Z")
          (state . ((name . "IN_PROGRESS")))
          (target . ((commit . ((hash . "abc")
                                (message . "cached message")
                                (author . ((raw . "Ada <ada@example.test>")))))))
          (bitbucket-devops-pipelines-deployments
           . (((environment . ((name . "dev")))))))))
      (cl-letf (((symbol-function 'bitbucket-devops-rest-get-pipeline)
                 (lambda (_context uuid callback)
                   (push uuid requested)
                   (funcall
                    callback
                    `((uuid . ,uuid)
                      (build_number . 7)
                      (created_on . "2026-06-07T12:01:00Z")
                      (state . ((name . "COMPLETED")
                                (result . ((name . "SUCCESSFUL")))))
                      (target . ((commit . ((hash . "abc"))))))
                    nil))))
        (bitbucket-devops-ui--refresh-loaded-pipelines context 4)
        (should (equal requested '("{pipeline}")))
        (let ((pipeline (car bitbucket-devops-ui--history-pipelines)))
          (should
           (equal (bitbucket-devops-ui--pipeline-state-label pipeline)
                  "SUCCESSFUL"))
          (should
           (equal
            (alist-get 'message (bitbucket-devops-ui--pipeline-commit pipeline))
            "cached message"))
          (should
           (equal
            (bitbucket-devops-ui--deployment-names
             (alist-get 'bitbucket-devops-pipelines-deployments pipeline))
            '("dev"))))))))

(ert-deftest bitbucket-devops-ui-history-request-merges-explicit-paused-list ()
  (with-temp-buffer
    (bitbucket-devops-pipelines-history-mode)
    (setq-local bitbucket-devops-ui--context
                '(:workspace "williseed1" :repo-slug "test"))
    (let (observed)
      (cl-letf (((symbol-function 'bitbucket-devops-rest-list-pipelines)
                 (lambda (_context callback &optional _next-url)
                   (funcall callback
                            '((values . (((uuid . "{running}")))))
                            nil)))
                ((symbol-function
                  'bitbucket-devops-ui--list-all-paused-pipelines)
                 (lambda (_context callback &rest _args)
                   (funcall callback '(((uuid . "{paused}"))) nil)))
                ((symbol-function 'bitbucket-devops-ui--history-process-page)
                 (lambda (_buffer _context page request-error append)
                   (setq observed (list page request-error append)))))
        (bitbucket-devops-ui--history-request nil nil)
        (should-not (cadr observed))
        (should-not (caddr observed))
        (should
         (equal
          (mapcar
           (lambda (pipeline) (alist-get 'uuid pipeline))
           (bitbucket-devops-rest-page-values (car observed)))
          '("{running}" "{paused}")))))))

(ert-deftest bitbucket-devops-ui-step-terminal-p-detects-completed-step ()
  (let* ((page
          (bitbucket-devops-ui-test-read-json-fixture
           "steps-page-1.json"))
         (step (car (alist-get 'values page))))
    (should (bitbucket-devops-ui--step-terminal-p step))
    (should-not
     (bitbucket-devops-ui--step-terminal-p
      '((state . ((name . "IN_PROGRESS"))))))))

(ert-deftest bitbucket-devops-ui-render-step-log-applies-ansi-color ()
  (let* ((context '(:workspace "williseed1" :repo-slug "test"))
         (pipeline '((uuid . "{pipeline-12}") (build_number . 12)))
         (step '((uuid . "{step-1}") (name . "Build")))
         (log
          (with-temp-buffer
            (insert-file-contents
             (expand-file-name
              "step-log.txt"
              bitbucket-devops-ui-test-fixtures-directory))
            (buffer-string)))
         (buffer
          (bitbucket-devops-ui--render-step-log context pipeline step log)))
    (unwind-protect
        (with-current-buffer buffer
          (should (derived-mode-p 'bitbucket-devops-pipelines-log-mode))
          (should buffer-read-only)
          (should (string-match-p "PASS default pipeline" (buffer-string)))
          (should-not
           (string-match-p
            "Bitbucket-reported step failure"
            (buffer-string)))
          (should-not (string-match-p "\e\\[" (buffer-string))))
      (kill-buffer buffer))))

(ert-deftest bitbucket-devops-ui-render-step-log-prepends-step-error ()
  (let* ((context '(:workspace "williseed1" :repo-slug "test"))
         (pipeline '((uuid . "{pipeline-12}") (build_number . 12)))
         (step
          '((uuid . "{step-1}")
            (name . "Build")
            (state
             . ((name . "COMPLETED")
                (result
                 . ((name . "FAILED")
                    (error
                     . ((key . "runner.image-pull-failure")
                        (message
                         . "Unable to pull registry.example.com/team/image:98")))))))))
         (buffer
          (bitbucket-devops-ui--render-step-log
           context pipeline step "script output\n")))
    (unwind-protect
        (with-current-buffer buffer
          (should buffer-read-only)
          (should
           (equal
            (substring-no-properties (buffer-string))
            (concat
             "Bitbucket-reported step failure\n"
             "Error key: runner.image-pull-failure\n"
             "Unable to pull registry.example.com/team/image:98\n\n"
             "Raw step log\n\n"
             "script output\n")))
          (should
           (eq
            (get-text-property (point-min) 'face)
            'bitbucket-devops-pipelines-error-face)))
      (kill-buffer buffer))))

(ert-deftest bitbucket-devops-ui-history-filter-pipelines-by-selected-branch ()
  (let* ((first-page
          (bitbucket-devops-ui-test-read-json-fixture
           "pipelines-page-1.json"))
         (second-page
          (bitbucket-devops-ui-test-read-json-fixture
           "pipelines-page-2.json"))
         (pipelines
          (append (alist-get 'values first-page)
                  (alist-get 'values second-page))))
    (with-temp-buffer
      (bitbucket-devops-pipelines-history-mode)
      (setq-local bitbucket-devops-ui--history-branch-filter
                  "feature/example")
      (should
       (equal
        (mapcar
         (lambda (pipeline) (alist-get 'build_number pipeline))
         (bitbucket-devops-ui--history-filter-pipelines pipelines))
        '(11))))))

(ert-deftest bitbucket-devops-ui-history-branch-names-include-loaded-and-current ()
  (let* ((first-page
          (bitbucket-devops-ui-test-read-json-fixture
           "pipelines-page-1.json"))
         (second-page
          (bitbucket-devops-ui-test-read-json-fixture
           "pipelines-page-2.json"))
         observed-directory
         observed-remote)
    (with-temp-buffer
      (bitbucket-devops-pipelines-history-mode)
      (setq-local bitbucket-devops-ui--context
                  '(:root "/tmp/repository/"
                    :remote "origin"
                    :branch "development"))
      (setq-local bitbucket-devops-ui--history-pipelines
                  (append (alist-get 'values first-page)
                          (alist-get 'values second-page)))
      (cl-letf (((symbol-function 'magit-list-local-branch-names)
                 (lambda ()
                   (setq observed-directory default-directory)
                   '("main" "local-only")))
                ((symbol-function 'magit-list-remote-branch-names)
                 (lambda (remote relative)
                   (setq observed-remote (list remote relative))
                   '("HEAD" "main" "remote-only"))))
        (should
         (equal
          (bitbucket-devops-ui--history-branch-names)
          '("development"
            "feature/example"
            "local-only"
            "main"
            "remote-only")))
        (should (equal observed-directory "/tmp/repository/"))
        (should (equal observed-remote '("origin" t)))))))

(ert-deftest bitbucket-devops-ui-history-branch-names-fall-back-after-magit-error ()
  (with-temp-buffer
    (bitbucket-devops-pipelines-history-mode)
    (setq-local bitbucket-devops-ui--context '(:branch "development"))
    (setq-local bitbucket-devops-ui--history-pipelines
                '(((target . ((ref_name . "main"))))))
    (cl-letf (((symbol-function 'magit-list-local-branch-names)
               (lambda () (error "Unable to list branches"))))
      (should
       (equal
        (bitbucket-devops-ui--history-branch-names)
        '("development" "main"))))))

(ert-deftest bitbucket-devops-ui-history-set-branch-filter-renders-selection ()
  (with-temp-buffer
    (bitbucket-devops-pipelines-history-mode)
    (let (rendered)
      (cl-letf (((symbol-function 'bitbucket-devops-ui--history-render)
                 (lambda () (setq rendered t))))
        (bitbucket-devops-pipelines-history-set-branch-filter "feature/example")
        (should rendered)
        (should
         (equal bitbucket-devops-ui--history-branch-filter
                "feature/example"))))))

(ert-deftest bitbucket-devops-ui-history-tab-expands-current-column ()
  (with-temp-buffer
    (bitbucket-devops-pipelines-history-mode)
    (setq tabulated-list-entries
          '(("{pipeline-1}"
             ["1" "SUCCESSFUL"
              "custom: a-very-long-pipeline-selector-name"
              "" "main" "abc" "" "" "" "message"])))
    (let ((inhibit-read-only t))
      (insert (make-string 24 ?\s)))
    (let ((initial-width (cadr (aref tabulated-list-format 2))))
      (bitbucket-devops-pipelines-history-expand-column-at-point)
      (should truncate-lines)
      (should-not word-wrap)
      (should
       (>
        (cadr (aref tabulated-list-format 2))
        initial-width)))))

(ert-deftest bitbucket-devops-ui-history-mode-uses-custom-column-widths ()
  (let ((bitbucket-devops-pipelines-history-column-widths
         '((build . 11)
           (state . 15)
           (type . 40)
           (deployments . 33)
           (target . 21)
           (commit . 16)
           (author . 35)
           (created . 28)
           (duration . 12)
           (message . 0))))
    (with-temp-buffer
      (bitbucket-devops-pipelines-history-mode)
      (should (= (cadr (aref tabulated-list-format 0)) 11))
      (should (= (cadr (aref tabulated-list-format 2)) 40))
      (should (= (cadr (aref tabulated-list-format 6)) 35)))))

(ert-deftest bitbucket-devops-ui-details-mode-uses-custom-column-widths ()
  (let ((bitbucket-devops-pipelines-details-column-widths
         '((number . 7)
           (step . 48)
           (state . 18)
           (deployment . 24)
           (duration . 12))))
    (with-temp-buffer
      (bitbucket-devops-pipelines-details-mode)
      (should (= (cadr (aref tabulated-list-format 0)) 7))
      (should (= (cadr (aref tabulated-list-format 1)) 48))
      (should (= (cadr (aref tabulated-list-format 3)) 24)))))

(ert-deftest bitbucket-devops-ui-history-filter-pipelines-by-status ()
  (let* ((first-page
          (bitbucket-devops-ui-test-read-json-fixture
           "pipelines-page-1.json"))
         (second-page
          (bitbucket-devops-ui-test-read-json-fixture
           "pipelines-page-2.json"))
         (pipelines
          (append (alist-get 'values first-page)
                  (alist-get 'values second-page))))
    (with-temp-buffer
      (bitbucket-devops-pipelines-history-mode)
      (setq-local bitbucket-devops-ui--history-status-filter 'failed)
      (should
       (equal
        (mapcar
         (lambda (pipeline) (alist-get 'build_number pipeline))
         (bitbucket-devops-ui--history-filter-pipelines pipelines))
        '(11))))))

(ert-deftest bitbucket-devops-ui-log-download-file-name-is-predictable ()
  (should
   (equal
    (bitbucket-devops-ui--log-download-file-name
     '(:workspace "williseed1" :repo-slug "test repo")
     '((build_number . 12))
     '((name . "Build & Test"))
     2)
    "williseed1-test-repo-pipeline-12-02-Build-Test.log")))

(ert-deftest bitbucket-devops-ui-download-logs-saves-terminal-steps ()
  (let ((directory (make-temp-file "bitbucket-devops-pipelines-logs-" t))
        observed
        callback-args)
    (unwind-protect
        (cl-letf (((symbol-function 'bitbucket-devops-rest-get-step-log)
                   (lambda (context pipeline-uuid step-uuid callback)
                     (push (list context pipeline-uuid step-uuid) observed)
                     (funcall callback "completed log\n" nil)
                     'request-process)))
          (bitbucket-devops-ui--download-logs
           '(:workspace "williseed1" :repo-slug "test")
           '((uuid . "{pipeline-12}") (build_number . 12))
           '(((uuid . "{step-1}")
              (name . "Build")
              (state . ((name . "COMPLETED"))))
             ((uuid . "{step-2}")
              (name . "Deploy")
              (state . ((name . "IN_PROGRESS"))))
             ((uuid . "{step-3}")
              (name . "Cancelled")
              (state . ((name . "COMPLETED")
                        (result . ((name . "STOPPED")))))))
           (lambda (&rest args) (setq callback-args args))
           directory)
          (should (= (length observed) 1))
          (should (= (length (car callback-args)) 1))
          (should (equal (cadr callback-args) '("Deploy" "Cancelled")))
          (should
           (equal
            (with-temp-buffer
              (insert-file-contents (car (car callback-args)))
              (buffer-string))
            "completed log\n")))
      (delete-directory directory t))))

(ert-deftest bitbucket-devops-ui-download-message-callback-copies-saved-paths ()
  (let (copied
        message-text)
    (cl-letf (((symbol-function 'kill-new)
               (lambda (text &rest _args)
                 (setq copied text)))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq message-text
                       (apply #'format format-string args)))))
      (funcall (bitbucket-devops-ui--download-message-callback
                "/tmp/bitbucket-devops-logs" t)
               '("/tmp/bitbucket-devops-logs/a.log"
                 "/tmp/bitbucket-devops-logs/b.log")
               nil))
    (should
     (equal
      copied
      "/tmp/bitbucket-devops-logs/a.log\n/tmp/bitbucket-devops-logs/b.log"))
    (should (string-match-p "copied path(s)" message-text))))

(ert-deftest bitbucket-devops-pipelines-browser-urls-use-bitbucket-pages ()
  (let ((context '(:workspace "williseed1" :repo-slug "test")))
    (should
     (equal
      (bitbucket-devops-ui--repository-pipelines-url context)
      "https://bitbucket.org/williseed1/test/pipelines/"))
    (should
     (equal
      (bitbucket-devops-ui--pipeline-browser-url
       context
       '((uuid . "{pipeline-12}") (build_number . 12)))
      "https://bitbucket.org/williseed1/test/pipelines/results/12"))
    (should
     (equal
      (bitbucket-devops-ui--pipeline-browser-url
       context
       '((uuid . "{pipeline-12}")
         (build_number . 12)
         (links . ((html . ((href . "https://bitbucket.test/pipeline/12")))))))
      "https://bitbucket.test/pipeline/12"))))

(ert-deftest bitbucket-devops-pipelines-history-browse-opens-selected-pipeline ()
  (let (opened)
    (with-temp-buffer
      (bitbucket-devops-pipelines-history-mode)
      (setq-local bitbucket-devops-ui--context
                  '(:workspace "williseed1" :repo-slug "test"))
      (setq-local bitbucket-devops-ui--history-pipelines
                  '(((uuid . "{pipeline-12}") (build_number . 12))))
      (let ((inhibit-read-only t))
        (insert (propertize "pipeline row" 'tabulated-list-id "{pipeline-12}")))
      (goto-char (point-min))
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _args)
                   (setq opened url))))
        (bitbucket-devops-pipelines-browse)))
    (should
     (equal opened "https://bitbucket.org/williseed1/test/pipelines/results/12"))))

(ert-deftest bitbucket-devops-pipelines-history-browse-opens-list-without-row ()
  (let (opened)
    (with-temp-buffer
      (bitbucket-devops-pipelines-history-mode)
      (setq-local bitbucket-devops-ui--context
                  '(:workspace "williseed1" :repo-slug "test"))
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _args)
                   (setq opened url))))
        (bitbucket-devops-pipelines-browse)))
    (should
     (equal opened "https://bitbucket.org/williseed1/test/pipelines/"))))

(ert-deftest bitbucket-devops-pipelines-details-browse-opens-displayed-pipeline ()
  (let (opened)
    (with-temp-buffer
      (bitbucket-devops-pipelines-details-mode)
      (setq-local bitbucket-devops-ui--context
                  '(:workspace "williseed1" :repo-slug "test"))
      (setq-local bitbucket-devops-ui--details-pipeline
                  '((uuid . "{pipeline-12}") (build_number . 12)))
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _args)
                   (setq opened url))))
        (bitbucket-devops-pipelines-browse)))
    (should
     (equal opened "https://bitbucket.org/williseed1/test/pipelines/results/12"))))

(ert-deftest bitbucket-devops-pipelines-browse-repository-opens-list ()
  (let (opened)
    (with-temp-buffer
      (bitbucket-devops-pipelines-details-mode)
      (setq-local bitbucket-devops-ui--context
                  '(:workspace "williseed1" :repo-slug "test"))
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _args)
                   (setq opened url))))
        (bitbucket-devops-pipelines-browse-repository)))
    (should
     (equal opened "https://bitbucket.org/williseed1/test/pipelines/"))))

(ert-deftest bitbucket-devops-pipelines-copy-browser-url-copies-current-url ()
  (let (copied)
    (with-temp-buffer
      (bitbucket-devops-pipelines-details-mode)
      (setq-local bitbucket-devops-ui--context
                  '(:workspace "williseed1" :repo-slug "test"))
      (setq-local bitbucket-devops-ui--details-pipeline
                  '((uuid . "{pipeline-12}") (build_number . 12)))
      (cl-letf (((symbol-function 'kill-new)
                 (lambda (text &rest _args)
                   (setq copied text)))
                ((symbol-function 'message)
                 (lambda (&rest _args))))
        (bitbucket-devops-pipelines-copy-browser-url-at-point)))
    (should
     (equal copied "https://bitbucket.org/williseed1/test/pipelines/results/12"))))

(ert-deftest bitbucket-devops-pipelines-download-selected-log-saves-selected-step ()
  (let* ((directory (make-temp-file "bitbucket-devops-pipelines-selected-log-" t))
         (expected-file
          (expand-file-name
           "williseed1-test-pipeline-12-01-Build.log"
           directory))
         observed
         copied)
    (unwind-protect
        (with-temp-buffer
          (bitbucket-devops-pipelines-details-mode)
          (setq-local bitbucket-devops-ui--context
                      '(:workspace "williseed1" :repo-slug "test"))
          (setq-local bitbucket-devops-ui--details-pipeline
                      '((uuid . "{pipeline-12}") (build_number . 12)))
          (setq-local bitbucket-devops-ui--details-steps
                      '(((uuid . "{step-1}")
                         (name . "Build")
                         (state . ((name . "COMPLETED"))))))
          (let ((inhibit-read-only t))
            (insert (propertize "step row" 'tabulated-list-id "{step-1}")))
          (goto-char (point-min))
          (let ((bitbucket-devops-pipelines-log-download-directory directory))
            (cl-letf (((symbol-function 'bitbucket-devops-rest-get-step-log)
                       (lambda (context pipeline-uuid step-uuid callback)
                         (setq observed (list context pipeline-uuid step-uuid))
                         (funcall callback "selected log\n" nil)))
                      ((symbol-function 'kill-new)
                       (lambda (text &rest _args)
                         (setq copied text))))
              (bitbucket-devops-pipelines-download-selected-log)))
          (should
           (equal
            observed
            '((:workspace "williseed1" :repo-slug "test")
              "{pipeline-12}"
              "{step-1}")))
          (should
           (equal
            (with-temp-buffer
              (insert-file-contents expected-file)
              (buffer-string))
            "selected log\n"))
          (should (equal copied expected-file)))
      (delete-directory directory t))))

(ert-deftest bitbucket-devops-pipelines-view-step-log-rejects-stopped-step ()
  (let (requested)
    (with-temp-buffer
      (bitbucket-devops-pipelines-details-mode)
      (setq-local bitbucket-devops-ui--context
                  '(:workspace "williseed1" :repo-slug "test"))
      (setq-local bitbucket-devops-ui--details-pipeline
                  '((uuid . "{pipeline-38}")
                    (state . ((name . "COMPLETED")
                              (result . ((name . "STOPPED")))))))
      (setq-local bitbucket-devops-ui--details-steps
                  '(((uuid . "{step-1}")
                     (name . "Cancel")
                     (state . ((name . "COMPLETED")
                               (result . ((name . "STOPPED"))))))))
      (let ((inhibit-read-only t))
        (insert (propertize "step row" 'tabulated-list-id "{step-1}")))
      (goto-char (point-min))
      (cl-letf (((symbol-function 'bitbucket-devops-rest-get-step-log)
                 (lambda (&rest _args) (setq requested t))))
        (let ((request-error
               (should-error
                (bitbucket-devops-pipelines-view-step-log)
                :type 'user-error)))
          (should
           (string-match-p "stopped" (error-message-string request-error)))))
      (should-not requested))))

(ert-deftest bitbucket-devops-pipelines-view-step-log-explains-pending-step ()
  (let (requested)
    (with-temp-buffer
      (bitbucket-devops-pipelines-details-mode)
      (setq-local bitbucket-devops-ui--context
                  '(:workspace "williseed1" :repo-slug "test"))
      (setq-local bitbucket-devops-ui--details-pipeline
                  '((uuid . "{pipeline-498}")
                    (state . ((name . "IN_PROGRESS")
                              (stage . ((name . "PAUSED")))))))
      (setq-local bitbucket-devops-ui--details-steps
                  '(((uuid . "{step-2}")
                     (name . "Approve")
                     (state . ((name . "PENDING")
                               (stage . ((name . "PAUSED"))))))))
      (bitbucket-devops-ui--details-render-steps)
      (cl-letf (((symbol-function 'bitbucket-devops-rest-get-step-log)
                 (lambda (&rest _args) (setq requested t))))
        (let ((request-error
               (should-error
                (bitbucket-devops-pipelines-view-step-log)
                :type 'user-error)))
          (should
           (string-match-p
            "after the step completes"
            (error-message-string request-error)))))
      (should-not requested))))

(ert-deftest bitbucket-devops-ui-list-all-steps-follows-pagination ()
  (let (callback-args observed)
    (cl-letf (((symbol-function 'bitbucket-devops-rest-list-steps)
               (lambda (_context _pipeline-uuid callback &optional next-url)
                 (push next-url observed)
                 (funcall
                  callback
                  (if next-url
                      '((values . (((uuid . "{step-2}")))))
                    '((values . (((uuid . "{step-1}"))))
                      (next . "https://api.bitbucket.org/2.0/repositories/williseed1/test/pipelines/%7Bpipeline-12%7D/steps?page=2")))
                  nil))))
      (bitbucket-devops-ui--list-all-steps
       '(:workspace "williseed1" :repo-slug "test")
       "{pipeline-12}"
       (lambda (&rest args) (setq callback-args args)))
      (should
       (equal
        (mapcar (lambda (step) (alist-get 'uuid step)) (car callback-args))
        '("{step-1}" "{step-2}")))
      (should-not (cadr callback-args))
      (should (= (length observed) 2)))))

(ert-deftest bitbucket-devops-pipelines-history-download-logs-fetches-selected-pipeline ()
  (let (observed)
    (with-temp-buffer
      (bitbucket-devops-pipelines-history-mode)
      (setq-local bitbucket-devops-ui--context
                  '(:workspace "williseed1" :repo-slug "test"))
      (let ((inhibit-read-only t))
        (insert (propertize "pipeline row" 'tabulated-list-id "{pipeline-12}")))
      (goto-char (point-min))
      (cl-letf (((symbol-function 'bitbucket-devops-rest-get-pipeline)
                 (lambda (context pipeline-uuid callback)
                   (push (list 'pipeline context pipeline-uuid) observed)
                   (funcall
                    callback
                    '((uuid . "{pipeline-12}") (build_number . 12))
                    nil)))
                ((symbol-function 'bitbucket-devops-ui--list-all-steps)
                 (lambda (context pipeline-uuid callback &rest _args)
                   (push (list 'steps context pipeline-uuid) observed)
                   (funcall callback '(((uuid . "{step-1}"))) nil)))
                ((symbol-function 'bitbucket-devops-ui--download-logs)
                 (lambda (context pipeline steps _callback &optional _directory)
                   (push (list 'download context pipeline steps) observed))))
        (bitbucket-devops-pipelines-history-download-logs)
        (should
         (equal
          (nreverse observed)
          '((pipeline (:workspace "williseed1" :repo-slug "test")
                      "{pipeline-12}")
            (steps (:workspace "williseed1" :repo-slug "test")
                   "{pipeline-12}")
            (download (:workspace "williseed1" :repo-slug "test")
                      ((uuid . "{pipeline-12}") (build_number . 12))
                      (((uuid . "{step-1}")))))))))))

(ert-deftest bitbucket-devops-ui-install-evil-bindings-includes-navigation ()
  (let (observed)
    (cl-letf (((symbol-function 'evil-define-key*)
               (lambda (&rest args) (push args observed))))
      (bitbucket-devops-ui--install-evil-bindings)
      (should (= (length observed) 3))
      (should
       (member
        (list
         'normal
         bitbucket-devops-pipelines-history-mode-map
         (kbd "r") #'bitbucket-devops-pipelines-history-refresh
         (kbd "n") #'bitbucket-devops-pipelines-history-load-more
         (kbd "f") #'bitbucket-devops-pipelines-history-set-branch-filter
         (kbd "s") #'bitbucket-devops-pipelines-history-set-status-filter
         (kbd "RET") #'bitbucket-devops-pipelines-history-view-details
         (kbd "S-RET") #'bitbucket-devops-pipelines-copy-browser-url-at-point
         (kbd "S-<return>") #'bitbucket-devops-pipelines-copy-browser-url-at-point
         (kbd "o") #'bitbucket-devops-pipelines-browse
         (kbd "O") #'bitbucket-devops-pipelines-browse-repository
         (kbd "t") #'bitbucket-devops-pipelines-watch-selected
         (kbd "d") #'bitbucket-devops-pipelines-history-download-logs
         (kbd "R") #'bitbucket-devops-pipelines-history-run-configured
         (kbd "TAB") #'bitbucket-devops-pipelines-history-expand-column-at-point
         (kbd "-") #'bitbucket-devops-ui-back
         (kbd "q") #'bitbucket-devops-ui-quit
         (kbd "?") #'bitbucket-devops-ui-show-command-panel)
        observed))
      (should
       (member
        (list
         'normal
         bitbucket-devops-pipelines-details-mode-map
         (kbd "r") #'bitbucket-devops-pipelines-details-refresh
         (kbd "RET") #'bitbucket-devops-pipelines-view-step-log
         (kbd "S-RET") #'bitbucket-devops-pipelines-copy-browser-url-at-point
         (kbd "S-<return>") #'bitbucket-devops-pipelines-copy-browser-url-at-point
         (kbd "o") #'bitbucket-devops-pipelines-browse
         (kbd "O") #'bitbucket-devops-pipelines-browse-repository
         (kbd "d") #'bitbucket-devops-pipelines-download-selected-log
         (kbd "D") #'bitbucket-devops-pipelines-download-logs
         (kbd "t") #'bitbucket-devops-pipelines-watch-selected
         (kbd "R") #'bitbucket-devops-pipelines-rerun
         (kbd "c") #'bitbucket-devops-pipelines-continue
         (kbd "s") #'bitbucket-devops-pipelines-stop
         (kbd "-") #'bitbucket-devops-ui-back
         (kbd "q") #'bitbucket-devops-ui-quit
         (kbd "?") #'bitbucket-devops-ui-show-command-panel)
        observed))
      (should
       (member
        (list
         'normal
         bitbucket-devops-pipelines-log-mode-map
         (kbd "-") #'bitbucket-devops-ui-back
         (kbd "q") #'bitbucket-devops-ui-quit
         (kbd "?") #'bitbucket-devops-ui-show-command-panel)
        observed)))))

(ert-deftest bitbucket-devops-ui-quit-bindings-remove-panel ()
  (dolist (map
           (list
            bitbucket-devops-pipelines-history-mode-map
            bitbucket-devops-pipelines-details-mode-map
            bitbucket-devops-pipelines-log-mode-map))
    (should
     (eq
      (lookup-key map (kbd "q"))
      #'bitbucket-devops-ui-quit))))

(ert-deftest bitbucket-devops-ui-help-bindings-show-panel ()
  (dolist (map
           (list
            bitbucket-devops-pipelines-history-mode-map
            bitbucket-devops-pipelines-details-mode-map
            bitbucket-devops-pipelines-log-mode-map))
    (should
     (eq
      (lookup-key map (kbd "?"))
      #'bitbucket-devops-ui-show-command-panel))))

(ert-deftest bitbucket-devops-ui-history-bindings-avoid-evil-g-prefix ()
  (should
   (eq
    (lookup-key bitbucket-devops-pipelines-history-mode-map (kbd "r"))
    #'bitbucket-devops-pipelines-history-refresh))
  (should
   (eq
    (lookup-key bitbucket-devops-pipelines-history-mode-map (kbd "d"))
    #'bitbucket-devops-pipelines-history-download-logs))
  (should
   (eq
    (lookup-key bitbucket-devops-pipelines-history-mode-map (kbd "R"))
    #'bitbucket-devops-pipelines-history-run-configured))
  (should-not
   (eq
    (lookup-key bitbucket-devops-pipelines-history-mode-map (kbd "g"))
    #'bitbucket-devops-pipelines-history-refresh)))

(ert-deftest bitbucket-devops-ui-history-bindings-avoid-evil-motion-keys ()
  (should
   (eq
    (lookup-key bitbucket-devops-pipelines-history-mode-map (kbd "f"))
    #'bitbucket-devops-pipelines-history-set-branch-filter))
  (should
   (eq
    (lookup-key bitbucket-devops-pipelines-history-mode-map (kbd "t"))
    #'bitbucket-devops-pipelines-watch-selected))
  (should
   (eq
    (lookup-key bitbucket-devops-pipelines-history-mode-map (kbd "TAB"))
    #'bitbucket-devops-pipelines-history-expand-column-at-point))
  (should-not
   (eq
    (lookup-key bitbucket-devops-pipelines-history-mode-map (kbd "b"))
    #'bitbucket-devops-pipelines-history-set-branch-filter))
  (should-not
   (eq
    (lookup-key bitbucket-devops-pipelines-history-mode-map (kbd "w"))
    #'bitbucket-devops-pipelines-watch-selected)))

(ert-deftest bitbucket-devops-ui-history-browser-bindings-open-and-copy ()
  (should
   (eq
    (lookup-key bitbucket-devops-pipelines-history-mode-map (kbd "o"))
    #'bitbucket-devops-pipelines-browse))
  (should
   (eq
    (lookup-key bitbucket-devops-pipelines-history-mode-map (kbd "O"))
    #'bitbucket-devops-pipelines-browse-repository))
  (should
   (eq
    (lookup-key bitbucket-devops-pipelines-history-mode-map (kbd "S-RET"))
    #'bitbucket-devops-pipelines-copy-browser-url-at-point))
  (should
   (eq
    (lookup-key bitbucket-devops-pipelines-history-mode-map (kbd "S-<return>"))
    #'bitbucket-devops-pipelines-copy-browser-url-at-point)))

(ert-deftest bitbucket-devops-pipelines-history-run-configured-uses-context-root ()
  (let (observed)
    (with-temp-buffer
      (bitbucket-devops-pipelines-history-mode)
      (setq-local bitbucket-devops-ui--context
                  '(:workspace "williseed1"
                    :repo-slug "test"
                    :root "/tmp/repository/"))
      (cl-letf (((symbol-function 'bitbucket-devops-pipelines-run-configured)
                 (lambda (&optional directory additional)
                   (setq observed (list directory additional)))))
        (bitbucket-devops-pipelines-history-run-configured)
        (should (equal observed '("/tmp/repository/" nil)))
        (bitbucket-devops-pipelines-history-run-configured t)
        (should (equal observed '("/tmp/repository/" t)))))))

(ert-deftest bitbucket-devops-ui-details-download-bindings-match-scope ()
  (should
   (eq
    (lookup-key bitbucket-devops-pipelines-details-mode-map (kbd "RET"))
    #'bitbucket-devops-pipelines-view-step-log))
  (should-not
   (eq
    (lookup-key bitbucket-devops-pipelines-details-mode-map (kbd "l"))
    #'bitbucket-devops-pipelines-view-step-log))
  (should
   (eq
    (lookup-key bitbucket-devops-pipelines-details-mode-map (kbd "d"))
    #'bitbucket-devops-pipelines-download-selected-log))
  (should
   (eq
    (lookup-key bitbucket-devops-pipelines-details-mode-map (kbd "D"))
    #'bitbucket-devops-pipelines-download-logs)))

(ert-deftest bitbucket-devops-ui-details-mutation-bindings-match-scope ()
  (should
   (eq
    (lookup-key bitbucket-devops-pipelines-details-mode-map (kbd "r"))
    #'bitbucket-devops-pipelines-details-refresh))
  (should
   (eq
    (lookup-key bitbucket-devops-pipelines-details-mode-map (kbd "R"))
    #'bitbucket-devops-pipelines-rerun))
  (should
   (eq
    (lookup-key bitbucket-devops-pipelines-details-mode-map (kbd "c"))
    #'bitbucket-devops-pipelines-continue))
  (should
   (eq
    (lookup-key bitbucket-devops-pipelines-details-mode-map (kbd "t"))
    #'bitbucket-devops-pipelines-watch-selected))
  (should-not
   (eq
    (lookup-key bitbucket-devops-pipelines-details-mode-map (kbd "w"))
    #'bitbucket-devops-pipelines-watch-selected))
  (should
   (eq
    (lookup-key bitbucket-devops-pipelines-details-mode-map (kbd "s"))
    #'bitbucket-devops-pipelines-stop)))

(ert-deftest bitbucket-devops-ui-details-browser-bindings-open-and-copy ()
  (should
   (eq
    (lookup-key bitbucket-devops-pipelines-details-mode-map (kbd "o"))
    #'bitbucket-devops-pipelines-browse))
  (should
   (eq
    (lookup-key bitbucket-devops-pipelines-details-mode-map (kbd "O"))
    #'bitbucket-devops-pipelines-browse-repository))
  (should
   (eq
    (lookup-key bitbucket-devops-pipelines-details-mode-map (kbd "S-RET"))
    #'bitbucket-devops-pipelines-copy-browser-url-at-point))
  (should
   (eq
    (lookup-key bitbucket-devops-pipelines-details-mode-map (kbd "S-<return>"))
    #'bitbucket-devops-pipelines-copy-browser-url-at-point)))

(ert-deftest bitbucket-devops-ui-command-panel-lines-match-buffer-type ()
  (with-temp-buffer
    (bitbucket-devops-pipelines-history-mode)
    (let ((panel (bitbucket-devops-ui--command-panel-lines
                  (current-buffer))))
      (should (string-match-p "RET Details" panel))
      (should (string-match-p "o Browser" panel))
      (should (string-match-p "O Browser list" panel))
      (should (string-match-p "S-RET Copy link" panel))
      (should (string-match-p "f Choose branch" panel))
      (should (string-match-p "t Track" panel))
      (should (string-match-p "R Run pipeline" panel))
      (should (string-match-p "TAB Expand column" panel))
      (if (fboundp 'bitbucket-devops)
          (should (string-match-p "- Back" panel))
        (should-not (string-match-p "- Back" panel)))
      (should (string-match-p "q Quit" panel))
      (should (string-match-p "\\? Help" panel)))
    (should-not mode-line-process))
  (with-temp-buffer
    (bitbucket-devops-pipelines-details-mode)
    (let ((panel (bitbucket-devops-ui--command-panel-lines
                  (current-buffer))))
      (should (string-match-p "RET View log" panel))
      (should (string-match-p "o Browser" panel))
      (should (string-match-p "O Browser list" panel))
      (should (string-match-p "S-RET Copy link" panel))
      (if (fboundp 'bitbucket-devops)
          (should (string-match-p "- Back" panel))
        (should-not (string-match-p "- Back" panel)))
      (should (string-match-p "d Download selected" panel))
      (should (string-match-p "D Download all" panel))
      (should (string-match-p "t Track" panel))
      (should (string-match-p "r Refresh" panel))
      (should (string-match-p "R Rerun" panel))
      (should (string-match-p "c Continue" panel))
      (should (string-match-p "s Stop" panel))
      (should (string-match-p "q Quit" panel))
      (should (string-match-p "\\? Help" panel)))
    (should-not mode-line-process))
  (with-temp-buffer
    (bitbucket-devops-pipelines-log-mode)
    (let ((panel (bitbucket-devops-ui--command-panel-lines
                  (current-buffer))))
      (should (string-match-p "Navigate" panel))
      (if (fboundp 'bitbucket-devops)
          (should (string-match-p "- Back" panel))
        (should-not (string-match-p "- Back" panel)))
      (should (string-match-p "q Quit" panel))
      (should (string-match-p "\\? Help" panel)))
    (should-not mode-line-process))
  (with-temp-buffer
    (bitbucket-devops-pipelines-watch-list-mode)
    (let ((panel (bitbucket-devops-ui--command-panel-lines
                  (current-buffer))))
      (should (string-match-p "Watchers" panel))
      (should (string-match-p "m Toggle Magit push pipeline watching" panel))
      (should (string-match-p "x Stop selected watcher" panel))
      (should (string-match-p "q Quit" panel))
      (should (string-match-p "\\? Help" panel)))
    (should-not mode-line-process))
  (with-temp-buffer
    (bitbucket-devops-pull-requests-list-mode)
    (let ((panel (bitbucket-devops-ui--command-panel-lines
                  (current-buffer))))
      (should (string-match-p "RET Details" panel))
      (should (string-match-p "c Create" panel))
      (should (string-match-p "r Refresh" panel))
      (should (string-match-p "P/C-c P Run pipeline" panel))
      (should (string-match-p "C-c b Checkout branch" panel))
      (should (string-match-p "C-c w/C-c C-w Watch comments" panel))
      (should (string-match-p "s State" panel))
      (should (string-match-p "f Branch" panel))
      (should (string-match-p "a Author" panel))
      (should (string-match-p "\\? Help" panel))))
  (with-temp-buffer
    (bitbucket-devops-pull-requests-detail-mode)
    (let ((panel (bitbucket-devops-ui--command-panel-lines
                  (current-buffer))))
      (should (string-match-p "a/u Approve / remove" panel))
      (should (string-match-p "m Commits" panel))
      (should (string-match-p "A Activity" panel))
      (should (string-match-p "c/C Comment / reply" panel))
      (should
       (string-match-p
        (regexp-quote "C-c +/C-c =/C-c - Reviewer add/default/remove")
        panel))
      (should (string-match-p "M/D Merge / decline" panel))
      (should (string-match-p "C-c e/C-c k Edit / delete comment" panel))
      (should (string-match-p "r Refresh" panel))
      (should (string-match-p "P/C-c P Run pipeline" panel))
      (should (string-match-p "C-c b Checkout branch" panel))
      (should (string-match-p "C-c w/C-c C-w Watch comments" panel))
      (should (string-match-p "R Toggle ready/draft" panel))
      (should
       (string-match-p
        (regexp-quote "C-c r/C-c o Resolve / reopen")
        panel))
      (should
       (string-match-p "C-c p e Edit title / Markdown" panel))
      (should (string-match-p "C-c i Inline comment" panel))
      (should
       (string-match-p
        "C-c t c Task create"
        panel))
      (should
       (string-match-p "C-c t r/C-c t o Task resolve / reopen" panel))
      (should (string-match-p "\\? Help" panel)))
    (setq-local bitbucket-devops-pull-requests-ui--details-pull-request
                '((draft . t)))
    (should
     (string-match-p
      "R Toggle ready/draft"
      (bitbucket-devops-ui--command-panel-lines (current-buffer)))))
  (with-temp-buffer
    (bitbucket-devops-pull-requests-diff-mode)
    (let ((panel (bitbucket-devops-ui--command-panel-lines
                  (current-buffer))))
      (if (fboundp 'bitbucket-devops)
          (should (string-match-p "- Back" panel))
        (should-not (string-match-p "- Back" panel)))
      (should (string-match-p "i Inline comment" panel))
      (should (string-match-p "r Refresh" panel))
      (should (string-match-p "q Quit" panel))
      (should (string-match-p "\\? Help" panel))))
  (dolist (mode '(bitbucket-devops-pull-requests-commits-mode
                  bitbucket-devops-pull-requests-activity-mode))
    (with-temp-buffer
      (funcall mode)
      (let ((panel (bitbucket-devops-ui--command-panel-lines
                    (current-buffer))))
        (should (string-match-p "r Refresh" panel))
        (should (string-match-p "q Quit" panel))
        (should (string-match-p "\\? Help" panel))))))

(ert-deftest bitbucket-devops-ui-command-panel-shows-back-with-ui-previous ()
  (let ((previous (generate-new-buffer " *bitbucket-devops-pipelines-previous*")))
    (unwind-protect
        (progn
          (with-current-buffer previous
            (bitbucket-devops-pipelines-history-mode))
          (with-temp-buffer
            (bitbucket-devops-pipelines-details-mode)
            (setq-local bitbucket-devops-ui--previous-buffer previous)
            (should
             (string-match-p
              "- Back"
              (bitbucket-devops-ui--command-panel-lines
               (current-buffer)))))
          (with-temp-buffer
            (bitbucket-devops-pipelines-log-mode)
            (setq-local bitbucket-devops-ui--previous-buffer previous)
            (should
             (string-match-p
              "- Back"
              (bitbucket-devops-ui--command-panel-lines
               (current-buffer))))))
      (kill-buffer previous))))

(ert-deftest bitbucket-devops-ui-command-panel-shows-back-with-main-fallback ()
  (with-temp-buffer
    (bitbucket-devops-pipelines-history-mode)
    (cl-letf (((symbol-function 'bitbucket-devops)
               (lambda () (interactive))))
      (should
       (string-match-p
        "- Back"
        (bitbucket-devops-ui--command-panel-lines (current-buffer)))))))

(ert-deftest bitbucket-devops-ui-command-panel-lines-style-headings-and-keys ()
  (with-temp-buffer
    (bitbucket-devops-pipelines-history-mode)
    (let ((text
           (bitbucket-devops-ui--command-panel-lines (current-buffer))))
      (should
       (eq
        (get-text-property 0 'face text)
        'bitbucket-devops-command-panel-heading-face))
      (should
       (eq
        (get-text-property (string-match "RET" text) 'face text)
        'bitbucket-devops-command-panel-key-face)))))

(ert-deftest bitbucket-devops-ui-display-command-panel-uses-bottom-side-window ()
  (let ((source (generate-new-buffer " *bitbucket-devops-pipelines-history*"))
        observed)
    (unwind-protect
        (progn
          (with-current-buffer source
            (bitbucket-devops-pipelines-history-mode))
          (cl-letf (((symbol-function 'display-buffer)
                     (lambda (buffer action)
                       (setq observed (list buffer action))
                       nil)))
            (bitbucket-devops-ui--display-command-panel source))
          (should
           (eq
            (car observed)
            (get-buffer bitbucket-devops-ui--command-panel-buffer-name)))
          (should (equal (alist-get 'side (cadr observed)) 'bottom))
          (with-current-buffer (car observed)
            (should-not mode-line-format)
            (should (string-match-p "Filters" (buffer-string)))))
      (kill-buffer source)
      (when-let ((panel
                  (get-buffer bitbucket-devops-ui--command-panel-buffer-name)))
        (kill-buffer panel)))))

(ert-deftest bitbucket-devops-ui-command-panel-closes-after-leaving-owner ()
  (save-window-excursion
    (bitbucket-devops-ui--delete-command-panel)
    (let ((source (generate-new-buffer " *bitbucket-devops-panel-owner*"))
          (other (generate-new-buffer " *bitbucket-devops-panel-other*")))
      (unwind-protect
          (progn
            (switch-to-buffer source)
            (with-current-buffer source
              (bitbucket-devops-pipelines-history-mode))
            (bitbucket-devops-ui--display-command-panel source)
            (should (eq bitbucket-devops-ui--command-panel-owner source))
            (switch-to-buffer other)
            (run-hooks 'buffer-list-update-hook)
            (should-not bitbucket-devops-ui--command-panel-owner)
            (should-not
             (get-buffer bitbucket-devops-ui--command-panel-buffer-name)))
        (when (buffer-live-p source)
          (kill-buffer source))
        (when (buffer-live-p other)
          (kill-buffer other))
        (bitbucket-devops-ui--delete-command-panel)))))

(ert-deftest bitbucket-devops-ui-command-panel-closes-with-owner-buffer ()
  (save-window-excursion
    (bitbucket-devops-ui--delete-command-panel)
    (let ((source (generate-new-buffer " *bitbucket-devops-panel-owner*")))
      (unwind-protect
          (progn
            (switch-to-buffer source)
            (with-current-buffer source
              (bitbucket-devops-pipelines-history-mode))
            (bitbucket-devops-ui--display-command-panel source)
            (kill-buffer source)
            (should-not bitbucket-devops-ui--command-panel-owner)
            (should-not
             (get-buffer bitbucket-devops-ui--command-panel-buffer-name)))
        (when (buffer-live-p source)
          (kill-buffer source))
        (bitbucket-devops-ui--delete-command-panel)))))

(ert-deftest bitbucket-devops-ui-command-panel-grows-to-fit-bindings ()
  (let ((source (generate-new-buffer " *bitbucket-pull-request-detail*"))
        (bitbucket-devops-command-panel-height 3)
        observed)
    (unwind-protect
        (progn
          (with-current-buffer source
            (bitbucket-devops-pull-requests-detail-mode))
          (cl-letf (((symbol-function 'display-buffer)
                     (lambda (_buffer action)
                       (setq observed action)
                       nil)))
            (bitbucket-devops-ui--display-command-panel source))
          (should (> (alist-get 'window-height observed)
                     bitbucket-devops-command-panel-height))
          (with-current-buffer
              (get-buffer bitbucket-devops-ui--command-panel-buffer-name)
            (should
             (= (alist-get 'window-height observed)
                (count-lines (point-min) (point-max))))))
      (kill-buffer source)
      (when-let ((panel
                  (get-buffer bitbucket-devops-ui--command-panel-buffer-name)))
        (kill-buffer panel)))))

(ert-deftest bitbucket-devops-ui-display-command-panel-manual-hides-automatic-display ()
  (let ((source (generate-new-buffer " *bitbucket-devops-pipelines-history*"))
        (bitbucket-devops-command-panel-enabled nil)
        displayed)
    (unwind-protect
        (progn
          (with-current-buffer source
            (bitbucket-devops-pipelines-history-mode))
          (cl-letf (((symbol-function 'display-buffer)
                     (lambda (&rest _args)
                       (setq displayed t))))
            (should-not
             (bitbucket-devops-ui--display-command-panel source)))
          (should-not displayed)
          (should-not
          (get-buffer bitbucket-devops-ui--command-panel-buffer-name)))
      (kill-buffer source))))

(ert-deftest bitbucket-devops-ui-show-command-panel-forces-display ()
  (let ((source (generate-new-buffer " *bitbucket-devops-pipelines-history*"))
        (bitbucket-devops-command-panel-enabled nil)
        observed)
    (unwind-protect
        (progn
          (with-current-buffer source
            (bitbucket-devops-pipelines-history-mode))
          (cl-letf (((symbol-function 'display-buffer)
                     (lambda (buffer action)
                       (setq observed (list buffer action))
                       nil)))
            (with-current-buffer source
              (bitbucket-devops-ui-show-command-panel)))
          (should
           (eq
            (car observed)
            (get-buffer bitbucket-devops-ui--command-panel-buffer-name)))
          (should (eq bitbucket-devops-ui--command-panel-owner source)))
      (kill-buffer source)
      (when-let ((panel
                  (get-buffer bitbucket-devops-ui--command-panel-buffer-name)))
        (kill-buffer panel))
      (setq bitbucket-devops-ui--command-panel-owner nil))))

(ert-deftest bitbucket-devops-ui-show-command-panel-toggles-visible-panel ()
  (let ((source (generate-new-buffer " *bitbucket-devops-pipelines-history*")))
    (unwind-protect
        (save-window-excursion
          (with-current-buffer source
            (bitbucket-devops-pipelines-history-mode))
          (switch-to-buffer source)
          (bitbucket-devops-ui--display-command-panel source t)
          (should (bitbucket-devops-ui--command-panel-displayed-p source))
          (with-current-buffer source
            (bitbucket-devops-ui-show-command-panel))
          (should-not
           (get-buffer bitbucket-devops-ui--command-panel-buffer-name)))
      (kill-buffer source)
      (when-let ((panel
                  (get-buffer bitbucket-devops-ui--command-panel-buffer-name)))
        (kill-buffer panel))
      (setq bitbucket-devops-ui--command-panel-owner nil))))

(ert-deftest bitbucket-devops-ui-show-command-panel-never-stays-hidden ()
  (let ((source (generate-new-buffer " *bitbucket-devops-pipelines-history*"))
        (bitbucket-devops-command-panel-enabled 'never)
        displayed
        message-text)
    (unwind-protect
        (progn
          (with-current-buffer source
            (bitbucket-devops-pipelines-history-mode))
          (cl-letf (((symbol-function 'display-buffer)
                     (lambda (&rest _args)
                       (setq displayed t)))
                    ((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (setq message-text
                             (apply #'format format-string args)))))
            (with-current-buffer source
              (bitbucket-devops-ui-show-command-panel)))
          (should-not displayed)
          (should-not
           (get-buffer bitbucket-devops-ui--command-panel-buffer-name))
          (should (string-match-p "disabled" message-text)))
      (kill-buffer source)
      (setq bitbucket-devops-ui--command-panel-owner nil))))

(ert-deftest bitbucket-devops-ui-display-command-panel-uses-custom-side ()
  (let ((source (generate-new-buffer " *bitbucket-devops-pipelines-history*"))
        (bitbucket-devops-command-panel-side 'top)
        observed)
    (unwind-protect
        (progn
          (with-current-buffer source
            (bitbucket-devops-pipelines-history-mode))
          (cl-letf (((symbol-function 'display-buffer)
                     (lambda (_buffer action)
                       (setq observed action)
                       nil)))
            (bitbucket-devops-ui--display-command-panel source))
          (should (equal (alist-get 'side observed) 'top)))
      (kill-buffer source)
      (when-let ((panel
                  (get-buffer bitbucket-devops-ui--command-panel-buffer-name)))
        (kill-buffer panel)))))

(ert-deftest bitbucket-devops-ui-quit-kills-buffer-and-command-panel ()
  (save-window-excursion
    (bitbucket-devops-ui--delete-command-panel)
    (let ((source (generate-new-buffer " *bitbucket-devops-pipelines-quit*")))
      (unwind-protect
          (progn
            (switch-to-buffer source)
            (with-current-buffer source
              (bitbucket-devops-pipelines-history-mode))
            (bitbucket-devops-ui--display-command-panel source)
            (should
             (get-buffer-window
              bitbucket-devops-ui--command-panel-buffer-name
              t))
            (with-current-buffer source
              (bitbucket-devops-ui-quit))
            (should-not (buffer-live-p source))
            (should-not
             (get-buffer bitbucket-devops-ui--command-panel-buffer-name)))
        (when (buffer-live-p source)
          (kill-buffer source))
        (bitbucket-devops-ui--delete-command-panel)))))

(ert-deftest bitbucket-devops-ui-display-buffer-fullscreen-replaces-windows ()
  (let ((buffer (generate-new-buffer " *bitbucket-devops-pipelines-display*"))
        (previous (generate-new-buffer " *bitbucket-devops-pipelines-previous*"))
        observed)
    (unwind-protect
        (let ((bitbucket-devops-fullscreen-buffers t))
          (with-current-buffer previous
            (bitbucket-devops-pipelines-history-mode))
          (cl-letf (((symbol-function 'delete-other-windows)
                     (lambda (&rest _args) (push 'delete-other-windows observed)))
                    ((symbol-function 'switch-to-buffer)
                     (lambda (target &rest _args)
                       (push (list 'switch-to-buffer target) observed)))
                    ((symbol-function
                      'bitbucket-devops-ui--display-command-panel)
                     #'ignore))
            (bitbucket-devops-ui--display-buffer buffer t previous)
            (should
             (equal
              (nreverse observed)
              (list 'delete-other-windows (list 'switch-to-buffer buffer))))
            (with-current-buffer buffer
              (should (eq bitbucket-devops-ui--previous-buffer previous)))))
      (kill-buffer buffer)
      (kill-buffer previous))))

(ert-deftest bitbucket-devops-ui-display-buffer-ignores-non-ui-previous-buffer ()
  (let ((buffer (generate-new-buffer " *bitbucket-devops-pipelines-display*"))
        (previous (generate-new-buffer " *bitbucket-devops-pipelines-previous*")))
    (unwind-protect
        (cl-letf (((symbol-function 'pop-to-buffer) #'ignore)
                  ((symbol-function
                    'bitbucket-devops-ui--display-command-panel)
                   #'ignore))
          (bitbucket-devops-ui--display-buffer buffer t previous)
          (with-current-buffer buffer
            (should-not bitbucket-devops-ui--previous-buffer)))
      (kill-buffer buffer)
      (kill-buffer previous))))

(ert-deftest bitbucket-devops-ui-display-buffer-disables-line-wrapping ()
  (let ((buffer (generate-new-buffer " *bitbucket-devops-pipelines-display*")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (bitbucket-devops-pipelines-history-mode)
            (visual-line-mode 1)
            (setq-local truncate-lines nil)
            (setq-local word-wrap t))
          (cl-letf (((symbol-function 'pop-to-buffer) #'ignore)
                    ((symbol-function
                      'bitbucket-devops-ui--display-command-panel)
                     #'ignore))
            (bitbucket-devops-ui--display-buffer buffer t))
          (with-current-buffer buffer
            (should truncate-lines)
            (should-not word-wrap)
            (should-not visual-line-mode)))
      (kill-buffer buffer))))

(ert-deftest bitbucket-devops-ui-back-restores-prior-buffer ()
  (let ((previous (generate-new-buffer " *bitbucket-devops-pipelines-previous*"))
        observed)
    (unwind-protect
        (progn
          (with-current-buffer previous
            (bitbucket-devops-pipelines-history-mode))
          (with-temp-buffer
            (setq-local bitbucket-devops-ui--previous-buffer previous)
            (cl-letf (((symbol-function 'bitbucket-devops-ui--display-buffer)
                       (lambda (&rest args) (setq observed args))))
              (bitbucket-devops-ui-back)
              (should (equal observed (list previous t))))))
      (kill-buffer previous))))

(ert-deftest bitbucket-devops-ui-back-opens-main-command-without-prior-buffer ()
  (let (opened)
    (with-temp-buffer
      (bitbucket-devops-pipelines-history-mode)
      (cl-letf (((symbol-function 'bitbucket-devops)
                 (lambda () (interactive) (setq opened t))))
        (bitbucket-devops-ui-back)
        (should opened)))))

(provide 'bitbucket-devops-ui-test)
;;; bitbucket-devops-ui-test.el ends here
