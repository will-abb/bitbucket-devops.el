;;; bitbucket-devops-pipelines-yaml-test.el --- Tests for Pipelines YAML parsing -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Code:

(require 'ert)
(require 'bitbucket-devops-pipelines-yaml)

(defconst bitbucket-devops-pipelines-yaml-test--config
  "pipelines:
  default:
    - step:
        script: [echo default]
        deployment: development
  branches:
    main:
      - step:
          script: [echo main]
    release/*:
      - step:
          script: [echo release]
          deployment: first-prod
  pull-requests:
    \"**\":
      - step:
          script: [echo pr]
  tags:
    \"release/*\":
      - step:
          script: [echo tag]
  custom:
    \"deploy prod/v1.0\":
      - variables:
          - name: REGION
            default: us-east-1
            allowed-values: [us-east-1, us-west-2]
            description: Deployment region
          - name: RUN_PLAN
            default: \"true\"
            allowed-values: [\"true\", \"false\"]
      - step:
          script: [echo deploy]
          deployment: production
    no-vars:
      - step:
          script: [echo plain]
"
  "Representative Bitbucket Pipelines trigger configuration.")

(ert-deftest bitbucket-devops-pipelines-yaml-parses-trigger-sections ()
  (let ((config
         (bitbucket-devops-pipelines-yaml-parse-string
          bitbucket-devops-pipelines-yaml-test--config)))
    (should (bitbucket-devops-pipelines-yaml-config-default config))
    (should
     (equal
      (bitbucket-devops-pipelines-yaml-config-branches config)
      '("main" "release/*")))
    (should
     (equal (bitbucket-devops-pipelines-yaml-config-pull-requests config) '("**")))
    (should
     (equal (bitbucket-devops-pipelines-yaml-config-tags config) '("release/*")))
    (should
     (equal
      (mapcar
       #'bitbucket-devops-pipelines-yaml-option-pattern
       (bitbucket-devops-pipelines-yaml-config-custom config))
      '("deploy prod/v1.0" "no-vars")))))

(ert-deftest bitbucket-devops-pipelines-yaml-preserves-deployment-metadata ()
  (let* ((config
          (bitbucket-devops-pipelines-yaml-parse-string
           bitbucket-devops-pipelines-yaml-test--config))
         (option
          (bitbucket-devops-pipelines-yaml-custom-option config "deploy prod/v1.0")))
    (should
     (equal
      (bitbucket-devops-pipelines-yaml-config-deployments config)
      '("development" "first-prod")))
    (should
     (equal
      (bitbucket-devops-pipelines-yaml-option-deployments option)
      '("production")))))

(ert-deftest bitbucket-devops-pipelines-yaml-resolves-automatic-branch-deployments ()
  (let ((config
         (bitbucket-devops-pipelines-yaml-parse-string
          bitbucket-devops-pipelines-yaml-test--config)))
    (should
     (equal
      (bitbucket-devops-pipelines-yaml-automatic-deployments config "feature/test")
      '("development")))
    (should-not
     (bitbucket-devops-pipelines-yaml-automatic-deployments config "main"))
    (should
     (equal
      (bitbucket-devops-pipelines-yaml-automatic-deployments config "release/1.0")
      '("first-prod")))))

(ert-deftest bitbucket-devops-pipelines-yaml-manual-option-uses-selected-branch ()
  (let* ((config
          (bitbucket-devops-pipelines-yaml-parse-string
           bitbucket-devops-pipelines-yaml-test--config))
         (option
          (car (bitbucket-devops-pipelines-yaml-manual-options
                config
                "feature/test"))))
    (should
     (equal
      (bitbucket-devops-pipelines-yaml-option-deployments option)
      '("development")))))

(ert-deftest bitbucket-devops-pipelines-yaml-preserves-custom-variable-metadata ()
  (let* ((config
          (bitbucket-devops-pipelines-yaml-parse-string
           bitbucket-devops-pipelines-yaml-test--config))
         (option
          (bitbucket-devops-pipelines-yaml-custom-option config "deploy prod/v1.0"))
         (variable (car (bitbucket-devops-pipelines-yaml-option-variables option))))
    (should (equal (bitbucket-devops-pipelines-yaml-variable-name variable) "REGION"))
    (should
     (equal (bitbucket-devops-pipelines-yaml-variable-default variable) "us-east-1"))
    (should
     (equal
      (bitbucket-devops-pipelines-yaml-variable-allowed-values variable)
      '("us-east-1" "us-west-2")))
    (should
     (equal
      (bitbucket-devops-pipelines-yaml-variable-description variable)
      "Deployment region"))))

(ert-deftest bitbucket-devops-pipelines-yaml-normalizes-runtime-variable-booleans ()
  (let* ((config
          (bitbucket-devops-pipelines-yaml-parse-string
           bitbucket-devops-pipelines-yaml-test--config))
         (option
          (bitbucket-devops-pipelines-yaml-custom-option config "deploy prod/v1.0"))
         (variable
          (cadr (bitbucket-devops-pipelines-yaml-option-variables option))))
    (should (equal (bitbucket-devops-pipelines-yaml-variable-name variable) "RUN_PLAN"))
    (should (equal (bitbucket-devops-pipelines-yaml-variable-default variable) "true"))
    (should
     (equal
      (bitbucket-devops-pipelines-yaml-variable-allowed-values variable)
      '("true" "false")))))

(ert-deftest bitbucket-devops-pipelines-yaml-builds-current-branch-manual-options ()
  (let* ((config
          (bitbucket-devops-pipelines-yaml-parse-string
           bitbucket-devops-pipelines-yaml-test--config))
         (options (bitbucket-devops-pipelines-yaml-manual-options config)))
    (should
     (equal
      (mapcar #'bitbucket-devops-pipelines-yaml-option-label options)
      '("default"
        "branches: main"
        "branches: release/*"
        "pull-requests: **"
        "custom: deploy prod/v1.0"
        "custom: no-vars")))))

(ert-deftest bitbucket-devops-pipelines-yaml-builds-exact-branch-manual-options ()
  (let* ((config
          (bitbucket-devops-pipelines-yaml-parse-string
           "pipelines:
  branches:
    dev:
      - step:
          deployment: dev
          script: [echo dev]
    release/*:
      - step:
          deployment: production
          script: [echo release]
    main:
      - step:
          deployment: production
          script: [echo main]
"))
         (options (bitbucket-devops-pipelines-yaml-manual-options config)))
    (should
     (equal
      (mapcar #'bitbucket-devops-pipelines-yaml-option-label options)
      '("branches: dev"
        "branches: release/*"
        "branches: main")))
    (should
     (equal
      (mapcar #'bitbucket-devops-pipelines-yaml-option-branch options)
      '("dev" "release/*" "main")))
    (should
     (equal
      (bitbucket-devops-pipelines-yaml-option-deployments (car options))
      '("dev")))))

(ert-deftest bitbucket-devops-pipelines-yaml-accepts-explicit-merge-tags ()
  (let* ((config
          (bitbucket-devops-pipelines-yaml-parse-string
           (concat
            "definitions:
  step-config:
    runner: &runner
      runs-on: [self.hosted, linux]
      oidc: true
    scan:
      !!merge <<: *runner
      image: scan-image
"
            bitbucket-devops-pipelines-yaml-test--config)))
         (option
          (bitbucket-devops-pipelines-yaml-custom-option config "deploy prod/v1.0"))
         (variable (car (bitbucket-devops-pipelines-yaml-option-variables option))))
    (should
     (equal
      (mapcar #'bitbucket-devops-pipelines-yaml-option-label
              (bitbucket-devops-pipelines-yaml-manual-options config))
      '("default" "branches: main" "branches: release/*" "pull-requests: **"
        "custom: deploy prod/v1.0" "custom: no-vars")))
    (should
     (equal (bitbucket-devops-pipelines-yaml-variable-default variable) "us-east-1"))
    (should
     (equal (bitbucket-devops-pipelines-yaml-option-deployments option)
            '("production")))))

(ert-deftest bitbucket-devops-pipelines-yaml-preserves-tagged-merge-deployments ()
  (let ((config
         (bitbucket-devops-pipelines-yaml-parse-string
          "definitions:
  steps:
    - step: &deploy
        deployment: production
        script: [echo deploy]
pipelines:
  default:
    - step:
        !!merge <<: *deploy
        name: Default deployment
  custom:
    manual:
      - step:
          # Inherit the deployment from the same anchor.
          !!merge <<: *deploy
          name: Manual deployment
")))
    (should
     (equal (bitbucket-devops-pipelines-yaml-config-default-envs config)
            '("production")))
    (should
     (equal
      (bitbucket-devops-pipelines-yaml-option-deployments
       (bitbucket-devops-pipelines-yaml-custom-option config "manual"))
      '("production")))))

(ert-deftest bitbucket-devops-pipelines-yaml-preserves-merge-tags-in-scalar-text ()
  (let* ((config
          (bitbucket-devops-pipelines-yaml-parse-string
           "definitions:
  text: |
    !!merge <<: *runner
  runner: &runner
    oidc: true
  scan:
    !!merge <<: *runner
pipelines:
  custom:
    manual:
      - variables:
          - name: QUOTED
            default: \"!!merge <<: *runner\"
          - name: SINGLE_QUOTED
            default: '!!merge <<: *runner'
          - name: LITERAL
            default: |
              !!merge <<: *runner
          - name: FOLDED
            default: >-
              !!merge <<: *runner
          - name: MULTILINE_QUOTED
            default: \"first
              !!merge <<: *runner\"
      - step:
          !!merge <<: *runner
          script:
            - |
              !!merge <<: *runner
"))
         (variables
          (bitbucket-devops-pipelines-yaml-option-variables
           (bitbucket-devops-pipelines-yaml-custom-option config "manual"))))
    (should
     (equal (mapcar #'bitbucket-devops-pipelines-yaml-variable-default variables)
            '("!!merge <<: *runner" "!!merge <<: *runner"
              "!!merge <<: *runner\n" "!!merge <<: *runner"
              "first !!merge <<: *runner")))))

(ert-deftest bitbucket-devops-pipelines-yaml-still-rejects-malformed-yaml ()
  (dolist (string
           '("definitions:
  runner: &runner {oidc: true}
  scan:
    !!merge <<: *runner
pipelines:
  custom: [unterminated
"
             "definitions:
  runner: &runner {oidc: true}
  scan:
    !!MERGE <<: *runner
"))
    (let ((case-fold-search t))
      (should-error (bitbucket-devops-pipelines-yaml-parse-string string)))))

(provide 'bitbucket-devops-pipelines-yaml-test)
;;; bitbucket-devops-pipelines-yaml-test.el ends here
