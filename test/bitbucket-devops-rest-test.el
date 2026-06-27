;;; bitbucket-devops-rest-test.el --- Tests for the REST client -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'bitbucket-devops-rest)

(defconst bitbucket-devops-rest-test-fixtures-directory
  (expand-file-name
   "fixtures"
   (file-name-directory (or load-file-name buffer-file-name)))
  "Directory containing sanitized REST response fixtures.")

(defconst bitbucket-devops-rest-test-context
  '(:workspace "williseed1" :repo-slug "test")
  "Repository context used by REST credential tests.")

(defconst bitbucket-devops-rest-test-auth-rules
  '((:workspace "williseed1"
     :repo-slug "test"
     :auth-source-host "bitbucket-devops-williseed1-test"))
  "Authentication rules used by REST credential tests.")

(defun bitbucket-devops-rest-test-read-json-fixture (name)
  "Return JSON fixture NAME parsed as an alist."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name name bitbucket-devops-rest-test-fixtures-directory))
    (json-parse-buffer
     :object-type 'alist
     :array-type 'list
     :null-object nil
     :false-object nil)))

(ert-deftest bitbucket-devops-rest-credential-loads-access-token ()
  (let ((bitbucket-devops-auth-rules bitbucket-devops-rest-test-auth-rules))
    (cl-letf (((symbol-function 'auth-source-search)
               (lambda (&rest args)
                 (should
                  (equal
                   args
                   '(:host "bitbucket-devops-williseed1-test"
                     :max 1
                     :require (:user :secret))))
                 (list
                  (list :user "x-token-auth"
                        :secret (lambda () "access-secret"))))))
      (should
       (equal
        (bitbucket-devops-rest-credential bitbucket-devops-rest-test-context)
        '(:kind access-token :token "access-secret"))))))

(ert-deftest bitbucket-devops-rest-credential-loads-user-api-token ()
  (let ((bitbucket-devops-auth-rules bitbucket-devops-rest-test-auth-rules))
    (cl-letf (((symbol-function 'auth-source-search)
               (lambda (&rest _args)
                 (list
                  (list :user "user@example.com"
                        :secret "api-secret")))))
      (should
       (equal
        (bitbucket-devops-rest-credential bitbucket-devops-rest-test-context)
        '(:kind api-token :login "user@example.com" :token "api-secret"))))))

(ert-deftest bitbucket-devops-rest-credential-rejects-missing-token ()
  (let ((bitbucket-devops-auth-rules bitbucket-devops-rest-test-auth-rules))
    (cl-letf (((symbol-function 'auth-source-search)
               (lambda (&rest _args) nil)))
      (should-error
       (bitbucket-devops-rest-credential bitbucket-devops-rest-test-context)
       :type 'user-error))))

(ert-deftest bitbucket-devops-rest-auth-source-host-requires-rules ()
  (let ((bitbucket-devops-auth-rules nil))
    (should-error
     (bitbucket-devops-rest-auth-source-host bitbucket-devops-rest-test-context)
     :type 'user-error)))

(ert-deftest bitbucket-devops-rest-auth-source-host-requires-context ()
  (let ((bitbucket-devops-auth-rules bitbucket-devops-rest-test-auth-rules))
    (should-error
     (bitbucket-devops-rest-auth-source-host nil)
     :type 'user-error)))

(ert-deftest bitbucket-devops-rest-auth-source-host-prefers-repository-rule ()
  (let ((bitbucket-devops-auth-rules
         '((:workspace "williseed1"
            :auth-source-host "bitbucket-devops-williseed1")
           (:workspace "williseed1"
            :repo-slug "test"
            :auth-source-host "bitbucket-devops-williseed1-test"))))
    (should
     (equal
      (bitbucket-devops-rest-auth-source-host
       '(:workspace "williseed1" :repo-slug "test"))
      "bitbucket-devops-williseed1-test"))))

(ert-deftest bitbucket-devops-rest-auth-source-host-uses-workspace-rule ()
  (let ((bitbucket-devops-auth-rules
         '((:workspace "williseed1"
            :auth-source-host "bitbucket-devops-williseed1"))))
    (should
     (equal
      (bitbucket-devops-rest-auth-source-host
       '(:workspace "williseed1" :repo-slug "test"))
      "bitbucket-devops-williseed1"))))

(ert-deftest bitbucket-devops-rest-auth-source-host-fails-without-match ()
  (let ((bitbucket-devops-auth-rules
         '((:workspace "other-workspace"
            :auth-source-host "bitbucket-devops-other-workspace"))))
    (should-error
     (bitbucket-devops-rest-auth-source-host
      '(:workspace "williseed1" :repo-slug "test"))
     :type 'user-error)))

(ert-deftest bitbucket-devops-rest-credential-uses-matched-auth-source-host ()
  (let ((bitbucket-devops-auth-rules
         '((:workspace "williseed1"
            :repo-slug "test"
            :auth-source-host "bitbucket-devops-williseed1-test"))))
    (cl-letf (((symbol-function 'auth-source-search)
               (lambda (&rest args)
                 (should
                  (equal args
                         '(:host "bitbucket-devops-williseed1-test"
                           :max 1
                           :require (:user :secret))))
                 (list
                  (list :user "x-token-auth"
                        :secret (lambda () "access-secret"))))))
      (should
       (equal
        (bitbucket-devops-rest-credential
         '(:workspace "williseed1" :repo-slug "test"))
        '(:kind access-token :token "access-secret"))))))

(ert-deftest bitbucket-devops-rest-authorization-header-uses-bearer-token ()
  (should
   (equal
    (bitbucket-devops-rest-authorization-header
     '(:kind access-token :token "access-secret"))
    '("Authorization" . "Bearer access-secret"))))

(ert-deftest bitbucket-devops-rest-authorization-header-uses-basic-auth ()
  (should
   (equal
    (bitbucket-devops-rest-authorization-header
     '(:kind api-token :login "user@example.com" :token "api-secret"))
    (cons "Authorization"
          (concat
           "Basic "
           (base64-encode-string "user@example.com:api-secret" t))))))

(ert-deftest bitbucket-devops-rest-encode-path-segment-encodes-delimiters ()
  (should
   (equal
    (bitbucket-devops-rest-encode-path-segment "{pipeline uuid}/step")
    "%7Bpipeline%20uuid%7D%2Fstep")))

(ert-deftest bitbucket-devops-rest-repository-url-encodes-each-segment ()
  (should
   (equal
    (bitbucket-devops-rest-repository-url
     '(:workspace "team name" :repo-slug "repo/name")
     "pipelines"
     "{pipeline-uuid}"
     "steps")
    "https://api.bitbucket.org/2.0/repositories/team%20name/repo%2Fname/pipelines/%7Bpipeline-uuid%7D/steps")))

(ert-deftest bitbucket-devops-rest-validate-pagination-url-allows-api-host ()
  (let ((url "https://api.bitbucket.org/2.0/repositories/workspace/repository/pipelines/?page=2"))
    (should
     (equal
      (bitbucket-devops-rest-validate-pagination-url url)
      url))))

(ert-deftest bitbucket-devops-rest-validate-pagination-url-rejects-untrusted-urls ()
  (dolist (url '("http://api.bitbucket.org/2.0/repositories/workspace/repository"
                 "https://bitbucket.org/2.0/repositories/workspace/repository"
                 "https://api.bitbucket.org.example.com/2.0/repositories/workspace/repository"
                 "https://user@example.com@api.bitbucket.org/2.0/repositories/workspace/repository"
                 "https://api.bitbucket.org:444/2.0/repositories/workspace/repository"))
    (should-error
     (bitbucket-devops-rest-validate-pagination-url url)
     :type 'user-error)))

(ert-deftest bitbucket-devops-rest-validate-download-url-allows-https-host ()
  (let ((url
         "https://pipeline-logs.s3.amazonaws.com/build.log?X-Amz-Signature=test"))
    (should
     (equal (bitbucket-devops-rest-validate-download-url url) url))))

(ert-deftest bitbucket-devops-rest-validate-download-url-rejects-unsafe-urls ()
  (dolist (url '("http://pipeline-logs.s3.amazonaws.com/build.log"
                 "https://user@example.com/build.log"
                 "https://pipeline-logs.s3.amazonaws.com:444/build.log"))
    (should-error
     (bitbucket-devops-rest-validate-download-url url)
     :type 'user-error)))

(ert-deftest bitbucket-devops-rest-request-configures-asynchronous-json-post ()
  (let (observed)
    (cl-letf (((symbol-function 'bitbucket-devops-rest-credential)
               (lambda (&optional _context)
                 '(:kind access-token :token "access-secret")))
              ((symbol-function 'url-retrieve)
               (lambda (url callback callback-args silent inhibit-cookies)
                 (setq observed
                       (list
                        :url url
                        :callback callback
                        :callback-args callback-args
                        :silent silent
                        :inhibit-cookies inhibit-cookies
                        :method url-request-method
                        :headers url-request-extra-headers
                        :data url-request-data))
                 'request-process)))
      (should
       (eq
        (bitbucket-devops-rest-request
         "POST"
         "https://api.bitbucket.org/2.0/repositories/workspace/repository/pipelines/"
         #'ignore
         '((target . ((type . "pipeline_ref_target")))))
        'request-process))
      (should
       (equal
        observed
        '(:url "https://api.bitbucket.org/2.0/repositories/workspace/repository/pipelines/"
          :callback bitbucket-devops-rest--handle-response-or-redirect
          :callback-args
          (ignore nil "POST"
                  ((target (type . "pipeline_ref_target")))
                  nil 5
                  "https://api.bitbucket.org/2.0/repositories/workspace/repository/pipelines/")
          :silent t
          :inhibit-cookies t
          :method "POST"
          :headers (("Authorization" . "Bearer access-secret")
                    ("Accept" . "application/json")
                    ("Content-Type" . "application/json"))
          :data "{\"target\":{\"type\":\"pipeline_ref_target\"}}"))))))

(ert-deftest bitbucket-devops-rest-request-encodes-json-post-as-utf-8-bytes ()
  (let* ((description (concat "Bumped 9.0.0 " (string #x2192) " 16.0.0"))
         (data (bitbucket-devops-rest--json-request-data
                `((description . ,description)))))
    (should-not (multibyte-string-p data))
    (should
     (equal
      (alist-get
       'description
       (json-parse-string
        (decode-coding-string data 'utf-8)
        :object-type 'alist))
      description))))

(ert-deftest bitbucket-devops-rest-follows-trusted-get-redirect-with-auth ()
  (let ((buffer (generate-new-buffer " *bitbucket-rest-redirect*"))
        observed)
    (with-current-buffer buffer
      (insert
       "HTTP/1.1 302 Found\r\n"
       "Location: https://api.bitbucket.org/2.0/repositories/workspace/repository/diffstat/main..feature\r\n\r\n")
      (setq-local url-http-response-status 302)
      (setq-local url-http-end-of-headers
                  (save-excursion
                    (goto-char (point-min))
                    (search-forward "\r\n\r\n")
                    (point)))
      (cl-letf (((symbol-function 'bitbucket-devops-rest--request)
                 (lambda (&rest args) (setq observed args))))
        (bitbucket-devops-rest--handle-response-or-redirect
         '(:error (error http 302))
         #'ignore
         nil
         "GET"
         nil
         '(:workspace "workspace" :repo-slug "repository")
         5
         "https://api.bitbucket.org/2.0/repositories/workspace/repository/pullrequests/1/diffstat")))
    (should
     (equal
      observed
      '("GET"
        "https://api.bitbucket.org/2.0/repositories/workspace/repository/diffstat/main..feature"
        ignore
        nil
        nil
        (:workspace "workspace" :repo-slug "repository")
        4)))
    (should-not (buffer-live-p buffer))))

(ert-deftest bitbucket-devops-rest-follows-raw-download-without-auth ()
  (let ((buffer (generate-new-buffer " *bitbucket-rest-download-redirect*"))
        public-request
        authenticated-request)
    (with-current-buffer buffer
      (insert
       "HTTP/1.1 302 Found\r\n"
       "Location: https://pipeline-logs.s3.amazonaws.com/build.log?signature=test\r\n\r\n")
      (setq-local url-http-response-status 302)
      (setq-local url-http-end-of-headers
                  (save-excursion
                    (goto-char (point-min))
                    (search-forward "\r\n\r\n")
                    (point)))
      (cl-letf (((symbol-function 'bitbucket-devops-rest--public-request)
                 (lambda (&rest args) (setq public-request args)))
                ((symbol-function 'bitbucket-devops-rest--request)
                 (lambda (&rest args) (setq authenticated-request args))))
        (bitbucket-devops-rest--handle-response-or-redirect
         '(:error (error http 302))
         #'ignore
         t
         "GET"
         nil
         '(:workspace "workspace" :repo-slug "repository")
         5
         "https://api.bitbucket.org/2.0/repositories/workspace/repository/pipelines/1/steps/2/log")))
    (should
     (equal
      public-request
      '("GET"
        "https://pipeline-logs.s3.amazonaws.com/build.log?signature=test"
        ignore
        t
        4)))
    (should-not authenticated-request)
    (should-not (buffer-live-p buffer))))

(ert-deftest bitbucket-devops-rest-public-request-omits-authorization ()
  (let (observed)
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (url callback callback-args silent inhibit-cookies)
                 (setq observed
                       (list url callback callback-args silent inhibit-cookies
                             url-request-extra-headers))
                 nil)))
      (bitbucket-devops-rest--public-request
       "GET" "https://pipeline-logs.s3.amazonaws.com/build.log"
       #'ignore t 4))
    (should
     (equal
      observed
      '("https://pipeline-logs.s3.amazonaws.com/build.log"
        bitbucket-devops-rest--handle-public-response-or-redirect
        (ignore t "GET" 4
                "https://pipeline-logs.s3.amazonaws.com/build.log")
        t t
        (("Accept" . "text/plain")))))))

(ert-deftest bitbucket-devops-rest-request-disables-automatic-redirects-in-buffer ()
  (let ((request-buffer (generate-new-buffer " *bitbucket-request*")))
    (unwind-protect
        (cl-letf (((symbol-function 'bitbucket-devops-rest-credential)
                   (lambda (&optional _context)
                     '(:kind access-token :token "access-secret")))
                  ((symbol-function 'url-retrieve)
                   (lambda (&rest _args) request-buffer)))
          (should
           (eq
            (bitbucket-devops-rest-request
             "GET"
             "https://api.bitbucket.org/2.0/repositories/workspace/repository/pullrequests/3/diff"
             #'ignore)
            request-buffer))
          (with-current-buffer request-buffer
            (should (local-variable-p 'url-max-redirections))
            (should (zerop url-max-redirections))))
      (when (buffer-live-p request-buffer)
        (kill-buffer request-buffer)))))

(ert-deftest bitbucket-devops-rest-handle-response-parses-json-and-kills-buffer ()
  (let ((buffer (generate-new-buffer " *bitbucket-rest-json*"))
        callback-args)
    (with-current-buffer buffer
      (insert "HTTP/1.1 200 OK\r\n\r\n{\"value\":42}")
      (setq-local url-http-response-status 200)
      (setq-local url-http-end-of-headers
                  (save-excursion
                    (goto-char (point-min))
                    (search-forward "\r\n\r\n")
                    (point)))
      (bitbucket-devops-rest--handle-response
       nil
       (lambda (&rest args) (setq callback-args args))
       nil))
    (should (equal callback-args '(((value . 42)) nil)))
    (should-not (buffer-live-p buffer))))

(ert-deftest bitbucket-devops-rest-handle-response-preserves-raw-log ()
  (let ((buffer (generate-new-buffer " *bitbucket-rest-raw*"))
        callback-args)
    (with-current-buffer buffer
      (insert "HTTP/1.1 200 OK\r\n\r\nline one\nline two\n")
      (setq-local url-http-response-status 200)
      (setq-local url-http-end-of-headers
                  (save-excursion
                    (goto-char (point-min))
                    (search-forward "\r\n\r\n")
                    (point)))
      (bitbucket-devops-rest--handle-response
       nil
       (lambda (&rest args) (setq callback-args args))
       t))
    (should (equal callback-args '("line one\nline two\n" nil)))
    (should-not (buffer-live-p buffer))))

(ert-deftest bitbucket-devops-rest-handle-response-allows-empty-success ()
  (let ((buffer (generate-new-buffer " *bitbucket-rest-empty*"))
        callback-args)
    (with-current-buffer buffer
      (insert "HTTP/1.1 204 No Content\r\n\r\n\n")
      (setq-local url-http-response-status 204)
      (setq-local url-http-end-of-headers
                  (save-excursion
                    (goto-char (point-min))
                    (search-forward "\r\n\r\n")
                    (point)))
      (bitbucket-devops-rest--handle-response
       nil
       (lambda (&rest args) (setq callback-args args))
       nil))
    (should (equal callback-args '(nil nil)))
    (should-not (buffer-live-p buffer))))

(ert-deftest bitbucket-devops-rest-handle-response-normalizes-network-error ()
  (let ((buffer (generate-new-buffer " *bitbucket-rest-network*"))
        callback-args)
    (with-current-buffer buffer
      (bitbucket-devops-rest--handle-response
       '(:error (error connection-failed "network is down"))
       (lambda (&rest args) (setq callback-args args))
       nil))
    (should-not (car callback-args))
    (should (eq (plist-get (cadr callback-args) :type) 'network))
    (should-not (buffer-live-p buffer))))

(ert-deftest bitbucket-devops-rest-handle-response-normalizes-status-http-error ()
  (let ((buffer (generate-new-buffer " *bitbucket-rest-status-http*"))
        callback-args)
    (with-current-buffer buffer
      (bitbucket-devops-rest--handle-response
       '(:error (error http 404))
       (lambda (&rest args) (setq callback-args args))
       nil))
    (should-not (car callback-args))
    (should (eq (plist-get (cadr callback-args) :type) 'http))
    (should (= (plist-get (cadr callback-args) :status) 404))
    (should-not (buffer-live-p buffer))))

(ert-deftest bitbucket-devops-rest-handle-response-normalizes-http-error ()
  (let ((buffer (generate-new-buffer " *bitbucket-rest-http*"))
        callback-args)
    (with-current-buffer buffer
      (insert "HTTP/1.1 401 Unauthorized\r\n\r\n{\"error\":\"unauthorized\"}")
      (setq-local url-http-response-status 401)
      (setq-local url-http-end-of-headers
                  (save-excursion
                    (goto-char (point-min))
                    (search-forward "\r\n\r\n")
                    (point)))
      (bitbucket-devops-rest--handle-response
       nil
       (lambda (&rest args) (setq callback-args args))
       nil))
    (should-not (car callback-args))
    (should (eq (plist-get (cadr callback-args) :type) 'http))
    (should (= (plist-get (cadr callback-args) :status) 401))
    (should-not (buffer-live-p buffer))))

(ert-deftest bitbucket-devops-rest-handle-response-uses-bitbucket-error-message ()
  (let ((buffer (generate-new-buffer " *bitbucket-rest-http-message*"))
        callback-args)
    (with-current-buffer buffer
      (insert "HTTP/1.1 400 Bad Request\r\n\r\n"
              "{\"type\":\"error\",\"error\":{\"message\":\"Pipeline already completed\"}}")
      (setq-local url-http-response-status 400)
      (setq-local url-http-end-of-headers
                  (save-excursion
                    (goto-char (point-min))
                    (search-forward "\r\n\r\n")
                    (point)))
      (bitbucket-devops-rest--handle-response
       nil
       (lambda (&rest args) (setq callback-args args))
       nil))
    (should-not (car callback-args))
    (should (eq (plist-get (cadr callback-args) :type) 'http))
    (should (= (plist-get (cadr callback-args) :status) 400))
    (should
     (equal
      (plist-get (cadr callback-args) :message)
      "Pipeline already completed"))
    (should-not (buffer-live-p buffer))))

(ert-deftest bitbucket-devops-rest-handle-response-normalizes-malformed-json ()
  (let ((buffer (generate-new-buffer " *bitbucket-rest-malformed*"))
        callback-args)
    (with-current-buffer buffer
      (insert "HTTP/1.1 200 OK\r\n\r\n{not-json}")
      (setq-local url-http-response-status 200)
      (setq-local url-http-end-of-headers
                  (save-excursion
                    (goto-char (point-min))
                    (search-forward "\r\n\r\n")
                    (point)))
      (bitbucket-devops-rest--handle-response
       nil
       (lambda (&rest args) (setq callback-args args))
       nil))
    (should-not (car callback-args))
    (should (eq (plist-get (cadr callback-args) :type) 'malformed-response))
    (should-not (buffer-live-p buffer))))

(ert-deftest bitbucket-devops-rest-page-values-returns-recorded-pipelines ()
  (let ((page
         (bitbucket-devops-rest-test-read-json-fixture
          "pipelines-page-1.json")))
    (should
     (equal
      (mapcar
       (lambda (pipeline) (alist-get 'build_number pipeline))
       (bitbucket-devops-rest-page-values page))
      '(12)))))

(ert-deftest bitbucket-devops-rest-page-next-validates-recorded-link ()
  (let ((page
         (bitbucket-devops-rest-test-read-json-fixture
          "pipelines-page-1.json")))
    (should
     (equal
      (bitbucket-devops-rest-page-next page)
      "https://api.bitbucket.org/2.0/repositories/williseed1/test/pipelines?page=2"))))

(ert-deftest bitbucket-devops-rest-page-next-allows-final-page ()
  (let ((page
         (bitbucket-devops-rest-test-read-json-fixture
          "pipelines-page-2.json")))
    (should-not (bitbucket-devops-rest-page-next page))))

(ert-deftest bitbucket-devops-rest-page-next-rejects-untrusted-link ()
  (should-error
   (bitbucket-devops-rest-page-next
    '((next . "https://example.com/steal-credential")))
   :type 'user-error))

(ert-deftest bitbucket-devops-rest-list-pipelines-requests-first-page ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        observed)
    (cl-letf (((symbol-function 'bitbucket-devops-rest-request)
               (lambda (&rest args) (setq observed args) 'request-process)))
      (should
       (eq
        (bitbucket-devops-rest-list-pipelines
         context
         #'ignore)
        'request-process))
      (should
       (equal
        observed
        (list
         "GET"
         "https://api.bitbucket.org/2.0/repositories/williseed1/test/pipelines?sort=-created_on"
         #'ignore
         nil
         nil
         context))))))

(ert-deftest bitbucket-devops-rest-list-pipelines-requests-next-page ()
  (let ((next
         "https://api.bitbucket.org/2.0/repositories/williseed1/test/pipelines?page=2")
        (context '(:workspace "ignored" :repo-slug "ignored"))
        observed)
    (cl-letf (((symbol-function 'bitbucket-devops-rest-request)
               (lambda (&rest args) (setq observed args) 'request-process)))
      (bitbucket-devops-rest-list-pipelines
       context
       #'ignore
       next)
      (should
       (equal observed
              (list "GET" (concat next "&sort=-created_on") #'ignore
                    nil nil context))))))

(ert-deftest bitbucket-devops-rest-list-paused-pipelines-filters-statuses ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        observed)
    (cl-letf (((symbol-function 'bitbucket-devops-rest-request)
               (lambda (&rest args) (setq observed args) 'request-process)))
      (bitbucket-devops-rest-list-paused-pipelines context #'ignore)
      (should
       (equal
        observed
        (list
         "GET"
         (concat
          "https://api.bitbucket.org/2.0/repositories/williseed1/test/pipelines"
          "?status=PAUSED,HALTED&sort=-created_on")
         #'ignore
         nil
         nil
         context))))))

(ert-deftest bitbucket-devops-rest-list-pipelines-for-commit-filters-history ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        observed)
    (cl-letf (((symbol-function 'bitbucket-devops-rest-request)
               (lambda (&rest args) (setq observed args) 'request-process)))
      (bitbucket-devops-rest-list-pipelines-for-commit
       context
       "commit/hash"
       #'ignore)
      (should
       (equal
        observed
        (list
         "GET"
         "https://api.bitbucket.org/2.0/repositories/williseed1/test/pipelines?target.commit.hash=commit%2Fhash&sort=-created_on"
         #'ignore
         nil
         nil
         context))))))

(ert-deftest bitbucket-devops-rest-get-pipeline-encodes-uuid ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        observed)
    (cl-letf (((symbol-function 'bitbucket-devops-rest-request)
               (lambda (&rest args) (setq observed args) 'request-process)))
      (bitbucket-devops-rest-get-pipeline
       context
       "{pipeline-12}"
       #'ignore)
      (should
       (equal
        observed
        (list
         "GET"
         "https://api.bitbucket.org/2.0/repositories/williseed1/test/pipelines/%7Bpipeline-12%7D"
         #'ignore
         nil
         nil
         context))))))

(ert-deftest bitbucket-devops-rest-get-commit-encodes-hash ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        observed)
    (cl-letf (((symbol-function 'bitbucket-devops-rest-request)
               (lambda (&rest args) (setq observed args) 'request-process)))
      (bitbucket-devops-rest-get-commit
       context
       "commit/hash"
       #'ignore)
      (should
       (equal
        observed
        (list
         "GET"
         "https://api.bitbucket.org/2.0/repositories/williseed1/test/commit/commit%2Fhash"
         #'ignore
         nil
         nil
         context))))))

(ert-deftest bitbucket-devops-rest-list-steps-requests-next-page ()
  (let ((next
         "https://api.bitbucket.org/2.0/repositories/williseed1/test/pipelines/%7Bpipeline-12%7D/steps?page=2")
        (context '(:workspace "ignored" :repo-slug "ignored"))
        observed)
    (cl-letf (((symbol-function 'bitbucket-devops-rest-request)
               (lambda (&rest args) (setq observed args) 'request-process)))
      (bitbucket-devops-rest-list-steps
       context
       "{ignored}"
       #'ignore
       next)
      (should
       (equal observed (list "GET" next #'ignore nil nil context))))))

(ert-deftest bitbucket-devops-rest-list-deployments-filters-pipeline ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        observed)
    (cl-letf (((symbol-function 'bitbucket-devops-rest-request)
               (lambda (&rest args) (setq observed args) 'request-process)))
      (should
       (eq
        (bitbucket-devops-rest-list-deployments
         context
         "{pipeline-12}"
         #'ignore)
        'request-process))
      (should
       (equal
        observed
        (list
         "GET"
         "https://api.bitbucket.org/2.0/repositories/williseed1/test/deployments?q=deployable.pipeline.uuid%3D%22%7Bpipeline-12%7D%22"
         #'ignore
         nil
         nil
         context))))))

(ert-deftest bitbucket-devops-rest-list-deployments-requests-next-page ()
  (let ((next
         "https://api.bitbucket.org/2.0/repositories/williseed1/test/deployments?page=2")
        (context '(:workspace "ignored" :repo-slug "ignored"))
        observed)
    (cl-letf (((symbol-function 'bitbucket-devops-rest-request)
               (lambda (&rest args) (setq observed args) 'request-process)))
      (bitbucket-devops-rest-list-deployments
       context
       "{ignored}"
       #'ignore
       next)
      (should
       (equal observed (list "GET" next #'ignore nil nil context))))))

(ert-deftest bitbucket-devops-rest-get-step-log-requests-raw-response ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        observed)
    (cl-letf (((symbol-function 'bitbucket-devops-rest-request)
               (lambda (&rest args) (setq observed args) 'request-process)))
      (bitbucket-devops-rest-get-step-log
       context
       "{pipeline-12}"
       "{step-1}"
       #'ignore)
      (should
       (equal
        observed
        (list
         "GET"
         "https://api.bitbucket.org/2.0/repositories/williseed1/test/pipelines/%7Bpipeline-12%7D/steps/%7Bstep-1%7D/log"
         #'ignore
         nil
         t
         context))))))

(ert-deftest bitbucket-devops-rest-run-pipeline-posts-payload ()
  (let ((body '((target . ((type . "pipeline_ref_target")))))
        (context '(:workspace "williseed1" :repo-slug "test"))
        observed)
    (cl-letf (((symbol-function 'bitbucket-devops-rest-request)
               (lambda (&rest args) (setq observed args) 'request-process)))
      (bitbucket-devops-rest-run-pipeline
       context
       body
       #'ignore)
      (should
       (equal
        observed
        (list
         "POST"
         "https://api.bitbucket.org/2.0/repositories/williseed1/test/pipelines"
         #'ignore
         body
         nil
         context))))))

(ert-deftest bitbucket-devops-rest-stop-pipeline-posts-action ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        observed)
    (cl-letf (((symbol-function 'bitbucket-devops-rest-request)
               (lambda (&rest args) (setq observed args) 'request-process)))
      (bitbucket-devops-rest-stop-pipeline
       context
       "{pipeline-12}"
       #'ignore)
      (should
       (equal
        observed
        (list
         "POST"
         "https://api.bitbucket.org/2.0/repositories/williseed1/test/pipelines/%7Bpipeline-12%7D/stopPipeline"
         #'ignore
         nil
         nil
         context))))))

(ert-deftest bitbucket-devops-rest-start-step-posts-internal-action ()
  (let ((context '(:workspace "williseed1" :repo-slug "test"))
        observed)
    (cl-letf (((symbol-function 'bitbucket-devops-rest-request)
               (lambda (&rest args) (setq observed args) 'request-process)))
      (bitbucket-devops-rest-start-step
       context
       "{pipeline-12}"
       "{step-2}"
       #'ignore)
      (should
       (equal
        observed
        (list
         "POST"
         "https://api.bitbucket.org/internal/repositories/williseed1/test/pipelines/%7Bpipeline-12%7D/steps/%7Bstep-2%7D/start_step"
         #'ignore
         nil
         nil
         context))))))

(provide 'bitbucket-devops-rest-test)
;;; bitbucket-devops-rest-test.el ends here
