;;; bitbucket-devops-rest.el --- Asynchronous Bitbucket Cloud REST client -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Will Bosch-Bello <williamsbosch@gmail.com>
;; Keywords: tools, vc

;;; Commentary:

;; Authenticate and communicate with the Bitbucket Cloud REST API.

;;; Code:

(require 'auth-source)
(require 'json)
(require 'mail-utils)
(require 'subr-x)
(require 'url)
(require 'url-http)
(require 'url-parse)
(require 'url-util)

(defvar url-http-end-of-headers)
(defvar url-http-response-status)

(defconst bitbucket-devops-rest-api-host "api.bitbucket.org"
  "Bitbucket Cloud API host.")

(defconst bitbucket-devops-rest-api-base-url
  "https://api.bitbucket.org/2.0/repositories"
  "Bitbucket Cloud repositories API base URL.")

(defcustom bitbucket-devops-rest-internal-api-base-url
  "https://api.bitbucket.org/internal/repositories"
  "Bitbucket Cloud internal repositories API base URL.

This is used only for pipeline actions that Bitbucket exposes in the web UI
but has not added to the public 2.0 API yet."
  :type 'string
  :group 'bitbucket-devops)

(defconst bitbucket-devops-rest-max-redirects 5
  "Maximum trusted redirects followed for one Bitbucket GET request.")

(defconst bitbucket-devops-rest-pipeline-sort-query "sort=-created_on"
  "Query parameter that requests newest-first pipeline history.")

(defconst bitbucket-devops-rest-paused-status-query
  "status=PAUSED,HALTED"
  "Query parameter matching Bitbucket's paused pipeline statuses.")

(defcustom bitbucket-devops-auth-rules nil
  "Rules for selecting Bitbucket credentials by workspace and repository.

Each rule is a plist.  The `:auth-source-host' value names the auth-source
entry to use for matching repositories.  Repository-specific rules include
`:workspace' and `:repo-slug'; workspace rules include only `:workspace'.

At least one rule is required.  Requests fail closed when no rule matches the
current repository."
  :type '(repeat sexp)
  :group 'bitbucket-devops)

(defun bitbucket-devops-rest--json-request-data (body)
  "Return BODY serialized as unibyte UTF-8 JSON for `url-request-data'."
  (encode-coding-string (json-serialize body) 'utf-8))

(defun bitbucket-devops-rest--secret-value (secret)
  "Return the string value represented by auth-source SECRET."
  (let ((value (if (functionp secret) (funcall secret) secret)))
    (unless (and (stringp value) (not (string-empty-p value)))
      (user-error "Bitbucket credential in auth-source has no token"))
    value))

(defun bitbucket-devops-rest--rule-specificity (rule)
  "Return the match specificity for auth RULE."
  (cond
   ((and (plist-get rule :workspace) (plist-get rule :repo-slug)) 2)
   ((plist-get rule :workspace) 1)
   (t 0)))

(defun bitbucket-devops-rest--auth-rule-match-p (rule context)
  "Return non-nil when auth RULE applies to repository CONTEXT."
  (let ((workspace (plist-get rule :workspace))
        (repo-slug (plist-get rule :repo-slug)))
    (and
     (or (null workspace)
         (equal workspace (plist-get context :workspace)))
     (or (null repo-slug)
         (and workspace
              (equal repo-slug (plist-get context :repo-slug)))))))

(defun bitbucket-devops-rest--auth-rule-host (rule)
  "Return RULE's auth-source host after validation."
  (let ((host (plist-get rule :auth-source-host)))
    (unless (and (stringp host) (not (string-empty-p host)))
      (user-error "Bitbucket auth rule has no :auth-source-host"))
    host))

(defun bitbucket-devops-rest-auth-source-host (context)
  "Return the auth-source host to use for CONTEXT."
  (unless context
    (user-error "Bitbucket authentication requires a repository context"))
  (let ((best nil)
        (best-specificity -1))
    (dolist (rule bitbucket-devops-auth-rules)
      (when (bitbucket-devops-rest--auth-rule-match-p rule context)
        (let ((specificity (bitbucket-devops-rest--rule-specificity rule)))
          (when (> specificity best-specificity)
            (setq best rule
                  best-specificity specificity)))))
    (if best
        (bitbucket-devops-rest--auth-rule-host best)
      (user-error
       "No Bitbucket auth rule configured for %s/%s"
       (plist-get context :workspace)
       (plist-get context :repo-slug)))))

(defun bitbucket-devops-rest-credential (context)
  "Return the configured Bitbucket Cloud credential.

Return a plist describing either a resource access token or a user API token.
The token remains internal to the REST client and must not be logged."
  (let* ((host (bitbucket-devops-rest-auth-source-host context))
         (match
         (car
          (auth-source-search
           :host host
           :max 1
           :require '(:user :secret)))))
    (unless match
      (user-error
       "No Bitbucket token found in auth-source for %s" host))
    (let ((login (plist-get match :user))
          (token
           (bitbucket-devops-rest--secret-value
            (plist-get match :secret))))
      (unless (and (stringp login) (not (string-empty-p login)))
        (user-error "Bitbucket credential in auth-source has no login"))
      (if (equal login "x-token-auth")
          (list :kind 'access-token :token token)
        (list :kind 'api-token :login login :token token)))))

(defun bitbucket-devops-rest-authorization-header (credential)
  "Return an HTTP Authorization header for CREDENTIAL."
  (let ((kind (plist-get credential :kind))
        (login (plist-get credential :login))
        (token (plist-get credential :token)))
    (unless (and (stringp token) (not (string-empty-p token)))
      (user-error "Bitbucket credential has no token"))
    (cons
     "Authorization"
     (pcase kind
       ('access-token (concat "Bearer " token))
       ('api-token
        (unless (and (stringp login) (not (string-empty-p login)))
          (user-error "Bitbucket API token credential has no login"))
        (concat "Basic "
                (base64-encode-string (concat login ":" token) t)))
       (_ (user-error "Unsupported Bitbucket credential kind"))))))

(defun bitbucket-devops-rest-encode-path-segment (segment)
  "Return SEGMENT encoded for use as one URL path segment."
  (unless (stringp segment)
    (user-error "Bitbucket API path segment must be a string"))
  (url-hexify-string segment))

(defun bitbucket-devops-rest-repository-url (context &rest segments)
  "Return a repository API URL for CONTEXT and SEGMENTS."
  (let ((all-segments
         (append
          (list
           (plist-get context :workspace)
           (plist-get context :repo-slug))
          segments)))
    (concat
     bitbucket-devops-rest-api-base-url
     "/"
     (mapconcat #'bitbucket-devops-rest-encode-path-segment
                all-segments
                "/"))))

(defun bitbucket-devops-rest-internal-repository-url
    (context &rest segments)
  "Return an internal repository API URL for CONTEXT and SEGMENTS."
  (let ((all-segments
         (append
          (list
           (plist-get context :workspace)
           (plist-get context :repo-slug))
          segments)))
    (concat
     bitbucket-devops-rest-internal-api-base-url
     "/"
     (mapconcat #'bitbucket-devops-rest-encode-path-segment
                all-segments
                "/"))))

(defun bitbucket-devops-rest-validate-pagination-url (url)
  "Return URL when it is a trusted Bitbucket Cloud pagination URL."
  (unless (stringp url)
    (user-error "Bitbucket pagination URL must be a string"))
  (let ((parsed (url-generic-parse-url url)))
    (unless (and (equal (url-type parsed) "https")
                 (equal (url-host parsed) bitbucket-devops-rest-api-host)
                 (= (url-port parsed) 443)
                 (not (url-user parsed))
                 (not (url-password parsed)))
      (user-error "Refusing untrusted Bitbucket pagination URL"))
    url))

(defun bitbucket-devops-rest-validate-download-url (url)
  "Return URL when it is safe for a credential-free HTTPS download."
  (unless (stringp url)
    (user-error "Bitbucket download URL must be a string"))
  (let ((parsed (url-generic-parse-url url)))
    (unless (and (equal (url-type parsed) "https")
                 (stringp (url-host parsed))
                 (not (string-empty-p (url-host parsed)))
                 (= (url-port parsed) 443)
                 (not (url-user parsed))
                 (not (url-password parsed)))
      (user-error "Refusing unsafe Bitbucket download URL"))
    url))

(defun bitbucket-devops-rest--response-body ()
  "Return the current URL response buffer body as a string."
  (unless (integer-or-marker-p url-http-end-of-headers)
    (error "Bitbucket response has no HTTP header boundary"))
  (goto-char url-http-end-of-headers)
  (buffer-substring-no-properties (point) (point-max)))

(defun bitbucket-devops-rest--parse-json-response ()
  "Return the current URL response buffer body parsed as JSON."
  (unless (integer-or-marker-p url-http-end-of-headers)
    (error "Bitbucket response has no HTTP header boundary"))
  (goto-char url-http-end-of-headers)
  (skip-chars-forward " \t\r\n")
  (if (eobp)
      nil
    (json-parse-buffer
     :object-type 'alist
     :array-type 'list
     :null-object nil
     :false-object nil)))

(defun bitbucket-devops-rest--json-error-message-value (value)
  "Return the best user-facing error message found in JSON VALUE."
  (cond
   ((null value) nil)
   ((and (stringp value) (not (string-empty-p value)))
    value)
   ((listp value)
    (or (bitbucket-devops-rest--json-error-message-value
         (alist-get 'message value))
        (bitbucket-devops-rest--json-error-message-value
         (alist-get 'detail value))
        (bitbucket-devops-rest--json-error-message-value
         (alist-get 'error value))))
   (t nil)))

(defun bitbucket-devops-rest--http-error-message ()
  "Return a Bitbucket HTTP error message parsed from the response body."
  (condition-case nil
      (bitbucket-devops-rest--json-error-message-value
       (bitbucket-devops-rest--parse-json-response))
    (error nil)))

(defun bitbucket-devops-rest--http-error (status)
  "Return a normalized HTTP error plist for STATUS."
  (list :type 'http
        :status status
        :message
        (or (bitbucket-devops-rest--http-error-message)
            "Bitbucket API request failed")))

(defun bitbucket-devops-rest--status-http-error-code (status)
  "Return the HTTP error code represented by callback STATUS, or nil."
  (let ((error-value (plist-get status :error)))
    (when (and (listp error-value)
               (eq (car error-value) 'error)
               (eq (cadr error-value) 'http)
               (integerp (caddr error-value)))
      (caddr error-value))))

(defun bitbucket-devops-rest--handle-response (status callback raw)
  "Normalize the current response STATUS and invoke CALLBACK.

CALLBACK receives two arguments: a result and an error plist.  The error is nil
on success; a successful empty response may also have a nil result.  Return raw
response text instead of parsing JSON when RAW is non-nil."
  (let ((buffer (current-buffer)))
    (unwind-protect
        (let* ((status-http-error
                (bitbucket-devops-rest--status-http-error-code status))
               (response
               (cond
                (status-http-error
                 (list nil
                       (bitbucket-devops-rest--http-error
                        status-http-error)))
                ((plist-get status :error)
                 (list nil
                       (list :type 'network
                             :message "Bitbucket network request failed")))
                ((not (integerp url-http-response-status))
                 (list nil
                       (list :type 'malformed-response
                             :message "Bitbucket response has no HTTP status")))
                ((not (<= 200 url-http-response-status 299))
                 (list nil
                       (bitbucket-devops-rest--http-error
                        url-http-response-status)))
                (t
                 (condition-case _error
                     (list
                      (if raw
                          (bitbucket-devops-rest--response-body)
                        (bitbucket-devops-rest--parse-json-response))
                      nil)
                   (error
                    (list nil
                          (list :type 'malformed-response
                                :message
                                "Unable to parse Bitbucket API response"))))))))
          (funcall callback (car response) (cadr response)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun bitbucket-devops-rest--response-location ()
  "Return the current HTTP response Location header, or nil."
  (when (integer-or-marker-p url-http-end-of-headers)
    (save-restriction
      (widen)
      (narrow-to-region (point-min) url-http-end-of-headers)
      (mail-fetch-field "Location"))))

(defun bitbucket-devops-rest--redirect-response-p (method)
  "Return non-nil when the current response is a redirect for METHOD."
  (and (equal method "GET")
       (integerp url-http-response-status)
       (<= 300 url-http-response-status 399)))

(defun bitbucket-devops-rest--handle-public-response-or-redirect
    (status callback raw method redirects-left request-url)
  "Handle a public response or follow a credential-free HTTPS redirect."
  (if-let* (((bitbucket-devops-rest--redirect-response-p method))
            ((> redirects-left 0))
            (location (bitbucket-devops-rest--response-location))
            (target (url-expand-file-name location request-url)))
      (let ((buffer (current-buffer)))
        (unwind-protect
            (condition-case redirect-error
                (progn
                  (bitbucket-devops-rest-validate-download-url target)
                  (bitbucket-devops-rest--public-request
                   method target callback raw (1- redirects-left)))
              (user-error
               (funcall
                callback nil
                (list :type 'unsafe-redirect
                      :message (error-message-string redirect-error)))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer))))
    (bitbucket-devops-rest--handle-response status callback raw)))

(defun bitbucket-devops-rest--public-request
    (method url callback raw redirects-left)
  "Send a credential-free METHOD request to URL and invoke CALLBACK."
  (let* ((url-request-method method)
         (url-request-extra-headers '(("Accept" . "text/plain")))
         (url-request-data nil)
         (request-buffer
          (url-retrieve
           url
           #'bitbucket-devops-rest--handle-public-response-or-redirect
           (list callback raw method redirects-left url)
           t
           t)))
    (when (buffer-live-p request-buffer)
      (with-current-buffer request-buffer
        (setq-local url-max-redirections 0)))
    request-buffer))

(defun bitbucket-devops-rest--handle-response-or-redirect
    (status callback raw method body context redirects-left request-url)
  "Handle a response or follow one trusted redirect from REQUEST-URL."
  (if-let* (((bitbucket-devops-rest--redirect-response-p method))
            ((> redirects-left 0))
            (location (bitbucket-devops-rest--response-location))
            (target (url-expand-file-name location request-url)))
      (let ((buffer (current-buffer)))
        (unwind-protect
            (condition-case redirect-error
                (if raw
                    (condition-case nil
                        (progn
                          (bitbucket-devops-rest-validate-pagination-url
                           target)
                          (bitbucket-devops-rest--request
                           method target callback body raw context
                           (1- redirects-left)))
                      (user-error
                       (bitbucket-devops-rest-validate-download-url target)
                       (bitbucket-devops-rest--public-request
                        method target callback raw (1- redirects-left))))
                  (bitbucket-devops-rest-validate-pagination-url target)
                  (bitbucket-devops-rest--request
                   method target callback body raw context
                   (1- redirects-left)))
              (user-error
               (funcall
                callback nil
                (list :type 'unsafe-redirect
                      :message (error-message-string redirect-error)))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer))))
    (bitbucket-devops-rest--handle-response status callback raw)))

(defun bitbucket-devops-rest--request
    (method url callback body raw context redirects-left)
  "Send one authenticated request, preserving auth across trusted redirects."
  (let* ((credential (bitbucket-devops-rest-credential context))
         (url-request-method method)
         (url-request-extra-headers
          (append
           (list
            (bitbucket-devops-rest-authorization-header credential)
            '("Accept" . "application/json"))
           (when body
             '(("Content-Type" . "application/json")))))
         (url-request-data
          (when body
            (bitbucket-devops-rest--json-request-data body)))
         (request-buffer
          (url-retrieve
           url
           #'bitbucket-devops-rest--handle-response-or-redirect
           (list callback raw method body context redirects-left url)
           t
           t)))
    (when (buffer-live-p request-buffer)
      (with-current-buffer request-buffer
        (setq-local url-max-redirections 0)))
    request-buffer))

(defun bitbucket-devops-rest-request
    (method url callback &optional body raw context)
  "Asynchronously send a Bitbucket API request.

METHOD and URL identify the request.  CALLBACK receives a result and an error
plist.  Encode BODY as JSON when non-nil.  Return raw response text when RAW is
  non-nil.  Use CONTEXT to select the repository credential configured by
`bitbucket-devops-auth-rules'."
  (bitbucket-devops-rest-validate-pagination-url url)
  (bitbucket-devops-rest--request
   method
   url
   callback
   body
   raw
   context
   bitbucket-devops-rest-max-redirects))

(defun bitbucket-devops-rest-page-values (page)
  "Return the resource values contained in paginated response PAGE."
  (alist-get 'values page))

(defun bitbucket-devops-rest-page-next (page)
  "Return PAGE's trusted next URL, or nil when PAGE is final."
  (when-let ((next (alist-get 'next page)))
    (bitbucket-devops-rest-validate-pagination-url next)))

(defun bitbucket-devops-rest--page-url (default-url next-url)
  "Return NEXT-URL after validation, or DEFAULT-URL when NEXT-URL is nil."
  (if next-url
      (bitbucket-devops-rest-validate-pagination-url next-url)
    default-url))

(defun bitbucket-devops-rest--with-pipeline-sort (url)
  "Return URL with an explicit newest-first pipeline sort parameter."
  (if (string-match-p "\\(?:[?&]\\)sort=" url)
      url
    (concat url
            (if (string-match-p "\\?" url) "&" "?")
            bitbucket-devops-rest-pipeline-sort-query)))

(defun bitbucket-devops-rest-list-pipelines (context callback &optional next-url)
  "Asynchronously list pipelines for CONTEXT and invoke CALLBACK.

Request NEXT-URL instead of the first page when it is non-nil."
  (bitbucket-devops-rest-request
   "GET"
   (bitbucket-devops-rest--with-pipeline-sort
    (bitbucket-devops-rest--page-url
     (bitbucket-devops-rest-repository-url context "pipelines")
     next-url))
   callback
   nil
   nil
   context))

(defun bitbucket-devops-rest-list-paused-pipelines
    (context callback &optional next-url)
  "Asynchronously list paused pipelines for CONTEXT and invoke CALLBACK.

Request NEXT-URL instead of the first paused page when it is non-nil."
  (bitbucket-devops-rest-request
   "GET"
   (bitbucket-devops-rest--with-pipeline-sort
    (bitbucket-devops-rest--page-url
     (concat
      (bitbucket-devops-rest-repository-url context "pipelines")
      "?"
      bitbucket-devops-rest-paused-status-query)
     next-url))
   callback
   nil
   nil
   context))

(defun bitbucket-devops-rest-list-pipelines-for-commit
    (context commit callback)
  "Invoke CALLBACK asynchronously with pipelines for CONTEXT filtered by COMMIT."
  (bitbucket-devops-rest-request
   "GET"
   (concat
    (bitbucket-devops-rest-repository-url context "pipelines")
    "?target.commit.hash="
    (url-hexify-string commit)
    "&"
    bitbucket-devops-rest-pipeline-sort-query)
   callback
   nil
   nil
   context))

(defun bitbucket-devops-rest-get-pipeline (context pipeline-uuid callback)
  "Asynchronously retrieve PIPELINE-UUID for CONTEXT and invoke CALLBACK."
  (bitbucket-devops-rest-request
   "GET"
   (bitbucket-devops-rest-repository-url
    context
    "pipelines"
    pipeline-uuid)
   callback
   nil
   nil
   context))

(defun bitbucket-devops-rest-get-commit (context commit callback)
  "Asynchronously retrieve COMMIT for CONTEXT and invoke CALLBACK."
  (bitbucket-devops-rest-request
   "GET"
   (bitbucket-devops-rest-repository-url
    context
    "commit"
    commit)
   callback
   nil
   nil
   context))

(defun bitbucket-devops-rest-list-steps
    (context pipeline-uuid callback &optional next-url)
  "Invoke CALLBACK asynchronously with PIPELINE-UUID step records for CONTEXT.

Request NEXT-URL instead of the first page when it is non-nil."
  (bitbucket-devops-rest-request
   "GET"
   (bitbucket-devops-rest--page-url
    (bitbucket-devops-rest-repository-url
     context
     "pipelines"
     pipeline-uuid
     "steps")
    next-url)
   callback
   nil
   nil
   context))

(defun bitbucket-devops-rest-list-deployments
    (context pipeline-uuid callback &optional next-url)
  "Invoke CALLBACK asynchronously with PIPELINE-UUID deployments for CONTEXT.

Request NEXT-URL instead of the first page when it is non-nil."
  (bitbucket-devops-rest-request
   "GET"
   (bitbucket-devops-rest--page-url
    (concat
     (bitbucket-devops-rest-repository-url context "deployments")
     "?q="
     (url-hexify-string
      (format "deployable.pipeline.uuid=\"%s\"" pipeline-uuid)))
    next-url)
   callback
   nil
   nil
   context))

(defun bitbucket-devops-rest-get-step-log
    (context pipeline-uuid step-uuid callback)
  "Invoke CALLBACK asynchronously with raw STEP-UUID log text.

CONTEXT and PIPELINE-UUID identify the pipeline run."
  (bitbucket-devops-rest-request
   "GET"
   (bitbucket-devops-rest-repository-url
    context
    "pipelines"
    pipeline-uuid
    "steps"
    step-uuid
    "log")
   callback
   nil
   t
   context))

(defun bitbucket-devops-rest-run-pipeline (context body callback)
  "Asynchronously create a pipeline in CONTEXT with BODY and invoke CALLBACK."
  (bitbucket-devops-rest-request
   "POST"
   (bitbucket-devops-rest-repository-url context "pipelines")
   callback
   body
   nil
   context))

(defun bitbucket-devops-rest-stop-pipeline
    (context pipeline-uuid callback)
  "Asynchronously stop PIPELINE-UUID in CONTEXT and invoke CALLBACK."
  (bitbucket-devops-rest-request
   "POST"
   (bitbucket-devops-rest-repository-url
    context
    "pipelines"
    pipeline-uuid
    "stopPipeline")
   callback
   nil
   nil
   context))

(defun bitbucket-devops-rest-start-step
    (context pipeline-uuid step-uuid callback)
  "Asynchronously start manual STEP-UUID in PIPELINE-UUID and invoke CALLBACK.

Bitbucket Cloud does not currently expose this operation in the public 2.0
Pipelines API.  This calls the internal endpoint used by Bitbucket's web UI,
which may change before Atlassian publishes a supported API."
  (bitbucket-devops-rest-request
   "POST"
   (bitbucket-devops-rest-internal-repository-url
    context
    "pipelines"
    pipeline-uuid
    "steps"
    step-uuid
    "start_step")
   callback
   nil
   nil
   context))

(provide 'bitbucket-devops-rest)
;;; bitbucket-devops-rest.el ends here
