;;; bitbucket-devops-pipelines-mutate-test.el --- Tests for pipeline mutations -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'bitbucket-devops-pipelines-mutate)

(ert-deftest bitbucket-devops-pipelines-mutate-branch-body-builds-default-target ()
  (should
   (equal
    (bitbucket-devops-pipelines-mutate-branch-body "main")
    '((target . ((type . "pipeline_ref_target")
                 (ref_type . "branch")
                 (ref_name . "main")))))))

(ert-deftest bitbucket-devops-pipelines-mutate-branch-body-builds-custom-variables ()
  (should
   (equal
    (bitbucket-devops-pipelines-mutate-branch-body
     "main"
     "manual-smoke"
     '((:key "SECRET" :value "hidden")
       (:key "MESSAGE" :value "hello")))
    '((target . ((type . "pipeline_ref_target")
                 (ref_type . "branch")
                 (ref_name . "main")
                 (selector . ((type . "custom")
                              (pattern . "manual-smoke")))))
      (variables . [((key . "SECRET")
                     (value . "hidden"))
                    ((key . "MESSAGE")
                     (value . "hello"))])))))

(ert-deftest bitbucket-devops-pipelines-mutate-branch-body-builds-explicit-selector ()
  (should
   (equal
    (bitbucket-devops-pipelines-mutate-branch-body
     "feature/example"
     '((type . "branches") (pattern . "dev")))
    '((target . ((type . "pipeline_ref_target")
                 (ref_type . "branch")
                 (ref_name . "feature/example")
                 (selector . ((type . "branches")
                              (pattern . "dev")))))))))

(ert-deftest bitbucket-devops-pipelines-mutate-pull-request-body-builds-target ()
  (should
   (equal
    (bitbucket-devops-pipelines-mutate-pull-request-body
     '((id . 42)
       (source . ((branch . ((name . "feature/example")))
                  (commit . ((hash . "abc123")))))
       (destination . ((branch . ((name . "main")))
                       (commit . ((hash . "def456"))))))
     "**")
    '((target . ((type . "pipeline_pullrequest_target")
                 (source . "feature/example")
                 (destination . "main")
                 (destination_commit . ((hash . "def456")))
                 (commit . ((hash . "abc123")))
                 (pullrequest . ((id . "42")))
                 (selector . ((type . "pull-requests")
                              (pattern . "**")))))))))

(ert-deftest bitbucket-devops-pipelines-mutate-rerun-body-reuses-prior-target ()
  (let ((pipeline
         '((target . ((type . "pipeline_ref_target")
                      (ref_type . "branch")
                      (ref_name . "main")
                      (commit . ((type . "commit")
                                 (hash . "0123456789abcdef"))))))))
    (should
     (equal
      (bitbucket-devops-pipelines-mutate-rerun-body pipeline)
      pipeline))))

(ert-deftest bitbucket-devops-pipelines-mutate-remember-defaults-discards-values ()
  (let (bitbucket-devops-pipelines-last-branch
        bitbucket-devops-pipelines-last-custom-selector
        bitbucket-devops-pipelines-last-variable-metadata
        (bitbucket-devops-pipelines-remember-variable-values nil))
    (bitbucket-devops-pipelines-mutate-remember-defaults
     "main"
     "manual-smoke"
     '((:key "SECRET" :value "must-not-persist")
       (:key "MESSAGE" :value "also-not-persisted")))
    (should (equal bitbucket-devops-pipelines-last-branch "main"))
    (should
     (equal bitbucket-devops-pipelines-last-custom-selector "manual-smoke"))
    (should
     (equal
      bitbucket-devops-pipelines-last-variable-metadata
      '((:key "SECRET")
        (:key "MESSAGE"))))
    (should-not
     (string-match-p
      "persist"
      (format "%S" bitbucket-devops-pipelines-last-variable-metadata)))))

(ert-deftest bitbucket-devops-pipelines-mutate-remember-defaults-keeps-values-when-enabled ()
  (let (bitbucket-devops-pipelines-last-variable-metadata
        (bitbucket-devops-pipelines-remember-variable-values t))
    (bitbucket-devops-pipelines-mutate-remember-defaults
     "main"
     "agent-pr-review"
     '((:key "PR_ID" :value "2361")
       (:key "RUN_PLAN" :value "true")))
    (should
     (equal
      bitbucket-devops-pipelines-last-variable-metadata
      '((:key "PR_ID" :value "2361")
        (:key "RUN_PLAN" :value "true"))))))

(ert-deftest bitbucket-devops-pipelines-mutate-trigger-starts-watcher-on-success ()
  (let (observed watcher)
    (cl-letf (((symbol-function 'bitbucket-devops-rest-run-pipeline)
               (lambda (context body callback)
                 (setq observed (list context body))
                 (funcall callback
                          '((uuid . "{pipeline-12}") (build_number . 12))
                          nil)
                 'request-process))
              ((symbol-function 'bitbucket-devops-pipelines-watch-pipeline)
               (lambda (context pipeline-uuid)
                 (setq watcher (list context pipeline-uuid)))))
      (bitbucket-devops-pipelines-mutate-trigger
       '(:workspace "williseed1" :repo-slug "test")
       '((target . ((type . "pipeline_ref_target")))))
      (should observed)
      (should
       (equal
        watcher
        '((:workspace "williseed1" :repo-slug "test")
          "{pipeline-12}"))))))

(ert-deftest bitbucket-devops-pipelines-mutate-trigger-forwards-errors ()
  (let (callback-args)
    (cl-letf (((symbol-function 'bitbucket-devops-rest-run-pipeline)
               (lambda (_context _body callback)
                 (funcall callback nil '(:type http :status 403))
                 'request-process)))
      (bitbucket-devops-pipelines-mutate-trigger
       '(:workspace "williseed1" :repo-slug "test")
       '((target . ((type . "pipeline_ref_target"))))
       (lambda (&rest args) (setq callback-args args)))
      (should
       (equal callback-args '(nil (:type http :status 403)))))))

(ert-deftest bitbucket-devops-pipelines-mutate-stop-rejects-completed-pipeline ()
  (let ((bitbucket-devops-ui--context
         '(:workspace "williseed1" :repo-slug "test"))
        (bitbucket-devops-ui--details-pipeline
         '((uuid . "{pipeline-12}")
           (build_number . 12)
           (state . ((name . "COMPLETED")
                     (result . ((name . "SUCCESSFUL")))))))
        rest-called)
    (cl-letf (((symbol-function 'bitbucket-devops-rest-stop-pipeline)
               (lambda (&rest _args) (setq rest-called t)))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _args)
                 (ert-fail "Completed pipeline should not prompt"))))
      (let ((error-data
             (should-error
              (bitbucket-devops-pipelines-stop)
              :type 'user-error)))
        (should
         (string-match-p
          "already completed (SUCCESSFUL)"
          (error-message-string error-data))))
      (should-not rest-called))))

(ert-deftest bitbucket-devops-pipelines-mutate-stop-allows-active-pipeline ()
  (let ((bitbucket-devops-ui--context
         '(:workspace "williseed1" :repo-slug "test"))
        (bitbucket-devops-ui--details-pipeline
         '((uuid . "{pipeline-12}")
           (build_number . 12)
           (state . ((name . "IN_PROGRESS")))))
        observed)
    (cl-letf (((symbol-function 'bitbucket-devops-rest-stop-pipeline)
               (lambda (&rest args) (setq observed args)))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _args) t)))
      (bitbucket-devops-pipelines-stop)
      (should
       (equal
        observed
        (list
         '(:workspace "williseed1" :repo-slug "test")
         "{pipeline-12}"
         (caddr observed)))))))

(ert-deftest bitbucket-devops-pipelines-mutate-continue-allows-paused-pending-step ()
  (let ((bitbucket-devops-ui--context
         '(:workspace "williseed1" :repo-slug "test"))
        (bitbucket-devops-ui--details-pipeline
         '((uuid . "{pipeline-12}")
           (build_number . 12)
           (state . ((name . "IN_PROGRESS")
                     (stage . ((name . "PAUSED")))))))
        (bitbucket-devops-ui--details-steps
         '(((uuid . "{step-1}")
            (name . "Build")
            (state . ((name . "COMPLETED")
                      (result . ((name . "SUCCESSFUL"))))))
           ((uuid . "{step-2}")
            (name . "Approve")
            (state . ((name . "PENDING"))))))
        observed
        watcher)
    (cl-letf (((symbol-function 'tabulated-list-get-id)
               (lambda () "{step-2}"))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _args) t))
              ((symbol-function 'bitbucket-devops-rest-start-step)
               (lambda (&rest args)
                 (setq observed args)
                 (funcall (nth 3 args) nil nil)))
              ((symbol-function 'bitbucket-devops-pipelines-watch-pipeline)
               (lambda (context pipeline-uuid)
                 (setq watcher (list context pipeline-uuid)))))
      (bitbucket-devops-pipelines-continue)
      (should
       (equal
        (butlast observed)
        '((:workspace "williseed1" :repo-slug "test")
          "{pipeline-12}"
          "{step-2}")))
      (should
       (equal
        watcher
        '((:workspace "williseed1" :repo-slug "test")
          "{pipeline-12}"))))))

(ert-deftest bitbucket-devops-pipelines-mutate-continue-finds-single-pending-step ()
  (let ((bitbucket-devops-ui--context
         '(:workspace "williseed1" :repo-slug "test"))
        (bitbucket-devops-ui--details-pipeline
         '((uuid . "{pipeline-12}")
           (build_number . 12)
           (state . ((name . "IN_PROGRESS")
                     (stage . ((name . "PAUSED")))))))
        (bitbucket-devops-ui--details-steps
         '(((uuid . "{step-1}")
            (name . "Blue/Green: DEV Deploy")
            (state . ((name . "COMPLETED")
                      (result . ((name . "SUCCESSFUL"))))))
           ((uuid . "{step-2}")
            (name . "Blue/Green: DEV Approve")
            (state . ((name . "PENDING"))))))
        observed)
    (cl-letf (((symbol-function 'tabulated-list-get-id)
               (lambda () "{step-1}"))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _args) t))
              ((symbol-function 'bitbucket-devops-rest-start-step)
               (lambda (&rest args)
                 (setq observed args)
                 (funcall (nth 3 args) nil nil)))
              ((symbol-function 'bitbucket-devops-pipelines-watch-pipeline)
               #'ignore))
      (bitbucket-devops-pipelines-continue)
      (should
       (equal
        (butlast observed)
        '((:workspace "williseed1" :repo-slug "test")
          "{pipeline-12}"
          "{step-2}"))))))

(ert-deftest bitbucket-devops-pipelines-mutate-continue-rejects-non-paused-pipeline ()
  (let ((bitbucket-devops-ui--context
         '(:workspace "williseed1" :repo-slug "test"))
        (bitbucket-devops-ui--details-pipeline
         '((uuid . "{pipeline-12}")
           (build_number . 12)
           (state . ((name . "IN_PROGRESS")))))
        (bitbucket-devops-ui--details-steps
         '(((uuid . "{step-2}")
            (name . "Approve")
            (state . ((name . "PENDING"))))))
        rest-called)
    (cl-letf (((symbol-function 'tabulated-list-get-id)
               (lambda () "{step-2}"))
              ((symbol-function 'bitbucket-devops-rest-start-step)
               (lambda (&rest _args) (setq rest-called t)))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _args)
                 (ert-fail "Non-paused pipeline should not prompt"))))
      (let ((error-data
             (should-error
              (bitbucket-devops-pipelines-continue)
              :type 'user-error)))
        (should
         (string-match-p
          "is not paused"
          (error-message-string error-data))))
      (should-not rest-called))))

(ert-deftest bitbucket-devops-pipelines-mutate-continue-rejects-completed-step ()
  (let ((bitbucket-devops-ui--context
         '(:workspace "williseed1" :repo-slug "test"))
        (bitbucket-devops-ui--details-pipeline
         '((uuid . "{pipeline-12}")
           (build_number . 12)
           (state . ((name . "IN_PROGRESS")
                     (stage . ((name . "PAUSED")))))))
        (bitbucket-devops-ui--details-steps
         '(((uuid . "{step-1}")
            (name . "Build")
            (state . ((name . "COMPLETED")
                      (result . ((name . "SUCCESSFUL"))))))))
        rest-called)
    (cl-letf (((symbol-function 'tabulated-list-get-id)
               (lambda () "{step-1}"))
              ((symbol-function 'bitbucket-devops-rest-start-step)
               (lambda (&rest _args) (setq rest-called t)))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _args)
                 (ert-fail "Completed step should not prompt"))))
      (let ((error-data
             (should-error
              (bitbucket-devops-pipelines-continue)
              :type 'user-error)))
        (should
         (string-match-p
          "is not pending"
          (error-message-string error-data))))
      (should-not rest-called))))

(ert-deftest bitbucket-devops-pipelines-mutate-continue-explains-auth-mechanism-error ()
  (let ((message
         (bitbucket-devops-pipelines-mutate--continue-error-message
          '(:type http
            :status 403
            :message
            "This API is not accessible by this authentication mechanism"))))
    (should
     (string-match-p "Atlassian user API token" message))
    (should
     (string-match-p "Bitbucket web UI" message))))

(ert-deftest bitbucket-devops-pipelines-mutate-production-reasons-match-branch-and-deployment ()
  (should
   (equal
    (bitbucket-devops-pipelines-mutate--production-reasons
     (bitbucket-devops-pipelines-mutate-branch-body "master")
     '("development" "first-prod" "PRODUCTION"))
    '("branch master" "deployment first-prod" "deployment PRODUCTION"))))

(ert-deftest bitbucket-devops-pipelines-mutate-trigger-confirms-production-branch ()
  (let (observed-prompt rest-called)
    (let ((bitbucket-devops-pipelines-production-confirmation-function
           (lambda (prompt)
             (setq observed-prompt prompt)
             t)))
      (cl-letf (((symbol-function 'bitbucket-devops-rest-run-pipeline)
                 (lambda (_context _body _callback)
                   (setq rest-called t))))
        (bitbucket-devops-pipelines-mutate-trigger
         '(:workspace "williseed1" :repo-slug "test")
         (bitbucket-devops-pipelines-mutate-branch-body "main"))))
    (should rest-called)
    (should
     (equal
      observed-prompt
      "Production-sensitive Bitbucket pipeline (branch main). Run it? "))))

(ert-deftest bitbucket-devops-pipelines-mutate-trigger-cancel-prevents-production-request ()
  (let (rest-called)
    (let ((bitbucket-devops-pipelines-production-confirmation-function
           (lambda (&rest _args) nil)))
      (cl-letf (((symbol-function 'bitbucket-devops-rest-run-pipeline)
                 (lambda (&rest _args)
                   (setq rest-called t))))
        (should-error
         (bitbucket-devops-pipelines-mutate-trigger
          '(:workspace "williseed1" :repo-slug "test")
          (bitbucket-devops-pipelines-mutate-branch-body "feature/example")
          nil
          '("pre-production"))
         :type 'user-error)))
    (should-not rest-called)))

(ert-deftest bitbucket-devops-pipelines-mutate-parse-custom-selectors ()
  (let ((file (make-temp-file "pipelines" nil ".yml")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "pipelines:\n"
                    "  default:\n"
                    "    - step:\n"
                    "        script:\n"
                    "          - echo default\n"
                    "  custom:\n"
                    "    manual-smoke:\n"
                    "      - variables:\n"
                    "          - name: HELLO\n"
                    "      - step:\n"
                    "          script:\n"
                    "            - echo smoke\n"
                    "    deploy-prod:\n"
                    "      - step:\n"
                    "          script:\n"
                    "            - echo deploy\n"))
          (should
           (equal
            (bitbucket-devops-pipelines-mutate--parse-custom-selectors file)
            '("manual-smoke" "deploy-prod"))))
      (delete-file file))))

(ert-deftest bitbucket-devops-pipelines-mutate-parse-custom-variables ()
  (let ((file (make-temp-file "pipelines" nil ".yml")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "pipelines:\n"
                    "  custom:\n"
                    "    manual-smoke:\n"
                    "      - variables:\n"
                    "          - name: HELLO\n"
                    "          - name: WORLD\n"
                    "      - step:\n"
                    "          script:\n"
                    "            - echo done\n"
                    "    no-vars:\n"
                    "      - step:\n"
                    "          script:\n"
                    "            - echo plain\n"))
          (should
           (equal
            (mapcar
             #'bitbucket-devops-pipelines-yaml-variable-name
             (bitbucket-devops-pipelines-mutate--parse-custom-variables
              file "manual-smoke"))
            '("HELLO" "WORLD")))
          (should
           (equal
            (bitbucket-devops-pipelines-mutate--parse-custom-variables
             file "no-vars")
            nil)))
      (delete-file file))))

(ert-deftest bitbucket-devops-pipelines-mutate-parses-complex-custom-selector ()
  (let ((file (make-temp-file "pipelines" nil ".yml")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "pipelines:\n"
                    "  custom:\n"
                    "    \"deploy prod/v1.0\":\n"
                    "      - step:\n"
                    "          script: [echo deploy]\n"))
          (should
           (equal
            (bitbucket-devops-pipelines-mutate--parse-custom-selectors file)
            '("deploy prod/v1.0"))))
      (delete-file file))))

(ert-deftest bitbucket-devops-pipelines-mutate-loads-configured-deployments ()
  (let ((root (make-temp-file "pipelines-root" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "bitbucket-pipelines.yml" root)
            (insert "pipelines:\n"
                    "  default:\n"
                    "    - step:\n"
                    "        deployment: development\n"
                    "        script: [echo default]\n"
                    "  branches:\n"
                    "    release/*:\n"
                    "      - step:\n"
                    "          deployment: first-prod\n"
                    "          script: [echo release]\n"
                    "  custom:\n"
                    "    deploy:\n"
                    "      - step:\n"
                    "          deployment: production\n"
                    "          script: [echo deploy]\n"))
          (let ((context (list :root root)))
            (should
             (equal
              (bitbucket-devops-pipelines-mutate--configured-deployments context nil)
              '("development" "first-prod")))
            (should
             (equal
              (bitbucket-devops-pipelines-mutate--configured-deployments
               context "deploy")
              '("production")))))
      (delete-directory root t))))

(ert-deftest bitbucket-devops-pipelines-mutate-run-configured-targets-current-branch-with-selected-selector ()
  (let ((root (make-temp-file "pipelines-root" t))
        observed
        labels)
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "bitbucket-pipelines.yml" root)
            (insert "pipelines:\n"
                    "  default:\n"
                    "    - step:\n"
                    "        script: [echo default]\n"
                    "  branches:\n"
                    "    dev:\n"
                    "      - step:\n"
                    "          deployment: dev\n"
                    "          script: [echo dev]\n"
                    "    uat:\n"
                    "      - step:\n"
                    "          deployment: uat\n"
                    "          script: [echo uat]\n"))
          (cl-letf (((symbol-function 'bitbucket-devops-context-resolve)
                     (lambda (_directory)
                       (list :workspace "williseed1"
                             :repo-slug "test"
                             :root root
                             :branch "feature/example")))
                    ((symbol-function 'bitbucket-devops-context-require-branch)
                     (lambda (_context) "feature/example"))
                    ((symbol-function 'completing-read)
                     (lambda (_prompt collection &rest _args)
                       (setq labels (mapcar #'car collection))
                       "branches: dev"))
                    ((symbol-function 'bitbucket-devops-rest-run-pipeline)
                     (lambda (context body _callback)
                       (setq observed (list context body))
                       'request-process)))
            (bitbucket-devops-pipelines-run-configured root))
          (should
           (equal
            labels
            '("default"
              "branches: dev"
              "branches: uat")))
          (should
           (equal
            (alist-get 'ref_name (alist-get 'target (cadr observed)))
            "feature/example"))
          (should
           (equal
            (alist-get 'selector (alist-get 'target (cadr observed)))
            '((type . "branches") (pattern . "dev")))))
      (delete-directory root t))))

(ert-deftest bitbucket-devops-pipelines-mutate-run-configured-triggers-pull-request-selector ()
  (let ((root (make-temp-file "pipelines-root" t))
        observed
        labels
        requested-detail)
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "bitbucket-pipelines.yml" root)
            (insert "pipelines:\n"
                    "  pull-requests:\n"
                    "    \"**\":\n"
                    "      - step:\n"
                    "          script: [echo pr]\n"))
          (cl-letf (((symbol-function 'bitbucket-devops-context-resolve)
                     (lambda (_directory)
                       (list :workspace "williseed1"
                             :repo-slug "test"
                             :root root
                             :branch "feature/example")))
                    ((symbol-function 'bitbucket-devops-context-require-branch)
                     (lambda (_context) "feature/example"))
                    ((symbol-function 'completing-read)
                     (lambda (_prompt collection &rest _args)
                       (setq labels (mapcar #'car collection))
                       "pull-requests: **"))
                    ((symbol-function 'bitbucket-devops-pull-requests-rest-list)
                     (lambda (_context callback &optional _next-url state)
                       (should (equal state "OPEN"))
                       (funcall
                        callback
                        '((values
                           . (((id . 42)
                               (title . "Feature")
                               (source . ((branch . ((name . "feature/example")))))
                               (destination . ((branch . ((name . "main")))))))))
                        nil)
                       'list-request))
                    ((symbol-function 'bitbucket-devops-pull-requests-rest-get)
                     (lambda (_context pull-request-id callback)
                       (setq requested-detail pull-request-id)
                       (funcall
                        callback
                        '((id . 42)
                          (title . "Feature")
                          (source . ((branch . ((name . "feature/example")))
                                     (commit . ((hash . "abc123")))))
                          (destination . ((branch . ((name . "main")))
                                          (commit . ((hash . "def456"))))))
                        nil)
                       'detail-request))
                    ((symbol-function 'bitbucket-devops-rest-run-pipeline)
                     (lambda (context body _callback)
                       (setq observed (list context body))
                       'request-process)))
            (bitbucket-devops-pipelines-run-configured root))
          (should (equal labels '("pull-requests: **")))
          (should (equal requested-detail 42))
          (should
           (equal
            (alist-get 'target (cadr observed))
            '((type . "pipeline_pullrequest_target")
              (source . "feature/example")
              (destination . "main")
              (destination_commit . ((hash . "def456")))
              (commit . ((hash . "abc123")))
              (pullrequest . ((id . "42")))
              (selector . ((type . "pull-requests")
                           (pattern . "**")))))))
      (delete-directory root t))))

(ert-deftest bitbucket-devops-pipelines-mutate-uses-custom-yaml-file-name ()
  (let ((root (make-temp-file "pipelines-root" t))
        (bitbucket-devops-pipelines-yaml-file-name "pipelines.test.yml"))
    (unwind-protect
        (let ((path (expand-file-name "pipelines.test.yml" root)))
          (with-temp-file path
            (insert "pipelines:\n"
                    "  default:\n"
                    "    - step:\n"
                    "        script: [echo test]\n"))
          (should
           (equal
            (bitbucket-devops-pipelines-mutate--pipelines-yml (list :root root))
            path)))
      (delete-directory root t))))

(ert-deftest bitbucket-devops-pipelines-mutate-read-variable-does-not-prompt-for-security ()
  (let (observed)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (&rest _args)
                 (ert-fail "Unexpected security prompt")))
              ((symbol-function 'read-passwd)
               (lambda (&rest _args)
                 (ert-fail "Unexpected secured-value prompt")))
              ((symbol-function 'read-string)
               (lambda (prompt &optional initial-input &rest _args)
                 (setq observed (list prompt initial-input))
                 "123")))
      (should
       (equal
        (bitbucket-devops-pipelines-mutate--read-variable "PR_ID")
        '(:key "PR_ID" :value "123")))
      (should (equal observed '("Value for variable PR_ID: " nil))))))

(ert-deftest bitbucket-devops-pipelines-mutate-read-variable-offers-allowed-values ()
  (let ((variable
         (bitbucket-devops-pipelines-yaml--make-variable
          :name "RUN_PLAN"
          :default "true"
          :allowed-values '("true" "false")))
        observed)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (prompt collection &optional _predicate
                               _require-match _initial-input _history default)
                 (setq observed
                       (list
                        prompt
                        (all-completions "" collection)
                        (alist-get
                         'category
                         (completion-metadata "" collection nil))
                        default))
                 "false")))
      (should
       (equal
        (bitbucket-devops-pipelines-mutate--read-variable variable)
        '(:key "RUN_PLAN" :value "false")))
      (should
       (equal observed
              '("Value for variable RUN_PLAN: "
                ("true" "false")
                bitbucket-devops-pipelines-runtime-variable-value
                "true"))))))

(ert-deftest bitbucket-devops-pipelines-mutate-read-variable-uses-remembered-value ()
  (let ((bitbucket-devops-pipelines-remember-variable-values t)
        (bitbucket-devops-pipelines-last-variable-metadata
         '((:key "PR_ID" :value "2361")))
        observed)
    (cl-letf (((symbol-function 'read-string)
               (lambda (prompt &optional initial-input &rest _args)
                 (setq observed (list prompt initial-input))
                 "2362")))
      (should
       (equal
        (bitbucket-devops-pipelines-mutate--read-variable
         (bitbucket-devops-pipelines-yaml--make-variable :name "PR_ID"))
        '(:key "PR_ID" :value "2362")))
      (should (equal observed '("Value for variable PR_ID: " "2361"))))))

(ert-deftest bitbucket-devops-pipelines-mutate-read-variable-ignores-invalid-remembered-choice ()
  (let ((bitbucket-devops-pipelines-remember-variable-values t)
        (bitbucket-devops-pipelines-last-variable-metadata
         '((:key "RUN_PLAN" :value "maybe")))
        observed)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt _collection &optional _predicate
                                _require-match _initial-input _history default)
                 (setq observed default)
                 "true")))
      (should
       (equal
        (bitbucket-devops-pipelines-mutate--read-variable
         (bitbucket-devops-pipelines-yaml--make-variable
          :name "RUN_PLAN"
          :default "false"
          :allowed-values '("true" "false")))
        '(:key "RUN_PLAN" :value "true")))
      (should (equal observed "false")))))

(ert-deftest bitbucket-devops-pipelines-mutate-read-variables-reuses-remembered-metadata ()
  (let ((bitbucket-devops-pipelines-remember-variable-values t)
        (bitbucket-devops-pipelines-last-variable-metadata
         '((:key "PR_ID" :value "2361")))
        prompts)
    (cl-letf (((symbol-function 'read-string)
               (lambda (prompt &optional initial-input &rest _args)
                 (push (list prompt initial-input) prompts)
                 (if (string-prefix-p "Additional runtime variable" prompt)
                     ""
                   "2361"))))
      (should
       (equal
        (bitbucket-devops-pipelines-mutate--read-variables)
        nil))
      (should
       (equal
        (nreverse prompts)
        '(("Additional runtime variable key (empty for none): " nil)))))))

(ert-deftest bitbucket-devops-pipelines-mutate-read-variables-reuses-remembered-metadata-when-requested ()
  (let ((bitbucket-devops-pipelines-remember-variable-values t)
        (bitbucket-devops-pipelines-last-variable-metadata
         '((:key "PR_ID" :value "2361")))
        prompts)
    (cl-letf (((symbol-function 'read-string)
               (lambda (prompt &optional initial-input &rest _args)
                 (push (list prompt initial-input) prompts)
                 (if (string-prefix-p "Additional runtime variable" prompt)
                     ""
                   "2361"))))
      (should
       (equal
        (bitbucket-devops-pipelines-mutate--read-variables nil t)
        '((:key "PR_ID" :value "2361"))))
      (should
       (equal
        (nreverse prompts)
        '(("Value for variable PR_ID: " "2361")
          ("Additional runtime variable key (empty for none): " nil)))))))

(ert-deftest bitbucket-devops-pipelines-mutate-parse-selectors-returns-nil-gracefully ()
  (let ((file (make-temp-file "pipelines" nil ".yml")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "pipelines:\n"
                    "  default:\n"
                    "    - step:\n"
                    "        script:\n"
                    "          - echo hello\n"))
          (should
           (equal
            (bitbucket-devops-pipelines-mutate--parse-custom-selectors file)
            nil)))
      (delete-file file))))

(provide 'bitbucket-devops-pipelines-mutate-test)
;;; bitbucket-devops-pipelines-mutate-test.el ends here
